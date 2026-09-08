# Realtime MDD/TRIAS Integration and GTFS Matching

**Last updated:** 2026-09-08

## Purpose

This is the **canonical source of truth for the realtime phase**. If an older project document conflicts with this file on realtime behavior, this file takes precedence.

## Current historical collection phase

The project is accumulating genuine MDD/TRIAS observations for a future
historical realtime analysis phase. Historical multi-target collection verified
from: **2026-09-07 20:03:53 UTC**. The useful-history target is a minimum of
14 actual calendar days, with 28 days preferred. The Collector must accumulate
the data naturally; missing periods are not generated or backfilled.

The live SQL Server baseline checked at 2026-09-08 08:28 UTC contains 1,058
genuine stop observations across 212 snapshots and 4 UTC collection dates. The
observed range is 2026-09-05 08:27:28 UTC through 2026-09-08 08:23:48 UTC; the
maximum snapshot gap remains 76,759 seconds. This is not yet a 14- or 28-day
dataset, and missing periods remain visible.

Before the verified start, preserved legacy Hbf-only history contained 845
observations across 169 snapshots. The first verified automatic run selected
Köln Porz Markt (slot 5) and inserted five genuine source observations. The
next scheduled run selected Köln Hbf (slot 6) and inserted five more. A live
audit check at 2026-09-08 08:28 UTC found 43 successful `Automatic` runs since
the verified start (`CollectorRunId` 1–43), 0 failed runs, and 0 stale or
incomplete `Started` runs. The latest successful run after `CollectorRunId = 2`
was `CollectorRunId = 43`: started 2026-09-08 08:23:52 UTC, completed
2026-09-08 08:23:55 UTC, status `Succeeded`, sampling mode `Automatic`, target
Köln Heumarkt (`de:05315:11110`), slot 3, HTTP 200, 5 source events, and 5
inserted observations. All seven enabled targets have participated in
successful automatic runs and have persisted observations. The earliest 14-day
and 28-day milestone dates from the verified start are
2026-09-21 and 2026-10-05 respectively; neither target is complete yet.

The repository-managed `ctl.MddCollectorRun` table and procedures are deployed.
All three files under `C:\Collector` now match the repository source by
SHA-256, and the existing `C:\Collector\Logs` directory was preserved. Task
Scheduler history shows `\Cologne Transit Realtime Collector` running as
`DATAANALYST-VM\Somaye` every five minutes with return code 0. Its corrected
wrapper logs and audit rows prove the scheduled runtime can read the external
`MDD_API_KEY` without exposing it.

This repository was narrowed from an earlier NRW-wide public-transport project
to the current Cologne scope. Live inspection on 2026-09-08 classified the
separate `\NRW DB Realtime Collector` task as the earlier Deutsche-Bahn
multi-station runtime, not as a duplicate MDD/TRIAS collector. Its live
Task Scheduler events expose `powershell.exe`; the protected task definition
could not be exported from the available SQL service context. The historical
task definition and matching live files are
`C:\NRWTransport\Collector\RunDbRealtimeCollector.ps1` and
`C:\NRWTransport\Collector\DbRealtimeCollector.ps1`; the latter uses
`cfg.DbRealtimeStation`, `stg.DbRealtimeStopObservation`, and Deutsche Bahn
`/plan` and `/fchg` endpoints. These legacy files and their log directory were
preserved. Its final enabled/disabled state remains unverified from the current
execution context because no authorized Windows Task Scheduler/elevated
PowerShell session could be established. The task has not been claimed
disabled, deleted, renamed, or reactivated. Administrator/authorized Windows
Task Scheduler access is the only remaining blocker for this cleanup item. No
old file, folder, or task was renamed; live SQL evidence confirms that the
current Cologne MDD/TRIAS pipeline continues to produce successful automatic
runs.

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
collector/MddRealtimeCollector.psm1
collector/Invoke-MddRealtimeCollector.ps1
collector/Run-MddRealtimeCollector.ps1
```

Windows runtime:

```text
C:\Collector\MddRealtimeCollector.psm1
C:\Collector\Invoke-MddRealtimeCollector.ps1
C:\Collector\Run-MddRealtimeCollector.ps1
C:\Collector\Logs\
```

One execution:

```text
start ctl.MddCollectorRun as Started
-> resolve automatic/manual sampling context
-> resolve API key
-> build TRIAS request
-> HTTP request with timeout and bounded transient retry
-> parse stop events
-> parse identifiable situations
-> parse SERVICE/CALL links
-> construct typed TVPs
-> one set-based SQL persistence procedure/transaction
-> complete ctl.MddCollectorRun as Succeeded
-> status/log
```

Properties:

- one logical TRIAS collection request per Collector execution, normally one HTTP attempt, with bounded additional HTTP attempts only for transient retryable failures;
- configurable 30-second HTTP timeout by default;
- bounded three-attempt transient retry policy with exponential 2/4-second backoff by default;
- retries only for HTTP 408, 429, 500, 502, 503, 504 and temporary transport/WebException failures;
- `Retry-After` seconds and HTTP-date values honored up to the 30-second retry-delay cap by default;
- actual HTTP attempt count reported in the run summary;
- API key outside source code;
- typed TVP inputs and one `stg.uspPersistMddRealtimeSnapshot` call;
- set-based SQL persistence with one atomic snapshot transaction;
- existing unique indexes, primary keys, and foreign keys remain the idempotency/relationship protection;
- idempotent observation/situation behavior using validated identities/timestamp;
- no fabricated situation identity;
- unresolved source links are skipped rather than assigned fabricated identity;
- NULL arrival/bay semantics preserved;
- no inferred cancellation/departure.

### Collector run audit

The operational audit grain is one row per Collector execution in
`ctl.MddCollectorRun`, created by `ctl.uspStartMddCollectorRun` and completed
by `ctl.uspCompleteMddCollectorRun`. The repository deployment script is
`sql/02-staging/09-create-mdd-collector-run-audit.sql`; the focused diagnostic
scripts are `sql/02-staging/10-validate-mdd-collector-run-audit.sql` and
`sql/02-staging/11-validate-realtime-collection-health.sql`.

The row starts as `Started` before sampling, authentication, the MDD request,
parsing, or realtime snapshot persistence. A successful run becomes
`Succeeded` and records its resolved sampling target, HTTP status and attempt
count, parsed source counts, and the persistence statistics already returned
by `stg.uspPersistMddRealtimeSnapshot`. A failure updates the row to `Failed`
with the last available context and a simple stage such as `Sampling`,
`Authentication`, `Request`, `Parse`, `Persistence`, `AuditStart`, or
`AuditComplete`; the original Collector exception is rethrown if the audit
update itself fails.
An execution killed after the start insert may remain `Started`, indicating
that completion was not observed. A valid response with little or no returned
data remains `Succeeded`; its zero or low source/persistence counts make that
case distinguishable from a failure.

If SQL Server is unavailable before the initial start insert, the database
cannot contain an audit row for that execution. The existing wrapper log and
nonzero exit behavior remain the fallback evidence. The audit implementation
does not store the MDD API key, authorization headers, passwords, or
connection-string credentials, and it does not add `CollectorRunId` to any
realtime staging table.

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

Task Scheduler history verifies a five-minute time-triggered PowerShell action,
the intended interactive principal `DATAANALYST-VM\Somaye`, and successful
completion with return code 0. The synchronized wrapper's `STATUS: SUCCESS`
marker plus the automatic audit rows verify that the action reaches
`C:\Collector\Run-MddRealtimeCollector.ps1`, which then invokes the current
module-backed Collector. The main task has not overlapped in the observed
successful interval; the local pilot still requires the VM/user context to be
available and does not collect while the VM is powered off.

The five-minute cadence would be ~8,640 normal HTTP attempts/month if continuous for 30 days, below the 250,000 project limit. Transient retries are bounded and are reported because they consume additional MDD requests.

## Realtime sampling panel

The scheduled no-target Collector execution now resolves its target from the
database-backed `ctl` sampling configuration. It uses the UTC five-minute
bucket, the enabled `ctl.MddRealtimeSamplingSlot` rows, and
`ctl.uspGetMddRealtimeSamplingTarget`; it does not use an in-memory counter.
Restarting PowerShell or Windows therefore does not reset the rotation. A
missed bucket is not replayed. An explicit `-StopPointRef` remains a manual
single-target override and bypasses automatic selection.

The current panel was selected from the live warehouse using current
`dw.DimStop` identities and scheduled mode/route coverage. Each stored target
is a current parent-station `StopId` used as the MDD/TRIAS `StopPointRef`:

| Target | StopPointRef | Static stable modes | Distinct routes | Slots | Average interval |
|---|---|---|---:|---:|---:|
| Köln Hbf | `de:05315:11201` | S-Bahn, RE, RB | 24 | 2 | 25 min |
| Köln Bf Mülheim | `de:05315:19201` | Stadtbahn/Tram, S-Bahn, RE, RB, Urban Bus | 24 | 2 | 25 min |
| Köln Bf Ehrenfeld | `de:05315:14201` | S-Bahn, RE, RB, Urban Bus | 17 | 1 | 50 min |
| Köln Heumarkt | `de:05315:11110` | Stadtbahn/Tram, Urban Bus, Regional/Other Bus | 14 | 2 | 25 min |
| Köln Porz Markt | `de:05315:17311` | Stadtbahn/Tram, Urban Bus | 10 | 1 | 50 min |
| Köln Worringen S-Bahn | `de:05315:16601` | S-Bahn, Regional/Other Bus, Urban Bus | 8 | 1 | 50 min |
| Köln Rodenkirchen Bf | `de:05315:12711` | Stadtbahn/Tram, Urban Bus | 7 | 1 | 50 min |

The fixed ten-slot, 50-minute cycle is:

```text
1 Hbf -> 2 Mülheim -> 3 Heumarkt -> 4 Ehrenfeld -> 5 Porz Markt
-> 6 Hbf -> 7 Mülheim -> 8 Heumarkt -> 9 Worringen -> 10 Rodenkirchen
```

The weighting reflects scheduled service volume, mode and route diversity,
multimodal interchange value, and geographic spread across central, east,
west, north, south, and southeast Cologne. It intentionally includes urban
bus/tram locations and does not require SEV, which is not a stable everyday
mode. `NumberOfResults` remains configurable and is seeded at 5 per target.
When automatic selection is used without an explicit `-NumberOfResults`, the
stored per-target value is used; an explicitly supplied `-NumberOfResults`
still overrides it for that invocation.

At a continuous five-minute cadence the plan produces approximately 8,928
normal logical MDD requests in a 31-day month. Transient retries remain the
existing bounded retry behavior and can add HTTP attempts. The repository
validation report is
`sql/02-staging/08-validate-mdd-realtime-sampling.sql`.

The synchronized Windows scheduled context successfully read the external
`MDD_API_KEY` and made genuine MDD requests without a manual `-StopPointRef`.
The first verified automatic run selected Köln Porz Markt (slot 5), and the
next selected Köln Hbf (slot 6); both returned HTTP 200 and persisted five
source observations. The live sampling tables remain configured with all seven
enabled targets, `NumberOfResults = 5`, and the intended
2/2/2/1/1/1/1 weighting. At the 2026-09-08 08:28 UTC checkpoint, all seven
targets had participated in successful automatic runs and all seven had
persisted observations:

| Target | Successful automatic runs since verified start | Persisted observations (all time) |
|---|---:|---:|
| Köln Heumarkt | 9 | 45 |
| Köln Hbf | 9 | 890 |
| Köln Rodenkirchen Bf | 4 | 20 |
| Köln Bf Ehrenfeld | 3 | 15 |
| Köln Worringen S-Bahn | 4 | 20 |
| Köln Porz Markt | 5 | 23 |
| Köln Bf Mülheim | 9 | 45 |

The current all-time observation total is 1,058; the Hbf total includes
preserved pre-start history. This is a genuine accumulation checkpoint, not a
reason to redesign the panel.

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

For the 2026-09-07 runtime checkpoint, the deployed module, Invoke script, and
Run wrapper were synchronized from the repository and matched by SHA-256. The
new log `collector-20260907-220352.log` records automatic slot 5 / Köln Porz
Markt, a successful HTTP 200 request, one attempt, five source events, five
inserts, `CollectorRunId = 1`, and `STATUS: SUCCESS`. The next scheduled log
`collector-20260907-220852.log` records automatic slot 6 / Köln Hbf with the
same successful source/persistence evidence and `CollectorRunId = 2`.

The separate `\NRW DB Realtime Collector` task is the retained legacy
Deutsche-Bahn runtime from the former NRW-wide project. Its recent Task
Scheduler events launch `powershell.exe` successfully, and live inspection of
the matching live files confirmed the old `cfg.DbRealtimeStation` /
`stg.DbRealtimeStopObservation` pipeline and Deutsche Bahn `/plan` and `/fchg`
requests. It does not perform current MDD/TRIAS collection and produced no new
`ctl.MddCollectorRun` row. Its legacy files were preserved, but its final
enabled/disabled state remains unverified from the current execution context
because no authorized Windows Task Scheduler/elevated PowerShell session could
be established. The task has not been claimed disabled, deleted, renamed, or
reactivated. Administrator/authorized Windows Task Scheduler access is the only
remaining blocker for this cleanup item. The named Cologne task remains the
verified current MDD/TRIAS Collector.

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

Before the rewrite, `wrk.vwCologneRealtimeTripMatch` candidate logic relied on `wrk.vwCologneScheduledStopEvent`, which originates from the large static staging path.

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

now resolves static candidates directly from the warehouse schedule model. Its candidate path uses `DimRoute`, `FactScheduledStopEvent`, `FactScheduledTrip`, `DimStop`, `DimService`, `BridgeServiceDate`, and `DimDate`; it no longer depends on `wrk.vwCologneScheduledStopEvent`.

The frozen-scope semantic regression captured the old production output before alteration and compared it with the warehouse-direct prototype:

```text
frozen observations: 450
baseline rows / direct rows: 450 / 450
duplicate observation-grain rows: 0 / 0
critical and complete DifferenceCount: 0 in both directions
status counts: ExactStopMatch 145, ParentStationFallback 27,
               StaticCoverageMissing 278
```

The same frozen baseline was rechecked against the altered production view with zero critical and complete-row differences in both directions and no grain/cardinality change.

The paired materialization benchmark was approximately 494.9 seconds for the old production path versus 3.6 seconds for the warehouse-direct implementation. After alteration, a forced-field projection returned 530 rows in approximately 1.6 seconds; the compiled plan referenced `IX_FactScheduledStopEvent_RealtimeMatch` and not the old scheduled-stop-event view. The focused regression script is checked in at `sql/03-working/04-validate-realtime-trip-match-rewrite.sql`.

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

At the end of the 2026-09-06 repository-synchronization session:

Completed:

- automated local collector every five minutes;
- per-run logging;
- collector strict-mode NULL-count fix;
- repeated realtime persistence;
- stop-enrichment semantic-preserving performance rewrite;
- persisted `ScheduledArrivalSecondOfDay`;
- `IX_FactScheduledStopEvent_RealtimeMatch`;
- repository SQL synchronization = completed for the validated realtime tables, views, computed column, and index;
- route/time lookup ~4 ms;
- route/time + active service-date lookup ~17 ms.

Not yet completed:

- consolidated realtime DW/analytics grain.

The trip-match rewrite and its semantic validation are complete; future work remains at the separate realtime DW/analytics consolidation grain.
