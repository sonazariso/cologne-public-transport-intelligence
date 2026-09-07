USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Set-based input contract for the MDD/TRIAS realtime Collector.

    The TVPs use source identities.  SQL Server resolves those identities to
    the existing staging-table surrogate keys inside the persistence
    procedure.
*/
IF TYPE_ID(N'stg.MddRealtimeStopObservationInputType') IS NULL
BEGIN
    EXEC
    (
        N'CREATE TYPE stg.MddRealtimeStopObservationInputType AS TABLE
        (
            ResultId NVARCHAR(100) NOT NULL,
            StopPointRef NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL,
            StopName NVARCHAR(200) NULL,
            LineName NVARCHAR(100) NULL,
            LineRef NVARCHAR(150) NULL,
            JourneyRef NVARCHAR(200) NOT NULL,
            DirectionRef NVARCHAR(50) NULL,
            OperatorRef NVARCHAR(100) NULL,
            PtMode NVARCHAR(50) NULL,
            RailSubmode NVARCHAR(100) NULL,
            TimetabledArrivalUtc DATETIME2(0) NULL,
            EstimatedArrivalUtc DATETIME2(0) NULL,
            PlannedBay NVARCHAR(100) NULL,
            EstimatedBay NVARCHAR(100) NULL
        );'
    );
END;
GO

IF TYPE_ID(N'stg.MddRealtimeSituationObservationInputType') IS NULL
BEGIN
    EXEC
    (
        N'CREATE TYPE stg.MddRealtimeSituationObservationInputType AS TABLE
        (
            ParticipantRef NVARCHAR(100) NOT NULL,
            SituationNumber NVARCHAR(150) NOT NULL,
            Summary NVARCHAR(1000) NULL,
            Description NVARCHAR(2000) NULL,
            Detail NVARCHAR(MAX) NULL,
            ValidFromUtc DATETIME2(0) NULL,
            ValidToUtc DATETIME2(0) NULL
        );'
    );
END;
GO

IF TYPE_ID(N'stg.MddRealtimeStopSituationLinkInputType') IS NULL
BEGIN
    EXEC
    (
        N'CREATE TYPE stg.MddRealtimeStopSituationLinkInputType AS TABLE
        (
            ResultId NVARCHAR(100) NOT NULL,
            ParticipantRef NVARCHAR(100) NOT NULL,
            SituationNumber NVARCHAR(150) NOT NULL,
            RelationScope NVARCHAR(20) NOT NULL
                CHECK (RelationScope IN (N''CALL'', N''SERVICE''))
        );'
    );
END;
GO

CREATE OR ALTER PROCEDURE stg.uspPersistMddRealtimeSnapshot
    @ObservedAtUtc DATETIME2(0),
    @StopObservations stg.MddRealtimeStopObservationInputType READONLY,
    @SituationObservations stg.MddRealtimeSituationObservationInputType READONLY,
    @SituationLinks stg.MddRealtimeStopSituationLinkInputType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @StopsInserted BIGINT = 0;
    DECLARE @StopsAlreadyPresent BIGINT = 0;
    DECLARE @SituationsInserted BIGINT = 0;
    DECLARE @SituationsAlreadyPresent BIGINT = 0;
    DECLARE @LinksInserted BIGINT = 0;
    DECLARE @LinksAlreadyPresent BIGINT = 0;
    DECLARE @LinksSkippedUnresolved BIGINT = 0;
    DECLARE @ResolvedLinkCount BIGINT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Stop observations remain append-only at ObservedAtUtc + ResultId. */
        ;WITH StopRows AS
        (
            SELECT
                s.ResultId,
                s.StopPointRef,
                s.StopName,
                s.LineName,
                s.LineRef,
                s.JourneyRef,
                s.DirectionRef,
                s.OperatorRef,
                s.PtMode,
                s.RailSubmode,
                s.TimetabledArrivalUtc,
                s.EstimatedArrivalUtc,
                s.PlannedBay,
                s.EstimatedBay,
                ROW_NUMBER() OVER
                (
                    PARTITION BY s.ResultId
                    ORDER BY (SELECT NULL)
                ) AS SourceRowNumber
            FROM @StopObservations AS s
        )
        INSERT INTO stg.MddRealtimeStopObservation
        (
            ObservedAtUtc,
            ResultId,
            StopPointRef,
            StopName,
            LineName,
            LineRef,
            JourneyRef,
            DirectionRef,
            OperatorRef,
            PtMode,
            RailSubmode,
            TimetabledArrivalUtc,
            EstimatedArrivalUtc,
            PlannedBay,
            EstimatedBay
        )
        SELECT
            @ObservedAtUtc,
            s.ResultId,
            s.StopPointRef,
            s.StopName,
            s.LineName,
            s.LineRef,
            s.JourneyRef,
            s.DirectionRef,
            s.OperatorRef,
            s.PtMode,
            s.RailSubmode,
            s.TimetabledArrivalUtc,
            s.EstimatedArrivalUtc,
            s.PlannedBay,
            s.EstimatedBay
        FROM StopRows AS s
        WHERE s.SourceRowNumber = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM stg.MddRealtimeStopObservation AS existing WITH (UPDLOCK, HOLDLOCK)
              WHERE existing.ObservedAtUtc = @ObservedAtUtc
                AND existing.ResultId = s.ResultId
          );

        SET @StopsInserted = @@ROWCOUNT;
        SELECT @StopsAlreadyPresent = COUNT_BIG(*) FROM @StopObservations;
        SET @StopsAlreadyPresent = @StopsAlreadyPresent - @StopsInserted;

        /* Situation observations remain append-only at the snapshot identity. */
        ;WITH SituationRows AS
        (
            SELECT
                s.ParticipantRef,
                s.SituationNumber,
                s.Summary,
                s.Description,
                s.Detail,
                s.ValidFromUtc,
                s.ValidToUtc,
                ROW_NUMBER() OVER
                (
                    PARTITION BY s.ParticipantRef, s.SituationNumber
                    ORDER BY (SELECT NULL)
                ) AS SourceRowNumber
            FROM @SituationObservations AS s
        )
        INSERT INTO stg.MddRealtimeSituationObservation
        (
            ObservedAtUtc,
            ParticipantRef,
            SituationNumber,
            Summary,
            Description,
            Detail,
            ValidFromUtc,
            ValidToUtc
        )
        SELECT
            @ObservedAtUtc,
            s.ParticipantRef,
            s.SituationNumber,
            s.Summary,
            s.Description,
            s.Detail,
            s.ValidFromUtc,
            s.ValidToUtc
        FROM SituationRows AS s
        WHERE s.SourceRowNumber = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM stg.MddRealtimeSituationObservation AS existing WITH (UPDLOCK, HOLDLOCK)
              WHERE existing.ObservedAtUtc = @ObservedAtUtc
                AND existing.ParticipantRef = s.ParticipantRef
                AND existing.SituationNumber = s.SituationNumber
          );

        SET @SituationsInserted = @@ROWCOUNT;
        SELECT @SituationsAlreadyPresent = COUNT_BIG(*) FROM @SituationObservations;
        SET @SituationsAlreadyPresent = @SituationsAlreadyPresent - @SituationsInserted;

        /*
            Resolve links only through identities present in this parsed
            snapshot.  This preserves the current unresolved-link behavior:
            no fabricated identity and no reuse of a same-timestamp row that
            was not part of the current response.
        */
        DECLARE @ResolvedLinks TABLE
        (
            ObservationKey BIGINT NULL,
            SituationObservationKey BIGINT NULL,
            RelationScope NVARCHAR(20) NOT NULL
        );

        ;WITH SourceStops AS
        (
            SELECT DISTINCT ResultId
            FROM @StopObservations
        ),
        SourceSituations AS
        (
            SELECT DISTINCT ParticipantRef, SituationNumber
            FROM @SituationObservations
        )
        INSERT INTO @ResolvedLinks
        (
            ObservationKey,
            SituationObservationKey,
            RelationScope
        )
        SELECT
            observation.ObservationKey,
            situation.SituationObservationKey,
            link.RelationScope
        FROM @SituationLinks AS link
        LEFT JOIN SourceStops AS sourceStop
            ON sourceStop.ResultId = link.ResultId
        LEFT JOIN stg.MddRealtimeStopObservation AS observation
            ON observation.ObservedAtUtc = @ObservedAtUtc
           AND observation.ResultId = sourceStop.ResultId
        LEFT JOIN SourceSituations AS sourceSituation
            ON sourceSituation.ParticipantRef = link.ParticipantRef
           AND sourceSituation.SituationNumber = link.SituationNumber
        LEFT JOIN stg.MddRealtimeSituationObservation AS situation
            ON situation.ObservedAtUtc = @ObservedAtUtc
           AND situation.ParticipantRef = sourceSituation.ParticipantRef
           AND situation.SituationNumber = sourceSituation.SituationNumber;

        SELECT @LinksSkippedUnresolved = COUNT_BIG(*)
        FROM @ResolvedLinks
        WHERE ObservationKey IS NULL
           OR SituationObservationKey IS NULL;

        SELECT @ResolvedLinkCount = COUNT_BIG(*)
        FROM @ResolvedLinks
        WHERE ObservationKey IS NOT NULL
          AND SituationObservationKey IS NOT NULL;

        ;WITH LinkRows AS
        (
            SELECT
                r.ObservationKey,
                r.SituationObservationKey,
                r.RelationScope,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        r.ObservationKey,
                        r.SituationObservationKey,
                        r.RelationScope
                    ORDER BY (SELECT NULL)
                ) AS SourceRowNumber
            FROM @ResolvedLinks AS r
            WHERE r.ObservationKey IS NOT NULL
              AND r.SituationObservationKey IS NOT NULL
        )
        INSERT INTO stg.MddRealtimeStopSituationLink
        (
            ObservationKey,
            SituationObservationKey,
            RelationScope
        )
        SELECT
            r.ObservationKey,
            r.SituationObservationKey,
            r.RelationScope
        FROM LinkRows AS r
        WHERE r.SourceRowNumber = 1
          AND NOT EXISTS
          (
              SELECT 1
              FROM stg.MddRealtimeStopSituationLink AS existing WITH (UPDLOCK, HOLDLOCK)
              WHERE existing.ObservationKey = r.ObservationKey
                AND existing.SituationObservationKey = r.SituationObservationKey
                AND existing.RelationScope = r.RelationScope
          );

        SET @LinksInserted = @@ROWCOUNT;
        SET @LinksAlreadyPresent = @ResolvedLinkCount - @LinksInserted;

        COMMIT TRANSACTION;

        SELECT
            @StopsInserted AS StopsInserted,
            @StopsAlreadyPresent AS StopsAlreadyPresent,
            @SituationsInserted AS SituationsInserted,
            @SituationsAlreadyPresent AS SituationsAlreadyPresent,
            @LinksInserted AS LinksInserted,
            @LinksAlreadyPresent AS LinksAlreadyPresent,
            @LinksSkippedUnresolved AS LinksSkippedUnresolved;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        THROW;
    END CATCH;
END;
GO
