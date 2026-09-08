USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Realtime analytics layer for later Power BI consumption.

    These views describe observed estimated-delay evidence.  They do not
    create an OnTimeRate because no approved business threshold exists yet.
    They also do not infer cancellation, departure, or situation causality.
    The seven configured locations are a sampling panel, not complete Cologne
    network coverage.
*/

/* One row per Collector execution, including successful Automatic runs. */
CREATE OR ALTER VIEW analytics.vwRealtimeCollectorRunHealth
AS
SELECT
    run.CollectorRunId,
    CONVERT(DATE, run.StartedAtUtc) AS CollectionDateUtc,
    CONVERT
    (
        DATE,
        run.StartedAtUtc AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time'
    ) AS CollectionDateLocal,
    run.StartedAtUtc,
    run.CompletedAtUtc,
    run.Status,
    run.SamplingMode,
    run.SamplingBucketUtc,
    run.SamplingSlot,
    run.SamplingTargetId,
    run.SamplingTargetName,
    run.StopPointRef,
    run.NumberOfResults,
    run.ObservedAtUtc,
    run.HttpStatus,
    run.HttpAttempts,
    run.StopEventsReturned AS SourceStopEventsReturned,
    run.SituationsInContext,
    run.UnidentifiedSituations,
    run.LinksObserved,
    run.StopsInserted,
    run.StopsAlreadyPresent,
    run.SituationsInserted,
    run.SituationsAlreadyPresent,
    run.LinksInserted,
    run.LinksAlreadyPresent,
    run.LinksSkippedUnresolved,
    run.DurationMs,
    run.ErrorCategory,
    run.ErrorMessage,
    CONVERT(BIT, CASE WHEN run.Status = 'Succeeded' THEN 1 ELSE 0 END)
        AS IsSuccessfulRun,
    CONVERT
    (
        BIT,
        CASE WHEN run.Status = 'Succeeded'
                  AND run.SamplingMode = 'Automatic'
             THEN 1 ELSE 0 END
    ) AS IsSuccessfulAutomaticRun,
    CONVERT(BIT, CASE WHEN run.Status = 'Failed' THEN 1 ELSE 0 END)
        AS IsFailedRun,
    CONVERT(BIT, CASE WHEN run.Status = 'Started' THEN 1 ELSE 0 END)
        AS IsIncompleteStartedRun,
    CONVERT
    (
        BIT,
        CASE WHEN run.Status = 'Succeeded'
                  AND run.SamplingMode = 'Automatic'
                  AND run.SamplingTargetId IS NOT NULL
             THEN 1 ELSE 0 END
    ) AS ParticipatedInSamplingPanel
FROM ctl.MddCollectorRun AS run;
GO

/*
    One row per UTC collection date.  Match-status, bay, situation, and run
    counts stay at their source-observation/run grains; outcome counts are
    labelled by the date on which an operational outcome was first observed.
*/
CREATE OR ALTER VIEW analytics.vwRealtimeDataQualityCoverage
AS
WITH SourceByDate AS
(
    SELECT
        CONVERT(DATE, observation.ObservedAtUtc) AS CollectionDateUtc,
        COUNT_BIG(*) AS SourceObservationCount,
        COUNT_BIG(DISTINCT observation.ObservedAtUtc) AS SourceSnapshotCount,
        MIN(observation.ObservedAtUtc) AS FirstSourceObservationAtUtc,
        MAX(observation.ObservedAtUtc) AS LastSourceObservationAtUtc
    FROM stg.MddRealtimeStopObservation AS observation
    GROUP BY CONVERT(DATE, observation.ObservedAtUtc)
),
SituationByObservation AS
(
    SELECT
        link.ObservationKey,
        COUNT_BIG(*) AS SituationLinkCount
    FROM stg.MddRealtimeStopSituationLink AS link
    GROUP BY link.ObservationKey
),
MatchByDate AS
(
    SELECT
        CONVERT(DATE, match_view.ObservedAtUtc) AS CollectionDateUtc,
        COUNT_BIG(*) AS MatchedViewObservationCount,
        SUM(CASE WHEN match_view.MatchStatus = N'ExactStopMatch'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS ExactStopMatchCount,
        SUM(CASE WHEN match_view.MatchStatus = N'ParentStationFallback'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS ParentStationFallbackCount,
        SUM(CASE WHEN match_view.MatchStatus = N'StaticCoverageMissing'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS StaticCoverageMissingCount,
        SUM(CASE WHEN match_view.MatchStatus = N'Unresolved'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS UnresolvedCount,
        SUM(CASE WHEN match_view.MatchStatus IN
                      (N'ExactStopMatch', N'ParentStationFallback')
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS UsableMatchCount,
        SUM(CASE WHEN NULLIF(LTRIM(RTRIM(match_view.EstimatedBay)), N'') IS NOT NULL
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS ObservationsWithEstimatedBayCount,
        SUM(CASE WHEN situation.ObservationKey IS NOT NULL
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS ObservationsWithSituationEvidenceCount,
        SUM(ISNULL(situation.SituationLinkCount, 0)) AS SituationLinkCount
    FROM wrk.vwCologneRealtimeTripMatch AS match_view
    LEFT JOIN SituationByObservation AS situation
        ON situation.ObservationKey = match_view.ObservationKey
    GROUP BY CONVERT(DATE, match_view.ObservedAtUtc)
),
RunByDate AS
(
    SELECT
        CONVERT(DATE, run.StartedAtUtc) AS CollectionDateUtc,
        COUNT_BIG(*) AS CollectorRunCount,
        SUM(CASE WHEN run.Status = 'Succeeded'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS SuccessfulCollectorRunCount,
        SUM(CASE WHEN run.Status = 'Failed'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS FailedCollectorRunCount,
        SUM(CASE WHEN run.Status = 'Started'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS IncompleteStartedRunCount,
        SUM(CASE WHEN run.Status = 'Succeeded'
                   AND run.SamplingMode = 'Automatic'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS SuccessfulAutomaticRunCount,
        COUNT(DISTINCT CASE WHEN run.Status = 'Succeeded'
                                  AND run.SamplingMode = 'Automatic'
                            THEN run.SamplingTargetId END)
            AS ParticipatingSamplingTargetCount
    FROM ctl.MddCollectorRun AS run
    GROUP BY CONVERT(DATE, run.StartedAtUtc)
),
OutcomeFirstDate AS
(
    SELECT
        CONVERT(DATE, outcome.FirstObservedAtUtc) AS CollectionDateUtc,
        COUNT_BIG(*) AS OperationalOutcomeFirstObservedCount,
        SUM(outcome.ObservationCount) AS OperationalOutcomeObservationCount
    FROM dw.FactOperationalStopOutcome AS outcome
    GROUP BY CONVERT(DATE, outcome.FirstObservedAtUtc)
),
AllDates AS
(
    SELECT CollectionDateUtc FROM SourceByDate
    UNION
    SELECT CollectionDateUtc FROM RunByDate
    UNION
    SELECT CollectionDateUtc FROM OutcomeFirstDate
)
SELECT
    all_dates.CollectionDateUtc,
    COALESCE(run_data.CollectorRunCount, 0) AS CollectorRunCount,
    COALESCE(run_data.SuccessfulCollectorRunCount, 0)
        AS SuccessfulCollectorRunCount,
    COALESCE(run_data.FailedCollectorRunCount, 0)
        AS FailedCollectorRunCount,
    COALESCE(run_data.IncompleteStartedRunCount, 0)
        AS IncompleteStartedRunCount,
    COALESCE(run_data.SuccessfulAutomaticRunCount, 0)
        AS SuccessfulAutomaticRunCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*)
                     FROM ctl.MddRealtimeSamplingTarget
                     WHERE IsEnabled = 1)) AS ConfiguredSamplingPanelTargetCount,
    COALESCE(run_data.ParticipatingSamplingTargetCount, 0)
        AS ParticipatingSamplingTargetCount,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(run_data.ParticipatingSamplingTargetCount, 0) * 1.0
        / NULLIF
          (
              (SELECT COUNT_BIG(*)
               FROM ctl.MddRealtimeSamplingTarget
               WHERE IsEnabled = 1),
              0
          )
    ) AS SamplingPanelParticipationRate,
    COALESCE(source_data.SourceObservationCount, 0)
        AS SourceObservationCount,
    COALESCE(source_data.SourceSnapshotCount, 0)
        AS SourceSnapshotCount,
    source_data.FirstSourceObservationAtUtc,
    source_data.LastSourceObservationAtUtc,
    COALESCE(match_data.MatchedViewObservationCount, 0)
        AS MatchedViewObservationCount,
    COALESCE(match_data.ExactStopMatchCount, 0)
        AS ExactStopMatchCount,
    COALESCE(match_data.ParentStationFallbackCount, 0)
        AS ParentStationFallbackCount,
    COALESCE(match_data.StaticCoverageMissingCount, 0)
        AS StaticCoverageMissingCount,
    COALESCE(match_data.UnresolvedCount, 0) AS UnresolvedCount,
    COALESCE(match_data.UsableMatchCount, 0) AS UsableMatchCount,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.ExactStopMatchCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS ExactStopMatchRate,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.ParentStationFallbackCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS ParentStationFallbackRate,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.StaticCoverageMissingCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS StaticCoverageMissingRate,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.UnresolvedCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS UnresolvedRate,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.UsableMatchCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS UsableMatchRate,
    COALESCE(match_data.ObservationsWithEstimatedBayCount, 0)
        AS ObservationsWithEstimatedBayCount,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.ObservationsWithEstimatedBayCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS EstimatedBayAvailabilityRate,
    COALESCE(match_data.ObservationsWithSituationEvidenceCount, 0)
        AS ObservationsWithSituationEvidenceCount,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(match_data.ObservationsWithSituationEvidenceCount, 0) * 1.0
        / NULLIF(match_data.MatchedViewObservationCount, 0)
    ) AS SituationEvidenceAvailabilityRate,
    COALESCE(match_data.SituationLinkCount, 0) AS SituationLinkCount,
    COALESCE(outcome_data.OperationalOutcomeFirstObservedCount, 0)
        AS OperationalOutcomeFirstObservedCount,
    COALESCE(outcome_data.OperationalOutcomeObservationCount, 0)
        AS OperationalOutcomeObservationCount,
    CONVERT
    (
        DECIMAL(10, 4),
        COALESCE(outcome_data.OperationalOutcomeObservationCount, 0) * 1.0
        / NULLIF(outcome_data.OperationalOutcomeFirstObservedCount, 0)
    ) AS ObservationsPerOperationalOutcome,
    N'Sampling panel only; not complete Cologne network coverage' AS CoverageScopeNote
FROM AllDates AS all_dates
LEFT JOIN SourceByDate AS source_data
    ON source_data.CollectionDateUtc = all_dates.CollectionDateUtc
LEFT JOIN MatchByDate AS match_data
    ON match_data.CollectionDateUtc = all_dates.CollectionDateUtc
LEFT JOIN RunByDate AS run_data
    ON run_data.CollectionDateUtc = all_dates.CollectionDateUtc
LEFT JOIN OutcomeFirstDate AS outcome_data
    ON outcome_data.CollectionDateUtc = all_dates.CollectionDateUtc;
GO

/* Consolidation-quality view at the dated operational-outcome grain. */
CREATE OR ALTER VIEW analytics.vwRealtimeOperationalConsolidationQuality
AS
SELECT
    outcome.ServiceDate,
    outcome.DateKey,
    COUNT_BIG(*) AS OperationalOutcomeCount,
    SUM(outcome.ObservationCount) AS UsableObservationCount,
    SUM(CASE WHEN outcome.ObservationCount > 1
             THEN outcome.ObservationCount - 1 ELSE 0 END)
        AS RepeatedObservationsConsolidated,
    CONVERT
    (
        DECIMAL(10, 4),
        SUM(outcome.ObservationCount) * 1.0 / NULLIF(COUNT_BIG(*), 0)
    ) AS ObservationsPerOperationalOutcome,
    SUM(CASE WHEN outcome.LatestObservedEstimatedArrivalUtc IS NOT NULL
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutcomesWithLatestObservedEstimatedArrival,
    SUM(CASE WHEN outcome.LatestObservedEstimatedBay IS NOT NULL
                  AND LTRIM(RTRIM(outcome.LatestObservedEstimatedBay)) <> N''
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutcomesWithLatestObservedEstimatedBay,
    SUM(CASE WHEN outcome.PlatformChangeEvidence = 'Changed'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS PlatformChangedEvidenceCount,
    SUM(CASE WHEN outcome.PlatformChangeEvidence = 'Unchanged'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS PlatformUnchangedEvidenceCount,
    SUM(CASE WHEN outcome.PlatformChangeEvidence = 'Unknown'
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS PlatformUnknownEvidenceCount,
    SUM(CASE WHEN outcome.HasSituationEvidence = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS SituationLinkedOutcomeCount,
    SUM(outcome.SituationLinkCount) AS SituationLinkCount
FROM dw.FactOperationalStopOutcome AS outcome
GROUP BY outcome.ServiceDate, outcome.DateKey;
GO

/* One row per dated operational stop outcome with dimension-friendly labels. */
CREATE OR ALTER VIEW analytics.vwRealtimeReliabilityOutcome
AS
SELECT
    outcome.OperationalStopOutcomeKey,
    outcome.DateKey,
    outcome.ServiceDate,
    outcome.ScheduledStopEventKey,
    outcome.TripKey,
    outcome.RouteKey,
    route.RouteId,
    route.RouteShortName AS Route,
    route.RouteShortName AS Line,
    route.RouteLongName,
    outcome.StopKey,
    stop.StopId,
    stop.StopName AS Stop,
    COALESCE(parent_stop.StopName, stop.StopName) AS Station,
    outcome.ModeKey,
    mode.ModeGroup,
    mode.ModeDetail AS Mode,
    outcome.ServiceKey,
    trip.TripHeadsign,
    outcome.MatchStatus,
    outcome.TimetabledArrivalUtc AS ScheduledArrivalUtc,
    CONVERT
    (
        DATETIME2(0),
        outcome.TimetabledArrivalUtc AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
    ) AS ScheduledArrival,
    outcome.LatestObservedEstimatedArrivalUtc
        AS LatestObservedEstimatedArrival,
    CONVERT
    (
        DATETIME2(0),
        outcome.LatestObservedEstimatedArrivalUtc AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
    ) AS LatestObservedEstimatedArrivalLocal,
    outcome.FirstObservedEstimatedDelayMinutes,
    outcome.FinalObservedEstimatedDelayMinutes,
    outcome.ObservationCount,
    outcome.FirstObservationKey,
    outcome.LastObservationKey,
    outcome.FirstObservedAtUtc,
    outcome.LastObservedAtUtc,
    outcome.PlannedBay,
    outcome.LatestObservedEstimatedBay,
    outcome.PlatformChangeEvidence,
    outcome.HasSituationEvidence,
    outcome.SituationLinkCount,
    outcome.RefreshedAtUtc,
    N'Estimated arrival / delay only; not confirmed physical arrival' AS DelaySemanticNote,
    N'Situation association is evidence, not confirmed causality' AS SituationSemanticNote
FROM dw.FactOperationalStopOutcome AS outcome
JOIN dw.FactScheduledTrip AS trip
    ON trip.TripKey = outcome.TripKey
JOIN dw.DimRoute AS route
    ON route.RouteKey = outcome.RouteKey
JOIN dw.DimStop AS stop
    ON stop.StopKey = outcome.StopKey
LEFT JOIN dw.DimStop AS parent_stop
    ON parent_stop.StopKey = stop.ParentStopKey
JOIN dw.DimMode AS mode
    ON mode.ModeKey = outcome.ModeKey;
GO

/*
    Performance rows support overall, date, route, stop, mode, and scheduled
    hour/time-of-day analysis.  Median and P95 are continuous observed
    estimated-delay statistics; no thresholded OnTimeRate is created.
*/
CREATE OR ALTER VIEW analytics.vwRealtimeReliabilityByDimension
AS
WITH Base AS
(
    SELECT
        outcome.OperationalStopOutcomeKey,
        outcome.ServiceDate,
        outcome.RouteKey,
        route.RouteShortName AS Route,
        outcome.StopKey,
        stop.StopName AS Stop,
        COALESCE(parent_stop.StopName, stop.StopName) AS Station,
        outcome.ModeKey,
        mode.ModeDetail AS Mode,
        DATEPART
        (
            HOUR,
            outcome.TimetabledArrivalUtc AT TIME ZONE 'UTC'
                AT TIME ZONE 'W. Europe Standard Time'
        ) AS ScheduledHourOfDay,
        outcome.FinalObservedEstimatedDelayMinutes AS ObservedEstimatedDelayMinutes,
        outcome.ObservationCount,
        outcome.HasSituationEvidence,
        outcome.PlatformChangeEvidence
    FROM dw.FactOperationalStopOutcome AS outcome
    JOIN dw.DimRoute AS route
        ON route.RouteKey = outcome.RouteKey
    JOIN dw.DimStop AS stop
        ON stop.StopKey = outcome.StopKey
    LEFT JOIN dw.DimStop AS parent_stop
        ON parent_stop.StopKey = stop.ParentStopKey
    JOIN dw.DimMode AS mode
        ON mode.ModeKey = outcome.ModeKey
),
DimensionRows AS
(
    SELECT
        N'Overall' AS DimensionType,
        N'ALL' AS DimensionKey,
        N'All matched observed services' AS DimensionLabel,
        base.*
    FROM Base AS base

    UNION ALL

    SELECT
        N'Date',
        CONVERT(NVARCHAR(30), base.ServiceDate, 112),
        CONVERT(NVARCHAR(30), base.ServiceDate, 23),
        base.*
    FROM Base AS base

    UNION ALL

    SELECT
        N'Route',
        CONVERT(NVARCHAR(30), base.RouteKey),
        COALESCE(base.Route, N'(unnamed route)'),
        base.*
    FROM Base AS base

    UNION ALL

    SELECT
        N'Stop',
        CONVERT(NVARCHAR(30), base.StopKey),
        COALESCE(base.Stop, N'(unnamed stop)'),
        base.*
    FROM Base AS base

    UNION ALL

    SELECT
        N'Mode',
        CONVERT(NVARCHAR(30), base.ModeKey),
        COALESCE(base.Mode, N'(unnamed mode)'),
        base.*
    FROM Base AS base

    UNION ALL

    SELECT
        N'Hour',
        CONVERT(NVARCHAR(30), base.ScheduledHourOfDay),
        CONCAT(N'Hour ', RIGHT(CONCAT(N'0', base.ScheduledHourOfDay), 2)),
        base.*
    FROM Base AS base
),
Aggregated AS
(
    SELECT
        dimension.DimensionType,
        dimension.DimensionKey,
        MAX(dimension.DimensionLabel) AS DimensionLabel,
        COUNT_BIG(*) AS ObservedMatchedServiceCount,
        SUM(CASE WHEN dimension.ObservedEstimatedDelayMinutes IS NOT NULL
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS DelayObservationCount,
        AVG(dimension.ObservedEstimatedDelayMinutes)
            AS AverageObservedEstimatedDelayMinutes,
        MIN(dimension.ObservedEstimatedDelayMinutes)
            AS MinimumObservedEstimatedDelayMinutes,
        MAX(dimension.ObservedEstimatedDelayMinutes)
            AS MaximumObservedEstimatedDelayMinutes,
        AVG(CONVERT(DECIMAL(18, 4), dimension.ObservationCount))
            AS AverageObservationsPerOutcome,
        SUM(CASE WHEN dimension.HasSituationEvidence = 1
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS SituationLinkedOutcomeCount,
        SUM(CASE WHEN dimension.PlatformChangeEvidence = 'Changed'
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS PlatformChangedEvidenceCount
    FROM DimensionRows AS dimension
    GROUP BY dimension.DimensionType, dimension.DimensionKey
),
Percentiles AS
(
    SELECT DISTINCT
        dimension.DimensionType,
        dimension.DimensionKey,
        CONVERT
        (
            DECIMAL(10, 2),
            PERCENTILE_CONT(0.50) WITHIN GROUP
            (
                ORDER BY dimension.ObservedEstimatedDelayMinutes
            ) OVER
            (
                PARTITION BY dimension.DimensionType, dimension.DimensionKey
            )
        ) AS MedianObservedEstimatedDelayMinutes,
        CONVERT
        (
            DECIMAL(10, 2),
            PERCENTILE_CONT(0.95) WITHIN GROUP
            (
                ORDER BY dimension.ObservedEstimatedDelayMinutes
            ) OVER
            (
                PARTITION BY dimension.DimensionType, dimension.DimensionKey
            )
        ) AS P95ObservedEstimatedDelayMinutes
    FROM DimensionRows AS dimension
)
SELECT
    aggregated.DimensionType,
    aggregated.DimensionKey,
    aggregated.DimensionLabel,
    aggregated.ObservedMatchedServiceCount,
    aggregated.DelayObservationCount,
    CONVERT(DECIMAL(10, 2), aggregated.AverageObservedEstimatedDelayMinutes)
        AS AverageObservedEstimatedDelayMinutes,
    aggregated.MinimumObservedEstimatedDelayMinutes,
    aggregated.MaximumObservedEstimatedDelayMinutes,
    percentiles.MedianObservedEstimatedDelayMinutes,
    percentiles.P95ObservedEstimatedDelayMinutes,
    aggregated.AverageObservationsPerOutcome,
    aggregated.SituationLinkedOutcomeCount,
    aggregated.PlatformChangedEvidenceCount,
    N'Observed estimated delay; no approved on-time threshold is applied'
        AS ThresholdSemanticNote
FROM Aggregated AS aggregated
JOIN Percentiles AS percentiles
    ON percentiles.DimensionType = aggregated.DimensionType
   AND percentiles.DimensionKey = aggregated.DimensionKey;
GO

/* Direct hotspot-consumer view; ranking/filtering remains a reporting choice. */
CREATE OR ALTER VIEW analytics.vwRealtimeDelayHotspot
AS
SELECT
    performance.DimensionType,
    performance.DimensionKey,
    performance.DimensionLabel,
    performance.ObservedMatchedServiceCount,
    performance.DelayObservationCount,
    performance.AverageObservedEstimatedDelayMinutes,
    performance.MedianObservedEstimatedDelayMinutes,
    performance.P95ObservedEstimatedDelayMinutes,
    performance.SituationLinkedOutcomeCount,
    performance.PlatformChangedEvidenceCount,
    N'Hotspot candidate; rank using continuous observed estimated-delay metrics'
        AS HotspotSemanticNote
FROM analytics.vwRealtimeReliabilityByDimension AS performance
WHERE performance.DimensionType IN (N'Route', N'Stop')
  AND performance.DelayObservationCount > 0;
GO

/* Platform evidence by dated route/stop outcome, without forcing NULL to zero. */
CREATE OR ALTER VIEW analytics.vwRealtimePlatformChangeEvidence
AS
SELECT
    outcome.ServiceDate,
    outcome.DateKey,
    outcome.RouteKey,
    route.RouteShortName AS Route,
    outcome.StopKey,
    stop.StopName AS Stop,
    outcome.ModeKey,
    mode.ModeDetail AS Mode,
    outcome.PlatformChangeEvidence,
    COUNT_BIG(*) AS OperationalOutcomeCount,
    SUM(outcome.ObservationCount) AS UsableObservationCount,
    SUM(CASE WHEN outcome.HasSituationEvidence = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS SituationLinkedOutcomeCount
FROM dw.FactOperationalStopOutcome AS outcome
JOIN dw.DimRoute AS route
    ON route.RouteKey = outcome.RouteKey
JOIN dw.DimStop AS stop
    ON stop.StopKey = outcome.StopKey
JOIN dw.DimMode AS mode
    ON mode.ModeKey = outcome.ModeKey
GROUP BY
    outcome.ServiceDate,
    outcome.DateKey,
    outcome.RouteKey,
    route.RouteShortName,
    outcome.StopKey,
    stop.StopName,
    outcome.ModeKey,
    mode.ModeDetail,
    outcome.PlatformChangeEvidence;
GO

/* Situation-linked outcomes remain evidence rows, not causal findings. */
CREATE OR ALTER VIEW analytics.vwRealtimeSituationLinkedOutcome
AS
SELECT
    reliability.*
FROM analytics.vwRealtimeReliabilityOutcome AS reliability
WHERE reliability.HasSituationEvidence = 1;
GO
