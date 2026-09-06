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

The project combines a validated **VRS/go.Rheinland static GTFS baseline** with **MDD NRW / DELFI / TRIAS 1.2 realtime observations**. SQL Server is used for staging, transformation, service-day normalization, schedule matching, warehouse modeling, and analytics. Power BI currently represents the validated scheduled-service baseline; realtime reliability reporting will be added only after repeated observations are consolidated into defensible dated operational facts.

## Current technology

- SQL Server 2025 Developer + SSMS
- Power BI Desktop
- Windows 11 VM in VMware Fusion
- PowerShell collector + Windows Task Scheduler
- GitHub Desktop on the macOS host
- MDD NRW / DELFI / TRIAS 1.2 realtime source

## Current status — 2026-09-05

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

### Realtime collector

The realtime pilot is operational:

- `POST https://mdd.gorheinland.com/delfi`
- TRIAS 1.2 with `x-api-key`
- current project limit: **250,000 requests/month**
- non-commercial pilot storage/historical-analysis use reviewed positively in the received permission email
- one arrival-oriented request every five minutes while the local Windows VM/task context is available
- parameterized SQL persistence into three realtime staging tables
- situation observation and `SERVICE` / `CALL` link support
- per-run collector logging
- API key kept outside Git, SQL, and screenshots

Current runtime:

```text
C:\Collector\Invoke-MddRealtimeCollector.ps1
C:\Collector\Run-MddRealtimeCollector.ps1
C:\Collector\Logs\
```

Repository collector source:

```text
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
