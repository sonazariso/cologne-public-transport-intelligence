USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;

/* 1. Reconcile the working-layer scope with the independently profiled snapshot. */
SELECT
    metric.MetricName,
    metric.ExpectedValue,
    metric.ActualValue,
    metric.ActualValue - metric.ExpectedValue AS Difference,
    CASE WHEN metric.ActualValue = metric.ExpectedValue THEN 'MATCH' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT N'Cologne stop records' AS MetricName, CONVERT(BIGINT, 3156) AS ExpectedValue,
           (SELECT COUNT_BIG(*) FROM wrk.vwCologneStop) AS ActualValue
    UNION ALL
    SELECT N'Cologne-serving routes', 153,
           (SELECT COUNT_BIG(*) FROM wrk.vwCologneServingRoute)
    UNION ALL
    SELECT N'Cologne-serving trips', 90331,
           (SELECT COUNT_BIG(*) FROM wrk.vwCologneServingTrip)
    UNION ALL
    SELECT N'Scheduled stop events in Cologne', 1551343,
           (SELECT COUNT_BIG(*) FROM wrk.vwCologneScheduledStopEvent)
) AS metric
ORDER BY metric.MetricName;

/* 2. Reconcile every transport subclass, not only the overall total. */
DECLARE @ExpectedMode TABLE
(
    ModeDetail NVARCHAR(100) NOT NULL PRIMARY KEY,
    ExpectedRoutes BIGINT NOT NULL,
    ExpectedTrips BIGINT NOT NULL,
    ExpectedStopEvents BIGINT NOT NULL
);

INSERT INTO @ExpectedMode (ModeDetail, ExpectedRoutes, ExpectedTrips, ExpectedStopEvents)
VALUES
    (N'Stadtbahn / Tram',              12, 33156, 623801),
    (N'S-Bahn',                         5,  4714,  48722),
    (N'Regional Express (RE)',         12,  2880,   8796),
    (N'Regional Bahn (RB)',             7,  2188,   8395),
    (N'Urban Bus (KVB)',               60, 38104, 826099),
    (N'Regional / Other Bus',          27,  4276,  22874),
    (N'Rail Replacement Bus (SEV)',    30,  5013,  12656);

SELECT
    expected.ModeDetail,
    expected.ExpectedRoutes,
    actual.RouteCount AS ActualRoutes,
    expected.ExpectedTrips,
    actual.TripCount AS ActualTrips,
    expected.ExpectedStopEvents,
    actual.CologneStopEventCount AS ActualStopEvents,
    CASE
        WHEN actual.RouteCount = expected.ExpectedRoutes
         AND actual.TripCount = expected.ExpectedTrips
         AND actual.CologneStopEventCount = expected.ExpectedStopEvents
        THEN 'MATCH'
        ELSE 'REVIEW'
    END AS CheckStatus
FROM @ExpectedMode AS expected
LEFT JOIN wrk.vwCologneModeSummary AS actual
    ON actual.ModeDetail = expected.ModeDetail
ORDER BY actual.ModeSortOrder;

/* 3. Structural and conversion checks. Every failed-row count should be zero. */
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT N'Duplicate Cologne stop IDs' AS CheckName,
           COUNT_BIG(*) - COUNT_BIG(DISTINCT StopId) AS FailedRows
    FROM wrk.vwCologneStop

    UNION ALL

    SELECT N'Duplicate Cologne-serving route IDs',
           COUNT_BIG(*) - COUNT_BIG(DISTINCT RouteId)
    FROM wrk.vwCologneServingRoute

    UNION ALL

    SELECT N'Duplicate Cologne-serving trip IDs',
           COUNT_BIG(*) - COUNT_BIG(DISTINCT TripId)
    FROM wrk.vwCologneServingTrip

    UNION ALL

    SELECT N'Cologne stops with invalid coordinates', COUNT_BIG(*)
    FROM wrk.vwCologneStop
    WHERE Latitude IS NULL OR Longitude IS NULL

    UNION ALL

    SELECT N'Routes without a transport classification', COUNT_BIG(*)
    FROM wrk.vwCologneServingRoute
    WHERE ModeDetail = N'Other / Unclassified'

    UNION ALL

    SELECT N'Routes with source ambiguity', COUNT_BIG(*)
    FROM wrk.vwCologneServingRoute
    WHERE HasSourceAmbiguity = 1

    UNION ALL

    SELECT N'Stop events with invalid stop sequence', COUNT_BIG(*)
    FROM wrk.vwCologneScheduledStopEvent
    WHERE StopSequence IS NULL

    UNION ALL

    SELECT N'Stop events with invalid scheduled time', COUNT_BIG(*)
    FROM wrk.vwCologneScheduledStopEvent
    WHERE ScheduledArrivalSeconds IS NULL
       OR ScheduledDepartureSeconds IS NULL
) AS check_result
ORDER BY check_result.CheckName;

/* 4. Final result for review and later Power BI reconciliation. */
SELECT
    ModeGroup,
    ModeDetail,
    RouteCount,
    TripCount,
    CologneStopEventCount
FROM wrk.vwCologneModeSummary
ORDER BY ModeSortOrder;
GO

