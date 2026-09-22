/*
    Read-only analysis of all eligible parent stations for a future realtime
    monitoring panel.

    This script creates only session-scoped temporary tables.  It does not
    create permanent objects and does not modify Collector or sampling
    configuration.  The O5_RESULT comments are optional client-side labels;
    in SSMS the script returns the same sections as separate result sets.
*/

USE CologneTransitIntelligence;
SET NOCOUNT ON;

DECLARE @PanelSize INT = 50;
DECLARE @QuotaLimit BIGINT = 250000;

DROP TABLE IF EXISTS #StationEventPattern;
DROP TABLE IF EXISTS #StationModes;
DROP TABLE IF EXISTS #StationModeNames;
DROP TABLE IF EXISTS #ChildPositionStats;
DROP TABLE IF EXISTS #PatternStats;
DROP TABLE IF EXISTS #OccurrenceStats;
DROP TABLE IF EXISTS #EligibleStations;
DROP TABLE IF EXISTS #EligibleWithTargets;
DROP TABLE IF EXISTS #ScoredStations;
DROP TABLE IF EXISTS #RankedStations;
DROP TABLE IF EXISTS #RankedGeoStations;
DROP TABLE IF EXISTS #AnchorCandidates;
DROP TABLE IF EXISTS #GeoAnchors;
DROP TABLE IF EXISTS #PanelCandidates;
DROP TABLE IF EXISTS #PanelSelected;
DROP TABLE IF EXISTS #PanelOrdered;
DROP TABLE IF EXISTS #PanelFinal;
DROP TABLE IF EXISTS #PanelMembership;

/*
    One row per scheduled stop-event pattern at a child stop position.  The
    child-to-parent relationship is resolved before any service-date join so
    later occurrence counts cannot multiply station rows accidentally.
*/
SELECT
    child_stop.ParentStopKey AS ParentStationKey,
    stop_event.StopKey,
    stop_event.ScheduledStopEventKey,
    stop_event.TripKey,
    stop_event.RouteKey,
    stop_event.ModeKey,
    stop_event.ServiceKey,
    COALESCE(stop_event.AgencyKey, route.AgencyKey) AS AgencyKey,
    mode_dimension.ModeDetail,
    mode_dimension.ModeSortOrder,
    mode_dimension.IsRailReplacementService
INTO #StationEventPattern
FROM dw.FactScheduledStopEvent AS stop_event
INNER JOIN dw.DimStop AS child_stop
    ON child_stop.StopKey = stop_event.StopKey
INNER JOIN dw.DimRoute AS route
    ON route.RouteKey = stop_event.RouteKey
INNER JOIN dw.DimMode AS mode_dimension
    ON mode_dimension.ModeKey = stop_event.ModeKey
WHERE child_stop.LocationTypeCode = 0
  AND child_stop.ParentStopKey IS NOT NULL;

CREATE CLUSTERED INDEX IX_StationEventPattern_ParentEvent
    ON #StationEventPattern (ParentStationKey, ScheduledStopEventKey);

CREATE INDEX IX_StationEventPattern_ParentService
    ON #StationEventPattern (ParentStationKey, ServiceKey)
    INCLUDE (TripKey, RouteKey, ModeKey, AgencyKey, IsRailReplacementService);

/* Distinct station/mode pairs for auditable mode labels and coverage counts. */
SELECT DISTINCT
    ParentStationKey,
    ModeKey,
    ModeDetail,
    ModeSortOrder,
    IsRailReplacementService
INTO #StationModes
FROM #StationEventPattern;

CREATE INDEX IX_StationModes_Parent
    ON #StationModes (ParentStationKey, ModeKey);

SELECT
    ParentStationKey,
    STRING_AGG(CONVERT(NVARCHAR(MAX), ModeDetail), N', ')
        WITHIN GROUP (ORDER BY ModeSortOrder, ModeDetail) AS ModeNames,
    STRING_AGG(CONVERT(NVARCHAR(MAX), CASE
            WHEN IsRailReplacementService = 0 THEN ModeDetail END), N', ')
        WITHIN GROUP (ORDER BY ModeSortOrder, ModeDetail) AS RegularModeNames,
    STRING_AGG(CONVERT(NVARCHAR(MAX), CASE
            WHEN IsRailReplacementService = 1 THEN ModeDetail END), N', ')
        WITHIN GROUP (ORDER BY ModeSortOrder, ModeDetail) AS SevModeNames
INTO #StationModeNames
FROM #StationModes
GROUP BY ParentStationKey;

CREATE UNIQUE CLUSTERED INDEX UX_StationModeNames_Parent
    ON #StationModeNames (ParentStationKey);

SELECT
    ParentStopKey AS ParentStationKey,
    COUNT_BIG(*) AS ChildStopPositionCount
INTO #ChildPositionStats
FROM dw.DimStop
WHERE LocationTypeCode = 0
  AND ParentStopKey IS NOT NULL
GROUP BY ParentStopKey;

SELECT
    ParentStationKey,
    COUNT_BIG(DISTINCT ScheduledStopEventKey)
        AS ScheduledStopEventPatternCount,
    COUNT_BIG(DISTINCT TripKey) AS ScheduledTripPatternCount,
    COUNT_BIG(DISTINCT RouteKey) AS ServedRouteCount,
    COUNT_BIG(DISTINCT CASE
        WHEN IsRailReplacementService = 0 THEN RouteKey END)
        AS RegularServedRouteCount,
    COUNT_BIG(DISTINCT CASE
        WHEN IsRailReplacementService = 1 THEN RouteKey END)
        AS SevRouteCount,
    COUNT_BIG(DISTINCT ModeKey) AS ModeCount,
    COUNT_BIG(DISTINCT CASE
        WHEN IsRailReplacementService = 0 THEN ModeKey END)
        AS RegularModeCount,
    COUNT_BIG(DISTINCT AgencyKey) AS AgencyCount,
    COUNT_BIG(DISTINCT CASE
        WHEN IsRailReplacementService = 0 THEN AgencyKey END)
        AS RegularAgencyCount,
    COUNT_BIG(DISTINCT StopKey) AS UsedStopPositionCount,
    COUNT_BIG(DISTINCT CASE
        WHEN IsRailReplacementService = 0 THEN StopKey END)
        AS RegularUsedStopPositionCount
INTO #PatternStats
FROM #StationEventPattern
GROUP BY ParentStationKey;

/*
    A fact stop-event pattern joined to BridgeServiceDate is one scheduled
    stop-event occurrence on one active service date.  BridgeServiceDate is
    unique on (ServiceKey, DateKey), so this is a controlled one-to-many join.
*/
SELECT
    event_pattern.ParentStationKey,
    COUNT_BIG(*) AS ScheduledStopEventOccurrenceCount,
    SUM(CONVERT(BIGINT, CASE
        WHEN event_pattern.IsRailReplacementService = 0 THEN 1
        ELSE 0 END)) AS RegularScheduledStopEventOccurrenceCount,
    COUNT_BIG(DISTINCT service_date.DateKey) AS ActiveServiceDateCount
INTO #OccurrenceStats
FROM #StationEventPattern AS event_pattern
INNER JOIN dw.BridgeServiceDate AS service_date
    ON service_date.ServiceKey = event_pattern.ServiceKey
GROUP BY event_pattern.ParentStationKey;

/* Eligibility is limited to used parent stations with a valid identity and geography. */
SELECT
    parent_stop.StopKey AS ParentStationKey,
    parent_stop.StopId AS ParentStationId,
    parent_stop.StopName AS ParentStationName,
    parent_stop.Latitude,
    parent_stop.Longitude,
    child_stats.ChildStopPositionCount,
    pattern_stats.ScheduledStopEventPatternCount,
    pattern_stats.ScheduledTripPatternCount,
    pattern_stats.UsedStopPositionCount,
    pattern_stats.ServedRouteCount,
    pattern_stats.RegularServedRouteCount,
    pattern_stats.SevRouteCount,
    pattern_stats.ModeCount,
    pattern_stats.RegularModeCount,
    pattern_stats.AgencyCount,
    pattern_stats.RegularAgencyCount,
    pattern_stats.RegularUsedStopPositionCount,
    occurrence_stats.ScheduledStopEventOccurrenceCount,
    occurrence_stats.RegularScheduledStopEventOccurrenceCount,
    occurrence_stats.ActiveServiceDateCount,
    CONVERT(DECIMAL(18, 2),
        CONVERT(DECIMAL(28, 6), occurrence_stats.ScheduledStopEventOccurrenceCount)
        / NULLIF(occurrence_stats.ActiveServiceDateCount, 0)
    ) AS AverageScheduledStopEventsPerActiveDay,
    CONVERT(DECIMAL(18, 2),
        CONVERT(DECIMAL(28, 6), occurrence_stats.RegularScheduledStopEventOccurrenceCount)
        / NULLIF(occurrence_stats.ActiveServiceDateCount, 0)
    ) AS RegularAverageScheduledStopEventsPerActiveDay,
    mode_names.ModeNames,
    mode_names.RegularModeNames,
    mode_names.SevModeNames
INTO #EligibleStations
FROM dw.DimStop AS parent_stop
INNER JOIN #ChildPositionStats AS child_stats
    ON child_stats.ParentStationKey = parent_stop.StopKey
INNER JOIN #PatternStats AS pattern_stats
    ON pattern_stats.ParentStationKey = parent_stop.StopKey
INNER JOIN #OccurrenceStats AS occurrence_stats
    ON occurrence_stats.ParentStationKey = parent_stop.StopKey
LEFT JOIN #StationModeNames AS mode_names
    ON mode_names.ParentStationKey = parent_stop.StopKey
WHERE parent_stop.LocationTypeCode = 1
  AND NULLIF(LTRIM(RTRIM(parent_stop.StopId)), N'') IS NOT NULL
  AND parent_stop.Latitude IS NOT NULL
  AND parent_stop.Longitude IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_EligibleStations_Key
    ON #EligibleStations (ParentStationKey);

SELECT
    eligible.*,
    CONVERT(BIT, CASE WHEN sampling_target.SamplingTargetId IS NULL
                      THEN 0 ELSE 1 END) AS IsExistingRealtimeTarget,
    sampling_target.SamplingTargetId AS ExistingSamplingTargetId,
    sampling_target.TargetName AS ExistingSamplingTargetName
INTO #EligibleWithTargets
FROM #EligibleStations AS eligible
LEFT JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
    ON sampling_target.StopPointRef = eligible.ParentStationId
   AND sampling_target.IsEnabled = 1;

CREATE UNIQUE CLUSTERED INDEX UX_EligibleWithTargets_Key
    ON #EligibleWithTargets (ParentStationKey);

/* Percentile inputs deliberately use regular/non-SEV service metrics. */
SELECT
    eligible.*,
    CONVERT(DECIMAL(12, 8), PERCENT_RANK() OVER
        (ORDER BY RegularScheduledStopEventOccurrenceCount))
        AS ServiceVolumePercentile,
    CONVERT(DECIMAL(12, 8), PERCENT_RANK() OVER
        (ORDER BY RegularServedRouteCount))
        AS RouteDiversityPercentile,
    CONVERT(DECIMAL(12, 8), PERCENT_RANK() OVER
        (ORDER BY RegularModeCount))
        AS ModeDiversityPercentile,
    CONVERT(DECIMAL(12, 8), PERCENT_RANK() OVER
        (ORDER BY RegularAgencyCount))
        AS AgencyDiversityPercentile,
    CONVERT(DECIMAL(12, 8), PERCENT_RANK() OVER
        (ORDER BY RegularUsedStopPositionCount))
        AS StopPositionPercentile,
    CONVERT(DECIMAL(10, 2), ROUND(
          40.0 * PERCENT_RANK() OVER (ORDER BY RegularScheduledStopEventOccurrenceCount)
        + 25.0 * PERCENT_RANK() OVER (ORDER BY RegularServedRouteCount)
        + 15.0 * PERCENT_RANK() OVER (ORDER BY RegularModeCount)
        + 10.0 * PERCENT_RANK() OVER (ORDER BY RegularAgencyCount)
        + 10.0 * PERCENT_RANK() OVER (ORDER BY RegularUsedStopPositionCount), 2))
        AS BaseImportanceScore
INTO #ScoredStations
FROM #EligibleWithTargets AS eligible;

CREATE UNIQUE CLUSTERED INDEX UX_ScoredStations_Key
    ON #ScoredStations (ParentStationKey);

SELECT
    scored.*,
    ROW_NUMBER() OVER
    (
        ORDER BY
            scored.BaseImportanceScore DESC,
            scored.RegularScheduledStopEventOccurrenceCount DESC,
            scored.RegularServedRouteCount DESC,
            scored.ParentStationName ASC,
            scored.ParentStationKey ASC
    ) AS RawImportanceRank
INTO #RankedStations
FROM #ScoredStations AS scored;

CREATE UNIQUE CLUSTERED INDEX UX_RankedStations_Rank
    ON #RankedStations (RawImportanceRank);

/* Four latitude and four longitude NTILE bands create the balancing grid. */
WITH GeographicBands AS
(
    SELECT
        ranked.*,
        NTILE(4) OVER (ORDER BY ranked.Latitude, ranked.ParentStationKey)
            AS LatitudeBand,
        NTILE(4) OVER (ORDER BY ranked.Longitude, ranked.ParentStationKey)
            AS LongitudeBand
    FROM #RankedStations AS ranked
)
SELECT
    geographic_bands.*,
    CONCAT(
        CONVERT(NVARCHAR(10), geographic_bands.LatitudeBand),
        N'-',
        CONVERT(NVARCHAR(10), geographic_bands.LongitudeBand)
    ) AS GeographicCell
INTO #RankedGeoStations
FROM GeographicBands AS geographic_bands;

CREATE UNIQUE CLUSTERED INDEX UX_RankedGeoStations_Key
    ON #RankedGeoStations (ParentStationKey);

/* One anchor per occupied cell, only when it clears both anchor thresholds. */
WITH AnchorCandidates AS
(
    SELECT
        ranked_geo.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY ranked_geo.GeographicCell
            ORDER BY
                ranked_geo.BaseImportanceScore DESC,
                ranked_geo.RegularScheduledStopEventOccurrenceCount DESC,
                ranked_geo.RegularServedRouteCount DESC,
                ranked_geo.ParentStationName ASC,
                ranked_geo.ParentStationKey ASC
        ) AS CellAnchorRank
    FROM #RankedGeoStations AS ranked_geo
    WHERE ranked_geo.ServiceVolumePercentile >= CONVERT(DECIMAL(12, 8), 0.25)
      AND ranked_geo.RawImportanceRank <= 100
)
SELECT *
INTO #AnchorCandidates
FROM AnchorCandidates;

SELECT
    anchor_candidates.ParentStationKey,
    anchor_candidates.GeographicCell
INTO #GeoAnchors
FROM #AnchorCandidates AS anchor_candidates
WHERE anchor_candidates.CellAnchorRank = 1;

DECLARE @AnchorCount BIGINT = (SELECT COUNT_BIG(*) FROM #GeoAnchors);

/* Fill remaining positions by composite importance, excluding anchors. */
WITH Unanchored AS
(
    SELECT
        ranked_geo.ParentStationKey,
        ROW_NUMBER() OVER
        (
            ORDER BY
                ranked_geo.BaseImportanceScore DESC,
                ranked_geo.RegularScheduledStopEventOccurrenceCount DESC,
                ranked_geo.RegularServedRouteCount DESC,
                ranked_geo.ParentStationName ASC,
                ranked_geo.ParentStationKey ASC
        ) AS FillOrder
    FROM #RankedGeoStations AS ranked_geo
    LEFT JOIN #GeoAnchors AS anchors
        ON anchors.ParentStationKey = ranked_geo.ParentStationKey
    WHERE anchors.ParentStationKey IS NULL
)
SELECT
    ranked_geo.*,
    CONVERT(BIT, 1) AS IsGeographicAnchor,
    CONVERT(BIGINT, 0) AS FillOrder
INTO #PanelCandidates
FROM #RankedGeoStations AS ranked_geo
INNER JOIN #GeoAnchors AS anchors
    ON anchors.ParentStationKey = ranked_geo.ParentStationKey
UNION ALL
SELECT
    ranked_geo.*,
    CONVERT(BIT, 0),
    CONVERT(BIGINT, unanchored.FillOrder)
FROM Unanchored AS unanchored
INNER JOIN #RankedGeoStations AS ranked_geo
    ON ranked_geo.ParentStationKey = unanchored.ParentStationKey;

SELECT *
INTO #PanelSelected
FROM #PanelCandidates
WHERE IsGeographicAnchor = 1
   OR FillOrder <= CONVERT(BIGINT, @PanelSize) - @AnchorCount;

WITH OrderedPanel AS
(
    SELECT
        panel_selected.*,
        ROW_NUMBER() OVER
        (
            ORDER BY
                panel_selected.BaseImportanceScore DESC,
                panel_selected.ParentStationName ASC,
                panel_selected.ParentStationKey ASC
        ) AS RecommendedRank
    FROM #PanelSelected AS panel_selected
)
SELECT
    ordered_panel.*,
    CASE
        WHEN ordered_panel.RecommendedRank <= 10 THEN N'Tier A'
        WHEN ordered_panel.RecommendedRank <= 30 THEN N'Tier B'
        ELSE N'Tier C'
    END AS ProposedTier,
    CASE
        WHEN ordered_panel.RecommendedRank <= 10 THEN 10
        WHEN ordered_panel.RecommendedRank <= 30 THEN 15
        ELSE 30
    END AS ProposedIntervalMinutes
INTO #PanelFinal
FROM OrderedPanel AS ordered_panel;

CREATE UNIQUE CLUSTERED INDEX UX_PanelFinal_Key
    ON #PanelFinal (ParentStationKey);

SELECT
    N'Raw Top 50' AS PanelName,
    raw_top.ParentStationKey,
    raw_top.GeographicCell
INTO #PanelMembership
FROM #RankedGeoStations AS raw_top
WHERE raw_top.RawImportanceRank <= @PanelSize
UNION ALL
SELECT
    N'Recommended Balanced Top 50',
    balanced.ParentStationKey,
    balanced.GeographicCell
FROM #PanelFinal AS balanced;

CREATE INDEX IX_PanelMembership_Panel
    ON #PanelMembership (PanelName, ParentStationKey);

-- O5_SETUP_END

-- O5_RESULT NetworkBaseline
SELECT
    (SELECT COUNT_BIG(*)
     FROM dw.DimStop
     WHERE LocationTypeCode = 1) AS TotalParentStations,
    (SELECT COUNT_BIG(*)
     FROM analytics.vwParentStationScheduleProfile
     WHERE IsUsedInCurrentSchedule = 1) AS UsedParentStations,
    (SELECT COUNT_BIG(*) FROM #EligibleStations) AS EligibleRealtimeCandidates,
    (SELECT COUNT_BIG(*) FROM ctl.MddRealtimeSamplingTarget)
        AS CurrentRealtimeSamplingTargetCount,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget
     WHERE IsEnabled = 1) AS EnabledRealtimeTargetCount;

-- O5_RESULT EligibleStationAnalysis
SELECT
    ranked.RawImportanceRank,
    ranked.ParentStationKey,
    ranked.ParentStationId,
    ranked.ParentStationName,
    ranked.Latitude,
    ranked.Longitude,
    ranked.ChildStopPositionCount,
    ranked.UsedStopPositionCount,
    ranked.ServedRouteCount,
    ranked.RegularServedRouteCount,
    ranked.SevRouteCount,
    ranked.ModeCount,
    ranked.RegularModeCount,
    ranked.RegularAgencyCount,
    ranked.RegularUsedStopPositionCount,
    ranked.ModeNames,
    ranked.RegularModeNames,
    ranked.SevModeNames,
    ranked.AgencyCount,
    ranked.ScheduledTripPatternCount,
    ranked.ScheduledStopEventPatternCount,
    ranked.ScheduledStopEventOccurrenceCount,
    ranked.RegularScheduledStopEventOccurrenceCount,
    ranked.ActiveServiceDateCount,
    ranked.AverageScheduledStopEventsPerActiveDay,
    ranked.RegularAverageScheduledStopEventsPerActiveDay,
    ranked.IsExistingRealtimeTarget,
    ranked.ExistingSamplingTargetId,
    ranked.ExistingSamplingTargetName,
    ranked.ServiceVolumePercentile,
    ranked.RouteDiversityPercentile,
    ranked.ModeDiversityPercentile,
    ranked.AgencyDiversityPercentile,
    ranked.StopPositionPercentile,
    ranked.BaseImportanceScore,
    ranked.LatitudeBand,
    ranked.LongitudeBand,
    ranked.GeographicCell
FROM #RankedGeoStations AS ranked
ORDER BY ranked.RawImportanceRank;

-- O5_RESULT RawTop50
SELECT
    ranked.RawImportanceRank,
    ranked.ParentStationKey,
    ranked.ParentStationId,
    ranked.ParentStationName,
    ranked.BaseImportanceScore,
    ranked.RegularScheduledStopEventOccurrenceCount,
    ranked.AverageScheduledStopEventsPerActiveDay,
    ranked.RegularServedRouteCount,
    ranked.RegularModeCount,
    ranked.RegularAgencyCount,
    ranked.RegularUsedStopPositionCount,
    ranked.ModeNames,
    ranked.AgencyCount,
    ranked.UsedStopPositionCount,
    ranked.GeographicCell,
    ranked.IsExistingRealtimeTarget,
    ranked.ServiceVolumePercentile,
    ranked.RouteDiversityPercentile,
    ranked.ModeDiversityPercentile,
    ranked.AgencyDiversityPercentile,
    ranked.StopPositionPercentile
FROM #RankedGeoStations AS ranked
WHERE ranked.RawImportanceRank <= @PanelSize
ORDER BY
    ranked.BaseImportanceScore DESC,
    ranked.RegularScheduledStopEventOccurrenceCount DESC,
    ranked.RegularServedRouteCount DESC,
    ranked.ParentStationName ASC,
    ranked.ParentStationKey ASC;

-- O5_RESULT BalancedRecommendedTop50
SELECT
    balanced.RecommendedRank,
    balanced.ParentStationKey,
    balanced.ParentStationId,
    balanced.ParentStationName,
    balanced.BaseImportanceScore,
    balanced.RegularScheduledStopEventOccurrenceCount,
    balanced.AverageScheduledStopEventsPerActiveDay,
    balanced.RegularServedRouteCount,
    balanced.RegularModeCount,
    balanced.RegularAgencyCount,
    balanced.RegularUsedStopPositionCount,
    balanced.ModeNames,
    balanced.AgencyCount,
    balanced.UsedStopPositionCount,
    balanced.GeographicCell,
    balanced.IsExistingRealtimeTarget,
    balanced.ProposedTier,
    balanced.ProposedIntervalMinutes,
    CONVERT(NVARCHAR(100), CASE
        WHEN balanced.IsGeographicAnchor = 1
            THEN N'Geographic coverage anchor'
        WHEN balanced.ServiceVolumePercentile >= CONVERT(DECIMAL(12, 8), 0.75)
             AND balanced.RegularModeCount >= 2
            THEN N'High service volume / multimodal'
        WHEN balanced.ServiceVolumePercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High service volume'
        WHEN balanced.RouteDiversityPercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High route diversity'
        WHEN balanced.ModeDiversityPercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High mode diversity'
        ELSE N'High composite importance score'
    END) AS SelectionReason,
    CASE
        WHEN balanced.IsGeographicAnchor = 1
            THEN N'Eligible geographic anchor'
        ELSE N'Not anchor - importance fill'
    END AS AnchorEligibility,
    balanced.RawImportanceRank,
    balanced.ServiceVolumePercentile,
    balanced.RouteDiversityPercentile,
    balanced.ModeDiversityPercentile,
    balanced.AgencyDiversityPercentile,
    balanced.StopPositionPercentile,
    balanced.LatitudeBand,
    balanced.LongitudeBand
FROM #PanelFinal AS balanced
ORDER BY
    balanced.RecommendedRank ASC;

-- O5_RESULT GeographicAnchorAudit
WITH GeographicCells AS
(
    SELECT DISTINCT
        ranked_geo.GeographicCell
    FROM #RankedGeoStations AS ranked_geo
),
EligibleAnchorCounts AS
(
    SELECT
        cells.GeographicCell,
        COUNT_BIG(anchor_candidate.ParentStationKey) AS EligibleAnchorCount
    FROM GeographicCells AS cells
    LEFT JOIN #AnchorCandidates AS anchor_candidate
        ON anchor_candidate.GeographicCell = cells.GeographicCell
    GROUP BY cells.GeographicCell
)
SELECT
    balanced.ParentStationId,
    balanced.ParentStationName,
    balanced.GeographicCell,
    balanced.BaseImportanceScore,
    balanced.RawImportanceRank,
    balanced.ServiceVolumePercentile,
    balanced.RecommendedRank,
    eligible_counts.EligibleAnchorCount
FROM #PanelFinal AS balanced
INNER JOIN EligibleAnchorCounts AS eligible_counts
    ON eligible_counts.GeographicCell = balanced.GeographicCell
WHERE balanced.IsGeographicAnchor = 1
UNION ALL
SELECT
    NULL AS ParentStationId,
    NULL AS ParentStationName,
    eligible_counts.GeographicCell,
    NULL AS BaseImportanceScore,
    NULL AS RawImportanceRank,
    NULL AS ServiceVolumePercentile,
    NULL AS RecommendedRank,
    eligible_counts.EligibleAnchorCount
FROM EligibleAnchorCounts AS eligible_counts
WHERE eligible_counts.EligibleAnchorCount = 0
ORDER BY GeographicCell, RawImportanceRank;

-- O5_RESULT Top100ReviewBuffer
SELECT
    ranked.RawImportanceRank,
    ranked.ParentStationKey,
    ranked.ParentStationId,
    ranked.ParentStationName,
    ranked.BaseImportanceScore,
    ranked.RegularScheduledStopEventOccurrenceCount,
    ranked.RegularServedRouteCount,
    ranked.RegularModeCount,
    ranked.RegularAgencyCount,
    ranked.RegularUsedStopPositionCount,
    ranked.ModeNames,
    ranked.AgencyCount,
    ranked.UsedStopPositionCount,
    ranked.GeographicCell,
    ranked.IsExistingRealtimeTarget
FROM #RankedGeoStations AS ranked
WHERE ranked.RawImportanceRank <= 100
ORDER BY ranked.RawImportanceRank;

-- O5_RESULT ModeCoverageByPanel
SELECT
    membership.PanelName,
    station_mode.ModeDetail,
    station_mode.IsRailReplacementService,
    CASE WHEN station_mode.IsRailReplacementService = 1
         THEN N'SEV' ELSE N'Regular' END AS ServiceClass,
    COUNT_BIG(DISTINCT membership.ParentStationKey) AS SelectedStationCount
FROM #PanelMembership AS membership
INNER JOIN #StationModes AS station_mode
    ON station_mode.ParentStationKey = membership.ParentStationKey
GROUP BY
    membership.PanelName,
    station_mode.ModeDetail,
    station_mode.IsRailReplacementService
ORDER BY membership.PanelName, station_mode.IsRailReplacementService, station_mode.ModeDetail;

-- O5_RESULT ModeDiversityAssessment
WITH PanelModeCounts AS
(
    SELECT
        membership.PanelName,
        COUNT_BIG(DISTINCT CASE WHEN station_mode.IsRailReplacementService = 0
                                THEN station_mode.ModeKey END)
            AS RegularModeDetailsRepresented,
        COUNT_BIG(DISTINCT CASE WHEN station_mode.IsRailReplacementService = 1
                                THEN station_mode.ModeKey END)
            AS SevModeDetailsRepresented,
        COUNT_BIG(DISTINCT station_mode.ModeKey) AS AllModeDetailsRepresented,
        COUNT_BIG(DISTINCT CASE WHEN station_mode.IsRailReplacementService = 1
                                THEN membership.ParentStationKey END)
            AS StationsWithSevService
    FROM #PanelMembership AS membership
    INNER JOIN #StationModes AS station_mode
        ON station_mode.ParentStationKey = membership.ParentStationKey
    GROUP BY membership.PanelName
)
SELECT
    raw.RegularModeDetailsRepresented AS RawTop50RegularModeDetails,
    balanced.RegularModeDetailsRepresented AS BalancedTop50RegularModeDetails,
    balanced.RegularModeDetailsRepresented - raw.RegularModeDetailsRepresented
        AS BalancedMinusRawRegularModeDetailDelta,
    raw.SevModeDetailsRepresented AS RawTop50SevModeDetails,
    balanced.SevModeDetailsRepresented AS BalancedTop50SevModeDetails,
    raw.AllModeDetailsRepresented AS RawTop50AllModeDetails,
    balanced.AllModeDetailsRepresented AS BalancedTop50AllModeDetails,
    raw.StationsWithSevService AS RawTop50StationsWithSevService,
    balanced.StationsWithSevService AS BalancedTop50StationsWithSevService,
    CASE WHEN balanced.RegularModeDetailsRepresented
               > raw.RegularModeDetailsRepresented
         THEN N'Yes — balanced panel represents more distinct regular mode details'
         ELSE N'No — balanced panel does not increase distinct regular mode details'
    END AS RegularModeDiversityAssessment
FROM PanelModeCounts AS raw
INNER JOIN PanelModeCounts AS balanced
    ON balanced.PanelName = N'Recommended Balanced Top 50'
WHERE raw.PanelName = N'Raw Top 50';

-- O5_RESULT GeographicCoverageByPanel
SELECT
    membership.PanelName,
    membership.GeographicCell,
    COUNT_BIG(*) AS SelectedStationCount
FROM #PanelMembership AS membership
GROUP BY membership.PanelName, membership.GeographicCell
ORDER BY membership.PanelName, membership.GeographicCell;

-- O5_RESULT GeographicCoverageSummary
SELECT
    membership.PanelName,
    COUNT_BIG(DISTINCT membership.GeographicCell)
        AS OccupiedGeographicCellsRepresented,
    COUNT_BIG(DISTINCT membership.ParentStationKey) AS SelectedStationCount
FROM #PanelMembership AS membership
GROUP BY membership.PanelName
ORDER BY membership.PanelName;

-- O5_RESULT CurrentEnabledTargetRankings
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName,
    COALESCE(ranked.ParentStationName, sampling_target.TargetName)
        AS ParentStationName,
    ranked.RawImportanceRank,
    panel.RecommendedRank,
    ranked.BaseImportanceScore,
    CONVERT(BIT, CASE WHEN panel.ParentStationKey IS NULL
                      THEN 0 ELSE 1 END) AS IsInRecommendedTop50,
    sampling_target.SamplingTargetId AS ExistingSamplingTargetId,
    sampling_target.StopPointRef AS ParentStationId,
    ranked.RegularServedRouteCount,
    ranked.RegularModeCount,
    ranked.RegularAgencyCount,
    ranked.RegularUsedStopPositionCount,
    ranked.RegularScheduledStopEventOccurrenceCount,
    sampling_target.TargetName AS ExistingSamplingTargetName
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN #RankedGeoStations AS ranked
    ON ranked.ParentStationId = sampling_target.StopPointRef
LEFT JOIN #PanelFinal AS panel
    ON panel.ParentStationKey = ranked.ParentStationKey
WHERE sampling_target.IsEnabled = 1
ORDER BY sampling_target.SamplingTargetId;

-- O5_RESULT CurrentEnabledRealtimeTargetSummary
SELECT
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget
     WHERE IsEnabled = 1) AS CurrentEnabledRealtimeTargetCount,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget AS sampling_target
     WHERE sampling_target.IsEnabled = 1
       AND EXISTS
       (
           SELECT 1
           FROM #PanelFinal AS panel
           WHERE panel.ParentStationId = sampling_target.StopPointRef
       )) AS ExistingRealtimeTargetsInFinal50,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget AS sampling_target
     WHERE sampling_target.IsEnabled = 1
       AND NOT EXISTS
       (
           SELECT 1
           FROM #PanelFinal AS panel
           WHERE panel.ParentStationId = sampling_target.StopPointRef
       )) AS EnabledRealtimeTargetsMissingFromFinal50;

-- O5_RESULT QuotaProjection
WITH TierInputs AS
(
    SELECT N'Tier A' AS TierName, CONVERT(BIGINT, 10) AS StationCount,
           CONVERT(INT, 10) AS IntervalMinutes
    UNION ALL
    SELECT N'Tier B', CONVERT(BIGINT, 20), CONVERT(INT, 15)
    UNION ALL
    SELECT N'Tier C', CONVERT(BIGINT, 20), CONVERT(INT, 30)
),
TierProjection AS
(
    SELECT
        TierName,
        StationCount,
        IntervalMinutes,
        StationCount * (60 / IntervalMinutes) * 24 * 30
            AS RequestsPerMonth
    FROM TierInputs
)
SELECT
    TierName,
    StationCount,
    IntervalMinutes AS ProposedIntervalMinutes,
    RequestsPerMonth,
    @QuotaLimit AS MonthlyQuotaLimit,
    @QuotaLimit - SUM(RequestsPerMonth) OVER () AS RemainingHeadroomRequests,
    CONVERT(DECIMAL(10, 2),
        100.0 * (@QuotaLimit - SUM(RequestsPerMonth) OVER ()) / @QuotaLimit
    ) AS RemainingQuotaPercent,
    N'Base estimate; retries excluded' AS EstimateNote
FROM TierProjection
UNION ALL
SELECT
    N'Total',
    SUM(StationCount),
    NULL,
    SUM(RequestsPerMonth),
    @QuotaLimit,
    @QuotaLimit - SUM(RequestsPerMonth),
    CONVERT(DECIMAL(10, 2),
        100.0 * (@QuotaLimit - SUM(RequestsPerMonth)) / @QuotaLimit
    ),
    N'Base estimate; retries excluded'
FROM TierProjection;

-- O5_RESULT QuotaHeadroomByUseCase
WITH TotalProjection AS
(
    SELECT CONVERT(BIGINT, 10) * (60 / 10) * 24 * 30
         + CONVERT(BIGINT, 20) * (60 / 15) * 24 * 30
         + CONVERT(BIGINT, 20) * (60 / 30) * 24 * 30 AS RequestsPerMonth
)
SELECT
    use_case.UseCase,
    @QuotaLimit - total_projection.RequestsPerMonth AS AvailableHeadroomRequests,
    CONVERT(DECIMAL(10, 2),
        100.0 * (@QuotaLimit - total_projection.RequestsPerMonth) / @QuotaLimit
    ) AS AvailableQuotaPercent,
    N'Unallocated headroom; percentages are not additive across use cases'
        AS AllocationNote
FROM (VALUES
    (N'Retries'),
    (N'Manual tests'),
    (N'Temporary diagnostics'),
    (N'Future expansion')
) AS use_case(UseCase)
CROSS JOIN TotalProjection AS total_projection;

-- O5_RESULT ValidationResults
SELECT
    (SELECT COUNT_BIG(*) FROM #RankedGeoStations) AS EligibleRowCount,
    (SELECT COUNT_BIG(DISTINCT ParentStationKey) FROM #RankedGeoStations)
        AS DistinctEligibleParentStationKeyCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal) AS FinalRecommendedCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal) AS FinalPanelCount,
    (SELECT COUNT_BIG(DISTINCT ParentStationKey) FROM #PanelFinal)
        AS DistinctParentStationKeyCount,
    (SELECT COUNT_BIG(DISTINCT ParentStationId) FROM #PanelFinal)
        AS DistinctParentStationIdCount,
    (SELECT COUNT_BIG(DISTINCT ParentStationKey) FROM #PanelFinal)
        AS FinalDistinctParentStationKeyCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier A')
        AS TierACount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier A')
        AS TierAStationCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier B')
        AS TierBCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier B')
        AS TierBStationCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier C')
        AS TierCCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal WHERE ProposedTier = N'Tier C')
        AS TierCStationCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE NULLIF(LTRIM(RTRIM(ParentStationId)), N'') IS NULL)
        AS InvalidParentStationIdCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE NULLIF(LTRIM(RTRIM(ParentStationId)), N'') IS NULL)
        AS FinalNullOrBlankParentStationIdCount,
    (SELECT COUNT_BIG(*) FROM
        (SELECT ParentStationId
         FROM #PanelFinal
         GROUP BY ParentStationId
         HAVING COUNT_BIG(*) > 1) AS duplicate_ids)
        AS DuplicateParentStationIdCount,
    (SELECT COUNT_BIG(*) FROM
        (SELECT ParentStationId
         FROM #PanelFinal
         GROUP BY ParentStationId
         HAVING COUNT_BIG(*) > 1) AS duplicate_ids)
        AS FinalDuplicateParentStationIdValueCount,
    (SELECT COUNT_BIG(*) FROM
        (SELECT ParentStationKey
         FROM #PanelFinal
         GROUP BY ParentStationKey
         HAVING COUNT_BIG(*) > 1) AS duplicate_keys)
        AS DuplicateParentStationKeyCount,
    (SELECT COUNT_BIG(*) FROM
        (SELECT ParentStationKey
         FROM #PanelFinal
         GROUP BY ParentStationKey
         HAVING COUNT_BIG(*) > 1) AS duplicate_keys)
        AS FinalDuplicateParentStationKeyValueCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
     WHERE NOT EXISTS
     (
         SELECT 1
         FROM analytics.vwParentStationScheduleProfile AS schedule_profile
         WHERE schedule_profile.ParentStationKey = panel.ParentStationKey
           AND schedule_profile.IsUsedInCurrentSchedule = 1
     )) AS InvalidScheduleActiveStationCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
     WHERE NOT EXISTS
     (
         SELECT 1
         FROM analytics.vwParentStationScheduleProfile AS schedule_profile
         WHERE schedule_profile.ParentStationKey = panel.ParentStationKey
           AND schedule_profile.IsUsedInCurrentSchedule = 1
     )) AS FinalUnusedScheduleViolationCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE RegularScheduledStopEventOccurrenceCount IS NULL
        OR RegularScheduledStopEventOccurrenceCount <= 0)
        AS InvalidRegularScheduledServiceCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE Latitude IS NULL OR Longitude IS NULL) AS FinalMissingCoordinateCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE Latitude IS NULL OR Longitude IS NULL) AS InvalidCoordinateCount,
    (SELECT MIN(BaseImportanceScore) FROM #PanelFinal)
        AS MinFinalBaseImportanceScore,
    (SELECT MAX(BaseImportanceScore) FROM #PanelFinal)
        AS MaxFinalBaseImportanceScore,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE BaseImportanceScore < 0 OR BaseImportanceScore > 100
        OR BaseImportanceScore IS NULL) AS InvalidFinalScoreCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
     WHERE panel.IsGeographicAnchor = 1
       AND (panel.RawImportanceRank > 100
            OR panel.ServiceVolumePercentile < CONVERT(DECIMAL(12, 8), 0.25)))
        AS InvalidGeographicAnchorCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal
     WHERE IsGeographicAnchor = 1) AS GeographicAnchorCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
     WHERE panel.IsGeographicAnchor = 1
       AND panel.RawImportanceRank > 100)
        AS GeographicAnchorsOutsideRawTop100Count,
    (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
     WHERE panel.IsGeographicAnchor = 1
       AND panel.ServiceVolumePercentile < CONVERT(DECIMAL(12, 8), 0.25))
        AS GeographicAnchorsBelowServiceVolumeThresholdCount,
    (SELECT COUNT_BIG(*) FROM #RankedGeoStations
     WHERE BaseImportanceScore < 0 OR BaseImportanceScore > 100)
        AS ScoreOutsideZeroTo100Count,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget
     WHERE IsEnabled = 1) AS CurrentEnabledRealtimeTargetCount,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget AS sampling_target
     WHERE sampling_target.IsEnabled = 1
       AND EXISTS
       (
           SELECT 1
           FROM #PanelFinal AS panel
           WHERE panel.ParentStationId = sampling_target.StopPointRef
       )) AS ExistingRealtimeTargetsInFinal50,
    (SELECT COUNT_BIG(*)
     FROM ctl.MddRealtimeSamplingTarget AS sampling_target
     WHERE sampling_target.IsEnabled = 1
       AND NOT EXISTS
       (
           SELECT 1
           FROM #PanelFinal AS panel
           WHERE panel.ParentStationId = sampling_target.StopPointRef
       )) AS EnabledRealtimeTargetsMissingFromFinal50,
    (SELECT COUNT_BIG(*) FROM #RankedStations)
      - (SELECT COUNT_BIG(DISTINCT RawImportanceRank) FROM #RankedStations)
        AS RawRankingDuplicateCount,
    (SELECT COUNT_BIG(*) FROM #PanelFinal)
      - (SELECT COUNT_BIG(DISTINCT RecommendedRank) FROM #PanelFinal)
        AS BalancedRankingDuplicateCount,
    N'Yes — score inputs are RegularScheduledStopEventOccurrenceCount, RegularServedRouteCount, RegularModeCount, RegularAgencyCount, and RegularUsedStopPositionCount; SEV-influenced all-service metrics are diagnostic only'
        AS SevExclusionConfirmation,
    N'Read-only analysis: permanent database objects, warehouse/staging/working data, and sampling configuration were not modified'
        AS MutationScope,
    CASE WHEN (SELECT COUNT_BIG(*) FROM #PanelFinal) = @PanelSize
           AND (SELECT COUNT_BIG(DISTINCT ParentStationKey) FROM #PanelFinal) = @PanelSize
           AND (SELECT COUNT_BIG(DISTINCT ParentStationId) FROM #PanelFinal) = @PanelSize
           AND (SELECT COUNT_BIG(*) FROM
                (SELECT ParentStationKey
                 FROM #PanelFinal
                 GROUP BY ParentStationKey
                 HAVING COUNT_BIG(*) > 1) AS duplicate_keys) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE NULLIF(LTRIM(RTRIM(ParentStationId)), N'') IS NULL) = 0
           AND (SELECT COUNT_BIG(*) FROM
                (SELECT ParentStationId
                 FROM #PanelFinal
                 GROUP BY ParentStationId
                 HAVING COUNT_BIG(*) > 1) AS duplicate_ids) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE RegularScheduledStopEventOccurrenceCount IS NULL
                   OR RegularScheduledStopEventOccurrenceCount <= 0) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE ProposedTier = N'Tier A') = 10
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE ProposedTier = N'Tier B') = 20
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE ProposedTier = N'Tier C') = 20
           AND (SELECT COUNT_BIG(*) FROM
                (SELECT ParentStationId
                 FROM #PanelFinal
                 GROUP BY ParentStationId
                 HAVING COUNT_BIG(*) > 1) AS duplicate_ids) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
                WHERE NOT EXISTS
                (
                    SELECT 1
                    FROM analytics.vwParentStationScheduleProfile AS schedule_profile
                    WHERE schedule_profile.ParentStationKey = panel.ParentStationKey
                      AND schedule_profile.IsUsedInCurrentSchedule = 1
                )) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE Latitude IS NULL OR Longitude IS NULL) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal
                WHERE BaseImportanceScore < 0 OR BaseImportanceScore > 100
                   OR BaseImportanceScore IS NULL) = 0
           AND (SELECT COUNT_BIG(*) FROM #PanelFinal AS panel
                WHERE panel.IsGeographicAnchor = 1
                  AND (panel.RawImportanceRank > 100
                       OR panel.ServiceVolumePercentile < CONVERT(DECIMAL(12, 8), 0.25))) = 0
           AND (SELECT COUNT_BIG(*) FROM #RankedGeoStations
                WHERE BaseImportanceScore < 0 OR BaseImportanceScore > 100) = 0
           AND NOT EXISTS
           (
               SELECT 1
               FROM ctl.MddRealtimeSamplingTarget AS sampling_target
               WHERE sampling_target.IsEnabled = 1
                 AND NOT EXISTS
                 (
                     SELECT 1
                     FROM #PanelFinal AS panel
                     WHERE panel.ParentStationId = sampling_target.StopPointRef
                 )
           )
         THEN N'PASS' ELSE N'REVIEW' END AS ValidationStatus;

-- O5_RESULT BadischeAlleeValidation
SELECT
    CONVERT(BIT, CASE WHEN badische.ParentStationKey IS NULL
                      THEN 0 ELSE 1 END) AS IsBadischeAlleeInFinal50,
    badische.ParentStationName,
    badische.RawImportanceRank,
    badische.BaseImportanceScore,
    badische.IsGeographicAnchor,
    CASE
        WHEN badische.ParentStationKey IS NULL
            THEN N'Not present in Final 50'
        WHEN badische.IsGeographicAnchor = 1
            THEN N'Geographic coverage anchor'
        WHEN badische.ServiceVolumePercentile >= CONVERT(DECIMAL(12, 8), 0.75)
             AND badische.RegularModeCount >= 2
            THEN N'High service volume / multimodal'
        WHEN badische.ServiceVolumePercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High service volume'
        WHEN badische.RouteDiversityPercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High route diversity'
        WHEN badische.ModeDiversityPercentile >= CONVERT(DECIMAL(12, 8), 0.75)
            THEN N'High mode diversity'
        ELSE N'High composite importance score'
    END AS SelectionReason,
    CASE
        WHEN badische.ParentStationKey IS NULL
            THEN N'Not selected'
        WHEN badische.IsGeographicAnchor = 1
            THEN N'Present as a geographic anchor under ServiceVolumePercentile >= 0.25 and RawImportanceRank <= 100'
        ELSE N'Present through deterministic importance-fill selection, not as a geographic anchor'
    END AS PresenceExplanation
FROM (VALUES (1)) AS one_row(Dummy)
OUTER APPLY
(
    SELECT TOP (1)
        panel.ParentStationKey,
        panel.ParentStationName,
        panel.RawImportanceRank,
        panel.BaseImportanceScore,
        panel.IsGeographicAnchor,
        panel.ServiceVolumePercentile,
        panel.RegularModeCount,
        panel.RouteDiversityPercentile,
        panel.ModeDiversityPercentile
    FROM #PanelFinal AS panel
    WHERE panel.ParentStationName = N'Köln Badische Allee'
    ORDER BY panel.RecommendedRank
) AS badische;

-- O5_RESULT FinalPanelValidationOffenders
;WITH DuplicateKeys AS
(
    SELECT ParentStationKey
    FROM #PanelFinal
    GROUP BY ParentStationKey
    HAVING COUNT_BIG(*) > 1
),
DuplicateIds AS
(
    SELECT ParentStationId
    FROM #PanelFinal
    GROUP BY ParentStationId
    HAVING COUNT_BIG(*) > 1
)
SELECT
    CONVERT(NVARCHAR(64), N'InvalidScheduleActiveStation') AS ValidationIssue,
    CONVERT(NVARCHAR(100), panel.ParentStationKey) AS ParentStationKey,
    CONVERT(NVARCHAR(200), panel.ParentStationId) AS ParentStationId,
    CONVERT(NVARCHAR(200), panel.ParentStationName) AS ParentStationName,
    CONVERT(NVARCHAR(100), panel.RawImportanceRank) AS RawImportanceRank,
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore) AS BaseImportanceScore,
    CONVERT(NVARCHAR(300), N'Not used in current schedule') AS Details
FROM #PanelFinal AS panel
WHERE NOT EXISTS
(
    SELECT 1
    FROM analytics.vwParentStationScheduleProfile AS schedule_profile
    WHERE schedule_profile.ParentStationKey = panel.ParentStationKey
      AND schedule_profile.IsUsedInCurrentSchedule = 1
)
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'InvalidRegularScheduledService'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'RegularScheduledStopEventOccurrenceCount <= 0 or NULL')
FROM #PanelFinal AS panel
WHERE panel.RegularScheduledStopEventOccurrenceCount IS NULL
   OR panel.RegularScheduledStopEventOccurrenceCount <= 0
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'InvalidParentStationId'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'ParentStationId is NULL or blank')
FROM #PanelFinal AS panel
WHERE NULLIF(LTRIM(RTRIM(panel.ParentStationId)), N'') IS NULL
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'InvalidCoordinate'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'Latitude or Longitude is NULL')
FROM #PanelFinal AS panel
WHERE panel.Latitude IS NULL OR panel.Longitude IS NULL
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'InvalidFinalScore'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'BaseImportanceScore is outside 0-100 or NULL')
FROM #PanelFinal AS panel
WHERE panel.BaseImportanceScore < 0
   OR panel.BaseImportanceScore > 100
   OR panel.BaseImportanceScore IS NULL
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'InvalidGeographicAnchor'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'Anchor is outside Raw Top 100 or below ServiceVolumePercentile 0.25')
FROM #PanelFinal AS panel
WHERE panel.IsGeographicAnchor = 1
  AND (panel.RawImportanceRank > 100
       OR panel.ServiceVolumePercentile < CONVERT(DECIMAL(12, 8), 0.25))
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'DuplicateParentStationKey'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'ParentStationKey occurs more than once')
FROM #PanelFinal AS panel
INNER JOIN DuplicateKeys AS duplicate_key
    ON duplicate_key.ParentStationKey = panel.ParentStationKey
UNION ALL
SELECT
    CONVERT(NVARCHAR(64), N'DuplicateParentStationId'),
    CONVERT(NVARCHAR(100), panel.ParentStationKey),
    CONVERT(NVARCHAR(200), panel.ParentStationId),
    CONVERT(NVARCHAR(200), panel.ParentStationName),
    CONVERT(NVARCHAR(100), panel.RawImportanceRank),
    CONVERT(NVARCHAR(100), panel.BaseImportanceScore),
    CONVERT(NVARCHAR(300), N'ParentStationId occurs more than once')
FROM #PanelFinal AS panel
INNER JOIN DuplicateIds AS duplicate_id
    ON duplicate_id.ParentStationId = panel.ParentStationId
    OR (duplicate_id.ParentStationId IS NULL AND panel.ParentStationId IS NULL)
ORDER BY ValidationIssue, ParentStationName, ParentStationKey;
