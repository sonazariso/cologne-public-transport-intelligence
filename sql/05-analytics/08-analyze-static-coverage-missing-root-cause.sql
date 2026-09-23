/*
    Read-only StaticCoverageMissing root-cause investigation.

    Scope:
      Diagnose the current production matching chain without changing
      MatchStatus, Collector behavior, warehouse semantics, or sampling.

    The current production condition is preserved as evidence:
      wrk.vwCologneRealtimeTripMatch returns StaticCoverageMissing when the
      normalized realtime line name is not present in the normalized
      RouteShortName set derived from wrk.vwCologneServingRoute.

    All tables in this script are session-scoped temporary tables.  The
    schedule-independent candidate tests deliberately do not join LineName
    or RouteShortName when finding static scheduled-stop candidates.
*/

USE CologneTransitIntelligence;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS #Observation;
DROP TABLE IF EXISTS #StaticCoverageMissing;
DROP TABLE IF EXISTS #GtfsRoute;
DROP TABLE IF EXISTS #ServingRoute;
DROP TABLE IF EXISTS #GtfsTrip;
DROP TABLE IF EXISTS #RouteEvidence;
DROP TABLE IF EXISTS #RouteEvidenceSummary;
DROP TABLE IF EXISTS #ScheduleCandidateAll;
DROP TABLE IF EXISTS #ScheduleCandidate;
DROP TABLE IF EXISTS #ScheduleSummary;
DROP TABLE IF EXISTS #CandidateEvidenceSummary;
DROP TABLE IF EXISTS #IdentifierEvidence;
DROP TABLE IF EXISTS #DiagnosticObservation;
DROP TABLE IF EXISTS #RootCause;
DROP TABLE IF EXISTS #StrategyObservation;

/* 1. Materialize the current production match view once. */
SELECT
    match_view.ObservationKey,
    match_view.ObservedAtUtc,
    match_view.ResultId,
    match_view.StopPointRef,
    match_view.StopName,
    match_view.LineName,
    match_view.LineRef,
    match_view.JourneyRef,
    match_view.DirectionRef,
    match_view.OperatorRef,
    match_view.PtMode,
    match_view.RailSubmode,
    match_view.TimetabledArrivalUtc,
    match_view.EstimatedArrivalUtc,
    match_view.PlannedBay,
    match_view.EstimatedBay,
    match_view.StaticParentStationId,
    match_view.AnalyticalParentStationId,
    match_view.AnalyticalParentStationName,
    match_view.StaticStopMatched,
    match_view.TimetabledArrivalLocal,
    match_view.ServiceDateLocal,
    match_view.ScheduledArrivalSecondsLocal,
    match_view.ExactStopCandidateCount,
    match_view.ParentStationCandidateCount,
    match_view.MatchStatus,
    match_view.IsInAnalyticalTransportScope,
    match_view.AnalyticalTransportScopeReason,
    match_view.MatchedTripId,
    match_view.MatchedRouteId,
    match_view.MatchedServiceId,
    match_view.MatchedStaticStopId,
    match_view.ScheduledStopEventKey,
    match_view.TripKey,
    match_view.RouteKey,
    match_view.StopKey,
    match_view.ModeKey,
    match_view.ServiceKey,
    match_view.DateKey,
    match_view.ServiceDate
INTO #Observation
FROM wrk.vwCologneRealtimeTripMatchScoped AS match_view;

CREATE UNIQUE CLUSTERED INDEX UX_Observation_ObservationKey
    ON #Observation (ObservationKey);

CREATE INDEX IX_Observation_Status_Stop_Time
    ON #Observation (MatchStatus, StopPointRef, ScheduledArrivalSecondsLocal, ServiceDateLocal)
    INCLUDE (LineName, LineRef, JourneyRef, StaticParentStationId, TimetabledArrivalUtc);

SELECT
    observation.*
INTO #StaticCoverageMissing
FROM #Observation AS observation
WHERE observation.MatchStatus = N'StaticCoverageMissing';

CREATE UNIQUE CLUSTERED INDEX UX_StaticCoverageMissing_ObservationKey
    ON #StaticCoverageMissing (ObservationKey);

CREATE INDEX IX_StaticCoverageMissing_Line
    ON #StaticCoverageMissing (LineName, StopPointRef)
    INCLUDE (LineRef, JourneyRef, TimetabledArrivalUtc, ServiceDateLocal);

/* 2. Loaded GTFS identifiers and current serving-route identifiers. */
SELECT DISTINCT
    route.RouteId,
    route.AgencyId,
    NULLIF(route.RouteShortName, N'') AS RouteShortName,
    NULLIF(route.RouteLongName, N'') AS RouteLongName,
    NULLIF(route.RouteDesc, N'') AS RouteDesc,
    route.RouteType,
    agency.AgencyName,
    NULLIF(LTRIM(RTRIM(route.RouteShortName)), N'') AS TrimmedRouteShortName,
    NULLIF(LTRIM(RTRIM(route.RouteLongName)), N'') AS TrimmedRouteLongName,
    CONVERT(NVARCHAR(4000), REPLACE(route.RouteShortName, N' ', N''))
        AS SpaceNormalizedRouteShortName,
    CONVERT(NVARCHAR(4000), REPLACE(route.RouteLongName, N' ', N''))
        AS SpaceNormalizedRouteLongName,
    TRY_CONVERT(INT, NULLIF(route.RouteType, N'')) AS RouteTypeCode
INTO #GtfsRoute
FROM stg.GtfsRoutes AS route
LEFT JOIN stg.GtfsAgency AS agency
    ON agency.AgencyId = route.AgencyId
WHERE NULLIF(LTRIM(RTRIM(route.RouteId)), N'') IS NOT NULL;

CREATE INDEX IX_GtfsRoute_RouteId
    ON #GtfsRoute (RouteId)
    INCLUDE (AgencyId, RouteShortName, RouteLongName, AgencyName, RouteTypeCode);

SELECT DISTINCT
    route.RouteId,
    route.AgencyId,
    route.AgencyName,
    route.RouteShortName,
    route.RouteLongName,
    route.RouteTypeCode,
    route.ModeGroup,
    route.ModeDetail,
    NULLIF(LTRIM(RTRIM(route.RouteShortName)), N'') AS TrimmedRouteShortName,
    CONVERT(NVARCHAR(4000), REPLACE(route.RouteShortName, N' ', N''))
        AS SpaceNormalizedRouteShortName
INTO #ServingRoute
FROM wrk.vwCologneServingRoute AS route;

SELECT DISTINCT
    trip.RouteId,
    trip.ServiceId,
    trip.TripId,
    trip.TripHeadsign,
    trip.DirectionId,
    NULLIF(LTRIM(RTRIM(trip.DirectionId)), N'') AS DirectionIdText,
    trip.BlockId,
    trip.ShapeId
INTO #GtfsTrip
FROM stg.GtfsTrips AS trip
WHERE NULLIF(LTRIM(RTRIM(trip.TripId)), N'') IS NOT NULL;

CREATE INDEX IX_GtfsTrip_TripId
    ON #GtfsTrip (TripId)
    INCLUDE (RouteId, ServiceId, DirectionIdText, TripHeadsign);

CREATE INDEX IX_GtfsTrip_Route
    ON #GtfsTrip (RouteId)
    INCLUDE (TripId, ServiceId, DirectionIdText, TripHeadsign);

/*
    3. Deterministic identifier evidence for every current observation.
    EvidenceType E is included to prove the current production short-name
    rule against both the complete loaded route set and the Cologne-serving
    route set.  A-D are diagnostic alternatives only.
*/
SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    NULL AS ModeGroup,
    NULL AS ModeDetail
INTO #RouteEvidence
FROM #Observation AS observation
INNER JOIN #GtfsRoute AS route
    ON route.RouteId COLLATE DATABASE_DEFAULT
         = observation.LineRef COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'LineRefEqualsRouteId')) AS evidence(EvidenceType)
WHERE observation.LineRef IS NOT NULL

UNION ALL

SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    NULL AS ModeGroup,
    NULL AS ModeDetail
FROM #Observation AS observation
INNER JOIN #GtfsRoute AS route
    ON NULLIF(LTRIM(RTRIM(observation.LineName)), N'') COLLATE DATABASE_DEFAULT
         = route.TrimmedRouteLongName COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'TrimmedLineNameEqualsRouteLongName')) AS evidence(EvidenceType)

UNION ALL

SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    NULL AS ModeGroup,
    NULL AS ModeDetail
FROM #Observation AS observation
INNER JOIN #GtfsRoute AS route
    ON REPLACE(observation.LineName, N' ', N'') COLLATE DATABASE_DEFAULT
         = route.SpaceNormalizedRouteLongName COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'SpaceNormalizedLineNameEqualsRouteLongName')) AS evidence(EvidenceType)

UNION ALL

SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    NULL AS ModeGroup,
    NULL AS ModeDetail
FROM #Observation AS observation
INNER JOIN #GtfsRoute AS route
    ON NULLIF(LTRIM(RTRIM(observation.LineName)), N'') COLLATE DATABASE_DEFAULT
         = route.TrimmedRouteShortName COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'TrimmedLineNameEqualsRouteShortName')) AS evidence(EvidenceType)

UNION ALL

SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    NULL AS ModeGroup,
    NULL AS ModeDetail
FROM #Observation AS observation
INNER JOIN #GtfsRoute AS route
    ON REPLACE(observation.LineName, N' ', N'') COLLATE DATABASE_DEFAULT
         = route.SpaceNormalizedRouteShortName COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'CurrentRuleLoadedRouteShortName')) AS evidence(EvidenceType)

UNION ALL

SELECT DISTINCT
    observation.ObservationKey,
    observation.LineName,
    observation.LineRef,
    evidence.EvidenceType,
    route.RouteId,
    route.AgencyId,
    route.RouteShortName,
    route.RouteLongName,
    route.AgencyName,
    route.RouteTypeCode,
    route.ModeGroup,
    route.ModeDetail
FROM #Observation AS observation
INNER JOIN #ServingRoute AS route
    ON REPLACE(observation.LineName, N' ', N'') COLLATE DATABASE_DEFAULT
         = route.SpaceNormalizedRouteShortName COLLATE DATABASE_DEFAULT
CROSS APPLY (VALUES (N'CurrentRuleCologneServingRouteShortName')) AS evidence(EvidenceType);

CREATE INDEX IX_RouteEvidence_ObservationType
    ON #RouteEvidence (ObservationKey, EvidenceType, RouteId)
    INCLUDE (AgencyId, RouteShortName, RouteLongName, AgencyName);

SELECT
    observation.ObservationKey,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'LineRefEqualsRouteId'
                            THEN evidence.RouteId END) AS LineRefRouteIdCount,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'TrimmedLineNameEqualsRouteLongName'
                            THEN evidence.RouteId END) AS TrimmedLineNameRouteLongNameCount,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'SpaceNormalizedLineNameEqualsRouteLongName'
                            THEN evidence.RouteId END) AS SpaceNormalizedLineNameRouteLongNameCount,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'TrimmedLineNameEqualsRouteShortName'
                            THEN evidence.RouteId END) AS TrimmedLineNameRouteShortNameCount,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'CurrentRuleLoadedRouteShortName'
                            THEN evidence.RouteId END) AS CurrentRuleLoadedRouteShortNameCount,
    COUNT_BIG(DISTINCT CASE WHEN evidence.EvidenceType = N'CurrentRuleCologneServingRouteShortName'
                            THEN evidence.RouteId END) AS CurrentRuleCologneServingRouteShortNameCount
INTO #RouteEvidenceSummary
FROM #Observation AS observation
LEFT JOIN #RouteEvidence AS evidence
    ON evidence.ObservationKey = observation.ObservationKey
GROUP BY observation.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_RouteEvidenceSummary_ObservationKey
    ON #RouteEvidenceSummary (ObservationKey);

/*
    4. Route-independent scheduled-stop candidates.
    This joins only stop, local scheduled time, service date, and warehouse
    schedule keys.  No LineName, LineRef, RouteShortName, or RouteLongName is
    used to find the candidate set.
*/
SELECT DISTINCT
    observation.ObservationKey,
    scheduled_event.ScheduledStopEventKey,
    route.RouteId,
    route.RouteShortName,
    route.RouteLongName,
    agency.AgencyId,
    trip.TripId,
    trip.TripHeadsign,
    trip.DirectionId,
    service.ServiceId,
    date_dimension.DateValue AS ServiceDate,
    stop.StopId,
    stop.ParentStationId,
    scheduled_event.ScheduledArrivalTimeText,
    scheduled_event.ScheduledArrivalSeconds,
    scheduled_event.ArrivalDayOffset,
    mode.ModeGroup,
    mode.ModeDetail,
    CONVERT
    (
        BIT,
        CASE WHEN stop.StopId COLLATE DATABASE_DEFAULT
                   = observation.StopPointRef COLLATE DATABASE_DEFAULT
             THEN 1 ELSE 0 END
    ) AS IsExactStopCandidate,
    CONVERT
    (
        BIT,
        CASE WHEN observation.StaticParentStationId IS NOT NULL
                   AND stop.ParentStationId COLLATE DATABASE_DEFAULT
                       = observation.StaticParentStationId COLLATE DATABASE_DEFAULT
             THEN 1 ELSE 0 END
    ) AS IsParentStationCandidate
INTO #ScheduleCandidateAll
FROM #Observation AS observation
INNER JOIN dw.FactScheduledStopEvent AS scheduled_event
    ON scheduled_event.ScheduledArrivalSecondOfDay
         = observation.ScheduledArrivalSecondsLocal
INNER JOIN dw.FactScheduledTrip AS trip
    ON trip.TripKey = scheduled_event.TripKey
INNER JOIN dw.DimRoute AS route
    ON route.RouteKey = scheduled_event.RouteKey
INNER JOIN dw.DimAgency AS agency
    ON agency.AgencyKey = scheduled_event.AgencyKey
INNER JOIN dw.DimStop AS stop
    ON stop.StopKey = scheduled_event.StopKey
INNER JOIN dw.DimMode AS mode
    ON mode.ModeKey = scheduled_event.ModeKey
INNER JOIN dw.DimService AS service
    ON service.ServiceKey = scheduled_event.ServiceKey
INNER JOIN dw.BridgeServiceDate AS bridge_service_date
    ON bridge_service_date.ServiceKey = service.ServiceKey
INNER JOIN dw.DimDate AS date_dimension
    ON date_dimension.DateKey = bridge_service_date.DateKey
   AND date_dimension.DateValue = DATEADD
       (
           DAY,
           -scheduled_event.ArrivalDayOffset,
           observation.ServiceDateLocal
       )
WHERE observation.ScheduledArrivalSecondsLocal IS NOT NULL
  AND observation.ServiceDateLocal IS NOT NULL
  AND
  (
      stop.StopId COLLATE DATABASE_DEFAULT
          = observation.StopPointRef COLLATE DATABASE_DEFAULT
      OR
      (
          observation.StaticParentStationId IS NOT NULL
          AND stop.ParentStationId COLLATE DATABASE_DEFAULT
              = observation.StaticParentStationId COLLATE DATABASE_DEFAULT
      )
  );

CREATE INDEX IX_ScheduleCandidateAll_Observation
    ON #ScheduleCandidateAll (ObservationKey, IsExactStopCandidate, IsParentStationCandidate)
    INCLUDE (ScheduledStopEventKey, RouteId, TripId, ServiceId, StopId, ServiceDate);

SELECT
    candidate.*
INTO #ScheduleCandidate
FROM #ScheduleCandidateAll AS candidate
WHERE
(
    candidate.IsExactStopCandidate = 1
    AND EXISTS
    (
        SELECT 1
        FROM #ScheduleCandidateAll AS exact_candidate
        WHERE exact_candidate.ObservationKey = candidate.ObservationKey
          AND exact_candidate.IsExactStopCandidate = 1
    )
)
OR
(
    candidate.IsExactStopCandidate = 0
    AND candidate.IsParentStationCandidate = 1
    AND NOT EXISTS
    (
        SELECT 1
        FROM #ScheduleCandidateAll AS exact_candidate
        WHERE exact_candidate.ObservationKey = candidate.ObservationKey
          AND exact_candidate.IsExactStopCandidate = 1
    )
);

CREATE UNIQUE CLUSTERED INDEX UX_ScheduleCandidate_ObservationEvent
    ON #ScheduleCandidate (ObservationKey, ScheduledStopEventKey);

SELECT
    observation.ObservationKey,
    COUNT_BIG(DISTINCT candidate.ScheduledStopEventKey) AS ScheduleCandidateCount,
    COUNT_BIG(DISTINCT candidate.RouteId) AS ScheduleCandidateRouteCount,
    COUNT_BIG(DISTINCT candidate.TripId) AS ScheduleCandidateTripCount,
    CASE
        WHEN COUNT_BIG(DISTINCT candidate.ScheduledStopEventKey) = 0
            THEN N'NoScheduleCandidate'
        WHEN COUNT_BIG(DISTINCT candidate.ScheduledStopEventKey) = 1
            THEN N'ExactlyOneScheduleCandidate'
        ELSE N'MultipleScheduleCandidates'
    END AS ScheduleCandidateClassification
INTO #ScheduleSummary
FROM #Observation AS observation
LEFT JOIN #ScheduleCandidate AS candidate
    ON candidate.ObservationKey = observation.ObservationKey
GROUP BY observation.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_ScheduleSummary_ObservationKey
    ON #ScheduleSummary (ObservationKey);

SELECT
    observation.ObservationKey,
    COUNT_BIG(DISTINCT CASE WHEN candidate.RouteId COLLATE DATABASE_DEFAULT
                                      = observation.LineRef COLLATE DATABASE_DEFAULT
                            THEN candidate.RouteId END) AS AfterLineRefRouteIdCount,
    COUNT_BIG(DISTINCT CASE WHEN candidate.TripId COLLATE DATABASE_DEFAULT
                                      = observation.JourneyRef COLLATE DATABASE_DEFAULT
                            THEN candidate.TripId END) AS AfterJourneyRefTripIdCount,
    COUNT_BIG(DISTINCT CASE WHEN candidate.AgencyId COLLATE DATABASE_DEFAULT
                                      = observation.OperatorRef COLLATE DATABASE_DEFAULT
                            THEN candidate.RouteId END) AS AfterOperatorRefAgencyIdRouteCount,
    COUNT_BIG(DISTINCT CASE WHEN CONVERT(NVARCHAR(50), candidate.DirectionId) COLLATE DATABASE_DEFAULT
                                      = observation.DirectionRef COLLATE DATABASE_DEFAULT
                            THEN candidate.TripId END) AS AfterDirectionRefDirectionIdTripCount,
    COUNT_BIG(DISTINCT CASE WHEN UPPER(LTRIM(RTRIM(candidate.ModeGroup))) COLLATE DATABASE_DEFAULT
                                      = UPPER(LTRIM(RTRIM(observation.PtMode))) COLLATE DATABASE_DEFAULT
                                  OR UPPER(LTRIM(RTRIM(candidate.ModeDetail))) COLLATE DATABASE_DEFAULT
                                      = UPPER(LTRIM(RTRIM(observation.PtMode))) COLLATE DATABASE_DEFAULT
                            THEN candidate.RouteId END) AS AfterPtModeRouteCount,
    COUNT_BIG(DISTINCT CASE WHEN UPPER(LTRIM(RTRIM(candidate.ModeDetail))) COLLATE DATABASE_DEFAULT
                                      = UPPER(LTRIM(RTRIM(observation.RailSubmode))) COLLATE DATABASE_DEFAULT
                            THEN candidate.RouteId END) AS AfterRailSubmodeRouteCount
INTO #CandidateEvidenceSummary
FROM #Observation AS observation
LEFT JOIN #ScheduleCandidate AS candidate
    ON candidate.ObservationKey = observation.ObservationKey
GROUP BY
    observation.ObservationKey,
    observation.LineRef,
    observation.JourneyRef,
    observation.OperatorRef,
    observation.DirectionRef,
    observation.PtMode,
    observation.RailSubmode;

CREATE UNIQUE CLUSTERED INDEX UX_CandidateEvidenceSummary_ObservationKey
    ON #CandidateEvidenceSummary (ObservationKey);

/* 5. Identifier evidence and explicit namespace-compatibility status. */
SELECT
    missing.*,
    ISNULL(route_evidence.LineRefRouteIdCount, 0) AS LineRefRouteIdCount,
    ISNULL(route_evidence.TrimmedLineNameRouteLongNameCount, 0)
        AS TrimmedLineNameRouteLongNameCount,
    ISNULL(route_evidence.SpaceNormalizedLineNameRouteLongNameCount, 0)
        AS SpaceNormalizedLineNameRouteLongNameCount,
    ISNULL(route_evidence.TrimmedLineNameRouteShortNameCount, 0)
        AS TrimmedLineNameRouteShortNameCount,
    ISNULL(route_evidence.CurrentRuleLoadedRouteShortNameCount, 0)
        AS CurrentRuleLoadedRouteShortNameCount,
    ISNULL(route_evidence.CurrentRuleCologneServingRouteShortNameCount, 0)
        AS CurrentRuleCologneServingRouteShortNameCount,
    (
        SELECT COUNT_BIG(DISTINCT route.RouteId)
        FROM #GtfsRoute AS route
        WHERE missing.OperatorRef IS NOT NULL
          AND route.AgencyId IS NOT NULL
          AND route.AgencyId COLLATE DATABASE_DEFAULT
                = missing.OperatorRef COLLATE DATABASE_DEFAULT
    ) AS OperatorRefAgencyIdRouteCount,
    (
        SELECT COUNT_BIG(DISTINCT trip.TripId)
        FROM #GtfsTrip AS trip
        WHERE missing.JourneyRef IS NOT NULL
          AND trip.TripId COLLATE DATABASE_DEFAULT
                = missing.JourneyRef COLLATE DATABASE_DEFAULT
    ) AS JourneyRefTripIdCount,
    (
        SELECT COUNT_BIG(DISTINCT trip.TripId)
        FROM #GtfsTrip AS trip
        WHERE missing.DirectionRef IS NOT NULL
          AND trip.DirectionIdText IS NOT NULL
          AND trip.DirectionIdText COLLATE DATABASE_DEFAULT
                = missing.DirectionRef COLLATE DATABASE_DEFAULT
    ) AS DirectionRefDirectionIdTripCount,
    CASE
        WHEN missing.LineRef IS NULL THEN N'Source value is NULL'
        WHEN ISNULL(route_evidence.LineRefRouteIdCount, 0) > 0
            THEN N'Exact text equality found; no namespace transformation used'
        ELSE N'Exact text comparison only; no project LineRef-to-RouteId namespace mapping is defined'
    END AS LineRefRouteIdCompatibility,
    CASE
        WHEN missing.OperatorRef IS NULL THEN N'Source value is NULL'
        WHEN
        (
            SELECT COUNT_BIG(DISTINCT route.RouteId)
            FROM #GtfsRoute AS route
            WHERE route.AgencyId IS NOT NULL
              AND route.AgencyId COLLATE DATABASE_DEFAULT
                    = missing.OperatorRef COLLATE DATABASE_DEFAULT
        ) > 0
            THEN N'Exact text equality found; no namespace transformation used'
        ELSE N'Exact text comparison only; OperatorRef and AgencyId namespaces are not mapped'
    END AS OperatorRefAgencyIdCompatibility,
    CASE
        WHEN missing.JourneyRef IS NULL THEN N'Source value is NULL'
        WHEN
        (
            SELECT COUNT_BIG(DISTINCT trip.TripId)
            FROM #GtfsTrip AS trip
            WHERE trip.TripId COLLATE DATABASE_DEFAULT
                    = missing.JourneyRef COLLATE DATABASE_DEFAULT
        ) > 0
            THEN N'Exact text equality found; no namespace transformation used'
        ELSE N'Exact text comparison only; no JourneyRef-to-TripId namespace mapping is defined'
    END AS JourneyRefTripIdCompatibility,
    CASE
        WHEN missing.DirectionRef IS NULL THEN N'Source value is NULL'
        WHEN
        (
            SELECT COUNT_BIG(DISTINCT trip.TripId)
            FROM #GtfsTrip AS trip
            WHERE trip.DirectionIdText IS NOT NULL
              AND trip.DirectionIdText COLLATE DATABASE_DEFAULT
                    = missing.DirectionRef COLLATE DATABASE_DEFAULT
        ) > 0
            THEN N'Exact text equality found; no numeric/text conversion used'
        ELSE N'Exact text comparison only; DirectionRef and DirectionId formats are not mapped'
    END AS DirectionRefDirectionIdCompatibility,
    CASE
        WHEN missing.PtMode IS NULL THEN N'Source value is NULL'
        ELSE N'Exact normalized text only against schedule candidate ModeGroup/ModeDetail'
    END AS PtModeCompatibility,
    CASE
        WHEN missing.RailSubmode IS NULL THEN N'Source value is NULL'
        ELSE N'Exact normalized text only against schedule candidate ModeDetail'
    END AS RailSubmodeCompatibility
INTO #IdentifierEvidence
FROM #StaticCoverageMissing AS missing
LEFT JOIN #RouteEvidenceSummary AS route_evidence
    ON route_evidence.ObservationKey = missing.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_IdentifierEvidence_ObservationKey
    ON #IdentifierEvidence (ObservationKey);

SELECT
    identifier_evidence.*,
    schedule_summary.ScheduleCandidateCount,
    schedule_summary.ScheduleCandidateRouteCount,
    schedule_summary.ScheduleCandidateTripCount,
    schedule_summary.ScheduleCandidateClassification,
    candidate_evidence.AfterLineRefRouteIdCount,
    candidate_evidence.AfterJourneyRefTripIdCount,
    candidate_evidence.AfterOperatorRefAgencyIdRouteCount,
    candidate_evidence.AfterDirectionRefDirectionIdTripCount,
    candidate_evidence.AfterPtModeRouteCount,
    candidate_evidence.AfterRailSubmodeRouteCount
INTO #DiagnosticObservation
FROM #IdentifierEvidence AS identifier_evidence
INNER JOIN #ScheduleSummary AS schedule_summary
    ON schedule_summary.ObservationKey = identifier_evidence.ObservationKey
INNER JOIN #CandidateEvidenceSummary AS candidate_evidence
    ON candidate_evidence.ObservationKey = identifier_evidence.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_DiagnosticObservation_ObservationKey
    ON #DiagnosticObservation (ObservationKey);

/* 6. Mutually exclusive observation-level root causes. */
SELECT
    diagnostic.*,
    CASE
        WHEN diagnostic.CurrentRuleLoadedRouteShortNameCount > 0
         AND diagnostic.CurrentRuleCologneServingRouteShortNameCount = 0
            THEN N'StaticRouteExistsButOutsideCurrentCologneScope'
        WHEN diagnostic.ScheduleCandidateCount = 1
            THEN N'CurrentRouteNameRuleMissesDeterministicStaticRoute'
        WHEN diagnostic.ScheduleCandidateCount > 1
         AND
         (
             diagnostic.AfterLineRefRouteIdCount = 1
             OR diagnostic.AfterJourneyRefTripIdCount = 1
             OR diagnostic.AfterOperatorRefAgencyIdRouteCount = 1
             OR diagnostic.AfterDirectionRefDirectionIdTripCount = 1
         )
            THEN N'CurrentRouteNameRuleMissesDeterministicStaticRoute'
        WHEN diagnostic.ScheduleCandidateCount > 1
            THEN N'StaticScheduleCandidateAmbiguous'
        WHEN diagnostic.TimetabledArrivalUtc IS NULL
            THEN N'StaticStopOrScheduleEvidenceMissing'
        WHEN diagnostic.ScheduleCandidateCount = 0
         AND
         (
             diagnostic.LineRefRouteIdCount > 0
             OR diagnostic.TrimmedLineNameRouteLongNameCount > 0
             OR diagnostic.SpaceNormalizedLineNameRouteLongNameCount > 0
             OR diagnostic.TrimmedLineNameRouteShortNameCount > 0
         )
            THEN N'StaticStopOrScheduleEvidenceMissing'
        WHEN diagnostic.ScheduleCandidateCount = 0
            THEN N'NoMatchingRouteInLoadedStaticFeed'
        ELSE N'Unexplained'
    END AS RootCauseCategory,
    CASE
        WHEN diagnostic.CurrentRuleLoadedRouteShortNameCount > 0
         AND diagnostic.CurrentRuleCologneServingRouteShortNameCount = 0
            THEN N'Current normalized RouteShortName finds a loaded route, but no route with that label is in the current Cologne-serving route set.'
        WHEN diagnostic.ScheduleCandidateCount = 1
            THEN N'Ignoring the route-name join leaves exactly one stop/time/service-date scheduled candidate.'
        WHEN diagnostic.ScheduleCandidateCount > 1
         AND
         (
             diagnostic.AfterLineRefRouteIdCount = 1
             OR diagnostic.AfterJourneyRefTripIdCount = 1
             OR diagnostic.AfterOperatorRefAgencyIdRouteCount = 1
             OR diagnostic.AfterDirectionRefDirectionIdTripCount = 1
         )
            THEN N'Multiple schedule candidates are reduced to one by a single exact, structurally comparable identifier test.'
        WHEN diagnostic.ScheduleCandidateCount > 1
            THEN N'Multiple route-independent scheduled candidates remain after each applicable individual identifier test.'
        WHEN diagnostic.TimetabledArrivalUtc IS NULL
            THEN N'TimetabledArrivalUtc is missing, so the production schedule-time constraint cannot be reproduced.'
        WHEN diagnostic.ScheduleCandidateCount = 0
         AND
         (
             diagnostic.LineRefRouteIdCount > 0
             OR diagnostic.TrimmedLineNameRouteLongNameCount > 0
             OR diagnostic.SpaceNormalizedLineNameRouteLongNameCount > 0
             OR diagnostic.TrimmedLineNameRouteShortNameCount > 0
         )
            THEN N'A static route identifier/label exists, but no active stop/time/service-date candidate was found in the loaded schedule.'
        WHEN diagnostic.ScheduleCandidateCount = 0
            THEN N'No deterministic route evidence or route-independent active schedule candidate was found in the loaded static feed.'
        ELSE N'No direct evidence in the diagnostic rule set explains this observation.'
    END AS RootCauseExplanation
INTO #RootCause
FROM #DiagnosticObservation AS diagnostic;

CREATE INDEX IX_RootCause_Category
    ON #RootCause (RootCauseCategory, LineName, StopPointRef);

/* 7. Per-observation strategy counts for missing and successful populations. */
SELECT
    observation.ObservationKey,
    observation.MatchStatus,
    observation.LineName,
    observation.LineRef,
    observation.JourneyRef,
    observation.DirectionRef,
    observation.OperatorRef,
    observation.MatchedRouteId,
    ISNULL(route_evidence.LineRefRouteIdCount, 0) AS LineRefRouteIdCount,
    ISNULL(route_evidence.CurrentRuleLoadedRouteShortNameCount, 0)
        AS RouteShortNameRouteCount,
    (
        SELECT COUNT_BIG(DISTINCT evidence.RouteId)
        FROM #RouteEvidence AS evidence
        WHERE evidence.ObservationKey = observation.ObservationKey
          AND evidence.EvidenceType IN
          (
              N'TrimmedLineNameEqualsRouteLongName',
              N'SpaceNormalizedLineNameEqualsRouteLongName'
          )
    ) AS RouteLongNameRouteCount,
    ISNULL(schedule_summary.ScheduleCandidateCount, 0) AS ScheduleCandidateCount,
    ISNULL(schedule_summary.ScheduleCandidateRouteCount, 0)
        AS ScheduleCandidateRouteCount,
    ISNULL(candidate_evidence.AfterLineRefRouteIdCount, 0)
        AS ScheduleAfterLineRefRouteIdCount,
    ISNULL(candidate_evidence.AfterJourneyRefTripIdCount, 0)
        AS ScheduleAfterJourneyRefTripIdCount,
    ISNULL(candidate_evidence.AfterOperatorRefAgencyIdRouteCount, 0)
        AS ScheduleAfterOperatorRefAgencyIdRouteCount,
    ISNULL(candidate_evidence.AfterDirectionRefDirectionIdTripCount, 0)
        AS ScheduleAfterDirectionRefDirectionIdTripCount
INTO #StrategyObservation
FROM #Observation AS observation
LEFT JOIN #RouteEvidenceSummary AS route_evidence
    ON route_evidence.ObservationKey = observation.ObservationKey
LEFT JOIN #ScheduleSummary AS schedule_summary
    ON schedule_summary.ObservationKey = observation.ObservationKey
LEFT JOIN #CandidateEvidenceSummary AS candidate_evidence
    ON candidate_evidence.ObservationKey = observation.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_StrategyObservation_ObservationKey
    ON #StrategyObservation (ObservationKey);

/* 8. Current production rule and population reconciliation. */
DECLARE @CurrentMatchViewDefinition NVARCHAR(MAX) = OBJECT_DEFINITION
(
    OBJECT_ID(N'wrk.vwCologneRealtimeTripMatch', N'V')
);

/*
    The remediation replaced the former single-branch route-coverage check
    with an explicit primary/fallback architecture. Inspect a few stable
    architecture markers instead of depending on one complete SQL fragment.
*/
DECLARE @CurrentMatchViewDefinitionSearch NVARCHAR(MAX) = UPPER
(
    REPLACE
    (
        REPLACE
        (
            REPLACE
            (
                REPLACE
                (
                    ISNULL(@CurrentMatchViewDefinition, N''),
                    NCHAR(13),
                    N''
                ),
                NCHAR(10),
                N''
            ),
            NCHAR(9),
            N''
        ),
        N' ',
        N''
    )
);

DECLARE @HasRouteShortNamePrimaryCoverage BIT =
    CASE
        WHEN CHARINDEX(N'SHORTNAMECOVERAGE', @CurrentMatchViewDefinitionSearch) > 0
         AND CHARINDEX(N'SHORTNAMECANDIDATE', @CurrentMatchViewDefinitionSearch) > 0
         AND CHARINDEX(N'ROUTESHORTNAME', @CurrentMatchViewDefinitionSearch) > 0
            THEN 1
        ELSE 0
    END;

DECLARE @HasRouteLongNameFallbackCoverage BIT =
    CASE
        WHEN CHARINDEX(N'LONGNAMECOVERAGE', @CurrentMatchViewDefinitionSearch) > 0
         AND CHARINDEX(N'LONGNAMEFALLBACKCANDIDATE', @CurrentMatchViewDefinitionSearch) > 0
         AND CHARINDEX(N'ROUTELONGNAME', @CurrentMatchViewDefinitionSearch) > 0
            THEN 1
        ELSE 0
    END;

DECLARE @HasFallbackShortNameGate BIT =
    CASE
        WHEN CHARINDEX(N'HASSHORTNAMECOVERAGE=0', @CurrentMatchViewDefinitionSearch) > 0
         AND CHARINDEX(N'HASLONGNAMECOVERAGE=1', @CurrentMatchViewDefinitionSearch) > 0
            THEN 1
        ELSE 0
    END;

DECLARE @HasStaticMissingBothCoverageGate BIT =
    CASE
        WHEN CHARINDEX
             (
                 N'ISNULL(ROUTE_PATH.HASSHORTNAMECOVERAGE,0)=0',
                 @CurrentMatchViewDefinitionSearch
             ) > 0
         AND CHARINDEX
             (
                 N'ISNULL(ROUTE_PATH.HASLONGNAMECOVERAGE,0)=0',
                 @CurrentMatchViewDefinitionSearch
             ) > 0
         AND CHARINDEX(N'STATICCOVERAGEMISSING', @CurrentMatchViewDefinitionSearch) > 0
            THEN 1
        ELSE 0
    END;

SELECT
    SYSUTCDATETIME() AS AnalysisRunAtUtc,
    MIN(observation.ObservedAtUtc) AS ObservationDateTimeMinUtc,
    MAX(observation.ObservedAtUtc) AS ObservationDateTimeMaxUtc,
    COUNT_BIG(*) AS TotalRealtimeObservations,
    SUM(CASE WHEN observation.MatchStatus = N'ExactStopMatch' THEN 1 ELSE 0 END)
        AS ExactStopMatchCount,
    SUM(CASE WHEN observation.MatchStatus = N'ParentStationFallback' THEN 1 ELSE 0 END)
        AS ParentStationFallbackCount,
    SUM(CASE WHEN observation.MatchStatus = N'StaticCoverageMissing' THEN 1 ELSE 0 END)
        AS StaticCoverageMissingCount,
    SUM(CASE WHEN observation.MatchStatus = N'Unresolved' THEN 1 ELSE 0 END)
        AS UnresolvedCount,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.MatchStatus = N'ExactStopMatch' THEN 1 ELSE 0 END)
        / NULLIF(CONVERT(DECIMAL(28, 8), COUNT_BIG(*)), 0)
    ) AS ExactStopMatchRate,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.MatchStatus = N'ParentStationFallback' THEN 1 ELSE 0 END)
        / NULLIF(CONVERT(DECIMAL(28, 8), COUNT_BIG(*)), 0)
    ) AS ParentStationFallbackRate,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.MatchStatus = N'StaticCoverageMissing' THEN 1 ELSE 0 END)
        / NULLIF(CONVERT(DECIMAL(28, 8), COUNT_BIG(*)), 0)
    ) AS StaticCoverageMissingRate,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.MatchStatus = N'Unresolved' THEN 1 ELSE 0 END)
        / NULLIF(CONVERT(DECIMAL(28, 8), COUNT_BIG(*)), 0)
    ) AS UnresolvedRate,
    CASE
        WHEN COUNT_BIG(*) =
        (
            SUM(CASE WHEN observation.MatchStatus = N'ExactStopMatch' THEN 1 ELSE 0 END)
            + SUM(CASE WHEN observation.MatchStatus = N'ParentStationFallback' THEN 1 ELSE 0 END)
            + SUM(CASE WHEN observation.MatchStatus = N'StaticCoverageMissing' THEN 1 ELSE 0 END)
            + SUM(CASE WHEN observation.MatchStatus = N'Unresolved' THEN 1 ELSE 0 END)
        ) THEN N'PASS'
        ELSE N'REVIEW'
    END AS MatchStatusReconciliationStatus
FROM #Observation AS observation;

SELECT
    OBJECT_SCHEMA_NAME(OBJECT_ID(N'wrk.vwCologneRealtimeTripMatch', N'V'))
        AS SourceSchema,
    OBJECT_NAME(OBJECT_ID(N'wrk.vwCologneRealtimeTripMatch', N'V'))
        AS SourceObject,
    CASE WHEN @CurrentMatchViewDefinition IS NOT NULL THEN N'PASS' ELSE N'REVIEW' END
        AS ViewDefinitionAvailable,
    CASE WHEN @HasRouteShortNamePrimaryCoverage = 1
         THEN N'PASS' ELSE N'REVIEW' END AS RouteShortNamePrimaryCoverageFound,
    CASE WHEN @HasRouteLongNameFallbackCoverage = 1
         THEN N'PASS' ELSE N'REVIEW' END AS RouteLongNameFallbackCoverageFound,
    CASE WHEN @HasFallbackShortNameGate = 1
         THEN N'PASS' ELSE N'REVIEW' END AS FallbackRequiresNoRouteShortNameCoverage,
    CASE WHEN @HasStaticMissingBothCoverageGate = 1
         THEN N'PASS' ELSE N'REVIEW' END
        AS StaticCoverageMissingRequiresNeitherCoverage,
    CASE
        WHEN @HasRouteShortNamePrimaryCoverage = 1
         AND @HasRouteLongNameFallbackCoverage = 1
         AND @HasFallbackShortNameGate = 1
         AND @HasStaticMissingBothCoverageGate = 1
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS ValidatedPrimaryFallbackArchitecture,
    CASE WHEN CHARINDEX(N'REPLACE(r.LineName, N'' '', N'''')', @CurrentMatchViewDefinition) > 0
         THEN N'PASS' ELSE N'REVIEW' END AS RouteNameNormalizationFound,
    SUBSTRING
    (
        @CurrentMatchViewDefinition,
        NULLIF(CHARINDEX(N'CASE', @CurrentMatchViewDefinition), 0),
        1200
    ) AS CurrentMatchConditionExcerpt,
    N'Validated architecture: RouteShortName is primary; RouteLongName is fallback only when no RouteShortName coverage exists; StaticCoverageMissing requires neither supported coverage path.'
        AS VerifiedCondition
;

/* 9. Realtime field inventory for the current StaticCoverageMissing population. */
WITH FieldValues AS
(
    SELECT
        missing.ObservationKey,
        field_value.FieldName,
        field_value.ValueText
    FROM #StaticCoverageMissing AS missing
    CROSS APPLY
    (
        VALUES
            (N'ObservationKey', CONVERT(NVARCHAR(4000), missing.ObservationKey) COLLATE DATABASE_DEFAULT),
            (N'ObservedAtUtc', CONVERT(NVARCHAR(4000), missing.ObservedAtUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'ResultId', CONVERT(NVARCHAR(4000), missing.ResultId) COLLATE DATABASE_DEFAULT),
            (N'StopPointRef', CONVERT(NVARCHAR(4000), missing.StopPointRef) COLLATE DATABASE_DEFAULT),
            (N'StopName', CONVERT(NVARCHAR(4000), missing.StopName) COLLATE DATABASE_DEFAULT),
            (N'LineName', CONVERT(NVARCHAR(4000), missing.LineName) COLLATE DATABASE_DEFAULT),
            (N'LineRef', CONVERT(NVARCHAR(4000), missing.LineRef) COLLATE DATABASE_DEFAULT),
            (N'JourneyRef', CONVERT(NVARCHAR(4000), missing.JourneyRef) COLLATE DATABASE_DEFAULT),
            (N'DirectionRef', CONVERT(NVARCHAR(4000), missing.DirectionRef) COLLATE DATABASE_DEFAULT),
            (N'OperatorRef', CONVERT(NVARCHAR(4000), missing.OperatorRef) COLLATE DATABASE_DEFAULT),
            (N'PtMode', CONVERT(NVARCHAR(4000), missing.PtMode) COLLATE DATABASE_DEFAULT),
            (N'RailSubmode', CONVERT(NVARCHAR(4000), missing.RailSubmode) COLLATE DATABASE_DEFAULT),
            (N'TimetabledArrivalUtc', CONVERT(NVARCHAR(4000), missing.TimetabledArrivalUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'EstimatedArrivalUtc', CONVERT(NVARCHAR(4000), missing.EstimatedArrivalUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'PlannedBay', CONVERT(NVARCHAR(4000), missing.PlannedBay) COLLATE DATABASE_DEFAULT),
            (N'EstimatedBay', CONVERT(NVARCHAR(4000), missing.EstimatedBay) COLLATE DATABASE_DEFAULT)
    ) AS field_value(FieldName, ValueText)
)
SELECT
    field_values.FieldName,
    COUNT_BIG(*) AS TotalRows,
    SUM(CASE WHEN field_values.ValueText IS NOT NULL THEN 1 ELSE 0 END)
        AS NonNullCount,
    SUM(CASE WHEN field_values.ValueText IS NULL THEN 1 ELSE 0 END)
        AS NullCount,
    COUNT_BIG(DISTINCT field_values.ValueText) AS DistinctCount
FROM FieldValues AS field_values
GROUP BY field_values.FieldName
ORDER BY field_values.FieldName;

/* 10. Representative values for every audited realtime field. */
WITH FieldValues AS
(
    SELECT
        field_value.FieldName,
        CASE
            WHEN field_value.ValueText IS NULL THEN NULL
            WHEN NULLIF(LTRIM(RTRIM(field_value.ValueText)), N'') IS NULL
                THEN N'<BLANK>'
            ELSE field_value.ValueText
        END AS ValueText
    FROM #StaticCoverageMissing AS missing
    CROSS APPLY
    (
        VALUES
            (N'ObservationKey', CONVERT(NVARCHAR(4000), missing.ObservationKey) COLLATE DATABASE_DEFAULT),
            (N'ObservedAtUtc', CONVERT(NVARCHAR(4000), missing.ObservedAtUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'ResultId', CONVERT(NVARCHAR(4000), missing.ResultId) COLLATE DATABASE_DEFAULT),
            (N'StopPointRef', CONVERT(NVARCHAR(4000), missing.StopPointRef) COLLATE DATABASE_DEFAULT),
            (N'StopName', CONVERT(NVARCHAR(4000), missing.StopName) COLLATE DATABASE_DEFAULT),
            (N'LineName', CONVERT(NVARCHAR(4000), missing.LineName) COLLATE DATABASE_DEFAULT),
            (N'LineRef', CONVERT(NVARCHAR(4000), missing.LineRef) COLLATE DATABASE_DEFAULT),
            (N'JourneyRef', CONVERT(NVARCHAR(4000), missing.JourneyRef) COLLATE DATABASE_DEFAULT),
            (N'DirectionRef', CONVERT(NVARCHAR(4000), missing.DirectionRef) COLLATE DATABASE_DEFAULT),
            (N'OperatorRef', CONVERT(NVARCHAR(4000), missing.OperatorRef) COLLATE DATABASE_DEFAULT),
            (N'PtMode', CONVERT(NVARCHAR(4000), missing.PtMode) COLLATE DATABASE_DEFAULT),
            (N'RailSubmode', CONVERT(NVARCHAR(4000), missing.RailSubmode) COLLATE DATABASE_DEFAULT),
            (N'TimetabledArrivalUtc', CONVERT(NVARCHAR(4000), missing.TimetabledArrivalUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'EstimatedArrivalUtc', CONVERT(NVARCHAR(4000), missing.EstimatedArrivalUtc, 121) COLLATE DATABASE_DEFAULT),
            (N'PlannedBay', CONVERT(NVARCHAR(4000), missing.PlannedBay) COLLATE DATABASE_DEFAULT),
            (N'EstimatedBay', CONVERT(NVARCHAR(4000), missing.EstimatedBay) COLLATE DATABASE_DEFAULT)
    ) AS field_value(FieldName, ValueText)
), ValueCounts AS
(
    SELECT
        field_values.FieldName,
        field_values.ValueText,
        COUNT_BIG(*) AS ValueCount
    FROM FieldValues AS field_values
    WHERE field_values.ValueText IS NOT NULL
    GROUP BY field_values.FieldName, field_values.ValueText
), RankedValues AS
(
    SELECT
        value_counts.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY value_counts.FieldName
            ORDER BY value_counts.ValueCount DESC, value_counts.ValueText
        ) AS ValueRank
    FROM ValueCounts AS value_counts
)
SELECT
    ranked_values.FieldName,
    ranked_values.ValueRank,
    ranked_values.ValueText AS RepresentativeValue,
    ranked_values.ValueCount
FROM RankedValues AS ranked_values
WHERE ranked_values.ValueRank <= 5
ORDER BY ranked_values.FieldName, ranked_values.ValueRank;

/* 11. Static GTFS identifier and schedule-field inventory. */
SELECT
    inventory.SourceObject,
    inventory.FieldName,
    inventory.TotalRows,
    inventory.NonNullCount,
    inventory.NullCount,
    inventory.DistinctCount
FROM
(
    SELECT N'stg.GtfsRoutes' AS SourceObject, N'RouteId' AS FieldName,
           COUNT_BIG(*) AS TotalRows,
           SUM(CASE WHEN route.RouteId IS NOT NULL THEN 1 ELSE 0 END) AS NonNullCount,
           SUM(CASE WHEN route.RouteId IS NULL THEN 1 ELSE 0 END) AS NullCount,
           COUNT_BIG(DISTINCT route.RouteId) AS DistinctCount
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsRoutes', N'AgencyId', COUNT_BIG(*),
           SUM(CASE WHEN route.AgencyId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN route.AgencyId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT route.AgencyId)
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsRoutes', N'RouteShortName', COUNT_BIG(*),
           SUM(CASE WHEN route.RouteShortName IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN route.RouteShortName IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT route.RouteShortName)
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsRoutes', N'RouteLongName', COUNT_BIG(*),
           SUM(CASE WHEN route.RouteLongName IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN route.RouteLongName IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT route.RouteLongName)
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsRoutes', N'RouteDesc', COUNT_BIG(*),
           SUM(CASE WHEN route.RouteDesc IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN route.RouteDesc IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT route.RouteDesc)
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsRoutes', N'RouteType', COUNT_BIG(*),
           SUM(CASE WHEN route.RouteType IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN route.RouteType IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT route.RouteType)
    FROM stg.GtfsRoutes AS route
    UNION ALL
    SELECT N'stg.GtfsTrips', N'RouteId', COUNT_BIG(*),
           SUM(CASE WHEN trip.RouteId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.RouteId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.RouteId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'ServiceId', COUNT_BIG(*),
           SUM(CASE WHEN trip.ServiceId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.ServiceId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.ServiceId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'TripId', COUNT_BIG(*),
           SUM(CASE WHEN trip.TripId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.TripId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.TripId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'TripHeadsign', COUNT_BIG(*),
           SUM(CASE WHEN trip.TripHeadsign IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.TripHeadsign IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.TripHeadsign)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'DirectionId', COUNT_BIG(*),
           SUM(CASE WHEN trip.DirectionId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.DirectionId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.DirectionId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'BlockId', COUNT_BIG(*),
           SUM(CASE WHEN trip.BlockId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.BlockId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.BlockId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsTrips', N'ShapeId', COUNT_BIG(*),
           SUM(CASE WHEN trip.ShapeId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN trip.ShapeId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT trip.ShapeId)
    FROM stg.GtfsTrips AS trip
    UNION ALL
    SELECT N'stg.GtfsStopTimes', N'StopId', COUNT_BIG(*),
           SUM(CASE WHEN stop_time.StopId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop_time.StopId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop_time.StopId)
    FROM stg.GtfsStopTimes AS stop_time
    UNION ALL
    SELECT N'stg.GtfsStopTimes', N'ArrivalTime', COUNT_BIG(*),
           SUM(CASE WHEN stop_time.ArrivalTime IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop_time.ArrivalTime IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop_time.ArrivalTime)
    FROM stg.GtfsStopTimes AS stop_time
    UNION ALL
    SELECT N'stg.GtfsStopTimes', N'DepartureTime', COUNT_BIG(*),
           SUM(CASE WHEN stop_time.DepartureTime IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop_time.DepartureTime IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop_time.DepartureTime)
    FROM stg.GtfsStopTimes AS stop_time
    UNION ALL
    SELECT N'stg.GtfsStopTimes', N'StopSequence', COUNT_BIG(*),
           SUM(CASE WHEN stop_time.StopSequence IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop_time.StopSequence IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop_time.StopSequence)
    FROM stg.GtfsStopTimes AS stop_time
    UNION ALL
    SELECT N'stg.GtfsStops', N'StopId', COUNT_BIG(*),
           SUM(CASE WHEN stop.StopId IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop.StopId IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop.StopId)
    FROM stg.GtfsStops AS stop
    UNION ALL
    SELECT N'stg.GtfsStops', N'ParentStation', COUNT_BIG(*),
           SUM(CASE WHEN stop.ParentStation IS NOT NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN stop.ParentStation IS NULL THEN 1 ELSE 0 END),
           COUNT_BIG(DISTINCT stop.ParentStation)
    FROM stg.GtfsStops AS stop
    UNION ALL
    SELECT N'dw.BridgeServiceDate + dw.DimDate', N'ServiceDate', COUNT_BIG(*),
           COUNT_BIG(*), 0, COUNT_BIG(DISTINCT date_dimension.DateValue)
    FROM dw.BridgeServiceDate AS bridge_service_date
    INNER JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = bridge_service_date.DateKey
) AS inventory
ORDER BY inventory.SourceObject, inventory.FieldName;

/* 12. Identifier-pair comparison summary and explicit compatibility notes. */
SELECT
    comparison.IdentifierPair,
    comparison.SourceNonNullObservationCount,
    comparison.ObservationWithExactEvidenceCount,
    comparison.DistinctStaticMatchCount,
    comparison.ComparisonStatus,
    comparison.CompatibilityNote
FROM
(
    SELECT
        N'LineName -> RouteShortName (current loaded-rule comparison)' AS IdentifierPair,
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.LineName IS NOT NULL
                                THEN identifier_evidence.ObservationKey END)
            AS SourceNonNullObservationCount,
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.CurrentRuleLoadedRouteShortNameCount > 0
                                THEN identifier_evidence.ObservationKey END)
            AS ObservationWithExactEvidenceCount,
        COUNT_BIG(DISTINCT evidence.RouteId) AS DistinctStaticMatchCount,
        N'Exact normalized text equality' AS ComparisonStatus,
        N'Production route-name comparison removes spaces and does not use fuzzy matching.'
            AS CompatibilityNote
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #RouteEvidence AS evidence
        ON evidence.ObservationKey = identifier_evidence.ObservationKey
       AND evidence.EvidenceType = N'CurrentRuleLoadedRouteShortName'
    UNION ALL
    SELECT
        N'LineName -> trimmed RouteLongName',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.LineName IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.TrimmedLineNameRouteLongNameCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT evidence.RouteId),
        N'Exact text equality after LTRIM/RTRIM',
        N'Labels are compared only after the specified trim operation.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #RouteEvidence AS evidence
        ON evidence.ObservationKey = identifier_evidence.ObservationKey
       AND evidence.EvidenceType = N'TrimmedLineNameEqualsRouteLongName'
    UNION ALL
    SELECT
        N'LineName -> space-normalized RouteLongName',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.LineName IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.SpaceNormalizedLineNameRouteLongNameCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT evidence.RouteId),
        N'Exact text equality after removing spaces',
        N'Labels are compared only after the specified space-removal operation.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #RouteEvidence AS evidence
        ON evidence.ObservationKey = identifier_evidence.ObservationKey
       AND evidence.EvidenceType = N'SpaceNormalizedLineNameEqualsRouteLongName'
    UNION ALL
    SELECT
        N'LineRef -> RouteId',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.LineRef IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.LineRefRouteIdCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT evidence.RouteId),
        N'Exact textual equality only',
        N'Both values are treated as opaque text; the repository defines no namespace transformation.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #RouteEvidence AS evidence
        ON evidence.ObservationKey = identifier_evidence.ObservationKey
       AND evidence.EvidenceType = N'LineRefEqualsRouteId'
    UNION ALL
    SELECT
        N'OperatorRef -> AgencyId',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.OperatorRef IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.OperatorRefAgencyIdRouteCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT route.RouteId),
        N'Exact textual equality only',
        N'OperatorRef and AgencyId are separate source fields with no project namespace mapping.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #GtfsRoute AS route
        ON route.AgencyId COLLATE DATABASE_DEFAULT
             = identifier_evidence.OperatorRef COLLATE DATABASE_DEFAULT
    UNION ALL
    SELECT
        N'JourneyRef -> TripId',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.JourneyRef IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.JourneyRefTripIdCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT trip.TripId),
        N'Exact textual equality only',
        N'JourneyRef and TripId are compared only as exact opaque text.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #GtfsTrip AS trip
        ON trip.TripId COLLATE DATABASE_DEFAULT
             = identifier_evidence.JourneyRef COLLATE DATABASE_DEFAULT
    UNION ALL
    SELECT
        N'DirectionRef -> DirectionId',
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.DirectionRef IS NOT NULL
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT CASE WHEN identifier_evidence.DirectionRefDirectionIdTripCount > 0
                                THEN identifier_evidence.ObservationKey END),
        COUNT_BIG(DISTINCT trip.TripId),
        N'Exact textual equality only',
        N'DirectionRef and DirectionId are not converted or mapped between namespaces.'
    FROM #IdentifierEvidence AS identifier_evidence
    LEFT JOIN #GtfsTrip AS trip
        ON trip.DirectionIdText COLLATE DATABASE_DEFAULT
             = identifier_evidence.DirectionRef COLLATE DATABASE_DEFAULT
) AS comparison
GROUP BY
    comparison.IdentifierPair,
    comparison.SourceNonNullObservationCount,
    comparison.ObservationWithExactEvidenceCount,
    comparison.DistinctStaticMatchCount,
    comparison.ComparisonStatus,
    comparison.CompatibilityNote
ORDER BY comparison.IdentifierPair;

/* 13. Per-observation identifier evidence and compatibility result. */
SELECT
    identifier_evidence.ObservationKey,
    identifier_evidence.LineName,
    identifier_evidence.LineRef,
    identifier_evidence.JourneyRef,
    identifier_evidence.DirectionRef,
    identifier_evidence.OperatorRef,
    identifier_evidence.PtMode,
    identifier_evidence.RailSubmode,
    identifier_evidence.CurrentRuleLoadedRouteShortNameCount,
    identifier_evidence.LineRefRouteIdCount,
    identifier_evidence.TrimmedLineNameRouteLongNameCount,
    identifier_evidence.SpaceNormalizedLineNameRouteLongNameCount,
    identifier_evidence.TrimmedLineNameRouteShortNameCount,
    identifier_evidence.OperatorRefAgencyIdRouteCount,
    identifier_evidence.JourneyRefTripIdCount,
    identifier_evidence.DirectionRefDirectionIdTripCount,
    identifier_evidence.LineRefRouteIdCompatibility,
    identifier_evidence.OperatorRefAgencyIdCompatibility,
    identifier_evidence.JourneyRefTripIdCompatibility,
    identifier_evidence.DirectionRefDirectionIdCompatibility,
    identifier_evidence.PtModeCompatibility,
    identifier_evidence.RailSubmodeCompatibility
FROM #IdentifierEvidence AS identifier_evidence
ORDER BY identifier_evidence.ObservationKey;

/* 14. Schedule-without-LineName candidate classification for every miss. */
SELECT
    root_cause.ObservationKey,
    root_cause.ObservedAtUtc,
    root_cause.LineName,
    root_cause.LineRef,
    root_cause.JourneyRef,
    root_cause.StopPointRef,
    root_cause.StaticParentStationId,
    root_cause.TimetabledArrivalUtc,
    root_cause.ServiceDateLocal,
    root_cause.ScheduleCandidateCount,
    root_cause.ScheduleCandidateRouteCount,
    root_cause.ScheduleCandidateTripCount,
    root_cause.ScheduleCandidateClassification,
    root_cause.RootCauseCategory,
    root_cause.RootCauseExplanation
FROM #RootCause AS root_cause
ORDER BY root_cause.ObservationKey;

/* 15. Exactly-one route-independent schedule candidate detail. */
SELECT
    root_cause.ObservationKey,
    root_cause.ObservedAtUtc,
    root_cause.ResultId,
    root_cause.StopName,
    root_cause.LineName,
    root_cause.LineRef,
    root_cause.JourneyRef,
    root_cause.DirectionRef,
    root_cause.OperatorRef,
    root_cause.PtMode,
    root_cause.RailSubmode,
    root_cause.StopPointRef,
    root_cause.TimetabledArrivalUtc,
    root_cause.EstimatedArrivalUtc,
    root_cause.PlannedBay,
    root_cause.EstimatedBay,
    root_cause.StaticParentStationId,
    root_cause.StaticStopMatched,
    root_cause.TimetabledArrivalLocal,
    root_cause.ServiceDateLocal,
    root_cause.ScheduledArrivalSecondsLocal,
    root_cause.ExactStopCandidateCount,
    root_cause.ParentStationCandidateCount,
    candidate.ScheduledStopEventKey,
    candidate.RouteId,
    candidate.RouteShortName,
    candidate.RouteLongName,
    candidate.AgencyId,
    candidate.TripId,
    candidate.TripHeadsign,
    candidate.DirectionId,
    candidate.ServiceId,
    candidate.StopId,
    candidate.ParentStationId,
    candidate.ServiceDate,
    candidate.ScheduledArrivalTimeText AS ScheduledArrival,
    candidate.ScheduledArrivalSeconds,
    candidate.ArrivalDayOffset,
    candidate.ModeGroup,
    candidate.ModeDetail,
    root_cause.CurrentRuleLoadedRouteShortNameCount,
    N'Current production route candidate requires normalized LineName = normalized RouteShortName and the route must be in wrk.vwCologneServingRoute.'
        AS CurrentConditionPreventingCandidate,
    root_cause.RootCauseCategory,
    root_cause.RootCauseExplanation
FROM #RootCause AS root_cause
INNER JOIN #ScheduleCandidate AS candidate
    ON candidate.ObservationKey = root_cause.ObservationKey
INNER JOIN #ScheduleSummary AS schedule_summary
    ON schedule_summary.ObservationKey = root_cause.ObservationKey
   AND schedule_summary.ScheduleCandidateCount = 1
WHERE root_cause.RootCauseCategory = N'CurrentRouteNameRuleMissesDeterministicStaticRoute'
ORDER BY root_cause.ObservationKey;

/* 16. Multiple schedule candidates and each individual extra-evidence test. */
SELECT
    root_cause.ObservationKey,
    root_cause.LineName,
    root_cause.LineRef,
    root_cause.JourneyRef,
    root_cause.OperatorRef,
    root_cause.DirectionRef,
    root_cause.ScheduleCandidateCount AS CandidateCountBeforeAdditionalEvidence,
    root_cause.AfterLineRefRouteIdCount AS CandidateCountAfterLineRefEvidence,
    root_cause.AfterJourneyRefTripIdCount AS CandidateCountAfterJourneyRefEvidence,
    root_cause.AfterOperatorRefAgencyIdRouteCount AS CandidateCountAfterOperatorRefEvidence,
    root_cause.AfterDirectionRefDirectionIdTripCount AS CandidateCountAfterDirectionRefEvidence,
    root_cause.AfterPtModeRouteCount AS CandidateCountAfterPtModeEvidence,
    root_cause.AfterRailSubmodeRouteCount AS CandidateCountAfterRailSubmodeEvidence,
    root_cause.RootCauseCategory,
    root_cause.RootCauseExplanation
FROM #RootCause AS root_cause
WHERE root_cause.ScheduleCandidateCount > 1
ORDER BY root_cause.ObservationKey;

SELECT
    evidence_test.EvidenceType,
    COUNT_BIG(*) AS MultipleCandidateObservationCount,
    SUM(CASE WHEN evidence_test.CandidateCountAfterEvidence = 0 THEN 1 ELSE 0 END)
        AS ZeroCandidateObservationCount,
    SUM(CASE WHEN evidence_test.CandidateCountAfterEvidence = 1 THEN 1 ELSE 0 END)
        AS ExactlyOneCandidateObservationCount,
    SUM(CASE WHEN evidence_test.CandidateCountAfterEvidence > 1 THEN 1 ELSE 0 END)
        AS StillMultipleCandidateObservationCount
FROM #RootCause AS root_cause
INNER JOIN #CandidateEvidenceSummary AS candidate_evidence
    ON candidate_evidence.ObservationKey = root_cause.ObservationKey
CROSS APPLY
(
    VALUES
        (N'BeforeAdditionalEvidence', root_cause.ScheduleCandidateCount),
        (N'LineRefEqualsRouteId', candidate_evidence.AfterLineRefRouteIdCount),
        (N'JourneyRefEqualsTripId', candidate_evidence.AfterJourneyRefTripIdCount),
        (N'OperatorRefEqualsAgencyId', candidate_evidence.AfterOperatorRefAgencyIdRouteCount),
        (N'DirectionRefEqualsDirectionId', candidate_evidence.AfterDirectionRefDirectionIdTripCount),
        (N'PtModeEqualsModeGroupOrDetail', candidate_evidence.AfterPtModeRouteCount),
        (N'RailSubmodeEqualsModeDetail', candidate_evidence.AfterRailSubmodeRouteCount)
) AS evidence_test(EvidenceType, CandidateCountAfterEvidence)
WHERE root_cause.ScheduleCandidateCount > 1
GROUP BY evidence_test.EvidenceType
ORDER BY CASE evidence_test.EvidenceType
             WHEN N'BeforeAdditionalEvidence' THEN 1
             WHEN N'LineRefEqualsRouteId' THEN 2
             WHEN N'JourneyRefEqualsTripId' THEN 3
             WHEN N'OperatorRefEqualsAgencyId' THEN 4
             WHEN N'DirectionRefEqualsDirectionId' THEN 5
             WHEN N'PtModeEqualsModeGroupOrDetail' THEN 6
             WHEN N'RailSubmodeEqualsModeDetail' THEN 7
             ELSE 8
         END;

/* 17. No-schedule-candidate evidence and directly evidenced reason. */
WITH NoCandidateEvidence AS
(
    SELECT
        root_cause.*,
        CASE
            WHEN root_cause.TimetabledArrivalUtc IS NULL
                THEN N'TimetabledArrivalUtcMissing'
            WHEN root_cause.StaticStopMatched = 0
                THEN N'RealtimeStopNotFoundInWarehouseStaticStopDimension'
            WHEN root_cause.LineRefRouteIdCount > 0
              OR root_cause.TrimmedLineNameRouteLongNameCount > 0
              OR root_cause.SpaceNormalizedLineNameRouteLongNameCount > 0
              OR root_cause.TrimmedLineNameRouteShortNameCount > 0
                THEN N'StaticRouteEvidenceExistsButNoActiveStopTimeServiceDateCandidate'
            ELSE N'NoDeterministicRouteOrActiveScheduleEvidence'
        END AS NoScheduleEvidenceReason
    FROM #RootCause AS root_cause
    WHERE root_cause.ScheduleCandidateCount = 0
)
SELECT
    no_candidate.NoScheduleEvidenceReason,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT no_candidate.LineName) AS DistinctLineNameCount,
    COUNT_BIG(DISTINCT no_candidate.StopPointRef) AS DistinctStopPointRefCount,
    SUM(CASE WHEN no_candidate.StaticStopMatched = 1 THEN 1 ELSE 0 END)
        AS StaticStopMatchedObservationCount,
    SUM(CASE WHEN no_candidate.TimetabledArrivalUtc IS NOT NULL THEN 1 ELSE 0 END)
        AS TimetabledTimePresentObservationCount,
    MAX(no_candidate.RootCauseExplanation) AS EvidenceInterpretation
FROM NoCandidateEvidence AS no_candidate
GROUP BY no_candidate.NoScheduleEvidenceReason
ORDER BY no_candidate.NoScheduleEvidenceReason;

SELECT
    no_candidate.ObservationKey,
    no_candidate.LineName,
    no_candidate.LineRef,
    no_candidate.JourneyRef,
    no_candidate.StopPointRef,
    no_candidate.TimetabledArrivalUtc,
    no_candidate.ServiceDateLocal,
    no_candidate.StaticStopMatched,
    no_candidate.LineRefRouteIdCount,
    no_candidate.TrimmedLineNameRouteLongNameCount,
    no_candidate.SpaceNormalizedLineNameRouteLongNameCount,
    no_candidate.TrimmedLineNameRouteShortNameCount,
    CASE
        WHEN no_candidate.TimetabledArrivalUtc IS NULL
            THEN N'TimetabledArrivalUtcMissing'
        WHEN no_candidate.StaticStopMatched = 0
            THEN N'RealtimeStopNotFoundInWarehouseStaticStopDimension'
        WHEN no_candidate.LineRefRouteIdCount > 0
          OR no_candidate.TrimmedLineNameRouteLongNameCount > 0
          OR no_candidate.SpaceNormalizedLineNameRouteLongNameCount > 0
          OR no_candidate.TrimmedLineNameRouteShortNameCount > 0
            THEN N'StaticRouteEvidenceExistsButNoActiveStopTimeServiceDateCandidate'
        ELSE N'NoDeterministicRouteOrActiveScheduleEvidence'
    END AS NoScheduleEvidenceReason,
    no_candidate.RootCauseCategory,
    no_candidate.RootCauseExplanation
FROM #RootCause AS no_candidate
WHERE no_candidate.ScheduleCandidateCount = 0
ORDER BY no_candidate.ObservationKey;

/* 18. Current-serving-scope findings for loaded routes found by the rule. */
WITH OutsideScopeRoute AS
(
    SELECT DISTINCT
        evidence.RouteId
    FROM #RouteEvidence AS evidence
    INNER JOIN #StaticCoverageMissing AS missing
        ON missing.ObservationKey = evidence.ObservationKey
    WHERE evidence.EvidenceType = N'CurrentRuleLoadedRouteShortName'
      AND NOT EXISTS
      (
          SELECT 1
          FROM #ServingRoute AS serving_route
          WHERE serving_route.RouteId COLLATE DATABASE_DEFAULT
                    = evidence.RouteId COLLATE DATABASE_DEFAULT
      )
), RouteStaticFacts AS
(
    SELECT
        route.RouteId,
        route.AgencyId,
        route.RouteShortName,
        route.RouteLongName,
        route.AgencyName,
        route.RouteType,
        COUNT_BIG(DISTINCT trip.TripId) AS LoadedTripCount,
        COUNT_BIG(DISTINCT stop_time.StopId) AS StaticStopCount,
        COUNT_BIG(DISTINCT CASE WHEN stop_time.StopId LIKE N'de:05315:%'
                                THEN stop_time.StopId END) AS CologneStaticStopCount
    FROM #GtfsRoute AS route
    LEFT JOIN stg.GtfsTrips AS trip
        ON trip.RouteId COLLATE DATABASE_DEFAULT
             = route.RouteId COLLATE DATABASE_DEFAULT
    LEFT JOIN stg.GtfsStopTimes AS stop_time
        ON stop_time.TripId COLLATE DATABASE_DEFAULT
             = trip.TripId COLLATE DATABASE_DEFAULT
    INNER JOIN OutsideScopeRoute AS outside_scope
        ON outside_scope.RouteId COLLATE DATABASE_DEFAULT
             = route.RouteId COLLATE DATABASE_DEFAULT
    GROUP BY
        route.RouteId,
        route.AgencyId,
        route.RouteShortName,
        route.RouteLongName,
        route.AgencyName,
        route.RouteType
)
SELECT
    static_facts.RouteId,
    static_facts.RouteShortName,
    static_facts.RouteLongName,
    static_facts.AgencyId,
    static_facts.AgencyName,
    static_facts.RouteType,
    static_facts.LoadedTripCount,
    static_facts.StaticStopCount,
    static_facts.CologneStaticStopCount,
    CASE WHEN static_facts.CologneStaticStopCount > 0 THEN N'YES' ELSE N'NO' END
        AS LoadedTripServesCologneStop,
    realtime.RealtimeObservationCount,
    realtime.RealtimeAffectedStopPointCount,
    realtime.RealtimeObservationAtCologneStopCount,
    CASE WHEN realtime.RealtimeObservationAtCologneStopCount > 0 THEN N'YES' ELSE N'NO' END
        AS RealtimeObservationOccurredAtCologneMonitoredStop,
    static_locations.StaticStopLocations
FROM RouteStaticFacts AS static_facts
OUTER APPLY
(
    SELECT
        COUNT_BIG(DISTINCT missing.ObservationKey) AS RealtimeObservationCount,
        COUNT_BIG(DISTINCT missing.StopPointRef) AS RealtimeAffectedStopPointCount,
        COUNT_BIG(DISTINCT CASE WHEN missing.StopPointRef LIKE N'de:05315:%'
                                THEN missing.ObservationKey END)
            AS RealtimeObservationAtCologneStopCount
    FROM #StaticCoverageMissing AS missing
    INNER JOIN #RouteEvidence AS evidence
        ON evidence.ObservationKey = missing.ObservationKey
       AND evidence.RouteId COLLATE DATABASE_DEFAULT
             = static_facts.RouteId COLLATE DATABASE_DEFAULT
       AND evidence.EvidenceType = N'CurrentRuleLoadedRouteShortName'
) AS realtime
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), locations.LocationText), N'; ')
            AS StaticStopLocations
    FROM
    (
        SELECT DISTINCT TOP (100)
            CONVERT
            (
                NVARCHAR(4000),
                CONCAT
                (
                    CONVERT(NVARCHAR(4000), stop_time.StopId) COLLATE DATABASE_DEFAULT,
                    N' | ',
                    COALESCE(CONVERT(NVARCHAR(4000), stop.StopName) COLLATE DATABASE_DEFAULT, N'(NULL)'),
                    N' | Parent=',
                    COALESCE(CONVERT(NVARCHAR(4000), stop.ParentStation) COLLATE DATABASE_DEFAULT, N'(NULL)')
                )
            ) AS LocationText
        FROM stg.GtfsTrips AS trip
        INNER JOIN stg.GtfsStopTimes AS stop_time
            ON stop_time.TripId = trip.TripId
        LEFT JOIN stg.GtfsStops AS stop
            ON stop.StopId = stop_time.StopId
        WHERE trip.RouteId COLLATE DATABASE_DEFAULT
                  = static_facts.RouteId COLLATE DATABASE_DEFAULT
    ) AS locations
) AS static_locations
ORDER BY static_facts.RouteId;

/* 19. Explicit high-volume line-group investigation. */
WITH HighVolumeLine AS
(
    SELECT LineName
    FROM
    (
        VALUES
            (N'ICE'),
            (N'IC'),
            (N'RE 1 (RRX)'),
            (N'RE 5 (RRX)'),
            (N'RE 6 (RRX)')
    ) AS requested(LineName)
), LineTotals AS
(
    SELECT
        missing.LineName,
        COUNT_BIG(*) AS ObservationCount,
        COUNT_BIG(DISTINCT missing.StopPointRef) AS AffectedStopPointCount,
        COUNT_BIG(DISTINCT missing.LineRef) AS DistinctLineRefCount,
        COUNT_BIG(DISTINCT missing.JourneyRef) AS DistinctJourneyRefCount,
        COUNT_BIG(DISTINCT missing.OperatorRef) AS DistinctOperatorRefCount,
        COUNT_BIG(DISTINCT missing.PtMode) AS DistinctPtModeCount,
        COUNT_BIG(DISTINCT missing.RailSubmode) AS DistinctRailSubmodeCount
    FROM #StaticCoverageMissing AS missing
    GROUP BY missing.LineName
)
SELECT
    requested.LineName,
    ISNULL(line_totals.ObservationCount, 0) AS ObservationCount,
    ISNULL(line_totals.AffectedStopPointCount, 0) AS AffectedStopPointCount,
    ISNULL(line_totals.DistinctLineRefCount, 0) AS DistinctLineRefCount,
    ISNULL(line_totals.DistinctJourneyRefCount, 0) AS DistinctJourneyRefCount,
    ISNULL(line_totals.DistinctOperatorRefCount, 0) AS DistinctOperatorRefCount,
    ISNULL(line_totals.DistinctPtModeCount, 0) AS DistinctPtModeCount,
    ISNULL(line_totals.DistinctRailSubmodeCount, 0) AS DistinctRailSubmodeCount,
    refs.LineRefs,
    journeys.JourneyRefs,
    directions.DirectionRefs,
    operators.OperatorRefs,
    modes.PtModes,
    submodes.RailSubmodes,
    route_evidence.MatchingGtfsRouteIds,
    route_evidence.MatchingGtfsRouteShortNames,
    route_evidence.MatchingGtfsRouteLongNames,
    route_evidence.MatchingAgencies,
    schedule_counts.NoScheduleCandidateCount,
    schedule_counts.ExactlyOneScheduleCandidateCount,
    schedule_counts.MultipleScheduleCandidateCount,
    schedule_routes.ScheduleCandidateRouteIds,
    root_causes.RootCauseDistribution,
    CASE
        WHEN root_causes.RootCauseDistribution LIKE N'%CurrentRouteNameRuleMissesDeterministicStaticRoute%'
            THEN N'Current route-name rule is a supported contributor for this line group.'
        ELSE N'No unique route-independent schedule resolution was observed for this line group.'
    END AS DiagnosticConclusion
FROM HighVolumeLine AS requested
LEFT JOIN LineTotals AS line_totals
    ON line_totals.LineName = requested.LineName
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS LineRefs
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.LineRef) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS refs
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS JourneyRefs
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.JourneyRef) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS journeys
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS DirectionRefs
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.DirectionRef) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS directions
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS OperatorRefs
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.OperatorRef) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS operators
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS PtModes
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.PtMode) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS modes
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.ValueText), N'; ') AS RailSubmodes
    FROM
    (
        SELECT DISTINCT CONVERT(NVARCHAR(4000), missing.RailSubmode) AS ValueText
        FROM #StaticCoverageMissing AS missing
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS submodes
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.RouteId), N'; ') AS MatchingGtfsRouteIds,
        STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.RouteShortName), N'; ') AS MatchingGtfsRouteShortNames,
        STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.RouteLongName), N'; ') AS MatchingGtfsRouteLongNames,
        STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.AgencyName), N'; ') AS MatchingAgencies
    FROM
    (
        SELECT DISTINCT
            evidence.RouteId,
            COALESCE(evidence.RouteShortName, N'(NULL)') AS RouteShortName,
            COALESCE(evidence.RouteLongName, N'(NULL)') AS RouteLongName,
            COALESCE(evidence.AgencyName, N'(NULL)') AS AgencyName
        FROM #RouteEvidence AS evidence
        INNER JOIN #StaticCoverageMissing AS missing
            ON missing.ObservationKey = evidence.ObservationKey
        WHERE missing.LineName = requested.LineName
          AND evidence.EvidenceType IN
          (
              N'LineRefEqualsRouteId',
              N'TrimmedLineNameEqualsRouteLongName',
              N'SpaceNormalizedLineNameEqualsRouteLongName',
              N'TrimmedLineNameEqualsRouteShortName',
              N'CurrentRuleLoadedRouteShortName'
          )
    ) AS values_list
) AS route_evidence
OUTER APPLY
(
    SELECT
        SUM(CASE WHEN diagnostic.ScheduleCandidateCount = 0 THEN 1 ELSE 0 END)
            AS NoScheduleCandidateCount,
        SUM(CASE WHEN diagnostic.ScheduleCandidateCount = 1 THEN 1 ELSE 0 END)
            AS ExactlyOneScheduleCandidateCount,
        SUM(CASE WHEN diagnostic.ScheduleCandidateCount > 1 THEN 1 ELSE 0 END)
            AS MultipleScheduleCandidateCount
    FROM #RootCause AS diagnostic
    WHERE diagnostic.LineName = requested.LineName
) AS schedule_counts
OUTER APPLY
(
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), values_list.RouteId), N'; ') AS ScheduleCandidateRouteIds
    FROM
    (
        SELECT DISTINCT candidate.RouteId
        FROM #ScheduleCandidate AS candidate
        INNER JOIN #StaticCoverageMissing AS missing
            ON missing.ObservationKey = candidate.ObservationKey
        WHERE missing.LineName = requested.LineName
    ) AS values_list
) AS schedule_routes
OUTER APPLY
(
    SELECT STRING_AGG
    (
        CONVERT
        (
            NVARCHAR(MAX),
            CONCAT
            (
                CONVERT(NVARCHAR(4000), values_list.RootCauseCategory) COLLATE DATABASE_DEFAULT,
                N'=',
                values_list.CategoryCount
            )
        ),
        N'; '
    ) AS RootCauseDistribution
    FROM
    (
        SELECT
            diagnostic.RootCauseCategory,
            COUNT_BIG(*) AS CategoryCount
        FROM #RootCause AS diagnostic
        WHERE diagnostic.LineName = requested.LineName
        GROUP BY diagnostic.RootCauseCategory
    ) AS values_list
) AS root_causes
ORDER BY CASE requested.LineName
             WHEN N'ICE' THEN 1
             WHEN N'IC' THEN 2
             WHEN N'RE 1 (RRX)' THEN 3
             WHEN N'RE 5 (RRX)' THEN 4
             WHEN N'RE 6 (RRX)' THEN 5
             ELSE 6
         END;

/* 20. Observation-level root-cause distribution. */
SELECT
    root_cause.RootCauseCategory,
    COUNT_BIG(*) AS ObservationCount,
    CONVERT
    (
        DECIMAL(18, 8),
        COUNT_BIG(*) / NULLIF(CONVERT(DECIMAL(28, 8), (SELECT COUNT_BIG(*) FROM #RootCause)), 0)
    ) AS ObservationPercent,
    COUNT_BIG(DISTINCT root_cause.LineName) AS DistinctLineNameCount,
    COUNT_BIG(DISTINCT root_cause.LineRef) AS DistinctLineRefCount,
    COUNT_BIG(DISTINCT root_cause.StopPointRef) AS DistinctStopPointRefCount,
    MAX(root_cause.RootCauseExplanation) AS DiagnosticExplanation
FROM #RootCause AS root_cause
GROUP BY root_cause.RootCauseCategory
ORDER BY root_cause.RootCauseCategory;

/* 21. Complete affected-line and root-cause table. */
WITH LineRefs AS
(
    SELECT DISTINCT
        root_cause.LineName,
        root_cause.RootCauseCategory,
        root_cause.LineRef
    FROM #RootCause AS root_cause
), LineRefList AS
(
    SELECT
        refs.LineName,
        refs.RootCauseCategory,
        STRING_AGG(CONVERT(NVARCHAR(MAX), refs.LineRef), N'; ') AS LineRefs
    FROM LineRefs AS refs
    GROUP BY refs.LineName, refs.RootCauseCategory
)
SELECT
    root_cause.LineName,
    ref_list.LineRefs,
    root_cause.RootCauseCategory,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT root_cause.StopPointRef) AS StopPointCount,
    MAX(root_cause.RootCauseExplanation) AS DiagnosticExplanation
FROM #RootCause AS root_cause
LEFT JOIN LineRefList AS ref_list
    ON ref_list.LineName = root_cause.LineName
   AND ref_list.RootCauseCategory = root_cause.RootCauseCategory
GROUP BY root_cause.LineName, ref_list.LineRefs, root_cause.RootCauseCategory
ORDER BY root_cause.LineName, root_cause.RootCauseCategory;

/* 22. Evidence-based answer to whether the current route-name rule is material. */
SELECT
    CASE
        WHEN current_rule.CurrentRuleMissObservationCount = 0 THEN N'NO'
        WHEN current_rule.CurrentRuleMissObservationCount = current_rule.TotalMissingObservationCount
            THEN N'YES'
        ELSE N'PARTIALLY'
    END AS CurrentRouteShortNameRuleConclusion,
    current_rule.TotalMissingObservationCount,
    current_rule.CurrentRuleMissObservationCount AS DeterministicallyRecoverableObservationCount,
    CONVERT
    (
        DECIMAL(18, 8),
        current_rule.CurrentRuleMissObservationCount
        / NULLIF(CONVERT(DECIMAL(28, 8), current_rule.TotalMissingObservationCount), 0)
    ) AS DeterministicallyRecoverableObservationPercent,
    current_rule.OutsideScopeObservationCount,
    current_rule.NoMatchingRouteObservationCount,
    current_rule.AmbiguousScheduleObservationCount,
    current_rule.StaticStopOrScheduleEvidenceMissingObservationCount,
    current_rule.UnexplainedObservationCount,
    N'CurrentRuleNameRuleMissesDeterministicStaticRoute is limited to observations with one route-independent candidate or one candidate after an individual exact identifier test; no production match is changed.'
        AS Interpretation
FROM
(
    SELECT
        COUNT_BIG(*) AS TotalMissingObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'CurrentRouteNameRuleMissesDeterministicStaticRoute'
                 THEN 1 ELSE 0 END) AS CurrentRuleMissObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'StaticRouteExistsButOutsideCurrentCologneScope'
                 THEN 1 ELSE 0 END) AS OutsideScopeObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'NoMatchingRouteInLoadedStaticFeed'
                 THEN 1 ELSE 0 END) AS NoMatchingRouteObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'StaticScheduleCandidateAmbiguous'
                 THEN 1 ELSE 0 END) AS AmbiguousScheduleObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'StaticStopOrScheduleEvidenceMissing'
                 THEN 1 ELSE 0 END) AS StaticStopOrScheduleEvidenceMissingObservationCount,
        SUM(CASE WHEN root_cause.RootCauseCategory = N'Unexplained'
                 THEN 1 ELSE 0 END) AS UnexplainedObservationCount
    FROM #RootCause AS root_cause
) AS current_rule;

/* 23. Diagnostic evaluation of candidate route-resolution strategies. */
WITH StrategyRows AS
(
    SELECT
        N'LineRef -> RouteId' AS StrategyName,
        strategy.LineRefRouteIdCount AS CandidateCount
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus = N'StaticCoverageMissing'
    UNION ALL
    SELECT
        N'LineName -> loaded RouteShortName',
        strategy.RouteShortNameRouteCount
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus = N'StaticCoverageMissing'
    UNION ALL
    SELECT
        N'LineName -> RouteLongName (trimmed or spaces removed)',
        strategy.RouteLongNameRouteCount
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus = N'StaticCoverageMissing'
    UNION ALL
    SELECT
        N'Unique stop + service date + scheduled time candidate',
        strategy.ScheduleCandidateCount
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus = N'StaticCoverageMissing'
)
SELECT
    strategy_rows.StrategyName,
    COUNT_BIG(*) AS StaticCoverageMissingObservationCount,
    SUM(CASE WHEN strategy_rows.CandidateCount > 0 THEN 1 ELSE 0 END)
        AS EvidenceObservationCount,
    SUM(CASE WHEN strategy_rows.CandidateCount = 1 THEN 1 ELSE 0 END)
        AS UniqueResolutionObservationCount,
    SUM(CASE WHEN strategy_rows.CandidateCount > 1 THEN 1 ELSE 0 END)
        AS AmbiguousResolutionObservationCount,
    SUM(CASE WHEN strategy_rows.CandidateCount = 0 THEN 1 ELSE 0 END)
        AS NoEvidenceObservationCount,
    CASE
        WHEN strategy_rows.StrategyName = N'Unique stop + service date + scheduled time candidate'
            THEN N'Deterministic schedule candidate count without any route-name join.'
        WHEN strategy_rows.StrategyName = N'LineName -> loaded RouteShortName'
            THEN N'Loaded-feed RouteShortName evidence; current Cologne-serving scope is not applied by this diagnostic count.'
        ELSE N'Exact deterministic identifier/label evidence only; no fuzzy matching.'
    END AS StrategyDefinition
FROM StrategyRows AS strategy_rows
GROUP BY strategy_rows.StrategyName;

/* 24. Regression safety against currently successful matches. */
WITH SuccessfulStrategy AS
(
    SELECT
        N'LineRef -> RouteId' AS StrategyName,
        strategy.ObservationKey,
        strategy.MatchedRouteId,
        strategy.LineRefRouteIdCount AS CandidateCount,
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #RouteEvidence AS evidence
                WHERE evidence.ObservationKey = strategy.ObservationKey
                  AND evidence.EvidenceType = N'LineRefEqualsRouteId'
                  AND evidence.RouteId COLLATE DATABASE_DEFAULT
                        = strategy.MatchedRouteId COLLATE DATABASE_DEFAULT
            ) THEN 1 ELSE 0 END
        ) AS SameRouteEvidence
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
    UNION ALL
    SELECT
        N'LineName -> loaded RouteShortName',
        strategy.ObservationKey,
        strategy.MatchedRouteId,
        strategy.RouteShortNameRouteCount,
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #RouteEvidence AS evidence
                WHERE evidence.ObservationKey = strategy.ObservationKey
                  AND evidence.EvidenceType = N'CurrentRuleLoadedRouteShortName'
                  AND evidence.RouteId COLLATE DATABASE_DEFAULT
                        = strategy.MatchedRouteId COLLATE DATABASE_DEFAULT
            ) THEN 1 ELSE 0 END
        )
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
    UNION ALL
    SELECT
        N'LineName -> RouteLongName (trimmed or spaces removed)',
        strategy.ObservationKey,
        strategy.MatchedRouteId,
        strategy.RouteLongNameRouteCount,
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #RouteEvidence AS evidence
                WHERE evidence.ObservationKey = strategy.ObservationKey
                  AND evidence.EvidenceType IN
                  (
                      N'TrimmedLineNameEqualsRouteLongName',
                      N'SpaceNormalizedLineNameEqualsRouteLongName'
                  )
                  AND evidence.RouteId COLLATE DATABASE_DEFAULT
                        = strategy.MatchedRouteId COLLATE DATABASE_DEFAULT
            ) THEN 1 ELSE 0 END
        )
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
    UNION ALL
    SELECT
        N'Unique stop + service date + scheduled time candidate',
        strategy.ObservationKey,
        strategy.MatchedRouteId,
        strategy.ScheduleCandidateRouteCount,
        CONVERT
        (
            BIT,
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM #ScheduleCandidate AS candidate
                WHERE candidate.ObservationKey = strategy.ObservationKey
                  AND candidate.RouteId COLLATE DATABASE_DEFAULT
                        = strategy.MatchedRouteId COLLATE DATABASE_DEFAULT
            ) THEN 1 ELSE 0 END
        )
    FROM #StrategyObservation AS strategy
    WHERE strategy.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
)
SELECT
    successful_strategy.StrategyName,
    COUNT_BIG(*) AS SuccessfulObservationCount,
    SUM(CASE WHEN successful_strategy.CandidateCount = 1
                  AND successful_strategy.SameRouteEvidence = 1
             THEN 1 ELSE 0 END) AS PreserveSameRouteCount,
    SUM(CASE WHEN successful_strategy.CandidateCount = 1
                  AND successful_strategy.SameRouteEvidence = 0
             THEN 1 ELSE 0 END) AS ConflictingRouteCount,
    SUM(CASE WHEN successful_strategy.CandidateCount > 1 THEN 1 ELSE 0 END)
        AS AmbiguousCandidateCount,
    SUM(CASE WHEN successful_strategy.CandidateCount = 0 THEN 1 ELSE 0 END)
        AS NoEvidenceCount,
    CASE
        WHEN SUM(CASE WHEN successful_strategy.CandidateCount = 1
                           AND successful_strategy.SameRouteEvidence = 0
                      THEN 1 ELSE 0 END) = 0
         AND SUM(CASE WHEN successful_strategy.CandidateCount > 1 THEN 1 ELSE 0 END) = 0
            THEN N'No conflicting or ambiguous candidate evidence observed.'
        ELSE N'Candidate evidence requires review before any production change.'
    END AS RegressionSafetyConclusion
FROM SuccessfulStrategy AS successful_strategy
GROUP BY successful_strategy.StrategyName;

/* 25. Full reconciliation of diagnostic assignment. */
SELECT
    (SELECT COUNT_BIG(*) FROM #StaticCoverageMissing)
        AS StaticCoverageMissingCount,
    (SELECT COUNT_BIG(*) FROM #RootCause)
        AS RootCauseAssignedObservationCount,
    (
        SELECT COUNT_BIG(*)
        FROM
        (
            SELECT DISTINCT observation.LineName
            FROM #StaticCoverageMissing AS observation
        ) AS affected_lines
    ) AS StaticCoverageMissingDistinctLineNameCount,
    (
        SELECT COUNT_BIG(*)
        FROM
        (
            SELECT DISTINCT root_cause.LineName
            FROM #RootCause AS root_cause
        ) AS assigned_lines
    ) AS RootCauseDistinctLineNameCount,
    (
        SELECT COUNT_BIG(DISTINCT observation.StopPointRef)
        FROM #StaticCoverageMissing AS observation
    ) AS StaticCoverageMissingDistinctStopPointRefCount,
    (
        SELECT COUNT_BIG(DISTINCT root_cause.StopPointRef)
        FROM #RootCause AS root_cause
    ) AS RootCauseDistinctStopPointRefCount,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #StaticCoverageMissing)
                 = (SELECT COUNT_BIG(*) FROM #RootCause)
         AND
             (
                 SELECT COUNT_BIG(*)
                 FROM
                 (
                     SELECT DISTINCT observation.LineName
                     FROM #StaticCoverageMissing AS observation
                 ) AS affected_lines
             )
                 =
             (
                 SELECT COUNT_BIG(*)
                 FROM
                 (
                     SELECT DISTINCT root_cause.LineName
                     FROM #RootCause AS root_cause
                 ) AS assigned_lines
             )
         AND
             (
                 SELECT COUNT_BIG(DISTINCT observation.StopPointRef)
                 FROM #StaticCoverageMissing AS observation
             )
                 =
             (
                 SELECT COUNT_BIG(DISTINCT root_cause.StopPointRef)
                 FROM #RootCause AS root_cause
             )
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS RootCauseReconciliationStatus;

/*
    26. Scope-separated quality results.

    The historical root-cause sections above intentionally continue to
    describe the raw technical StaticCoverageMissing population.  The result
    below adds the Cologne analytical view without rewriting those findings.
*/
SELECT
    COUNT_BIG(*) AS RawRealtimeObservationCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfAnalyticalTransportScopeObservationCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InAnalyticalTransportScopeObservationCount,
    SUM(CASE WHEN observation.MatchStatus = N'StaticCoverageMissing'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS RawTechnicalStaticCoverageMissingCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 0
                  AND observation.MatchStatus = N'StaticCoverageMissing'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfScopeStaticCoverageMissingCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                  AND observation.MatchStatus = N'StaticCoverageMissing'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeStaticCoverageMissingCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                  AND observation.MatchStatus = N'Unresolved'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeUnresolvedCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                  AND observation.MatchStatus = N'ExactStopMatch'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeExactStopMatchCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                  AND observation.MatchStatus = N'ParentStationFallback'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeParentStationFallbackCount,
    SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                  AND observation.MatchStatus IN
                      (N'ExactStopMatch', N'ParentStationFallback')
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeUsableMatchCount,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                      AND observation.MatchStatus = N'StaticCoverageMissing'
                 THEN CONVERT(DECIMAL(28, 8), 1)
                 ELSE CONVERT(DECIMAL(28, 8), 0) END)
        / NULLIF
          (
              SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                       THEN CONVERT(DECIMAL(28, 8), 1)
                       ELSE CONVERT(DECIMAL(28, 8), 0) END),
              0
          )
    ) AS InScopeStaticCoverageMissingRate,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                      AND observation.MatchStatus IN
                          (N'ExactStopMatch', N'ParentStationFallback')
                 THEN CONVERT(DECIMAL(28, 8), 1)
                 ELSE CONVERT(DECIMAL(28, 8), 0) END)
        / NULLIF
          (
              SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                       THEN CONVERT(DECIMAL(28, 8), 1)
                       ELSE CONVERT(DECIMAL(28, 8), 0) END),
              0
          )
    ) AS InScopeUsableMatchRate,
    CASE
        WHEN COUNT_BIG(*) =
             SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 0
                      THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
             +
             SUM(CASE WHEN observation.IsInAnalyticalTransportScope = 1
                      THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS ScopeRowReconciliationStatus
FROM #Observation AS observation;

/* 27. Complete excluded long-distance population with parent-station rollup. */
SELECT
    observation.LineName,
    observation.LineRef,
    observation.PtMode,
    observation.RailSubmode,
    observation.OperatorRef,
    observation.AnalyticalParentStationId AS ParentStationId,
    observation.AnalyticalParentStationName AS ParentStationName,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT observation.AnalyticalParentStationId)
        AS DistinctParentStationCount,
    COUNT_BIG(DISTINCT observation.StopPointRef)
        AS DistinctStopPointRefCount
FROM #Observation AS observation
WHERE observation.IsInAnalyticalTransportScope = 0
GROUP BY
    observation.LineName,
    observation.LineRef,
    observation.PtMode,
    observation.RailSubmode,
    observation.OperatorRef,
    observation.AnalyticalParentStationId,
    observation.AnalyticalParentStationName
ORDER BY observation.LineName, ObservationCount DESC, ParentStationId;

/* 28. Explicit ICE and IC parent-station distributions. */
SELECT
    CASE
        WHEN observation.LineName LIKE N'ICE%' THEN N'ICE'
        WHEN observation.LineName = N'IC' THEN N'IC'
    END AS LongDistanceServiceClass,
    observation.AnalyticalParentStationId AS ParentStationId,
    observation.AnalyticalParentStationName AS ParentStationName,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT observation.StopPointRef)
        AS DistinctStopPointRefCount
FROM #Observation AS observation
WHERE observation.IsInAnalyticalTransportScope = 0
  AND
  (
      observation.LineName LIKE N'ICE%'
      OR observation.LineName = N'IC'
  )
GROUP BY
    CASE
        WHEN observation.LineName LIKE N'ICE%' THEN N'ICE'
        WHEN observation.LineName = N'IC' THEN N'IC'
    END,
    observation.AnalyticalParentStationId,
    observation.AnalyticalParentStationName
ORDER BY LongDistanceServiceClass, ObservationCount DESC, ParentStationId;

/* 29. Final in-scope StaticCoverageMissing worklist with existing root cause. */
WITH LineRefs AS
(
    SELECT DISTINCT
        root_cause.LineName,
        root_cause.RootCauseCategory,
        root_cause.LineRef
    FROM #RootCause AS root_cause
    INNER JOIN #Observation AS observation
        ON observation.ObservationKey = root_cause.ObservationKey
    WHERE observation.IsInAnalyticalTransportScope = 1
), LineRefList AS
(
    SELECT
        refs.LineName,
        refs.RootCauseCategory,
        STRING_AGG(CONVERT(NVARCHAR(MAX), refs.LineRef), N'; ') AS LineRefs
    FROM LineRefs AS refs
    GROUP BY refs.LineName, refs.RootCauseCategory
)
SELECT
    root_cause.LineName,
    ref_list.LineRefs,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT root_cause.StopPointRef) AS StopPointCount,
    COUNT_BIG(DISTINCT observation.AnalyticalParentStationId)
        AS ParentStationCount,
    root_cause.PtMode,
    root_cause.RailSubmode,
    root_cause.RootCauseCategory AS ExistingRootCauseCategory,
    MAX(root_cause.RootCauseExplanation) AS ExistingRootCauseExplanation
FROM #RootCause AS root_cause
INNER JOIN #Observation AS observation
    ON observation.ObservationKey = root_cause.ObservationKey
LEFT JOIN LineRefList AS ref_list
    ON ref_list.LineName = root_cause.LineName
   AND ref_list.RootCauseCategory = root_cause.RootCauseCategory
WHERE observation.IsInAnalyticalTransportScope = 1
GROUP BY
    root_cause.LineName,
    ref_list.LineRefs,
    root_cause.PtMode,
    root_cause.RailSubmode,
    root_cause.RootCauseCategory
ORDER BY root_cause.LineName, root_cause.RootCauseCategory;
