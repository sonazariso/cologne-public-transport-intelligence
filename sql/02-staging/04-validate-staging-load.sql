USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;

/* Snapshot row counts from VRS feed VERSION__20260829_0050. */
DECLARE @Expected TABLE
(
    TableName SYSNAME NOT NULL,
    ExpectedRows BIGINT NOT NULL
);

INSERT INTO @Expected (TableName, ExpectedRows)
VALUES
    (N'GtfsAgency', 36),
    (N'GtfsCalendar', 6337),
    (N'GtfsCalendarDates', 1025387),
    (N'GtfsFeedInfo', 1),
    (N'GtfsFrequencies', 0),
    (N'GtfsRoutes', 981),
    (N'GtfsShapes', 1742925),
    (N'GtfsStopTimes', 3818617),
    (N'GtfsStops', 30719),
    (N'GtfsTransfers', 1708),
    (N'GtfsTrips', 167386);

DECLARE @Actual TABLE
(
    TableName SYSNAME NOT NULL,
    ActualRows BIGINT NOT NULL
);

INSERT INTO @Actual (TableName, ActualRows)
SELECT N'GtfsAgency', COUNT_BIG(*) FROM stg.GtfsAgency UNION ALL
SELECT N'GtfsCalendar', COUNT_BIG(*) FROM stg.GtfsCalendar UNION ALL
SELECT N'GtfsCalendarDates', COUNT_BIG(*) FROM stg.GtfsCalendarDates UNION ALL
SELECT N'GtfsFeedInfo', COUNT_BIG(*) FROM stg.GtfsFeedInfo UNION ALL
SELECT N'GtfsFrequencies', COUNT_BIG(*) FROM stg.GtfsFrequencies UNION ALL
SELECT N'GtfsRoutes', COUNT_BIG(*) FROM stg.GtfsRoutes UNION ALL
SELECT N'GtfsShapes', COUNT_BIG(*) FROM stg.GtfsShapes UNION ALL
SELECT N'GtfsStopTimes', COUNT_BIG(*) FROM stg.GtfsStopTimes UNION ALL
SELECT N'GtfsStops', COUNT_BIG(*) FROM stg.GtfsStops UNION ALL
SELECT N'GtfsTransfers', COUNT_BIG(*) FROM stg.GtfsTransfers UNION ALL
SELECT N'GtfsTrips', COUNT_BIG(*) FROM stg.GtfsTrips;

SELECT
    expected.TableName,
    expected.ExpectedRows,
    actual.ActualRows,
    actual.ActualRows - expected.ExpectedRows AS Difference,
    CASE WHEN actual.ActualRows = expected.ExpectedRows THEN 'MATCH' ELSE 'REVIEW' END AS SnapshotStatus
FROM @Expected AS expected
JOIN @Actual AS actual
    ON actual.TableName = expected.TableName
ORDER BY expected.TableName;

CREATE TABLE #ValidationResults
(
    CheckName NVARCHAR(200) NOT NULL,
    Severity VARCHAR(10) NOT NULL,
    FailedRows BIGINT NOT NULL,
    ExpectedResult NVARCHAR(200) NOT NULL
);

INSERT INTO #ValidationResults
SELECT N'Duplicate agency_id', 'Error', COUNT_BIG(*) - COUNT_BIG(DISTINCT AgencyId), N'0'
FROM stg.GtfsAgency;

INSERT INTO #ValidationResults
SELECT N'Duplicate route_id', 'Warning', COUNT_BIG(*) - COUNT_BIG(DISTINCT RouteId), N'1 known source duplicate'
FROM stg.GtfsRoutes;

INSERT INTO #ValidationResults
SELECT N'Duplicate trip_id', 'Error', COUNT_BIG(*) - COUNT_BIG(DISTINCT TripId), N'0'
FROM stg.GtfsTrips;

INSERT INTO #ValidationResults
SELECT N'Duplicate stop_id', 'Error', COUNT_BIG(*) - COUNT_BIG(DISTINCT StopId), N'0'
FROM stg.GtfsStops;

INSERT INTO #ValidationResults
SELECT N'Duplicate calendar service_id', 'Error', COUNT_BIG(*) - COUNT_BIG(DISTINCT ServiceId), N'0'
FROM stg.GtfsCalendar;

INSERT INTO #ValidationResults
SELECT N'Routes with missing agency', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsRoutes AS route
WHERE NULLIF(route.AgencyId, N'') IS NOT NULL
  AND NOT EXISTS
      (SELECT 1 FROM stg.GtfsAgency AS agency WHERE agency.AgencyId = route.AgencyId);

INSERT INTO #ValidationResults
SELECT N'Trips with missing route', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsTrips AS trip
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsRoutes AS route WHERE route.RouteId = trip.RouteId);

INSERT INTO #ValidationResults
SELECT N'Trips with missing service', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsTrips AS trip
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsCalendar AS calendar WHERE calendar.ServiceId = trip.ServiceId)
  AND NOT EXISTS
      (SELECT 1 FROM stg.GtfsCalendarDates AS calendar_date WHERE calendar_date.ServiceId = trip.ServiceId);

INSERT INTO #ValidationResults
SELECT N'Stop times with missing trip', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsStopTimes AS stop_time
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsTrips AS trip WHERE trip.TripId = stop_time.TripId);

INSERT INTO #ValidationResults
SELECT N'Stop times with missing stop', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsStopTimes AS stop_time
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsStops AS stop WHERE stop.StopId = stop_time.StopId);

INSERT INTO #ValidationResults
SELECT N'Invalid calendar dates', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsCalendar
WHERE TRY_CONVERT(DATE, StartDate, 112) IS NULL
   OR TRY_CONVERT(DATE, EndDate, 112) IS NULL;

INSERT INTO #ValidationResults
SELECT N'Stop times missing required identifiers', 'Error', COUNT_BIG(*), N'0'
FROM stg.GtfsStopTimes
WHERE NULLIF(TripId, N'') IS NULL
   OR NULLIF(StopId, N'') IS NULL
   OR TRY_CONVERT(INT, StopSequence) IS NULL;

SELECT
    CheckName,
    Severity,
    FailedRows,
    ExpectedResult,
    CASE
        WHEN CheckName = N'Duplicate route_id' AND FailedRows = 1 THEN 'EXPECTED WARNING'
        WHEN FailedRows = 0 THEN 'PASS'
        ELSE 'REVIEW'
    END AS CheckStatus
FROM #ValidationResults
ORDER BY
    CASE Severity WHEN 'Error' THEN 1 ELSE 2 END,
    CheckName;

/* Initial technical Cologne scope: global stop-ID prefix de:05315:. */
SELECT
    (SELECT COUNT_BIG(*) FROM stg.GtfsStops WHERE StopId LIKE N'de:05315:%') AS CologneStops,
    COUNT_BIG(DISTINCT trip.RouteId) AS CologneRoutes,
    COUNT_BIG(DISTINCT stop_time.TripId) AS CologneTrips,
    COUNT_BIG(*) AS CologneStopTimes
FROM stg.GtfsStopTimes AS stop_time
JOIN stg.GtfsTrips AS trip
    ON trip.TripId = stop_time.TripId
WHERE stop_time.StopId LIKE N'de:05315:%';

DECLARE @ErrorFailures BIGINT =
(
    SELECT COALESCE(SUM(FailedRows), 0)
    FROM #ValidationResults
    WHERE Severity = 'Error'
);

;WITH LatestLoadedBatch AS
(
    SELECT TOP (1) LoadBatchId
    FROM ctl.GtfsLoadBatch
    WHERE Status IN ('Loaded', 'Validated', 'ValidationFailed')
    ORDER BY LoadBatchId DESC
)
UPDATE batch
SET Status = CASE WHEN @ErrorFailures = 0 THEN 'Validated' ELSE 'ValidationFailed' END
FROM ctl.GtfsLoadBatch AS batch
JOIN LatestLoadedBatch AS latest
    ON latest.LoadBatchId = batch.LoadBatchId;

SELECT TOP (1)
    LoadBatchId,
    FeedVersion,
    FeedStartDate,
    FeedEndDate,
    Status,
    StartedAtUtc,
    CompletedAtUtc,
    ErrorMessage
FROM ctl.GtfsLoadBatch
ORDER BY LoadBatchId DESC;
GO
