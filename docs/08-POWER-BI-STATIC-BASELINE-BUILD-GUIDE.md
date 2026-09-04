# Power BI Static Baseline Build Guide

**Last updated:** 2026-09-04

## Objective

Build and maintain a portfolio-ready Power BI report for the validated **static GTFS scheduled-service baseline**. Realtime database integration now exists, but it must remain separate from this baseline until historical collection and consolidated operational facts are validated.

## 1. Connect to SQL Server

```text
Home -> Get data -> SQL Server
Server: localhost
Database: CologneTransitIntelligence
Data connectivity mode: Import
```

## 2. Import Static Analytics Views

| SQL view | Power BI table name |
|---|---|
| `vwNetworkBaselineKpi` | `NetworkKPI` |
| `vwModeScheduleProfile` | `Mode` |
| `vwRouteScheduleProfile` | `Route` |
| `vwActiveDateProfile` | `ActiveDate` |
| `vwDailyScheduledTripProfile` | `DailySchedule` |
| `vwStopPositionScheduleProfile` | `StopPosition` |
| `vwParentStationScheduleProfile` | `ParentStation` |

Do not import `stg` or `wrk` realtime views into the static baseline model merely because they now exist.

## 3. Data Types

- date columns -> Date
- key/count/sort columns -> Whole number
- latitude/longitude -> Decimal number with appropriate data categories
- `Is...` columns -> True/False
- labels -> Text

Do not convert GTFS scheduled seconds directly to Power BI `Time`; GTFS values may exceed 24 hours.

## 4. Relationships

Use one-to-many, single-direction relationships:

```text
Mode[ModeKey]       1 --- * Route[ModeKey]
Route[RouteKey]     1 --- * DailySchedule[RouteKey]
ActiveDate[DateKey] 1 --- * DailySchedule[DateKey]
```

Keep `NetworkKPI`, `StopPosition`, and `ParentStation` disconnected in the current static model because their grains differ from the daily route fact.

## 5. Date and Sorting Configuration

- mark `ActiveDate` as the Date table using `DateValue`;
- sort month name by calendar month;
- sort weekday name by ISO weekday number;
- sort mode detail by mode sort order;
- hide technical keys from Report view after relationships are complete.

## 6. Measures

Use the checked-in measure file:

```text
powerbi/measures/StaticBaselineMeasures.dax
```

Central measure:

```DAX
Scheduled Trips =
SUM ( DailySchedule[ScheduledTripCount] )
```

Always prefer explicit measures over dragging raw numeric columns directly into visuals.

## 7. Theme

Import:

```text
powerbi/theme/cologne-transit-baseline-theme.json
```

Keep SEV visually distinct from ordinary buses.

## 8. Recommended Pages

### Page 1 — Scheduled Network Overview

Subtitle should explicitly state:

```text
Validated static GTFS snapshot | Planned supply, not actual operational performance
```

### Page 2 — Mode and Route Profile

Route ranking, mode profile, matrix, and slicers.

### Page 3 — Stop and Station Coverage

Maps/tables for physical stop positions and parent stations at their correct grains.

### Page 4 — Planned Daily Service

Date trend, weekday/weekend comparison, mode/route filters.

### Page 5 — Methodology and Data Quality

Show feed version, scope, pattern-vs-occurrence definitions, validation status, architecture, and realtime roadmap.

## 9. Realtime Integration Note

The database now contains realtime working views such as:

- `wrk.vwCologneRealtimeTripMatch`
- `wrk.vwCologneRealtimeEvidenceSituation`

These are validation/engineering objects, not yet the semantic source of the static baseline report.

Before adding reliability visuals, the project must have:

1. approved and documented storage/retention terms;
2. a scheduled collector;
3. sufficient historical observation coverage;
4. consolidated dated stop/trip outcomes;
5. documented delay/cancellation thresholds;
6. validated realtime analytics views.

## 10. Save Artifact

```text
powerbi/CologneTransitScheduledBaseline.pbix
```

Verify that the PBIX contains no credentials, tokens, or sensitive local configuration before sharing or committing it.
