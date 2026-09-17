# Power BI M01 — Network & Delay Overview

**Status:** PBIP/TMDL source implementation complete; Power BI Desktop refresh, render, and interaction validation remain runtime steps.

## Purpose

`M01 - Network & Delay Overview` is a management-facing page organized around:

`Problem → Impact → Evidence → Priority → Action`

It answers what the network operates, how much service is planned, what the selected realtime sampling panel observes, and where observed estimated delay is highest. The page uses `Mode[ModeDetail]` and the model's seven values rather than hard-coded category labels.

## Page and visuals

- Page title: `Cologne Public Transport – Network & Delay Overview`.
- Subtitle: `What do we operate? How much service is planned? What do we observe? Where are the biggest delays?`.
- KPI cards: baseline transport modes, baseline routes, baseline parent stations plus stop positions, scheduled trips, and observed matched services.
- Donuts: scheduled trips by transport mode and observed services by transport mode.
- Delay chart: median and P95 observed estimated delay by transport mode, sorted by P95 descending.
- Summary table: routes, scheduled trips and share, observed services and share, median delay, and P95 delay by transport mode.
- Key Insights panel: dynamic largest planned mode, highest typical delay, highest severe delay, and observed sample composition.
- Permanent scope note: `Realtime findings represent the selected Cologne Sampling Panel, not full-network realtime coverage.`

Cross-filter behavior is intentionally left connected through the shared `Mode[ModeDetail]` field. Selecting a mode in either donut filters the other donut, delay chart, summary table, and dynamic insights.

## Measures

The semantic model adds ten measures in `_Measures`, in display folder `08 Management Overview`:

- `Mode Share of Observed Services`
- `Routes`
- `% of Scheduled Trips`
- `% of Observed Services`
- `Median Delay`
- `P95 Delay`
- `Insight Largest Planned Mode`
- `Insight Highest Typical Delay`
- `Insight Highest Severe Delay`
- `Insight Observed Sample Composition`

The four insight measures are filter-aware and return no-data messages when the selected mode/date context has no valid evidence. They do not contain sample counts or percentages as hard-coded display values.

## Model and metric boundaries

- No relationships or warehouse tables were changed for M01.
- `Observed Matched Services` remains the connected `RT_ReliabilityOutcome` count and represents the selected Sampling Panel, not all Cologne realtime services.
- Delay labels use observed estimated delay. They do not claim confirmed physical arrival delay.
- A mode with no observations is not presented as having zero delay; the delay measures and insight measures remain blank/no-evidence in that context.
- Typical route length and typical scheduled duration are not shown as fabricated values. The current imported model exposes route-level earliest/latest schedule seconds but not a trip-level schedule profile, and `ShapeDistanceTraveled` source units have not been validated for this model. Those columns remain pending source-unit validation and model exposure.

## Formatting and reconciliation

- Human-readable count measures use `#,0`.
- Management delay measures use `#,0.0` minutes.
- Percentages use `0.0%`.
- Technical identifiers, route names, years, dates, times, codes, GTFS IDs, and keys retain identifier-safe formatting.
- Report-level `defaultDisplayUnitsToNone` remains enabled so the measure format strings control visible values.
- The scheduled-trip KPI and donut use `[Scheduled Trips]`; the current full-baseline reconciliation reference is `1,878,944` occurrences from the approved static baseline snapshot, not a hard-coded visual value.
- Baseline reference counts from the approved snapshot are 7 modes, 153 routes, 866 parent stations, and 2,290 stop positions. Runtime refresh validation must confirm the PBIP model returns those values.

## Validation status

Source-level checks should confirm valid JSON, a page-order entry for the new page, preserved existing page IDs and active page, valid measure references, no hard-coded realtime numbers, and no unsupported route-length units. Power BI Desktop is required to complete import refresh, visual rendering, cross-filter interaction, accessibility, and final total reconciliation.
