# Local Documentation Status

**Updated:** 2026-09-05

The local project documentation is being maintained during the realtime collector implementation and will be synchronized manually to GitHub using GitHub Desktop.

Current local-only additions:

- MDD non-commercial pilot permission / retention interpretation.
- First persisted realtime snapshot and working-layer validation.
- VM resource decision: keep the collector lightweight and use PowerShell instead of installing the .NET SDK on the constrained SQL Server VM.
- One-shot PowerShell collector prototype at `collector/Invoke-MddRealtimeCollector.ps1`.

GitHub remains unchanged until the user performs a manual synchronization.
