# Power BI M01 — System Overview

**Status:** PBIP/TMDL/PBIR source implementation complete; Power BI Desktop refresh, rendering, and interaction QA remain runtime steps.

## Purpose

`M01 - System Overview` is the manager-facing first report page. It shows the
monitored realtime scope alongside the full network baseline, the actual
monitoring period, comparable scheduled trips, observed realtime trips, and
punctuality.

M01 does not use the full static GTFS trip total as its plan-versus-realtime
KPI. The comparison is limited to scheduled trips that have a legitimate
operational outcome in the trusted realtime reliability dataset.

## Refresh-safe data design

M01-specific SQL views are not required. The two M01 helper partitions use
Power Query `Value.NativeQuery` against database objects already used by the
working semantic model:

- `analytics.vwRealtimeReliabilityOutcome` supplies the canonical trip and
  station/stop helpers.
- `analytics.vwRealtimeCollectorRunHealth` supplies successful sampling-panel
  target activity and collection dates.

`ManagementComparableTrip` is one row per `ServiceDate + TripKey`. The
canonical row prefers a nonblank final estimated delay, then the latest
observation timestamp, latest scheduled arrival, and the operational outcome
key. It keeps only fields required by M01.

`ManagementTripStation` is one row per `ServiceDate + TripKey + StopKey` and
uses the already consolidated operational outcome. It supports station
punctuality, best/worst monitored station, and distinct observed stop-position
counts without counting repeated realtime observations as extra services.

`ManagementMonitoredStation` is derived from successful records marked
`ParticipatedInSamplingPanel = TRUE`. The page therefore distinguishes the
realtime sampling panel from the complete `ParentStation` network dimension.

## Measures and behavior

M01 measures are stored in `_Measures` under display folder
`09 M01 System Overview`; the source mirror is
`powerbi/measures/M01SystemOverviewMeasures.dax`.

The page includes measures for comparable scheduled trips, observed realtime
trips, on-time/delayed/early counts and percentages, observed stop positions,
network parent stations, realtime monitored stations, monitoring start/end,
distinct observed days, route count, best/worst mode, best/worst monitored
station, and the dynamic system-status sentence.

The `Delay Threshold (Minutes)` parameter remains a disconnected 0–15 minute
slicer and defaults to 0. For `difference = final observed estimated delay`:

- On Time: `ABS(difference) <= threshold`
- Delayed: `difference > threshold`
- Early: `difference < -threshold`

The three buckets are mutually exclusive and collectively reconcile to
`Observed Realtime Trips` in every Mode/Date context. Missing realtime timing
is not classified as a cancellation.

Best and worst comparisons use the same primary metric, `On-Time %`. Ties are
resolved by lower average absolute schedule difference, higher observed trip
count, and alphabetical name.

`Realtime Observed Days` is a distinct count of actual collection dates; it is
not a calendar-span calculation. No citywide observation-coverage percentage
is reported.

## Page design

Only the `M01 - System Overview` page is rebuilt. It contains:

- a navy header with the dynamic status summary;
- Transport Mode, Service Date / Date Range, and Delay Threshold filters;
- network/period and service KPI rows;
- Routes by Transport Mode;
- Scheduled vs Realtime Trips by Transport Mode;
- Punctuality of Observed Trips;
- On-Time Rate by Transport Mode;
- separate searchable network-station and realtime-monitored-station controls;
- best/worst mode and monitored-station summaries; and
- one concise sampling-panel scope note.

M01 formatting is applied directly to the page and its visuals. The global
registered report theme and every other report page remain unchanged.

## Refresh workflow

The intended user workflow is:

1. Open the PBIP in Power BI Desktop.
2. Select **Apply external changes**.
3. Select **Refresh now**.

No M01-specific SQL deployment or validation script is required before the
refresh.

Power BI Desktop remains required for Import Refresh, page rendering,
slicer cross-filtering, accessibility checks, and final visual reconciliation.
