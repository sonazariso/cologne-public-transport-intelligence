[CmdletBinding()]
param(
    [string]$Endpoint = "https://mdd.gorheinland.com/delfi",

    [string]$ApiKey,

    [ValidateRange(1, 120)]
    [int]$RequestTimeoutSeconds = 30,

    [string]$ConnectionString = "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;",

    [ValidateRange(0, 5000)]
    [int]$InterRequestDelayMilliseconds = 250,

    [string]$BaselinePath,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $scriptDirectory

if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    $BaselinePath = Join-Path $repositoryRoot "docs/24-REALTIME-50-STATION-BASELINE.md"
}
elseif (-not [System.IO.Path]::IsPathRooted($BaselinePath)) {
    $BaselinePath = Join-Path $repositoryRoot $BaselinePath
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $repositoryRoot "docs/25-REALTIME-50-STATION-MDD-COMPATIBILITY.md"
}
elseif (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path $repositoryRoot $ReportPath
}

$expectedBaselineSha256 = "3d44587e5c07f25ba25468e1cfb620c7932bb381231d149557492afd34019ee8"
$numberOfResults = 1
$maxAttempts = 1
$approvedStationCount = 50

function Get-ObjectPropertyValue {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return $Object.$PropertyName
    }

    return $null
}

function Get-SafeErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception,

        [string]$ApiKey,

        [string]$Endpoint
    )

    $message = [string]$Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $Exception.GetType().FullName
    }

    if (-not [string]::IsNullOrEmpty($ApiKey)) {
        $message = $message.Replace($ApiKey, "<redacted>")
    }

    if (-not [string]::IsNullOrEmpty($Endpoint)) {
        $message = $message.Replace($Endpoint, "<endpoint>")
    }

    $message = $message -replace '(?i)(x-api-key|authorization|api[\s-]?key)\s*[:=]\s*[^;\r\n]+', '$1=<redacted>'
    $message = $message -replace '(?i)(data source|server|initial catalog|database|user id|uid|password|pwd)\s*=\s*[^;\r\n]+', '$1=<redacted>'
    $message = $message -replace '(?i)(https?://[^?\s]+)\?[^\s\r\n]+', '$1?<redacted>'

    $message = $message -replace '[\r\n]+', ' '
    if ($message.Length -gt 500) {
        $message = $message.Substring(0, 500)
    }

    return $message
}

function ConvertTo-MarkdownCell {
    param($Value)

    if ($null -eq $Value) {
        return "—"
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "—"
    }

    return ($text -replace '[\r\n]+', ' ' -replace '\|', '\|')
}

function Format-ReportBoolean {
    param($Value)

    if ($null -eq $Value) {
        return "—"
    }

    if ([bool]$Value) {
        return "Yes"
    }

    return "No"
}

function Resolve-MddCompatibilityApiKey {
    param([string]$ExplicitApiKey)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitApiKey)) {
        return $ExplicitApiKey
    }

    $processApiKey = [System.Environment]::GetEnvironmentVariable(
        "MDD_API_KEY",
        [System.EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrWhiteSpace($processApiKey)) {
        return $processApiKey
    }

    $userApiKey = $null
    try {
        $userApiKey = [System.Environment]::GetEnvironmentVariable(
            "MDD_API_KEY",
            [System.EnvironmentVariableTarget]::User
        )
    }
    catch {
        $userApiKey = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($userApiKey)) {
        return $userApiKey
    }

    throw "MDD API key is required. Provide -ApiKey or set MDD_API_KEY in the process or User environment. No MDD/TRIAS request was made."
}

function Get-EndpointHostname {
    param([Parameter(Mandatory = $true)][string]$EndpointValue)

    $endpointUri = $null
    try {
        $endpointUri = [System.Uri]$EndpointValue
    }
    catch {
        throw "Endpoint must be an absolute HTTP or HTTPS URI."
    }

    if (-not $endpointUri.IsAbsoluteUri -or
        @("http", "https") -notcontains $endpointUri.Scheme.ToLowerInvariant()) {
        throw "Endpoint must be an absolute HTTP or HTTPS URI."
    }

    return $endpointUri.Host
}

function Read-ApprovedBaseline {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Approved baseline document was not found: $Path"
    }

    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Approved baseline changed and must be reviewed first. Expected SHA256 $ExpectedSha256 but found $actualSha256. No MDD/TRIAS request was made."
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $rowPattern = '(?m)^\|\s*(\d+)\s*\|\s*([^|\r\n]+)\s*\|\s*([^|\r\n]+)\s*\|\s*(Tier\s+[ABC])\s*\|\s*([^|\r\n]+)\s*\|\s*$'
    $rowMatches = [System.Text.RegularExpressions.Regex]::Matches($content, $rowPattern)

    $stations = @(
        foreach ($rowMatch in $rowMatches) {
            [PSCustomObject][ordered]@{
                Rank                    = [int]$rowMatch.Groups[1].Value
                ParentStationId         = $rowMatch.Groups[2].Value.Trim()
                ParentStationName       = $rowMatch.Groups[3].Value.Trim()
                Tier                    = $rowMatch.Groups[4].Value.Trim() -replace '\s+', ' '
                ProposedSamplingInterval = $rowMatch.Groups[5].Value.Trim()
            }
        }
    )

    if ($stations.Count -ne $approvedStationCount) {
        throw "Approved baseline validation failed: expected exactly $approvedStationCount station rows but found $($stations.Count). No MDD/TRIAS request was made."
    }

    $distinctParentStationIds = @(
        $stations | Select-Object -ExpandProperty ParentStationId -Unique
    )
    if ($distinctParentStationIds.Count -ne $approvedStationCount) {
        throw "Approved baseline validation failed: expected exactly $approvedStationCount distinct ParentStationId values but found $($distinctParentStationIds.Count). No MDD/TRIAS request was made."
    }

    $actualRanks = @($stations | ForEach-Object { [int]$_.Rank })
    $expectedRanks = @(1..$approvedStationCount)
    if (($actualRanks -join ",") -ne ($expectedRanks -join ",")) {
        throw "Approved baseline validation failed: ranks are not exactly 1 through $approvedStationCount. No MDD/TRIAS request was made."
    }

    $tierCounts = @{
        "Tier A" = @($stations | Where-Object { $_.Tier -eq "Tier A" }).Count
        "Tier B" = @($stations | Where-Object { $_.Tier -eq "Tier B" }).Count
        "Tier C" = @($stations | Where-Object { $_.Tier -eq "Tier C" }).Count
    }
    if ($tierCounts["Tier A"] -ne 10 -or
        $tierCounts["Tier B"] -ne 20 -or
        $tierCounts["Tier C"] -ne 20) {
        throw "Approved baseline validation failed: expected Tier A/B/C counts of 10/20/20 but found $($tierCounts['Tier A'])/$($tierCounts['Tier B'])/$($tierCounts['Tier C']). No MDD/TRIAS request was made."
    }

    $expectedIntervals = @{
        "Tier A" = "10 min"
        "Tier B" = "15 min"
        "Tier C" = "30 min"
    }
    foreach ($station in $stations) {
        if ($station.ProposedSamplingInterval -ne $expectedIntervals[$station.Tier]) {
            throw "Approved baseline validation failed: station rank $($station.Rank) has an unexpected sampling interval. No MDD/TRIAS request was made."
        }
    }

    return [PSCustomObject][ordered]@{
        Path                    = $Path
        Sha256                  = $actualSha256
        Stations                = $stations
        StationCount            = $stations.Count
        DistinctParentStationIdCount = $distinctParentStationIds.Count
        TierACount              = $tierCounts["Tier A"]
        TierBCount              = $tierCounts["Tier B"]
        TierCCount              = $tierCounts["Tier C"]
    }
}

function Get-DatabaseSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionStringValue,

        [ValidateRange(1, 300)]
        [int]$CommandTimeoutSeconds = 30
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionStringValue
    $command = $null
    $reader = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::Text
        $command.CommandTimeout = $CommandTimeoutSeconds
        $command.CommandText = @"
SELECT
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget)) AS SamplingTargetCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingSlot)) AS SamplingSlotCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget WHERE IsEnabled = 1)) AS EnabledSamplingTargetCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation)) AS StopObservationCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM stg.MddRealtimeSituationObservation)) AS SituationObservationCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopSituationLink)) AS StopSituationLinkCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddCollectorRun)) AS CollectorRunCount;
"@

        $reader = $command.ExecuteReader()
        if (-not $reader.Read()) {
            throw "Read-only database safety query returned no row."
        }

        $values = [ordered]@{}
        for ($index = 0; $index -lt $reader.FieldCount; $index++) {
            $value = $reader.GetValue($index)
            if ($value -is [DBNull]) {
                $value = $null
            }

            $values[$reader.GetName($index)] = $value
        }

        return [PSCustomObject]$values
    }
    finally {
        if ($null -ne $reader) {
            $reader.Close()
            $reader.Dispose()
        }

        if ($null -ne $command) {
            $command.Dispose()
        }

        $connection.Close()
        $connection.Dispose()
    }
}

function Get-StaticParentStationRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Stations,

        [Parameter(Mandatory = $true)]
        [string]$ConnectionStringValue,

        [ValidateRange(1, 300)]
        [int]$CommandTimeoutSeconds = 30
    )

    $rowsByStopId = @{}
    $stopIds = @(
        $Stations | ForEach-Object { [string]$_.ParentStationId }
    )
    foreach ($stopId in $stopIds) {
        $rowsByStopId[$stopId] = $null
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionStringValue
    $command = $null
    $reader = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::Text
        $command.CommandTimeout = $CommandTimeoutSeconds

        $placeholders = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $stopIds.Count; $index++) {
            $parameterName = "@stopId$index"
            $placeholders.Add($parameterName) | Out-Null
            $parameter = $command.Parameters.Add($parameterName, [System.Data.SqlDbType]::NVarChar, 100)
            $parameter.Value = $stopIds[$index]
        }

        $command.CommandText = @"
SELECT
    StopId,
    StopName,
    LocationTypeCode,
    Latitude,
    Longitude
FROM dw.DimStop
WHERE StopId IN ($($placeholders -join ", "));
"@

        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            $stopId = [string]$reader["StopId"]
            $stopName = $reader["StopName"]
            $locationTypeCode = $reader["LocationTypeCode"]
            $latitude = $reader["Latitude"]
            $longitude = $reader["Longitude"]

            if ($stopName -is [DBNull]) {
                $stopName = $null
            }
            if ($locationTypeCode -is [DBNull]) {
                $locationTypeCode = $null
            }
            if ($latitude -is [DBNull]) {
                $latitude = $null
            }
            if ($longitude -is [DBNull]) {
                $longitude = $null
            }

            $rowsByStopId[$stopId] = [PSCustomObject][ordered]@{
                StopId            = $stopId
                StopName          = $stopName
                LocationTypeCode  = $locationTypeCode
                Latitude          = $latitude
                Longitude         = $longitude
            }
        }

        return ,$rowsByStopId
    }
    finally {
        if ($null -ne $reader) {
            $reader.Close()
            $reader.Dispose()
        }

        if ($null -ne $command) {
            $command.Dispose()
        }

        $connection.Close()
        $connection.Dispose()
    }
}

function New-StaticValidationInfo {
    param(
        [Parameter(Mandatory = $true)]
        $Station,

        $DatabaseRow,

        [string]$DatabaseError
    )

    if (-not [string]::IsNullOrWhiteSpace($DatabaseError)) {
        return [PSCustomObject][ordered]@{
            StaticParentStationExists  = $null
            StaticLocationTypeValid    = $null
            StaticCoordinatesAvailable = $null
            StaticNameMatches          = $null
            StaticStopName             = $null
            StaticValidationMessage    = "Database cross-check unavailable: $DatabaseError"
        }
    }

    $exists = $null -ne $DatabaseRow
    $locationTypeValid = $false
    $coordinatesAvailable = $false
    $actualName = $null
    $nameMatches = $false

    if ($exists) {
        $locationTypeValid = [int]$DatabaseRow.LocationTypeCode -eq 1
        $coordinatesAvailable = $null -ne $DatabaseRow.Latitude -and $null -ne $DatabaseRow.Longitude
        $actualName = [string]$DatabaseRow.StopName
        $nameMatches = [string]::Equals(
            ([string]$Station.ParentStationName).Trim(),
            ([string]$actualName).Trim(),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }

    $failureReasons = [System.Collections.Generic.List[string]]::new()
    if (-not $exists) {
        $failureReasons.Add("parent-station row not found") | Out-Null
    }
    elseif (-not $locationTypeValid) {
        $failureReasons.Add("LocationTypeCode is not 1") | Out-Null
    }

    if ($exists -and -not $coordinatesAvailable) {
        $failureReasons.Add("coordinates are missing") | Out-Null
    }
    if ($exists -and -not $nameMatches) {
        $failureReasons.Add("StopName differs from the approved baseline") | Out-Null
    }

    $validationMessage = if ($failureReasons.Count -eq 0) {
        "Static parent-station validation passed."
    }
    else {
        $failureReasons -join "; "
    }

    return [PSCustomObject][ordered]@{
        StaticParentStationExists  = $exists
        StaticLocationTypeValid    = $locationTypeValid
        StaticCoordinatesAvailable = $coordinatesAvailable
        StaticNameMatches          = $nameMatches
        StaticStopName             = $actualName
        StaticValidationMessage    = $validationMessage
    }
}

function New-CompatibilityResult {
    param(
        [Parameter(Mandatory = $true)]
        $Station,

        [Parameter(Mandatory = $true)]
        $StaticValidation
    )

    return [PSCustomObject][ordered]@{
        Rank                         = $Station.Rank
        ParentStationId              = $Station.ParentStationId
        ParentStationName            = $Station.ParentStationName
        Tier                         = $Station.Tier
        ProposedSamplingInterval     = $Station.ProposedSamplingInterval
        TestedAtUtc                  = $null
        HttpReachable                = $null
        HttpStatus                   = $null
        HttpAttempts                 = 0
        ParseSucceeded               = $null
        ReturnedStopEventCount       = $null
        CompatibilityStatus          = $null
        FailureCategory              = $null
        FailureMessage               = $null
        FirstReturnedStopPointRef    = $null
        FirstReturnedStopName        = $null
        StaticParentStationExists    = $StaticValidation.StaticParentStationExists
        StaticLocationTypeValid      = $StaticValidation.StaticLocationTypeValid
        StaticCoordinatesAvailable   = $StaticValidation.StaticCoordinatesAvailable
        StaticNameMatches            = $StaticValidation.StaticNameMatches
        StaticStopName               = $StaticValidation.StaticStopName
        StaticValidationMessage      = $StaticValidation.StaticValidationMessage
    }
}

function Get-MddServiceRejectionClassification {
    param(
        [Parameter(Mandatory = $true)]
        $ResponseContent,

        [string]$ApiKey,

        [string]$Endpoint
    )

    $json = $null
    try {
        if ($ResponseContent -is [string]) {
            $json = $ResponseContent | ConvertFrom-Json
        }
        else {
            $json = $ResponseContent
        }
    }
    catch {
        return $null
    }

    $serviceDelivery = Get-ObjectPropertyValue -Object $json -PropertyName "serviceDelivery"
    if ($null -eq $serviceDelivery) {
        return $null
    }

    $statusValue = Get-ObjectPropertyValue -Object $serviceDelivery -PropertyName "status"
    $statusIsFalse = (
        ($statusValue -is [bool] -and -not $statusValue) -or
        ([string]$statusValue -match '^(?i:false|0)$')
    )

    $diagnosticValues = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in @(
        "error",
        "serviceError",
        "errorCondition",
        "diagnosis",
        "errorText"
    )) {
        $value = Get-ObjectPropertyValue -Object $serviceDelivery -PropertyName $propertyName
        if ($null -ne $value) {
            if ($value -is [string]) {
                $diagnosticValues.Add([string]$value) | Out-Null
            }
            else {
                try {
                    $diagnosticValues.Add(($value | ConvertTo-Json -Depth 10 -Compress)) | Out-Null
                }
                catch {
                    $diagnosticValues.Add([string]$value) | Out-Null
                }
            }
        }
    }

    $classificationText = $diagnosticValues -join " "
    $hasServiceError = $diagnosticValues.Count -gt 0
    if (-not $statusIsFalse -and -not $hasServiceError) {
        return $null
    }

    $hasExplicitInvalidStopPointRef = (
        $classificationText -match '(?i)(invalid|unknown|unsupported|not[\s_-]*found|does[\s_-]*not[\s_-]*exist)' -and
        $classificationText -match '(?i)(stop[\s_-]*point|stoppointref|location[\s_-]*ref|stop)'
    )

    if ($hasExplicitInvalidStopPointRef) {
        return [PSCustomObject][ordered]@{
            CompatibilityStatus = "InvalidStopPointRefConfirmed"
            FailureCategory     = "InvalidStopPointRefConfirmed"
            FailureMessage      = "MDD/TRIAS explicitly identified the requested StopPointRef or location as invalid, unknown, or unsupported."
        }
    }

    return [PSCustomObject][ordered]@{
        CompatibilityStatus = "SourceRejected"
        FailureCategory     = "SourceRejected"
        FailureMessage      = "MDD/TRIAS explicitly rejected the request at service level."
    }
}

function Compare-DatabaseSnapshots {
    param(
        $Before,
        $After
    )

    if ($null -eq $Before -or $null -eq $After) {
        return [PSCustomObject][ordered]@{
            Status                         = "Unknown"
            SamplingConfigurationUnchanged = $null
            PersistenceTablesUnchanged     = $null
            CollectorAuditRowsUnchanged    = $null
            EnabledTargetCountUnchanged    = $null
        }
    }

    $samplingTargetUnchanged = (
        [int64]$Before.SamplingTargetCount -eq [int64]$After.SamplingTargetCount
    )
    $samplingSlotUnchanged = (
        [int64]$Before.SamplingSlotCount -eq [int64]$After.SamplingSlotCount
    )
    $enabledTargetUnchanged = (
        [int64]$Before.EnabledSamplingTargetCount -eq [int64]$After.EnabledSamplingTargetCount
    )
    $stopObservationUnchanged = (
        [int64]$Before.StopObservationCount -eq [int64]$After.StopObservationCount
    )
    $situationObservationUnchanged = (
        [int64]$Before.SituationObservationCount -eq [int64]$After.SituationObservationCount
    )
    $linkUnchanged = (
        [int64]$Before.StopSituationLinkCount -eq [int64]$After.StopSituationLinkCount
    )
    $collectorRunUnchanged = (
        [int64]$Before.CollectorRunCount -eq [int64]$After.CollectorRunCount
    )

    $databaseStatus = if ($samplingTargetUnchanged -and
                          $samplingSlotUnchanged -and
                          $enabledTargetUnchanged -and
                          $stopObservationUnchanged -and
                          $situationObservationUnchanged -and
                          $linkUnchanged -and
                          $collectorRunUnchanged) { "Unchanged" } else { "Changed" }

    return [PSCustomObject][ordered]@{
        Status                         = $databaseStatus
        SamplingConfigurationUnchanged = ($samplingTargetUnchanged -and $samplingSlotUnchanged)
        PersistenceTablesUnchanged     = ($stopObservationUnchanged -and $situationObservationUnchanged -and $linkUnchanged)
        CollectorAuditRowsUnchanged    = $collectorRunUnchanged
        EnabledTargetCountUnchanged    = $enabledTargetUnchanged
    }
}

function Write-MddCompatibilityReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Baseline,

        [Parameter(Mandatory = $true)]
        [string]$EndpointHostname,

        [Parameter(Mandatory = $true)]
        [datetime]$RunStartedAtUtc,

        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        $Summary,

        $DatabaseBefore,
        $DatabaseAfter,
        $DatabaseSafety,
        [string]$DatabaseError,
        [string]$DatabaseSafetyError
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Realtime 50-Station MDD/TRIAS Compatibility") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Status: ROADMAP ITEM 3 COMPATIBILITY TEST") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Test timestamp UTC: $( $RunStartedAtUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') )") | Out-Null
    $lines.Add("Endpoint hostname: $(ConvertTo-MarkdownCell $EndpointHostname)") | Out-Null
    $lines.Add("Approved baseline: $(ConvertTo-MarkdownCell (Split-Path -Leaf $Baseline.Path))") | Out-Null
    $lines.Add("Approved baseline SHA256: $(ConvertTo-MarkdownCell $Baseline.Sha256)") | Out-Null
    $lines.Add("NumberOfResults: 1") | Out-Null
    $lines.Add("MaxAttempts: 1") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Metric | Value |") | Out-Null
    $lines.Add("| --- | ---: |") | Out-Null
    $lines.Add("| ApprovedStationCount | $($Summary.ApprovedStationCount) |") | Out-Null
    $lines.Add("| TestedStationCount | $($Summary.TestedStationCount) |") | Out-Null
    $lines.Add("| CompatibleWithEventsCount | $($Summary.CompatibleWithEventsCount) |") | Out-Null
    $lines.Add("| CompatibleNoCurrentEventsCount | $($Summary.CompatibleNoCurrentEventsCount) |") | Out-Null
    $lines.Add("| CompatibleTotalCount | $($Summary.CompatibleTotalCount) |") | Out-Null
    $lines.Add("| HttpFailureCount | $($Summary.HttpFailureCount) |") | Out-Null
    $lines.Add("| TransportFailureCount | $($Summary.TransportFailureCount) |") | Out-Null
    $lines.Add("| ParseFailureCount | $($Summary.ParseFailureCount) |") | Out-Null
    $lines.Add("| SourceRejectedCount | $($Summary.SourceRejectedCount) |") | Out-Null
    $lines.Add("| InvalidStopPointRefConfirmedCount | $($Summary.InvalidStopPointRefConfirmedCount) |") | Out-Null
    $lines.Add("| StaticValidationFailureCount | $($Summary.StaticValidationFailureCount) |") | Out-Null
    $lines.Add("| TotalHttpAttempts | $($Summary.TotalHttpAttempts) |") | Out-Null
    $lines.Add("| Compatibility coverage | $($Summary.CompatibilityCoveragePercentage)% |") | Out-Null
    $lines.Add("| GlobalAuthenticationFailureCount | $($Summary.GlobalAuthenticationFailureCount) |") | Out-Null
    $lines.Add("| GlobalRateLimitFailureCount | $($Summary.GlobalRateLimitFailureCount) |") | Out-Null
    $lines.Add("| NotTestedGlobalFailureCount | $($Summary.NotTestedGlobalFailureCount) |") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Station results") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Rank | ParentStationId | ParentStationName | Status | HTTP | Parsed | Events |") | Out-Null
    $lines.Add("| ---: | --- | --- | --- | ---: | --- | ---: |") | Out-Null

    foreach ($result in ($Results | Sort-Object Rank)) {
        $httpStatus = if ($null -eq $result.HttpStatus) { "—" } else { [string]$result.HttpStatus }
        $parsed = if ($null -eq $result.ParseSucceeded) {
            "—"
        }
        else {
            Format-ReportBoolean $result.ParseSucceeded
        }
        $events = if ($null -eq $result.ReturnedStopEventCount) {
            "—"
        }
        else {
            [string]$result.ReturnedStopEventCount
        }

        $lines.Add(
            "| $($result.Rank) | $(ConvertTo-MarkdownCell $result.ParentStationId) | $(ConvertTo-MarkdownCell $result.ParentStationName) | $(ConvertTo-MarkdownCell $result.CompatibilityStatus) | $httpStatus | $parsed | $events |"
        ) | Out-Null
    }

    $failedResults = @(
        $Results | Where-Object {
            $_.CompatibilityStatus -notin @("CompatibleWithEvents", "CompatibleNoCurrentEvents")
        } | Sort-Object Rank
    )
    if ($failedResults.Count -gt 0) {
        $lines.Add("") | Out-Null
        $lines.Add("## Failure diagnostics") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("Only sanitized diagnostic messages are included; response bodies and credentials are not stored.") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("| ParentStationId | Status | Failure category | Sanitized reason |") | Out-Null
        $lines.Add("| --- | --- | --- | --- |") | Out-Null
        foreach ($result in $failedResults) {
            $lines.Add(
                "| $(ConvertTo-MarkdownCell $result.ParentStationId) | $(ConvertTo-MarkdownCell $result.CompatibilityStatus) | $(ConvertTo-MarkdownCell $result.FailureCategory) | $(ConvertTo-MarkdownCell $result.FailureMessage) |"
            ) | Out-Null
        }
    }

    $staticFailures = @(
        $Results | Where-Object {
            $_.StaticParentStationExists -ne $true -or
            $_.StaticLocationTypeValid -ne $true -or
            $_.StaticCoordinatesAvailable -ne $true -or
            $_.StaticNameMatches -ne $true
        } | Sort-Object Rank
    )
    $lines.Add("") | Out-Null
    $lines.Add("## Static database cross-check") | Out-Null
    $lines.Add("") | Out-Null
    if ([string]::IsNullOrWhiteSpace($DatabaseError)) {
        $lines.Add('The cross-check queried `dw.DimStop` read-only using each approved `ParentStationId` as `StopId`.') | Out-Null
    }
    else {
        $lines.Add("The read-only `dw.DimStop` cross-check was unavailable: $(ConvertTo-MarkdownCell $DatabaseError)") | Out-Null
    }
    if ($staticFailures.Count -gt 0) {
        $lines.Add("") | Out-Null
        $lines.Add("| ParentStationId | Parent row | LocationTypeCode = 1 | Coordinates | Name matches | Actual StopName | Diagnostic |") | Out-Null
        $lines.Add("| --- | --- | --- | --- | --- | --- | --- |") | Out-Null
        foreach ($result in $staticFailures) {
            $lines.Add(
                "| $(ConvertTo-MarkdownCell $result.ParentStationId) | $(Format-ReportBoolean $result.StaticParentStationExists) | $(Format-ReportBoolean $result.StaticLocationTypeValid) | $(Format-ReportBoolean $result.StaticCoordinatesAvailable) | $(Format-ReportBoolean $result.StaticNameMatches) | $(ConvertTo-MarkdownCell $result.StaticStopName) | $(ConvertTo-MarkdownCell $result.StaticValidationMessage) |"
            ) | Out-Null
        }
    }
    else {
        $lines.Add("All approved stations passed the static parent-station, location-type, name, and coordinate checks.") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Database read-only safety validation") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Sampling configuration unchanged: $(Format-ReportBoolean $DatabaseSafety.SamplingConfigurationUnchanged)") | Out-Null
    $lines.Add("Enabled-target count unchanged: $(Format-ReportBoolean $DatabaseSafety.EnabledTargetCountUnchanged)") | Out-Null
    $lines.Add("Realtime persistence tables unchanged: $(Format-ReportBoolean $DatabaseSafety.PersistenceTablesUnchanged)") | Out-Null
    $lines.Add("Collector-run audit rows unchanged: $(Format-ReportBoolean $DatabaseSafety.CollectorAuditRowsUnchanged)") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($DatabaseSafetyError)) {
        $lines.Add("Database safety count validation was unavailable: $(ConvertTo-MarkdownCell $DatabaseSafetyError)") | Out-Null
    }
    if ($null -ne $DatabaseBefore -and $null -ne $DatabaseAfter) {
        $lines.Add("") | Out-Null
        $lines.Add("| Read-only count | Before | After |") | Out-Null
        $lines.Add("| --- | ---: | ---: |") | Out-Null
        foreach ($propertyName in @(
            "SamplingTargetCount",
            "SamplingSlotCount",
            "EnabledSamplingTargetCount",
            "StopObservationCount",
            "SituationObservationCount",
            "StopSituationLinkCount",
            "CollectorRunCount"
        )) {
            $lines.Add(
                "| $propertyName | $($DatabaseBefore.$propertyName) | $($DatabaseAfter.$propertyName) |"
            ) | Out-Null
        }
    }

    $lines.Add("") | Out-Null
    $lines.Add('Zero returned stop events were classified as `CompatibleNoCurrentEvents` and retained as compatible; they were not treated as invalid StopPointRefs.') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add('This compatibility test used the existing request and parser functions directly and performed no realtime persistence.') | Out-Null

    $parentDirectory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    ($lines -join [Environment]::NewLine) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$runStartedAtUtc = (Get-Date).ToUniversalTime()
$baseline = Read-ApprovedBaseline -Path $BaselinePath -ExpectedSha256 $expectedBaselineSha256
$endpointHostname = Get-EndpointHostname -EndpointValue $Endpoint
$resolvedApiKey = Resolve-MddCompatibilityApiKey -ExplicitApiKey $ApiKey

$modulePath = Join-Path $scriptDirectory "MddRealtimeCollector.psm1"
Import-Module $modulePath -Force

$staticRowsByStopId = @{}
$staticDatabaseError = $null
$databaseBefore = $null
$databaseAfter = $null
$databaseSafety = $null
$databaseSafetyError = $null

try {
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        throw "No SQL connection string was supplied."
    }

    $staticRowsByStopId = Get-StaticParentStationRows `
        -Stations $baseline.Stations `
        -ConnectionStringValue $ConnectionString
}
catch {
    $staticDatabaseError = Get-SafeErrorMessage -Exception $_.Exception -ApiKey $resolvedApiKey -Endpoint $Endpoint
}

$staticValidationByStopId = @{}
foreach ($station in $baseline.Stations) {
    $databaseRow = $null
    if ($staticRowsByStopId.ContainsKey($station.ParentStationId)) {
        $databaseRow = $staticRowsByStopId[$station.ParentStationId]
    }

    $staticValidationByStopId[$station.ParentStationId] = New-StaticValidationInfo `
        -Station $station `
        -DatabaseRow $databaseRow `
        -DatabaseError $staticDatabaseError
}

try {
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        throw "No SQL connection string was supplied."
    }

    $databaseBefore = Get-DatabaseSnapshot -ConnectionStringValue $ConnectionString
}
catch {
    $databaseSafetyError = Get-SafeErrorMessage -Exception $_.Exception -ApiKey $resolvedApiKey -Endpoint $Endpoint
}

$results = [System.Collections.Generic.List[object]]::new()
$globalFailure = $null
$totalHttpAttempts = 0
$testedStationCount = 0
$requestsStarted = 0

try {
    foreach ($station in $baseline.Stations) {
        $staticValidation = $staticValidationByStopId[$station.ParentStationId]
        $result = New-CompatibilityResult -Station $station -StaticValidation $staticValidation

        if ($null -ne $globalFailure) {
            $result.CompatibilityStatus = "NotTestedGlobalFailure"
            $result.FailureCategory = $globalFailure.FailureCategory
            $result.FailureMessage = "Compatibility was not assessed because the run stopped after $($globalFailure.FailureCategory) at another station."
            $results.Add($result) | Out-Null
            continue
        }

        if ($requestsStarted -gt 0 -and $InterRequestDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $InterRequestDelayMilliseconds
        }

        $testedAtUtc = (Get-Date).ToUniversalTime()
        $requestTelemetry = @{
            HttpStatus   = $null
            HttpAttempts = 0
        }
        $requestBody = New-MddTriasStopEventRequest `
            -StopPointRef ([string]$station.ParentStationId) `
            -NumberOfResults $numberOfResults `
            -RequestTimestampUtc $testedAtUtc

        $testedStationCount++
        $requestsStarted++

        try {
            $response = Invoke-MddTriasRequest `
                -Endpoint $Endpoint `
                -Body $requestBody `
                -ApiKey $resolvedApiKey `
                -RequestTimeoutSeconds $RequestTimeoutSeconds `
                -MaxAttempts $maxAttempts `
                -InitialRetryDelaySeconds 0 `
                -MaxRetryDelaySeconds 0 `
                -Telemetry $requestTelemetry

            $result.TestedAtUtc = $testedAtUtc
            $result.HttpReachable = $true
            $result.HttpStatus = $response.StatusCode
            $result.HttpAttempts = [int]$response.Attempts
            $totalHttpAttempts += [int]$response.Attempts

            try {
                $snapshot = ConvertFrom-MddTriasResponse -ResponseContent $response.Content
                $stops = @($snapshot.Stops | Where-Object { $null -ne $_ })
                $result.ParseSucceeded = $true
                $result.ReturnedStopEventCount = $stops.Count
                if ($stops.Count -gt 0) {
                    $result.CompatibilityStatus = "CompatibleWithEvents"
                    $result.FirstReturnedStopPointRef = $stops[0].StopPointRef
                    $result.FirstReturnedStopName = $stops[0].StopName
                }
                else {
                    $result.CompatibilityStatus = "CompatibleNoCurrentEvents"
                }
            }
            catch {
                $serviceClassification = Get-MddServiceRejectionClassification `
                    -ResponseContent $response.Content `
                    -ApiKey $resolvedApiKey `
                    -Endpoint $Endpoint

                $result.ParseSucceeded = $false
                if ($null -ne $serviceClassification) {
                    $result.CompatibilityStatus = $serviceClassification.CompatibilityStatus
                    $result.FailureCategory = $serviceClassification.FailureCategory
                    $result.FailureMessage = $serviceClassification.FailureMessage
                }
                else {
                    $result.CompatibilityStatus = "ParseFailure"
                    $result.FailureCategory = "ParseFailure"
                    $result.FailureMessage = Get-SafeErrorMessage `
                        -Exception $_.Exception `
                        -ApiKey $resolvedApiKey `
                        -Endpoint $Endpoint
                }
            }
        }
        catch {
            $result.TestedAtUtc = $testedAtUtc
            $result.HttpStatus = $requestTelemetry.HttpStatus
            $result.HttpAttempts = [int]$requestTelemetry.HttpAttempts
            $totalHttpAttempts += [int]$requestTelemetry.HttpAttempts

            if ($null -ne $requestTelemetry.HttpStatus) {
                $result.HttpReachable = $true
            }
            else {
                $result.HttpReachable = $false
            }

            $safeMessage = Get-SafeErrorMessage `
                -Exception $_.Exception `
                -ApiKey $resolvedApiKey `
                -Endpoint $Endpoint

            if ($requestTelemetry.HttpStatus -eq 401 -or $requestTelemetry.HttpStatus -eq 403) {
                $result.CompatibilityStatus = "GlobalAuthenticationFailure"
                $result.FailureCategory = "GlobalAuthenticationFailure"
                $result.FailureMessage = $safeMessage
                $globalFailure = [PSCustomObject][ordered]@{
                    FailureCategory = "GlobalAuthenticationFailure"
                    FailureMessage   = $safeMessage
                }
            }
            elseif ($requestTelemetry.HttpStatus -eq 429) {
                $result.CompatibilityStatus = "GlobalRateLimitFailure"
                $result.FailureCategory = "GlobalRateLimitFailure"
                $result.FailureMessage = $safeMessage
                $globalFailure = [PSCustomObject][ordered]@{
                    FailureCategory = "GlobalRateLimitFailure"
                    FailureMessage   = $safeMessage
                }
            }
            elseif ($null -ne $requestTelemetry.HttpStatus) {
                $result.CompatibilityStatus = "HttpFailure"
                $result.FailureCategory = "HttpFailure"
                $result.FailureMessage = $safeMessage
            }
            else {
                $result.CompatibilityStatus = "TransportFailure"
                $result.FailureCategory = "TransportFailure"
                $result.FailureMessage = $safeMessage
            }
        }

        $results.Add($result) | Out-Null
    }
}
catch {
    $safeMessage = Get-SafeErrorMessage `
        -Exception $_.Exception `
        -ApiKey $resolvedApiKey `
        -Endpoint $Endpoint
    throw "MDD/TRIAS compatibility run failed before completion: $safeMessage"
}
finally {
    $resolvedApiKey = $null

    if ($null -ne $databaseBefore) {
        try {
            $databaseAfter = Get-DatabaseSnapshot -ConnectionStringValue $ConnectionString
        }
        catch {
            $databaseAfter = $null
            $databaseSafetyError = Get-SafeErrorMessage -Exception $_.Exception -Endpoint $Endpoint
        }
    }
}

$resultArray = @($results.ToArray())
$compatibleWithEventsCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "CompatibleWithEvents" }).Count
$compatibleNoCurrentEventsCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "CompatibleNoCurrentEvents" }).Count
$compatibleTotalCount = $compatibleWithEventsCount + $compatibleNoCurrentEventsCount
$httpFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "HttpFailure" }).Count
$transportFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "TransportFailure" }).Count
$parseFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "ParseFailure" }).Count
$sourceRejectedCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "SourceRejected" }).Count
$invalidStopPointRefConfirmedCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "InvalidStopPointRefConfirmed" }).Count
$globalAuthenticationFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "GlobalAuthenticationFailure" }).Count
$globalRateLimitFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "GlobalRateLimitFailure" }).Count
$notTestedGlobalFailureCount = @($resultArray | Where-Object { $_.CompatibilityStatus -eq "NotTestedGlobalFailure" }).Count
$staticValidationFailureCount = @(
    $resultArray | Where-Object {
        $_.StaticParentStationExists -ne $true -or
        $_.StaticLocationTypeValid -ne $true -or
        $_.StaticCoordinatesAvailable -ne $true -or
        $_.StaticNameMatches -ne $true
    }
).Count

$compatibilityCoveragePercentage = if ($baseline.StationCount -eq 0) {
    "0.00"
}
else {
    (($compatibleTotalCount / [double]$baseline.StationCount) * 100).ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
}

$databaseSafety = Compare-DatabaseSnapshots -Before $databaseBefore -After $databaseAfter
$summary = [PSCustomObject][ordered]@{
    ApprovedStationCount                 = $baseline.StationCount
    TestedStationCount                   = $testedStationCount
    CompatibleWithEventsCount            = $compatibleWithEventsCount
    CompatibleNoCurrentEventsCount       = $compatibleNoCurrentEventsCount
    CompatibleTotalCount                 = $compatibleTotalCount
    HttpFailureCount                     = $httpFailureCount
    TransportFailureCount                = $transportFailureCount
    ParseFailureCount                    = $parseFailureCount
    SourceRejectedCount                  = $sourceRejectedCount
    InvalidStopPointRefConfirmedCount    = $invalidStopPointRefConfirmedCount
    StaticValidationFailureCount         = $staticValidationFailureCount
    TotalHttpAttempts                    = $totalHttpAttempts
    CompatibilityCoveragePercentage      = $compatibilityCoveragePercentage
    GlobalAuthenticationFailureCount     = $globalAuthenticationFailureCount
    GlobalRateLimitFailureCount          = $globalRateLimitFailureCount
    NotTestedGlobalFailureCount          = $notTestedGlobalFailureCount
}

Write-MddCompatibilityReport `
    -Path $ReportPath `
    -Baseline $baseline `
    -EndpointHostname $endpointHostname `
    -RunStartedAtUtc $runStartedAtUtc `
    -Results $resultArray `
    -Summary $summary `
    -DatabaseBefore $databaseBefore `
    -DatabaseAfter $databaseAfter `
    -DatabaseSafety $databaseSafety `
    -DatabaseError $staticDatabaseError `
    -DatabaseSafetyError $databaseSafetyError

Write-Host "MDD/TRIAS compatibility test completed."
Write-Host "Approved stations loaded: $($summary.ApprovedStationCount)"
Write-Host "Stations tested: $($summary.TestedStationCount)"
Write-Host "Total HTTP attempts: $($summary.TotalHttpAttempts)"
Write-Host "Compatibility coverage: $($summary.CompatibilityCoveragePercentage)%"
Write-Host "Report: $ReportPath"

foreach ($result in $resultArray) {
    Write-Output $result
}
