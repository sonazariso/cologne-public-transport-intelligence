USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;

/* 1. Reconcile the cardinality of every reporting view. */
SELECT
    metric.MetricName,
    metric.ExpectedValue,
    metric.ActualValue,
    metric.ActualValue - metric.ExpectedValue AS Difference,
    CASE WHEN metric.ActualValue = metric.ExpectedValue THEN 'MATCH' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT N'Network KPI rows' AS MetricName, CONVERT(BIGINT, 1) AS ExpectedValue,
           (SELECT COUNT_BIG(*) FROM analytics.vwNetworkBaselineKpi) AS ActualValue
    UNION ALL
    SELECT N'Active-date profile rows', 182,
           (SELECT COUNT_BIG(*) FROM analytics.vwActiveDateProfile)
    UNION ALL
    SELECT N'Mode profile rows', 7,
           (SELECT COUNT_BIG(*) FROM analytics.vwModeScheduleProfile)
    UNION ALL
    SELECT N'Route profile rows', 153,
           (SELECT COUNT_BIG(*) FROM analytics.vwRouteScheduleProfile)
    UNION ALL
    SELECT N'Stop-position profile rows', 2290,
           (SELECT COUNT_BIG(*) FROM analytics.vwStopPositionScheduleProfile)
    UNION ALL
    SELECT N'Parent-station profile rows', 866,
           (SELECT COUNT_BIG(*) FROM analytics.vwParentStationScheduleProfile)
    UNION ALL
    SELECT N'Daily route-profile rows', 20059,
           (SELECT COUNT_BIG(*) FROM analytics.vwDailyScheduledTripProfile)
) AS metric
ORDER BY metric.MetricName;

/* 2. Validate the scheduled-network baseline KPIs. */
SELECT
    kpi.*,
    CASE
        WHEN kpi.AgencyCount = 15
         AND kpi.ModeCount = 7
         AND kpi.RouteCount = 153
         AND kpi.ParentStationCount = 866
         AND kpi.StopPositionCount = 2290
         AND kpi.UsedStopPositionCount = 2287
         AND kpi.ServicePatternCount = 3947
         AND kpi.ActiveServiceDateCount = 182
         AND kpi.ScheduledTripPatternCount = 90331
         AND kpi.ScheduledTripOccurrenceCount = 1878944
         AND kpi.ScheduledStopEventPatternCount = 1551343
        THEN 'MATCH'
        ELSE 'REVIEW'
    END AS CheckStatus
FROM analytics.vwNetworkBaselineKpi AS kpi;

/* 3. Reconcile scheduled trip occurrences by transport mode. */
DECLARE @ExpectedModeOccurrence TABLE
(
    ModeDetail NVARCHAR(100) NOT NULL PRIMARY KEY,
    ExpectedTripOccurrences BIGINT NOT NULL
);

INSERT INTO @ExpectedModeOccurrence (ModeDetail, ExpectedTripOccurrences)
VALUES
    (N'Stadtbahn / Tram',             500043),
    (N'S-Bahn',                        80403),
    (N'Regional Express (RE)',         50923),
    (N'Regional Bahn (RB)',            49613),
    (N'Urban Bus (KVB)',              918349),
    (N'Regional / Other Bus',         223797),
    (N'Rail Replacement Bus (SEV)',    55816);

SELECT
    expected.ModeDetail,
    expected.ExpectedTripOccurrences,
    actual.ScheduledTripOccurrenceCount AS ActualTripOccurrences,
    actual.ScheduledTripOccurrenceCount - expected.ExpectedTripOccurrences AS Difference,
    CASE
        WHEN actual.ScheduledTripOccurrenceCount = expected.ExpectedTripOccurrences THEN 'MATCH'
        ELSE 'REVIEW'
    END AS CheckStatus
FROM @ExpectedModeOccurrence AS expected
LEFT JOIN analytics.vwModeScheduleProfile AS actual
    ON actual.ModeDetail = expected.ModeDetail
ORDER BY actual.ModeSortOrder;

/* 4. Validate the scheduled-service date coverage. */
SELECT
    MIN(DateValue) AS FirstActiveDate,
    MAX(DateValue) AS LastActiveDate,
    COUNT_BIG(DISTINCT DateKey) AS ActiveDateCount,
    SUM(ScheduledTripCount) AS ScheduledTripOccurrenceCount,
    CASE
        WHEN MIN(DateValue) = CONVERT(DATE, '20260614', 112)
         AND MAX(DateValue) = CONVERT(DATE, '20261212', 112)
         AND COUNT_BIG(DISTINCT DateKey) = 182
         AND SUM(ScheduledTripCount) = 1878944
        THEN 'MATCH'
        ELSE 'REVIEW'
    END AS CheckStatus
FROM analytics.vwDailyScheduledTripProfile;
GO
