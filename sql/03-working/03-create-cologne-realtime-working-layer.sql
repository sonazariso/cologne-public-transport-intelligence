USE CologneTransitIntelligence;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER VIEW wrk.vwCologneRealtimeStopObservation
AS
SELECT
    s.ObservationKey,
    s.ObservedAtUtc,
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

    CASE
        WHEN s.TimetabledArrivalUtc IS NOT NULL
         AND s.EstimatedArrivalUtc IS NOT NULL
        THEN
            CAST(
                DATEDIFF(
                    SECOND,
                    s.TimetabledArrivalUtc,
                    s.EstimatedArrivalUtc
                ) / 60.0
                AS DECIMAL(10,2)
            )
        ELSE NULL
    END AS ArrivalDelayMinutes,

    s.PlannedBay,
    s.EstimatedBay,

    CASE
        WHEN NULLIF(LTRIM(RTRIM(s.PlannedBay)), '') IS NULL
          OR NULLIF(LTRIM(RTRIM(s.EstimatedBay)), '') IS NULL
        THEN NULL

        WHEN LTRIM(RTRIM(s.PlannedBay)) <> LTRIM(RTRIM(s.EstimatedBay))
        THEN CAST(1 AS BIT)

        ELSE CAST(0 AS BIT)
    END AS PlatformChanged,

    s.CreatedAtUtc
FROM stg.MddRealtimeStopObservation AS s;
GO

/*
    Enrich realtime stop observations using the curated static stop dimension.

    The previous implementation rebuilt a distinct stop map from
    wrk.vwCologneScheduledStopEvent, which required scanning approximately
    1.55 million scheduled stop-event rows on every query.

    This version preserves the same result while using dw.DimStop and an
    indexed existence check against dw.FactScheduledStopEvent.
*/
CREATE OR ALTER VIEW wrk.vwCologneRealtimeStopEnriched
AS
SELECT
    r.*,

    sm.ParentStationId AS StaticParentStationId,
    sm.StopName AS StaticStopName,

    CAST
    (
        CASE
            WHEN sm.StopId IS NOT NULL THEN 1
            ELSE 0
        END
        AS BIT
    ) AS StaticStopMatched

FROM wrk.vwCologneRealtimeStopObservation AS r

LEFT JOIN
(
    SELECT
        s.StopId,
        s.ParentStationId,
        s.StopName
    FROM dw.DimStop AS s
    WHERE EXISTS
    (
        SELECT 1
        FROM dw.FactScheduledStopEvent AS f
        WHERE f.StopKey = s.StopKey
    )
) AS sm
    ON sm.StopId COLLATE Latin1_General_100_BIN2
     = r.StopPointRef COLLATE Latin1_General_100_BIN2;
GO

CREATE OR ALTER VIEW wrk.vwCologneRealtimeTripMatchKey
AS
SELECT
    r.*,

    CAST(
        r.TimetabledArrivalUtc
            AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
        AS DATETIME2(0)
    ) AS TimetabledArrivalLocal,

    CAST(
        r.TimetabledArrivalUtc
            AT TIME ZONE 'UTC'
            AT TIME ZONE 'W. Europe Standard Time'
        AS DATE
    ) AS ServiceDateLocal,

    CASE
        WHEN r.TimetabledArrivalUtc IS NOT NULL
        THEN
            DATEPART(
                HOUR,
                r.TimetabledArrivalUtc
                    AT TIME ZONE 'UTC'
                    AT TIME ZONE 'W. Europe Standard Time'
            ) * 3600
            +
            DATEPART(
                MINUTE,
                r.TimetabledArrivalUtc
                    AT TIME ZONE 'UTC'
                    AT TIME ZONE 'W. Europe Standard Time'
            ) * 60
            +
            DATEPART(
                SECOND,
                r.TimetabledArrivalUtc
                    AT TIME ZONE 'UTC'
                    AT TIME ZONE 'W. Europe Standard Time'
            )
        ELSE NULL
    END AS ScheduledArrivalSecondsLocal

FROM wrk.vwCologneRealtimeStopEnriched AS r;
GO

CREATE OR ALTER VIEW wrk.vwCologneRealtimeTripMatch
AS

WITH RouteCoverage AS
(
    SELECT DISTINCT
        REPLACE(RouteShortName, N' ', N'') AS NormalizedRouteName
    FROM wrk.vwCologneServingRoute
    WHERE RouteShortName IS NOT NULL
),

Candidate AS
(
    SELECT
        r.ObservationKey,

        trip.TripId,
        route.RouteId,
        service.ServiceId,
        route.RouteShortName,
        trip.TripHeadsign,

        stop.StopId AS StaticMatchedStopId,
        stop.StopName AS StaticMatchedStopName,
        stop.ParentStationId,

        stop_event.ScheduledStopEventKey,
        trip.TripKey,
        stop_event.RouteKey,
        stop_event.StopKey,
        stop_event.ModeKey,
        stop_event.ServiceKey,
        date_dimension.DateKey,
        date_dimension.DateValue AS ServiceDate,

        CASE
            WHEN stop.StopId = r.StopPointRef
            THEN 1
            ELSE 0
        END AS IsExactStopMatch,

        CASE
            WHEN stop.ParentStationId = r.StaticParentStationId
            THEN 1
            ELSE 0
        END AS IsParentStationMatch

    FROM wrk.vwCologneRealtimeTripMatchKey AS r

    /*
        Resolve static candidates directly from the warehouse. The persisted
        local seconds-of-day value keeps the existing ArrivalDayOffset
        service-day rule while allowing the realtime-match index to be used.
    */
    INNER JOIN dw.DimRoute AS route
        ON REPLACE(route.RouteShortName, N' ', N'')
         = REPLACE(r.LineName, N' ', N'')

    INNER JOIN dw.FactScheduledStopEvent AS stop_event
        ON stop_event.RouteKey = route.RouteKey
       AND stop_event.ScheduledArrivalSecondOfDay =
             r.ScheduledArrivalSecondsLocal

    INNER JOIN dw.FactScheduledTrip AS trip
        ON trip.TripKey = stop_event.TripKey

    INNER JOIN dw.DimStop AS stop
        ON stop.StopKey = stop_event.StopKey

    INNER JOIN dw.DimService AS service
        ON service.ServiceKey = stop_event.ServiceKey

    INNER JOIN dw.BridgeServiceDate AS bridge_service_date
        ON bridge_service_date.ServiceKey = service.ServiceKey

    INNER JOIN dw.DimDate AS date_dimension
        ON date_dimension.DateKey = bridge_service_date.DateKey

       AND date_dimension.DateValue =
           DATEADD(
               DAY,
               -stop_event.ArrivalDayOffset,
               r.ServiceDateLocal
           )
),

CandidateSummary AS
(
    SELECT
        ObservationKey,

        SUM(IsExactStopMatch) AS ExactStopCandidateCount,
        SUM(IsParentStationMatch) AS ParentStationCandidateCount,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN TripId END
        ) AS ExactTripId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN TripId END
        ) AS ParentTripId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN RouteId END
        ) AS ExactRouteId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN RouteId END
        ) AS ParentRouteId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ServiceId END
        ) AS ExactServiceId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ServiceId END
        ) AS ParentServiceId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ExactStaticStopId,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN StaticMatchedStopId END
        ) AS ParentStaticStopId,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ScheduledStopEventKey END
        ) AS ExactScheduledStopEventKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ScheduledStopEventKey END
        ) AS ParentScheduledStopEventKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN TripKey END
        ) AS ExactTripKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN TripKey END
        ) AS ParentTripKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN RouteKey END
        ) AS ExactRouteKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN RouteKey END
        ) AS ParentRouteKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN StopKey END
        ) AS ExactStopKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN StopKey END
        ) AS ParentStopKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ModeKey END
        ) AS ExactModeKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ModeKey END
        ) AS ParentModeKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ServiceKey END
        ) AS ExactServiceKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ServiceKey END
        ) AS ParentServiceKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN DateKey END
        ) AS ExactDateKey,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN DateKey END
        ) AS ParentDateKey,

        MAX(
            CASE WHEN IsExactStopMatch = 1
                 THEN ServiceDate END
        ) AS ExactServiceDate,

        MAX(
            CASE WHEN IsParentStationMatch = 1
                 THEN ServiceDate END
        ) AS ParentServiceDate

    FROM Candidate
    GROUP BY ObservationKey
)

SELECT
    r.*,

    ISNULL(cs.ExactStopCandidateCount, 0)
        AS ExactStopCandidateCount,

    ISNULL(cs.ParentStationCandidateCount, 0)
        AS ParentStationCandidateCount,

    CASE
        WHEN rc.NormalizedRouteName IS NULL
            THEN N'StaticCoverageMissing'

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN N'ExactStopMatch'

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN N'ParentStationFallback'

        ELSE N'Unresolved'
    END AS MatchStatus,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactTripId

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentTripId
    END AS MatchedTripId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactRouteId

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentRouteId
    END AS MatchedRouteId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceId

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceId
    END AS MatchedServiceId,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactStaticStopId

        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentStaticStopId
    END AS MatchedStaticStopId,

    /* Existing candidate selection exposes the selected warehouse keys. */
    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactScheduledStopEventKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentScheduledStopEventKey
    END AS ScheduledStopEventKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactTripKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentTripKey
    END AS TripKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactRouteKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentRouteKey
    END AS RouteKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactStopKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentStopKey
    END AS StopKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactModeKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentModeKey
    END AS ModeKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceKey
    END AS ServiceKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactDateKey
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentDateKey
    END AS DateKey,

    CASE
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 1
            THEN cs.ExactServiceDate
        WHEN ISNULL(cs.ExactStopCandidateCount, 0) = 0
         AND ISNULL(cs.ParentStationCandidateCount, 0) = 1
            THEN cs.ParentServiceDate
    END AS ServiceDate

FROM wrk.vwCologneRealtimeTripMatchKey AS r

LEFT JOIN CandidateSummary AS cs
    ON cs.ObservationKey = r.ObservationKey

LEFT JOIN RouteCoverage AS rc
    ON rc.NormalizedRouteName =
       REPLACE(r.LineName, N' ', N'');
GO

CREATE OR ALTER VIEW wrk.vwCologneRealtimeEvidenceSituation
AS
SELECT
    o.ObservationKey,
    o.ObservedAtUtc,

    o.ResultId,
    o.StopPointRef,
    o.StopName,

    o.StaticParentStationId,
    o.StaticStopName,
    o.StaticStopMatched,

    o.LineName,
    o.LineRef,
    o.JourneyRef,

    o.TimetabledArrivalUtc,
    o.EstimatedArrivalUtc,
    o.ArrivalDelayMinutes,

    o.TimetabledArrivalLocal,
    o.ServiceDateLocal,
    o.ScheduledArrivalSecondsLocal,

    o.PlannedBay,
    o.EstimatedBay,
    o.PlatformChanged,

    o.ExactStopCandidateCount,
    o.ParentStationCandidateCount,
    o.MatchStatus,

    ISNULL(
        CASE
            WHEN o.MatchStatus IN
            (
                N'ExactStopMatch',
                N'ParentStationFallback'
            )
            THEN CAST(1 AS bit)
            ELSE CAST(0 AS bit)
        END,
        CAST(0 AS bit)
    ) AS HasUsableStaticMatch,

    o.MatchedTripId,
    o.MatchedRouteId,
    o.MatchedServiceId,
    o.MatchedStaticStopId,

    o.ScheduledStopEventKey,
    o.TripKey,
    o.RouteKey,
    o.StopKey,
    o.ModeKey,
    o.ServiceKey,
    o.DateKey,
    o.ServiceDate,

    l.RelationScope,

    s.SituationObservationKey,
    s.ParticipantRef,
    s.SituationNumber,
    s.Summary AS SituationSummary,
    s.Description AS SituationDescription,
    s.Detail AS SituationDetail,
    s.ValidFromUtc AS SituationValidFromUtc,
    s.ValidToUtc AS SituationValidToUtc

FROM wrk.vwCologneRealtimeTripMatch AS o

LEFT JOIN stg.MddRealtimeStopSituationLink AS l
    ON l.ObservationKey = o.ObservationKey

LEFT JOIN stg.MddRealtimeSituationObservation AS s
    ON s.SituationObservationKey = l.SituationObservationKey;
GO
