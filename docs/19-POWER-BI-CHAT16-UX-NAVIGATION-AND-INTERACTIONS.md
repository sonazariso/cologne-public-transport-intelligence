# Power BI Chat 16 — UX, Navigation & Interactions

**Status:** COMPLETE / CLOSED
**Audit date:** 2026-09-16
**Authoritative source:** `powerbi/CologneTransitIntelligence.pbip`

This handoff records the read-only UX audit required by `prompts/pbi40.md` and
the resulting scope decisions. The prompt file is treated as task
specification; it does not override repository or system instructions.

## Navigation

**Implementation:** retained the validated `pageNavigator` pattern from Phase
1. One navigator exists on each portfolio page `01` through `08` at
`X=32, Y=126, W=1216, H=24`.

Each navigator targets, in order:

1. `01 - Executive Overview`
2. `02 - Reliability`
3. `03 - Routes & Lines`
4. `04 - Stations & Stops`
5. `05 - Time Analysis`
6. `06 - Data Quality & Collector Health`
7. `07 - Situation & Platform Evidence`
8. `08 - Methodology`

`00 - Template` and Legacy QA pages `90` through `92` remain in the report
but are hidden from the portfolio navigator. The bounding-box audit found no
navigation overlap with analytical visuals. No navigation JSON was changed in
Chat 16 completion.

**Validation result:** PASS by the validated Phase 1 state and repository
audit. Use the Desktop checklist below for the final Windows VM smoke test.

## Read-only audit findings

All twelve report pages are `1280 x 720` and `FitToPage`. Portfolio pages have
the approved title/subtitle shell, navigation at `Y=126`, and analytical
content beginning at `Y=150`. The available layout is intentionally full, so
there is no stable user-facing filter zone that can accept a slicer without
shrinking or covering approved analytical content.

The model has 27 explicit relationships and 69 explicit measures. The
relationship paths relevant to UX are:

- `ActiveDate` filters `DailySchedule`, `RT_ReliabilityOutcome`, and
  `RT_ConsolidationQuality`.
- `Mode` filters `Route`, which filters both `DailySchedule` and
  `RT_ReliabilityOutcome`.
- `Route` filters both `DailySchedule` and `RT_ReliabilityOutcome`.
- `ParentStation` filters `StopPosition`, which filters
  `RT_ReliabilityOutcome`.
- `NetworkKPI`, `RT_ReliabilityByDimension`, `RT_DataQualityCoverage`, and
  `RT_CollectorRunHealth` do not share a general connected filter path with
  all portfolio facts. Their separation is intentional.

There are no report-level or page-level filters on pages `01` through `08`.
The existing visual filters are retained analytical definitions:

- Top 10 `Route[RouteShortName]` filters on the three route-detail visuals.
- Top 10 `ParentStation[ParentStationName]` / `StopPosition[StopId]`
  filters on the three station-detail visuals.
- `RT_ReliabilityByDimension[DimensionType] = "Hour"` on the Time Analysis
  helper visual.

## Slicer / Filter Strategy

**Decision:** no new visible slicers were added to pages `01` through `08`.

Fields evaluated were:

- `ActiveDate[DateValue]` — valid for the static schedule and realtime
  reliability paths, but not for the Collector Health path.
- `Mode[ModeDetail]` / `Mode[ModeGroup]` — valid through `Mode → Route` for
  schedule and reliability visuals, while disconnected baseline KPIs remain
  whole-network context by design.
- `Route[RouteShortName]` — valid for schedule and reliability paths, but the
  route pages already use intentional Top 10 visual filters.
- `ParentStation` / `StopPosition` — valid for the realtime station path, not
  for the static scheduled station-volume path.

The mixed static/realtime pages and the approved full-page layouts make a
portfolio slicer more likely to create confusing partial filtering than clear
analytical value. Page `06` especially must not imply that a Data Quality or
Collector date filters the other disconnected source. The existing sample
slicers on `00 - Template` and Legacy QA pages remain historical/reference
objects and are not portfolio controls.

**Fields used by new slicers:** none.
**Pages affected:** none.

## Sync Slicers

Sync Slicers evaluated and intentionally not implemented.

There are no new persistent slicers to synchronize. Synchronizing a shared
field onto `RT_CollectorRunHealth`, `RT_DataQualityCoverage`, or the
disconnected/helper tables would not be supported by the current model and
would weaken Page `06`'s Data Quality / Collector separation. Page `08` remains
explanatory and receives no analytical slicer.

## Visual Interactions

**Audit result:** existing Power BI default interaction behavior was retained;
no interaction definitions were changed.

The report has `defaultDrillFilterOtherVisuals = true`. Analytical visuals
retain their existing `drillFilterOtherVisuals` behavior; the two Page `06`
source tables intentionally do not add a manual override. The model and visual
bindings support these meaningful interaction groups:

- Pages `01` and `03`: Mode/Route selections can relate static scheduled
  visuals to connected realtime visuals. Disconnected baseline cards remain
  baseline context and are not presented as filtered sampled evidence.
- Page `02`: Mode-group selections on the reliability chart update the
  connected realtime reliability measures.
- Page `04`: Parent Station and Stop Position selections operate on the
  realtime station path. Static scheduled station-pattern context remains
  separate because `DailySchedule` has no station relationship.
- Page `05`: `ActiveDate` selections connect the scheduled and realtime date
  visuals. The disconnected hourly helper remains a separate cross-check and
  is fixed to `DimensionType = "Hour"`.
- Page `06`: Data Quality chart/cards use `RT_DataQualityCoverage`; Collector
  Health table/cards use `RT_CollectorRunHealth`. Their separation prevents
  Data Quality states from becoming Reliability outcomes.
- Page `07`: Platform Evidence categories and evidence measures share the
  connected realtime outcome path. `Changed`, `Unchanged`, and `Unknown`
  remain distinct, and Situation Evidence remains descriptive association,
  not causality.

The existing titles, notes, and measure names keep static scheduled metrics
distinct from sampled realtime evidence. No default interaction was found to
be misleading in the repository audit.

## Reset Filters

Reset Filters evaluated and intentionally not implemented.

No new visible slicer or persistent filter state was introduced, so a bookmark
reset pattern would add hidden state without solving a user-facing problem.

## Tooltips

The report already has enhanced tooltips enabled through
`report.json` (`useEnhancedTooltips = true`). Existing default tooltips are
sufficient for the current category, metric, value, and context bindings.

No custom tooltip page was needed. No decorative tooltip measures were added.
Existing terminology is preserved, including `Observed Estimated Delay`,
`Sampling Panel`, `Situation Evidence`, and `Changed` / `Unchanged` /
`Unknown`.

## Drill-through

Drill-through evaluated and intentionally not implemented.

Routes, Stations & Stops, and Time Analysis already provide the relevant
analytical views. No additional drill-through path would add validated value,
and no drill-through page or binding was added.

## Methodology page

Page `08 - Methodology` remains explanatory. It has no slicer, drill-through,
bookmark, or unnecessary interaction control; navigation is its only portfolio
control.

## Semantic guardrails

**PASS — unchanged.** The audit and completion preserve:

- `Observed Estimated Delay != Actual Delay`.
- No arbitrary On-Time threshold.
- `Situation Evidence != causality`.
- `Platform Unknown != Unchanged`.
- `StaticCoverageMissing` and `Unresolved` remain Data Quality states.
- No cancellation KPI.
- No departure KPI.
- Seven realtime locations remain a `Sampling Panel`.
- Repeated observations are not separate operational services.

No SQL, Collector, Power Query, TMDL relationship, DAX measure, analytical
definition, or Page 07 recovery repair was changed.

## Files changed

- `docs/19-POWER-BI-CHAT16-UX-NAVIGATION-AND-INTERACTIONS.md`

No PBIR file was structurally edited for this completion pass.

## PBIR validation

**PASS:** all 123 JSON files under
`powerbi/CologneTransitIntelligence.Report/definition/` strict-parse with
`jq`. The validated Page 07 repairs remain intact: `707c` has no
`sortDefinition`, and `707h` / `707i` have no `prototypeQuery` or
`dataTransforms` properties.

The report still contains 27 relationships, 69 measures, and no
bidirectional relationship declaration. The navigation target audit resolves
all eight portfolio targets on all eight navigators and hides Template/Legacy
QA destinations.

## Power BI Desktop QA checklist

In the Windows VM, open:

`Z:\cologne-public-transport-intelligence\powerbi\CologneTransitIntelligence.pbip`

Then verify:

1. The report opens without a PBIR warning and pages `01` through `08` render.
2. On every portfolio page, the navigator shows exactly pages `01` through
   `08`; click each destination and confirm the target page is correct.
3. Confirm the navigator does not expose `00`, `90`, `91`, or `92`.
4. Confirm the navigator does not cover or clip any analytical visual.
5. On Pages `01`, `02`, and `03`, select a Mode/Route chart category or table
   row and confirm the connected scheduled/reliability visuals cross-filter or
   highlight meaningfully. Baseline cards may remain whole-network context.
6. On Page `04`, select a Parent Station and Stop Position and confirm the
   realtime station visuals respond. Confirm static scheduled context is not
   presented as station-filtered realtime evidence.
7. On Page `05`, select a service date and confirm the scheduled and realtime
   date visuals respond through `ActiveDate`. Confirm missing realtime dates do
   not display as zero delay or perfect reliability.
8. On Page `06`, select a Data Quality date and a Collector Health target
   separately. Confirm each source group responds through its own existing
   path and that Data Quality states do not become Reliability outcomes.
9. On Page `07`, select each platform evidence state and table row. Confirm
   `Changed`, `Unchanged`, and `Unknown` stay distinct and that the page does
   not imply Situation Evidence is causal.
10. Hover representative chart categories, table rows, and KPI cards. Confirm
    default tooltips show category/metric/value/context and retain the approved
    terminology.
11. Confirm Page `08` remains readable and explanatory with navigation only.
12. Confirm there are no new slicers, reset bookmark, drill-through page, or
    hidden analytical state.

## Final status

Power BI Chat 16 — UX, Navigation & Interactions:

**COMPLETE / CLOSED**

Do not start Chat 17.
