[CmdletBinding()]
param(
    [string]$Endpoint = "https://mdd.gorheinland.com/delfi",

    [string]$ApiKey,

    [string]$ConnectionString = "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;",

    [ValidateRange(1, 120)]
    [int]$RequestTimeoutSeconds = 30,

    [ValidateRange(1, 3)]
    [int]$MaxAttempts = 3,

    [ValidateRange(0, 300)]
    [int]$InitialRetryDelaySeconds = 2,

    [ValidateRange(0, 300)]
    [int]$MaxRetryDelaySeconds = 30,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $scriptDirectory "MddRealtimeCollector.psm1"
Import-Module $modulePath -Force

function Get-SafeInspectionErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception,

        [string]$ApiKeyValue,

        [string]$EndpointValue
    )

    $message = [string]$Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $Exception.GetType().FullName
    }

    if (-not [string]::IsNullOrEmpty($ApiKeyValue)) {
        $message = $message.Replace($ApiKeyValue, "<redacted>")
    }

    if (-not [string]::IsNullOrEmpty($EndpointValue)) {
        $message = $message.Replace($EndpointValue, "<endpoint>")
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

function Resolve-InspectionApiKey {
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

function Invoke-InspectionReadOnlyQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionStringValue,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionStringValue
    $command = $null
    $reader = $null
    $rows = New-Object 'System.Collections.Generic.List[object]'

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::Text
        $command.CommandTimeout = 60
        $command.CommandText = $Query
        $reader = $command.ExecuteReader()

        while ($reader.Read()) {
            $values = [ordered]@{}
            for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                $value = $reader.GetValue($index)
                if ($value -is [DBNull]) {
                    $value = $null
                }

                $values[$reader.GetName($index)] = $value
            }

            $rows.Add([PSCustomObject]$values) | Out-Null
        }

        return @($rows.ToArray())
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

function Get-EnabledInspectionTargets {
    param([Parameter(Mandatory = $true)][string]$ConnectionStringValue)

    $targets = @(
        Invoke-InspectionReadOnlyQuery `
            -ConnectionStringValue $ConnectionStringValue `
            -Query @"
SELECT
    SamplingTargetId,
    TargetName,
    StopPointRef,
    NumberOfResults
FROM ctl.MddRealtimeSamplingTarget
WHERE IsEnabled = 1
ORDER BY SamplingTargetId;
"@
    )

    if ($targets.Count -ne 7) {
        throw "Safe raw inspection requires exactly seven enabled sampling targets; found $($targets.Count). No MDD/TRIAS request was made."
    }

    if (@($targets | Select-Object -ExpandProperty StopPointRef -Unique).Count -ne 7) {
        throw "Safe raw inspection requires seven distinct enabled StopPointRef values. No MDD/TRIAS request was made."
    }

    foreach ($target in $targets) {
        if ([string]::IsNullOrWhiteSpace([string]$target.StopPointRef)) {
            throw "An enabled sampling target has no StopPointRef. No MDD/TRIAS request was made."
        }

        if ([int]$target.NumberOfResults -lt 1 -or [int]$target.NumberOfResults -gt 100) {
            throw "An enabled sampling target has an invalid NumberOfResults value. No MDD/TRIAS request was made."
        }
    }

    return $targets
}

function Get-InspectionApplicationTableCounts {
    param([Parameter(Mandatory = $true)][string]$ConnectionStringValue)

    return @(
        Invoke-InspectionReadOnlyQuery `
            -ConnectionStringValue $ConnectionStringValue `
            -Query @"
SELECT
    schema_row.name AS SchemaName,
    table_row.name AS TableName,
    CONVERT(BIGINT, COALESCE(SUM(CASE WHEN partition_row.index_id IN (0, 1) THEN partition_row.row_count ELSE 0 END), 0)) AS RowCount
FROM sys.tables AS table_row
JOIN sys.schemas AS schema_row
  ON schema_row.schema_id = table_row.schema_id
LEFT JOIN sys.dm_db_partition_stats AS partition_row
  ON partition_row.object_id = table_row.object_id
WHERE table_row.is_ms_shipped = 0
GROUP BY schema_row.name, table_row.name
ORDER BY schema_row.name, table_row.name;
"@
    )
}

function Get-JsonPropertyState {
    param(
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return [PSCustomObject]@{
            Exists = $false
            Value  = $null
        }
    }

    if ($Object.PSObject.Properties.Name -contains $PropertyName) {
        return [PSCustomObject]@{
            Exists = $true
            Value  = $Object.$PropertyName
        }
    }

    return [PSCustomObject]@{
        Exists = $false
        Value  = $null
    }
}

function Get-JsonValueType {
    param($Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    if ($Value -is [System.Array]) {
        return "Array"
    }

    if ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [hashtable]) {
        return "Object"
    }

    if ($Value -is [bool]) {
        return "Boolean"
    }

    if ($Value -is [string]) {
        return "String"
    }

    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [single] -or
        $Value -is [int] -or $Value -is [long] -or $Value -is [short] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [uint16]) {
        return "Number"
    }

    return $Value.GetType().Name
}

function Test-RelevantJsonPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path -match '(?i)(serviceArrival|serviceDeparture|timetabledTime|estimatedTime|actual|recorded|measured|arrival|departure|delay|cancel|cancelled|cancellation|status|service|callAtStop|bay|platform|situation)'
}

function Get-ParserProjectionForPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = $Path -replace '\[\d+\]', '[*]'

    if ($normalizedPath -match '(?i)serviceDelivery\.responseTimestamp$') {
        return [PSCustomObject]@{ Persists = "YES"; TargetField = "ObservedAtUtc" }
    }

    if ($normalizedPath -match '(?i)serviceArrival\.timetabledTime$') {
        return [PSCustomObject]@{ Persists = "YES"; TargetField = "TimetabledArrivalUtc" }
    }

    if ($normalizedPath -match '(?i)serviceArrival\.estimatedTime$') {
        return [PSCustomObject]@{ Persists = "YES"; TargetField = "EstimatedArrivalUtc" }
    }

    if ($normalizedPath -match '(?i)(plannedBay|estimatedBay)$') {
        $targetField = if ($normalizedPath -match '(?i)plannedBay$') { "PlannedBay" } else { "EstimatedBay" }
        return [PSCustomObject]@{ Persists = "YES"; TargetField = $targetField }
    }

    if ($normalizedPath -match '(?i)(situationFullRef|ptSituation\.(participantRef|situationNumber|summary|description|detail)|validityPeriod\.(startTime|endTime))$') {
        return [PSCustomObject]@{ Persists = "YES"; TargetField = "Situation/link projection" }
    }

    if ($normalizedPath -match '(?i)(resultId|stopPointRef|stopPointName|publishedLineName|lineRef|journeyRef|directionRef|operatorRef|ptMode|railSubmode)$') {
        return [PSCustomObject]@{ Persists = "YES"; TargetField = "Current stop-observation projection" }
    }

    return [PSCustomObject]@{ Persists = "NO"; TargetField = $null }
}

function Get-SanitizedJsonValue {
    param(
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($null -eq $Value) {
        return "<null>"
    }

    if ($Path -match '(?i)(api[-_]?key|authorization|token|password|secret|credential|requestor)') {
        return "<redacted>"
    }

    $type = Get-JsonValueType -Value $Value
    if ($type -eq "Object") {
        return "<object>"
    }

    if ($type -eq "Array") {
        return "<array count=$(@($Value).Count)>"
    }

    $text = [string]$Value
    $text = $text -replace '[\r\n]+', ' '
    if ($text.Length -gt 160) {
        $text = $text.Substring(0, 160) + "..."
    }

    return $text
}

function Add-JsonInventoryObservation {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Inventory,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        $Value
    )

    if (-not $Inventory.ContainsKey($Path)) {
        $projection = Get-ParserProjectionForPath -Path $Path
        $Inventory[$Path] = [ordered]@{
            JsonPath                 = $Path
            EvidenceClass            = Get-FocusEvidenceClass -Path $Path
            ObservedValueType        = @()
            NonNullOccurrenceCount   = 0
            NullOccurrenceCount      = 0
            ExampleSanitizedValue    = $null
            CurrentParserPersists    = $projection.Persists
            ParserTargetField        = $projection.TargetField
        }
    }

    $entry = $Inventory[$Path]
    $valueType = Get-JsonValueType -Value $Value
    if (@($entry.ObservedValueType) -notcontains $valueType) {
        $entry.ObservedValueType = @($entry.ObservedValueType) + $valueType
    }

    if ($null -eq $Value) {
        $entry.NullOccurrenceCount++
        if ($null -eq $entry.ExampleSanitizedValue) {
            $entry.ExampleSanitizedValue = "<null>"
        }
    }
    else {
        $entry.NonNullOccurrenceCount++
        if ($null -eq $entry.ExampleSanitizedValue) {
            $entry.ExampleSanitizedValue = Get-SanitizedJsonValue -Value $Value -Path $Path
        }
    }
}

function Add-JsonRelatedInventory {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Inventory,

        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($null -eq $Value) {
        if (Test-RelevantJsonPath -Path $Path) {
            Add-JsonInventoryObservation -Inventory $Inventory -Path $Path -Value $null
        }
        return
    }

    $valueType = Get-JsonValueType -Value $Value
    if (Test-RelevantJsonPath -Path $Path) {
        Add-JsonInventoryObservation -Inventory $Inventory -Path $Path -Value $Value
    }

    if ($valueType -eq "Array") {
        foreach ($item in @($Value)) {
            Add-JsonRelatedInventory -Inventory $Inventory -Value $item -Path ($Path + "[*]")
        }
        return
    }

    if ($valueType -eq "Object") {
        foreach ($property in $Value.PSObject.Properties) {
            Add-JsonRelatedInventory `
                -Inventory $Inventory `
                -Value $property.Value `
                -Path ($Path + "." + $property.Name)
        }
    }
}

function Get-SourceScalarValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value.PSObject.Properties.Name -contains "value") {
        return $Value.value
    }

    return $Value
}

function Get-FocusEvidenceClass {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -match '(?i)serviceDeparture\.(timetabledTime|estimatedTime)$') {
        return "DepartureTiming"
    }

    if ($Path -match '(?i)(actual|recorded|measured).*(arrival|departure|time|timestamp)|((arrival|departure).*(actual|recorded|measured))') {
        return "ActualOrRecordedTiming"
    }

    # A property name is not sufficient to establish cancellation semantics.
    # Keep service/request status and event-level status/cancellation names
    # neutral until the raw value and structure establish their meaning.
    if ($Path -match '(?i)serviceDelivery\.status$') {
        return "ServiceOrRequestStatusNamedField"
    }

    if ($Path -match '(?i)(cancel|cancelled|cancellation|status)') {
        return "StatusOrCancellationNamedField"
    }

    if ($Path -match '(?i)delay') {
        return "DelayEvidence"
    }

    if ($Path -match '(?i)serviceArrival\.(timetabledTime|estimatedTime)$') {
        return "ArrivalTiming"
    }

    return "OtherRelatedField"
}

function Get-EventRelatedLeafEvidence {
    param(
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $evidence = New-Object 'System.Collections.Generic.List[object]'

    function Add-EventEvidenceRecursive {
        param($CurrentValue, [string]$CurrentPath)

        if ($null -eq $CurrentValue) {
            return
        }

        $currentType = Get-JsonValueType -Value $CurrentValue
        if ($currentType -eq "Array") {
            foreach ($item in @($CurrentValue)) {
                Add-EventEvidenceRecursive -CurrentValue $item -CurrentPath ($CurrentPath + "[*]")
            }
            return
        }

        if ($currentType -eq "Object") {
            foreach ($property in $CurrentValue.PSObject.Properties) {
                Add-EventEvidenceRecursive `
                    -CurrentValue $property.Value `
                    -CurrentPath ($CurrentPath + "." + $property.Name)
            }
            return
        }

        if (Test-RelevantJsonPath -Path $CurrentPath) {
            $projection = Get-ParserProjectionForPath -Path $CurrentPath
            $evidence.Add([PSCustomObject][ordered]@{
                JsonPath              = $CurrentPath
                EvidenceClass         = Get-FocusEvidenceClass -Path $CurrentPath
                ObservedValueType     = $currentType
                ExampleSanitizedValue = Get-SanitizedJsonValue -Value $CurrentValue -Path $CurrentPath
                CurrentParserPersists = $projection.Persists
                ParserTargetField     = $projection.TargetField
            }) | Out-Null
        }
    }

    Add-EventEvidenceRecursive -CurrentValue $Value -CurrentPath $Path
    return @($evidence.ToArray())
}

function Test-ClearAlternativeArrivalTimingEvidence {
    param(
        [Parameter(Mandatory = $true)]
        $Evidence
    )

    if ($Evidence.CurrentParserPersists -ne "NO" -or $Evidence.EvidenceClass -ne "ActualOrRecordedTiming") {
        return $false
    }

    return $Evidence.JsonPath -match '(?i)(actual|recorded|measured).*arrival.*(time|timestamp)|arrival.*(actual|recorded|measured).*(time|timestamp)'
}

function Test-AmbiguousNonPersistedTimingEvidence {
    param(
        [Parameter(Mandatory = $true)]
        $Evidence
    )

    if ($Evidence.CurrentParserPersists -ne "NO" -or
        $Evidence.EvidenceClass -notin @("ActualOrRecordedTiming", "DelayEvidence")) {
        return $false
    }

    if ($Evidence.JsonPath -match '(?i)departure') {
        return $false
    }

    return -not (Test-ClearAlternativeArrivalTimingEvidence -Evidence $Evidence)
}

function Get-MissingArrivalEvents {
    param(
        $RawJson,

        [Parameter(Mandatory = $true)]
        [string]$TargetStopPointRef,

        [Parameter(Mandatory = $true)]
        [int]$TargetNumberOfResults
    )

    $deliveryPayloadState = Get-JsonPropertyState -Object (Get-JsonPropertyState -Object $RawJson -PropertyName "serviceDelivery").Value -PropertyName "deliveryPayload"
    $responseState = Get-JsonPropertyState -Object $deliveryPayloadState.Value -PropertyName "stopEventResponse"
    $resultsState = Get-JsonPropertyState -Object $responseState.Value -PropertyName "stopEventResult"
    $results = if ($resultsState.Exists -and $null -ne $resultsState.Value) { @($resultsState.Value) } else { @() }
    $missing = New-Object 'System.Collections.Generic.List[object]'

    for ($index = 0; $index -lt $results.Count; $index++) {
        $result = $results[$index]
        $eventState = Get-JsonPropertyState -Object $result -PropertyName "stopEvent"
        $event = $eventState.Value
        $thisCallState = Get-JsonPropertyState -Object $event -PropertyName "thisCall"
        $callState = Get-JsonPropertyState -Object $thisCallState.Value -PropertyName "callAtStop"
        $call = $callState.Value
        $arrivalState = Get-JsonPropertyState -Object $call -PropertyName "serviceArrival"
        $arrivalStateValue = $arrivalState.Value
        $estimateState = Get-JsonPropertyState -Object $arrivalStateValue -PropertyName "estimatedTime"
        $isMissing = (-not $estimateState.Exists) -or ($null -eq $estimateState.Value)

        if (-not $isMissing) {
            continue
        }

        $resultIdState = Get-JsonPropertyState -Object $result -PropertyName "resultId"
        $stopPointState = Get-JsonPropertyState -Object $call -PropertyName "stopPointRef"
        $serviceState = Get-JsonPropertyState -Object $event -PropertyName "service"
        $journeyState = Get-JsonPropertyState -Object $serviceState.Value -PropertyName "journeyRef"
        $eventPath = "$.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResult[*].stopEvent"
        $eventEvidence = @(Get-EventRelatedLeafEvidence -Value $event -Path $eventPath)
        $additionalNonPersistedTimingEvidence = @(
            $eventEvidence | Where-Object {
                $_.CurrentParserPersists -eq "NO" -and
                $_.EvidenceClass -in @(
                    "DepartureTiming",
                    "ActualOrRecordedTiming",
                    "DelayEvidence"
                )
            }
        )
        $potentialAlternativeArrivalTimingEvidence = @(
            $eventEvidence | Where-Object {
                Test-ClearAlternativeArrivalTimingEvidence -Evidence $_
            }
        )
        $ambiguousNonPersistedTimingEvidence = @(
            $eventEvidence | Where-Object {
                Test-AmbiguousNonPersistedTimingEvidence -Evidence $_
            }
        )

        $missing.Add([PSCustomObject][ordered]@{
            TargetStopPointRef                         = $TargetStopPointRef
            TargetNumberOfResults                     = $TargetNumberOfResults
            ResultIndex                                = $index
            ResultId                                   = Get-SanitizedJsonValue -Value (Get-SourceScalarValue $resultIdState.Value) -Path "resultId"
            ReturnedStopPointRef                      = Get-SanitizedJsonValue -Value (Get-SourceScalarValue $stopPointState.Value) -Path "stopPointRef"
            JourneyRef                                = Get-SanitizedJsonValue -Value (Get-SourceScalarValue $journeyState.Value) -Path "journeyRef"
            ArrivalEstimatePresence                  = if (-not $estimateState.Exists) { "ABSENT" } else { "NULL" }
            AdditionalNonPersistedTimingEvidenceCount = $additionalNonPersistedTimingEvidence.Count
            DepartureTimingEvidence                  = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "DepartureTiming" })
            ActualOrRecordedTimingEvidence           = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "ActualOrRecordedTiming" })
            StatusOrCancellationNamedFieldEvidence   = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "StatusOrCancellationNamedField" })
            ServiceOrRequestStatusNamedFieldEvidence = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "ServiceOrRequestStatusNamedField" })
            DelayEvidence                            = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "DelayEvidence" })
            PotentialAlternativeArrivalTimingEvidence = @($potentialAlternativeArrivalTimingEvidence)
            AmbiguousNonPersistedTimingEvidenceCount = $ambiguousNonPersistedTimingEvidence.Count
            AmbiguousNonPersistedTimingEvidence       = @($ambiguousNonPersistedTimingEvidence)
            OtherRelatedFieldEvidence                = @($eventEvidence | Where-Object { $_.EvidenceClass -eq "OtherRelatedField" })
            ParserMatched                            = $false
            ParserEstimatedArrivalUtc                = "<not compared>"
            ParserDiscardedRelevantTimingFieldCount  = 0
            ParserDiscardedRelevantTimingFields      = @()
            ScheduledStopPosition                    = "NOT_DETERMINED"
            ScheduledStopPositionEvidence            = "The raw probe does not establish a dated static GTFS trip/stop sequence; no First/Intermediate/Last inference was made."
        }) | Out-Null
    }

    return @($missing.ToArray())
}

function Get-ParserStopForResultId {
    param(
        [object[]]$ParsedStops,
        $ResultId
    )

    $idText = [string](Get-SourceScalarValue -Value $ResultId)
    foreach ($stop in @($ParsedStops)) {
        if ([string]$stop.ResultId -eq $idText) {
            return $stop
        }
    }

    return $null
}

function Compare-InspectionTableCounts {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Before,

        [Parameter(Mandatory = $true)]
        [object[]]$After
    )

    $beforeByKey = @{}
    foreach ($row in @($Before)) {
        $beforeByKey["$($row.SchemaName).$($row.TableName)"] = [long]$row.RowCount
    }

    $afterByKey = @{}
    foreach ($row in @($After)) {
        $afterByKey["$($row.SchemaName).$($row.TableName)"] = [long]$row.RowCount
    }

    $keys = @($beforeByKey.Keys + $afterByKey.Keys | Sort-Object -Unique)
    $deltas = New-Object 'System.Collections.Generic.List[object]'
    $unchanged = $true

    foreach ($key in $keys) {
        $hasBefore = $beforeByKey.ContainsKey($key)
        $hasAfter = $afterByKey.ContainsKey($key)
        $beforeCount = if ($hasBefore) { $beforeByKey[$key] } else { $null }
        $afterCount = if ($hasAfter) { $afterByKey[$key] } else { $null }
        $same = $hasBefore -and $hasAfter -and ($beforeCount -eq $afterCount)
        if (-not $same) {
            $unchanged = $false
        }

        $parts = $key -split '\.', 2
        $deltas.Add([PSCustomObject][ordered]@{
            SchemaName = $parts[0]
            TableName  = $parts[1]
            Before     = $beforeCount
            After      = $afterCount
            Unchanged  = $same
        }) | Out-Null
    }

    return [PSCustomObject][ordered]@{
        ApplicationTablesUnchanged = $unchanged
        TableCount                 = $keys.Count
        ChangedTables              = @($deltas | Where-Object { -not $_.Unchanged })
        CountDeltas                = @($deltas.ToArray())
    }
}

$resolvedApiKey = $null
$runStartedAtUtc = (Get-Date).ToUniversalTime()
$targetRows = @()
$databaseBefore = @()
$databaseAfter = @()
$targetResults = New-Object 'System.Collections.Generic.List[object]'
$rawInventory = @{}
$missingArrivalEvents = New-Object 'System.Collections.Generic.List[object]'
$logicalRequestsStarted = 0
$totalHttpAttempts = 0
$successfulRequestCount = 0
$failedRequestCount = 0
$parserSuccessCount = 0
$parserFailureCount = 0

try {
    $resolvedApiKey = Resolve-InspectionApiKey -ExplicitApiKey $ApiKey

    $targetRows = @(Get-EnabledInspectionTargets -ConnectionStringValue $ConnectionString)
    $databaseBefore = @(Get-InspectionApplicationTableCounts -ConnectionStringValue $ConnectionString)

    foreach ($target in $targetRows) {
        $logicalRequestsStarted++
        $requestTelemetry = @{
            HttpStatus   = $null
            HttpAttempts = 0
        }
        $requestAttemptsRecorded = $false
        $targetResult = [ordered]@{
            SamplingTargetId    = $target.SamplingTargetId
            TargetName          = $target.TargetName
            StopPointRef        = $target.StopPointRef
            NumberOfResults     = $target.NumberOfResults
            LogicalRequestIndex = $logicalRequestsStarted
            Status              = "NOT_STARTED"
            HttpStatus          = $null
            HttpAttempts        = 0
            RawStopEventCount   = 0
            MissingArrivalEventCount = 0
            ParserSucceeded     = $false
            Error               = $null
        }

        try {
            $requestBody = New-MddTriasStopEventRequest `
                -StopPointRef ([string]$target.StopPointRef) `
                -NumberOfResults ([int]$target.NumberOfResults) `
                -RequestTimestampUtc ((Get-Date).ToUniversalTime())

            $response = Invoke-MddTriasRequest `
                -Endpoint $Endpoint `
                -Body $requestBody `
                -ApiKey $resolvedApiKey `
                -RequestTimeoutSeconds $RequestTimeoutSeconds `
                -MaxAttempts $MaxAttempts `
                -InitialRetryDelaySeconds $InitialRetryDelaySeconds `
                -MaxRetryDelaySeconds $MaxRetryDelaySeconds `
                -Telemetry $requestTelemetry

            $targetResult.HttpStatus = $response.StatusCode
            $targetResult.HttpAttempts = [int]$response.Attempts
            $totalHttpAttempts += [int]$response.Attempts
            $requestAttemptsRecorded = $true
            $successfulRequestCount++

            # Raw JSON is inspected before ConvertFrom-MddTriasResponse and is
            # never written to disk or sent to a persistence function.
            $rawJson = $response.Content | ConvertFrom-Json
            Add-JsonRelatedInventory `
                -Inventory $rawInventory `
                -Value $rawJson `
                -Path "`$"

            $rawMissingEvents = @(Get-MissingArrivalEvents `
                -RawJson $rawJson `
                -TargetStopPointRef ([string]$target.StopPointRef) `
                -TargetNumberOfResults ([int]$target.NumberOfResults))
            foreach ($finding in $rawMissingEvents) {
                $missingArrivalEvents.Add($finding) | Out-Null
            }

            $rawResultsState = Get-JsonPropertyState `
                -Object (Get-JsonPropertyState `
                    -Object (Get-JsonPropertyState -Object $rawJson -PropertyName "serviceDelivery").Value `
                    -PropertyName "deliveryPayload").Value `
                -PropertyName "stopEventResponse"
            $rawResultsState = Get-JsonPropertyState `
                -Object $rawResultsState.Value `
                -PropertyName "stopEventResult"
            $rawResults = if ($rawResultsState.Exists -and $null -ne $rawResultsState.Value) { @($rawResultsState.Value) } else { @() }
            $targetResult.RawStopEventCount = $rawResults.Count
            $targetResult.MissingArrivalEventCount = $rawMissingEvents.Count

            try {
                $parsed = ConvertFrom-MddTriasResponse -ResponseContent $response.Content
                $parsedStops = @($parsed.Stops | Where-Object { $null -ne $_ })
                $parserSuccessCount++
                $targetResult.ParserSucceeded = $true

                for ($resultIndex = 0; $resultIndex -lt $rawResults.Count; $resultIndex++) {
                    $rawResult = $rawResults[$resultIndex]
                    $rawResultId = (Get-JsonPropertyState -Object $rawResult -PropertyName "resultId").Value
                    $parserStop = Get-ParserStopForResultId -ParsedStops $parsedStops -ResultId $rawResultId
                    if ($null -eq $parserStop) {
                        continue
                    }

                    $rawEvent = (Get-JsonPropertyState -Object $rawResult -PropertyName "stopEvent").Value
                    $rawEvidence = @(Get-EventRelatedLeafEvidence `
                        -Value $rawEvent `
                        -Path "$.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResult[*].stopEvent")
                    $eventCall = (Get-JsonPropertyState `
                        -Object (Get-JsonPropertyState -Object $rawEvent -PropertyName "thisCall").Value `
                        -PropertyName "callAtStop").Value
                    $eventArrival = (Get-JsonPropertyState -Object $eventCall -PropertyName "serviceArrival").Value
                    $rawEstimateState = Get-JsonPropertyState -Object $eventArrival -PropertyName "estimatedTime"
                    if ((-not $rawEstimateState.Exists) -or ($null -eq $rawEstimateState.Value)) {
                        $discarded = @($rawEvidence | Where-Object {
                            Test-ClearAlternativeArrivalTimingEvidence -Evidence $_
                        })

                        foreach ($finding in @($missingArrivalEvents | Where-Object { $_.ResultIndex -eq $resultIndex -and $_.TargetStopPointRef -eq $target.StopPointRef })) {
                            $finding.ParserMatched = $true
                            $finding.ParserEstimatedArrivalUtc = Get-SanitizedJsonValue -Value $parserStop.EstimatedArrivalUtc -Path "EstimatedArrivalUtc"
                            $finding.ParserDiscardedRelevantTimingFieldCount = $discarded.Count
                            $finding.ParserDiscardedRelevantTimingFields = @($discarded)
                        }
                    }
                }
            }
            catch {
                $parserFailureCount++
                $targetResult.Error = "Parser comparison failed: " + (Get-SafeInspectionErrorMessage -Exception $_.Exception -ApiKeyValue $resolvedApiKey -EndpointValue $Endpoint)
            }

            $targetResult.Status = "SUCCEEDED"
        }
        catch {
            $failedRequestCount++
            $targetResult.Status = "FAILED"
            $targetResult.HttpStatus = $requestTelemetry.HttpStatus
            $targetResult.HttpAttempts = [int]$requestTelemetry.HttpAttempts
            if (-not $requestAttemptsRecorded) {
                $totalHttpAttempts += [int]$requestTelemetry.HttpAttempts
            }
            $targetResult.Error = Get-SafeInspectionErrorMessage `
                -Exception $_.Exception `
                -ApiKeyValue $resolvedApiKey `
                -EndpointValue $Endpoint
        }
        finally {
            $targetResults.Add([PSCustomObject]$targetResult) | Out-Null
        }
    }

    $databaseAfter = @(Get-InspectionApplicationTableCounts -ConnectionStringValue $ConnectionString)
}
catch {
    $safeError = Get-SafeInspectionErrorMessage `
        -Exception $_.Exception `
        -ApiKeyValue $resolvedApiKey `
        -EndpointValue $Endpoint
    throw $safeError
}
finally {
    $resolvedApiKey = $null
}

$tableComparison = Compare-InspectionTableCounts -Before $databaseBefore -After $databaseAfter
$missingEventCount = $missingArrivalEvents.Count
$missingEventWithDiscardedEvidenceCount = @(
    $missingArrivalEvents | Where-Object {
        $_.ParserDiscardedRelevantTimingFieldCount -gt 0
    }
).Count
$missingEventWithAmbiguousEvidenceCount = @(
    $missingArrivalEvents | Where-Object {
        $_.AmbiguousNonPersistedTimingEvidenceCount -gt 0
    }
).Count
$missingEventWithUnmatchedAlternativeEvidenceCount = @(
    $missingArrivalEvents | Where-Object {
        $_.PotentialAlternativeArrivalTimingEvidence.Count -gt 0 -and -not $_.ParserMatched
    }
).Count

$parserDiscardsConclusion = if ($missingEventCount -eq 0) {
    "INCONCLUSIVE"
}
elseif ($parserFailureCount -gt 0 -or $missingEventWithUnmatchedAlternativeEvidenceCount -gt 0) {
    "INCONCLUSIVE"
}
elseif ($missingEventWithDiscardedEvidenceCount -eq 0 -and $missingEventWithAmbiguousEvidenceCount -gt 0) {
    "INCONCLUSIVE"
}
elseif ($missingEventWithDiscardedEvidenceCount -eq 0) {
    "NO"
}
elseif ($missingEventWithDiscardedEvidenceCount -eq $missingEventCount -and $parserFailureCount -eq 0) {
    "YES"
}
else {
    "PARTIALLY"
}

$report = [ordered]@{
    RawTriasTimingInspection                    = if ($failedRequestCount -eq 0) { "EXECUTED" } else { "EXECUTED_PARTIALLY" }
    InspectionStartedAtUtc                     = $runStartedAtUtc.ToString("o")
    InspectionCompletedAtUtc                   = (Get-Date).ToUniversalTime().ToString("o")
    EndpointHost                               = ([System.Uri]$Endpoint).Host
    EnabledTargetCount                         = $targetRows.Count
    LogicalRequestCount                        = $logicalRequestsStarted
    MaximumLogicalRequestCount                 = 7
    SuccessfulRequestCount                     = $successfulRequestCount
    FailedRequestCount                         = $failedRequestCount
    TotalHttpAttemptCount                      = $totalHttpAttempts
    ParserSuccessCount                         = $parserSuccessCount
    ParserFailureCount                         = $parserFailureCount
    ApplicationTablesUnchanged                 = $tableComparison.ApplicationTablesUnchanged
    ApplicationTableCount                      = $tableComparison.TableCount
    ApplicationTableCountDeltas                = @($tableComparison.CountDeltas)
    ChangedApplicationTables                   = @($tableComparison.ChangedTables)
    CollectorParserDiscardsRelevantTiming      = $parserDiscardsConclusion
    EnabledTargets                             = @($targetRows)
    TargetResults                              = @($targetResults.ToArray())
    RawTimingStatusFieldInventory              = @($rawInventory.Values | Sort-Object JsonPath)
    ArrivalEstimateMissingRawEventFindings     = @($missingArrivalEvents.ToArray())
    SafetyNotes                                = @(
        "Raw response content was inspected in memory only; no raw response file was written.",
        "No collector persistence function, collector-run audit insertion, sampling configuration write, or application-table write was called.",
        "StatusOrCancellationNamedField and ServiceOrRequestStatusNamedField labels are property-path inventory labels only; no cancellation semantics are inferred from a field name or generic service/request status.",
        "Status/cancellation-named fields are reported separately and cannot by themselves establish CollectorParserDiscardsRelevantTiming.",
        "Departure timing is reported separately and is not treated as arrival timing.",
        "Only clearly identified non-persisted actual/recorded/measured arrival timing can establish parser-discarded relevant timing; ambiguous non-persisted timing evidence yields INCONCLUSIVE.",
        "Actual/recorded fields, if present, are evidence only and are not integrated into delay semantics."
    )
}

$jsonReport = $report | ConvertTo-Json -Depth 30
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportDirectory = Split-Path -Parent $ReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }

    $jsonReport | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}

Write-Output $jsonReport
