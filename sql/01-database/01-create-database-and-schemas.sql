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

/*
    The static GTFS staging tables contain one replaceable feed snapshot.
    Keep its owner in one small control row rather than repeating the batch ID
    on every source row.  A NULL owner is valid before the first GTFS load.
*/
IF OBJECT_ID(N'ctl.GtfsStagingState', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.GtfsStagingState
    (
        StagingStateId TINYINT NOT NULL
            CONSTRAINT PK_ctl_GtfsStagingState PRIMARY KEY
            CONSTRAINT CK_ctl_GtfsStagingState_Singleton CHECK (StagingStateId = 1),
        CurrentLoadBatchId BIGINT NULL,
        UpdatedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_ctl_GtfsStagingState_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ctl_GtfsStagingState_CurrentLoadBatch
            FOREIGN KEY (CurrentLoadBatchId) REFERENCES ctl.GtfsLoadBatch (LoadBatchId)
    );
END;

IF NOT EXISTS
(
    SELECT 1
    FROM ctl.GtfsStagingState
    WHERE StagingStateId = 1
)
BEGIN
    INSERT INTO ctl.GtfsStagingState (StagingStateId)
    VALUES (1);
END;
GO

/*
    Safe bootstrap for an existing database.  If static staging already has
    one feed_info row and the state row is still uninitialized, associate it
    only when exactly one completed batch has the same feed metadata.  This
    deliberately stops on ambiguity instead of guessing from MAX(LoadBatchId)
    or from the latest Validated batch.
*/
IF OBJECT_ID(N'stg.GtfsFeedInfo', N'U') IS NOT NULL
BEGIN
    DECLARE @CurrentStagingBatchId BIGINT;
    DECLARE @FeedInfoRowCount BIGINT;
    DECLARE @MatchingBatchCount BIGINT;
    DECLARE @FeedVersion NVARCHAR(100);
    DECLARE @FeedStartDate DATE;
    DECLARE @FeedEndDate DATE;
    DECLARE @MatchingBatchId BIGINT;

    SELECT @CurrentStagingBatchId = CurrentLoadBatchId
    FROM ctl.GtfsStagingState
    WHERE StagingStateId = 1;

    IF @CurrentStagingBatchId IS NULL
    BEGIN
        SELECT @FeedInfoRowCount = COUNT_BIG(*)
        FROM stg.GtfsFeedInfo;

        IF @FeedInfoRowCount > 1
        BEGIN
            THROW 50003, 'GTFS staging ownership cannot be initialized because stg.GtfsFeedInfo contains multiple rows.', 1;
        END;

        IF @FeedInfoRowCount = 1
        BEGIN
            SELECT
                @FeedVersion = FeedVersion,
                @FeedStartDate = TRY_CONVERT(DATE, FeedStartDate, 112),
                @FeedEndDate = TRY_CONVERT(DATE, FeedEndDate, 112)
            FROM stg.GtfsFeedInfo;

            SELECT
                @MatchingBatchCount = COUNT_BIG(*),
                @MatchingBatchId = MIN(LoadBatchId)
            FROM ctl.GtfsLoadBatch
            WHERE Status IN ('Loaded', 'Validated', 'ValidationFailed')
              AND ((FeedVersion = @FeedVersion) OR (FeedVersion IS NULL AND @FeedVersion IS NULL))
              AND ((FeedStartDate = @FeedStartDate) OR (FeedStartDate IS NULL AND @FeedStartDate IS NULL))
              AND ((FeedEndDate = @FeedEndDate) OR (FeedEndDate IS NULL AND @FeedEndDate IS NULL));

            IF @MatchingBatchCount = 0
            BEGIN
                THROW 50004, 'GTFS staging ownership cannot be initialized because no completed batch matches stg.GtfsFeedInfo.', 1;
            END;

            IF @MatchingBatchCount > 1
            BEGIN
                THROW 50005, 'GTFS staging ownership cannot be initialized because multiple completed batches match stg.GtfsFeedInfo.', 1;
            END;

            UPDATE ctl.GtfsStagingState
            SET
                CurrentLoadBatchId = @MatchingBatchId,
                UpdatedAtUtc = SYSUTCDATETIME()
            WHERE StagingStateId = 1;
        END;
    END;
END;
GO
