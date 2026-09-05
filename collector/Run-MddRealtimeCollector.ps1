$ErrorActionPreference = "Stop"

$collectorPath = "C:\Collector\Invoke-MddRealtimeCollector.ps1"
$logDirectory = "C:\Collector\Logs"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logDirectory "collector-$timestamp.log"

try {
    & $collectorPath *>&1 |
        Tee-Object -FilePath $logPath

    if ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) {
        throw "Collector returned exit code $LASTEXITCODE."
    }

    Add-Content $logPath "`r`nSTATUS: SUCCESS"
    exit 0
}
catch {
    Add-Content $logPath "`r`nSTATUS: FAILED"
    Add-Content $logPath "ERROR: $($_.Exception.Message)"
    Add-Content $logPath "DETAIL: $($_ | Out-String)"

    exit 1
}
