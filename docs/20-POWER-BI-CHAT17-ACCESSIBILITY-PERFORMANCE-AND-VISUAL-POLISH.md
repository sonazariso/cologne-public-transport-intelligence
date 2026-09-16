# Power BI Chat 17 — Accessibility, Performance & Visual Polish

**Status:** PARTIAL
**Audit date:** 2026-09-16
**Authoritative source:** `powerbi/CologneTransitIntelligence.pbip`

This handoff records the read-only audit required by `prompts/pbi41.md` and the
narrow source-safe changes applied afterward. The prompt file is treated as
task specification; it does not override repository or system instructions.

Power BI Desktop rendering, save-roundtrip, alt-text entry, and Performance
Analyzer measurements remain pending. Chat 18 has not been started.

## Scope and baseline

The authoritative report source is:

- `powerbi/CologneTransitIntelligence.pbip`
- `powerbi/CologneTransitIntelligence.Report/`
- `powerbi/CologneTransitIntelligence.SemanticModel/`

No pages, KPIs, slicers, bookmarks, drill-through pages, custom tooltip pages,
relationships, analytical definitions, model objects, DAX, SQL, Collector, or
Power Query content was added or redesigned.

The required read-only audit was completed before any PBIR edit. The eight
portfolio pages contain 85 visuals in total:

| Page | Name | Visuals |
| --- | --- | ---: |
| 01 | Executive Overview | 12 |
| 02 | Reliability | 10 |
| 03 | Routes & Lines | 11 |
| 04 | Stations & Stops | 11 |
| 05 | Time Analysis | 8 |
| 06 | Data Quality & Collector Health | 13 |
| 07 | Situation & Platform Evidence | 11 |
| 08 | Methodology | 9 |
| **Total** |  | **85** |

The source-level type inventory is 29 `cardVisual`, 29 `textbox`, 7
`tableEx`, 8 `pageNavigator`, 3 `clusteredColumnChart`, 6
`clusteredBarChart`, 2 `lineChart`, and 1 `columnChart`. All portfolio pages
are 1280 × 720 with `FitToPage`. The source bounding-box audit found no
off-canvas visuals and no visual overlaps.

## Accessibility

### Alt text

No explicit `altText` configuration or reusable Power BI Desktop-generated
pattern exists in the portfolio source. Because the current report uses
`visualContainer/2.11.0` and the safe structure could not be proven from this
repository, no guessed PBIR accessibility property was written.

Power BI documents the supported authoring path as Format visual → General →
Alt text, with concise descriptions (the accessibility guidance specifies a
250-character limit): [Power BI accessibility guidance](https://learn.microsoft.com/en-us/power-bi/create-reports/desktop-accessibility-creating-reports)
and [Format pane overview](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-format-pane-overview).

In Power BI Desktop, use this exact workflow:

1. Open `Z:\cologne-public-transport-intelligence\powerbi\CologneTransitIntelligence.pbip`.
2. Select a chart, KPI card, table, or page navigator.
3. Open **Format visual → General → Alt text**.
4. Enter the matching description below, save, and close Desktop.
5. Inspect the generated diff. Reuse only a pattern emitted by Desktop; do
   not manually invent PBIR keys.

The following descriptions are the proposed factual manifest. They describe
what each visual shows and do not add analytical claims.

### Charts and tables

| Page | Visual | Description |
| --- | --- | --- |
| 01 | `101i` | Shows scheduled trip volume by mode group. |
| 01 | `101j` | Shows average Observed Estimated Delay by mode group in minutes. |
| 02 | `202h` | Shows Observed Estimated Delay distribution landmarks in minutes. |
| 02 | `202i` | Shows average, median and P95 Observed Estimated Delay by mode group in minutes. |
| 03 | `303g` | Shows the top 10 routes by scheduled trip volume. |
| 03 | `303h` | Shows average Observed Estimated Delay for the top 10 routes in minutes. |
| 03 | `303i` | Shows the top 10 routes by scheduled trip volume with matched services and average Observed Estimated Delay. |
| 04 | `404g` | Shows the top 10 parent stations by scheduled trip-pattern volume. |
| 04 | `404h` | Shows average Observed Estimated Delay for the top 10 parent stations in minutes. |
| 04 | `404i` | Shows the top 10 stop positions by P95 Observed Estimated Delay with parent station context. |
| 05 | `505c` | Shows scheduled trips by service date. |
| 05 | `505d` | Shows average and median Observed Estimated Delay by service date. |
| 05 | `505e` | Shows average Observed Estimated Delay by hour of day. |
| 05 | `505f` | Shows scheduled trips by day of week. |
| 06 | `606i` | Shows Data Quality matching states by collection date. |
| 06 | `606j` | Shows collector runs by Sampling Panel target. |
| 06 | `606k` | Shows coverage rates for matching and evidence states. |
| 07 | `707h` | Shows observed matched services grouped by Platform Evidence state: Changed, Unchanged, or Unknown. |
| 07 | `707i` | Shows the share of validated outcomes with Platform Changed, Platform Unchanged, and Platform Unknown evidence. |
| 01–08 | each page navigator | Navigates between portfolio pages 01 through 08. |

### KPI cards

| Visuals | Description |
| --- | --- |
| `101c`, `303c`, `404e` | Shows the count of scheduled trips in the static GTFS baseline. |
| `101d` | Shows the count of routes in the static GTFS baseline. |
| `101e`, `404c` | Shows the count of parent stations in the static GTFS baseline. |
| `404d` | Shows the count of stop positions in the static GTFS baseline. |
| `101f`, `202c`, `303e`, `404f` | Shows the count of observed matched services. |
| `101g`, `202d`, `303f` | Shows the average Observed Estimated Delay in minutes. |
| `101h`, `202e` | Shows the median Observed Estimated Delay in minutes. |
| `202f` | Shows the P95 Observed Estimated Delay in minutes. |
| `303d` | Shows the count of routes in context. |
| `606c` | Shows the count of realtime source observations. |
| `606d` | Shows the count of matched view observations. |
| `606e` | Shows the count of usable matches. |
| `606f` | Shows the usable match rate. |
| `606g` | Shows the collector success rate. |
| `606h` | Shows the count of Sampling Panel targets observed. |
| `707c` | Shows the count of Situation-Linked Outcomes. |
| `707d` | Shows the share of outcomes with Situation Evidence. |
| `707e` | Shows the count of outcomes with Platform Changed evidence. |
| `707f` | Shows the count of outcomes with Platform Unchanged evidence. |
| `707g` | Shows the count of outcomes with Platform Unknown evidence. |

Visible textboxes already contain explanatory labels or notes and were not
assigned redundant alt text in source.

### Keyboard and tab order

**Result:** PASS at the source level. The page navigator is visually below the
subtitle and was previously last in keyboard order. Its `tabOrder` is now
`1500` on each portfolio page, producing this sequence without reordering
analytical content:

`0` title → `1000` subtitle → `1500` page navigator → `2000+` KPI cards →
`3000+` charts/tables → `4000+`/`5000+` notes.

The navigators remain at `X=32, Y=126, W=1216, H=24`; only keyboard order was
changed. The navigator visual `z` order was preserved.

### Font-size audit and fixes

The audit covered all user-facing text in the 85 portfolio visuals. The
following narrow fixes were applied:

- Page 07 table headers `707h` and `707i`: 8 pt → 9 pt.
- Page 02 chart data labels `202i`: 8 pt → 9 pt.
- Page 04 table values `404i`: 8 pt → 9 pt.
- Page 06 table headers `606j` and `606k`: 8 pt → 9 pt.
- Page 08 analytical-flow lines in `808e` and 8 pt body/status text in
  `808h`: 8 pt → 9 pt.

The dense date/hour labels in Page 05 (`505d`, `505e`) and collection-date
labels in Page 06 (`606i`) remain 8 pt because enlarging them in source would
risk clipping or overlap. They require the Desktop FitToPage legibility check.
The existing title/subtitle/KPI hierarchy and Design System typography were
otherwise preserved.

### Color and contrast

The palette was not redesigned. The source contrast audit found that the
existing teal/orange colors are not suitable for small text on every light
background. The following scoped improvements were applied:

- Page 07 `707i` Changed and Unchanged header text changed from white to dark
  ink `#1F2933` while retaining the existing orange/teal backgrounds. The
  resulting calculated foreground/background ratios are 4.77:1 and 4.44:1.
- Page 07 Unknown KPI `707g` neutral value changed from `#8C8C8C` to the
  existing darker neutral `#5F6B6D` (5.51:1 on white).
- Page 08 `808h` inline status labels use dark ink rather than relying on
  green/orange text alone.

The words `Changed`, `Unchanged`, `Unknown`, `StaticCoverageMissing`, and
`Unresolved` remain visible semantic labels; color is not the sole status
indicator. Navigation selected/unselected colors were audited and retained.

## Visual polish

**Pages changed:** 01, 02, 03, 04, 05, 06, 07, and 08. Page 05 received only
the portfolio-wide navigator/header cleanup; Page 08 also received the
methodology rebalancing described below.

### Visual headers

Visual-header controls were already hidden for charts, tables, and textboxes.
The same existing `visualContainerObjects.visualHeader.show=false` structure
was applied to the 29 KPI cards and 8 page navigators, where header controls
add no portfolio value. Analytical chart/table interaction functionality and
page navigation were preserved.

### Methodology page

Page 08 was rebalanced without removing content:

- top row (`808c`, `808d`, `808e`): `Y=150`, height 150;
- middle row (`808f`, `808g`): `Y=316`, height 220;
- bottom guardrail box (`808h`): `Y=552`, height 168;
- all six methodology textboxes: vertical padding 12 pt → 8 pt, with
  horizontal padding retained;
- duplicated wording was shortened only where the same meaning remained.

The analytical flow, Static GTFS baseline, Realtime TRIAS explanation,
matching states, operational grain, seven-location Sampling Panel limitation,
Observed Estimated Delay terminology, Situation Evidence boundary, Platform
Unknown distinction, cancellation/departure limitation, and Data Quality
boundary remain in the page source. Desktop must confirm that the new geometry
removes unnecessary internal scrolling and does not clip essential text.

### Consistency and density

Title/subtitle positions, navigator geometry, KPI/card treatment, borders,
chart/table containers, alignment, capitalization, and spacing were already
consistent and were retained. No visual was removed or added. The 8–13 visual
density per page remains unchanged.

Tables retain their existing fields, sorting, widths, full-count display, and
approved terminology. Existing measure formats were preserved: counts are not
abbreviated, delay values retain their existing decimal precision, and
percentages retain `0.00%` formatting. No semantic-model format strings were
changed.

## Performance

### Source-level audit

The source audit found:

- 85 portfolio visuals across pages 01–08;
- 7 visual filter configurations: six intentional Top 10 detail filters on
  Pages 03–04 and the existing `DimensionType = "Hour"` helper filter on
  Page 05;
- no hidden portfolio visuals, custom visuals, speculative high-cardinality
  projections, or unnecessary presentation-only duplicate measures;
- repeated measures used for KPI/chart presentation as expected;
- existing sort definitions retained where valid;
- no measured source defect requiring DAX, SQL, relationship, or semantic-model
  changes.

No performance optimization was inferred from formula complexity or source
shape alone.

### Performance Analyzer

**Result:** NOT RUN — Power BI Desktop is required for actual query and render
durations. The following measurements are still required for pages 01–07:

| Page | Slowest visual | DAX query (ms) | Display (ms) | Other (ms) | Total (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| 01 | pending Desktop measurement | pending | pending | pending | pending |
| 02 | pending Desktop measurement | pending | pending | pending | pending |
| 03 | pending Desktop measurement | pending | pending | pending | pending |
| 04 | pending Desktop measurement | pending | pending | pending | pending |
| 05 | pending Desktop measurement | pending | pending | pending | pending |
| 06 | pending Desktop measurement | pending | pending | pending | pending |
| 07 | pending Desktop measurement | pending | pending | pending | pending |

Desktop measurement workflow:

1. Open **View → Performance Analyzer**.
2. Select **Start recording**.
3. Refresh visuals.
4. Visit pages 01 through 07 and record the slowest visual plus DAX query,
   visual display, other, and total durations.
5. Only investigate model/DAX changes if the measurements show a material
   bottleneck.

## Semantic guardrails

**PASS — preserved.** Every source change preserves:

- `Observed Estimated Delay != Actual Delay`;
- no arbitrary On-Time threshold;
- `Situation Evidence != causality`;
- `Platform Unknown != Unchanged`;
- `StaticCoverageMissing` and `Unresolved` as Data Quality states;
- no invented cancellation KPI;
- no invented departure KPI;
- seven realtime locations as a `Sampling Panel`;
- repeated observations not treated as separate operational services.

The recovered Page 07 repairs remain intact:

- `707c0000000000000001`: `sortDefinition` absent;
- `707h0000000000000001`: valid sort retained, `prototypeQuery` and
  `dataTransforms` absent;
- `707i0000000000000001`: `prototypeQuery` and `dataTransforms` absent.

## Files changed

The 49 edited PBIR files are listed exactly below. No semantic-model, SQL,
Collector, Power Query, or other analytical source file changed.

```text
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101g0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/101h0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a1e0c7b6d92f4a1385c1/visuals/nav010000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707g0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707h0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/707i0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/a7e623b1d85f90794bc7/visuals/nav070000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/202c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/202d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/202e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/202f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/202i0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b2f1d8c7e30a4b2496d2/visuals/nav020000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808g0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/808h0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/b8f734c2e960a18a5cd8/visuals/nav080000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/c3a2e9d8f41b5c3507e3/visuals/303c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/c3a2e9d8f41b5c3507e3/visuals/303d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/c3a2e9d8f41b5c3507e3/visuals/303e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/c3a2e9d8f41b5c3507e3/visuals/303f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/c3a2e9d8f41b5c3507e3/visuals/nav030000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/404c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/404d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/404e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/404f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/404i0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/d4b3f0e9a52c6d4618f4/visuals/nav040000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/e5c401fab63d7e5729a5/visuals/nav050000000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606c0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606d0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606e0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606f0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606g0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606h0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606j0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/606k0000000000000001/visual.json
powerbi/CologneTransitIntelligence.Report/definition/pages/f6d512a0c74e8f683ab6/visuals/nav060000000000000000001/visual.json
```

This handoff document is the additional changed file:

`docs/20-POWER-BI-CHAT17-ACCESSIBILITY-PERFORMANCE-AND-VISUAL-POLISH.md`

## PBIR validation

**PASS for source validation:** all 123 JSON files under
`powerbi/CologneTransitIntelligence.Report/definition/` strict-parse with
`jq`. Structural checks pass for all 85 portfolio visuals: every visual has a
position and tab order, all card/navigator headers are explicitly hidden, and
no portfolio visual contains `prototypeQuery` or `dataTransforms`.

The recovered Page 07 sort/recovery state listed above was rechecked after the
edits. No arbitrary `altText` property was added. The repository does not
include a Power BI Desktop save-roundtrip, so Desktop remains the authority for
final PBIR schema acceptance and rendering.

## Power BI Desktop QA

**Result:** NOT RUN — requires the Windows Power BI Desktop environment.

Open the PBIP in Desktop and validate every portfolio page at **Fit to Page**:

- no clipping, unexpected essential-text scrollbars, or overlaps;
- navigation destinations and focus behavior remain correct;
- title, subtitle, KPI labels, chart labels, table headers, and contrast are
  readable;
- Page 07 loads without a PBIR warning and keeps the three platform states;
- Page 08 is readable with no hidden essential methodology content;
- all approved wording and semantic guardrails remain intact;
- save once, close Desktop, inspect the diff, and remove unrelated generated
  metadata noise before any commit.

## Open issues

1. Run the Desktop FitToPage visual QA and save-roundtrip check.
2. Run Performance Analyzer for pages 01–07 and fill the pending measurement
   table above.
3. Add the chart, table, KPI, and navigator alt text in Desktop using the
   manifest above; only a Desktop-generated PBIR pattern may be reused in a
   later source pass.

## Final status

Power BI Chat 17 — Accessibility, Performance & Visual Polish remains

**PARTIAL — source-safe changes complete; Power BI Desktop validation and
manual alt-text authoring are still required.**

**Git commit:** none created.
**Final Git status:** not clean — 49 modified PBIR files and this new handoff
document are uncommitted.

Chat 18 was not started.
