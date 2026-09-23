# Realtime Pre-Rollout Data-Quality Baseline

Status: RECORDED

This document records the required read-only seven-station baseline gate before
any future activation of the approved 50-station/tiered sampling panel. It is
not a new architecture feature and it does not activate or change the panel.

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
