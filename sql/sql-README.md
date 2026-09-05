# SQL Server Implementation

**Last updated:** 2026-09-05

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
- SQL performance work for realtime stop enrichment and schedule candidate lookup.

The final realtime warehouse fact and realtime `analytics` views are **not yet approved**.

---

## Current Checked-In Static SQL Execution Order

The currently checked-in SQL scripts reproduce the validated static baseline in this order:

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

The realtime database objects and the latest realtime performance changes were validated interactively during the realtime implementation phase and must be synchronized into reproducible checked-in SQL scripts before the realtime SQL execution order is declared complete.

---

## Important Reproducibility Gap — Realtime SQL

As of 2026-09-05, the local database contains validated realtime structures and performance changes that are newer than the checked-in static SQL script set.

The repository SQL must next be updated to reproduce at least these already-applied database changes:

### Realtime staging

- `stg.MddRealtimeStopObservation`
- `stg.MddRealtimeSituationObservation`
- `stg.MddRealtimeStopSituationLink`

### Realtime working views

- `wrk.vwCologneRealtimeStopObservation`
- `wrk.vwCologneRealtimeStopEnriched`
- `wrk.vwCologneRealtimeTripMatchKey`
- `wrk.vwCologneRealtimeTripMatch`
- `wrk.vwCologneRealtimeEvidenceSituation`

### Realtime performance changes already applied locally

1. Optimized `wrk.vwCologneRealtimeStopEnriched`
2. Persisted computed column: `dw.FactScheduledStopEvent.ScheduledArrivalSecondOfDay`
3. Nonclustered index: `IX_FactScheduledStopEvent_RealtimeMatch`

The next development session should synchronize these changes into repository SQL before making further production-view changes.

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
- Final realtime facts will be introduced only after the dated operational grain is validated.

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

`wrk.vwCologneRealtimeTripMatch` still uses the previously validated production semantics.

A warehouse-direct rewrite is under investigation because materializing candidate counts and matched IDs through the older scheduled-stop-event path is expensive.

Do **not** replace the production view merely because the warehouse-direct path is faster.

Required validation order:

1. complete the warehouse-direct matching prototype;
2. benchmark it;
3. compare output row-by-row with the current production view;
4. validate:
   - `ExactStopCandidateCount`
   - `ParentStationCandidateCount`
   - `MatchStatus`
   - `MatchedTripId`
   - `MatchedRouteId`
   - `MatchedServiceId`
   - `MatchedStaticStopId`
5. alter the production view only after semantic equivalence is proven.

---

## Analytics-Layer Design Rules

- Analytics views expose business-readable datasets.
- Pattern counts and dated occurrence counts must remain explicit.
- Parent stations and physical stop positions are separate reporting grains.
- The current Power BI report is a scheduled baseline, not a reliability report.
- Power BI must not read raw realtime staging directly.
- Realtime reliability views should be created only after repeated observations are consolidated into validated dated operational outcomes.

---

## Collector Boundary

The realtime collector source is maintained outside the SQL directory:

```text
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

## Next SQL Repository Step

Before further production matching changes, update the checked-in SQL scripts so a fresh database build can reproduce the realtime structures and the validated performance changes already present in the local database.

That reproducibility step should happen **before** replacing `wrk.vwCologneRealtimeTripMatch`.
