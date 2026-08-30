# Power BI Static Baseline Build Guide

## Objective

Build a portfolio-ready Power BI report that communicates the planned public-transport supply represented by the validated GTFS snapshot. The model is intentionally separated from future realtime performance analysis.

## 1. Connect to SQL Server

Open Power BI Desktop in the Windows VM and select:

```text
Home → Get data → SQL Server
```

Use:

```text
Server: localhost
Database: CologneTransitIntelligence
Data connectivity mode: Import
```

Import is selected because the analytics datasets are compact and refresh only after the SQL warehouse is rebuilt. It provides faster report interaction and a portable portfolio file without the runtime dependency and latency of DirectQuery.

## 2. Select Analytics Views

Select these seven views from the `analytics` schema:

| SQL view | Power BI table name |
|---|---|
| `vwNetworkBaselineKpi` | `NetworkKPI` |
| `vwModeScheduleProfile` | `Mode` |
| `vwRouteScheduleProfile` | `Route` |
| `vwActiveDateProfile` | `ActiveDate` |
| `vwDailyScheduledTripProfile` | `DailySchedule` |
| `vwStopPositionScheduleProfile` | `StopPosition` |
| `vwParentStationScheduleProfile` | `ParentStation` |

Choose **Transform Data** before loading and rename the queries exactly as shown. Stable short names make DAX easier to read and maintain.

## 3. Verify Data Types

| Table/column | Data type or category |
|---|---|
| `ActiveDate[DateValue]` | Date |
| `DailySchedule[DateValue]` | Date |
| All `...Key`, count, year, month, and sort columns | Whole number |
| `Latitude`, `Longitude` | Decimal number |
| `Latitude` | Data category: Latitude |
| `Longitude` | Data category: Longitude |
| Columns beginning with `Is...` | True/False |
| Route, agency, station, and mode labels | Text |

Do not convert GTFS seconds to Power BI Time without applying the day offset. Values can exceed 86,400 because GTFS permits times after `24:00:00`.

## 4. Build the Semantic Model

Create these one-to-many relationships with single-direction filtering:

```text
Mode[ModeKey]       1 ─── * Route[ModeKey]
Route[RouteKey]     1 ─── * DailySchedule[RouteKey]
ActiveDate[DateKey] 1 ─── * DailySchedule[DateKey]
```

`DailySchedule` is the central daily planned-supply fact.

`NetworkKPI`, `StopPosition`, and `ParentStation` remain disconnected reporting marts. They intentionally represent full-snapshot or geographic aggregates at different grains; connecting them directly to the daily fact would create misleading filter behavior without a route-stop bridge.

Do not enable bidirectional filtering. The documented one-direction model avoids ambiguous paths and makes filter propagation predictable.

## 5. Date and Sorting Configuration

In Model view:

1. Mark `ActiveDate` as the Date table using `DateValue`.
2. Sort `ActiveDate[MonthName]` by `CalendarMonth`.
3. Sort `ActiveDate[WeekdayName]` by `IsoWeekdayNumber`.
4. Sort `Mode[ModeDetail]` by `ModeSortOrder`.
5. Hide technical keys from Report view after relationships are complete.

These steps prevent alphabetical month/weekday ordering and keep transport categories in a stable business order.

## 6. Create Measures

Create the measures stored in:

```text
powerbi/measures/StaticBaselineMeasures.dax
```

The central measure is:

```DAX
Scheduled Trips =
SUM ( DailySchedule[ScheduledTripCount] )
```

Always use measures rather than dragging raw numeric fields directly into visuals. Measures provide consistent aggregation and make later realtime extensions easier.

Measures beginning with `Baseline` use the disconnected one-row `NetworkKPI` table and always represent the complete snapshot. They are not intended to change with daily or route slicers.

## 7. Import the Theme

Select:

```text
View → Themes → Browse for themes
```

Import:

```text
powerbi/theme/cologne-transit-baseline-theme.json
```

The palette separates the dominant supply categories while keeping the report neutral and portfolio-ready. SEV should use the warning/accent color rather than the same color as ordinary buses.

## 8. Report Pages

### Page 1 — Scheduled Network Overview

Header:

```text
Cologne Public Transport — Scheduled Network Baseline
```

Subtitle:

```text
Validated static GTFS snapshot | Planned supply, not actual operational performance
```

Recommended visuals:

- Cards: `Baseline Agencies`, `Baseline Routes`, `Baseline Parent Stations`, `Baseline Active Service Dates`.
- Clustered bar: `Mode[ModeDetail]` and `[Scheduled Trips]`.
- Line chart: `ActiveDate[DateValue]` and `[Scheduled Trips]`.
- Cards: `[Average Scheduled Trips per Active Day]` and `[Weekend Share]`.
- Slicers: date, mode, agency, route.

Use `DailySchedule` measures for visuals that must react to dates. Use `NetworkKPI` measures only for full-snapshot cards.

### Page 2 — Mode and Route Profile

- Top-N horizontal bar: `Route[RouteShortName]` by `[Scheduled Trips]`.
- Matrix: mode, agency, route, scheduled trips.
- Cards: routes and agencies in the current context.
- Slicers: mode, agency, and active date.

Do not interpret trip count as passenger demand, capacity, vehicle kilometres, or punctuality.

### Page 3 — Stop and Station Coverage

- Stop-position map using latitude and longitude.
- Bubble size: `ScheduledStopEventPatternCount`.
- Tooltips: parent station, served routes, trip patterns, and use status.
- Parent-station map or table on a separate visual.

Stop-position and parent-station visuals represent the complete snapshot and do not respond to daily route filters in this first model. This limitation is explicit until a validated route-stop bridge is introduced.

### Page 4 — Methodology and Data Quality

Show:

- source and feed version;
- scheduled coverage dates;
- layer architecture;
- definitions of pattern versus occurrence;
- validation status;
- current limitations and realtime roadmap.

This page is essential for defensible interpretation and portfolio review.

## 9. Save the Artifact

Save the report into the shared repository as:

```text
powerbi/CologneTransitScheduledBaseline.pbix
```

Before committing the `.pbix`, confirm that it contains no credentials, tokens, realtime endpoint secrets, or raw local file paths that should remain private.

## Defence Questions

### Why is the model not connected directly to staging?

Staging stores source-faithful text and is designed for ingestion. The report uses validated business categories and stable grains from the analytics layer, preventing duplicated transformation logic in Power Query or DAX.

### Why are some tables disconnected?

They have different grains. A one-row network snapshot, a physical-stop aggregate, and a daily route fact cannot be connected safely without additional bridging keys. Keeping them disconnected is more accurate than creating a relationship that produces misleading cross-filtering.

### Why are baseline cards unaffected by date slicers?

They describe the complete published snapshot. Date-responsive visuals use the daily fact; full-snapshot cards are intentionally separated and labelled `Baseline`.

### Why not call this a reliability dashboard?

Static GTFS proves what was scheduled, not what occurred. Reliability requires dated realtime observations matched to the scheduled trip and stop sequence.

