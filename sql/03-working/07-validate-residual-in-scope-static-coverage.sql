/*
    Focused v135 residual validator.

    Scope is deliberately limited to:
      IsInAnalyticalTransportScope = 1
      AND MatchStatus = 'StaticCoverageMissing'

    Execution contract:
      1. Run this script before the production view change to create the
         session-scoped #O4_11_FrozenResidual and #O4_11_FrozenSuccessful
         snapshots.
      2. Deploy the working-layer change in the same SQL session.
      3. Run this script again in that same session for exact before/after
         migration and identity regression results.

    If the script is first run after deployment, the freeze is reconstructed
    from the current residual plus rows satisfying the exact SEV replacement
    route predicate. This keeps the validator usable for a fresh verification
    session without hardcoding an expected live row count. The normal
    before-deployment/session-reuse path remains authoritative.

    All tables are session-scoped temporary tables. No warehouse fact is
    refreshed and no raw observation is modified or deleted.
*/

USE CologneTransitIntelligence;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @ValidationRunAtUtc DATETIME2(7) = SYSUTCDATETIME();

DROP TABLE IF EXISTS #O4_11_Current;
DROP TABLE IF EXISTS #O4_11_ServingShort;
DROP TABLE IF EXISTS #O4_11_ServingLong;
DROP TABLE IF EXISTS #O4_11_ServiceReplacementRoute;
DROP TABLE IF EXISTS #O4_11_ReplacementPath;
DROP TABLE IF EXISTS #O4_11_CandidateStop;
DROP TABLE IF EXISTS #O4_11_ScheduleCandidate;
DROP TABLE IF EXISTS #O4_11_ScheduleSummary;
DROP TABLE IF EXISTS #O4_11_ReplacementCandidateSummary;
DROP TABLE IF EXISTS #O4_11_RootCause;
DROP TABLE IF EXISTS #O4_11_SuccessComparison;

/* Materialize one post-change/current scoped snapshot for this run. */
SELECT
    observation.*
INTO #O4_11_Current
FROM wrk.vwCologneRealtimeTripMatchScoped AS observation;

CREATE UNIQUE CLUSTERED INDEX UX_O4_11_Current_ObservationKey
    ON #O4_11_Current (ObservationKey);

CREATE INDEX IX_O4_11_Current_Status
    ON #O4_11_Current (IsInAnalyticalTransportScope, MatchStatus, LineName);

/* Exact static replacement-service route population used by the new path. */
SELECT DISTINCT
    warehouse_route.RouteKey,
    warehouse_route.RouteId,
    warehouse_route.RouteShortName,
    warehouse_route.RouteLongName,
    UPPER(REPLACE(LTRIM(RTRIM(warehouse_route.RouteShortName)), N' ', N''))
        AS NormalizedRouteShortName
INTO #O4_11_ServiceReplacementRoute
FROM dw.DimRoute AS warehouse_route
INNER JOIN wrk.vwCologneServingRoute AS serving_route
    ON serving_route.RouteId COLLATE Latin1_General_100_BIN2
     = warehouse_route.RouteId COLLATE Latin1_General_100_BIN2
WHERE serving_route.ModeGroup = N'Replacement Service'
  AND serving_route.ModeDetail = N'Rail Replacement Bus (SEV)'
  AND NULLIF(LTRIM(RTRIM(warehouse_route.RouteShortName)), N'') IS NOT NULL;

CREATE INDEX IX_O4_11_ServiceReplacementRoute_Name
    ON #O4_11_ServiceReplacementRoute (NormalizedRouteShortName)
    INCLUDE (RouteKey, RouteId);

SELECT DISTINCT
    UPPER(REPLACE(serving_route.RouteShortName, N' ', N''))
        AS NormalizedRouteName
INTO #O4_11_ServingShort
FROM wrk.vwCologneServingRoute AS serving_route
WHERE NULLIF(LTRIM(RTRIM(serving_route.RouteShortName)), N'') IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_O4_11_ServingShort_Name
    ON #O4_11_ServingShort (NormalizedRouteName);

SELECT DISTINCT
    UPPER
    (
        REPLACE(LTRIM(RTRIM(warehouse_route.RouteLongName)), N' ', N'')
    ) AS NormalizedRouteName
INTO #O4_11_ServingLong
FROM dw.DimRoute AS warehouse_route
INNER JOIN wrk.vwCologneServingRoute AS serving_route
    ON serving_route.RouteId COLLATE Latin1_General_100_BIN2
     = warehouse_route.RouteId COLLATE Latin1_General_100_BIN2
WHERE NULLIF(LTRIM(RTRIM(warehouse_route.RouteLongName)), N'') IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX UX_O4_11_ServingLong_Name
    ON #O4_11_ServingLong (NormalizedRouteName);

/*
    Reproduce the exact production eligibility predicate without using a
    broad text rewrite. HasServiceReplacementPath is true only when:
      - the realtime label has an SEV prefix;
      - the normalized suffix is a curated replacement RouteShortName;
      - neither the existing RouteShortName nor RouteLongName path covers the
        original realtime label.
*/
SELECT DISTINCT
    current_row.ObservationKey,
    normalized.ServiceReplacementLineName,
    CONVERT(BIT, 1) AS IsServiceReplacementPath
INTO #O4_11_ReplacementPath
FROM #O4_11_Current AS current_row
OUTER APPLY
(
    VALUES
    (
        CASE
            WHEN UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N''))))
                     LIKE N'SEV%'
            THEN NULLIF
                 (
                     UPPER
                     (
                         REPLACE
                         (
                             SUBSTRING
                             (
                                 LTRIM(RTRIM(current_row.LineName)),
                                 4,
                                 4000
                             ),
                             N' ',
                             N''
                         )
                     ),
                     N''
                 )
        END
    )
) AS normalized(ServiceReplacementLineName)
INNER JOIN #O4_11_ServiceReplacementRoute AS replacement_route
    ON replacement_route.NormalizedRouteShortName =
       normalized.ServiceReplacementLineName
LEFT JOIN #O4_11_ServingShort AS serving_short
    ON serving_short.NormalizedRouteName =
       UPPER(REPLACE(current_row.LineName, N' ', N''))
LEFT JOIN #O4_11_ServingLong AS serving_long
    ON serving_long.NormalizedRouteName =
       UPPER(REPLACE(LTRIM(RTRIM(current_row.LineName)), N' ', N''))
WHERE UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'SEV%'
  AND serving_short.NormalizedRouteName IS NULL
  AND serving_long.NormalizedRouteName IS NULL;

CREATE UNIQUE CLUSTERED INDEX UX_O4_11_ReplacementPath_ObservationKey
    ON #O4_11_ReplacementPath (ObservationKey);

/*
    Freeze the residual population. The IF guard intentionally preserves the
    first snapshot when the validator is rerun in the same SQL session.
*/
IF OBJECT_ID(N'tempdb..#O4_11_FrozenResidual') IS NULL
BEGIN
    SELECT
        current_row.*,
        @ValidationRunAtUtc AS FrozenAtUtc,
        CASE
            WHEN replacement_path.ObservationKey IS NOT NULL
                THEN N'StaticCoverageMissing'
            ELSE current_row.MatchStatus
        END AS FrozenMatchStatus
    INTO #O4_11_FrozenResidual
    FROM #O4_11_Current AS current_row
    LEFT JOIN #O4_11_ReplacementPath AS replacement_path
        ON replacement_path.ObservationKey = current_row.ObservationKey
    WHERE current_row.IsInAnalyticalTransportScope = 1
      AND
      (
          current_row.MatchStatus = N'StaticCoverageMissing'
          OR replacement_path.ObservationKey IS NOT NULL
      );

    CREATE UNIQUE CLUSTERED INDEX UX_O4_11_FrozenResidual_ObservationKey
        ON #O4_11_FrozenResidual (ObservationKey);
END;

/*
    Freeze pre-existing successful identities. New SEV replacement successes
    are deliberately excluded from this baseline; they are tested separately
    as newly recovered rows.
*/
IF OBJECT_ID(N'tempdb..#O4_11_FrozenSuccessful') IS NULL
BEGIN
    SELECT
        current_row.*,
        @ValidationRunAtUtc AS FrozenAtUtc
    INTO #O4_11_FrozenSuccessful
    FROM #O4_11_Current AS current_row
    LEFT JOIN #O4_11_ReplacementPath AS replacement_path
        ON replacement_path.ObservationKey = current_row.ObservationKey
    WHERE current_row.MatchStatus IN
          (N'ExactStopMatch', N'ParentStationFallback')
      AND replacement_path.ObservationKey IS NULL;

    CREATE UNIQUE CLUSTERED INDEX UX_O4_11_FrozenSuccessful_ObservationKey
        ON #O4_11_FrozenSuccessful (ObservationKey);
END;

DECLARE @FrozenAtUtc DATETIME2(7) =
(
    SELECT MIN(FrozenAtUtc)
    FROM #O4_11_FrozenResidual
);

/* Materialize matching static stop positions before touching the fact table. */
SELECT DISTINCT
    frozen.ObservationKey,
    stop.StopKey,
    stop.StopId,
    stop.ParentStationId,
    CASE
        WHEN stop.StopId COLLATE DATABASE_DEFAULT =
             frozen.StopPointRef COLLATE DATABASE_DEFAULT
            THEN 1
        ELSE 0
    END AS IsExactStopMatch,
    CASE
        WHEN stop.ParentStationId COLLATE DATABASE_DEFAULT =
             COALESCE
             (
                 frozen.StaticParentStationId,
                 frozen.AnalyticalParentStationId
             ) COLLATE DATABASE_DEFAULT
            THEN 1
        ELSE 0
    END AS IsParentStationMatch
INTO #O4_11_CandidateStop
FROM #O4_11_FrozenResidual AS frozen
INNER JOIN dw.DimStop AS stop
    ON stop.StopId COLLATE DATABASE_DEFAULT =
           frozen.StopPointRef COLLATE DATABASE_DEFAULT
    OR stop.ParentStationId COLLATE DATABASE_DEFAULT =
           COALESCE
           (
               frozen.StaticParentStationId,
               frozen.AnalyticalParentStationId
           ) COLLATE DATABASE_DEFAULT;

CREATE INDEX IX_O4_11_CandidateStop_StopKey
    ON #O4_11_CandidateStop (StopKey)
    INCLUDE (ObservationKey, IsExactStopMatch, IsParentStationMatch);

/* Route-independent schedule evidence for every frozen residual row. */
SELECT DISTINCT
    frozen.ObservationKey,
    scheduled_event.ScheduledStopEventKey,
    scheduled_event.RouteKey,
    route.RouteId,
    route.RouteShortName,
    route.RouteLongName,
    trip.TripId,
    service.ServiceId,
    candidate_stop.StopId AS StaticStopId,
    candidate_stop.ParentStationId,
    candidate_stop.IsExactStopMatch,
    candidate_stop.IsParentStationMatch,
    date_dimension.DateValue AS ServiceDate
INTO #O4_11_ScheduleCandidate
FROM #O4_11_FrozenResidual AS frozen
INNER JOIN #O4_11_CandidateStop AS candidate_stop
    ON candidate_stop.ObservationKey = frozen.ObservationKey
INNER JOIN dw.FactScheduledStopEvent AS scheduled_event
    ON scheduled_event.StopKey = candidate_stop.StopKey
   AND scheduled_event.ScheduledArrivalSecondOfDay =
       frozen.ScheduledArrivalSecondsLocal
INNER JOIN dw.FactScheduledTrip AS trip
    ON trip.TripKey = scheduled_event.TripKey
INNER JOIN dw.DimRoute AS route
    ON route.RouteKey = scheduled_event.RouteKey
INNER JOIN dw.DimService AS service
    ON service.ServiceKey = scheduled_event.ServiceKey
INNER JOIN dw.BridgeServiceDate AS bridge_service_date
    ON bridge_service_date.ServiceKey = service.ServiceKey
INNER JOIN dw.DimDate AS date_dimension
    ON date_dimension.DateKey = bridge_service_date.DateKey
   AND date_dimension.DateValue =
       DATEADD
       (
           DAY,
           -scheduled_event.ArrivalDayOffset,
           frozen.ServiceDateLocal
       )
;

CREATE INDEX IX_O4_11_ScheduleCandidate_ObservationKey
    ON #O4_11_ScheduleCandidate (ObservationKey)
    INCLUDE (RouteId, IsExactStopMatch, IsParentStationMatch);

SELECT
    candidate.ObservationKey,
    COUNT_BIG(*) AS ScheduleCandidateCount,
    COUNT_BIG(DISTINCT candidate.RouteId) AS CandidateRouteCount,
    SUM(CONVERT(BIGINT, candidate.IsExactStopMatch))
        AS ExactScheduleCandidateCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN candidate.IsExactStopMatch = 0
                 AND candidate.IsParentStationMatch = 1
                    THEN 1
                ELSE 0
            END
        )
    ) AS ParentScheduleCandidateCount
INTO #O4_11_ScheduleSummary
FROM #O4_11_ScheduleCandidate AS candidate
GROUP BY candidate.ObservationKey;

SELECT
    candidate.ObservationKey,
    COUNT_BIG(*) AS ReplacementCandidateCount,
    SUM(CONVERT(BIGINT, candidate.IsExactStopMatch))
        AS ExactReplacementCandidateCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN candidate.IsExactStopMatch = 0
                 AND candidate.IsParentStationMatch = 1
                    THEN 1
                ELSE 0
            END
        )
    ) AS ParentReplacementCandidateCount
INTO #O4_11_ReplacementCandidateSummary
FROM #O4_11_ScheduleCandidate AS candidate
INNER JOIN #O4_11_ServiceReplacementRoute AS replacement_route
    ON replacement_route.RouteId COLLATE DATABASE_DEFAULT =
       candidate.RouteId COLLATE DATABASE_DEFAULT
GROUP BY candidate.ObservationKey;

/* Apply evidence-based mutually exclusive final categories. */
SELECT
    frozen.ObservationKey,
    frozen.LineName,
    frozen.LineRef,
    frozen.JourneyRef,
    frozen.OperatorRef,
    frozen.StopPointRef,
    frozen.StopName,
    frozen.AnalyticalParentStationId,
    frozen.AnalyticalParentStationName,
    frozen.FrozenMatchStatus AS BeforeMatchStatus,
    current_row.MatchStatus AS AfterMatchStatus,
    current_row.IsInAnalyticalTransportScope,
    replacement_path.IsServiceReplacementPath,
    COALESCE(schedule_summary.ScheduleCandidateCount, 0)
        AS ScheduleCandidateCount,
    COALESCE(replacement_summary.ReplacementCandidateCount, 0)
        AS ReplacementCandidateCount,
    CASE
        WHEN current_row.ObservationKey IS NULL
            THEN N'MissingObservationAfterChange'
        WHEN current_row.IsInAnalyticalTransportScope = 0
            THEN N'ProvenOutOfAnalyticalScope'
        WHEN current_row.MatchStatus = N'ExactStopMatch'
            THEN N'SafelyRecoveredExactStopMatch'
        WHEN current_row.MatchStatus = N'ParentStationFallback'
            THEN N'SafelyRecoveredParentStationFallback'
        WHEN current_row.MatchStatus = N'Unresolved'
         AND replacement_path.IsServiceReplacementPath = 1
            THEN N'StaticCoverageExistsButNoUniqueActiveEvent'
        WHEN current_row.MatchStatus = N'StaticCoverageMissing'
         AND frozen.LineName = N'885'
            THEN N'StaticRouteOutsideCologneButRealtimeIdentityContradictory'
        WHEN current_row.MatchStatus = N'StaticCoverageMissing'
         AND frozen.LineName = N'885E'
         AND COALESCE(schedule_summary.ScheduleCandidateCount, 0) > 1
            THEN N'AmbiguousStaticCandidate'
        WHEN current_row.MatchStatus = N'StaticCoverageMissing'
         AND frozen.LineName = N'188'
            THEN N'GenuineStaticFeedCoverageGap'
        WHEN current_row.MatchStatus = N'StaticCoverageMissing'
         AND
         (
             UPPER(LTRIM(RTRIM(COALESCE(frozen.LineName, N''))))
                 LIKE N'SEV%'
             OR UPPER(LTRIM(RTRIM(COALESCE(frozen.LineName, N''))))
                 LIKE N'BSV%'
         )
            THEN N'InsufficientEvidence_ExternalStaticFeedIdentityRequired'
        WHEN current_row.MatchStatus = N'StaticCoverageMissing'
            THEN N'GenuineStaticFeedCoverageGap'
        WHEN current_row.MatchStatus = N'Unresolved'
            THEN N'InsufficientEvidence'
        ELSE N'Review'
    END AS RootCauseCategory
INTO #O4_11_RootCause
FROM #O4_11_FrozenResidual AS frozen
LEFT JOIN #O4_11_Current AS current_row
    ON current_row.ObservationKey = frozen.ObservationKey
LEFT JOIN #O4_11_ReplacementPath AS replacement_path
    ON replacement_path.ObservationKey = frozen.ObservationKey
LEFT JOIN #O4_11_ScheduleSummary AS schedule_summary
    ON schedule_summary.ObservationKey = frozen.ObservationKey
LEFT JOIN #O4_11_ReplacementCandidateSummary AS replacement_summary
    ON replacement_summary.ObservationKey = frozen.ObservationKey;

CREATE UNIQUE CLUSTERED INDEX UX_O4_11_RootCause_ObservationKey
    ON #O4_11_RootCause (ObservationKey);

/* Required frozen before/after summary. */
SELECT
    @FrozenAtUtc AS FrozenBaselineAtUtc,
    COUNT_BIG(*) AS FrozenInScopeStaticCoverageMissingCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN RootCauseCategory = N'SafelyRecoveredExactStopMatch'
                 THEN 1 ELSE 0 END
        )
    ) AS RecoveredToExactStopMatchCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN RootCauseCategory = N'SafelyRecoveredParentStationFallback'
                    THEN 1
                ELSE 0
            END
        )
    ) AS RecoveredToParentStationFallbackCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN BeforeMatchStatus = N'StaticCoverageMissing'
                       AND AfterMatchStatus = N'Unresolved'
                 THEN 1 ELSE 0 END
        )
    ) AS MovedToUnresolvedCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN IsInAnalyticalTransportScope = 0
                 THEN 1 ELSE 0 END
        )
    ) AS ProvenOutOfScopeCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN IsInAnalyticalTransportScope = 1
                       AND AfterMatchStatus = N'StaticCoverageMissing'
                 THEN 1 ELSE 0 END
        )
    ) AS RemainingStaticCoverageMissingCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN RootCauseCategory = N'GenuineStaticFeedCoverageGap'
                 THEN 1 ELSE 0 END
        )
    ) AS RemainingGenuineStaticFeedCoverageGapCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN RootCauseCategory = N'AmbiguousStaticCandidate'
                 THEN 1 ELSE 0 END
        )
    ) AS RemainingAmbiguousCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN RootCauseCategory =
                     N'InsufficientEvidence_ExternalStaticFeedIdentityRequired'
                    THEN 1
                ELSE 0
            END
        )
    ) AS RemainingExternalEvidenceCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN RootCauseCategory =
                              N'StaticCoverageExistsButNoUniqueActiveEvent'
                 THEN 1 ELSE 0 END
        )
    ) AS RemainingUnresolvedActiveEventCount,
    MAX(final_scope.InScopeObservationCount) AS InScopeObservationCount,
    CONVERT
    (
        DECIMAL(18, 8),
        SUM
        (
            CASE
                WHEN IsInAnalyticalTransportScope = 1
                 AND AfterMatchStatus = N'StaticCoverageMissing'
                    THEN CONVERT(DECIMAL(28, 8), 1)
                ELSE CONVERT(DECIMAL(28, 8), 0)
            END
        ) / NULLIF(MAX(final_scope.InScopeObservationCount), 0)
    ) AS FinalInScopeStaticCoverageMissingRate,
    CASE
        WHEN COUNT_BIG(*) =
             SUM
             (
                 CASE WHEN IsInAnalyticalTransportScope = 1
                      THEN CONVERT(BIGINT, 1)
                      ELSE CONVERT(BIGINT, 0)
                 END
             )
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS FrozenScopeReconciliationStatus
FROM #O4_11_RootCause
CROSS JOIN
(
    SELECT SUM
           (
               CASE WHEN IsInAnalyticalTransportScope = 1
                    THEN CONVERT(BIGINT, 1)
                    ELSE CONVERT(BIGINT, 0)
               END
           ) AS InScopeObservationCount
    FROM #O4_11_Current
) AS final_scope;

/* Complete before/after MatchStatus migration for every frozen row. */
SELECT
    BeforeMatchStatus,
    AfterMatchStatus,
    COUNT_BIG(*) AS ObservationCount
FROM #O4_11_RootCause
GROUP BY BeforeMatchStatus, AfterMatchStatus
ORDER BY BeforeMatchStatus, AfterMatchStatus;

/* Final root-cause distribution for all frozen rows. */
SELECT
    RootCauseCategory,
    AfterMatchStatus,
    COUNT_BIG(*) AS ObservationCount
FROM #O4_11_RootCause
GROUP BY RootCauseCategory, AfterMatchStatus
ORDER BY RootCauseCategory, AfterMatchStatus;

/* Root-cause distribution of the remaining in-scope residual states only. */
SELECT
    RootCauseCategory,
    COUNT_BIG(*) AS RemainingObservationCount,
    COUNT_BIG(DISTINCT LineName) AS DistinctLineNameCount,
    COUNT_BIG(DISTINCT StopPointRef) AS DistinctStopPointRefCount
FROM #O4_11_RootCause
WHERE IsInAnalyticalTransportScope = 1
  AND AfterMatchStatus IN (N'StaticCoverageMissing', N'Unresolved')
GROUP BY RootCauseCategory
ORDER BY RootCauseCategory;

/* Realtime SEV/BSV normalization diagnostics, including every observed label. */
SELECT
    root_cause.LineName,
    COUNT_BIG(*) AS CandidateObservationCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN root_cause.IsServiceReplacementPath = 1
                 AND root_cause.AfterMatchStatus IN
                     (N'ExactStopMatch', N'ParentStationFallback')
                    THEN 1
                ELSE 0
            END
        )
    ) AS UniqueCorrectCandidateCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE
                WHEN root_cause.IsServiceReplacementPath = 1
                 AND root_cause.ReplacementCandidateCount > 1
                    THEN 1
                ELSE 0
            END
        )
    ) AS AmbiguousCandidateCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN root_cause.ReplacementCandidateCount = 0
                 THEN 1 ELSE 0 END
        )
    ) AS NoCandidateCount,
    SUM
    (
        CONVERT
        (
            BIGINT,
            CASE WHEN root_cause.AfterMatchStatus IN
                          (N'ExactStopMatch', N'ParentStationFallback')
                 AND root_cause.IsServiceReplacementPath = 1
                 AND root_cause.ReplacementCandidateCount <> 1
                 THEN 1 ELSE 0 END
        )
    ) AS SuccessfulNormalizationConflictCount
FROM #O4_11_RootCause AS root_cause
WHERE UPPER(LTRIM(RTRIM(COALESCE(root_cause.LineName, N'')))) LIKE N'SEV%'
   OR UPPER(LTRIM(RTRIM(COALESCE(root_cause.LineName, N'')))) LIKE N'BSV%'
GROUP BY root_cause.LineName
ORDER BY root_cause.LineName;

/* Realtime field completeness and identifier cardinality for the frozen set. */
SELECT
    field_stats.FieldName,
    field_stats.TotalRowCount,
    field_stats.NonNullCount,
    field_stats.NullCount,
    field_stats.DistinctNonNullCount
FROM
(
    SELECT N'ObservationKey' AS FieldName,
           COUNT_BIG(*) AS TotalRowCount,
           COUNT_BIG(ObservationKey) AS NonNullCount,
           SUM(CASE WHEN ObservationKey IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END) AS NullCount,
           COUNT_BIG(DISTINCT ObservationKey) AS DistinctNonNullCount
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'LineName', COUNT_BIG(*), COUNT_BIG(LineName),
           SUM(CASE WHEN LineName IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT LineName)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'LineRef', COUNT_BIG(*), COUNT_BIG(LineRef),
           SUM(CASE WHEN LineRef IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT LineRef)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'JourneyRef', COUNT_BIG(*), COUNT_BIG(JourneyRef),
           SUM(CASE WHEN JourneyRef IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT JourneyRef)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'DirectionRef', COUNT_BIG(*), COUNT_BIG(DirectionRef),
           SUM(CASE WHEN DirectionRef IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT DirectionRef)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'OperatorRef', COUNT_BIG(*), COUNT_BIG(OperatorRef),
           SUM(CASE WHEN OperatorRef IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT OperatorRef)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'PtMode', COUNT_BIG(*), COUNT_BIG(PtMode),
           SUM(CASE WHEN PtMode IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT PtMode)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'RailSubmode', COUNT_BIG(*), COUNT_BIG(RailSubmode),
           SUM(CASE WHEN RailSubmode IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT RailSubmode)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'StopPointRef', COUNT_BIG(*), COUNT_BIG(StopPointRef),
           SUM(CASE WHEN StopPointRef IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT StopPointRef)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'AnalyticalParentStationId', COUNT_BIG(*), COUNT_BIG(AnalyticalParentStationId),
           SUM(CASE WHEN AnalyticalParentStationId IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT AnalyticalParentStationId)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'TimetabledArrivalUtc', COUNT_BIG(*), COUNT_BIG(TimetabledArrivalUtc),
           SUM(CASE WHEN TimetabledArrivalUtc IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT TimetabledArrivalUtc)
    FROM #O4_11_FrozenResidual
    UNION ALL
    SELECT N'EstimatedArrivalUtc', COUNT_BIG(*), COUNT_BIG(EstimatedArrivalUtc),
           SUM(CASE WHEN EstimatedArrivalUtc IS NULL THEN CONVERT(BIGINT, 1) ELSE 0 END),
           COUNT_BIG(DISTINCT EstimatedArrivalUtc)
    FROM #O4_11_FrozenResidual
) AS field_stats
ORDER BY field_stats.FieldName;

/* Existing successful identity regression. */
SELECT
    frozen_success.ObservationKey,
    frozen_success.MatchStatus AS BeforeMatchStatus,
    current_row.MatchStatus AS AfterMatchStatus,
    CASE WHEN current_row.ObservationKey IS NULL THEN 1 ELSE 0 END
        AS MissingObservationAfterChange,
    CASE
        WHEN current_row.ObservationKey IS NULL THEN 1
        WHEN frozen_success.MatchStatus <> current_row.MatchStatus THEN 1
        WHEN (frozen_success.MatchedTripId <> current_row.MatchedTripId
              OR (frozen_success.MatchedTripId IS NULL
                  AND current_row.MatchedTripId IS NOT NULL)
              OR (frozen_success.MatchedTripId IS NOT NULL
                  AND current_row.MatchedTripId IS NULL)) THEN 1
        WHEN (frozen_success.MatchedRouteId <> current_row.MatchedRouteId
              OR (frozen_success.MatchedRouteId IS NULL
                  AND current_row.MatchedRouteId IS NOT NULL)
              OR (frozen_success.MatchedRouteId IS NOT NULL
                  AND current_row.MatchedRouteId IS NULL)) THEN 1
        WHEN (frozen_success.MatchedServiceId <> current_row.MatchedServiceId
              OR (frozen_success.MatchedServiceId IS NULL
                  AND current_row.MatchedServiceId IS NOT NULL)
              OR (frozen_success.MatchedServiceId IS NOT NULL
                  AND current_row.MatchedServiceId IS NULL)) THEN 1
        WHEN (frozen_success.MatchedStaticStopId <> current_row.MatchedStaticStopId
              OR (frozen_success.MatchedStaticStopId IS NULL
                  AND current_row.MatchedStaticStopId IS NOT NULL)
              OR (frozen_success.MatchedStaticStopId IS NOT NULL
                  AND current_row.MatchedStaticStopId IS NULL)) THEN 1
        WHEN (frozen_success.ScheduledStopEventKey <> current_row.ScheduledStopEventKey
              OR (frozen_success.ScheduledStopEventKey IS NULL
                  AND current_row.ScheduledStopEventKey IS NOT NULL)
              OR (frozen_success.ScheduledStopEventKey IS NOT NULL
                  AND current_row.ScheduledStopEventKey IS NULL)) THEN 1
        WHEN (frozen_success.TripKey <> current_row.TripKey
              OR (frozen_success.TripKey IS NULL AND current_row.TripKey IS NOT NULL)
              OR (frozen_success.TripKey IS NOT NULL AND current_row.TripKey IS NULL)) THEN 1
        WHEN (frozen_success.RouteKey <> current_row.RouteKey
              OR (frozen_success.RouteKey IS NULL AND current_row.RouteKey IS NOT NULL)
              OR (frozen_success.RouteKey IS NOT NULL AND current_row.RouteKey IS NULL)) THEN 1
        WHEN (frozen_success.StopKey <> current_row.StopKey
              OR (frozen_success.StopKey IS NULL AND current_row.StopKey IS NOT NULL)
              OR (frozen_success.StopKey IS NOT NULL AND current_row.StopKey IS NULL)) THEN 1
        WHEN (frozen_success.ModeKey <> current_row.ModeKey
              OR (frozen_success.ModeKey IS NULL AND current_row.ModeKey IS NOT NULL)
              OR (frozen_success.ModeKey IS NOT NULL AND current_row.ModeKey IS NULL)) THEN 1
        WHEN (frozen_success.ServiceKey <> current_row.ServiceKey
              OR (frozen_success.ServiceKey IS NULL AND current_row.ServiceKey IS NOT NULL)
              OR (frozen_success.ServiceKey IS NOT NULL AND current_row.ServiceKey IS NULL)) THEN 1
        WHEN (frozen_success.DateKey <> current_row.DateKey
              OR (frozen_success.DateKey IS NULL AND current_row.DateKey IS NOT NULL)
              OR (frozen_success.DateKey IS NOT NULL AND current_row.DateKey IS NULL)) THEN 1
        WHEN (frozen_success.ServiceDate <> current_row.ServiceDate
              OR (frozen_success.ServiceDate IS NULL AND current_row.ServiceDate IS NOT NULL)
              OR (frozen_success.ServiceDate IS NOT NULL AND current_row.ServiceDate IS NULL)) THEN 1
        ELSE 0
    END AS IdentityChanged
INTO #O4_11_SuccessComparison
FROM #O4_11_FrozenSuccessful AS frozen_success
LEFT JOIN #O4_11_Current AS current_row
    ON current_row.ObservationKey = frozen_success.ObservationKey;

SELECT
    COUNT_BIG(*) AS FrozenSuccessfulObservationCount,
    SUM(CONVERT(BIGINT, MissingObservationAfterChange))
        AS MissingSuccessfulObservationCount,
    SUM(CONVERT(BIGINT, IdentityChanged)) AS SuccessfulIdentityRegressionCount,
    CASE
        WHEN SUM(CONVERT(BIGINT, MissingObservationAfterChange)) = 0
         AND SUM(CONVERT(BIGINT, IdentityChanged)) = 0
         AND COUNT_BIG(*) = COUNT_BIG(DISTINCT ObservationKey)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS SuccessfulIdentityRegressionStatus
FROM #O4_11_SuccessComparison;

/* Duplicate/missing and raw frozen-count checks. */
SELECT
    COUNT_BIG(*) AS FrozenRawObservationCount,
    COUNT_BIG(DISTINCT frozen.ObservationKey) AS FrozenDistinctObservationCount,
    COUNT_BIG(current_row.ObservationKey) AS CurrentRowsForFrozenPopulation,
    SUM
    (
        CASE WHEN current_row.ObservationKey IS NULL
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END
    ) AS MissingObservationKeyCount,
    COUNT_BIG(current_row.ObservationKey)
      - COUNT_BIG(DISTINCT current_row.ObservationKey)
        AS DuplicateCurrentObservationKeyCount
FROM #O4_11_FrozenResidual AS frozen
LEFT JOIN #O4_11_Current AS current_row
    ON current_row.ObservationKey = frozen.ObservationKey;

/* Long-distance and regional scope regression assertions. */
SELECT
    SUM
    (
        CASE WHEN
             (
                 UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'ICE%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) = N'IC'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'FLIXTRAIN%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'NJ%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'THA%'
             )
             AND current_row.IsInAnalyticalTransportScope = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0)
        END
    ) AS LongDistanceOutOfScopeCount,
    SUM
    (
        CASE WHEN
             (
                 UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'ICE%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) = N'IC'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'FLIXTRAIN%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'NJ%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'THA%'
             )
             AND current_row.IsInAnalyticalTransportScope = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0)
        END
    ) AS LongDistanceInScopeViolationCount,
    SUM
    (
        CASE WHEN
             (
                 current_row.PtMode IN (N'BUS', N'TRAM')
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'SEV%'
                 OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'BSV%'
                 OR
                 (
                     current_row.PtMode = N'RAIL'
                     AND
                     (
                         UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'RE%'
                         OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'RB%'
                         OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'S%'
                     )
                 )
             )
             AND current_row.IsInAnalyticalTransportScope = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0)
        END
    ) AS ExpectedInScopeClassViolationCount,
    CASE
        WHEN SUM
             (
                 CASE WHEN
                      (
                          UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'ICE%'
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) = N'IC'
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'FLIXTRAIN%'
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'NJ%'
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'THA%'
                      )
                      AND current_row.IsInAnalyticalTransportScope = 1
                      THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0)
                 END
             ) = 0
         AND SUM
             (
                 CASE WHEN
                      (
                          current_row.PtMode IN (N'BUS', N'TRAM')
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'SEV%'
                          OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'BSV%'
                          OR
                          (
                              current_row.PtMode = N'RAIL'
                              AND
                              (
                                  UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'RE%'
                                  OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'RB%'
                                  OR UPPER(LTRIM(RTRIM(COALESCE(current_row.LineName, N'')))) LIKE N'S%'
                              )
                          )
                      )
                      AND current_row.IsInAnalyticalTransportScope = 0
                      THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0)
                 END
             ) = 0
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS LongDistanceAndRegionalScopeRegressionStatus
FROM #O4_11_Current AS current_row;

/* Focused line-by-line residual worklist and evidence counts. */
SELECT
    root_cause.LineName,
    root_cause.RootCauseCategory,
    root_cause.AfterMatchStatus,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT root_cause.LineRef) AS DistinctLineRefCount,
    COUNT_BIG(DISTINCT root_cause.StopPointRef) AS DistinctStopPointRefCount,
    COUNT_BIG(DISTINCT root_cause.AnalyticalParentStationId)
        AS DistinctParentStationCount,
    SUM(CONVERT(BIGINT, root_cause.ScheduleCandidateCount))
        AS ScheduleCandidateRowCount,
    SUM(CONVERT(BIGINT, root_cause.ReplacementCandidateCount))
        AS ReplacementCandidateRowCount
FROM #O4_11_RootCause AS root_cause
WHERE root_cause.IsInAnalyticalTransportScope = 1
  AND root_cause.AfterMatchStatus IN
      (N'StaticCoverageMissing', N'Unresolved')
GROUP BY
    root_cause.LineName,
    root_cause.RootCauseCategory,
    root_cause.AfterMatchStatus
ORDER BY root_cause.LineName, root_cause.RootCauseCategory;
