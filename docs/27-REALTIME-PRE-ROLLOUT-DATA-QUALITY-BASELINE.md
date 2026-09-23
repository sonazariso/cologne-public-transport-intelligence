# Realtime Pre-Rollout Data-Quality Baseline

Status: RECORDED

This document records the required read-only seven-station baseline gate before
any future activation of the approved 50-station/tiered sampling panel. It is
not a new architecture feature and it does not activate or change the panel.

> Historical snapshot boundary: the execution record and baseline sections
> through `Scope confirmation` below are the preserved v129 pre-refresh
> evidence. The current aligned seven-station record is appended under
> `Fresh aligned seven-station baseline`; do not read the historical values as
> the post-refresh state.

## Execution record

| Field | Value |
| --- | --- |
| Repository baseline | v129 |
| Branch | `feature/powerbi-m02-station-performance` |
| Database | `CologneTransitIntelligence` development database |
| SQL Server | `172.16.192.128` (`DataAnalyst-VM`) |
| Analysis script | `sql/05-analytics/07-analyze-realtime-pre-rollout-data-quality.sql` |
| Analysis script SHA-256 | `ccdcf17ef3ebe36e26c53309f8383d094a6acd283bca11807888d106366e774c` |
| Execution started | `2026-09-22T22:22:21.8330950+02:00` |
| Execution completed | `2026-09-22T22:22:33.5182800+02:00` |
| Execution duration | `00:00:11.6851850` |
| Execution status | PASS — one batch, 22 result sets, no SQL errors |

The analysis was read-only. It used session-scoped temporary tables and did not
refresh `dw.FactOperationalStopOutcome` or change permanent database objects.

## Static match baseline

Rates below are fractions in the SQL result set; the percentage rendering is
included for readability.

| Metric | Current value |
| --- | ---: |
| ObservationDateTimeMin (UTC) | `2026-09-05 08:27:28` |
| ObservationDateTimeMax (UTC) | `2026-09-22 20:18:49` |
| TotalRealtimeObservations | 7,507 |
| ExactStopMatchCount | 5,610 |
| ExactStopMatchRate | 0.74730251 (74.730251%) |
| ParentStationFallbackCount | 115 |
| ParentStationFallbackRate | 0.01531903 (1.531903%) |
| StaticCoverageMissingCount | 1,701 |
| StaticCoverageMissingRate | 0.22658851 (22.658851%) |
| UnresolvedCount | 81 |
| UnresolvedRate | 0.01078992 (1.078992%) |
| UsableStaticMatchCount | 5,725 |
| UsableStaticMatchRate | 0.76262155 (76.262155%) |
| StaticCoverageMissingDistinctLineNameCount | 28 |
| StaticCoverageMissingAffectedStopPointCount | 26 |
| MatchStatusReconciliationStatus | PASS |

The complete distinct affected-line classification contains 28 rows and its
reconciliation with `StaticCoverageMissingDistinctLineNameCount` is PASS.
The current data contains no NULL or blank affected realtime `LineName` group;
the diagnostic is nevertheless implemented as a distinct derived set so one
NULL group will be counted if it occurs in a future run.

## StaticCoverageMissing root causes

The current matching rule was preserved:
`REPLACE(realtime LineName, spaces) = REPLACE(static RouteShortName, spaces)`.

| DiagnosticCategory | Distinct realtime lines | StaticCoverageMissing observations | Distinct affected StopPointRef | Category reconciliation |
| --- | ---: | ---: | ---: | --- |
| PresentInGtfsButOutsideCologneServingScope | 1 | 80 | 3 | PASS |
| NotFoundInLoadedGtfsUnderCurrentRule | 27 | 1,621 | 23 | PASS |
| UnexpectedCurrentRuleInconsistency | 0 | 0 | 0 | PASS |

`UnexpectedCurrentRuleInconsistency` is zero. The category stop-point counts
are direct `COUNT(DISTINCT StopPointRef)` values from the underlying affected
observations; they are not sums of per-line stop counts. The per-line counts
remain available in the complete classification below.

The one outside-scope line is `885` (80 observations, 3 stop points). It is
present in loaded GTFS as route `de:vrs:885:111`, operated by RVK, but is not in
the current Cologne serving scope. The current rule was not changed.

### Complete distinct affected-line classification

| LineName | DiagnosticCategory | StaticCoverageMissing observations | Affected StopPointRef | In loaded GTFS under current rule | In Cologne serving scope under current rule |
| --- | --- | ---: | ---: | --- | --- |
| 188 | NotFoundInLoadedGtfsUnderCurrentRule | 26 | 1 | NO | NO |
| 885 | PresentInGtfsButOutsideCologneServingScope | 80 | 3 | YES | NO |
| 885E | NotFoundInLoadedGtfsUnderCurrentRule | 5 | 1 | NO | NO |
| BSV 11008 8211008 | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| FlixTrain | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| IC | NotFoundInLoadedGtfsUnderCurrentRule | 147 | 5 | NO | NO |
| ICE | NotFoundInLoadedGtfsUnderCurrentRule | 660 | 8 | NO | NO |
| ICE 126 ICE International | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| ICE 29 InterCityExpress | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| NJ 403 NightJet | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| RE 1 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 423 | 6 | NO | NO |
| RE 5 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 157 | 3 | NO | NO |
| RE 6 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 140 | 2 | NO | NO |
| RE1 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| RE5 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| RE6 (RRX) | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| SEV | NotFoundInLoadedGtfsUnderCurrentRule | 2 | 1 | NO | NO |
| SEV RB38 | NotFoundInLoadedGtfsUnderCurrentRule | 2 | 1 | NO | NO |
| SEV RE 1 | NotFoundInLoadedGtfsUnderCurrentRule | 2 | 1 | NO | NO |
| SEV RE6X | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| SEV RE8 | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| SEV S 11 | NotFoundInLoadedGtfsUnderCurrentRule | 11 | 3 | NO | NO |
| SEV S 19 | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |
| SEV S 6 | NotFoundInLoadedGtfsUnderCurrentRule | 20 | 1 | NO | NO |
| SEV S 6X | NotFoundInLoadedGtfsUnderCurrentRule | 4 | 1 | NO | NO |
| SEV S11 | NotFoundInLoadedGtfsUnderCurrentRule | 4 | 3 | NO | NO |
| SEV S6 | NotFoundInLoadedGtfsUnderCurrentRule | 6 | 1 | NO | NO |
| THA 9471 Thalys | NotFoundInLoadedGtfsUnderCurrentRule | 1 | 1 | NO | NO |

### Top affected lines by observation count

| Rank | LineName | Observations | Affected StopPointRef | DiagnosticCategory |
| ---: | --- | ---: | ---: | --- |
| 1 | ICE | 660 | 8 | NotFoundInLoadedGtfsUnderCurrentRule |
| 2 | RE 1 (RRX) | 423 | 6 | NotFoundInLoadedGtfsUnderCurrentRule |
| 3 | RE 5 (RRX) | 157 | 3 | NotFoundInLoadedGtfsUnderCurrentRule |
| 4 | IC | 147 | 5 | NotFoundInLoadedGtfsUnderCurrentRule |
| 5 | RE 6 (RRX) | 140 | 2 | NotFoundInLoadedGtfsUnderCurrentRule |
| 6 | 885 | 80 | 3 | PresentInGtfsButOutsideCologneServingScope |
| 7 | 188 | 26 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 8 | SEV S 6 | 20 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 9 | SEV S 11 | 11 | 3 | NotFoundInLoadedGtfsUnderCurrentRule |
| 10 | SEV S6 | 6 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 11 | 885E | 5 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 12 | SEV S 6X | 4 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 13 | SEV S11 | 4 | 3 | NotFoundInLoadedGtfsUnderCurrentRule |
| 14 | SEV | 2 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 15 | SEV RB38 | 2 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 16 | SEV RE 1 | 2 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 17 | BSV 11008 8211008 | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 18 | FlixTrain | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 19 | ICE 126 ICE International | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 20 | ICE 29 InterCityExpress | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 21 | NJ 403 NightJet | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 22 | RE1 (RRX) | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 23 | RE5 (RRX) | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 24 | RE6 (RRX) | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |
| 25 | SEV RE6X | 1 | 1 | NotFoundInLoadedGtfsUnderCurrentRule |

Supporting current-rule label diagnostics show no NULL/blank line evidence.
`RE1 (RRX)`, `RE5 (RRX)`, and `RE6 (RRX)` have trimmed realtime labels that
equal a loaded GTFS `RouteLongName`, but none equals the loaded GTFS
`RouteShortName` under the current rule. They therefore remain in
`NotFoundInLoadedGtfsUnderCurrentRule`; no new production match status or
diagnostic category was introduced.

## StaticCoverageMissing lineage conclusion

`StaticCoverageMissingDirectlyContributesToTimingUnavailable`: **NO**.

The current evidence is consistent across code, constraint, and data:

| MatchStatus | Source observations | Fact-linked observations |
| --- | ---: | ---: |
| ExactStopMatch | 5,610 | 3,075 |
| ParentStationFallback | 115 | 80 |
| StaticCoverageMissing | 1,701 | 0 |
| Unresolved | 81 | 0 |

The fact load filter and fact constraint both permit only
`ExactStopMatch` and `ParentStationFallback`. `StaticCoverageMissing` is not
harmless: its 1,701 observations reduce the usable realtime population before
operational-outcome and management timing analysis, even though the status does
not directly enter the `TimingUnavailableTrips` measure.

## Current M01 timing baseline

| Metric | Current value |
| --- | ---: |
| ServiceDateMin | `2026-09-05` |
| ServiceDateMax | `2026-09-16` |
| ComparableScheduledTrips | 2,822 |
| TripsWithUsableRealtimeTiming | 2,440 |
| TimingUnavailableTrips | 382 |
| TimingUnavailableRate | 0.13536498 (13.536498%) |
| M01 timing reconciliation | PASS — 2,822 = 2,440 + 382 |

The current M01 root-cause and observation-density source sets remained
fact-bounded. The live source observations not represented in the current fact
were excluded from the current M01 `Timing Unavailable` root-cause analysis.

### Timing Unavailable root causes

| Category | TripCount | Percentage of TimingUnavailableTrips | Reconciliation |
| --- | ---: | ---: | --- |
| NoEstimatedArrivalEverObserved | 380 | 0.99476440 (99.476440%) | PASS |
| EstimateExistedEarlierButFinalTimingIsNull | 2 | 0.00523560 (0.523560%) | PASS |
| OtherOrInconsistent | 0 | 0.00000000 (0.000000%) | PASS |

The three categories sum to 382 `TimingUnavailableTrips`. Because
`OtherOrInconsistent` is zero, there are no affected dated trips requiring a
C-category evidence appendix. The two final-null cases remain represented by
the separate latest-null diagnostic below; warehouse semantics were not
changed.

### Latest-observation-null evidence

The pattern is an earlier usable non-NULL `EstimatedArrivalUtc` followed by a
later/final usable observation with `EstimatedArrivalUtc IS NULL`, evaluated at
`ServiceDate + ScheduledStopEventKey` and reported at `ServiceDate + TripKey`.

| Metric | Current value |
| --- | ---: |
| AffectedOperationalStopOutcomeCount | 9 |
| AffectedDistinctDatedTripCount | 9 |
| PatternExists | YES |

| ServiceDate | TripKey | Station | Route |
| --- | ---: | --- | --- |
| 2026-09-07 | 59219 | Köln Rodenkirchen Bf | 16 |
| 2026-09-08 | 7574 | Köln Worringen S-Bahn | S11 |
| 2026-09-08 | 7760 | Köln Bf Mülheim | S11 |
| 2026-09-08 | 7768 | Köln Bf Mülheim | S11 |
| 2026-09-08 | 12895 | Köln Bf Mülheim | S6 |
| 2026-09-08 | 58819 | Köln Rodenkirchen Bf | 16 |
| 2026-09-16 | 7500 | Köln Bf Mülheim | S11 |
| 2026-09-16 | 7537 | Köln Bf Mülheim | S11 |
| 2026-09-16 | 12987 | Köln Bf Mülheim | S6 |

### Observation density

| TimingUnavailable trips by usable matched-observation count | Count |
| --- | ---: |
| Zero matched observations | 0 |
| One matched observation | 367 |
| Multiple matched observations | 15 |
| Total TimingUnavailableTrips | 382 |
| Observation-density reconciliation | PASS |

The existing date/mode/route and station breakdown result sets were also
returned by the execution. The seven-station station-grain result was:

| Station | Comparable trips | Usable timing trips | Timing unavailable trips | Timing unavailable rate |
| --- | ---: | ---: | ---: | ---: |
| Köln Bf Ehrenfeld | 294 | 265 | 29 | 0.09863946 |
| Köln Bf Mülheim | 579 | 524 | 55 | 0.09499136 |
| Köln Hbf | 483 | 444 | 39 | 0.08074534 |
| Köln Heumarkt | 641 | 520 | 121 | 0.18876755 |
| Köln Porz Markt | 332 | 280 | 52 | 0.15662651 |
| Köln Rodenkirchen Bf | 355 | 283 | 72 | 0.20281690 |
| Köln Worringen S-Bahn | 296 | 252 | 44 | 0.14864865 |

Station rows are non-additive because one dated trip can appear at more than
one monitored station.

## Corrected source/fact freshness diagnostic

The source/fact comparison uses the deterministic `(ObservedAtUtc,
ObservationKey)` ordering. The fact-bounded source set used for current M01
root-cause classification was not changed.

| Metric | Current value |
| --- | ---: |
| CurrentRealtimeObservationMaxUtc | `2026-09-22 20:18:49` |
| CurrentUsableObservationMaxUtc | `2026-09-22 20:18:49` |
| OperationalFactLastObservedMaxUtc | `2026-09-16 18:38:42` |
| LiveUsableObservationsBeyondExistingFactBoundaryCount | 4 |
| LiveUsableObservationsWithoutFactBoundaryCount | 2,459 |
| LiveUsableObservationsNotRepresentedInFactCount | 2,463 |

The corrected reconciliation is `2,463 = 4 + 2,459`. The 2,459 usable source
observations without a current fact boundary are now counted explicitly;
neither those observations nor the four beyond-boundary observations entered
the current M01 root-cause classification.

## Reconciliation summary

| Check | Result |
| --- | --- |
| M01 timing reconciliation | PASS |
| MatchStatus reconciliation | PASS |
| StaticCoverageMissing distinct-line classification reconciliation | PASS |
| StaticCoverageMissing category reconciliation | PASS |
| Timing Unavailable root-cause reconciliation | PASS |
| Observation-density reconciliation | PASS |

## Scope confirmation

This baseline records evidence; it does not fix the discovered business
semantics. No production matching behavior, `StaticCoverageMissing` semantics,
`Timing Unavailable` semantics, `FactOperationalStopOutcome` behavior,
warehouse data, Collector code, sampling configuration, 50-station panel
activation, Power BI, or tiered-sampling architecture decision was changed.
No `Actual Physical Delay` work was implemented or renamed.

## Fresh aligned seven-station baseline

This section records the refreshed seven-station baseline requested for the
v130 repository baseline. It is separate from, and does not overwrite, the
historical v129 pre-refresh snapshot above.

The preserved historical values remain `2,822 / 2,440 / 382` for comparable,
usable, and Timing Unavailable trips, with root causes `380 / 2 / 0`.

### Fresh execution record

| Field | Value |
| --- | --- |
| Repository baseline | v130 |
| Branch | `feature/powerbi-m02-station-performance` |
| Database | `CologneTransitIntelligence` development database |
| Analysis script | `sql/05-analytics/07-analyze-realtime-pre-rollout-data-quality.sql` |
| Analysis script SHA-256 | `d10f21e5039778ec295ac2073237cde760a21d73b111c3d6c4a3b65cc83d16a2` |
| Active panel gate | PASS — exactly 7 configured/enabled target rows; the approved 50-station list is not activated |
| Controlled refresh | `dw.uspRefreshFactOperationalStopOutcome`, executed exactly once |
| Refresh started | `2026-09-23 07:01:50 UTC` |
| Refresh completed | `2026-09-23 07:01:57 UTC` |
| Refresh status | Succeeded |
| Analysis execution | PASS — one batch, 24 result sets, no SQL errors |

The active-panel gate returned `ConfiguredTargetCount = 7`,
`EnabledSamplingTargetCount = 7`, `EnabledDistinctStopPointRefCount = 7`,
`EnabledTargetRowsInApproved50StationList = 7`, `ConfiguredSlotCount = 10`,
and `EnabledSlotCount = 10`. No sampling configuration or panel activation was
changed.

### Controlled refresh result

| Metric | Value |
| --- | ---: |
| SourceObservationCount | 7,547 |
| UsableObservationCount | 5,756 |
| SourceOperationalOutcomeCount | 5,386 |
| OperationalOutcomeCount | 5,386 |
| RepeatedObservationsConsolidated | 370 |
| InsertedOutcomeCount | 2,406 |
| UpdatedOutcomeCount | 2 |
| UnchangedOutcomeCount | 2,978 |

The refresh procedure body was not changed. The validation script contains two
embedded refresh calls, so only its read-only prefix through line 399 was run
after the controlled refresh; no additional refresh was executed.

### Read-only warehouse validation

| Check | Result |
| --- | --- |
| `dw.FactOperationalStopOutcome` exists | PASS |
| Operational outcome rows | 5,386 |
| Duplicate surrogate keys | 0 |
| Source observations represented | 5,756 |
| Repeated observations consolidated | 370 |
| Duplicate operational-grain groups/rows | 0 / 0 |
| 12 structural and referential checks | PASS — 0 failed rows in each check |
| First/latest observation lineage violations | 0 / 0 — PASS |
| Consolidated outcome ordering violations | 0 — PASS |
| Situation/platform evidence checks | PASS — 0 failed rows in each check |

The match-status validation remained aligned with the warehouse contract:

| MatchStatus | Source observations | Fact outcomes | Treatment |
| --- | ---: | ---: | --- |
| ExactStopMatch | 5,646 | 5,283 | Eligible for operational outcomes |
| ParentStationFallback | 118 | 103 | Eligible for operational outcomes |
| StaticCoverageMissing | 1,712 | 0 | Data quality/coverage only |
| Unresolved | 81 | 0 | Data quality/coverage only |

### Refreshed static-match baseline

Rates are fractions in the SQL result set; percentage rendering is included
for readability. This is observation grain and must not be compared directly
with trip-grain `TimingUnavailableRate`.

| Metric | Fresh value |
| --- | ---: |
| ObservationDateTimeMin (UTC) | `2026-09-05 08:27:28` |
| ObservationDateTimeMax (UTC) | `2026-09-23 07:08:45` |
| TotalRealtimeObservations | 7,557 |
| ExactStopMatchCount | 5,646 |
| ExactStopMatchRate | 0.74712187 (74.712187%) |
| ParentStationFallbackCount | 118 |
| ParentStationFallbackRate | 0.01561466 (1.561466%) |
| StaticCoverageMissingCount | 1,712 |
| StaticCoverageMissingRate | 0.22654492 (22.654492%) |
| UnresolvedCount | 81 |
| UnresolvedRate | 0.01071853 (1.071853%) |
| UsableStaticMatchCount | 5,764 |
| UsableStaticMatchRate | 0.76273653 (76.273653%) |
| StaticCoverageMissingDistinctLineNameCount | 28 |
| StaticCoverageMissingAffectedStopPointCount | 26 |
| MatchStatusReconciliationStatus | PASS |

The static diagnostic now reports four explicit categories. The category
counts reconcile to 1,712 observations and 28 distinct affected line names;
the direct affected-stop-point reconciliation is also PASS.

| Diagnostic category | Distinct lines | StaticCoverageMissing observations | Distinct affected stop points |
| --- | ---: | ---: | ---: |
| PresentInGtfsButOutsideCologneServingScope | 1 | 80 | 3 |
| StaticRouteExistsButCurrentRuleMissesIt | 6 | 732 | 8 |
| NoDeterministicEvidenceInLoadedGtfs | 21 | 900 | 20 |
| UnexpectedCurrentRuleInconsistency | 0 | 0 | 0 |

The existing production rule remains unchanged:
`REPLACE(realtime LineName, spaces) = REPLACE(static RouteShortName, spaces)`.
The refined diagnostic alternatives are read-only evidence only: exact
`LineRef = RouteId`; trimmed `LineName = RouteLongName`; spaces-removed
`LineName = RouteLongName`; and trimmed `LineName = RouteShortName`.

#### Deterministic evidence for every current-rule miss with a static route

The six lines in `StaticRouteExistsButCurrentRuleMissesIt` are fully emitted
by the SQL result set. None has exact `LineRef = RouteId` or trimmed
`RouteShortName` evidence. The loaded GTFS long-name evidence is:

| Realtime line name | Observations / stops | Deterministic evidence |
| --- | ---: | --- |
| `RE 1 (RRX)` | 428 / 6 | Space-normalized `LineName = RouteLongName` matches `de:nrw:re1:`, `de:nrw:re1:2`, `de:nrw:re1:4`; static `RouteShortName` is NULL |
| `RE1 (RRX)` | 1 / 1 | Trimmed and space-normalized `LineName = RouteLongName` match the same three `RE1 (RRX)` routes; exact ID and trimmed short-name evidence are NONE |
| `RE 5 (RRX)` | 160 / 3 | Space-normalized `LineName = RouteLongName` matches `de:nrw:re5:`, `de:nrw:re5:3`, `de:nrw:re5:4`; static `RouteShortName` is NULL |
| `RE5 (RRX)` | 1 / 1 | Trimmed and space-normalized `LineName = RouteLongName` match the same three `RE5 (RRX)` routes; exact ID and trimmed short-name evidence are NONE |
| `RE 6 (RRX)` | 141 / 2 | Space-normalized `LineName = RouteLongName` matches `de:nrw:re6:`, `de:nrw:re6:2`, `de:nrw:re6:4`; static `RouteShortName` is NULL |
| `RE6 (RRX)` | 1 / 1 | Trimmed and space-normalized `LineName = RouteLongName` match the same three `RE6 (RRX)` routes; exact ID and trimmed short-name evidence are NONE |

#### Explicit high-volume line evidence

The requested high-volume lines were checked with all five deterministic
comparisons and the current production-rule result:

| Line | Observations / stops | Current rule match | Exact ID | Trimmed long name | Space-normalized long name | Trimmed short name | Diagnostic conclusion |
| --- | ---: | ---: | --- | --- | --- | --- | --- |
| `ICE` | 661 / 8 | 0 | NONE | NONE | NONE | NONE | NoDeterministicEvidenceInLoadedGtfs |
| `RE 1 (RRX)` | 428 / 6 | 0 | NONE | NONE | route long-name evidence | NONE | StaticRouteExistsButCurrentRuleMissesIt |
| `RE 5 (RRX)` | 160 / 3 | 0 | NONE | NONE | route long-name evidence | NONE | StaticRouteExistsButCurrentRuleMissesIt |
| `IC` | 148 / 5 | 0 | NONE | NONE | NONE | NONE | NoDeterministicEvidenceInLoadedGtfs |
| `RE 6 (RRX)` | 141 / 2 | 0 | NONE | NONE | route long-name evidence | NONE | StaticRouteExistsButCurrentRuleMissesIt |

The exact `RealtimeLineRef` values returned for those five rows are:

- `ICE`: `ddb:98X01:Q:H, ddb:98X10::R, ddb:98X10:P:R, ddb:98X14::R, ddb:98X14:P:R, ddb:98X19::H, ddb:98X33:Q:H, ddb:98X39::R, ddb:98X41::R, ddb:98X42::H, ddb:98X42:P:R, ddb:98X42:W:H, ddb:98X42:W:R, ddb:98X43::H, ddb:98X43::R, ddb:98X43:P:H, ddb:98X45:Q:R, ddb:98X47::R, ddb:98X47:A:H, ddb:98X47:A:R, ddb:98X49::R, ddb:98X55:Q:R, ddb:98X78::H, ddb:98X78::R, ddb:98X79::H, ddb:98X79::R, ddb:98X91::H, ddb:98X91::R`.
- `RE 1 (RRX)`: `ddb:90E01::H, ddb:90E01::R, ddb:90E01:G:H, ddb:90E01:G:R`.
- `RE 5 (RRX)`: `ddb:90E05::H, ddb:90E05::R`.
- `IC`: `ddb:96X35::H, ddb:96X55::H, ddb:96X55:E:R, ddb:96X55:P:H, ddb:96X55:P:R`.
- `RE 6 (RRX)`: `ddb:90E06::H, ddb:90E06::R`.

No production `MatchStatus`, matching, warehouse, Collector, or sampling logic
was changed to produce these classifications.

### Refreshed M01 timing baseline

| Metric | Fresh value |
| --- | ---: |
| ServiceDateMin | `2026-09-05` |
| ServiceDateMax | `2026-09-23` |
| ComparableScheduledTrips | 5,127 |
| TripsWithUsableRealtimeTiming | 4,239 |
| TimingUnavailableTrips | 888 |
| TimingUnavailableRate | 0.17320070 (17.320070%) |
| M01 timing reconciliation | PASS — 5,127 = 4,239 + 888 |

The refreshed `TimingUnavailable` root-cause distribution is:

| Category | Trip count | Share of TimingUnavailableTrips | Reconciliation |
| --- | ---: | ---: | --- |
| NoEstimatedArrivalEverObserved | 886 | 0.99774775 (99.774775%) | PASS |
| EstimateExistedEarlierButFinalTimingIsNull | 2 | 0.00225225 (0.225225%) | PASS |
| OtherOrInconsistent | 0 | 0.00000000 (0.000000%) | PASS |

The latest-observation-null pattern remains present at 9 operational stop
outcomes across 9 dated trips. Observation density is:

| TimingUnavailable trips by usable matched-observation count | Count |
| --- | ---: |
| Zero matched observations | 0 |
| One matched observation | 852 |
| Multiple matched observations | 36 |
| Total TimingUnavailableTrips | 888 |
| Observation-density reconciliation | PASS |

The refreshed seven-station station-grain result is:

| Station | Comparable trips | Usable timing trips | Timing unavailable trips | Timing unavailable rate |
| --- | ---: | ---: | ---: | ---: |
| Köln Bf Ehrenfeld | 556 | 481 | 75 | 0.13489209 |
| Köln Bf Mülheim | 1,072 | 934 | 138 | 0.12873134 |
| Köln Hbf | 704 | 631 | 73 | 0.10369318 |
| Köln Heumarkt | 1,222 | 949 | 273 | 0.22340426 |
| Köln Porz Markt | 633 | 508 | 125 | 0.19747235 |
| Köln Rodenkirchen Bf | 642 | 488 | 154 | 0.23987539 |
| Köln Worringen S-Bahn | 557 | 450 | 107 | 0.19210054 |

Station rows remain distinct dated-trip grain and are not additive to the
overall trip total.

### Post-refresh source/fact freshness

The analysis ran after the refresh while the live source continued collecting.
The source/fact boundary is deterministic on `(ObservedAtUtc, ObservationKey)`:

| Metric | Immediately before refresh | Post-refresh analysis |
| --- | ---: | ---: |
| CurrentRealtimeObservationMaxUtc | `2026-09-23 06:58:45` | `2026-09-23 07:08:45` |
| CurrentUsableObservationMaxUtc | `2026-09-23 06:58:45` | `2026-09-23 07:08:45` |
| OperationalFactLastObservedMaxUtc | `2026-09-16 18:38:42` | `2026-09-23 06:58:45` |
| LiveUsableObservationsBeyondExistingFactBoundaryCount | 4 | 0 |
| LiveUsableObservationsWithoutFactBoundaryCount | 2,490 | 8 |
| LiveUsableObservationsNotRepresentedInFactCount | 2,494 | 8 |

The post-refresh values are also retained as the standalone current result:

| Metric | Fresh value |
| --- | ---: |
| CurrentRealtimeObservationMaxUtc | `2026-09-23 07:08:45` |
| CurrentUsableObservationMaxUtc | `2026-09-23 07:08:45` |
| OperationalFactLastObservedMaxUtc | `2026-09-23 06:58:45` |
| LiveUsableObservationsBeyondExistingFactBoundaryCount | 0 |
| LiveUsableObservationsWithoutFactBoundaryCount | 8 |
| LiveUsableObservationsNotRepresentedInFactCount | 8 |

The eight not-yet-represented usable observations are new source rows for
dated stop-event grains without an existing fact boundary; they arrived after
the single refresh and were excluded from fact-bounded root-cause and density
aggregates. This is a small live tail, not a material refresh backlog.

### Historical versus fresh comparison rule

The historical snapshot and fresh run have different source/fact boundaries
and service-date horizons, so absolute counts are not a causal before/after
measure. The aligned values are retained for context:

| Metric | Historical v129 pre-refresh | Fresh aligned v130 |
| --- | ---: | ---: |
| StaticCoverageMissingRate | 0.22658851 (22.658851%) | 0.22654492 (22.654492%) |
| TimingUnavailableRate | 0.13536498 (13.536498%) | 0.17320070 (17.320070%) |
| Timing Unavailable root causes | 380 / 2 / 0 | 886 / 2 / 0 |
| Observation density (zero / one / multiple) | 0 / 367 / 15 | 0 / 852 / 36 |

For the future 7→50 station comparison, compare `StaticCoverageMissingRate`,
`UnresolvedRate`, `UsableStaticMatchRate`, `TimingUnavailableRate`, and the
root-cause and observation-density distributions alongside absolute counts.
No arbitrary acceptable-percentage threshold is defined by this diagnostic.
