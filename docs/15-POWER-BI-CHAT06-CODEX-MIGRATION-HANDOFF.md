# Power BI Chat 06 — Codex/PBIP Migration Handoff

**Completed:** 2026-09-15  
**Status:** INFRASTRUCTURE / AUTHORING-WORKFLOW MIGRATION COMPLETE — DESIGN SYSTEM STILL IN PROGRESS

## Purpose

Chat 06 began as manual Design System & Theme work, then deliberately switched the Power BI authoring workflow from PBIX-centric manual editing to **PBIP + TMDL + PBIR with VS Code + Codex on macOS**, while keeping Power BI Desktop inside the Windows VM for rendering, refresh, interaction testing, and final validation.

## Completed in this chat

- Imported `powerbi/theme/cologne-transit-intelligence-theme.json` successfully in Power BI Desktop.
- Created `00 - Template` at 1280 × 720 / 16:9.
- Established the current template header geometry:
  - Title: X 32 / Y 24 / W 1216 / H 58.
  - Subtitle: X 32 / Y 90 / W 1216 / H 36.
  - KPI row starts at Y 150.
- Added a sample KPI card using `[Observed Matched Services]` at X 32 / Y 150 / W 230 / H 110.
- Enabled full numeric display instead of automatic K/M abbreviation through the Power BI display-units setting.
- Enabled Power BI Project / TMDL / PBIR preview features.
- Saved the existing report as `powerbi/CologneTransitIntelligence.pbip` in the user's local shared repository.
- Installed the official Microsoft `TMDL` VS Code extension (`analysis-services.TMDL`).
- Updated Git ignore policy for Power BI local state/cache and PBIX binary backup files.
- Created/verified baseline commit:
  - `0044919 Add Power BI project source format`
- Audited the TMDL semantic model with Codex in read-only mode.
- Validated 33 exported model tables, 27 exported relationships (including generated local-date relationships), 68 explicit measures, seven Display Folders, no bidirectional relationships, and no active ambiguous filter path.
- Performed a metadata-only external TMDL edit on `[Observed Matched Services]` and validated it in Power BI Desktop.
- Verified a clean TMDL save round-trip.
- Observed a harmless `diagramLayout.json` scroll-position change from Desktop and restored it; this file is treated as Desktop-owned layout metadata.
- Audited the PBIR report project with Codex in read-only mode.
- Identified four pages and exact identifiers/geometry for the `00 - Template` visuals.
- Performed a controlled external PBIR edit changing only the Template subtitle to:
  - `Layout and visual styling reference for all report pages`
- Opened the PBIP successfully in Power BI Desktop and confirmed the PBIR edit rendered correctly.
- Verified a clean PBIR save round-trip with no unexpected report rewrite.

## Validated new authoring architecture

```text
Mac VS Code + Codex
   -> TMDL / PBIR / theme / DAX / SQL / docs
   -> Git diff
   -> Windows Power BI Desktop
   -> render / refresh / visual QA / interaction QA
   -> save
   -> Git diff / commit
```

The PBIX binary is no longer the intended source-of-truth authoring artifact. The active local Power BI Project (`.pbip`) and its TMDL/PBIR source are the preferred authoring representation.

## Git policy established

Repository `.gitignore` must contain:

```gitignore
# Power BI Project local state
**/.pbi/localSettings.json
**/.pbi/cache.abf

# Power BI Desktop binary files
/powerbi/*.pbix
```

Track:

- `powerbi/CologneTransitIntelligence.pbip`
- `powerbi/CologneTransitIntelligence.Report/`
- `powerbi/CologneTransitIntelligence.SemanticModel/`

Do not treat `.pbix`, local settings, or cache files as source-of-truth project files.

## Semantic-model audit snapshot

- 33 model tables in exported TMDL.
- Business dimensions: `ActiveDate`, `Mode`, `ParentStation`, `Route`, `StopPosition`.
- Core fact/analytics tables: `DailySchedule`, `RT_CollectorRunHealth`, `RT_DataQualityCoverage`, `RT_ConsolidationQuality`, `RT_ReliabilityOutcome`.
- Disconnected/helpers: `NetworkKPI`, `RT_ReliabilityByDimension`, `_Measures`.
- 19 generated `LocalDateTable_*` tables plus template; no cleanup performed in this chat.
- `_Measures`: 68 explicit measures in seven folders.
- No bidirectional relationships detected.
- No active ambiguous filter path detected.

## Current Template PBIR identifiers

Page `00 - Template`:

```text
Page identifier: 3cdff3efc36ad5b16990
Canvas: 1280 x 720
Fit: FitToPage
```

Visuals:

```text
Page Title textbox
Identifier: 45b26de4d7002c56ad33
X=32 Y=24 W=1216 H=58

Subtitle textbox
Identifier: f70e8350c1013d1d530a
X=32 Y=90 W=1216 H=36
Current text: Layout and visual styling reference for all report pages

Observed Matched Services card
Identifier: d12f9c4e72d9b98cb551
X=32 Y=150 W=230 H=110
```

## Semantic/business guardrails remain unchanged

- use `Observed Estimated Delay`, not confirmed Actual Delay;
- do not invent an On-Time threshold;
- situation evidence is association, not causality;
- Platform `Unknown` is not `Unchanged`;
- `StaticCoverageMissing` and `Unresolved` remain Data Quality states;
- do not invent cancellation/departure KPIs;
- seven realtime locations remain a sampling panel, not full Köln coverage;
- Data Quality rates remain summed numerator / summed denominator.

## Current status of Chat 06

The **workflow migration/testing part is complete**.

The **Design System & Theme phase itself is not complete**.

Next task:

> Continue Chat 06 using PBIR/Codex and finalize the KPI Card design standard on `00 - Template`, then encode the approved pattern for reuse across the report.

Do not restart the Power BI build from scratch and do not return to PBIX-only/manual authoring.

## Important source archive note

The actual PBIP/TMDL/PBIR files were generated in the user's active local repository after the last source ZIP was uploaded. A documentation ZIP produced from that older uploaded repository cannot contain the exact new local project files unless the user uploads the current local `powerbi/CologneTransitIntelligence.pbip`, `.Report`, and `.SemanticModel` artifacts.
