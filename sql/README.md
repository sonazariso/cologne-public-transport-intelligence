# SQL Server Implementation

This directory contains the SQL Server implementation for the Cologne public transport intelligence project.

## Current Milestone

The VRS static GTFS snapshot has been loaded and validated in the source-faithful staging layer. The working layer defines typed Cologne stops, Cologne-serving routes and trips, scheduled stop events inside Cologne, and a defensible transport-mode classification. The warehouse scripts materialize that scope into an indexed analytical model suitable for Power BI.

## Execution Order

1. `01-database/01-create-database-and-schemas.sql`
2. `02-staging/01-create-gtfs-staging-tables.sql`
3. Edit `@GtfsRoot` in `02-staging/02-load-vrs-gtfs.sql`
4. `02-staging/02-load-vrs-gtfs.sql`
5. `02-staging/03-create-staging-indexes.sql`
6. `02-staging/04-validate-staging-load.sql`
7. `03-working/01-create-cologne-working-layer.sql`
8. `03-working/02-validate-cologne-working-layer.sql`
9. `04-warehouse/01-create-static-warehouse.sql`
10. `04-warehouse/02-load-static-warehouse.sql`
11. `04-warehouse/03-validate-static-warehouse.sql`

## Important: Source Path

`BULK INSERT` reads files from the machine or container running the SQL Server Database Engine—not from the computer running SSMS or Azure Data Studio.

The extracted feed is currently stored on the Mac at:

```text
/Users/admin/Documents/CologneTransitData/google_transit_goR/
```

Before running the loader:

- For SQL Server on Windows, copy the extracted GTFS directory to a server-accessible path such as `C:\Data\CologneTransitIntelligence\vrs_gtfs_static\2026-08-29\`.
- For SQL Server in Docker, mount the local data directory into the container and use the mounted container path.
- Ensure the SQL Server service account has read permission on every GTFS file.

Do not commit the raw GTFS files or credentials to GitHub.

## Compatibility

The loader uses `FORMAT = 'CSV'` and requires SQL Server 2017 or later.

## Staging Design Rules

- Source rows are preserved without silent deduplication.
- No source identifiers are assumed to be unique until validated.
- GTFS identifiers use a binary collation for exact matching.
- The current staging layer holds one replaceable feed snapshot.
- Feed history is retained through archived source files and load-batch metadata, not by appending duplicate staging snapshots.

## Working-Layer Design Rules

- A Cologne stop is identified by the global stop-ID prefix `de:05315:`.
- A trip or route is included when it serves at least one Cologne stop.
- Operator identity is not used as the city-boundary filter.
- Original GTFS types remain visible beside the derived management category.
- S-Bahn, RE, RB, ordinary buses, and rail-replacement buses are kept separate.
- Scheduled GTFS times are converted to seconds after service-day midnight so values above `24:00:00` remain valid.
- Working objects remain transparent views; the warehouse materializes their validated output into indexed physical tables.

## Warehouse Design Rules

- Every dimension and fact has an explicitly documented grain.
- GTFS natural IDs are retained for lineage and future GTFS-RT matching.
- Integer surrogate keys support database and Power BI relationships.
- `calendar.txt` and `calendar_dates.txt` are resolved into active service-date pairs.
- A trip ID is treated as a schedule pattern; a dated operational occurrence will later use `trip_id + service date`.
- The scheduled stop-event fact is restricted to events occurring at Cologne stops.
- Realtime observations will be stored in separate facts and will not overwrite the scheduled baseline.
