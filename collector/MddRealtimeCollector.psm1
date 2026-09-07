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

function Get-TriasPropertyValue {
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

function Get-MddSafeErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $message = [string]$Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $Exception.GetType().FullName
    }

    # Only exception messages are recorded, and known credential/header forms
    # are redacted before the value can reach SQL or a warning.
    $message = $message -replace '(?i)(x-api-key|authorization|api[\s-]?key)\s*[:=]\s*[^;\r\n]+', '$1=<redacted>'
    $message = $message -replace '(?i)(data source|server|initial catalog|database|user id|uid|password|pwd)\s*=\s*[^;\r\n]+', '$1=<redacted>'

    if ($message.Length -gt 4000) {
        $message = $message.Substring(0, 4000)
    }

    return $message
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

        [scriptblock]$SleepAction,

        [hashtable]$Telemetry
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

    if ($null -ne $Telemetry) {
        $Telemetry.HttpStatus = $null
        $Telemetry.HttpAttempts = 0
    }

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
                if ($null -ne $Telemetry) {
                    $Telemetry.HttpStatus = $statusCode
                    $Telemetry.HttpAttempts = $attempt
                }

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

        if ($null -ne $Telemetry) {
            $Telemetry.HttpStatus = $statusCode
            $Telemetry.HttpAttempts = $attempt
        }

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
            $service = Get-TriasPropertyValue -Object $event -PropertyName "service"
            $thisCall = Get-TriasPropertyValue -Object $event -PropertyName "thisCall"
            $call = Get-TriasPropertyValue -Object $thisCall -PropertyName "callAtStop"
            $section = @(Get-TriasPropertyValue -Object $service -PropertyName "serviceSection")[0]
            $mode = Get-TriasPropertyValue -Object $section -PropertyName "mode"
            $serviceArrival = Get-TriasPropertyValue -Object $call -PropertyName "serviceArrival"

            # These TRIAS fields are optional. Missing estimates, bays, mode
            # details, or line metadata remain NULL instead of aborting the
            # whole source snapshot under StrictMode.
            $parsed = [PSCustomObject]@{
                ResultId             = Get-SourceValue (Get-TriasPropertyValue -Object $result -PropertyName "resultId")
                StopPointRef         = Get-SourceValue (Get-TriasPropertyValue -Object $call -PropertyName "stopPointRef")
                StopName             = Get-TriasText (Get-TriasPropertyValue -Object $call -PropertyName "stopPointName")
                LineName             = Get-TriasText (Get-TriasPropertyValue -Object $section -PropertyName "publishedLineName")
                LineRef              = Get-SourceValue (Get-TriasPropertyValue -Object $section -PropertyName "lineRef")
                JourneyRef           = Get-SourceValue (Get-TriasPropertyValue -Object $service -PropertyName "journeyRef")
                DirectionRef         = Get-SourceValue (Get-TriasPropertyValue -Object $section -PropertyName "directionRef")
                OperatorRef          = Get-SourceValue (Get-TriasPropertyValue -Object $section -PropertyName "operatorRef")
                PtMode               = Get-TriasPropertyValue -Object $mode -PropertyName "ptMode"
                RailSubmode          = Get-TriasPropertyValue -Object $mode -PropertyName "railSubmode"
                TimetabledArrivalUtc = Get-TriasPropertyValue -Object $serviceArrival -PropertyName "timetabledTime"
                EstimatedArrivalUtc  = Get-TriasPropertyValue -Object $serviceArrival -PropertyName "estimatedTime"
                PlannedBay           = Get-TriasText (Get-TriasPropertyValue -Object $call -PropertyName "plannedBay")
                EstimatedBay         = Get-TriasText (Get-TriasPropertyValue -Object $call -PropertyName "estimatedBay")
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
    $deliveryPayload = Get-TriasPropertyValue -Object $json.serviceDelivery -PropertyName "deliveryPayload"
    $stopEventResponse = Get-TriasPropertyValue -Object $deliveryPayload -PropertyName "stopEventResponse"
    $context = Get-TriasPropertyValue -Object $stopEventResponse -PropertyName "stopEventResponseContext"
    $situations = Get-TriasPropertyValue -Object $context -PropertyName "situations"
    $allSituations = @(
        foreach ($situation in @(Get-TriasPropertyValue -Object $situations -PropertyName "ptSituation")) {
            if ($null -ne $situation) {
                $situation
            }
        }
    )

    $parsedSituations = @(
        foreach ($situation in $allSituations) {
            $validityPeriod = Get-TriasPropertyValue -Object $situation -PropertyName "validityPeriod"
            $validity = @(
                foreach ($period in @($validityPeriod)) {
                    if ($null -ne $period) {
                        $period
                    }
                }
            )
            $validFrom = $null
            $validTo = $null

            if ($validity.Count -gt 0) {
                $validFrom = Get-TriasPropertyValue -Object $validity[0] -PropertyName "startTime"
                $validTo = Get-TriasPropertyValue -Object $validity[0] -PropertyName "endTime"
            }

            [PSCustomObject]@{
                ParticipantRef  = Get-SourceValue (Get-TriasPropertyValue -Object $situation -PropertyName "participantRef")
                SituationNumber = Get-SourceValue (Get-TriasPropertyValue -Object $situation -PropertyName "situationNumber")
                Summary         = Get-TriasText (Get-TriasPropertyValue -Object $situation -PropertyName "summary")
                Description     = Get-TriasText (Get-TriasPropertyValue -Object $situation -PropertyName "description")
                Detail          = Get-TriasText (Get-TriasPropertyValue -Object $situation -PropertyName "detail")
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
            $service = Get-TriasPropertyValue -Object $event -PropertyName "service"
            $thisCall = Get-TriasPropertyValue -Object $event -PropertyName "thisCall"
            $call = Get-TriasPropertyValue -Object $thisCall -PropertyName "callAtStop"
            $resultId = Get-SourceValue (Get-TriasPropertyValue -Object $result -PropertyName "resultId")

            foreach ($ref in @(
                Get-TriasPropertyValue -Object $service -PropertyName "situationFullRef"
            )) {
                if ($null -eq $ref) {
                    continue
                }

                $participantRef = Get-SourceValue (Get-TriasPropertyValue -Object $ref -PropertyName "participantRef")
                $situationNumber = Get-SourceValue (Get-TriasPropertyValue -Object $ref -PropertyName "situationNumber")

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

            foreach ($ref in @(
                Get-TriasPropertyValue -Object $call -PropertyName "situationFullRef"
            )) {
                if ($null -eq $ref) {
                    continue
                }

                $participantRef = Get-SourceValue (Get-TriasPropertyValue -Object $ref -PropertyName "participantRef")
                $situationNumber = Get-SourceValue (Get-TriasPropertyValue -Object $ref -PropertyName "situationNumber")

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

function Read-MddSamplingTarget {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlDataReader]$Reader
    )

    if (-not $Reader.Read()) {
        throw "MDD realtime sampling procedure returned no target."
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

function Add-MddCollectorRunParameter {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlCommand]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlDbType]$Type,

        [object]$Value,

        [int]$Size = 0
    )

    $parameter = $Command.Parameters.Add($Name, $Type)
    if ($Size -gt 0) {
        $parameter.Size = $Size
    }

    if ($Type -eq [System.Data.SqlDbType]::DateTime2) {
        $parameter.Scale = 0
    }

    $parameter.Value = Get-DbValue $Value
    return $parameter
}

function Start-MddCollectorRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [datetime]$StartedAtUtc,

        [ValidateSet("Automatic", "Manual")]
        [string]$SamplingMode,

        [string]$StopPointRef,

        [object]$NumberOfResults
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    $command = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $command.CommandText = "ctl.uspStartMddCollectorRun"

        $null = Add-MddCollectorRunParameter `
            -Command $command `
            -Name "@StartedAtUtc" `
            -Type ([System.Data.SqlDbType]::DateTime2) `
            -Value ($StartedAtUtc.ToUniversalTime())

        $null = Add-MddCollectorRunParameter `
            -Command $command `
            -Name "@SamplingMode" `
            -Type ([System.Data.SqlDbType]::VarChar) `
            -Size 20 `
            -Value $SamplingMode

        $null = Add-MddCollectorRunParameter `
            -Command $command `
            -Name "@StopPointRef" `
            -Type ([System.Data.SqlDbType]::NVarChar) `
            -Size 100 `
            -Value $StopPointRef

        $null = Add-MddCollectorRunParameter `
            -Command $command `
            -Name "@NumberOfResults" `
            -Type ([System.Data.SqlDbType]::TinyInt) `
            -Value $NumberOfResults

        $runIdValue = $command.ExecuteScalar()
        if ($null -eq $runIdValue -or $runIdValue -is [DBNull]) {
            throw "MDD Collector run start procedure returned no CollectorRunId."
        }

        return [long]$runIdValue
    }
    finally {
        if ($null -ne $command) {
            $command.Dispose()
        }

        $connection.Close()
        $connection.Dispose()
    }
}

function Complete-MddCollectorRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [long]$CollectorRunId,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Succeeded", "Failed")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [datetime]$CompletedAtUtc,

        [Parameter(Mandatory = $true)]
        [long]$DurationMs,

        [ValidateSet("Automatic", "Manual")]
        [string]$SamplingMode,

        [object]$SamplingBucketUtc,
        [object]$SamplingSlot,
        [object]$SamplingTargetId,
        [string]$SamplingTargetName,
        [string]$StopPointRef,
        [object]$NumberOfResults,
        [object]$ObservedAtUtc,
        [object]$HttpStatus,
        [object]$HttpAttempts,
        [object]$StopEventsReturned,
        [object]$SituationsInContext,
        [object]$UnidentifiedSituations,
        [object]$LinksObserved,
        [object]$StopsInserted,
        [object]$StopsAlreadyPresent,
        [object]$SituationsInserted,
        [object]$SituationsAlreadyPresent,
        [object]$LinksInserted,
        [object]$LinksAlreadyPresent,
        [object]$LinksSkippedUnresolved,
        [string]$ErrorCategory,
        [string]$ErrorMessage
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    $command = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $command.CommandText = "ctl.uspCompleteMddCollectorRun"

        $parameterDefinitions = @(
            @{ Name = "@CollectorRunId"; Type = [System.Data.SqlDbType]::BigInt; Value = $CollectorRunId; Size = 0 },
            @{ Name = "@Status"; Type = [System.Data.SqlDbType]::VarChar; Value = $Status; Size = 20 },
            @{ Name = "@CompletedAtUtc"; Type = [System.Data.SqlDbType]::DateTime2; Value = $CompletedAtUtc.ToUniversalTime(); Size = 0 },
            @{ Name = "@DurationMs"; Type = [System.Data.SqlDbType]::BigInt; Value = $DurationMs; Size = 0 },
            @{ Name = "@SamplingMode"; Type = [System.Data.SqlDbType]::VarChar; Value = $SamplingMode; Size = 20 },
            @{ Name = "@SamplingBucketUtc"; Type = [System.Data.SqlDbType]::DateTime2; Value = $SamplingBucketUtc; Size = 0 },
            @{ Name = "@SamplingSlot"; Type = [System.Data.SqlDbType]::SmallInt; Value = $SamplingSlot; Size = 0 },
            @{ Name = "@SamplingTargetId"; Type = [System.Data.SqlDbType]::Int; Value = $SamplingTargetId; Size = 0 },
            @{ Name = "@SamplingTargetName"; Type = [System.Data.SqlDbType]::NVarChar; Value = $SamplingTargetName; Size = 200 },
            @{ Name = "@StopPointRef"; Type = [System.Data.SqlDbType]::NVarChar; Value = $StopPointRef; Size = 100 },
            @{ Name = "@NumberOfResults"; Type = [System.Data.SqlDbType]::TinyInt; Value = $NumberOfResults; Size = 0 },
            @{ Name = "@ObservedAtUtc"; Type = [System.Data.SqlDbType]::DateTime2; Value = $ObservedAtUtc; Size = 0 },
            @{ Name = "@HttpStatus"; Type = [System.Data.SqlDbType]::Int; Value = $HttpStatus; Size = 0 },
            @{ Name = "@HttpAttempts"; Type = [System.Data.SqlDbType]::Int; Value = $HttpAttempts; Size = 0 },
            @{ Name = "@StopEventsReturned"; Type = [System.Data.SqlDbType]::BigInt; Value = $StopEventsReturned; Size = 0 },
            @{ Name = "@SituationsInContext"; Type = [System.Data.SqlDbType]::BigInt; Value = $SituationsInContext; Size = 0 },
            @{ Name = "@UnidentifiedSituations"; Type = [System.Data.SqlDbType]::BigInt; Value = $UnidentifiedSituations; Size = 0 },
            @{ Name = "@LinksObserved"; Type = [System.Data.SqlDbType]::BigInt; Value = $LinksObserved; Size = 0 },
            @{ Name = "@StopsInserted"; Type = [System.Data.SqlDbType]::BigInt; Value = $StopsInserted; Size = 0 },
            @{ Name = "@StopsAlreadyPresent"; Type = [System.Data.SqlDbType]::BigInt; Value = $StopsAlreadyPresent; Size = 0 },
            @{ Name = "@SituationsInserted"; Type = [System.Data.SqlDbType]::BigInt; Value = $SituationsInserted; Size = 0 },
            @{ Name = "@SituationsAlreadyPresent"; Type = [System.Data.SqlDbType]::BigInt; Value = $SituationsAlreadyPresent; Size = 0 },
            @{ Name = "@LinksInserted"; Type = [System.Data.SqlDbType]::BigInt; Value = $LinksInserted; Size = 0 },
            @{ Name = "@LinksAlreadyPresent"; Type = [System.Data.SqlDbType]::BigInt; Value = $LinksAlreadyPresent; Size = 0 },
            @{ Name = "@LinksSkippedUnresolved"; Type = [System.Data.SqlDbType]::BigInt; Value = $LinksSkippedUnresolved; Size = 0 },
            @{ Name = "@ErrorCategory"; Type = [System.Data.SqlDbType]::VarChar; Value = $ErrorCategory; Size = 50 },
            @{ Name = "@ErrorMessage"; Type = [System.Data.SqlDbType]::NVarChar; Value = $ErrorMessage; Size = 4000 }
        )

        foreach ($definition in $parameterDefinitions) {
            $null = Add-MddCollectorRunParameter `
                -Command $command `
                -Name $definition.Name `
                -Type $definition.Type `
                -Value $definition.Value `
                -Size $definition.Size
        }

        $null = $command.ExecuteNonQuery()
    }
    finally {
        if ($null -ne $command) {
            $command.Dispose()
        }

        $connection.Close()
        $connection.Dispose()
    }
}

function Get-MddRealtimeSamplingTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConnectionString,

        [datetime]$AtUtc = [datetime]::MinValue
    )

    if ($AtUtc -eq [datetime]::MinValue) {
        $AtUtc = (Get-Date).ToUniversalTime()
    }
    else {
        $AtUtc = $AtUtc.ToUniversalTime()
    }

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $ConnectionString
    $command = $null
    $reader = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $command.CommandText = "ctl.uspGetMddRealtimeSamplingTarget"

        $atParameter = $command.Parameters.Add(
            "@AtUtc",
            [System.Data.SqlDbType]::DateTime2
        )
        $atParameter.Value = $AtUtc
        $atParameter.Scale = 0

        $reader = $command.ExecuteReader()
        return Read-MddSamplingTarget -Reader $reader
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

        [string]$StopPointRef,

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

    $collectorStartedAtUtc = (Get-Date).ToUniversalTime()
    $requestTimestampUtc = $collectorStartedAtUtc
    $samplingTarget = $null
    $manualSampling = -not [string]::IsNullOrWhiteSpace($StopPointRef)
    $samplingMode = if ($manualSampling) { "Manual" } else { "Automatic" }
    $numberOfResultsWasSpecified = $PSBoundParameters.ContainsKey("NumberOfResults")
    $effectiveNumberOfResults = if ($manualSampling -or $numberOfResultsWasSpecified) { $NumberOfResults } else { $null }
    $resolvedStopPointRef = if ($manualSampling) { $StopPointRef } else { $null }

    $samplingBucketUtc = $null
    $samplingSlot = $null
    $samplingTargetId = $null
    $samplingTargetName = $null
    $observedAtUtc = $null
    $httpStatus = $null
    $httpAttempts = $null
    $stopEventsReturned = $null
    $situationsInContext = $null
    $unidentifiedSituations = $null
    $linksObserved = $null
    $stopsInserted = $null
    $stopsAlreadyPresent = $null
    $situationsInserted = $null
    $situationsAlreadyPresent = $null
    $linksInserted = $null
    $linksAlreadyPresent = $null
    $linksSkippedUnresolved = $null

    $response = $null
    $snapshot = $null
    $persistence = $null
    $resolvedApiKey = $null
    $requestTelemetry = @{
        HttpStatus   = $null
        HttpAttempts = 0
    }
    $collectorRunId = $null
    $stage = "AuditStart"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Start auditing before sampling, authentication, or any HTTP work.
        $collectorRunId = Start-MddCollectorRun `
            -ConnectionString $ConnectionString `
            -StartedAtUtc $collectorStartedAtUtc `
            -SamplingMode $samplingMode `
            -StopPointRef $resolvedStopPointRef `
            -NumberOfResults $effectiveNumberOfResults

        $stage = "Request"
        Assert-MddRetryConfiguration `
            -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -MaxAttempts $MaxAttempts `
            -MaxRetryDelaySeconds $MaxRetryDelaySeconds

        $stage = "Sampling"
        if (-not $manualSampling) {
            $samplingTarget = Get-MddRealtimeSamplingTarget `
                -ConnectionString $ConnectionString `
                -AtUtc $requestTimestampUtc

            $resolvedStopPointRef = [string]$samplingTarget.StopPointRef
            $samplingBucketUtc = $samplingTarget.SamplingBucketUtc
            $samplingSlot = $samplingTarget.SamplingSlot
            $samplingTargetId = $samplingTarget.SamplingTargetId
            $samplingTargetName = $samplingTarget.TargetName

            if (-not $numberOfResultsWasSpecified) {
                $effectiveNumberOfResults = [int]$samplingTarget.NumberOfResults
            }

            Write-Host "Sampling target: slot=$($samplingTarget.SamplingSlot); targetId=$($samplingTarget.SamplingTargetId); targetName=$($samplingTarget.TargetName); StopPointRef=$resolvedStopPointRef; NumberOfResults=$effectiveNumberOfResults"
        }
        else {
            Write-Host "Sampling target: manual override; StopPointRef=$resolvedStopPointRef; NumberOfResults=$effectiveNumberOfResults"
        }

        $stage = "Authentication"
        $resolvedApiKey = Get-MddApiKey -ApiKey $ApiKey

        $stage = "Request"
        $body = New-MddTriasStopEventRequest `
            -StopPointRef $resolvedStopPointRef `
            -NumberOfResults $effectiveNumberOfResults `
            -RequestTimestampUtc $requestTimestampUtc

        Write-Host "Requesting one TRIAS arrival snapshot..."
        $response = Invoke-MddTriasRequest `
            -Endpoint $Endpoint `
            -Body $body `
            -ApiKey $resolvedApiKey `
            -RequestTimeoutSeconds $RequestTimeoutSeconds `
            -MaxAttempts $MaxAttempts `
            -InitialRetryDelaySeconds $InitialRetryDelaySeconds `
            -MaxRetryDelaySeconds $MaxRetryDelaySeconds `
            -Telemetry $requestTelemetry

        $httpStatus = $response.StatusCode
        $httpAttempts = $response.Attempts

        $stage = "Parse"
        $snapshot = ConvertFrom-MddTriasResponse -ResponseContent $response.Content

        $observedAtUtc = $snapshot.ObservedAtUtc
        $stopEventsReturned = @($snapshot.Stops).Count
        $situationsInContext = @($snapshot.Situations).Count
        $unidentifiedSituations = $snapshot.UnidentifiedSituationCount
        $linksObserved = @($snapshot.Links).Count

        $stage = "Persistence"
        $persistence = Write-MddRealtimeSnapshot `
            -ConnectionString $ConnectionString `
            -Snapshot $snapshot

        $stopsInserted = $persistence.StopsInserted
        $stopsAlreadyPresent = $persistence.StopsAlreadyPresent
        $situationsInserted = $persistence.SituationsInserted
        $situationsAlreadyPresent = $persistence.SituationsAlreadyPresent
        $linksInserted = $persistence.LinksInserted
        $linksAlreadyPresent = $persistence.LinksAlreadyPresent
        $linksSkippedUnresolved = $persistence.LinksSkippedUnresolved

        $stage = "AuditComplete"
        $completedAtUtc = (Get-Date).ToUniversalTime()
        $durationMs = [long]$stopwatch.Elapsed.TotalMilliseconds
        Complete-MddCollectorRun `
            -ConnectionString $ConnectionString `
            -CollectorRunId $collectorRunId `
            -Status "Succeeded" `
            -CompletedAtUtc $completedAtUtc `
            -DurationMs $durationMs `
            -SamplingMode $samplingMode `
            -SamplingBucketUtc $samplingBucketUtc `
            -SamplingSlot $samplingSlot `
            -SamplingTargetId $samplingTargetId `
            -SamplingTargetName $samplingTargetName `
            -StopPointRef $resolvedStopPointRef `
            -NumberOfResults $effectiveNumberOfResults `
            -ObservedAtUtc $observedAtUtc `
            -HttpStatus $httpStatus `
            -HttpAttempts $httpAttempts `
            -StopEventsReturned $stopEventsReturned `
            -SituationsInContext $situationsInContext `
            -UnidentifiedSituations $unidentifiedSituations `
            -LinksObserved $linksObserved `
            -StopsInserted $stopsInserted `
            -StopsAlreadyPresent $stopsAlreadyPresent `
            -SituationsInserted $situationsInserted `
            -SituationsAlreadyPresent $situationsAlreadyPresent `
            -LinksInserted $linksInserted `
            -LinksAlreadyPresent $linksAlreadyPresent `
            -LinksSkippedUnresolved $linksSkippedUnresolved

        Write-Host ""
        Write-Host "Snapshot persisted successfully."
        Write-Host "CollectorRunId:              $collectorRunId"
        Write-Host "ObservedAtUtc:               $observedAtUtc"
        Write-Host "HTTP status:                 $httpStatus"
        Write-Host "HTTP attempts:               $httpAttempts"
        Write-Host "Stop events returned:        $stopEventsReturned"
        Write-Host "Stops inserted:              $stopsInserted"
        Write-Host "Stops already present:       $stopsAlreadyPresent"
        Write-Host "Situations in context:       $situationsInContext"
        Write-Host "Situations inserted:         $situationsInserted"
        Write-Host "Situations already present:  $situationsAlreadyPresent"
        Write-Host "Unidentified situations:     $unidentifiedSituations"
        Write-Host "Links observed:              $linksObserved"
        Write-Host "Links inserted:              $linksInserted"
        Write-Host "Links already present:       $linksAlreadyPresent"
        Write-Host "Links skipped unresolved:    $linksSkippedUnresolved"

        return [PSCustomObject]@{
            CollectorRunId              = $collectorRunId
            SamplingMode               = $samplingMode
            SamplingBucketUtc          = $samplingBucketUtc
            SamplingSlot               = $samplingSlot
            SamplingSlotCount          = if ($null -eq $samplingTarget) { $null } else { $samplingTarget.SamplingSlotCount }
            SamplingTargetId           = $samplingTargetId
            SamplingTargetName         = $samplingTargetName
            StopPointRef               = $resolvedStopPointRef
            NumberOfResults            = $effectiveNumberOfResults
            ObservedAtUtc              = $observedAtUtc
            HttpStatus                 = $httpStatus
            HttpAttempts               = $httpAttempts
            StopEventsReturned         = $stopEventsReturned
            SituationsInContext        = $situationsInContext
            UnidentifiedSituations     = $unidentifiedSituations
            LinksObserved              = $linksObserved
            StopsInserted              = $stopsInserted
            StopsAlreadyPresent        = $stopsAlreadyPresent
            SituationsInserted         = $situationsInserted
            SituationsAlreadyPresent   = $situationsAlreadyPresent
            LinksInserted              = $linksInserted
            LinksAlreadyPresent        = $linksAlreadyPresent
            LinksSkippedUnresolved     = $linksSkippedUnresolved
        }
    }
    catch {
        $originalErrorRecord = $_
        $originalException = $_.Exception

        if ($stage -eq "Request" -and
            ($requestTelemetry.HttpStatus -eq 401 -or $requestTelemetry.HttpStatus -eq 403)) {
            $stage = "Authentication"
        }

        if ($requestTelemetry.HttpAttempts -gt 0) {
            $httpAttempts = $requestTelemetry.HttpAttempts
            $httpStatus = $requestTelemetry.HttpStatus
        }

        if ($null -ne $collectorRunId) {
            try {
                Complete-MddCollectorRun `
                    -ConnectionString $ConnectionString `
                    -CollectorRunId $collectorRunId `
                    -Status "Failed" `
                    -CompletedAtUtc ((Get-Date).ToUniversalTime()) `
                    -DurationMs ([long]$stopwatch.Elapsed.TotalMilliseconds) `
                    -SamplingMode $samplingMode `
                    -SamplingBucketUtc $samplingBucketUtc `
                    -SamplingSlot $samplingSlot `
                    -SamplingTargetId $samplingTargetId `
                    -SamplingTargetName $samplingTargetName `
                    -StopPointRef $resolvedStopPointRef `
                    -NumberOfResults $effectiveNumberOfResults `
                    -ObservedAtUtc $observedAtUtc `
                    -HttpStatus $httpStatus `
                    -HttpAttempts $httpAttempts `
                    -StopEventsReturned $stopEventsReturned `
                    -SituationsInContext $situationsInContext `
                    -UnidentifiedSituations $unidentifiedSituations `
                    -LinksObserved $linksObserved `
                    -StopsInserted $stopsInserted `
                    -StopsAlreadyPresent $stopsAlreadyPresent `
                    -SituationsInserted $situationsInserted `
                    -SituationsAlreadyPresent $situationsAlreadyPresent `
                    -LinksInserted $linksInserted `
                    -LinksAlreadyPresent $linksAlreadyPresent `
                    -LinksSkippedUnresolved $linksSkippedUnresolved `
                    -ErrorCategory $stage `
                    -ErrorMessage (Get-MddSafeErrorMessage -Exception $originalException)
            }
            catch {
                $auditException = $_.Exception
                $auditMessage = Get-MddSafeErrorMessage -Exception $auditException
                Write-Warning ("Collector run audit update failed for CollectorRunId {0}: {1}. Original Collector failure is preserved." -f $collectorRunId, $auditMessage)
            }
        }

        throw $originalErrorRecord
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
    "Get-MddRealtimeSamplingTarget",
    "Write-MddRealtimeSnapshot",
    "Invoke-MddRealtimeCollector"
)
