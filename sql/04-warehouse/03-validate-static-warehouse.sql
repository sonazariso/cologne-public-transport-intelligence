USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;

/* 1. Reconcile every physical warehouse table with the profiled snapshot. */
SELECT
    metric.MetricName,
    metric.ExpectedValue,
    metric.ActualValue,
    metric.ActualValue - metric.ExpectedValue AS Difference,
    CASE WHEN metric.ActualValue = metric.ExpectedValue THEN 'MATCH' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT N'Agencies' AS MetricName, CONVERT(BIGINT, 15) AS ExpectedValue,
           (SELECT COUNT_BIG(*) FROM dw.DimAgency) AS ActualValue
    UNION ALL
    SELECT N'Transport modes', 7, (SELECT COUNT_BIG(*) FROM dw.DimMode)
    UNION ALL
    SELECT N'Routes', 153, (SELECT COUNT_BIG(*) FROM dw.DimRoute)
    UNION ALL
    SELECT N'Stops', 3156, (SELECT COUNT_BIG(*) FROM dw.DimStop)
    UNION ALL
    SELECT N'Service patterns', 3947, (SELECT COUNT_BIG(*) FROM dw.DimService)
    UNION ALL
    SELECT N'Feed dates', 364, (SELECT COUNT_BIG(*) FROM dw.DimDate)
    UNION ALL
    SELECT N'Active service-date pairs', 99399, (SELECT COUNT_BIG(*) FROM dw.BridgeServiceDate)
    UNION ALL
    SELECT N'Scheduled trip patterns', 90331, (SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip)
    UNION ALL
    SELECT N'Scheduled stop-event patterns', 1551343,
           (SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent)
) AS metric
ORDER BY metric.MetricName;

/* 2. Validate referential integrity and typed analytical fields. */
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT N'Stops with unresolved parent station' AS CheckName, COUNT_BIG(*) AS FailedRows
    FROM dw.DimStop
    WHERE ParentStationId IS NOT NULL AND ParentStopKey IS NULL

    UNION ALL

    SELECT N'Routes with source ambiguity', COUNT_BIG(*)
    FROM dw.DimRoute
    WHERE HasSourceAmbiguity = 1

    UNION ALL

    SELECT N'Trips without agency key', COUNT_BIG(*)
    FROM dw.FactScheduledTrip
    WHERE AgencyKey IS NULL

    UNION ALL

    SELECT N'Stop events with invalid schedule seconds', COUNT_BIG(*)
    FROM dw.FactScheduledStopEvent
    WHERE ScheduledArrivalSeconds < 0
       OR ScheduledDepartureSeconds < 0
       OR ScheduledDepartureSeconds < ScheduledArrivalSeconds

    UNION ALL

    SELECT N'Service dates outside dimension range', COUNT_BIG(*)
    FROM dw.BridgeServiceDate AS service_date
    LEFT JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = service_date.DateKey
    WHERE date_dimension.DateKey IS NULL
) AS check_result
ORDER BY check_result.CheckName;

/* 3. Reconcile transport modes at the physical fact-table level. */
SELECT
    mode.ModeGroup,
    mode.ModeDetail,
    COUNT_BIG(DISTINCT route.RouteKey) AS RouteCount,
    COUNT_BIG(DISTINCT trip.TripKey) AS TripCount,
    COUNT_BIG(stop_event.ScheduledStopEventKey) AS ScheduledStopEventCount
FROM dw.DimMode AS mode
JOIN dw.DimRoute AS route
    ON route.ModeKey = mode.ModeKey
JOIN dw.FactScheduledTrip AS trip
    ON trip.RouteKey = route.RouteKey
JOIN dw.FactScheduledStopEvent AS stop_event
    ON stop_event.TripKey = trip.TripKey
GROUP BY
    mode.ModeSortOrder,
    mode.ModeGroup,
    mode.ModeDetail
ORDER BY mode.ModeSortOrder;

/* 4. Mark the latest successful warehouse build as validated. */
DECLARE @WarehouseLoadBatchId BIGINT =
(
    SELECT TOP (1) WarehouseLoadBatchId
    FROM ctl.StaticWarehouseLoadBatch
    WHERE Status IN ('Loaded', 'Validated', 'ValidationFailed')
    ORDER BY WarehouseLoadBatchId DESC
);

IF @WarehouseLoadBatchId IS NULL
BEGIN
    THROW 50012, 'No loaded static warehouse batch is available for validation.', 1;
END;

DECLARE @FailureCount BIGINT =
(
    SELECT
        ABS((SELECT COUNT_BIG(*) FROM dw.DimAgency) - 15)
        + ABS((SELECT COUNT_BIG(*) FROM dw.DimMode) - 7)
        + ABS((SELECT COUNT_BIG(*) FROM dw.DimRoute) - 153)
        + ABS((SELECT COUNT_BIG(*) FROM dw.DimStop) - 3156)
        + ABS((SELECT COUNT_BIG(*) FROM dw.DimService) - 3947)
        + ABS((SELECT COUNT_BIG(*) FROM dw.DimDate) - 364)
        + ABS((SELECT COUNT_BIG(*) FROM dw.BridgeServiceDate) - 99399)
        + ABS((SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip) - 90331)
        + ABS((SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent) - 1551343)
        + (SELECT COUNT_BIG(*) FROM dw.DimStop
           WHERE ParentStationId IS NOT NULL AND ParentStopKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dw.DimRoute
           WHERE HasSourceAmbiguity = 1)
        + (SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip
           WHERE AgencyKey IS NULL)
        + (SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent
           WHERE ScheduledArrivalSeconds < 0
              OR ScheduledDepartureSeconds < 0
              OR ScheduledDepartureSeconds < ScheduledArrivalSeconds)
);

UPDATE ctl.StaticWarehouseLoadBatch
SET Status = CASE WHEN @FailureCount = 0 THEN 'Validated' ELSE 'ValidationFailed' END
WHERE WarehouseLoadBatchId = @WarehouseLoadBatchId;

SELECT *
FROM ctl.StaticWarehouseLoadBatch
WHERE WarehouseLoadBatchId = @WarehouseLoadBatchId;
GO
