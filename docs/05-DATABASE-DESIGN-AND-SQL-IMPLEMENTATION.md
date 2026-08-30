# Database Design and SQL Server Implementation

## Purpose

This document records the SQL Server design, object responsibilities, execution order, validation approach, and the planned realtime extension. It explains both what has been implemented and why the design is defensible.

## Platform and Database

- Database engine: SQL Server 2022 Developer
- Administration: SQL Server Management Studio (SSMS)
- Reporting: Power BI Desktop
- Development host: Windows 11 virtual machine in VMware Fusion
- Database: `CologneTransitIntelligence`

The root repository remains on the MacBook and is shared with Windows. SQL Server runs inside Windows, so SQL file access and Git file access are different concerns. `BULK INSERT` paths must be readable by the SQL Server Database Engine, not merely visible in Finder or SSMS.

## Schema Contracts

| Schema | Responsibility | Reporting access |
|---|---|---|
| `ctl` | Load batches, status, counts, timestamps, and errors | Audit only |
| `stg` | Source-faithful static and realtime ingestion | No direct Power BI use |
| `wrk` | Typed, matched, normalized, and classified intermediate logic | Validation and development |
| `dw` | Validated dimensions, bridges, and facts | Stable analytical model |
| `analytics` | Business-readable reporting views | Power BI source |

The schema name `stg` is a fixed project decision. Realtime database stop observations use the fixed table name:

```sql
stg.DbRealtimeStopObservation
```

Future implementation must extend this contract rather than create an undocumented alternative such as a second realtime schema or similarly named duplicate table.

## Implemented Static Staging Tables

| Table | Source | Grain |
|---|---|---|
| `stg.GtfsAgency` | `agency.txt` | One source agency row |
| `stg.GtfsCalendar` | `calendar.txt` | One source service-calendar row |
| `stg.GtfsCalendarDates` | `calendar_dates.txt` | One source service-date exception row |
| `stg.GtfsFeedInfo` | `feed_info.txt` | One feed metadata row |
| `stg.GtfsFrequencies` | `frequencies.txt` | One frequency definition row |
| `stg.GtfsRoutes` | `routes.txt` | One source route row |
| `stg.GtfsShapes` | `shapes.txt` | One shape point |
| `stg.GtfsStopTimes` | `stop_times.txt` | One scheduled stop sequence for a trip pattern |
| `stg.GtfsStops` | `stops.txt` | One stop or parent-station row |
| `stg.GtfsTransfers` | `transfers.txt` | One transfer rule row |
| `stg.GtfsTrips` | `trips.txt` | One scheduled trip pattern |

Source identifiers use exact comparison rules and are not assumed unique until profiled. Raw rows are not silently deduplicated. The known duplicate route ID in the current regional snapshot is therefore preserved and resolved transparently downstream.

## Control Tables

### `ctl.GtfsLoadBatch`

Tracks the static GTFS source load, including feed version, coverage dates, start/completion timestamps, status, and error information. A batch moves from loading through loaded and finally validated only after source counts and integrity checks pass.

### `ctl.StaticWarehouseLoadBatch`

Tracks materialization of a validated GTFS load into the static warehouse. It records the source batch and counts for agencies, modes, routes, stops, services, dates, service-date pairs, trips, and scheduled stop events.

Control tables are not optional bookkeeping. They provide the evidence that a report came from a known and validated source snapshot.

## Working-Layer Views

| View | Grain | Main rule |
|---|---|---|
| `wrk.vwCologneStop` | One Cologne stop record | `stop_id` begins with `de:05315:` |
| `wrk.vwCologneServingRoute` | One Cologne-serving route ID | At least one trip serves a Cologne stop |
| `wrk.vwCologneServingTrip` | One Cologne-serving trip ID | At least one scheduled event is in Cologne |
| `wrk.vwCologneScheduledStopEvent` | One in-city trip/stop sequence | Typed GTFS service-day time |
| `wrk.vwCologneModeSummary` | One analytical mode | Reconciliation by derived category |

These remain views because their first responsibility is visibility and auditability. The warehouse materializes their validated result for performance.

## Static Warehouse Objects

| Object | Grain | Key design |
|---|---|---|
| `dw.DimAgency` | One Cologne-relevant agency | Surrogate `AgencyKey`, natural `AgencyId` |
| `dw.DimMode` | One analytical mode | Surrogate `ModeKey` |
| `dw.DimRoute` | One Cologne-serving route | Surrogate `RouteKey`, natural `RouteId` |
| `dw.DimStop` | One stop or parent station | Surrogate `StopKey`, natural `StopId` |
| `dw.DimService` | One GTFS service pattern | Surrogate `ServiceKey`, natural `ServiceId` |
| `dw.DimDate` | One feed calendar date | Integer date key |
| `dw.BridgeServiceDate` | One active service/date pair | Service and date foreign keys |
| `dw.FactScheduledTrip` | One GTFS trip pattern | Surrogate `TripKey`, natural `TripId` |
| `dw.FactScheduledStopEvent` | One in-city stop sequence of one trip pattern | Trip, stop, route, agency, mode, and service keys |

Natural GTFS identifiers remain available for lineage and GTFS-RT matching. Integer surrogate keys support compact relationships, foreign-key validation, and Power BI performance.

## Static Grain and Dated Occurrences

A GTFS `trip_id` is a schedule template, not proof that a vehicle operated. The calendar resolves the dates on which the pattern is scheduled.

```text
scheduled trip occurrence = trip_id + service date
scheduled stop occurrence = trip_id + service date + stop_sequence
```

Realtime matching must use the dated occurrence. Comparing an undated trip template to an observation would mix services from different days.

## GTFS Service-Day Time

GTFS permits values later than `24:00:00`. SQL Server `TIME` cannot preserve this operational meaning. The working and warehouse layers therefore retain the original text and derive seconds after service-day midnight.

```text
25:05:00 -> 90,300 service-day seconds
```

This representation allows a dated service occurrence to be constructed without incorrectly moving an after-midnight event to the wrong service day.

## Calendar Resolution

The warehouse first expands weekday rules from `calendar.txt`, then applies `calendar_dates.txt` exceptions:

- `exception_type = 1`: add the service on the date;
- `exception_type = 2`: remove the service on the date.

The result is stored in `dw.BridgeServiceDate`. This bridge is scheduled availability, not operational performance.

## Static Load Execution Order

Run the checked-in scripts in this order:

1. `sql/01-database/01-create-database-and-schemas.sql`
2. `sql/02-staging/01-create-gtfs-staging-tables.sql`
3. Set `@GtfsRoot` in `sql/02-staging/02-load-vrs-gtfs.sql` to the extracted Windows directory.
4. `sql/02-staging/02-load-vrs-gtfs.sql`
5. `sql/02-staging/03-create-staging-indexes.sql`
6. `sql/02-staging/04-validate-staging-load.sql`
7. `sql/03-working/01-create-cologne-working-layer.sql`
8. `sql/03-working/02-validate-cologne-working-layer.sql`
9. `sql/04-warehouse/00-configure-development-database.sql` for the local development database only.
10. `sql/04-warehouse/01-create-static-warehouse.sql`
11. `sql/04-warehouse/02-load-static-warehouse.sql`
12. `sql/04-warehouse/03-validate-static-warehouse.sql`
13. `sql/05-analytics/01-create-static-analytics-views.sql`
14. `sql/05-analytics/02-validate-static-analytics-views.sql`

The detailed component entrypoint remains [`sql/README.md`](../sql/README.md).

## SQL Server File-Access Rule

`BULK INSERT` executes under the Database Engine service account. A path visible through VMware Shared Folders may still be unreadable to the service. The reliable local workflow is:

1. Extract the GTFS archive outside Git.
2. Copy it to a Windows directory such as:

   ```text
   C:\Data\CologneTransitIntelligence\vrs_gtfs_static\YYYY-MM-DD\google_transit_goR\
   ```

3. Grant read access to the SQL Server service account, currently `NT Service\MSSQLSERVER` for the default instance.
4. Confirm access with `sys.dm_os_file_exists`.
5. Set `@GtfsRoot` to the exact extracted directory and execute the loader.

Neither the raw feed nor a machine-specific production credential belongs in Git.

## Transaction-Log Strategy

The local database uses `SIMPLE` recovery because the warehouse can be reproduced from source and the portfolio environment does not run transaction-log backups. This is a development decision, not a general production recommendation.

The 1.55-million-row scheduled stop-event fact is loaded in bounded batches. A single transaction previously exhausted the log because active log records could not be reused before commit. The implemented load:

1. rebuilds and commits dimensions, service dates, and trip patterns;
2. inserts scheduled stop events in groups of 5,000 trip keys;
3. commits and checkpoints between batches;
4. retains `Loading` status until all batches finish;
5. exposes the batch only after validation.

This controls log growth while keeping restart behavior explicit.

## Validation Strategy

Validation is performed at four boundaries:

### Staging

- source row counts match the independently profiled snapshot;
- required files and fields are present;
- duplicate identifiers are reported;
- trip, route, stop, agency, and calendar references are tested;
- Cologne scope counts reconcile.

### Working Layer

- stop coordinates are valid;
- Cologne stop, route, trip, and stop-event counts match the staging derivation;
- mode classifications are complete and unambiguous;
- duplicate derived identifiers are absent;
- scheduled seconds are valid.

### Warehouse

- every materialized object matches its validated working-layer source;
- surrogate and foreign keys resolve;
- service dates remain within the dimension range;
- routes, trips, stops, and modes reconcile;
- the load audit status becomes `Validated` only after success.

### Analytics

- view row counts match warehouse expectations;
- route, stop, station, mode, and daily-profile totals reconcile;
- scheduled trip occurrences by mode sum to the network total;
- active-date coverage matches the calendar bridge.

The current validated baseline is documented in [Static GTFS Warehouse Model](06-STATIC-GTFS-WAREHOUSE-MODEL.md) and [Static Analytics and Power BI Baseline](07-STATIC-ANALYTICS-AND-POWER-BI-BASELINE.md).

## Planned Realtime Staging Contract

Realtime implementation has not yet started. The following design records the agreed contract without claiming that the table or pipeline is already deployed.

### Table

```text
stg.DbRealtimeStopObservation
```

### Grain

One structured provider observation about one dated trip/stop event at one collector retrieval time.

This is an observation grain, not the final performance grain. Multiple rows may legitimately describe the same dated stop occurrence as estimates change.

### Required Information Categories

The physical column design should preserve at least:

| Category | Examples |
|---|---|
| Ingestion identity | observation key, load/collection batch, collected-at UTC |
| Source identity | provider, feed entity ID, payload/archive reference |
| Scheduled match | trip ID, route ID, stop ID, stop sequence, service date |
| Vehicle/service context | vehicle ID, direction, start time, schedule relationship |
| Event values | arrival/departure delay or timestamp, uncertainty |
| Operational state | cancellation, skipped stop, no-data state |
| Quality | parse status, match status, match method, validation message |
| Lineage | source timestamp, first-seen and last-seen information where appropriate |

Exact column names and types must be finalized from a real sanitized GTFS-RT payload, not invented from assumptions. The stable table and schema contract can be preserved while the source-specific mapping is validated.

## Realtime Matching and Consolidation

The intended exact key is:

```text
trip_id + service date + stop_sequence
```

`stop_id`, route, start time, direction, and vehicle may support fallback matching. Each result must be classified:

- exact;
- defensible fallback;
- ambiguous;
- unmatched.

Only accepted match classes enter reliability KPIs. Raw observations remain available for feed diagnostics.

The final analytical fact should contain one dated stop outcome after repeated observations are consolidated. A separate raw observation fact can support prediction evolution and feed-quality analysis.

## Planned Realtime Quality Controls

- collector retrieval succeeded and returned a parseable payload;
- source header timestamp and collector UTC timestamp are retained;
- feed age remains within an agreed threshold;
- collection gaps and duplicate payloads are measured;
- trip, stop, route, and service-date matches are classified;
- delay units and timestamp conversions are valid;
- cancelled and skipped states do not conflict with an observed completion;
- one final stop-performance outcome is produced per accepted dated occurrence;
- raw observation counts are never used directly as delayed-service counts.

## Credential Handling

Never store real credentials or connection strings in SQL, Markdown, PBIX, source-controlled configuration, or command history. Use environment variables or a local ignored secrets store:

```text
VRS_GTFS_RT_CLIENT_ID=<set outside Git>
VRS_GTFS_RT_API_KEY=<set outside Git>
DB_TIMETABLES_CLIENT_ID=<set outside Git>
DB_TIMETABLES_API_KEY=<set outside Git>
SQL_CONNECTION_STRING=<set outside Git>
```

Examples use placeholders only. The collector should fail clearly when a required variable is absent and must not print secret values to logs.

## Power BI Access Boundary

Power BI uses `analytics` views in Import mode for the current scheduled baseline. It does not read `stg`, raw observation tables, or unvalidated warehouse batches. Future realtime views must preserve the same rule: SQL owns ingestion, matching, grain, and quality; Power BI owns measures, interaction, and narrative.

## Current Validated Snapshot

| Metric | Validated value |
|---|---:|
| Agencies | 15 |
| Modes | 7 |
| Cologne-serving routes | 153 |
| Cologne stop records | 3,156 |
| Service patterns | 3,947 |
| Feed dates | 364 |
| Active service-date pairs | 99,399 |
| Scheduled trip patterns | 90,331 |
| Scheduled stop-event patterns | 1,551,343 |
| Scheduled trip occurrences | 1,878,944 |

These controls belong to feed version `VERSION__20260829_0050`. A new source snapshot should create a new documented baseline rather than force new data to match old counts.

## Defence Questions

### Why preserve source fields as text in staging?

Staging should not lose or reinterpret source information before validation. Typed values and business rules belong in the working layer, where failures and assumptions are visible.

### Why use surrogate keys if GTFS already has IDs?

Natural IDs are essential for lineage and realtime matching. Surrogate integer keys make joins, constraints, warehouse history, and Power BI relationships more efficient. The model keeps both because they solve different problems.

### Why materialize working views?

Working views make rules auditable but repeatedly scanning millions of stop-time rows is slow. Materialization creates a validated performance boundary while reconciliation proves the meaning did not change.

### Why not place realtime columns in `FactScheduledStopEvent`?

The scheduled fact represents a reusable timetable pattern; realtime data represents repeated observations and dated outcomes. Mixing the grains would duplicate schedule rows, overwrite history, and produce incorrect delay counts.

### Why is `stg.DbRealtimeStopObservation` not yet fully specified as SQL?

The schema/table contract and observation grain are fixed, but the physical fields must be validated against an actual sanitized provider payload. Documenting invented fields as implemented would be less defensible than separating confirmed decisions from pending source mapping.

### Why are the static counts called a baseline rather than performance?

They describe planned supply. Actual delay, cancellation, disruption, completion, and reliability require realtime evidence matched to a dated scheduled occurrence.
