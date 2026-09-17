# Power BI M01 — Network & Delay Overview

**Status:** PBIP/TMDL source implementation complete; Power BI Desktop refresh, render, and interaction validation remain runtime steps.

## Purpose

`M01 - Network & Delay Overview` is a management-facing page organized around:

`Problem → Impact → Evidence → Priority → Action`

It answers what the network operates, how much service is planned, what the selected realtime sampling panel observes, and where observed estimated delay is highest. The page uses `Mode[ModeDetail]` and the model's seven values rather than hard-coded category labels.

## Page and visuals

- Page title: `Cologne Public Transport – Network & Delay Overview`.
- Subtitle: `What do we operate? How much service is planned? What do we observe? Where are the biggest delays?`.
- KPI cards: baseline transport modes, baseline routes, parent stations with a separate stop-position support value, scheduled trips, and observed matched services.
- Donuts: scheduled trips by transport mode and observed services by transport mode.
- Delay chart: median and P95 observed estimated delay by transport mode, sorted by P95 descending.
- Summary table: routes, scheduled trips and share, observed services and share, median delay, P95 delay, typical scheduled duration, and typical route length by transport mode.
- Key Insights panel: dynamic largest planned mode, highest typical delay, highest severe delay, and observed sample composition.
- Permanent scope note: `Realtime findings represent the selected Cologne Sampling Panel, not full-network realtime coverage.`

Cross-filter behavior is intentionally left connected through the shared `Mode[ModeDetail]` field. Selecting a mode in either donut filters the other donut, delay chart, summary table, and dynamic insights.

## Measures

The semantic model adds thirteen measures in `_Measures`, in display folder `08 Management Overview`:

- `Mode Share of Observed Services`
- `Routes`
- `% of Scheduled Trips`
- `% of Observed Services`
- `Median Delay`
- `P95 Delay`
- `Typical Scheduled Duration`
- `Typical Route Length`
- `Parent Station KPI Support`
- `Insight Largest Planned Mode`
- `Insight Highest Typical Delay`
- `Insight Highest Severe Delay`
- `Insight Observed Sample Composition`

The four insight measures are filter-aware and return no-data messages when the selected mode/date context has no valid evidence. They do not contain sample counts or percentages as hard-coded display values.

`Mode Share of Scheduled Trips` and `Mode Share of Observed Services` remove
the complete `Mode` table in their denominators, preserving other applicable
filters. The M01 validation query returns one row per mode plus unfiltered
share totals so a refresh can confirm both distributions sum to 100%.

## Model and metric boundaries

- The new disconnected `ScheduledTripProfile` import is an analytics
  projection at one row per scheduled trip pattern. `TREATAS` applies the
  current Route and Mode context to its measures, so the existing relationship
  topology and operational fact grain remain unchanged.
- `Observed Matched Services` remains the connected `RT_ReliabilityOutcome` count and represents the selected Sampling Panel, not all Cologne realtime services.
- Delay labels use observed estimated delay. They do not claim confirmed physical arrival delay.
- A mode with no observations is not presented as having zero delay; the delay measures and insight measures remain blank/no-evidence in that context.
- `Typical Scheduled Duration` is the median of per-trip values derived from
  the first scheduled departure and final scheduled arrival in the persisted
  `FactScheduledStopEvent` rows. GTFS after-midnight seconds remain normalized
  schedule seconds; no route-wide earliest/latest span is used.
- `Typical Route Length` is the median terminal `ShapeDistanceTraveled` value
  per scheduled trip. The VRS source snapshot has numeric distance values on
  all 3,818,617 `stop_times` rows; every trip terminal value equals its
  per-trip maximum, and all 153 Cologne routes have terminal values; 144 of
  those routes vary across trip patterns. The [GTFS Schedule
  Reference](https://gtfs.org/documentation/schedule/reference/) defines
  `shape_dist_traveled` in the same units as `shapes.txt`, but the VRS source
  feed metadata does not name the unit. A
  geometry-scale check across 13,695 shapes produced a median reported/
  geodesic-kilometre ratio of 1.0010 (P05 1.0008, P95 1.0013), with no
  monotonicity failures. This direct geometry check supports the validated
  kilometre scale used by the model; the metric is therefore explicitly
  labelled `km`.

## Formatting and reconciliation

- Human-readable count measures use `#,0`.
- Management delay measures use `#,0.0` minutes.
- Typical scheduled duration uses `#,0.0 min`; typical route length uses
  `#,0.0 km`.
- Percentages use `0.0%`.
- Technical identifiers, route names, years, dates, times, codes, GTFS IDs, and keys retain identifier-safe formatting.
- Report-level `defaultDisplayUnitsToNone` remains enabled so the measure format strings control visible values.
- The scheduled-trip KPI and donut use `[Scheduled Trips]`; the current full-baseline reconciliation reference is `1,878,944` occurrences from the approved static baseline snapshot, not a hard-coded visual value.
- Baseline reference counts from the approved snapshot are 7 modes, 153 routes, 866 parent stations, and 2,290 stop positions. Runtime refresh validation must confirm the PBIP model returns those values.
- The unfiltered scheduled-occurrence shares are: Urban Bus (KVB) 48.8758%,
  Stadtbahn / Tram 26.6130%, Regional / Other Bus 11.9108%, S-Bahn 4.2792%,
  Rail Replacement Bus (SEV) 2.9706%, Regional Express (RE) 2.7102%, and
  Regional Bahn (RB) 2.6405% (100.0000% total). Observed-service shares are
  intentionally computed from the refreshed Sampling Panel fact rather than
  copied into the PBIR.

## Validation status

Source-level checks should confirm valid JSON, a page-order entry for the new page, preserved existing page IDs and active page, valid measure references, no hard-coded realtime numbers, and no unsupported route-length units. Power BI Desktop is required to complete import refresh, visual rendering, cross-filter interaction, accessibility, and final total reconciliation.
