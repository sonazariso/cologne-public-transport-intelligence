# Cologne Scope and Transport-Mode Classification

**Last updated:** 2026-09-04

## 1. Purpose

This document defines the Cologne analytical boundary and transport-mode classification used by the static GTFS model, and explains how realtime services outside that static scope are handled.

## 2. Cologne Boundary

A static GTFS stop is considered part of the Cologne analytical scope when its `stop_id` begins with:

```text
de:05315:
```

The derived scope is service-based:

1. Cologne stop: matching stop prefix.
2. Cologne-serving trip: at least one scheduled event at a Cologne stop.
3. Cologne-serving route: referenced by a Cologne-serving trip.
4. Cologne scheduled stop event: stop-time row occurring at a Cologne stop.

This avoids operator-only or route-name-only filtering.

## 3. Stop Hierarchy

| Stop level | Records | Meaning |
|---|---:|---|
| Parent station | 866 | Logical station grouping |
| Stop position / mast | 2,290 | Physical boarding position |
| Used stop positions | 2,287 | Referenced by schedules |

Parent stations support management rollups; physical stop positions support operational matching.

At Köln Hbf, the static feed contains both the parent station and individual platform stops, for example:

```text
de:05315:11201        -> Köln Hbf
de:05315:11201:7:78   -> Köln Hbf (Gleis 8)
```

TRIAS `StopPointRef` values can therefore match GTFS platform-level `StopId` values directly when both sources agree.

## 4. Mode Classification Rules

| Source condition | Analytical classification |
|---|---|
| `route_type = 0` | Stadtbahn / Tram |
| `route_type = 2` and label `S` + number | S-Bahn |
| `route_type = 2` and label begins `RE` | Regional Express (RE) |
| `route_type = 2` and label begins `RB` | Regional Bahn (RB) |
| `route_type = 3` and agency/route indicates SEV/rail replacement | Rail Replacement Bus (SEV) |
| `route_type = 3` and `agency_id = 1` | Urban Bus (KVB) |
| remaining `route_type = 3` | Regional / Other Bus |

The original GTFS route type is retained next to the analytical category for lineage.

## 5. Validated Static Baseline

| Mode | Routes | Trips | Scheduled stop events |
|---|---:|---:|---:|
| Stadtbahn / Tram | 12 | 33,156 | 623,801 |
| S-Bahn | 5 | 4,714 | 48,722 |
| Regional Express (RE) | 12 | 2,880 | 8,796 |
| Regional Bahn (RB) | 7 | 2,188 | 8,395 |
| Urban Bus (KVB) | 60 | 38,104 | 826,099 |
| Regional / Other Bus | 27 | 4,276 | 22,874 |
| Rail Replacement Bus (SEV) | 30 | 5,013 | 12,656 |

## 6. GTFS Service-Day Time

GTFS times may exceed 24 hours. The model retains the text and derives seconds after service-day midnight.

Validated examples:

```text
24:00:00 -> 86,400 seconds -> ArrivalDayOffset 1
24:01:00 -> 86,460 seconds -> ArrivalDayOffset 1
48:50:00 -> 175,800 seconds -> ArrivalDayOffset 2
49:23:00 -> 177,780 seconds -> ArrivalDayOffset 2
```

Observed arrival-day offsets in the current Cologne schedule:

- `0`: 1,488,108 stop-event patterns
- `1`: 63,231
- `2`: 4

## 7. Realtime Line Normalization

TRIAS line labels may contain spacing differences relative to GTFS, for example:

```text
TRIAS: RE 9
GTFS:  RE9
```

The current match logic normalizes by removing spaces before comparing line labels. This is a controlled matching aid, not a replacement for source identifiers.

## 8. Static Coverage vs Realtime Coverage

The static Cologne GTFS scope does not currently contain ICE/IC. DELFI/TRIAS can still return ICE events at Köln Hbf.

Therefore realtime matching distinguishes:

```text
StaticCoverageMissing
```

from:

```text
Unresolved
```

A missing static route is a coverage limitation; an unresolved match means static coverage exists but the evidence is insufficient or ambiguous.

## 9. Platform-Level vs Parent-Station Matching

Exact platform matching is preferred, but a validated RB27 example demonstrated that realtime and static platform assignments can differ:

```text
TRIAS: Gleis 3 -> de:05315:11201:7:73
GTFS:  Gleis 4 -> de:05315:11201:7:74
```

The route, time, active service date, and parent station uniquely identified the same service. This case is classified as:

```text
ParentStationFallback
```

rather than discarded.

## 10. Working-Layer Objects

Static scope:

- `wrk.vwCologneStop`
- `wrk.vwCologneServingRoute`
- `wrk.vwCologneServingTrip`
- `wrk.vwCologneScheduledStopEvent`
- `wrk.vwCologneModeSummary`

Realtime enrichment/matching:

- `wrk.vwCologneRealtimeStopObservation`
- `wrk.vwCologneRealtimeStopEnriched`
- `wrk.vwCologneRealtimeTripMatchKey`
- `wrk.vwCologneRealtimeTripMatch`
- `wrk.vwCologneRealtimeEvidenceSituation`
