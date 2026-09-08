USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/*
    Read-only validation report for the realtime analytics layer.

    The report consumes current genuine collector observations and operational
    outcomes.  It does not create synthetic rows, apply an arbitrary on-time
    threshold, infer cancellations/departures, or claim situation causality.
*/

/* 1. All production analytics views exist and are queryable. */
SELECT
    view_check.ViewName,
    view_check.ExistsFlag,
    view_check.ViewRowCount,
    CASE WHEN view_check.ExistsFlag = 1 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT
        N'analytics.vwRealtimeCollectorRunHealth' AS ViewName,
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeCollectorRunHealth', N'V') IS NULL
            THEN 0 ELSE 1 END) AS ExistsFlag,
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeCollectorRunHealth) AS ViewRowCount

    UNION ALL
    SELECT
        N'analytics.vwRealtimeDataQualityCoverage',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeDataQualityCoverage', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeDataQualityCoverage)

    UNION ALL
    SELECT
        N'analytics.vwRealtimeOperationalConsolidationQuality',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeOperationalConsolidationQuality', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeOperationalConsolidationQuality)

    UNION ALL
    SELECT
        N'analytics.vwRealtimeReliabilityOutcome',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeReliabilityOutcome', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeReliabilityOutcome)

    UNION ALL
    SELECT
        N'analytics.vwRealtimeReliabilityByDimension',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeReliabilityByDimension', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeReliabilityByDimension)

    UNION ALL
    SELECT
        N'analytics.vwRealtimeDelayHotspot',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeDelayHotspot', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeDelayHotspot)

    UNION ALL
    SELECT
        N'analytics.vwRealtimePlatformChangeEvidence',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimePlatformChangeEvidence', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimePlatformChangeEvidence)

    UNION ALL
    SELECT
        N'analytics.vwRealtimeSituationLinkedOutcome',
        CONVERT(BIT, CASE WHEN OBJECT_ID
            (N'analytics.vwRealtimeSituationLinkedOutcome', N'V') IS NULL
            THEN 0 ELSE 1 END),
        (SELECT COUNT_BIG(*)
         FROM analytics.vwRealtimeSituationLinkedOutcome)
) AS view_check
ORDER BY view_check.ViewName;

/* 2. Coverage rates and match-status accounting are bounded and complete. */
;WITH coverage AS
(
    SELECT *
    FROM analytics.vwRealtimeDataQualityCoverage
)
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT N'Coverage rate below zero or above one' AS CheckName,
           COUNT_BIG(*) AS FailedRows
    FROM coverage
    WHERE ExactStopMatchRate NOT BETWEEN 0 AND 1
       OR ParentStationFallbackRate NOT BETWEEN 0 AND 1
       OR StaticCoverageMissingRate NOT BETWEEN 0 AND 1
       OR UnresolvedRate NOT BETWEEN 0 AND 1
       OR UsableMatchRate NOT BETWEEN 0 AND 1
       OR EstimatedBayAvailabilityRate NOT BETWEEN 0 AND 1
       OR SituationEvidenceAvailabilityRate NOT BETWEEN 0 AND 1
       OR SamplingPanelParticipationRate NOT BETWEEN 0 AND 1

    UNION ALL
    SELECT N'Match-status counts do not sum to matched observations',
           COUNT_BIG(*)
    FROM coverage
    WHERE ExactStopMatchCount
        + ParentStationFallbackCount
        + StaticCoverageMissingCount
        + UnresolvedCount <> MatchedViewObservationCount

    UNION ALL
    SELECT N'Usable count does not equal Exact plus Parent',
           COUNT_BIG(*)
    FROM coverage
    WHERE UsableMatchCount <> ExactStopMatchCount
        + ParentStationFallbackCount

    UNION ALL
    SELECT N'Coverage scope note missing sampling-panel wording',
           COUNT_BIG(*)
    FROM coverage
    WHERE CoverageScopeNote NOT LIKE N'%sampling panel%'
) AS check_result
ORDER BY check_result.CheckName;

/* 3. Operational outcome and reliability consumer counts agree. */
SELECT
    fact_count.OperationalOutcomeCount AS FactOutcomeCount,
    reliability_count.ReliabilityOutcomeCount,
    reliability_count.ReliabilityOutcomeCount
        - fact_count.OperationalOutcomeCount AS DifferenceCount,
    CASE WHEN reliability_count.ReliabilityOutcomeCount
              = fact_count.OperationalOutcomeCount
         THEN 'PASS' ELSE 'REVIEW' END AS CheckStatus
FROM
(
    SELECT COUNT_BIG(*) AS OperationalOutcomeCount
    FROM dw.FactOperationalStopOutcome
) AS fact_count
CROSS JOIN
(
    SELECT COUNT_BIG(*) AS ReliabilityOutcomeCount
    FROM analytics.vwRealtimeReliabilityOutcome
) AS reliability_count;

/* 4. Dimension coverage supports the current SQL reliability questions. */
SELECT
    required_dimension.DimensionType,
    CASE WHEN actual_dimension.DimensionType IS NULL THEN 'MISSING'
         ELSE 'PRESENT' END AS DimensionStatus
FROM
(
    SELECT N'Overall' AS DimensionType
    UNION ALL SELECT N'Date'
    UNION ALL SELECT N'Route'
    UNION ALL SELECT N'Stop'
    UNION ALL SELECT N'Mode'
    UNION ALL SELECT N'Hour'
) AS required_dimension
LEFT JOIN
(
    SELECT DISTINCT DimensionType
    FROM analytics.vwRealtimeReliabilityByDimension
) AS actual_dimension
    ON actual_dimension.DimensionType = required_dimension.DimensionType
ORDER BY required_dimension.DimensionType;

/* 5. Platform and situation semantics remain explicit. */
SELECT
    check_result.CheckName,
    check_result.FailedRows,
    CASE WHEN check_result.FailedRows = 0 THEN 'PASS' ELSE 'REVIEW' END
        AS CheckStatus
FROM
(
    SELECT N'Invalid platform evidence label' AS CheckName,
           COUNT_BIG(*) AS FailedRows
    FROM dw.FactOperationalStopOutcome
    WHERE PlatformChangeEvidence NOT IN ('Changed', 'Unchanged', 'Unknown')

    UNION ALL
    SELECT N'Situation-linked view contains an outcome without evidence',
           COUNT_BIG(*)
    FROM analytics.vwRealtimeSituationLinkedOutcome
    WHERE HasSituationEvidence <> 1

    UNION ALL
    SELECT N'Linked situation count is negative', COUNT_BIG(*)
    FROM analytics.vwRealtimeReliabilityOutcome
    WHERE SituationLinkCount < 0

    UNION ALL
    SELECT N'Missing causal/evidence semantic note', COUNT_BIG(*)
    FROM analytics.vwRealtimeReliabilityOutcome
    WHERE SituationSemanticNote NOT LIKE N'%not confirmed causality%'
) AS check_result
ORDER BY check_result.CheckName;

/* 6. Continuous estimated-delay metrics are populated without an OnTimeRate. */
SELECT
    performance.DimensionType,
    performance.DimensionLabel,
    performance.ObservedMatchedServiceCount,
    performance.DelayObservationCount,
    performance.AverageObservedEstimatedDelayMinutes,
    performance.MedianObservedEstimatedDelayMinutes,
    performance.P95ObservedEstimatedDelayMinutes,
    performance.ThresholdSemanticNote
FROM analytics.vwRealtimeReliabilityByDimension AS performance
WHERE performance.DimensionType = N'Overall';

/* 7. Realtime source and outcome scope remains explicit. */
SELECT
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation)
        AS SourceObservationCount,
    (SELECT COUNT_BIG(*) FROM dw.FactOperationalStopOutcome)
        AS OperationalOutcomeCount,
    (SELECT COUNT_BIG(*)
     FROM stg.MddRealtimeStopObservation AS observation
     JOIN wrk.vwCologneRealtimeTripMatch AS match_view
       ON match_view.ObservationKey = observation.ObservationKey
     WHERE match_view.MatchStatus IN
           (N'ExactStopMatch', N'ParentStationFallback'))
        AS UsableSourceObservationCount,
    (SELECT COUNT_BIG(*)
     FROM stg.MddRealtimeStopObservation AS observation
     JOIN wrk.vwCologneRealtimeTripMatch AS match_view
       ON match_view.ObservationKey = observation.ObservationKey
     WHERE match_view.MatchStatus IN
           (N'StaticCoverageMissing', N'Unresolved'))
        AS NonUsableSourceObservationCount,
    N'Arrival estimates only; no confirmed physical arrival, cancellation, or departure KPI'
        AS ScopeNote;
