USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Convert a GTFS clock value to seconds after the start of its service day.

    GTFS permits values such as 24:15:00 and 25:05:00. SQL Server TIME does not,
    so the working layer stores seconds instead of forcing the value into TIME.
*/
CREATE OR ALTER FUNCTION wrk.GtfsTimeToSeconds
(
    @GtfsTime NVARCHAR(20)
)
RETURNS INT
AS
BEGIN
    DECLARE @FirstColon INT = CHARINDEX(N':', @GtfsTime);
    DECLARE @SecondColon INT =
        CASE
            WHEN @FirstColon > 0 THEN CHARINDEX(N':', @GtfsTime, @FirstColon + 1)
            ELSE 0
        END;

    DECLARE @Hours INT;
    DECLARE @Minutes INT;
    DECLARE @Seconds INT;

    IF NULLIF(LTRIM(RTRIM(@GtfsTime)), N'') IS NULL
       OR @FirstColon <= 1
       OR @SecondColon <= @FirstColon + 1
       OR CHARINDEX(N':', @GtfsTime, @SecondColon + 1) > 0
    BEGIN
        RETURN NULL;
    END;

    SET @Hours = TRY_CONVERT(INT, LEFT(@GtfsTime, @FirstColon - 1));
    SET @Minutes = TRY_CONVERT
    (
        INT,
        SUBSTRING(@GtfsTime, @FirstColon + 1, @SecondColon - @FirstColon - 1)
    );
    SET @Seconds = TRY_CONVERT
    (
        INT,
        SUBSTRING(@GtfsTime, @SecondColon + 1, LEN(@GtfsTime) - @SecondColon)
    );

    IF @Hours IS NULL
       OR @Minutes IS NULL
       OR @Seconds IS NULL
       OR @Hours < 0
       OR @Minutes NOT BETWEEN 0 AND 59
       OR @Seconds NOT BETWEEN 0 AND 59
    BEGIN
        RETURN NULL;
    END;

    RETURN (@Hours * 3600) + (@Minutes * 60) + @Seconds;
END;
GO

/*
    All stop records whose global ID belongs to the municipality of Cologne.
    The prefix de:05315: is the initial explicit boundary rule for Cologne.
*/
CREATE OR ALTER VIEW wrk.vwCologneStop
AS
SELECT
    stop.StopId,
    NULLIF(stop.StopCode, N'') AS StopCode,
    NULLIF(stop.StopName, N'') AS StopName,
    NULLIF(stop.StopDesc, N'') AS StopDescription,
    TRY_CONVERT(DECIMAL(9, 6), stop.StopLat) AS Latitude,
    TRY_CONVERT(DECIMAL(9, 6), stop.StopLon) AS Longitude,
    NULLIF(stop.ZoneId, N'') AS ZoneId,
    NULLIF(stop.StopUrl, N'') AS StopUrl,
    TRY_CONVERT(TINYINT, NULLIF(stop.LocationType, N'')) AS LocationTypeCode,
    CASE stop.LocationType
        WHEN N'0' THEN N'Stop position / mast'
        WHEN N'1' THEN N'Parent station'
        WHEN N'2' THEN N'Station entrance / exit'
        WHEN N'3' THEN N'Generic node'
        WHEN N'4' THEN N'Boarding area'
        ELSE N'Unknown'
    END AS LocationTypeName,
    NULLIF(stop.ParentStation, N'') AS ParentStationId,
    NULLIF(stop.StopTimezone, N'') AS StopTimezone
FROM stg.GtfsStops AS stop
WHERE stop.StopId LIKE N'de:05315:%';
GO

/*
    One classified row per route serving at least one Cologne stop.

    route_type is the primary source attribute. Route labels and agency names
    refine rail subclasses and identify rail-replacement buses. Source-row
    counts remain visible so a future duplicate is flagged rather than hidden.
*/
CREATE OR ALTER VIEW wrk.vwCologneServingRoute
AS
WITH CologneRouteId AS
(
    SELECT DISTINCT trip.RouteId
    FROM stg.GtfsStopTimes AS stop_time
    JOIN stg.GtfsTrips AS trip
        ON trip.TripId = stop_time.TripId
    WHERE stop_time.StopId LIKE N'de:05315:%'
),
RouteQuality AS
(
    SELECT
        route.RouteId,
        COUNT_BIG(*) AS SourceRouteRowCount,
        COUNT_BIG(DISTINCT NULLIF(route.AgencyId, N'')) AS SourceAgencyCount
    FROM stg.GtfsRoutes AS route
    JOIN CologneRouteId AS cologne_route
        ON cologne_route.RouteId = route.RouteId
    GROUP BY route.RouteId
),
RankedRoute AS
(
    SELECT
        route.RouteId,
        route.AgencyId,
        route.RouteShortName,
        route.RouteLongName,
        route.RouteDesc,
        route.RouteType,
        route.RouteUrl,
        route.RouteColor,
        route.RouteTextColor,
        agency.AgencyName,
        quality.SourceRouteRowCount,
        quality.SourceAgencyCount,
        ROW_NUMBER() OVER
        (
            PARTITION BY route.RouteId
            ORDER BY
                CASE WHEN NULLIF(route.AgencyId, N'') IS NULL THEN 1 ELSE 0 END,
                route.AgencyId,
                route.RouteShortName,
                route.RouteLongName
        ) AS SourcePreference
    FROM stg.GtfsRoutes AS route
    JOIN CologneRouteId AS cologne_route
        ON cologne_route.RouteId = route.RouteId
    JOIN RouteQuality AS quality
        ON quality.RouteId = route.RouteId
    LEFT JOIN stg.GtfsAgency AS agency
        ON agency.AgencyId = route.AgencyId
),
SelectedRoute AS
(
    SELECT *
    FROM RankedRoute
    WHERE SourcePreference = 1
),
PreparedRoute AS
(
    SELECT
        selected.*,
        TRY_CONVERT(INT, selected.RouteType) AS RouteTypeCode,
        UPPER
        (
            LTRIM
            (
                RTRIM
                (
                    COALESCE
                    (
                        NULLIF(selected.RouteShortName, N''),
                        NULLIF(selected.RouteLongName, N''),
                        N''
                    )
                )
            )
        ) AS NormalizedRouteLabel,
        UPPER(COALESCE(selected.AgencyName, N'')) AS NormalizedAgencyName
    FROM SelectedRoute AS selected
)
SELECT
    route.RouteId,
    NULLIF(route.AgencyId, N'') AS AgencyId,
    NULLIF(route.AgencyName, N'') AS AgencyName,
    NULLIF(route.RouteShortName, N'') AS RouteShortName,
    NULLIF(route.RouteLongName, N'') AS RouteLongName,
    NULLIF(route.RouteDesc, N'') AS RouteDescription,
    route.RouteTypeCode,
    CASE
        WHEN route.RouteTypeCode IN (0, 1) THEN N'Urban Rail'
        WHEN route.RouteTypeCode = 2 THEN N'Rail'
        WHEN route.RouteTypeCode = 3
             AND
             (
                 route.NormalizedAgencyName LIKE N'%SEV%'
                 OR route.NormalizedRouteLabel LIKE N'RE%'
                 OR route.NormalizedRouteLabel LIKE N'RB%'
                 OR route.NormalizedRouteLabel LIKE N'S[0-9]%'
             ) THEN N'Replacement Service'
        WHEN route.RouteTypeCode = 3 THEN N'Bus'
        WHEN route.RouteTypeCode = 4 THEN N'Water Transport'
        WHEN route.RouteTypeCode IN (5, 6, 7) THEN N'Cable Transport'
        ELSE N'Other'
    END AS ModeGroup,
    CASE
        WHEN route.RouteTypeCode = 0 THEN N'Stadtbahn / Tram'
        WHEN route.RouteTypeCode = 1 THEN N'Subway / Metro'
        WHEN route.RouteTypeCode = 2
             AND route.NormalizedRouteLabel LIKE N'S[0-9]%' THEN N'S-Bahn'
        WHEN route.RouteTypeCode = 2
             AND route.NormalizedRouteLabel LIKE N'RE%' THEN N'Regional Express (RE)'
        WHEN route.RouteTypeCode = 2
             AND route.NormalizedRouteLabel LIKE N'RB%' THEN N'Regional Bahn (RB)'
        WHEN route.RouteTypeCode = 2 THEN N'Other Rail'
        WHEN route.RouteTypeCode = 3
             AND
             (
                 route.NormalizedAgencyName LIKE N'%SEV%'
                 OR route.NormalizedRouteLabel LIKE N'RE%'
                 OR route.NormalizedRouteLabel LIKE N'RB%'
                 OR route.NormalizedRouteLabel LIKE N'S[0-9]%'
             ) THEN N'Rail Replacement Bus (SEV)'
        WHEN route.RouteTypeCode = 3 AND route.AgencyId = N'1' THEN N'Urban Bus (KVB)'
        WHEN route.RouteTypeCode = 3 THEN N'Regional / Other Bus'
        WHEN route.RouteTypeCode = 4 THEN N'Ferry'
        WHEN route.RouteTypeCode = 5 THEN N'Cable Tram'
        WHEN route.RouteTypeCode = 6 THEN N'Aerial Lift'
        WHEN route.RouteTypeCode = 7 THEN N'Funicular'
        WHEN route.RouteTypeCode = 11 THEN N'Trolleybus'
        WHEN route.RouteTypeCode = 12 THEN N'Monorail'
        ELSE N'Other / Unclassified'
    END AS ModeDetail,
    CASE
        WHEN route.RouteTypeCode = 0 THEN 10
        WHEN route.RouteTypeCode = 1 THEN 20
        WHEN route.RouteTypeCode = 2 AND route.NormalizedRouteLabel LIKE N'S[0-9]%' THEN 30
        WHEN route.RouteTypeCode = 2 AND route.NormalizedRouteLabel LIKE N'RE%' THEN 40
        WHEN route.RouteTypeCode = 2 AND route.NormalizedRouteLabel LIKE N'RB%' THEN 50
        WHEN route.RouteTypeCode = 2 THEN 60
        WHEN route.RouteTypeCode = 3
             AND
             (
                 route.NormalizedAgencyName LIKE N'%SEV%'
                 OR route.NormalizedRouteLabel LIKE N'RE%'
                 OR route.NormalizedRouteLabel LIKE N'RB%'
                 OR route.NormalizedRouteLabel LIKE N'S[0-9]%'
             ) THEN 90
        WHEN route.RouteTypeCode = 3 AND route.AgencyId = N'1' THEN 70
        WHEN route.RouteTypeCode = 3 THEN 80
        ELSE 100
    END AS ModeSortOrder,
    CONVERT
    (
        BIT,
        CASE
            WHEN route.RouteTypeCode = 3
                 AND
                 (
                     route.NormalizedAgencyName LIKE N'%SEV%'
                     OR route.NormalizedRouteLabel LIKE N'RE%'
                     OR route.NormalizedRouteLabel LIKE N'RB%'
                     OR route.NormalizedRouteLabel LIKE N'S[0-9]%'
                 ) THEN 1
            ELSE 0
        END
    ) AS IsRailReplacementService,
    NULLIF(route.RouteUrl, N'') AS RouteUrl,
    NULLIF(route.RouteColor, N'') AS RouteColor,
    NULLIF(route.RouteTextColor, N'') AS RouteTextColor,
    route.SourceRouteRowCount,
    route.SourceAgencyCount,
    CONVERT(BIT, CASE WHEN route.SourceRouteRowCount > 1 THEN 1 ELSE 0 END) AS HasSourceAmbiguity
FROM PreparedRoute AS route;
GO

/* Trips are included when at least one of their scheduled stops is in Cologne. */
CREATE OR ALTER VIEW wrk.vwCologneServingTrip
AS
WITH CologneTripId AS
(
    SELECT DISTINCT stop_time.TripId
    FROM stg.GtfsStopTimes AS stop_time
    WHERE stop_time.StopId LIKE N'de:05315:%'
)
SELECT
    trip.TripId,
    trip.RouteId,
    trip.ServiceId,
    NULLIF(trip.TripHeadsign, N'') AS TripHeadsign,
    TRY_CONVERT(TINYINT, NULLIF(trip.DirectionId, N'')) AS DirectionId,
    NULLIF(trip.BlockId, N'') AS BlockId,
    NULLIF(trip.ShapeId, N'') AS ShapeId,
    route.AgencyId,
    route.AgencyName,
    route.RouteShortName,
    route.RouteLongName,
    route.RouteTypeCode,
    route.ModeGroup,
    route.ModeDetail,
    route.ModeSortOrder,
    route.IsRailReplacementService
FROM stg.GtfsTrips AS trip
JOIN CologneTripId AS cologne_trip
    ON cologne_trip.TripId = trip.TripId
JOIN wrk.vwCologneServingRoute AS route
    ON route.RouteId = trip.RouteId;
GO

/*
    One scheduled event per trip and Cologne stop position.
    Parent stations remain in vwCologneStop but are not expected here.
*/
CREATE OR ALTER VIEW wrk.vwCologneScheduledStopEvent
AS
SELECT
    stop_time.TripId,
    trip.RouteId,
    trip.ServiceId,
    trip.AgencyId,
    trip.AgencyName,
    trip.RouteShortName,
    trip.RouteLongName,
    trip.TripHeadsign,
    trip.DirectionId,
    trip.ModeGroup,
    trip.ModeDetail,
    trip.ModeSortOrder,
    trip.IsRailReplacementService,
    stop_time.StopId,
    stop.StopCode,
    stop.StopName,
    stop.ParentStationId,
    stop.Latitude,
    stop.Longitude,
    TRY_CONVERT(INT, stop_time.StopSequence) AS StopSequence,
    NULLIF(stop_time.ArrivalTime, N'') AS ScheduledArrivalTimeText,
    NULLIF(stop_time.DepartureTime, N'') AS ScheduledDepartureTimeText,
    wrk.GtfsTimeToSeconds(stop_time.ArrivalTime) AS ScheduledArrivalSeconds,
    wrk.GtfsTimeToSeconds(stop_time.DepartureTime) AS ScheduledDepartureSeconds,
    wrk.GtfsTimeToSeconds(stop_time.ArrivalTime) / 86400 AS ArrivalDayOffset,
    wrk.GtfsTimeToSeconds(stop_time.DepartureTime) / 86400 AS DepartureDayOffset,
    NULLIF(stop_time.StopHeadsign, N'') AS StopHeadsign,
    TRY_CONVERT(TINYINT, NULLIF(stop_time.PickupType, N'')) AS PickupType,
    TRY_CONVERT(TINYINT, NULLIF(stop_time.DropOffType, N'')) AS DropOffType,
    TRY_CONVERT(DECIMAL(18, 3), NULLIF(stop_time.ShapeDistTraveled, N'')) AS ShapeDistanceTraveled
FROM stg.GtfsStopTimes AS stop_time
JOIN wrk.vwCologneServingTrip AS trip
    ON trip.TripId = stop_time.TripId
JOIN wrk.vwCologneStop AS stop
    ON stop.StopId = stop_time.StopId;
GO

/* A compact mode-level reconciliation view for SQL checks and Power BI profiling. */
CREATE OR ALTER VIEW wrk.vwCologneModeSummary
AS
WITH RouteCount AS
(
    SELECT
        ModeSortOrder,
        ModeGroup,
        ModeDetail,
        COUNT_BIG(*) AS RouteCount
    FROM wrk.vwCologneServingRoute
    GROUP BY ModeSortOrder, ModeGroup, ModeDetail
),
TripCount AS
(
    SELECT
        ModeSortOrder,
        ModeGroup,
        ModeDetail,
        COUNT_BIG(*) AS TripCount
    FROM wrk.vwCologneServingTrip
    GROUP BY ModeSortOrder, ModeGroup, ModeDetail
),
StopEventCount AS
(
    SELECT
        ModeSortOrder,
        ModeGroup,
        ModeDetail,
        COUNT_BIG(*) AS CologneStopEventCount
    FROM wrk.vwCologneScheduledStopEvent
    GROUP BY ModeSortOrder, ModeGroup, ModeDetail
)
SELECT
    route.ModeSortOrder,
    route.ModeGroup,
    route.ModeDetail,
    route.RouteCount,
    trip.TripCount,
    stop_event.CologneStopEventCount
FROM RouteCount AS route
JOIN TripCount AS trip
    ON trip.ModeSortOrder = route.ModeSortOrder
   AND trip.ModeGroup = route.ModeGroup
   AND trip.ModeDetail = route.ModeDetail
JOIN StopEventCount AS stop_event
    ON stop_event.ModeSortOrder = route.ModeSortOrder
   AND stop_event.ModeGroup = route.ModeGroup
   AND stop_event.ModeDetail = route.ModeDetail;
GO
