USE CologneTransitIntelligence;

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Focused validation for the StaticCoverageMissing RouteLongName fallback.

    This script intentionally reconstructs the v131 SHORT-NAME-ONLY behavior
    independently of wrk.vwCologneRealtimeTripMatch. It does not reuse the
    modified production view as its legacy baseline. Both the reconstructed
    baseline and the live implementation use the same frozen observation scope
    captured from stg.MddRealtimeStopObservation and are compared by
    ObservationKey.

    This is a semantic-fix validator, not a replacement for
    04-validate-realtime-trip-match-rewrite.sql. That historical script proves
    that the earlier warehouse-direct rewrite preserved the older semantics;
    this script intentionally expects only the proven RouteLongName fallback
    population to differ.

    The script is read-only apart from session-scoped temporary tables. It does
    not refresh dw.FactOperationalStopOutcome and does not alter collector,
    sampling, timing, Power BI, or warehouse data.
*/

DROP TABLE IF EXISTS #RouteLongNameCoverage;
DROP TABLE IF EXISTS #RouteShortNameCoverage;
DROP TABLE IF EXISTS #StaticCoverageFallbackScope;
DROP TABLE IF EXISTS #LegacyTripMatch;
DROP TABLE IF EXISTS #NewTripMatch;
DROP TABLE IF EXISTS #LegacySuccessfulState;
DROP TABLE IF EXISTS #NewProtectedState;
DROP TABLE IF EXISTS #SuccessfulMatchRegression;
DROP TABLE IF EXISTS #LegacyUnresolvedState;
DROP TABLE IF EXISTS #NewUnresolvedState;
DROP TABLE IF EXISTS #LegacyUnresolvedChanged;
DROP TABLE IF EXISTS #RowGrainViolations;
DROP TABLE IF EXISTS #NewMatchViolations;
DROP TABLE IF EXISTS #NewFallbackResolved;

/* 1. Freeze one identical observation scope for both implementations. */
CREATE TABLE #StaticCoverageFallbackScope
(
    ObservationKey BIGINT NOT NULL
        CONSTRAINT PK_StaticCoverageFallbackScope PRIMARY KEY
);

INSERT INTO #StaticCoverageFallbackScope (ObservationKey)
SELECT DISTINCT ObservationKey
FROM stg.MddRealtimeStopObservation;

/* 2. Reconstruct the v131 RouteShortName-only baseline independently. */
;WITH RouteCoverage AS
(
    SELECT DISTINCT
        REPLACE(RouteShortName, N' ', N'') AS NormalizedRouteName
    FROM wrk.vwCologneServingRoute
    WHERE RouteShortName IS NOT NULL
),
Candidate AS
(
    SELECT
        r.ObservationKey,

        trip.TripId,
        route.RouteId,
        service.ServiceId,

        stop.StopId AS StaticMatchedStopId,

        stop_event.ScheduledStopEventKey,
        trip.TripKey,
        stop_event.RouteKey,
        stop_event.StopKey,
        stop_event.ModeKey,
        stop_event.ServiceKey,
        date_dimension.DateKey,
        date_dimension.DateValue AS ServiceDate,

        CASE
            WHEN stop.StopId = r.StopPointRef
            THEN 1
            ELSE 0
        END AS IsExactStopMatch,

        CASE
            WHEN stop.ParentStationId = r.StaticParentStationId
            THEN 1
            ELSE 0
        END AS IsParentStationMatch

    FROM wrk.vwCologneRealtimeTripMatchKey AS r

    INNER JOIN #StaticCoverageFallbackScope AS scope
        ON scope.ObservationKey = r.ObservationKey

    INNER JOIN dw.DimRoute AS route
        ON REPLACE(route.RouteShortName, N' ', N'')
         = REPLACE(r.LineName, N' ', N'')

    INNER JOIN dw.FactScheduledStopEvent AS stop_event
        ON stop_event.RouteKey = route.RouteKey
       AND stop_event.ScheduledArrivalSecondOfDay =
             r.ScheduledArrivalSecondsLocal

    INNER JOIN dw.FactScheduledTrip AS trip
        ON trip.TripKey = stop_event.TripKey

    INNER JOIN dw.DimStop AS stop
        ON stop.StopKey = stop_event.StopKey

    INNER JOIN dw.DimService AS service
        ON service.ServiceKey = stop_event.ServiceKey

    INNER JOIN dw.BridgeServiceDate AS bridge_service_date
        ON bridge_service_date.ServiceKey = service.ServiceKey

    INNER JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = bridge_service_date.DateKey
       AND date_dimension.DateValue =
           DATEADD(
               DAY,
               -stop_event.ArrivalDayOffset,
               r.ServiceDateLocal
           )
),
CandidateSummary AS
(
    SELECT
        ObservationKey,

        SUM(IsExactStopMatch) AS ExactStopCandidateCount,
        SUM(IsParentStationMatch) AS ParentStationCandidateCount,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN TripId END)
            AS ExactTripId,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN TripId END)
            AS ParentTripId,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN RouteId END)
            AS ExactRouteId,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN RouteId END)
            AS ParentRouteId,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN ServiceId END)
            AS ExactServiceId,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN ServiceId END)
            AS ParentServiceId,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN StaticMatchedStopId END)
            AS ExactStaticStopId,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN StaticMatchedStopId END)
            AS ParentStaticStopId,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN ScheduledStopEventKey END)
            AS ExactScheduledStopEventKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN ScheduledStopEventKey END)
            AS ParentScheduledStopEventKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN TripKey END)
            AS ExactTripKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN TripKey END)
            AS ParentTripKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN RouteKey END)
            AS ExactRouteKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN RouteKey END)
            AS ParentRouteKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN StopKey END)
            AS ExactStopKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN StopKey END)
            AS ParentStopKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN ModeKey END)
            AS ExactModeKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN ModeKey END)
            AS ParentModeKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN ServiceKey END)
            AS ExactServiceKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN ServiceKey END)
            AS ParentServiceKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN DateKey END)
            AS ExactDateKey,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN DateKey END)
            AS ParentDateKey,

        MAX(CASE WHEN IsExactStopMatch = 1 THEN ServiceDate END)
            AS ExactServiceDate,
        MAX(CASE WHEN IsParentStationMatch = 1 THEN ServiceDate END)
            AS ParentServiceDate

    FROM Candidate
    GROUP BY ObservationKey
)
SELECT
    r.ObservationKey,
    r.LineName,
    r.StopPointRef,
    r.StaticParentStationId,

    ISNULL(cs.ExactStopCandidateCount, 0)
        AS ExactStopCandidateCount,
    ISNULL(cs.ParentStationCandidateCount, 0)
        AS ParentStationCandidateCount,

    CASE
        WHEN rc.NormalizedRouteName IS NULL
            THEN N'StaticCoverageMissing'

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN N'ExactStopMatch'

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN N'ParentStationFallback'

        ELSE N'Unresolved'
    END AS MatchStatus,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactTripId
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentTripId
    END AS MatchedTripId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactRouteId
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentRouteId
    END AS MatchedRouteId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceId
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceId
    END AS MatchedServiceId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactStaticStopId
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentStaticStopId
    END AS MatchedStaticStopId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactScheduledStopEventKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentScheduledStopEventKey
    END AS ScheduledStopEventKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactTripKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentTripKey
    END AS TripKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactRouteKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentRouteKey
    END AS RouteKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactStopKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentStopKey
    END AS StopKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactModeKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentModeKey
    END AS ModeKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceKey
    END AS ServiceKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactDateKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentDateKey
    END AS DateKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceDate
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceDate
    END AS ServiceDate
INTO #LegacyTripMatch
FROM wrk.vwCologneRealtimeTripMatchKey AS r
INNER JOIN #StaticCoverageFallbackScope AS scope
    ON scope.ObservationKey = r.ObservationKey
LEFT JOIN CandidateSummary AS cs
    ON cs.ObservationKey = r.ObservationKey
LEFT JOIN RouteCoverage AS rc
    ON rc.NormalizedRouteName = REPLACE(r.LineName, N' ', N'');

CREATE UNIQUE CLUSTERED INDEX UX_LegacyTripMatch_ObservationKey
    ON #LegacyTripMatch (ObservationKey);

/* 3. Materialize the deployed implementation over the same frozen scope. */
SELECT
    current_match.ObservationKey,
    current_match.LineName,
    current_match.StopPointRef,
    current_match.StaticParentStationId,
    current_match.ExactStopCandidateCount,
    current_match.ParentStationCandidateCount,
    current_match.MatchStatus,
    current_match.MatchedTripId,
    current_match.MatchedRouteId,
    current_match.MatchedServiceId,
    current_match.MatchedStaticStopId,
    current_match.ScheduledStopEventKey,
    current_match.TripKey,
    current_match.RouteKey,
    current_match.StopKey,
    current_match.ModeKey,
    current_match.ServiceKey,
    current_match.DateKey,
    current_match.ServiceDate
INTO #NewTripMatch
FROM wrk.vwCologneRealtimeTripMatch AS current_match
INNER JOIN #StaticCoverageFallbackScope AS scope
    ON scope.ObservationKey = current_match.ObservationKey;

CREATE INDEX IX_NewTripMatch_ObservationKey
    ON #NewTripMatch (ObservationKey);

/* 4. Rebuild the route-coverage maps used by the fallback acceptance gate. */
SELECT DISTINCT
    CONVERT(NVARCHAR(255), REPLACE(RouteShortName, N' ', N''))
        AS NormalizedRouteShortName
INTO #RouteShortNameCoverage
FROM wrk.vwCologneServingRoute
WHERE RouteShortName IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_RouteShortNameCoverage_Name
    ON #RouteShortNameCoverage (NormalizedRouteShortName);

SELECT DISTINCT
    warehouse_route.RouteId,
    CONVERT
    (
        NVARCHAR(500),
        REPLACE(LTRIM(RTRIM(warehouse_route.RouteLongName)), N' ', N'')
    )
        AS NormalizedRouteLongName
INTO #RouteLongNameCoverage
FROM dw.DimRoute AS warehouse_route
INNER JOIN wrk.vwCologneServingRoute AS serving_route
    ON serving_route.RouteId COLLATE Latin1_General_100_BIN2
     = warehouse_route.RouteId COLLATE Latin1_General_100_BIN2
WHERE NULLIF(LTRIM(RTRIM(warehouse_route.RouteLongName)), N'') IS NOT NULL;

CREATE INDEX IX_RouteLongNameCoverage_Name
    ON #RouteLongNameCoverage (NormalizedRouteLongName, RouteId);

/* 5. Compare protected legacy state by ObservationKey. */
SELECT
    ObservationKey,
    MatchStatus,
    MatchedTripId,
    MatchedRouteId,
    MatchedServiceId,
    MatchedStaticStopId,
    ScheduledStopEventKey,
    TripKey,
    RouteKey,
    StopKey,
    ModeKey,
    ServiceKey,
    DateKey,
    ServiceDate
INTO #LegacySuccessfulState
FROM #LegacyTripMatch
WHERE MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback');

SELECT
    new_match.ObservationKey,
    new_match.MatchStatus,
    new_match.MatchedTripId,
    new_match.MatchedRouteId,
    new_match.MatchedServiceId,
    new_match.MatchedStaticStopId,
    new_match.ScheduledStopEventKey,
    new_match.TripKey,
    new_match.RouteKey,
    new_match.StopKey,
    new_match.ModeKey,
    new_match.ServiceKey,
    new_match.DateKey,
    new_match.ServiceDate
INTO #NewProtectedState
FROM #NewTripMatch AS new_match
INNER JOIN #LegacySuccessfulState AS legacy
    ON legacy.ObservationKey = new_match.ObservationKey;

SELECT
    difference.ObservationKey,
    difference.MatchStatus,
    difference.MatchedTripId,
    difference.MatchedRouteId,
    difference.MatchedServiceId,
    difference.MatchedStaticStopId,
    difference.ScheduledStopEventKey,
    difference.TripKey,
    difference.RouteKey,
    difference.StopKey,
    difference.ModeKey,
    difference.ServiceKey,
    difference.DateKey,
    difference.ServiceDate
INTO #SuccessfulMatchRegression
FROM
(
    SELECT * FROM #LegacySuccessfulState

    EXCEPT

    SELECT * FROM #NewProtectedState
) AS difference;

SELECT
    ObservationKey,
    MatchStatus,
    MatchedTripId,
    MatchedRouteId,
    MatchedServiceId,
    MatchedStaticStopId,
    ScheduledStopEventKey,
    TripKey,
    RouteKey,
    StopKey,
    ModeKey,
    ServiceKey,
    DateKey,
    ServiceDate
INTO #LegacyUnresolvedState
FROM #LegacyTripMatch
WHERE MatchStatus = N'Unresolved';

SELECT
    new_match.ObservationKey,
    new_match.MatchStatus,
    new_match.MatchedTripId,
    new_match.MatchedRouteId,
    new_match.MatchedServiceId,
    new_match.MatchedStaticStopId,
    new_match.ScheduledStopEventKey,
    new_match.TripKey,
    new_match.RouteKey,
    new_match.StopKey,
    new_match.ModeKey,
    new_match.ServiceKey,
    new_match.DateKey,
    new_match.ServiceDate
INTO #NewUnresolvedState
FROM #NewTripMatch AS new_match
INNER JOIN #LegacyUnresolvedState AS legacy
    ON legacy.ObservationKey = new_match.ObservationKey;

SELECT
    difference.ObservationKey,
    difference.MatchStatus,
    difference.MatchedTripId,
    difference.MatchedRouteId,
    difference.MatchedServiceId,
    difference.MatchedStaticStopId,
    difference.ScheduledStopEventKey,
    difference.TripKey,
    difference.RouteKey,
    difference.StopKey,
    difference.ModeKey,
    difference.ServiceKey,
    difference.DateKey,
    difference.ServiceDate
INTO #LegacyUnresolvedChanged
FROM
(
    SELECT * FROM #LegacyUnresolvedState

    EXCEPT

    SELECT * FROM #NewUnresolvedState
) AS difference;

/* 6. Row-grain violations are reported separately from semantic differences. */
CREATE TABLE #RowGrainViolations
(
    ValidationIssue NVARCHAR(80) NOT NULL,
    ObservationKey BIGINT NULL,
    ObservedRowCount BIGINT NULL
);

INSERT INTO #RowGrainViolations
(
    ValidationIssue,
    ObservationKey,
    ObservedRowCount
)
SELECT
    N'LegacyBaselineMissingObservation',
    scope.ObservationKey,
    0
FROM #StaticCoverageFallbackScope AS scope
LEFT JOIN #LegacyTripMatch AS legacy
    ON legacy.ObservationKey = scope.ObservationKey
WHERE legacy.ObservationKey IS NULL

UNION ALL

SELECT
    N'NewImplementationMissingObservation',
    scope.ObservationKey,
    0
FROM #StaticCoverageFallbackScope AS scope
LEFT JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = scope.ObservationKey
WHERE new_match.ObservationKey IS NULL

UNION ALL

SELECT
    N'NewImplementationDuplicateObservation',
    new_match.ObservationKey,
    COUNT_BIG(*)
FROM #NewTripMatch AS new_match
GROUP BY new_match.ObservationKey
HAVING COUNT_BIG(*) <> 1;

/* 7. Validate every newly accepted fallback match and long-name status gate. */
SELECT
    legacy.ObservationKey,
    new_match.LineName,
    new_match.StopPointRef,
    legacy.MatchStatus AS LegacyMatchStatus,
    new_match.MatchStatus AS NewMatchStatus,
    new_match.MatchedRouteId,
    new_match.ExactStopCandidateCount,
    new_match.ParentStationCandidateCount,
    CASE
        WHEN legacy.MatchStatus <> N'StaticCoverageMissing'
            THEN N'Legacy status was not StaticCoverageMissing'
        WHEN short_name.NormalizedRouteShortName IS NOT NULL
            THEN N'Legacy RouteShortName coverage existed'
        WHEN long_name.LongRouteCount = 0
            THEN N'No Cologne-serving RouteLongName coverage existed'
        WHEN matched_route.MatchedRouteCount = 0
            THEN N'Selected route was not a matching Cologne-serving RouteLongName route'
        WHEN new_match.MatchStatus = N'ExactStopMatch'
         AND new_match.ExactStopCandidateCount <> 1
            THEN N'ExactStopMatch did not have exactly one exact-stop candidate'
        WHEN new_match.MatchStatus = N'ParentStationFallback'
         AND
         (
             new_match.ExactStopCandidateCount <> 0
             OR new_match.ParentStationCandidateCount <> 1
         )
            THEN N'ParentStationFallback did not have zero exact and one parent candidate'
        WHEN new_match.MatchStatus = N'StaticCoverageMissing'
            THEN N'RouteLongName coverage was incorrectly classified as StaticCoverageMissing'
        ELSE N'Unclassified fallback validation violation'
    END AS ViolationReason
INTO #NewMatchViolations
FROM #LegacyTripMatch AS legacy
INNER JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
LEFT JOIN #RouteShortNameCoverage AS short_name
    ON short_name.NormalizedRouteShortName =
       REPLACE(new_match.LineName, N' ', N'')
OUTER APPLY
(
    SELECT COUNT_BIG(*) AS LongRouteCount
    FROM #RouteLongNameCoverage AS long_route
    WHERE long_route.NormalizedRouteLongName =
          REPLACE(LTRIM(RTRIM(new_match.LineName)), N' ', N'')
) AS long_name
OUTER APPLY
(
    SELECT COUNT_BIG(*) AS MatchedRouteCount
    FROM #RouteLongNameCoverage AS long_route
    WHERE long_route.NormalizedRouteLongName =
          REPLACE(LTRIM(RTRIM(new_match.LineName)), N' ', N'')
      AND long_route.RouteId COLLATE DATABASE_DEFAULT =
          new_match.MatchedRouteId COLLATE DATABASE_DEFAULT
) AS matched_route
WHERE
(
    new_match.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
    AND legacy.MatchStatus = N'StaticCoverageMissing'
    AND short_name.NormalizedRouteShortName IS NULL
    AND
    (
        long_name.LongRouteCount = 0
        OR matched_route.MatchedRouteCount = 0
        OR
        (
            new_match.MatchStatus = N'ExactStopMatch'
            AND new_match.ExactStopCandidateCount <> 1
        )
        OR
        (
            new_match.MatchStatus = N'ParentStationFallback'
            AND
            (
                new_match.ExactStopCandidateCount <> 0
                OR new_match.ParentStationCandidateCount <> 1
            )
        )
    )
)
OR
(
    legacy.MatchStatus = N'StaticCoverageMissing'
    AND short_name.NormalizedRouteShortName IS NULL
    AND long_name.LongRouteCount > 0
    AND new_match.MatchStatus = N'StaticCoverageMissing'
);

/* 8. Identify the intended fallback populations for reporting. */
SELECT
    new_match.ObservationKey,
    new_match.LineName,
    new_match.StopPointRef,
    new_match.MatchStatus AS NewMatchStatus,
    new_match.MatchedRouteId
INTO #NewFallbackResolved
FROM #LegacyTripMatch AS legacy
INNER JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
WHERE legacy.MatchStatus = N'StaticCoverageMissing'
  AND new_match.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
  AND NOT EXISTS
  (
      SELECT 1
      FROM #RouteShortNameCoverage AS short_name
      WHERE short_name.NormalizedRouteShortName =
            REPLACE(new_match.LineName, N' ', N'')
  );

/* 9. Result sets: row grain, protected populations, violations, and matrix. */
DECLARE @ScopeRowCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #StaticCoverageFallbackScope
);

DECLARE @LegacyRowCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #LegacyTripMatch
);

DECLARE @NewRowCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #NewTripMatch
);

DECLARE @LegacyDistinctObservationCount BIGINT =
(
    SELECT COUNT_BIG(DISTINCT ObservationKey)
    FROM #LegacyTripMatch
);

DECLARE @NewDistinctObservationCount BIGINT =
(
    SELECT COUNT_BIG(DISTINCT ObservationKey)
    FROM #NewTripMatch
);

SELECT
    @ScopeRowCount AS FrozenObservationCount,
    @LegacyRowCount AS LegacyRowCount,
    @LegacyDistinctObservationCount AS LegacyDistinctObservationCount,
    @LegacyRowCount - @LegacyDistinctObservationCount
        AS LegacyDuplicateObservationCount,
    @NewRowCount AS NewRowCount,
    @NewDistinctObservationCount AS NewDistinctObservationCount,
    @NewRowCount - @NewDistinctObservationCount
        AS NewDuplicateObservationCount,
    @NewRowCount - @LegacyRowCount AS NewMinusLegacyRowCount,
    (SELECT COUNT_BIG(*) FROM #SuccessfulMatchRegression)
        AS SuccessfulMatchRegressionCount,
    (SELECT COUNT_BIG(*) FROM #LegacyUnresolvedChanged)
        AS LegacyUnresolvedChangedCount,
    (SELECT COUNT_BIG(*) FROM #NewMatchViolations)
        AS NewMatchViolationCount,
    (SELECT COUNT_BIG(*) FROM #RowGrainViolations)
        AS RowGrainViolationCount,
    (SELECT COUNT_BIG(*) FROM #NewFallbackResolved)
        AS NewFallbackResolvedCount;

    SELECT
        N'ProtectedLegacySuccessfulMatches' AS ValidationGate,
        COUNT_BIG(*) AS LegacyObservationCount,
        (SELECT COUNT_BIG(*) FROM #SuccessfulMatchRegression)
            AS ChangedObservationCount,
        CAST(0 AS BIGINT) AS ExpectedChangedObservationCount
    FROM #LegacySuccessfulState;

SELECT
    N'LegacyUnresolvedPreservation' AS ValidationGate,
    COUNT_BIG(*) AS LegacyObservationCount,
    (SELECT COUNT_BIG(*) FROM #LegacyUnresolvedChanged)
        AS LegacyUnresolvedChangedCount,
    CAST(0 AS BIGINT) AS ExpectedChangedObservationCount
FROM #LegacyUnresolvedState;

SELECT
    N'NewFallbackValidation' AS ValidationGate,
    COUNT_BIG(*) AS ViolationCount,
    CAST(0 AS BIGINT) AS ExpectedViolationCount
FROM #NewMatchViolations;

SELECT
    N'RowGrainValidation' AS ValidationGate,
    COUNT_BIG(*) AS ViolationCount,
    CAST(0 AS BIGINT) AS ExpectedViolationCount
FROM #RowGrainViolations;

SELECT
    N'SuccessfulMatchRegression' AS ValidationIssue,
    legacy.ObservationKey,
    legacy.MatchStatus AS LegacyMatchStatus,
    new_match.MatchStatus AS NewMatchStatus,
    legacy.MatchedTripId AS LegacyMatchedTripId,
    new_match.MatchedTripId AS NewMatchedTripId,
    legacy.MatchedRouteId AS LegacyMatchedRouteId,
    new_match.MatchedRouteId AS NewMatchedRouteId,
    legacy.MatchedServiceId AS LegacyMatchedServiceId,
    new_match.MatchedServiceId AS NewMatchedServiceId,
    legacy.MatchedStaticStopId AS LegacyMatchedStaticStopId,
    new_match.MatchedStaticStopId AS NewMatchedStaticStopId,
    legacy.ScheduledStopEventKey AS LegacyScheduledStopEventKey,
    new_match.ScheduledStopEventKey AS NewScheduledStopEventKey,
    legacy.TripKey AS LegacyTripKey,
    new_match.TripKey AS NewTripKey,
    legacy.RouteKey AS LegacyRouteKey,
    new_match.RouteKey AS NewRouteKey,
    legacy.StopKey AS LegacyStopKey,
    new_match.StopKey AS NewStopKey,
    legacy.ModeKey AS LegacyModeKey,
    new_match.ModeKey AS NewModeKey,
    legacy.ServiceKey AS LegacyServiceKey,
    new_match.ServiceKey AS NewServiceKey,
    legacy.DateKey AS LegacyDateKey,
    new_match.DateKey AS NewDateKey,
    legacy.ServiceDate AS LegacyServiceDate,
    new_match.ServiceDate AS NewServiceDate
FROM #LegacySuccessfulState AS legacy
LEFT JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
WHERE EXISTS
(
    SELECT 1
    FROM #SuccessfulMatchRegression AS difference
    WHERE difference.ObservationKey = legacy.ObservationKey
);

SELECT
    N'LegacyUnresolvedChanged' AS ValidationIssue,
    legacy.ObservationKey,
    legacy.MatchStatus AS LegacyMatchStatus,
    new_match.MatchStatus AS NewMatchStatus,
    legacy.MatchedTripId AS LegacyMatchedTripId,
    new_match.MatchedTripId AS NewMatchedTripId,
    legacy.MatchedRouteId AS LegacyMatchedRouteId,
    new_match.MatchedRouteId AS NewMatchedRouteId,
    legacy.MatchedServiceId AS LegacyMatchedServiceId,
    new_match.MatchedServiceId AS NewMatchedServiceId,
    legacy.MatchedStaticStopId AS LegacyMatchedStaticStopId,
    new_match.MatchedStaticStopId AS NewMatchedStaticStopId,
    legacy.ScheduledStopEventKey AS LegacyScheduledStopEventKey,
    new_match.ScheduledStopEventKey AS NewScheduledStopEventKey,
    legacy.TripKey AS LegacyTripKey,
    new_match.TripKey AS NewTripKey,
    legacy.RouteKey AS LegacyRouteKey,
    new_match.RouteKey AS NewRouteKey,
    legacy.StopKey AS LegacyStopKey,
    new_match.StopKey AS NewStopKey,
    legacy.ModeKey AS LegacyModeKey,
    new_match.ModeKey AS NewModeKey,
    legacy.ServiceKey AS LegacyServiceKey,
    new_match.ServiceKey AS NewServiceKey,
    legacy.DateKey AS LegacyDateKey,
    new_match.DateKey AS NewDateKey,
    legacy.ServiceDate AS LegacyServiceDate,
    new_match.ServiceDate AS NewServiceDate
FROM #LegacyUnresolvedState AS legacy
LEFT JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
WHERE EXISTS
(
    SELECT 1
    FROM #LegacyUnresolvedChanged AS difference
    WHERE difference.ObservationKey = legacy.ObservationKey
);

SELECT
    N'NewFallbackValidationViolation' AS ValidationIssue,
    ObservationKey,
    LineName,
    StopPointRef,
    LegacyMatchStatus,
    NewMatchStatus,
    MatchedRouteId,
    ExactStopCandidateCount,
    ParentStationCandidateCount,
    ViolationReason
FROM #NewMatchViolations;

SELECT
    ValidationIssue,
    ObservationKey,
    ObservedRowCount
FROM #RowGrainViolations;

/* Complete 4 x 4 status migration matrix. */
;WITH Statuses AS
(
    SELECT N'ExactStopMatch' AS MatchStatus
    UNION ALL SELECT N'ParentStationFallback'
    UNION ALL SELECT N'StaticCoverageMissing'
    UNION ALL SELECT N'Unresolved'
),
Actual AS
(
    SELECT
        legacy.MatchStatus AS LegacyMatchStatus,
        new_match.MatchStatus AS NewMatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM #LegacyTripMatch AS legacy
    INNER JOIN #NewTripMatch AS new_match
        ON new_match.ObservationKey = legacy.ObservationKey
    GROUP BY legacy.MatchStatus, new_match.MatchStatus
)
SELECT
    legacy_status.MatchStatus AS LegacyMatchStatus,
    new_status.MatchStatus AS NewMatchStatus,
    ISNULL(actual.ObservationCount, 0) AS ObservationCount
FROM Statuses AS legacy_status
CROSS JOIN Statuses AS new_status
LEFT JOIN Actual AS actual
    ON actual.LegacyMatchStatus = legacy_status.MatchStatus
   AND actual.NewMatchStatus = new_status.MatchStatus
ORDER BY
    CASE legacy_status.MatchStatus
        WHEN N'ExactStopMatch' THEN 1
        WHEN N'ParentStationFallback' THEN 2
        WHEN N'StaticCoverageMissing' THEN 3
        WHEN N'Unresolved' THEN 4
    END,
    CASE new_status.MatchStatus
        WHEN N'ExactStopMatch' THEN 1
        WHEN N'ParentStationFallback' THEN 2
        WHEN N'StaticCoverageMissing' THEN 3
        WHEN N'Unresolved' THEN 4
    END;

SELECT
    legacy.MatchStatus AS LegacyMatchStatus,
    new_match.MatchStatus AS NewMatchStatus,
    COUNT_BIG(*) AS ObservationCount
FROM #LegacyTripMatch AS legacy
INNER JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
GROUP BY legacy.MatchStatus, new_match.MatchStatus
ORDER BY legacy.MatchStatus, new_match.MatchStatus;

/* 10. Report fallback resolutions and fallback-route unresolved rows. */
SELECT
    LineName,
    NewMatchStatus,
    MatchedRouteId,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT StopPointRef) AS DistinctStopPointRefCount
FROM #NewFallbackResolved
GROUP BY LineName, NewMatchStatus, MatchedRouteId
ORDER BY LineName, NewMatchStatus, MatchedRouteId;

SELECT
    new_match.LineName,
    COUNT_BIG(*) AS ObservationCount
FROM #LegacyTripMatch AS legacy
INNER JOIN #NewTripMatch AS new_match
    ON new_match.ObservationKey = legacy.ObservationKey
WHERE legacy.MatchStatus = N'StaticCoverageMissing'
  AND new_match.MatchStatus = N'Unresolved'
  AND NOT EXISTS
  (
      SELECT 1
      FROM #RouteShortNameCoverage AS short_name
      WHERE short_name.NormalizedRouteShortName =
            REPLACE(new_match.LineName, N' ', N'')
  )
  AND EXISTS
  (
      SELECT 1
      FROM #RouteLongNameCoverage AS long_name
      WHERE long_name.NormalizedRouteLongName =
            REPLACE(LTRIM(RTRIM(new_match.LineName)), N' ', N'')
  )
GROUP BY new_match.LineName
ORDER BY new_match.LineName;

/* 11. Fail closed after returning exact failing rows. */
DECLARE @SuccessfulMatchRegressionCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #SuccessfulMatchRegression
);

DECLARE @LegacyUnresolvedChangedCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #LegacyUnresolvedChanged
);

DECLARE @NewMatchViolationCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #NewMatchViolations
);

DECLARE @RowGrainViolationCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #RowGrainViolations
);

IF @SuccessfulMatchRegressionCount <> 0
   OR @LegacyUnresolvedChangedCount <> 0
   OR @NewMatchViolationCount <> 0
   OR @RowGrainViolationCount <> 0
   OR @LegacyRowCount <> @ScopeRowCount
   OR @NewRowCount <> @ScopeRowCount
   OR @LegacyDistinctObservationCount <> @LegacyRowCount
   OR @NewDistinctObservationCount <> @NewRowCount
BEGIN
    THROW 51010,
        'StaticCoverageMissing RouteLongName fallback validation FAILED.',
        1;
END;

PRINT 'StaticCoverageMissing RouteLongName fallback validation PASS.';
