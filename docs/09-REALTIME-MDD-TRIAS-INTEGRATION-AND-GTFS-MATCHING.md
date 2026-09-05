# Realtime MDD/TRIAS Integration and GTFS Matching

**Last updated:** 2026-09-05

## Purpose

This is the **canonical source of truth for the realtime phase**. If an older project document conflicts with this file on realtime behavior, this file takes precedence.

## 1. Source and quota

```text
POST https://mdd.gorheinland.com/delfi
Content-Type: application/xml
Header: x-api-key
Protocol: TRIAS 1.2
```

Authentication validated with HTTP 200.

Current project limit: **250,000 requests/month**.

## 2. Permission / retention boundary

The reviewed response states that TRIAS may be used for research, test, development, or hobby purposes. The project was described as a limited non-commercial pilot, and the responder assessed the listed activities as:

> `... ist unsere Einschätzung, dass die unten aufgeführten Punkte unkritisch sind.`

For the current pilot this is treated as positive permission to proceed with the previously described historical storage and analysis.

The response does **not** state a specific retention duration. None is invented. Commercial or otherwise out-of-scope use requires renewed contact/review (`opendata-oepnv@vrr.de` was supplied in the response).

## 3. Realtime staging contract

### `stg.MddRealtimeStopObservation`

Grain: one source stop-event observation at one source observation timestamp.

Important fields: observation/result identity, stop/line/journey references, mode/operator references, timetabled/estimated arrival UTC, planned/estimated bay.

`StopPointRef` uses `Latin1_General_100_BIN2`.

Validated uniqueness:

```text
ObservedAtUtc + ResultId
```

### `stg.MddRealtimeSituationObservation`

Grain: one identifiable source situation snapshot at an observation timestamp.

### `stg.MddRealtimeStopSituationLink`

Source-observed observation-to-situation relationship.

Validated `RelationScope`:

```text
CALL
SERVICE
```

## 4. Working views

```text
wrk.vwCologneRealtimeStopObservation
wrk.vwCologneRealtimeStopEnriched
wrk.vwCologneRealtimeTripMatchKey
wrk.vwCologneRealtimeTripMatch
wrk.vwCologneRealtimeEvidenceSituation
```

Power BI must not read realtime staging directly.

## 5. Arrival / departure / platform / cancellation semantics

Current collector is arrival-oriented and persists current-call arrival data.

Platform rule:

```text
EstimatedBay missing       -> PlatformChanged = NULL
both present and different -> 1
both present and equal     -> 0
```

Missing estimated bay is not “unchanged platform”.

Departure and cancellation are **not** production-modeled yet. Their semantics will only be added after real source examples establish the applicable current-call fields and meaning.

## 6. Timezone and GTFS service day

TRIAS timestamps are UTC. Current static agencies use `Europe/Berlin`; SQL Server conversion uses `W. Europe Standard Time`.

Validated GTFS arrival offsets: 0, 1, 2.

Examples include `48:50:00` and `49:23:00`.

Canonical formulas:

```text
GTFS ServiceDate
= TRIAS LocalCalendarDate - ArrivalDayOffset

GTFS ScheduledArrivalSeconds
= TRIAS LocalSecondsOfDay + ArrivalDayOffset * 86400
```

## 7. Matching contract

Never assume:

```text
TRIAS JourneyRef = GTFS TripId
TRIAS LineRef    = GTFS RouteId
```

Evidence:

1. normalized line name;
2. local scheduled time;
3. active service date;
4. exact stop;
5. controlled parent-station fallback.

Current line normalization removes spaces (`RE 9 -> RE9`).

Statuses:

```text
StaticCoverageMissing
ExactStopMatch
ParentStationFallback
Unresolved
```

`HasUsableStaticMatch = 1` only for exact/fallback.

Validated original sample:

| Line | Status |
|---|---|
| ICE | StaticCoverageMissing |
| RE 7 | ExactStopMatch |
| RB 27 | ParentStationFallback |
| RB 25 | ExactStopMatch |
| RE 9 | ExactStopMatch |

RB27 validated a real platform disagreement (TRIAS Gleis 3 vs GTFS Gleis 4) that resolved uniquely at the same parent station.

## 8. Situation evidence boundary

A linked situation is evidence, not automatically the cause of a delay.

Analytical language must distinguish:

```text
evidence -> association -> likely contributing factor -> confirmed cause
```

A situation context object without the identifiers required by staging is counted/logged but is not given fabricated identity or inferred relationships.

## 9. First persistence checkpoint

First successful persisted snapshot on 2026-09-05 contained:

```text
5 stop observations
2 identifiable situations
2 source-observed links
```

It validated the complete staging -> working -> matching -> evidence path.

Repeated snapshots were then collected successfully.

A later engineering checkpoint contained:

```text
105 stop observations
21 snapshots
5 stop observations per snapshot
```

This is a historical checkpoint only; the scheduled collector continued afterward.

## 10. Collector source and runtime

Repository source:

```text
collector/Invoke-MddRealtimeCollector.ps1
collector/Run-MddRealtimeCollector.ps1
```

Windows runtime:

```text
C:\Collector\Invoke-MddRealtimeCollector.ps1
C:\Collector\Run-MddRealtimeCollector.ps1
C:\Collector\Logs\
```

One execution:

```text
TRIAS request
-> parse stop events
-> parse identifiable situations
-> parse SERVICE/CALL links
-> one SQL transaction
-> status/log
```

Properties:

- one MDD request/execution;
- API key outside source code;
- parameterized SQL;
- idempotent observation/situation behavior using validated identities/timestamp;
- no fabricated situation identity;
- transactional staging inserts;
- NULL arrival/bay semantics preserved;
- no inferred cancellation/departure.

## 11. API key

Current local pilot reads `MDD_API_KEY` from the Windows **User** environment configuration.

The key is never printed, committed, embedded in SQL, or shown in screenshots.

## 12. Task Scheduler automation

Task:

```text
Cologne Transit Realtime Collector
```

Cadence:

```text
every 5 minutes
```

Configured with non-interactive PowerShell, `MultipleInstances IgnoreNew`, `StartWhenAvailable`, and a bounded execution limit.

Current principal is the interactive Windows user context. Therefore the local pilot requires the VM/user context to be available. It does not collect while the VM is powered off.

The five-minute cadence would be ~8,640 requests/month if continuous for 30 days, below the 250,000 project limit.

## 13. Collector logging and scheduler diagnostics

Wrapper logs every run under:

```text
C:\Collector\Logs\collector-YYYYMMDD-HHMMSS.log
```

Terminal marker:

```text
STATUS: SUCCESS
```

or `STATUS: FAILED`.

Task Scheduler Operational logging was enabled so task/process events can be inspected independently of collector logs.

A prior task event returned nonzero process code `2147942401`, demonstrating that scheduler “completed” text is not sufficient application-level evidence. This motivated collector-level logs.

## 14. Strict-mode collection-count bug

A real scheduled run persisted its snapshot but failed during summary output because `$parsedLinks` was NULL and strict mode rejected:

```powershell
$parsedLinks.Count
```

Fix:

```powershell
@($parsedLinks).Count
```

Safe array counting was applied to parsed collections used in summary reporting. Manual wrapper execution and later scheduled execution validated `STATUS: SUCCESS` and `LastTaskResult = 0`.

## 15. Repository/runtime separation

GitHub Desktop runs on macOS. The repository is shared into Windows at:

```text
\vmware-host\Shared Folders\cologne-public-transport-intelligence
```

Runtime remains `C:\Collector`. Source copies are synchronized to repository `collector/`. Logs remain runtime data and are not committed.

## 16. Stop-enrichment performance root cause

Old `wrk.vwCologneRealtimeStopEnriched` built:

```sql
SELECT DISTINCT StopId, ParentStationId, StopName
FROM wrk.vwCologneScheduledStopEvent
```

This traversed ~1,551,343 scheduled stop-event patterns to produce 2,287 used stops.

Measured stop-map cost:

```text
CPU ~5735 ms
elapsed ~6207 ms
```

Full enrichment count:

```text
CPU ~6265 ms
elapsed ~6920 ms
```

## 17. Stop-enrichment optimization

Replacement used:

```text
dw.DimStop
+ EXISTS(dw.FactScheduledStopEvent)
```

Validation:

```text
Rows = 2287
DifferenceCount = 0
```

The production view was then altered.

Post-change engineering benchmark on the then-current 105 observations:

```text
RowsCount = 105
CPU = 0 ms
elapsed = 0 ms
```

## 18. Trip-match performance finding

Important optimizer behavior:

```text
COUNT(*) on vwCologneRealtimeTripMatch -> ~0 ms
simple columns -> ~1 ms
matching columns/candidate counts -> slow
```

Therefore cheap counts did not prove that matching expressions were fast.

`wrk.vwCologneRealtimeTripMatch` candidate logic relied on `wrk.vwCologneScheduledStopEvent`, which originates from the large static staging path.

Route-name normalization alone was fast (~3 ms). The schedule route/time lookup was the real bottleneck.

Pre-index isolated schedule lookup:

```text
CPU ~328 ms
elapsed ~1647 ms
```

## 19. Persisted realtime search column

Added to `dw.FactScheduledStopEvent`:

```text
ScheduledArrivalSecondOfDay
```

Persisted definition:

```text
ScheduledArrivalSeconds - (ArrivalDayOffset * 86400)
```

This exposes local seconds-of-day for an index seek while preserving `ArrivalDayOffset` for GTFS service-date semantics.

## 20. Realtime-match index

Added:

```text
IX_FactScheduledStopEvent_RealtimeMatch
```

Keys:

```text
RouteKey
ScheduledArrivalSecondOfDay
```

Includes:

```text
ArrivalDayOffset
ServiceKey
StopKey
TripKey
```

Post-index isolated route/time lookup:

```text
CPU ~16 ms
elapsed ~4 ms
```

With active service-date validation through `BridgeServiceDate` / `DimDate`:

```text
CPU ~15 ms
elapsed ~17 ms
```

## 21. Current trip-match rewrite status

The production view:

```text
wrk.vwCologneRealtimeTripMatch
```

has **not yet been rewritten** to the warehouse-direct version.

Required next sequence:

1. synchronize already-applied DB performance changes into checked-in SQL scripts;
2. complete warehouse-direct matching using `DimRoute`, `FactScheduledStopEvent`, `FactScheduledTrip`, `DimStop`, and active service-date objects;
3. benchmark after the new index;
4. compare current vs proposed output row-by-row;
5. verify `ExactStopCandidateCount`, `ParentStationCandidateCount`, `MatchStatus`, `MatchedTripId`, `MatchedRouteId`, `MatchedServiceId`, `MatchedStaticStopId`;
6. only with semantic equivalence proven, alter the production view.

## 22. Grain warnings

`wrk.vwCologneRealtimeEvidenceSituation` can have more rows than stop observations because one observation can link to multiple situations.

Repeated snapshots can also observe the same service multiple times.

Therefore:

```text
EvidenceSituation row count != observation count
observation count != dated service count
```

Realtime KPIs require a later consolidation grain.

## 23. Binding decisions

- raw/source values stay in `stg`;
- normalization/matching stays in `wrk`;
- validated operational facts enter `dw`/`analytics` later;
- Power BI does not read staging;
- exact stop preferred, parent fallback controlled;
- `StaticCoverageMissing` is not match failure;
- GTFS >24h semantics preserved;
- missing estimate/bay preserves NULL meaning;
- cancellation/departure not invented;
- situations are evidence, not confirmed causality;
- secrets remain outside source control;
- performance rewrites require semantic-equivalence validation.

## 24. Exact handoff checkpoint

At end of the 2026-09-05 session:

Completed:

- automated local collector every five minutes;
- per-run logging;
- collector strict-mode NULL-count fix;
- repeated realtime persistence;
- stop-enrichment semantic-preserving performance rewrite;
- persisted `ScheduledArrivalSecondOfDay`;
- `IX_FactScheduledStopEvent_RealtimeMatch`;
- route/time lookup ~4 ms;
- route/time + active service-date lookup ~17 ms.

Not yet completed:

- repository SQL scripts reproducing the performance DB changes;
- full warehouse-direct `vwCologneRealtimeTripMatch` prototype after the new index;
- row-by-row semantic-equivalence comparison;
- production trip-match alteration;
- consolidated realtime DW/analytics grain.

**The next session should continue exactly here.**
