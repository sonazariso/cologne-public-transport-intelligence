# SQL Server Implementation

This directory contains the SQL Server implementation for the Cologne public transport intelligence project.

## Current Milestone

The VRS static GTFS snapshot has been loaded and validated in the source-faithful staging layer. The working-layer scripts now define typed Cologne stops, Cologne-serving routes and trips, scheduled stop events inside Cologne, and a defensible transport-mode classification.

## Execution Order

1. `01-database/01-create-database-and-schemas.sql`
2. `02-staging/01-create-gtfs-staging-tables.sql`
3. Edit `@GtfsRoot` in `02-staging/02-load-vrs-gtfs.sql`
4. `02-staging/02-load-vrs-gtfs.sql`
5. `02-staging/03-create-staging-indexes.sql`
6. `02-staging/04-validate-staging-load.sql`
7. `03-working/01-create-cologne-working-layer.sql`
8. `03-working/02-validate-cologne-working-layer.sql`

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
- Working objects are views at this milestone; physical dimensional tables will be designed after realtime keys and analytical grain are confirmed.
