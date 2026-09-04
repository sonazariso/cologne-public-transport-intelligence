# Database Design and SQL Server Implementation

**Last updated:** 2026-09-04

## 1. Platform

- Database: `CologneTransitIntelligence`
- Database engine: **SQL Server 2025 Developer (17.x)**
- Administration: SSMS
- Reporting: Power BI Desktop
- Development environment: Windows 11 VM in VMware Fusion

Earlier documentation references to SQL Server 2022 are superseded by the current 2025 development installation.

## 2. Schema Contracts

| Schema | Responsibility |
|---|---|
| `ctl` | load/audit controls |
| `stg` | source-faithful static and realtime staging |
| `wrk` | typing, normalization, matching, derived logic |
| `dw` | validated dimensions, bridges, facts |
| `analytics` | business-facing views |

## 3. Static Staging

The validated static GTFS tables include:

- `stg.GtfsAgency`
- `stg.GtfsCalendar`
- `stg.GtfsCalendarDates`
- `stg.GtfsFeedInfo`
- `stg.GtfsFrequencies`
- `stg.GtfsRoutes`
- `stg.GtfsShapes`
- `stg.GtfsStopTimes`
- `stg.GtfsStops`
- `stg.GtfsTransfers`
- `stg.GtfsTrips`

## 4. Realtime Staging Tables

### `stg.MddRealtimeStopObservation`

Current logical columns:

- `ObservationKey` bigint PK
- `ObservedAtUtc` datetime2 NOT NULL
- `ResultId` nvarchar NOT NULL
- `StopPointRef` nvarchar NOT NULL, `Latin1_General_100_BIN2`
- `StopName` nvarchar NULL
- `LineName` nvarchar NULL
- `LineRef` nvarchar NULL
- `JourneyRef` nvarchar NOT NULL
- `DirectionRef` nvarchar NULL
- `OperatorRef` nvarchar NULL
- `PtMode` nvarchar NULL
- `RailSubmode` nvarchar NULL
- `TimetabledArrivalUtc` datetime2 NULL
- `EstimatedArrivalUtc` datetime2 NULL
- `CreatedAtUtc` datetime2 NOT NULL
- `PlannedBay` nvarchar NULL
- `EstimatedBay` nvarchar NULL

`ArrivalDelayMinutes` is intentionally derived in `wrk`, not stored in staging.

A unique index exists on `(ObservedAtUtc, ResultId)` in the validated design.

### `stg.MddRealtimeSituationObservation`

- `SituationObservationKey`
- `ObservedAtUtc`
- `ParticipantRef`
- `SituationNumber`
- `Summary`
- `Description`
- `Detail`
- `ValidFromUtc`
- `ValidToUtc`
- `CreatedAtUtc`

### `stg.MddRealtimeStopSituationLink`

- `ObservationKey`
- `SituationObservationKey`
- `RelationScope`
- `CreatedAtUtc`

The composite primary key covers observation, situation, and scope. Foreign keys reference both parent staging tables. `RelationScope` is restricted to `CALL` or `SERVICE`.

## 5. Realtime Working Views

### `wrk.vwCologneRealtimeStopObservation`

Derives:

- `ArrivalDelayMinutes`
- nullable `PlatformChanged`

`PlatformChanged` rules:

- `EstimatedBay` missing -> `NULL`
- both values present and different -> `1`
- both values present and equal -> `0`

### `wrk.vwCologneRealtimeStopEnriched`

Adds:

- `StaticParentStationId`
- `StaticStopName`
- `StaticStopMatched`

Primary enrichment rule:

```text
TRIAS StopPointRef = GTFS StopId
```

### `wrk.vwCologneRealtimeTripMatchKey`

Adds:

- `TimetabledArrivalLocal`
- `ServiceDateLocal`
- `ScheduledArrivalSecondsLocal`

### `wrk.vwCologneRealtimeTripMatch`

Adds candidate counts and final static matching fields:

- `ExactStopCandidateCount`
- `ParentStationCandidateCount`
- `MatchStatus`
- `MatchedTripId`
- `MatchedRouteId`
- `MatchedServiceId`
- `MatchedStaticStopId`

### `wrk.vwCologneRealtimeEvidenceSituation`

Combines realtime evidence, static match quality, and linked situations. It also exposes:

```text
HasUsableStaticMatch bit NOT NULL
```

Usable statuses are `ExactStopMatch` and `ParentStationFallback`.

## 6. Collation Conflict and Fix

A SQL Server 468 conflict occurred because realtime `StopPointRef` initially used `SQL_Latin1_General_CP1_CI_AS` while static GTFS `StopId` used `Latin1_General_100_BIN2`.

The staging column was corrected to `Latin1_General_100_BIN2`, then `sys.sp_refreshview` was run on `wrk.vwCologneRealtimeStopObservation` because its view metadata still exposed the old collation.

This resolved the exact stop join.

## 7. Static Warehouse Objects Used by Matching

- `dw.DimAgency`
- `dw.DimDate`
- `dw.DimService`
- `dw.BridgeServiceDate`
- `dw.FactScheduledTrip`
- `dw.FactScheduledStopEvent`

`dw.DimService` maps natural `ServiceId` to `ServiceKey`; `dw.BridgeServiceDate` proves whether that service is active on a date.

## 8. Timezone and GTFS Service-Day Matching

All current relevant agencies use `Europe/Berlin`. SQL Server conversion uses:

```sql
AT TIME ZONE 'UTC'
AT TIME ZONE 'W. Europe Standard Time'
```

Matching formulas:

```text
ServiceDate = LocalCalendarDate - ArrivalDayOffset
ScheduledArrivalSeconds = LocalSecondsOfDay + ArrivalDayOffset * 86400
```

Validated `ArrivalDayOffset` values are 0, 1, and 2.

## 9. Match Hierarchy

```text
1. StaticCoverageMissing
2. ExactStopMatch
3. ParentStationFallback
4. Unresolved
```

Order is evaluated so an exact match wins over a parent fallback. A route absent from static coverage is reported separately from an unresolved covered route.

## 10. Validated Match Examples

| Line | Result |
|---|---|
| ICE | `StaticCoverageMissing` |
| RE 7 | `ExactStopMatch` |
| RB 27 | `ParentStationFallback` |
| RB 25 | `ExactStopMatch` |
| RE 9 | `ExactStopMatch` |

RB27 validated a real platform mismatch: TRIAS reported Gleis 3 while static GTFS matched the service at Gleis 4.

## 11. Static Validation Baseline

| Metric | Value |
|---|---:|
| Agencies | 15 |
| Modes | 7 |
| Cologne-serving routes | 153 |
| Cologne stop records | 3,156 |
| Service patterns | 3,947 |
| Feed dates | 364 |
| Active service-date pairs | 99,399 |
| Scheduled trip patterns | 90,331 |
| Scheduled stop-event patterns | 1,551,343 |
| Scheduled trip occurrences | 1,878,944 |

## 12. Persistence Checkpoint

Realtime table structures and views have been prepared. Before enabling the production collector, row counts of the three realtime staging tables must be checked and the exact email-confirmed storage/retention terms recorded.

The project must not assume a retention duration until the confirmation email wording is transcribed.

## 13. SQL Server File Access

GTFS `BULK INSERT` paths must be readable by the SQL Server Database Engine service account. VMware shared-folder visibility to the interactive Windows user does not by itself prove SQL Server service access.

## 14. Power BI Boundary

Power BI reads validated `analytics` views, not raw `stg` tables. Realtime analytics views should be created only after the collector produces stable historical data and consolidated operational grains are defined.
