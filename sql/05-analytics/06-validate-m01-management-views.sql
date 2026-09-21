USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/* Read-only validation for the deployed M01 management analytical layer. */

SELECT
    view_check.ViewName,
    view_check.ExistsFlag,
    view_check.TotalRows,
    CASE WHEN view_check.ExistsFlag = 1 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT
        N'analytics.vwManagementComparableTrip' AS ViewName,
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwManagementComparableTrip', N'V') IS NULL
            THEN 0 ELSE 1 END) AS ExistsFlag,
        (SELECT COUNT_BIG(*)
         FROM analytics.vwManagementComparableTrip) AS TotalRows

    UNION ALL
    SELECT
        N'analytics.vwManagementTripStation',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwManagementTripStation', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwManagementTripStation)

    UNION ALL
    SELECT
        N'analytics.vwManagementMonitoredStation',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwManagementMonitoredStation', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwManagementMonitoredStation)
) AS view_check
ORDER BY view_check.ViewName;

SELECT TOP (10) *
FROM analytics.vwManagementComparableTrip;

SELECT TOP (10) *
FROM analytics.vwManagementTripStation;

SELECT TOP (10) *
FROM analytics.vwManagementMonitoredStation;

SELECT
    N'ComparableTrip grain duplicates' AS CheckName,
    COUNT_BIG(*) AS DuplicateGroupCount,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT ServiceDate, TripKey
    FROM analytics.vwManagementComparableTrip
    GROUP BY ServiceDate, TripKey
    HAVING COUNT_BIG(*) > 1
) AS duplicate_grain;

SELECT
    N'TripStation grain duplicates' AS CheckName,
    COUNT_BIG(*) AS DuplicateGroupCount,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT ServiceDate, TripKey, StopKey
    FROM analytics.vwManagementTripStation
    GROUP BY ServiceDate, TripKey, StopKey
    HAVING COUNT_BIG(*) > 1
) AS duplicate_grain;

/* Informational station-grain checks for M02.  Multiple stop positions for
   one dated trip within a station are allowed because the source view is at
   ServiceDate + TripKey + StopKey grain.  A dated trip appearing at more than
   one station is also expected and must not be collapsed system-wide. */

SELECT
    N'TripStation rows with multiple stop positions in one station' AS CheckName,
    COUNT_BIG(*) AS GroupCount,
    N'INFO - expected at stop-position grain; station measures distinct-count the trip'
        AS CheckStatus
FROM
(
    SELECT ServiceDate, TripKey, Station
    FROM analytics.vwManagementTripStation
    GROUP BY ServiceDate, TripKey, Station
    HAVING COUNT_BIG(DISTINCT StopKey) > 1
) AS station_stop_grain;

SELECT
    N'Dated trips observed at multiple stations' AS CheckName,
    COUNT_BIG(*) AS GroupCount,
    N'INFO - expected; do not use as a system-wide duplicate defect'
        AS CheckStatus
FROM
(
    SELECT ServiceDate, TripKey
    FROM analytics.vwManagementTripStation
    GROUP BY ServiceDate, TripKey
    HAVING COUNT_BIG(DISTINCT Station) > 1
) AS cross_station_trip;

DECLARE @ExpectedColumns TABLE
(
    ViewName SYSNAME NOT NULL,
    ColumnName SYSNAME NOT NULL
);

INSERT INTO @ExpectedColumns (ViewName, ColumnName)
VALUES
    (N'vwManagementComparableTrip', N'ManagementTripKey'),
    (N'vwManagementComparableTrip', N'DateKey'),
    (N'vwManagementComparableTrip', N'ServiceDate'),
    (N'vwManagementComparableTrip', N'TripKey'),
    (N'vwManagementComparableTrip', N'RouteKey'),
    (N'vwManagementComparableTrip', N'ModeKey'),
    (N'vwManagementComparableTrip', N'RouteName'),
    (N'vwManagementComparableTrip', N'Route'),
    (N'vwManagementComparableTrip', N'Mode'),
    (N'vwManagementComparableTrip', N'Station'),
    (N'vwManagementComparableTrip', N'StopKey'),
    (N'vwManagementComparableTrip', N'ScheduledArrival'),
    (N'vwManagementComparableTrip', N'LatestObservedEstimatedArrivalLocal'),
    (N'vwManagementComparableTrip', N'FinalObservedEstimatedDelayMinutes'),
    (N'vwManagementComparableTrip', N'LastObservedAtUtc'),
    (N'vwManagementComparableTrip', N'OperationalStopOutcomeKey'),
    (N'vwManagementComparableTrip', N'HasValidRealtimeObservation'),
    (N'vwManagementTripStation', N'ManagementTripStationKey'),
    (N'vwManagementTripStation', N'ManagementTripKey'),
    (N'vwManagementTripStation', N'DateKey'),
    (N'vwManagementTripStation', N'ServiceDate'),
    (N'vwManagementTripStation', N'TripKey'),
    (N'vwManagementTripStation', N'RouteKey'),
    (N'vwManagementTripStation', N'ModeKey'),
    (N'vwManagementTripStation', N'RouteName'),
    (N'vwManagementTripStation', N'Route'),
    (N'vwManagementTripStation', N'Mode'),
    (N'vwManagementTripStation', N'Station'),
    (N'vwManagementTripStation', N'StopKey'),
    (N'vwManagementTripStation', N'ScheduledArrival'),
    (N'vwManagementTripStation', N'LatestObservedEstimatedArrivalLocal'),
    (N'vwManagementTripStation', N'FinalObservedEstimatedDelayMinutes'),
    (N'vwManagementTripStation', N'LastObservedAtUtc'),
    (N'vwManagementTripStation', N'OperationalStopOutcomeKey'),
    (N'vwManagementTripStation', N'HasValidRealtimeObservation'),
    (N'vwManagementMonitoredStation', N'DateKey'),
    (N'vwManagementMonitoredStation', N'CollectionDateLocal'),
    (N'vwManagementMonitoredStation', N'SamplingTargetId'),
    (N'vwManagementMonitoredStation', N'SamplingTargetName'),
    (N'vwManagementMonitoredStation', N'StopPointRef'),
    (N'vwManagementMonitoredStation', N'ParticipatedInSamplingPanel'),
    (N'vwManagementMonitoredStation', N'MonitoredStationKey'),
    (N'vwManagementMonitoredStation', N'MonitoredStationName'),
    (N'vwManagementMonitoredStation', N'StaticParentStationName');

SELECT
    expected.ViewName,
    expected.ColumnName,
    N'MISSING' AS CheckStatus
FROM @ExpectedColumns AS expected
LEFT JOIN sys.columns AS actual
    ON actual.object_id = OBJECT_ID(N'analytics.' + expected.ViewName)
   AND actual.name = expected.ColumnName
WHERE actual.column_id IS NULL
ORDER BY expected.ViewName, expected.ColumnName;
GO
