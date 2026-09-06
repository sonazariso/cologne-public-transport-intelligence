USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Normalize source arrival values and derive nullable realtime measures. */
CREATE OR ALTER VIEW wrk.vwCologneRealtimeStopObservation
AS
SELECT
    observation.ObservationKey,
    observation.ObservedAtUtc,
    observation.ResultId,
    observation.StopPointRef,
    observation.StopName,
    observation.LineName,
    observation.LineRef,
    observation.JourneyRef,
    observation.DirectionRef,
    observation.OperatorRef,
    observation.PtMode,
    observation.RailSubmode,
    observation.TimetabledArrivalUtc,
    observation.EstimatedArrivalUtc,
    observation.CreatedAtUtc,
    observation.PlannedBay,
    observation.EstimatedBay,
    DATEDIFF
    (
        MINUTE,
        observation.TimetabledArrivalUtc,
        observation.EstimatedArrivalUtc
    ) AS ArrivalDelayMinutes,
    CONVERT
    (
        BIT,
        CASE
            WHEN observation.PlannedBay IS NULL
                 OR observation.EstimatedBay IS NULL THEN NULL
            WHEN observation.PlannedBay <> observation.EstimatedBay THEN 1
            ELSE 0
        END
    ) AS PlatformChanged
FROM stg.MddRealtimeStopObservation AS observation;
GO

/*
    Enrich only with static stop positions that are actually used by the
    scheduled warehouse.  This is the validated warehouse-based replacement
    for rebuilding the stop map through wrk.vwCologneScheduledStopEvent.
*/
CREATE OR ALTER VIEW wrk.vwCologneRealtimeStopEnriched
AS
WITH UsedStaticStop AS
(
    SELECT
        stop.StopId,
        stop.ParentStationId,
        stop.StopName
    FROM dw.DimStop AS stop
    WHERE EXISTS
    (
        SELECT 1
        FROM dw.FactScheduledStopEvent AS stop_event
        WHERE stop_event.StopKey = stop.StopKey
    )
)
SELECT
    realtime.*,
    static_stop.ParentStationId AS StaticParentStationId,
    static_stop.StopName AS StaticStopName,
    CONVERT
    (
        BIT,
        CASE WHEN static_stop.StopId IS NULL THEN 0 ELSE 1 END
    ) AS StaticStopMatched
FROM wrk.vwCologneRealtimeStopObservation AS realtime
LEFT JOIN UsedStaticStop AS static_stop
    ON static_stop.StopId = realtime.StopPointRef;
GO

/* Convert UTC TRIAS timetable values to Berlin local service-day inputs. */
CREATE OR ALTER VIEW wrk.vwCologneRealtimeTripMatchKey
AS
WITH Localized AS
(
    SELECT
        realtime.*,
        CONVERT
        (
            DATETIME2(0),
            realtime.TimetabledArrivalUtc
                AT TIME ZONE 'UTC'
                AT TIME ZONE 'W. Europe Standard Time'
        ) AS TimetabledArrivalLocal
    FROM wrk.vwCologneRealtimeStopEnriched AS realtime
)
SELECT
    localized.*,
    CONVERT(DATE, localized.TimetabledArrivalLocal) AS ServiceDateLocal,
    CONVERT
    (
        INT,
        DATEDIFF
        (
            SECOND,
            CONVERT(DATE, localized.TimetabledArrivalLocal),
            localized.TimetabledArrivalLocal
        )
    ) AS ScheduledArrivalSecondsLocal
FROM Localized AS localized;
GO

/*
    Preserve the current production matching path through the validated
    scheduled-stop-event working view.  The warehouse-direct replacement is a
    future, separately validated change and is intentionally not implemented
    here.
*/
CREATE OR ALTER VIEW wrk.vwCologneRealtimeTripMatch
AS
WITH RealtimeLineKey AS
(
    SELECT
        realtime.*,
        REPLACE
        (
            UPPER(LTRIM(RTRIM(COALESCE(NULLIF(realtime.LineName, N''), N'')))),
            N' ',
            N''
        ) AS NormalizedLineName
    FROM wrk.vwCologneRealtimeTripMatchKey AS realtime
),
RouteCoverage AS
(
    SELECT
        route.RouteId,
        REPLACE
        (
            UPPER
            (
                LTRIM
                (
                    RTRIM
                    (
                        COALESCE
                        (
                            NULLIF(route.RouteShortName, N''),
                            NULLIF(route.RouteLongName, N''),
                            N''
                        )
                    )
                )
            ),
            N' ',
            N''
        ) AS NormalizedRouteLabel
    FROM wrk.vwCologneServingRoute AS route
),
LineCoverage AS
(
    SELECT
        realtime.ObservationKey,
        COUNT_BIG(route.RouteId) AS StaticRouteCoverageCount
    FROM RealtimeLineKey AS realtime
    LEFT JOIN RouteCoverage AS route
        ON route.NormalizedRouteLabel = realtime.NormalizedLineName
    GROUP BY realtime.ObservationKey
),
ExactCandidates AS
(
    SELECT
        realtime.ObservationKey,
        scheduled.TripId,
        scheduled.RouteId,
        scheduled.ServiceId,
        scheduled.StopId,
        ROW_NUMBER() OVER
        (
            PARTITION BY realtime.ObservationKey
            ORDER BY
                scheduled.TripId,
                scheduled.RouteId,
                scheduled.ServiceId,
                scheduled.StopId,
                scheduled.StopSequence
        ) AS CandidateOrder
    FROM RealtimeLineKey AS realtime
    JOIN wrk.vwCologneScheduledStopEvent AS scheduled
        ON scheduled.StopId = realtime.StopPointRef
       AND REPLACE
           (
               UPPER
               (
                   LTRIM
                   (
                       RTRIM
                       (
                           COALESCE
                           (
                               NULLIF(scheduled.RouteShortName, N''),
                               NULLIF(scheduled.RouteLongName, N''),
                               N''
                           )
                       )
                   )
               ),
               N' ',
               N''
           ) = realtime.NormalizedLineName
       AND scheduled.ScheduledArrivalSeconds =
           realtime.ScheduledArrivalSecondsLocal
             + (scheduled.ArrivalDayOffset * 86400)
    JOIN dw.DimService AS service
        ON service.ServiceId = scheduled.ServiceId
    JOIN dw.BridgeServiceDate AS service_date
        ON service_date.ServiceKey = service.ServiceKey
    JOIN dw.DimDate AS calendar_date
        ON calendar_date.DateKey = service_date.DateKey
       AND calendar_date.DateValue =
           DATEADD(DAY, -scheduled.ArrivalDayOffset, realtime.ServiceDateLocal)
),
ParentStationCandidates AS
(
    SELECT
        realtime.ObservationKey,
        scheduled.TripId,
        scheduled.RouteId,
        scheduled.ServiceId,
        scheduled.StopId,
        ROW_NUMBER() OVER
        (
            PARTITION BY realtime.ObservationKey
            ORDER BY
                scheduled.TripId,
                scheduled.RouteId,
                scheduled.ServiceId,
                scheduled.StopId,
                scheduled.StopSequence
        ) AS CandidateOrder
    FROM RealtimeLineKey AS realtime
    JOIN wrk.vwCologneScheduledStopEvent AS scheduled
        ON scheduled.ParentStationId = realtime.StaticParentStationId
       AND REPLACE
           (
               UPPER
               (
                   LTRIM
                   (
                       RTRIM
                       (
                           COALESCE
                           (
                               NULLIF(scheduled.RouteShortName, N''),
                               NULLIF(scheduled.RouteLongName, N''),
                               N''
                           )
                       )
                   )
               ),
               N' ',
               N''
           ) = realtime.NormalizedLineName
       AND scheduled.ScheduledArrivalSeconds =
           realtime.ScheduledArrivalSecondsLocal
             + (scheduled.ArrivalDayOffset * 86400)
    JOIN dw.DimService AS service
        ON service.ServiceId = scheduled.ServiceId
    JOIN dw.BridgeServiceDate AS service_date
        ON service_date.ServiceKey = service.ServiceKey
    JOIN dw.DimDate AS calendar_date
        ON calendar_date.DateKey = service_date.DateKey
       AND calendar_date.DateValue =
           DATEADD(DAY, -scheduled.ArrivalDayOffset, realtime.ServiceDateLocal)
),
ExactCounts AS
(
    SELECT
        ObservationKey,
        COUNT_BIG(*) AS ExactStopCandidateCount
    FROM ExactCandidates
    GROUP BY ObservationKey
),
ParentStationCounts AS
(
    SELECT
        ObservationKey,
        COUNT_BIG(*) AS ParentStationCandidateCount
    FROM ParentStationCandidates
    GROUP BY ObservationKey
),
ExactSelection AS
(
    SELECT
        candidate.ObservationKey,
        candidate.TripId,
        candidate.RouteId,
        candidate.ServiceId,
        candidate.StopId
    FROM ExactCandidates AS candidate
    WHERE candidate.CandidateOrder = 1
),
ParentStationSelection AS
(
    SELECT
        candidate.ObservationKey,
        candidate.TripId,
        candidate.RouteId,
        candidate.ServiceId,
        candidate.StopId
    FROM ParentStationCandidates AS candidate
    WHERE candidate.CandidateOrder = 1
),
CandidateStats AS
(
    SELECT
        realtime.ObservationKey,
        COALESCE(line_coverage.StaticRouteCoverageCount, 0) AS StaticRouteCoverageCount,
        COALESCE(exact_count.ExactStopCandidateCount, 0) AS ExactStopCandidateCount,
        COALESCE(parent_count.ParentStationCandidateCount, 0) AS ParentStationCandidateCount
    FROM wrk.vwCologneRealtimeTripMatchKey AS realtime
    LEFT JOIN LineCoverage AS line_coverage
        ON line_coverage.ObservationKey = realtime.ObservationKey
    LEFT JOIN ExactCounts AS exact_count
        ON exact_count.ObservationKey = realtime.ObservationKey
    LEFT JOIN ParentStationCounts AS parent_count
        ON parent_count.ObservationKey = realtime.ObservationKey
),
MatchDecision AS
(
    SELECT
        stats.*,
        CASE
            WHEN stats.StaticRouteCoverageCount = 0
                THEN N'StaticCoverageMissing'
            WHEN stats.ExactStopCandidateCount = 1
                THEN N'ExactStopMatch'
            WHEN stats.ExactStopCandidateCount = 0
                 AND stats.ParentStationCandidateCount = 1
                THEN N'ParentStationFallback'
            ELSE N'Unresolved'
        END AS MatchStatus
    FROM CandidateStats AS stats
)
SELECT
    realtime.*,
    decision.ExactStopCandidateCount,
    decision.ParentStationCandidateCount,
    decision.MatchStatus,
    CASE
        WHEN decision.MatchStatus = N'ExactStopMatch' THEN exact_match.TripId
        WHEN decision.MatchStatus = N'ParentStationFallback' THEN parent_match.TripId
        ELSE NULL
    END AS MatchedTripId,
    CASE
        WHEN decision.MatchStatus = N'ExactStopMatch' THEN exact_match.RouteId
        WHEN decision.MatchStatus = N'ParentStationFallback' THEN parent_match.RouteId
        ELSE NULL
    END AS MatchedRouteId,
    CASE
        WHEN decision.MatchStatus = N'ExactStopMatch' THEN exact_match.ServiceId
        WHEN decision.MatchStatus = N'ParentStationFallback' THEN parent_match.ServiceId
        ELSE NULL
    END AS MatchedServiceId,
    CASE
        WHEN decision.MatchStatus = N'ExactStopMatch' THEN exact_match.StopId
        WHEN decision.MatchStatus = N'ParentStationFallback' THEN parent_match.StopId
        ELSE NULL
    END AS MatchedStaticStopId
FROM wrk.vwCologneRealtimeTripMatchKey AS realtime
JOIN MatchDecision AS decision
    ON decision.ObservationKey = realtime.ObservationKey
LEFT JOIN ExactSelection AS exact_match
    ON exact_match.ObservationKey = realtime.ObservationKey
   AND decision.MatchStatus = N'ExactStopMatch'
LEFT JOIN ParentStationSelection AS parent_match
    ON parent_match.ObservationKey = realtime.ObservationKey
   AND decision.MatchStatus = N'ParentStationFallback';
GO

/* Expose linked source situations as evidence, not confirmed causality. */
CREATE OR ALTER VIEW wrk.vwCologneRealtimeEvidenceSituation
AS
SELECT
    realtime_match.*,
    ISNULL
    (
        CONVERT
        (
            BIT,
            CASE
                WHEN realtime_match.MatchStatus IN
                     (N'ExactStopMatch', N'ParentStationFallback') THEN 1
                ELSE 0
            END
        ),
        CONVERT(BIT, 0)
    ) AS HasUsableStaticMatch,
    link.SituationObservationKey,
    link.RelationScope,
    situation.ObservedAtUtc AS SituationObservedAtUtc,
    situation.ParticipantRef,
    situation.SituationNumber,
    situation.Summary AS SituationSummary,
    situation.Description AS SituationDescription,
    situation.Detail AS SituationDetail,
    situation.ValidFromUtc AS SituationValidFromUtc,
    situation.ValidToUtc AS SituationValidToUtc,
    situation.CreatedAtUtc AS SituationCreatedAtUtc
FROM wrk.vwCologneRealtimeTripMatch AS realtime_match
LEFT JOIN stg.MddRealtimeStopSituationLink AS link
    ON link.ObservationKey = realtime_match.ObservationKey
LEFT JOIN stg.MddRealtimeSituationObservation AS situation
    ON situation.SituationObservationKey = link.SituationObservationKey;
GO
