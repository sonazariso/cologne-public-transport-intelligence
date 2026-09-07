USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
GO

/*
    Focused validation/report for the deterministic realtime sampling panel.
    This is an inspection script only.  It does not create reliability KPIs,
    operational facts, or Power BI objects.
*/

DECLARE @RecentHours INT = 168;

/* 1. Configured targets, rotation slots, and effective frequency. */
;WITH EnabledSlotCounts AS
(
    SELECT
        sampling_target.SamplingTargetId,
        COUNT_BIG(*) AS SlotsPerCycle,
        SUM(COUNT_BIG(*)) OVER () AS TotalEnabledSlots
    FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
    INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
        ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
    WHERE sampling_target.IsEnabled = 1
    GROUP BY sampling_target.SamplingTargetId
),
SlotList AS
(
    SELECT
        SamplingTargetId,
        STRING_AGG(CONVERT(NVARCHAR(MAX), CONVERT(NVARCHAR(20), SamplingSlot)), N', ')
            WITHIN GROUP (ORDER BY SamplingSlot) AS SamplingSlots
    FROM ctl.MddRealtimeSamplingSlot
    GROUP BY SamplingTargetId
)
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName,
    sampling_target.NumberOfResults,
    sampling_target.IsEnabled,
    enabled_slot_counts.SlotsPerCycle,
    enabled_slot_counts.TotalEnabledSlots,
    CONVERT(DECIMAL(10, 1),
        5.0 * enabled_slot_counts.TotalEnabledSlots / enabled_slot_counts.SlotsPerCycle
    ) AS EffectiveSamplingMinutes,
    slot_list.SamplingSlots,
    sampling_target.Notes
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN EnabledSlotCounts AS enabled_slot_counts
    ON enabled_slot_counts.SamplingTargetId = sampling_target.SamplingTargetId
LEFT JOIN SlotList AS slot_list
    ON slot_list.SamplingTargetId = sampling_target.SamplingTargetId
ORDER BY sampling_target.SamplingTargetId;

/* 2. Static identity, geography, modes, routes, and scheduled volume. */
;WITH TargetStatic AS
(
    SELECT
        sampling_target.SamplingTargetId,
        sampling_target.StopPointRef,
        sampling_target.TargetName,
        target_stop.StopName AS StaticStopName,
        target_stop.LocationTypeName,
        target_stop.Latitude,
        target_stop.Longitude,
        fact.RouteKey,
        fact.ModeKey,
        mode_dimension.ModeDetail,
        route.RouteShortName,
        fact.ScheduledStopEventKey
    FROM ctl.MddRealtimeSamplingTarget AS sampling_target
    INNER JOIN dw.DimStop AS target_stop
        ON target_stop.StopId = sampling_target.StopPointRef
    INNER JOIN dw.DimStop AS served_stop
        ON served_stop.StopId = sampling_target.StopPointRef
        OR served_stop.ParentStationId = sampling_target.StopPointRef
    INNER JOIN dw.FactScheduledStopEvent AS fact
        ON fact.StopKey = served_stop.StopKey
    INNER JOIN dw.DimMode AS mode_dimension
        ON mode_dimension.ModeKey = fact.ModeKey
    INNER JOIN dw.DimRoute AS route
        ON route.RouteKey = fact.RouteKey
    WHERE sampling_target.IsEnabled = 1
),
ModeList AS
(
    SELECT DISTINCT SamplingTargetId, ModeDetail
    FROM TargetStatic
),
ModeSummary AS
(
    SELECT
        SamplingTargetId,
        STRING_AGG(CONVERT(NVARCHAR(MAX), ModeDetail), N', ')
            WITHIN GROUP (ORDER BY ModeDetail) AS ScheduledModeDetail
    FROM ModeList
    GROUP BY SamplingTargetId
),
RouteList AS
(
    SELECT DISTINCT SamplingTargetId, RouteKey, RouteShortName
    FROM TargetStatic
),
RouteSummary AS
(
    SELECT
        SamplingTargetId,
        COUNT(*) AS DistinctRoutes,
        STRING_AGG(CONVERT(NVARCHAR(MAX), RouteShortName), N', ')
            WITHIN GROUP (ORDER BY RouteShortName) AS ScheduledRoutes
    FROM RouteList
    GROUP BY SamplingTargetId
),
EventSummary AS
(
    SELECT SamplingTargetId, COUNT_BIG(*) AS ScheduledStopEvents
    FROM TargetStatic
    GROUP BY SamplingTargetId
)
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName,
    static_identity.StaticStopName,
    static_identity.LocationTypeName,
    static_identity.Latitude,
    static_identity.Longitude,
    mode_summary.ScheduledModeDetail,
    route_summary.DistinctRoutes,
    route_summary.ScheduledRoutes,
    event_summary.ScheduledStopEvents
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
INNER JOIN
(
    SELECT DISTINCT
        SamplingTargetId,
        StaticStopName,
        LocationTypeName,
        Latitude,
        Longitude
    FROM TargetStatic
) AS static_identity
    ON static_identity.SamplingTargetId = sampling_target.SamplingTargetId
INNER JOIN ModeSummary AS mode_summary
    ON mode_summary.SamplingTargetId = sampling_target.SamplingTargetId
INNER JOIN RouteSummary AS route_summary
    ON route_summary.SamplingTargetId = sampling_target.SamplingTargetId
INNER JOIN EventSummary AS event_summary
    ON event_summary.SamplingTargetId = sampling_target.SamplingTargetId
ORDER BY sampling_target.SamplingTargetId;

/* Geographic spread summary from the stored static stop coordinates. */
SELECT
    COUNT(*) AS EnabledTargetCount,
    MIN(target_stop.Latitude) AS MinLatitude,
    MAX(target_stop.Latitude) AS MaxLatitude,
    CONVERT(DECIMAL(10, 6), MAX(target_stop.Latitude) - MIN(target_stop.Latitude)) AS LatitudeSpan,
    MIN(target_stop.Longitude) AS MinLongitude,
    MAX(target_stop.Longitude) AS MaxLongitude,
    CONVERT(DECIMAL(10, 6), MAX(target_stop.Longitude) - MIN(target_stop.Longitude)) AS LongitudeSpan
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
INNER JOIN dw.DimStop AS target_stop
    ON target_stop.StopId = sampling_target.StopPointRef
WHERE sampling_target.IsEnabled = 1;

/* 3. Intended major stable-mode coverage; missing modes remain visible. */
;WITH IntendedMode(ModeDetail) AS
(
    SELECT N'Stadtbahn / Tram'
    UNION ALL SELECT N'S-Bahn'
    UNION ALL SELECT N'Regional Express (RE)'
    UNION ALL SELECT N'Regional Bahn (RB)'
    UNION ALL SELECT N'Urban Bus (KVB)'
    UNION ALL SELECT N'Regional / Other Bus'
),
CoveredMode AS
(
    SELECT DISTINCT mode_dimension.ModeDetail
    FROM ctl.MddRealtimeSamplingTarget AS sampling_target
    INNER JOIN dw.DimStop AS served_stop
        ON served_stop.StopId = sampling_target.StopPointRef
        OR served_stop.ParentStationId = sampling_target.StopPointRef
    INNER JOIN dw.FactScheduledStopEvent AS fact
        ON fact.StopKey = served_stop.StopKey
    INNER JOIN dw.DimMode AS mode_dimension
        ON mode_dimension.ModeKey = fact.ModeKey
    WHERE sampling_target.IsEnabled = 1
)
SELECT
    intended_mode.ModeDetail,
    CASE WHEN covered_mode.ModeDetail IS NULL THEN 0 ELSE 1 END AS IsCovered
FROM IntendedMode AS intended_mode
LEFT JOIN CoveredMode AS covered_mode
    ON covered_mode.ModeDetail = intended_mode.ModeDetail
ORDER BY intended_mode.ModeDetail;

/* 4. Recent and all-time realtime observations associated with each target. */
;WITH RealtimeObservationTarget AS
(
    SELECT
        sampling_target.SamplingTargetId,
        realtime.ObservedAtUtc,
        realtime.ResultId
    FROM ctl.MddRealtimeSamplingTarget AS sampling_target
    INNER JOIN stg.MddRealtimeStopObservation AS realtime
        ON realtime.StopPointRef = sampling_target.StopPointRef
        OR EXISTS
        (
            SELECT 1
            FROM dw.DimStop AS realtime_stop
            WHERE realtime_stop.StopId = realtime.StopPointRef
              AND realtime_stop.ParentStationId = sampling_target.StopPointRef
        )
    WHERE sampling_target.IsEnabled = 1
)
SELECT
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName,
    SUM
    (
        CASE
            WHEN realtime_target.ObservedAtUtc >= DATEADD(HOUR, -@RecentHours, SYSUTCDATETIME())
                THEN CONVERT(BIGINT, 1)
            ELSE CONVERT(BIGINT, 0)
        END
    ) AS RecentRealtimeObservationCount,
    COUNT_BIG(realtime_target.ResultId) AS RealtimeObservationCount,
    MIN(realtime_target.ObservedAtUtc) AS FirstObservedAtUtc,
    MAX(realtime_target.ObservedAtUtc) AS LastObservedAtUtc
FROM ctl.MddRealtimeSamplingTarget AS sampling_target
LEFT JOIN RealtimeObservationTarget AS realtime_target
    ON realtime_target.SamplingTargetId = sampling_target.SamplingTargetId
WHERE sampling_target.IsEnabled = 1
GROUP BY
    sampling_target.SamplingTargetId,
    sampling_target.StopPointRef,
    sampling_target.TargetName
ORDER BY sampling_target.SamplingTargetId;

/* 5. Deterministic simulated five-minute rotation (12 consecutive buckets). */
DECLARE @SimulationStartUtc DATETIME2(0) = CONVERT(DATETIME2(0), '2026-09-07T00:00:00');
DECLARE @EpochUtc DATETIME2(0) = CONVERT(DATETIME2(0), '19700101');

;WITH BucketNumber(Number) AS
(
    SELECT Number
    FROM (VALUES
        (0), (1), (2), (3), (4), (5),
        (6), (7), (8), (9), (10), (11)
    ) AS numbers(Number)
),
EnabledSlots AS
(
    SELECT
        sampling_slot.SamplingSlot,
        sampling_slot.SamplingTargetId,
        sampling_target.StopPointRef,
        sampling_target.TargetName,
        ROW_NUMBER() OVER (ORDER BY sampling_slot.SamplingSlot) AS SlotOrdinal,
        COUNT_BIG(*) OVER () AS EnabledSlotCount
    FROM ctl.MddRealtimeSamplingSlot AS sampling_slot
    INNER JOIN ctl.MddRealtimeSamplingTarget AS sampling_target
        ON sampling_target.SamplingTargetId = sampling_slot.SamplingTargetId
    WHERE sampling_target.IsEnabled = 1
),
Rotation AS
(
    SELECT
        DATEADD(MINUTE, 5 * bucket_number.Number, @SimulationStartUtc) AS BucketStartUtc,
        enabled_slot.SamplingSlot,
        enabled_slot.SamplingTargetId,
        enabled_slot.StopPointRef,
        enabled_slot.TargetName
    FROM BucketNumber AS bucket_number
    INNER JOIN EnabledSlots AS enabled_slot
        ON enabled_slot.SlotOrdinal =
        (
            (
                DATEDIFF_BIG
                (
                    MINUTE,
                    @EpochUtc,
                    DATEADD(MINUTE, 5 * bucket_number.Number, @SimulationStartUtc)
                ) / 5
            ) % enabled_slot.EnabledSlotCount
        ) + 1
)
SELECT *
FROM Rotation
ORDER BY BucketStartUtc;
