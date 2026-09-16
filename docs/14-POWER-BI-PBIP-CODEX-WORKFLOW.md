# Power BI Development with VS Code + Codex (PBIP / TMDL / PBIR)

**Project:** Cologne Public Transport Intelligence  
**Workflow established:** 2026-09-15  
**Status:** Codex-based Power BI authoring workflow validated end-to-end

## 1. Purpose

This document records the migration from a primarily manual Power BI Desktop workflow to a source-controlled Power BI Project workflow that can be developed from **VS Code + Codex on macOS** while retaining **Power BI Desktop inside the Windows VMware Fusion VM** for refresh, rendering, visual QA, and final validation.

The goal is not to eliminate Power BI Desktop. The goal is to move as much deterministic authoring as possible into text-based project files that can be inspected, edited, diffed, reviewed, and committed through Git.

The validated authoring flow is:

```text
VS Code + Codex on macOS
        |
        | edits source-controlled Power BI project files
        v
TMDL semantic model + PBIR report + theme JSON
        |
        | shared repository through VMware Shared Folder
        v
Power BI Desktop on Windows VM
        |
        | open / refresh / render / interact / validate / save
        v
Git diff and commit on macOS
```

## 2. Environment

### macOS host

Repository root:

```text
/Users/admin/Documents/cologne-public-transport-intelligence/
```

Primary authoring tools:

- Visual Studio Code
- Codex
- Git
- SQL Server extension for VS Code
- Microsoft TMDL extension (`analysis-services.TMDL`)

### Windows 11 VMware Fusion VM

Shared repository path:

```text
\\vmware-host\Shared Folders\cologne-public-transport-intelligence\
```

Power BI Desktop and SQL Server run inside the Windows VM.

Power BI SQL connection remains:

```text
Server: localhost
Database: CologneTransitIntelligence
Data Connectivity Mode: Import
```

The Mac and Windows paths refer to the same repository files through VMware Shared Folders.

## 3. Why PBIP is required for Codex-based authoring

A `.pbix` file is a packaged binary artifact and is not suitable as the primary Git/Codex authoring surface.

The active local Power BI report was therefore migrated to **Power BI Project (`.pbip`)** format.

The target local structure is:

```text
powerbi/
├── CologneTransitIntelligence.pbip
├── CologneTransitIntelligence.Report/
│   ├── definition.pbir
│   ├── definition/
│   │   ├── report.json
│   │   └── pages/
│   │       └── .../visuals/.../visual.json
│   └── StaticResources/
└── CologneTransitIntelligence.SemanticModel/
    ├── definition.pbism
    ├── definition/
    │   ├── database.tmdl
    │   ├── model.tmdl
    │   ├── relationships.tmdl
    │   └── tables/
    │       └── *.tmdl
    └── diagramLayout.json
```

This gives Codex text-based access to both the semantic model and report definition.

## 4. Required Power BI Desktop preview features

The following Power BI Desktop options were enabled under:

```text
File -> Options and settings -> Options -> Global -> Preview features
```

Enabled:

- `Power BI Project (.pbip) save option`
- `Store semantic model using TMDL format`
- `Store reports using enhanced metadata format (PBIR)`

A separate option related to storing PBIX reports in enhanced metadata format was not required for the migration because the project itself was moved to PBIP.

After enabling the options, Power BI Desktop was restarted when required.

## 5. PBIX to PBIP migration

The existing local report was saved as:

```text
powerbi/CologneTransitIntelligence.pbip
```

The existing PBIX was retained as a local safety backup during migration.

The PBIP save created the report and semantic-model project folders. No migration warning or upgrade dialog was shown.

The migration was verified from macOS by enumerating the project files and confirming the presence of:

- the `.pbip` project file;
- the `.Report` project;
- the `.SemanticModel` project;
- TMDL model definitions;
- PBIR report definitions.

## 6. Git and local-state policy

PBIP uses local state/cache files under `.pbi`. These must not be treated as source-controlled project definition.

The repository `.gitignore` was updated with:

```gitignore
# Power BI Project local state
**/.pbi/localSettings.json
**/.pbi/cache.abf

# Power BI Desktop binary files
/powerbi/*.pbix
```

Important policy:

- `.pbip` is source controlled.
- `.Report` project definition is source controlled.
- `.SemanticModel` project definition is source controlled.
- `cache.abf` is not source controlled.
- `localSettings.json` is not source controlled.
- `.pbix` is retained only as a local binary backup and is not the source of truth.
- the entire `.pbi` directory is **not** blanket-ignored, because some project metadata may be source-relevant.

A baseline migration commit was verified locally:

```text
0044919 Add Power BI project source format
```

This commit is the known rollback point before external TMDL/PBIR editing began.

## 7. TMDL extension installation

The official Microsoft TMDL extension was installed in VS Code:

```text
Extension: TMDL
Extension ID: analysis-services.TMDL
Publisher: Microsoft / Analysis Services
```

After installation, `.tmdl` files showed language-aware syntax highlighting for:

- table/model keywords;
- measures;
- properties such as `formatString` and `displayFolder`;
- embedded DAX expressions.

The `_Measures.tmdl` file was opened successfully and the 68 explicit measures were visible in source form.

## 8. Read-only semantic-model audit with Codex

Before allowing any external model edit, Codex performed a read-only audit of:

```text
powerbi/CologneTransitIntelligence.SemanticModel/
```

Validated audit results:

- 33 tables referenced by `model.tmdl`;
- 5 business dimensions: `ActiveDate`, `Mode`, `ParentStation`, `Route`, `StopPosition`;
- primary facts/analytics tables including `DailySchedule`, `RT_CollectorRunHealth`, `RT_DataQualityCoverage`, `RT_ConsolidationQuality`, and `RT_ReliabilityOutcome`;
- disconnected/helper tables: `NetworkKPI`, `RT_ReliabilityByDimension`, `_Measures`;
- 19 generated `LocalDateTable_*` tables plus a date-table template;
- 27 explicit relationships in the exported TMDL, including generated local-date relationships;
- no bidirectional relationship detected;
- no active ambiguous filter path detected;
- `_Measures` has no relationships;
- 68 explicit measures in `_Measures`;
- seven measure display folders:
  - `01 Static Schedule` — 9 measures;
  - `02 Network Baseline` — 12 measures;
  - `03 Realtime Reliability` — 8 measures;
  - `04 Evidence` — 8 measures;
  - `05 Consolidation` — 5 measures;
  - `06 Data Quality` — 17 measures;
  - `07 Collector Health` — 9 measures.

The generated local date tables were noted but were **not** changed during this migration. Their existence is not treated as a defect in this phase.

## 9. First controlled external TMDL edit

The first Codex model edit was deliberately metadata-only.

Codex changed only:

```text
powerbi/CologneTransitIntelligence.SemanticModel/definition/tables/_Measures.tmdl
```

and added this description above `Observed Matched Services`:

```tmdl
/// Count of matched operational stop outcomes available for validated
/// realtime reliability analysis.
```

No DAX expression, format string, display folder, lineage tag, relationship, or other measure was changed.

### Validation

The PBIP project was opened in Power BI Desktop and the Description appeared correctly on the measure.

A Power BI Desktop save round-trip was then tested. The TMDL diff remained limited to the intended description, proving that the external edit could be loaded and saved without destructive model rewrites.

Power BI Desktop also changed only the scroll position in:

```text
powerbi/CologneTransitIntelligence.SemanticModel/diagramLayout.json
```

That change was treated as UI-layout noise and restored from Git.

### Rule established

`diagramLayout.json` is Power BI Desktop-owned layout metadata for this workflow. Codex must not intentionally edit it.

## 10. Read-only PBIR report audit with Codex

Codex then audited:

```text
powerbi/CologneTransitIntelligence.Report/
```

without modifying files.

The report contained four pages at the time of the audit:

| Display name | Page identifier | Canvas | Visual count |
|---|---|---:|---:|
| Page 1 | `8d6d0e30741134c8178e` | 1280 × 720 | 7 |
| Page 2 | `f5b0f1183d7ce864a485` | 1280 × 720 | 4 |
| Page 3 | `b2e639ab501a0ceb71d0` | 1280 × 720 | 4 |
| `00 - Template` | `3cdff3efc36ad5b16990` | 1280 × 720 | 3 |

All pages used `FitToPage`.

The `00 - Template` page contained:

| Visual | Identifier | X | Y | Width | Height |
|---|---|---:|---:|---:|---:|
| Page Title textbox | `45b26de4d7002c56ad33` | 32 | 24 | 1216 | 58 |
| Subtitle textbox | `f70e8350c1013d1d530a` | 32 | 90 | 1216 | 36 |
| `Observed Matched Services` card | `d12f9c4e72d9b98cb551` | 32 | 150 | 230 | 110 |

The audit also identified the storage locations for:

- visual position and local formatting: each visual's `visual.json`;
- textbox content/style: `visual.objects.general`;
- KPI query/styling: card `visual.query` and `visual.objects`;
- page settings: `page.json`;
- report settings/theme registration: `definition/report.json`;
- registered custom theme under `StaticResources/RegisteredResources/`;
- Power BI base theme under `StaticResources/SharedResources/BaseThemes/`.

## 11. First controlled external PBIR edit

The first PBIR edit deliberately changed only the visible subtitle text on `00 - Template`.

Before:

```text
Short page description or scope
```

After:

```text
Layout and visual styling reference for all report pages
```

Only one `visual.json` file changed. No visual identifier, x/y position, width, height, font, font size, color, alignment, other visual, other page, semantic-model file, or theme file was changed.

### Validation

The PBIP project opened successfully in Power BI Desktop and displayed the new subtitle with the original layout preserved.

A Power BI Desktop save round-trip was then tested. Git diff remained limited to the intended text value. No PBIR rewrite or unexpected report metadata change occurred.

This validates the full external report-edit path:

```text
Codex -> PBIR JSON -> Power BI Desktop -> Save -> Git diff
```

## 12. Design-system state reached before migration

Chat 06 Design System work had begun manually before switching to Codex-based authoring.

Validated state:

- theme imported successfully;
- page format: 16:9 / 1280 × 720;
- template page: `00 - Template`;
- title layout: `X=32`, `Y=24`, `W=1216`, `H=58`;
- subtitle layout: `X=32`, `Y=90`, `W=1216`, `H=36`;
- first KPI row starts at `Y=150`;
- sample KPI card: `X=32`, `Y=150`, `W=230`, `H=110`;
- sample measure: `[Observed Matched Services]`;
- report-level/default display units were configured so counts display as full values instead of automatic `K` abbreviation;
- the sample KPI card shows a full value rather than `2K`.

The KPI card design standard was **not yet finalized** when the workflow migration was completed. This is the correct next Design System task.

## 13. Theme state

Repository theme source:

```text
powerbi/theme/cologne-transit-intelligence-theme.json
```

The theme was imported successfully into Power BI Desktop.

The report project also contains a Power BI-registered resource copy under its PBIR static resources. The repository theme file remains the human-maintained design asset; generated/registered report resources should be treated carefully and should not be manually rewritten without a clear reason.

Existing semantic warning remains mandatory: `good` / `neutral` / `bad` colors must not be repurposed into On-Time / delay-severity classes unless a documented business threshold is explicitly approved.

## 14. Standard operating procedure for future Power BI work

Use the following workflow for every meaningful Codex edit.

### A. Before editing

1. Save the PBIP project in Power BI Desktop.
2. For external structural edits, close Power BI Desktop to avoid competing writes.
3. Check Git status.
4. Start from a clean or understood diff.

### B. Give Codex a narrow scope

Each edit prompt should identify:

- exact project area (`SemanticModel` or `Report`);
- exact table/page/visual when possible;
- exact file when known;
- properties that may change;
- properties that must not change;
- requirement to show Git diff afterward.

Avoid vague instructions such as "clean up the report" without an explicit scope.

### C. Review before Power BI Desktop

Run:

```bash
git status --short
git diff --stat
git diff
```

Reject any change that touches unrelated TMDL, PBIR, relationships, lineage tags, or generated layout metadata without a justified reason.

### D. Validate in Power BI Desktop

Open:

```text
powerbi/CologneTransitIntelligence.pbip
```

Validate:

- project loads without parse/recovery errors;
- intended model/report change appears;
- measures still evaluate;
- visual layout is correct;
- filters/interactions behave correctly when relevant;
- data refresh still works when a refresh is required.

### E. Save round-trip check

After Desktop validation:

1. save the project;
2. close Desktop if the next edit will be external;
3. inspect `git diff` again;
4. restore unrelated UI-only noise such as accidental `diagramLayout.json` scroll changes when appropriate;
5. commit only the validated logical change.

## 15. Division of responsibility: Codex vs Power BI Desktop

### Codex / VS Code is now preferred for

- TMDL semantic-model inspection and controlled edits;
- explicit DAX measure authoring and metadata;
- display folders and format strings;
- table/column descriptions;
- relationship definition changes when deliberately required;
- PBIR report/page/visual JSON inspection;
- repeatable layout and formatting changes;
- theme JSON;
- documentation;
- Git diffs and source review;
- SQL scripts and validation queries.

### Power BI Desktop remains required for

- rendering and visual inspection;
- Import refresh against SQL Server;
- checking interactions, slicers, drill-through, tooltips, bookmarks, and responsive behavior;
- verifying text clipping, chart density, label overlap, and actual visual polish;
- validating external edits after loading;
- final report save and publication workflow.

The strategy is therefore **code-first authoring with Desktop validation**, not Desktop elimination.

## 16. Files Codex should not edit casually

Do not directly manipulate these without a specific validated need:

- `.pbi/cache.abf`;
- `.pbi/localSettings.json`;
- `diagramLayout.json`;
- generated base-theme resources;
- other local/session/cache metadata;
- PBIX binary files.

For any unknown PBIR/TMDL file, audit it first and edit only after the purpose is understood.

## 17. Optional tools considered but not required

The following were considered for later use but are **not required** for the validated workflow:

- Power BI Modeling MCP Server — potentially useful for AI-driven semantic-model operations, but not a core dependency;
- DAX Studio — useful later for DAX query/server-timing performance analysis;
- Tabular Editor — useful for advanced tabular-model operations, but unnecessary for the current project because TMDL already provides a strong source-controlled authoring surface;
- ALM Toolkit / pbi-tools — not required for the current workflow.

Avoid adding tools merely because they exist. Add one only when it solves a concrete project need.

## 18. Current next step

The infrastructure/migration test is complete.

Continue **Chat 06 — Design System & Theme** using the new Codex/PBIP method.

Immediate next work:

1. finalize the KPI Card pattern on `00 - Template` through controlled PBIR edits;
2. standardize card typography, padding, border, background, and label behavior;
3. validate the rendered result in Power BI Desktop;
4. encode the approved pattern for repeated use across report pages;
5. continue the remaining Design System work before building the portfolio pages.

Do not return to broad manual report authoring unless Power BI Desktop rendering/interaction work specifically requires it.

## 19. Source-snapshot caveat

The PBIP/TMDL/PBIR project files described in this document were created and validated in the user's active local repository on macOS/Windows shared storage **after** the repository ZIP used as the source for this documentation update was uploaded.

Therefore, a generated archive based only on that uploaded ZIP can document the migration and update repository text assets, but it cannot reproduce the exact local `.pbip`, `.Report`, or `.SemanticModel` bytes unless those files are separately uploaded.

The user's active local repository containing the actual PBIP project remains authoritative for those generated Power BI project files.
