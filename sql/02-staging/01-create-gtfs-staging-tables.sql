USE CologneTransitIntelligence;
GO

/*
    Source-faithful GTFS staging.
    Values remain text so that source-quality problems are visible before conversion.
    GTFS identifiers use a binary collation for exact comparisons.
*/

IF OBJECT_ID(N'stg.GtfsAgency', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsAgency
    (
        AgencyId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NULL,
        AgencyName NVARCHAR(100) NULL,
        AgencyUrl NVARCHAR(500) NULL,
        AgencyTimezone NVARCHAR(100) NULL,
        AgencyLang NVARCHAR(10) NULL,
        AgencyPhone NVARCHAR(50) NULL,
        AgencyFareUrl NVARCHAR(500) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsCalendar', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsCalendar
    (
        ServiceId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NULL,
        Monday NVARCHAR(10) NULL,
        Tuesday NVARCHAR(10) NULL,
        Wednesday NVARCHAR(10) NULL,
        Thursday NVARCHAR(10) NULL,
        Friday NVARCHAR(10) NULL,
        Saturday NVARCHAR(10) NULL,
        Sunday NVARCHAR(10) NULL,
        StartDate NVARCHAR(20) NULL,
        EndDate NVARCHAR(20) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsCalendarDates', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsCalendarDates
    (
        ServiceId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NULL,
        ServiceDate NVARCHAR(20) NULL,
        ExceptionType NVARCHAR(10) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsFeedInfo', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsFeedInfo
    (
        FeedPublisherName NVARCHAR(100) NULL,
        FeedPublisherUrl NVARCHAR(500) NULL,
        FeedLang NVARCHAR(10) NULL,
        FeedStartDate NVARCHAR(20) NULL,
        FeedEndDate NVARCHAR(20) NULL,
        FeedVersion NVARCHAR(100) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsFrequencies', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsFrequencies
    (
        TripId NVARCHAR(255) COLLATE Latin1_General_100_BIN2 NULL,
        StartTime NVARCHAR(20) NULL,
        EndTime NVARCHAR(20) NULL,
        HeadwaySecs NVARCHAR(20) NULL,
        ExactTimes NVARCHAR(10) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsRoutes', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsRoutes
    (
        RouteId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        AgencyId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NULL,
        RouteShortName NVARCHAR(50) NULL,
        RouteLongName NVARCHAR(255) NULL,
        RouteDesc NVARCHAR(1000) NULL,
        RouteType NVARCHAR(10) NULL,
        RouteUrl NVARCHAR(500) NULL,
        RouteColor NVARCHAR(20) NULL,
        RouteTextColor NVARCHAR(20) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsShapes', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsShapes
    (
        ShapeId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ShapePtLat NVARCHAR(30) NULL,
        ShapePtLon NVARCHAR(30) NULL,
        ShapePtSequence NVARCHAR(20) NULL,
        ShapeDistTraveled NVARCHAR(50) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsStopTimes', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsStopTimes
    (
        TripId NVARCHAR(255) COLLATE Latin1_General_100_BIN2 NULL,
        ArrivalTime NVARCHAR(20) NULL,
        DepartureTime NVARCHAR(20) NULL,
        StopId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        StopSequence NVARCHAR(20) NULL,
        StopHeadsign NVARCHAR(255) NULL,
        PickupType NVARCHAR(10) NULL,
        DropOffType NVARCHAR(10) NULL,
        ShapeDistTraveled NVARCHAR(50) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsStops', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsStops
    (
        StopId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        StopCode NVARCHAR(50) NULL,
        StopName NVARCHAR(255) NULL,
        StopDesc NVARCHAR(1000) NULL,
        StopLat NVARCHAR(30) NULL,
        StopLon NVARCHAR(30) NULL,
        ZoneId NVARCHAR(100) NULL,
        StopUrl NVARCHAR(500) NULL,
        LocationType NVARCHAR(10) NULL,
        ParentStation NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        StopTimezone NVARCHAR(100) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsTransfers', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsTransfers
    (
        FromStopId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ToStopId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        TransferType NVARCHAR(10) NULL,
        MinTransferTime NVARCHAR(20) NULL
    );
END;

IF OBJECT_ID(N'stg.GtfsTrips', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GtfsTrips
    (
        RouteId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ServiceId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NULL,
        TripId NVARCHAR(255) COLLATE Latin1_General_100_BIN2 NULL,
        TripHeadsign NVARCHAR(255) NULL,
        DirectionId NVARCHAR(10) NULL,
        BlockId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ShapeId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL
    );
END;
GO
