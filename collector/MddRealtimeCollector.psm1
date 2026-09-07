Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:MddCollectorExecutionBudgetSeconds = 240

function Assert-MddRetryConfiguration {
    param(
        [int]$RequestTimeoutSeconds,
        [int]$MaxAttempts,
        [int]$MaxRetryDelaySeconds
    )

    $worstCaseDurationSeconds = ([long]$MaxAttempts * [long]$RequestTimeoutSeconds) + (([long]$MaxAttempts - 1) * [long]$MaxRetryDelaySeconds)

    if ($worstCaseDurationSeconds -gt $script:MddCollectorExecutionBudgetSeconds) {
        throw "Invalid Collector timeout/retry configuration: the worst-case HTTP/retry duration is $worstCaseDurationSeconds seconds, exceeding the Collector execution budget of $script:MddCollectorExecutionBudgetSeconds seconds. Reduce RequestTimeoutSeconds, MaxAttempts, or MaxRetryDelaySeconds."
    }
}

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

function Write-MddCollectorMessage {
    param(
        [string]$Message,
        [scriptblock]$Logger
    )

    if ($null -eq $Logger) {
        Write-Host $Message
    }
    else {
        $null = & $Logger $Message
    }
}

function New-MddTriasStopEventRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StopPointRef,

        [ValidateRange(1, 100)]
        [int]$NumberOfResults = 5,

        [datetime]$RequestTimestampUtc = [datetime]::MinValue
    )

    if ($RequestTimestampUtc -eq [datetime]::MinValue) {
        $RequestTimestampUtc = (Get-Date).ToUniversalTime()
    }
    else {
        $RequestTimestampUtc = $RequestTimestampUtc.ToUniversalTime()
    }

    $requestTimestamp = $RequestTimestampUtc.ToString(
        "yyyy-MM-ddTHH:mm:ssZ",
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    @"
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
}

function Get-MddResponseStatusCode {
    param($Response)

    if ($null -eq $Response) {
        return $null
    }

    if ($Response.PSObject.Properties.Name -contains "StatusCode") {
        try {
            return [int]$Response.StatusCode
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-MddResponseHeader {
    param(
        $Response,
        [string]$Name
    )

    if ($null -eq $Response -or $Response.PSObject.Properties.Name -notcontains "Headers") {
        return $null
    }

    $headers = $Response.Headers
    if ($null -eq $headers) {
        return $null
    }

    try {
        $value = $headers[$Name]
        if ($null -ne $value) {
            return [string]$value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Test-MddTransientHttpStatus {
    param($StatusCode)

    if ($null -eq $StatusCode) {
        return $false
    }

    return @(
        408,
        429,
        500,
        502,
        503,
        504
    ) -contains ([int]$StatusCode)
}

function Test-MddTransientTransportException {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.Net.Sockets.SocketException]) {
            return $true
        }

        if ($current -is [System.Net.WebException]) {
            $transientStatuses = @(
                [System.Net.WebExceptionStatus]::Timeout,
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::SendFailure,
                [System.Net.WebExceptionStatus]::PipelineFailure,
                [System.Net.WebExceptionStatus]::KeepAliveFailure,
                [System.Net.WebExceptionStatus]::RequestCanceled,
                [System.Net.WebExceptionStatus]::NameResolutionFailure
            )

            if ($transientStatuses -contains $current.Status) {
                return $true
            }
        }

        if ($current.Message -match '(?i)timed?\s*out|timeout|connection\s+(was\s+)?(reset|closed|refused)|actively\s+refused|temporarily\s+unavailable|could\s+not\s+be\s+resolved|name\s+or\s+service\s+not\s+known|no\s+such\s+host|network\s+is\s+unreachable') {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Get-MddRetryAfterSeconds {
    param(
        $Response,

        [ValidateRange(0, 300)]
        [int]$MaxRetryDelaySeconds = 30
    )

    $rawValue = Get-MddResponseHeader -Response $Response -Name "Retry-After"
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $null
    }

    $seconds = 0
    $parsedSeconds = [int]::TryParse(
        $rawValue.Trim(),
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$seconds
    )

    if ($parsedSeconds) {
        if ($seconds -lt 0) {
            return 0
        }

        return [math]::Min($seconds, $MaxRetryDelaySeconds)
    }

    $retryAt = [DateTimeOffset]::MinValue
    $parsedDate = [DateTimeOffset]::TryParse(
        $rawValue.Trim(),
        [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref]$retryAt
    )

    if (-not $parsedDate) {
        return $null
    }

    $delay = [math]::Ceiling(($retryAt - [DateTimeOffset]::UtcNow).TotalSeconds)
    if ($delay -lt 0) {
        $delay = 0
    }

    return [math]::Min([int]$delay, $MaxRetryDelaySeconds)
}

function Get-MddRetryDelaySeconds {
    param(
        $Response,

        [Parameter(Mandatory = $true)]
        [int]$Attempt,

        [ValidateRange(0, 300)]
        [int]$InitialRetryDelaySeconds = 2,

        [ValidateRange(0, 300)]
        [int]$MaxRetryDelaySeconds = 30
    )

    $retryAfterSeconds = Get-MddRetryAfterSeconds -Response $Response -MaxRetryDelaySeconds $MaxRetryDelaySeconds
    if ($null -ne $retryAfterSeconds) {
        return [int]$retryAfterSeconds
    }

    $backoff = [math]::Ceiling($InitialRetryDelaySeconds * [math]::Pow(2, ($Attempt - 1)))
    return [int][math]::Min($backoff, $MaxRetryDelaySeconds)
}

function Invoke-MddTriasRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApiKey,

        [ValidateRange(1, 120)]
        [int]$RequestTimeoutSeconds = 30,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 3,

        [ValidateRange(0, 300)]
        [int]$InitialRetryDelaySeconds = 2,

        [ValidateRange(0, 300)]
        [int]$MaxRetryDelaySeconds = 30,

        [scriptblock]$Logger,

        [scriptblock]$SleepAction
    )

    Assert-MddRetryConfiguration `
        -RequestTimeoutSeconds $RequestTimeoutSeconds `
        -MaxAttempts $MaxAttempts `
        -MaxRetryDelaySeconds $MaxRetryDelaySeconds

    if ($null -eq $SleepAction) {
        $SleepAction = {
            param($Seconds)
            Start-Sleep -Seconds $Seconds
        }
    }

    $headers = @{
        "x-api-key" = $ApiKey
    }

    $lastStatusCode = $null
    $lastFailureCategory = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = $null
        $exception = $null
        $statusCode = $null
        $retryable = $false
        $failureCategory = $null

        try {
            $response = Invoke-WebRequest `
                -Uri $Endpoint `
                -Method POST `
                -Headers $headers `
                -ContentType "application/xml; charset=utf-8" `
                -Body $Body `
                -UseBasicParsing `
                -TimeoutSec $RequestTimeoutSeconds `
                -ErrorAction Stop

            $statusCode = Get-MddResponseStatusCode $response
            if ($statusCode -eq 200) {
                return [PSCustomObject]@{
                    Content    = $response.Content
                    StatusCode = $statusCode
                    Attempts   = $attempt
                }
            }

            if ($null -ne $statusCode) {
                $failureCategory = "HTTP $statusCode"
                $retryable = Test-MddTransientHttpStatus $statusCode
            }
            else {
                $failureCategory = "unexpected HTTP response"
            }
        }
        catch {
            $exception = $_.Exception
            if ($exception.PSObject.Properties.Name -contains "Response") {
                $response = $exception.Response
            }
            $statusCode = Get-MddResponseStatusCode $response

            if ($null -ne $statusCode) {
                $failureCategory = "HTTP $statusCode"
                $retryable = Test-MddTransientHttpStatus $statusCode
            }
            else {
                $failureCategory = "transport error"
                $retryable = Test-MddTransientTransportException $exception
            }
        }

        $lastStatusCode = $statusCode
        $lastFailureCategory = $failureCategory

        if (-not $retryable) {
            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                throw "TRIAS request failed after $attempt HTTP attempt(s) with authentication status HTTP $statusCode; no retry was attempted."
            }

            if ($null -ne $statusCode) {
                throw "TRIAS request failed after $attempt HTTP attempt(s) with HTTP status $statusCode; no retry was attempted."
            }

            throw "TRIAS request failed after $attempt HTTP attempt(s) with a non-transient transport error; no retry was attempted."
        }

        if ($attempt -ge $MaxAttempts) {
            if ($null -ne $statusCode) {
                throw "TRIAS request failed after $attempt HTTP attempts with HTTP status $statusCode."
            }

            throw "TRIAS request failed after $attempt HTTP attempts because of a transient transport error."
        }

        $retryDelaySeconds = Get-MddRetryDelaySeconds `
            -Response $response `
            -Attempt $attempt `
            -InitialRetryDelaySeconds $InitialRetryDelaySeconds `
            -MaxRetryDelaySeconds $MaxRetryDelaySeconds

        Write-MddCollectorMessage `
            -Message "TRIAS request attempt $attempt failed ($failureCategory); retrying in $retryDelaySeconds second(s)." `
            -Logger $Logger

        if ($retryDelaySeconds -gt 0) {
            $null = & $SleepAction $retryDelaySeconds
        }
    }

    if ($null -ne $lastStatusCode) {
        throw "TRIAS request failed after $MaxAttempts HTTP attempts with HTTP status $lastStatusCode."
    }

    throw "TRIAS request failed after $MaxAttempts HTTP attempts ($lastFailureCategory)."
}

function ConvertFrom-MddTriasResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ResponseContent
    )

    if ($ResponseContent.PSObject.Properties.Name -contains "Content" -and
        $ResponseContent.PSObject.Properties.Name -notcontains "serviceDelivery") {
        $ResponseContent = $ResponseContent.Content
    }

    if ($ResponseContent -is [string]) {
        $json = $ResponseContent | ConvertFrom-Json
    }
    else {
        $json = $ResponseContent
    }

    if ($json.serviceDelivery.status -ne $true) {
        throw "TRIAS serviceDelivery.status is not true."
    }

    $observedAtRaw = $json.serviceDelivery.responseTimestamp -replace '\[GMT\]$', ''
    $observedAtUtc = [DateTimeOffset]::Parse($observedAtRaw).UtcDateTime

    $results = @(
        $json.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResult
    )

    # Parse source stop-event observations.
    $parsedStops = @(
        foreach ($result in $results) {
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
    )

    # Parse identifiable context situations.
    $context = $json.serviceDelivery.deliveryPayload.stopEventResponse.stopEventResponseContext
    $allSituations = @($context.situations.ptSituation)

    $parsedSituations = @(
        foreach ($situation in $allSituations) {
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
    )

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
    $parsedLinks = @(
        foreach ($result in $results) {
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
    )

    return [PSCustomObject]@{
        ObservedAtUtc              = $observedAtUtc
        Stops                      = @($parsedStops)
        Situations                 = @($parsedSituations)
        ValidSituations            = @($validSituations)
        Links                      = @($parsedLinks)
        UnidentifiedSituationCount = $unidentifiedSituationCount
    }
}

function New-MddDataTable {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Columns
    )

    $table = New-Object System.Data.DataTable
    foreach ($definition in $Columns) {
        $column = New-Object System.Data.DataColumn
        $column.ColumnName = [string]$definition.Name
        $column.DataType = $definition.DataType

        if ($definition.MaxLength -gt 0 -and $definition.DataType -eq [string]) {
            $column.MaxLength = [int]$definition.MaxLength
        }

        $null = $table.Columns.Add($column)
    }

    return ,$table
}

function Add-MddDataTableRow {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.DataTable]$Table,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $dataRow = $Table.NewRow()
    foreach ($column in $Table.Columns) {
        $value = $Values[$column.ColumnName]
        if ($null -eq $value) {
            $value = [DBNull]::Value
        }

        $dataRow[$column.ColumnName] = $value
    }

    $Table.Rows.Add($dataRow)
}

function New-MddRealtimeSnapshotDataTables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $stopTable = New-MddDataTable -Columns @(
        @{ Name = "ResultId"; DataType = [string]; MaxLength = 100 },
        @{ Name = "StopPointRef"; DataType = [string]; MaxLength = 100 },
        @{ Name = "StopName"; DataType = [string]; MaxLength = 200 },
        @{ Name = "LineName"; DataType = [string]; MaxLength = 100 },
        @{ Name = "LineRef"; DataType = [string]; MaxLength = 150 },
        @{ Name = "JourneyRef"; DataType = [string]; MaxLength = 200 },
        @{ Name = "DirectionRef"; DataType = [string]; MaxLength = 50 },
        @{ Name = "OperatorRef"; DataType = [string]; MaxLength = 100 },
        @{ Name = "PtMode"; DataType = [string]; MaxLength = 50 },
        @{ Name = "RailSubmode"; DataType = [string]; MaxLength = 100 },
        @{ Name = "TimetabledArrivalUtc"; DataType = [datetime]; MaxLength = 0 },
        @{ Name = "EstimatedArrivalUtc"; DataType = [datetime]; MaxLength = 0 },
        @{ Name = "PlannedBay"; DataType = [string]; MaxLength = 100 },
        @{ Name = "EstimatedBay"; DataType = [string]; MaxLength = 100 }
    )

    foreach ($source in @($Snapshot.Stops)) {
        Add-MddDataTableRow -Table $stopTable -Values @{
            ResultId             = Get-DbValue $source.ResultId
            StopPointRef         = Get-DbValue $source.StopPointRef
            StopName             = Get-DbValue $source.StopName
            LineName             = Get-DbValue $source.LineName
            LineRef              = Get-DbValue $source.LineRef
            JourneyRef           = Get-DbValue $source.JourneyRef
            DirectionRef         = Get-DbValue $source.DirectionRef
            OperatorRef          = Get-DbValue $source.OperatorRef
            PtMode               = Get-DbValue $source.PtMode
            RailSubmode          = Get-DbValue $source.RailSubmode
            TimetabledArrivalUtc = Get-DbValue (Convert-TriasUtc $source.TimetabledArrivalUtc)
            EstimatedArrivalUtc  = Get-DbValue (Convert-TriasUtc $source.EstimatedArrivalUtc)
            PlannedBay           = Get-DbValue $source.PlannedBay
            EstimatedBay         = Get-DbValue $source.EstimatedBay
        }
    }

    $situationTable = New-MddDataTable -Columns @(
        @{ Name = "ParticipantRef"; DataType = [string]; MaxLength = 100 },
        @{ Name = "SituationNumber"; DataType = [string]; MaxLength = 150 },
        @{ Name = "Summary"; DataType = [string]; MaxLength = 1000 },
        @{ Name = "Description"; DataType = [string]; MaxLength = 2000 },
        @{ Name = "Detail"; DataType = [string]; MaxLength = -1 },
        @{ Name = "ValidFromUtc"; DataType = [datetime]; MaxLength = 0 },
        @{ Name = "ValidToUtc"; DataType = [datetime]; MaxLength = 0 }
    )

    foreach ($source in @($Snapshot.ValidSituations)) {
        Add-MddDataTableRow -Table $situationTable -Values @{
            ParticipantRef  = Get-DbValue $source.ParticipantRef
            SituationNumber = Get-DbValue $source.SituationNumber
            Summary         = Get-DbValue $source.Summary
            Description     = Get-DbValue $source.Description
            Detail          = Get-DbValue $source.Detail
            ValidFromUtc    = Get-DbValue (Convert-TriasUtc $source.ValidFromUtc)
            ValidToUtc      = Get-DbValue (Convert-TriasUtc $source.ValidToUtc)
        }
    }

    $linkTable = New-MddDataTable -Columns @(
        @{ Name = "ResultId"; DataType = [string]; MaxLength = 100 },
        @{ Name = "ParticipantRef"; DataType = [string]; MaxLength = 100 },
        @{ Name = "SituationNumber"; DataType = [string]; MaxLength = 150 },
        @{ Name = "RelationScope"; DataType = [string]; MaxLength = 20 }
    )

    foreach ($source in @($Snapshot.Links)) {
        Add-MddDataTableRow -Table $linkTable -Values @{
            ResultId        = Get-DbValue $source.ResultId
            ParticipantRef  = Get-DbValue $source.ParticipantRef
            SituationNumber = Get-DbValue $source.SituationNumber
            RelationScope   = Get-DbValue $source.RelationScope
        }
    }

    return [PSCustomObject]@{
        StopObservations      = $stopTable
        SituationObservations = $situationTable
        SituationLinks        = $linkTable
    }
}

function Add-MddStructuredParameter {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlCommand]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$TypeName,

        [Parameter(Mandatory = $true)]
        [System.Data.DataTable]$Value
    )

    $parameter = $Command.Parameters.Add($Name, [System.Data.SqlDbType]::Structured)
    $parameter.TypeName = $TypeName
    $parameter.Value = $Value
    return $parameter
}

function Read-MddPersistenceStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlDataReader]$Reader
    )

    if (-not $Reader.Read()) {
        throw "MDD realtime persistence procedure returned no statistics."
    }

    $values = [ordered]@{}
    for ($index = 0; $index -lt $Reader.FieldCount; $index++) {
        $value = $Reader.GetValue($index)
        if ($value -is [DBNull]) {
            $value = $null
        }

        $values[$Reader.GetName($index)] = $value
    }

    return [PSCustomObject]$values
}

function Write-MddRealtimeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        $Snapshot
    )

    $tables = New-MddRealtimeSnapshotDataTables -Snapshot $Snapshot
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    $command = $null
    $reader = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $command.CommandText = "stg.uspPersistMddRealtimeSnapshot"

        $observedParameter = $command.Parameters.Add(
            "@ObservedAtUtc",
            [System.Data.SqlDbType]::DateTime2
        )
        $observedParameter.Value = $Snapshot.ObservedAtUtc
        $observedParameter.Scale = 0

        $null = Add-MddStructuredParameter `
            -Command $command `
            -Name "@StopObservations" `
            -TypeName "stg.MddRealtimeStopObservationInputType" `
            -Value $tables.StopObservations

        $null = Add-MddStructuredParameter `
            -Command $command `
            -Name "@SituationObservations" `
            -TypeName "stg.MddRealtimeSituationObservationInputType" `
            -Value $tables.SituationObservations

        $null = Add-MddStructuredParameter `
            -Command $command `
            -Name "@SituationLinks" `
            -TypeName "stg.MddRealtimeStopSituationLinkInputType" `
            -Value $tables.SituationLinks

        $reader = $command.ExecuteReader()
        return Read-MddPersistenceStatistics -Reader $reader
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

function Get-MddApiKey {
    param([string]$ApiKey)

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $ApiKey = [System.Environment]::GetEnvironmentVariable("MDD_API_KEY", "User")
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $secureApiKey = Read-Host "Enter MDD API Key" -AsSecureString
        $ApiKey = [System.Net.NetworkCredential]::new("", $secureApiKey).Password
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "MDD API key is required."
    }

    return $ApiKey
}

function Invoke-MddRealtimeCollector {
    [CmdletBinding()]
    param(
        [string]$Endpoint = "https://mdd.gorheinland.com/delfi",

        [string]$StopPointRef = "de:05315:11201",

        [ValidateRange(1, 100)]
        [int]$NumberOfResults = 5,

        [string]$ConnectionString = "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;",

        [ValidateRange(1, 120)]
        [int]$RequestTimeoutSeconds = 30,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 3,

        [ValidateRange(0, 300)]
        [int]$InitialRetryDelaySeconds = 2,

        [ValidateRange(0, 300)]
        [int]$MaxRetryDelaySeconds = 30,

        [string]$ApiKey
    )

    Assert-MddRetryConfiguration `
        -RequestTimeoutSeconds $RequestTimeoutSeconds `
        -MaxAttempts $MaxAttempts `
        -MaxRetryDelaySeconds $MaxRetryDelaySeconds

    $resolvedApiKey = Get-MddApiKey -ApiKey $ApiKey

    try {
        $requestTimestampUtc = (Get-Date).ToUniversalTime()
        $body = New-MddTriasStopEventRequest `
            -StopPointRef $StopPointRef `
            -NumberOfResults $NumberOfResults `
            -RequestTimestampUtc $requestTimestampUtc

        Write-Host "Requesting one TRIAS arrival snapshot..."
        $response = Invoke-MddTriasRequest `
            -Endpoint $Endpoint `
            -Body $body `
            -ApiKey $resolvedApiKey `
            -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -MaxAttempts $MaxAttempts `
            -InitialRetryDelaySeconds $InitialRetryDelaySeconds `
            -MaxRetryDelaySeconds $MaxRetryDelaySeconds

        $snapshot = ConvertFrom-MddTriasResponse -ResponseContent $response.Content
        $persistence = Write-MddRealtimeSnapshot `
            -ConnectionString $ConnectionString `
            -Snapshot $snapshot

        Write-Host ""
        Write-Host "Snapshot persisted successfully."
        Write-Host "ObservedAtUtc:               $($snapshot.ObservedAtUtc)"
        Write-Host "HTTP status:                 $($response.StatusCode)"
        Write-Host "HTTP attempts:               $($response.Attempts)"
        Write-Host "Stop events returned:        $(@($snapshot.Stops).Count)"
        Write-Host "Stops inserted:              $($persistence.StopsInserted)"
        Write-Host "Stops already present:       $($persistence.StopsAlreadyPresent)"
        Write-Host "Situations in context:       $(@($snapshot.Situations).Count)"
        Write-Host "Situations inserted:         $($persistence.SituationsInserted)"
        Write-Host "Situations already present:  $($persistence.SituationsAlreadyPresent)"
        Write-Host "Unidentified situations:     $($snapshot.UnidentifiedSituationCount)"
        Write-Host "Links observed:              $(@($snapshot.Links).Count)"
        Write-Host "Links inserted:              $($persistence.LinksInserted)"
        Write-Host "Links already present:       $($persistence.LinksAlreadyPresent)"
        Write-Host "Links skipped unresolved:    $($persistence.LinksSkippedUnresolved)"

        return [PSCustomObject]@{
            ObservedAtUtc              = $snapshot.ObservedAtUtc
            HttpStatus                 = $response.StatusCode
            HttpAttempts               = $response.Attempts
            StopEventsReturned         = @($snapshot.Stops).Count
            SituationsInContext        = @($snapshot.Situations).Count
            UnidentifiedSituations     = $snapshot.UnidentifiedSituationCount
            LinksObserved              = @($snapshot.Links).Count
            StopsInserted              = $persistence.StopsInserted
            StopsAlreadyPresent        = $persistence.StopsAlreadyPresent
            SituationsInserted         = $persistence.SituationsInserted
            SituationsAlreadyPresent   = $persistence.SituationsAlreadyPresent
            LinksInserted              = $persistence.LinksInserted
            LinksAlreadyPresent        = $persistence.LinksAlreadyPresent
            LinksSkippedUnresolved     = $persistence.LinksSkippedUnresolved
        }
    }
    finally {
        $resolvedApiKey = $null
        $ApiKey = $null
    }
}

Export-ModuleMember -Function @(
    "Get-SourceValue",
    "Get-TriasText",
    "Convert-TriasUtc",
    "New-MddTriasStopEventRequest",
    "Invoke-MddTriasRequest",
    "ConvertFrom-MddTriasResponse",
    "New-MddRealtimeSnapshotDataTables",
    "Write-MddRealtimeSnapshot",
    "Invoke-MddRealtimeCollector"
)
