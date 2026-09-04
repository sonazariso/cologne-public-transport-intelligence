# Static Analytics and Power BI Baseline

**Last updated:** 2026-09-04

## 1. Purpose

The static analytics layer remains the validated **scheduled-service baseline** for the portfolio. Realtime integration now exists in `stg`/`wrk`, but the current baseline Power BI report must still be interpreted as planned supply rather than reliability.

## 2. Static Analytics Views

| View | Grain | Expected rows |
|---|---|---:|
| `analytics.vwNetworkBaselineKpi` | whole network | 1 |
| `analytics.vwModeScheduleProfile` | mode | 7 |
| `analytics.vwRouteScheduleProfile` | route | 153 |
| `analytics.vwActiveDateProfile` | active service date | 182 |
| `analytics.vwStopPositionScheduleProfile` | physical stop | 2,290 |
| `analytics.vwParentStationScheduleProfile` | parent station | 866 |
| `analytics.vwDailyScheduledTripProfile` | active date + route | 20,059 |

## 3. Baseline KPIs

| KPI | Value |
|---|---:|
| Agencies | 15 |
| Modes | 7 |
| Routes | 153 |
| Parent stations | 866 |
| Stop positions | 2,290 |
| Used stop positions | 2,287 |
| Service patterns | 3,947 |
| Active service dates | 182 |
| Scheduled trip patterns | 90,331 |
| Scheduled trip occurrences | 1,878,944 |
| Scheduled stop-event patterns | 1,551,343 |

## 4. Scheduled Trip Occurrences by Mode

| Mode | Occurrences |
|---|---:|
| Stadtbahn / Tram | 500,043 |
| S-Bahn | 80,403 |
| Regional Express (RE) | 50,923 |
| Regional Bahn (RB) | 49,613 |
| Urban Bus (KVB) | 918,349 |
| Regional / Other Bus | 223,797 |
| Rail Replacement Bus (SEV) | 55,816 |
| **Total** | **1,878,944** |

## 5. Semantic Guardrails

- Use “scheduled”, “planned”, or “baseline” for current supply metrics.
- Do not label the existing static report as a reliability dashboard.
- Scheduled trip count is not passenger demand.
- Do not combine parent stations and physical stop positions into one station count.
- Keep SEV separate from ordinary bus service.
- Snapshot/feed version and coverage dates should remain visible in methodology documentation.

## 6. Realtime Status Update

Realtime MDD/TRIAS ingestion structures and matching views now exist in the database working layer. They currently support:

- delay calculation;
- platform/bay interpretation;
- situation context;
- static stop enrichment;
- UTC/local-time conversion;
- service-date matching;
- match-quality statuses.

This does **not** yet mean the Power BI static baseline should be converted into a reliability report. Historical collection and consolidated operational grains must be established first.

## 7. Future Realtime Analytics

Once approved historical collection is active, new analytics views should expose measures such as:

- observed services;
- match coverage and data-quality rates;
- on-time / delayed distribution;
- median / P95 delay;
- route/station hotspots;
- platform mismatch/change evidence;
- situation-linked delay counts;
- coverage-missing and unresolved rates.

Raw snapshot row counts must never be used as delayed-service counts.

## 8. Current Recommended Static Report Pages

1. Scheduled Network Overview
2. Mode and Route Profile
3. Stop and Station Coverage
4. Planned Daily Service
5. Methodology / Data Quality

A separate realtime reliability section/report can be added when the collector history is analytically stable.
