USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Management-page scope helpers.

    The realtime collector is configured against parent-station StopPointRefs.
    This view keeps that monitored scope explicit and separate from the full
    static parent-station dimension.
*/
CREATE OR ALTER VIEW analytics.vwManagementMonitoredStation
AS
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName AS MonitoredStationName,
    CASE
        WHEN target_stop.LocationTypeCode = 1 THEN target_stop.StopKey
        ELSE target_stop.ParentStopKey
    END AS MonitoredStationKey,
    COALESCE(parent_stop.StopId, target_stop.StopId) AS StaticParentStationId,
    COALESCE(parent_stop.StopName, target_stop.StopName, sampling_target.TargetName)
        AS StaticParentStationName,
    sampling_target.NumberOfResults,
    sampling_target.IsEnabled,
    sampling_target.Notes
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN dw.DimStop AS target_stop
    ON target_stop.StopId COLLATE Latin1_General_100_BIN2
     = sampling_target.StopPointRef COLLATE Latin1_General_100_BIN2
LEFT JOIN dw.DimStop AS parent_stop
    ON parent_stop.StopKey =
       CASE
           WHEN target_stop.LocationTypeCode = 1 THEN target_stop.StopKey
           ELSE target_stop.ParentStopKey
       END
WHERE sampling_target.IsEnabled = 1;
GO

/*
    One row per scheduled trip and enabled monitored station.

    The management comparison cohort is deliberately narrower than the full
    static schedule: it uses the local observation date window, the current
    authoritative mode dimension, and only stop events at enabled realtime
    monitoring targets.  A trip can have more than one relevant stop event at
    a station; the preferred event is selected deterministically, giving
    observed evidence precedence over an unmatched scheduled event.

    Repeated observations are already consolidated in
    dw.FactOperationalStopOutcome.  The canonical trip flag lets overall
    management counts use one row per (ServiceDate, TripKey), while the
    station rows remain available for station-level comparisons.
*/
CREATE OR ALTER VIEW analytics.vwManagementComparableTrip
AS
WITH RealtimeWindow AS
(
    SELECT
        CONVERT
        (
            DATE,
            MIN
            (
                observation.ObservedAtUtc AT TIME ZONE 'UTC'
                    AT TIME ZONE 'W. Europe Standard Time'
            )
        ) AS RealtimeDataStartDate,
        CONVERT
        (
            DATE,
            MAX
            (
                observation.ObservedAtUtc AT TIME ZONE 'UTC'
                    AT TIME ZONE 'W. Europe Standard Time'
            )
        ) AS RealtimeDataEndDate
    FROM stg.MddRealtimeStopObservation AS observation
),
EnabledTargets AS
(
    SELECT
        monitored_station.SamplingTargetId,
        monitored_station.StopPointRef,
        monitored_station.MonitoredStationName,
        monitored_station.MonitoredStationKey,
        monitored_station.StaticParentStationName
    FROM analytics.vwManagementMonitoredStation AS monitored_station
    WHERE monitored_station.MonitoredStationKey IS NOT NULL
),
ComparableStopEvents AS
(
    SELECT
        date_dimension.DateKey,
        date_dimension.DateValue AS ServiceDate,
        trip.TripKey,
        trip.TripId,
        trip.RouteKey,
        route.RouteId,
        route.RouteShortName AS Route,
        route.RouteLongName,
        trip.ModeKey,
        mode.ModeGroup,
        mode.ModeDetail,
        trip.ServiceKey,
        trip.TripHeadsign,
        target.SamplingTargetId,
        target.StopPointRef,
        target.MonitoredStationKey,
        target.MonitoredStationName,
        target.StaticParentStationName,
        stop_event.ScheduledStopEventKey,
        stop.StopName AS ScheduledStop,
        DATEADD
        (
            SECOND,
            stop_event.ScheduledArrivalSeconds,
            CONVERT(DATETIME2(0), date_dimension.DateValue)
        ) AS ScheduledArrival,
        DATEADD
        (
            SECOND,
            stop_event.ScheduledDepartureSeconds,
            CONVERT(DATETIME2(0), date_dimension.DateValue)
        ) AS ScheduledDeparture,
        outcome.OperationalStopOutcomeKey,
        outcome.MatchStatus,
        outcome.FirstObservedAtUtc,
        outcome.LastObservedAtUtc,
        outcome.ObservationCount,
        outcome.FirstEstimatedArrivalUtc,
        outcome.LatestObservedEstimatedArrivalUtc,
        outcome.FinalObservedEstimatedDelayMinutes AS ScheduleDifferenceMinutes,
        CAST
        (
            CASE
                WHEN outcome.OperationalStopOutcomeKey IS NOT NULL THEN 1
                ELSE 0
            END
            AS BIT
        ) AS HasMatchedRealtimeOutcome,
        CAST
        (
            CASE
                WHEN outcome.FinalObservedEstimatedDelayMinutes IS NOT NULL THEN 1
                ELSE 0
            END
            AS BIT
        ) AS HasValidRealtimeObservation
    FROM dw.BridgeServiceDate AS service_date
    INNER JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = service_date.DateKey
    INNER JOIN dw.FactScheduledTrip AS trip
        ON trip.ServiceKey = service_date.ServiceKey
    INNER JOIN dw.DimRoute AS route
        ON route.RouteKey = trip.RouteKey
    INNER JOIN dw.DimMode AS mode
        ON mode.ModeKey = trip.ModeKey
    INNER JOIN dw.FactScheduledStopEvent AS stop_event
        ON stop_event.TripKey = trip.TripKey
       AND stop_event.ServiceKey = trip.ServiceKey
    INNER JOIN dw.DimStop AS stop
        ON stop.StopKey = stop_event.StopKey
    INNER JOIN EnabledTargets AS target
        ON stop.StopKey = target.MonitoredStationKey
        OR stop.ParentStopKey = target.MonitoredStationKey
    LEFT JOIN dw.FactOperationalStopOutcome AS outcome
        ON outcome.DateKey = service_date.DateKey
       AND outcome.ScheduledStopEventKey = stop_event.ScheduledStopEventKey
    CROSS JOIN RealtimeWindow AS realtime_window
    WHERE realtime_window.RealtimeDataStartDate IS NOT NULL
      AND date_dimension.DateValue BETWEEN realtime_window.RealtimeDataStartDate
                                       AND realtime_window.RealtimeDataEndDate
),
StationEventCandidates AS
(
    SELECT
        comparable.*,
        MAX
        (
            CASE
                WHEN comparable.HasMatchedRealtimeOutcome = 1 THEN 1
                ELSE 0
            END
        ) OVER
        (
            PARTITION BY
                comparable.DateKey,
                comparable.TripKey,
                comparable.SamplingTargetId
        ) AS HasMatchedRealtimeOutcomeAtStationInt,
        MAX
        (
            CASE
                WHEN comparable.HasValidRealtimeObservation = 1 THEN 1
                ELSE 0
            END
        ) OVER
        (
            PARTITION BY
                comparable.DateKey,
                comparable.TripKey,
                comparable.SamplingTargetId
        ) AS HasValidRealtimeObservationAtStationInt,
        ROW_NUMBER() OVER
        (
            PARTITION BY
                comparable.DateKey,
                comparable.TripKey,
                comparable.SamplingTargetId
            ORDER BY
                CASE WHEN comparable.HasValidRealtimeObservation = 1 THEN 0 ELSE 1 END,
                CASE WHEN comparable.HasMatchedRealtimeOutcome = 1 THEN 0 ELSE 1 END,
                comparable.LastObservedAtUtc DESC,
                comparable.ScheduledArrival DESC,
                comparable.ScheduledStopEventKey DESC
        ) AS StationEventRank
    FROM ComparableStopEvents AS comparable
),
PreferredStationRows AS
(
    SELECT
        station_event.*,
        CAST
        (
            CASE
                WHEN station_event.HasMatchedRealtimeOutcomeAtStationInt = 1 THEN 1
                ELSE 0
            END
            AS BIT
        ) AS HasMatchedRealtimeOutcomeAtStation,
        CAST
        (
            CASE
                WHEN station_event.HasValidRealtimeObservationAtStationInt = 1 THEN 1
                ELSE 0
            END
            AS BIT
        ) AS HasValidRealtimeObservationAtStation
    FROM StationEventCandidates AS station_event
    WHERE station_event.StationEventRank = 1
),
TripRows AS
(
    SELECT
        preferred_station.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY preferred_station.DateKey, preferred_station.TripKey
            ORDER BY
                CASE WHEN preferred_station.HasValidRealtimeObservation = 1 THEN 0 ELSE 1 END,
                CASE WHEN preferred_station.HasMatchedRealtimeOutcome = 1 THEN 0 ELSE 1 END,
                preferred_station.LastObservedAtUtc DESC,
                preferred_station.ScheduledArrival DESC,
                preferred_station.MonitoredStationName,
                preferred_station.SamplingTargetId
        ) AS TripRowRank
    FROM PreferredStationRows AS preferred_station
)
SELECT
    CONCAT
    (
        CONVERT(NVARCHAR(8), trip_row.ServiceDate, 112),
        N'|',
        CONVERT(NVARCHAR(30), trip_row.TripKey)
    ) AS ManagementTripKey,
    trip_row.DateKey,
    trip_row.ServiceDate,
    trip_row.TripKey,
    trip_row.TripId,
    trip_row.RouteKey,
    trip_row.RouteId,
    trip_row.Route,
    trip_row.RouteLongName,
    trip_row.ModeKey,
    trip_row.ModeGroup,
    trip_row.ModeDetail,
    trip_row.ServiceKey,
    trip_row.TripHeadsign,
    trip_row.SamplingTargetId,
    trip_row.StopPointRef,
    trip_row.MonitoredStationKey,
    trip_row.MonitoredStationName,
    trip_row.StaticParentStationName,
    trip_row.ScheduledStopEventKey,
    trip_row.ScheduledStop,
    trip_row.ScheduledArrival,
    trip_row.ScheduledDeparture,
    CONVERT
    (
        DATETIME2(0),
        trip_row.FirstEstimatedArrivalUtc AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
    ) AS FirstObservedEstimatedArrival,
    CONVERT
    (
        DATETIME2(0),
        trip_row.LatestObservedEstimatedArrivalUtc AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
    ) AS ObservedEstimatedArrival,
    trip_row.FirstObservedAtUtc,
    trip_row.LastObservedAtUtc,
    trip_row.ObservationCount,
    trip_row.MatchStatus,
    trip_row.ScheduleDifferenceMinutes,
    trip_row.HasMatchedRealtimeOutcome,
    trip_row.HasValidRealtimeObservation,
    trip_row.HasMatchedRealtimeOutcomeAtStation,
    trip_row.HasValidRealtimeObservationAtStation,
    CAST(CASE WHEN trip_row.TripRowRank = 1 THEN 1 ELSE 0 END AS BIT)
        AS IsTripLevelRecord,
    realtime_window.RealtimeDataStartDate,
    realtime_window.RealtimeDataEndDate,
    CASE
        WHEN realtime_window.RealtimeDataStartDate IS NULL
          OR realtime_window.RealtimeDataEndDate IS NULL
        THEN NULL
        ELSE DATEDIFF
        (
            DAY,
            realtime_window.RealtimeDataStartDate,
            realtime_window.RealtimeDataEndDate
        ) + 1
    END AS RealtimeCoveredDays,
    CAST(0 AS BIT) AS CoverageDenominatorDefensible,
    N'Distinct ServiceDate + TripKey scheduled at an enabled realtime monitored station during the realtime source observation date window.'
        AS CohortDefinition,
    N'Distinct ServiceDate + TripKey with a matched realtime outcome and a nonblank estimated arrival/difference in that same cohort.'
        AS ObservedMatchDefinition,
    N'Collector run history records target sampling but does not prove run-by-run eligibility for every scheduled trip; an observation coverage percentage is therefore not reported.'
        AS CoverageLimitation
FROM TripRows AS trip_row
CROSS JOIN RealtimeWindow AS realtime_window;
GO
