# Static Analytics and Power BI Baseline

## Purpose

The analytics layer exposes small, business-readable views over the validated warehouse. It supports an initial Power BI portfolio report while realtime access is pending.

This report is a **scheduled-service baseline**, not a reliability dashboard. It describes planned network coverage and service supply but cannot yet measure actual delay, cancellation, disruption, or vehicle performance.

## Layer Responsibilities

| Layer | Responsibility |
|---|---|
| `stg` | Preserve the source faithfully |
| `wrk` | Apply transparent scope and classification rules |
| `dw` | Materialize validated dimensions and facts |
| `analytics` | Present business-readable reporting datasets |
| Power BI | Visual interaction, measures, narrative, and decision support |

## Analytics Views

| View | Grain | Expected rows | Primary use |
|---|---|---:|---|
| `analytics.vwNetworkBaselineKpi` | Whole scheduled network | 1 | KPI cards |
| `analytics.vwModeScheduleProfile` | Transport mode | 7 | Mode comparison |
| `analytics.vwRouteScheduleProfile` | Route | 153 | Route ranking and drill-through |
| `analytics.vwActiveDateProfile` | Active service date | 182 | Date dimension and calendar filtering |
| `analytics.vwStopPositionScheduleProfile` | Physical stop position | 2,290 | Map and stop analysis |
| `analytics.vwParentStationScheduleProfile` | Parent station | 866 | Management station rollup |
| `analytics.vwDailyScheduledTripProfile` | Active date and route | 20,059 | Daily planned service trend |

## Baseline KPIs

| KPI | Value | Correct interpretation |
|---|---:|---|
| Agencies | 15 | Operators with Cologne-serving routes |
| Modes | 7 | Derived analytical transport categories |
| Routes | 153 | GTFS route IDs serving Cologne |
| Parent stations | 866 | Logical station groupings |
| Stop positions | 2,290 | Physical boarding positions/masts |
| Used stop positions | 2,287 | Positions referenced by the schedule |
| Service patterns | 3,947 | GTFS calendar patterns |
| Active service dates | 182 | Dates with at least one active relevant service |
| Scheduled trip patterns | 90,331 | GTFS trip templates |
| Scheduled trip occurrences | 1,878,944 | Trip templates expanded across active dates |
| Scheduled stop-event patterns | 1,551,343 | In-city stop events before date expansion |

## Pattern Counts Versus Occurrence Counts

- **Trip pattern:** one `trip_id` template in GTFS.
- **Trip occurrence:** one trip pattern scheduled on one active date.
- **Stop-event pattern:** one stop sequence belonging to a trip pattern.
- **Actual stop event:** a dated operational event derived from realtime data later.

Calling a trip pattern an “actual trip” would overstate what static GTFS proves.

## Scheduled Trip Occurrences by Mode

| Mode | Scheduled trip occurrences |
|---|---:|
| Stadtbahn / Tram | 500,043 |
| S-Bahn | 80,403 |
| Regional Express (RE) | 50,923 |
| Regional Bahn (RB) | 49,613 |
| Urban Bus (KVB) | 918,349 |
| Regional / Other Bus | 223,797 |
| Rail Replacement Bus (SEV) | 55,816 |
| **Total** | **1,878,944** |

These counts measure planned supply, not completed trips or passenger demand.

## Recommended Power BI Connection

Use Power BI Desktop inside the Windows VM:

```text
Get data → SQL Server
Server: localhost
Database: CologneTransitIntelligence
Data connectivity mode: Import
```

Select only the seven views documented in the Power BI build guide. Import mode is appropriate because the views are compact, refreshable, and optimized for interactive exploration.

## Recommended Initial Pages

### 1. Network Overview

- KPI cards for agencies, modes, routes, parent stations, and active service dates.
- Subtitle: “Scheduled GTFS baseline — not actual operational performance.”
- Mode share by scheduled trip occurrences.

### 2. Mode and Route Profile

- Scheduled trip occurrences by mode.
- Route ranking by scheduled occurrences.
- Filters for mode, agency, and route.
- Separate visual or color for `SEV`.

### 3. Stop and Station Coverage

- Map using latitude and longitude.
- Route count and scheduled stop-event patterns as tooltips.
- Separate views for physical stop positions and parent stations.

### 4. Planned Daily Service

- Daily scheduled trip count.
- Weekday/weekend comparison.
- Mode and route drill-down.
- Date filter restricted to active scheduled dates.

## Semantic Guardrails

- Use “scheduled,” “planned,” or “baseline” in every supply metric label.
- Do not label the current report “reliability,” “delay,” or “performance.”
- Do not interpret scheduled count as passenger demand.
- Do not combine parent stations and physical stop positions in one count.
- Keep SEV separate from ordinary buses.
- Display snapshot version and coverage dates on an information page.

## Realtime Extension

GTFS Realtime will later add predicted or observed times, delay seconds, cancellations, skipped stops, service alerts, disruption categories, vehicle positions if supplied, feed-quality KPIs, and consolidated stop performance. Only then can the project progress from planned supply to evidence-based reliability and root-cause analysis.

## Defence Questions

### Why create a dashboard before realtime data arrives?

The scheduled baseline establishes what service was supposed to operate, validates the city and mode scope, and prepares the dimensions and interaction design. Realtime performance has no meaning without a trustworthy schedule baseline.

### Why use Import rather than DirectQuery?

The reporting views are compact and change only when the warehouse refreshes. Import provides faster interaction and a portable portfolio file.

### Why does the feed contain 364 dates but only 182 active service dates?

`DimDate` covers the published feed range. Calendar rules and exception removals determine the dates with relevant scheduled service. The active set begins on 14 June 2026 and ends on 12 December 2026.

### Can scheduled trip count be used as a demand metric?

No. Passenger counts, occupancy, ticketing, or survey data would be required to measure demand.
