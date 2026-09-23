/*
    Read-only validator for the analytical transport-scope wrapper.

    This script does not change staging, collector behavior, sampling,
    warehouse facts, matching keys, MatchStatus, or timing semantics.  The
    temporary tables below are session-scoped and are used only to make the
    reconciliation outputs repeatable.
*/
USE CologneTransitIntelligence;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DROP TABLE IF EXISTS #TechnicalMatch;
DROP TABLE IF EXISTS #ScopedMatch;

SELECT
    technical_match.ObservationKey,
    technical_match.MatchStatus,
    technical_match.MatchedTripId,
    technical_match.MatchedRouteId,
    technical_match.MatchedServiceId,
    technical_match.MatchedStaticStopId,
    technical_match.ScheduledStopEventKey,
    technical_match.TripKey,
    technical_match.RouteKey,
    technical_match.StopKey,
    technical_match.ModeKey,
    technical_match.ServiceKey,
    technical_match.DateKey,
    technical_match.ServiceDate
INTO #TechnicalMatch
FROM wrk.vwCologneRealtimeTripMatch AS technical_match;

CREATE UNIQUE CLUSTERED INDEX UX_TechnicalMatch_ObservationKey
    ON #TechnicalMatch (ObservationKey);

SELECT
    scoped_match.ObservationKey,
    scoped_match.ObservedAtUtc,
    scoped_match.StopPointRef,
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.OperatorRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.MatchStatus,
    scoped_match.MatchedTripId,
    scoped_match.MatchedRouteId,
    scoped_match.MatchedServiceId,
    scoped_match.MatchedStaticStopId,
    scoped_match.ScheduledStopEventKey,
    scoped_match.TripKey,
    scoped_match.RouteKey,
    scoped_match.StopKey,
    scoped_match.ModeKey,
    scoped_match.ServiceKey,
    scoped_match.DateKey,
    scoped_match.ServiceDate,
    scoped_match.StaticParentStationId,
    scoped_match.AnalyticalParentStationId,
    scoped_match.AnalyticalParentStationName,
    scoped_match.IsInAnalyticalTransportScope,
    scoped_match.AnalyticalTransportScopeReason
INTO #ScopedMatch
FROM wrk.vwCologneRealtimeTripMatchScoped AS scoped_match;

CREATE UNIQUE CLUSTERED INDEX UX_ScopedMatch_ObservationKey
    ON #ScopedMatch (ObservationKey);

/* 1. Raw row preservation, scope reconciliation, and MatchStatus reconciliation. */
SELECT
    (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation)
        AS RawObservationCount,
    (SELECT COUNT_BIG(*) FROM #TechnicalMatch)
        AS TechnicalMatchRowCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch)
        AS ScopedMatchRowCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1)
        AS InAnalyticalTransportScopeObservationCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 0)
        AS OutOfAnalyticalTransportScopeObservationCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE MatchStatus = N'StaticCoverageMissing')
        AS RawTechnicalStaticCoverageMissingCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 0
       AND MatchStatus = N'StaticCoverageMissing')
        AS OutOfScopeStaticCoverageMissingCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus = N'StaticCoverageMissing')
        AS InScopeStaticCoverageMissingCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus = N'Unresolved')
        AS InScopeUnresolvedCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus = N'ExactStopMatch')
        AS InScopeExactStopMatchCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus = N'ParentStationFallback')
        AS InScopeParentStationFallbackCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback'))
        AS InScopeUsableMatchCount,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM stg.MddRealtimeStopObservation)
             = (SELECT COUNT_BIG(*) FROM #ScopedMatch)
         AND (SELECT COUNT_BIG(*) FROM #ScopedMatch)
             = (SELECT COUNT_BIG(*) FROM #ScopedMatch
                WHERE IsInAnalyticalTransportScope = 1)
               +
               (SELECT COUNT_BIG(*) FROM #ScopedMatch
                WHERE IsInAnalyticalTransportScope = 0)
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS RawAndScopeRowCountStatus,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #ScopedMatch)
             =
             (
                 SELECT COUNT_BIG(*) FROM #ScopedMatch
                 WHERE MatchStatus IN
                       (
                           N'ExactStopMatch',
                           N'ParentStationFallback',
                           N'StaticCoverageMissing',
                           N'Unresolved'
                       )
             )
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS RawMatchStatusReconciliationStatus,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #ScopedMatch
              WHERE IsInAnalyticalTransportScope = 1)
             =
             (
                 SELECT COUNT_BIG(*) FROM #ScopedMatch
                 WHERE IsInAnalyticalTransportScope = 1
                   AND MatchStatus IN
                       (
                           N'ExactStopMatch',
                           N'ParentStationFallback',
                           N'StaticCoverageMissing',
                           N'Unresolved'
                       )
             )
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS InScopeMatchStatusReconciliationStatus;

/* 2. Any duplicate ObservationKey is a failure; an empty result is PASS. */
SELECT
    ObservationKey,
    COUNT_BIG(*) AS DuplicateRowCount,
    N'REVIEW' AS ValidationStatus
FROM #ScopedMatch
GROUP BY ObservationKey
HAVING COUNT_BIG(*) <> 1;

/* 3. Match identity and MatchStatus must remain unchanged by the wrapper. */
WITH TechnicalOnly AS
(
    SELECT
        ObservationKey,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId,
        ScheduledStopEventKey,
        TripKey,
        RouteKey,
        StopKey,
        ModeKey,
        ServiceKey,
        DateKey,
        ServiceDate
    FROM #TechnicalMatch
),
ScopedOnly AS
(
    SELECT
        ObservationKey,
        MatchStatus,
        MatchedTripId,
        MatchedRouteId,
        MatchedServiceId,
        MatchedStaticStopId,
        ScheduledStopEventKey,
        TripKey,
        RouteKey,
        StopKey,
        ModeKey,
        ServiceKey,
        DateKey,
        ServiceDate
    FROM #ScopedMatch
)
SELECT
    (SELECT COUNT_BIG(*) FROM #TechnicalMatch
     WHERE MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback'))
        AS TechnicalSuccessfulMatchCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 1
       AND MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback'))
        AS InScopeSuccessfulMatchCount,
    (SELECT COUNT_BIG(*) FROM #ScopedMatch
     WHERE IsInAnalyticalTransportScope = 0
       AND MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback'))
        AS OutOfScopeSuccessfulMatchCount,
    (SELECT COUNT_BIG(*)
     FROM
     (
         SELECT * FROM TechnicalOnly
         EXCEPT
         SELECT * FROM ScopedOnly
     ) AS technical_only)
        AS TechnicalToScopedIdentityDifferenceCount,
    (SELECT COUNT_BIG(*)
     FROM
     (
         SELECT * FROM ScopedOnly
         EXCEPT
         SELECT * FROM TechnicalOnly
     ) AS scoped_only)
        AS ScopedToTechnicalIdentityDifferenceCount,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #ScopedMatch
              WHERE IsInAnalyticalTransportScope = 0
                AND MatchStatus IN (N'ExactStopMatch', N'ParentStationFallback')) = 0
         AND (SELECT COUNT_BIG(*)
              FROM
              (
                  SELECT * FROM TechnicalOnly
                  EXCEPT
                  SELECT * FROM ScopedOnly
              ) AS technical_only) = 0
         AND (SELECT COUNT_BIG(*)
              FROM
              (
                  SELECT * FROM ScopedOnly
                  EXCEPT
                  SELECT * FROM TechnicalOnly
              ) AS scoped_only) = 0
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS SuccessfulMatchIdentityRegressionStatus;

/* 4. Current valid service classes must not be excluded. */
WITH Evidence AS
(
    SELECT
        scoped_match.*,
        UPPER(REPLACE(LTRIM(RTRIM(COALESCE(scoped_match.LineName, N''))), N' ', N''))
            AS NormalizedLineName,
        UPPER(LTRIM(RTRIM(COALESCE(scoped_match.PtMode, N''))))
            AS NormalizedPtMode
    FROM #ScopedMatch AS scoped_match
)
SELECT
    ServiceClass,
    ObservationCount,
    OutOfScopeObservationCount,
    CASE WHEN OutOfScopeObservationCount = 0 THEN N'PASS' ELSE N'REVIEW' END
        AS ValidationStatus
FROM
(
    SELECT
        N'S-Bahn' AS ServiceClass,
        COUNT_BIG(*) AS ObservationCount,
        SUM(CASE WHEN evidence.IsInAnalyticalTransportScope = 0
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
            AS OutOfScopeObservationCount
    FROM Evidence AS evidence
    WHERE evidence.NormalizedPtMode = N'RAIL'
      AND evidence.NormalizedLineName LIKE N'S[0-9]%'
    UNION ALL
    SELECT
        N'Regional Express (RE)',
        COUNT_BIG(*),
        SUM(CASE WHEN evidence.IsInAnalyticalTransportScope = 0
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
    FROM Evidence AS evidence
    WHERE evidence.NormalizedPtMode = N'RAIL'
      AND evidence.NormalizedLineName LIKE N'RE[0-9]%'
    UNION ALL
    SELECT
        N'Regional Bahn (RB)',
        COUNT_BIG(*),
        SUM(CASE WHEN evidence.IsInAnalyticalTransportScope = 0
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
    FROM Evidence AS evidence
    WHERE evidence.NormalizedPtMode = N'RAIL'
      AND evidence.NormalizedLineName LIKE N'RB[0-9]%'
    UNION ALL
    SELECT
        N'Rail Replacement Bus (SEV/BSV labels)',
        COUNT_BIG(*),
        SUM(CASE WHEN evidence.IsInAnalyticalTransportScope = 0
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
    FROM Evidence AS evidence
    WHERE evidence.NormalizedPtMode = N'BUS'
      AND
      (
          evidence.NormalizedLineName LIKE N'SEV%'
          OR evidence.NormalizedLineName LIKE N'BSV%'
      )
    UNION ALL
    SELECT
        N'Defined non-rail modes (BUS/TRAM)',
        COUNT_BIG(*),
        SUM(CASE WHEN evidence.IsInAnalyticalTransportScope = 0
                 THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
    FROM Evidence AS evidence
    WHERE evidence.NormalizedPtMode IN (N'BUS', N'TRAM')
) AS service_classes
ORDER BY ServiceClass;

/* 5. All current rail service classes and scope outcomes. */
SELECT
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.OperatorRef,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT scoped_match.StopPointRef)
        AS DistinctStopPointRefCount,
    COUNT_BIG(DISTINCT scoped_match.AnalyticalParentStationId)
        AS DistinctParentStationCount,
    SUM(CASE WHEN scoped_match.IsInAnalyticalTransportScope = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeObservationCount,
    SUM(CASE WHEN scoped_match.IsInAnalyticalTransportScope = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfScopeObservationCount,
    MIN(scoped_match.AnalyticalTransportScopeReason)
        AS ScopeClassificationReason
FROM #ScopedMatch AS scoped_match
WHERE UPPER(LTRIM(RTRIM(scoped_match.PtMode))) = N'RAIL'
GROUP BY
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.OperatorRef
ORDER BY ObservationCount DESC, scoped_match.LineName, scoped_match.LineRef;

/* 6. Out-of-scope observations remain fully traceable. */
SELECT
    scoped_match.ObservationKey,
    scoped_match.ObservedAtUtc,
    scoped_match.StopPointRef,
    scoped_match.AnalyticalParentStationId AS ParentStationId,
    scoped_match.AnalyticalParentStationName AS ParentStationName,
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.OperatorRef,
    scoped_match.MatchStatus,
    scoped_match.IsInAnalyticalTransportScope,
    scoped_match.AnalyticalTransportScopeReason
FROM #ScopedMatch AS scoped_match
WHERE scoped_match.IsInAnalyticalTransportScope = 0
ORDER BY scoped_match.ObservationKey;

/* 7. Final excluded population by parent station, including ICE and IC. */
SELECT
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.OperatorRef,
    scoped_match.AnalyticalParentStationId AS ParentStationId,
    scoped_match.AnalyticalParentStationName AS ParentStationName,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT scoped_match.AnalyticalParentStationId)
        AS DistinctParentStationCount,
    COUNT_BIG(DISTINCT scoped_match.StopPointRef)
        AS DistinctStopPointRefCount
FROM #ScopedMatch AS scoped_match
WHERE scoped_match.IsInAnalyticalTransportScope = 0
GROUP BY
    scoped_match.LineName,
    scoped_match.LineRef,
    scoped_match.PtMode,
    scoped_match.RailSubmode,
    scoped_match.OperatorRef,
    scoped_match.AnalyticalParentStationId,
    scoped_match.AnalyticalParentStationName
ORDER BY scoped_match.LineName, ObservationCount DESC, ParentStationId;

SELECT
    CASE
        WHEN scoped_match.LineName LIKE N'ICE%' THEN N'ICE'
        WHEN scoped_match.LineName = N'IC' THEN N'IC'
    END AS LongDistanceServiceClass,
    scoped_match.AnalyticalParentStationId AS ParentStationId,
    scoped_match.AnalyticalParentStationName AS ParentStationName,
    COUNT_BIG(*) AS ObservationCount,
    COUNT_BIG(DISTINCT scoped_match.StopPointRef)
        AS DistinctStopPointRefCount
FROM #ScopedMatch AS scoped_match
WHERE scoped_match.IsInAnalyticalTransportScope = 0
  AND
  (
      scoped_match.LineName LIKE N'ICE%'
      OR scoped_match.LineName = N'IC'
  )
GROUP BY
    CASE
        WHEN scoped_match.LineName LIKE N'ICE%' THEN N'ICE'
        WHEN scoped_match.LineName = N'IC' THEN N'IC'
    END,
    scoped_match.AnalyticalParentStationId,
    scoped_match.AnalyticalParentStationName
ORDER BY LongDistanceServiceClass, ObservationCount DESC, ParentStationId;

/* 8. The scope flag cannot create a usable timing input. */
WITH TimingEvidence AS
(
    SELECT
        scoped_match.IsInAnalyticalTransportScope,
        scoped_match.MatchStatus,
        scoped_match.MatchedTripId,
        CASE
            WHEN EXISTS
                 (
                     SELECT 1
                     FROM dw.FactOperationalStopOutcome AS outcome
                     WHERE outcome.FirstObservationKey = scoped_match.ObservationKey
                        OR outcome.LastObservationKey = scoped_match.ObservationKey
                 )
                THEN 1
            ELSE 0
        END AS IsReferencedByOperationalOutcome
    FROM #ScopedMatch AS scoped_match
)
SELECT
    SUM(CASE WHEN timing.IsInAnalyticalTransportScope = 0
                  AND timing.MatchStatus IN
                      (N'ExactStopMatch', N'ParentStationFallback')
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfScopeRowsWithUsableMatch,
    SUM(CASE WHEN timing.IsInAnalyticalTransportScope = 0
                  AND timing.MatchedTripId IS NOT NULL
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfScopeRowsWithMatchedTripId,
    SUM(CASE WHEN timing.IsInAnalyticalTransportScope = 0
                  AND timing.IsReferencedByOperationalOutcome = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS OutOfScopeRowsReferencedByOperationalOutcome,
    CASE
        WHEN SUM(CASE WHEN timing.IsInAnalyticalTransportScope = 0
                           AND timing.MatchStatus IN
                               (N'ExactStopMatch', N'ParentStationFallback')
                      THEN 1 ELSE 0 END) = 0
         AND SUM(CASE WHEN timing.IsInAnalyticalTransportScope = 0
                           AND timing.MatchedTripId IS NOT NULL
                      THEN 1 ELSE 0 END) = 0
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS TimingInputIsolationStatus
FROM TimingEvidence AS timing;

/* 9. RouteLongName fallback examples remain in scope and identity-stable. */
WITH FallbackExamples AS
(
    SELECT
        scoped_match.*,
        UPPER(REPLACE(LTRIM(RTRIM(COALESCE(scoped_match.LineName, N''))), N' ', N''))
            AS NormalizedLineName
    FROM #ScopedMatch AS scoped_match
    WHERE UPPER(REPLACE(LTRIM(RTRIM(COALESCE(scoped_match.LineName, N''))), N' ', N''))
          IN (N'RE1(RRX)', N'RE5(RRX)', N'RE6(RRX)')
),
FallbackEvidence AS
(
    SELECT
        examples.*,
        CASE
            WHEN NOT EXISTS
                 (
                     SELECT 1
                     FROM wrk.vwCologneServingRoute AS serving_route
                     WHERE REPLACE(serving_route.RouteShortName, N' ', N'')
                               = examples.NormalizedLineName
                 )
             AND EXISTS
                 (
                     SELECT 1
                     FROM dw.DimRoute AS route
                     INNER JOIN wrk.vwCologneServingRoute AS serving_route
                         ON serving_route.RouteId COLLATE DATABASE_DEFAULT
                          = route.RouteId COLLATE DATABASE_DEFAULT
                     WHERE route.RouteId COLLATE DATABASE_DEFAULT
                               = examples.MatchedRouteId COLLATE DATABASE_DEFAULT
                       AND REPLACE(LTRIM(RTRIM(route.RouteLongName)), N' ', N'')
                               = examples.NormalizedLineName
                 )
                THEN 1
            ELSE 0
        END AS HasRouteLongNameFallbackEvidence
    FROM FallbackExamples AS examples
)
SELECT
    fallback.LineName,
    COUNT_BIG(*) AS ObservationCount,
    SUM(CASE WHEN fallback.MatchStatus IN
                  (N'ExactStopMatch', N'ParentStationFallback')
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS SuccessfulMatchCount,
    SUM(CASE WHEN fallback.IsInAnalyticalTransportScope = 1
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS InScopeObservationCount,
    SUM(CASE WHEN fallback.HasRouteLongNameFallbackEvidence = 1
                  AND fallback.MatchStatus IN
                      (N'ExactStopMatch', N'ParentStationFallback')
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS RouteLongNameFallbackSuccessfulMatchCount,
    SUM(CASE WHEN fallback.IsInAnalyticalTransportScope = 0
             THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
        AS ScopeConflictCount,
    CASE
        WHEN SUM(CASE WHEN fallback.IsInAnalyticalTransportScope = 0
                      THEN 1 ELSE 0 END) = 0
         AND SUM(CASE WHEN fallback.HasRouteLongNameFallbackEvidence = 1
                           AND fallback.MatchStatus IN
                               (N'ExactStopMatch', N'ParentStationFallback')
                      THEN 1 ELSE 0 END) > 0
            THEN N'PASS'
        ELSE N'REVIEW'
    END AS RouteLongNameScopeStatus
FROM FallbackEvidence AS fallback
GROUP BY fallback.LineName
ORDER BY fallback.LineName;
