USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
    Change this path before execution.
    The path must be readable by the SQL Server Database Engine.
*/
DECLARE @GtfsRoot NVARCHAR(4000) = N'C:\CHANGE_ME\google_transit_goR';

IF @GtfsRoot LIKE N'%CHANGE_ME%'
BEGIN
    THROW 50001, 'Set @GtfsRoot to the extracted GTFS directory before running this script.', 1;
END;

IF RIGHT(@GtfsRoot, 1) NOT IN (N'\', N'/')
BEGIN
    SET @GtfsRoot += CASE WHEN CHARINDEX(N'/', @GtfsRoot) > 0 THEN N'/' ELSE N'\' END;
END;

DECLARE @Files TABLE
(
    LoadOrder INT NOT NULL,
    TargetTable NVARCHAR(261) NOT NULL,
    FileName NVARCHAR(255) NOT NULL
);

INSERT INTO @Files (LoadOrder, TargetTable, FileName)
VALUES
    (1,  N'stg.GtfsAgency',        N'agency.txt'),
    (2,  N'stg.GtfsCalendar',      N'calendar.txt'),
    (3,  N'stg.GtfsCalendarDates', N'calendar_dates.txt'),
    (4,  N'stg.GtfsFeedInfo',      N'feed_info.txt'),
    (5,  N'stg.GtfsFrequencies',   N'frequencies.txt'),
    (6,  N'stg.GtfsRoutes',        N'routes.txt'),
    (7,  N'stg.GtfsShapes',        N'shapes.txt'),
    (8,  N'stg.GtfsStops',         N'stops.txt'),
    (9,  N'stg.GtfsTrips',         N'trips.txt'),
    (10, N'stg.GtfsStopTimes',     N'stop_times.txt'),
    (11, N'stg.GtfsTransfers',     N'transfers.txt');

DECLARE @LoadBatchId BIGINT;
DECLARE @TargetTable NVARCHAR(261);
DECLARE @FileName NVARCHAR(255);
DECLARE @FilePath NVARCHAR(4000);
DECLARE @Sql NVARCHAR(MAX);

INSERT INTO ctl.GtfsLoadBatch (SourcePath, Status)
VALUES (@GtfsRoot, 'Loading');

SET @LoadBatchId = SCOPE_IDENTITY();

BEGIN TRY
    DECLARE FileCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT TargetTable, FileName
        FROM @Files
        ORDER BY LoadOrder;

    OPEN FileCursor;
    FETCH NEXT FROM FileCursor INTO @TargetTable, @FileName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @FilePath = @GtfsRoot + @FileName;
        SET @Sql =
            N'TRUNCATE TABLE ' + @TargetTable + N';' + CHAR(10) +
            N'BULK INSERT ' + @TargetTable +
            N' FROM N''' + REPLACE(@FilePath, N'''', N'''''') + N''' WITH (' +
            N'FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', ' +
            N'CODEPAGE = ''65001'', ROWTERMINATOR = ''0x0a'', TABLOCK, KEEPNULLS);';

        EXEC sys.sp_executesql @Sql;
        FETCH NEXT FROM FileCursor INTO @TargetTable, @FileName;
    END;

    CLOSE FileCursor;
    DEALLOCATE FileCursor;

    UPDATE batch
    SET
        FeedVersion = feed.FeedVersion,
        FeedStartDate = TRY_CONVERT(DATE, feed.FeedStartDate, 112),
        FeedEndDate = TRY_CONVERT(DATE, feed.FeedEndDate, 112),
        CompletedAtUtc = SYSUTCDATETIME(),
        Status = 'Loaded'
    FROM ctl.GtfsLoadBatch AS batch
    CROSS JOIN stg.GtfsFeedInfo AS feed
    WHERE batch.LoadBatchId = @LoadBatchId;
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'FileCursor') >= 0 CLOSE FileCursor;
    IF CURSOR_STATUS('local', 'FileCursor') > -3 DEALLOCATE FileCursor;

    UPDATE ctl.GtfsLoadBatch
    SET
        CompletedAtUtc = SYSUTCDATETIME(),
        Status = 'Failed',
        ErrorMessage = ERROR_MESSAGE()
    WHERE LoadBatchId = @LoadBatchId;

    THROW;
END CATCH;

SELECT
    LoadBatchId,
    FeedVersion,
    FeedStartDate,
    FeedEndDate,
    Status,
    StartedAtUtc,
    CompletedAtUtc
FROM ctl.GtfsLoadBatch
WHERE LoadBatchId = @LoadBatchId;
GO
