# Power BI Measure Layer

**Status:** Chat 05 complete — 2026-09-15

All report measures belong to the disconnected `_Measures` home table in the PBIX. The table contains one hidden placeholder column/row only; it has no relationships.

## Source files

- `StaticBaselineMeasures.dax` — folders 01–02.
- `RealtimeReliabilityMeasures.dax` — folders 03–07.
- `ManagementOverviewMeasures.dax` — folder 08 and the dynamic Key Insights text measures.

These files are the source-controlled DAX definitions. Display-folder metadata is configured in the PBIX and documented below.

## Display folders

### 01 Static Schedule

- Scheduled Trips
- Active Dates in Context
- Routes in Context
- Agencies in Context
- Average Scheduled Trips per Active Day
- Weekday Scheduled Trips
- Weekend Scheduled Trips
- Weekend Share
- Mode Share of Scheduled Trips

### 02 Network Baseline

- Baseline Agencies
- Baseline Modes
- Baseline Routes
- Baseline Parent Stations
- Baseline Stop Positions
- Baseline Used Stop Positions
- Baseline Active Service Dates
- Baseline Scheduled Trip Patterns
- Baseline Scheduled Trip Occurrences
- Baseline Scheduled Stop-Event Patterns
- Used Stop Positions
- Unused Stop Positions

### 03 Realtime Reliability

- Observed Matched Services
- Delay Observations
- Average Observed Estimated Delay (min)
- Median Observed Estimated Delay (min)
- P95 Observed Estimated Delay (min)
- Minimum Observed Estimated Delay (min)
- Maximum Observed Estimated Delay (min)
- Average Observations per Outcome

### 04 Evidence

- Situation-Linked Outcomes
- Situation Evidence Share
- Platform Changed Evidence Outcomes
- Platform Changed Evidence Share
- Platform Unchanged Evidence Outcomes
- Platform Unchanged Evidence Share
- Platform Unknown Evidence Outcomes
- Platform Unknown Evidence Share

### 05 Consolidation

- Operational Outcomes
- Usable Realtime Observations
- Repeated Observations Consolidated
- Consolidation Reduction Share
- Observations per Operational Outcome

### 06 Data Quality

- Realtime Source Observations
- Matched View Observations
- Exact Stop Matches
- Parent Station Fallback Matches
- Static Coverage Missing
- Unresolved Matches
- Usable Matches
- Exact Stop Match Rate
- Parent Station Fallback Rate
- Static Coverage Missing Rate
- Unresolved Match Rate
- Usable Match Rate
- Observations with Estimated Bay
- Estimated Bay Availability Rate
- Observations with Situation Evidence
- Situation Evidence Availability Rate
- Situation Links

### 07 Collector Health

- Collector Runs
- Successful Collector Runs
- Failed Collector Runs
- Incomplete Collector Runs
- Successful Automatic Runs
- Completed Collector Runs
- Collector Success Rate
- Sampling Panel Targets Observed
- Average Successful Run Duration (sec)

### 08 Management Overview

- Mode Share of Observed Services
- Routes
- % of Scheduled Trips
- % of Observed Services
- Median Delay
- P95 Delay
- Insight Largest Planned Mode
- Insight Highest Typical Delay
- Insight Highest Severe Delay
- Insight Observed Sample Composition

## Formatting conventions

- Count measures: Whole number with a thousands separator (`#,0`).
- Delay measures: One decimal minute value (`#,0.0`) for management-facing views; the measure name retains the observed-estimated qualifier.
- `Average Observations...` and duration: Decimal number with two decimals (`#,0.00`).
- Share/rate measures: Percentage with one decimal (`0.0%`).
- Technical identifiers, route names, years, dates, times, codes, GTFS IDs, and keys retain identifier-safe formatting.

## Semantic notes

- `RT_ReliabilityOutcome` is the connected operational reliability fact and should drive slicer-responsive reliability measures.
- `RT_ReliabilityByDimension` remains disconnected and is a SQL cross-check/helper, not the primary DAX fact.
- Data Quality rates are recomputed from summed counts rather than averaging daily percentages.
- `NetworkKPI` stays disconnected; baseline measures intentionally remain whole-network values under connected-model filters.
- The current model is single-direction. Do not introduce bidirectional relationships solely to make dimension counts respond to unrelated dimension filters.
- The management page uses `Mode[ModeDetail]` for the seven model values: Urban Bus, Stadtbahn / Tram, Regional Bus, S-Bahn, RE, RB, and SEV.
- Route length and scheduled-duration metrics are intentionally not synthesized in the management page: the current imported model does not expose trip-level duration or validated `ShapeDistanceTraveled` units.
