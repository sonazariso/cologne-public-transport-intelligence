/*
Cologne Public Transport Intelligence
Power BI Chat 04 — SQL-side validation queries
Validated against the 2026-09-14 project state.

Purpose:
- compare imported Power BI model counts/KPIs with SQL analytics views;
- check realtime freshness independently from Power BI refresh state;
- validate the SQL side of relationship/filter-propagation tests.

These queries are read-only except for the explicitly marked optional warehouse
refresh procedure call. Do not run the refresh merely to force parity; first
check freshness and only run the existing idempotent procedure when the derived
operational fact is genuinely behind the preserved realtime source history.
*/

/* 1. Static import cardinality */
SELECT 'NetworkKPI' AS TableName, COUNT_BIG(*) AS SqlRowCount
FROM analytics.vwNetworkBaselineKpi
UNION ALL SELECT 'Mode', COUNT_BIG(*) FROM analytics.vwModeScheduleProfile
UNION ALL SELECT 'Route', COUNT_BIG(*) FROM analytics.vwRouteScheduleProfile
UNION ALL SELECT 'StopPosition', COUNT_BIG(*) FROM analytics.vwStopPositionScheduleProfile
UNION ALL SELECT 'ParentStation', COUNT_BIG(*) FROM analytics.vwParentStationScheduleProfile
UNION ALL SELECT 'ActiveDate', COUNT_BIG(*) FROM analytics.vwActiveDateProfile
UNION ALL SELECT 'DailySchedule', COUNT_BIG(*) FROM analytics.vwDailyScheduledTripProfile
UNION ALL SELECT 'ScheduledTripProfile', COUNT_BIG(*) FROM analytics.vwScheduledTripProfile
ORDER BY TableName;

/* 2. Static baseline KPI reconciliation */
SELECT
    AgencyCount,
    ModeCount,
    RouteCount,
    ParentStationCount,
    StopPositionCount,
    UsedStopPositionCount,
    ServicePatternCount,
    ActiveServiceDateCount,
    ScheduledTripPatternCount,
    ScheduledTripOccurrenceCount,
    ScheduledStopEventPatternCount
FROM analytics.vwNetworkBaselineKpi;

/* 3. Realtime freshness — collection vs derived warehouse fact */
SELECT
    SYSUTCDATETIME() AS CheckedAtUtc,
    (SELECT MAX(StartedAtUtc) FROM ctl.MddCollectorRun) AS LatestCollectorRunStartedUtc,
    (SELECT MAX(CompletedAtUtc) FROM ctl.MddCollectorRun WHERE Status = 'Succeeded') AS LatestSuccessfulCollectorRunUtc,
    (SELECT MAX(ObservedAtUtc) FROM stg.MddRealtimeStopObservation) AS LatestRawObservationUtc,
    (SELECT MAX(LastObservedAtUtc) FROM dw.FactOperationalStopOutcome) AS LatestOperationalObservationUtc,
    (SELECT MAX(RefreshedAtUtc) FROM dw.FactOperationalStopOutcome) AS LatestOperationalFactRefreshUtc;

/*
Optional only when freshness proves the derived operational fact is behind:

EXEC dw.uspRefreshFactOperationalStopOutcome;
*/

/* 4. Realtime reliability fact import parity */
SELECT
    COUNT_BIG(*) AS SqlOutcomeCount,
    MAX(RefreshedAtUtc) AS SqlMaxRefreshedAtUtc,
    MIN(ServiceDate) AS SqlMinServiceDate,
    MAX(ServiceDate) AS SqlMaxServiceDate
FROM analytics.vwRealtimeReliabilityOutcome;

/* 5. ActiveDate -> RT_ReliabilityOutcome */
SELECT
    ServiceDate,
    COUNT_BIG(*) AS SqlOutcomeCount
FROM analytics.vwRealtimeReliabilityOutcome
GROUP BY ServiceDate
ORDER BY ServiceDate;

/* 6. Route -> RT_ReliabilityOutcome */
SELECT
    RouteKey,
    Route AS RouteShortName,
    COUNT_BIG(*) AS SqlOutcomeCount
FROM analytics.vwRealtimeReliabilityOutcome
GROUP BY RouteKey, Route
ORDER BY RouteKey;

/* 7. StopPosition -> RT_ReliabilityOutcome */
SELECT
    StopKey,
    Stop AS StopName,
    COUNT_BIG(*) AS SqlOutcomeCount
FROM analytics.vwRealtimeReliabilityOutcome
GROUP BY StopKey, Stop
ORDER BY StopKey;

/* 8. ParentStation -> StopPosition -> RT_ReliabilityOutcome */
SELECT
    sp.ParentStopKey AS ParentStationKey,
    ps.ParentStationName,
    COUNT_BIG(*) AS SqlOutcomeCount
FROM analytics.vwRealtimeReliabilityOutcome AS rt
JOIN analytics.vwStopPositionScheduleProfile AS sp
    ON sp.StopKey = rt.StopKey
JOIN analytics.vwParentStationScheduleProfile AS ps
    ON ps.ParentStationKey = sp.ParentStopKey
GROUP BY sp.ParentStopKey, ps.ParentStationName
ORDER BY sp.ParentStopKey;

/* 9. Mode -> Route -> RT_ReliabilityOutcome */
SELECT
    r.ModeKey,
    m.ModeGroup,
    COUNT_BIG(*) AS SqlOutcomeCount
FROM analytics.vwRealtimeReliabilityOutcome AS rt
JOIN analytics.vwRouteScheduleProfile AS r
    ON r.RouteKey = rt.RouteKey
JOIN analytics.vwModeScheduleProfile AS m
    ON m.ModeKey = r.ModeKey
GROUP BY r.ModeKey, m.ModeGroup
ORDER BY r.ModeKey;

/* 10. ActiveDate -> RT_ConsolidationQuality */
SELECT
    ServiceDate,
    UsableObservationCount,
    OperationalOutcomeCount,
    RepeatedObservationsConsolidated
FROM analytics.vwRealtimeOperationalConsolidationQuality
ORDER BY ServiceDate;

/* 11. ActiveDate -> DailySchedule */
SELECT
    DateValue,
    SUM(ScheduledTripCount) AS SqlScheduledTripCount
FROM analytics.vwDailyScheduledTripProfile
GROUP BY DateValue
ORDER BY DateValue;
