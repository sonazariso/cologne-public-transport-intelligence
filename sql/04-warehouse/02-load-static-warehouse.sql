USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(DB_NAME(), 'Recovery')) <> N'SIMPLE'
BEGIN
    THROW 50013, 'For local development, run 00-configure-development-database.sql before this loader.', 1;
END;

DECLARE @GtfsLoadBatchId BIGINT =
(
    SELECT TOP (1) LoadBatchId
    FROM ctl.GtfsLoadBatch
    WHERE Status = 'Validated'
    ORDER BY LoadBatchId DESC
);

IF @GtfsLoadBatchId IS NULL
BEGIN
    THROW 50010, 'No validated GTFS load batch is available.', 1;
END;

DECLARE @FeedStartDate DATE;
DECLARE @FeedEndDate DATE;
DECLARE @WarehouseLoadBatchId BIGINT;
DECLARE @TripBatchSize BIGINT = 5000;
DECLARE @FirstTripKey BIGINT;
DECLARE @LastTripKey BIGINT;
DECLARE @MaximumTripKey BIGINT;
DECLARE @RowsInserted BIGINT;
DECLARE @TotalRowsInserted BIGINT = 0;
DECLARE @ProgressMessage NVARCHAR(4000);

SELECT
    @FeedStartDate = FeedStartDate,
    @FeedEndDate = FeedEndDate
FROM ctl.GtfsLoadBatch
WHERE LoadBatchId = @GtfsLoadBatchId;

IF @FeedStartDate IS NULL OR @FeedEndDate IS NULL OR @FeedStartDate > @FeedEndDate
BEGIN
    THROW 50011, 'The validated GTFS batch has an invalid feed date range.', 1;
END;

INSERT INTO ctl.StaticWarehouseLoadBatch (GtfsLoadBatchId, Status)
VALUES (@GtfsLoadBatchId, 'Loading');

SET @WarehouseLoadBatchId = SCOPE_IDENTITY();

BEGIN TRY
    BEGIN TRANSACTION;

    TRUNCATE TABLE dw.FactScheduledStopEvent;
    TRUNCATE TABLE dw.BridgeServiceDate;
    DELETE FROM dw.FactScheduledTrip;

    UPDATE dw.DimStop SET ParentStopKey = NULL WHERE ParentStopKey IS NOT NULL;
    DELETE FROM dw.DimRoute;
    DELETE FROM dw.DimStop;
    DELETE FROM dw.DimService;
    DELETE FROM dw.DimDate;
    DELETE FROM dw.DimMode;
    DELETE FROM dw.DimAgency;

    DBCC CHECKIDENT ('dw.DimAgency', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.DimMode', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.DimRoute', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.DimStop', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.DimService', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('dw.FactScheduledTrip', RESEED, 0) WITH NO_INFOMSGS;

    INSERT INTO dw.DimAgency
    (
        AgencyId,
        AgencyName,
        AgencyUrl,
        AgencyTimezone,
        AgencyLanguage,
        AgencyPhone,
        AgencyFareUrl,
        WarehouseLoadBatchId
    )
    SELECT DISTINCT
        agency.AgencyId,
        NULLIF(agency.AgencyName, N''),
        NULLIF(agency.AgencyUrl, N''),
        NULLIF(agency.AgencyTimezone, N''),
        NULLIF(agency.AgencyLang, N''),
        NULLIF(agency.AgencyPhone, N''),
        NULLIF(agency.AgencyFareUrl, N''),
        @WarehouseLoadBatchId
    FROM stg.GtfsAgency AS agency
    JOIN
    (
        SELECT DISTINCT AgencyId
        FROM wrk.vwCologneServingRoute
        WHERE AgencyId IS NOT NULL
    ) AS relevant_agency
        ON relevant_agency.AgencyId = agency.AgencyId;

    INSERT INTO dw.DimMode
    (
        ModeGroup,
        ModeDetail,
        ModeSortOrder,
        IsRailReplacementService,
        WarehouseLoadBatchId
    )
    SELECT DISTINCT
        ModeGroup,
        ModeDetail,
        ModeSortOrder,
        IsRailReplacementService,
        @WarehouseLoadBatchId
    FROM wrk.vwCologneServingRoute;

    INSERT INTO dw.DimRoute
    (
        RouteId,
        AgencyKey,
        ModeKey,
        RouteShortName,
        RouteLongName,
        RouteDescription,
        RouteTypeCode,
        RouteUrl,
        RouteColor,
        RouteTextColor,
        SourceRouteRowCount,
        SourceAgencyCount,
        HasSourceAmbiguity,
        WarehouseLoadBatchId
    )
    SELECT
        route.RouteId,
        agency.AgencyKey,
        mode.ModeKey,
        route.RouteShortName,
        route.RouteLongName,
        route.RouteDescription,
        route.RouteTypeCode,
        route.RouteUrl,
        route.RouteColor,
        route.RouteTextColor,
        route.SourceRouteRowCount,
        route.SourceAgencyCount,
        route.HasSourceAmbiguity,
        @WarehouseLoadBatchId
    FROM wrk.vwCologneServingRoute AS route
    LEFT JOIN dw.DimAgency AS agency
        ON agency.AgencyId = route.AgencyId
    JOIN dw.DimMode AS mode
        ON mode.ModeDetail = route.ModeDetail;

    INSERT INTO dw.DimStop
    (
        StopId,
        StopCode,
        StopName,
        StopDescription,
        Latitude,
        Longitude,
        ZoneId,
        StopUrl,
        LocationTypeCode,
        LocationTypeName,
        ParentStationId,
        StopTimezone,
        WarehouseLoadBatchId
    )
    SELECT
        StopId,
        StopCode,
        StopName,
        StopDescription,
        Latitude,
        Longitude,
        ZoneId,
        StopUrl,
        LocationTypeCode,
        LocationTypeName,
        ParentStationId,
        StopTimezone,
        @WarehouseLoadBatchId
    FROM wrk.vwCologneStop;

    UPDATE child_stop
    SET ParentStopKey = parent_stop.StopKey
    FROM dw.DimStop AS child_stop
    JOIN dw.DimStop AS parent_stop
        ON parent_stop.StopId = child_stop.ParentStationId;

    ;WITH RelevantService AS
    (
        SELECT DISTINCT ServiceId
        FROM wrk.vwCologneServingTrip
    )
    INSERT INTO dw.DimService
    (
        ServiceId,
        Monday,
        Tuesday,
        Wednesday,
        Thursday,
        Friday,
        Saturday,
        Sunday,
        StartDate,
        EndDate,
        HasBaseCalendar,
        WarehouseLoadBatchId
    )
    SELECT
        service.ServiceId,
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Monday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Tuesday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Wednesday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Thursday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Friday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Saturday), 0)),
        CONVERT(BIT, COALESCE(TRY_CONVERT(TINYINT, calendar.Sunday), 0)),
        TRY_CONVERT(DATE, calendar.StartDate, 112),
        TRY_CONVERT(DATE, calendar.EndDate, 112),
        CONVERT(BIT, CASE WHEN calendar.ServiceId IS NULL THEN 0 ELSE 1 END),
        @WarehouseLoadBatchId
    FROM RelevantService AS service
    LEFT JOIN stg.GtfsCalendar AS calendar
        ON calendar.ServiceId = service.ServiceId;

    ;WITH NumberSeries AS
    (
        SELECT TOP (DATEDIFF(DAY, @FeedStartDate, @FeedEndDate) + 1)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS DayOffset
        FROM sys.all_objects AS first_set
        CROSS JOIN sys.all_objects AS second_set
    ),
    FeedDate AS
    (
        SELECT DATEADD(DAY, DayOffset, @FeedStartDate) AS DateValue
        FROM NumberSeries
    )
    INSERT INTO dw.DimDate
    (
        DateKey,
        DateValue,
        CalendarYear,
        CalendarQuarter,
        CalendarMonth,
        MonthName,
        DayOfMonth,
        IsoWeekNumber,
        IsoWeekdayNumber,
        WeekdayName,
        IsWeekend,
        WarehouseLoadBatchId
    )
    SELECT
        CONVERT(INT, CONVERT(CHAR(8), DateValue, 112)),
        DateValue,
        DATEPART(YEAR, DateValue),
        DATEPART(QUARTER, DateValue),
        DATEPART(MONTH, DateValue),
        DATENAME(MONTH, DateValue),
        DATEPART(DAY, DateValue),
        DATEPART(ISO_WEEK, DateValue),
        CONVERT(TINYINT, (DATEDIFF(DAY, CONVERT(DATE, '19000101', 112), DateValue) % 7) + 1),
        DATENAME(WEEKDAY, DateValue),
        CONVERT
        (
            BIT,
            CASE
                WHEN ((DATEDIFF(DAY, CONVERT(DATE, '19000101', 112), DateValue) % 7) + 1) IN (6, 7)
                THEN 1 ELSE 0
            END
        ),
        @WarehouseLoadBatchId
    FROM FeedDate;

    ;WITH BaseServiceDate AS
    (
        SELECT
            service.ServiceKey,
            date_dimension.DateKey
        FROM dw.DimService AS service
        CROSS JOIN dw.DimDate AS date_dimension
        WHERE date_dimension.DateValue BETWEEN service.StartDate AND service.EndDate
          AND
          (
              (date_dimension.IsoWeekdayNumber = 1 AND service.Monday = 1)
              OR (date_dimension.IsoWeekdayNumber = 2 AND service.Tuesday = 1)
              OR (date_dimension.IsoWeekdayNumber = 3 AND service.Wednesday = 1)
              OR (date_dimension.IsoWeekdayNumber = 4 AND service.Thursday = 1)
              OR (date_dimension.IsoWeekdayNumber = 5 AND service.Friday = 1)
              OR (date_dimension.IsoWeekdayNumber = 6 AND service.Saturday = 1)
              OR (date_dimension.IsoWeekdayNumber = 7 AND service.Sunday = 1)
          )
          AND NOT EXISTS
          (
              SELECT 1
              FROM stg.GtfsCalendarDates AS exception
              WHERE exception.ServiceId = service.ServiceId
                AND TRY_CONVERT(DATE, exception.ServiceDate, 112) = date_dimension.DateValue
          )
    ),
    AddedServiceDate AS
    (
        SELECT DISTINCT
            service.ServiceKey,
            date_dimension.DateKey
        FROM stg.GtfsCalendarDates AS exception
        JOIN dw.DimService AS service
            ON service.ServiceId = exception.ServiceId
        JOIN dw.DimDate AS date_dimension
            ON date_dimension.DateValue = TRY_CONVERT(DATE, exception.ServiceDate, 112)
        WHERE exception.ExceptionType = N'1'
    )
    INSERT INTO dw.BridgeServiceDate
    (
        ServiceKey,
        DateKey,
        ActivationSource,
        WarehouseLoadBatchId
    )
    SELECT
        ServiceKey,
        DateKey,
        'Calendar',
        @WarehouseLoadBatchId
    FROM BaseServiceDate
    UNION ALL
    SELECT
        ServiceKey,
        DateKey,
        'Added exception',
        @WarehouseLoadBatchId
    FROM AddedServiceDate;

    INSERT INTO dw.FactScheduledTrip
    (
        TripId,
        RouteKey,
        AgencyKey,
        ModeKey,
        ServiceKey,
        TripHeadsign,
        DirectionId,
        BlockId,
        ShapeId,
        WarehouseLoadBatchId
    )
    SELECT
        trip.TripId,
        route.RouteKey,
        route.AgencyKey,
        route.ModeKey,
        service.ServiceKey,
        trip.TripHeadsign,
        trip.DirectionId,
        trip.BlockId,
        trip.ShapeId,
        @WarehouseLoadBatchId
    FROM wrk.vwCologneServingTrip AS trip
    JOIN dw.DimRoute AS route
        ON route.RouteId = trip.RouteId
    JOIN dw.DimService AS service
        ON service.ServiceId = trip.ServiceId;

    /*
        Commit dimensions and trip patterns before loading the 1.55M-row fact.
        The large fact is loaded in restartable transaction-log-safe batches.
        The audit row remains Loading until every batch completes.
    */
    COMMIT TRANSACTION;
    CHECKPOINT;

    SELECT
        @FirstTripKey = MIN(TripKey),
        @MaximumTripKey = MAX(TripKey)
    FROM dw.FactScheduledTrip;

    WHILE @FirstTripKey IS NOT NULL AND @FirstTripKey <= @MaximumTripKey
    BEGIN
        SET @LastTripKey = @FirstTripKey + @TripBatchSize - 1;

        BEGIN TRANSACTION;

        INSERT INTO dw.FactScheduledStopEvent
        (
            TripKey,
            RouteKey,
            AgencyKey,
            ModeKey,
            ServiceKey,
            StopKey,
            StopSequence,
            ScheduledArrivalTimeText,
            ScheduledDepartureTimeText,
            ScheduledArrivalSeconds,
            ScheduledDepartureSeconds,
            ArrivalDayOffset,
            DepartureDayOffset,
            StopHeadsign,
            PickupType,
            DropOffType,
            ShapeDistanceTraveled,
            WarehouseLoadBatchId
        )
        SELECT
            trip.TripKey,
            trip.RouteKey,
            trip.AgencyKey,
            trip.ModeKey,
            trip.ServiceKey,
            stop.StopKey,
            TRY_CONVERT(INT, stop_time.StopSequence),
            NULLIF(stop_time.ArrivalTime, N''),
            NULLIF(stop_time.DepartureTime, N''),
            wrk.GtfsTimeToSeconds(stop_time.ArrivalTime),
            wrk.GtfsTimeToSeconds(stop_time.DepartureTime),
            wrk.GtfsTimeToSeconds(stop_time.ArrivalTime) / 86400,
            wrk.GtfsTimeToSeconds(stop_time.DepartureTime) / 86400,
            NULLIF(stop_time.StopHeadsign, N''),
            TRY_CONVERT(TINYINT, NULLIF(stop_time.PickupType, N'')),
            TRY_CONVERT(TINYINT, NULLIF(stop_time.DropOffType, N'')),
            TRY_CONVERT(DECIMAL(18, 3), NULLIF(stop_time.ShapeDistTraveled, N'')),
            @WarehouseLoadBatchId
        FROM dw.FactScheduledTrip AS trip
        JOIN stg.GtfsStopTimes AS stop_time
            ON stop_time.TripId = trip.TripId
        JOIN dw.DimStop AS stop
            ON stop.StopId = stop_time.StopId
        WHERE trip.TripKey BETWEEN @FirstTripKey AND @LastTripKey;

        SET @RowsInserted = @@ROWCOUNT;
        SET @TotalRowsInserted += @RowsInserted;

        COMMIT TRANSACTION;
        CHECKPOINT;

        SET @ProgressMessage = CONCAT
        (
            N'Loaded TripKey batch ',
            @FirstTripKey,
            N'–',
            @LastTripKey,
            N': ',
            @RowsInserted,
            N' stop events; cumulative ',
            @TotalRowsInserted,
            N'.'
        );
        RAISERROR(@ProgressMessage, 10, 1) WITH NOWAIT;

        SET @FirstTripKey = @LastTripKey + 1;
    END;

    UPDATE ctl.StaticWarehouseLoadBatch
    SET
        CompletedAtUtc = SYSUTCDATETIME(),
        Status = 'Loaded',
        AgencyRows = (SELECT COUNT_BIG(*) FROM dw.DimAgency),
        ModeRows = (SELECT COUNT_BIG(*) FROM dw.DimMode),
        RouteRows = (SELECT COUNT_BIG(*) FROM dw.DimRoute),
        StopRows = (SELECT COUNT_BIG(*) FROM dw.DimStop),
        ServiceRows = (SELECT COUNT_BIG(*) FROM dw.DimService),
        DateRows = (SELECT COUNT_BIG(*) FROM dw.DimDate),
        ServiceDateRows = (SELECT COUNT_BIG(*) FROM dw.BridgeServiceDate),
        TripRows = (SELECT COUNT_BIG(*) FROM dw.FactScheduledTrip),
        ScheduledStopEventRows = (SELECT COUNT_BIG(*) FROM dw.FactScheduledStopEvent)
    WHERE WarehouseLoadBatchId = @WarehouseLoadBatchId;

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

    UPDATE ctl.StaticWarehouseLoadBatch
    SET
        CompletedAtUtc = SYSUTCDATETIME(),
        Status = 'Failed',
        ErrorMessage = ERROR_MESSAGE()
    WHERE WarehouseLoadBatchId = @WarehouseLoadBatchId;

    THROW;
END CATCH;

SELECT *
FROM ctl.StaticWarehouseLoadBatch
WHERE WarehouseLoadBatchId = @WarehouseLoadBatchId;
GO
