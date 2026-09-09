# Project Locations and Synchronization

**Audit timestamp:** 2026-09-09 09:35:13 UTC
**Scope:** location and synchronization audit before Power BI development. No
database, Collector, Power BI, or raw-data changes were made.

## Repository inventory

| Project path | Exact macOS location |
|---|---|
| `README.md` | `/Users/admin/Documents/cologne-public-transport-intelligence/README.md` |
| `docs/` | `/Users/admin/Documents/cologne-public-transport-intelligence/docs/` |
| `sql/` | `/Users/admin/Documents/cologne-public-transport-intelligence/sql/` |
| `collector/` | `/Users/admin/Documents/cologne-public-transport-intelligence/collector/` |
| `powerbi/` | `/Users/admin/Documents/cologne-public-transport-intelligence/powerbi/` |
| `data/` | `/Users/admin/Documents/cologne-public-transport-intelligence/data/` |
| `scripts/` | `/Users/admin/Documents/cologne-public-transport-intelligence/scripts/` |

## Authoritative location and synchronization map

| Component | Authoritative location | Access from macOS | Access from Windows | Version-controlled? | Synchronization method | Current synchronization status |
|---|---|---|---|---|---|---|
| macOS Git repository | `/Users/admin/Documents/cologne-public-transport-intelligence/` | Direct local filesystem; GitHub Desktop and VS Code use this root | VMware shared-folder view | Yes | Git working tree on macOS; shared-folder visibility in Windows | Branch `develop`; synchronization checkpoint commit is `affeee02d8864e92e614146bfbf6b5136be965d6`. At the checkpoint, local `develop`, `origin/develop`, and `origin/main` were identical and the working tree was clean. |
| GitHub repository | `https://github.com/sonazariso/cologne-public-transport-intelligence.git` | `origin` remote; fetched during this audit | Available through the shared repository if Git is used there | Yes | Manual Git fetch/commit/push; no automatic push | At the synchronization checkpoint, `origin/develop` and `origin/main` were both `affeee02d8864e92e614146bfbf6b5136be965d6`; local `develop...origin/develop` and `develop...origin/main` were both `0 0`. Synchronized. |
| Windows shared repository | `\\vmware-host\Shared Folders\cologne-public-transport-intelligence` | Same underlying macOS repository root; the UNC path is not a second clone | Direct Explorer, VS Code, and Power BI access | Yes, through the macOS Git repository | VMware shared folder; Git operations remain manual | Project documentation confirms this is the macOS repository shared into Windows, not an independent Windows Git clone. Its files therefore reflect the macOS working copy, which is synchronized with GitHub at the documented checkpoint. |
| SQL Server / `CologneTransitIntelligence` | SQL Server in the Windows VMware VM; network route `172.16.192.128:1433`; `@@SERVERNAME = DataAnalyst-VM` | VS Code MSSQL profile `VM-Ware` to `172.16.192.128`, SQL Login `sa` | SQL Server local tools and Power BI through `localhost` | No; database state is live runtime state (deployment scripts are version-controlled) | Live SQL connection over the VMware network or Windows-local connection | Read-only connection verified at 2026-09-09 08:44:42 UTC. Physical files: `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\CologneTransitIntelligence.mdf` and `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\CologneTransitIntelligence_log.ldf`. |
| Raw GTFS | `/Users/admin/Documents/CologneTransitData/google_transit_goR/` | Direct local macOS source path | No direct Windows mapping was verified; SQL Server loads only from a Windows service-readable path | No; raw GTFS is outside Git | External local source; no repository synchronization | Directory exists at the discovered path and was verified read-only. `agency.txt`, `stops.txt`, `routes.txt`, `trips.txt`, `stop_times.txt`, `calendar.txt`, and `calendar_dates.txt` are present. Raw GTFS was not added to Git. |
| Collector repository source | `/Users/admin/Documents/cologne-public-transport-intelligence/collector/` | Direct local filesystem | `\\vmware-host\Shared Folders\cologne-public-transport-intelligence\collector\` | Yes | Same shared repository files plus manual Git synchronization | Repository source is present. No Collector source files were changed in this audit. |
| Collector Windows runtime | `C:\Collector\` | Not the same macOS filesystem location; no direct runtime access used | Direct Windows runtime path | No; runtime copy is separate from the repository | Manual deployment/copy and checksum comparison | Separate runtime copy, not the shared repository. No redeploy or modification was attempted; a fresh Windows runtime checksum was not performed in this macOS-only audit. |
| Power BI artifact directory | Windows preferred save path `\\vmware-host\Shared Folders\cologne-public-transport-intelligence\powerbi\`; underlying macOS path `/Users/admin/Documents/cologne-public-transport-intelligence/powerbi/` | Direct local Git working copy | Direct shared-folder path from Power BI Desktop | Source assets: yes; no PBIX currently exists | Save through VMware shared folder, then manually commit/push if desired | Directory exists and contains the source-controlled Power BI assets. Power BI was not started and no PBIX was created. |
| VS Code SQL connection profile | Workspace metadata `/Users/admin/Documents/cologne-public-transport-intelligence/.vscode/settings.json`; profile also exists in VS Code User Settings; password is in macOS Keychain/Secret Storage | VS Code MSSQL profile `VM-Ware`; server `172.16.192.128`; SQL Login; user `sa` | Not a Windows profile; Windows Power BI uses its own `localhost` connection | No; workspace settings are ignored and the password is not in Git | Manual profile recreation; password stored by the operating system | Profile metadata is present and the read-only SQL connection succeeded. The password is intentionally not documented. |

## Intended Windows Power BI connection

| Setting | Value |
|---|---|
| Server | `localhost` |
| Database | `CologneTransitIntelligence` |
| Connectivity mode | `Import` |

In Power BI Desktop, `localhost` means SQL Server running inside the Windows
VM. The macOS-side address `172.16.192.128` is the VMware network route to
that same SQL Server, not a second database.

## Git synchronization evidence

The remote was refreshed with `git fetch origin` before comparison. At the
latest synchronization checkpoint, 2026-09-09 09:35:13 UTC:

- Current branch: `develop`
- Local `develop`: `affeee02d8864e92e614146bfbf6b5136be965d6`
- `origin/develop`: `affeee02d8864e92e614146bfbf6b5136be965d6`
- `origin/main`: `affeee02d8864e92e614146bfbf6b5136be965d6`
- `git rev-list --left-right --count develop...origin/develop`: `0 0`
- `git rev-list --left-right --count develop...origin/main`: `0 0`
- `git status --short`: empty at the checkpoint.

The macOS repository, Windows shared-folder view, `origin/develop`, and
`origin/main` represented the same project state at that checkpoint. This
documentation update is a synchronization-record change made afterward and
is committed and pushed as part of this task; the final refs are verified
again after that commit.

## Windows runtime separation

Project documentation distinguishes the repository source under `collector/`
from the separate runtime copy under `C:\Collector\`. The runtime is not the
same filesystem location as the macOS repository and was not modified or
redeployed for this audit.
