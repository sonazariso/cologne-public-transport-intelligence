# SQL Server Implementation

**Last updated:** 2026-09-08

This directory contains the SQL Server implementation for the **Cologne Public Transport Intelligence** project.

The SQL model now covers two distinct phases:

1. a validated static GTFS warehouse and scheduled-service analytics baseline;
2. an active realtime engineering phase using MDD NRW / DELFI / TRIAS observations.

For realtime behavior and matching semantics, `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md` is the authoritative project document.

---

## Current Milestone

The static VRS/go.Rheinland GTFS snapshot has been loaded, reconciled, transformed, materialized, indexed, and validated.

The realtime phase now includes:

- source-faithful realtime staging tables;
- realtime stop-observation normalization;
- static stop enrichment;
- UTC -> Europe/Berlin normalization;
- GTFS service-day matching for times above 24:00;
- exact-stop and parent-station fallback matching;
- explicit static-coverage and unresolved statuses;
- situation/disruption evidence linking;
- automated PowerShell collection every five minutes in the local VM pilot;
- database-backed deterministic realtime sampling across a small multi-mode Cologne panel;
- one-row-per-execution Collector run auditing;
- SQL performance work for realtime stop enrichment and schedule candidate lookup.

The realtime operational fact and realtime `analytics` views are now implemented
and validated against the genuine current sample. The database is ready for
continued refresh while history accumulates; this does not start Power BI or
turn the current sample into final portfolio conclusions.

The project is now in the historical realtime collection phase. Historical
multi-target collection verified from: **2026-09-07 20:03:53 UTC**. The useful
history target is a minimum of 14 actual calendar days, with 28 days preferred.
The earliest corresponding milestone dates are 2026-09-21 and 2026-10-05;
neither target is complete until real calendar time and genuine observations
support it.

The live SQL Server baseline checked at 2026-09-08 10:42 UTC contains 1,193
stop observations across 239 snapshots and 4 UTC collection dates, spanning
2026-09-05 08:27:28 UTC through 2026-09-08 10:38:41 UTC. The maximum snapshot
gap remains 76,759 seconds. Preserved legacy Hbf-only history contributed 845
observations across 169 snapshots before the verified start. A live audit check
found 70 successful `Automatic` runs since the verified start, 0 failed runs,
and 0 stale or incomplete `Started` runs. All seven enabled targets have
participated in successful runs and have persisted observations. Missing periods
remain visible and are not backfilled.

---

## Current Checked-In SQL Execution Order

The checked-in scripts reproduce the validated static baseline and the synchronized realtime SQL objects in this order:

1. `01-database/01-create-database-and-schemas.sql`
2. `02-staging/01-create-gtfs-staging-tables.sql`
3. Edit `@GtfsRoot` in `02-staging/02-load-vrs-gtfs.sql`
4. `02-staging/02-load-vrs-gtfs.sql`
5. `02-staging/03-create-staging-indexes.sql`
6. `02-staging/04-validate-staging-load.sql`
7. `03-working/01-create-cologne-working-layer.sql`
8. `03-working/02-validate-cologne-working-layer.sql`
9. `04-warehouse/00-configure-development-database.sql` — local development only
10. `04-warehouse/01-create-static-warehouse.sql`
11. `04-warehouse/02-load-static-warehouse.sql`
12. `04-warehouse/03-validate-static-warehouse.sql`
13. `05-analytics/01-create-static-analytics-views.sql`
14. `05-analytics/02-validate-static-analytics-views.sql`
15. `02-staging/05-create-mdd-realtime-staging-tables.sql`
16. `02-staging/06-create-mdd-realtime-persistence-api.sql`
17. `02-staging/07-create-mdd-realtime-sampling.sql`
18. `02-staging/09-create-mdd-collector-run-audit.sql`
19. `04-warehouse/04-add-realtime-match-performance-support.sql`
20. `03-working/03-create-cologne-realtime-working-layer.sql`
21. `02-staging/08-validate-mdd-realtime-sampling.sql` — focused sampling report after the warehouse and realtime objects exist
22. `02-staging/10-validate-mdd-collector-run-audit.sql` — focused Collector run audit report
23. `02-staging/11-validate-realtime-collection-health.sql` — read-only historical collection-health report
24. `04-warehouse/05-create-operational-stop-outcome.sql`
25. `04-warehouse/06-refresh-operational-stop-outcome.sql`
26. `04-warehouse/07-validate-operational-stop-outcome.sql`
27. `05-analytics/03-create-realtime-analytics-views.sql`
28. `05-analytics/04-validate-realtime-analytics-views.sql`

The realtime steps are listed after the static warehouse and analytics steps so every dependency of the realtime working views exists before those views are created. The folder numbering remains organized by schema/layer rather than by this global dependency order.

---

## Synchronized Realtime SQL

The repository now contains reproducible SQL for the validated realtime
structures, Collector run audit, operational outcome fact, analytics views, and
performance changes:

### Realtime staging

- `stg.MddRealtimeStopObservation`
- `stg.MddRealtimeSituationObservation`
- `stg.MddRealtimeStopSituationLink`

Validated staging indexes:

- `UX_MddRealtimeStopObservation_ObservedAt_ResultId`
- `UX_MddRealtimeSituationObservation_Snapshot`

### Realtime persistence API

`02-staging/06-create-mdd-realtime-persistence-api.sql` creates the three
source-oriented TVP types and `stg.uspPersistMddRealtimeSnapshot`. The
PowerShell Collector sends one parsed snapshot through that procedure. The
procedure owns one `SET XACT_ABORT ON` transaction, performs set-based
append-only inserts and source-identity link resolution, and returns insert,
already-present, and unresolved-link counts. Existing realtime unique indexes,
primary keys, and foreign keys remain the idempotency and relationship
constraints.

### Deterministic realtime sampling

`02-staging/07-create-mdd-realtime-sampling.sql` creates the persistent `ctl`
configuration and seeds seven current parent-station `StopPointRef` targets.
`ctl.uspGetMddRealtimeSamplingTarget` resolves a five-minute UTC bucket against
the enabled slot table, so the Collector selects the same target after a
PowerShell or Windows restart and does not replay missed buckets. The ten-slot
cycle gives Köln Hbf, Köln Bf Mülheim, and Köln Heumarkt two slots each; the
other four targets receive one slot each. At the unchanged five-minute cadence
this is an average 25-minute interval for two-slot targets and 50 minutes for
one-slot targets, while each normal execution still makes one logical TRIAS
request.

The target panel was selected from the live static warehouse rather than from
names alone. It covers `Stadtbahn / Tram`, `S-Bahn`, `Regional Express (RE)`,
`Regional Bahn (RB)`, `Urban Bus (KVB)`, and `Regional / Other Bus`; SEV is
retained as opportunistic static context rather than a required target mode.
`02-staging/08-validate-mdd-realtime-sampling.sql` reports target identity,
slot frequency, warehouse mode/route coverage, geography, realtime counts, and
a simulated deterministic rotation without creating reliability KPIs.

### Collector run audit

`02-staging/09-create-mdd-collector-run-audit.sql` creates the operational
control table `ctl.MddCollectorRun` and the procedures
`ctl.uspStartMddCollectorRun` and `ctl.uspCompleteMddCollectorRun`. Its grain
is exactly one row per Collector execution; it does not add a run key to the
realtime observation, situation, or link tables.

The Collector creates a `Started` row before sampling, authentication, HTTP,
parsing, or snapshot persistence. On a normal completion it updates that same
row to `Succeeded` with the resolved sampling context, HTTP telemetry, parsed
source counts, and the statistics returned by
`stg.uspPersistMddRealtimeSnapshot`. A failure updates the row to `Failed`,
records the simple stage in `ErrorCategory`, and stores only a redacted safe
error message plus information obtained before the failure. An abruptly
terminated process can leave the row in `Started`, which is evidence of an
incomplete execution rather than a success or an inferred failure. A valid
response with little or no returned data remains `Succeeded`; the recorded
source and persistence counts distinguish that case from a failure.

If SQL Server is unavailable before the start procedure can insert the row,
no database audit row can exist; the existing Collector wrapper/file log and
exit-code behavior remain the fallback evidence for that case. API keys,
authorization headers, passwords, and connection-string credentials are not
stored in the audit table.

`02-staging/11-validate-realtime-collection-health.sql` is the focused
read-only report for the historical collection phase. It reports the actual
observation range and daily/hourly coverage, configured-target participation,
snapshot gaps against the expected five-minute cadence, Collector run status
and source counts, stale `Started` rows, and the existing matching-status
distribution. It does not create analytics objects or fabricate missing
history.

### Realtime working views

- `wrk.vwCologneRealtimeStopObservation`
- `wrk.vwCologneRealtimeStopEnriched`
- `wrk.vwCologneRealtimeTripMatchKey`
- `wrk.vwCologneRealtimeTripMatch`
- `wrk.vwCologneRealtimeEvidenceSituation`

### Realtime operational fact and refresh

`04-warehouse/05-create-operational-stop-outcome.sql` creates
`dw.FactOperationalStopOutcome` at the grain of one matched scheduled stop
event on one GTFS service date. Its lineage and business fields retain first
and last source observations, deterministic observation counts, estimated
arrival/delay fields, conservative platform evidence, and situation-link
evidence without duplicating dimension text.

`04-warehouse/06-refresh-operational-stop-outcome.sql` creates the idempotent
`dw.uspRefreshFactOperationalStopOutcome` procedure. It orders contributing
rows by `ObservedAtUtc`, then `ObservationKey`; inserts new outcomes and
updates existing outcomes when the consolidated state changes. It never
truncates or deletes append-only realtime staging history. Only
`ExactStopMatch` and `ParentStationFallback` are eligible for the fact;
`StaticCoverageMissing` and `Unresolved` remain available to Data Quality /
Coverage analytics.

`04-warehouse/07-validate-operational-stop-outcome.sql` checks the unique
dated operational grain, warehouse lineage/foreign keys, consolidation
examples, platform Unknown semantics, situation-link counts, usable-match
eligibility, and repeatability using the current genuine source rows.

### Realtime analytics views

`05-analytics/03-create-realtime-analytics-views.sql` creates:

- `analytics.vwRealtimeCollectorRunHealth`
- `analytics.vwRealtimeDataQualityCoverage`
- `analytics.vwRealtimeOperationalConsolidationQuality`
- `analytics.vwRealtimeReliabilityOutcome`
- `analytics.vwRealtimeReliabilityByDimension`
- `analytics.vwRealtimeDelayHotspot`
- `analytics.vwRealtimePlatformChangeEvidence`
- `analytics.vwRealtimeSituationLinkedOutcome`

The views expose Collector health, sampling-panel participation, all four
match statuses, usable-match rates, observation consolidation, platform
availability, situation evidence, and continuous observed estimated-delay
metrics (average, median, and P95) by date, route, stop, mode, and scheduled
hour. They do not apply an arbitrary On-Time threshold and do not infer
cancellation, departure, or causal disruption effects. The seven targets are a
sampling panel, not complete Cologne network coverage.

`05-analytics/04-validate-realtime-analytics-views.sql` is the read-only
analytics validation report. The 14/28-day period remains useful for stronger
historical interpretation, but it is not required to create or validate these
database objects.

### Realtime performance support

1. Optimized `wrk.vwCologneRealtimeStopEnriched` definition
2. Persisted computed column: `dw.FactScheduledStopEvent.ScheduledArrivalSecondOfDay`
3. Nonclustered index: `IX_FactScheduledStopEvent_RealtimeMatch`

`wrk.vwCologneRealtimeTripMatch` now resolves static candidates directly from the warehouse schedule model and no longer uses `wrk.vwCologneScheduledStopEvent` for candidate search. The focused validation script `03-working/04-validate-realtime-trip-match-rewrite.sql` freezes observation keys, captures the production baseline, compares critical and complete output rows, and checks grain/cardinality before a deployment change.

---

## Database Schemas

| Schema | Responsibility |
|---|---|
| `ctl` | load/audit/control metadata |
| `stg` | source-faithful static and realtime staging |
| `wrk` | typing, normalization, matching, derived logic |
| `dw` | validated dimensions, bridges, facts |
| `analytics` | business-facing Power BI datasets |

---

## Important: Static GTFS Source Path

`BULK INSERT` reads files from the machine or container running the SQL Server Database Engine, not from the computer running SSMS.

The extracted feed is maintained outside Git.

For the current Windows SQL Server development environment, use a SQL Server service-readable local path such as:

```text
C:\Data\CologneTransitIntelligence\vrs_gtfs_static\2026-08-29\
```

VMware shared-folder visibility to the interactive Windows user does **not** prove that the SQL Server service account can read the same path.

Before loading:

- confirm the exact GTFS root;
- confirm every required file exists;
- confirm SQL Server service-account read access;
- never commit raw GTFS files or credentials to GitHub.

---

## Compatibility

Current development database engine:

```text
SQL Server 2025 Developer
```

The static loader uses `FORMAT = 'CSV'` and requires SQL Server 2017 or later.

Current project database:

```text
CologneTransitIntelligence
```

---

## Staging Design Rules

- Preserve source rows without silent deduplication.
- Do not assume source identifiers are unique until validated.
- Keep GTFS identifiers under exact/binary matching semantics where required.
- The current static staging layer represents one replaceable GTFS feed snapshot.
- `ctl.GtfsStagingState` records the single `ctl.GtfsLoadBatch` that owns that snapshot; the loader updates the pointer in the same transaction as the staging replacement.
- Validation and warehouse loading use that pointer exactly. A warehouse load is refused unless the current pointer targets a `Validated` batch; it never falls back to an older validated batch.
- Historical static feed retention is handled outside the current staging tables.
- Realtime snapshots are append-only observations, not replacements of static data.
- Realtime staging stores source-aligned values; derived delays and matching logic belong in `wrk`.
- API keys and secrets never belong in SQL scripts or staging tables.

---

## Working-Layer Design Rules

### Static

- Cologne stop scope uses the global stop-ID prefix `de:05315:`.
- A trip or route is included when it serves at least one Cologne stop.
- Operator identity is not used as the city-boundary rule.
- Original GTFS route types remain visible beside analytical mode classification.
- S-Bahn, RE, RB, ordinary buses, and SEV remain distinct.
- GTFS times are converted to seconds after service-day midnight so values above `24:00:00` remain valid.

### Realtime

- TRIAS timestamps are normalized from UTC to Berlin local time in `wrk`.
- SQL Server timezone conversion uses `W. Europe Standard Time`.
- `JourneyRef` is not assumed equal to GTFS `TripId`.
- `LineRef` is not assumed equal to GTFS `RouteId`.
- Line-name normalization currently removes spaces for controlled comparison.
- Matching uses line, local scheduled time, active service date, and stop hierarchy.
- Exact `StopId` matching is preferred.
- A unique parent-station fallback is allowed only when exact-stop matching does not resolve.
- Coverage gaps and unresolved matches remain explicitly separate.
- Missing estimated arrival remains NULL and does not produce a derived delay.
- Missing estimated bay remains NULL and does not mean "platform unchanged".
- Situation linkage is evidence, not automatically confirmed causality.
- Cancellation/departure semantics must not be invented without real validated TRIAS examples.

---

## Realtime Match Status Contract

Current production statuses:

```text
StaticCoverageMissing
ExactStopMatch
ParentStationFallback
Unresolved
```

Usable static matches:

```text
ExactStopMatch
ParentStationFallback
```

`StaticCoverageMissing` is a source-coverage limitation.

`Unresolved` means static coverage exists but the available evidence does not produce one defensible candidate.

---

## Warehouse Design Rules

- Every dimension and fact has an explicitly documented grain.
- GTFS natural IDs are retained for lineage and realtime matching.
- Integer surrogate keys support SQL Server and Power BI relationships.
- `calendar.txt` and `calendar_dates.txt` are resolved into active service-date pairs.
- A GTFS `TripId` is a schedule pattern, not automatically a dated physical service.
- Realtime observations must never overwrite the scheduled baseline.
- Repeated realtime predictions must not later be counted as repeated services.
- `dw.FactOperationalStopOutcome` is the validated dated operational outcome;
  repeated realtime predictions are consolidated and are not counted as
  repeated services.

---

## Realtime Performance Optimization

### 1. Static stop enrichment

The original realtime stop-enrichment path rebuilt a distinct static stop map from:

```text
wrk.vwCologneScheduledStopEvent
```

which represents approximately:

```text
1,551,343 scheduled stop-event patterns
```

This produced approximately 2,287 used-stop rows but cost several seconds per realtime query.

The replacement uses:

- `dw.DimStop`
- `EXISTS` against `dw.FactScheduledStopEvent`

Semantic comparison before altering the production view returned:

```text
DifferenceCount = 0
```

Observed benchmark on the engineering sample:

```text
before: ~6.9 seconds
after:  effectively immediate for the tested projection
```

### 2. Indexed realtime schedule lookup

A persisted computed column was added to:

```text
dw.FactScheduledStopEvent
```

Column:

```text
ScheduledArrivalSecondOfDay
```

Definition:

```text
ScheduledArrivalSeconds - (ArrivalDayOffset * 86400)
```

This preserves the GTFS service-day offset separately while providing an index-searchable local seconds-of-day value.

Targeted index:

```text
IX_FactScheduledStopEvent_RealtimeMatch
```

Key columns:

```text
RouteKey
ScheduledArrivalSecondOfDay
```

Included columns:

```text
ArrivalDayOffset
ServiceKey
StopKey
TripKey
```

Validated engineering benchmark:

```text
route/time schedule lookup before index:
CPU ~328 ms
elapsed ~1647 ms

after index:
CPU ~16 ms
elapsed ~4 ms

with active service-date validation:
CPU ~15 ms
elapsed ~17 ms
```

These are local engineering measurements, not production SLA commitments.

---

## Current Trip-Matching Performance Checkpoint

`wrk.vwCologneRealtimeTripMatch` now uses the warehouse-direct candidate path while preserving the previously validated production semantics.

Validation on a frozen 450-observation scope returned `DifferenceCount = 0` in both directions for the seven critical matching fields and for the complete 32-column output, with identical row grain/cardinality. The same frozen baseline was rechecked against the altered production view with zero critical/full differences. Status counts were 145 `ExactStopMatch`, 27 `ParentStationFallback`, and 278 `StaticCoverageMissing`.

The paired materialization benchmark was approximately 494.9 seconds for the production baseline versus 3.6 seconds for the direct implementation. A final live forced-field projection returned 530 rows in approximately 1.6 seconds, and its plan used `IX_FactScheduledStopEvent_RealtimeMatch`.

---

## Analytics-Layer Design Rules

- Analytics views expose business-readable datasets.
- Pattern counts and dated occurrence counts must remain explicit.
- Parent stations and physical stop positions are separate reporting grains.
- The current Power BI report is a scheduled baseline, not a reliability report.
- Power BI must not read raw realtime staging directly.
- Realtime reliability views consume the validated dated operational outcome;
  they expose continuous observed estimated-delay metrics and do not create an
  arbitrary `OnTimeRate`.

---

## Collector Boundary

The realtime collector source is maintained outside the SQL directory:

```text
collector/MddRealtimeCollector.psm1
collector/Invoke-MddRealtimeCollector.ps1
collector/Run-MddRealtimeCollector.ps1
```

Runtime on Windows:

```text
C:\Collector
```

Logs:

```text
C:\Collector\Logs
```

The collector currently runs through Windows Task Scheduler every five minutes while the local VM/user context is available.

The entry point imports the Windows PowerShell 5.1-compatible module. HTTP
requests use a configurable 30-second timeout, up to three attempts, and
bounded transient retry backoff. Retryable HTTP statuses are 408, 429, 500,
502, 503, and 504; retryable transport timeouts and temporary WebExceptions
are also covered. `Retry-After` seconds or HTTP-date values are honored up to
the 30-second retry-delay cap by default. Per-run output reports actual HTTP
attempts.

Parsed stop observations, identifiable situations, and source SERVICE/CALL
links are constructed as typed TVPs and persisted with one call to
`stg.uspPersistMddRealtimeSnapshot`.

Each execution also reports its `CollectorRunId` in the normal success summary
and module result, and completes the matching `ctl.MddCollectorRun` audit row.

Collector source, runtime behavior, permission status, and realtime matching details are documented in:

```text
docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md
```

---

## Security

Never commit:

- MDD API keys;
- database credentials;
- raw GTFS source files;
- collector runtime logs containing sensitive values;
- local secret configuration.

Current `MDD_API_KEY` runtime configuration is external to SQL and source code.

---

## Historical Collection Health

Use `02-staging/11-validate-realtime-collection-health.sql` as the focused
read-only collection report. It keeps the actual date range, daily/hourly
coverage, enabled-target participation, five-minute snapshot gaps, Collector
run status/source counts, stale `Started` rows, and current matching-status
distribution visible without creating realtime analytics objects or filling
missing history.

The repository-managed Collector audit objects are deployed and the three
runtime files under `C:\Collector` match the repository source by SHA-256. The
existing `C:\Collector\Logs` directory was preserved. Task Scheduler history
shows `Cologne Transit Realtime Collector` running as
`DATAANALYST-VM\Somaye` every five minutes with return code 0, and the two
successful wrapper logs prove that the scheduled runtime can read the external
`MDD_API_KEY` without storing or exposing it.

The project was originally NRW-wide and included a separate Deutsche-Bahn
multi-station runtime. The user has already manually disabled the legacy
`\NRW DB Realtime Collector`. Windows Scheduled Task management is outside the
scope of this SQL implementation; the old NRW runtime is not inspected,
modified, or reused here. The current MDD/TRIAS Collector continues
independently and its SQL audit rows remain available through the realtime
health views.
