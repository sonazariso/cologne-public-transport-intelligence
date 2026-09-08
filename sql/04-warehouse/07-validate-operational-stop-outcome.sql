USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/*
    Read-only validation report for dw.FactOperationalStopOutcome.

    All examples and checks use genuine current staging observations.  The
    script never inserts, updates, deletes, backfills, or fabricates source
    observations.  Its two refresh calls are safe production refreshes used
    to prove repeatability against the current append-only source history.
*/

/* 1. Object, row count, and intended grain. */
SELECT
    OBJECT_SCHEMA_NAME(object_id) AS SchemaName,
    OBJECT_NAME(object_id) AS ObjectName,
    type_desc AS ObjectType
FROM sys.objects
WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome');

SELECT
    COUNT_BIG(*) AS OperationalOutcomeCount,
    COUNT_BIG(*) - COUNT_BIG(DISTINCT OperationalStopOutcomeKey)
        AS DuplicateSurrogateKeyCount,
    SUM(ObservationCount) AS SourceObservationsRepresented,
    SUM(CASE WHEN ObservationCount > 1
             THEN ObservationCount - 1 ELSE 0 END)
        AS RepeatedObservationsConsolidated
FROM dw.FactOperationalStopOutcome;

SELECT
    COUNT_BIG(*) AS DuplicateOperationalGrainGroups,
    COALESCE(SUM(DuplicateRows), 0) AS DuplicateOperationalRows
FROM
(
    SELECT
        DateKey,
        ScheduledStopEventKey,
        COUNT_BIG(*) - 1 AS DuplicateRows
    FROM dw.FactOperationalStopOutcome
    GROUP BY DateKey, ScheduledStopEventKey
    HAVING COUNT_BIG(*) > 1
) AS duplicate_grain;

/* 2. Constraint-aligned structural checks. */
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT N'ObservationCount <= 0' AS CheckName, COUNT_BIG(*) AS FailedRows
    FROM dw.FactOperationalStopOutcome
    WHERE ObservationCount <= 0

    UNION ALL
    SELECT N'FirstObservedAtUtc after LastObservedAtUtc', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome
    WHERE FirstObservedAtUtc > LastObservedAtUtc

    UNION ALL
    SELECT N'Invalid MatchStatus in fact', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome
    WHERE MatchStatus NOT IN (N'ExactStopMatch', N'ParentStationFallback')

    UNION ALL
    SELECT N'Fact rows with missing first observation lineage', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN stg.MddRealtimeStopObservation AS observation
        ON observation.ObservationKey = outcome.FirstObservationKey
    WHERE observation.ObservationKey IS NULL

    UNION ALL
    SELECT N'Fact rows with missing last observation lineage', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN stg.MddRealtimeStopObservation AS observation
        ON observation.ObservationKey = outcome.LastObservationKey
    WHERE observation.ObservationKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid DateKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = outcome.DateKey
    WHERE date_dimension.DateKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid ScheduledStopEventKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.FactScheduledStopEvent AS scheduled_stop
        ON scheduled_stop.ScheduledStopEventKey = outcome.ScheduledStopEventKey
    WHERE scheduled_stop.ScheduledStopEventKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid TripKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.FactScheduledTrip AS trip
        ON trip.TripKey = outcome.TripKey
    WHERE trip.TripKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid RouteKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.DimRoute AS route
        ON route.RouteKey = outcome.RouteKey
    WHERE route.RouteKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid StopKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.DimStop AS stop
        ON stop.StopKey = outcome.StopKey
    WHERE stop.StopKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid ModeKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.DimMode AS mode
        ON mode.ModeKey = outcome.ModeKey
    WHERE mode.ModeKey IS NULL

    UNION ALL
    SELECT N'Fact rows with invalid ServiceKey', COUNT_BIG(*)
    FROM dw.FactOperationalStopOutcome AS outcome
    LEFT JOIN dw.DimService AS service
        ON service.ServiceKey = outcome.ServiceKey
    WHERE service.ServiceKey IS NULL
) AS check_result
ORDER BY check_result.CheckName;

/* 3. Match-status distribution: non-usable observations remain outside fact. */
SELECT
    match_view.MatchStatus,
    COUNT_BIG(*) AS SourceObservationCount,
    CASE WHEN match_view.MatchStatus IN
              (N'ExactStopMatch', N'ParentStationFallback')
         THEN 'Eligible for operational outcomes'
         ELSE 'Data Quality/Coverage only'
    END AS OutcomeTreatment
FROM wrk.vwCologneRealtimeTripMatch AS match_view
GROUP BY match_view.MatchStatus
ORDER BY match_view.MatchStatus;

SELECT
    outcome.MatchStatus,
    COUNT_BIG(*) AS OperationalOutcomeCount
FROM dw.FactOperationalStopOutcome AS outcome
GROUP BY outcome.MatchStatus
ORDER BY outcome.MatchStatus;

/* 4. Real examples of repeated observations consolidated to one outcome. */
;WITH SourceConsolidation AS
(
    SELECT
        match_view.DateKey,
        match_view.ServiceDate,
        match_view.ScheduledStopEventKey,
        COUNT_BIG(*) AS SourceObservationCount,
        MIN(match_view.ObservationKey) AS EarliestSourceObservationKey,
        MAX(match_view.ObservationKey) AS LatestSourceObservationKey,
        MIN(match_view.ObservedAtUtc) AS EarliestSourceObservedAtUtc,
        MAX(match_view.ObservedAtUtc) AS LatestSourceObservedAtUtc
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
    GROUP BY
        match_view.DateKey,
        match_view.ServiceDate,
        match_view.ScheduledStopEventKey
)
SELECT TOP (15)
    outcome.ServiceDate,
    outcome.ScheduledStopEventKey,
    outcome.RouteKey,
    outcome.StopKey,
    outcome.MatchStatus,
    source_consolidation.SourceObservationCount,
    outcome.ObservationCount AS FactObservationCount,
    source_consolidation.EarliestSourceObservationKey,
    source_consolidation.LatestSourceObservationKey,
    outcome.FirstObservationKey,
    outcome.LastObservationKey,
    source_consolidation.EarliestSourceObservedAtUtc,
    source_consolidation.LatestSourceObservedAtUtc,
    outcome.FirstObservedAtUtc,
    outcome.LastObservedAtUtc,
    outcome.FirstObservedEstimatedDelayMinutes,
    outcome.FinalObservedEstimatedDelayMinutes,
    outcome.PlatformChangeEvidence,
    outcome.HasSituationEvidence,
    outcome.SituationLinkCount
FROM dw.FactOperationalStopOutcome AS outcome
JOIN SourceConsolidation AS source_consolidation
    ON source_consolidation.DateKey = outcome.DateKey
   AND source_consolidation.ScheduledStopEventKey = outcome.ScheduledStopEventKey
WHERE source_consolidation.SourceObservationCount > 1
ORDER BY
    source_consolidation.SourceObservationCount DESC,
    outcome.ServiceDate,
    outcome.ScheduledStopEventKey;

/* 5. Latest source observation lineage must be reflected in the fact. */
;WITH LatestSource AS
(
    SELECT
        match_view.DateKey,
        match_view.ScheduledStopEventKey,
        MAX(match_view.ObservationKey) AS LatestSourceObservationKey
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
    GROUP BY match_view.DateKey, match_view.ScheduledStopEventKey
)
SELECT
    COUNT_BIG(*) AS LatestObservationLineageViolations,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM LatestSource AS source_latest
JOIN dw.FactOperationalStopOutcome AS outcome
    ON outcome.DateKey = source_latest.DateKey
   AND outcome.ScheduledStopEventKey = source_latest.ScheduledStopEventKey
WHERE outcome.LastObservationKey <> source_latest.LatestSourceObservationKey;

SELECT
    COUNT_BIG(*) AS ConsolidatedOutcomeOrderingViolations,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM dw.FactOperationalStopOutcome AS outcome
WHERE outcome.ObservationCount > 1
  AND outcome.LastObservationKey <= outcome.FirstObservationKey;

/* 6. Situation-link totals and platform evidence semantics. */
;WITH SourceSituation AS
(
    SELECT
        match_view.DateKey,
        match_view.ScheduledStopEventKey,
        SUM(CASE WHEN link.ObservationKey IS NULL
                 THEN CONVERT(BIGINT, 0) ELSE CONVERT(BIGINT, 1) END)
            AS SituationLinkCount
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    LEFT JOIN stg.MddRealtimeStopSituationLink AS link
        ON link.ObservationKey = match_view.ObservationKey
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
    GROUP BY match_view.DateKey, match_view.ScheduledStopEventKey
),
PlatformEvidence AS
(
    SELECT
        outcome.OperationalStopOutcomeKey,
        MAX(CASE WHEN NULLIF(LTRIM(RTRIM(match_view.PlannedBay)), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(match_view.EstimatedBay)), N'') IS NOT NULL
                      AND LTRIM(RTRIM(match_view.PlannedBay))
                          <> LTRIM(RTRIM(match_view.EstimatedBay))
                 THEN 1 ELSE 0 END) AS HasChangedEvidence,
        MAX(CASE WHEN NULLIF(LTRIM(RTRIM(match_view.PlannedBay)), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(match_view.EstimatedBay)), N'') IS NOT NULL
                      AND LTRIM(RTRIM(match_view.PlannedBay))
                          = LTRIM(RTRIM(match_view.EstimatedBay))
                 THEN 1 ELSE 0 END) AS HasUnchangedEvidence
    FROM dw.FactOperationalStopOutcome AS outcome
    JOIN wrk.vwCologneRealtimeTripMatch AS match_view
        ON match_view.DateKey = outcome.DateKey
       AND match_view.ScheduledStopEventKey = outcome.ScheduledStopEventKey
    GROUP BY outcome.OperationalStopOutcomeKey
)
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT N'SituationLinkCount mismatch' AS CheckName, COUNT_BIG(*) AS FailedRows
    FROM SourceSituation AS source_situation
    JOIN dw.FactOperationalStopOutcome AS outcome
        ON outcome.DateKey = source_situation.DateKey
       AND outcome.ScheduledStopEventKey = source_situation.ScheduledStopEventKey
    WHERE outcome.SituationLinkCount <> source_situation.SituationLinkCount

    UNION ALL

    SELECT N'Changed without comparable changed evidence', COUNT_BIG(*)
    FROM PlatformEvidence AS evidence
    JOIN dw.FactOperationalStopOutcome AS outcome
        ON outcome.OperationalStopOutcomeKey = evidence.OperationalStopOutcomeKey
    WHERE outcome.PlatformChangeEvidence = 'Changed'
      AND evidence.HasChangedEvidence = 0

    UNION ALL

    SELECT N'Unchanged without comparable unchanged-only evidence', COUNT_BIG(*)
    FROM PlatformEvidence AS evidence
    JOIN dw.FactOperationalStopOutcome AS outcome
        ON outcome.OperationalStopOutcomeKey = evidence.OperationalStopOutcomeKey
    WHERE outcome.PlatformChangeEvidence = 'Unchanged'
      AND (evidence.HasUnchangedEvidence = 0 OR evidence.HasChangedEvidence = 1)

    UNION ALL

    SELECT N'Unknown with comparable platform evidence', COUNT_BIG(*)
    FROM PlatformEvidence AS evidence
    JOIN dw.FactOperationalStopOutcome AS outcome
        ON outcome.OperationalStopOutcomeKey = evidence.OperationalStopOutcomeKey
    WHERE outcome.PlatformChangeEvidence = 'Unknown'
      AND (evidence.HasUnchangedEvidence = 1 OR evidence.HasChangedEvidence = 1)
) AS check_result
ORDER BY check_result.CheckName;

/* 7. Refresh repeatability on current genuine source state. */
CREATE TABLE #FactStateBeforeRepeat
(
    DateKey INT NOT NULL,
    ServiceDate DATE NOT NULL,
    ScheduledStopEventKey BIGINT NOT NULL,
    TripKey BIGINT NOT NULL,
    RouteKey INT NOT NULL,
    StopKey INT NOT NULL,
    ModeKey SMALLINT NOT NULL,
    ServiceKey INT NOT NULL,
    MatchStatus NVARCHAR(30) NOT NULL,
    FirstObservationKey BIGINT NOT NULL,
    LastObservationKey BIGINT NOT NULL,
    FirstObservedAtUtc DATETIME2(0) NOT NULL,
    LastObservedAtUtc DATETIME2(0) NOT NULL,
    ObservationCount BIGINT NOT NULL,
    TimetabledArrivalUtc DATETIME2(0) NOT NULL,
    FirstEstimatedArrivalUtc DATETIME2(0) NULL,
    LatestObservedEstimatedArrivalUtc DATETIME2(0) NULL,
    FirstObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    FinalObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    PlannedBay NVARCHAR(100) NULL,
    LatestObservedEstimatedBay NVARCHAR(100) NULL,
    PlatformChangeEvidence VARCHAR(20) NOT NULL,
    HasSituationEvidence BIT NOT NULL,
    SituationLinkCount BIGINT NOT NULL
);

INSERT INTO #FactStateBeforeRepeat
SELECT
    DateKey,
    ServiceDate,
    ScheduledStopEventKey,
    TripKey,
    RouteKey,
    StopKey,
    ModeKey,
    ServiceKey,
    MatchStatus,
    FirstObservationKey,
    LastObservationKey,
    FirstObservedAtUtc,
    LastObservedAtUtc,
    ObservationCount,
    TimetabledArrivalUtc,
    FirstEstimatedArrivalUtc,
    LatestObservedEstimatedArrivalUtc,
    FirstObservedEstimatedDelayMinutes,
    FinalObservedEstimatedDelayMinutes,
    PlannedBay,
    LatestObservedEstimatedBay,
    PlatformChangeEvidence,
    HasSituationEvidence,
    SituationLinkCount
FROM dw.FactOperationalStopOutcome;

EXEC dw.uspRefreshFactOperationalStopOutcome;

CREATE TABLE #FactStateAfterFirstRepeat
(
    DateKey INT NOT NULL,
    ServiceDate DATE NOT NULL,
    ScheduledStopEventKey BIGINT NOT NULL,
    TripKey BIGINT NOT NULL,
    RouteKey INT NOT NULL,
    StopKey INT NOT NULL,
    ModeKey SMALLINT NOT NULL,
    ServiceKey INT NOT NULL,
    MatchStatus NVARCHAR(30) NOT NULL,
    FirstObservationKey BIGINT NOT NULL,
    LastObservationKey BIGINT NOT NULL,
    FirstObservedAtUtc DATETIME2(0) NOT NULL,
    LastObservedAtUtc DATETIME2(0) NOT NULL,
    ObservationCount BIGINT NOT NULL,
    TimetabledArrivalUtc DATETIME2(0) NOT NULL,
    FirstEstimatedArrivalUtc DATETIME2(0) NULL,
    LatestObservedEstimatedArrivalUtc DATETIME2(0) NULL,
    FirstObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    FinalObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    PlannedBay NVARCHAR(100) NULL,
    LatestObservedEstimatedBay NVARCHAR(100) NULL,
    PlatformChangeEvidence VARCHAR(20) NOT NULL,
    HasSituationEvidence BIT NOT NULL,
    SituationLinkCount BIGINT NOT NULL
);

INSERT INTO #FactStateAfterFirstRepeat
SELECT
    DateKey,
    ServiceDate,
    ScheduledStopEventKey,
    TripKey,
    RouteKey,
    StopKey,
    ModeKey,
    ServiceKey,
    MatchStatus,
    FirstObservationKey,
    LastObservationKey,
    FirstObservedAtUtc,
    LastObservedAtUtc,
    ObservationCount,
    TimetabledArrivalUtc,
    FirstEstimatedArrivalUtc,
    LatestObservedEstimatedArrivalUtc,
    FirstObservedEstimatedDelayMinutes,
    FinalObservedEstimatedDelayMinutes,
    PlannedBay,
    LatestObservedEstimatedBay,
    PlatformChangeEvidence,
    HasSituationEvidence,
    SituationLinkCount
FROM dw.FactOperationalStopOutcome;

EXEC dw.uspRefreshFactOperationalStopOutcome;

CREATE TABLE #FactStateAfterSecondRepeat
(
    DateKey INT NOT NULL,
    ServiceDate DATE NOT NULL,
    ScheduledStopEventKey BIGINT NOT NULL,
    TripKey BIGINT NOT NULL,
    RouteKey INT NOT NULL,
    StopKey INT NOT NULL,
    ModeKey SMALLINT NOT NULL,
    ServiceKey INT NOT NULL,
    MatchStatus NVARCHAR(30) NOT NULL,
    FirstObservationKey BIGINT NOT NULL,
    LastObservationKey BIGINT NOT NULL,
    FirstObservedAtUtc DATETIME2(0) NOT NULL,
    LastObservedAtUtc DATETIME2(0) NOT NULL,
    ObservationCount BIGINT NOT NULL,
    TimetabledArrivalUtc DATETIME2(0) NOT NULL,
    FirstEstimatedArrivalUtc DATETIME2(0) NULL,
    LatestObservedEstimatedArrivalUtc DATETIME2(0) NULL,
    FirstObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    FinalObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
    PlannedBay NVARCHAR(100) NULL,
    LatestObservedEstimatedBay NVARCHAR(100) NULL,
    PlatformChangeEvidence VARCHAR(20) NOT NULL,
    HasSituationEvidence BIT NOT NULL,
    SituationLinkCount BIGINT NOT NULL
);

INSERT INTO #FactStateAfterSecondRepeat
SELECT
    DateKey,
    ServiceDate,
    ScheduledStopEventKey,
    TripKey,
    RouteKey,
    StopKey,
    ModeKey,
    ServiceKey,
    MatchStatus,
    FirstObservationKey,
    LastObservationKey,
    FirstObservedAtUtc,
    LastObservedAtUtc,
    ObservationCount,
    TimetabledArrivalUtc,
    FirstEstimatedArrivalUtc,
    LatestObservedEstimatedArrivalUtc,
    FirstObservedEstimatedDelayMinutes,
    FinalObservedEstimatedDelayMinutes,
    PlannedBay,
    LatestObservedEstimatedBay,
    PlatformChangeEvidence,
    HasSituationEvidence,
    SituationLinkCount
FROM dw.FactOperationalStopOutcome;

SELECT
    comparison.CheckName,
    comparison.BeforeRows,
    comparison.AfterRows,
    comparison.DifferenceRows,
    CASE WHEN comparison.DifferenceRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT
        N'Fact state before first repeat vs after first repeat' AS CheckName,
        (SELECT COUNT_BIG(*) FROM #FactStateBeforeRepeat) AS BeforeRows,
        (SELECT COUNT_BIG(*) FROM #FactStateAfterFirstRepeat) AS AfterRows,
        (SELECT COUNT_BIG(*) FROM
            (
                SELECT * FROM #FactStateBeforeRepeat
                EXCEPT
                SELECT * FROM #FactStateAfterFirstRepeat
                UNION ALL
                SELECT * FROM #FactStateAfterFirstRepeat
                EXCEPT
                SELECT * FROM #FactStateBeforeRepeat
            ) AS difference_rows) AS DifferenceRows

    UNION ALL

    SELECT
        N'Fact state after first repeat vs after second repeat',
        (SELECT COUNT_BIG(*) FROM #FactStateAfterFirstRepeat),
        (SELECT COUNT_BIG(*) FROM #FactStateAfterSecondRepeat),
        (SELECT COUNT_BIG(*) FROM
            (
                SELECT * FROM #FactStateAfterFirstRepeat
                EXCEPT
                SELECT * FROM #FactStateAfterSecondRepeat
                UNION ALL
                SELECT * FROM #FactStateAfterSecondRepeat
                EXCEPT
                SELECT * FROM #FactStateAfterFirstRepeat
            ) AS difference_rows)
) AS comparison;
