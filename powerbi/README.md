# Power BI

This directory contains the source-controlled Power BI project for Cologne Public Transport Intelligence.

## Authoritative authoring source

The authoritative Power BI authoring source is:

- `CologneTransitIntelligence.pbip`
- `CologneTransitIntelligence.Report/`
- `CologneTransitIntelligence.SemanticModel/`

The authoring workflow is PBIP + TMDL + PBIR with VS Code/Codex. A local
`CologneTransitIntelligence.pbix`, if present, is only a binary backup and is
not the source of truth. Power BI Desktop remains required for Import Refresh,
rendering, interaction QA, and final validation.

## Current report state

- Chat 07 report architecture is complete.
- `00 - Template` is the approved Design System / Component Library reference.
- Pages `01` through `08` currently contain only the approved Title and Subtitle skeleton.
- The current semantic model contains both Static and Realtime Reliability measures.
- The active custom report theme source is `theme/cologne-transit-intelligence-theme.json`.
- Validation assets are maintained under `validation/`.
- Chat 08 — Executive Overview is the next implementation stage.

## Preserved historical/static assets

The repository retains the historical StaticBaseline assets as part of the
broader project. They remain useful source and reference material, but they do
not replace the current PBIP/TMDL/PBIR project source:

- `measures/StaticBaselineMeasures.dax`
- `theme/cologne-transit-baseline-theme.json`

See the [Power BI Static Baseline Build Guide](../docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md)
for the historical static-baseline build process.
