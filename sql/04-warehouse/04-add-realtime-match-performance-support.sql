USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Preserve GTFS service-day offsets while exposing a seekable local
    seconds-of-day value for the existing realtime matching path.
*/
IF COL_LENGTH(N'dw.FactScheduledStopEvent', N'ScheduledArrivalSecondOfDay') IS NULL
BEGIN
    ALTER TABLE dw.FactScheduledStopEvent
        ADD ScheduledArrivalSecondOfDay AS
        (
            ScheduledArrivalSeconds - (ArrivalDayOffset * 86400)
        ) PERSISTED;
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dw.FactScheduledStopEvent')
      AND name = N'IX_FactScheduledStopEvent_RealtimeMatch'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_FactScheduledStopEvent_RealtimeMatch
        ON dw.FactScheduledStopEvent
        (
            RouteKey,
            ScheduledArrivalSecondOfDay
        )
        INCLUDE
        (
            ArrivalDayOffset,
            ServiceKey,
            StopKey,
            TripKey
        );
END;
GO
