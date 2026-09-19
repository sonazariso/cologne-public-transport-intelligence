USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/* Read-only checks for the M01 management cohort. */
SELECT
    OBJECT_SCHEMA_NAME(object_id) AS ViewSchema,
    OBJECT_NAME(object_id) AS ViewName,
    create_date,
    modify_date
FROM sys.views
WHERE object_id IN
(
    OBJECT_ID(N'analytics.vwManagementMonitoredStation'),
    OBJECT_ID(N'analytics.vwManagementComparableTrip')
);

SELECT
    COUNT_BIG(*) AS ManagementRows,
    COUNT_BIG(DISTINCT ManagementTripKey) AS DistinctTripKeys,
    COUNT_BIG(DISTINCT CASE WHEN IsTripLevelRecord = 1 THEN ManagementTripKey END)
        AS CanonicalTripKeys,
    MIN(RealtimeDataStartDate) AS RealtimeDataStartDate,
    MAX(RealtimeDataEndDate) AS RealtimeDataEndDate,
    COUNT_BIG(DISTINCT ModeKey) AS ModeCount,
    COUNT_BIG(DISTINCT MonitoredStationKey) AS MonitoredStationCount
FROM analytics.vwManagementComparableTrip;

/* No trip may have more than one canonical overall row. */
SELECT
    ManagementTripKey,
    COUNT_BIG(*) AS CanonicalRows
FROM analytics.vwManagementComparableTrip
WHERE IsTripLevelRecord = 1
GROUP BY ManagementTripKey
HAVING COUNT_BIG(*) <> 1;

/* The three punctuality buckets must reconcile to valid observed trips at 0 minutes. */
SELECT
    COUNT_BIG(DISTINCT CASE
        WHEN IsTripLevelRecord = 1
         AND HasValidRealtimeObservation = 1
         AND ScheduleDifferenceMinutes >= 0
         AND ScheduleDifferenceMinutes <= 0
        THEN ManagementTripKey END) AS OnTimeTrips,
    COUNT_BIG(DISTINCT CASE
        WHEN IsTripLevelRecord = 1
         AND HasValidRealtimeObservation = 1
         AND ScheduleDifferenceMinutes > 0
        THEN ManagementTripKey END) AS DelayedTrips,
    COUNT_BIG(DISTINCT CASE
        WHEN IsTripLevelRecord = 1
         AND HasValidRealtimeObservation = 1
         AND ScheduleDifferenceMinutes < 0
        THEN ManagementTripKey END) AS EarlyTrips,
    COUNT_BIG(DISTINCT CASE
        WHEN IsTripLevelRecord = 1
         AND HasValidRealtimeObservation = 1
        THEN ManagementTripKey END) AS ObservedMatchedTrips
FROM analytics.vwManagementComparableTrip;

SELECT
    SamplingTargetId,
    StopPointRef,
    MonitoredStationName,
    MonitoredStationKey,
    StaticParentStationName,
    IsEnabled
FROM analytics.vwManagementMonitoredStation
ORDER BY MonitoredStationName;
