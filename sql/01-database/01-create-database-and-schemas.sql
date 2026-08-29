USE master;
GO

IF DB_ID(N'CologneTransitIntelligence') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE CologneTransitIntelligence;');
END;
GO

USE CologneTransitIntelligence;
GO

IF SCHEMA_ID(N'ctl') IS NULL EXEC(N'CREATE SCHEMA ctl AUTHORIZATION dbo;');
IF SCHEMA_ID(N'stg') IS NULL EXEC(N'CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID(N'wrk') IS NULL EXEC(N'CREATE SCHEMA wrk AUTHORIZATION dbo;');
IF SCHEMA_ID(N'dw') IS NULL EXEC(N'CREATE SCHEMA dw AUTHORIZATION dbo;');
IF SCHEMA_ID(N'analytics') IS NULL EXEC(N'CREATE SCHEMA analytics AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'ctl.GtfsLoadBatch', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.GtfsLoadBatch
    (
        LoadBatchId BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ctl_GtfsLoadBatch PRIMARY KEY,
        SourceName NVARCHAR(100) NOT NULL
            CONSTRAINT DF_ctl_GtfsLoadBatch_SourceName DEFAULT N'VRS static GTFS',
        SourcePath NVARCHAR(1000) NOT NULL,
        FeedVersion NVARCHAR(100) NULL,
        FeedStartDate DATE NULL,
        FeedEndDate DATE NULL,
        StartedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_ctl_GtfsLoadBatch_StartedAtUtc DEFAULT SYSUTCDATETIME(),
        CompletedAtUtc DATETIME2(0) NULL,
        Status VARCHAR(30) NOT NULL,
        ErrorMessage NVARCHAR(4000) NULL,
        LoadedBy SYSNAME NOT NULL
            CONSTRAINT DF_ctl_GtfsLoadBatch_LoadedBy DEFAULT ORIGINAL_LOGIN(),
        CONSTRAINT CK_ctl_GtfsLoadBatch_Status CHECK
        (
            Status IN ('Loading', 'Loaded', 'Validated', 'ValidationFailed', 'Failed')
        )
    );
END;
GO
