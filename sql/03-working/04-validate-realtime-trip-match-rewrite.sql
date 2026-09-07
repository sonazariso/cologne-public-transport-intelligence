USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Frozen-scope semantic regression for wrk.vwCologneRealtimeTripMatch.

    Run this script in one SQL Server session. It freezes the append-only
    realtime observation keys first, reconstructs the preserved pre-rewrite
    implementation from Git commit 81ddb85 as the historical baseline, and
    compares it with the warehouse-direct implementation.

    The baseline deliberately references wrk.vwCologneScheduledStopEvent only
    as the preserved historical implementation. The production view under
    test must never use that working view for candidate lookup.

    The final CREATE OR ALTER VIEW is kept in
    03-create-cologne-realtime-working-layer.sql. If the production view is
    changed in this session, rerun the post-change block below against the
    same frozen baseline before closing the session.
*/

CREATE TABLE #TripMatchRegressionScope
(
    ObservationKey BIGINT NOT NULL
        CONSTRAINT PK_TripMatchRegressionScope PRIMARY KEY
);

INSERT INTO #TripMatchRegressionScope (ObservationKey)
SELECT DISTINCT ObservationKey
FROM stg.MddRealtimeStopObservation;

DECLARE @BaselineStartedAtUtc DATETIME2(7) = SYSUTCDATETIME();

SET STATISTICS TIME ON;
SET STATISTICS IO ON;

/*
    Materialize the preserved pre-rewrite baseline from Git commit 81ddb85.
    This is intentionally independent of the current production view, so the
    test remains valid when the live database is already warehouse-direct.
*/
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

        se.TripId,
        se.RouteId,
        se.ServiceId,
        se.RouteShortName,
        se.TripHeadsign,

        se.StopId AS StaticMatchedStopId,
        se.StopName AS StaticMatchedStopName,
        se.ParentStationId,

        CASE
            WHEN se.StopId = r.StopPointRef
            THEN 1
            ELSE 0
        END AS IsExactStopMatch,

        CASE
            WHEN se.ParentStationId = r.StaticParentStationId
            THEN 1
            ELSE 0
        END AS IsParentStationMatch

    FROM wrk.vwCologneRealtimeTripMatchKey AS r

    INNER JOIN #TripMatchRegressionScope AS scope
        ON scope.ObservationKey = r.ObservationKey

    INNER JOIN wrk.vwCologneScheduledStopEvent AS se
        ON REPLACE(se.RouteShortName, N' ', N'')
         = REPLACE(r.LineName, N' ', N'')

       AND se.ScheduledArrivalSeconds =
             r.ScheduledArrivalSecondsLocal
             + (se.ArrivalDayOffset * 86400)

    INNER JOIN dw.DimService AS ds
        ON ds.ServiceId COLLATE Latin1_General_100_BIN2
         = se.ServiceId COLLATE Latin1_General_100_BIN2

    INNER JOIN dw.BridgeServiceDate AS b
        ON b.ServiceKey = ds.ServiceKey

    INNER JOIN dw.DimDate AS d
        ON d.DateKey = b.DateKey

       AND d.DateValue =
           DATEADD(
               DAY,
               -se.ArrivalDayOffset,
               r.ServiceDateLocal
           )
),
CandidateSummary AS
(
    SELECT
        ObservationKey,

        SUM(IsExactStopMatch) AS ExactStopCandidateCount,
        SUM(IsParentStationMatch) AS ParentStationCandidateCount,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN TripId END
        ) AS ExactTripId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN TripId END
        ) AS ParentTripId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN RouteId END
        ) AS ExactRouteId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN RouteId END
        ) AS ParentRouteId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ServiceId END
        ) AS ExactServiceId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ServiceId END
        ) AS ParentServiceId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ExactStaticStopId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ParentStaticStopId

    FROM Candidate
    GROUP BY ObservationKey
)
SELECT
    r.*,

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
    END AS MatchedStaticStopId
INTO #TripMatchBaseline
FROM wrk.vwCologneRealtimeTripMatchKey AS r
JOIN #TripMatchRegressionScope AS scope
    ON scope.ObservationKey = r.ObservationKey
LEFT JOIN CandidateSummary AS cs
    ON cs.ObservationKey = r.ObservationKey
LEFT JOIN RouteCoverage AS rc
    ON rc.NormalizedRouteName = REPLACE(r.LineName, N' ', N'');

DECLARE @BaselineElapsedMilliseconds BIGINT =
    DATEDIFF_BIG(MILLISECOND, @BaselineStartedAtUtc, SYSUTCDATETIME());

DECLARE @ProposedStartedAtUtc DATETIME2(7) = SYSUTCDATETIME();

/* The proposed implementation uses only the warehouse static candidate path. */
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
        route.RouteShortName,
        trip.TripHeadsign,

        stop.StopId AS StaticMatchedStopId,
        stop.StopName AS StaticMatchedStopName,
        stop.ParentStationId,

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

    INNER JOIN #TripMatchRegressionScope AS scope
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

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN TripId END
        ) AS ExactTripId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN TripId END
        ) AS ParentTripId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN RouteId END
        ) AS ExactRouteId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN RouteId END
        ) AS ParentRouteId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ServiceId END
        ) AS ExactServiceId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ServiceId END
        ) AS ParentServiceId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ExactStaticStopId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ParentStaticStopId

    FROM Candidate
    GROUP BY ObservationKey
)
SELECT
    r.*,

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
    END AS MatchedStaticStopId
INTO #TripMatchProposed
FROM wrk.vwCologneRealtimeTripMatchKey AS r
JOIN #TripMatchRegressionScope AS scope
    ON scope.ObservationKey = r.ObservationKey
LEFT JOIN CandidateSummary AS cs
    ON cs.ObservationKey = r.ObservationKey
LEFT JOIN RouteCoverage AS rc
    ON rc.NormalizedRouteName = REPLACE(r.LineName, N' ', N'');

DECLARE @ProposedElapsedMilliseconds BIGINT =
    DATEDIFF_BIG(MILLISECOND, @ProposedStartedAtUtc, SYSUTCDATETIME());

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

DECLARE @FrozenObservationCount BIGINT;
DECLARE @BaselineRowCount BIGINT;
DECLARE @ProposedRowCount BIGINT;
DECLARE @BaselineDistinctObservationCount BIGINT;
DECLARE @ProposedDistinctObservationCount BIGINT;
DECLARE @BaselineDuplicateGrainRows BIGINT;
DECLARE @ProposedDuplicateGrainRows BIGINT;
DECLARE @CriticalBaselineOnly BIGINT;
DECLARE @CriticalProposedOnly BIGINT;
DECLARE @CompleteBaselineOnly BIGINT;
DECLARE @CompleteProposedOnly BIGINT;
DECLARE @GrainDifferenceCount BIGINT;
DECLARE @CriticalFieldDifferenceCount BIGINT;

SELECT @FrozenObservationCount = COUNT_BIG(*)
FROM #TripMatchRegressionScope;

SELECT
    @BaselineRowCount = COUNT_BIG(*),
    @BaselineDistinctObservationCount = COUNT_BIG(DISTINCT ObservationKey)
FROM #TripMatchBaseline;

SELECT
    @ProposedRowCount = COUNT_BIG(*),
    @ProposedDistinctObservationCount = COUNT_BIG(DISTINCT ObservationKey)
FROM #TripMatchProposed;

SET @BaselineDuplicateGrainRows =
    @BaselineRowCount - @BaselineDistinctObservationCount;
SET @ProposedDuplicateGrainRows =
    @ProposedRowCount - @ProposedDistinctObservationCount;

SELECT @CriticalBaselineOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline

    EXCEPT

    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchProposed
) AS difference;

SELECT @CriticalProposedOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchProposed

    EXCEPT

    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline
) AS difference;

SET @CriticalFieldDifferenceCount =
    @CriticalBaselineOnly + @CriticalProposedOnly;

/* Compare every output column, including NULL/value differences. */
SELECT @CompleteBaselineOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ObservedAtUtc,
        ResultId,
        StopPointRef,
        StopName,
        LineName,
        LineRef,
        JourneyRef,
        DirectionRef,
        OperatorRef,
        PtMode,
        RailSubmode,
        TimetabledArrivalUtc,
        EstimatedArrivalUtc,
        ArrivalDelayMinutes,
        PlannedBay,
        EstimatedBay,
        PlatformChanged,
        CreatedAtUtc,
        StaticParentStationId,
        StaticStopName,
        StaticStopMatched,
        TimetabledArrivalLocal,
        ServiceDateLocal,
        ScheduledArrivalSecondsLocal,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline

    EXCEPT

    SELECT
        ObservationKey,
        ObservedAtUtc,
        ResultId,
        StopPointRef,
        StopName,
        LineName,
        LineRef,
        JourneyRef,
        DirectionRef,
        OperatorRef,
        PtMode,
        RailSubmode,
        TimetabledArrivalUtc,
        EstimatedArrivalUtc,
        ArrivalDelayMinutes,
        PlannedBay,
        EstimatedBay,
        PlatformChanged,
        CreatedAtUtc,
        StaticParentStationId,
        StaticStopName,
        StaticStopMatched,
        TimetabledArrivalLocal,
        ServiceDateLocal,
        ScheduledArrivalSecondsLocal,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchProposed
) AS difference;

SELECT @CompleteProposedOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ObservedAtUtc,
        ResultId,
        StopPointRef,
        StopName,
        LineName,
        LineRef,
        JourneyRef,
        DirectionRef,
        OperatorRef,
        PtMode,
        RailSubmode,
        TimetabledArrivalUtc,
        EstimatedArrivalUtc,
        ArrivalDelayMinutes,
        PlannedBay,
        EstimatedBay,
        PlatformChanged,
        CreatedAtUtc,
        StaticParentStationId,
        StaticStopName,
        StaticStopMatched,
        TimetabledArrivalLocal,
        ServiceDateLocal,
        ScheduledArrivalSecondsLocal,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchProposed

    EXCEPT

    SELECT
        ObservationKey,
        ObservedAtUtc,
        ResultId,
        StopPointRef,
        StopName,
        LineName,
        LineRef,
        JourneyRef,
        DirectionRef,
        OperatorRef,
        PtMode,
        RailSubmode,
        TimetabledArrivalUtc,
        EstimatedArrivalUtc,
        ArrivalDelayMinutes,
        PlannedBay,
        EstimatedBay,
        PlatformChanged,
        CreatedAtUtc,
        StaticParentStationId,
        StaticStopName,
        StaticStopMatched,
        TimetabledArrivalLocal,
        ServiceDateLocal,
        ScheduledArrivalSecondsLocal,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline
) AS difference;

WITH BaselineGrain AS
(
    SELECT ObservationKey, COUNT_BIG(*) AS GrainRowCount
    FROM #TripMatchBaseline
    GROUP BY ObservationKey
),
ProposedGrain AS
(
    SELECT ObservationKey, COUNT_BIG(*) AS GrainRowCount
    FROM #TripMatchProposed
    GROUP BY ObservationKey
)
SELECT @GrainDifferenceCount = COUNT_BIG(*)
FROM
(
    SELECT
        COALESCE(baseline_grain.ObservationKey, proposed_grain.ObservationKey)
            AS ObservationKey,
        baseline_grain.GrainRowCount AS BaselineRows,
        proposed_grain.GrainRowCount AS ProposedRows
    FROM BaselineGrain AS baseline_grain
    FULL OUTER JOIN ProposedGrain AS proposed_grain
        ON proposed_grain.ObservationKey = baseline_grain.ObservationKey
    WHERE baseline_grain.GrainRowCount IS NULL
       OR proposed_grain.GrainRowCount IS NULL
       OR baseline_grain.GrainRowCount <> proposed_grain.GrainRowCount
) AS grain_difference;

SELECT
    @FrozenObservationCount AS RegressionObservationCount,
    @BaselineElapsedMilliseconds AS BaselineElapsedMilliseconds,
    @ProposedElapsedMilliseconds AS NewElapsedMilliseconds,
    @BaselineRowCount AS BaselineRowCount,
    @ProposedRowCount AS NewRowCount,
    @BaselineRowCount - @BaselineDistinctObservationCount AS BaselineDuplicateGrainRows,
    @ProposedRowCount - @ProposedDistinctObservationCount AS NewDuplicateGrainRows,
    @CriticalBaselineOnly AS CriticalBaselineOnlyRows,
    @CriticalProposedOnly AS CriticalNewOnlyRows,
    @CriticalFieldDifferenceCount AS CriticalFieldDifferenceCount,
    @CompleteBaselineOnly AS BaselineOnlyRows,
    @CompleteProposedOnly AS NewOnlyRows,
    @GrainDifferenceCount AS GrainDifferenceCount,
    CASE
        WHEN @FrozenObservationCount = @BaselineRowCount
         AND @FrozenObservationCount = @ProposedRowCount
         AND @BaselineRowCount = @BaselineDistinctObservationCount
         AND @ProposedRowCount = @ProposedDistinctObservationCount
         AND @CriticalBaselineOnly = 0
         AND @CriticalProposedOnly = 0
         AND @CompleteBaselineOnly = 0
         AND @CompleteProposedOnly = 0
         AND @GrainDifferenceCount = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS RegressionResult;

WITH StatusValues AS
(
    SELECT *
    FROM
    (
        VALUES
            (N'StaticCoverageMissing'),
            (N'ExactStopMatch'),
            (N'ParentStationFallback'),
            (N'Unresolved')
    ) AS statuses(MatchStatus)
),
StatusCounts AS
(
    SELECT
        N'Baseline' AS Implementation,
        MatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM #TripMatchBaseline
    GROUP BY MatchStatus

    UNION ALL

    SELECT
        N'Proposed' AS Implementation,
        MatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM #TripMatchProposed
    GROUP BY MatchStatus
),
Implementations AS
(
    SELECT *
    FROM
    (
        VALUES
            (N'Baseline'),
            (N'Proposed')
    ) AS implementations(Implementation)
)
SELECT
    implementations.Implementation,
    status_values.MatchStatus,
    ISNULL(status_counts.ObservationCount, 0) AS ObservationCount
FROM Implementations AS implementations
CROSS JOIN StatusValues AS status_values
LEFT JOIN StatusCounts AS status_counts
    ON status_counts.Implementation = implementations.Implementation
   AND status_counts.MatchStatus = status_values.MatchStatus
ORDER BY implementations.Implementation, status_values.MatchStatus;

/*
    Validate the known examples only when their observations are present.
    A missing example is reported as NOT PRESENT, not manufactured.
*/
WITH KnownCase AS
(
    SELECT *
    FROM
    (
        VALUES
            (N'ICE',   N'StaticCoverageMissing'),
            (N'RE 7',  N'ExactStopMatch'),
            (N'RB 27', N'ParentStationFallback'),
            (N'RB 25', N'ExactStopMatch'),
            (N'RE 9',  N'ExactStopMatch')
    ) AS cases(LineLabel, ExpectedStatus)
),
ObservedCase AS
(
    SELECT
        known_case.LineLabel,
        known_case.ExpectedStatus,
        COUNT_BIG(proposed.ObservationKey) AS ObservationCount,
        SUM(
            CASE
                WHEN proposed.MatchStatus = known_case.ExpectedStatus
                THEN 1
                ELSE 0
            END
        ) AS ExpectedStatusObservationCount
    FROM KnownCase AS known_case
    LEFT JOIN #TripMatchProposed AS proposed
        ON REPLACE(proposed.LineName, N' ', N'')
         = REPLACE(known_case.LineLabel, N' ', N'')
    GROUP BY
        known_case.LineLabel,
        known_case.ExpectedStatus
)
SELECT
    LineLabel,
    ExpectedStatus,
    ObservationCount,
    ExpectedStatusObservationCount,
    CASE
        WHEN ObservationCount = 0 THEN 'NOT PRESENT'
        WHEN ExpectedStatusObservationCount > 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS CaseResult
FROM ObservedCase
ORDER BY LineLabel;

IF @CriticalBaselineOnly <> 0
   OR @CriticalProposedOnly <> 0
   OR @CompleteBaselineOnly <> 0
   OR @CompleteProposedOnly <> 0
   OR @GrainDifferenceCount <> 0
   OR @BaselineRowCount <> @FrozenObservationCount
   OR @ProposedRowCount <> @FrozenObservationCount
   OR @BaselineRowCount <> @BaselineDistinctObservationCount
   OR @ProposedRowCount <> @ProposedDistinctObservationCount
BEGIN
    THROW 51000, 'Realtime trip-match semantic regression FAILED; production view must not be replaced.', 1;
END;

PRINT 'Realtime trip-match pre-change semantic regression PASS. Apply the final view definition only after this result.';
GO

/*
    POST-CHANGE VALIDATION BLOCK

    Execute this batch in the same SQL Server session after applying the final
    CREATE OR ALTER VIEW from 03-create-cologne-realtime-working-layer.sql.
    It reuses #TripMatchRegressionScope and #TripMatchBaseline, and refuses to
    report a final result unless the live view is warehouse-direct. When the
    complete file is run before deployment, this block prints SKIPPED because
    the old view is still present; execute this batch after the alteration.
*/
IF OBJECT_ID(N'tempdb..#TripMatchRegressionScope') IS NULL
   OR OBJECT_ID(N'tempdb..#TripMatchBaseline') IS NULL
BEGIN
    THROW 51001, 'Run the pre-change regression block first in this same session.', 1;
END;

DECLARE @CurrentTripMatchObjectId INT =
    OBJECT_ID(N'wrk.vwCologneRealtimeTripMatch');
DECLARE @WarehouseStopEventObjectId INT =
    OBJECT_ID(N'dw.FactScheduledStopEvent');
DECLARE @LegacyScheduledStopEventObjectId INT =
    OBJECT_ID(N'wrk.vwCologneScheduledStopEvent');
DECLARE @HasWarehouseCandidateDependency BIT =
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM sys.sql_expression_dependencies
            WHERE referencing_id = @CurrentTripMatchObjectId
              AND referenced_id = @WarehouseStopEventObjectId
        )
        THEN 1
        ELSE 0
    END;
DECLARE @HasLegacyCandidateDependency BIT =
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM sys.sql_expression_dependencies
            WHERE referencing_id = @CurrentTripMatchObjectId
              AND referenced_id = @LegacyScheduledStopEventObjectId
        )
        THEN 1
        ELSE 0
    END;

IF @CurrentTripMatchObjectId IS NULL
   OR @HasWarehouseCandidateDependency = 0
   OR @HasLegacyCandidateDependency = 1
BEGIN
    PRINT 'Realtime trip-match post-change validation SKIPPED: the warehouse-direct view is not active yet.';
    RETURN;
END;

DROP TABLE IF EXISTS #TripMatchPostChange;

DECLARE @PostChangeStartedAtUtc DATETIME2(7) = SYSUTCDATETIME();

SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT current_match.*
INTO #TripMatchPostChange
FROM wrk.vwCologneRealtimeTripMatch AS current_match
JOIN #TripMatchRegressionScope AS scope
    ON scope.ObservationKey = current_match.ObservationKey;

DECLARE @PostChangeElapsedMilliseconds BIGINT =
    DATEDIFF_BIG(MILLISECOND, @PostChangeStartedAtUtc, SYSUTCDATETIME());

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

DECLARE @PostChangeRowCount BIGINT;
DECLARE @PostChangeDistinctObservationCount BIGINT;
DECLARE @PostChangeDuplicateGrainRows BIGINT;
DECLARE @PostCriticalBaselineOnly BIGINT;
DECLARE @PostCriticalOnly BIGINT;
DECLARE @PostCriticalFieldDifferenceCount BIGINT;
DECLARE @PostCompleteBaselineOnly BIGINT;
DECLARE @PostCompleteOnly BIGINT;
DECLARE @PostGrainDifferenceCount BIGINT;

SELECT
    @PostChangeRowCount = COUNT_BIG(*),
    @PostChangeDistinctObservationCount = COUNT_BIG(DISTINCT ObservationKey)
FROM #TripMatchPostChange;

SET @PostChangeDuplicateGrainRows =
    @PostChangeRowCount - @PostChangeDistinctObservationCount;

SELECT @PostCriticalBaselineOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline

    EXCEPT

    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchPostChange
) AS difference;

SELECT @PostCriticalOnly = COUNT_BIG(*)
FROM
(
    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchPostChange

    EXCEPT

    SELECT
        ObservationKey,
        ExactStopCandidateCount,
        ParentStationCandidateCount,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId
    FROM #TripMatchBaseline
) AS difference;

SET @PostCriticalFieldDifferenceCount =
    @PostCriticalBaselineOnly + @PostCriticalOnly;

/* The temp tables have the same 32-column contract, so SELECT * compares all columns. */
SELECT @PostCompleteBaselineOnly = COUNT_BIG(*)
FROM
(
    SELECT * FROM #TripMatchBaseline
    EXCEPT
    SELECT * FROM #TripMatchPostChange
) AS difference;

SELECT @PostCompleteOnly = COUNT_BIG(*)
FROM
(
    SELECT * FROM #TripMatchPostChange
    EXCEPT
    SELECT * FROM #TripMatchBaseline
) AS difference;

WITH BaselineGrain AS
(
    SELECT ObservationKey, COUNT_BIG(*) AS GrainRowCount
    FROM #TripMatchBaseline
    GROUP BY ObservationKey
),
PostChangeGrain AS
(
    SELECT ObservationKey, COUNT_BIG(*) AS GrainRowCount
    FROM #TripMatchPostChange
    GROUP BY ObservationKey
)
SELECT @PostGrainDifferenceCount = COUNT_BIG(*)
FROM
(
    SELECT
        COALESCE(baseline_grain.ObservationKey, post_change_grain.ObservationKey)
            AS ObservationKey,
        baseline_grain.GrainRowCount AS BaselineRows,
        post_change_grain.GrainRowCount AS PostChangeRows
    FROM BaselineGrain AS baseline_grain
    FULL OUTER JOIN PostChangeGrain AS post_change_grain
        ON post_change_grain.ObservationKey = baseline_grain.ObservationKey
    WHERE baseline_grain.GrainRowCount IS NULL
       OR post_change_grain.GrainRowCount IS NULL
       OR baseline_grain.GrainRowCount <> post_change_grain.GrainRowCount
) AS grain_difference;

SELECT
    COUNT_BIG(*) AS RegressionObservationCount,
    @PostChangeElapsedMilliseconds AS FinalViewElapsedMilliseconds,
    @PostChangeRowCount AS FinalViewRowCount,
    @PostChangeDuplicateGrainRows AS FinalViewDuplicateGrainRows,
    @PostCriticalBaselineOnly AS CriticalBaselineOnlyRows,
    @PostCriticalOnly AS CriticalFinalOnlyRows,
    @PostCriticalFieldDifferenceCount AS CriticalFieldDifferenceCount,
    @PostCompleteBaselineOnly AS BaselineOnlyRows,
    @PostCompleteOnly AS FinalOnlyRows,
    @PostGrainDifferenceCount AS GrainDifferenceCount,
    CASE
        WHEN @PostChangeRowCount = COUNT_BIG(*)
         AND @PostChangeRowCount = @PostChangeDistinctObservationCount
         AND @PostCriticalBaselineOnly = 0
         AND @PostCriticalOnly = 0
         AND @PostCompleteBaselineOnly = 0
         AND @PostCompleteOnly = 0
         AND @PostGrainDifferenceCount = 0
        THEN 'PASS'
        ELSE 'FAIL'
    END AS FinalRegressionResult
FROM #TripMatchRegressionScope;

WITH StatusValues AS
(
    SELECT *
    FROM
    (
        VALUES
            (N'StaticCoverageMissing'),
            (N'ExactStopMatch'),
            (N'ParentStationFallback'),
            (N'Unresolved')
    ) AS statuses(MatchStatus)
),
StatusCounts AS
(
    SELECT
        N'Baseline' AS Implementation,
        MatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM #TripMatchBaseline
    GROUP BY MatchStatus

    UNION ALL

    SELECT
        N'FinalView' AS Implementation,
        MatchStatus,
        COUNT_BIG(*) AS ObservationCount
    FROM #TripMatchPostChange
    GROUP BY MatchStatus
),
Implementations AS
(
    SELECT *
    FROM
    (
        VALUES
            (N'Baseline'),
            (N'FinalView')
    ) AS implementations(Implementation)
)
SELECT
    implementations.Implementation,
    status_values.MatchStatus,
    ISNULL(status_counts.ObservationCount, 0) AS ObservationCount
FROM Implementations AS implementations
CROSS JOIN StatusValues AS status_values
LEFT JOIN StatusCounts AS status_counts
    ON status_counts.Implementation = implementations.Implementation
   AND status_counts.MatchStatus = status_values.MatchStatus
ORDER BY implementations.Implementation, status_values.MatchStatus;

IF @PostCriticalBaselineOnly <> 0
   OR @PostCriticalOnly <> 0
   OR @PostCompleteBaselineOnly <> 0
   OR @PostCompleteOnly <> 0
   OR @PostGrainDifferenceCount <> 0
   OR @PostChangeRowCount <> @PostChangeDistinctObservationCount
   OR @PostChangeRowCount <> (SELECT COUNT_BIG(*) FROM #TripMatchRegressionScope)
BEGIN
    THROW 51002, 'Realtime trip-match post-change semantic regression FAILED.', 1;
END;

PRINT 'Realtime trip-match post-change semantic regression PASS.';
