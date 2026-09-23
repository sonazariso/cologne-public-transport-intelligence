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

WITH ShortNameCoverage AS
(
    /* Preserve the current RouteShortName coverage semantics exactly. */
    SELECT DISTINCT
        REPLACE(RouteShortName, N' ', N'') AS NormalizedRouteName
    FROM wrk.vwCologneServingRoute
    WHERE RouteShortName IS NOT NULL
),

CologneServingWarehouseRoute AS
(
    /*
        Restrict fallback evidence to the curated Cologne-serving population
        and its corresponding warehouse route rows. This prevents a route
        present only in stg.GtfsRoutes from becoming a valid match.
    */
    SELECT DISTINCT
        warehouse_route.RouteKey,
        warehouse_route.RouteId,
        warehouse_route.RouteShortName,
        warehouse_route.RouteLongName
    FROM dw.DimRoute AS warehouse_route
    INNER JOIN wrk.vwCologneServingRoute AS serving_route
        ON serving_route.RouteId COLLATE Latin1_General_100_BIN2
         = warehouse_route.RouteId COLLATE Latin1_General_100_BIN2
    WHERE NULLIF(LTRIM(RTRIM(warehouse_route.RouteLongName)), N'') IS NOT NULL
),

LongNameCoverage AS
(
    SELECT DISTINCT
        REPLACE(LTRIM(RTRIM(RouteLongName)), N' ', N'')
            AS NormalizedRouteName
    FROM CologneServingWarehouseRoute
),

ObservationRoutePath AS
(
    SELECT
        r.ObservationKey,

        CASE
            WHEN short_name.NormalizedRouteName IS NOT NULL
            THEN 1
            ELSE 0
        END AS HasShortNameCoverage,

        CASE
            WHEN long_name.NormalizedRouteName IS NOT NULL
            THEN 1
            ELSE 0
        END AS HasLongNameCoverage

    FROM wrk.vwCologneRealtimeTripMatchKey AS r

    LEFT JOIN ShortNameCoverage AS short_name
        ON short_name.NormalizedRouteName =
           REPLACE(r.LineName, N' ', N'')

    LEFT JOIN LongNameCoverage AS long_name
        ON long_name.NormalizedRouteName =
           REPLACE(LTRIM(RTRIM(r.LineName)), N' ', N'')
),

ShortNameCandidate AS
(
    SELECT
        r.ObservationKey,

        N'RouteShortName' AS CandidatePath,

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
        This is the existing RouteShortName candidate path. Keep its joins
        and schedule/date predicates unchanged so successful legacy matches
        continue through the same primary semantics.
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

LongNameFallbackCandidate AS
(
    SELECT
        r.ObservationKey,

        N'RouteLongNameFallback' AS CandidatePath,

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

    INNER JOIN ObservationRoutePath AS route_path
        ON route_path.ObservationKey = r.ObservationKey
       AND route_path.HasShortNameCoverage = 0
       AND route_path.HasLongNameCoverage = 1

    INNER JOIN CologneServingWarehouseRoute AS route
        ON REPLACE(LTRIM(RTRIM(route.RouteLongName)), N' ', N'')
         = REPLACE(LTRIM(RTRIM(r.LineName)), N' ', N'')

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

Candidate AS
(
    SELECT *
    FROM ShortNameCandidate

    UNION ALL

    SELECT *
    FROM LongNameFallbackCandidate
),

CandidateSummary AS
(
    SELECT
        ObservationKey,
        CandidatePath,

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
    GROUP BY ObservationKey, CandidatePath
)

SELECT
    r.*,

    ISNULL(cs.ExactStopCandidateCount, 0)
        AS ExactStopCandidateCount,

    ISNULL(cs.ParentStationCandidateCount, 0)
        AS ParentStationCandidateCount,

    CASE
        WHEN ISNULL(route_path.HasShortNameCoverage, 0) = 0
         AND ISNULL(route_path.HasLongNameCoverage, 0) = 0
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

LEFT JOIN ObservationRoutePath AS route_path
    ON route_path.ObservationKey = r.ObservationKey

LEFT JOIN CandidateSummary AS cs
    ON cs.ObservationKey = r.ObservationKey
   AND
   (
       (
           route_path.HasShortNameCoverage = 1
           AND cs.CandidatePath = N'RouteShortName'
       )
       OR
       (
           route_path.HasShortNameCoverage = 0
           AND route_path.HasLongNameCoverage = 1
           AND cs.CandidatePath = N'RouteLongNameFallback'
       )
   );
GO

/*
    Add analytical transport scope without changing technical matching truth.

    The technical match view above remains the source of MatchStatus and all
    selected warehouse keys.  This wrapper classifies only the current
    analytical boundary.  Raw observations, including out-of-scope rail,
    remain queryable at the same ObservationKey grain.

    Current-data evidence supports two safe rail paths:
      - S-Bahn / RE / RB labels are regional or suburban rail and remain in
        scope, independent of origin or destination;
      - non-regional rail with a proven long-distance label or long-distance
        rail submode, together with a LineRef and (for the submode-only path)
        an OperatorRef, is outside the seven-category Cologne analytical scope.

    RailSubmode is therefore never used alone.  Unknown combinations default
    to in-scope for review until a future data audit proves a safe exclusion.
*/
CREATE OR ALTER VIEW wrk.vwCologneRealtimeTripMatchScoped
AS
WITH Base AS
(
    SELECT
        technical_match.*,
        COALESCE
        (
            technical_match.StaticParentStationId,
            static_stop.ParentStationId,
            CASE
                WHEN static_stop.LocationTypeCode = 1
                THEN static_stop.StopId
            END
        ) AS AnalyticalParentStationId,
        COALESCE
        (
            parent_stop.StopName,
            CASE
                WHEN static_stop.LocationTypeCode = 1
                THEN static_stop.StopName
            END
        ) AS AnalyticalParentStationName
    FROM wrk.vwCologneRealtimeTripMatch AS technical_match
    LEFT JOIN dw.DimStop AS static_stop
        ON static_stop.StopId COLLATE DATABASE_DEFAULT
         = technical_match.StopPointRef COLLATE DATABASE_DEFAULT
    LEFT JOIN dw.DimStop AS parent_stop
        ON parent_stop.StopId COLLATE DATABASE_DEFAULT
         = COALESCE
           (
               technical_match.StaticParentStationId,
               static_stop.ParentStationId
           ) COLLATE DATABASE_DEFAULT
),
Evidence AS
(
    SELECT
        base.*,
        normalized.NormalizedPtMode,
        normalized.NormalizedLineName,
        normalized.NormalizedRailSubmode,
        normalized.HasLineRef,
        normalized.HasOperatorRef,
        CASE
            WHEN normalized.NormalizedPtMode = N'RAIL'
             AND
             (
                 normalized.NormalizedLineName LIKE N'S[0-9]%'
                 OR normalized.NormalizedLineName LIKE N'RE[0-9]%'
                 OR normalized.NormalizedLineName LIKE N'RB[0-9]%'
             )
            THEN 1
            ELSE 0
        END AS IsRegionalRailServiceLabel,
        CASE
            WHEN normalized.NormalizedLineName LIKE N'ICE%'
              OR normalized.NormalizedLineName LIKE N'IC%'
              OR normalized.NormalizedLineName LIKE N'FLIXTRAIN%'
              OR normalized.NormalizedLineName LIKE N'NJ%'
              OR normalized.NormalizedLineName LIKE N'THA%'
            THEN 1
            ELSE 0
        END AS HasLongDistanceLineLabelEvidence,
        CASE
            WHEN normalized.NormalizedRailSubmode IN
                 (
                     N'HIGH_SPEED_RAIL',
                     N'INTERNATIONAL',
                     N'INTERREGIONAL_RAIL'
                 )
            THEN 1
            ELSE 0
        END AS HasLongDistanceRailSubmodeEvidence
    FROM Base AS base
    CROSS APPLY
    (
        VALUES
        (
            UPPER(LTRIM(RTRIM(COALESCE(base.PtMode, N'')))),
            UPPER(REPLACE(LTRIM(RTRIM(COALESCE(base.LineName, N''))), N' ', N'')),
            UPPER(LTRIM(RTRIM(COALESCE(base.RailSubmode, N'')))),
            CASE
                WHEN NULLIF(LTRIM(RTRIM(base.LineRef)), N'') IS NOT NULL
                THEN 1 ELSE 0
            END,
            CASE
                WHEN NULLIF(LTRIM(RTRIM(base.OperatorRef)), N'') IS NOT NULL
                THEN 1 ELSE 0
            END
        )
    ) AS normalized
    (
        NormalizedPtMode,
        NormalizedLineName,
        NormalizedRailSubmode,
        HasLineRef,
        HasOperatorRef
    )
)
SELECT
    evidence.*,
    CONVERT
    (
        BIT,
        CASE
            WHEN evidence.NormalizedPtMode = N'RAIL'
             AND evidence.IsRegionalRailServiceLabel = 0
             AND evidence.HasLineRef = 1
             AND
             (
                 evidence.HasLongDistanceLineLabelEvidence = 1
                 OR
                 (
                     evidence.HasLongDistanceRailSubmodeEvidence = 1
                     AND evidence.HasOperatorRef = 1
                 )
             )
            THEN 0
            ELSE 1
        END
    ) AS IsInAnalyticalTransportScope,
    CASE
        WHEN evidence.NormalizedPtMode = N'RAIL'
         AND evidence.IsRegionalRailServiceLabel = 0
         AND evidence.HasLineRef = 1
         AND
         (
             evidence.HasLongDistanceLineLabelEvidence = 1
             OR
             (
                 evidence.HasLongDistanceRailSubmodeEvidence = 1
                 AND evidence.HasOperatorRef = 1
             )
         )
            THEN N'OutOfScopeLongDistanceRailServiceClass'
        WHEN evidence.IsRegionalRailServiceLabel = 1
            THEN N'InScopeRegionalOrSuburbanRailServiceClass'
        WHEN evidence.NormalizedPtMode IN (N'BUS', N'TRAM')
            THEN N'InScopeDefinedNonRailTransportMode'
        WHEN evidence.MatchStatus IN
             (N'ExactStopMatch', N'ParentStationFallback')
            THEN N'InScopeTechnicallyMatchedService'
        ELSE N'InScopeDefaultNoProvenExclusion'
    END AS AnalyticalTransportScopeReason
FROM Evidence AS evidence;
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
    o.AnalyticalParentStationId,
    o.AnalyticalParentStationName,
    o.StaticStopName,
    o.StaticStopMatched,

    o.LineName,
    o.LineRef,
    o.JourneyRef,
    o.OperatorRef,
    o.PtMode,
    o.RailSubmode,

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
    o.IsInAnalyticalTransportScope,
    o.AnalyticalTransportScopeReason,

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

FROM wrk.vwCologneRealtimeTripMatchScoped AS o

LEFT JOIN stg.MddRealtimeStopSituationLink AS l
    ON l.ObservationKey = o.ObservationKey

LEFT JOIN stg.MddRealtimeSituationObservation AS s
    ON s.SituationObservationKey = l.SituationObservationKey;
GO
