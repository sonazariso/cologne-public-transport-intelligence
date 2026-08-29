# Data Directory

Raw source data is stored locally and is not committed to GitHub.

## Current Local Source

```text
/Users/admin/Documents/DataBaseKÖLN/google_transit_goR/
```

This directory contains the extracted VRS static GTFS feed downloaded on 2026-08-29.

## Repository Convention

If data is later placed inside this repository, use the following structure:

```text
data/
├── raw/          # Immutable source extracts
├── interim/      # Temporary transformation outputs
└── processed/    # Analysis-ready local outputs
```

These directories are excluded through `.gitignore`. Only documentation, schemas, scripts, and appropriately small non-sensitive samples should be version-controlled.
