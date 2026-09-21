# Power BI M02 — Station Coverage & Performance

**Status:** M02 source corrections are applied on the dedicated branch.
Power BI Desktop Import Refresh, rendering, interaction, and the final save
round-trip remain runtime validation steps and are not claimed complete here.

## Business purpose and scope

M02 answers one management question:

> At station level, where is performance better or worse, and what realtime
> coverage do we actually have?

The page includes only the context needed to interpret station performance:

- Network Stations, Realtime Monitored Stations, Observed Stop Positions,
  Observed Realtime Trips, On-Time %, and Delayed % as secondary KPIs;
- On-Time Rate by Monitored Station, ranked by On-Time %;
- Observed Realtime Trips by Monitored Station, ranked by observed volume;
- Best and Worst Performing Monitored Station callouts;
- the monitored-station detail table;
- a full-network Network Station Search and coverage-status message;
- the Station versus Stop Position explanation; and
- a compact Transport Mode Guide.

M02 deliberately excludes route, mode-ranking, delay-trend, time-of-day,
delay-reason, disruption, cancellation, forecast, recommendation, and full
Matched / Usable Timing / Timing Unavailable reconciliation visuals. Those
topics belong to M01 or later management pages.

## Data grain and counting rule

M02 reuses the deployed management views:

- `analytics.vwManagementComparableTrip` — one row per
  `ServiceDate + TripKey` for overall context KPIs;
- `analytics.vwManagementTripStation` — one row per
  `ServiceDate + TripKey + StopKey`; and
- `analytics.vwManagementMonitoredStation` — one row per collection date and
  monitored sampling-panel target.

`vwManagementTripStation` is intentionally at trusted stop-position grain.
Its `Station` label is the parent-station label for the outcome. M02 station
measures distinct-count `ManagementTripKey` within the current monitored
station context, using `TREATAS` from
`ManagementMonitoredStation[MonitoredStationName]` to
`ManagementTripStation[Station]`. A trip with multiple stop positions at one
station is counted once for that station. The same dated trip may legitimately
appear at more than one monitored station and is counted once in each station
context. As a result, station-level trip counts are not an additive
reconciliation to the overall unique observed-trip count.

No new SQL view was required; the existing management analytics layer already
provides the trusted grain. The SQL creation comments and read-only validation
script document and check both within-station stop-position multiplicity and
the allowed cross-station trip repetition.

## Measures and filter behavior

M02 reuses the shared measures in `_Measures` and the source mirror
`powerbi/measures/M01SystemOverviewMeasures.dax`:

- `Station Observed Realtime Trips`;
- `Station On-Time Trips` and `Station On-Time %`;
- `Station Delayed Trips` and `Station Delayed %`;
- `Station Observed Stop Positions` for the detail-table station context;
- `Observed Stop Positions` for the page-level context KPI; and
- `Best Performing Monitored Station` / `Worst Performing Monitored Station`.

M02-specific helpers are `M02 Network Stations` and `M02 Network Station
Coverage Status`; the first keeps the full-network KPI invariant to the lookup
selection, while the second communicates whether a selected network station
has monitoring evidence under the current filters.

The On-Time Rate chart, Observed Realtime Trips chart, and Monitored Station
Detail table all use `ManagementMonitoredStation[MonitoredStationName]` as
their category/row source. `showAll` remains enabled, and the station volume
measure returns zero when no matching trip rows exist. This keeps a monitored
station identifiable for the selected monitoring period while the percentage
measures remain blank when their observed-trip denominator is zero.

The station measures count a trip once within a station and inherit the same
`Delay Threshold (Minutes)` parameter as M01. The definition is unchanged:

- On Time: `ABS(delay) <= threshold`;
- Delayed: `delay > threshold`; and
- Early: `delay < -threshold`.

M02 includes the same Transport Mode, Service Date / Date Range, Delay
Threshold, and Effective Threshold context as M01. Mode and date selections
recalculate station volume, punctuality, callouts, and the detail table.
Changing the threshold changes On-Time Trips, Delayed Trips, On-Time %, and
Delayed %, but it does not change the pure-volume `Station Observed Realtime
Trips` measure.

The new `M02 Network Stations` helper keeps the Network Stations KPI as the
full static network count when a station is selected in the lookup slicer. It
does not change the frozen M01 page.

## Station ranking and sample protection

The On-Time chart sorts only by `Station On-Time %`. The volume chart sorts
only by `Station Observed Realtime Trips`; it does not normalize or combine
volume with punctuality.

The Best and Worst callouts use On-Time % as their only ranking criterion.
Alphabetical station name order is used only to make an equal-percentage tie
deterministic. Stations with no observed realtime trips are excluded, and the
callout displays the observed-trip sample beside the percentage. No new
minimum-sample business rule was introduced because the project has no
approved threshold for one; introducing one later must be explicit and
configurable rather than silently embedded in DAX.

## Network station lookup

`ParentStation[ParentStationName]` supplies the Network Station Search from
the full static network. The separate Realtime Monitored Stations list is
backed by `ManagementMonitoredStation`, so the page does not imply that every
static network station has realtime evidence.

The lookup is scope and lookup only. The selected network station is reported
in the dynamic Selected Network Station Coverage card:

- an unmonitored station displays “No realtime monitoring data available for
  this station in the selected period.”;
- a monitored station with no observations matching the selected filters is
  explicitly distinguished from an unmonitored station; and
- a monitored station with evidence displays its observed realtime trip
  volume.

The lookup does not create zero-valued punctuality metrics for an unmonitored
station or cross-filter the station performance comparisons.

## R2-2 correction record

- The invalid `drillFilterOtherVisuals` property was removed from the
  `visual.visualContainerObjects` object in `m02networkstatus` and kept at the
  valid `visual` level.
- `Station Observed Stop Positions` was added because the detail table now
  uses the monitored-station dimension rather than the trip-station fact
  column. It counts distinct observed `StopKey` values in the current station,
  mode, and date context.
- The detail table explicitly sets `visual.objects.total.show` to `false`; no
  calculated station total was added. Power BI Desktop still needs to confirm
  the rendered result after opening and saving the PBIP.
- No SQL view, M01 page file, `diagramLayout.json`, or later-report content was
  added or changed by this correction.

## Station versus Stop Position

The visible page explains the distinction in plain language:

- **Station** — the monitored station/location used for management reporting.
- **Stop Position** — the physical boarding location, platform, bay, or stop
  position inside or associated with the station.

A station can contain multiple stop positions. Therefore Observed Stop
Positions may be greater than Realtime Monitored Stations.

## Validation status

Completed source-level checks for this correction include:

- branch isolation on `feature/powerbi-m02-station-performance`;
- valid JSON for the M02 page and all M02 visuals;
- the `m02networkstatus` drill-filter property at the valid PBIR level;
- all three station-performance visual row/category bindings using
  `ManagementMonitoredStation[MonitoredStationName]`;
- station-specific trip, punctuality, and stop-position measures using the
  monitored-station-to-trip-station mapping;
- station chart sort definitions bound to the correct independent measures;
- the Effective Threshold visual bound to the shared display measure;
- the Network Stations KPI remaining independent of the lookup selection;
- all required detail-table columns present and an explicit disabled total-row
  setting;
- no current station or stop-position counts in visible explanatory text;
- all referenced M02 measures present in the semantic model;
- the frozen M01 page files remaining unchanged; and
- the M02 page remaining finite-height with all lower-page content visible in
  the existing FitToPage layout.

The read-only SQL grain checks are in
`sql/05-analytics/06-validate-m01-management-views.sql`. Power BI Desktop is
still required to run Import Refresh, verify the actual slicer interactions,
confirm zero-observation station visibility, confirm the rendered absence of
the detail-table Total row, inspect accessibility/readability, perform the
normal save round-trip, and review the resulting Git diff. Those runtime
checks were not run in this macOS workspace because Power BI Desktop is not
available here, so no runtime pass is claimed. `diagramLayout.json` is not
intentionally edited.
