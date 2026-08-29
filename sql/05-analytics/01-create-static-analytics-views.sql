USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/* One-row scheduled-network baseline for Power BI cards and reconciliation. */
CREATE OR ALTER VIEW analytics.vwNetworkBaselineKpi
AS
SELECT
    (SELECT COUNT_BIG(*) FROM dw.DimAgency) AS AgencyCount,
    (SELECT COUNT_BIG(*) FROM dw.DimMode) AS ModeCount,
    (SELECT COUNT_BIG(*) FROM dw.DimRoute) AS RouteCount,
    (SELECT COUNT_BIG(*) FROM dw.DimStop WHERE LocationTypeCode = 1) AS ParentStationCount,
    (SELECT COUNT_BIG(*) FROM dw.DimStop WHERE LocationTypeCode = 0) AS StopPositionCount,
    (SELECT COUNT_BIG(DISTINCT StopKey) FROM dw.FactScheduledStopEvent) AS UsedStopPositionCount,
    (SELECT COUNT_BIG(*) FROM dw.DimService) AS ServicePatternCount,
    (SELECT COUNT_BIG(DISTINCT DateKey) FROM dw.BridgeServiceDate) AS ActiveServiceDateCount,
    (SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip) AS ScheduledTripPatternCount,
    (
        SELECT COUNT_BIG(*)
        FROM dw.FactScheduledTrip AS trip
        JOIN dw.BridgeServiceDate AS service_date
            ON service_date.ServiceKey = trip.ServiceKey
    ) AS ScheduledTripOccurrenceCount,
    (SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent) AS ScheduledStopEventPatternCount;
GO

/* One row per analytical transport mode. */
CREATE OR ALTER VIEW analytics.vwModeScheduleProfile
AS
WITH RouteCount AS
(
    SELECT ModeKey, COUNT_BIG(*) AS RouteCount
    FROM dw.DimRoute
    GROUP BY ModeKey
),
TripPatternCount AS
(
    SELECT ModeKey, COUNT_BIG(*) AS ScheduledTripPatternCount
    FROM dw.FactScheduledTrip
    GROUP BY ModeKey
),
TripOccurrenceCount AS
(
    SELECT trip.ModeKey, COUNT_BIG(*) AS ScheduledTripOccurrenceCount
    FROM dw.FactScheduledTrip AS trip
    JOIN dw.BridgeServiceDate AS service_date
        ON service_date.ServiceKey = trip.ServiceKey
    GROUP BY trip.ModeKey
),
StopEventCount AS
(
    SELECT
        ModeKey,
        COUNT_BIG(*) AS ScheduledStopEventPatternCount,
        COUNT_BIG(DISTINCT StopKey) AS ServedStopPositionCount
    FROM dw.FactScheduledStopEvent
    GROUP BY ModeKey
)
SELECT
    mode.ModeKey,
    mode.ModeSortOrder,
    mode.ModeGroup,
    mode.ModeDetail,
    mode.IsRailReplacementService,
    route.RouteCount,
    trip_pattern.ScheduledTripPatternCount,
    trip_occurrence.ScheduledTripOccurrenceCount,
    stop_event.ScheduledStopEventPatternCount,
    stop_event.ServedStopPositionCount
FROM dw.DimMode AS mode
JOIN RouteCount AS route ON route.ModeKey = mode.ModeKey
JOIN TripPatternCount AS trip_pattern ON trip_pattern.ModeKey = mode.ModeKey
JOIN TripOccurrenceCount AS trip_occurrence ON trip_occurrence.ModeKey = mode.ModeKey
JOIN StopEventCount AS stop_event ON stop_event.ModeKey = mode.ModeKey;
GO

/* One row per Cologne-serving route, including planned supply and network reach. */
CREATE OR ALTER VIEW analytics.vwRouteScheduleProfile
AS
WITH TripPatternStats AS
(
    SELECT
        RouteKey,
        COUNT_BIG(*) AS ScheduledTripPatternCount,
        COUNT_BIG(DISTINCT ServiceKey) AS ServicePatternCount
    FROM dw.FactScheduledTrip
    GROUP BY RouteKey
),
TripOccurrenceStats AS
(
    SELECT
        trip.RouteKey,
        COUNT_BIG(*) AS ScheduledTripOccurrenceCount,
        COUNT_BIG(DISTINCT service_date.DateKey) AS ActiveServiceDateCount
    FROM dw.FactScheduledTrip AS trip
    JOIN dw.BridgeServiceDate AS service_date
        ON service_date.ServiceKey = trip.ServiceKey
    GROUP BY trip.RouteKey
),
StopEventStats AS
(
    SELECT
        RouteKey,
        COUNT_BIG(*) AS ScheduledStopEventPatternCount,
        COUNT_BIG(DISTINCT StopKey) AS ServedStopPositionCount,
        MIN(ScheduledDepartureSeconds) AS EarliestScheduledDepartureSeconds,
        MAX(ScheduledArrivalSeconds) AS LatestScheduledArrivalSeconds
    FROM dw.FactScheduledStopEvent
    GROUP BY RouteKey
)
SELECT
    route.RouteKey,
    route.RouteId,
    route.RouteShortName,
    route.RouteLongName,
    route.RouteTypeCode,
    agency.AgencyId,
    agency.AgencyName,
    mode.ModeSortOrder,
    mode.ModeGroup,
    mode.ModeDetail,
    mode.IsRailReplacementService,
    trip_pattern.ScheduledTripPatternCount,
    trip_pattern.ServicePatternCount,
    trip_occurrence.ScheduledTripOccurrenceCount,
    trip_occurrence.ActiveServiceDateCount,
    stop_event.ScheduledStopEventPatternCount,
    stop_event.ServedStopPositionCount,
    stop_event.EarliestScheduledDepartureSeconds,
    stop_event.LatestScheduledArrivalSeconds,
    route.RouteColor,
    route.RouteTextColor
FROM dw.DimRoute AS route
LEFT JOIN dw.DimAgency AS agency ON agency.AgencyKey = route.AgencyKey
JOIN dw.DimMode AS mode ON mode.ModeKey = route.ModeKey
JOIN TripPatternStats AS trip_pattern ON trip_pattern.RouteKey = route.RouteKey
JOIN TripOccurrenceStats AS trip_occurrence ON trip_occurrence.RouteKey = route.RouteKey
JOIN StopEventStats AS stop_event ON stop_event.RouteKey = route.RouteKey;
GO

/* One row per physical stop position, including unused positions with zero counts. */
CREATE OR ALTER VIEW analytics.vwStopPositionScheduleProfile
AS
WITH StopEventStats AS
(
    SELECT
        StopKey,
        COUNT_BIG(*) AS ScheduledStopEventPatternCount,
        COUNT_BIG(DISTINCT TripKey) AS ScheduledTripPatternCount,
        COUNT_BIG(DISTINCT RouteKey) AS ServedRouteCount,
        MIN(ScheduledDepartureSeconds) AS EarliestScheduledDepartureSeconds,
        MAX(ScheduledArrivalSeconds) AS LatestScheduledArrivalSeconds
    FROM dw.FactScheduledStopEvent
    GROUP BY StopKey
)
SELECT
    stop.StopKey,
    stop.StopId,
    stop.StopCode,
    stop.StopName,
    stop.Latitude,
    stop.Longitude,
    stop.ParentStopKey,
    parent_stop.StopId AS ParentStationId,
    parent_stop.StopName AS ParentStationName,
    COALESCE(stop_event.ServedRouteCount, 0) AS ServedRouteCount,
    COALESCE(stop_event.ScheduledTripPatternCount, 0) AS ScheduledTripPatternCount,
    COALESCE(stop_event.ScheduledStopEventPatternCount, 0) AS ScheduledStopEventPatternCount,
    stop_event.EarliestScheduledDepartureSeconds,
    stop_event.LatestScheduledArrivalSeconds,
    CONVERT(BIT, CASE WHEN stop_event.StopKey IS NULL THEN 0 ELSE 1 END) AS IsUsedInCurrentSchedule
FROM dw.DimStop AS stop
LEFT JOIN dw.DimStop AS parent_stop ON parent_stop.StopKey = stop.ParentStopKey
LEFT JOIN StopEventStats AS stop_event ON stop_event.StopKey = stop.StopKey
WHERE stop.LocationTypeCode = 0;
GO

/* One row per parent station for management-level station reporting. */
CREATE OR ALTER VIEW analytics.vwParentStationScheduleProfile
AS
WITH ChildPositionCount AS
(
    SELECT ParentStopKey, COUNT_BIG(*) AS ChildStopPositionCount
    FROM dw.DimStop
    WHERE LocationTypeCode = 0 AND ParentStopKey IS NOT NULL
    GROUP BY ParentStopKey
),
StationEventStats AS
(
    SELECT
        child_stop.ParentStopKey,
        COUNT_BIG(*) AS ScheduledStopEventPatternCount,
        COUNT_BIG(DISTINCT stop_event.TripKey) AS ScheduledTripPatternCount,
        COUNT_BIG(DISTINCT stop_event.RouteKey) AS ServedRouteCount,
        COUNT_BIG(DISTINCT stop_event.StopKey) AS UsedStopPositionCount
    FROM dw.FactScheduledStopEvent AS stop_event
    JOIN dw.DimStop AS child_stop ON child_stop.StopKey = stop_event.StopKey
    WHERE child_stop.ParentStopKey IS NOT NULL
    GROUP BY child_stop.ParentStopKey
)
SELECT
    parent_stop.StopKey AS ParentStationKey,
    parent_stop.StopId AS ParentStationId,
    parent_stop.StopName AS ParentStationName,
    parent_stop.Latitude,
    parent_stop.Longitude,
    COALESCE(child.ChildStopPositionCount, 0) AS ChildStopPositionCount,
    COALESCE(event_stats.UsedStopPositionCount, 0) AS UsedStopPositionCount,
    COALESCE(event_stats.ServedRouteCount, 0) AS ServedRouteCount,
    COALESCE(event_stats.ScheduledTripPatternCount, 0) AS ScheduledTripPatternCount,
    COALESCE(event_stats.ScheduledStopEventPatternCount, 0) AS ScheduledStopEventPatternCount,
    CONVERT(BIT, CASE WHEN event_stats.ParentStopKey IS NULL THEN 0 ELSE 1 END) AS IsUsedInCurrentSchedule
FROM dw.DimStop AS parent_stop
LEFT JOIN ChildPositionCount AS child ON child.ParentStopKey = parent_stop.StopKey
LEFT JOIN StationEventStats AS event_stats ON event_stats.ParentStopKey = parent_stop.StopKey
WHERE parent_stop.LocationTypeCode = 1;
GO

/* One row per active date and route for planned daily-service analysis. */
CREATE OR ALTER VIEW analytics.vwDailyScheduledTripProfile
AS
SELECT
    date_dimension.DateKey,
    date_dimension.DateValue,
    date_dimension.CalendarYear,
    date_dimension.CalendarQuarter,
    date_dimension.CalendarMonth,
    date_dimension.MonthName,
    date_dimension.IsoWeekNumber,
    date_dimension.IsoWeekdayNumber,
    date_dimension.WeekdayName,
    date_dimension.IsWeekend,
    route.RouteKey,
    route.RouteId,
    route.RouteShortName,
    route.RouteLongName,
    agency.AgencyId,
    agency.AgencyName,
    mode.ModeKey,
    mode.ModeSortOrder,
    mode.ModeGroup,
    mode.ModeDetail,
    mode.IsRailReplacementService,
    COUNT_BIG(*) AS ScheduledTripCount
FROM dw.BridgeServiceDate AS service_date
JOIN dw.DimDate AS date_dimension ON date_dimension.DateKey = service_date.DateKey
JOIN dw.FactScheduledTrip AS trip ON trip.ServiceKey = service_date.ServiceKey
JOIN dw.DimRoute AS route ON route.RouteKey = trip.RouteKey
LEFT JOIN dw.DimAgency AS agency ON agency.AgencyKey = route.AgencyKey
JOIN dw.DimMode AS mode ON mode.ModeKey = trip.ModeKey
GROUP BY
    date_dimension.DateKey,
    date_dimension.DateValue,
    date_dimension.CalendarYear,
    date_dimension.CalendarQuarter,
    date_dimension.CalendarMonth,
    date_dimension.MonthName,
    date_dimension.IsoWeekNumber,
    date_dimension.IsoWeekdayNumber,
    date_dimension.WeekdayName,
    date_dimension.IsWeekend,
    route.RouteKey,
    route.RouteId,
    route.RouteShortName,
    route.RouteLongName,
    agency.AgencyId,
    agency.AgencyName,
    mode.ModeKey,
    mode.ModeSortOrder,
    mode.ModeGroup,
    mode.ModeDetail,
    mode.IsRailReplacementService;
GO

