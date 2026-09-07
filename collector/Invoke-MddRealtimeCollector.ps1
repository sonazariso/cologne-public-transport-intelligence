[CmdletBinding()]
param(
    [string]$Endpoint = "https://mdd.gorheinland.com/delfi",
    [string]$StopPointRef,
    [int]$NumberOfResults = 5,
    [string]$ConnectionString = "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;",
    [int]$RequestTimeoutSeconds = 30,
    [int]$MaxAttempts = 3,
    [int]$InitialRetryDelaySeconds = 2,
    [int]$MaxRetryDelaySeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "MddRealtimeCollector.psm1"
Import-Module $modulePath -Force

$invokeParameters = @{
    Endpoint                 = $Endpoint
    StopPointRef             = $StopPointRef
    ConnectionString         = $ConnectionString
    RequestTimeoutSeconds    = $RequestTimeoutSeconds
    MaxAttempts              = $MaxAttempts
    InitialRetryDelaySeconds = $InitialRetryDelaySeconds
    MaxRetryDelaySeconds     = $MaxRetryDelaySeconds
}

if ($PSBoundParameters.ContainsKey("NumberOfResults")) {
    $invokeParameters.NumberOfResults = $NumberOfResults
}

$null = Invoke-MddRealtimeCollector @invokeParameters
