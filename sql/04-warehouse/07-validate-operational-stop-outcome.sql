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
;WITH OrderedUsableObservation AS
(
    SELECT
        match_view.DateKey,
        match_view.ServiceDate,
        match_view.ScheduledStopEventKey,
        match_view.ObservationKey,
        match_view.ObservedAtUtc,
        ROW_NUMBER() OVER
        (
            PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
            ORDER BY match_view.ObservedAtUtc ASC, match_view.ObservationKey ASC
        ) AS FirstOrdinal,
        ROW_NUMBER() OVER
        (
            PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
            ORDER BY match_view.ObservedAtUtc DESC, match_view.ObservationKey DESC
        ) AS LatestOrdinal
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
),
SourceConsolidation AS
(
    SELECT
        ordered_observation.DateKey,
        ordered_observation.ServiceDate,
        ordered_observation.ScheduledStopEventKey,
        COUNT_BIG(*) AS SourceObservationCount,
        MAX(CASE WHEN ordered_observation.FirstOrdinal = 1
                 THEN ordered_observation.ObservationKey END)
            AS EarliestSourceObservationKey,
        MAX(CASE WHEN ordered_observation.LatestOrdinal = 1
                 THEN ordered_observation.ObservationKey END)
            AS LatestSourceObservationKey,
        MAX(CASE WHEN ordered_observation.FirstOrdinal = 1
                 THEN ordered_observation.ObservedAtUtc END)
            AS EarliestSourceObservedAtUtc,
        MAX(CASE WHEN ordered_observation.LatestOrdinal = 1
                 THEN ordered_observation.ObservedAtUtc END)
            AS LatestSourceObservedAtUtc
    FROM OrderedUsableObservation AS ordered_observation
    GROUP BY
        ordered_observation.DateKey,
        ordered_observation.ServiceDate,
        ordered_observation.ScheduledStopEventKey
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

/* 5. First/latest source lineage must use the production ordering rule. */
;WITH OrderedSource AS
(
    SELECT
        match_view.DateKey,
        match_view.ScheduledStopEventKey,
        match_view.ObservationKey,
        match_view.ObservedAtUtc,
        ROW_NUMBER() OVER
        (
            PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
            ORDER BY match_view.ObservedAtUtc ASC, match_view.ObservationKey ASC
        ) AS FirstOrdinal,
        ROW_NUMBER() OVER
        (
            PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
            ORDER BY match_view.ObservedAtUtc DESC, match_view.ObservationKey DESC
        ) AS LatestOrdinal
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
),
SourceLineage AS
(
    SELECT
        ordered_source.DateKey,
        ordered_source.ScheduledStopEventKey,
        MAX(CASE WHEN ordered_source.FirstOrdinal = 1
                 THEN ordered_source.ObservationKey END)
            AS FirstSourceObservationKey,
        MAX(CASE WHEN ordered_source.LatestOrdinal = 1
                 THEN ordered_source.ObservationKey END)
            AS LatestSourceObservationKey,
        MAX(CASE WHEN ordered_source.FirstOrdinal = 1
                 THEN ordered_source.ObservedAtUtc END)
            AS FirstSourceObservedAtUtc,
        MAX(CASE WHEN ordered_source.LatestOrdinal = 1
                 THEN ordered_source.ObservedAtUtc END)
            AS LatestSourceObservedAtUtc
    FROM OrderedSource AS ordered_source
    GROUP BY ordered_source.DateKey, ordered_source.ScheduledStopEventKey
)
SELECT
    COALESCE(SUM
    (
        CASE WHEN outcome.FirstObservationKey <> source_lineage.FirstSourceObservationKey
                   OR outcome.FirstObservedAtUtc <> source_lineage.FirstSourceObservedAtUtc
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END
    ), 0) AS FirstObservationLineageViolations,
    COALESCE(SUM
    (
        CASE WHEN outcome.LastObservationKey <> source_lineage.LatestSourceObservationKey
                   OR outcome.LastObservedAtUtc <> source_lineage.LatestSourceObservedAtUtc
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END
    ), 0) AS LatestObservationLineageViolations,
    CASE WHEN COALESCE(SUM
    (
        CASE WHEN outcome.FirstObservationKey <> source_lineage.FirstSourceObservationKey
                   OR outcome.FirstObservedAtUtc <> source_lineage.FirstSourceObservedAtUtc
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END
    ), 0) = 0
       AND COALESCE(SUM
    (
        CASE WHEN outcome.LastObservationKey <> source_lineage.LatestSourceObservationKey
                   OR outcome.LastObservedAtUtc <> source_lineage.LatestSourceObservedAtUtc
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END
    ), 0) = 0
         THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM SourceLineage AS source_lineage
JOIN dw.FactOperationalStopOutcome AS outcome
    ON outcome.DateKey = source_lineage.DateKey
   AND outcome.ScheduledStopEventKey = source_lineage.ScheduledStopEventKey;

SELECT
    COUNT_BIG(*) AS ConsolidatedOutcomeOrderingViolations,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM dw.FactOperationalStopOutcome AS outcome
WHERE outcome.ObservationCount > 1
  AND
  (
      outcome.LastObservedAtUtc < outcome.FirstObservedAtUtc
      OR
      (
          outcome.LastObservedAtUtc = outcome.FirstObservedAtUtc
          AND outcome.LastObservationKey < outcome.FirstObservationKey
      )
  );

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

/* 8. Static-reload compatibility and post-reload reconciliation. */
;WITH LatestStaticLoad AS
(
    SELECT TOP (1)
        load_batch.WarehouseLoadBatchId,
        load_batch.Status,
        load_batch.CompletedAtUtc,
        load_batch.AgencyRows,
        load_batch.ModeRows,
        load_batch.RouteRows,
        load_batch.StopRows,
        load_batch.ServiceRows,
        load_batch.DateRows,
        load_batch.ServiceDateRows,
        load_batch.TripRows,
        load_batch.ScheduledStopEventRows
    FROM ctl.StaticWarehouseLoadBatch AS load_batch
    ORDER BY load_batch.WarehouseLoadBatchId DESC
)
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT
        N'Latest static warehouse load completed' AS CheckName,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM LatestStaticLoad
            WHERE Status IN ('Loaded', 'Validated')
              AND CompletedAtUtc IS NOT NULL
        )
        THEN CONVERT(BIGINT, 0) ELSE CONVERT(BIGINT, 1) END AS FailedRows

    UNION ALL

    SELECT
        N'Latest static warehouse row counts reconcile' AS CheckName,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM LatestStaticLoad
            WHERE Status IN ('Loaded', 'Validated')
              AND AgencyRows = (SELECT COUNT_BIG(*) FROM dw.DimAgency)
              AND ModeRows = (SELECT COUNT_BIG(*) FROM dw.DimMode)
              AND RouteRows = (SELECT COUNT_BIG(*) FROM dw.DimRoute)
              AND StopRows = (SELECT COUNT_BIG(*) FROM dw.DimStop)
              AND ServiceRows = (SELECT COUNT_BIG(*) FROM dw.DimService)
              AND DateRows = (SELECT COUNT_BIG(*) FROM dw.DimDate)
              AND ServiceDateRows = (SELECT COUNT_BIG(*) FROM dw.BridgeServiceDate)
              AND TripRows = (SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip)
              AND ScheduledStopEventRows =
                  (SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent)
        )
        THEN CONVERT(BIGINT, 0) ELSE CONVERT(BIGINT, 1) END
) AS check_result
ORDER BY check_result.CheckName;

SELECT
    fk.name AS ForeignKeyName,
    fk.is_disabled AS IsDisabled,
    fk.is_not_trusted AS IsNotTrusted,
    CASE WHEN fk.is_disabled = 0 AND fk.is_not_trusted = 0
         THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM sys.foreign_keys AS fk
WHERE fk.parent_object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
ORDER BY fk.name;

SELECT
    COUNT_BIG(*) AS FactForeignKeyCount,
    COALESCE(SUM(CASE WHEN fk.is_disabled = 1 THEN CONVERT(BIGINT, 1)
                      ELSE CONVERT(BIGINT, 0) END), 0)
        AS DisabledForeignKeyCount,
    COALESCE(SUM(CASE WHEN fk.is_not_trusted = 1 THEN CONVERT(BIGINT, 1)
                      ELSE CONVERT(BIGINT, 0) END), 0)
        AS UntrustedForeignKeyCount,
    CASE WHEN COUNT_BIG(*) = 9
               AND COALESCE(SUM(CASE WHEN fk.is_disabled = 1 THEN 1 ELSE 0 END), 0) = 0
               AND COALESCE(SUM(CASE WHEN fk.is_not_trusted = 1 THEN 1 ELSE 0 END), 0) = 0
         THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM sys.foreign_keys AS fk
WHERE fk.parent_object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome');

;WITH CurrentUsableGrain AS
(
    SELECT
        match_view.DateKey,
        match_view.ScheduledStopEventKey
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    WHERE match_view.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
    GROUP BY match_view.DateKey, match_view.ScheduledStopEventKey
),
FactGrain AS
(
    SELECT
        outcome.DateKey,
        outcome.ScheduledStopEventKey
    FROM dw.FactOperationalStopOutcome AS outcome
    GROUP BY outcome.DateKey, outcome.ScheduledStopEventKey
),
GrainDifferences AS
(
    SELECT
        missing.DateKey,
        missing.ScheduledStopEventKey,
        N'Missing operational outcome for current usable match' AS DifferenceType
    FROM
    (
        SELECT DateKey, ScheduledStopEventKey
        FROM CurrentUsableGrain
        EXCEPT
        SELECT DateKey, ScheduledStopEventKey
        FROM FactGrain
    ) AS missing

    UNION ALL

    SELECT
        stale.DateKey,
        stale.ScheduledStopEventKey,
        N'Stale operational outcome without current usable match'
    FROM
    (
        SELECT DateKey, ScheduledStopEventKey
        FROM FactGrain
        EXCEPT
        SELECT DateKey, ScheduledStopEventKey
        FROM CurrentUsableGrain
    ) AS stale
)
SELECT
    (SELECT COUNT_BIG(*) FROM CurrentUsableGrain)
        AS CurrentUsableMatchGrainCount,
    (SELECT COUNT_BIG(*) FROM FactGrain)
        AS OperationalFactGrainCount,
    (SELECT COUNT_BIG(*) FROM GrainDifferences)
        AS GrainDifferenceCount,
    CASE WHEN (SELECT COUNT_BIG(*) FROM GrainDifferences) = 0
         THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus;

SELECT
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation)
        AS RealtimeStopObservationCount,
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeSituationObservation)
        AS RealtimeSituationObservationCount,
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopSituationLink)
        AS RealtimeStopSituationLinkCount,
    (SELECT COUNT_BIG(*) FROM ctl.MddCollectorRun)
        AS CollectorRunCount,
    N'Append-only realtime source counts are reported for comparison with the pre-reload capture.'
        AS SourceHistoryNote;
