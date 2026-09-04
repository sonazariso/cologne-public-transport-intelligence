# Data Sources and GTFS Profile

**Last updated:** 2026-09-04

## 1. Purpose

This document records the validated static GTFS source and the currently tested realtime source for Cologne Public Transport Intelligence.

## 2. Static VRS/go.Rheinland GTFS Snapshot

- Publisher: VRS / go.Rheinland
- Feed version: `VERSION__20260829_0050`
- Feed start date: `2025-12-14`
- Feed end date: `2026-12-12`
- Profile date: `2026-08-29`

Raw source files are stored locally and excluded from Git.

### Source row counts

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

## 3. Initial Cologne Static Scope

The validated Cologne prefix is:

```text
de:05315:
```

| Metric | Count |
|---|---:|
| Cologne stop records | 3,156 |
| Parent stations | 866 |
| Stop positions / masts | 2,290 |
| Stop positions referenced by schedules | 2,287 |
| Cologne-serving routes | 153 |
| Cologne-serving trips | 90,331 |
| Cologne scheduled stop-event patterns | 1,551,343 |

## 4. Static Transport Modes

| Mode | Routes | Trips | Cologne scheduled stop events |
|---|---:|---:|---:|
| Stadtbahn / Tram | 12 | 33,156 | 623,801 |
| S-Bahn | 5 | 4,714 | 48,722 |
| Regional Express (RE) | 12 | 2,880 | 8,796 |
| Regional Bahn (RB) | 7 | 2,188 | 8,395 |
| Urban Bus (KVB) | 60 | 38,104 | 826,099 |
| Regional / Other Bus | 27 | 4,276 | 22,874 |
| Rail Replacement Bus (SEV) | 30 | 5,013 | 12,656 |
| **Total** | **153** | **90,331** | **1,551,343** |

## 5. Important Static Data-Quality Findings

- `frequencies.txt` contains no data rows.
- `routes.txt` contains one duplicated `route_id`, `be:sncb:S41:`, with different agency IDs. Staging preserves both source rows.
- The regional feed must be scoped to Cologne rather than treated as city-only data.
- Parent stations are grouping entities and are not expected to be scheduled stop-time positions.
- Static GTFS cannot measure actual delay, cancellation, or disruption on its own.
- ICE/IC services are not represented in the current Cologne static route/trip scope.

## 6. MDD NRW Realtime Source

The current validated realtime source is the **direct DELFI interface** exposed by MDD NRW. It uses the VDV 431 TRIAS protocol.

### Endpoint

```text
POST https://mdd.gorheinland.com/delfi
```

### Request requirements

```text
Header: x-api-key: <API key>
Content-Type: application/xml
Body: TRIAS 1.2 XML
```

A successful request has been executed with `StopEventRequest`, `StopEventType=arrival`, `IncludePreviousCalls=true`, `IncludeOnwardCalls=true`, and `IncludeRealtimeData=true`.

## 7. MDD Access and Request Limit

MDD NRW access is client/API-key based. The current approved planning limit for this project is:

**250,000 requests per month**

Collector frequency must be designed against this limit rather than assuming unlimited polling.

## 8. Successful TRIAS Test Snapshot

A tested response returned HTTP `200` and five stop-event results. The sample included:

| Line | StopPointRef | Planned UTC | Estimated UTC | Delay |
|---|---|---|---|---:|
| ICE | `de:05315:11201:7:77` | 19:14 | 19:41 | 27 min |
| RE 7 | `de:05315:11201:7:72` | 19:17 | 20:02 | 45 min |
| RB 27 | `de:05315:11201:7:73` | 19:35 | 19:58 | 23 min |
| RB 25 | `de:05315:11201:7:81` | 19:36 | 19:44 | 8 min |
| RE 9 | `de:05315:11201:7:78` | 19:37 | 19:42 | 5 min |

The response also exposed line/journey references, planned bays, optional estimated bays, and situation references/context.

## 9. Realtime Situation Examples

Validated situation numbers in the sample include:

- `ZTP-PROD-132377` — no barrier-free boarding/alighting at the affected location;
- `ZTP-PROD-138201` — disruption in the greater Mönchengladbach area related to construction/overhead-line work;
- `ZTP-PROD-138150` — Hoffnungsthal information/construction-related stop issue.

These are contextual evidence. They are not automatically treated as proven causes of every linked delay.

## 10. Realtime Coverage Differs from Static Coverage

The TRIAS sample contained an ICE arrival, while the current static Cologne GTFS route/trip views contain no ICE records. The matching layer therefore records this case as:

```text
StaticCoverageMissing
```

This is a source-coverage issue, not a matching error.

## 11. Storage / Retention Compliance Status

A confirmation email has been received regarding realtime data storage/retention. The exact conditions will be copied into project documentation after the email text is provided. No retention duration or legal condition is inferred in advance.
