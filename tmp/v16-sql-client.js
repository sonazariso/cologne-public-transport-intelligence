const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const projectRoot = process.cwd();
const envText = fs.readFileSync(path.join(projectRoot, ".env"), "utf8");
const config = {};
for (const line of envText.split(/\r?\n/)) {
    const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!match) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
    }
    config[match[1]] = value;
}

const dotnet = path.join(
    process.env.HOME,
    "Library/Application Support/Code/User/globalStorage/ms-dotnettools.vscode-dotnet-runtime/.dotnet/10.0.0~x64/dotnet"
);
const service = path.join(
    process.env.HOME,
    ".vscode/extensions/ms-mssql.mssql-1.45.1/sqltoolsservice/6.0.20260810.1/Portable/MicrosoftSqlToolsServiceLayer.dll"
);
const dataPath = path.join(projectRoot, "tmp", "v16-sqltools-data");
fs.mkdirSync(dataPath, { recursive: true });

const child = spawn(dotnet, [
    service,
    "--application-name", "vscode-mssql",
    "--data-path", dataPath,
    "--tracing-level", "Error"
], { stdio: ["pipe", "pipe", "pipe"] });

let buffer = Buffer.alloc(0);
let nextId = 1;
const pending = new Map();

function sendMessage(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    child.stdin.write(Buffer.concat([
        Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii"),
        body
    ]));
}

function request(method, params, timeoutMs = 60000) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`Timed out waiting for ${method}`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer, method });
        sendMessage({ jsonrpc: "2.0", id, method, params });
    });
}

function notify(method, params) {
    sendMessage({ jsonrpc: "2.0", method, params });
}

function handleMessage(message) {
    if (message.id !== undefined && pending.has(message.id)) {
        const item = pending.get(message.id);
        pending.delete(message.id);
        clearTimeout(item.timer);
        if (message.error) item.reject(new Error(`${item.method}: ${JSON.stringify(message.error)}`));
        else item.resolve(message.result);
        return;
    }

    if (message.method === "connection/complete") {
        const params = message.params || {};
        process.stderr.write(`connection/complete: ${JSON.stringify({
            ownerUri: params.ownerUri,
            errorMessage: params.errorMessage,
            serverConnectionId: params.serverConnectionId,
            connectionSummary: params.connectionSummary ? {
                serverName: params.connectionSummary.serverName,
                databaseName: params.connectionSummary.databaseName,
                userName: params.connectionSummary.userName
            } : undefined
        })}\n`);
    }
}

child.stdout.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
        const separator = buffer.indexOf(Buffer.from("\r\n\r\n"));
        if (separator < 0) return;
        const header = buffer.slice(0, separator).toString("ascii");
        const match = header.match(/Content-Length:\s*(\d+)/i);
        if (!match) throw new Error(`Missing Content-Length in: ${header}`);
        const length = Number(match[1]);
        const start = separator + 4;
        if (buffer.length < start + length) return;
        const body = buffer.slice(start, start + length).toString("utf8");
        buffer = buffer.slice(start + length);
        handleMessage(JSON.parse(body));
    }
});

child.stderr.on("data", chunk => {
    const text = chunk.toString();
    if (text.trim()) process.stderr.write(text);
});

child.on("error", error => {
    for (const item of pending.values()) {
        clearTimeout(item.timer);
        item.reject(error);
    }
    pending.clear();
});

async function main() {
    const queryPath = process.argv[2];
    if (!queryPath) throw new Error("Usage: node tmp/v16-sql-client.js <query.sql>");
    const query = fs.readFileSync(path.resolve(queryPath), "utf8");
    const ownerUri = `file://${path.join(projectRoot, "tmp", "v16-live-query.sql")}`;

    await request("initialize", {
        processId: process.pid,
        clientInfo: { name: "CodexSqlProbe", version: "1.0" },
        rootPath: projectRoot,
        rootUri: `file://${projectRoot}`,
        capabilities: {},
        workspaceFolders: [],
        initializationOptions: {},
        trace: "off"
    });
    notify("initialized", {});

    const connection = {
        serverName: config.SQL_SERVER,
        port: Number(config.SQL_PORT || 1433),
        databaseName: config.SQL_DATABASE,
        userName: config.SQL_USER,
        password: config.SQL_PASSWORD,
        authenticationType: "SqlLogin",
        encrypt: config.SQL_ENCRYPT || "Mandatory",
        trustServerCertificate: String(config.SQL_TRUST_SERVER_CERTIFICATE).toLowerCase() === "true",
        applicationName: "CodexSqlProbe",
        connectTimeout: 30,
        commandTimeout: 120
    };

    const connected = await request("connection/connect", {
        ownerUri,
        connection,
        type: "Default"
    });
    if (connected !== true) {
        throw new Error(`connection/connect returned ${JSON.stringify(connected)}`);
    }

    const result = await request("query/simpleexecute", {
        ownerUri,
        queryString: query
    });
    process.stdout.write(JSON.stringify(result) + "\n");

    try { await request("connection/disconnect", { ownerUri, type: "Default" }, 10000); } catch {}
    try { await request("shutdown", null, 10000); } catch {}
    notify("exit", null);
    child.stdin.end();
}

main().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    child.kill();
    process.exitCode = 1;
});
