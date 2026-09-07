USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/*
    Focused diagnostic queries for ctl.MddCollectorRun.
    These queries intentionally inspect the operational audit table only; they
    do not create analytics-layer objects or reliability KPIs.
*/

/* 1. Recent executions, newest first. */
SELECT TOP (50)
    CollectorRunId,
    StartedAtUtc,
    CompletedAtUtc,
    DurationMs,
    Status,
    SamplingMode,
    SamplingBucketUtc,
    SamplingSlot,
    SamplingTargetId,
    SamplingTargetName,
    StopPointRef,
    NumberOfResults,
    ObservedAtUtc,
    HttpStatus,
    HttpAttempts,
    StopEventsReturned,
    SituationsInContext,
    UnidentifiedSituations,
    LinksObserved,
    StopsInserted,
    StopsAlreadyPresent,
    SituationsInserted,
    SituationsAlreadyPresent,
    LinksInserted,
    LinksAlreadyPresent,
    LinksSkippedUnresolved,
    ErrorCategory,
    ErrorMessage
FROM ctl.MddCollectorRun
ORDER BY StartedAtUtc DESC, CollectorRunId DESC;

/* 2. Run count by lifecycle status. */
SELECT
    Status,
    COUNT_BIG(*) AS RunCount
FROM ctl.MddCollectorRun
GROUP BY Status
ORDER BY Status;

/* 3. Simple success rate across completed runs. */
;WITH CompletedRuns AS
(
    SELECT
        COUNT_BIG(*) AS CompletedRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Succeeded' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS SucceededRunCount,
        COALESCE(SUM(CASE WHEN Status = 'Failed' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS FailedRunCount
    FROM ctl.MddCollectorRun
    WHERE Status IN ('Succeeded', 'Failed')
)
SELECT
    CompletedRunCount,
    SucceededRunCount,
    FailedRunCount,
    CONVERT(DECIMAL(5, 2),
        CASE
            WHEN CompletedRunCount = 0 THEN NULL
            ELSE 100.0 * SucceededRunCount / CompletedRunCount
        END
    ) AS SuccessRatePercent
FROM CompletedRuns;

/* 4. Executions that remain Started beyond a normal run window. */
SELECT
    CollectorRunId,
    StartedAtUtc,
    DATEDIFF_BIG(MILLISECOND, StartedAtUtc, SYSUTCDATETIME()) AS OpenDurationMs,
    SamplingMode,
    SamplingTargetName,
    StopPointRef,
    NumberOfResults
FROM ctl.MddCollectorRun
WHERE Status = 'Started'
  AND StartedAtUtc < DATEADD(MINUTE, -15, SYSUTCDATETIME())
ORDER BY StartedAtUtc ASC, CollectorRunId ASC;

/* 5. Recent failures with the recorded failure stage and safe message. */
SELECT TOP (50)
    CollectorRunId,
    StartedAtUtc,
    CompletedAtUtc,
    DurationMs,
    Status,
    SamplingTargetName,
    StopPointRef,
    HttpStatus,
    HttpAttempts,
    StopEventsReturned,
    SituationsInContext,
    LinksInserted,
    ErrorCategory,
    ErrorMessage
FROM ctl.MddCollectorRun
WHERE Status = 'Failed'
ORDER BY StartedAtUtc DESC, CollectorRunId DESC;
