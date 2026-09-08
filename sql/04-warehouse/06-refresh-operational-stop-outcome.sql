USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Idempotent refresh for dw.FactOperationalStopOutcome.

    Source observations remain append-only.  The procedure reads the current
    matching view, consolidates each dated scheduled stop event by
    (DateKey, ScheduledStopEventKey), updates an existing outcome when a
    newer source observation changes its consolidated values, and inserts only
    genuinely new outcomes.

    Ordering is deterministic: ObservedAtUtc first, ObservationKey second.
    LatestObservedEstimatedArrivalUtc and the final delay therefore mean the
    latest observed MDD/TRIAS estimate, not a confirmed physical arrival.

    PlatformChangeEvidence is intentionally conservative:
      Changed   = comparable planned/estimated bay values differ at least once;
      Unchanged = comparable planned/estimated bay values agree and no change
                  evidence exists;
      Unknown   = no comparable bay evidence exists.
*/
CREATE OR ALTER PROCEDURE dw.uspRefreshFactOperationalStopOutcome
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SourceObservationCount BIGINT;
    DECLARE @UsableObservationCount BIGINT;
    DECLARE @OperationalOutcomeCount BIGINT;
    DECLARE @RepeatedObservationsConsolidated BIGINT;
    DECLARE @InsertedOutcomeCount BIGINT = 0;
    DECLARE @UpdatedOutcomeCount BIGINT = 0;
    DECLARE @UnchangedOutcomeCount BIGINT = 0;
    DECLARE @RefreshedAtUtc DATETIME2(0) = CONVERT(DATETIME2(0), SYSUTCDATETIME());

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Materialize the expensive matching view once per refresh. */
        CREATE TABLE #MatchedObservation
        (
            ObservationKey BIGINT NOT NULL,
            ObservedAtUtc DATETIME2(0) NOT NULL,
            ScheduledStopEventKey BIGINT NOT NULL,
            TripKey BIGINT NOT NULL,
            RouteKey INT NOT NULL,
            StopKey INT NOT NULL,
            ModeKey SMALLINT NOT NULL,
            ServiceKey INT NOT NULL,
            DateKey INT NOT NULL,
            ServiceDate DATE NOT NULL,
            MatchStatus NVARCHAR(30) NOT NULL,
            TimetabledArrivalUtc DATETIME2(0) NOT NULL,
            EstimatedArrivalUtc DATETIME2(0) NULL,
            ArrivalDelayMinutes DECIMAL(10, 2) NULL,
            PlannedBay NVARCHAR(100) NULL,
            EstimatedBay NVARCHAR(100) NULL,
            FirstOrdinal BIGINT NOT NULL,
            LastOrdinal BIGINT NOT NULL
        );

        INSERT INTO #MatchedObservation
        (
            ObservationKey,
            ObservedAtUtc,
            ScheduledStopEventKey,
            TripKey,
            RouteKey,
            StopKey,
            ModeKey,
            ServiceKey,
            DateKey,
            ServiceDate,
            MatchStatus,
            TimetabledArrivalUtc,
            EstimatedArrivalUtc,
            ArrivalDelayMinutes,
            PlannedBay,
            EstimatedBay,
            FirstOrdinal,
            LastOrdinal
        )
        SELECT
            match_view.ObservationKey,
            match_view.ObservedAtUtc,
            match_view.ScheduledStopEventKey,
            match_view.TripKey,
            match_view.RouteKey,
            match_view.StopKey,
            match_view.ModeKey,
            match_view.ServiceKey,
            match_view.DateKey,
            match_view.ServiceDate,
            match_view.MatchStatus,
            match_view.TimetabledArrivalUtc,
            match_view.EstimatedArrivalUtc,
            match_view.ArrivalDelayMinutes,
            match_view.PlannedBay,
            match_view.EstimatedBay,
            ROW_NUMBER() OVER
            (
                PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
                ORDER BY match_view.ObservedAtUtc, match_view.ObservationKey
            ),
            ROW_NUMBER() OVER
            (
                PARTITION BY match_view.DateKey, match_view.ScheduledStopEventKey
                ORDER BY match_view.ObservedAtUtc DESC, match_view.ObservationKey DESC
            )
        FROM wrk.vwCologneRealtimeTripMatch AS match_view
        WHERE match_view.MatchStatus IN
        (
            N'ExactStopMatch',
            N'ParentStationFallback'
        );

        CREATE UNIQUE CLUSTERED INDEX UX_TempMatchedObservation_ObservationKey
            ON #MatchedObservation (ObservationKey);

        CREATE INDEX IX_TempMatchedObservation_Outcome
            ON #MatchedObservation
            (
                DateKey,
                ScheduledStopEventKey,
                ObservedAtUtc,
                ObservationKey
            );

        CREATE TABLE #OperationalOutcome
        (
            DateKey INT NOT NULL,
            ServiceDate DATE NOT NULL,
            ScheduledStopEventKey BIGINT NOT NULL,
            TripKey BIGINT NOT NULL,
            RouteKey INT NOT NULL,
            StopKey INT NOT NULL,
            ModeKey SMALLINT NOT NULL,
            ServiceKey INT NOT NULL,
            MatchStatus NVARCHAR(30) NOT NULL,
            FirstObservationKey BIGINT NOT NULL,
            LastObservationKey BIGINT NOT NULL,
            FirstObservedAtUtc DATETIME2(0) NOT NULL,
            LastObservedAtUtc DATETIME2(0) NOT NULL,
            ObservationCount BIGINT NOT NULL,
            TimetabledArrivalUtc DATETIME2(0) NOT NULL,
            FirstEstimatedArrivalUtc DATETIME2(0) NULL,
            LatestObservedEstimatedArrivalUtc DATETIME2(0) NULL,
            FirstObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
            FinalObservedEstimatedDelayMinutes DECIMAL(10, 2) NULL,
            PlannedBay NVARCHAR(100) NULL,
            LatestObservedEstimatedBay NVARCHAR(100) NULL,
            PlatformChangeEvidence VARCHAR(20) NOT NULL,
            HasSituationEvidence BIT NOT NULL,
            SituationLinkCount BIGINT NOT NULL
        );

        ;WITH ObservationSituation AS
        (
            SELECT
                observation.ObservationKey,
                COUNT_BIG(link.ObservationKey) AS SituationLinkCount
            FROM #MatchedObservation AS observation
            LEFT JOIN stg.MddRealtimeStopSituationLink AS link
                ON link.ObservationKey = observation.ObservationKey
            GROUP BY observation.ObservationKey
        )
        INSERT INTO #OperationalOutcome
        (
            DateKey,
            ServiceDate,
            ScheduledStopEventKey,
            TripKey,
            RouteKey,
            StopKey,
            ModeKey,
            ServiceKey,
            MatchStatus,
            FirstObservationKey,
            LastObservationKey,
            FirstObservedAtUtc,
            LastObservedAtUtc,
            ObservationCount,
            TimetabledArrivalUtc,
            FirstEstimatedArrivalUtc,
            LatestObservedEstimatedArrivalUtc,
            FirstObservedEstimatedDelayMinutes,
            FinalObservedEstimatedDelayMinutes,
            PlannedBay,
            LatestObservedEstimatedBay,
            PlatformChangeEvidence,
            HasSituationEvidence,
            SituationLinkCount
        )
        SELECT
            observation.DateKey,
            observation.ServiceDate,
            observation.ScheduledStopEventKey,
            observation.TripKey,
            observation.RouteKey,
            observation.StopKey,
            observation.ModeKey,
            observation.ServiceKey,
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.MatchStatus END),

            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.ObservationKey END),
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.ObservationKey END),
            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.ObservedAtUtc END),
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.ObservedAtUtc END),
            COUNT_BIG(*),

            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.TimetabledArrivalUtc END),
            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.EstimatedArrivalUtc END),
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.EstimatedArrivalUtc END),
            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.ArrivalDelayMinutes END),
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.ArrivalDelayMinutes END),
            MAX(CASE WHEN observation.FirstOrdinal = 1
                     THEN observation.PlannedBay END),
            MAX(CASE WHEN observation.LastOrdinal = 1
                     THEN observation.EstimatedBay END),

            CASE
                WHEN MAX
                (
                    CASE
                        WHEN NULLIF(LTRIM(RTRIM(observation.PlannedBay)), N'') IS NOT NULL
                         AND NULLIF(LTRIM(RTRIM(observation.EstimatedBay)), N'') IS NOT NULL
                         AND LTRIM(RTRIM(observation.PlannedBay))
                             <> LTRIM(RTRIM(observation.EstimatedBay))
                        THEN 1
                        ELSE 0
                    END
                ) = 1
                    THEN 'Changed'
                WHEN MAX
                (
                    CASE
                        WHEN NULLIF(LTRIM(RTRIM(observation.PlannedBay)), N'') IS NOT NULL
                         AND NULLIF(LTRIM(RTRIM(observation.EstimatedBay)), N'') IS NOT NULL
                         AND LTRIM(RTRIM(observation.PlannedBay))
                             = LTRIM(RTRIM(observation.EstimatedBay))
                        THEN 1
                        ELSE 0
                    END
                ) = 1
                    THEN 'Unchanged'
                ELSE 'Unknown'
            END,

            CONVERT
            (
                BIT,
                CASE WHEN SUM(ISNULL(situation.SituationLinkCount, 0)) > 0
                     THEN 1 ELSE 0 END
            ),
            SUM(ISNULL(situation.SituationLinkCount, 0))
        FROM #MatchedObservation AS observation
        JOIN ObservationSituation AS situation
            ON situation.ObservationKey = observation.ObservationKey
        GROUP BY
            observation.DateKey,
            observation.ServiceDate,
            observation.ScheduledStopEventKey,
            observation.TripKey,
            observation.RouteKey,
            observation.StopKey,
            observation.ModeKey,
            observation.ServiceKey;

        SELECT @SourceObservationCount = COUNT_BIG(*)
        FROM stg.MddRealtimeStopObservation;

        SELECT
            @UsableObservationCount = ISNULL(SUM(ObservationCount), 0),
            @OperationalOutcomeCount = COUNT_BIG(*),
            @RepeatedObservationsConsolidated = ISNULL
            (
                SUM
                (
                    CASE WHEN ObservationCount > 1
                         THEN ObservationCount - 1
                         ELSE 0 END
                ),
                0
            )
        FROM #OperationalOutcome;

        UPDATE target_fact
        SET
            target_fact.ServiceDate = source_fact.ServiceDate,
            target_fact.TripKey = source_fact.TripKey,
            target_fact.RouteKey = source_fact.RouteKey,
            target_fact.StopKey = source_fact.StopKey,
            target_fact.ModeKey = source_fact.ModeKey,
            target_fact.ServiceKey = source_fact.ServiceKey,
            target_fact.MatchStatus = source_fact.MatchStatus,
            target_fact.FirstObservationKey = source_fact.FirstObservationKey,
            target_fact.LastObservationKey = source_fact.LastObservationKey,
            target_fact.FirstObservedAtUtc = source_fact.FirstObservedAtUtc,
            target_fact.LastObservedAtUtc = source_fact.LastObservedAtUtc,
            target_fact.ObservationCount = source_fact.ObservationCount,
            target_fact.TimetabledArrivalUtc = source_fact.TimetabledArrivalUtc,
            target_fact.FirstEstimatedArrivalUtc = source_fact.FirstEstimatedArrivalUtc,
            target_fact.LatestObservedEstimatedArrivalUtc = source_fact.LatestObservedEstimatedArrivalUtc,
            target_fact.FirstObservedEstimatedDelayMinutes = source_fact.FirstObservedEstimatedDelayMinutes,
            target_fact.FinalObservedEstimatedDelayMinutes = source_fact.FinalObservedEstimatedDelayMinutes,
            target_fact.PlannedBay = source_fact.PlannedBay,
            target_fact.LatestObservedEstimatedBay = source_fact.LatestObservedEstimatedBay,
            target_fact.PlatformChangeEvidence = source_fact.PlatformChangeEvidence,
            target_fact.HasSituationEvidence = source_fact.HasSituationEvidence,
            target_fact.SituationLinkCount = source_fact.SituationLinkCount,
            target_fact.RefreshedAtUtc = @RefreshedAtUtc
        FROM dw.FactOperationalStopOutcome AS target_fact
        JOIN #OperationalOutcome AS source_fact
            ON source_fact.DateKey = target_fact.DateKey
           AND source_fact.ScheduledStopEventKey = target_fact.ScheduledStopEventKey
        WHERE EXISTS
        (
            SELECT
                target_fact.ServiceDate,
                target_fact.TripKey,
                target_fact.RouteKey,
                target_fact.StopKey,
                target_fact.ModeKey,
                target_fact.ServiceKey,
                target_fact.MatchStatus,
                target_fact.FirstObservationKey,
                target_fact.LastObservationKey,
                target_fact.FirstObservedAtUtc,
                target_fact.LastObservedAtUtc,
                target_fact.ObservationCount,
                target_fact.TimetabledArrivalUtc,
                target_fact.FirstEstimatedArrivalUtc,
                target_fact.LatestObservedEstimatedArrivalUtc,
                target_fact.FirstObservedEstimatedDelayMinutes,
                target_fact.FinalObservedEstimatedDelayMinutes,
                target_fact.PlannedBay,
                target_fact.LatestObservedEstimatedBay,
                target_fact.PlatformChangeEvidence,
                target_fact.HasSituationEvidence,
                target_fact.SituationLinkCount
            EXCEPT
            SELECT
                source_fact.ServiceDate,
                source_fact.TripKey,
                source_fact.RouteKey,
                source_fact.StopKey,
                source_fact.ModeKey,
                source_fact.ServiceKey,
                source_fact.MatchStatus,
                source_fact.FirstObservationKey,
                source_fact.LastObservationKey,
                source_fact.FirstObservedAtUtc,
                source_fact.LastObservedAtUtc,
                source_fact.ObservationCount,
                source_fact.TimetabledArrivalUtc,
                source_fact.FirstEstimatedArrivalUtc,
                source_fact.LatestObservedEstimatedArrivalUtc,
                source_fact.FirstObservedEstimatedDelayMinutes,
                source_fact.FinalObservedEstimatedDelayMinutes,
                source_fact.PlannedBay,
                source_fact.LatestObservedEstimatedBay,
                source_fact.PlatformChangeEvidence,
                source_fact.HasSituationEvidence,
                source_fact.SituationLinkCount
        );

        SET @UpdatedOutcomeCount = @@ROWCOUNT;

        INSERT INTO dw.FactOperationalStopOutcome
        (
            DateKey,
            ServiceDate,
            ScheduledStopEventKey,
            TripKey,
            RouteKey,
            StopKey,
            ModeKey,
            ServiceKey,
            MatchStatus,
            FirstObservationKey,
            LastObservationKey,
            FirstObservedAtUtc,
            LastObservedAtUtc,
            ObservationCount,
            TimetabledArrivalUtc,
            FirstEstimatedArrivalUtc,
            LatestObservedEstimatedArrivalUtc,
            FirstObservedEstimatedDelayMinutes,
            FinalObservedEstimatedDelayMinutes,
            PlannedBay,
            LatestObservedEstimatedBay,
            PlatformChangeEvidence,
            HasSituationEvidence,
            SituationLinkCount,
            RefreshedAtUtc
        )
        SELECT
            source_fact.DateKey,
            source_fact.ServiceDate,
            source_fact.ScheduledStopEventKey,
            source_fact.TripKey,
            source_fact.RouteKey,
            source_fact.StopKey,
            source_fact.ModeKey,
            source_fact.ServiceKey,
            source_fact.MatchStatus,
            source_fact.FirstObservationKey,
            source_fact.LastObservationKey,
            source_fact.FirstObservedAtUtc,
            source_fact.LastObservedAtUtc,
            source_fact.ObservationCount,
            source_fact.TimetabledArrivalUtc,
            source_fact.FirstEstimatedArrivalUtc,
            source_fact.LatestObservedEstimatedArrivalUtc,
            source_fact.FirstObservedEstimatedDelayMinutes,
            source_fact.FinalObservedEstimatedDelayMinutes,
            source_fact.PlannedBay,
            source_fact.LatestObservedEstimatedBay,
            source_fact.PlatformChangeEvidence,
            source_fact.HasSituationEvidence,
            source_fact.SituationLinkCount,
            @RefreshedAtUtc
        FROM #OperationalOutcome AS source_fact
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dw.FactOperationalStopOutcome AS target_fact WITH (UPDLOCK, HOLDLOCK)
            WHERE target_fact.DateKey = source_fact.DateKey
              AND target_fact.ScheduledStopEventKey = source_fact.ScheduledStopEventKey
        );

        SET @InsertedOutcomeCount = @@ROWCOUNT;
        SET @UnchangedOutcomeCount =
            @OperationalOutcomeCount - @InsertedOutcomeCount - @UpdatedOutcomeCount;

        COMMIT TRANSACTION;

        SELECT
            N'Succeeded' AS RefreshStatus,
            @RefreshedAtUtc AS RefreshStartedAtUtc,
            CONVERT(DATETIME2(0), SYSUTCDATETIME()) AS RefreshCompletedAtUtc,
            @SourceObservationCount AS SourceObservationCount,
            @UsableObservationCount AS UsableObservationCount,
            @OperationalOutcomeCount AS SourceOperationalOutcomeCount,
            (SELECT COUNT_BIG(*) FROM dw.FactOperationalStopOutcome)
                AS OperationalOutcomeCount,
            @RepeatedObservationsConsolidated AS RepeatedObservationsConsolidated,
            @InsertedOutcomeCount AS InsertedOutcomeCount,
            @UpdatedOutcomeCount AS UpdatedOutcomeCount,
            @UnchangedOutcomeCount AS UnchangedOutcomeCount;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO
