# Cologne Public Transport Intelligence

<p align="center">
  <a href="https://commons.wikimedia.org/wiki/File:K%C3%B6ln_Hohenzollernbr%C3%BCcke.jpg">
    <img src="https://commons.wikimedia.org/wiki/Special:Redirect/file/K%C3%B6ln%20Hohenzollernbr%C3%BCcke.jpg?width=1600"
         alt="Cologne Cathedral and Hohenzollern Bridge across the Rhine"
         width="100%">
  </a>
  <br>
  <sub>Cologne Cathedral and Hohenzollern Bridge · Photo: Anne Offermanns ·
    <a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>
  </sub>
</p>

An end-to-end analytics project for understanding the reliability and performance of multimodal public transport in Cologne, Germany.

The project combines a validated **VRS/go.Rheinland static GTFS baseline** with **MDD NRW / DELFI / TRIAS 1.2 realtime observations**. SQL Server is used for staging, transformation, service-day normalization, schedule matching, warehouse modeling, and analytics. Power BI currently represents the validated scheduled-service baseline; the realtime operational fact and SQL analytics layer are now prepared, while Power BI remains a later reporting step after more history accumulates.

This repository is the narrowed Cologne successor to an earlier NRW-wide
public-transport project. Some runtime names still carry that historical scope.
The current active realtime pipeline is the Cologne MDD NRW / DELFI / TRIAS
Collector; the former NRW Deutsche-Bahn collector is a separate legacy runtime.

## Current technology

- SQL Server 2025 Developer + SSMS
- Power BI Desktop
- Windows 11 VM in VMware Fusion
- PowerShell collector + Windows Task Scheduler
- GitHub Desktop on the macOS host
- MDD NRW / DELFI / TRIAS 1.2 realtime source

## Current status — 2026-09-08

### Static baseline

Validated static scope:

- 15 agencies
- 7 analytical modes
- 153 Cologne-serving routes
- 3,156 Cologne stop records
- 90,331 scheduled trip patterns
- 1,551,343 Cologne scheduled stop-event patterns
- 1,878,944 dated scheduled trip occurrences

The existing Power BI model remains a **planned supply baseline**, not a reliability dashboard.

### Historical realtime collection phase

The project is now in the historical realtime collection phase. The intended
window is a minimum of **14 actual calendar days**, with **28 days preferred**;
missing periods must remain visible rather than being backfilled.

The 2026-09-08 10:42 UTC values below are preserved as a historical checkpoint:
1,193 genuine stop observations across 239 snapshots and 4 UTC collection
dates, spanning 2026-09-05 08:27:28 UTC through 2026-09-08 10:38:41 UTC. The
maximum snapshot gap remains 76,759 seconds, so that checkpoint was not yet a
14- or 28-day dataset and missing periods remain visible.

Historical multi-target collection verified from: **2026-09-07 20:03:53 UTC**.
Before that verified run, the preserved legacy Hbf-only history contained 845
observations across 169 snapshots. The first verified automatic multi-target
run selected Köln Porz Markt (slot 5) and persisted five genuine observations;
the next scheduled run selected Köln Hbf (slot 6) and also succeeded. The
earlier 2026-09-08 10:42 UTC audit found 70 successful `Automatic` runs since
the verified start, with 0 failed runs and 0 stale or incomplete `Started` runs;
those values are not the current live state.

#### Latest live historical-collection verification — 2026-09-08 13:45:46 UTC

The live SQL Server verification found latest `CollectorRunId = 107`, with the
latest Collector run started at 2026-09-08 13:43:52 UTC and completed at
13:43:55 UTC as `Succeeded` / `Automatic`. There are 107 total
`ctl.MddCollectorRun` rows, 107 successful `Automatic` runs since
2026-09-07 20:03:53 UTC, 0 `Failed` runs, 0 current `Started` runs, and 0
stale `Started` runs using the existing 15-minute rule.

Current persisted realtime totals are 1,378 stop observations, 496 situation
observations, and 618 stop-situation links across 276 snapshots and 4 UTC
observation dates. The realtime stop-observation range is
2026-09-05 08:27:28 UTC through 2026-09-08 13:43:49 UTC.

Collection continued after the old checkpoint: 37 Collector runs and 37
successful `Automatic` runs started after 10:42 UTC, and 185 genuine stop
observations were both observed and created after that checkpoint, beginning at
2026-09-08 10:43:49 UTC and reaching 13:43:49 UTC.

All seven currently enabled targets are still participating and have persisted
observations. Each live target still has `NumberOfResults = 5`; the configured
target list, slot weighting, and five-minute cadence were not changed:

| SamplingTargetId | Target | StopPointRef | IsEnabled | Slots | Successful Automatic runs since trusted start | Latest successful Automatic start | Persisted stop observations | Latest persisted observation |
| ---: | --- | --- | :---: | ---: | ---: | --- | ---: | --- |
| 1 | Köln Heumarkt | `de:05315:11110` | 1 | 2 | 21 | 2026-09-08 13:23:52 UTC | 105 | 2026-09-08 13:23:42 UTC |
| 2 | Köln Hbf | `de:05315:11201` | 1 | 2 | 22 | 2026-09-08 13:38:52 UTC | 955 | 2026-09-08 13:38:41 UTC |
| 3 | Köln Rodenkirchen Bf | `de:05315:12711` | 1 | 1 | 10 | 2026-09-08 13:08:53 UTC | 50 | 2026-09-08 13:08:47 UTC |
| 4 | Köln Bf Ehrenfeld | `de:05315:14201` | 1 | 1 | 10 | 2026-09-08 13:28:52 UTC | 50 | 2026-09-08 13:28:48 UTC |
| 5 | Köln Worringen S-Bahn | `de:05315:16601` | 1 | 1 | 10 | 2026-09-08 13:03:53 UTC | 48 | 2026-09-08 13:03:47 UTC |
| 6 | Köln Porz Markt | `de:05315:17311` | 1 | 1 | 12 | 2026-09-08 13:33:52 UTC | 58 | 2026-09-08 13:33:48 UTC |
| 7 | Köln Bf Mülheim | `de:05315:19201` | 1 | 2 | 22 | 2026-09-08 13:43:52 UTC | 110 | 2026-09-08 13:43:49 UTC |

The health check found no failed HTTP/API or SQL/persistence runs, no stale
started execution, no unselected configured target, and no target without
persisted observations. Two automatic run gaps over ten minutes remain visible
as old historical gaps (4,598 seconds from 21:53:53 to 23:10:31 UTC and
27,832 seconds from 23:10:31 to 2026-09-08 06:54:23 UTC); no later automatic
gap exceeded ten minutes. The 76,759-second maximum snapshot gap is likewise a
preserved historical gap, not evidence that current collection has stopped.

The minimum target is 14 actual calendar days from that verified start; the
preferred target is 28 actual calendar days. At the live verification time,
the elapsed duration was 17 hours 41 minutes 53 seconds (0.737419 days), or
5.2673% toward 14 days and 2.6336% toward 28 days. The earliest milestones are
2026-09-21 20:03:53 UTC and 2026-10-05 20:03:53 UTC respectively; neither is
complete. Preserved pre-start Hbf-only history is excluded from this clock.

The repository-managed `ctl.MddCollectorRun` audit objects are deployed and the
current Collector continues to persist successful `Succeeded` / `Automatic`
rows. Windows Scheduled Task management is outside this database task. The
user has already manually disabled the legacy `NRW DB Realtime Collector`; this
repository does not inspect, modify, or reuse that old NRW runtime.

### Realtime database engineering — completed now

The live database now contains the production operational fact
`dw.FactOperationalStopOutcome`, refreshed by
`dw.uspRefreshFactOperationalStopOutcome`, plus read-only Data Quality/Coverage
and Reliability analytics views under `analytics`. The fact grain is one
matched scheduled stop event on one GTFS service date; repeated observations
are consolidated by `ObservedAtUtc`, then `ObservationKey`.

Only `ExactStopMatch` and `ParentStationFallback` enter operational outcomes.
`StaticCoverageMissing` and `Unresolved` remain visible in coverage analytics.
Estimated arrival/delay values are explicitly source estimates, platform
changes require comparable bay evidence, and linked situations are evidence
only—not confirmed causality. The 14/28-day period remains a later history and
interpretation milestone; it is not a prerequisite for this database design or
SQL validation. Power BI has not been started in this task.

Subsequent GTFS/static warehouse reloads now clear and rebuild only the derived
operational outcome fact within the same transaction as the static replacement,
then refresh it from the preserved append-only realtime observations before
commit. A failed reload rolls back both layers; realtime staging and Collector
run history are not deleted. The initial static load remains compatible with a
database where the realtime operational objects do not yet exist.

### Controlled static-reload verification — 2026-09-08

A real controlled reload was executed against the live SQL Server using the
current validated GTFS staging batch and
`sql/04-warehouse/02-load-static-warehouse.sql`. The pre-reload capture was at
2026-09-08 11:52:31 UTC; the latest realtime observation then was
2026-09-08 11:48:49 UTC.

| Evidence | Before reload | Immediately after committed reload |
| --- | ---: | ---: |
| `WarehouseLoadBatchId` | 2 | 3 |
| Static load status | — | `Loaded`; `CompletedAtUtc` 2026-09-08 11:59:37 UTC |
| `stg.MddRealtimeStopObservation` | 1,263 | 1,273 |
| `stg.MddRealtimeSituationObservation` | 454 | 457 |
| `stg.MddRealtimeStopSituationLink` | 542 | 545 |
| `ctl.MddCollectorRun` | 84 | 86 |
| `dw.FactOperationalStopOutcome` | 466 | 518 |
| Current usable `(DateKey, ScheduledStopEventKey)` grain | 512 | 518 |

Batch 3 recorded and actual static row counts reconciled exactly: agencies
15, modes 7, routes 153, stops 3,156, services 3,947, dates 364,
service-date rows 99,399, trips 90,331, and scheduled stop events 1,551,343.
The realtime counts increased during the test but never decreased, proving
source history preservation while the Collector continued naturally.

The checked-in operational validation reported 9 foreign keys with 0 disabled
and 0 untrusted, a unique operational grain, and a 522/522/0 current usable
grain comparison at its completion. Its initial lineage check saw 0 first and
1 latest violation while five new genuine stop observations arrived after the
reload; the existing refresh resolved that live timing difference. A final
exact recheck using the required `ObservedAtUtc ASC, ObservationKey ASC` first
ordering and `ObservedAtUtc DESC, ObservationKey DESC` latest ordering returned
0/0 lineage violations, 0 exact grain differences, and 0 non-usable fact rows.

The same validation proved refresh repeatability: the first refresh moved the
fact from 518 to 522 as four new grains and one existing grain update arrived;
the second refresh returned 0 inserts, 0 updates, and a 522/522/0 state
comparison. The first comparison was therefore a documented natural-data
`REVIEW`, not an idempotency failure. A later final refresh incorporated five
more genuine observations and left 527 outcomes.

`sql/05-analytics/04-validate-realtime-analytics-views.sql` returned PASS for
view existence/queryability, Data Quality/Coverage, reliability reconciliation
(527 fact rows and 527 consumer rows), dimensions, and platform/situation
semantics. Overall observed estimated delay remained valid at average 9.00,
median 3.85, and P95 35.80 minutes. Power BI was not started.

### Realtime collector

The repository realtime collector is configured for the local pilot:

- `POST https://mdd.gorheinland.com/delfi`
- TRIAS 1.2 with `x-api-key`
- current project limit: **250,000 requests/month**
- non-commercial pilot storage/historical-analysis use reviewed positively in the received permission email
- one arrival-oriented request every five minutes while the local Windows VM/task context is available, using a database-backed rotating Cologne stop-point panel for scheduled no-target runs
- parameterized SQL persistence into three realtime staging tables
- situation observation and `SERVICE` / `CALL` link support
- per-run collector logging
- API key kept outside Git, SQL, and screenshots

Current runtime:

```text
C:\Collector\MddRealtimeCollector.psm1
C:\Collector\Invoke-MddRealtimeCollector.ps1
C:\Collector\Run-MddRealtimeCollector.ps1
C:\Collector\Logs\
```

Repository collector source:

```text
collector/MddRealtimeCollector.psm1
collector/Invoke-MddRealtimeCollector.ps1
collector/Run-MddRealtimeCollector.ps1
```

### Realtime matching

Validated statuses:

```text
StaticCoverageMissing
ExactStopMatch
ParentStationFallback
Unresolved
```

`HasUsableStaticMatch = 1` only for `ExactStopMatch` and `ParentStationFallback`.

TRIAS IDs are not assumed to equal GTFS IDs. Matching uses normalized line name, local scheduled time, active GTFS service date, exact stop, and controlled parent-station fallback.

### SQL performance work

Two important performance improvements were validated:

1. `wrk.vwCologneRealtimeStopEnriched` no longer rebuilds its stop lookup through ~1.55M scheduled stop-event rows. A warehouse-based equivalent was validated with `DifferenceCount = 0`, reducing the tested elapsed time from about 6.9 seconds to effectively immediate execution.
2. `dw.FactScheduledStopEvent` now has persisted `ScheduledArrivalSecondOfDay` plus `IX_FactScheduledStopEvent_RealtimeMatch`. The isolated route/time lookup improved from ~1647 ms to ~4 ms; with active service-date validation it completed in ~17 ms.

`wrk.vwCologneRealtimeTripMatch` now resolves static candidates directly from the warehouse schedule model and no longer uses `wrk.vwCologneScheduledStopEvent` for candidate search. On a frozen 450-observation regression scope, the warehouse-direct prototype matched the captured production baseline in both directions (`DifferenceCount = 0` for critical and complete output comparisons), with identical row grain and status counts of 145 `ExactStopMatch`, 27 `ParentStationFallback`, and 278 `StaticCoverageMissing`; the same frozen baseline was rechecked against the altered production view with zero critical/full differences. Materialized client elapsed time was approximately 494.9 seconds for the baseline versus 3.6 seconds for the direct implementation; a final forced-field projection returned 530 rows in approximately 1.6 seconds.

## Documentation

The [Mac-to-VMware SQL Server and VS Code setup guide](docs/guides/Mac_VMware_SQLServer_VSCode_Guide.pdf) is the public visual companion for configuring SQL Server inside a VMware Fusion Windows VM and connecting to it from macOS.

Read in order:

1. [Project Definition](docs/01-PROJECT-DEFINITION.md)
2. [Data Sources and GTFS Profile](docs/02-DATA-SOURCES-AND-GTFS-PROFILE.md)
3. [Cologne Scope and Mode Classification](docs/03-COLOGNE-SCOPE-AND-MODE-CLASSIFICATION.md)
4. [Data Architecture](docs/04-DATA-ARCHITECTURE.md)
5. [Database Design and SQL Implementation](docs/05-DATABASE-DESIGN-AND-SQL-IMPLEMENTATION.md)
6. [Static GTFS Warehouse Model](docs/06-STATIC-GTFS-WAREHOUSE-MODEL.md)
7. [Static Analytics and Power BI Baseline](docs/07-STATIC-ANALYTICS-AND-POWER-BI-BASELINE.md)
8. [Power BI Static Baseline Build Guide](docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md)
9. [Realtime MDD/TRIAS Integration and GTFS Matching](docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md)
10. [Local SQL Server Connection Guide](docs/10-LOCAL-SQL-SERVER-CONNECTION-GUIDE.md)

For realtime behavior, **document 09 is authoritative** if an older document conflicts with it.
