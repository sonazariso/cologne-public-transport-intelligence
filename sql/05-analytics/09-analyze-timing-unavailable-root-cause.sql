USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    Read-only Timing Unavailable root-cause analysis.

    Execution contract:
      1. Run dw.uspRefreshFactOperationalStopOutcome once, explicitly,
         before starting this script.
      2. Run this script in one SQL Server session.
      3. The management-comparable population is frozen immediately into
         #FrozenComparableTrip at ServiceDate + TripKey grain. Every later
         diagnostic in this batch uses that dated-trip population.

    This script deliberately contains only SELECT statements, CTEs,
    session-scoped temporary tables, and temporary indexes. It does not
    refresh the warehouse, create permanent objects, or change production
    semantics.

    Timing semantics remain the existing semantics:
      - EstimatedArrivalUtc is an observed estimate, not actual arrival;
      - FinalObservedEstimatedDelayMinutes is the latest observed estimate's
        delay, not confirmed physical delay;
      - NULL EstimatedArrivalUtc remains unknown/unavailable.
*/

DECLARE @AnalysisExecutionAtUtc DATETIME2(0) = CONVERT(DATETIME2(0), SYSUTCDATETIME());
DECLARE @FrozenMaxObservationKey BIGINT =
(
    SELECT MAX(LastObservationKey)
    FROM dw.FactOperationalStopOutcome
);
DECLARE @FactRefreshMaxUtc DATETIME2(0) =
(
    SELECT MAX(RefreshedAtUtc)
    FROM dw.FactOperationalStopOutcome
);

/* 1. Active-panel gate.  This must remain the existing seven-target panel. */
;WITH EnabledSlotCounts AS
(
    SELECT
        target.SamplingTargetId,
        COUNT_BIG(slot.SamplingSlot) AS ConfiguredSlotCount,
        SUM(COUNT_BIG(slot.SamplingSlot)) OVER () AS EnabledSlotCount
    FROM ctl.MddRealtimeSamplingTarget AS target
    LEFT JOIN ctl.MddRealtimeSamplingSlot AS slot
        ON slot.SamplingTargetId = target.SamplingTargetId
    WHERE target.IsEnabled = 1
    GROUP BY target.SamplingTargetId
)
SELECT
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget)) AS ConfiguredTargetCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget WHERE IsEnabled = 1)) AS EnabledSamplingTargetCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(DISTINCT target.StopPointRef)
                     FROM ctl.MddRealtimeSamplingTarget AS target
                     WHERE target.IsEnabled = 1
                       AND target.StopPointRef IS NOT NULL)) AS EnabledDistinctStopPointRefCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingSlot)) AS ConfiguredSlotCount,
    CONVERT(BIGINT, (SELECT COUNT_BIG(*)
                     FROM ctl.MddRealtimeSamplingSlot AS slot
                     JOIN ctl.MddRealtimeSamplingTarget AS target
                       ON target.SamplingTargetId = slot.SamplingTargetId
                     WHERE target.IsEnabled = 1)) AS EnabledSlotCount,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget) = 7
         AND (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget WHERE IsEnabled = 1) = 7
         AND (SELECT COUNT_BIG(DISTINCT target.StopPointRef)
              FROM ctl.MddRealtimeSamplingTarget AS target
              WHERE target.IsEnabled = 1
                AND target.StopPointRef IS NOT NULL) = 7
            THEN N'PASS'
        ELSE N'STOP/REVIEW'
    END AS ActiveSevenStationPanelStatus,
    N'Approved 50-station panel remains planning-only; seven enabled target rows are active.'
        AS PanelInterpretation;

/* 2. Freeze the current management population at ServiceDate + TripKey. */
SELECT
    comparable.ManagementTripKey,
    comparable.DateKey,
    comparable.ServiceDate,
    comparable.TripKey,
    comparable.RouteKey,
    comparable.ModeKey,
    comparable.RouteName,
    comparable.Route,
    comparable.Mode,
    comparable.Station AS ParentStation,
    comparable.StopKey,
    comparable.ScheduledArrival,
    comparable.LatestObservedEstimatedArrivalLocal,
    comparable.FinalObservedEstimatedDelayMinutes,
    comparable.LastObservedAtUtc,
    comparable.OperationalStopOutcomeKey,
    comparable.HasValidRealtimeObservation
INTO #FrozenComparableTrip
FROM analytics.vwManagementComparableTrip AS comparable;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenComparableTrip_Date_Trip
    ON #FrozenComparableTrip (ServiceDate, TripKey);

SELECT *
INTO #FrozenTimingUnavailableTrip
FROM #FrozenComparableTrip
WHERE HasValidRealtimeObservation = 0;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenTimingUnavailableTrip_Date_Trip
    ON #FrozenTimingUnavailableTrip (ServiceDate, TripKey);

/* 3. Freeze every operational outcome belonging to the frozen dated trips. */
SELECT
    reliability.OperationalStopOutcomeKey,
    reliability.DateKey,
    reliability.ServiceDate,
    reliability.ScheduledStopEventKey,
    reliability.TripKey,
    reliability.RouteKey,
    reliability.RouteId,
    reliability.RouteName,
    reliability.Route,
    reliability.RouteLongName,
    reliability.StopKey,
    reliability.StopId,
    reliability.Stop AS StopName,
    reliability.Station AS ParentStation,
    reliability.ModeKey,
    reliability.ModeGroup,
    reliability.Mode,
    reliability.ServiceKey,
    reliability.MatchStatus,
    reliability.ScheduledArrivalUtc,
    reliability.ScheduledArrival,
    reliability.LatestObservedEstimatedArrival,
    reliability.LatestObservedEstimatedArrivalLocal,
    reliability.FirstObservedEstimatedDelayMinutes,
    reliability.FinalObservedEstimatedDelayMinutes,
    reliability.ObservationCount,
    reliability.FirstObservationKey,
    reliability.LastObservationKey,
    reliability.FirstObservedAtUtc,
    reliability.LastObservedAtUtc,
    reliability.PlannedBay,
    reliability.LatestObservedEstimatedBay,
    reliability.PlatformChangeEvidence,
    reliability.HasSituationEvidence,
    reliability.SituationLinkCount,
    reliability.RefreshedAtUtc
INTO #FrozenOutcome
FROM analytics.vwRealtimeReliabilityOutcome AS reliability
JOIN #FrozenComparableTrip AS comparable
  ON comparable.ServiceDate = reliability.ServiceDate
 AND comparable.TripKey = reliability.TripKey;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenOutcome_Key
    ON #FrozenOutcome (OperationalStopOutcomeKey);

CREATE INDEX IX_FrozenOutcome_Date_Trip
    ON #FrozenOutcome (ServiceDate, TripKey, ScheduledStopEventKey);

CREATE INDEX IX_FrozenOutcome_Observation
    ON #FrozenOutcome (FirstObservationKey, LastObservationKey);

/* 4. Read-only fact/freeze reconciliation and live-tail visibility. */
SELECT
    @AnalysisExecutionAtUtc AS AnalysisExecutionAtUtc,
    @FactRefreshMaxUtc AS FactRefreshMaxUtc,
    @FrozenMaxObservationKey AS FrozenMaxObservationKey,
    (SELECT COUNT_BIG(*) FROM #FrozenComparableTrip) AS FrozenComparableTripCount,
    (SELECT COUNT_BIG(*) FROM #FrozenComparableTrip WHERE HasValidRealtimeObservation = 1) AS FrozenUsableTimingTripCount,
    (SELECT COUNT_BIG(*) FROM #FrozenTimingUnavailableTrip) AS FrozenTimingUnavailableTripCount,
    CONVERT
    (
        DECIMAL(18, 8),
        CONVERT(DECIMAL(28, 8), (SELECT COUNT_BIG(*) FROM #FrozenTimingUnavailableTrip))
        / NULLIF((SELECT COUNT_BIG(*) FROM #FrozenComparableTrip), 0)
    ) AS FrozenTimingUnavailableRate,
    (SELECT COUNT_BIG(*) FROM #FrozenOutcome) AS FrozenOperationalStopOutcomeCount,
    (SELECT COALESCE(SUM(ObservationCount), 0) FROM #FrozenOutcome) AS FrozenFactObservationCount,
    (SELECT COUNT_BIG(*) FROM dw.FactOperationalStopOutcome) AS CurrentFactOperationalStopOutcomeCount,
    (SELECT COALESCE(SUM(ObservationCount), 0) FROM dw.FactOperationalStopOutcome) AS CurrentFactObservationCount,
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation) AS CurrentSourceObservationCount,
    (SELECT COUNT_BIG(*)
     FROM stg.MddRealtimeStopObservation
     WHERE ObservationKey > @FrozenMaxObservationKey) AS LiveTailObservationCount,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #FrozenComparableTrip)
             = (SELECT COUNT_BIG(*) FROM #FrozenComparableTrip WHERE HasValidRealtimeObservation = 1)
             + (SELECT COUNT_BIG(*) FROM #FrozenTimingUnavailableTrip)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS FrozenTripReconciliationStatus,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #FrozenOutcome)
             = (SELECT COUNT_BIG(*) FROM dw.FactOperationalStopOutcome AS fact
                JOIN #FrozenComparableTrip AS comparable
                  ON comparable.ServiceDate = fact.ServiceDate
                 AND comparable.TripKey = fact.TripKey)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS FrozenFactReconciliationStatus,
    N'Rows with ObservationKey above FrozenMaxObservationKey are excluded as a live tail created after the controlled refresh.'
        AS LiveTailTreatment;

/* 5. Materialize the current matched source rows once, bounded by the freeze. */
SELECT
    match_view.ObservationKey,
    match_view.ObservedAtUtc,
    match_view.ResultId,
    match_view.StopPointRef,
    match_view.StopName,
    match_view.LineName,
    match_view.LineRef,
    match_view.JourneyRef,
    match_view.DirectionRef,
    match_view.OperatorRef,
    match_view.PtMode,
    match_view.RailSubmode,
    match_view.TimetabledArrivalUtc,
    match_view.EstimatedArrivalUtc,
    match_view.ArrivalDelayMinutes,
    match_view.PlannedBay,
    match_view.EstimatedBay,
    match_view.CreatedAtUtc,
    match_view.MatchStatus,
    match_view.ScheduledStopEventKey,
    match_view.TripKey,
    match_view.RouteKey,
    match_view.StopKey,
    match_view.ModeKey,
    match_view.ServiceKey,
    match_view.DateKey,
    match_view.ServiceDate
INTO #FrozenMatchedObservation
FROM wrk.vwCologneRealtimeTripMatch AS match_view
JOIN #FrozenOutcome AS outcome
  ON outcome.DateKey = match_view.DateKey
 AND outcome.ScheduledStopEventKey = match_view.ScheduledStopEventKey
 AND outcome.TripKey = match_view.TripKey
WHERE match_view.MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')
  AND match_view.ObservationKey <= @FrozenMaxObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenMatchedObservation_Key
    ON #FrozenMatchedObservation (ObservationKey);

CREATE INDEX IX_FrozenMatchedObservation_Date_Trip
    ON #FrozenMatchedObservation (DateKey, ServiceDate, TripKey, ObservedAtUtc, ObservationKey);

CREATE INDEX IX_FrozenMatchedObservation_Outcome
    ON #FrozenMatchedObservation (DateKey, ScheduledStopEventKey, ObservedAtUtc, ObservationKey);

/* 6. Stored source-field inventory for every observation in frozen Timing Unavailable trips. */
SELECT
    matched.*
INTO #FrozenUnavailableObservation
FROM #FrozenMatchedObservation AS matched
JOIN #FrozenTimingUnavailableTrip AS unavailable
  ON unavailable.ServiceDate = matched.ServiceDate
 AND unavailable.TripKey = matched.TripKey;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenUnavailableObservation_Key
    ON #FrozenUnavailableObservation (ObservationKey);

SELECT
    field_inventory.FieldName,
    field_inventory.TotalRowCount,
    field_inventory.NonNullCount,
    field_inventory.NullCount,
    field_inventory.DistinctCount
FROM
(
    SELECT N'ObservationKey' AS FieldName, COUNT_BIG(*) AS TotalRowCount, COUNT_BIG(ObservationKey) AS NonNullCount, COUNT_BIG(*) - COUNT_BIG(ObservationKey) AS NullCount, COUNT_BIG(DISTINCT ObservationKey) AS DistinctCount FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'ObservedAtUtc', COUNT_BIG(*), COUNT_BIG(ObservedAtUtc), COUNT_BIG(*) - COUNT_BIG(ObservedAtUtc), COUNT_BIG(DISTINCT ObservedAtUtc) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'ResultId', COUNT_BIG(*), COUNT_BIG(ResultId), COUNT_BIG(*) - COUNT_BIG(ResultId), COUNT_BIG(DISTINCT ResultId) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'StopPointRef', COUNT_BIG(*), COUNT_BIG(StopPointRef), COUNT_BIG(*) - COUNT_BIG(StopPointRef), COUNT_BIG(DISTINCT StopPointRef) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'StopName', COUNT_BIG(*), COUNT_BIG(StopName), COUNT_BIG(*) - COUNT_BIG(StopName), COUNT_BIG(DISTINCT StopName) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'LineName', COUNT_BIG(*), COUNT_BIG(LineName), COUNT_BIG(*) - COUNT_BIG(LineName), COUNT_BIG(DISTINCT LineName) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'LineRef', COUNT_BIG(*), COUNT_BIG(LineRef), COUNT_BIG(*) - COUNT_BIG(LineRef), COUNT_BIG(DISTINCT LineRef) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'JourneyRef', COUNT_BIG(*), COUNT_BIG(JourneyRef), COUNT_BIG(*) - COUNT_BIG(JourneyRef), COUNT_BIG(DISTINCT JourneyRef) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'DirectionRef', COUNT_BIG(*), COUNT_BIG(DirectionRef), COUNT_BIG(*) - COUNT_BIG(DirectionRef), COUNT_BIG(DISTINCT DirectionRef) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'OperatorRef', COUNT_BIG(*), COUNT_BIG(OperatorRef), COUNT_BIG(*) - COUNT_BIG(OperatorRef), COUNT_BIG(DISTINCT OperatorRef) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'PtMode', COUNT_BIG(*), COUNT_BIG(PtMode), COUNT_BIG(*) - COUNT_BIG(PtMode), COUNT_BIG(DISTINCT PtMode) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'RailSubmode', COUNT_BIG(*), COUNT_BIG(RailSubmode), COUNT_BIG(*) - COUNT_BIG(RailSubmode), COUNT_BIG(DISTINCT RailSubmode) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'TimetabledArrivalUtc', COUNT_BIG(*), COUNT_BIG(TimetabledArrivalUtc), COUNT_BIG(*) - COUNT_BIG(TimetabledArrivalUtc), COUNT_BIG(DISTINCT TimetabledArrivalUtc) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'EstimatedArrivalUtc', COUNT_BIG(*), COUNT_BIG(EstimatedArrivalUtc), COUNT_BIG(*) - COUNT_BIG(EstimatedArrivalUtc), COUNT_BIG(DISTINCT EstimatedArrivalUtc) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'PlannedBay', COUNT_BIG(*), COUNT_BIG(PlannedBay), COUNT_BIG(*) - COUNT_BIG(PlannedBay), COUNT_BIG(DISTINCT PlannedBay) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'EstimatedBay', COUNT_BIG(*), COUNT_BIG(EstimatedBay), COUNT_BIG(*) - COUNT_BIG(EstimatedBay), COUNT_BIG(DISTINCT EstimatedBay) FROM #FrozenUnavailableObservation
    UNION ALL SELECT N'CreatedAtUtc', COUNT_BIG(*), COUNT_BIG(CreatedAtUtc), COUNT_BIG(*) - COUNT_BIG(CreatedAtUtc), COUNT_BIG(DISTINCT CreatedAtUtc) FROM #FrozenUnavailableObservation
) AS field_inventory
ORDER BY field_inventory.FieldName;

/* 7. Full trip-level timing lineage and observation lead times. */
SELECT
    comparable.ServiceDate,
    comparable.TripKey,
    comparable.RouteName,
    comparable.Route,
    comparable.Mode,
    comparable.ParentStation,
    comparable.ScheduledArrival,
    comparable.HasValidRealtimeObservation,
    COUNT_BIG(matched.ObservationKey) AS MatchedObservationCount,
    SUM(CASE WHEN matched.EstimatedArrivalUtc IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS MatchedObservationWithEstimateCount,
    first_observation.ObservedAtUtc AS FirstObservedAtUtc,
    last_observation.ObservedAtUtc AS LastObservedAtUtc,
    CONVERT(DECIMAL(18, 4), DATEDIFF_BIG(SECOND, first_observation.ObservedAtUtc, first_observation.TimetabledArrivalUtc) / 60.0) AS FirstObservationLeadMinutes,
    CONVERT(DECIMAL(18, 4), DATEDIFF_BIG(SECOND, last_observation.ObservedAtUtc, last_observation.TimetabledArrivalUtc) / 60.0) AS LastObservationLeadMinutes,
    closest_observation.ObservedAtUtc AS ClosestObservationAtUtc,
    CONVERT(DECIMAL(18, 4), DATEDIFF_BIG(SECOND, closest_observation.ObservedAtUtc, closest_observation.TimetabledArrivalUtc) / 60.0) AS ClosestObservationToScheduledArrivalMinutes,
    CONVERT(DECIMAL(18, 4), ABS(DATEDIFF_BIG(SECOND, closest_observation.ObservedAtUtc, closest_observation.TimetabledArrivalUtc)) / 60.0) AS ClosestObservationAbsoluteLeadMinutes
INTO #TripTiming
FROM #FrozenComparableTrip AS comparable
LEFT JOIN #FrozenMatchedObservation AS matched
  ON matched.ServiceDate = comparable.ServiceDate
 AND matched.TripKey = comparable.TripKey
OUTER APPLY
(
    SELECT TOP (1)
        first_row.ObservedAtUtc,
        first_row.TimetabledArrivalUtc
    FROM #FrozenMatchedObservation AS first_row
    WHERE first_row.ServiceDate = comparable.ServiceDate
      AND first_row.TripKey = comparable.TripKey
      AND first_row.TimetabledArrivalUtc IS NOT NULL
    ORDER BY first_row.ObservedAtUtc, first_row.ObservationKey
) AS first_observation
OUTER APPLY
(
    SELECT TOP (1)
        last_row.ObservedAtUtc,
        last_row.TimetabledArrivalUtc
    FROM #FrozenMatchedObservation AS last_row
    WHERE last_row.ServiceDate = comparable.ServiceDate
      AND last_row.TripKey = comparable.TripKey
      AND last_row.TimetabledArrivalUtc IS NOT NULL
    ORDER BY last_row.ObservedAtUtc DESC, last_row.ObservationKey DESC
) AS last_observation
OUTER APPLY
(
    SELECT TOP (1)
        closest_row.ObservedAtUtc,
        closest_row.TimetabledArrivalUtc
    FROM #FrozenMatchedObservation AS closest_row
    WHERE closest_row.ServiceDate = comparable.ServiceDate
      AND closest_row.TripKey = comparable.TripKey
      AND closest_row.TimetabledArrivalUtc IS NOT NULL
    ORDER BY ABS(DATEDIFF_BIG(SECOND, closest_row.ObservedAtUtc, closest_row.TimetabledArrivalUtc)),
             closest_row.ObservedAtUtc DESC,
             closest_row.ObservationKey DESC
) AS closest_observation
GROUP BY
    comparable.ServiceDate,
    comparable.TripKey,
    comparable.RouteName,
    comparable.Route,
    comparable.Mode,
    comparable.ParentStation,
    comparable.ScheduledArrival,
    comparable.HasValidRealtimeObservation,
    first_observation.ObservedAtUtc,
    first_observation.TimetabledArrivalUtc,
    last_observation.ObservedAtUtc,
    last_observation.TimetabledArrivalUtc,
    closest_observation.ObservedAtUtc,
    closest_observation.TimetabledArrivalUtc;

CREATE UNIQUE CLUSTERED INDEX UX_TripTiming_Date_Trip
    ON #TripTiming (ServiceDate, TripKey);

SELECT
    matched.ObservationKey,
    matched.ServiceDate,
    matched.TripKey,
    CASE WHEN timing.HasValidRealtimeObservation = 1 THEN N'UsableTiming' ELSE N'TimingUnavailable' END AS TimingStatus,
    timing.HasValidRealtimeObservation,
    matched.ObservedAtUtc,
    matched.TimetabledArrivalUtc,
    matched.EstimatedArrivalUtc,
    CONVERT(DECIMAL(18, 4), DATEDIFF_BIG(SECOND, matched.ObservedAtUtc, matched.TimetabledArrivalUtc) / 60.0) AS ArrivalLeadMinutes
INTO #FrozenObservationLead
FROM #FrozenMatchedObservation AS matched
JOIN #TripTiming AS timing
  ON timing.ServiceDate = matched.ServiceDate
 AND timing.TripKey = matched.TripKey
WHERE matched.ObservedAtUtc IS NOT NULL
  AND matched.TimetabledArrivalUtc IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenObservationLead_Key
    ON #FrozenObservationLead (ObservationKey);

SELECT
    lead.ObservationKey,
    lead.ServiceDate,
    lead.TripKey,
    lead.TimingStatus,
    lead.ObservedAtUtc,
    lead.TimetabledArrivalUtc,
    lead.EstimatedArrivalUtc,
    lead.ArrivalLeadMinutes
FROM #FrozenObservationLead AS lead
ORDER BY lead.ServiceDate, lead.TripKey, lead.ObservedAtUtc, lead.ObservationKey;

/* Per-dated-trip lead fields are retained for review; bins below are
   observation-level diagnostics and are not KPI thresholds. */
SELECT
    timing.ServiceDate,
    timing.TripKey,
    timing.RouteName,
    timing.Route,
    timing.Mode,
    timing.ParentStation,
    timing.ScheduledArrival,
    CASE WHEN timing.HasValidRealtimeObservation = 1 THEN N'UsableTiming' ELSE N'TimingUnavailable' END AS TimingStatus,
    timing.MatchedObservationCount,
    timing.MatchedObservationWithEstimateCount,
    timing.FirstObservedAtUtc,
    timing.FirstObservationLeadMinutes,
    timing.LastObservedAtUtc,
    timing.LastObservationLeadMinutes,
    timing.ClosestObservationAtUtc,
    timing.ClosestObservationToScheduledArrivalMinutes,
    timing.ClosestObservationAbsoluteLeadMinutes
FROM #TripTiming AS timing
ORDER BY timing.ServiceDate, timing.TripKey;

/* Overall reconciliation and historical evidence are intentionally separate. */
SELECT
    N'HistoricalTimingUnavailableSnapshot' AS SnapshotName,
    CONVERT(BIGINT, 2822) AS ComparableScheduledTrips,
    CONVERT(BIGINT, 2440) AS TripsWithUsableRealtimeTiming,
    CONVERT(BIGINT, 382) AS TimingUnavailableTrips,
    CONVERT(DECIMAL(18, 8), 382.0 / 2822.0) AS TimingUnavailableRate,
    N'Historical M01 evidence: 380 / 2 / 0' AS RootCauseEvidence
UNION ALL
SELECT
    N'HistoricalTimingUnavailableSnapshot_AlignedSevenStation', 5127, 4239, 888,
    CONVERT(DECIMAL(18, 8), 888.0 / 5127.0),
    N'Historical aligned evidence: 886 / 2 / 0'
UNION ALL
SELECT
    N'CurrentFrozenTimingUnavailableSnapshot',
    COUNT_BIG(*),
    SUM(CASE WHEN HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    SUM(CASE WHEN HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    CONVERT(DECIMAL(18, 8), SUM(CONVERT(DECIMAL(28, 8), CASE WHEN HasValidRealtimeObservation = 0 THEN 1 ELSE 0 END)) / NULLIF(COUNT_BIG(*), 0)),
    N'Current primary distribution is returned below from the frozen dated-trip population.'
FROM #FrozenComparableTrip;

SELECT
    COUNT_BIG(*) AS FrozenComparableTripCount,
    SUM(CASE WHEN HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS FrozenUsableTimingTripCount,
    SUM(CASE WHEN HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS FrozenTimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CONVERT(DECIMAL(28, 8), CASE WHEN HasValidRealtimeObservation = 0 THEN 1 ELSE 0 END)) / NULLIF(COUNT_BIG(*), 0)) AS FrozenTimingUnavailableRate,
    CASE
        WHEN COUNT_BIG(*) = SUM(CASE WHEN HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
                           + SUM(CASE WHEN HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            THEN N'PASS' ELSE N'REVIEW'
    END AS FrozenTripReconciliationStatus,
    MIN(ServiceDate) AS FrozenServiceDateMin,
    MAX(ServiceDate) AS FrozenServiceDateMax
FROM #FrozenComparableTrip;

/* Lead-time distributions use diagnostic bins only; they are not KPI thresholds. */
WITH Bins AS
(
    SELECT N'after scheduled arrival' AS LeadTimeBin, 1 AS SortOrder
    UNION ALL SELECT N'0-5 minutes before', 2
    UNION ALL SELECT N'5-10 minutes before', 3
    UNION ALL SELECT N'10-20 minutes before', 4
    UNION ALL SELECT N'20-30 minutes before', 5
    UNION ALL SELECT N'30-60 minutes before', 6
    UNION ALL SELECT N'more than 60 minutes before', 7
), Binned AS
(
    SELECT
        CASE
            WHEN observation.ArrivalLeadMinutes < 0 THEN N'after scheduled arrival'
            WHEN observation.ArrivalLeadMinutes < 5 THEN N'0-5 minutes before'
            WHEN observation.ArrivalLeadMinutes < 10 THEN N'5-10 minutes before'
            WHEN observation.ArrivalLeadMinutes < 20 THEN N'10-20 minutes before'
            WHEN observation.ArrivalLeadMinutes < 30 THEN N'20-30 minutes before'
            WHEN observation.ArrivalLeadMinutes < 60 THEN N'30-60 minutes before'
            ELSE N'more than 60 minutes before'
        END AS LeadTimeBin,
        observation.TimingStatus,
        observation.ObservationKey,
        observation.EstimatedArrivalUtc
    FROM #FrozenObservationLead AS observation
), Statuses AS
(
    SELECT DISTINCT observation.TimingStatus
    FROM #FrozenObservationLead AS observation
), Grouped AS
(
    SELECT
        statuses.TimingStatus,
        bins.SortOrder,
        bins.LeadTimeBin,
        COUNT_BIG(binned.ObservationKey) AS ObservationCount,
        COALESCE(SUM(CASE WHEN binned.EstimatedArrivalUtc IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END), CONVERT(BIGINT, 0)) AS ObservationWithEstimateCount
    FROM Statuses AS statuses
    CROSS JOIN Bins AS bins
    LEFT JOIN Binned AS binned
      ON binned.TimingStatus = statuses.TimingStatus
     AND binned.LeadTimeBin = bins.LeadTimeBin
    GROUP BY statuses.TimingStatus, bins.SortOrder, bins.LeadTimeBin
)
SELECT
    grouped.TimingStatus,
    grouped.LeadTimeBin,
    grouped.ObservationCount,
    grouped.ObservationWithEstimateCount,
    CONVERT(DECIMAL(18, 8), grouped.ObservationCount / NULLIF(CONVERT(DECIMAL(28, 8), SUM(grouped.ObservationCount) OVER (PARTITION BY grouped.TimingStatus)), 0)) AS PercentageWithinTimingStatus
FROM Grouped AS grouped
ORDER BY grouped.TimingStatus, grouped.SortOrder;

SELECT
    timing.HasValidRealtimeObservation,
    CASE WHEN timing.HasValidRealtimeObservation = 1 THEN N'UsableTiming' ELSE N'TimingUnavailable' END AS TimingStatus,
    COUNT_BIG(*) AS DatedTripCount,
    AVG(timing.MatchedObservationCount * 1.0) AS AverageMatchedObservationCount,
    MIN(timing.MatchedObservationCount) AS MinimumMatchedObservationCount,
    MAX(timing.MatchedObservationCount) AS MaximumMatchedObservationCount,
    AVG(timing.FirstObservationLeadMinutes) AS AverageFirstObservationLeadMinutes,
    AVG(timing.LastObservationLeadMinutes) AS AverageLastObservationLeadMinutes,
    AVG(timing.ClosestObservationAbsoluteLeadMinutes) AS AverageClosestAbsoluteLeadMinutes,
    MIN(timing.ClosestObservationAbsoluteLeadMinutes) AS MinimumClosestAbsoluteLeadMinutes,
    MAX(timing.ClosestObservationAbsoluteLeadMinutes) AS MaximumClosestAbsoluteLeadMinutes
FROM #TripTiming AS timing
GROUP BY timing.HasValidRealtimeObservation
ORDER BY timing.HasValidRealtimeObservation DESC;

SELECT
    CASE WHEN timing.HasValidRealtimeObservation = 1 THEN N'UsableTiming' ELSE N'TimingUnavailable' END AS TimingStatus,
    timing.MatchedObservationCount,
    COUNT_BIG(*) AS DatedTripCount,
    AVG(timing.LastObservationLeadMinutes) AS AverageLastObservationLeadMinutes,
    AVG(timing.ClosestObservationAbsoluteLeadMinutes) AS AverageClosestAbsoluteLeadMinutes
FROM #TripTiming AS timing
GROUP BY timing.HasValidRealtimeObservation, timing.MatchedObservationCount
ORDER BY timing.HasValidRealtimeObservation DESC, timing.MatchedObservationCount;

SELECT
    CASE WHEN timing.HasValidRealtimeObservation = 1 THEN N'UsableTiming' ELSE N'TimingUnavailable' END AS TimingStatus,
    COUNT_BIG(*) AS DatedTripCount,
    SUM(CASE WHEN timing.MatchedObservationCount = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS SingleObservationDatedTripCount,
    SUM(CASE WHEN timing.MatchedObservationCount > 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS MultipleObservationDatedTripCount,
    SUM(CASE WHEN timing.MatchedObservationWithEstimateCount = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimateEverDatedTripCount,
    SUM(CASE WHEN timing.MatchedObservationWithEstimateCount > 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS AtLeastOneEstimateDatedTripCount
FROM #TripTiming AS timing
GROUP BY timing.HasValidRealtimeObservation;

/* 8. Equal estimate/scheduled-time test. */
SELECT
    COUNT_BIG(*) AS MatchedObservationWithEstimateCount,
    SUM(CASE WHEN DATEDIFF_BIG(SECOND, matched.TimetabledArrivalUtc, matched.EstimatedArrivalUtc) = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS EstimateExactlyEqualsTimetabledArrivalCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN DATEDIFF_BIG(SECOND, matched.TimetabledArrivalUtc, matched.EstimatedArrivalUtc) = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS EstimateEqualsScheduledRate,
    N'NULL EstimatedArrivalUtc remains unknown/unavailable; this test does not authorize a NULL-as-on-time interpretation.' AS SemanticConclusion
FROM #FrozenMatchedObservation AS matched
WHERE matched.EstimatedArrivalUtc IS NOT NULL
  AND matched.TimetabledArrivalUtc IS NOT NULL;

/* 9. Situation evidence and text samples. */
SELECT DISTINCT
    matched.ServiceDate,
    matched.TripKey,
    matched.ObservationKey,
    link.SituationObservationKey,
    link.RelationScope,
    link.CreatedAtUtc
INTO #FrozenSituationLink
FROM #FrozenUnavailableObservation AS matched
JOIN stg.MddRealtimeStopSituationLink AS link
  ON link.ObservationKey = matched.ObservationKey;

CREATE INDEX IX_FrozenSituationLink_Date_Trip
    ON #FrozenSituationLink (ServiceDate, TripKey, ObservationKey);

SELECT DISTINCT
    link_row.ServiceDate,
    link_row.TripKey,
    link_row.ObservationKey,
    link_row.SituationObservationKey
INTO #FrozenSituationObservation
FROM #FrozenSituationLink AS link_row;

CREATE INDEX IX_FrozenSituationObservation_Date_Trip
    ON #FrozenSituationObservation (ServiceDate, TripKey, ObservationKey);

SELECT DISTINCT
    situation.SituationObservationKey,
    situation.ObservedAtUtc,
    situation.ParticipantRef,
    situation.SituationNumber,
    situation.Summary,
    situation.Description,
    situation.Detail,
    situation.ValidFromUtc,
    situation.ValidToUtc,
    situation.CreatedAtUtc
INTO #FrozenSituationDetail
FROM #FrozenSituationObservation AS link_row
JOIN stg.MddRealtimeSituationObservation AS situation
  ON situation.SituationObservationKey = link_row.SituationObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenSituationDetail_Key
    ON #FrozenSituationDetail (SituationObservationKey);

SELECT
    inventory.FieldName,
    inventory.TotalRowCount,
    inventory.NonNullCount,
    inventory.NullCount,
    inventory.DistinctCount
FROM
(
    SELECT N'SituationObservationKey' AS FieldName, COUNT_BIG(*) AS TotalRowCount, COUNT_BIG(SituationObservationKey) AS NonNullCount, COUNT_BIG(*) - COUNT_BIG(SituationObservationKey) AS NullCount, COUNT_BIG(DISTINCT SituationObservationKey) AS DistinctCount FROM #FrozenSituationDetail
    UNION ALL SELECT N'ObservedAtUtc', COUNT_BIG(*), COUNT_BIG(ObservedAtUtc), COUNT_BIG(*) - COUNT_BIG(ObservedAtUtc), COUNT_BIG(DISTINCT ObservedAtUtc) FROM #FrozenSituationDetail
    UNION ALL SELECT N'ParticipantRef', COUNT_BIG(*), COUNT_BIG(ParticipantRef), COUNT_BIG(*) - COUNT_BIG(ParticipantRef), COUNT_BIG(DISTINCT ParticipantRef) FROM #FrozenSituationDetail
    UNION ALL SELECT N'SituationNumber', COUNT_BIG(*), COUNT_BIG(SituationNumber), COUNT_BIG(*) - COUNT_BIG(SituationNumber), COUNT_BIG(DISTINCT SituationNumber) FROM #FrozenSituationDetail
    UNION ALL SELECT N'Summary', COUNT_BIG(*), COUNT_BIG(Summary), COUNT_BIG(*) - COUNT_BIG(Summary), COUNT_BIG(DISTINCT Summary) FROM #FrozenSituationDetail
    UNION ALL SELECT N'Description', COUNT_BIG(*), COUNT_BIG(Description), COUNT_BIG(*) - COUNT_BIG(Description), COUNT_BIG(DISTINCT Description) FROM #FrozenSituationDetail
    UNION ALL SELECT N'Detail', COUNT_BIG(*), COUNT_BIG(Detail), COUNT_BIG(*) - COUNT_BIG(Detail), COUNT_BIG(DISTINCT CONVERT(NVARCHAR(4000), Detail)) FROM #FrozenSituationDetail
    UNION ALL SELECT N'ValidFromUtc', COUNT_BIG(*), COUNT_BIG(ValidFromUtc), COUNT_BIG(*) - COUNT_BIG(ValidFromUtc), COUNT_BIG(DISTINCT ValidFromUtc) FROM #FrozenSituationDetail
    UNION ALL SELECT N'ValidToUtc', COUNT_BIG(*), COUNT_BIG(ValidToUtc), COUNT_BIG(*) - COUNT_BIG(ValidToUtc), COUNT_BIG(DISTINCT ValidToUtc) FROM #FrozenSituationDetail
    UNION ALL SELECT N'CreatedAtUtc', COUNT_BIG(*), COUNT_BIG(CreatedAtUtc), COUNT_BIG(*) - COUNT_BIG(CreatedAtUtc), COUNT_BIG(DISTINCT CreatedAtUtc) FROM #FrozenSituationDetail
) AS inventory
ORDER BY inventory.FieldName;

SELECT
    inventory.FieldName,
    inventory.TotalRowCount,
    inventory.NonNullCount,
    inventory.NullCount,
    inventory.DistinctCount
FROM
(
    SELECT N'ObservationKey' AS FieldName, COUNT_BIG(*) AS TotalRowCount, COUNT_BIG(ObservationKey) AS NonNullCount, COUNT_BIG(*) - COUNT_BIG(ObservationKey) AS NullCount, COUNT_BIG(DISTINCT ObservationKey) AS DistinctCount FROM #FrozenSituationLink
    UNION ALL SELECT N'SituationObservationKey', COUNT_BIG(*), COUNT_BIG(SituationObservationKey), COUNT_BIG(*) - COUNT_BIG(SituationObservationKey), COUNT_BIG(DISTINCT SituationObservationKey) FROM #FrozenSituationLink
    UNION ALL SELECT N'RelationScope', COUNT_BIG(*), COUNT_BIG(RelationScope), COUNT_BIG(*) - COUNT_BIG(RelationScope), COUNT_BIG(DISTINCT RelationScope) FROM #FrozenSituationLink
    UNION ALL SELECT N'CreatedAtUtc', COUNT_BIG(*), COUNT_BIG(CreatedAtUtc), COUNT_BIG(*) - COUNT_BIG(CreatedAtUtc), COUNT_BIG(DISTINCT CreatedAtUtc) FROM #FrozenSituationLink
) AS inventory
ORDER BY inventory.FieldName;

SELECT
    COUNT_BIG(DISTINCT CONVERT(NVARCHAR(8), unavailable.ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), unavailable.TripKey)) AS FrozenTimingUnavailableTripCount,
    COUNT_BIG(DISTINCT CASE WHEN situation.ObservationKey IS NOT NULL THEN CONVERT(NVARCHAR(8), unavailable.ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), unavailable.TripKey) END) AS TripsWithSituationEvidence,
    COUNT_BIG(DISTINCT CASE WHEN situation.ObservationKey IS NULL THEN CONVERT(NVARCHAR(8), unavailable.ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), unavailable.TripKey) END) AS TripsWithoutSituationEvidence,
    COUNT_BIG(situation.ObservationKey) AS LinkedObservationCount,
    COUNT_BIG(DISTINCT situation.SituationObservationKey) AS LinkedSituationObservationCount,
    SUM(COALESCE(situation.SituationLinkCount, 0)) AS SituationLinkCount
FROM #FrozenTimingUnavailableTrip AS unavailable
LEFT JOIN
(
    SELECT
        matched.ServiceDate,
        matched.TripKey,
        matched.ObservationKey,
        link.SituationObservationKey,
        1 AS SituationLinkCount
    FROM #FrozenUnavailableObservation AS matched
    JOIN stg.MddRealtimeStopSituationLink AS link
      ON link.ObservationKey = matched.ObservationKey
) AS situation
  ON situation.ServiceDate = unavailable.ServiceDate
 AND situation.TripKey = unavailable.TripKey;

SELECT
    situation.ParticipantRef,
    situation.SituationNumber,
    situation.RelationScope,
    COUNT_BIG(*) AS LinkRowCount,
    COUNT_BIG(DISTINCT CONVERT(NVARCHAR(8), situation.ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), situation.TripKey)) AS DatedTripCount,
    MAX(situation.Summary) AS Summary,
    MAX(situation.Description) AS Description,
    MAX(CONVERT(NVARCHAR(4000), situation.Detail)) AS Detail
FROM
(
    SELECT
        matched.ServiceDate,
        matched.TripKey,
        link.RelationScope,
        situation.ParticipantRef,
        situation.SituationNumber,
        situation.Summary,
        situation.Description,
        situation.Detail
    FROM #FrozenUnavailableObservation AS matched
    JOIN stg.MddRealtimeStopSituationLink AS link
      ON link.ObservationKey = matched.ObservationKey
    JOIN stg.MddRealtimeSituationObservation AS situation
      ON situation.SituationObservationKey = link.SituationObservationKey
) AS situation
GROUP BY situation.ParticipantRef, situation.SituationNumber, situation.RelationScope
ORDER BY LinkRowCount DESC, situation.ParticipantRef, situation.SituationNumber;

/* 10. Platform evidence while arrival estimate is NULL. */
SELECT
    COUNT_BIG(*) AS NoEstimateObservationCount,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(matched.EstimatedBay)), N'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimateWithEstimatedBayObservationCount,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(matched.PlannedBay)), N'') IS NOT NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimateWithPlannedBayObservationCount,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(matched.PlannedBay)), N'') IS NOT NULL
               AND NULLIF(LTRIM(RTRIM(matched.EstimatedBay)), N'') IS NOT NULL
               AND LTRIM(RTRIM(matched.PlannedBay)) <> LTRIM(RTRIM(matched.EstimatedBay))
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimateWithPlatformChangeObservationCount
FROM #FrozenUnavailableObservation AS matched
WHERE matched.EstimatedArrivalUtc IS NULL;

SELECT
    COUNT_BIG(*) AS NoEstimateTimingUnavailableTripCount,
    SUM(CASE WHEN flags.HasAnyBay = 0 AND flags.HasPlatformChange = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimate_NoRealtimeBay,
    SUM(CASE WHEN flags.HasEstimatedBay = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimate_WithEstimatedBay,
    SUM(CASE WHEN flags.HasPlatformChange = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoEstimate_WithPlatformChangeEvidence,
    N'Flags are diagnostic and may overlap; they are not primary root-cause categories.' AS Interpretation
FROM
(
    SELECT
        unavailable.ServiceDate,
        unavailable.TripKey,
        MAX(CASE WHEN NULLIF(LTRIM(RTRIM(matched.PlannedBay)), N'') IS NOT NULL
                      OR NULLIF(LTRIM(RTRIM(matched.EstimatedBay)), N'') IS NOT NULL THEN 1 ELSE 0 END) AS HasAnyBay,
        MAX(CASE WHEN NULLIF(LTRIM(RTRIM(matched.EstimatedBay)), N'') IS NOT NULL THEN 1 ELSE 0 END) AS HasEstimatedBay,
        MAX(CASE WHEN NULLIF(LTRIM(RTRIM(matched.PlannedBay)), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(matched.EstimatedBay)), N'') IS NOT NULL
                      AND LTRIM(RTRIM(matched.PlannedBay)) <> LTRIM(RTRIM(matched.EstimatedBay)) THEN 1 ELSE 0 END) AS HasPlatformChange
    FROM #FrozenTimingUnavailableTrip AS unavailable
    JOIN #FrozenUnavailableObservation AS matched
      ON matched.ServiceDate = unavailable.ServiceDate
     AND matched.TripKey = unavailable.TripKey
    WHERE matched.EstimatedArrivalUtc IS NULL
    GROUP BY unavailable.ServiceDate, unavailable.TripKey
) AS flags;

/* 11. Latest-null semantic pattern. */
SELECT
    outcome.OperationalStopOutcomeKey,
    outcome.ServiceDate,
    outcome.TripKey,
    outcome.RouteName,
    outcome.ParentStation AS Station,
    outcome.ScheduledArrival,
    outcome.FirstObservedAtUtc,
    outcome.LastObservedAtUtc,
    earlier.EarlierNonNullEstimatedArrivalUtc,
    final_observation.EstimatedArrivalUtc AS LatestEstimatedArrivalUtc,
    outcome.FirstObservedEstimatedDelayMinutes,
    outcome.FinalObservedEstimatedDelayMinutes
INTO #LatestNullPattern
FROM #FrozenOutcome AS outcome
JOIN #FrozenTimingUnavailableTrip AS unavailable
  ON unavailable.ServiceDate = outcome.ServiceDate
 AND unavailable.TripKey = outcome.TripKey
JOIN #FrozenMatchedObservation AS final_observation
  ON final_observation.ObservationKey = outcome.LastObservationKey
 AND final_observation.EstimatedArrivalUtc IS NULL
OUTER APPLY
(
    SELECT TOP (1)
        previous.EstimatedArrivalUtc AS EarlierNonNullEstimatedArrivalUtc
    FROM #FrozenMatchedObservation AS previous
    WHERE previous.DateKey = outcome.DateKey
      AND previous.ScheduledStopEventKey = outcome.ScheduledStopEventKey
      AND previous.EstimatedArrivalUtc IS NOT NULL
      AND
      (
          previous.ObservedAtUtc < outcome.LastObservedAtUtc
          OR (previous.ObservedAtUtc = outcome.LastObservedAtUtc AND previous.ObservationKey < outcome.LastObservationKey)
      )
    ORDER BY previous.ObservedAtUtc DESC, previous.ObservationKey DESC
) AS earlier
WHERE earlier.EarlierNonNullEstimatedArrivalUtc IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_LatestNullPattern_Outcome
    ON #LatestNullPattern (OperationalStopOutcomeKey);

SELECT
    COUNT_BIG(*) AS AffectedOperationalStopOutcomeCount,
    COUNT_BIG(DISTINCT CONVERT(NVARCHAR(8), pattern.ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), pattern.TripKey)) AS AffectedDistinctDatedTripCount,
    CASE WHEN COUNT_BIG(*) = 0 THEN N'NO' ELSE N'YES' END AS PatternExists,
    N'Earlier non-NULL EstimatedArrivalUtc followed by the final/latest matched observation with EstimatedArrivalUtc IS NULL for the same dated scheduled stop event.' AS PatternDefinition
FROM #LatestNullPattern AS pattern;

SELECT
    pattern.ServiceDate,
    pattern.TripKey,
    pattern.RouteName,
    pattern.Station,
    pattern.ScheduledArrival,
    pattern.FirstObservedAtUtc,
    pattern.LastObservedAtUtc,
    pattern.EarlierNonNullEstimatedArrivalUtc,
    pattern.LatestEstimatedArrivalUtc,
    pattern.FirstObservedEstimatedDelayMinutes,
    pattern.FinalObservedEstimatedDelayMinutes
FROM
(
    SELECT
        pattern.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY pattern.ServiceDate, pattern.TripKey
            ORDER BY pattern.LastObservedAtUtc DESC, pattern.OperationalStopOutcomeKey DESC
        ) AS RowNumber
    FROM #LatestNullPattern AS pattern
) AS pattern
WHERE pattern.RowNumber = 1
ORDER BY pattern.ServiceDate, pattern.TripKey;

/* 12. Reliable source-level operator/mode attributes for dimensional analysis. */
SELECT
    timing.ServiceDate,
    timing.TripKey,
    CASE
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.OperatorRef)), N'')) = 1
            THEN MAX(NULLIF(LTRIM(RTRIM(matched.OperatorRef)), N''))
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.OperatorRef)), N'')) = 0
            THEN N'(Unknown)'
        ELSE N'(MultipleOperatorRefs)'
    END AS OperatorRef,
    CASE
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.PtMode)), N'')) = 1
            THEN MAX(NULLIF(LTRIM(RTRIM(matched.PtMode)), N''))
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.PtMode)), N'')) = 0
            THEN N'(Unknown)'
        ELSE N'(MultiplePtModes)'
    END AS PtMode,
    CASE
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.RailSubmode)), N'')) = 1
            THEN MAX(NULLIF(LTRIM(RTRIM(matched.RailSubmode)), N''))
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(matched.RailSubmode)), N'')) = 0
            THEN N'(Unknown)'
        ELSE N'(MultipleRailSubmodes)'
    END AS RailSubmode
INTO #TripSourceAttribute
FROM #TripTiming AS timing
LEFT JOIN #FrozenMatchedObservation AS matched
  ON matched.ServiceDate = timing.ServiceDate
 AND matched.TripKey = timing.TripKey
GROUP BY timing.ServiceDate, timing.TripKey;

CREATE UNIQUE CLUSTERED INDEX UX_TripSourceAttribute_Date_Trip
    ON #TripSourceAttribute (ServiceDate, TripKey);

/* 13. Dimension concentration: each result is at unique dated-trip grain except station rows, which are non-additive. */
SELECT
    timing.Mode AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate
FROM #TripTiming AS timing
GROUP BY timing.Mode
ORDER BY timing.Mode;

SELECT
    timing.RouteName AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate
FROM #TripTiming AS timing
GROUP BY timing.RouteName
ORDER BY TimingUnavailableTripCount DESC, timing.RouteName;

SELECT
    timing.ParentStation AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate,
    N'Station rows are non-additive; the same dated trip may appear at more than one monitored station in underlying outcome data.' AS GrainNote
FROM #TripTiming AS timing
GROUP BY timing.ParentStation
ORDER BY TimingUnavailableTripCount DESC, timing.ParentStation;

SELECT
    attributes.OperatorRef AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate
FROM #TripTiming AS timing
JOIN #TripSourceAttribute AS attributes
  ON attributes.ServiceDate = timing.ServiceDate
 AND attributes.TripKey = timing.TripKey
GROUP BY attributes.OperatorRef
ORDER BY TimingUnavailableTripCount DESC, attributes.OperatorRef;

SELECT
    attributes.PtMode AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate
FROM #TripTiming AS timing
JOIN #TripSourceAttribute AS attributes
  ON attributes.ServiceDate = timing.ServiceDate
 AND attributes.TripKey = timing.TripKey
GROUP BY attributes.PtMode
ORDER BY TimingUnavailableTripCount DESC, attributes.PtMode;

SELECT
    attributes.RailSubmode AS DimensionValue,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate
FROM #TripTiming AS timing
JOIN #TripSourceAttribute AS attributes
  ON attributes.ServiceDate = timing.ServiceDate
 AND attributes.TripKey = timing.TripKey
GROUP BY attributes.RailSubmode
ORDER BY TimingUnavailableTripCount DESC, attributes.RailSubmode;

/* 14. Scheduled-stop position analysis. */
;WITH TripStopBounds AS
(
    SELECT
        TripKey,
        MIN(StopSequence) AS MinimumStopSequenceForTrip,
        MAX(StopSequence) AS MaximumStopSequenceForTrip
    FROM dw.FactScheduledStopEvent
    GROUP BY TripKey
), Positions AS
(
    SELECT DISTINCT
        outcome.ServiceDate,
        outcome.TripKey,
        CASE
            WHEN bounds.MinimumStopSequenceForTrip = bounds.MaximumStopSequenceForTrip
                THEN N'SingleStopPattern'
            WHEN event.StopSequence = bounds.MinimumStopSequenceForTrip
                THEN N'FirstScheduledStop'
            WHEN event.StopSequence = bounds.MaximumStopSequenceForTrip
                THEN N'LastScheduledStop'
            ELSE N'IntermediateScheduledStop'
        END AS ScheduledStopPosition
    FROM #FrozenOutcome AS outcome
    JOIN dw.FactScheduledStopEvent AS event
      ON event.ScheduledStopEventKey = outcome.ScheduledStopEventKey
    JOIN TripStopBounds AS bounds
      ON bounds.TripKey = event.TripKey
)
SELECT
    positions.ScheduledStopPosition,
    COUNT_BIG(*) AS ComparableTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS UsableTimingTripCount,
    SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS TimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN timing.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS TimingUnavailableRate,
    N'Position rows may be non-additive when a dated trip has multiple matched scheduled stops.' AS GrainNote
FROM Positions AS positions
JOIN #TripTiming AS timing
  ON timing.ServiceDate = positions.ServiceDate
 AND timing.TripKey = positions.TripKey
GROUP BY positions.ScheduledStopPosition
ORDER BY CASE positions.ScheduledStopPosition
             WHEN N'SingleStopPattern' THEN 1
             WHEN N'FirstScheduledStop' THEN 2
             WHEN N'IntermediateScheduledStop' THEN 3
             WHEN N'LastScheduledStop' THEN 4
         END;

/* 15. Current seven-target sampling cadence and target-specific timing. */
;WITH SlotCounts AS
(
    SELECT
        target.SamplingTargetId,
        target.TargetName AS SamplingTargetName,
        target.StopPointRef,
        target.NumberOfResults,
        COUNT_BIG(slot.SamplingSlot) AS ConfiguredSlotCount
    FROM ctl.MddRealtimeSamplingTarget AS target
    LEFT JOIN ctl.MddRealtimeSamplingSlot AS slot
      ON slot.SamplingTargetId = target.SamplingTargetId
    WHERE target.IsEnabled = 1
    GROUP BY target.SamplingTargetId, target.TargetName, target.StopPointRef, target.NumberOfResults
), RunCounts AS
(
    SELECT
        target.SamplingTargetId,
        COUNT_BIG(DISTINCT run.CollectorRunId) AS CollectorRunCount,
        COUNT_BIG(DISTINCT CASE WHEN run.Status = 'Succeeded' THEN run.CollectorRunId END) AS SucceededCollectorRunCount,
        COUNT_BIG(DISTINCT CASE WHEN run.Status = 'Failed' THEN run.CollectorRunId END) AS FailedCollectorRunCount,
        COUNT_BIG(DISTINCT CASE WHEN run.Status = 'Started' THEN run.CollectorRunId END) AS StartedCollectorRunCount,
        MAX(run.StartedAtUtc) AS LatestCollectorRunStartedAtUtc
    FROM ctl.MddRealtimeSamplingTarget AS target
    LEFT JOIN ctl.MddCollectorRun AS run
      ON run.SamplingTargetId = target.SamplingTargetId
    WHERE target.IsEnabled = 1
    GROUP BY target.SamplingTargetId
)
SELECT
    slots.SamplingTargetId,
    slots.SamplingTargetName,
    slots.StopPointRef,
    slots.NumberOfResults,
    slots.ConfiguredSlotCount,
    SUM(slots.ConfiguredSlotCount) OVER () AS EnabledSamplingSlotCount,
    CONVERT(DECIMAL(10, 2), 5.0 * SUM(slots.ConfiguredSlotCount) OVER () / NULLIF(slots.ConfiguredSlotCount, 0)) AS ImpliedSamplingCadenceMinutes,
    runs.CollectorRunCount,
    runs.SucceededCollectorRunCount,
    runs.FailedCollectorRunCount,
    runs.StartedCollectorRunCount,
    runs.LatestCollectorRunStartedAtUtc
INTO #SamplingTargetSummary
FROM SlotCounts AS slots
LEFT JOIN RunCounts AS runs
  ON runs.SamplingTargetId = slots.SamplingTargetId;

CREATE UNIQUE CLUSTERED INDEX UX_SamplingTargetSummary_Id
    ON #SamplingTargetSummary (SamplingTargetId);

SELECT DISTINCT
    target_summary.SamplingTargetId,
    target_summary.SamplingTargetName,
    target_summary.StopPointRef,
    target_summary.NumberOfResults,
    target_summary.ConfiguredSlotCount,
    target_summary.EnabledSamplingSlotCount,
    target_summary.ImpliedSamplingCadenceMinutes,
    trip.ServiceDate,
    trip.TripKey,
    trip.HasValidRealtimeObservation
INTO #FrozenTargetTrip
FROM #SamplingTargetSummary AS target_summary
JOIN ctl.MddRealtimeSamplingTarget AS target
  ON target.SamplingTargetId = target_summary.SamplingTargetId
JOIN #FrozenOutcome AS outcome
  ON 1 = 1
JOIN dw.DimStop AS outcome_stop
  ON outcome_stop.StopKey = outcome.StopKey
 AND
 (
     outcome_stop.StopId = target.StopPointRef
     OR outcome_stop.ParentStationId = target.StopPointRef
 )
JOIN #FrozenComparableTrip AS trip
  ON trip.ServiceDate = outcome.ServiceDate
 AND trip.TripKey = outcome.TripKey
WHERE target.IsEnabled = 1;

CREATE UNIQUE CLUSTERED INDEX UX_FrozenTargetTrip
    ON #FrozenTargetTrip (SamplingTargetId, ServiceDate, TripKey);

SELECT
    target_trip.SamplingTargetId,
    target_trip.SamplingTargetName,
    target_trip.StopPointRef,
    MAX(target_trip.NumberOfResults) AS NumberOfResults,
    MAX(target_trip.ConfiguredSlotCount) AS ConfiguredSlotCount,
    MAX(target_trip.EnabledSamplingSlotCount) AS EnabledSamplingSlotCount,
    MAX(target_trip.ImpliedSamplingCadenceMinutes) AS ImpliedSamplingCadenceMinutes,
    COUNT_BIG(*) AS FrozenComparableTripCount,
    SUM(CASE WHEN target_trip.HasValidRealtimeObservation = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS FrozenUsableTimingTripCount,
    SUM(CASE WHEN target_trip.HasValidRealtimeObservation = 0 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS FrozenTimingUnavailableTripCount,
    CONVERT(DECIMAL(18, 8), SUM(CASE WHEN target_trip.HasValidRealtimeObservation = 0 THEN CONVERT(DECIMAL(28, 8), 1) ELSE CONVERT(DECIMAL(28, 8), 0) END) / NULLIF(COUNT_BIG(*), 0)) AS FrozenTimingUnavailableRate,
    SUM(CASE WHEN target_trip.HasValidRealtimeObservation = 0 AND timing.MatchedObservationCount = 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS SingleObservationTimingUnavailableCount,
    SUM(CASE WHEN target_trip.HasValidRealtimeObservation = 0 AND timing.MatchedObservationCount > 1 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS MultipleObservationTimingUnavailableCount
FROM #FrozenTargetTrip AS target_trip
JOIN #TripTiming AS timing
  ON timing.ServiceDate = target_trip.ServiceDate
 AND timing.TripKey = target_trip.TripKey
GROUP BY target_trip.SamplingTargetId, target_trip.SamplingTargetName, target_trip.StopPointRef
ORDER BY target_trip.SamplingTargetId;

SELECT
    target_trip.SamplingTargetId,
    target_trip.SamplingTargetName,
    target_trip.StopPointRef,
    CASE
        WHEN target_timing.LastObservationLeadMinutes < 0 THEN N'after scheduled arrival'
        WHEN target_timing.LastObservationLeadMinutes < 5 THEN N'0-5 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 10 THEN N'5-10 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 20 THEN N'10-20 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 30 THEN N'20-30 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 60 THEN N'30-60 minutes before'
        ELSE N'more than 60 minutes before'
    END AS LeadTimeBin,
    COUNT_BIG(*) AS TimingUnavailableTripCount
FROM #FrozenTargetTrip AS target_trip
JOIN #TripTiming AS overall_timing
  ON overall_timing.ServiceDate = target_trip.ServiceDate
 AND overall_timing.TripKey = target_trip.TripKey
OUTER APPLY
(
    SELECT TOP (1)
        CONVERT(DECIMAL(18, 4), DATEDIFF_BIG(SECOND, matched.ObservedAtUtc, matched.TimetabledArrivalUtc) / 60.0) AS LastObservationLeadMinutes
    FROM #FrozenMatchedObservation AS matched
    WHERE matched.ServiceDate = target_trip.ServiceDate
      AND matched.TripKey = target_trip.TripKey
      AND EXISTS
      (
          SELECT 1
          FROM dw.DimStop AS source_stop
          JOIN ctl.MddRealtimeSamplingTarget AS target
            ON target.SamplingTargetId = target_trip.SamplingTargetId
          WHERE source_stop.StopId = matched.StopPointRef
            AND
            (
                source_stop.StopId = target.StopPointRef
                OR source_stop.ParentStationId = target.StopPointRef
            )
      )
    ORDER BY matched.ObservedAtUtc DESC, matched.ObservationKey DESC
) AS target_timing
WHERE target_trip.HasValidRealtimeObservation = 0
  AND target_timing.LastObservationLeadMinutes IS NOT NULL
GROUP BY
    target_trip.SamplingTargetId,
    target_trip.SamplingTargetName,
    target_trip.StopPointRef,
    CASE
        WHEN target_timing.LastObservationLeadMinutes < 0 THEN N'after scheduled arrival'
        WHEN target_timing.LastObservationLeadMinutes < 5 THEN N'0-5 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 10 THEN N'5-10 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 20 THEN N'10-20 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 30 THEN N'20-30 minutes before'
        WHEN target_timing.LastObservationLeadMinutes < 60 THEN N'30-60 minutes before'
        ELSE N'more than 60 minutes before'
    END
ORDER BY target_trip.SamplingTargetId, LeadTimeBin;

/* 16. Mutually exclusive current primary root-cause classification.
       Observation exposure is secondary evidence only.  The primary
       category is based on persisted timing evidence or an explicit
       evidence gap, not on the number of observations. */
SELECT
    timing.ServiceDate,
    timing.TripKey,
    CASE
        WHEN timing.MatchedObservationCount = 0
            THEN N'InsufficientEvidence'
        WHEN EXISTS
        (
            SELECT 1
            FROM #LatestNullPattern AS latest_null
            WHERE latest_null.ServiceDate = timing.ServiceDate
              AND latest_null.TripKey = timing.TripKey
        )
            THEN N'EstimatePreviouslyPresent_FinalObservationNull'
        WHEN timing.MatchedObservationWithEstimateCount = 0
            THEN N'NoPersistedArrivalEstimateObserved'
        ELSE N'OtherProvenCause'
    END AS PrimaryRootCauseCategory,
    CASE
        WHEN timing.MatchedObservationCount = 0 THEN N'NoMatchedObservation'
        WHEN timing.MatchedObservationWithEstimateCount = 0 THEN N'NoPersistedArrivalEstimateObserved'
        ELSE N'PersistedArrivalEstimateObserved'
    END AS PersistedArrivalEstimateEvidence,
    CASE WHEN timing.MatchedObservationCount = 1 THEN N'OnlyObservedOnce' WHEN timing.MatchedObservationCount > 1 THEN N'MultipleObservations' ELSE N'NoMatchedObservation' END AS ObservationCountEvidence,
    CASE WHEN EXISTS
         (
             SELECT 1
             FROM #LatestNullPattern AS latest_null
             WHERE latest_null.ServiceDate = timing.ServiceDate
               AND latest_null.TripKey = timing.TripKey
         ) THEN N'LatestObservationWasNullAfterEarlierEstimate' ELSE N'NoLatestNullPattern' END AS LatestNullEvidence,
    CASE WHEN EXISTS
         (
             SELECT 1
             FROM #FrozenSituationObservation AS situation
             WHERE situation.ServiceDate = timing.ServiceDate
               AND situation.TripKey = timing.TripKey
         ) THEN N'SituationEvidencePresent' ELSE N'NoSituationEvidence' END AS SituationEvidenceFlag
INTO #PrimaryRootCause
FROM #TripTiming AS timing
WHERE timing.HasValidRealtimeObservation = 0;

CREATE UNIQUE CLUSTERED INDEX UX_PrimaryRootCause_Date_Trip
    ON #PrimaryRootCause (ServiceDate, TripKey);

SELECT
    category.PrimaryRootCauseCategory,
    COUNT_BIG(*) AS DatedTripCount,
    CONVERT(DECIMAL(18, 8), COUNT_BIG(*) / NULLIF(CONVERT(DECIMAL(28, 8), (SELECT COUNT_BIG(*) FROM #PrimaryRootCause)), 0)) AS PercentageOfFrozenTimingUnavailableTrips,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #PrimaryRootCause)
             = (SELECT SUM(counts.DatedTripCount) FROM (SELECT PrimaryRootCauseCategory, COUNT_BIG(*) AS DatedTripCount FROM #PrimaryRootCause GROUP BY PrimaryRootCauseCategory) AS counts)
            THEN N'PASS' ELSE N'REVIEW'
    END AS PrimaryCategoryReconciliationStatus
FROM #PrimaryRootCause AS category
GROUP BY category.PrimaryRootCauseCategory
ORDER BY category.PrimaryRootCauseCategory;

SELECT
    COUNT_BIG(*) AS FrozenTimingUnavailableTripCount,
    SUM(CASE WHEN PersistedArrivalEstimateEvidence = N'NoPersistedArrivalEstimateObserved' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoPersistedArrivalEstimateObservedCount,
    SUM(CASE WHEN ObservationCountEvidence = N'NoMatchedObservation' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS NoMatchedObservationCount,
    SUM(CASE WHEN ObservationCountEvidence = N'OnlyObservedOnce' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS OnlyObservedOnceCount,
    SUM(CASE WHEN ObservationCountEvidence = N'MultipleObservations' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS MultipleObservationsCount,
    SUM(CASE WHEN LatestNullEvidence = N'LatestObservationWasNullAfterEarlierEstimate' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS LatestNullAffectedDatedTripCount,
    SUM(CASE WHEN SituationEvidenceFlag = N'SituationEvidencePresent' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS SituationEvidenceDatedTripCount,
    N'Only the PrimaryRootCauseCategory distribution is mutually exclusive; the columns in this result are secondary diagnostic flags.' AS Interpretation
FROM #PrimaryRootCause;

/* 17. Raw TRIAS inspection is an external, diagnostic-only operation.  This
       reusable SQL batch never issues MDD requests; the companion helper is
       responsible for any prospective raw inspection. */
SELECT
    N'RawTriasTimingInspection' AS Finding,
    N'NOT_EXECUTED' AS Status,
    N'This read-only SQL batch does not issue MDD requests. Use collector/Inspect-MddTriasTimingEvidence.ps1 for the bounded seven-target raw inspection; no raw response is persisted by that helper.' AS Evidence;

SELECT
    N'ServiceArrival.timetabledTime' AS SourceJsonPath,
    N'YES' AS CurrentParserPersistsIt,
    N'NOT_TESTED' AS RawObservedWhenArrivalEstimateMissing,
    N'PARSER_PROJECTION_ONLY' AS SemanticConfidence,
    N'Creates stg.MddRealtimeStopObservation.TimetabledArrivalUtc; raw source presence in a missing-estimate event requires the bounded helper.' AS PotentiallyRelevantObservationPattern
UNION ALL
SELECT N'ServiceArrival.estimatedTime', N'YES', N'NOT_TESTED', N'PARSER_PROJECTION_ONLY', N'Creates stg.MddRealtimeStopObservation.EstimatedArrivalUtc; NULL remains unavailable in the persisted path.'
UNION ALL
SELECT N'serviceDeparture.*', N'NO', N'NOT_TESTED', N'RAW_INSPECTION_REQUIRED', N'Current parser has no persisted departure timing field; departure timing must not be treated as arrival timing.'
UNION ALL
SELECT N'actual/recorded arrival or departure fields', N'NO', N'NOT_TESTED', N'RAW_INSPECTION_REQUIRED', N'No current persisted actual/recorded arrival or departure field.'
UNION ALL
SELECT N'cancellation/status fields', N'NO', N'NOT_TESTED', N'RAW_INSPECTION_REQUIRED', N'No current persisted deterministic cancellation/status field; free text is not converted into cancellation.';

/* 18. Alternative persisted timing conclusion. */
SELECT
    CONVERT(BIGINT, 0) AS AlternativePersistedRealtimeTimingAvailableCount,
    COUNT_BIG(*) AS FrozenUnavailableObservationCount,
    COUNT_BIG(CreatedAtUtc) AS CreatedAtUtcPresentCount,
    COUNT_BIG(ObservedAtUtc) AS ObservedAtUtcPresentCount,
    COUNT_BIG(TimetabledArrivalUtc) AS TimetabledArrivalUtcPresentCount,
    N'NO: ObservedAtUtc and CreatedAtUtc are observation/storage timestamps; TimetabledArrivalUtc is schedule time. Neither is a valid substitute for EstimatedArrivalUtc.' AS EvidenceBasedConclusion
FROM #FrozenUnavailableObservation;

/* 19. Collector audit context by enabled target. */
SELECT
    target_summary.SamplingTargetId,
    target_summary.SamplingTargetName,
    target_summary.StopPointRef,
    target_summary.NumberOfResults,
    target_summary.ConfiguredSlotCount,
    target_summary.EnabledSamplingSlotCount,
    target_summary.ImpliedSamplingCadenceMinutes,
    target_summary.CollectorRunCount,
    target_summary.SucceededCollectorRunCount,
    target_summary.FailedCollectorRunCount,
    target_summary.StartedCollectorRunCount,
    target_summary.LatestCollectorRunStartedAtUtc
FROM #SamplingTargetSummary AS target_summary
ORDER BY target_summary.SamplingTargetId;

/* 20. Production-semantics answers supported by this stored-data analysis. */
SELECT
    N'CollectorParserDiscardsRelevantTiming' AS Question,
    N'INCONCLUSIVE' AS Answer,
    N'Stored evidence proves the parser persists serviceArrival.timetabledTime and serviceArrival.estimatedTime, but this SQL batch does not inspect raw TRIAS responses; no discarded raw field can be proven from stored rows alone.' AS Evidence
UNION ALL
SELECT
    N'SamplingCadenceMateriallyContributes',
    N'PARTIALLY',
    CONCAT
    (
        N'Cadence is a plausible exposure contributor: unavailable dated trips with one matched observation=',
        (SELECT COUNT_BIG(*) FROM #TripTiming WHERE HasValidRealtimeObservation = 0 AND MatchedObservationCount = 1),
        N'/',
        (SELECT COUNT_BIG(*) FROM #TripTiming WHERE HasValidRealtimeObservation = 0),
        N'; usable=',
        (SELECT COUNT_BIG(*) FROM #TripTiming WHERE HasValidRealtimeObservation = 1 AND MatchedObservationCount = 1),
        N'/',
        (SELECT COUNT_BIG(*) FROM #TripTiming WHERE HasValidRealtimeObservation = 1),
        N'. The 25-minute and 50-minute target groups differ by station and service mix, so the stored data does not prove a causal cadence effect.'
    )
UNION ALL
SELECT
    N'WarehouseLatestNullSemanticsMateriallyContribute',
    CASE WHEN COUNT_BIG(*) > 0 THEN N'PARTIALLY' ELSE N'NO' END,
    CONCAT
    (
        N'AffectedOperationalStopOutcomeCount=', COUNT_BIG(*),
        N'; affected dated trips=', COUNT_BIG(DISTINCT CONVERT(NVARCHAR(8), ServiceDate, 112) + N'|' + CONVERT(NVARCHAR(30), TripKey)),
        N'/', (SELECT COUNT_BIG(*) FROM #FrozenTimingUnavailableTrip),
        N' (', CONVERT(DECIMAL(18, 4), COUNT_BIG(*) / NULLIF(CONVERT(DECIMAL(28, 8), (SELECT COUNT_BIG(*) FROM #FrozenTimingUnavailableTrip)), 0) * 100.0),
        N'%). The latest-observation semantic is unchanged in this branch.'
    )
FROM #LatestNullPattern;

/* 21. Final analysis metadata and prohibited-change reminder. */
SELECT
    @AnalysisExecutionAtUtc AS AnalysisExecutionAtUtc,
    N'One-session frozen dated-trip analysis' AS AnalysisMode,
    N'Historical 382 and aligned 888 snapshots preserved as evidence' AS HistoricalEvidenceTreatment,
    N'No Collector, matching, warehouse logic, Power BI, sampling, tiered scheduling, or Actual Physical Delay semantics changed by this script.' AS ChangeBoundary;
