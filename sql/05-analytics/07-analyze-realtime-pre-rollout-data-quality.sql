/*
    Read-only pre-rollout realtime data-quality analysis.

    Purpose:
      Establish the current seven-station baseline before any future
      50-station/tiered sampling activation and distinguish:
        - observation-grain static matching states; and
        - trip-grain Timing Unavailable outcomes.

    Re-run safety:
      This script creates only session-scoped temporary tables and indexes.
      It does not create or alter permanent objects, change data, execute a
      data-changing procedure, or modify Collector/sampling configuration.

    Result-set contract:
      1. M01 reconciliation
      2. static-match baseline and grain reconciliation
     3. source/fact freshness boundary diagnostic
     4. source-path/code/data evidence for StaticCoverageMissing lineage
     5. explicit StaticCoverageMissing lineage conclusion
     6. StaticCoverageMissing observation detail
     7. StaticCoverageMissing grouped diagnostics
     8. complete loaded-GTFS StaticCoverageMissing classification
     9. supporting no-current-rule-match label diagnostics
    10. Timing Unavailable root-cause summary
    11. every Timing Unavailable trip classification
    12. OtherOrInconsistent detail (if any)
    13. latest-observation-null pattern summary
    14. latest-observation-null sample
    15. date/mode/route breakdown
    16. station breakdown (distinct dated-trip grain; not additive overall)
    17. observation-density reconciliation
    18. future 50-station comparison rule
    19. Roadmap Item 3 compatibility-test scope limitation
*/

USE CologneTransitIntelligence;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS #MatchObservation;
DROP TABLE IF EXISTS #UsableMatchObservation;
DROP TABLE IF EXISTS #FactBoundary;
DROP TABLE IF EXISTS #FactBoundedUsableMatchObservation;
DROP TABLE IF EXISTS #RouteCoverage;
DROP TABLE IF EXISTS #LoadedGtfsRoute;
DROP TABLE IF EXISTS #ManagementComparableTrip;
DROP TABLE IF EXISTS #ManagementTripStation;
DROP TABLE IF EXISTS #UnavailableTripDiagnostics;
DROP TABLE IF EXISTS #UsableTripAggregate;
DROP TABLE IF EXISTS #OperationalTripAggregate;
DROP TABLE IF EXISTS #LatestNullPattern;
DROP TABLE IF EXISTS #StaticCoverageMissingLineClassification;

/*
    Materialize the current matching view once for all observation-level and
    source-lineage checks.  The columns below are intentionally limited to
    the diagnostic contract rather than copying the full view projection.
*/
SELECT
    match_view.ObservationKey,
    match_view.ObservedAtUtc,
    match_view.StopPointRef,
    match_view.StopName,
    match_view.LineName,
    match_view.LineRef,
    match_view.PtMode,
    match_view.RailSubmode,
    match_view.JourneyRef,
    match_view.StaticParentStationId,
    match_view.StaticStopMatched,
    match_view.TimetabledArrivalUtc,
    match_view.EstimatedArrivalUtc,
    match_view.MatchStatus,
    match_view.ExactStopCandidateCount,
    match_view.ParentStationCandidateCount,
    match_view.ScheduledStopEventKey,
    match_view.TripKey,
    match_view.RouteKey,
    match_view.StopKey,
    match_view.ModeKey,
    match_view.ServiceKey,
    match_view.DateKey,
    match_view.ServiceDate
INTO #MatchObservation
FROM wrk.vwCologneRealtimeTripMatch AS match_view;

CREATE UNIQUE CLUSTERED INDEX UX_MatchObservation_ObservationKey
    ON #MatchObservation (ObservationKey);

CREATE INDEX IX_MatchObservation_Status_Line_Stop_Date
    ON #MatchObservation
    (
        MatchStatus,
        LineName,
        StopPointRef,
        ObservedAtUtc
    );

CREATE INDEX IX_MatchObservation_Trip
    ON #MatchObservation
    (
        ServiceDate,
        TripKey,
        ScheduledStopEventKey,
        ObservedAtUtc,
        ObservationKey
    )
    INCLUDE (EstimatedArrivalUtc, MatchStatus);

SELECT
    observation.*
INTO #UsableMatchObservation
FROM #MatchObservation AS observation
WHERE observation.MatchStatus IN
(
    N'ExactStopMatch',
    N'ParentStationFallback'
);

CREATE UNIQUE CLUSTERED INDEX UX_UsableMatchObservation_ObservationKey
    ON #UsableMatchObservation (ObservationKey);

CREATE INDEX IX_UsableMatchObservation_Trip
    ON #UsableMatchObservation
    (
        ServiceDate,
        TripKey,
        ScheduledStopEventKey,
        ObservedAtUtc,
        ObservationKey
    )
    INCLUDE (EstimatedArrivalUtc, TimetabledArrivalUtc);

/*
    Current fact boundary for each dated scheduled stop event.  The live
    matching view can contain observations collected after this boundary;
    those rows are intentionally retained in #UsableMatchObservation for the
    freshness diagnostic but are excluded from fact-consistent diagnosis.
*/
SELECT
    outcome.ServiceDate,
    outcome.ScheduledStopEventKey,
    outcome.LastObservedAtUtc,
    outcome.LastObservationKey
INTO #FactBoundary
FROM dw.FactOperationalStopOutcome AS outcome;

CREATE UNIQUE CLUSTERED INDEX UX_FactBoundary_Date_StopEvent
    ON #FactBoundary (ServiceDate, ScheduledStopEventKey);

/*
    Only observations at or before the current fact boundary belong to the
    source state used to explain the current M01 population.  Ordering is the
    same deterministic (ObservedAtUtc, ObservationKey) ordering used by the
    operational refresh procedure.
*/
SELECT
    source_observation.*
INTO #FactBoundedUsableMatchObservation
FROM #UsableMatchObservation AS source_observation
INNER JOIN #FactBoundary AS fact_boundary
    ON fact_boundary.ServiceDate = source_observation.ServiceDate
   AND fact_boundary.ScheduledStopEventKey
        = source_observation.ScheduledStopEventKey
   AND
   (
        source_observation.ObservedAtUtc < fact_boundary.LastObservedAtUtc
        OR
        (
            source_observation.ObservedAtUtc = fact_boundary.LastObservedAtUtc
            AND source_observation.ObservationKey <= fact_boundary.LastObservationKey
        )
   );

CREATE UNIQUE CLUSTERED INDEX UX_FactBoundedUsableMatchObservation_ObservationKey
    ON #FactBoundedUsableMatchObservation (ObservationKey);

CREATE INDEX IX_FactBoundedUsableMatchObservation_Trip
    ON #FactBoundedUsableMatchObservation
    (
        ServiceDate,
        TripKey,
        ScheduledStopEventKey,
        ObservedAtUtc,
        ObservationKey
    )
    INCLUDE (EstimatedArrivalUtc, TimetabledArrivalUtc);

SELECT DISTINCT
    route.RouteId,
    route.RouteShortName,
    CONVERT(NVARCHAR(50), REPLACE(route.RouteShortName, N' ', N''))
        AS NormalizedRouteShortName
INTO #RouteCoverage
FROM wrk.vwCologneServingRoute AS route
WHERE route.RouteShortName IS NOT NULL;

CREATE INDEX IX_RouteCoverage_NormalizedName
    ON #RouteCoverage (NormalizedRouteShortName)
    INCLUDE (RouteId, RouteShortName);

/* Complete currently loaded GTFS route source, including routes outside Cologne. */
SELECT DISTINCT
    route.RouteId,
    route.AgencyId,
    agency.AgencyName,
    route.RouteShortName,
    route.RouteLongName,
    CONVERT(NVARCHAR(50), REPLACE(route.RouteShortName, N' ', N''))
        AS NormalizedRouteShortName
INTO #LoadedGtfsRoute
FROM stg.GtfsRoutes AS route
LEFT JOIN stg.GtfsAgency AS agency
    ON agency.AgencyId = route.AgencyId;

CREATE INDEX IX_LoadedGtfsRoute_NormalizedName
    ON #LoadedGtfsRoute (NormalizedRouteShortName)
    INCLUDE (RouteId, RouteShortName, RouteLongName, AgencyId, AgencyName);

CREATE INDEX IX_LoadedGtfsRoute_Identifiers
    ON #LoadedGtfsRoute (RouteId, RouteLongName, RouteShortName)
    INCLUDE (AgencyId, AgencyName, NormalizedRouteShortName);

/* M01 source at its published one-row-per-ServiceDate+TripKey grain. */
SELECT
    comparable.ManagementTripKey,
    comparable.DateKey,
    comparable.ServiceDate,
    comparable.TripKey,
    comparable.RouteKey,
    comparable.ModeKey,
    comparable.RouteName,
    comparable.Route,
    comparable.Mode,
    comparable.Station,
    comparable.StopKey,
    comparable.ScheduledArrival,
    comparable.LatestObservedEstimatedArrivalLocal,
    comparable.FinalObservedEstimatedDelayMinutes,
    comparable.LastObservedAtUtc,
    comparable.OperationalStopOutcomeKey,
    comparable.HasValidRealtimeObservation
INTO #ManagementComparableTrip
FROM analytics.vwManagementComparableTrip AS comparable;

CREATE UNIQUE CLUSTERED INDEX UX_ManagementComparableTrip_Date_Trip
    ON #ManagementComparableTrip (ServiceDate, TripKey);

/* Stop-position rows are used only for the non-additive station breakdown. */
SELECT
    trip_station.ManagementTripStationKey,
    trip_station.ManagementTripKey,
    trip_station.ServiceDate,
    trip_station.TripKey,
    trip_station.Station,
    trip_station.HasValidRealtimeObservation
INTO #ManagementTripStation
FROM analytics.vwManagementTripStation AS trip_station;

CREATE INDEX IX_ManagementTripStation_Station_Trip
    ON #ManagementTripStation (Station, ManagementTripKey)
    INCLUDE (ServiceDate, TripKey, HasValidRealtimeObservation);

/* Trip-level source-observation aggregate for unavailable-trip diagnosis. */
SELECT
    observation.ServiceDate,
    observation.TripKey,
    COUNT_BIG(*) AS UsableMatchedObservationCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN observation.EstimatedArrivalUtc IS NOT NULL
                 THEN 1 ELSE 0 END
        )
    ) AS UsableMatchedObservationWithEstimateCount,
    MIN(observation.ObservedAtUtc) AS FirstUsableObservationAtUtc,
    MAX(observation.ObservedAtUtc) AS LastUsableObservationAtUtc,
    COUNT_BIG(DISTINCT observation.ScheduledStopEventKey)
        AS UsableMatchedScheduledStopEventCount
INTO #UsableTripAggregate
FROM #FactBoundedUsableMatchObservation AS observation
WHERE observation.ServiceDate IS NOT NULL
  AND observation.TripKey IS NOT NULL
GROUP BY
    observation.ServiceDate,
    observation.TripKey;

CREATE UNIQUE CLUSTERED INDEX UX_UsableTripAggregate_Date_Trip
    ON #UsableTripAggregate (ServiceDate, TripKey);

/* All operational outcomes available to M01 for the dated trip. */
SELECT
    outcome.ServiceDate,
    outcome.TripKey,
    COUNT_BIG(*) AS OperationalOutcomeCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL
                 THEN 1 ELSE 0 END
        )
    ) AS OperationalOutcomeWithFinalDelayCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NULL
                 THEN 1 ELSE 0 END
        )
    ) AS OperationalOutcomeWithNullFinalDelayCount,
    MIN(outcome.FirstObservedAtUtc) AS FirstOperationalObservationAtUtc,
    MAX(outcome.LastObservedAtUtc) AS LastOperationalObservationAtUtc
INTO #OperationalTripAggregate
FROM dw.FactOperationalStopOutcome AS outcome
GROUP BY
    outcome.ServiceDate,
    outcome.TripKey;

CREATE UNIQUE CLUSTERED INDEX UX_OperationalTripAggregate_Date_Trip
    ON #OperationalTripAggregate (ServiceDate, TripKey);

/*
    Mutually exclusive Timing Unavailable categories.

    A: no usable matched source row for the dated trip ever carried an
       estimated arrival;
    B: a usable source estimate existed, but every operational outcome's
       selected final delay is NULL;
    C: anything else, retained for review rather than silently reclassified.
*/
SELECT
    comparable.ManagementTripKey,
    comparable.ServiceDate,
    comparable.TripKey,
    comparable.RouteName,
    comparable.Route,
    comparable.Mode,
    comparable.Station,
    comparable.StopKey,
    comparable.OperationalStopOutcomeKey,
    comparable.FinalObservedEstimatedDelayMinutes,
    comparable.LastObservedAtUtc,
    ISNULL(source_aggregate.UsableMatchedObservationCount, 0)
        AS UsableMatchedObservationCount,
    ISNULL(source_aggregate.UsableMatchedObservationWithEstimateCount, 0)
        AS UsableMatchedObservationWithEstimateCount,
    ISNULL(source_aggregate.UsableMatchedScheduledStopEventCount, 0)
        AS UsableMatchedScheduledStopEventCount,
    source_aggregate.FirstUsableObservationAtUtc,
    source_aggregate.LastUsableObservationAtUtc,
    ISNULL(outcome_aggregate.OperationalOutcomeCount, 0)
        AS OperationalOutcomeCount,
    ISNULL(outcome_aggregate.OperationalOutcomeWithFinalDelayCount, 0)
        AS OperationalOutcomeWithFinalDelayCount,
    ISNULL(outcome_aggregate.OperationalOutcomeWithNullFinalDelayCount, 0)
        AS OperationalOutcomeWithNullFinalDelayCount,
    CASE
        WHEN ISNULL(source_aggregate.UsableMatchedObservationWithEstimateCount, 0) = 0
            THEN N'NoEstimatedArrivalEverObserved'
        WHEN ISNULL(outcome_aggregate.OperationalOutcomeWithFinalDelayCount, 0) = 0
            THEN N'EstimateExistedEarlierButFinalTimingIsNull'
        ELSE N'OtherOrInconsistent'
    END AS RootCauseCategory
INTO #UnavailableTripDiagnostics
FROM #ManagementComparableTrip AS comparable
LEFT JOIN #UsableTripAggregate AS source_aggregate
    ON source_aggregate.ServiceDate = comparable.ServiceDate
   AND source_aggregate.TripKey = comparable.TripKey
LEFT JOIN #OperationalTripAggregate AS outcome_aggregate
    ON outcome_aggregate.ServiceDate = comparable.ServiceDate
   AND outcome_aggregate.TripKey = comparable.TripKey
WHERE comparable.HasValidRealtimeObservation = 0;

CREATE UNIQUE CLUSTERED INDEX UX_UnavailableTripDiagnostics_Date_Trip
    ON #UnavailableTripDiagnostics (ServiceDate, TripKey);

/*
    Identify the semantic pattern directly from the current latest row, not
    from FirstEstimatedArrivalUtc alone.  This catches cases where the first
    observation was NULL, a later observation had an estimate, and the final
    observation became NULL again.
*/
SELECT
    outcome.OperationalStopOutcomeKey,
    outcome.ServiceDate,
    outcome.ScheduledStopEventKey,
    outcome.TripKey,
    outcome.FirstObservedAtUtc,
    outcome.LastObservedAtUtc,
    outcome.ObservationCount,
    earlier.EarlierNonNullEstimatedArrivalUtc,
    final_observation.EstimatedArrivalUtc AS FinalEstimatedArrivalUtc,
    outcome.FinalObservedEstimatedDelayMinutes
INTO #LatestNullPattern
FROM dw.FactOperationalStopOutcome AS outcome
INNER JOIN #FactBoundedUsableMatchObservation AS final_observation
    ON final_observation.ObservationKey = outcome.LastObservationKey
   AND final_observation.EstimatedArrivalUtc IS NULL
OUTER APPLY
(
    SELECT TOP (1)
        earlier_observation.EstimatedArrivalUtc
            AS EarlierNonNullEstimatedArrivalUtc
    FROM #FactBoundedUsableMatchObservation AS earlier_observation
    WHERE earlier_observation.ServiceDate = outcome.ServiceDate
      AND earlier_observation.ScheduledStopEventKey
            = outcome.ScheduledStopEventKey
      AND
      (
            earlier_observation.ObservedAtUtc < outcome.LastObservedAtUtc
         OR
            (
                earlier_observation.ObservedAtUtc = outcome.LastObservedAtUtc
                AND earlier_observation.ObservationKey < outcome.LastObservationKey
            )
      )
      AND earlier_observation.EstimatedArrivalUtc IS NOT NULL
    ORDER BY
        earlier_observation.ObservedAtUtc,
        earlier_observation.ObservationKey
) AS earlier
WHERE earlier.EarlierNonNullEstimatedArrivalUtc IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_LatestNullPattern_Outcome
    ON #LatestNullPattern (OperationalStopOutcomeKey);

/* 1. Current full-period M01 reconciliation.  Rates are fractions [0,1]. */
SELECT
    MIN(comparable.ServiceDate) AS ServiceDateMin,
    MAX(comparable.ServiceDate) AS ServiceDateMax,
    COUNT_BIG(*) AS ComparableScheduledTrips,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN comparable.HasValidRealtimeObservation = 1
                 THEN 1 ELSE 0 END
        )
    ) AS TripsWithUsableRealtimeTiming,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN comparable.HasValidRealtimeObservation = 0
                 THEN 1 ELSE 0 END
        )
    ) AS TimingUnavailableTrips,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM
        (
            CONVERT
            (
                DECIMAL(28, 8),
                CASE WHEN comparable.HasValidRealtimeObservation = 0
                     THEN 1 ELSE 0 END
            )
        )
        / NULLIF(COUNT_BIG(*), 0)
    ) AS TimingUnavailableRate,
    CASE
        WHEN COUNT_BIG(*) =
             SUM
             (
                 CONVERT
                 (
                     BIGINT,
                     CASE WHEN comparable.HasValidRealtimeObservation = 1
                          THEN 1 ELSE 0 END
                 )
             )
             +
             SUM
             (
                 CONVERT
                 (
                     BIGINT,
                     CASE WHEN comparable.HasValidRealtimeObservation = 0
                          THEN 1 ELSE 0 END
                 )
             )
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS M01ReconciliationStatus,
    N'Trip grain: one row per ServiceDate + TripKey from analytics.vwManagementComparableTrip.'
        AS GrainNote
FROM #ManagementComparableTrip AS comparable;

/* 2. Current observation-level static coverage baseline. */
SELECT
    MIN(observation.ObservedAtUtc) AS ObservationDateTimeMin,
    MAX(observation.ObservedAtUtc) AS ObservationDateTimeMax,
    COUNT_BIG(*) AS TotalRealtimeObservations,
    SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus = N'ExactStopMatch'
                             THEN 1 ELSE 0 END)) AS ExactStopMatchCount,
    SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus = N'ParentStationFallback'
                             THEN 1 ELSE 0 END)) AS ParentStationFallbackCount,
    SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus = N'StaticCoverageMissing'
                             THEN 1 ELSE 0 END)) AS StaticCoverageMissingCount,
    SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus = N'Unresolved'
                             THEN 1 ELSE 0 END)) AS UnresolvedCount,
    SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus IN
                             (N'ExactStopMatch', N'ParentStationFallback')
                             THEN 1 ELSE 0 END)) AS UsableStaticMatchCount,
    (
        SELECT COUNT_BIG(*)
        FROM
        (
            SELECT DISTINCT
                affected_line.LineName
            FROM #MatchObservation AS affected_line
            WHERE affected_line.MatchStatus = N'StaticCoverageMissing'
        ) AS distinct_affected_line
    ) AS StaticCoverageMissingDistinctLineNameCount,
    COUNT_BIG
    (
        DISTINCT CASE WHEN observation.MatchStatus = N'StaticCoverageMissing'
                      THEN observation.StopPointRef END
    ) AS StaticCoverageMissingAffectedStopPointCount,
    CONVERT(DECIMAL(18, 8),
        SUM(CONVERT(DECIMAL(28, 8), CASE WHEN observation.MatchStatus = N'ExactStopMatch'
                                        THEN 1 ELSE 0 END))
        / NULLIF(COUNT_BIG(*), 0)) AS ExactStopMatchRate,
    CONVERT(DECIMAL(18, 8),
        SUM(CONVERT(DECIMAL(28, 8), CASE WHEN observation.MatchStatus = N'ParentStationFallback'
                                        THEN 1 ELSE 0 END))
        / NULLIF(COUNT_BIG(*), 0)) AS ParentStationFallbackRate,
    CONVERT(DECIMAL(18, 8),
        SUM(CONVERT(DECIMAL(28, 8), CASE WHEN observation.MatchStatus = N'StaticCoverageMissing'
                                        THEN 1 ELSE 0 END))
        / NULLIF(COUNT_BIG(*), 0)) AS StaticCoverageMissingRate,
    CONVERT(DECIMAL(18, 8),
        SUM(CONVERT(DECIMAL(28, 8), CASE WHEN observation.MatchStatus = N'Unresolved'
                                        THEN 1 ELSE 0 END))
        / NULLIF(COUNT_BIG(*), 0)) AS UnresolvedRate,
    CONVERT(DECIMAL(18, 8),
        SUM(CONVERT(DECIMAL(28, 8), CASE WHEN observation.MatchStatus IN
                                         (N'ExactStopMatch', N'ParentStationFallback')
                                        THEN 1 ELSE 0 END))
        / NULLIF(COUNT_BIG(*), 0)) AS UsableStaticMatchRate,
    CASE
        WHEN COUNT_BIG(*) =
             SUM(CONVERT(BIGINT, CASE WHEN observation.MatchStatus IN
                                      (N'ExactStopMatch', N'ParentStationFallback',
                                       N'StaticCoverageMissing', N'Unresolved')
                                     THEN 1 ELSE 0 END))
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS MatchStatusReconciliationStatus,
    N'Observation grain: one row per wrk.vwCologneRealtimeTripMatch observation; not comparable to the trip-grain M01 counts.'
        AS GrainNote
FROM #MatchObservation AS observation;

/* 3. Source/fact freshness boundary diagnostic. */
SELECT
    (SELECT MAX(observation.ObservedAtUtc)
     FROM #MatchObservation AS observation)
        AS CurrentRealtimeObservationMaxUtc,
    (SELECT MAX(observation.ObservedAtUtc)
     FROM #UsableMatchObservation AS observation)
        AS CurrentUsableObservationMaxUtc,
    (SELECT MAX(fact_boundary.LastObservedAtUtc)
     FROM #FactBoundary AS fact_boundary)
        AS OperationalFactLastObservedMaxUtc,
    (
        SELECT COUNT_BIG(*)
        FROM #UsableMatchObservation AS source_observation
        INNER JOIN #FactBoundary AS fact_boundary
            ON fact_boundary.ServiceDate = source_observation.ServiceDate
           AND fact_boundary.ScheduledStopEventKey
                = source_observation.ScheduledStopEventKey
        WHERE source_observation.ObservedAtUtc > fact_boundary.LastObservedAtUtc
           OR
           (
                source_observation.ObservedAtUtc = fact_boundary.LastObservedAtUtc
                AND source_observation.ObservationKey > fact_boundary.LastObservationKey
           )
    ) AS LiveUsableObservationsBeyondExistingFactBoundaryCount,
    (
        SELECT COUNT_BIG(*)
        FROM #UsableMatchObservation AS source_observation
        LEFT JOIN #FactBoundary AS fact_boundary
            ON fact_boundary.ServiceDate = source_observation.ServiceDate
           AND fact_boundary.ScheduledStopEventKey
                = source_observation.ScheduledStopEventKey
        WHERE fact_boundary.ServiceDate IS NULL
          AND fact_boundary.ScheduledStopEventKey IS NULL
    ) AS LiveUsableObservationsWithoutFactBoundaryCount,
    (
        (
            SELECT COUNT_BIG(*)
            FROM #UsableMatchObservation AS source_observation
            INNER JOIN #FactBoundary AS fact_boundary
                ON fact_boundary.ServiceDate = source_observation.ServiceDate
               AND fact_boundary.ScheduledStopEventKey
                    = source_observation.ScheduledStopEventKey
            WHERE source_observation.ObservedAtUtc > fact_boundary.LastObservedAtUtc
               OR
               (
                    source_observation.ObservedAtUtc = fact_boundary.LastObservedAtUtc
                    AND source_observation.ObservationKey > fact_boundary.LastObservationKey
               )
        )
        +
        (
            SELECT COUNT_BIG(*)
            FROM #UsableMatchObservation AS source_observation
            LEFT JOIN #FactBoundary AS fact_boundary
                ON fact_boundary.ServiceDate = source_observation.ServiceDate
               AND fact_boundary.ScheduledStopEventKey
                    = source_observation.ScheduledStopEventKey
            WHERE fact_boundary.ServiceDate IS NULL
              AND fact_boundary.ScheduledStopEventKey IS NULL
        )
    ) AS LiveUsableObservationsNotRepresentedInFactCount,
    N'Root-cause and observation-density source aggregates use only usable observations at or before the matching fact row boundary ordered by ObservedAtUtc, ObservationKey.'
        AS BoundaryRule;

/* 4. Prove the StaticCoverageMissing/Timing Unavailable source path. */
WITH ProcedureEvidence AS
(
    SELECT
        OBJECT_DEFINITION
        (
            OBJECT_ID(N'dw.uspRefreshFactOperationalStopOutcome', N'P')
        ) AS ProcedureDefinition
),
ConstraintEvidence AS
(
    SELECT TOP (1)
        check_constraint.definition AS ConstraintDefinition
    FROM sys.check_constraints AS check_constraint
    INNER JOIN sys.tables AS table_object
        ON table_object.object_id = check_constraint.parent_object_id
    INNER JOIN sys.schemas AS schema_object
        ON schema_object.schema_id = table_object.schema_id
    WHERE schema_object.name = N'dw'
      AND table_object.name = N'FactOperationalStopOutcome'
      AND check_constraint.name = N'CK_dw_FactOperationalStopOutcome_MatchStatus'
)
SELECT
    N'Code' AS EvidenceType,
    N'dw.uspRefreshFactOperationalStopOutcome' AS SourceObject,
    CASE
        WHEN CHARINDEX(N'MatchStatus IN', evidence.ProcedureDefinition) > 0
         AND CHARINDEX(N'ExactStopMatch', evidence.ProcedureDefinition) > 0
         AND CHARINDEX(N'ParentStationFallback', evidence.ProcedureDefinition) > 0
         AND CHARINDEX(N'StaticCoverageMissing', evidence.ProcedureDefinition) = 0
         AND CHARINDEX(N'Unresolved', evidence.ProcedureDefinition) = 0
            THEN N'PASS: the load filter names only ExactStopMatch and ParentStationFallback.'
        ELSE N'REVIEW: current procedure text does not match the expected two-status load filter.'
    END AS Evidence,
    CAST(NULL AS BIGINT) AS ObservationCount,
    CAST(NULL AS BIGINT) AS FactOutcomeCount
FROM ProcedureEvidence AS evidence
UNION ALL
SELECT
    N'Code' AS EvidenceType,
    N'dw.FactOperationalStopOutcome' AS SourceObject,
    CASE
        WHEN CHARINDEX(N'ExactStopMatch', evidence.ConstraintDefinition) > 0
         AND CHARINDEX(N'ParentStationFallback', evidence.ConstraintDefinition) > 0
         AND CHARINDEX(N'StaticCoverageMissing', evidence.ConstraintDefinition) = 0
         AND CHARINDEX(N'Unresolved', evidence.ConstraintDefinition) = 0
            THEN N'PASS: the fact constraint permits only the two usable match statuses.'
        ELSE N'REVIEW: fact MatchStatus constraint should be inspected.'
    END AS Evidence,
    CAST(NULL AS BIGINT) AS ObservationCount,
    CAST(NULL AS BIGINT) AS FactOutcomeCount
FROM ConstraintEvidence AS evidence
UNION ALL
SELECT
    N'Actual data' AS EvidenceType,
    N'wrk.vwCologneRealtimeTripMatch' AS SourceObject,
    observation.MatchStatus AS Evidence,
    COUNT_BIG(*) AS ObservationCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN fact_link.OperationalStopOutcomeKey IS NOT NULL
                 THEN 1 ELSE 0 END
        )
    ) AS FactOutcomeCount
FROM #MatchObservation AS observation
LEFT JOIN
(
    SELECT
        fact.OperationalStopOutcomeKey,
        fact.FirstObservationKey AS ObservationKey
    FROM dw.FactOperationalStopOutcome AS fact
    UNION
    SELECT
        fact.OperationalStopOutcomeKey,
        fact.LastObservationKey AS ObservationKey
    FROM dw.FactOperationalStopOutcome AS fact
) AS fact_link
    ON fact_link.ObservationKey = observation.ObservationKey
GROUP BY observation.MatchStatus;

SELECT
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM #MatchObservation AS observation
            INNER JOIN
            (
                SELECT fact.FirstObservationKey AS ObservationKey
                FROM dw.FactOperationalStopOutcome AS fact
                UNION
                SELECT fact.LastObservationKey AS ObservationKey
                FROM dw.FactOperationalStopOutcome AS fact
            ) AS fact_observation
                ON fact_observation.ObservationKey = observation.ObservationKey
            WHERE observation.MatchStatus IN
            (N'StaticCoverageMissing', N'Unresolved')
        )
            THEN N'REVIEW'
        ELSE N'NO'
    END AS StaticCoverageMissingDirectlyContributesToTimingUnavailable,
    N'StaticCoverageMissing and Unresolved do not enter FactOperationalStopOutcome or M01 TimingUnavailableTrips, but they reduce the usable realtime matching population before the Timing Unavailable stage.'
        AS Conclusion,
    N'Actual lineage test checks FirstObservationKey/LastObservationKey against the current matched view.'
        AS ActualDataCheck;

/* 6. Every current StaticCoverageMissing observation. */
SELECT
    observation.ObservationKey,
    observation.ObservedAtUtc,
    CONVERT(DATE, observation.ObservedAtUtc) AS CollectionDateUtc,
    observation.ServiceDate,
    observation.StopPointRef,
    observation.StopName,
    observation.LineName,
    observation.LineRef,
    observation.PtMode,
    observation.RailSubmode,
    observation.ExactStopCandidateCount,
    observation.ParentStationCandidateCount,
    observation.StaticParentStationId,
    observation.StaticStopMatched
FROM #MatchObservation AS observation
WHERE observation.MatchStatus = N'StaticCoverageMissing'
ORDER BY
    observation.ObservedAtUtc,
    observation.ObservationKey;

/* 7. Grouped StaticCoverageMissing diagnostics by line/stop/date. */
SELECT
    observation.LineName,
    observation.StopPointRef,
    CONVERT(DATE, observation.ObservedAtUtc) AS CollectionDateUtc,
    observation.ServiceDate,
    observation.StopName,
    observation.LineRef,
    observation.PtMode,
    observation.RailSubmode,
    COUNT_BIG(*) AS StaticCoverageMissingObservationCount,
    MIN(observation.ObservedAtUtc) AS FirstObservedAtUtc,
    MAX(observation.ObservedAtUtc) AS LastObservedAtUtc
FROM #MatchObservation AS observation
WHERE observation.MatchStatus = N'StaticCoverageMissing'
GROUP BY
    observation.LineName,
    observation.StopPointRef,
    CONVERT(DATE, observation.ObservedAtUtc),
    observation.ServiceDate,
    observation.StopName,
    observation.LineRef,
    observation.PtMode,
    observation.RailSubmode
ORDER BY
    observation.LineName,
    observation.StopPointRef,
    CollectionDateUtc;

/*
    8. Complete StaticCoverageMissing classification.

    The first comparison preserves the exact current production rule.  The
    second comparison is against all loaded GTFS routes, not only the Cologne
    serving scope.  No fuzzy or identifier-based comparison is used to alter
    the source MatchStatus.
*/
WITH AffectedLines AS
(
    SELECT
        observation.LineName,
        COUNT_BIG(*) AS StaticCoverageMissingObservationCount,
        COUNT_BIG(DISTINCT observation.StopPointRef)
            AS AffectedStopPointCount,
        MIN(observation.ObservedAtUtc) AS FirstObservedAtUtc,
        MAX(observation.ObservedAtUtc) AS LastObservedAtUtc
    FROM #MatchObservation AS observation
    WHERE observation.MatchStatus = N'StaticCoverageMissing'
    GROUP BY observation.LineName
)
SELECT
    affected.LineName AS RealtimeLineName,
    (
        SELECT STRING_AGG
        (
            CONVERT(NVARCHAR(MAX), line_ref.LineRef) COLLATE DATABASE_DEFAULT,
            N', ' COLLATE DATABASE_DEFAULT
        )
        FROM
        (
            SELECT DISTINCT
                NULLIF(LTRIM(RTRIM(observation.LineRef)), N'') AS LineRef
            FROM #MatchObservation AS observation
            WHERE observation.MatchStatus = N'StaticCoverageMissing'
              AND ISNULL(observation.LineName, N'') = ISNULL(affected.LineName, N'')
        ) AS line_ref
    ) AS RealtimeLineRef,
    REPLACE(affected.LineName, N' ', N'') AS NormalizedRealtimeLineName,
    scope_evidence.ExistsInCologneServingScopeUnderCurrentRule,
    gtfs_evidence.ExistsAnywhereInLoadedGtfsUnderCurrentRule,
    (
        SELECT STRING_AGG
        (
            CONVERT(NVARCHAR(MAX), route_id.RouteId) COLLATE DATABASE_DEFAULT,
            N', ' COLLATE DATABASE_DEFAULT
        )
        FROM
        (
            SELECT DISTINCT route.RouteId
            FROM #LoadedGtfsRoute AS route
            WHERE route.NormalizedRouteShortName =
                  REPLACE(affected.LineName, N' ', N'')
        ) AS route_id
    ) AS MatchingGtfsRouteIds,
    (
        SELECT STRING_AGG
        (
            CONVERT(NVARCHAR(MAX), route_name.RouteShortName) COLLATE DATABASE_DEFAULT,
            N', ' COLLATE DATABASE_DEFAULT
        )
        FROM
        (
            SELECT DISTINCT route.RouteShortName
            FROM #LoadedGtfsRoute AS route
            WHERE route.NormalizedRouteShortName =
                  REPLACE(affected.LineName, N' ', N'')
        ) AS route_name
    ) AS MatchingGtfsRouteShortNames,
    (
        SELECT STRING_AGG
        (
            CONVERT(NVARCHAR(MAX), route_name.RouteLongName) COLLATE DATABASE_DEFAULT,
            N', ' COLLATE DATABASE_DEFAULT
        )
        FROM
        (
            SELECT DISTINCT route.RouteLongName
            FROM #LoadedGtfsRoute AS route
            WHERE route.NormalizedRouteShortName =
                  REPLACE(affected.LineName, N' ', N'')
        ) AS route_name
    ) AS MatchingGtfsRouteLongNames,
    (
        SELECT STRING_AGG
        (
            CONVERT
            (
                NVARCHAR(MAX),
                CONCAT
                (
                    COALESCE(NULLIF(LTRIM(RTRIM(route.AgencyId)), N''), N'(no agency id)'),
                    CASE
                        WHEN NULLIF(LTRIM(RTRIM(route.AgencyName)), N'') IS NOT NULL
                            THEN CONCAT(N' — ', LTRIM(RTRIM(route.AgencyName)))
                        ELSE N''
                    END
                )
            ) COLLATE DATABASE_DEFAULT,
            N', ' COLLATE DATABASE_DEFAULT
        )
        FROM
        (
            SELECT DISTINCT route.AgencyId, route.AgencyName
            FROM #LoadedGtfsRoute AS route
            WHERE route.NormalizedRouteShortName =
                  REPLACE(affected.LineName, N' ', N'')
        ) AS route
    ) AS MatchingAgencies,
    CASE
        WHEN scope_evidence.ExistsInCologneServingScopeUnderCurrentRule = 1
            THEN N'UnexpectedCurrentRuleInconsistency'
        WHEN gtfs_evidence.ExistsAnywhereInLoadedGtfsUnderCurrentRule = 1
            THEN N'PresentInGtfsButOutsideCologneServingScope'
        ELSE N'NotFoundInLoadedGtfsUnderCurrentRule'
    END AS DiagnosticCategory,
    affected.StaticCoverageMissingObservationCount,
    affected.AffectedStopPointCount,
    affected.FirstObservedAtUtc,
    affected.LastObservedAtUtc,
    N'Current rule: REPLACE(realtime LineName, spaces) must equal REPLACE(static RouteShortName, spaces).' AS RouteCoverageRule
INTO #StaticCoverageMissingLineClassification
FROM AffectedLines AS affected
CROSS APPLY
(
    SELECT
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #RouteCoverage AS route
                WHERE route.NormalizedRouteShortName =
                      REPLACE(affected.LineName, N' ', N'')
            ) THEN 1 ELSE 0 END
        ) AS ExistsInCologneServingScopeUnderCurrentRule
) AS scope_evidence
CROSS APPLY
(
    SELECT
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #LoadedGtfsRoute AS route
                WHERE route.NormalizedRouteShortName =
                      REPLACE(affected.LineName, N' ', N'')
            ) THEN 1 ELSE 0 END
        ) AS ExistsAnywhereInLoadedGtfsUnderCurrentRule
) AS gtfs_evidence;

CREATE UNIQUE CLUSTERED INDEX UX_StaticCoverageMissingLineClassification
    ON #StaticCoverageMissingLineClassification (RealtimeLineName);

/* 8.1 Reconcile the complete distinct affected-line classification. */
SELECT
    (
        SELECT COUNT_BIG(*)
        FROM
        (
            SELECT DISTINCT
                observation.LineName
            FROM #MatchObservation AS observation
            WHERE observation.MatchStatus = N'StaticCoverageMissing'
        ) AS distinct_affected_line
    ) AS StaticCoverageMissingDistinctLineNameCount,
    COUNT_BIG(*) AS CompleteDistinctAffectedLineClassificationCount,
    CASE
        WHEN
        (
            SELECT COUNT_BIG(*)
            FROM
            (
                SELECT DISTINCT
                    observation.LineName
                FROM #MatchObservation AS observation
                WHERE observation.MatchStatus = N'StaticCoverageMissing'
            ) AS distinct_affected_line
        ) = COUNT_BIG(*)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS StaticCoverageMissingDistinctLineClassificationReconciliationStatus,
    N'Complete classification is one row per distinct realtime LineName, including one NULL group when NULL LineName observations exist.'
        AS ReconciliationDefinition
FROM #StaticCoverageMissingLineClassification AS classification;

/* 8. Full distinct affected-line classification and category counts. */
SELECT
    classification.RealtimeLineName,
    classification.RealtimeLineRef,
    classification.NormalizedRealtimeLineName,
    classification.StaticCoverageMissingObservationCount,
    classification.AffectedStopPointCount,
    classification.ExistsInCologneServingScopeUnderCurrentRule,
    classification.ExistsAnywhereInLoadedGtfsUnderCurrentRule,
    classification.MatchingGtfsRouteIds,
    classification.MatchingGtfsRouteShortNames,
    classification.MatchingGtfsRouteLongNames,
    classification.MatchingAgencies,
    classification.DiagnosticCategory,
    classification.FirstObservedAtUtc,
    classification.LastObservedAtUtc,
    classification.RouteCoverageRule
FROM #StaticCoverageMissingLineClassification AS classification
ORDER BY
    classification.RealtimeLineName;

WITH Categories AS
(
    SELECT category.CategoryOrder, category.CategoryName
    FROM
    (
        VALUES
            (1, N'PresentInGtfsButOutsideCologneServingScope'),
            (2, N'NotFoundInLoadedGtfsUnderCurrentRule'),
            (3, N'UnexpectedCurrentRuleInconsistency')
    ) AS category(CategoryOrder, CategoryName)
), LineCounts AS
(
    SELECT
        classification.DiagnosticCategory,
        COUNT_BIG(*) AS DistinctRealtimeLineCount,
        SUM(classification.StaticCoverageMissingObservationCount)
            AS StaticCoverageMissingObservationCount
    FROM #StaticCoverageMissingLineClassification AS classification
    GROUP BY classification.DiagnosticCategory
), StopCounts AS
(
    SELECT
        classification.DiagnosticCategory,
        COUNT_BIG(DISTINCT observation.StopPointRef)
            AS AffectedStopPointCount
    FROM #StaticCoverageMissingLineClassification AS classification
    INNER JOIN #MatchObservation AS observation
        ON observation.MatchStatus = N'StaticCoverageMissing'
       AND
       (
            classification.RealtimeLineName = observation.LineName
            OR
            (
                classification.RealtimeLineName IS NULL
                AND observation.LineName IS NULL
            )
       )
    GROUP BY classification.DiagnosticCategory
)
SELECT
    categories.CategoryName AS DiagnosticCategory,
    ISNULL(line_counts.DistinctRealtimeLineCount, 0) AS DistinctRealtimeLineCount,
    ISNULL(line_counts.StaticCoverageMissingObservationCount, 0)
        AS StaticCoverageMissingObservationCount,
    ISNULL(stop_counts.AffectedStopPointCount, 0) AS AffectedStopPointCount,
    CASE
        WHEN
        (
            SELECT COUNT_BIG(*)
            FROM #StaticCoverageMissingLineClassification
        ) =
        (
            SELECT ISNULL(SUM(line_counts_inner.DistinctRealtimeLineCount), 0)
            FROM LineCounts AS line_counts_inner
        )
        THEN N'PASS'
        ELSE N'REVIEW'
    END AS CategoryReconciliationStatus
FROM Categories AS categories
LEFT JOIN LineCounts AS line_counts
    ON line_counts.DiagnosticCategory = categories.CategoryName
LEFT JOIN StopCounts AS stop_counts
    ON stop_counts.DiagnosticCategory = categories.CategoryName
ORDER BY categories.CategoryOrder;

/* Top affected lines, retained separately from the complete classification. */
SELECT TOP (25)
    classification.RealtimeLineName,
    classification.RealtimeLineRef,
    classification.StaticCoverageMissingObservationCount,
    classification.AffectedStopPointCount,
    classification.DiagnosticCategory,
    classification.MatchingGtfsRouteIds,
    classification.MatchingGtfsRouteShortNames,
    classification.MatchingGtfsRouteLongNames,
    classification.MatchingAgencies
FROM #StaticCoverageMissingLineClassification AS classification
ORDER BY
    classification.StaticCoverageMissingObservationCount DESC,
    classification.RealtimeLineName;

/* 9. Supporting identifiers for lines with no current-rule GTFS match. */
WITH NotFoundLabels AS
(
    SELECT
        observation.LineName,
        observation.LineRef,
        observation.PtMode,
        observation.RailSubmode,
        COUNT_BIG(*) AS StaticCoverageMissingObservationCount,
        COUNT_BIG(DISTINCT observation.StopPointRef) AS AffectedStopPointCount
    FROM #MatchObservation AS observation
    INNER JOIN #StaticCoverageMissingLineClassification AS classification
        ON ISNULL(classification.RealtimeLineName, N'') COLLATE DATABASE_DEFAULT
             = ISNULL(observation.LineName, N'') COLLATE DATABASE_DEFAULT
       AND classification.DiagnosticCategory = N'NotFoundInLoadedGtfsUnderCurrentRule'
    WHERE observation.MatchStatus = N'StaticCoverageMissing'
    GROUP BY
        observation.LineName,
        observation.LineRef,
        observation.PtMode,
        observation.RailSubmode
)
SELECT
    labels.LineName,
    labels.LineRef,
    labels.PtMode,
    labels.RailSubmode,
    labels.StaticCoverageMissingObservationCount,
    labels.AffectedStopPointCount,
    stop_refs.GroupedStopPointRefs,
    CONVERT
    (
        BIT,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM #LoadedGtfsRoute AS route
            WHERE route.RouteId COLLATE DATABASE_DEFAULT
                    = labels.LineRef COLLATE DATABASE_DEFAULT
        ) THEN 1 ELSE 0 END
    ) AS LineRefExactlyEqualsGtfsRouteId,
    CONVERT
    (
        BIT,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM #LoadedGtfsRoute AS route
            WHERE NULLIF(LTRIM(RTRIM(labels.LineName)), N'') COLLATE DATABASE_DEFAULT =
                  NULLIF(LTRIM(RTRIM(route.RouteLongName)), N'') COLLATE DATABASE_DEFAULT
        ) THEN 1 ELSE 0 END
    ) AS LineNameExactlyEqualsTrimmedGtfsRouteLongName,
    CONVERT
    (
        BIT,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM #LoadedGtfsRoute AS route
            WHERE NULLIF(LTRIM(RTRIM(labels.LineName)), N'') COLLATE DATABASE_DEFAULT =
                  NULLIF(LTRIM(RTRIM(route.RouteShortName)), N'') COLLATE DATABASE_DEFAULT
        ) THEN 1 ELSE 0 END
    ) AS LineNameExactlyEqualsTrimmedGtfsRouteShortName
FROM NotFoundLabels AS labels
OUTER APPLY
(
    SELECT STRING_AGG
    (
        CONVERT(NVARCHAR(MAX), stop_ref.StopPointRef) COLLATE DATABASE_DEFAULT,
        N', ' COLLATE DATABASE_DEFAULT
    ) AS GroupedStopPointRefs
    FROM
    (
        SELECT DISTINCT observation.StopPointRef
        FROM #MatchObservation AS observation
        WHERE observation.MatchStatus = N'StaticCoverageMissing'
          AND ISNULL(observation.LineName, N'') = ISNULL(labels.LineName, N'')
          AND ISNULL(observation.LineRef, N'') = ISNULL(labels.LineRef, N'')
          AND ISNULL(observation.PtMode, N'') = ISNULL(labels.PtMode, N'')
          AND ISNULL(observation.RailSubmode, N'') = ISNULL(labels.RailSubmode, N'')
    ) AS stop_ref
) AS stop_refs
ORDER BY
    labels.LineName,
    labels.LineRef,
    labels.PtMode,
    labels.RailSubmode;

/* 10. Root-cause category counts; percentages use TimingUnavailableTrips. */
WITH Categories AS
(
    SELECT category.CategoryOrder, category.CategoryName
    FROM
    (
        VALUES
            (1, N'NoEstimatedArrivalEverObserved'),
            (2, N'EstimateExistedEarlierButFinalTimingIsNull'),
            (3, N'OtherOrInconsistent')
    ) AS category(CategoryOrder, CategoryName)
), Counts AS
(
    SELECT
        diagnostic.RootCauseCategory,
        COUNT_BIG(*) AS TripCount
    FROM #UnavailableTripDiagnostics AS diagnostic
    GROUP BY diagnostic.RootCauseCategory
)
SELECT
    categories.CategoryName AS Category,
    ISNULL(counts.TripCount, 0) AS TripCount,
    CONVERT
    (
        DECIMAL(18, 8),
        CONVERT(DECIMAL(28, 8), ISNULL(counts.TripCount, 0))
        / NULLIF((SELECT COUNT_BIG(*) FROM #UnavailableTripDiagnostics), 0)
    ) AS PercentageOfTimingUnavailableTrips,
    CASE
        WHEN
        (
            SELECT COUNT_BIG(*) FROM #UnavailableTripDiagnostics
        ) =
        (
            SELECT ISNULL(SUM(counts_inner.TripCount), 0)
            FROM Counts AS counts_inner
        )
        THEN N'PASS'
        ELSE N'REVIEW'
    END AS CategoryReconciliationStatus
FROM Categories AS categories
LEFT JOIN Counts AS counts
    ON counts.RootCauseCategory = categories.CategoryName
ORDER BY categories.CategoryOrder;

/* 11. Complete trip-level classification for all Timing Unavailable trips. */
SELECT
    diagnostic.ServiceDate,
    diagnostic.ManagementTripKey,
    diagnostic.TripKey,
    diagnostic.RouteName,
    diagnostic.Route,
    diagnostic.Mode,
    diagnostic.Station,
    diagnostic.StopKey,
    diagnostic.OperationalStopOutcomeKey,
    diagnostic.FinalObservedEstimatedDelayMinutes,
    diagnostic.LastObservedAtUtc,
    diagnostic.UsableMatchedObservationCount,
    diagnostic.UsableMatchedObservationWithEstimateCount,
    diagnostic.UsableMatchedScheduledStopEventCount,
    diagnostic.FirstUsableObservationAtUtc,
    diagnostic.LastUsableObservationAtUtc,
    diagnostic.OperationalOutcomeCount,
    diagnostic.OperationalOutcomeWithFinalDelayCount,
    diagnostic.OperationalOutcomeWithNullFinalDelayCount,
    diagnostic.RootCauseCategory
FROM #UnavailableTripDiagnostics AS diagnostic
ORDER BY
    diagnostic.ServiceDate,
    diagnostic.TripKey;

/* 12. C-category detail is intentionally non-empty only when inconsistent. */
SELECT
    diagnostic.ServiceDate,
    diagnostic.ManagementTripKey,
    diagnostic.TripKey,
    diagnostic.RouteName,
    diagnostic.Route,
    diagnostic.Mode,
    diagnostic.Station,
    diagnostic.UsableMatchedObservationCount,
    diagnostic.UsableMatchedObservationWithEstimateCount,
    diagnostic.OperationalOutcomeCount,
    diagnostic.OperationalOutcomeWithFinalDelayCount,
    diagnostic.OperationalOutcomeWithNullFinalDelayCount,
    diagnostic.RootCauseCategory
FROM #UnavailableTripDiagnostics AS diagnostic
WHERE diagnostic.RootCauseCategory = N'OtherOrInconsistent'
ORDER BY
    diagnostic.ServiceDate,
    diagnostic.TripKey;

/* 13. Latest observation became NULL summary. */
SELECT
    COUNT_BIG(*) AS AffectedOperationalStopOutcomeCount,
    (
        SELECT COUNT_BIG(*)
        FROM
        (
            SELECT DISTINCT
                dated_pattern.ServiceDate,
                dated_pattern.TripKey
            FROM #LatestNullPattern AS dated_pattern
        ) AS dated_trip
    ) AS AffectedDistinctDatedTripCount,
    CASE WHEN COUNT_BIG(*) = 0 THEN N'NO' ELSE N'YES' END
        AS PatternExists,
    N'Pattern is an earlier usable non-NULL EstimatedArrivalUtc followed by a later/final usable observation with EstimatedArrivalUtc IS NULL for the same dated ScheduledStopEventKey.'
        AS PatternDefinition
FROM #LatestNullPattern AS pattern;

/* 14. Small diagnostic sample for the latest-observation-null pattern. */
SELECT TOP (25)
    pattern.ServiceDate,
    pattern.TripKey,
    pattern.ScheduledStopEventKey,
    COALESCE(parent_stop.StopName, stop.StopName) AS Station,
    route.RouteShortName AS LineRoute,
    pattern.FirstObservedAtUtc,
    pattern.LastObservedAtUtc,
    pattern.EarlierNonNullEstimatedArrivalUtc,
    pattern.FinalEstimatedArrivalUtc,
    pattern.FinalObservedEstimatedDelayMinutes
FROM #LatestNullPattern AS pattern
INNER JOIN dw.FactOperationalStopOutcome AS outcome
    ON outcome.OperationalStopOutcomeKey = pattern.OperationalStopOutcomeKey
INNER JOIN dw.DimStop AS stop
    ON stop.StopKey = outcome.StopKey
LEFT JOIN dw.DimStop AS parent_stop
    ON parent_stop.StopKey = stop.ParentStopKey
INNER JOIN dw.DimRoute AS route
    ON route.RouteKey = outcome.RouteKey
ORDER BY
    pattern.ServiceDate,
    pattern.TripKey,
    pattern.ScheduledStopEventKey;

/* 15. Trip-grain breakdown by service date, mode, and route. */
SELECT
    comparable.ServiceDate,
    comparable.Mode,
    comparable.RouteName,
    comparable.Route,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CONVERT(BIGINT, CASE WHEN comparable.HasValidRealtimeObservation = 1
                             THEN 1 ELSE 0 END)) AS UsableTimingTripCount,
    SUM(CONVERT(BIGINT, CASE WHEN comparable.HasValidRealtimeObservation = 0
                             THEN 1 ELSE 0 END)) AS TimingUnavailableTripCount,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM
        (
            CONVERT
            (
                DECIMAL(28, 8),
                CASE WHEN comparable.HasValidRealtimeObservation = 0
                     THEN 1 ELSE 0 END
            )
        ) / NULLIF(COUNT_BIG(*), 0)
    ) AS TimingUnavailableRate
FROM #ManagementComparableTrip AS comparable
GROUP BY
    comparable.ServiceDate,
    comparable.Mode,
    comparable.RouteName,
    comparable.Route
ORDER BY
    comparable.ServiceDate,
    comparable.Mode,
    comparable.RouteName;

/* 16. Station attribution is distinct dated-trip grain and is non-additive. */
SELECT
    trip_station.Station,
    CONVERT
    (
        BIT,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM analytics.vwManagementMonitoredStation AS monitored
            WHERE monitored.MonitoredStationName = trip_station.Station
        ) THEN 1 ELSE 0 END
    ) AS IsCurrentMonitoredStationName,
    COUNT_BIG(DISTINCT trip_station.ManagementTripKey)
        AS ComparableTripCount,
    COUNT_BIG
    (
        DISTINCT CASE WHEN trip_station.HasValidRealtimeObservation = 1
                      THEN trip_station.ManagementTripKey END
    ) AS UsableTimingTripCount,
    COUNT_BIG
    (
        DISTINCT CASE WHEN trip_station.HasValidRealtimeObservation = 0
                      THEN trip_station.ManagementTripKey END
    ) AS TimingUnavailableTripCount,
    CONVERT
    (
        DECIMAL(18, 8),
        CONVERT
        (
            DECIMAL(28, 8),
            COUNT_BIG
            (
                DISTINCT CASE WHEN trip_station.HasValidRealtimeObservation = 0
                              THEN trip_station.ManagementTripKey END
            )
        )
        / NULLIF
        (
            COUNT_BIG(DISTINCT trip_station.ManagementTripKey),
            0
        )
    ) AS TimingUnavailableRate,
    N'Station rows use DISTINCT ManagementTripKey, but one dated trip may appear at more than one monitored station; do not sum station rows as a unique overall-trip total.'
        AS GrainNote
FROM #ManagementTripStation AS trip_station
GROUP BY trip_station.Station
ORDER BY trip_station.Station;

/* 17. Observation density before dated-stop-event consolidation. */
SELECT
    SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount = 0
                             THEN 1 ELSE 0 END))
        AS TimingUnavailableTripsWithZeroMatchedObservation,
    SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount = 1
                             THEN 1 ELSE 0 END))
        AS TimingUnavailableTripsWithOneMatchedObservation,
    SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount > 1
                             THEN 1 ELSE 0 END))
        AS TimingUnavailableTripsWithMultipleMatchedObservations,
    COUNT_BIG(*) AS TimingUnavailableTrips,
    CASE
        WHEN COUNT_BIG(*) =
             SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount = 0
                                      THEN 1 ELSE 0 END))
             +
             SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount = 1
                                      THEN 1 ELSE 0 END))
             +
             SUM(CONVERT(BIGINT, CASE WHEN diagnostic.UsableMatchedObservationCount > 1
                                      THEN 1 ELSE 0 END))
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS ObservationDensityReconciliationStatus,
    N'Count is at dated-trip grain across all usable ExactStopMatch and ParentStationFallback observations before operational consolidation.'
        AS GrainNote
FROM #UnavailableTripDiagnostics AS diagnostic;

/* 18. Consistent seven-to-50 comparison rule; no arbitrary threshold. */
SELECT
    N'Pre/post quality comparison rule' AS RuleName,
    N'Absolute TimingUnavailableTrips is sensitive to monitored volume and may increase when the panel expands.' AS ComparisonRule,
    N'Compare TimingUnavailableRate and the root-cause distribution alongside absolute TimingUnavailableTrips.' AS RequiredComparison,
    N'Also compare StaticCoverageMissingRate, UnresolvedRate, and UsableStaticMatchRate before and after the future 50-station pilot.' AS StaticCoverageComparison,
    N'No arbitrary acceptable percentage threshold is defined by this diagnostic.' AS ThresholdRule;

/* 19. Roadmap Item 3 compatibility-test scope limitation. */
SELECT
    N'Roadmap Item 3 compatibility test' AS AnalysisArea,
    N'Validated' AS ScopeStatus,
    N'HTTP reachability, TRIAS parsing, requested ParentStationId/StopPointRef compatibility, static parent-station metadata, and returned current event availability.' AS EvidenceScope,
    N'Did not validate the complete realtime event -> static route -> scheduled trip -> scheduled stop event matching chain.' AS Limitation,
    N'docs/25-REALTIME-50-STATION-MDD-COMPATIBILITY.md and collector/Test-MddRealtimePanelCompatibility.ps1' AS Source;
