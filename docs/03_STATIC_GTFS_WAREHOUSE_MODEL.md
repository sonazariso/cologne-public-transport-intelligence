# Static GTFS Analytical Warehouse Model

## Purpose

The static warehouse converts transparent working-layer rules into indexed physical tables suitable for repeatable analysis and Power BI. It is the scheduled-service baseline to which realtime observations will later be matched.

## Why Materialize the Working Views

The working views intentionally expose every rule and are valuable for validation. Recalculating them repeatedly over 3.8 million source stop-time rows is inefficient for interactive reporting; the complete working-layer validation took approximately four minutes on the development VM.

The warehouse therefore materializes the validated result once and adds surrogate keys, foreign keys, uniqueness constraints, and reporting indexes. This creates a controlled performance boundary without changing the raw source or hiding the transformation logic.

## Grain Before Tables

The grain states exactly what one row represents. Defining it first prevents ambiguous counts and double counting.

| Object | Grain |
|---|---|
| `dw.DimAgency` | One Cologne-relevant GTFS agency |
| `dw.DimMode` | One analytical transport category |
| `dw.DimRoute` | One Cologne-serving GTFS route ID |
| `dw.DimStop` | One Cologne stop or parent-station record |
| `dw.DimService` | One GTFS service-calendar pattern |
| `dw.DimDate` | One calendar date in the feed range |
| `dw.BridgeServiceDate` | One active service pattern on one date |
| `dw.FactScheduledTrip` | One scheduled GTFS trip pattern |
| `dw.FactScheduledStopEvent` | One scheduled stop sequence of one trip pattern inside Cologne |

## Trip Pattern Is Not Trip Occurrence

A GTFS `trip_id` describes a timetable pattern associated with a `service_id`. It does not by itself mean that a physical vehicle completed the trip on every date in the feed.

For the current Cologne scope:

- Scheduled trip patterns: 90,331
- Relevant service patterns: 3,947
- Active service-date pairs after exceptions: 99,399

The service calendar and its exceptions determine on which dates a trip pattern is scheduled to operate. Later, an operational trip occurrence will be identified by at least:

```text
trip_id + service date
```

and a stop occurrence by:

```text
trip_id + service date + stop_sequence
```

This key strategy is compatible with later GTFS Realtime matching.

## Calendar Logic

The active service-date bridge is built in two steps:

1. Generate dates allowed by `calendar.txt` weekday flags and start/end dates.
2. Apply `calendar_dates.txt` overrides:
   - `exception_type = 1`: add service for the date.
   - `exception_type = 2`: remove service for the date.

The current snapshot contains 651,533 relevant exception rows, all of which remove base-calendar service dates. After applying them, 99,399 active service-date pairs remain.

## Surrogate and Natural Keys

GTFS IDs are retained as natural business keys for traceability and realtime matching. Integer surrogate keys are added for relationships and Power BI performance.

For example:

| Key | Purpose |
|---|---|
| `RouteId` | Trace back to GTFS and match future feeds |
| `RouteKey` | Efficient warehouse relationship |
| `TripId` | GTFS and GTFS-RT matching |
| `TripKey` | Efficient fact-table relationship |

Natural-key uniqueness constraints prevent accidental duplication, while foreign keys ensure facts cannot reference missing dimensions.

## Stop Hierarchy

`DimStop` stores both the original `ParentStationId` and the resolved integer `ParentStopKey`. This supports two valid reporting levels:

- physical stop position or mast for operational analysis;
- parent station for management-level station aggregation.

The hierarchy must be used deliberately. Counting both levels as equivalent “stations” would overstate the network size.

## Direct Fact Keys

The scheduled stop-event fact contains direct keys to route, agency, mode, service, and stop, even though some are functionally determined by the trip. This controlled denormalization reduces relationship chains in Power BI and supports fast slicing by operator or mode.

Consistency is protected during the ETL load by deriving those keys from the same validated trip and route records.

## Realtime Extension

The current warehouse does not claim to contain delays. The later realtime design will add separate facts such as:

- realtime feed observation;
- trip update;
- stop-time update;
- service alert;
- vehicle position, if available;
- final stop-performance record after observations are consolidated.

Scheduled and realtime records will be matched using GTFS identifiers, service date, and stop sequence. Delay can then be calculated as:

```text
actual or predicted event seconds - scheduled event seconds
```

## Why Realtime Snapshots Must Not Be Overcounted

GTFS Realtime can report the same trip repeatedly as predictions change. Each message is an observation, not a separate disruption. The future model must preserve raw observations while producing a consolidated performance fact for management KPIs.

This distinction enables both:

- prediction-quality analysis across time;
- final operational reliability measures without counting the same incident multiple times.

## Validation Baseline

| Warehouse object | Expected rows |
|---|---:|
| Agencies | 15 |
| Modes | 7 |
| Routes | 153 |
| Stops | 3,156 |
| Service patterns | 3,947 |
| Feed dates | 364 |
| Active service-date pairs | 99,399 |
| Scheduled trip patterns | 90,331 |
| Scheduled stop-event patterns | 1,551,343 |

These values are snapshot-specific reconciliation controls. A later feed is expected to change them, at which point the baseline must be versioned rather than silently overwritten in the validation logic.

## Defence Questions

### Why not connect Power BI directly to staging?

Staging preserves source text and is designed for ingestion and investigation. It has no stable business categories, surrogate keys, or reporting grain. Direct reporting would duplicate transformation logic inside Power BI and make results harder to audit.

### Why keep both working views and warehouse tables?

The working views prioritize transparency; the warehouse tables prioritize performance and controlled relationships. Comparing their row counts proves that materialization did not change the analytical scope.

### Why not create one huge flat table?

A flat table would repeat route, stop, agency, and mode text millions of times, increase model size, and make attribute corrections inconsistent. The star model stores descriptive attributes once and connects them to measurable events through keys.

### Why is `BridgeServiceDate` not a delay fact?

It records when a timetable pattern is scheduled to be active. It contains no actual arrival, prediction, cancellation, or disruption measurement.

### Can this model already prove root cause?

No. It establishes the planned operational context. Root-cause claims require realtime observations, alerts, infrastructure or weather context, and careful separation of evidence from inference.

