# Timing Unavailable Root-Cause Investigation

Status: diagnostic evidence completion plus prospective source-evidence capture. No timing or KPI semantic fix was made.

This follow-up implements the instructions in `prompts/05-OptimSql/o4-16.md`. It distinguishes stored-data evidence from hypotheses, keeps estimated arrival/delay separate from confirmed physical arrival, and persists only the proven current-call stop-service evidence for future observations.

## Execution contract and frozen scope

The repository baseline for this follow-up is **v139 plus the local RowCount alias fix** on branch `fix/timing-unavailable-stop-service-status-evidence`.

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

| Snapshot | Comparable | Usable timing | Timing unavailable | Rate | Prior root evidence (preserved) |
|---|---:|---:|---:|---:|---|
| Historical M01 | 2,822 | 2,440 | 382 | 13.536490% | 380 / 2 / 0 |
| Historical aligned seven-station | 5,127 | 4,239 | 888 | 17.320070% | 886 / 2 / 0 |
| Current frozen | 5,857 | 4,907 | 950 | 16.219907% | 906 / 40 / 4 |

## Source-level evidence completion

This section completes the source-evidence gap without changing timing or KPI
behavior.

### Historical evidence limitation

The raw TRIAS responses for the historical 382-trip M01 snapshot were not
persisted. The database therefore proves that 380 historical trips had no
usable persisted `EstimatedArrivalUtc`, while 2 had an earlier persisted
estimate followed by a latest persisted NULL and 0 were inconsistent. It does
not retroactively prove whether the 380 historical raw responses contained a
different, unpersisted timing or status field. This is an evidence limitation,
not a database reconciliation failure. The historical raw payloads do not
exist, so those 380 trips cannot be retrospectively subdivided by
`NotServicedStop`. No historical source field is fabricated here.

### Corrected primary root-cause distribution

The reusable SQL now classifies primary causes from directly observed persisted
timing evidence. Observation count is not part of the primary category. The
current frozen population reconciles exactly to 950:

| Primary category | Dated trips | Share | Direct evidence semantics |
|---|---:|---:|---|
| NoPersistedArrivalEstimateObserved | 946 | 99.5789% | At least one matched observation existed, and none had a non-NULL persisted `EstimatedArrivalUtc`. |
| EstimatePreviouslyPresent_FinalObservationNull | 4 | 0.4211% | An earlier persisted estimate existed, but the final persisted observation was NULL. |
| InsufficientEvidence | 0 | 0.0000% | No matched observation existed for the dated trip. |
| OtherProvenCause | 0 | 0.0000% | Reserved for a directly proven cause outside the two timing patterns above. |
| **Total** | **950** | **100.0000%** | **PASS** |

The SQL derives these counts from the frozen tables; it does not hardcode the
946/4 distribution.

### Secondary observation and contextual evidence

Observation exposure remains separate evidence:

| Secondary flag | Dated trips |
|---|---:|
| OnlyObservedOnce | 906 |
| MultipleObservations | 44 |
| NoMatchedObservation | 0 |

The latest-null flag affects 4 dated trips, and situation evidence is present
for 27. These flags can overlap and are not primary causes. In particular,
`OnlyObservedOnce` does not prove that sampling cadence caused the missing
estimate.

### Prospective source-level finding

`StopNotServicedEvidenceObserved` is a separate prospective source finding,
not a replacement for the frozen persisted-data categories:

| Finding | Evidence | Scope |
|---|---|---|
| `StopNotServicedEvidenceObserved` | One of the three current raw missing-arrival events had `thisCall.callAtStop.notServicedStop = true`; the same event also had `noAlightingAtStop = true`. | One bounded raw-probe event only; not merged into the historical 946/4 counts and not a cancellation KPI. |

This branch does not exclude `NotServicedStop` rows from
`ComparableScheduledTrips`, `TimingUnavailableTrips`, On-Time, Delayed, or
Early populations. It adds no cancellation rate, cancelled-trip measure, or
other management KPI; status semantics will be reviewed only after enough
prospective evidence has been collected.

### Prospective raw TRIAS inspection status

The bounded raw probe executed successfully. The evidence report is
[`tmp/timing-unavailable-source-evidence.json`](../tmp/timing-unavailable-source-evidence.json).
It inspected the seven enabled targets with seven logical requests and seven
HTTP attempts. All seven requests succeeded, all seven responses parsed, and
the probe made no persistence or collector-audit write.

| Metric | Result |
|---|---:|
| `RawTriasTimingInspection` | `EXECUTED` |
| Logical requests | 7 |
| HTTP attempts | 7 |
| Successful requests | 7 |
| Failed requests | 0 |
| `ParserSuccessCount` | 7 |
| `ParserFailureCount` | 0 |
| Raw current-stop events | 35 |
| Missing `thisCall.callAtStop.serviceArrival.estimatedTime` events | 3 |
| `ApplicationTablesUnchanged` | `true` |
| `CollectorParserDiscardsRelevantTiming` | `NO` |

The diagnostic-only helper is
[`Inspect-MddTriasTimingEvidence.ps1`](../collector/Inspect-MddTriasTimingEvidence.ps1).
It reads the seven enabled targets and their existing `StopPointRef` and
`NumberOfResults`, caps the run at seven logical requests, uses the existing
safe request/retry helper, inspects raw JSON in memory before parser
projection, and reports sanitized before/after counts for all non-system base
tables. It does not call persistence or collector-run audit functions.

Exact Windows Collector command used when `MDD_API_KEY` is available in the
process or User environment:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Collector\Inspect-MddTriasTimingEvidence.ps1 -ConnectionString "Server=localhost;Database=CologneTransitIntelligence;Integrated Security=True;TrustServerCertificate=True;" -ReportPath C:\Collector\Logs\timing-unavailable-source-evidence-20260924.json
```

### Raw timing/status/departure field inventory

The executed report found the following relevant source fields. The diagnostic
helper now classifies the three current-call serviceability properties as
`StopServiceStatusEvidence`; generic request status remains separate.
The supplied report is retained as the raw-probe evidence artifact; the
classification and parser-target labels below describe the updated helper and
collector contract without changing the raw occurrence counts.

| JsonPath | CurrentParserPersists | Parser target / note | ObservedValueType | NonNullOccurrenceCount | NullOccurrenceCount | ExampleSanitizedValue |
|---|---|---|---|---:|---:|---|
| `$.serviceDelivery.status` | NO | `ServiceOrRequestStatusNamedField`; validation only | Boolean | 7 | 0 | `True` |
| `$.serviceDelivery.responseTimestamp` | YES | `ObservedAtUtc` | String | 7 | 0 | `2026-09-24T08:39:09Z` |
| `...thisCall.callAtStop.serviceArrival.timetabledTime` | YES | `TimetabledArrivalUtc` | String | 35 | 0 | `2026-09-24T06:41:00Z[GMT]` |
| `...thisCall.callAtStop.serviceArrival.estimatedTime` | YES | `EstimatedArrivalUtc` | String | 32 | 0 | `2026-09-24T08:47:48Z[GMT]` |
| `...thisCall.callAtStop.notServicedStop` | YES | `NotServicedStop`; `StopServiceStatusEvidence` | Boolean | 1 | 0 | `True` |
| `...thisCall.callAtStop.noBoardingAtStop` | YES when present | `NoBoardingAtStop`; not observed on a current call in this sample | — | — | — | — |
| `...thisCall.callAtStop.noAlightingAtStop` | YES | `NoAlightingAtStop`; `StopServiceStatusEvidence` | Boolean | 1 | 0 | `True` |
| `...previousCall[*].callAtStop.serviceDeparture.timetabledTime` | NO | `AdditionalDepartureTimingEvidence` only | String | 556 | 0 | `2026-09-24T06:04:00Z[GMT]` |
| `...previousCall[*].callAtStop.serviceDeparture.estimatedTime` | NO | `AdditionalDepartureTimingEvidence` only | String | 544 | 0 | `2026-09-24T06:04:00Z[GMT]` |
| `...onwardCall[*].callAtStop.serviceDeparture.timetabledTime` | NO | `AdditionalDepartureTimingEvidence` only | String | 409 | 0 | `2026-09-24T06:43:00Z[GMT]` |
| `...onwardCall[*].callAtStop.serviceDeparture.estimatedTime` | NO | `AdditionalDepartureTimingEvidence` only | String | 349 | 0 | `2026-09-24T08:49:48Z[GMT]` |
| `*actual*` / `*recorded*` arrival timestamp | NO | No observed field | — | 0 | 0 | — |
| `*delay*` arrival replacement | NO | No observed field | — | 0 | 0 | — |

The same property names also appeared on surrounding calls: the report
observed `notServicedStop` on 7 `previousCall` and 2 `onwardCall` entries,
`noBoardingAtStop` on 8 previous and 2 onward entries, and
`noAlightingAtStop` on 7 previous and 2 onward entries. These remain
`StopServiceStatusEvidence` inventory only; only `thisCall.callAtStop.*` is
projected into the current observation row.

`serviceDelivery.status = true` is retained as
`ServiceOrRequestStatusNamedField`; it is a service/request response status,
not vehicle or trip cancellation evidence. Arbitrary status/cancel-named
properties remain separate from the confirmed current-call serviceability
properties. `NoBoardingAtStop` and `NoAlightingAtStop` are restrictions on
boarding/alighting, not route cancellation. `NotServicedStop` means that the
planned stop is not served; it is source evidence only.

`CollectorParserDiscardsRelevantTiming = NO`: all three missing-estimate
events parsed successfully with `EstimatedArrivalUtc = NULL`, and none
contained an alternative current-call arrival timestamp for the parser to
discard. `serviceDeparture.timetabledTime` and `serviceDeparture.estimatedTime`
remain departure context, never arrival timing.

### Missing-arrival raw-event findings

The probe inspected 35 current stop events: 32 had
`thisCall.callAtStop.serviceArrival.estimatedTime`, and three had that
property absent. Each missing event was parser-matched and produced
`ParserEstimatedArrivalUtc = NULL`. No event exposed actual/recorded arrival
timing, an alternative arrival field, a delay field that could replace arrival,
or a parser-discarded relevant timing field.

| Target | StopPointRef | ResultId | JourneyRef | ArrivalEstimatePresence | ParserEstimatedArrivalUtc | ActualOrRecordedTimingEvidence | PotentialAlternativeArrivalTimingEvidence | StopServiceStatusEvidence |
|---|---|---|---|---|---|---|---|---|
| Köln Rodenkirchen Bf (`de:05315:12711`) | `de:05315:12711:1:11` | `ID-B40CD36A-282C-40F4-9EE7-325832FD0F13` | `vrs:01016::H:673:996` | `ABSENT` | `NULL` | None | None | None on `thisCall`; arrival estimate absent; no alternative current-call arrival timing or service-status explanation observed in this bounded sample. |
| Köln Bf Ehrenfeld (`de:05315:14201`) | `de:05315:14201:7:71` | `ID-1FC8BC1C-4A67-4B80-B696-BA9725785F76` | `ddb:92K12::R:j26:343` | `ABSENT` | `NULL` | None | None | `thisCall.callAtStop.notServicedStop = true`; `thisCall.callAtStop.noAlightingAtStop = true`. |
| Köln Bf Mülheim (`de:05315:19201`) | `de:05315:19201:1:12` | `ID-4A2B6FA6-C169-4740-B964-3F9F3BEB0665` | `vrs:01018::R:673:1426` | `ABSENT` | `NULL` | None | None | None on `thisCall`; arrival estimate absent; no alternative current-call arrival timing or service-status explanation observed in this bounded sample. |

The Ehrenfeld event is the one prospective raw-probe finding named
`StopNotServicedEvidenceObserved`: confirmed stop-not-serviced evidence is
associated with a missing-arrival event. It must not be generalized to all
historical `TimingUnavailableTrips`, and the three missing estimates must not
be described as cancelled services. A `previousCall.noBoardingAtStop` value
also occurred in the Ehrenfeld event's surrounding call history; it is not
current-call evidence and is not persisted into the current observation row.

Departure context was retained as `AdditionalDepartureTimingEvidence`. The
three missing events exposed only non-persisted departure paths in
`previousCall` and/or `onwardCall`; those values do not resolve the missing
current-stop arrival estimate and are not used for `TimingUnavailable`.

### Remaining uncertainty

The current evidence proves one prospective source-level stop-service status
finding, but it does not prove a historical source-level subdivision of the
382-trip snapshot. It does not derive cancellation from free text or generic
status fields, and it does not authorize a KPI change from estimated delay to
actual physical delay. Actual/recorded timing remains deferred to Roadmap Item
12.

## Stored timing lineage

The current collector/parser stores the following timing path:

| Stage | Evidence and semantics |
|---|---|
| TRIAS source | `serviceArrival.timetabledTime`, `serviceArrival.estimatedTime`, and current-call stop-service flags are parsed in `collector/MddRealtimeCollector.psm1:586-608`. |
| Collector observation time | `serviceDelivery.responseTimestamp` becomes `ObservedAtUtc` (`collector/MddRealtimeCollector.psm1:570-571`). |
| Staging | The parser persists `TimetabledArrivalUtc`, `EstimatedArrivalUtc`, `PlannedBay`, `EstimatedBay`, and nullable current-call `NotServicedStop`, `NoBoardingAtStop`, and `NoAlightingAtStop`; `CreatedAtUtc` is storage time. |
| Working match | `ArrivalDelayMinutes` is derived from scheduled versus estimated arrival. Matching identifies the dated scheduled event; it does not fill a missing estimate. |
| Fact | The refresh consolidates repeated observations and stores first/latest observed estimate, delay, observation count, bays, platform evidence, and situation associations. |
| Analytics reliability | `FinalObservedEstimatedDelayMinutes` is an observed estimate-derived delay, explicitly not confirmed physical delay (`sql/05-analytics/03-create-realtime-analytics-views.sql:471-485`). |
| Management | `HasValidRealtimeObservation = 1` only when the selected outcome has a non-NULL final observed estimated delay (`sql/05-analytics/05-create-m01-management-views.sql:58-73`). A NULL estimate remains unavailable, not on-time. |

No departure time, actual/recorded arrival time, or deterministic cancellation
status is persisted by the current collector path. The three optional
current-call service-status booleans are source evidence only.

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

The parser’s persisted source shapes are also visible in `collector/MddRealtimeCollector.psm1:792-870`, including the situation and link payloads.

The three new status columns were added after the frozen source audit. Existing
rows, including the historical and current frozen populations, remain NULL in
those columns; no historical rows were rewritten.

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

### Persisted-path boundary for affected observations

The raw-source status, parser inventory, and missing-arrival evidence are
recorded in [Source-level evidence completion](#source-level-evidence-completion)
above. The persisted data itself contains no departure time, actual/recorded
arrival time, or deterministic cancellation/status field. Newly collected
rows may contain only the three nullable current-call service-status fields;
they do not contain previous-call or onward-call status values.

The alternative-persisted-timing check found **0** usable alternatives. All
1,007 affected observations had `ObservedAtUtc`, `CreatedAtUtc`, and
`TimetabledArrivalUtc`, but those are respectively observation time, storage
time, and scheduled time—not an arrival estimate.

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

The reusable SQL now assigns primary categories from persisted timing evidence;
observation count is retained only as secondary evidence. Every frozen
timing-unavailable dated trip received exactly one primary category; the
distribution reconciles to 950:

| Primary category | Dated trips | Share |
|---|---:|---:|
| NoPersistedArrivalEstimateObserved | 946 | 99.5789% |
| EstimatePreviouslyPresent_FinalObservationNull | 4 | 0.4211% |
| InsufficientEvidence | 0 | 0.0000% |
| OtherProvenCause | 0 | 0.0000% |
| **Total** | **950** | **100.0000%** |

The secondary evidence totals were: no non-NULL persisted arrival estimate
was observed for 946 trips; only one matched observation for 906; multiple
observations for 44; no matched observation for 0; latest-null pattern for 4;
and situation evidence for 27. These flags are intentionally not treated as
mutually exclusive causes.

## Conclusions and unknowns

1. The dominant proven condition is missing `EstimatedArrivalUtc` in the persisted arrival-estimate path: 946/950 frozen unavailable dated trips had matched observations but no non-NULL persisted estimate. This is not a retroactive claim about every raw TRIAS response.
2. Limited observation exposure is a meaningful contributing factor: 906/950 unavailable trips were observed once. Sampling cadence receives **PARTIALLY** because the pattern is compatible with the 25/50-minute schedule, but station/service mix prevents causal attribution.
3. Latest-null warehouse semantics contribute only **PARTIALLY** at this snapshot: 4 operational outcomes / 4 dated trips / 0.4211%. The latest semantic is unchanged.
4. `CollectorParserDiscardsRelevantTiming` is **NO**. The executed raw probe found no alternative current-call arrival timestamp in the three missing-arrival events, and the parser produced NULL estimates for all three.
5. One prospective missing-arrival event carried confirmed `NotServicedStop` evidence. It is not generalized to historical trips, and it does not prove cancellation, physical arrival, or causality for other events.
6. No alternative persisted realtime timing field can replace `EstimatedArrivalUtc`.
7. Estimated delay remains an observed estimate-derived measure, never confirmed actual or physical delay.

Only the optional current-call source-evidence projection and its diagnostic inventory were changed. Working-layer matching, warehouse timing semantics, analytics KPIs, Power BI, sampling configuration, tiered-scheduling, and actual-physical-delay logic were not changed. The source diff is this report, the collector/parser and staging persistence additions, and the diagnostic raw inspection helper.

## Stop-service status persistence acceptance

The final documentation-only acceptance was validated at **2026-09-24
10:26:48 UTC** using read-only evidence from the development database. The
historical analysis above was not recomputed or rewritten.

### Physical staging and persistence-contract validation

The live physical-column check found the three optional columns on
`stg.MddRealtimeStopObservation` as follows:

| Column | SQL type | Nullable |
|---|---|---|
| `NotServicedStop` | `BIT` | Yes |
| `NoBoardingAtStop` | `BIT` | Yes |
| `NoAlightingAtStop` | `BIT` | Yes |

The live check of `stg.MddRealtimeStopObservationInputType` found the same
three `BIT NULL` columns in the same relative order expected by
`New-MddRealtimeSnapshotDataTables`: `NotServicedStop`, `NoBoardingAtStop`,
then `NoAlightingAtStop`. The collector creates those DataTable columns as
nullable-capable PowerShell `[bool]` values and sends absent values as
`DBNull.Value`.

The live definition of `stg.uspPersistMddRealtimeSnapshot` was also checked.
Each field is carried from `@StopObservations` through `StopRows` into both
the `INSERT` column list and the corresponding `SELECT` projection for
`stg.MddRealtimeStopObservation`.

The nullable mapping contract is therefore:

| TRIAS property | DataTable/TVP value | Persisted SQL value |
|---|---|---|
| Property absent | `DBNull.Value` | `NULL` |
| `false` | Boolean false | `0` |
| `true` | Boolean true | `1` |

The earlier bounded raw probe also supplies the known positive parser case at
Köln Bf Ehrenfeld: for returned stop `de:05315:14201:7:71`,
`ResultId = ID-1FC8BC1C-4A67-4B80-B696-BA9725785F76`, and
`JourneyRef = ddb:92K12::R:j26:343`, the current-call evidence contained
`notServicedStop = true` and `noAlightingAtStop = true` while the current
arrival estimate was absent. This remains source evidence, not a cancellation
KPI or a requirement that every later snapshot contain a true flag.

### Accepted live manual Collector run

The newest matching manual run for `StopPointRef = de:05315:11110` was:

| Field | Value |
|---|---|
| `CollectorRunId` | `11472` |
| `SamplingMode` | `Manual` |
| `StopPointRef` | `de:05315:11110` |
| `StartedAtUtc` | `2026-09-24 10:12:48` |
| `CompletedAtUtc` | `2026-09-24 10:12:51` |
| `Status` | `Succeeded` |
| `HttpStatus` | `200` |
| `HttpAttempts` | `1` |
| `ObservedAtUtc` | `2026-09-24 10:12:45` |
| `StopEventsReturned` | `5` |
| `StopsInserted` | `5` |
| `StopsAlreadyPresent` | `0` |
| `ErrorCategory` | `NULL` |
| `ErrorMessage` | `NULL` |

### Persisted real snapshot

For the exact `ObservedAtUtc = 2026-09-24 10:12:45`, the staging query
returned five rows. The row count reconciles exactly with
`StopEventsReturned = 5` and `StopsInserted = 5`; `StopsAlreadyPresent = 0`.

| `ObservationKey` | `ObservedAtUtc` | `ResultId` | `StopPointRef` | `JourneyRef` |
|---:|---|---|---|---|
| 18033 | 2026-09-24 10:12:45 | `ID-5B2C3A58-CAC3-409F-BBF6-72BA16E8D098` | `de:05315:11110:2:21` | `vrs:01133::R:673:214` |
| 18034 | 2026-09-24 10:12:45 | `ID-5BEECA7D-24D1-4AE1-82D6-46BC74A7BA05` | `de:05315:11110:2:21` | `vrs:01133::H:673:686` |
| 18035 | 2026-09-24 10:12:45 | `ID-9FBB3001-A6BF-4FDD-B33F-7770C9685251` | `de:05315:11110:1:12` | `vrs:01001::R:673:1226` |
| 18036 | 2026-09-24 10:12:45 | `ID-D4CCB17C-0168-4ABF-AE5E-8DC7FCCB637B` | `de:05315:11110:1:11` | `vrs:01007::H:673:793` |
| 18037 | 2026-09-24 10:12:45 | `ID-F5A4644E-5D48-4BEB-8253-ECED8A582CAA` | `de:05315:11110:2:24` | `vrs:03025:S:H:673:115` |

The remaining requested persisted fields were:

| `ObservationKey` | `TimetabledArrivalUtc` | `EstimatedArrivalUtc` | `PlannedBay` | `EstimatedBay` | `NotServicedStop` | `NoBoardingAtStop` | `NoAlightingAtStop` |
|---:|---|---|---|---|---|---|---|
| 18033 | 2026-09-24 10:12:00 | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` |
| 18034 | 2026-09-24 10:12:00 | 2026-09-24 10:16:48 | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` |
| 18035 | 2026-09-24 10:08:00 | 2026-09-24 10:12:42 | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` |
| 18036 | 2026-09-24 08:41:00 | 2026-09-24 10:53:54 | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` |
| 18037 | 2026-09-24 10:12:00 | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` | `NULL` |

All three status values being `NULL` in this optional-property snapshot is a
valid result. The successful persisted snapshot, the reconciled row counts,
and the null `ErrorCategory`/`ErrorMessage` prove that no DataTable column
mismatch, TVP schema mismatch, BIT conversion error, missing-column error,
stored-procedure parameter error, or SQL type mismatch occurred at runtime.

### Preserved timing conclusions

This acceptance leaves the accepted timing results unchanged:

- Historical `TimingUnavailableTrips = 382`: 380 had no persisted arrival
  estimate and 2 had an earlier estimate followed by latest `NULL`.
- Current frozen `TimingUnavailableTrips = 950`: 946 were
  `NoPersistedArrivalEstimateObserved` and 4 were
  `EstimatePreviouslyPresent_FinalObservationNull`.
- `CollectorParserDiscardsRelevantTiming = NO`.
- `SamplingCadenceMateriallyContributes = PARTIALLY`.
- `WarehouseLatestNullSemanticsContributes = PARTIALLY`.

Stop-service status persistence is fully validated end-to-end.
