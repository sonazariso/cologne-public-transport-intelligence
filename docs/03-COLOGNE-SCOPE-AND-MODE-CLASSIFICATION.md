# Cologne Scope and Transport-Mode Classification

## Purpose

This document defines how the regional VRS/go.Rheinland GTFS feed is converted into a Cologne-focused, multimodal analytical scope. The rules are explicit because route inclusion and mode classification directly affect every later KPI, comparison, and management recommendation.

## Source and Analytical Scope Are Different

The source feed is regional and contains 30,719 stop records, 981 route records, and 167,386 trips. It must not be treated as if every source row describes service inside Cologne.

The analytical boundary is currently defined by the global stop-ID prefix:

```text
de:05315:
```

The `05315` segment identifies the municipality of Cologne within the global-ID convention used by this feed. This is an explicit technical boundary rule, not a geographic guess based on route operator or route name.

## Inclusion Rules

The working layer applies the following rules in order:

1. **Cologne stop:** a stop record whose `stop_id` begins with `de:05315:`.
2. **Cologne-serving trip:** a trip with at least one scheduled stop event at a Cologne stop.
3. **Cologne-serving route:** a route referenced by at least one Cologne-serving trip.
4. **Cologne scheduled stop event:** a `stop_times` row occurring at a Cologne stop for a Cologne-serving trip.

This service-based definition is deliberately independent of the operator. It includes KVB services as well as DB Regio, National Express, trans regio, RVK, REVG, wupsi, and other operators when their services stop in Cologne.

## Why a Route Is Not Filtered by Operator

Filtering only for KVB would exclude S-Bahn, RE, RB, regional buses, and services operated by companies other than KVB. Filtering by the text “Köln” in route names would also be unreliable because many relevant routes do not contain the city name. A stop-based inclusion rule is reproducible and aligned with the actual service delivered in the city.

## Stop Hierarchy

The Cologne prefix returns 3,156 stop records:

| Stop level | Records | Interpretation |
|---|---:|---|
| Parent station (`location_type = 1`) | 866 | Logical station grouping |
| Stop position / mast (`location_type = 0`) | 2,290 | Physical boarding position |
| Stop positions referenced by schedules | 2,287 | Positions used by `stop_times` |

Parent stations are retained for reporting and station-level rollups. They are not expected to appear directly in scheduled stop events. Three stop positions are present in the source but unused by the current timetable snapshot.

## Why `route_type` Alone Is Not Sufficient

GTFS `route_type` provides the broad vehicle category:

- `0`: tram/light rail
- `2`: rail
- `3`: bus

However, the management questions require more useful categories. For example, `route_type = 2` does not distinguish S-Bahn, RE, and RB. In this source, some rail-replacement services are correctly encoded as buses because the actual replacement vehicle is a bus. Treating every `route_type = 3` row as a normal bus route would therefore mix planned bus operations with disruption-related replacement services.

## Classification Rules

Classification uses source attributes in a controlled order:

| Source condition | Analytical classification |
|---|---|
| `route_type = 0` | Stadtbahn / Tram |
| `route_type = 2` and route label begins with `S` followed by a number | S-Bahn |
| `route_type = 2` and route label begins with `RE` | Regional Express (RE) |
| `route_type = 2` and route label begins with `RB` | Regional Bahn (RB) |
| `route_type = 3` and agency or route label indicates `SEV`, `RE`, `RB`, or S-Bahn | Rail Replacement Bus (SEV) |
| `route_type = 3` and `agency_id = 1` | Urban Bus (KVB) |
| Remaining `route_type = 3` | Regional / Other Bus |

The broad GTFS type remains available next to the analytical category. This preserves traceability and allows the classification to be audited or revised without changing the raw source.

## Independently Profiled Baseline

The current snapshot produces the following scope:

| Mode | Routes | Trips | Scheduled stop events in Cologne |
|---|---:|---:|---:|
| Stadtbahn / Tram | 12 | 33,156 | 623,801 |
| S-Bahn | 5 | 4,714 | 48,722 |
| Regional Express (RE) | 12 | 2,880 | 8,796 |
| Regional Bahn (RB) | 7 | 2,188 | 8,395 |
| Urban Bus (KVB) | 60 | 38,104 | 826,099 |
| Regional / Other Bus | 27 | 4,276 | 22,874 |
| Rail Replacement Bus (SEV) | 30 | 5,013 | 12,656 |
| **Total** | **153** | **90,331** | **1,551,343** |

These are route IDs, scheduled trip records, and scheduled stop events—not counts of physical vehicles or passengers.

## Working-Layer Objects

| Object | Grain | Purpose |
|---|---|---|
| `wrk.vwCologneStop` | One row per Cologne stop record | Typed coordinates and stop hierarchy |
| `wrk.vwCologneServingRoute` | One row per Cologne-serving route ID | Route and mode classification |
| `wrk.vwCologneServingTrip` | One row per Cologne-serving trip ID | Trip-to-route and mode relationship |
| `wrk.vwCologneScheduledStopEvent` | One row per scheduled trip-stop event in Cologne | Typed schedule sequence and time |
| `wrk.vwCologneModeSummary` | One row per analytical mode | Reconciliation and profiling |

Views are appropriate at this stage because the source snapshot is already indexed, the rules remain fully visible, and no second physical copy is needed before the dimensional warehouse design is finalized.

## GTFS Time Handling

GTFS permits service-day times after midnight such as `24:15:00` or `25:05:00`. SQL Server's `TIME` data type cannot represent those values without changing their meaning. The working layer therefore converts scheduled times to seconds after the start of the service day and also retains the original text.

For example:

```text
25:05:00 = 90,300 seconds = service-day offset 1 plus 01:05:00
```

This prevents after-midnight trips from being assigned to the wrong operational day.

## Known Boundaries

- The current layer represents scheduled service (`GTFS-SOLL`), not actual operations.
- Delay, cancellation, vehicle-position, and alert analysis requires GTFS Realtime or another operational source.
- ICE/IC, ferry, cable car, shared bicycle, scooter, and car-sharing services are not present in the current Cologne route scope.
- The global-ID prefix is a strong initial municipality rule, but a later geographic boundary check can compare stop coordinates with an official Cologne polygon.
- A route serving Cologne may also operate outside the city. Current stop-event metrics include only events occurring at Cologne stops.

## Defence Questions

### Why are there 3,156 Cologne stops but only 2,287 used stops?

The larger number includes 866 parent stations plus 2,290 physical stop positions. Scheduled stop events reference physical positions, not parent groupings. Of the physical positions, 2,287 are used in the current timetable.

### Why are there more bus-like route records than ordinary bus routes?

Thirty `route_type = 3` routes are rail-replacement services. GTFS describes the replacement vehicle as a bus, but the analytical purpose differs from a regular bus service. They are separated as `SEV` to avoid distorting bus-performance analysis.

### Why retain the original GTFS route type?

The derived category supports management reporting, while the original value provides lineage back to the source. Keeping both prevents the transformation from becoming a black box.

### Does the current data measure delays?

No. It provides the scheduled baseline. A delay is calculated only after an actual or predicted timestamp from GTFS Realtime is matched to the scheduled event.

### Does “Cologne-serving” mean the entire trip happens inside Cologne?

No. It means the trip has at least one stop in Cologne. This includes cross-boundary services, but the current stop-event view counts only their events within the city boundary.

