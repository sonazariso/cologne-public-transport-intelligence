USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* One audit row for each rebuild of the static GTFS analytical warehouse. */
IF OBJECT_ID(N'ctl.StaticWarehouseLoadBatch', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.StaticWarehouseLoadBatch
    (
        WarehouseLoadBatchId BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_ctl_StaticWarehouseLoadBatch PRIMARY KEY,
        GtfsLoadBatchId BIGINT NOT NULL,
        StartedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_ctl_StaticWarehouseLoadBatch_StartedAtUtc DEFAULT SYSUTCDATETIME(),
        CompletedAtUtc DATETIME2(0) NULL,
        Status VARCHAR(30) NOT NULL,
        AgencyRows BIGINT NULL,
        ModeRows BIGINT NULL,
        RouteRows BIGINT NULL,
        StopRows BIGINT NULL,
        ServiceRows BIGINT NULL,
        DateRows BIGINT NULL,
        ServiceDateRows BIGINT NULL,
        TripRows BIGINT NULL,
        ScheduledStopEventRows BIGINT NULL,
        ErrorMessage NVARCHAR(4000) NULL,
        LoadedBy SYSNAME NOT NULL
            CONSTRAINT DF_ctl_StaticWarehouseLoadBatch_LoadedBy DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT FK_ctl_StaticWarehouseLoadBatch_GtfsLoadBatch
            FOREIGN KEY (GtfsLoadBatchId) REFERENCES ctl.GtfsLoadBatch (LoadBatchId),
        CONSTRAINT CK_ctl_StaticWarehouseLoadBatch_Status
            CHECK (Status IN ('Loading', 'Loaded', 'Validated', 'ValidationFailed', 'Failed'))
    );
END;
GO

IF OBJECT_ID(N'dw.DimAgency', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimAgency
    (
        AgencyKey INT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_DimAgency PRIMARY KEY,
        AgencyId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NOT NULL,
        AgencyName NVARCHAR(100) NULL,
        AgencyUrl NVARCHAR(500) NULL,
        AgencyTimezone NVARCHAR(100) NULL,
        AgencyLanguage NVARCHAR(10) NULL,
        AgencyPhone NVARCHAR(50) NULL,
        AgencyFareUrl NVARCHAR(500) NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimAgency_AgencyId UNIQUE (AgencyId),
        CONSTRAINT FK_dw_DimAgency_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.DimMode', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimMode
    (
        ModeKey SMALLINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_DimMode PRIMARY KEY,
        ModeGroup NVARCHAR(100) NOT NULL,
        ModeDetail NVARCHAR(100) NOT NULL,
        ModeSortOrder INT NOT NULL,
        IsRailReplacementService BIT NOT NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimMode_ModeDetail UNIQUE (ModeDetail),
        CONSTRAINT FK_dw_DimMode_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.DimRoute', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimRoute
    (
        RouteKey INT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_DimRoute PRIMARY KEY,
        RouteId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL,
        AgencyKey INT NULL,
        ModeKey SMALLINT NOT NULL,
        RouteShortName NVARCHAR(50) NULL,
        RouteLongName NVARCHAR(255) NULL,
        RouteDescription NVARCHAR(1000) NULL,
        RouteTypeCode INT NULL,
        RouteUrl NVARCHAR(500) NULL,
        RouteColor NVARCHAR(20) NULL,
        RouteTextColor NVARCHAR(20) NULL,
        SourceRouteRowCount BIGINT NOT NULL,
        SourceAgencyCount BIGINT NOT NULL,
        HasSourceAmbiguity BIT NOT NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimRoute_RouteId UNIQUE (RouteId),
        CONSTRAINT FK_dw_DimRoute_Agency
            FOREIGN KEY (AgencyKey) REFERENCES dw.DimAgency (AgencyKey),
        CONSTRAINT FK_dw_DimRoute_Mode
            FOREIGN KEY (ModeKey) REFERENCES dw.DimMode (ModeKey),
        CONSTRAINT FK_dw_DimRoute_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.DimStop', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimStop
    (
        StopKey INT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_DimStop PRIMARY KEY,
        StopId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL,
        StopCode NVARCHAR(50) NULL,
        StopName NVARCHAR(255) NULL,
        StopDescription NVARCHAR(1000) NULL,
        Latitude DECIMAL(9, 6) NULL,
        Longitude DECIMAL(9, 6) NULL,
        ZoneId NVARCHAR(100) NULL,
        StopUrl NVARCHAR(500) NULL,
        LocationTypeCode TINYINT NULL,
        LocationTypeName NVARCHAR(100) NOT NULL,
        ParentStationId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ParentStopKey INT NULL,
        StopTimezone NVARCHAR(100) NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimStop_StopId UNIQUE (StopId),
        CONSTRAINT FK_dw_DimStop_ParentStop
            FOREIGN KEY (ParentStopKey) REFERENCES dw.DimStop (StopKey),
        CONSTRAINT FK_dw_DimStop_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.DimService', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimService
    (
        ServiceKey INT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_DimService PRIMARY KEY,
        ServiceId NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NOT NULL,
        Monday BIT NOT NULL,
        Tuesday BIT NOT NULL,
        Wednesday BIT NOT NULL,
        Thursday BIT NOT NULL,
        Friday BIT NOT NULL,
        Saturday BIT NOT NULL,
        Sunday BIT NOT NULL,
        StartDate DATE NULL,
        EndDate DATE NULL,
        HasBaseCalendar BIT NOT NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimService_ServiceId UNIQUE (ServiceId),
        CONSTRAINT FK_dw_DimService_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.DimDate', N'U') IS NULL
BEGIN
    CREATE TABLE dw.DimDate
    (
        DateKey INT NOT NULL
            CONSTRAINT PK_dw_DimDate PRIMARY KEY,
        DateValue DATE NOT NULL,
        CalendarYear SMALLINT NOT NULL,
        CalendarQuarter TINYINT NOT NULL,
        CalendarMonth TINYINT NOT NULL,
        MonthName NVARCHAR(30) NOT NULL,
        DayOfMonth TINYINT NOT NULL,
        IsoWeekNumber TINYINT NOT NULL,
        IsoWeekdayNumber TINYINT NOT NULL,
        WeekdayName NVARCHAR(30) NOT NULL,
        IsWeekend BIT NOT NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_DimDate_DateValue UNIQUE (DateValue),
        CONSTRAINT FK_dw_DimDate_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.BridgeServiceDate', N'U') IS NULL
BEGIN
    CREATE TABLE dw.BridgeServiceDate
    (
        ServiceKey INT NOT NULL,
        DateKey INT NOT NULL,
        ActivationSource VARCHAR(30) NOT NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT PK_dw_BridgeServiceDate PRIMARY KEY (ServiceKey, DateKey),
        CONSTRAINT FK_dw_BridgeServiceDate_Service
            FOREIGN KEY (ServiceKey) REFERENCES dw.DimService (ServiceKey),
        CONSTRAINT FK_dw_BridgeServiceDate_Date
            FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey),
        CONSTRAINT FK_dw_BridgeServiceDate_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId),
        CONSTRAINT CK_dw_BridgeServiceDate_ActivationSource
            CHECK (ActivationSource IN ('Calendar', 'Added exception'))
    );
END;
GO

IF OBJECT_ID(N'dw.FactScheduledTrip', N'U') IS NULL
BEGIN
    CREATE TABLE dw.FactScheduledTrip
    (
        TripKey BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_FactScheduledTrip PRIMARY KEY,
        TripId NVARCHAR(255) COLLATE Latin1_General_100_BIN2 NOT NULL,
        RouteKey INT NOT NULL,
        AgencyKey INT NULL,
        ModeKey SMALLINT NOT NULL,
        ServiceKey INT NOT NULL,
        TripHeadsign NVARCHAR(255) NULL,
        DirectionId TINYINT NULL,
        BlockId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        ShapeId NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT UQ_dw_FactScheduledTrip_TripId UNIQUE (TripId),
        CONSTRAINT FK_dw_FactScheduledTrip_Route
            FOREIGN KEY (RouteKey) REFERENCES dw.DimRoute (RouteKey),
        CONSTRAINT FK_dw_FactScheduledTrip_Agency
            FOREIGN KEY (AgencyKey) REFERENCES dw.DimAgency (AgencyKey),
        CONSTRAINT FK_dw_FactScheduledTrip_Mode
            FOREIGN KEY (ModeKey) REFERENCES dw.DimMode (ModeKey),
        CONSTRAINT FK_dw_FactScheduledTrip_Service
            FOREIGN KEY (ServiceKey) REFERENCES dw.DimService (ServiceKey),
        CONSTRAINT FK_dw_FactScheduledTrip_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );
END;
GO

IF OBJECT_ID(N'dw.FactScheduledStopEvent', N'U') IS NULL
BEGIN
    CREATE TABLE dw.FactScheduledStopEvent
    (
        ScheduledStopEventKey BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_FactScheduledStopEvent PRIMARY KEY,
        TripKey BIGINT NOT NULL,
        RouteKey INT NOT NULL,
        AgencyKey INT NULL,
        ModeKey SMALLINT NOT NULL,
        ServiceKey INT NOT NULL,
        StopKey INT NOT NULL,
        StopSequence INT NOT NULL,
        ScheduledArrivalTimeText NVARCHAR(20) NULL,
        ScheduledDepartureTimeText NVARCHAR(20) NULL,
        ScheduledArrivalSeconds INT NOT NULL,
        ScheduledDepartureSeconds INT NOT NULL,
        ArrivalDayOffset INT NOT NULL,
        DepartureDayOffset INT NOT NULL,
        StopHeadsign NVARCHAR(255) NULL,
        PickupType TINYINT NULL,
        DropOffType TINYINT NULL,
        ShapeDistanceTraveled DECIMAL(18, 3) NULL,
        WarehouseLoadBatchId BIGINT NOT NULL,
        CONSTRAINT FK_dw_FactScheduledStopEvent_Trip
            FOREIGN KEY (TripKey) REFERENCES dw.FactScheduledTrip (TripKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_Route
            FOREIGN KEY (RouteKey) REFERENCES dw.DimRoute (RouteKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_Agency
            FOREIGN KEY (AgencyKey) REFERENCES dw.DimAgency (AgencyKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_Mode
            FOREIGN KEY (ModeKey) REFERENCES dw.DimMode (ModeKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_Service
            FOREIGN KEY (ServiceKey) REFERENCES dw.DimService (ServiceKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_Stop
            FOREIGN KEY (StopKey) REFERENCES dw.DimStop (StopKey),
        CONSTRAINT FK_dw_FactScheduledStopEvent_WarehouseLoadBatch
            FOREIGN KEY (WarehouseLoadBatchId)
            REFERENCES ctl.StaticWarehouseLoadBatch (WarehouseLoadBatchId)
    );

    CREATE UNIQUE INDEX UX_FactScheduledStopEvent_TripSequence
        ON dw.FactScheduledStopEvent (TripKey, StopSequence);

    CREATE INDEX IX_FactScheduledStopEvent_Stop
        ON dw.FactScheduledStopEvent (StopKey)
        INCLUDE (RouteKey, ModeKey, ScheduledArrivalSeconds, ScheduledDepartureSeconds);

    CREATE INDEX IX_FactScheduledStopEvent_Route
        ON dw.FactScheduledStopEvent (RouteKey)
        INCLUDE (StopKey, ModeKey, TripKey);

    CREATE INDEX IX_FactScheduledStopEvent_Mode
        ON dw.FactScheduledStopEvent (ModeKey)
        INCLUDE (RouteKey, StopKey, TripKey);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.BridgeServiceDate')
      AND name = N'IX_BridgeServiceDate_Date'
)
BEGIN
    CREATE INDEX IX_BridgeServiceDate_Date
        ON dw.BridgeServiceDate (DateKey, ServiceKey);
END;
GO
