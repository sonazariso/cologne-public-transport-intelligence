# Timing Unavailable Root-Cause Investigation

Status: diagnostic only. No production fix was made.

This investigation implements the instructions in `prompts/05-OptimSql/o4-12.md`. It distinguishes stored-data evidence from hypotheses and keeps estimated arrival/delay separate from confirmed physical arrival.

## Execution contract and frozen scope

The repository did not contain a local `v136` ref. The working baseline used for this run is the exact current commit `042c0b7` (`fix/sql: resolve residual in-scope static coverage gaps`) on branch `analysis/timing-unavailable-root-cause`.

The reusable read-only batch is [09-analyze-timing-unavailable-root-cause.sql](../sql/05-analytics/09-analyze-timing-unavailable-root-cause.sql). It uses session-scoped temporary tables only and does not refresh the warehouse.

### Active-panel gate

The gate passed before warehouse work:

| Metric | Result |
|---|---:|
| ConfiguredTargetCount | 7 |
| EnabledSamplingTargetCount | 7 |
| EnabledDistinctStopPointRefCount | 7 |
| ConfiguredSlotCount | 10 |
| EnabledSlotCount | 10 |

The approved 50-station panel remains planning-only. No target or slot was activated.

### Matching validation

The existing matching semantics were preserved and checked read-only. `RouteShortName` remains primary; `RouteLongNameFallback` is used only when short-name coverage is absent; `SEVReplacementRoute` is deterministic and limited to curated SEV replacement routes; analytical scope remains separate from matching.

The post-freeze current regression check returned:

| Check | Result |
|---|---:|
| Raw staging observations | 7,987 |
| Scoped-match rows | 7,987 |
| In-scope usable matches | 6,893 |
| In-scope `StaticCoverageMissing` | 134 |
| In-scope `Unresolved` | 110 |
| Out-of-scope usable matches | 0 |
| Matched SEV replacement/equivalent rows | 39 |
| Matching validation status | PASS |

The 134/110 residual rows are expected diagnostic outcomes of the current matching/scope classification; this task did not change them. The full status distribution was ExactStopMatch 6,745, ParentStationFallback 148, StaticCoverageMissing 984, and Unresolved 110.

### One controlled refresh

`dw.uspRefreshFactOperationalStopOutcome` was executed exactly once, immediately after the gate and matching checks. Captured procedure metrics:

| Metric | Result |
|---|---:|
| Refresh status | Succeeded |
| Refresh started UTC | 2026-09-23 14:09:02 |
| Refresh completed UTC | 2026-09-23 14:11:32 |
| SourceObservationCount | 7,957 |
| UsableObservationCount | 6,872 |
| SourceOperationalOutcomeCount | 6,262 |
| OperationalOutcomeCount | 6,262 |
| RepeatedObservationsConsolidated | 610 |
| InsertedOutcomeCount | 876 |
| UpdatedOutcomeCount | 0 |
| UnchangedOutcomeCount | 5,386 |

No backlog or material refresh failure was observed.

### Frozen management population

Immediately after the refresh, a read-only freeze/reconciliation query ran at 2026-09-23 14:14:42 UTC. It materialized the current `analytics.vwManagementComparableTrip` population at `ServiceDate + TripKey`. The final verified reusable analysis batch ran at 2026-09-23 14:49:14 UTC and re-materialized the same fact-backed population using `FrozenMaxObservationKey = 17,802`; it covered service dates 2026-09-05 through 2026-09-23 and reconciled successfully.

| Frozen population | Count |
|---|---:|
| Comparable dated trips | 5,857 |
| Usable timing trips | 4,907 |
| Timing-unavailable trips | 950 |
| Timing-unavailable rate | 16.219907% |
| Frozen operational outcomes | 6,262 |
| Fact observation count | 6,872 |
| Trip reconciliation | PASS |
| Fact reconciliation | PASS |

Rows with `ObservationKey > 17,802` were treated as a live tail and excluded from all frozen diagnostics. Forty such rows were visible in the final verified analysis; the current matching check was also run against the live append-only source and its row count can continue to grow without changing the frozen population.

Historical evidence is preserved separately and is not relabeled as current:

| Snapshot | Comparable | Usable timing | Timing unavailable | Rate | Existing root evidence |
|---|---:|---:|---:|---:|---|
| Historical M01 | 2,822 | 2,440 | 382 | 13.536490% | 380 / 2 / 0 |
| Historical aligned seven-station | 5,127 | 4,239 | 888 | 17.320070% | 886 / 2 / 0 |
| Current frozen | 5,857 | 4,907 | 950 | 16.219907% | 906 / 40 / 4 |

## Stored timing lineage

The current collector/parser stores the following timing path:

| Stage | Evidence and semantics |
|---|---|
| TRIAS source | `serviceArrival.timetabledTime` and `serviceArrival.estimatedTime` are parsed in `collector/MddRealtimeCollector.psm1:586-605`. |
| Collector observation time | `serviceDelivery.responseTimestamp` becomes `ObservedAtUtc` (`collector/MddRealtimeCollector.psm1:570-571`). |
| Staging | The parser persists `TimetabledArrivalUtc`, `EstimatedArrivalUtc`, `PlannedBay`, and `EstimatedBay`; `CreatedAtUtc` is storage time. |
| Working match | `ArrivalDelayMinutes` is derived from scheduled versus estimated arrival. Matching identifies the dated scheduled event; it does not fill a missing estimate. |
| Fact | The refresh consolidates repeated observations and stores first/latest observed estimate, delay, observation count, bays, platform evidence, and situation associations. |
| Analytics reliability | `FinalObservedEstimatedDelayMinutes` is an observed estimate-derived delay, explicitly not confirmed physical delay (`sql/05-analytics/03-create-realtime-analytics-views.sql:471-485`). |
| Management | `HasValidRealtimeObservation = 1` only when the selected outcome has a non-NULL final observed estimated delay (`sql/05-analytics/05-create-m01-management-views.sql:58-73`). A NULL estimate remains unavailable, not on-time. |

No departure time, actual/recorded arrival time, or deterministic cancellation/status field is persisted by the current collector path.

### Persisted field inventory for affected observations

The affected-source inventory covers 1,007 matched staging observations belonging to the frozen timing-unavailable trips. All requested persisted fields were audited:

| Field | Non-NULL | NULL | Distinct |
|---|---:|---:|---:|
| ObservationKey | 1,007 | 0 | 1,007 |
| ObservedAtUtc | 1,007 | 0 | 546 |
| ResultId | 1,007 | 0 | 1,007 |
| StopPointRef | 1,007 | 0 | 50 |
| StopName | 1,007 | 0 | 7 |
| LineName | 1,007 | 0 | 67 |
| LineRef | 1,007 | 0 | 92 |
| JourneyRef | 1,007 | 0 | 931 |
| DirectionRef | 1,007 | 0 | 2 |
| OperatorRef | 1,007 | 0 | 5 |
| PtMode | 1,007 | 0 | 3 |
| RailSubmode | 225 | 782 | 2 |
| TimetabledArrivalUtc | 1,007 | 0 | 794 |
| EstimatedArrivalUtc | 6 | 1,001 | 6 |
| PlannedBay | 233 | 774 | 19 |
| EstimatedBay | 2 | 1,005 | 2 |
| CreatedAtUtc | 1,007 | 0 | 546 |

The parser’s persisted source shapes are also visible in `collector/MddRealtimeCollector.psm1:789-867`, including the situation and link payloads.

The linked situation inventory covered 43 distinct situation rows:

| Situation field | Non-NULL | NULL | Distinct |
|---|---:|---:|---:|
| SituationObservationKey | 43 | 0 | 43 |
| ObservedAtUtc | 43 | 0 | 28 |
| ParticipantRef | 43 | 0 | 1 |
| SituationNumber | 43 | 0 | 27 |
| Summary | 43 | 0 | 28 |
| Description | 43 | 0 | 28 |
| Detail | 43 | 0 | 31 |
| ValidFromUtc | 43 | 0 | 27 |
| ValidToUtc | 43 | 0 | 27 |
| CreatedAtUtc | 43 | 0 | 28 |

The affected link inventory covered 44 rows:

| Link field | Non-NULL | NULL | Distinct |
|---|---:|---:|---:|
| ObservationKey | 44 | 0 | 32 |
| SituationObservationKey | 44 | 0 | 43 |
| RelationScope | 44 | 0 | 1 |
| CreatedAtUtc | 44 | 0 | 28 |

### Raw TRIAS inspection and parser inventory

Raw inspection was **not performed**. No safe `MDD_API_KEY` was available in the execution environment, so no TRIAS request was sent, no response was persisted, and no collector/configuration change was made.

| Source path / field | Current parser persists it | Observed with missing estimate | Confidence |
|---|---|---|---|
| `serviceArrival.timetabledTime` | YES | YES | Established from current parser and stored rows |
| `serviceArrival.estimatedTime` | YES | YES | Established from current parser; NULL remains unavailable |
| `serviceDeparture.*` | NO | Not tested | Raw source unavailable; no current persisted field |
| Actual/recorded arrival fields | NO | Not tested | Raw source unavailable; no current persisted field |
| Cancellation/status fields | NO | Not tested | Raw source unavailable; no current deterministic field |

Because raw source inspection was unavailable, the collector/parser-loss answer is **INCONCLUSIVE**: stored evidence proves both service-arrival fields are mapped, but cannot prove whether an unpersisted TRIAS timing field existed in the unavailable cases.

The alternative-persisted-timing check found **0** usable alternatives. All 1,007 affected observations had `ObservedAtUtc`, `CreatedAtUtc`, and `TimetabledArrivalUtc`, but those are respectively observation time, storage time, and scheduled time—not an arrival estimate.

## Timing lead-time analysis

The analysis uses the exact definition:

`ArrivalLeadMinutes = DATEDIFF_BIG(SECOND, ObservedAtUtc, TimetabledArrivalUtc) / 60.0`.

Positive values mean the observation occurred before scheduled arrival; negative values mean it occurred after scheduled arrival. Estimated arrival is never called actual arrival or physical delay.

The frozen population contained 6,872 matched observations with usable observation/schedule timestamps. Per-dated-trip first/last/closest lead, matched-observation count, and estimate count are emitted row-by-row by the reusable SQL.

| Timing status | Dated trips | Avg matched obs | Min–max obs | Avg first lead (min) | Avg last lead (min) | Avg closest absolute lead (min) |
|---|---:|---:|---:|---:|---:|---:|
| Usable timing | 4,907 | 1.195231 | 1–13 | -2.517115 | -4.038336 | 5.883811 |
| Timing unavailable | 950 | 1.060000 | 1–6 | 2.333229 | 1.671895 | 4.679632 |

Observation-level lead bins:

| Timing status | After scheduled | 0–5 before | 5–10 before | 10–20 before | 20–30 before | 30–60 before | >60 before |
|---|---:|---:|---:|---:|---:|---:|---:|
| Usable timing | 3,744 | 1,441 | 436 | 197 | 36 | 11 | 0 |
| Timing unavailable | 275 | 463 | 190 | 61 | 13 | 5 | 0 |

Unavailable trips had 906 single-observation cases and 44 multiple-observation cases. Usable trips had 4,341 single-observation and 566 multiple-observation cases. Only four unavailable dated trips had at least one non-NULL estimate; 946 had no estimate in any matched observation.

The equality test found 5,830 matched observations with an estimate, of which 1,064 exactly equaled the timetable (`18.250428%`). This is a diagnostic equality rate only; NULL is not treated as on-time.

## Situation evidence

Among the 950 unavailable dated trips, 27 had situation evidence, 923 had none, and the evidence comprised 44 linked observation rows, 43 distinct situation observations, and 44 link rows.

Representative stored text included:

- `ZTP-PROD-138783`: Dormagen region not passable because of a defective signal box; delays and partial cancellations were described.
- `ZTP-PROD-137914`: S6/S11/S12/S19 disruption around Köln; construction-related irregularities and delays/partial cancellations were described.
- `ZTP-PROD-138453`: RB48 restrictions attributed to short-term staff absence.

These are source situation descriptions, not proof that a specific dated trip was cancelled. No cancellation category was inferred from text alone.

## Platform evidence

For the 1,001 no-estimate observations:

| Evidence | Count |
|---|---:|
| With estimated bay | 1 |
| With planned bay | 229 |
| With planned/estimated bay mismatch | 1 |

At dated-trip grain, 759 of 950 unavailable trips had neither realtime bay nor platform-change evidence; one had an estimated bay and one had platform-change evidence. These flags overlap and are secondary evidence only.

## Latest-null pattern

The explicit latest-null pattern is: an earlier non-NULL `EstimatedArrivalUtc` followed by the final/latest matched observation with `EstimatedArrivalUtc IS NULL` for the same dated scheduled stop event.

It affected 4 operational outcomes and 4 distinct dated trips, or **4/950 = 0.4211%** of frozen timing-unavailable trips:

| ServiceDate | TripKey | Route | Station | Scheduled | First observed | Last observed | Earlier estimate | First delay | Final estimate/delay |
|---|---:|---|---|---|---|---|---|---:|---|
| 2026-09-07 | 59219 | 16 | Köln Rodenkirchen Bf | 22:42 | 20:28:41 | 20:28:41 | 20:42 | 0.00 | NULL / NULL |
| 2026-09-08 | 58819 | 16 | Köln Rodenkirchen Bf | 11:55 | 09:48:47 | 09:48:47 | 09:55 | 0.00 | NULL / NULL |
| 2026-09-17 | 5644 | RE6 (RRX) | Köln Hbf | 10:52 | 09:43:38 | 10:33:47 | 11:00 | 128.00 | NULL / NULL |
| 2026-09-22 | 5661 | RE6 (RRX) | Köln Hbf | 12:52 | 10:58:54 | 12:38:45 | 12:36 | 83.00 | NULL / NULL |

The existing latest-observation semantic was not changed. It is a **PARTIAL** contributor at this snapshot, with an exact affected count and rate above; it is not the dominant root cause.

## Dimension results

Rates below are unavailable trips divided by comparable dated trips. Station rows are non-additive: the same dated trip can occur at more than one monitored station.

### Mode

| Mode | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| Rail Replacement Bus (SEV) | 38 | 30 | 8 | 21.0526% |
| Regional / Other Bus | 231 | 167 | 64 | 27.7056% |
| Regional Bahn (RB) | 402 | 346 | 56 | 13.9303% |
| Regional Express (RE) | 666 | 628 | 38 | 5.7057% |
| S-Bahn | 841 | 752 | 89 | 10.5826% |
| Stadtbahn / Tram | 1,608 | 1,247 | 361 | 22.4502% |
| Urban Bus (KVB) | 2,071 | 1,737 | 334 | 16.1275% |

### Parent station

| Parent station | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| Köln Heumarkt | 1,278 | 1,001 | 277 | 21.6745% |
| Köln Rodenkirchen Bf | 682 | 518 | 164 | 24.0469% |
| Köln Bf Mülheim | 1,177 | 1,044 | 133 | 11.2999% |
| Köln Porz Markt | 662 | 537 | 125 | 18.8822% |
| Köln Worringen S-Bahn | 551 | 454 | 97 | 17.6044% |
| Köln Hbf | 900 | 813 | 87 | 9.6667% |
| Köln Bf Ehrenfeld | 607 | 540 | 67 | 11.0379% |

### Reliable source dimensions

| OperatorRef | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| vrs: | 3,910 | 3,151 | 759 | 19.4118% |
| ddb:8003 | 1,229 | 1,076 | 153 | 12.4491% |
| ddb:NX | 635 | 605 | 30 | 4.7244% |
| ddb: | 62 | 56 | 6 | 9.6774% |
| ddb:TR | 21 | 19 | 2 | 9.5238% |

| PtMode | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| BUS | 2,340 | 1,934 | 406 | 17.3504% |
| TRAM | 1,602 | 1,243 | 359 | 22.4095% |
| RAIL | 1,909 | 1,726 | 183 | 9.5861% |
| MultiplePtModes | 6 | 4 | 2 | 33.3333% |

| RailSubmode | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| Unknown | 3,948 | 3,181 | 767 | 19.4276% |
| LOCAL | 1,068 | 974 | 94 | 8.8015% |
| SUBURBAN_RAILWAY | 841 | 752 | 89 | 10.5826% |

The reusable SQL emits all 50 exact route rows. The largest unavailable route counts were route 7 (86/386, 22.2798%), route 16 (68/233, 29.1845%), route 132 (64/272, 23.5294%), route 120 (57/240, 23.7500%), route 1 (52/272, 19.1176%), route 18 (41/153, 26.7974%), S11 (40/360, 11.1111%), route 131 (38/157, 24.2038%), route 260 (38/112, 33.9286%), route 5 (34/121, 28.0992%), S6 (33/222, 14.8649%), route 13 (28/177, 15.8192%), and route 154 (28/57, 49.1228%). Low-volume extremes include RB38 at 28/28 unavailable and SB25 at 12/23; these are not causal findings.

## Scheduled-stop position

Position was derived from static `StopSequence` minimum/maximum for each scheduled trip. No origin/destination inference was made.

| Position | Comparable | Usable | Unavailable | Rate |
|---|---:|---:|---:|---:|
| SingleStopPattern | 1 | 1 | 0 | 0.0000% |
| FirstScheduledStop | 448 | 389 | 59 | 13.1696% |
| IntermediateScheduledStop | 4,317 | 3,594 | 723 | 16.7477% |
| LastScheduledStop | 1,400 | 1,216 | 184 | 13.1429% |

Intermediate stops carry most of the volume and unavailable count; this is an association, not evidence of operational causality.

## Sampling cadence hypothesis

The active seven-target panel has `NumberOfResults = 5` for every target. With ten five-minute slots, targets with two slots have an implied 25-minute cadence and targets with one slot have an implied 50-minute cadence. No sampling frequency was changed.

| Target | StopPointRef | Slots | Cadence | Comparable | Usable | Unavailable | Rate | Unavailable single / multiple |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Köln Heumarkt | `de:05315:11110` | 2 | 25 min | 1,293 | 1,013 | 280 | 21.6551% | 275 / 5 |
| Köln Hbf | `de:05315:11201` | 2 | 25 min | 1,017 | 927 | 90 | 8.8496% | 63 / 27 |
| Köln Rodenkirchen Bf | `de:05315:12711` | 1 | 50 min | 682 | 518 | 164 | 24.0469% | 162 / 2 |
| Köln Bf Ehrenfeld | `de:05315:14201` | 1 | 50 min | 680 | 604 | 76 | 11.1765% | 66 / 10 |
| Köln Worringen S-Bahn | `de:05315:16601` | 1 | 50 min | 597 | 495 | 102 | 17.0854% | 92 / 10 |
| Köln Porz Markt | `de:05315:17311` | 1 | 50 min | 671 | 546 | 125 | 18.6289% | 120 / 5 |
| Köln Bf Mülheim | `de:05315:19201` | 2 | 25 min | 1,322 | 1,185 | 137 | 10.3631% | 128 / 9 |

The strongest stored signal is observation exposure: 906/950 unavailable trips had one matched observation versus 4,341/4,907 usable trips. Cadence is therefore a plausible contributing factor, but the target groups differ in station, mode, route, and operator mix. The evidence supports **PARTIALLY**, not a causal `YES`.

Collector audit context at analysis time showed successful/failed runs respectively: Heumarkt 286/6, Hbf 289/7, Rodenkirchen 140/4, Ehrenfeld 142/4, Worringen 145/3, Porz 145/4, and Mülheim 283/10. No `Started` runs remained in the audit result.

## Mutually exclusive primary root causes

Every frozen timing-unavailable dated trip received exactly one primary category; the distribution reconciles to 950:

| Primary category | Dated trips | Share |
|---|---:|---:|
| ObservedOnlyOnce_NoArrivalEstimate | 906 | 95.3684% |
| RepeatedlyObserved_NoArrivalEstimate | 40 | 4.2105% |
| EstimatePreviouslyPresent_FinalObservationNull | 4 | 0.4211% |
| **Total** | **950** | **100.0000%** |

The secondary evidence totals were: source never provided an estimate for 946 trips; only one matched observation for 906; multiple observations for 44; latest-null pattern for 4; situation evidence for 27. Secondary flags are intentionally not treated as mutually exclusive causes.

## Conclusions and unknowns

1. The dominant observed condition is missing `EstimatedArrivalUtc` at the source-observation grain: 946/950 frozen unavailable dated trips never had a non-NULL estimate in matched observations. This is the primary root-cause evidence.
2. Limited observation exposure is a meaningful contributing factor: 906/950 unavailable trips were observed once. Sampling cadence receives **PARTIALLY** because the pattern is compatible with the 25/50-minute schedule, but station/service mix prevents causal attribution.
3. Latest-null warehouse semantics contribute only **PARTIALLY** at this snapshot: 4 operational outcomes / 4 dated trips / 0.4211%. The latest semantic is unchanged.
4. Collector/parser timing loss is **INCONCLUSIVE**. The parser clearly maps scheduled and estimated service-arrival fields, but raw TRIAS inspection was safely skipped because credentials were unavailable.
5. Situation text and platform fields provide sparse contextual evidence. They do not prove cancellation, physical arrival, or causality.
6. No alternative persisted realtime timing field can replace `EstimatedArrivalUtc`.
7. Estimated delay remains an observed estimate-derived measure, never confirmed actual or physical delay.

No collector, staging, working-layer, warehouse, production analytics view, Power BI, sampling, tiered-scheduling, or actual-physical-delay logic was changed. The only intended source diff is this report and the reusable read-only SQL analysis.
