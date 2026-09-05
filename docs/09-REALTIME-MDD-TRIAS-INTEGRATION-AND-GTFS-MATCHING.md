# Realtime MDD/TRIAS Integration and GTFS Matching

**Last updated:** 2026-09-05

## Purpose

This document is the canonical implementation record for the realtime phase of Cologne Public Transport Intelligence.

It records the validated MDD NRW / DELFI / TRIAS source, realtime staging model, situation evidence, timezone and GTFS service-day normalization, TRIAS-to-GTFS matching, compliance status, and the first successfully persisted realtime snapshot.

If an older project document conflicts with this file on realtime behavior, this file takes precedence.

---

## 1. Realtime Architecture

The project preserves the following data-layer contract:

```text
MDD NRW / DELFI / TRIAS
        |
        v
source-faithful realtime staging (`stg`)
        |
        v
normalization / enrichment / matching (`wrk`)
        |
        +----------------------+
        |                      |
        v                      v
static GTFS / DW         situation evidence
        |                      |
        +----------+-----------+
                   |
                   v
wrk.vwCologneRealtimeEvidenceSituation
                   |
                   v
future validated DW realtime facts / analytics / Power BI
```

### `stg`

Source-faithful realtime storage. Derived KPIs do not belong here.

Current realtime tables:

1. `stg.MddRealtimeStopObservation`
2. `stg.MddRealtimeSituationObservation`
3. `stg.MddRealtimeStopSituationLink`

### `wrk`

Derived / normalized logic.

Current realtime views:

1. `wrk.vwCologneRealtimeStopObservation`
2. `wrk.vwCologneRealtimeStopEnriched`
3. `wrk.vwCologneRealtimeTripMatchKey`
4. `wrk.vwCologneRealtimeTripMatch`
5. `wrk.vwCologneRealtimeEvidenceSituation`

### `dw`

The existing static warehouse provides the schedule/service calendar needed for realtime matching. No final realtime fact has been approved yet.

### `analytics`

Realtime reliability analytics will be added only after collector behavior and consolidated operational grains are stable.

Power BI must not read realtime staging directly.

---

## 2. MDD NRW / DELFI / TRIAS Source

Validated endpoint:

```text
POST https://mdd.gorheinland.com/delfi
Content-Type: application/xml
Header: x-api-key
Protocol: TRIAS 1.2
```

Authentication has been tested successfully with HTTP `200` responses.

The current project request budget is:

**250,000 requests per month**

Collector scheduling must remain within this limit.

Secrets and API keys must never be committed to GitHub, embedded in SQL, or exposed in screenshots.

---

## 3. Data-Usage / Retention Permission

The storage/retention clarification email has now been reviewed.

The response states that the TRIAS interface may be used for:

- research,
- test,
- development,
- hobby purposes.

The project had previously been described as a limited, non-commercial pilot. Based on that description, the responder's assessment was:

> `... ist unsere Einschätzung, dass die unten aufgeführten Punkte unkritisch sind.`

For the current project scope, this is treated as positive permission to proceed with the previously described non-commercial pilot activities, including the storage and historical analysis questions that were part of that request.

If the usage moves outside that framework, especially into commercial use, the project description should be sent to:

```text
opendata-oepnv@vrr.de
```

### Important compliance boundary

The supplied reply does **not** state a specific retention duration.

Therefore this project does not invent a retention period and does not interpret the reply as an unlimited or unconditional license beyond the described pilot scope.

**Documentation decision date:** 2026-09-05.

---

## 4. Realtime Staging Tables

### 4.1 `stg.MddRealtimeStopObservation`

Grain:

> one source stop-event observation at one source observation timestamp.

Current relevant columns:

- `ObservationKey` — bigint IDENTITY, primary key
- `ObservedAtUtc` — datetime2, required
- `ResultId` — nvarchar, required
- `StopPointRef` — nvarchar, required, `Latin1_General_100_BIN2`
- `StopName` — nvarchar, nullable
- `LineName` — nvarchar, nullable
- `LineRef` — nvarchar, nullable
- `JourneyRef` — nvarchar, required
- `DirectionRef` — nvarchar, nullable
- `OperatorRef` — nvarchar, nullable
- `PtMode` — nvarchar, nullable
- `RailSubmode` — nvarchar, nullable
- `TimetabledArrivalUtc` — datetime2, nullable
- `EstimatedArrivalUtc` — datetime2, nullable
- `PlannedBay` — nvarchar, nullable
- `EstimatedBay` — nvarchar, nullable
- `CreatedAtUtc` — datetime2, default `sysutcdatetime()`

`ArrivalDelayMinutes` is deliberately derived in `wrk`, not stored in staging.

A unique observation rule exists on `(ObservedAtUtc, ResultId)`.

### 4.2 `stg.MddRealtimeSituationObservation`

Grain:

> one identifiable source situation snapshot at one observation timestamp.

Current relevant columns:

- `SituationObservationKey` — bigint IDENTITY, primary key
- `ObservedAtUtc`
- `ParticipantRef` — required
- `SituationNumber` — required
- `Summary`
- `Description`
- `Detail`
- `ValidFromUtc`
- `ValidToUtc`
- `CreatedAtUtc` — default `sysutcdatetime()`

### 4.3 `stg.MddRealtimeStopSituationLink`

Many-to-many bridge between stop-event observations and situation observations.

Columns:

- `ObservationKey`
- `SituationObservationKey`
- `RelationScope`
- `CreatedAtUtc`

Validated `RelationScope` values:

```text
CALL
SERVICE
```

The composite primary key covers observation, situation and scope.

---

## 5. Arrival, Departure, Bay and Cancellation Semantics

### Arrival

The current collector prototype is arrival-oriented and persists:

```text
stopEvent.thisCall.callAtStop.serviceArrival
```

with timetabled and estimated arrival timestamps when supplied.

### Departure

The 2026-09-05 arrival response demonstrated that `serviceDeparture` can appear inside `previousCall` / `onwardCall` structures.

This does **not** yet define the production departure grain for this project.

The arrival collector continues to persist only the `thisCall` arrival event. Departure fields will not be added until a real, explicitly validated departure/current-call example establishes the correct semantics.

### Bay / platform

Observed source fields:

- `plannedBay`
- `estimatedBay`

Working-layer rule:

```text
EstimatedBay missing        -> PlatformChanged = NULL
Both present and different  -> PlatformChanged = 1
Both present and equal      -> PlatformChanged = 0
```

A missing estimated bay is not interpreted as an unchanged platform.

### Cancellation

No production cancellation field has been approved.

Cancellation semantics will only be added after a real TRIAS example demonstrates the applicable source field and interpretation.

---

## 6. Collation Resolution

A real SQL Server collation conflict occurred between:

```text
stg realtime StopPointRef : SQL_Latin1_General_CP1_CI_AS
static GTFS StopId        : Latin1_General_100_BIN2
```

The realtime staging column was changed to:

```text
Latin1_General_100_BIN2
```

After that alteration, `sys.sp_refreshview` was executed for `wrk.vwCologneRealtimeStopObservation` because existing view metadata still exposed the previous collation.

The exact stop join then worked correctly.

---

## 7. Static Stop Enrichment

At Köln Hbf, static GTFS contains a parent station and physical platform stops.

Examples:

```text
de:05315:11201        -> Köln Hbf
de:05315:11201:7:71   -> Köln Hbf (Gleis 1)
de:05315:11201:7:78   -> Köln Hbf (Gleis 8)
```

Primary stop-enrichment rule:

```text
TRIAS StopPointRef = GTFS StopId
```

`wrk.vwCologneRealtimeStopEnriched` exposes:

- `StaticParentStationId`
- `StaticStopName`
- `StaticStopMatched`

No guessed string truncation is used as the primary stop mapping method.

A successful static stop enrichment does not imply that the realtime line/trip exists in the current static route coverage. This distinction is demonstrated by ICE observations that match a Köln Hbf platform but remain `StaticCoverageMissing` at trip level.

---

## 8. Delay and Timezone Normalization

### Delay

`wrk.vwCologneRealtimeStopObservation` derives `ArrivalDelayMinutes` from:

- `TimetabledArrivalUtc`
- `EstimatedArrivalUtc`

If the estimated arrival is absent, delay remains NULL.

### Timezone

TRIAS timestamps are represented as UTC.

Static GTFS uses local agency time.

All 15 agencies currently represented in `dw.DimAgency` use:

```text
Europe/Berlin
```

SQL Server conversion uses:

```sql
AT TIME ZONE 'UTC'
AT TIME ZONE 'W. Europe Standard Time'
```

The timezone conversion belongs in `wrk`, not `stg`.

---

## 9. GTFS Service-Day / After-Midnight Logic

GTFS schedule times can exceed 24 hours.

Validated current values include:

```text
24:00:00 -> 86400 seconds  -> ArrivalDayOffset 1
24:01:00 -> 86460 seconds  -> ArrivalDayOffset 1
48:50:00 -> 175800 seconds -> ArrivalDayOffset 2
49:23:00 -> 177780 seconds -> ArrivalDayOffset 2
```

Observed `ArrivalDayOffset` values:

- 0
- 1
- 2

General matching formula:

```text
GTFS ServiceDate
= TRIAS LocalCalendarDate - ArrivalDayOffset

GTFS ScheduledArrivalSeconds
= TRIAS LocalSecondsOfDay + ArrivalDayOffset * 86400
```

The implementation intentionally does not hard-code only offsets 0 and 1.

---

## 10. TRIAS-to-GTFS Trip Matching

TRIAS identifiers and GTFS identifiers use different schemes.

Never assume:

```text
TRIAS JourneyRef = GTFS TripId
TRIAS LineRef    = GTFS RouteId
```

Matching uses evidence from:

1. normalized line name,
2. local scheduled time,
3. GTFS service-day calculation,
4. active `ServiceId`,
5. exact stop when available,
6. controlled parent-station fallback.

Current line-name normalization removes spaces, for example:

```text
RE 9  -> RE9
RB 27 -> RB27
```

Active-service validation uses:

- `dw.DimService`
- `dw.BridgeServiceDate`
- `dw.DimDate`

---

## 11. Match-Quality Contract

Final statuses:

```text
StaticCoverageMissing
ExactStopMatch
ParentStationFallback
Unresolved
```

### `StaticCoverageMissing`

Realtime line/service is outside the current static route/trip coverage.

### `ExactStopMatch`

Exactly one valid active candidate matches the normalized line, service date, scheduled local time and exact `StopId`.

### `ParentStationFallback`

No exact stop candidate exists, but one candidate resolves uniquely at the same parent station using the remaining validated evidence.

### `Unresolved`

Static coverage exists, but the available evidence does not produce exactly one defensible candidate.

`HasUsableStaticMatch = 1` only for:

```text
ExactStopMatch
ParentStationFallback
```

---

## 12. Original Five-Event Matching Validation — 2026-09-03

The original engineering sample established the matching hierarchy:

| Line | MatchStatus |
|---|---|
| ICE | `StaticCoverageMissing` |
| RE 7 | `ExactStopMatch` |
| RB 27 | `ParentStationFallback` |
| RB 25 | `ExactStopMatch` |
| RE 9 | `ExactStopMatch` |

### RB27 platform fallback

TRIAS:

```text
StopPointRef = de:05315:11201:7:73
Gleis 3
```

Static GTFS candidate:

```text
StopId = de:05315:11201:7:74
Gleis 4
```

The route, service date, local scheduled time and parent station resolved uniquely, so this is a valid `ParentStationFallback`, not a failed match.

### ICE coverage gap

No ICE rows exist in the current:

- `wrk.vwCologneServingRoute`
- `wrk.vwCologneServingTrip`

Therefore ICE is `StaticCoverageMissing`, not `MatchFailed`.

---

## 13. Situation Evidence Contract

TRIAS situation context is evidence, not automatic proof of causality.

The analytical boundary remains:

```text
observed delay
+
linked / overlapping situation context
+
repeated temporal and location evidence
=
association or likely contributing factor
```

A confirmed cause requires stronger source evidence than simple co-occurrence or linkage.

`RelationScope` records whether a source reference was attached at:

- `SERVICE`, or
- `CALL`

level.

---

## 14. First Persisted Realtime Snapshot — 2026-09-05

Before persistence, all three realtime staging tables were confirmed to contain zero rows.

A new authenticated arrival request then returned:

```text
HTTP Status: 200
Response length: 43618
Result count: 5
ObservedAtUtc: 2026-09-05 08:27:28 UTC
```

The response was parsed directly in PowerShell and inserted into SQL Server using parameterized commands and SQL transactions.

No API key was persisted.

### Staging result

After the first successful persistence:

| Table | Rows from snapshot |
|---|---:|
| `stg.MddRealtimeStopObservation` | 5 |
| `stg.MddRealtimeSituationObservation` | 2 |
| `stg.MddRealtimeStopSituationLink` | 2 |

### Five persisted stop observations

| Line | Timetabled UTC | Estimated UTC | Delay min | MatchStatus | HasUsableStaticMatch |
|---|---|---|---:|---|---:|
| ICE | 08:06 | 08:56 | 50 | `StaticCoverageMissing` | 0 |
| ICE | 08:16 | 08:29 | 13 | `StaticCoverageMissing` | 0 |
| RB 48 | 08:22 | 08:36 | 14 | `ParentStationFallback` | 1 |
| RB 25 | 08:23 | 08:25 | 2 | `ExactStopMatch` | 1 |
| RB38 | 08:26 | NULL | NULL | `ParentStationFallback` | 1 |

All five realtime `StopPointRef` values successfully enriched against the static stop hierarchy (`StaticStopMatched = 1`).

This again demonstrates that stop enrichment and trip coverage are separate concepts: the two ICE rows have known static platforms at Köln Hbf but no usable static trip coverage.

### Platform / bay findings

The source supplied planned bays including:

- ICE: `5`
- ICE: `4`
- RB48: `1 A-C`
- RB25: `10 A-B`
- RB38: `7 D-G`

`EstimatedBay` was NULL for all five observations, therefore `PlatformChanged` correctly remained NULL for all five.

Two current rows resolved through parent-station fallback:

- RB48: realtime `StopPointRef = de:05315:11201:7:72`, matched static stop `de:05315:11201:7:71`;
- RB38: realtime `StopPointRef = de:05315:11201:7:78`, matched static stop `de:05315:11201:7:77`.

These are retained as controlled fallback evidence, not converted into invented platform-change events.

### Situation observations

Three context `ptSituation` objects were visible in the source response.

Two had the identifiers required by the current staging contract and were persisted:

1. `ZTP-PROD-135726`
   - summary: `Aufzug Gleis 1/2 in Haan außer Betrieb`

2. `ZTP-PROD-138150`
   - summary: system-information issue involving the Hoffnungsthal stop

One additional context situation had the summary:

```text
Defektes Stellwerk
```

but did not expose `ParticipantRef` or `SituationNumber` in the inspected object.

Because the current staging model requires both source identifiers, this unidentified context object was **not persisted**, no surrogate source identity was invented, and no event association was inferred.

This is now a recorded source/data-quality case for the future production parser.

### Situation links

Two source-observed service-level relationships were persisted:

| Line | SituationNumber | RelationScope |
|---|---|---|
| RB 48 | `ZTP-PROD-135726` | `SERVICE` |
| RB 25 | `ZTP-PROD-138150` | `SERVICE` |

No CALL-level relationship was observed in this snapshot.

The presence of these links is situation evidence only; it is not proof that the linked situation caused the measured delay.

---

## 15. Validation Through `wrk.vwCologneRealtimeEvidenceSituation`

The first persisted snapshot was successfully read through:

```text
stg
 -> wrk.vwCologneRealtimeStopObservation
 -> wrk.vwCologneRealtimeStopEnriched
 -> wrk.vwCologneRealtimeTripMatchKey
 -> wrk.vwCologneRealtimeTripMatch
 -> wrk.vwCologneRealtimeEvidenceSituation
```

The final evidence view produced all five observation rows with the expected:

- source stop identity,
- static stop enrichment,
- UTC-to-Berlin normalization,
- scheduled local seconds,
- delay evidence,
- candidate counts,
- match status,
- usable-match flag,
- and situation context.

Validated current match distribution for this snapshot:

```text
StaticCoverageMissing : 2
ExactStopMatch         : 1
ParentStationFallback  : 2
Unresolved             : 0
```

Usable static matches:

```text
3 of 5 observations
```

This is an engineering sample only and must not be reported as a network reliability rate.

---

## 16. Current Data-Quality Findings

The production collector must preserve and expose, rather than hide, cases such as:

- static stop exists but static trip coverage is missing;
- exact platform fails but parent-station matching is uniquely defensible;
- estimated arrival is absent;
- estimated bay is absent;
- situation context exists without a usable source identifier;
- situation evidence exists but causality is not established;
- repeated source snapshots represent observations, not repeated trips.

Raw snapshot row counts must never be interpreted as service counts or delay counts.

---

## 17. Current Persistence Status

Realtime persistence is no longer blocked by the earlier permission checkpoint.

The database now contains the first validated historical snapshot in all three realtime staging tables.

The current implementation was performed manually/prototypically through PowerShell to prove:

- request execution,
- parsing,
- parameterized insertion,
- transaction behavior,
- foreign-key resolution,
- situation linking,
- and end-to-end working-view validation.

This manual prototype is not yet the production collector.

---

## 18. Next Implementation Step

The next major technical step is to convert the validated manual prototype into a production-style arrival collector while preserving the exact semantics proven above.

The collector design must include:

- API-quota-aware scheduling against 250,000 requests/month;
- secure external API-key configuration;
- one coherent snapshot timestamp per response;
- parameterized SQL writes;
- transactional insertion of stop observations, situation observations and links;
- deduplication / idempotency using established source identities and snapshot timestamp;
- explicit handling/logging of unidentifiable context situations rather than inventing identifiers;
- preservation of NULL semantics;
- no inferred cancellation or departure fields;
- collection-gap/error logging;
- validation metrics for exact match, parent fallback, unresolved and static coverage missing.

Collector code should be added to the repository only after its first design is validated against the current database contract.

---

## 19. Established Modeling Decisions

The following decisions remain binding unless explicitly revised after new source evidence:

- raw/source values stay in `stg`;
- normalization and derived logic stay in `wrk`;
- validated facts only later enter `dw` / `analytics`;
- Power BI does not read staging directly;
- TRIAS IDs are not assumed equal to GTFS IDs;
- GTFS service-day semantics above 24:00 are preserved;
- exact stop match is preferred, parent-station fallback is controlled and explicit;
- static coverage gaps are not match failures;
- `EstimatedBay = NULL` does not mean platform unchanged;
- absent estimated arrival means no derived arrival delay for that snapshot;
- situation linkage is evidence, not confirmed causality;
- cancellation/departure semantics are not invented from unvalidated source structures;
- API secrets remain outside source control and screenshots.

---

## 20. Current Checkpoint

As of 2026-09-05:

- MDD authentication works;
- TRIAS 1.2 arrival requests work;
- monthly request budget is 250,000;
- current non-commercial pilot usage has a positive permission assessment from the MDD/OpenData contact context described above;
- exact retention duration was not stated and is therefore not invented;
- realtime staging tables and constraints are validated;
- first realtime persistence succeeded;
- first situation persistence and service-level linking succeeded;
- working-layer delay, timezone, GTFS matching and evidence views succeeded against persisted data;
- the first persisted snapshot produced 2 `StaticCoverageMissing`, 1 `ExactStopMatch`, 2 `ParentStationFallback`, and 0 `Unresolved` rows;
- production-style collector implementation is the next major step.

---

## 21. One-Shot Collector Prototype

A consolidated PowerShell collector prototype has now been prepared at:

```text
collector/Invoke-MddRealtimeCollector.ps1
```

The script performs one complete arrival snapshot per execution:

```text
TRIAS request
-> response parsing
-> stop-event parsing
-> identifiable situation parsing
-> SERVICE/CALL relationship parsing
-> one SQL transaction
-> idempotent staging persistence
```

Current design properties:

- one execution uses exactly one MDD request;
- API key is never hard-coded;
- the script first checks the `MDD_API_KEY` environment variable and otherwise prompts securely;
- SQL writes are parameterized;
- stop observations are treated idempotently by `ObservedAtUtc + ResultId`;
- situation observations are treated idempotently by `ObservedAtUtc + ParticipantRef + SituationNumber`;
- relationship rows are checked before insert;
- an unidentifiable context situation is counted but not assigned a fabricated source identifier;
- only source-observed `SERVICE` / `CALL` links are persisted;
- all three staging-table writes run inside one SQL transaction;
- missing estimated arrival / bay values retain NULL semantics;
- cancellation and departure are still not inferred.

This is intentionally a **one-shot collector**, not yet a scheduled service. Scheduling, persistent operational logging and monthly quota accounting will be designed only after repeated one-shot executions are validated.

