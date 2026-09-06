USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Source-faithful MDD / DELFI / TRIAS realtime staging.

    Realtime rows are append-only observations.  Delay and matching values are
    derived in wrk rather than persisted in this source-aligned layer.
*/
IF OBJECT_ID(N'stg.MddRealtimeStopObservation', N'U') IS NULL
BEGIN
    CREATE TABLE stg.MddRealtimeStopObservation
    (
        ObservationKey BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_stg_MddRealtimeStopObservation PRIMARY KEY,
        ObservedAtUtc DATETIME2(0) NOT NULL,
        ResultId NVARCHAR(100) NOT NULL,
        StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL,
        StopName NVARCHAR(200) NULL,
        LineName NVARCHAR(100) NULL,
        LineRef NVARCHAR(150) NULL,
        JourneyRef NVARCHAR(200) NOT NULL,
        DirectionRef NVARCHAR(50) NULL,
        OperatorRef NVARCHAR(100) NULL,
        PtMode NVARCHAR(50) NULL,
        RailSubmode NVARCHAR(100) NULL,
        TimetabledArrivalUtc DATETIME2(0) NULL,
        EstimatedArrivalUtc DATETIME2(0) NULL,
        CreatedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_stg_MddRealtimeStopObservation_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        PlannedBay NVARCHAR(100) NULL,
        EstimatedBay NVARCHAR(100) NULL
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'stg.MddRealtimeStopObservation')
      AND name = N'UX_stg_MddRealtimeStopObservation_ObservedAtUtc_ResultId'
)
BEGIN
    CREATE UNIQUE INDEX UX_stg_MddRealtimeStopObservation_ObservedAtUtc_ResultId
        ON stg.MddRealtimeStopObservation (ObservedAtUtc, ResultId);
END;
GO

IF OBJECT_ID(N'stg.MddRealtimeSituationObservation', N'U') IS NULL
BEGIN
    CREATE TABLE stg.MddRealtimeSituationObservation
    (
        SituationObservationKey BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_stg_MddRealtimeSituationObservation PRIMARY KEY,
        ObservedAtUtc DATETIME2(0) NOT NULL,
        ParticipantRef NVARCHAR(100) NOT NULL,
        SituationNumber NVARCHAR(150) NOT NULL,
        Summary NVARCHAR(1000) NULL,
        Description NVARCHAR(2000) NULL,
        Detail NVARCHAR(MAX) NULL,
        ValidFromUtc DATETIME2(0) NULL,
        ValidToUtc DATETIME2(0) NULL,
        CreatedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_stg_MddRealtimeSituationObservation_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID(N'stg.MddRealtimeStopSituationLink', N'U') IS NULL
BEGIN
    CREATE TABLE stg.MddRealtimeStopSituationLink
    (
        ObservationKey BIGINT NOT NULL,
        SituationObservationKey BIGINT NOT NULL,
        RelationScope NVARCHAR(20) NOT NULL,
        CreatedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_stg_MddRealtimeStopSituationLink_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_stg_MddRealtimeStopSituationLink
            PRIMARY KEY (ObservationKey, SituationObservationKey, RelationScope),
        CONSTRAINT FK_stg_MddRealtimeStopSituationLink_Observation
            FOREIGN KEY (ObservationKey)
            REFERENCES stg.MddRealtimeStopObservation (ObservationKey),
        CONSTRAINT FK_stg_MddRealtimeStopSituationLink_Situation
            FOREIGN KEY (SituationObservationKey)
            REFERENCES stg.MddRealtimeSituationObservation (SituationObservationKey),
        CONSTRAINT CK_stg_MddRealtimeStopSituationLink_RelationScope
            CHECK (RelationScope IN (N'CALL', N'SERVICE'))
    );
END;
GO
