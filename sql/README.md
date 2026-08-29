# SQL Server Implementation

This directory contains the SQL Server implementation for the Cologne public transport intelligence project.

## Current Milestone

The current scripts create the database and load the VRS static GTFS snapshot into a source-faithful staging layer. All staging columns are intentionally stored as text. Type conversion, standardization, Cologne filtering, and transport-mode classification belong in the next transformation layer.

## Execution Order

1. `01-database/01-create-database-and-schemas.sql`
2. `02-staging/01-create-gtfs-staging-tables.sql`
3. Edit `@GtfsRoot` in `02-staging/02-load-vrs-gtfs.sql`
4. `02-staging/02-load-vrs-gtfs.sql`
5. `02-staging/03-create-staging-indexes.sql`
6. `02-staging/04-validate-staging-load.sql`

## Important: Source Path

`BULK INSERT` reads files from the machine or container running the SQL Server Database Engine—not from the computer running SSMS or Azure Data Studio.

The extracted feed is currently stored on the Mac at:

```text
/Users/admin/Documents/DataBaseKÖLN/google_transit_goR/
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
