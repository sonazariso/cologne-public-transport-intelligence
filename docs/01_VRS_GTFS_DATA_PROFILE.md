# Initial VRS GTFS Data Profile

## Purpose

This document records the first validation of the static VRS GTFS source for the Cologne multimodal public transport analytics project. It confirms data availability and scope before any SQL Server schema is designed.

## Source Snapshot

- Publisher: VRS
- Source: VRS mast-accurate GTFS feed based on global IDs
- Feed version: `VERSION__20260829_0050`
- Feed start date: `2025-12-14`
- Feed end date: `2026-12-12`
- Profile date: `2026-08-29`

The raw files are stored locally and are intentionally excluded from GitHub.

## Files and Record Counts

| GTFS file | Data rows |
|---|---:|
| `agency.txt` | 36 |
| `calendar.txt` | 6,337 |
| `calendar_dates.txt` | 1,025,387 |
| `feed_info.txt` | 1 |
| `frequencies.txt` | 0 |
| `routes.txt` | 981 |
| `shapes.txt` | 1,742,925 |
| `stop_times.txt` | 3,818,617 |
| `stops.txt` | 30,719 |
| `transfers.txt` | 1,708 |
| `trips.txt` | 167,386 |

## Initial Cologne Scope

For this initial profile, Cologne stops were identified using the global stop-ID prefix `de:05315:`. This technical filter must be validated before it becomes a permanent business rule.

| Metric | Count |
|---|---:|
| Cologne stop records | 3,156 |
| Parent stations (`location_type = 1`) | 866 |
| Stop positions / masts (`location_type = 0`) | 2,290 |
| Stops referenced by `stop_times.txt` | 2,287 |
| Routes serving at least one Cologne stop | 153 |
| Trips serving at least one Cologne stop | 90,331 |
| Stop-time records at Cologne stops | 1,551,343 |

## Transport Modes Observed

| GTFS route type | Initial interpretation | Routes | Trips |
|---:|---|---:|---:|
| 0 | Tram / Stadtbahn | 12 | 33,156 |
| 2 | Rail / S-Bahn / regional rail | 24 | 9,782 |
| 3 | Bus | 117 | 47,393 |

These counts confirm that the source supports a substantial multimodal Cologne case study. More detailed classification—particularly separating S-Bahn, RE, RB, and other rail services—must be derived from the actual route and agency attributes rather than assumed from `route_type` alone.

## Data-Quality Observations

- The feed contains no data rows in `frequencies.txt`; scheduled service is represented through trips, stop times, and service calendars.
- `routes.txt` contains one duplicated `route_id`: `be:sncb:S41:`. The two source rows have different `agency_id` values (`159` and `5`) while their other route attributes match. Raw staging must preserve both rows; the ambiguity will be resolved explicitly in transformation rather than hidden by a staging constraint.
- The Cologne prefix identifies 3,156 stop records: 866 parent stations and 2,290 stop positions/masts. Of those stop positions, 2,287 are referenced by `stop_times.txt`; three are currently unused. Parent stations organize child stop positions and are not expected to appear in scheduled stop times.
- The feed is regional, so the Cologne analytical scope must be derived rather than treating the entire feed as Cologne data.
- Global stop IDs provide a useful initial geographic filter, but boundary and cross-city route behavior still require validation.
- Static GTFS describes scheduled service and cannot measure actual delay, cancellation, or disruption performance without realtime or event data.

## Next Step

Profile agencies, routes, route names, and stop geography for the 153 Cologne-serving routes. Use those results to define defensible transport-mode classifications and the exact Cologne inclusion rule before designing the SQL Server staging model.
