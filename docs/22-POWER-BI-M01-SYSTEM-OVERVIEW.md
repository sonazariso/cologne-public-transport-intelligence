# Power BI M01 — System Overview

**Status:** PBIP/TMDL/PBIR source implementation complete; Power BI Desktop refresh, rendering, and interaction QA remain runtime steps.

## Purpose

`M01 - System Overview` is the first report page for nontechnical managers. It answers:

- Which transport modes and routes are in the current static network?
- Which network parent stations exist, and which stations are actually monitored in realtime?
- What realtime source period is covered?
- How many scheduled trips are comparable in that same scope, and how many have a valid matched realtime estimate?
- What share of observed matched trips is on time, delayed, or early?
- Which mode and monitored station perform best and worst on the same on-time metric?

The page uses the current `Mode` dimension, so the authoritative seven mode categories remain selectable rather than hard-coded in the report.

## Defensible comparison cohort

`analytics.vwManagementComparableTrip` is a clean management-facing view. Its grain is one row per scheduled trip and enabled monitored station, keyed by `ServiceDate + TripKey + SamplingTargetId`. A deterministic `IsTripLevelRecord` flag identifies exactly one canonical row per `ServiceDate + TripKey` for overall trip counts.

The comparable scheduled cohort is restricted to:

1. scheduled service dates between the local dates of the realtime source observations;
2. the current authoritative mode dimension; and
3. scheduled stop events at the enabled realtime monitored-station scope.

Observed matched trips are the same cohort with a consolidated operational outcome and a nonblank estimated arrival/difference. Repeated realtime observations are consolidated upstream in `dw.FactOperationalStopOutcome`; they are not counted as additional trips.

The page never compares the realtime sample with the full static schedule total. `Comparable Scheduled Trips` and `Observed Matched Trips` use the same date and monitored-station scope.

## Measures and behavior

The M01 measures are in `_Measures` under display folder `09 M01 System Overview`, with the source definitions mirrored in `powerbi/measures/M01SystemOverviewMeasures.dax`.

Required measures include:

- `Comparable Scheduled Trips`
- `Observed Matched Trips`
- `Realtime Observation Coverage %`
- `On-Time Trips`, `Delayed Trips`, `Early Trips`
- `On-Time %`, `Delayed %`, `Early %`
- `Average Schedule Difference Minutes`
- `Average Absolute Schedule Gap Minutes`

The `Delay Threshold (Minutes)` parameter is a disconnected 0–15 minute slicer and defaults to 0 when no value is selected. For a trip with `difference = observed estimated arrival - scheduled arrival`:

- On Time: `ABS(difference) <= threshold`
- Delayed: `difference > threshold`
- Early: `difference < -threshold`

Best/worst mode and monitored-station cards use the same `On-Time %` metric. Ties are deterministic: lower average absolute schedule gap, then higher comparable-trip count, then alphabetical name.

## Scope labels and limitations

- Network parent-station counts are static network scope; monitored-station counts are the enabled realtime collector scope. They are shown separately.
- Realtime timestamps are estimated arrival observations, not confirmed physical arrivals.
- Missing realtime observations are not classified as cancellations.
- The collector run history records target sampling, but does not establish run-by-run eligibility for every scheduled trip. `Realtime Observation Coverage %` therefore remains blank and the page shows a plain-language limitation instead of an invalid denominator-based percentage.
- The seven monitored stations are a sample of Cologne, not the full citywide realtime network.

## Validation

Run `sql/05-analytics/06-validate-management-overview.sql` after the analytics views are deployed. It checks view presence, source period, distinct trip grain, canonical-row uniqueness, monitored-station scope, and reconciliation of the zero-minute on-time/delayed/early buckets to valid observed matched trips.

Power BI Desktop remains required for Import Refresh, page rendering, slicer cross-filtering, accessibility checks, and final visual reconciliation.
