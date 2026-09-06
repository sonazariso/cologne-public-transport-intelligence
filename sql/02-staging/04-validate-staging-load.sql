USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @GtfsLoadBatchId BIGINT;
DECLARE @GtfsBatchStatus VARCHAR(30);
DECLARE @StagingStateRowCount INT;
DECLARE @StagingLockResult INT;
DECLARE @StagingLockAcquired BIT = 0;

BEGIN TRY
    /* Keep the staging snapshot stable while it is being validated. */
    EXEC @StagingLockResult = sys.sp_getapplock
        @Resource = N'GtfsStaticStaging',
        @LockMode = N'Shared',
        @LockOwner = N'Session',
        @LockTimeout = 0;

    IF @StagingLockResult < 0
    BEGIN
        THROW 50020, 'A GTFS staging replacement is already in progress.', 1;
    END;

    SET @StagingLockAcquired = 1;

    SELECT @StagingStateRowCount = COUNT(*)
    FROM ctl.GtfsStagingState
    WHERE StagingStateId = 1;

    IF @StagingStateRowCount <> 1
    BEGIN
        THROW 50021, 'The singleton GTFS staging-state row is missing.', 1;
    END;

    SELECT @GtfsLoadBatchId = CurrentLoadBatchId
    FROM ctl.GtfsStagingState
    WHERE StagingStateId = 1;

    IF @GtfsLoadBatchId IS NULL
    BEGIN
        THROW 50022, 'No current GTFS staging batch is recorded.', 1;
    END;

    SELECT @GtfsBatchStatus = Status
    FROM ctl.GtfsLoadBatch
    WHERE LoadBatchId = @GtfsLoadBatchId;

    IF @GtfsBatchStatus IS NULL
    BEGIN
        THROW 50023, 'The current GTFS staging batch does not exist.', 1;
    END;

    IF @GtfsBatchStatus NOT IN ('Loaded', 'Validated', 'ValidationFailed')
    BEGIN
        THROW 50024, 'The current GTFS staging batch is not eligible for validation.', 1;
    END;

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
    ExpectedResult NVARCHAR(200) NOT NULL,
    ActualResult NVARCHAR(200) NOT NULL
);

/* Include expected staging row-count mismatches in the batch validation decision. */
INSERT INTO #ValidationResults
SELECT N'Staging row count: ' + expected.TableName,
       'Error',
       CASE WHEN actual.ActualRows = expected.ExpectedRows THEN 0 ELSE 1 END,
       N'Actual rows = ' + CONVERT(NVARCHAR(30), expected.ExpectedRows),
       N'Actual rows = ' + CONVERT(NVARCHAR(30), actual.ActualRows)
FROM @Expected AS expected
JOIN @Actual AS actual
    ON actual.TableName = expected.TableName;

INSERT INTO #ValidationResults
SELECT N'Duplicate agency_id',
       'Error',
       COUNT_BIG(*) - COUNT_BIG(DISTINCT AgencyId),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*) - COUNT_BIG(DISTINCT AgencyId))
FROM stg.GtfsAgency;

INSERT INTO #ValidationResults
SELECT N'Duplicate route_id',
       'Warning',
       COUNT_BIG(*) - COUNT_BIG(DISTINCT RouteId),
       N'1 known source duplicate',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*) - COUNT_BIG(DISTINCT RouteId))
FROM stg.GtfsRoutes;

INSERT INTO #ValidationResults
SELECT N'Duplicate trip_id',
       'Error',
       COUNT_BIG(*) - COUNT_BIG(DISTINCT TripId),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*) - COUNT_BIG(DISTINCT TripId))
FROM stg.GtfsTrips;

INSERT INTO #ValidationResults
SELECT N'Duplicate stop_id',
       'Error',
       COUNT_BIG(*) - COUNT_BIG(DISTINCT StopId),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*) - COUNT_BIG(DISTINCT StopId))
FROM stg.GtfsStops;

INSERT INTO #ValidationResults
SELECT N'Duplicate calendar service_id',
       'Error',
       COUNT_BIG(*) - COUNT_BIG(DISTINCT ServiceId),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*) - COUNT_BIG(DISTINCT ServiceId))
FROM stg.GtfsCalendar;

INSERT INTO #ValidationResults
SELECT N'Routes with missing agency',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsRoutes AS route
WHERE NULLIF(route.AgencyId, N'') IS NOT NULL
  AND NOT EXISTS
      (SELECT 1 FROM stg.GtfsAgency AS agency WHERE agency.AgencyId = route.AgencyId);

INSERT INTO #ValidationResults
SELECT N'Trips with missing route',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsTrips AS trip
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsRoutes AS route WHERE route.RouteId = trip.RouteId);

INSERT INTO #ValidationResults
SELECT N'Trips with missing service',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsTrips AS trip
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsCalendar AS calendar WHERE calendar.ServiceId = trip.ServiceId)
  AND NOT EXISTS
      (SELECT 1 FROM stg.GtfsCalendarDates AS calendar_date WHERE calendar_date.ServiceId = trip.ServiceId);

INSERT INTO #ValidationResults
SELECT N'Stop times with missing trip',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsStopTimes AS stop_time
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsTrips AS trip WHERE trip.TripId = stop_time.TripId);

INSERT INTO #ValidationResults
SELECT N'Stop times with missing stop',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsStopTimes AS stop_time
WHERE NOT EXISTS
      (SELECT 1 FROM stg.GtfsStops AS stop WHERE stop.StopId = stop_time.StopId);

INSERT INTO #ValidationResults
SELECT N'Invalid calendar dates',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsCalendar
WHERE TRY_CONVERT(DATE, StartDate, 112) IS NULL
   OR TRY_CONVERT(DATE, EndDate, 112) IS NULL;

INSERT INTO #ValidationResults
SELECT N'Stop times missing required identifiers',
       'Error',
       COUNT_BIG(*),
       N'0',
       N'Failed rows = ' + CONVERT(NVARCHAR(30), COUNT_BIG(*))
FROM stg.GtfsStopTimes
WHERE NULLIF(TripId, N'') IS NULL
   OR NULLIF(StopId, N'') IS NULL
   OR TRY_CONVERT(INT, StopSequence) IS NULL;

ALTER TABLE #ValidationResults
ADD CheckStatus VARCHAR(20) NULL;

UPDATE result
SET CheckStatus = CASE
    WHEN CheckName = N'Duplicate route_id' AND FailedRows = 1 THEN 'EXPECTED WARNING'
    WHEN FailedRows = 0 THEN 'PASS'
    ELSE 'REVIEW'
END
FROM #ValidationResults AS result;

IF EXISTS
(
    SELECT 1
    FROM #ValidationResults
    WHERE CheckStatus IS NULL
)
BEGIN
    THROW 50026, 'A GTFS validation check did not receive a status.', 1;
END;

SELECT
    CheckName,
    Severity,
    FailedRows,
    ExpectedResult,
    CheckStatus
FROM #ValidationResults
ORDER BY
    CASE Severity WHEN 'Error' THEN 1 ELSE 2 END,
    CheckName;

/* Initial technical Cologne scope: global stop-ID prefix de:05315:. */
SELECT
    (SELECT COUNT_BIG(*) FROM stg.GtfsStops WHERE StopId LIKE N'de:05315:%') AS CologneStopRecords,
    (SELECT COUNT_BIG(*) FROM stg.GtfsStops WHERE StopId LIKE N'de:05315:%' AND LocationType = N'1') AS CologneParentStations,
    (SELECT COUNT_BIG(*) FROM stg.GtfsStops WHERE StopId LIKE N'de:05315:%' AND LocationType = N'0') AS CologneStopPositions,
    COUNT_BIG(DISTINCT stop_time.StopId) AS CologneStopsUsedInStopTimes,
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

DECLARE @ValidationResultCount BIGINT =
(
    SELECT COUNT_BIG(*)
    FROM #ValidationResults
);

BEGIN TRANSACTION;

DECLARE @ValidatedAtUtc DATETIME2(0) = SYSUTCDATETIME();

/* Replace this batch's current results and status as one logical outcome. */
DELETE FROM ctl.GtfsValidationResult
WHERE LoadBatchId = @GtfsLoadBatchId;

INSERT INTO ctl.GtfsValidationResult
(
    LoadBatchId,
    CheckName,
    Severity,
    FailedRows,
    ExpectedResult,
    ActualResult,
    CheckStatus,
    ValidatedAtUtc
)
SELECT
    @GtfsLoadBatchId,
    result.CheckName,
    result.Severity,
    result.FailedRows,
    result.ExpectedResult,
    result.ActualResult,
    result.CheckStatus,
    @ValidatedAtUtc
FROM #ValidationResults AS result;

IF @@ROWCOUNT <> @ValidationResultCount
BEGIN
    THROW 50027, 'The persisted GTFS validation-result count does not match the calculated result count.', 1;
END;

UPDATE batch
SET Status = CASE WHEN @ErrorFailures = 0 THEN 'Validated' ELSE 'ValidationFailed' END
FROM ctl.GtfsLoadBatch AS batch
WHERE batch.LoadBatchId = @GtfsLoadBatchId;

IF @@ROWCOUNT <> 1
BEGIN
    THROW 50025, 'The current GTFS staging batch could not be updated by validation.', 1;
END;

COMMIT TRANSACTION;

SELECT
    LoadBatchId,
    FeedVersion,
    FeedStartDate,
    FeedEndDate,
    Status,
    StartedAtUtc,
    CompletedAtUtc,
    ErrorMessage
FROM ctl.GtfsLoadBatch
WHERE LoadBatchId = @GtfsLoadBatchId;

EXEC sys.sp_releaseapplock
    @Resource = N'GtfsStaticStaging',
    @LockOwner = N'Session';

SET @StagingLockAcquired = 0;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    IF @StagingLockAcquired = 1
    BEGIN
        EXEC sys.sp_releaseapplock
            @Resource = N'GtfsStaticStaging',
            @LockOwner = N'Session';
    END;

    THROW;
END CATCH;
GO
