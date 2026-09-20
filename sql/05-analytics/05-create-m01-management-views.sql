USE CologneTransitIntelligence;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

/*
    M01 management-layer views.

    These views sit on top of the trusted realtime analytical views so Power BI
    can use normal Sql.Database schema/table navigation.  The management grain
    is deliberately separate from the underlying stop-outcome grain:

      - vwManagementComparableTrip: one row per ServiceDate + TripKey
      - vwManagementTripStation: one row per ServiceDate + TripKey + StopKey
      - vwManagementMonitoredStation: one row per local date + panel target

    The Station value is the parent-station label for the trusted stop outcome.
    M02 station measures distinct-count ManagementTripKey within each Station
    context, so a trip is counted once per station even when it has multiple
    stop positions there.  The same dated trip may legitimately occur at more
    than one monitored station and is intentionally counted once in each such
    station context.

    Missing estimated timing remains a valid comparable row and is not treated
    as a cancellation.  When repeated source rows exist, the row with usable
    final estimated delay wins, followed by the latest observation, latest
    scheduled arrival, and the operational outcome key.
*/

CREATE OR ALTER VIEW analytics.vwManagementComparableTrip
AS
WITH RankedOutcome AS
(
    SELECT
        CONVERT(NVARCHAR(8), outcome.ServiceDate, 112)
            + N'|' + CONVERT(NVARCHAR(30), outcome.TripKey)
            AS ManagementTripKey,
        outcome.DateKey,
        outcome.ServiceDate,
        outcome.TripKey,
        outcome.RouteKey,
        outcome.ModeKey,
        outcome.Route,
        outcome.Mode,
        outcome.Station,
        outcome.StopKey,
        outcome.ScheduledArrival,
        outcome.LatestObservedEstimatedArrivalLocal,
        outcome.FinalObservedEstimatedDelayMinutes,
        outcome.LastObservedAtUtc,
        outcome.OperationalStopOutcomeKey,
        CONVERT
        (
            BIT,
            CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL
                 THEN 1 ELSE 0 END
        ) AS HasValidRealtimeObservation,
        ROW_NUMBER() OVER
        (
            PARTITION BY outcome.ServiceDate, outcome.TripKey
            ORDER BY
                CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL
                     THEN 0 ELSE 1 END,
                outcome.LastObservedAtUtc DESC,
                outcome.ScheduledArrival DESC,
                outcome.OperationalStopOutcomeKey DESC
        ) AS ManagementRowNumber
    FROM analytics.vwRealtimeReliabilityOutcome AS outcome
    WHERE outcome.OperationalStopOutcomeKey IS NOT NULL
)
SELECT
    ManagementTripKey,
    DateKey,
    ServiceDate,
    TripKey,
    RouteKey,
    ModeKey,
    Route,
    Mode,
    Station,
    StopKey,
    ScheduledArrival,
    LatestObservedEstimatedArrivalLocal,
    FinalObservedEstimatedDelayMinutes,
    LastObservedAtUtc,
    OperationalStopOutcomeKey,
    HasValidRealtimeObservation
FROM RankedOutcome
WHERE ManagementRowNumber = 1;
GO

CREATE OR ALTER VIEW analytics.vwManagementTripStation
AS
WITH RankedOutcome AS
(
    SELECT
        CONVERT(NVARCHAR(8), outcome.ServiceDate, 112)
            + N'|' + CONVERT(NVARCHAR(30), outcome.TripKey)
            AS ManagementTripKey,
        CONVERT(NVARCHAR(8), outcome.ServiceDate, 112)
            + N'|' + CONVERT(NVARCHAR(30), outcome.TripKey)
            + N'|' + CONVERT(NVARCHAR(30), outcome.StopKey)
            AS ManagementTripStationKey,
        outcome.DateKey,
        outcome.ServiceDate,
        outcome.TripKey,
        outcome.RouteKey,
        outcome.ModeKey,
        outcome.Route,
        outcome.Mode,
        outcome.Station,
        outcome.StopKey,
        outcome.ScheduledArrival,
        outcome.LatestObservedEstimatedArrivalLocal,
        outcome.FinalObservedEstimatedDelayMinutes,
        outcome.LastObservedAtUtc,
        outcome.OperationalStopOutcomeKey,
        CONVERT
        (
            BIT,
            CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL
                 THEN 1 ELSE 0 END
        ) AS HasValidRealtimeObservation,
        ROW_NUMBER() OVER
        (
            PARTITION BY outcome.ServiceDate, outcome.TripKey, outcome.StopKey
            ORDER BY
                CASE WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL
                     THEN 0 ELSE 1 END,
                outcome.LastObservedAtUtc DESC,
                outcome.ScheduledArrival DESC,
                outcome.OperationalStopOutcomeKey DESC
        ) AS ManagementRowNumber
    FROM analytics.vwRealtimeReliabilityOutcome AS outcome
    WHERE outcome.OperationalStopOutcomeKey IS NOT NULL
)
SELECT
    ManagementTripStationKey,
    ManagementTripKey,
    DateKey,
    ServiceDate,
    TripKey,
    RouteKey,
    ModeKey,
    Route,
    Mode,
    Station,
    StopKey,
    ScheduledArrival,
    LatestObservedEstimatedArrivalLocal,
    FinalObservedEstimatedDelayMinutes,
    LastObservedAtUtc,
    OperationalStopOutcomeKey,
    HasValidRealtimeObservation
FROM RankedOutcome
WHERE ManagementRowNumber = 1;
GO

CREATE OR ALTER VIEW analytics.vwManagementMonitoredStation
AS
WITH PanelTargetByDate AS
(
    SELECT
        CONVERT(INT, CONVERT(CHAR(8), health.CollectionDateLocal, 112))
            AS DateKey,
        health.CollectionDateLocal,
        health.SamplingTargetId,
        NULLIF(LTRIM(RTRIM(health.SamplingTargetName)), N'')
            AS SamplingTargetName,
        health.StopPointRef,
        CONVERT(BIT, health.ParticipatedInSamplingPanel)
            AS ParticipatedInSamplingPanel,
        ROW_NUMBER() OVER
        (
            PARTITION BY
                CONVERT(INT, CONVERT(CHAR(8), health.CollectionDateLocal, 112)),
                health.SamplingTargetId
            ORDER BY health.CollectionDateLocal DESC, health.CollectorRunId DESC
        ) AS ManagementRowNumber
    FROM analytics.vwRealtimeCollectorRunHealth AS health
    WHERE health.ParticipatedInSamplingPanel = 1
      AND health.SamplingTargetId IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(health.SamplingTargetName)), N'') IS NOT NULL
)
SELECT
    DateKey,
    CollectionDateLocal,
    SamplingTargetId,
    SamplingTargetName,
    StopPointRef,
    ParticipatedInSamplingPanel,
    SamplingTargetId AS MonitoredStationKey,
    SamplingTargetName AS MonitoredStationName,
    SamplingTargetName AS StaticParentStationName
FROM PanelTargetByDate
WHERE ManagementRowNumber = 1;
GO
