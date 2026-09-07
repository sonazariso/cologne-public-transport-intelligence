USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    One operational audit row per MDD/TRIAS Collector execution.

    This table deliberately remains separate from the source-faithful
    realtime observations.  A run may be left in Started when the process is
    terminated before its completion update can be written.
*/
IF OBJECT_ID(N'ctl.MddCollectorRun', N'U') IS NULL
BEGIN
    CREATE TABLE ctl.MddCollectorRun
    (
        CollectorRunId BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_ctl_MddCollectorRun PRIMARY KEY,
        StartedAtUtc DATETIME2(0) NOT NULL,
        CompletedAtUtc DATETIME2(0) NULL,
        Status VARCHAR(20) NOT NULL
            CONSTRAINT DF_ctl_MddCollectorRun_Status DEFAULT ('Started'),
        DurationMs BIGINT NULL,

        SamplingMode VARCHAR(20) NULL,
        SamplingBucketUtc DATETIME2(0) NULL,
        SamplingSlot SMALLINT NULL,
        SamplingTargetId INT NULL,
        SamplingTargetName NVARCHAR(200) NULL,
        StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL,
        NumberOfResults TINYINT NULL,

        ObservedAtUtc DATETIME2(0) NULL,
        HttpStatus INT NULL,
        HttpAttempts INT NULL,

        StopEventsReturned BIGINT NULL,
        SituationsInContext BIGINT NULL,
        UnidentifiedSituations BIGINT NULL,
        LinksObserved BIGINT NULL,

        StopsInserted BIGINT NULL,
        StopsAlreadyPresent BIGINT NULL,
        SituationsInserted BIGINT NULL,
        SituationsAlreadyPresent BIGINT NULL,
        LinksInserted BIGINT NULL,
        LinksAlreadyPresent BIGINT NULL,
        LinksSkippedUnresolved BIGINT NULL,

        ErrorCategory VARCHAR(50) NULL,
        ErrorMessage NVARCHAR(4000) NULL,

        CONSTRAINT CK_ctl_MddCollectorRun_Status
            CHECK (Status IN ('Started', 'Succeeded', 'Failed')),
        CONSTRAINT CK_ctl_MddCollectorRun_SamplingMode
            CHECK (SamplingMode IS NULL OR SamplingMode IN ('Automatic', 'Manual')),
        CONSTRAINT CK_ctl_MddCollectorRun_DurationMs
            CHECK (DurationMs IS NULL OR DurationMs >= 0),
        CONSTRAINT CK_ctl_MddCollectorRun_NumberOfResults
            CHECK (NumberOfResults IS NULL OR NumberOfResults BETWEEN 1 AND 100),
        CONSTRAINT CK_ctl_MddCollectorRun_SamplingSlot
            CHECK (SamplingSlot IS NULL OR SamplingSlot > 0),
        CONSTRAINT CK_ctl_MddCollectorRun_HttpAttempts
            CHECK (HttpAttempts IS NULL OR HttpAttempts >= 0),
        CONSTRAINT CK_ctl_MddCollectorRun_NonNegativeCounts
            CHECK
            (
                (StopEventsReturned IS NULL OR StopEventsReturned >= 0)
                AND (SituationsInContext IS NULL OR SituationsInContext >= 0)
                AND (UnidentifiedSituations IS NULL OR UnidentifiedSituations >= 0)
                AND (LinksObserved IS NULL OR LinksObserved >= 0)
                AND (StopsInserted IS NULL OR StopsInserted >= 0)
                AND (StopsAlreadyPresent IS NULL OR StopsAlreadyPresent >= 0)
                AND (SituationsInserted IS NULL OR SituationsInserted >= 0)
                AND (SituationsAlreadyPresent IS NULL OR SituationsAlreadyPresent >= 0)
                AND (LinksInserted IS NULL OR LinksInserted >= 0)
                AND (LinksAlreadyPresent IS NULL OR LinksAlreadyPresent >= 0)
                AND (LinksSkippedUnresolved IS NULL OR LinksSkippedUnresolved >= 0)
            )
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'ctl.MddCollectorRun')
      AND name = N'IX_ctl_MddCollectorRun_StartedAtUtc'
)
BEGIN
    CREATE INDEX IX_ctl_MddCollectorRun_StartedAtUtc
        ON ctl.MddCollectorRun (StartedAtUtc DESC);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'ctl.MddCollectorRun')
      AND name = N'IX_ctl_MddCollectorRun_Status_StartedAtUtc'
)
BEGIN
    CREATE INDEX IX_ctl_MddCollectorRun_Status_StartedAtUtc
        ON ctl.MddCollectorRun (Status, StartedAtUtc DESC);
END;
GO

CREATE OR ALTER PROCEDURE ctl.uspStartMddCollectorRun
    @StartedAtUtc DATETIME2(0),
    @SamplingMode VARCHAR(20) = NULL,
    @StopPointRef NVARCHAR(100) = NULL,
    @NumberOfResults TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @SamplingMode IS NOT NULL
       AND @SamplingMode NOT IN ('Automatic', 'Manual')
    BEGIN
        THROW 51010, 'Invalid MDD Collector sampling mode.', 1;
    END;

    IF @NumberOfResults IS NOT NULL
       AND @NumberOfResults NOT BETWEEN 1 AND 100
    BEGIN
        THROW 51011, 'Invalid MDD Collector number of results.', 1;
    END;

    INSERT INTO ctl.MddCollectorRun
    (
        StartedAtUtc,
        Status,
        SamplingMode,
        StopPointRef,
        NumberOfResults
    )
    OUTPUT INSERTED.CollectorRunId
    VALUES
    (
        @StartedAtUtc,
        'Started',
        @SamplingMode,
        @StopPointRef,
        @NumberOfResults
    );
END;
GO

CREATE OR ALTER PROCEDURE ctl.uspCompleteMddCollectorRun
    @CollectorRunId BIGINT,
    @Status VARCHAR(20),
    @CompletedAtUtc DATETIME2(0),
    @DurationMs BIGINT,
    @SamplingMode VARCHAR(20) = NULL,
    @SamplingBucketUtc DATETIME2(0) = NULL,
    @SamplingSlot SMALLINT = NULL,
    @SamplingTargetId INT = NULL,
    @SamplingTargetName NVARCHAR(200) = NULL,
    @StopPointRef NVARCHAR(100) = NULL,
    @NumberOfResults TINYINT = NULL,
    @ObservedAtUtc DATETIME2(0) = NULL,
    @HttpStatus INT = NULL,
    @HttpAttempts INT = NULL,
    @StopEventsReturned BIGINT = NULL,
    @SituationsInContext BIGINT = NULL,
    @UnidentifiedSituations BIGINT = NULL,
    @LinksObserved BIGINT = NULL,
    @StopsInserted BIGINT = NULL,
    @StopsAlreadyPresent BIGINT = NULL,
    @SituationsInserted BIGINT = NULL,
    @SituationsAlreadyPresent BIGINT = NULL,
    @LinksInserted BIGINT = NULL,
    @LinksAlreadyPresent BIGINT = NULL,
    @LinksSkippedUnresolved BIGINT = NULL,
    @ErrorCategory VARCHAR(50) = NULL,
    @ErrorMessage NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Succeeded', 'Failed')
    BEGIN
        THROW 51012, 'Invalid MDD Collector completion status.', 1;
    END;

    IF @DurationMs < 0
    BEGIN
        THROW 51013, 'MDD Collector duration cannot be negative.', 1;
    END;

    IF @Status = 'Succeeded'
    BEGIN
        SET @ErrorCategory = NULL;
        SET @ErrorMessage = NULL;
    END;

    UPDATE ctl.MddCollectorRun
    SET
        CompletedAtUtc = @CompletedAtUtc,
        Status = @Status,
        DurationMs = @DurationMs,
        SamplingMode = @SamplingMode,
        SamplingBucketUtc = @SamplingBucketUtc,
        SamplingSlot = @SamplingSlot,
        SamplingTargetId = @SamplingTargetId,
        SamplingTargetName = @SamplingTargetName,
        StopPointRef = @StopPointRef,
        NumberOfResults = @NumberOfResults,
        ObservedAtUtc = @ObservedAtUtc,
        HttpStatus = @HttpStatus,
        HttpAttempts = @HttpAttempts,
        StopEventsReturned = @StopEventsReturned,
        SituationsInContext = @SituationsInContext,
        UnidentifiedSituations = @UnidentifiedSituations,
        LinksObserved = @LinksObserved,
        StopsInserted = @StopsInserted,
        StopsAlreadyPresent = @StopsAlreadyPresent,
        SituationsInserted = @SituationsInserted,
        SituationsAlreadyPresent = @SituationsAlreadyPresent,
        LinksInserted = @LinksInserted,
        LinksAlreadyPresent = @LinksAlreadyPresent,
        LinksSkippedUnresolved = @LinksSkippedUnresolved,
        ErrorCategory = @ErrorCategory,
        ErrorMessage = @ErrorMessage
    WHERE CollectorRunId = @CollectorRunId;

    IF @@ROWCOUNT = 0
    BEGIN
        THROW 51014, 'MDD Collector run was not found for completion.', 1;
    END;
END;
GO
