# Static Analytics and Power BI Baseline

**Last updated:** 2026-09-08

## 1. Purpose

The static analytics layer remains the validated **scheduled-service baseline**
for the portfolio. The realtime SQL operational fact and analytics consumer
views now exist separately; the current baseline Power BI report must still be
interpreted as planned supply rather than reliability.

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

## 6. Realtime SQL Status Update

Realtime MDD/TRIAS ingestion structures and matching views now exist in the database working layer. They currently support:

- delay calculation;
- platform/bay interpretation;
- situation context;
- static stop enrichment;
- UTC/local-time conversion;
- service-date matching;
- match-quality statuses.

The database engineering is complete against the genuine current sample. The
operational fact grain is one matched scheduled stop event on one GTFS service
date; repeated observations are consolidated by `ObservedAtUtc`, then
`ObservationKey`. Only `ExactStopMatch` and `ParentStationFallback` enter
reliability outcomes. `StaticCoverageMissing` and `Unresolved` remain visible
in Data Quality/Coverage analytics.

The current analytics layer exposes Collector health, sampling-panel
participation, all match-status rates, observations per operational outcome,
platform-information availability, situation evidence, and continuous observed
estimated-delay metrics. It deliberately does not create an arbitrary
`OnTimeRate`, infer cancellation/departure, or claim disruption causality.

This does **not** mean the Power BI static baseline should be converted into a
final reliability report now. The 14/28-day history window remains necessary
for stronger interpretation and portfolio findings, but it is not a
prerequisite for database design, consolidation, or SQL validation. Power BI
work is intentionally deferred.

## 7. Current Realtime Analytics Views

The SQL layer now exposes:

- `analytics.vwRealtimeCollectorRunHealth`
- `analytics.vwRealtimeDataQualityCoverage`
- `analytics.vwRealtimeOperationalConsolidationQuality`
- `analytics.vwRealtimeReliabilityOutcome`
- `analytics.vwRealtimeReliabilityByDimension`
- `analytics.vwRealtimeDelayHotspot`
- `analytics.vwRealtimePlatformChangeEvidence`
- `analytics.vwRealtimeSituationLinkedOutcome`

Average, median, and P95 are observed estimated-delay statistics. Raw snapshot
row counts are never used as delayed-service counts, and the seven configured
locations are a sampling panel rather than complete Cologne network coverage.

## 8. Current Recommended Static Report Pages

1. Scheduled Network Overview
2. Mode and Route Profile
3. Stop and Station Coverage
4. Planned Daily Service
5. Methodology / Data Quality

A separate realtime reliability section/report can be added when the collector history is analytically stable.
