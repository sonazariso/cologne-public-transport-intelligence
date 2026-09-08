# Data Architecture

**Last updated:** 2026-09-08

## 1. Purpose

The architecture separates schedule data, realtime observations, transformation, matching, warehouse materialization, business-facing analytics, and reporting so every KPI can be traced to source evidence.

## 2. Current End-to-End Architecture

```text
VRS/go.Rheinland static GTFS            MDD NRW DELFI/TRIAS
             |                                   |
             v                                   v
       static staging (`stg`)          realtime staging (`stg`)
             |                                   |
             +----------------+------------------+
                              |
                              v
                    working layer (`wrk`)
             scope / typing / time normalization
              static enrichment / trip matching
                    situation relationships
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
          static warehouse (`dw`)   realtime matching/evidence
                  |                       |
                  +-----------+-----------+
                              |
                              v
          operational outcome fact (`dw`)
                               |
                               v
                       realtime `analytics`
                              |
                              v
                           Power BI
```

## 3. Layer Responsibilities

### `ctl`

Load/control metadata, statuses, counts, timestamps, source versions, and errors.

### `stg`

Source-faithful staging. No business KPI calculations.

Static examples:

- `stg.GtfsAgency`
- `stg.GtfsRoutes`
- `stg.GtfsTrips`
- `stg.GtfsStops`
- `stg.GtfsStopTimes`

Realtime objects:

- `stg.MddRealtimeStopObservation`
- `stg.MddRealtimeSituationObservation`
- `stg.MddRealtimeStopSituationLink`

### `wrk`

Transparent transformations and derived logic:

- city scope;
- mode classification;
- UTC/local-time normalization;
- GTFS service-day handling;
- realtime delay calculation;
- static stop enrichment;
- trip candidate generation and match classification;
- situation evidence exposure.

### `dw`

Validated static dimensions, service-date bridge, static facts, and the
realtime `dw.FactOperationalStopOutcome` operational fact. The realtime fact
is refreshed from genuine staging history; the 14/28-day period is a later
historical interpretation milestone, not a database-design prerequisite.

### `analytics`

Business-readable datasets for Power BI. Existing static views remain the
scheduled-supply baseline; realtime Data Quality/Coverage and Reliability views
now consume the validated operational fact. Power BI authoring remains a later
step.

## 4. Realtime Source Architecture

The validated operational source is MDD NRW's direct DELFI endpoint using TRIAS 1.2:

```text
POST https://mdd.gorheinland.com/delfi
Header: x-api-key
Content-Type: application/xml
```

The current monthly request limit is **250,000**. Collector cadence must be budgeted against this limit.

## 5. Realtime Staging Grain

### `stg.MddRealtimeStopObservation`

One source stop-event observation at one observed timestamp.

Important source-aligned fields include:

- result ID;
- stop-point reference/name;
- line/line reference;
- journey reference;
- direction/operator/mode;
- timetabled and estimated arrival UTC;
- planned and estimated bay;
- observed/created timestamps.

### `stg.MddRealtimeSituationObservation`

One situation snapshot with participant reference, situation number, summary, description, detail, validity interval, and observation timestamps.

### `stg.MddRealtimeStopSituationLink`

Many-to-many relationship between a stop observation and a situation. `RelationScope` is constrained to `CALL` or `SERVICE`.

## 6. Working Realtime Flow

```text
stg.MddRealtimeStopObservation
        |
        v
wrk.vwCologneRealtimeStopObservation
  delay + nullable platform-change inference
        |
        v
wrk.vwCologneRealtimeStopEnriched
  exact static StopId enrichment
        |
        v
wrk.vwCologneRealtimeTripMatchKey
  UTC -> Europe/Berlin
  local date + local seconds
        |
        v
wrk.vwCologneRealtimeTripMatch
  service date + line + time + stop/station hierarchy
        |
        v
wrk.vwCologneRealtimeEvidenceSituation
  match quality + disruption/situation context

        |
        v
dw.FactOperationalStopOutcome
  one usable matched scheduled stop event + GTFS service date
  repeated observations consolidated by ObservedAtUtc, ObservationKey

        |
        v
analytics.vwRealtimeDataQualityCoverage
analytics.vwRealtimeReliabilityOutcome
analytics.vwRealtimeReliabilityByDimension
```

## 7. Time and Service-Day Normalization

All 15 agencies currently represented in `dw.DimAgency` use `Europe/Berlin`. SQL Server conversion uses `W. Europe Standard Time`.

TRIAS timestamps are normalized from UTC to Berlin local time before matching to GTFS scheduled seconds.

For a candidate with `ArrivalDayOffset = N`:

```text
GTFS ServiceDate
= TRIAS LocalCalendarDate - N days

GTFS ScheduledArrivalSeconds
= TRIAS LocalSecondsOfDay + N * 86400
```

This handles GTFS times up to at least the validated `49:23:00` case.

## 8. Trip Matching Strategy

TRIAS and GTFS identifiers are not assumed equal. Matching is based on:

- normalized line name;
- active service date;
- local scheduled time;
- exact stop when possible;
- parent station as controlled fallback.

Statuses:

- `ExactStopMatch`
- `ParentStationFallback`
- `StaticCoverageMissing`
- `Unresolved`

Only the first two are considered usable static matches.

## 9. Validated Five-Event Match Test

| Realtime line | Status |
|---|---|
| ICE | `StaticCoverageMissing` |
| RE 7 | `ExactStopMatch` |
| RB 27 | `ParentStationFallback` |
| RB 25 | `ExactStopMatch` |
| RE 9 | `ExactStopMatch` |

## 10. Evidence vs Cause Boundary

The architecture supports:

```text
observed delay
+
linked situation / overlapping disruption context
+
repeated temporal/location pattern
=
association or likely contributing factor
```

A source-linked situation is evidence, not automatic proof that it caused the delay.

## 11. Realtime Operational Fact and Analytics Boundary

`dw.FactOperationalStopOutcome` has one row per matched scheduled stop event on
one GTFS service date. Only `ExactStopMatch` and `ParentStationFallback` enter
this fact. `StaticCoverageMissing` and `Unresolved` remain in staging and are
reported by `analytics.vwRealtimeDataQualityCoverage`.

The refresh procedure orders source observations by `ObservedAtUtc`, then
`ObservationKey`, retaining first/last lineage and consolidating repeated
predictions into one operational outcome. Arrival and delay fields are
observed estimates; they are not confirmed physical arrivals or actual delays.

The realtime analytics layer exposes collector health, sampling-panel coverage,
match-status rates, observations per operational outcome, platform information,
situation evidence, and average/median/P95 observed estimated delay by date,
route, stop, mode, and hour. It deliberately does not create an arbitrary
on-time threshold or infer cancellation, departure, or situation causality.

The seven configured locations are a sampling panel, not complete Cologne
network coverage. Historical collection continues independently in the
append-only staging layer; Power BI is not part of this database-preparation
step.

## 12. Data Quality Gates

Critical checks include:

- parse success and source availability;
- feed/request age and collection gaps;
- duplicate observation detection;
- exact/fallback/unresolved/coverage-missing match rates;
- stop/platform disagreement rate;
- invalid time conversions;
- service-date reconciliation;
- situation-link integrity;
- warehouse-to-analytics reconciliation;
- operational-grain uniqueness and repeated-observation consolidation;
- fact refresh idempotency;
- usable-match-only reliability eligibility.

## 13. Security and Compliance

- API keys and secrets remain outside Git and documentation.
- The MDD storage/retention confirmation email has been received.
- Exact compliance terms will be documented only after the email text is supplied.
- No legal/retention condition is inferred from the existence of the confirmation alone.
