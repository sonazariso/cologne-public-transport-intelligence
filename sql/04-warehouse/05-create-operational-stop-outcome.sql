USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    One row per matched scheduled stop event on one GTFS service date.

    This is an operational observation outcome, not a confirmed physical
    arrival fact.  MDD/TRIAS currently supplies estimated arrival times only;
    the fields below deliberately use "ObservedEstimated" terminology and do
    not claim ActualArrival or ActualDelay.

    Repeated source observations for the same dated scheduled stop event are
    consolidated by dw.uspRefreshFactOperationalStopOutcome.  The unique
    (DateKey, ScheduledStopEventKey) constraint enforces that grain.
*/
IF OBJECT_ID(N'dw.FactOperationalStopOutcome', N'U') IS NULL
BEGIN
    CREATE TABLE dw.FactOperationalStopOutcome
    (
        OperationalStopOutcomeKey BIGINT IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_dw_FactOperationalStopOutcome PRIMARY KEY,

        DateKey INT NOT NULL,
        ServiceDate DATE NOT NULL,

        ScheduledStopEventKey BIGINT NOT NULL,
        TripKey BIGINT NOT NULL,
        RouteKey INT NOT NULL,
        StopKey INT NOT NULL,
        ModeKey SMALLINT NOT NULL,
        ServiceKey INT NOT NULL,

        MatchStatus NVARCHAR(30) NOT NULL,

        FirstObservationKey BIGINT NOT NULL,
        LastObservationKey BIGINT NOT NULL,
        FirstObservedAtUtc DATETIME2(0) NOT NULL,
        LastObservedAtUtc DATETIME2(0) NOT NULL,
        ObservationCount BIGINT NOT NULL,

        TimetabledArrivalUtc DATETIME2(0) NOT NULL,
        FirstEstimatedArrivalUtc DATETIME2(0) NULL,
        LatestObservedEstimatedArrivalUtc DATETIME2(0) NULL,
        FirstObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
        FinalObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,

        PlannedBay NVARCHAR(100) NULL,
        LatestObservedEstimatedBay NVARCHAR(100) NULL,
        PlatformChangeEvidence VARCHAR(20) NOT NULL,

        HasSituationEvidence BIT NOT NULL,
        SituationLinkCount BIGINT NOT NULL,

        RefreshedAtUtc DATETIME2(0) NOT NULL
            CONSTRAINT DF_dw_FactOperationalStopOutcome_RefreshedAtUtc
            DEFAULT SYSUTCDATETIME(),

        CONSTRAINT CK_dw_FactOperationalStopOutcome_MatchStatus
            CHECK (MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')),
        CONSTRAINT CK_dw_FactOperationalStopOutcome_ObservationCount
            CHECK (ObservationCount > 0),
        CONSTRAINT CK_dw_FactOperationalStopOutcome_ObservedAtOrder
            CHECK (FirstObservedAtUtc <= LastObservedAtUtc),
        CONSTRAINT CK_dw_FactOperationalStopOutcome_SituationLinkCount
            CHECK (SituationLinkCount >= 0),
        CONSTRAINT CK_dw_FactOperationalStopOutcome_HasSituationEvidence
            CHECK
            (
                (HasSituationEvidence = 0 AND SituationLinkCount = 0)
                OR (HasSituationEvidence = 1 AND SituationLinkCount > 0)
            ),
        CONSTRAINT CK_dw_FactOperationalStopOutcome_PlatformEvidence
            CHECK (PlatformChangeEvidence IN ('Changed', 'Unchanged', 'Unknown')),

        CONSTRAINT FK_dw_FactOperationalStopOutcome_Date
            FOREIGN KEY (DateKey) REFERENCES dw.DimDate (DateKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_ScheduledStopEvent
            FOREIGN KEY (ScheduledStopEventKey)
            REFERENCES dw.FactScheduledStopEvent (ScheduledStopEventKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_Trip
            FOREIGN KEY (TripKey) REFERENCES dw.FactScheduledTrip (TripKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_Route
            FOREIGN KEY (RouteKey) REFERENCES dw.DimRoute (RouteKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_Stop
            FOREIGN KEY (StopKey) REFERENCES dw.DimStop (StopKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_Mode
            FOREIGN KEY (ModeKey) REFERENCES dw.DimMode (ModeKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_Service
            FOREIGN KEY (ServiceKey) REFERENCES dw.DimService (ServiceKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_FirstObservation
            FOREIGN KEY (FirstObservationKey)
            REFERENCES stg.MddRealtimeStopObservation (ObservationKey),
        CONSTRAINT FK_dw_FactOperationalStopOutcome_LastObservation
            FOREIGN KEY (LastObservationKey)
            REFERENCES stg.MddRealtimeStopObservation (ObservationKey)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'UX_dw_FactOperationalStopOutcome_Date_StopEvent'
)
BEGIN
    CREATE UNIQUE INDEX UX_dw_FactOperationalStopOutcome_Date_StopEvent
        ON dw.FactOperationalStopOutcome (DateKey, ScheduledStopEventKey);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_Date'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_Date
        ON dw.FactOperationalStopOutcome (DateKey, ServiceDate)
        INCLUDE
        (
            RouteKey,
            StopKey,
            ModeKey,
            MatchStatus,
            FinalObservedEstimatedDelayMinutes,
            ObservationCount,
            PlatformChangeEvidence,
            HasSituationEvidence
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_Route'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_Route
        ON dw.FactOperationalStopOutcome (RouteKey, ServiceDate)
        INCLUDE
        (
            DateKey,
            StopKey,
            ModeKey,
            FinalObservedEstimatedDelayMinutes,
            ObservationCount,
            PlatformChangeEvidence,
            HasSituationEvidence
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_Stop'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_Stop
        ON dw.FactOperationalStopOutcome (StopKey, ServiceDate)
        INCLUDE
        (
            DateKey,
            RouteKey,
            ModeKey,
            FinalObservedEstimatedDelayMinutes,
            ObservationCount,
            PlatformChangeEvidence,
            HasSituationEvidence
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_Mode'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_Mode
        ON dw.FactOperationalStopOutcome (ModeKey, ServiceDate)
        INCLUDE
        (
            DateKey,
            RouteKey,
            StopKey,
            FinalObservedEstimatedDelayMinutes,
            ObservationCount,
            PlatformChangeEvidence,
            HasSituationEvidence
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_MatchStatus'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_MatchStatus
        ON dw.FactOperationalStopOutcome (MatchStatus, ServiceDate)
        INCLUDE
        (
            DateKey,
            RouteKey,
            StopKey,
            ModeKey,
            FinalObservedEstimatedDelayMinutes,
            ObservationCount
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactOperationalStopOutcome')
      AND name = N'IX_dw_FactOperationalStopOutcome_ScheduledStopEvent'
)
BEGIN
    CREATE INDEX IX_dw_FactOperationalStopOutcome_ScheduledStopEvent
        ON dw.FactOperationalStopOutcome
        (
            ScheduledStopEventKey,
            DateKey
        )
        INCLUDE
        (
            ServiceDate,
            TripKey,
            RouteKey,
            StopKey,
            ModeKey,
            ServiceKey,
            ObservationCount,
            LastObservationKey
        );
END;
GO
