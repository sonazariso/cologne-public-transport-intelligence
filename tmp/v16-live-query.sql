®SELECT
    DB_NAME() AS DatabaseName,
    CONVERT(DATETIME2(0), SYSUTCDATETIME()) AS CheckedAtUtc,
    @@SERVERNAME AS ServerName;
