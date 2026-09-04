# Static GTFS Analytical Warehouse Model

**Last updated:** 2026-09-04

## 1. Purpose

The static warehouse materializes the validated Cologne schedule baseline and provides the dimensions/service calendar required for realtime matching.

## 2. Warehouse Grain

| Object | Grain |
|---|---|
| `dw.DimAgency` | one relevant GTFS agency |
| `dw.DimMode` | one analytical mode |
| `dw.DimRoute` | one Cologne-serving route ID |
| `dw.DimStop` | one Cologne stop or parent station |
| `dw.DimService` | one GTFS service pattern |
| `dw.DimDate` | one calendar date |
| `dw.BridgeServiceDate` | one active service/date pair |
| `dw.FactScheduledTrip` | one GTFS trip pattern |
| `dw.FactScheduledStopEvent` | one Cologne stop sequence of one trip pattern |

## 3. Static Baseline Counts

| Object | Rows |
|---|---:|
| Agencies | 15 |
| Modes | 7 |
| Routes | 153 |
| Stops | 3,156 |
| Service patterns | 3,947 |
| Feed dates | 364 |
| Active service-date pairs | 99,399 |
| Scheduled trip patterns | 90,331 |
| Scheduled stop-event patterns | 1,551,343 |

Scheduled trip occurrences expanded across active dates: **1,878,944**.

## 4. Pattern vs Dated Occurrence

A GTFS `TripId` is a schedule template. Realtime matching requires a dated operational occurrence.

```text
scheduled trip occurrence = TripId + service date
scheduled stop occurrence = TripId + service date + StopSequence
```

The current TRIAS matching method cannot use direct `JourneyRef = TripId` equality because the two systems use different identifier schemes.

## 5. Service Calendar

`dw.DimService` maps natural `ServiceId` to `ServiceKey`. `dw.BridgeServiceDate` contains the active dates after weekday rules and `calendar_dates.txt` exceptions are applied.

This bridge is a core part of realtime candidate filtering.

## 6. GTFS After-Midnight Time

GTFS scheduled seconds remain relative to service-day midnight and can exceed 86,400.

Validated current data:

| ArrivalDayOffset | Stop-event count | Min seconds | Max seconds |
|---:|---:|---:|---:|
| 0 | 1,488,108 | 10,260 | 86,340 |
| 1 | 63,231 | 86,400 | 111,120 |
| 2 | 4 | 175,800 | 177,780 |

The four offset-2 events are an S12 trip with times from `48:50:00` to `49:23:00`.

## 7. Realtime Matching Use of the Warehouse

For each TRIAS realtime event:

1. Convert UTC scheduled timestamp to Berlin local time.
2. Calculate local calendar date and local seconds-of-day.
3. Join to scheduled stop-event candidates by normalized line and scheduled seconds adjusted by `ArrivalDayOffset`.
4. Use `DimService + BridgeServiceDate + DimDate` to require an active service date.
5. Prefer exact `StopId` matching.
6. If no exact match exists, allow one unique candidate at the same parent station.

## 8. Validated RE9 Example

TRIAS:

```text
Line: RE 9
StopPointRef: de:05315:11201:7:78
Planned UTC: 2026-09-03 19:37
```

Berlin local:

```text
2026-09-03 21:37 +02:00
```

After active-service filtering, only `ServiceId = 67358` remained, producing one GTFS trip candidate to Aachen Hbf.

## 9. Platform Fallback Example

RB27 matched the route/time/service at Köln Hbf but static GTFS used Gleis 4 while TRIAS reported Gleis 3. Because the parent station matched uniquely, the event is classified `ParentStationFallback`.

## 10. Static Coverage Gap Example

The static Cologne route/trip views contain no ICE rows, while TRIAS returned an ICE event. This is `StaticCoverageMissing`, not `Unresolved`.

## 11. Warehouse Extension Principle

Realtime observations must not overwrite static scheduled facts. Future warehouse design should preserve separate grains for:

- raw realtime observation;
- consolidated dated stop performance;
- consolidated dated trip performance;
- situation/disruption evidence.

This prevents repeated predictions from being counted as repeated services.
