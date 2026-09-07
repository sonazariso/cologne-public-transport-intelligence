USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/*
    Read-only operational report for the historical realtime collection phase.

    This script intentionally reports source coverage, configured-panel
    coverage, snapshot gaps, and Collector run health. It does not create
    views, facts, KPIs, or synthetic/backfilled observations.

    Run after 09-create-mdd-collector-run-audit.sql when Collector run audit
    results are required. The audit section remains safe to run before that
    deployment and reports that the audit objects are not deployed.
*/
DECLARE @CheckedAtUtc DATETIME2(0) = CONVERT(DATETIME2(0), SYSUTCDATETIME());
DECLARE @ExpectedIntervalSeconds INT = 5 * 60;
DECLARE @StaleStartedMinutes INT = 15;

/* 1. Overall historical observation coverage. */
SELECT
    @CheckedAtUtc AS CheckedAtUtc,
    COUNT_BIG(*) AS StopObservationCount,
    COUNT(DISTINCT ObservedAtUtc) AS SnapshotCount,
    MIN(ObservedAtUtc) AS EarliestObservedAtUtc,
    MAX(ObservedAtUtc) AS LatestObservedAtUtc,
    COUNT(DISTINCT CONVERT(DATE, ObservedAtUtc)) AS DistinctCollectionDates,
    CASE
        WHEN MIN(ObservedAtUtc) IS NULL THEN 0
        ELSE DATEDIFF(DAY, CONVERT(DATE, MIN(ObservedAtUtc)), CONVERT(DATE, MAX(ObservedAtUtc))) + 1
    END AS CalendarSpanDays,
    MIN(CreatedAtUtc) AS EarliestCreatedAtUtc,
    MAX(CreatedAtUtc) AS LatestCreatedAtUtc
FROM stg.MddRealtimeStopObservation;

/* 2. Observations and snapshots by UTC collection date. */
SELECT
    CONVERT(DATE, observation.ObservedAtUtc) AS ObservationDateUtc,
    COUNT_BIG(*) AS StopObservationCount,
    COUNT(DISTINCT observation.ObservedAtUtc) AS SnapshotCount,
    COUNT(DISTINCT observation.StopPointRef) AS SourceStopPointRefCount,
    SUM
    (
        CASE
            WHEN observation.StopPointRef = sampling_target.StopPointRef
              OR source_stop.ParentStationId = sampling_target.StopPointRef
            THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS ConfiguredPanelObservationCount
FROM stg.MddRealtimeStopObservation AS observation
LEFT JOIN dw.DimStop AS source_stop
    ON source_stop.StopId = observation.StopPointRef
LEFT JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
    ON sampling_target.IsEnabled = 1
   AND
   (
       observation.StopPointRef = sampling_target.StopPointRef
       OR source_stop.ParentStationId = sampling_target.StopPointRef
   )
GROUP BY CONVERT(DATE, observation.ObservedAtUtc)
ORDER BY ObservationDateUtc;

/* 3. Observations by UTC hour and source mode. */
SELECT
    DATEPART(HOUR, observation.ObservedAtUtc) AS ObservationUtcHour,
    COALESCE(NULLIF(LTRIM(RTRIM(observation.PtMode)), N''), N'(NULL/blank)') AS PtMode,
    COUNT_BIG(*) AS StopObservationCount,
    COUNT(DISTINCT observation.ObservedAtUtc) AS SnapshotCount,
    COUNT(DISTINCT observation.StopPointRef) AS SourceStopPointRefCount
FROM stg.MddRealtimeStopObservation AS observation
GROUP BY
    DATEPART(HOUR, observation.ObservedAtUtc),
    COALESCE(NULLIF(LTRIM(RTRIM(observation.PtMode)), N''), N'(NULL/blank)')
ORDER BY ObservationUtcHour, PtMode;

/* 4. Historical coverage of each enabled sampling target. */
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.TargetName,
    sampling_target.StopPointRef,
    sampling_target.IsEnabled,
    sampling_target.NumberOfResults,
    COUNT(DISTINCT sampling_slot.SamplingSlot) AS ConfiguredSlotCount,
    COUNT_BIG(DISTINCT observation.ObservationKey) AS StopObservationCount,
    COUNT(DISTINCT observation.ObservedAtUtc) AS SnapshotCount,
    MIN(observation.ObservedAtUtc) AS FirstObservedAtUtc,
    MAX(observation.ObservedAtUtc) AS LastObservedAtUtc,
    CASE
        WHEN COUNT_BIG(DISTINCT observation.ObservationKey) > 0 THEN CAST(1 AS BIT)
        ELSE CAST(0 AS BIT)
    END AS HasHistoricalObservation
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN ctl.MddRealtimeSamplingSlot AS sampling_slot
    ON sampling_slot.SamplingTargetId = sampling_target.SamplingTargetId
LEFT JOIN stg.MddRealtimeStopObservation AS observation
    ON observation.StopPointRef = sampling_target.StopPointRef
    OR EXISTS
    (
        SELECT 1
        FROM dw.DimStop AS source_stop
        WHERE source_stop.StopId = observation.StopPointRef
          AND source_stop.ParentStationId = sampling_target.StopPointRef
    )
WHERE sampling_target.IsEnabled = 1
GROUP BY
    sampling_target.SamplingTargetId,
    sampling_target.TargetName,
    sampling_target.StopPointRef,
    sampling_target.IsEnabled,
    sampling_target.NumberOfResults
ORDER BY sampling_target.SamplingTargetId;

/* 5. Snapshot gaps larger than the expected five-minute cadence. */
;WITH Snapshots AS
(
    SELECT DISTINCT ObservedAtUtc
    FROM stg.MddRealtimeStopObservation
), SnapshotGaps AS
(
    SELECT
        ObservedAtUtc,
        LAG(ObservedAtUtc) OVER (ORDER BY ObservedAtUtc) AS PreviousObservedAtUtc
    FROM Snapshots
)
SELECT
    COUNT_BIG(*) AS SnapshotCount,
    MIN(ObservedAtUtc) AS FirstSnapshotUtc,
    MAX(ObservedAtUtc) AS LastSnapshotUtc,
    MIN(DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc)) AS MinGapSeconds,
    MAX(DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc)) AS MaxGapSeconds,
    AVG(CONVERT(DECIMAL(18, 2), DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc))) AS AverageGapSeconds,
    COALESCE
    (
        SUM
        (
            CASE
                WHEN PreviousObservedAtUtc IS NOT NULL
                 AND DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc) > @ExpectedIntervalSeconds
                THEN CONVERT(BIGINT, 1)
                ELSE CONVERT(BIGINT, 0)
            END
        ),
        CONVERT(BIGINT, 0)
    ) AS GapsOverExpectedInterval
FROM SnapshotGaps;

;WITH Snapshots AS
(
    SELECT DISTINCT ObservedAtUtc
    FROM stg.MddRealtimeStopObservation
), SnapshotGaps AS
(
    SELECT
        ObservedAtUtc,
        LAG(ObservedAtUtc) OVER (ORDER BY ObservedAtUtc) AS PreviousObservedAtUtc
    FROM Snapshots
)
SELECT
    PreviousObservedAtUtc,
    ObservedAtUtc,
    DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc) AS GapSeconds
FROM SnapshotGaps
WHERE PreviousObservedAtUtc IS NOT NULL
  AND DATEDIFF_BIG(SECOND, PreviousObservedAtUtc, ObservedAtUtc) > @ExpectedIntervalSeconds
ORDER BY PreviousObservedAtUtc;

/* 6. Collector audit health, when the audit deployment exists. */
IF OBJECT_ID(N'ctl.MddCollectorRun', N'U') IS NULL
BEGIN
    SELECT
        CAST(N'AuditNotDeployed' AS NVARCHAR(30)) AS AuditStatus,
        CAST(N'Run sql/02-staging/09-create-mdd-collector-run-audit.sql before relying on Collector run audit coverage.' AS NVARCHAR(300)) AS Detail;
END;
ELSE
BEGIN
    SELECT
        @CheckedAtUtc AS CheckedAtUtc,
        COUNT_BIG(*) AS CollectorRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Succeeded' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS SucceededRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Failed' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS FailedRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Started' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS StartedRunCount,
        COALESCE(SUM(CASE WHEN Status IN ('Succeeded', 'Failed') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS CompletedRunCount,
        CONVERT
        (
            DECIMAL(5, 2),
            CASE
                WHEN SUM(CASE WHEN Status IN ('Succeeded', 'Failed') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) = 0 THEN NULL
                ELSE 100.0 * SUM(CASE WHEN Status = 'Succeeded' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
                    / SUM(CASE WHEN Status IN ('Succeeded', 'Failed') THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            END
        ) AS SuccessRatePercent,
        MIN(StartedAtUtc) AS EarliestStartedAtUtc,
        MAX(StartedAtUtc) AS LatestStartedAtUtc
    FROM ctl.MddCollectorRun;

    SELECT
        CONVERT(DATE, StartedAtUtc) AS StartedDateUtc,
        COUNT_BIG(*) AS CollectorRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Succeeded' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS SucceededRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Failed' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS FailedRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Started' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS StartedRunCount,
        COALESCE(SUM(CASE WHEN StopEventsReturned IS NULL THEN CONVERT(BIGINT, 0) ELSE StopEventsReturned END), CONVERT(BIGINT, 0)) AS SourceStopEventsReturned
    FROM ctl.MddCollectorRun
    GROUP BY CONVERT(DATE, StartedAtUtc)
    ORDER BY StartedDateUtc;

    SELECT TOP (50)
        CollectorRunId,
        StartedAtUtc,
        CompletedAtUtc,
        DurationMs,
        Status,
        SamplingMode,
        SamplingBucketUtc,
        SamplingSlot,
        SamplingTargetName,
        StopPointRef,
        NumberOfResults,
        HttpStatus,
        HttpAttempts,
        StopEventsReturned,
        StopsInserted,
        StopsAlreadyPresent,
        ErrorCategory,
        ErrorMessage
    FROM ctl.MddCollectorRun
    ORDER BY StartedAtUtc DESC, CollectorRunId DESC;

    SELECT
        CollectorRunId,
        StartedAtUtc,
        DATEDIFF_BIG(MILLISECOND, StartedAtUtc, @CheckedAtUtc) AS OpenDurationMs,
        SamplingMode,
        SamplingTargetName,
        StopPointRef
    FROM ctl.MddCollectorRun
    WHERE Status = 'Started'
      AND StartedAtUtc < DATEADD(MINUTE, -@StaleStartedMinutes, @CheckedAtUtc)
    ORDER BY StartedAtUtc;

    SELECT
        ErrorCategory,
        COUNT_BIG(*) AS FailedRunCount
    FROM ctl.MddCollectorRun
    WHERE Status = 'Failed'
    GROUP BY ErrorCategory
    ORDER BY FailedRunCount DESC, ErrorCategory;
END;

/* 7. Source counts returned by successful audited executions. */
IF OBJECT_ID(N'ctl.MddCollectorRun', N'U') IS NOT NULL
BEGIN
    SELECT
        COUNT_BIG(*) AS SuccessfulRunCount,
        COALESCE(SUM(CASE WHEN StopEventsReturned IS NULL THEN CONVERT(BIGINT, 0) ELSE StopEventsReturned END), CONVERT(BIGINT, 0)) AS SourceStopEventsReturned,
        AVG(CONVERT(DECIMAL(18, 2), StopEventsReturned)) AS AverageStopEventsReturned,
        MIN(StopEventsReturned) AS MinimumStopEventsReturned,
        MAX(StopEventsReturned) AS MaximumStopEventsReturned,
        COALESCE(SUM(CASE WHEN StopsInserted IS NULL THEN CONVERT(BIGINT, 0) ELSE StopsInserted END), CONVERT(BIGINT, 0)) AS StopsInserted
    FROM ctl.MddCollectorRun
    WHERE Status = 'Succeeded';
END;

/* 8. Existing working-layer matching status distribution. */
IF OBJECT_ID(N'wrk.vwCologneRealtimeTripMatch', N'V') IS NOT NULL
BEGIN
    SELECT
        MatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM wrk.vwCologneRealtimeTripMatch
    GROUP BY MatchStatus
    ORDER BY MatchStatus;
END;
