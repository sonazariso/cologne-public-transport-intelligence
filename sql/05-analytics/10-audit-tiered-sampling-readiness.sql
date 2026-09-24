/*
    Read-only Tiered Collector readiness diagnostic.

    This script is intentionally an inspection report.  Persistent tables are
    read under READ UNCOMMITTED; only session-scoped # tables are used for
    intermediate calculations.  The approved station list below is copied
    from docs/24-REALTIME-50-STATION-BASELINE.md and is not recomputed here.

    Static density definition:
      each active service-date scheduled arrival is a deterministic anchor;
      a forward window is [anchor arrival, anchor arrival + N minutes).
      Typical = P50 of anchor-window counts, high density = P95, and peak =
      MAX.  GTFS arrival seconds remain service-day seconds, so values above
      24:00 are not wrapped to a clock time.

    Realtime snapshot definition:
      observations are grouped at current target/parent station + ObservedAtUtc
      when the source stop maps to a current enabled target.  The persisted
      schema has ObservedAtUtc + ResultId row identity but no CollectorRunId;
      this script does not fabricate that relationship.
*/

USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

DECLARE @QuotaLimit BIGINT = 250000;

DROP TABLE IF EXISTS #CurrentTargetContract;
DROP TABLE IF EXISTS #RunBase;
DROP TABLE IF EXISTS #HttpAttemptRows;
DROP TABLE IF EXISTS #AutomaticDuration;
DROP TABLE IF EXISTS #DurationRows;
DROP TABLE IF EXISTS #DurationSummary;
DROP TABLE IF EXISTS #ReturnBehaviorRows;
DROP TABLE IF EXISTS #RealtimeSnapshotCandidate;
DROP TABLE IF EXISTS #DefensibleRealtimeSnapshot;
DROP TABLE IF EXISTS #RealtimeCoverageStats;
DROP TABLE IF EXISTS #ApprovedPanel;
DROP TABLE IF EXISTS #StaticScheduleEvents;
DROP TABLE IF EXISTS #StaticEventAnchors;
DROP TABLE IF EXISTS #StaticDensityStats;
DROP TABLE IF EXISTS #BudgetPlan;
DROP TABLE IF EXISTS #BudgetSummary;
DROP TABLE IF EXISTS #PhasePlan;

/* ========================================================================
   SECTION 1 — CURRENT TARGET CONTRACT
   ======================================================================== */

;WITH EnabledSlotCounts AS
(
    SELECT
        sampling_slot.SamplingTargetId,
        COUNT_BIG(*) AS SamplingSlotCount
    FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
    INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
        ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
    WHERE sampling_target.IsEnabled = 1
    GROUP BY sampling_slot.SamplingTargetId
),
EnabledSlotTotal AS
(
    SELECT COUNT_BIG(*) AS EnabledSamplingSlotCount
    FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
    INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
        ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
    WHERE sampling_target.IsEnabled = 1
),
SlotList AS
(
    SELECT
        sampling_slot.SamplingTargetId,
        STRING_AGG
        (
            CONVERT(NVARCHAR(MAX), CONVERT(NVARCHAR(20), sampling_slot.SamplingSlot)),
            N', '
        ) WITHIN GROUP (ORDER BY sampling_slot.SamplingSlot) AS SamplingSlots
    FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
    GROUP BY sampling_slot.SamplingTargetId
)
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.TargetName,
    sampling_target.StopPointRef,
    sampling_target.NumberOfResults,
    sampling_target.IsEnabled,
    COALESCE(enabled_slot_counts.SamplingSlotCount, CONVERT(BIGINT, 0))
        AS SamplingSlotCount,
    enabled_slot_total.EnabledSamplingSlotCount,
    CASE
        WHEN COALESCE(enabled_slot_counts.SamplingSlotCount, 0) > 0
        THEN CONVERT
        (
            DECIMAL(12, 2),
            5.0 * enabled_slot_total.EnabledSamplingSlotCount
                / enabled_slot_counts.SamplingSlotCount
        )
        ELSE NULL
    END AS EffectiveLegacyCadenceMinutes,
    slot_list.SamplingSlots
INTO #CurrentTargetContract
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN EnabledSlotCounts AS enabled_slot_counts
    ON enabled_slot_counts.SamplingTargetId = sampling_target.SamplingTargetId
LEFT JOIN SlotList AS slot_list
    ON slot_list.SamplingTargetId = sampling_target.SamplingTargetId
CROSS JOIN EnabledSlotTotal AS enabled_slot_total
WHERE sampling_target.IsEnabled = 1;

CREATE UNIQUE CLUSTERED INDEX UX_CurrentTargetContract
    ON #CurrentTargetContract (SamplingTargetId);

SELECT
    SamplingTargetId,
    TargetName,
    StopPointRef,
    NumberOfResults,
    IsEnabled,
    SamplingSlotCount,
    EnabledSamplingSlotCount,
    EffectiveLegacyCadenceMinutes,
    SamplingSlots
FROM #CurrentTargetContract
ORDER BY SamplingTargetId;

;WITH ContractCounts AS
(
    SELECT
        COUNT_BIG(*) AS ActualEnabledTargetCount,
        COUNT_BIG(CASE WHEN NumberOfResults = 5 THEN 1 END)
            AS EnabledTargetsWithNumberOfResultsFive,
        COUNT_BIG(CASE WHEN NumberOfResults <> 5 THEN 1 END)
            AS EnabledTargetsWithOtherNumberOfResults,
        COUNT_BIG(CASE WHEN SamplingSlotCount = 0 THEN 1 END)
            AS EnabledTargetsWithoutSamplingSlot,
        COUNT(DISTINCT NumberOfResults) AS DistinctCurrentNumberOfResults,
        COALESCE(MAX(EnabledSamplingSlotCount), CONVERT(BIGINT, 0))
            AS ActualEnabledSamplingSlotCount
    FROM #CurrentTargetContract
)
SELECT
    CONVERT(BIGINT, 7) AS ExpectedEnabledTargetCount,
    counts.ActualEnabledTargetCount,
    CONVERT(BIGINT, 10) AS ExpectedEnabledSamplingSlotCount,
    counts.ActualEnabledSamplingSlotCount,
    counts.EnabledTargetsWithNumberOfResultsFive,
    counts.EnabledTargetsWithOtherNumberOfResults,
    counts.EnabledTargetsWithoutSamplingSlot,
    counts.DistinctCurrentNumberOfResults,
    CASE
        WHEN counts.ActualEnabledTargetCount = 7
         AND counts.ActualEnabledSamplingSlotCount = 10
         AND counts.EnabledTargetsWithNumberOfResultsFive = 7
         AND counts.EnabledTargetsWithOtherNumberOfResults = 0
         AND counts.EnabledTargetsWithoutSamplingSlot = 0
        THEN N'MATCHES_EXPECTED_CURRENT_CONTRACT'
        ELSE N'DISCREPANCY_REPORTED_ONLY'
    END AS CurrentContractStatus;

/* Run rows are copied once so every later section uses the same read-only
   classification and can distinguish a current enabled target from an old,
   disabled, or unassigned target id. */
SELECT
    collector_run.*,
    current_target.TargetName AS CurrentEnabledTargetName,
    current_target.StopPointRef AS CurrentEnabledStopPointRef,
    CONVERT
    (
        BIT,
        CASE WHEN current_target.SamplingTargetId IS NULL THEN 0 ELSE 1 END
    ) AS IsCurrentEnabledTarget
INTO #RunBase
FROM ctl.MddCollectorRun AS collector_run
LEFT JOIN #CurrentTargetContract AS current_target
    ON current_target.SamplingTargetId = collector_run.SamplingTargetId;

CREATE INDEX IX_RunBase_ModeTargetStatus
    ON #RunBase (SamplingMode, SamplingTargetId, Status)
    INCLUDE
    (
        CollectorRunId,
        StartedAtUtc,
        CompletedAtUtc,
        HttpAttempts,
        StopEventsReturned,
        NumberOfResults
    );

/* ========================================================================
   SECTION 2 — COLLECTOR RUN VOLUME AND OUTCOMES
   ======================================================================== */

;WITH RawAutomaticRollup AS
(
    SELECT
        N'CURRENT_ENABLED_TARGET' AS SamplingTargetScope,
        current_target.SamplingTargetId,
        current_target.TargetName,
        current_target.StopPointRef,
        COUNT_BIG(collector_run.CollectorRunId) AS AutomaticRunCount,
        COUNT_BIG(CASE WHEN collector_run.Status = 'Succeeded' THEN 1 END)
            AS AutomaticSucceededCount,
        COUNT_BIG(CASE WHEN collector_run.Status = 'Failed' THEN 1 END)
            AS AutomaticFailedCount,
        COUNT_BIG(CASE WHEN collector_run.Status = 'Started' THEN 1 END)
            AS AutomaticStartedCount,
        MIN(collector_run.StartedAtUtc) AS EarliestAutomaticRun,
        MAX(collector_run.StartedAtUtc) AS LatestAutomaticRun
    FROM #CurrentTargetContract AS current_target
    LEFT JOIN #RunBase AS collector_run
        ON collector_run.SamplingMode = 'Automatic'
       AND collector_run.SamplingTargetId = current_target.SamplingTargetId
    GROUP BY
        current_target.SamplingTargetId,
        current_target.TargetName,
        current_target.StopPointRef
    UNION ALL
    SELECT
        N'NOT_CURRENT_ENABLED_TARGET' AS SamplingTargetScope,
        collector_run.SamplingTargetId,
        COALESCE
        (
            collector_run.SamplingTargetName,
            N'(automatic run without current enabled target)'
        ) AS TargetName,
        collector_run.StopPointRef,
        COUNT_BIG(*) AS AutomaticRunCount,
        COUNT_BIG(CASE WHEN collector_run.Status = 'Succeeded' THEN 1 END),
        COUNT_BIG(CASE WHEN collector_run.Status = 'Failed' THEN 1 END),
        COUNT_BIG(CASE WHEN collector_run.Status = 'Started' THEN 1 END),
        MIN(collector_run.StartedAtUtc),
        MAX(collector_run.StartedAtUtc)
    FROM #RunBase AS collector_run
    WHERE collector_run.SamplingMode = 'Automatic'
      AND collector_run.IsCurrentEnabledTarget = 0
    GROUP BY
        collector_run.SamplingTargetId,
        collector_run.SamplingTargetName,
        collector_run.StopPointRef
)
SELECT
    SamplingTargetScope,
    SamplingTargetId,
    TargetName,
    StopPointRef,
    AutomaticRunCount,
    AutomaticSucceededCount,
    AutomaticFailedCount,
    AutomaticStartedCount,
    CONVERT
    (
        DECIMAL(9, 2),
        100.0 * AutomaticSucceededCount / NULLIF(AutomaticRunCount, 0)
    ) AS AutomaticSuccessRatePercent,
    CONVERT
    (
        DECIMAL(9, 2),
        100.0 * AutomaticFailedCount / NULLIF(AutomaticRunCount, 0)
    ) AS AutomaticFailureRatePercent,
    EarliestAutomaticRun,
    LatestAutomaticRun
FROM RawAutomaticRollup
ORDER BY
    CASE WHEN SamplingTargetScope = N'CURRENT_ENABLED_TARGET' THEN 0 ELSE 1 END,
    SamplingTargetId;

SELECT
    N'NETWORK' AS SamplingTargetScope,
    COUNT_BIG(*) AS AutomaticRunCount,
    COUNT_BIG(CASE WHEN Status = 'Succeeded' THEN 1 END)
        AS AutomaticSucceededCount,
    COUNT_BIG(CASE WHEN Status = 'Failed' THEN 1 END)
        AS AutomaticFailedCount,
    COUNT_BIG(CASE WHEN Status = 'Started' THEN 1 END)
        AS AutomaticStartedCount,
    CONVERT
    (
        DECIMAL(9, 2),
        100.0 * COUNT_BIG(CASE WHEN Status = 'Succeeded' THEN 1 END)
            / NULLIF(COUNT_BIG(*), 0)
    ) AS AutomaticSuccessRatePercent,
    CONVERT
    (
        DECIMAL(9, 2),
        100.0 * COUNT_BIG(CASE WHEN Status = 'Failed' THEN 1 END)
            / NULLIF(COUNT_BIG(*), 0)
    ) AS AutomaticFailureRatePercent,
    MIN(StartedAtUtc) AS EarliestAutomaticRun,
    MAX(StartedAtUtc) AS LatestAutomaticRun
FROM #RunBase
WHERE SamplingMode = 'Automatic';

/* Manual runs remain a separate result set and never enter automatic rates. */
;WITH ManualRollup AS
(
    SELECT
        COALESCE(CONVERT(NVARCHAR(30), SamplingTargetId), N'(unassigned)')
            AS SamplingTargetIdLabel,
        SamplingTargetId,
        COALESCE(SamplingTargetName, N'(manual run)') AS TargetName,
        StopPointRef,
        COUNT_BIG(*) AS ManualRunCount,
        COUNT_BIG(CASE WHEN Status = 'Succeeded' THEN 1 END)
            AS ManualSucceededCount,
        COUNT_BIG(CASE WHEN Status = 'Failed' THEN 1 END)
            AS ManualFailedCount,
        COUNT_BIG(CASE WHEN Status = 'Started' THEN 1 END)
            AS ManualStartedCount,
        MIN(StartedAtUtc) AS EarliestManualRun,
        MAX(StartedAtUtc) AS LatestManualRun
    FROM #RunBase
    WHERE SamplingMode = 'Manual'
    GROUP BY SamplingTargetId, SamplingTargetName, StopPointRef
)
SELECT
    SamplingTargetIdLabel,
    SamplingTargetId,
    TargetName,
    StopPointRef,
    ManualRunCount,
    ManualSucceededCount,
    ManualFailedCount,
    ManualStartedCount,
    EarliestManualRun,
    LatestManualRun
FROM ManualRollup
ORDER BY SamplingTargetId;

/* ========================================================================
   SECTION 3 — ACTUAL HTTP ATTEMPT DISTRIBUTION
   ======================================================================== */

;WITH RunOutcomes AS
(
    SELECT CONVERT(VARCHAR(20), 'Succeeded') AS RunOutcome
    UNION ALL SELECT CONVERT(VARCHAR(20), 'Failed')
)
SELECT
    CONVERT(NVARCHAR(30), N'NETWORK') AS ScopeLevel,
    CONVERT(INT, NULL) AS SamplingTargetId,
    CONVERT(NVARCHAR(200), N'Network aggregate') AS TargetName,
    run_outcome.RunOutcome,
    collector_run.CollectorRunId,
    collector_run.HttpAttempts
INTO #HttpAttemptRows
FROM RunOutcomes AS run_outcome
LEFT JOIN #RunBase AS collector_run
    ON collector_run.SamplingMode = 'Automatic'
   AND collector_run.Status = run_outcome.RunOutcome
UNION ALL
SELECT
    CONVERT(NVARCHAR(30), N'CURRENT_ENABLED_TARGET'),
    current_target.SamplingTargetId,
    current_target.TargetName,
    run_outcome.RunOutcome,
    collector_run.CollectorRunId,
    collector_run.HttpAttempts
FROM #CurrentTargetContract AS current_target
CROSS JOIN RunOutcomes AS run_outcome
LEFT JOIN #RunBase AS collector_run
    ON collector_run.SamplingMode = 'Automatic'
   AND collector_run.Status = run_outcome.RunOutcome
   AND collector_run.SamplingTargetId = current_target.SamplingTargetId;

;WITH AttemptMetrics AS
(
    SELECT
        ScopeLevel,
        SamplingTargetId,
        TargetName,
        RunOutcome,
        COUNT_BIG(CollectorRunId) AS RunCount,
        COUNT_BIG
        (
            CASE WHEN CollectorRunId IS NOT NULL AND HttpAttempts IS NULL
                 THEN 1 END
        ) AS RunsWithMissingHttpAttempts,
        COUNT_BIG
        (
            CASE WHEN HttpAttempts IS NOT NULL THEN 1 END
        ) AS RunsWithKnownHttpAttempts,
        COUNT_BIG(CASE WHEN HttpAttempts = 0 THEN 1 END)
            AS RunsWithHttpAttemptsZero,
        COUNT_BIG(CASE WHEN HttpAttempts = 1 THEN 1 END)
            AS RunsWithHttpAttemptsOne,
        COUNT_BIG(CASE WHEN HttpAttempts = 2 THEN 1 END)
            AS RunsWithHttpAttemptsTwo,
        COUNT_BIG(CASE WHEN HttpAttempts = 3 THEN 1 END)
            AS RunsWithHttpAttemptsThree,
        COUNT_BIG(CASE WHEN HttpAttempts > 3 THEN 1 END)
            AS RunsWithHttpAttemptsGreaterThanThree,
        COUNT_BIG(CASE WHEN HttpAttempts >= 1 THEN 1 END)
            AS RunsWithAtLeastOneHttpAttempt,
        COUNT_BIG(CASE WHEN HttpAttempts > 1 THEN 1 END)
            AS RunsRequiringMoreThanOneHttpAttempt,
        SUM
        (
            CASE WHEN HttpAttempts IS NULL THEN CONVERT(BIGINT, 0)
                 ELSE CONVERT(BIGINT, HttpAttempts) END
        ) AS TotalHttpAttemptsKnown
    FROM #HttpAttemptRows
    GROUP BY ScopeLevel, SamplingTargetId, TargetName, RunOutcome
)
SELECT
    ScopeLevel,
    SamplingTargetId,
    TargetName,
    RunOutcome,
    RunCount,
    RunsWithMissingHttpAttempts,
    RunsWithKnownHttpAttempts,
    RunsWithHttpAttemptsZero,
    RunsWithHttpAttemptsOne,
    RunsWithHttpAttemptsTwo,
    RunsWithHttpAttemptsThree,
    RunsWithHttpAttemptsGreaterThanThree,
    CASE WHEN RunsWithKnownHttpAttempts > 0
         THEN TotalHttpAttemptsKnown END AS TotalHttpAttempts,
    CASE WHEN RunsWithKnownHttpAttempts > 0
         THEN CONVERT
         (
             DECIMAL(19, 4),
             CONVERT(DECIMAL(28, 6), TotalHttpAttemptsKnown)
                 / RunsWithKnownHttpAttempts
         ) END AS AverageHttpAttemptsPerRun,
    RunsRequiringMoreThanOneHttpAttempt,
    CASE WHEN RunsWithKnownHttpAttempts > 0
         THEN CONVERT
         (
             DECIMAL(9, 2),
             100.0 * RunsRequiringMoreThanOneHttpAttempt
                 / RunsWithKnownHttpAttempts
         ) END AS PercentRunsRequiringMoreThanOneHttpAttempt,
    RunsWithAtLeastOneHttpAttempt,
    CASE WHEN RunsWithAtLeastOneHttpAttempt > 0
              AND TotalHttpAttemptsKnown IS NOT NULL
         THEN CONVERT
         (
             DECIMAL(19, 6),
             CONVERT(DECIMAL(28, 6),
                 TotalHttpAttemptsKnown - RunsWithAtLeastOneHttpAttempt)
                 / RunsWithAtLeastOneHttpAttempt
         ) END AS AdditionalHttpAttemptRate,
    CASE WHEN RunsWithAtLeastOneHttpAttempt > 0
              AND TotalHttpAttemptsKnown IS NOT NULL
         THEN CONVERT
         (
             DECIMAL(9, 2),
             100.0 * CONVERT(DECIMAL(28, 6),
                 TotalHttpAttemptsKnown - RunsWithAtLeastOneHttpAttempt)
                 / RunsWithAtLeastOneHttpAttempt
         ) END AS AdditionalHttpAttemptRatePercent,
    CASE
        WHEN RunsWithMissingHttpAttempts = 0 THEN N'COMPLETE_HTTP_ATTEMPT_TELEMETRY'
        WHEN RunsWithKnownHttpAttempts = 0 THEN N'NULL_MISSING_FOR_ALL_RUNS'
        ELSE N'PARTIAL_NULL_MISSING_TELEMETRY'
    END AS HttpTelemetryStatus,
    CASE
        WHEN RunsWithAtLeastOneHttpAttempt > 0
        THEN N'AdditionalHttpAttemptRate uses known runs with at least one attempt.'
        ELSE N'AdditionalHttpAttemptRate is NULL because no known run has an attempt.'
    END AS AdditionalHttpAttemptRateDefinition
FROM AttemptMetrics
ORDER BY
    CASE WHEN ScopeLevel = N'NETWORK' THEN 0 ELSE 1 END,
    SamplingTargetId,
    RunOutcome;

/* ========================================================================
   SECTION 4 — COLLECTOR EXECUTION DURATION
   ======================================================================== */

SELECT
    collector_run.*,
    CONVERT
    (
        DECIMAL(28, 3),
        DATEDIFF_BIG(MILLISECOND, collector_run.StartedAtUtc,
                     collector_run.CompletedAtUtc)
    ) / CONVERT(DECIMAL(28, 3), 1000) AS DurationSeconds
INTO #AutomaticDuration
FROM #RunBase AS collector_run
WHERE collector_run.SamplingMode = 'Automatic'
  AND collector_run.StartedAtUtc IS NOT NULL
  AND collector_run.CompletedAtUtc IS NOT NULL
  AND collector_run.CompletedAtUtc >= collector_run.StartedAtUtc;

CREATE INDEX IX_AutomaticDuration_TargetStatus
    ON #AutomaticDuration (SamplingTargetId, Status)
    INCLUDE (CollectorRunId, DurationSeconds);

;WITH DurationOutcomes AS
(
    SELECT CONVERT(VARCHAR(30), 'Succeeded') AS OutcomeStatus
    UNION ALL SELECT CONVERT(VARCHAR(30), 'Failed')
),
DurationRows AS
(
    SELECT
        CONVERT(NVARCHAR(30), N'NETWORK') AS ScopeLevel,
        CONVERT(INT, NULL) AS SamplingTargetId,
        CONVERT(NVARCHAR(200), N'Network aggregate') AS TargetName,
        duration_outcome.OutcomeStatus,
        duration.CollectorRunId,
        duration.DurationSeconds
    FROM DurationOutcomes AS duration_outcome
    LEFT JOIN #AutomaticDuration AS duration
        ON duration.Status = duration_outcome.OutcomeStatus
    UNION ALL
    SELECT
        CONVERT(NVARCHAR(30), N'CURRENT_ENABLED_TARGET'),
        current_target.SamplingTargetId,
        current_target.TargetName,
        duration_outcome.OutcomeStatus,
        duration.CollectorRunId,
        duration.DurationSeconds
    FROM #CurrentTargetContract AS current_target
    CROSS JOIN DurationOutcomes AS duration_outcome
    LEFT JOIN #AutomaticDuration AS duration
        ON duration.Status = duration_outcome.OutcomeStatus
       AND duration.SamplingTargetId = current_target.SamplingTargetId
    UNION ALL
    SELECT
        CONVERT(NVARCHAR(30), N'NETWORK'),
        CONVERT(INT, NULL),
        CONVERT(NVARCHAR(200), N'Network aggregate'),
        CONVERT(VARCHAR(30), N'ALL_COMPLETED_AUTOMATIC'),
        duration.CollectorRunId,
        duration.DurationSeconds
    FROM #AutomaticDuration AS duration
)
SELECT *
INTO #DurationRows
FROM DurationRows;

;WITH DurationPercentiles AS
(
    SELECT
        ScopeLevel,
        SamplingTargetId,
        TargetName,
        OutcomeStatus,
        CollectorRunId,
        DurationSeconds,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY DurationSeconds)
            OVER (PARTITION BY ScopeLevel, SamplingTargetId, OutcomeStatus) AS P50,
        PERCENTILE_CONT(0.90) WITHIN GROUP
            (ORDER BY DurationSeconds)
            OVER (PARTITION BY ScopeLevel, SamplingTargetId, OutcomeStatus) AS P90,
        PERCENTILE_CONT(0.95) WITHIN GROUP
            (ORDER BY DurationSeconds)
            OVER (PARTITION BY ScopeLevel, SamplingTargetId, OutcomeStatus) AS P95,
        PERCENTILE_CONT(0.99) WITHIN GROUP
            (ORDER BY DurationSeconds)
            OVER (PARTITION BY ScopeLevel, SamplingTargetId, OutcomeStatus) AS P99
    FROM #DurationRows
),
DurationSummary AS
(
    SELECT
        ScopeLevel,
        SamplingTargetId,
        TargetName,
        OutcomeStatus,
        COUNT_BIG(CollectorRunId) AS ValidCompletedAutomaticRunCount,
        MIN(DurationSeconds) AS MinimumDurationSeconds,
        CONVERT(DECIMAL(28, 3), MAX(P50)) AS P50DurationSeconds,
        CONVERT(DECIMAL(28, 3), MAX(P90)) AS P90DurationSeconds,
        CONVERT(DECIMAL(28, 3), MAX(P95)) AS P95DurationSeconds,
        CONVERT(DECIMAL(28, 3), MAX(P99)) AS P99DurationSeconds,
        MAX(DurationSeconds) AS MaximumDurationSeconds,
        AVG(DurationSeconds) AS AverageDurationSeconds
    FROM DurationPercentiles
    GROUP BY ScopeLevel, SamplingTargetId, TargetName, OutcomeStatus
)
SELECT
    ScopeLevel,
    SamplingTargetId,
    TargetName,
    OutcomeStatus,
    ValidCompletedAutomaticRunCount,
    MinimumDurationSeconds,
    P50DurationSeconds,
    P90DurationSeconds,
    P95DurationSeconds,
    P99DurationSeconds,
    MaximumDurationSeconds,
    AverageDurationSeconds
INTO #DurationSummary
FROM DurationSummary;

SELECT
    ScopeLevel,
    SamplingTargetId,
    TargetName,
    OutcomeStatus,
    ValidCompletedAutomaticRunCount,
    MinimumDurationSeconds,
    P50DurationSeconds,
    P90DurationSeconds,
    P95DurationSeconds,
    P99DurationSeconds,
    MaximumDurationSeconds,
    AverageDurationSeconds
FROM #DurationSummary
ORDER BY
    CASE WHEN ScopeLevel = N'NETWORK' THEN 0 ELSE 1 END,
    SamplingTargetId,
    OutcomeStatus;

SELECT
    COUNT_BIG(*) AS AutomaticRunCount,
    COUNT_BIG
    (
        CASE WHEN StartedAtUtc IS NOT NULL
                   AND CompletedAtUtc IS NOT NULL
                   AND CompletedAtUtc >= StartedAtUtc
             THEN 1 END
    ) AS ValidCompletedAutomaticRunCount,
    COUNT_BIG(CASE WHEN CompletedAtUtc IS NULL THEN 1 END)
        AS AutomaticRunsWithoutCompletedAtUtc,
    COUNT_BIG
    (
        CASE WHEN CompletedAtUtc IS NOT NULL
                   AND CompletedAtUtc < StartedAtUtc
             THEN 1 END
    ) AS AutomaticRunsWithInvalidTimestampOrder,
    N'Only completed Automatic rows with nonnegative timestamp duration enter the percentile calculations.'
        AS DurationInclusionRule
FROM #RunBase
WHERE SamplingMode = 'Automatic';

/* ========================================================================
   SECTION 5 — NUMBEROFRESULTS RETURN BEHAVIOR
   ======================================================================== */

SELECT
    CONVERT(NVARCHAR(30), N'NETWORK') AS ScopeLevel,
    CONVERT(INT, NULL) AS SamplingTargetId,
    CONVERT(NVARCHAR(200), N'Network aggregate') AS TargetName,
    collector_run.CollectorRunId,
    collector_run.StopEventsReturned
INTO #ReturnBehaviorRows
FROM (VALUES (1)) AS network_scope(ScopeId)
LEFT JOIN #RunBase AS collector_run
    ON collector_run.SamplingMode = 'Automatic'
   AND collector_run.Status = 'Succeeded'
   AND collector_run.NumberOfResults = 5
UNION ALL
SELECT
    CONVERT(NVARCHAR(30), N'CURRENT_ENABLED_TARGET'),
    current_target.SamplingTargetId,
    current_target.TargetName,
    collector_run.CollectorRunId,
    collector_run.StopEventsReturned
FROM #CurrentTargetContract AS current_target
LEFT JOIN #RunBase AS collector_run
    ON collector_run.SamplingMode = 'Automatic'
   AND collector_run.Status = 'Succeeded'
   AND collector_run.NumberOfResults = 5
   AND collector_run.SamplingTargetId = current_target.SamplingTargetId;

;WITH ReturnPercentiles AS
(
    SELECT
        ScopeLevel,
        SamplingTargetId,
        TargetName,
        CollectorRunId,
        StopEventsReturned,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY StopEventsReturned)
            OVER (PARTITION BY ScopeLevel, SamplingTargetId) AS MedianStopEventsReturned
    FROM #ReturnBehaviorRows
),
ReturnSummary AS
(
    SELECT
        ScopeLevel,
        SamplingTargetId,
        TargetName,
        COUNT_BIG(CollectorRunId) AS SuccessfulRunCount,
        COUNT_BIG(StopEventsReturned) AS RunsWithStopEventsReturnedTelemetry,
        COUNT_BIG(CASE WHEN CollectorRunId IS NOT NULL
                            AND StopEventsReturned IS NULL THEN 1 END)
            AS RunsWithMissingStopEventsReturned,
        CONVERT(DECIMAL(28, 3), MAX(MedianStopEventsReturned))
            AS MedianStopEventsReturned,
        MIN(StopEventsReturned) AS MinimumStopEventsReturned,
        MAX(StopEventsReturned) AS MaximumStopEventsReturned,
        COUNT_BIG(CASE WHEN StopEventsReturned = 5 THEN 1 END)
            AS RunsReturningExactlyFive,
        COUNT_BIG(CASE WHEN StopEventsReturned < 5 THEN 1 END)
            AS RunsReturningFewerThanFive,
        COUNT_BIG(CASE WHEN StopEventsReturned = 0 THEN 1 END)
            AS RunsReturningZero
    FROM ReturnPercentiles
    GROUP BY ScopeLevel, SamplingTargetId, TargetName
)
SELECT
    ScopeLevel,
    SamplingTargetId,
    TargetName,
    SuccessfulRunCount,
    RunsWithStopEventsReturnedTelemetry,
    RunsWithMissingStopEventsReturned,
    MedianStopEventsReturned,
    MinimumStopEventsReturned,
    MaximumStopEventsReturned,
    CASE WHEN RunsWithStopEventsReturnedTelemetry > 0
         THEN CONVERT
         (
             DECIMAL(9, 2),
             100.0 * RunsReturningExactlyFive
                 / RunsWithStopEventsReturnedTelemetry
         ) END AS PercentageReturningExactlyFive,
    CASE WHEN RunsWithStopEventsReturnedTelemetry > 0
         THEN CONVERT
         (
             DECIMAL(9, 2),
             100.0 * RunsReturningFewerThanFive
                 / RunsWithStopEventsReturnedTelemetry
         ) END AS PercentageReturningFewerThanFive,
    CASE WHEN RunsWithStopEventsReturnedTelemetry > 0
         THEN CONVERT
         (
             DECIMAL(9, 2),
             100.0 * RunsReturningZero
                 / RunsWithStopEventsReturnedTelemetry
         ) END AS PercentageReturningZero,
    N'Succeeded Automatic runs with NumberOfResults = 5; percentages use non-NULL StopEventsReturned telemetry.'
        AS InclusionRule
FROM ReturnSummary
ORDER BY
    CASE WHEN ScopeLevel = N'NETWORK' THEN 0 ELSE 1 END,
    SamplingTargetId;

/* ========================================================================
   SECTION 6 — TEMPORAL COVERAGE OF FIVE RETURNED EVENTS
   ======================================================================== */

;WITH ObservationWithCurrentTarget AS
(
    SELECT
        observation.ObservationKey,
        observation.ObservedAtUtc,
        observation.ResultId,
        observation.StopPointRef AS ObservedStopPointRef,
        observation.TimetabledArrivalUtc,
        current_target.SamplingTargetId,
        current_target.StopPointRef AS TargetStopPointRef,
        current_target.TargetName,
        COALESCE(current_target.StopPointRef, observation.StopPointRef)
            AS SnapshotGroupingStopPointRef
    FROM stg.MddRealtimeStopObservation AS observation
    LEFT JOIN dw.DimStop AS observed_stop
        ON observed_stop.StopId = observation.StopPointRef
    OUTER APPLY
    (
        SELECT TOP (1)
            target.SamplingTargetId,
            target.StopPointRef,
            target.TargetName
        FROM #CurrentTargetContract AS target
        WHERE target.StopPointRef = observation.StopPointRef
           OR observed_stop.ParentStationId = target.StopPointRef
        ORDER BY
            CASE WHEN target.StopPointRef = observation.StopPointRef
                 THEN 0 ELSE 1 END,
            target.SamplingTargetId
    ) AS current_target
)
SELECT
    observation_with_target.SamplingTargetId,
    observation_with_target.TargetStopPointRef,
    observation_with_target.TargetName,
    observation_with_target.SnapshotGroupingStopPointRef,
    observation_with_target.ObservedAtUtc,
    COUNT_BIG(*) AS SnapshotEventCount,
    COUNT_BIG(observation_with_target.TimetabledArrivalUtc)
        AS ArrivalTimestampEventCount,
    COUNT_BIG
    (
        CASE WHEN observation_with_target.TimetabledArrivalUtc IS NULL
             THEN 1 END
    ) AS MissingArrivalTimestampEventCount,
    MIN(observation_with_target.TimetabledArrivalUtc)
        AS EarliestTimetabledArrivalUtc,
    MAX(observation_with_target.TimetabledArrivalUtc)
        AS LatestTimetabledArrivalUtc
INTO #RealtimeSnapshotCandidate
FROM ObservationWithCurrentTarget AS observation_with_target
GROUP BY
    observation_with_target.SamplingTargetId,
    observation_with_target.TargetStopPointRef,
    observation_with_target.TargetName,
    observation_with_target.SnapshotGroupingStopPointRef,
    observation_with_target.ObservedAtUtc;

CREATE INDEX IX_RealtimeSnapshotCandidate_TargetObserved
    ON #RealtimeSnapshotCandidate (SamplingTargetId, ObservedAtUtc)
    INCLUDE
    (
        SnapshotEventCount,
        ArrivalTimestampEventCount,
        MissingArrivalTimestampEventCount,
        EarliestTimetabledArrivalUtc,
        LatestTimetabledArrivalUtc
    );

SELECT
    snapshot_candidate.*,
    CONVERT
    (
        DECIMAL(28, 3),
        DATEDIFF_BIG
        (
            SECOND,
            snapshot_candidate.ObservedAtUtc,
            snapshot_candidate.LatestTimetabledArrivalUtc
        )
    ) / CONVERT(DECIMAL(28, 3), 60) AS ForwardCoverageMinutes,
    CONVERT
    (
        DECIMAL(28, 3),
        DATEDIFF_BIG
        (
            SECOND,
            snapshot_candidate.EarliestTimetabledArrivalUtc,
            snapshot_candidate.LatestTimetabledArrivalUtc
        )
    ) / CONVERT(DECIMAL(28, 3), 60) AS ReturnedEventSpanMinutes
INTO #DefensibleRealtimeSnapshot
FROM #RealtimeSnapshotCandidate AS snapshot_candidate
WHERE snapshot_candidate.SamplingTargetId IS NOT NULL
  AND snapshot_candidate.SnapshotEventCount > 0
  AND snapshot_candidate.ArrivalTimestampEventCount
        = snapshot_candidate.SnapshotEventCount
  AND snapshot_candidate.LatestTimetabledArrivalUtc
        >= snapshot_candidate.ObservedAtUtc;

CREATE INDEX IX_DefensibleRealtimeSnapshot_Target
    ON #DefensibleRealtimeSnapshot (SamplingTargetId, ObservedAtUtc)
    INCLUDE (ForwardCoverageMinutes, ReturnedEventSpanMinutes);

SELECT
    SamplingTargetId,
    TargetStopPointRef,
    TargetName,
    SnapshotGroupingStopPointRef,
    ObservedAtUtc,
    SnapshotEventCount,
    EarliestTimetabledArrivalUtc,
    LatestTimetabledArrivalUtc,
    ForwardCoverageMinutes,
    ReturnedEventSpanMinutes,
    N'Grain = current enabled parent target + ObservedAtUtc; no CollectorRunId join was inferred.'
        AS SnapshotGrainNote
FROM #DefensibleRealtimeSnapshot
ORDER BY SamplingTargetId, ObservedAtUtc;

;WITH CoveragePercentiles AS
(
    SELECT
        SamplingTargetId,
        ForwardCoverageMinutes,
        ReturnedEventSpanMinutes,
        PERCENTILE_CONT(0.10) WITHIN GROUP
            (ORDER BY ForwardCoverageMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P10ForwardCoverageMinutes,
        PERCENTILE_CONT(0.25) WITHIN GROUP
            (ORDER BY ForwardCoverageMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P25ForwardCoverageMinutes,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY ForwardCoverageMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P50ForwardCoverageMinutes,
        PERCENTILE_CONT(0.90) WITHIN GROUP
            (ORDER BY ForwardCoverageMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P90ForwardCoverageMinutes,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY ReturnedEventSpanMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P50ReturnedEventSpanMinutes,
        PERCENTILE_CONT(0.90) WITHIN GROUP
            (ORDER BY ReturnedEventSpanMinutes)
            OVER (PARTITION BY SamplingTargetId) AS P90ReturnedEventSpanMinutes
    FROM #DefensibleRealtimeSnapshot
),
CoverageSummary AS
(
    SELECT
        SamplingTargetId,
        COUNT_BIG(*) AS DefensibleSnapshotCount,
        MIN(ForwardCoverageMinutes) AS MinimumForwardCoverageMinutes,
        MAX(ForwardCoverageMinutes) AS MaximumForwardCoverageMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P10ForwardCoverageMinutes))
            AS P10ForwardCoverageMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P25ForwardCoverageMinutes))
            AS P25ForwardCoverageMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P50ForwardCoverageMinutes))
            AS P50ForwardCoverageMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P90ForwardCoverageMinutes))
            AS P90ForwardCoverageMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P50ReturnedEventSpanMinutes))
            AS P50ReturnedEventSpanMinutes,
        CONVERT(DECIMAL(28, 3), MAX(P90ReturnedEventSpanMinutes))
            AS P90ReturnedEventSpanMinutes
    FROM CoveragePercentiles
    GROUP BY SamplingTargetId
),
CandidateCounts AS
(
    SELECT
        SamplingTargetId,
        COUNT_BIG(*) AS CandidateSnapshotCount
    FROM #RealtimeSnapshotCandidate
    WHERE SamplingTargetId IS NOT NULL
    GROUP BY SamplingTargetId
)
SELECT
    current_target.SamplingTargetId,
    current_target.StopPointRef,
    current_target.TargetName,
    COALESCE(candidate_counts.CandidateSnapshotCount, CONVERT(BIGINT, 0))
        AS CandidateSnapshotCount,
    COALESCE(coverage_summary.DefensibleSnapshotCount, CONVERT(BIGINT, 0))
        AS DefensibleSnapshotCount,
    COALESCE(candidate_counts.CandidateSnapshotCount, CONVERT(BIGINT, 0))
        - COALESCE(coverage_summary.DefensibleSnapshotCount, CONVERT(BIGINT, 0))
        AS ExcludedSnapshotCount,
    coverage_summary.P10ForwardCoverageMinutes,
    coverage_summary.P25ForwardCoverageMinutes,
    coverage_summary.P50ForwardCoverageMinutes,
    coverage_summary.P90ForwardCoverageMinutes,
    coverage_summary.MinimumForwardCoverageMinutes,
    coverage_summary.MaximumForwardCoverageMinutes,
    coverage_summary.P50ReturnedEventSpanMinutes,
    coverage_summary.P90ReturnedEventSpanMinutes,
    N'Forward coverage uses TimetabledArrivalUtc only; snapshots with missing arrival timestamps or latest arrival before observation are excluded.'
        AS CoverageInclusionRule
INTO #RealtimeCoverageStats
FROM #CurrentTargetContract AS current_target
LEFT JOIN CandidateCounts AS candidate_counts
    ON candidate_counts.SamplingTargetId = current_target.SamplingTargetId
LEFT JOIN CoverageSummary AS coverage_summary
    ON coverage_summary.SamplingTargetId = current_target.SamplingTargetId;

SELECT
    SamplingTargetId,
    StopPointRef,
    TargetName,
    CandidateSnapshotCount,
    DefensibleSnapshotCount,
    ExcludedSnapshotCount,
    P10ForwardCoverageMinutes,
    P25ForwardCoverageMinutes,
    P50ForwardCoverageMinutes,
    P90ForwardCoverageMinutes,
    MinimumForwardCoverageMinutes,
    MaximumForwardCoverageMinutes,
    P50ReturnedEventSpanMinutes,
    P90ReturnedEventSpanMinutes,
    CoverageInclusionRule
FROM #RealtimeCoverageStats
ORDER BY SamplingTargetId;

;WITH ExcludedSnapshots AS
(
    SELECT
        snapshot_candidate.SamplingTargetId,
        snapshot_candidate.TargetStopPointRef,
        snapshot_candidate.TargetName,
        CASE
            WHEN snapshot_candidate.SamplingTargetId IS NULL
                THEN N'UNMAPPED_TO_CURRENT_ENABLED_TARGET'
            WHEN snapshot_candidate.ArrivalTimestampEventCount = 0
                THEN N'NO_TIMETABLED_ARRIVAL_TIMESTAMP'
            WHEN snapshot_candidate.ArrivalTimestampEventCount
                   < snapshot_candidate.SnapshotEventCount
                THEN N'PARTIAL_TIMETABLED_ARRIVAL_TIMESTAMP'
            WHEN snapshot_candidate.LatestTimetabledArrivalUtc
                   < snapshot_candidate.ObservedAtUtc
                THEN N'LATEST_ARRIVAL_BEFORE_OBSERVED_AT_UTC'
            ELSE N'OTHER_NOT_DEFENSIBLE'
        END AS ExclusionReason
    FROM #RealtimeSnapshotCandidate AS snapshot_candidate
    LEFT JOIN #DefensibleRealtimeSnapshot AS defensible
        ON defensible.SamplingTargetId = snapshot_candidate.SamplingTargetId
       AND defensible.ObservedAtUtc = snapshot_candidate.ObservedAtUtc
       AND defensible.SnapshotGroupingStopPointRef
            = snapshot_candidate.SnapshotGroupingStopPointRef
    WHERE defensible.SamplingTargetId IS NULL
)
SELECT
    SamplingTargetId,
    TargetStopPointRef,
    TargetName,
    ExclusionReason,
    COUNT_BIG(*) AS ExcludedSnapshotCount
FROM ExcludedSnapshots
GROUP BY
    SamplingTargetId,
    TargetStopPointRef,
    TargetName,
    ExclusionReason
ORDER BY SamplingTargetId, ExclusionReason;

SELECT
    COUNT_BIG(*) AS AllSnapshotCandidateGroups,
    COUNT_BIG(CASE WHEN SamplingTargetId IS NOT NULL THEN 1 END)
        AS SnapshotCandidateGroupsMappedToCurrentTarget,
    COUNT_BIG(CASE WHEN SamplingTargetId IS NULL THEN 1 END)
        AS SnapshotCandidateGroupsWithoutCurrentTarget,
    (SELECT COUNT_BIG(*) FROM #DefensibleRealtimeSnapshot)
        AS DefensibleSnapshotGroups,
    COUNT_BIG(*) - (SELECT COUNT_BIG(*) FROM #DefensibleRealtimeSnapshot)
        AS ExcludedSnapshotGroups,
    N'Persisted grain is ObservedAtUtc + ResultId at row level; target/parent + ObservedAtUtc is the defensible aggregate. No CollectorRunId relationship exists in the persisted observation schema.'
        AS SnapshotGrainExplanation
FROM #RealtimeSnapshotCandidate;

/* ========================================================================
   SECTION 7 — APPROVED 50-STATION STATIC DENSITY
   ======================================================================== */

;WITH ApprovedBaseline AS
(
    SELECT
        approved_rank,
        stop_point_ref COLLATE Latin1_General_100_BIN2 AS StopPointRef,
        approved_station_name,
        tier_name
    FROM
    (
        VALUES
            (1,  N'de:05315:19201', N'Köln Bf Mülheim',                    N'Tier A'),
            (2,  N'de:05315:11110', N'Köln Heumarkt',                      N'Tier A'),
            (3,  N'de:05315:11212', N'Köln Breslauer Platz/Hbf',            N'Tier A'),
            (4,  N'de:05315:19211', N'Köln Mülheim Wiener Platz',           N'Tier A'),
            (5,  N'de:05315:11201', N'Köln Hbf',                            N'Tier A'),
            (6,  N'de:05315:11901', N'Köln Messe/Deutz Bf',                 N'Tier A'),
            (7,  N'de:05315:14201', N'Köln Bf Ehrenfeld',                   N'Tier A'),
            (8,  N'de:05315:17701', N'Köln Wahn S-Bahn',                    N'Tier A'),
            (9,  N'de:05315:11801', N'Köln Hansaring',                      N'Tier A'),
            (10, N'de:05315:13701', N'Köln Bf Lövenich',                    N'Tier A'),
            (11, N'de:05315:16101', N'Köln Chorweiler',                     N'Tier B'),
            (12, N'de:05315:19614', N'Köln Leuchterstr.',                   N'Tier B'),
            (13, N'de:05315:19711', N'Köln Keupstr.',                       N'Tier B'),
            (14, N'de:05315:15201', N'Köln Geldernstr./Parkgürtel',         N'Tier B'),
            (15, N'de:05315:19713', N'Köln Mülheim Berliner Str.',           N'Tier B'),
            (16, N'de:05315:17301', N'Köln Bf Porz',                        N'Tier B'),
            (17, N'de:05315:13708', N'Köln Weiden Zentrum',                 N'Tier B'),
            (18, N'de:05315:14611', N'Köln Bocklemünd',                     N'Tier B'),
            (19, N'de:05315:13702', N'Köln Weiden West',                    N'Tier B'),
            (20, N'de:05315:11511', N'Köln Barbarossaplatz',                N'Tier B'),
            (21, N'de:05315:13213', N'Köln Berrenrather Str./Gürtel',       N'Tier B'),
            (22, N'de:05315:11513', N'Köln Süd Bf',                         N'Tier B'),
            (23, N'de:05315:19501', N'Köln Dellbrück S-Bahn',               N'Tier B'),
            (24, N'de:05315:15501', N'Köln Longerich S-Bahn',               N'Tier B'),
            (25, N'de:05315:19801', N'Köln Stammheim S-Bahn',               N'Tier B'),
            (26, N'de:05315:16601', N'Köln Worringen S-Bahn',               N'Tier B'),
            (27, N'de:05315:19511', N'Köln Dellbrück Hauptstr.',            N'Tier B'),
            (28, N'de:05315:18001', N'Köln Trimbornstr.',                   N'Tier B'),
            (29, N'de:05315:13111', N'Köln Weißhausstr.',                   N'Tier B'),
            (30, N'de:05315:19851', N'Köln Stammheimer Ring',               N'Tier B'),
            (31, N'de:05315:13501', N'Köln Müngersdorf Technologiepark S-Bahn', N'Tier C'),
            (32, N'de:05315:15001', N'Köln Nippes S-Bahn',                  N'Tier C'),
            (33, N'de:05315:19101', N'Köln Buchforst S-Bahn',               N'Tier C'),
            (34, N'de:05315:11111', N'Köln Neumarkt',                       N'Tier C'),
            (35, N'de:05315:19233', N'Köln Danzierstr.',                    N'Tier C'),
            (36, N'de:05315:18401', N'Köln Frankfurter Str.',               N'Tier C'),
            (37, N'de:05315:11907', N'Köln Bf Deutz/Messe LANXESS arena',   N'Tier C'),
            (38, N'de:05315:12552', N'Köln Meschenich Kirche',              N'Tier C'),
            (39, N'de:05315:11411', N'Köln Chlodwigplatz',                  N'Tier C'),
            (40, N'de:05315:11710', N'Köln Friesenplatz',                   N'Tier C'),
            (41, N'de:05315:11810', N'Köln Ebertplatz',                     N'Tier C'),
            (42, N'de:05315:14211', N'Köln Venloer Str./Gürtel',            N'Tier C'),
            (43, N'de:05315:11610', N'Köln Rudolfplatz',                    N'Tier C'),
            (44, N'de:05315:17311', N'Köln Porz Markt',                     N'Tier C'),
            (45, N'de:05315:13411', N'Köln Aachener Str./Gürtel',           N'Tier C'),
            (46, N'de:05315:15011', N'Köln Neusser Str./Gürtel',            N'Tier C'),
            (47, N'de:05315:11311', N'Köln Severinstr.',                    N'Tier C'),
            (48, N'de:05315:19613', N'Köln Am Emberg',                     N'Tier C'),
            (49, N'de:05315:12711', N'Köln Rodenkirchen Bf',                N'Tier C'),
            (50, N'de:05315:15511', N'Köln Longericher Str.',               N'Tier C')
    ) AS baseline
    (
        approved_rank,
        stop_point_ref,
        approved_station_name,
        tier_name
    )
)
SELECT
    baseline.approved_rank AS ApprovedRank,
    baseline.StopPointRef,
    baseline.approved_station_name AS ApprovedStationName,
    baseline.tier_name AS CandidateTier,
    CASE baseline.tier_name
        WHEN N'Tier A' THEN CONVERT(INT, 5)
        WHEN N'Tier B' THEN CONVERT(INT, 10)
        WHEN N'Tier C' THEN CONVERT(INT, 30)
    END AS CandidateIntervalMinutes,
    current_target.SamplingTargetId,
    CONVERT
    (
        NVARCHAR(20),
        CASE WHEN current_target.SamplingTargetId IS NULL
             THEN N'NEW_TARGET' ELSE N'EXISTING_TARGET' END
    ) AS ExistingOrNewTarget,
    static_stop.StopName AS StaticWarehouseStationName
INTO #ApprovedPanel
FROM ApprovedBaseline AS baseline
LEFT JOIN #CurrentTargetContract AS current_target
    ON current_target.StopPointRef = baseline.StopPointRef
LEFT JOIN dw.DimStop AS static_stop
    ON static_stop.StopId = baseline.StopPointRef;

CREATE UNIQUE CLUSTERED INDEX UX_ApprovedPanel_Rank
    ON #ApprovedPanel (ApprovedRank);

CREATE UNIQUE INDEX UX_ApprovedPanel_StopPointRef
    ON #ApprovedPanel (StopPointRef);

SELECT
    CONVERT(BIGINT, 50) AS ExpectedApprovedStationCount,
    COUNT_BIG(*) AS ActualApprovedStationCount,
    COUNT_BIG(DISTINCT StopPointRef) AS ActualDistinctStopPointRefCount,
    COUNT_BIG(DISTINCT ApprovedRank) AS ActualDistinctApprovedRankCount,
    COUNT_BIG(CASE WHEN CandidateTier = N'Tier A' THEN 1 END)
        AS TierAStationCount,
    COUNT_BIG(CASE WHEN CandidateTier = N'Tier B' THEN 1 END)
        AS TierBStationCount,
    COUNT_BIG(CASE WHEN CandidateTier = N'Tier C' THEN 1 END)
        AS TierCStationCount,
    CASE
        WHEN COUNT_BIG(*) = 50
         AND COUNT_BIG(DISTINCT StopPointRef) = 50
         AND COUNT_BIG(DISTINCT ApprovedRank) = 50
         AND COUNT_BIG(CASE WHEN CandidateTier = N'Tier A' THEN 1 END) = 10
         AND COUNT_BIG(CASE WHEN CandidateTier = N'Tier B' THEN 1 END) = 20
         AND COUNT_BIG(CASE WHEN CandidateTier = N'Tier C' THEN 1 END) = 20
        THEN N'APPROVED_BASELINE_SHAPE_MATCH'
        ELSE N'BASELINE_SHAPE_DISCREPANCY_REPORTED_ONLY'
    END AS ApprovedPanelStatus;

/* A fact occurrence joined to BridgeServiceDate is one active service-date
   arrival.  The join uses all current warehouse schedule rows, including
   service-day seconds above 24:00 and all warehouse mode rows. */
SELECT
    approved_panel.ApprovedRank,
    approved_panel.StopPointRef,
    approved_panel.ApprovedStationName,
    approved_panel.CandidateTier,
    approved_panel.CandidateIntervalMinutes,
    scheduled_stop_event.ScheduledStopEventKey,
    scheduled_stop_event.StopKey,
    scheduled_stop_event.ServiceKey,
    service_date.DateKey AS ServiceDateKey,
    date_dimension.DateValue AS ServiceDate,
    scheduled_stop_event.ScheduledArrivalSeconds,
    scheduled_stop_event.ArrivalDayOffset
INTO #StaticScheduleEvents
FROM #ApprovedPanel AS approved_panel
INNER JOIN dw.DimStop AS served_stop
    ON served_stop.StopId = approved_panel.StopPointRef
    OR served_stop.ParentStationId = approved_panel.StopPointRef
INNER JOIN dw.FactScheduledStopEvent AS scheduled_stop_event
    ON scheduled_stop_event.StopKey = served_stop.StopKey
INNER JOIN dw.BridgeServiceDate AS service_date
    ON service_date.ServiceKey = scheduled_stop_event.ServiceKey
INNER JOIN dw.DimDate AS date_dimension
    ON date_dimension.DateKey = service_date.DateKey
WHERE scheduled_stop_event.ScheduledArrivalSeconds >= 0;

CREATE CLUSTERED INDEX IX_StaticScheduleEvents_StationDateArrival
    ON #StaticScheduleEvents
    (
        StopPointRef,
        ServiceDateKey,
        ScheduledArrivalSeconds,
        ScheduledStopEventKey
    );

/* Each anchor counts arrivals at the same parent station and active service
   date in three forward, half-open windows. */
SELECT
    anchor.ApprovedRank,
    anchor.StopPointRef,
    anchor.ApprovedStationName,
    anchor.CandidateTier,
    anchor.CandidateIntervalMinutes,
    anchor.ScheduledStopEventKey AS AnchorScheduledStopEventKey,
    anchor.ServiceDateKey,
    anchor.ServiceDate,
    anchor.ScheduledArrivalSeconds AS AnchorScheduledArrivalSeconds,
    window_counts.ScheduledArrivalsIn5MinuteWindow,
    window_counts.ScheduledArrivalsIn10MinuteWindow,
    window_counts.ScheduledArrivalsIn30MinuteWindow
INTO #StaticEventAnchors
FROM #StaticScheduleEvents AS anchor
CROSS APPLY
(
    SELECT
        COUNT_BIG
        (
            CASE WHEN nearby.ScheduledArrivalSeconds
                          < anchor.ScheduledArrivalSeconds + 300
                 THEN 1 END
        ) AS ScheduledArrivalsIn5MinuteWindow,
        COUNT_BIG
        (
            CASE WHEN nearby.ScheduledArrivalSeconds
                          < anchor.ScheduledArrivalSeconds + 600
                 THEN 1 END
        ) AS ScheduledArrivalsIn10MinuteWindow,
        COUNT_BIG(*) AS ScheduledArrivalsIn30MinuteWindow
    FROM #StaticScheduleEvents AS nearby
    WHERE nearby.StopPointRef = anchor.StopPointRef
      AND nearby.ServiceDateKey = anchor.ServiceDateKey
      AND nearby.ScheduledArrivalSeconds >= anchor.ScheduledArrivalSeconds
      AND nearby.ScheduledArrivalSeconds
            < anchor.ScheduledArrivalSeconds + 1800
) AS window_counts;

CREATE INDEX IX_StaticEventAnchors_Station
    ON #StaticEventAnchors (StopPointRef, ServiceDateKey)
    INCLUDE
    (
        ScheduledArrivalsIn5MinuteWindow,
        ScheduledArrivalsIn10MinuteWindow,
        ScheduledArrivalsIn30MinuteWindow
    );

;WITH AnchorPercentiles AS
(
    SELECT
        StopPointRef,
        ScheduledArrivalsIn5MinuteWindow,
        ScheduledArrivalsIn10MinuteWindow,
        ScheduledArrivalsIn30MinuteWindow,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn5MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P50_5,
        PERCENTILE_CONT(0.95) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn5MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P95_5,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn10MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P50_10,
        PERCENTILE_CONT(0.95) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn10MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P95_10,
        PERCENTILE_CONT(0.50) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn30MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P50_30,
        PERCENTILE_CONT(0.95) WITHIN GROUP
            (ORDER BY ScheduledArrivalsIn30MinuteWindow)
            OVER (PARTITION BY StopPointRef) AS P95_30
    FROM #StaticEventAnchors
),
AnchorStats AS
(
    SELECT
        StopPointRef,
        COUNT_BIG(*) AS WindowAnchorCount,
        CONVERT(DECIMAL(18, 2), MAX(P50_5)) AS TypicalScheduledArrivals5,
        CONVERT(DECIMAL(18, 2), MAX(P95_5)) AS HighDensityScheduledArrivals5,
        MAX(ScheduledArrivalsIn5MinuteWindow) AS PeakScheduledArrivals5,
        CONVERT(DECIMAL(18, 2), MAX(P50_10)) AS TypicalScheduledArrivals10,
        CONVERT(DECIMAL(18, 2), MAX(P95_10)) AS HighDensityScheduledArrivals10,
        MAX(ScheduledArrivalsIn10MinuteWindow) AS PeakScheduledArrivals10,
        CONVERT(DECIMAL(18, 2), MAX(P50_30)) AS TypicalScheduledArrivals30,
        CONVERT(DECIMAL(18, 2), MAX(P95_30)) AS HighDensityScheduledArrivals30,
        MAX(ScheduledArrivalsIn30MinuteWindow) AS PeakScheduledArrivals30
    FROM AnchorPercentiles
    GROUP BY StopPointRef
),
ScheduleStats AS
(
    SELECT
        StopPointRef,
        COUNT_BIG(*) AS ScheduledArrivalOccurrenceCount,
        COUNT_BIG(DISTINCT ServiceDateKey) AS ActiveServiceDateCount
    FROM #StaticScheduleEvents
    GROUP BY StopPointRef
)
SELECT
    approved_panel.ApprovedRank,
    approved_panel.StopPointRef,
    approved_panel.ApprovedStationName AS StationName,
    approved_panel.StaticWarehouseStationName,
    approved_panel.ExistingOrNewTarget,
    approved_panel.SamplingTargetId,
    approved_panel.CandidateTier,
    approved_panel.CandidateIntervalMinutes,
    COALESCE(schedule_stats.ActiveServiceDateCount, CONVERT(BIGINT, 0))
        AS ActiveServiceDateCount,
    COALESCE(schedule_stats.ScheduledArrivalOccurrenceCount, CONVERT(BIGINT, 0))
        AS ScheduledArrivalOccurrenceCount,
    COALESCE(anchor_stats.WindowAnchorCount, CONVERT(BIGINT, 0))
        AS WindowAnchorCount,
    anchor_stats.TypicalScheduledArrivals5,
    anchor_stats.HighDensityScheduledArrivals5,
    anchor_stats.PeakScheduledArrivals5,
    anchor_stats.TypicalScheduledArrivals10,
    anchor_stats.HighDensityScheduledArrivals10,
    anchor_stats.PeakScheduledArrivals10,
    anchor_stats.TypicalScheduledArrivals30,
    anchor_stats.HighDensityScheduledArrivals30,
    anchor_stats.PeakScheduledArrivals30,
    N'STATIC SCHEDULE PLANNING EVIDENCE' AS EvidenceType,
    N'Event-anchored forward half-open windows; Typical=P50, HighDensity=P95, Peak=MAX.'
        AS DensityDefinition,
    N'ScheduledArrivalSeconds and ArrivalDayOffset retain GTFS service-day semantics, including values beyond 24:00.'
        AS GtfsTimeSemantics
INTO #StaticDensityStats
FROM #ApprovedPanel AS approved_panel
LEFT JOIN ScheduleStats AS schedule_stats
    ON schedule_stats.StopPointRef = approved_panel.StopPointRef
LEFT JOIN AnchorStats AS anchor_stats
    ON anchor_stats.StopPointRef = approved_panel.StopPointRef;

CREATE UNIQUE CLUSTERED INDEX UX_StaticDensityStats_StopPointRef
    ON #StaticDensityStats (StopPointRef);

SELECT
    ApprovedRank,
    StopPointRef,
    StationName,
    StaticWarehouseStationName,
    ExistingOrNewTarget,
    SamplingTargetId,
    CandidateTier,
    CandidateIntervalMinutes,
    ActiveServiceDateCount,
    ScheduledArrivalOccurrenceCount,
    WindowAnchorCount,
    TypicalScheduledArrivals5,
    HighDensityScheduledArrivals5,
    PeakScheduledArrivals5,
    TypicalScheduledArrivals10,
    HighDensityScheduledArrivals10,
    PeakScheduledArrivals10,
    TypicalScheduledArrivals30,
    HighDensityScheduledArrivals30,
    PeakScheduledArrivals30,
    EvidenceType,
    DensityDefinition,
    GtfsTimeSemantics
FROM #StaticDensityStats
ORDER BY ApprovedRank;

/* ========================================================================
   SECTION 8 — NUMBEROFRESULTS=5 COVERAGE-RISK INPUT
   ======================================================================== */

;WITH CandidateWindowEvidence AS
(
    SELECT
        static_density.*,
        CASE static_density.CandidateIntervalMinutes
            WHEN 5 THEN static_density.TypicalScheduledArrivals5
            WHEN 10 THEN static_density.TypicalScheduledArrivals10
            WHEN 30 THEN static_density.TypicalScheduledArrivals30
        END AS CandidateWindowTypicalMedianCount,
        CASE static_density.CandidateIntervalMinutes
            WHEN 5 THEN static_density.HighDensityScheduledArrivals5
            WHEN 10 THEN static_density.HighDensityScheduledArrivals10
            WHEN 30 THEN static_density.HighDensityScheduledArrivals30
        END AS CandidateWindowHighDensityP95Count,
        CASE static_density.CandidateIntervalMinutes
            WHEN 5 THEN static_density.PeakScheduledArrivals5
            WHEN 10 THEN static_density.PeakScheduledArrivals10
            WHEN 30 THEN static_density.PeakScheduledArrivals30
        END AS CandidateWindowPeakCount
    FROM #StaticDensityStats AS static_density
)
SELECT
    ApprovedRank,
    StopPointRef,
    StationName,
    ExistingOrNewTarget,
    SamplingTargetId,
    CandidateTier,
    CandidateIntervalMinutes,
    CandidateWindowTypicalMedianCount,
    CandidateWindowHighDensityP95Count,
    CandidateWindowPeakCount,
    CONVERT
    (
        BIT,
        CASE
            WHEN CandidateWindowPeakCount IS NULL THEN NULL
            WHEN CandidateWindowPeakCount >= 5 THEN 1
            ELSE 0
        END
    ) AS FiveEventResultSetCouldBeExhaustedWithinCandidateIntervalAccordingToStaticPeakEvidence,
    CASE
        WHEN CandidateWindowPeakCount IS NULL
            THEN N'NO_STATIC_SCHEDULE_EVIDENCE'
        WHEN CandidateWindowPeakCount >= 5
            THEN N'POTENTIAL_FIVE_EVENT_SATURATION'
        WHEN CandidateWindowHighDensityP95Count >= 3
            THEN N'HIGH_STATIC_DENSITY'
        ELSE N'LOW_STATIC_DENSITY'
    END AS NeutralStaticEvidenceLabel,
    N'Static GTFS evidence only; this does not claim actual MDD return coverage or an architecture decision.'
        AS EvidenceLimitation
FROM CandidateWindowEvidence
ORDER BY ApprovedRank;

/* The seven historical targets are shown against both evidence sources. */
SELECT
    current_target.SamplingTargetId,
    current_target.StopPointRef,
    current_target.TargetName,
    current_target.EffectiveLegacyCadenceMinutes,
    approved_panel.ApprovedRank,
    approved_panel.CandidateTier,
    approved_panel.CandidateIntervalMinutes,
    static_density.TypicalScheduledArrivals5,
    static_density.HighDensityScheduledArrivals5,
    static_density.PeakScheduledArrivals5,
    static_density.TypicalScheduledArrivals10,
    static_density.HighDensityScheduledArrivals10,
    static_density.PeakScheduledArrivals10,
    static_density.TypicalScheduledArrivals30,
    static_density.HighDensityScheduledArrivals30,
    static_density.PeakScheduledArrivals30,
    realtime_coverage.CandidateSnapshotCount,
    realtime_coverage.DefensibleSnapshotCount,
    realtime_coverage.ExcludedSnapshotCount,
    realtime_coverage.P10ForwardCoverageMinutes,
    realtime_coverage.P25ForwardCoverageMinutes,
    realtime_coverage.P50ForwardCoverageMinutes,
    realtime_coverage.P90ForwardCoverageMinutes,
    realtime_coverage.MinimumForwardCoverageMinutes,
    realtime_coverage.MaximumForwardCoverageMinutes,
    realtime_coverage.P50ReturnedEventSpanMinutes,
    realtime_coverage.P90ReturnedEventSpanMinutes,
    N'STATIC SCHEDULE PLANNING EVIDENCE plus persisted realtime snapshot evidence; no MDD claim is made for static values.'
        AS EvidenceScope
FROM #CurrentTargetContract AS current_target
LEFT JOIN #ApprovedPanel AS approved_panel
    ON approved_panel.StopPointRef = current_target.StopPointRef
LEFT JOIN #StaticDensityStats AS static_density
    ON static_density.StopPointRef = current_target.StopPointRef
LEFT JOIN #RealtimeCoverageStats AS realtime_coverage
    ON realtime_coverage.SamplingTargetId = current_target.SamplingTargetId
ORDER BY current_target.SamplingTargetId;

/* ========================================================================
   SECTION 9 — 5/10/30 REQUEST BUDGET
   ======================================================================== */

;WITH TierPlan AS
(
    SELECT
        tier_name,
        station_count,
        candidate_interval_minutes
    FROM
    (
        VALUES
            (N'Tier A', CONVERT(BIGINT, 10), CONVERT(INT, 5)),
            (N'Tier B', CONVERT(BIGINT, 20), CONVERT(INT, 10)),
            (N'Tier C', CONVERT(BIGINT, 20), CONVERT(INT, 30))
    ) AS plan(tier_name, station_count, candidate_interval_minutes)
)
SELECT
    tier_name AS TierName,
    station_count AS StationCount,
    candidate_interval_minutes AS CandidateIntervalMinutes,
    CONVERT(BIGINT, station_count * 60 / candidate_interval_minutes)
        AS LogicalRequestsPerHour,
    CONVERT(BIGINT, station_count * 60 / candidate_interval_minutes * 24)
        AS LogicalRequestsPerDay,
    CONVERT(BIGINT, station_count * 60 / candidate_interval_minutes * 24 * 30)
        AS LogicalRequestsPer30Days,
    CONVERT(BIGINT, station_count * 60 / candidate_interval_minutes * 24 * 31)
        AS LogicalRequestsPer31Days
INTO #BudgetPlan
FROM TierPlan;

;WITH Horizons AS
(
    SELECT CONVERT(INT, 30) AS HorizonDays
    UNION ALL SELECT CONVERT(INT, 31)
),
RawBudget AS
(
    SELECT
        horizons.HorizonDays,
        SUM
        (
            CASE WHEN horizons.HorizonDays = 30
                 THEN budget_plan.LogicalRequestsPer30Days
                 ELSE budget_plan.LogicalRequestsPer31Days END
        ) AS LogicalRequests
    FROM Horizons AS horizons
    CROSS JOIN #BudgetPlan AS budget_plan
    GROUP BY horizons.HorizonDays
)
SELECT
    HorizonDays,
    LogicalRequests,
    CONVERT(DECIMAL(12, 3), 100.0 * LogicalRequests / @QuotaLimit)
        AS QuotaPercent,
    @QuotaLimit - LogicalRequests AS RemainingHeadroom
INTO #BudgetSummary
FROM RawBudget;

SELECT
    TierName,
    StationCount,
    CandidateIntervalMinutes,
    LogicalRequestsPerHour,
    LogicalRequestsPerDay,
    LogicalRequestsPer30Days,
    LogicalRequestsPer31Days,
    N'LOGICAL REQUEST BUDGET; no retry rate is assumed.' AS EvidenceType
FROM #BudgetPlan
ORDER BY TierName;

SELECT
    HorizonDays,
    LogicalRequests,
    QuotaPercent,
    RemainingHeadroom,
    N'LOGICAL REQUEST BUDGET; quota is 250,000.' AS EvidenceType
FROM #BudgetSummary
ORDER BY HorizonDays;

;WITH AdditionalAttemptRates AS
(
    SELECT CONVERT(DECIMAL(5, 2), 5.00) AS AdditionalAttemptRatePercent
    UNION ALL SELECT CONVERT(DECIMAL(5, 2), 10.00)
    UNION ALL SELECT CONVERT(DECIMAL(5, 2), 15.00)
    UNION ALL SELECT CONVERT(DECIMAL(5, 2), 20.00)
)
SELECT
    budget_summary.HorizonDays,
    additional_rate.AdditionalAttemptRatePercent,
    budget_summary.LogicalRequests AS BaseLogicalRequests,
    CONVERT
    (
        DECIMAL(28, 3),
        budget_summary.LogicalRequests
            * (1.0 + additional_rate.AdditionalAttemptRatePercent / 100.0)
    ) AS TotalAttempts,
    CONVERT
    (
        DECIMAL(12, 3),
        100.0 * budget_summary.LogicalRequests
            * (1.0 + additional_rate.AdditionalAttemptRatePercent / 100.0)
            / @QuotaLimit
    ) AS QuotaPercent,
    CONVERT
    (
        DECIMAL(28, 3),
        @QuotaLimit
            - budget_summary.LogicalRequests
                * (1.0 + additional_rate.AdditionalAttemptRatePercent / 100.0)
    ) AS RemainingHeadroom,
    N'SENSITIVITY ONLY; additional HTTP attempts are not predicted retry rates.'
        AS ScenarioType
FROM #BudgetSummary AS budget_summary
CROSS JOIN AdditionalAttemptRates AS additional_rate
ORDER BY budget_summary.HorizonDays, additional_rate.AdditionalAttemptRatePercent;

/* ========================================================================
   SECTION 10 — HISTORICAL CONTINUITY
   ======================================================================== */

SELECT
    current_target.SamplingTargetId,
    current_target.StopPointRef,
    current_target.TargetName,
    approved_panel.ApprovedRank,
    approved_panel.CandidateTier,
    current_target.EffectiveLegacyCadenceMinutes,
    approved_panel.CandidateIntervalMinutes,
    CONVERT
    (
        BIT,
        CASE WHEN approved_panel.StopPointRef IS NULL THEN 0 ELSE 1 END
    ) AS HistoricalTargetPresentInApprovedPanel,
    N'VALIDATION ONLY; preserve existing target ids, observations, situations, links, and CollectorRun rows.'
        AS MigrationPrinciple
FROM #CurrentTargetContract AS current_target
LEFT JOIN #ApprovedPanel AS approved_panel
    ON approved_panel.StopPointRef = current_target.StopPointRef
ORDER BY current_target.SamplingTargetId;

;WITH Continuity AS
(
    SELECT
        COUNT_BIG(*) AS CurrentEnabledTargetCount,
        COUNT_BIG(CASE WHEN approved_panel.StopPointRef IS NOT NULL THEN 1 END)
            AS CurrentTargetsPresentInApprovedPanel,
        COUNT_BIG(CASE WHEN approved_panel.StopPointRef IS NULL THEN 1 END)
            AS CurrentTargetsMissingFromApprovedPanel
    FROM #CurrentTargetContract AS current_target
    LEFT JOIN #ApprovedPanel AS approved_panel
        ON approved_panel.StopPointRef = current_target.StopPointRef
)
SELECT
    continuity.CurrentEnabledTargetCount,
    continuity.CurrentTargetsPresentInApprovedPanel,
    continuity.CurrentTargetsMissingFromApprovedPanel,
    CONVERT
    (
        BIT,
        CASE WHEN continuity.CurrentEnabledTargetCount > 0
                   AND continuity.CurrentTargetsMissingFromApprovedPanel = 0
             THEN 1 ELSE 0 END
    ) AS HistoricalTargetsPresentInFuturePanel,
    CONVERT(BIGINT, 43) AS PlannedAdditionalTargetCount,
    N'No migration is performed by this diagnostic.' AS ValidationOnly;

/* ========================================================================
   SECTION 11 — PHASE-STAGGERING MATHEMATICS
   ======================================================================== */

SELECT
    phase.HeartbeatNumber,
    phase.HeartbeatOffsetMinutes,
    phase.TierADueTargetCount,
    phase.TierBGroup1DueTargetCount,
    phase.TierBGroup2DueTargetCount,
    phase.TierBDueTargetCount,
    phase.TierCGroupDueTargetCount,
    phase.TierCDueTargetCount,
    phase.TotalLogicalTargetRequests
INTO #PhasePlan
FROM
(
    SELECT
        phase_number AS HeartbeatNumber,
        phase_number * 5 AS HeartbeatOffsetMinutes,
        CONVERT(BIGINT, 10) AS TierADueTargetCount,
        tier_b_group_1 AS TierBGroup1DueTargetCount,
        tier_b_group_2 AS TierBGroup2DueTargetCount,
        CONVERT(BIGINT, tier_b_group_1 + tier_b_group_2)
            AS TierBDueTargetCount,
        tier_c_group AS TierCGroupDueTargetCount,
        CONVERT(BIGINT, tier_c_group) AS TierCDueTargetCount,
        CONVERT(BIGINT, 10 + tier_b_group_1 + tier_b_group_2 + tier_c_group)
            AS TotalLogicalTargetRequests
    FROM
    (
        VALUES
            (0, 10, 0, 4),
            (1, 0, 10, 3),
            (2, 10, 0, 3),
            (3, 0, 10, 4),
            (4, 10, 0, 3),
            (5, 0, 10, 3)
    ) AS phase(phase_number, tier_b_group_1, tier_b_group_2, tier_c_group)
) AS phase;

SELECT
    HeartbeatNumber,
    HeartbeatOffsetMinutes,
    TierADueTargetCount,
    TierBGroup1DueTargetCount,
    TierBGroup2DueTargetCount,
    TierBDueTargetCount,
    TierCGroupDueTargetCount,
    TierCDueTargetCount,
    TotalLogicalTargetRequests,
    N'Tier B uses two stable groups of 10 on alternating five-minute heartbeats; Tier C uses balanced six-group sizes 4/3/3/4/3/3. Station membership/phases are not assigned here.'
        AS PhaseDefinition
FROM #PhasePlan
ORDER BY HeartbeatNumber;

SELECT
    SUM(TierADueTargetCount) AS TierALogicalRequestsPer30Minutes,
    SUM(TierBDueTargetCount) AS TierBLogicalRequestsPer30Minutes,
    SUM(TierCDueTargetCount) AS TierCLogicalRequestsPer30Minutes,
    SUM(TotalLogicalTargetRequests) AS TotalLogicalTargetRequestsPer30Minutes,
    SUM(TotalLogicalTargetRequests) * 2 AS TotalLogicalTargetRequestsPerHour,
    CONVERT
    (
        BIT,
        CASE WHEN SUM(TotalLogicalTargetRequests) = 140
                   AND SUM(TotalLogicalTargetRequests) * 2 = 280
             THEN 1 ELSE 0 END
    ) AS Expected140Per30MinutesAnd280PerHour,
    N'PHASE ASSIGNMENT NOT FINALIZED' AS PhaseAssignmentStatus;

/* ========================================================================
   SECTION 12 — FINAL MACHINE-READABLE SUMMARY
   ======================================================================== */

;WITH AutomaticCounts AS
(
    SELECT
        COUNT_BIG(*) AS AutomaticRunCount,
        COUNT_BIG(CASE WHEN Status = 'Succeeded' THEN 1 END)
            AS AutomaticSucceededCount,
        COUNT_BIG(CASE WHEN Status = 'Failed' THEN 1 END)
            AS AutomaticFailedCount,
        COUNT_BIG(CASE WHEN Status = 'Started' THEN 1 END)
            AS AutomaticStartedCount
    FROM #RunBase
    WHERE SamplingMode = 'Automatic'
),
HttpTotals AS
(
    SELECT
        COUNT_BIG(CASE WHEN HttpAttempts IS NULL THEN 1 END)
            AS HttpAttemptTelemetryMissingRunCount,
        COUNT_BIG(HttpAttempts) AS HttpAttemptTelemetryKnownRunCount,
        SUM
        (
            CASE WHEN HttpAttempts IS NULL THEN CONVERT(BIGINT, 0)
                 ELSE CONVERT(BIGINT, HttpAttempts) END
        ) AS KnownHttpAttemptCount,
        COUNT_BIG(CASE WHEN HttpAttempts >= 1 THEN 1 END)
            AS RunsWithAtLeastOneHttpAttempt
    FROM #RunBase
    WHERE SamplingMode = 'Automatic'
),
SuccessfulDurationPercentiles AS
(
    SELECT
        MAX(P50) AS P50SuccessfulRunDurationSeconds,
        MAX(P95) AS P95SuccessfulRunDurationSeconds,
        MAX(P99) AS P99SuccessfulRunDurationSeconds
    FROM
    (
        SELECT
            PERCENTILE_CONT(0.50) WITHIN GROUP
                (ORDER BY DurationSeconds) OVER () AS P50,
            PERCENTILE_CONT(0.95) WITHIN GROUP
                (ORDER BY DurationSeconds) OVER () AS P95,
            PERCENTILE_CONT(0.99) WITHIN GROUP
                (ORDER BY DurationSeconds) OVER () AS P99
        FROM #AutomaticDuration
        WHERE Status = 'Succeeded'
    ) AS duration_percentiles
),
CurrentContract AS
(
    SELECT
        COUNT_BIG(*) AS CurrentEnabledTargets,
        COALESCE(MAX(EnabledSamplingSlotCount), CONVERT(BIGINT, 0))
            AS CurrentSamplingSlots,
        CASE WHEN COUNT(DISTINCT NumberOfResults) = 1
             THEN CONVERT(INT, MIN(NumberOfResults)) END
            AS CurrentNumberOfResults
    FROM #CurrentTargetContract
),
Continuity AS
(
    SELECT
        CONVERT
        (
            BIT,
            CASE WHEN COUNT_BIG(*) > 0
                       AND COUNT_BIG
                           (CASE WHEN approved_panel.StopPointRef IS NULL THEN 1 END) = 0
                 THEN 1 ELSE 0 END
        ) AS HistoricalTargetsPresentInFuturePanel
    FROM #CurrentTargetContract AS current_target
    LEFT JOIN #ApprovedPanel AS approved_panel
        ON approved_panel.StopPointRef = current_target.StopPointRef
),
Budget AS
(
    SELECT
        MAX(CASE WHEN HorizonDays = 30 THEN LogicalRequests END)
            AS ThirtyDayLogicalRequests,
        MAX(CASE WHEN HorizonDays = 30 THEN QuotaPercent END)
            AS ThirtyDayQuotaPercent,
        MAX(CASE WHEN HorizonDays = 30 THEN RemainingHeadroom END)
            AS ThirtyDayHeadroom,
        MAX(CASE WHEN HorizonDays = 31 THEN LogicalRequests END)
            AS ThirtyOneDayLogicalRequests,
        MAX(CASE WHEN HorizonDays = 31 THEN QuotaPercent END)
            AS ThirtyOneDayQuotaPercent,
        MAX(CASE WHEN HorizonDays = 31 THEN RemainingHeadroom END)
            AS ThirtyOneDayHeadroom
    FROM #BudgetSummary
)
SELECT
    current_contract.CurrentEnabledTargets,
    current_contract.CurrentSamplingSlots,
    current_contract.CurrentNumberOfResults,
    automatic_counts.AutomaticRunCount,
    automatic_counts.AutomaticSucceededCount,
    automatic_counts.AutomaticFailedCount,
    automatic_counts.AutomaticStartedCount,
    CASE WHEN http_totals.HttpAttemptTelemetryMissingRunCount = 0
         THEN http_totals.KnownHttpAttemptCount END AS ActualHttpAttemptCount,
    http_totals.KnownHttpAttemptCount,
    http_totals.HttpAttemptTelemetryMissingRunCount,
    CASE WHEN http_totals.RunsWithAtLeastOneHttpAttempt > 0
              AND http_totals.KnownHttpAttemptCount IS NOT NULL
         THEN CONVERT
         (
             DECIMAL(19, 6),
             CONVERT(DECIMAL(28, 6),
                 http_totals.KnownHttpAttemptCount
                     - http_totals.RunsWithAtLeastOneHttpAttempt)
                 / http_totals.RunsWithAtLeastOneHttpAttempt
         ) END AS AdditionalHttpAttemptRate,
    CASE WHEN http_totals.HttpAttemptTelemetryMissingRunCount = 0
         THEN N'ALL_AUTOMATIC_RUNS_HAVE_HTTP_ATTEMPT_TELEMETRY'
         ELSE N'RATE_AND_KNOWN_TOTAL_USE_AVAILABLE_HTTP_TELEMETRY_ONLY'
    END AS HttpAttemptSummaryScope,
    CONVERT(DECIMAL(28, 3), duration_percentiles.P50SuccessfulRunDurationSeconds)
        AS P50SuccessfulRunDurationSeconds,
    CONVERT(DECIMAL(28, 3), duration_percentiles.P95SuccessfulRunDurationSeconds)
        AS P95SuccessfulRunDurationSeconds,
    CONVERT(DECIMAL(28, 3), duration_percentiles.P99SuccessfulRunDurationSeconds)
        AS P99SuccessfulRunDurationSeconds,
    budget.ThirtyDayLogicalRequests,
    budget.ThirtyDayQuotaPercent,
    budget.ThirtyDayHeadroom,
    budget.ThirtyOneDayLogicalRequests,
    budget.ThirtyOneDayQuotaPercent,
    budget.ThirtyOneDayHeadroom,
    continuity.HistoricalTargetsPresentInFuturePanel,
    (SELECT COUNT_BIG(*) FROM #ApprovedPanel) AS FuturePanelStationCount,
    (SELECT COUNT_BIG(DISTINCT StopPointRef) FROM #ApprovedPanel)
        AS FuturePanelDistinctStationCount,
    N'READ_ONLY_DIAGNOSTIC; no candidate tier is approved and no phase/station assignment is made.'
        AS SummaryScope
FROM CurrentContract AS current_contract
CROSS JOIN AutomaticCounts AS automatic_counts
CROSS JOIN HttpTotals AS http_totals
CROSS JOIN SuccessfulDurationPercentiles AS duration_percentiles
CROSS JOIN Continuity AS continuity
CROSS JOIN Budget AS budget;
