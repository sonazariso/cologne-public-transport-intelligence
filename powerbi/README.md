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

- Chat 07 report architecture is complete, and M01 adds the management-facing system overview page.
- `00 - Template` is the approved Design System / Component Library reference.
- `M01 - System Overview` is inserted first; pages `01` through `08` and the legacy QA pages remain unchanged.
- The current semantic model contains Static, Realtime Reliability, and M01 System Overview measures.
- The active custom report theme source is `theme/cologne-transit-intelligence-theme.json`.
- Validation assets are maintained under `validation/`.
- Power BI Desktop is still required for refresh, rendering, and final interaction QA.

## Preserved historical/static assets

The repository retains the historical StaticBaseline assets as part of the
broader project. They remain useful source and reference material, but they do
not replace the current PBIP/TMDL/PBIR project source:

- `measures/StaticBaselineMeasures.dax`
- `theme/cologne-transit-baseline-theme.json`

See the [Power BI Static Baseline Build Guide](../docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md)
for the historical static-baseline build process.
