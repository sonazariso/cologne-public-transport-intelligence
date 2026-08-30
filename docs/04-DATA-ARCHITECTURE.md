# Data Architecture

## Purpose

This document explains how Cologne Public Transport Intelligence moves from source data to defensible management information. It separates source preservation, transformation, analytical modeling, reporting, and interpretation so that every KPI can be traced back to evidence.

The architecture supports the complete target journey:

```text
Scheduled data + realtime observations + disruption context
                         |
                         v
              ingestion and source audit
                         |
                         v
         source-faithful staging (`stg`)
                         |
                         v
       transparent transformation (`wrk`)
                         |
                         v
        validated analytical warehouse (`dw`)
                         |
                         v
        business-facing views (`analytics`)
                         |
                         v
                 Power BI model
                         |
                         v
  problem -> evidence -> likely cause -> impact -> recommendation
```

## Current Stage and Target Stage

The project currently has a validated static GTFS pipeline. It can describe scheduled network coverage, modes, routes, stops, stations, calendars, and planned service volume. It cannot yet claim that a service was late, cancelled, disrupted, or completed.

The target architecture adds independently collected realtime data and disruption context, matches dated observations to the scheduled baseline, consolidates repeated predictions, and exposes reliability facts to Power BI. This separation prevents planned service from being mistaken for actual performance.

## Source Architecture

### Static VRS GTFS

The VRS/go.Rheinland GTFS feed is the schedule system of record for the initial multimodal Cologne scope. It provides agencies, routes, trips, stops, stop times, service calendars, exceptions, transfers, shapes, and feed metadata.

It establishes what should operate. Raw extracts remain outside Git because they are large, replaceable source files. The repository stores profiling results, schema definitions, loaders, validation rules, and documentation instead.

### VRS GTFS Realtime

VRS GTFS-RT is the intended operational source for urban and regional services where the feed supplies trip updates, stop-time predictions, vehicle positions, or service alerts. Access has been requested, but ingestion is not yet implemented or validated.

Realtime messages are snapshots. The same trip and stop may appear repeatedly as a prediction changes. Therefore a snapshot is an observation, not a separate trip, delay, or incident.

### DB Timetables API

The DB Timetables API is a separate candidate source for railway planned and changed arrivals/departures, cancellations, and platform changes. It must remain a distinct ingestion stream because its identifiers, message semantics, refresh behavior, and coverage differ from GTFS-RT.

### Disruption and Context Sources

Service alerts, construction notices, infrastructure outages, platform changes, and other operational messages may later contribute explanatory evidence. They must not be treated as proven causes merely because their time and location overlap with a delay. The analytical output must distinguish observed facts, associations, likely contributing factors, and unknown causes.

## Layer Responsibilities

### `ctl` — Control and Audit

The control layer records load identity, source version, timestamps, status, row counts, and errors. A dataset is available to downstream consumers only after reconciliation and validation. Existing examples are `ctl.GtfsLoadBatch` and `ctl.StaticWarehouseLoadBatch`.

This layer answers:

- Which source snapshot produced these rows?
- When did the load start and finish?
- Did the run load, fail, or validate?
- How many rows were expected and written?
- Can a Power BI refresh safely consume this batch?

### `stg` — Source-Faithful Staging

The staging schema preserves source values with minimal interpretation. Static GTFS tables retain the published identifiers and text. Realtime database observations use the fixed staging table name:

```text
stg.DbRealtimeStopObservation
```

The table name is a stabilized project decision and must not be replaced with an alternative schema or duplicate staging table without an explicit migration decision.

Staging is intentionally not a reporting layer. It may contain repeated snapshots, incomplete source fields, provider-specific codes, and source text that still requires normalization.

### `wrk` — Transparent Working Layer

The working layer applies reproducible business rules while preserving lineage. Current views identify Cologne stops, Cologne-serving routes and trips, scheduled stop events, and analytical transport categories.

The working layer is where future realtime logic should:

- parse and normalize source timestamps;
- resolve service dates and time zones;
- match provider identifiers to GTFS identifiers;
- retain unmatched records for investigation;
- distinguish prediction, observation, cancellation, and skipped-stop states;
- classify alerts and disruption evidence;
- calculate candidate delay values without yet presenting management KPIs.

### `dw` — Validated Analytical Warehouse

The warehouse materializes stable dimensions, bridges, and facts with explicit grains. Static dimensions retain GTFS natural IDs for lineage and use integer surrogate keys for efficient SQL and Power BI relationships.

Realtime extensions must add facts rather than overwrite the scheduled facts. This preserves the difference between:

```text
what was scheduled
what the source reported at a point in time
what was finally observed or inferred
```

### `analytics` — Business-Readable Views

The analytics schema presents small, named datasets with defined meanings. The current views expose only scheduled supply. Future reliability views must be based on consolidated dated operational events, not raw snapshot counts.

### Power BI — Semantic and Decision Layer

Power BI supplies measures, filters, visual narrative, and decision support. Transformations that define city scope, transport mode, matching, or reliability should remain in SQL so they are testable and reusable. DAX should focus on analytical measures rather than repairing source data.

## Static Data Flow Already Implemented

```text
VRS GTFS text files
        |
        v
stg.Gtfs* tables
        |
        v
wrk.vwCologneStop
wrk.vwCologneServingRoute
wrk.vwCologneServingTrip
wrk.vwCologneScheduledStopEvent
wrk.vwCologneModeSummary
        |
        v
dw dimensions, service-date bridge,
scheduled-trip and scheduled-stop-event facts
        |
        v
analytics scheduled-baseline views
        |
        v
Power BI scheduled baseline
```

At each boundary, row-count reconciliation and integrity checks protect the analytical scope. The validated warehouse batch is the only safe input to the analytics layer.

## Target Realtime Data Flow

```text
VRS GTFS-RT / DB realtime endpoint
        |
        v
collector with UTC collection timestamp
        |
        v
source payload archive outside Git
        |
        v
stg.DbRealtimeStopObservation
        |
        v
working normalization and GTFS matching
        |
        +----> unmatched-record quality queue
        |
        v
raw observation facts
        |
        v
consolidated trip/stop performance facts
        |
        +----> alert and disruption evidence
        |
        v
analytics reliability and cause-association views
        |
        v
Power BI reliability, hotspots, causes, and recommendations
```

The collector must timestamp every retrieval independently of provider timestamps. Raw payload retention makes parser changes auditable, while the database table supports structured matching and analysis.

## Matching Strategy

The strongest GTFS-RT stop-event key is expected to be:

```text
trip_id + service date + stop_sequence
```

Depending on source completeness, `stop_id`, route, direction, start time, and vehicle identifiers may provide supporting evidence. Matches must receive an explicit quality status such as exact, fallback, ambiguous, or unmatched. Ambiguous records must not silently enter punctuality KPIs.

GTFS times can exceed `24:00:00`; they are stored as seconds after service-day midnight. Realtime timestamps must be normalized to the same service-day interpretation before delay is calculated.

## Observation Versus Outcome

A feed collected every interval can report many predictions for one stop occurrence. The architecture preserves both grains:

| Dataset | Grain | Use |
|---|---|---|
| Raw realtime observation | One source report for one trip/stop at one collection time | Feed quality and prediction evolution |
| Consolidated stop performance | One dated trip-stop occurrence | Delay and cancellation KPIs |
| Consolidated trip performance | One dated trip occurrence | Route and trip reliability |
| Alert/disruption evidence | One normalized message or affected entity/time interval | Cause-association analysis |

This prevents a frequently updated delayed trip from being counted as many delayed trips.

## Security and Configuration

Secrets never belong in Git, Markdown examples, SQL scripts, PBIX files, or screenshots. Runtime configuration must use placeholders or environment variables, for example:

```text
VRS_GTFS_RT_CLIENT_ID
VRS_GTFS_RT_API_KEY
DB_TIMETABLES_CLIENT_ID
DB_TIMETABLES_API_KEY
SQL_CONNECTION_STRING
```

Local `.env` or secrets files must be ignored. Documentation may show variable names but never real values. Database permissions should follow least privilege: the collector writes staging data, ETL procedures transform it, and Power BI reads validated analytics views.

## Reliability, Restartability, and Auditability

- Every run receives a batch or collection identity.
- Source version and collection time are retained.
- UTC is used for audit timestamps; local service time retains the `Europe/Berlin` interpretation.
- Loads are idempotent or explicitly replaceable at their documented grain.
- Partial failures do not become validated reporting data.
- Large writes are committed in bounded batches to control transaction-log growth.
- Raw and transformed counts are reconciled.
- Unmatched and malformed records remain measurable rather than disappearing.
- Power BI reads validated views, not raw staging tables.

## Data Quality Gates

The pipeline should not advance when critical checks fail. Required controls include:

- source availability and parse success;
- expected file or entity presence;
- natural-key duplication analysis;
- referential integrity between routes, trips, stops, and calendars;
- valid coordinates and service-day times;
- Cologne-scope reconciliation;
- mode-classification completeness;
- feed age and collection-gap monitoring;
- exact/fallback/unmatched realtime-match rates;
- duplicate snapshot detection;
- cancellation and skipped-stop consistency;
- warehouse-to-analytics row reconciliation.

## Root-Cause Evidence Boundary

The architecture supports root-cause investigation but does not manufacture causality. A defensible chain is:

```text
observed performance problem
        +
time/location/entity overlap with an alert or event
        +
repeated pattern or operational context
        =
documented association or likely contributing factor
```

A cause may be called confirmed only when the source explicitly provides reliable causal information or an independent operational record verifies it. Otherwise the correct category is likely, associated, or unknown/insufficient evidence.

## Deployment Context

Development currently runs on Windows 11 in VMware Fusion on the MacBook. SQL Server 2022 Developer, SSMS, and Power BI Desktop run in Windows. The repository and large source files are available through controlled shared folders, but SQL Server `BULK INSERT` requires a Windows path readable by the SQL Server Database Engine service account.

This local topology is suitable for portfolio development. It does not imply a production SLA, public cloud deployment, or realtime control-room system.

## Defence Questions

### Why use several schemas instead of one collection of tables?

Each schema establishes a trust boundary. Staging preserves the source, working objects explain transformation, the warehouse enforces analytical grain and relationships, and analytics views expose business meaning. This makes errors easier to locate and prevents Power BI from becoming an undocumented ETL layer.

### Why keep static and realtime data separate?

Static GTFS is a plan; realtime messages are changing observations about dated operations. Overwriting one with the other destroys lineage and makes it impossible to distinguish schedule design from operational execution.

### Why preserve every realtime snapshot?

Snapshots show how predictions evolve and allow feed-quality analysis. Management KPIs use a consolidated outcome, so preservation does not imply counting every snapshot as a separate service.

### Why is the database table fixed as `stg.DbRealtimeStopObservation`?

It is the agreed integration contract for database realtime stop observations. A stable name prevents collectors, validation scripts, ETL logic, and documentation from drifting toward multiple competing tables.

### Why are secrets represented only by environment-variable names?

Credentials change independently of code and documentation. External configuration avoids accidental Git exposure and allows development, test, and future production environments to use different values safely.
