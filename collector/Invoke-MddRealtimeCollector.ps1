param(
    [string]$Endpoint = "https://mdd.gorheinland.com/delfi",
    [string]$StopPointRef = "de:05315:11201",
    [int]$NumberOfResults = 5,
    [string]$ConnectionString = "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SourceValue {
    param($Object)

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [string]) {
        return $Object
    }

    if ($Object.PSObject.Properties.Name -contains "value") {
        return $Object.value
    }

    return $Object
}

function Get-TriasText {
    param($Object)

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [string]) {
        return $Object
    }

    if ($Object.PSObject.Properties.Name -contains "value") {
        return $Object.value
    }

    foreach ($item in @($Object)) {
        if ($null -eq $item) {
            continue
        }

        if ($item.PSObject.Properties.Name -contains "text" -and $null -ne $item.text) {
            return $item.text
        }

        if ($item.PSObject.Properties.Name -contains "value" -and $null -ne $item.value) {
            return $item.value
        }
    }

    return $null
}

function Convert-TriasUtc {
    param($Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return [DBNull]::Value
    }

    $clean = ([string]$Value) -replace '\[GMT\]$', ''
    return [DateTimeOffset]::Parse($clean).UtcDateTime
}

function Get-DbValue {
    param($Value)

    if ($null -eq $Value) {
        return [DBNull]::Value
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return [DBNull]::Value
    }

    return $Value
}

function Add-Parameter {
    param(
        [System.Data.SqlClient.SqlCommand]$Command,
        [string]$Name,
        [System.Data.SqlDbType]$Type,
        $Value,
        [int]$Size = 0
    )

    if ($Size -ne 0) {
        $parameter = $Command.Parameters.Add($Name, $Type, $Size)
    }
    else {
        $parameter = $Command.Parameters.Add($Name, $Type)
    }

    $parameter.Value = Get-DbValue $Value
    return $parameter
}

# Read the API key from the environment when available; otherwise prompt securely.
$apiKeyPlain = [System.Environment]::GetEnvironmentVariable("MDD_API_KEY", "User")

if ([string]::IsNullOrWhiteSpace($apiKeyPlain)) {
    $secureApiKey = Read-Host "Enter MDD API Key" -AsSecureString
    $apiKeyPlain = [System.Net.NetworkCredential]::new("", $secureApiKey).Password
}

if ([string]::IsNullOrWhiteSpace($apiKeyPlain)) {
    throw "MDD API key is required."
}

$requestTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Build one arrival-oriented TRIAS request for the configured stop.
$body = @"
<?xml version="1.0" encoding="UTF-8"?>
<Trias xmlns="http://www.vdv.de/trias"
       xmlns:siri="http://www.siri.org.uk/siri"
       version="1.2">
  <ServiceRequest>
    <siri:RequestTimestamp>$requestTimestamp</siri:RequestTimestamp>
    <siri:RequestorRef>CologneTransitIntelligence</siri:RequestorRef>
    <RequestPayload>
      <StopEventRequest>
        <Location>
          <LocationRef>
            <StopPointRef>$StopPointRef</StopPointRef>
          </LocationRef>
          <DepArrTime>$requestTimestamp</DepArrTime>
        </Location>
        <Params>
          <NumberOfResults>$NumberOfResults</NumberOfResults>
          <StopEventType>arrival</StopEventType>
          <IncludePreviousCalls>true</IncludePreviousCalls>
          <IncludeOnwardCalls>true</IncludeOnwardCalls>
          <IncludeRealtimeData>true</IncludeRealtimeData>
        </Params>
      </StopEventRequest>
    </RequestPayload>
  </ServiceRequest>
</Trias>
"@

$headers = @{
    "x-api-key" = $apiKeyPlain
}

Write-Host "Requesting one TRIAS arrival snapshot..."
$response = Invoke-WebRequest `
    -Uri $Endpoint `
    -Method POST `
    -Headers $headers `
    -ContentType "application/xml; charset=utf-8" `
    -Body $body `
    -UseBasicParsing

if ($response.StatusCode -ne 200) {
    throw "Unexpected HTTP status: $($response.StatusCode)"
}

$json = $response.Content | ConvertFrom-Json

if ($json.serviceDelivery.status -ne $true) {
    throw "TRIAS serviceDelivery.status is not true."
}

$observedAtRaw = $json.serviceDelivery.responseTimestamp -replace '\[GMT\]$', ''
$observedAtUtc = [DateTimeOffset]::Parse($observedAtRaw).UtcDateTime

$results = @(
    $json.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResult
)

# Parse source stop-event observations.
$parsedStops = foreach ($result in $results) {
    $event = $result.stopEvent
    $call = $event.thisCall.callAtStop
    $section = @($event.service.serviceSection)[0]

    $parsed = [PSCustomObject]@{
        ResultId             = Get-SourceValue $result.resultId
        StopPointRef         = Get-SourceValue $call.stopPointRef
        StopName             = Get-TriasText $call.stopPointName
        LineName             = Get-TriasText $section.publishedLineName
        LineRef              = Get-SourceValue $section.lineRef
        JourneyRef           = Get-SourceValue $event.service.journeyRef
        DirectionRef         = Get-SourceValue $section.directionRef
        OperatorRef          = Get-SourceValue $section.operatorRef
        PtMode               = $section.mode.ptMode
        RailSubmode          = $section.mode.railSubmode
        TimetabledArrivalUtc = $call.serviceArrival.timetabledTime
        EstimatedArrivalUtc  = $call.serviceArrival.estimatedTime
        PlannedBay           = Get-TriasText $call.plannedBay
        EstimatedBay         = Get-TriasText $call.estimatedBay
    }

    if ([string]::IsNullOrWhiteSpace($parsed.ResultId) -or
        [string]::IsNullOrWhiteSpace($parsed.StopPointRef) -or
        [string]::IsNullOrWhiteSpace($parsed.JourneyRef)) {
        throw "A required stop-event source identifier is missing."
    }

    $parsed
}

# Parse identifiable context situations.
$context = $json.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResponseContext
$allSituations = @($context.situations.ptSituation)

$parsedSituations = foreach ($situation in $allSituations) {
    $validity = @($situation.validityPeriod)
    $validFrom = $null
    $validTo = $null

    if ($validity.Count -gt 0) {
        $validFrom = $validity[0].startTime
        $validTo = $validity[0].endTime
    }

    [PSCustomObject]@{
        ParticipantRef  = Get-SourceValue $situation.participantRef
        SituationNumber = Get-SourceValue $situation.situationNumber
        Summary         = Get-TriasText $situation.summary
        Description     = Get-TriasText $situation.description
        Detail          = Get-TriasText $situation.detail
        ValidFromUtc    = $validFrom
        ValidToUtc      = $validTo
    }
}

$validSituations = @(
    $parsedSituations | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.ParticipantRef) -and
        -not [string]::IsNullOrWhiteSpace($_.SituationNumber)
    }
)

$unidentifiedSituationCount = @(
    $parsedSituations | Where-Object {
        [string]::IsNullOrWhiteSpace($_.ParticipantRef) -or
        [string]::IsNullOrWhiteSpace($_.SituationNumber)
    }
).Count

# Parse source-observed SERVICE and CALL situation relationships.
$parsedLinks = foreach ($result in $results) {
    $event = $result.stopEvent
    $call = $event.thisCall.callAtStop
    $resultId = Get-SourceValue $result.resultId

    foreach ($ref in @($event.service.situationFullRef)) {
        if ($null -eq $ref) {
            continue
        }

        $participantRef = Get-SourceValue $ref.participantRef
        $situationNumber = Get-SourceValue $ref.situationNumber

        if (-not [string]::IsNullOrWhiteSpace($participantRef) -and
            -not [string]::IsNullOrWhiteSpace($situationNumber)) {
            [PSCustomObject]@{
                ResultId        = $resultId
                ParticipantRef  = $participantRef
                SituationNumber = $situationNumber
                RelationScope   = "SERVICE"
            }
        }
    }

    foreach ($ref in @($call.situationFullRef)) {
        if ($null -eq $ref) {
            continue
        }

        $participantRef = Get-SourceValue $ref.participantRef
        $situationNumber = Get-SourceValue $ref.situationNumber

        if (-not [string]::IsNullOrWhiteSpace($participantRef) -and
            -not [string]::IsNullOrWhiteSpace($situationNumber)) {
            [PSCustomObject]@{
                ResultId        = $resultId
                ParticipantRef  = $participantRef
                SituationNumber = $situationNumber
                RelationScope   = "CALL"
            }
        }
    }
}

$conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
$conn.Open()
$transaction = $conn.BeginTransaction()

$stopKeyByResultId = @{}
$situationKeyByIdentity = @{}

$insertedStops = 0
$existingStops = 0
$insertedSituations = 0
$existingSituations = 0
$insertedLinks = 0
$existingLinks = 0
$skippedLinks = 0

try {
    # Persist stop observations idempotently by snapshot timestamp + ResultId.
    foreach ($row in $parsedStops) {
        $findStop = $conn.CreateCommand()
        $findStop.Transaction = $transaction
        $findStop.CommandText = @"
SELECT ObservationKey
FROM stg.MddRealtimeStopObservation
WHERE ObservedAtUtc = @ObservedAtUtc
  AND ResultId = @ResultId;
"@

        $null = Add-Parameter $findStop "@ObservedAtUtc" ([System.Data.SqlDbType]::DateTime2) $observedAtUtc
        $null = Add-Parameter $findStop "@ResultId" ([System.Data.SqlDbType]::NVarChar) $row.ResultId 100

        $observationKey = $findStop.ExecuteScalar()

        if ($null -eq $observationKey -or $observationKey -is [DBNull]) {
            $insertStop = $conn.CreateCommand()
            $insertStop.Transaction = $transaction
            $insertStop.CommandText = @"
INSERT INTO stg.MddRealtimeStopObservation
(
    ObservedAtUtc,
    ResultId,
    StopPointRef,
    StopName,
    LineName,
    LineRef,
    JourneyRef,
    DirectionRef,
    OperatorRef,
    PtMode,
    RailSubmode,
    TimetabledArrivalUtc,
    EstimatedArrivalUtc,
    PlannedBay,
    EstimatedBay
)
OUTPUT INSERTED.ObservationKey
VALUES
(
    @ObservedAtUtc,
    @ResultId,
    @StopPointRef,
    @StopName,
    @LineName,
    @LineRef,
    @JourneyRef,
    @DirectionRef,
    @OperatorRef,
    @PtMode,
    @RailSubmode,
    @TimetabledArrivalUtc,
    @EstimatedArrivalUtc,
    @PlannedBay,
    @EstimatedBay
);
"@

            $null = Add-Parameter $insertStop "@ObservedAtUtc" ([System.Data.SqlDbType]::DateTime2) $observedAtUtc
            $null = Add-Parameter $insertStop "@ResultId" ([System.Data.SqlDbType]::NVarChar) $row.ResultId 100
            $null = Add-Parameter $insertStop "@StopPointRef" ([System.Data.SqlDbType]::NVarChar) $row.StopPointRef 100
            $null = Add-Parameter $insertStop "@StopName" ([System.Data.SqlDbType]::NVarChar) $row.StopName 200
            $null = Add-Parameter $insertStop "@LineName" ([System.Data.SqlDbType]::NVarChar) $row.LineName 100
            $null = Add-Parameter $insertStop "@LineRef" ([System.Data.SqlDbType]::NVarChar) $row.LineRef 150
            $null = Add-Parameter $insertStop "@JourneyRef" ([System.Data.SqlDbType]::NVarChar) $row.JourneyRef 200
            $null = Add-Parameter $insertStop "@DirectionRef" ([System.Data.SqlDbType]::NVarChar) $row.DirectionRef 50
            $null = Add-Parameter $insertStop "@OperatorRef" ([System.Data.SqlDbType]::NVarChar) $row.OperatorRef 100
            $null = Add-Parameter $insertStop "@PtMode" ([System.Data.SqlDbType]::NVarChar) $row.PtMode 50
            $null = Add-Parameter $insertStop "@RailSubmode" ([System.Data.SqlDbType]::NVarChar) $row.RailSubmode 100
            $null = Add-Parameter $insertStop "@TimetabledArrivalUtc" ([System.Data.SqlDbType]::DateTime2) (Convert-TriasUtc $row.TimetabledArrivalUtc)
            $null = Add-Parameter $insertStop "@EstimatedArrivalUtc" ([System.Data.SqlDbType]::DateTime2) (Convert-TriasUtc $row.EstimatedArrivalUtc)
            $null = Add-Parameter $insertStop "@PlannedBay" ([System.Data.SqlDbType]::NVarChar) $row.PlannedBay 100
            $null = Add-Parameter $insertStop "@EstimatedBay" ([System.Data.SqlDbType]::NVarChar) $row.EstimatedBay 100

            $observationKey = $insertStop.ExecuteScalar()
            $insertedStops++
        }
        else {
            $existingStops++
        }

        $stopKeyByResultId[$row.ResultId] = [int64]$observationKey
    }

    # Persist identifiable situation snapshots idempotently.
    foreach ($row in $validSituations) {
        $identity = "$($row.ParticipantRef)|$($row.SituationNumber)"

        $findSituation = $conn.CreateCommand()
        $findSituation.Transaction = $transaction
        $findSituation.CommandText = @"
SELECT SituationObservationKey
FROM stg.MddRealtimeSituationObservation
WHERE ObservedAtUtc = @ObservedAtUtc
  AND ParticipantRef = @ParticipantRef
  AND SituationNumber = @SituationNumber;
"@

        $null = Add-Parameter $findSituation "@ObservedAtUtc" ([System.Data.SqlDbType]::DateTime2) $observedAtUtc
        $null = Add-Parameter $findSituation "@ParticipantRef" ([System.Data.SqlDbType]::NVarChar) $row.ParticipantRef 100
        $null = Add-Parameter $findSituation "@SituationNumber" ([System.Data.SqlDbType]::NVarChar) $row.SituationNumber 150

        $situationKey = $findSituation.ExecuteScalar()

        if ($null -eq $situationKey -or $situationKey -is [DBNull]) {
            $insertSituation = $conn.CreateCommand()
            $insertSituation.Transaction = $transaction
            $insertSituation.CommandText = @"
INSERT INTO stg.MddRealtimeSituationObservation
(
    ObservedAtUtc,
    ParticipantRef,
    SituationNumber,
    Summary,
    Description,
    Detail,
    ValidFromUtc,
    ValidToUtc
)
OUTPUT INSERTED.SituationObservationKey
VALUES
(
    @ObservedAtUtc,
    @ParticipantRef,
    @SituationNumber,
    @Summary,
    @Description,
    @Detail,
    @ValidFromUtc,
    @ValidToUtc
);
"@

            $null = Add-Parameter $insertSituation "@ObservedAtUtc" ([System.Data.SqlDbType]::DateTime2) $observedAtUtc
            $null = Add-Parameter $insertSituation "@ParticipantRef" ([System.Data.SqlDbType]::NVarChar) $row.ParticipantRef 100
            $null = Add-Parameter $insertSituation "@SituationNumber" ([System.Data.SqlDbType]::NVarChar) $row.SituationNumber 150
            $null = Add-Parameter $insertSituation "@Summary" ([System.Data.SqlDbType]::NVarChar) $row.Summary 1000
            $null = Add-Parameter $insertSituation "@Description" ([System.Data.SqlDbType]::NVarChar) $row.Description 2000
            $null = Add-Parameter $insertSituation "@Detail" ([System.Data.SqlDbType]::NVarChar) $row.Detail -1
            $null = Add-Parameter $insertSituation "@ValidFromUtc" ([System.Data.SqlDbType]::DateTime2) (Convert-TriasUtc $row.ValidFromUtc)
            $null = Add-Parameter $insertSituation "@ValidToUtc" ([System.Data.SqlDbType]::DateTime2) (Convert-TriasUtc $row.ValidToUtc)

            $situationKey = $insertSituation.ExecuteScalar()
            $insertedSituations++
        }
        else {
            $existingSituations++
        }

        $situationKeyByIdentity[$identity] = [int64]$situationKey
    }

    # Persist only links that can be resolved to source-identifiable situations in this snapshot.
    foreach ($link in $parsedLinks) {
        $identity = "$($link.ParticipantRef)|$($link.SituationNumber)"

        if (-not $stopKeyByResultId.ContainsKey($link.ResultId) -or
            -not $situationKeyByIdentity.ContainsKey($identity)) {
            $skippedLinks++
            continue
        }

        $observationKey = $stopKeyByResultId[$link.ResultId]
        $situationObservationKey = $situationKeyByIdentity[$identity]

        $findLink = $conn.CreateCommand()
        $findLink.Transaction = $transaction
        $findLink.CommandText = @"
SELECT COUNT_BIG(*)
FROM stg.MddRealtimeStopSituationLink
WHERE ObservationKey = @ObservationKey
  AND SituationObservationKey = @SituationObservationKey
  AND RelationScope = @RelationScope;
"@

        $null = Add-Parameter $findLink "@ObservationKey" ([System.Data.SqlDbType]::BigInt) $observationKey
        $null = Add-Parameter $findLink "@SituationObservationKey" ([System.Data.SqlDbType]::BigInt) $situationObservationKey
        $null = Add-Parameter $findLink "@RelationScope" ([System.Data.SqlDbType]::NVarChar) $link.RelationScope 20

        $linkCount = [int64]$findLink.ExecuteScalar()

        if ($linkCount -eq 0) {
            $insertLink = $conn.CreateCommand()
            $insertLink.Transaction = $transaction
            $insertLink.CommandText = @"
INSERT INTO stg.MddRealtimeStopSituationLink
(
    ObservationKey,
    SituationObservationKey,
    RelationScope
)
VALUES
(
    @ObservationKey,
    @SituationObservationKey,
    @RelationScope
);
"@

            $null = Add-Parameter $insertLink "@ObservationKey" ([System.Data.SqlDbType]::BigInt) $observationKey
            $null = Add-Parameter $insertLink "@SituationObservationKey" ([System.Data.SqlDbType]::BigInt) $situationObservationKey
            $null = Add-Parameter $insertLink "@RelationScope" ([System.Data.SqlDbType]::NVarChar) $link.RelationScope 20
            $null = $insertLink.ExecuteNonQuery()
            $insertedLinks++
        }
        else {
            $existingLinks++
        }
    }

    $transaction.Commit()
}
catch {
    try {
        $transaction.Rollback()
    }
    catch {
        # Ignore rollback errors and preserve the original exception.
    }

    throw
}
finally {
    $conn.Close()
    $apiKeyPlain = $null
}

Write-Host ""
Write-Host "Snapshot persisted successfully."
Write-Host "ObservedAtUtc:               $observedAtUtc"
Write-Host "HTTP status:                 $($response.StatusCode)"
Write-Host "Stop events returned:        $(@($parsedStops).Count)"
Write-Host "Stops inserted:              $insertedStops"
Write-Host "Stops already present:       $existingStops"
Write-Host "Situations in context:       $(@($parsedSituations).Count)"
Write-Host "Situations inserted:         $insertedSituations"
Write-Host "Situations already present:  $existingSituations"
Write-Host "Unidentified situations:     $unidentifiedSituationCount"
Write-Host "Links observed:              $(@($parsedLinks).Count)"
Write-Host "Links inserted:              $insertedLinks"
Write-Host "Links already present:       $existingLinks"
Write-Host "Links skipped unresolved:    $skippedLinks"
Write-Host "API requests used:           1"


