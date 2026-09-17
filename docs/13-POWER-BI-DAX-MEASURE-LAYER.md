# Power BI DAX Measure Layer

**Phase:** Chat 05 — DAX Measure Layer  
**Status:** COMPLETE / PASS  
**Completed:** 2026-09-15

## 1. Objective

Build an explicit, interview-defensible DAX measure layer on top of the validated Chat 04 semantic model, while preserving the SQL-defined business semantics and avoiding duplicated business logic.

The measure layer was built in a dedicated disconnected Power BI table named `_Measures`. The table contains only a hidden `_Placeholder` field/row and has no relationships.

## 2. Organization

The PBIX measure table is organized into seven Display Folders:

1. `01 Static Schedule`
2. `02 Network Baseline`
3. `03 Realtime Reliability`
4. `04 Evidence`
5. `05 Consolidation`
6. `06 Data Quality`
7. `07 Collector Health`

Source-controlled DAX definitions are stored in:

```text
powerbi/measures/StaticBaselineMeasures.dax
powerbi/measures/RealtimeReliabilityMeasures.dax
powerbi/measures/README.md
```

The completed layer contains **68 explicit measures** across the seven folders.

## 3. Static Schedule Measures

The static schedule measures use the connected `DailySchedule` fact and dimensions so that normal report filters propagate through the validated single-direction semantic model.

Core measures include:

- `Scheduled Trips`
- `Active Dates in Context`
- `Routes in Context`
- `Agencies in Context`
- `Average Scheduled Trips per Active Day`
- weekday/weekend scheduled trips and weekend share
- `Mode Share of Scheduled Trips`

Validation examples showed correct `Mode -> Route -> DailySchedule` filter propagation. For example, the report returned different trip and route totals for S-Bahn, Regional Express, and Regional Bahn while keeping the same 182 active dates where appropriate.

The identity below was explicitly validated under mode filters:

```text
Weekday Scheduled Trips + Weekend Scheduled Trips = Scheduled Trips
```

`Mode Share of Scheduled Trips` uses `REMOVEFILTERS(Mode)` in its denominator so the selected mode is compared with the complete mode total while other applicable filters remain active.

## 4. Network Baseline Measures

The one-row `NetworkKPI` table remains intentionally disconnected. Baseline measures therefore represent the whole validated static network baseline and do not change when a connected Mode slicer is used.

Validated baseline values:

| Measure | Value |
|---|---:|
| Baseline Agencies | 15 |
| Baseline Modes | 7 |
| Baseline Routes | 153 |
| Baseline Parent Stations | 866 |
| Baseline Stop Positions | 2,290 |
| Baseline Used Stop Positions | 2,287 |
| Baseline Active Service Dates | 182 |
| Baseline Scheduled Trip Patterns | 90,331 |
| Baseline Scheduled Trip Occurrences | 1,878,944 |
| Baseline Scheduled Stop-Event Patterns | 1,551,343 |

The stop-position dimension counts also validated to 2,287 used and 3 unused positions, totaling 2,290.

With the current single-direction model, a Mode filter does not flow backward from `Route`/facts into the independent `StopPosition` dimension. This is intentional; bidirectional filtering must not be added merely to force those counts to change by Mode.

## 5. Realtime Reliability Measures

The connected `RT_ReliabilityOutcome` table is the primary DAX source for slicer-responsive reliability measures.

The disconnected `RT_ReliabilityByDimension` helper view was used only as a SQL-side cross-check for the overall result.

Validated overall values:

| Measure | Value |
|---|---:|
| Observed Matched Services | 1,643 |
| Delay Observations | 1,448 |
| Average Observed Estimated Delay | 8.49 min |
| Median Observed Estimated Delay | 3.00 min |
| P95 Observed Estimated Delay | 36.00 min |
| Minimum Observed Estimated Delay | 0.00 min |
| Maximum Observed Estimated Delay | 701.00 min |
| Average Observations per Outcome | 1.13 |

All eight values matched the `DimensionType = Overall` row in `RT_ReliabilityByDimension` for the validated snapshot.

### Terminology guardrail

These are **Observed Estimated Delay** measures. They are not confirmed physical `Actual Delay` / `Actual Arrival` measures.

No On-Time / Minor / Moderate / Severe threshold has been introduced because no approved business threshold exists yet.

## 6. Evidence Measures

Situation and platform evidence are kept separate from delay causality.

Validated snapshot:

| Evidence measure | Value |
|---|---:|
| Situation-Linked Outcomes | 322 |
| Platform Changed Evidence Outcomes | 10 |
| Platform Unchanged Evidence Outcomes | 0 |
| Platform Unknown Evidence Outcomes | 1,633 |

The platform partition validated as:

```text
10 Changed + 0 Unchanged + 1,633 Unknown = 1,643 outcomes
```

Important semantics:

- `Unknown` is **not** `Unchanged`.
- A missing/insufficient EstimatedBay comparison must not be presented as proof that the platform remained unchanged.
- Situation evidence is an association/link and must not be presented as a confirmed cause of delay.

## 7. Operational Consolidation Measures

`RT_ConsolidationQuality` is connected to `ActiveDate` and is used to explain how repeated realtime observations are consolidated into operational stop outcomes.

Validated values:

| Measure | Value |
|---|---:|
| Usable Realtime Observations | 1,857 |
| Operational Outcomes | 1,643 |
| Repeated Observations Consolidated | 214 |
| Consolidation Reduction Share | 11.52% |
| Observations per Operational Outcome | 1.13 |

Validated identity:

```text
1,857 usable observations - 1,643 operational outcomes = 214 repeated observations consolidated
```

Repeated observations are expected sampling of the same scheduled event and are not automatically a data-error classification.

## 8. Data Quality / Coverage Measures

`RT_DataQualityCoverage` remains disconnected because it represents collection-date / coverage analytics rather than the GTFS service-date fact grain.

Validated counts:

| Measure | Value |
|---|---:|
| Realtime Source Observations | 2,673 |
| Matched View Observations | 2,673 |
| Exact Stop Matches | 1,798 |
| Parent Station Fallback Matches | 59 |
| Static Coverage Missing | 787 |
| Unresolved Matches | 29 |
| Usable Matches | 1,857 |

Validated identities:

```text
1,798 + 59 + 787 + 29 = 2,673
1,798 + 59 = 1,857 usable matches
```

Validated rates:

| Measure | Value |
|---|---:|
| Exact Stop Match Rate | 67.27% |
| Parent Station Fallback Rate | 2.21% |
| Static Coverage Missing Rate | 29.44% |
| Unresolved Match Rate | 1.08% |
| Usable Match Rate | 69.47% |

Rates are recomputed from **summed numerators divided by summed denominators**. The report does not average pre-aggregated daily percentages, which would incorrectly weight low- and high-volume collection dates equally.

Additional evidence availability:

| Measure | Value |
|---|---:|
| Observations with Estimated Bay | 58 |
| Estimated Bay Availability Rate | 2.17% |
| Observations with Situation Evidence | 641 |
| Situation Evidence Availability Rate | 23.98% |
| Situation Links | 815 |

Estimated Bay availability means that comparable source evidence exists; it does not itself mean a platform changed.

## 9. Collector Health Measures

`RT_CollectorRunHealth` remains intentionally disconnected from the GTFS service-date model.

Validated imported snapshot:

| Measure | Value |
|---|---:|
| Collector Runs | 376 |
| Successful Collector Runs | 366 |
| Failed Collector Runs | 9 |
| Incomplete Collector Runs | 1 |
| Successful Automatic Runs | 366 |
| Completed Collector Runs | 375 |
| Collector Success Rate | 97.60% |
| Sampling Panel Targets Observed | 7 |
| Average Successful Run Duration | 3.07 sec |

Validated run-status identity:

```text
366 successful + 9 failed + 1 incomplete = 376 runs
```

`Collector Success Rate` deliberately uses completed runs only:

```text
Successful / (Successful + Failed)
```

Incomplete `Started` runs are not included in the denominator because they are not completed outcomes.

## 10. Measure Formatting

Final conventions:

- counts: whole number;
- delay measures: decimal number with two decimals and `(min)` in the measure name;
- run duration / observation-density measures: decimal number with two decimals;
- rates/shares: percentage (normally one decimal in report visuals; additional decimals may be used during validation).

## 11. Model and Business-Semantic Decisions Preserved

Chat 05 did **not** change SQL, Collector, Power Query, or semantic-model relationships.

The following project rules remain mandatory:

- no fabricated or backfilled realtime history;
- seven realtime locations are a sampling panel, not complete Köln network coverage;
- only `ExactStopMatch` and `ParentStationFallback` feed normal reliability outcomes;
- `StaticCoverageMissing` and `Unresolved` stay in Data Quality / Coverage;
- no arbitrary On-Time threshold;
- no cancellation/departure KPI without validated source semantics;
- situation association is not causality;
- platform `Unknown` remains distinct from `Unchanged`;
- estimated delay is not confirmed actual arrival delay.

## 12. PBIX / Source ZIP Note

The PBIX is maintained through the VMware shared repository at:

```text
powerbi/CologneTransitIntelligence.pbix
```

The source archive supplied to this chat did not contain the PBIX, so the generated source ZIP cannot embed the user's local PBIX changes. The checked-in DAX/documentation files in this repository snapshot record the manually completed Chat 05 work and should be kept alongside the PBIX in the real repository.

## 13. Next Phase

**Chat 06 — Design System & Theme**.

Chat 06 should improve visual standards, typography, spacing, theme usage, page canvas, and report consistency. It must not redefine the validated measure semantics merely for visual convenience.

---

## Post-Chat-05 PBIP/TMDL update — 2026-09-15

After Chat 05, Chat 06 migrated the active local Power BI report to PBIP/TMDL/PBIR for source-controlled development through VS Code + Codex. The 68-measure layer was successfully audited from `_Measures.tmdl`, and a metadata-only description edit on `Observed Matched Services` was loaded and round-trip-saved successfully in Power BI Desktop without changing the DAX logic or validated measure semantics.

See `docs/14-POWER-BI-PBIP-CODEX-WORKFLOW.md` for the current authoring procedure. This postscript does not change the Chat 05 validation results recorded above.
