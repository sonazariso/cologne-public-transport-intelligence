# Local SQL Server Connection Guide

**Last updated:** 2026-09-06

This project uses the **SQL Server (mssql)** VS Code extension to connect to the SQL Server running in the local VMware environment.

## What was saved on this Mac

The connection profile currently used by VS Code is:

| Setting | Value |
|---|---|
| Profile name | `VM-Ware` |
| Server | `172.16.192.128` |
| Authentication | SQL Login |
| User | `sa` |
| Database | Not fixed in the profile; the server default is used until a database is selected |
| Encryption | `Mandatory` |
| Trust server certificate | Enabled |
| Profile ID | `544834a7-b442-45fb-a976-5c6c0090af42` |

The same profile is saved in:

1. VS Code User Settings, which is where the MSSQL extension normally stores connection profiles.
2. This workspace's `.vscode/settings.json`, so the project has a local, reusable copy of the non-secret connection metadata.

The workspace settings file is deliberately ignored by Git through `.gitignore`. It will remain on this Mac but will not be committed or uploaded to GitHub.

## Password handling

The password is **not** written to `.vscode/settings.json`, SQL scripts, this guide, or Git. `savePassword` is enabled, so the MSSQL extension stores and retrieves the password through VS Code Secret Storage, backed by the macOS Keychain.

If VS Code asks for the password again, enter it in the connection prompt and enable **Save Password**. Do not paste the password into a repository file or a connection string stored in Git.

## Connect in VS Code

1. Open this project folder in VS Code.
2. Open a `.sql` file, for example `sql/05-analytics/01-create-static-analytics-views.sql`.
3. Press `F1` or `Cmd+Shift+P`.
4. Run **MS SQL: Connect**.
5. Select the **VM-Ware** profile.
6. If prompted, enter the SQL password and select **Save Password**.
7. If the profile opens on the server default database, use the database selector in the editor/status bar and choose `CologneTransitIntelligence`.
8. Run the selected statement or query with `Cmd+Shift+E` (or use the editor's **Run Query** command).

For a quick read-only check, run:

```sql
SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    SUSER_SNAME() AS LoginName,
    SYSUTCDATETIME() AS CheckedAtUtc;
```

## Recreate the profile on another Mac or after a reset

1. Install the **SQL Server (mssql)** extension from Microsoft in VS Code.
2. Open the Command Palette with `F1`.
3. Run **MS SQL: Manage Connection Profiles**.
4. Create a new profile with these values:

   - Server: `172.16.192.128`
   - Authentication type: `SQL Login`
   - User: `sa`
   - Database: leave blank, or use `CologneTransitIntelligence` for project queries
   - Encrypt: `Mandatory`
   - Trust server certificate: enabled, if this is still the certificate configuration of the VMware SQL Server
   - Profile name: `VM-Ware`

5. Enter the password when connecting and enable **Save Password**.
6. Confirm that the profile appears under **MS SQL: Connect**.

The password cannot be restored from the Git repository because it is intentionally kept in the operating system's secure storage.

## If the VMware IP address changes

The current address is `172.16.192.128`. If VMware assigns a different address:

1. Check the current IP address of the Windows SQL Server VM.
2. Run **MS SQL: Manage Connection Profiles**.
3. Edit **VM-Ware** and replace only the **Server** value.
4. Reconnect and save the password again if prompted.
5. Update the ignored `.vscode/settings.json` copy if you want this workspace-local metadata to remain accurate.
6. Update scripts or documentation that explicitly use the old address, if any.

## Git safety check

From the project root, run:

```bash
git check-ignore -v .vscode/settings.json
git status --short
```

The first command should report the `.gitignore` rule. The second command should not list `.vscode/settings.json`.

Before committing, also check for accidental secrets:

```bash
git diff --check
git diff -- .gitignore docs/10-LOCAL-SQL-SERVER-CONNECTION-GUIDE.md
```

Never commit a password, API key, or full SQL connection string containing credentials.
