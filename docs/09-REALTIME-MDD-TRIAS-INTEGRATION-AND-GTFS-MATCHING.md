# Realtime MDD/TRIAS Integration and GTFS Matching

**Last updated:** 2026-09-04

## Purpose

This document is the canonical implementation record for the realtime phase of Cologne Public Transport Intelligence. It documents the MDD NRW DELFI/TRIAS source, staging model, situation evidence, timezone/service-day normalization, static GTFS enrichment, trip-matching hierarchy, validated test cases, and the compliance checkpoint before production collection.

## 1. Project Objective

Build a Cologne-focused public-transport intelligence project that combines:

- static GTFS schedule/reference data,
- realtime DELFI/TRIAS observations from MDD NRW,
- delay calculations,
- platform/bay information,
- service disruption/situation context,
- matching of realtime events to static GTFS trips,
- and later analytical models / dashboards for delay evidence and likely causes.

The current implementation deliberately separates raw/source data, working logic, and analytical/warehouse structures.

---

## 2. Data-Layer Architecture

### `stg` — source-aligned staging

Purpose:

- store values as received from the source,
- avoid derived business logic in staging,
- preserve source identifiers and source timestamps,
- keep realtime observations and situations separate.

Current realtime staging objects:

1. `stg.MddRealtimeStopObservation`
2. `stg.MddRealtimeSituationObservation`
3. `stg.MddRealtimeStopSituationLink`

### `wrk` — normalization and matching logic

Purpose:

- calculate delay,
- normalize UTC timestamps to local service time,
- enrich realtime stops with static GTFS information,
- match TRIAS realtime events to GTFS trips,
- expose situation/evidence relationships.

Current realtime working views:

1. `wrk.vwCologneRealtimeStopObservation`
2. `wrk.vwCologneRealtimeStopEnriched`
3. `wrk.vwCologneRealtimeTripMatchKey`
4. `wrk.vwCologneRealtimeTripMatch`
5. `wrk.vwCologneRealtimeEvidenceSituation`

Existing static working views used by realtime matching:

- `wrk.vwCologneStop`
- `wrk.vwCologneScheduledStopEvent`
- `wrk.vwCologneServingRoute`
- `wrk.vwCologneServingTrip`
- `wrk.vwCologneModeSummary`

### `dw` — warehouse / conformed structures

Important existing objects used by realtime matching:

- `dw.DimAgency`
- `dw.DimDate`
- `dw.DimService`
- `dw.BridgeServiceDate`
- `dw.FactScheduledStopEvent`
- `dw.FactScheduledTrip`

### `analytics`

Existing analytical objects include:

- `analytics.vwActiveDateProfile`
- `analytics.vwDailyScheduledTripProfile`

No realtime reporting fact has been finalized yet.

---

## 3. MDD NRW / DELFI / TRIAS Access

The realtime source currently being tested is the MDD NRW direct DELFI endpoint:

`POST https://mdd.gorheinland.com/delfi`

Protocol / format:

- TRIAS 1.2
- request body: XML
- authentication header: `x-api-key`
- realtime stop-event requests tested successfully.

### Request-limit status

The MDD NRW monthly request limit for this project has been increased to:

**250,000 requests per month**

This is the active planning limit for future collector scheduling.

### Storage / retention permission

A follow-up request was sent to MDD NRW to clarify whether DELFI/TRIAS responses and extracted realtime information may be stored and historically analyzed.

**Current status as of 2026-09-04:**  
The user reports that a confirmation email has now been received.

Important documentation action still required:

- copy the exact wording of that confirmation into the project compliance notes,
- record any retention duration, attribution, redistribution, commercial/non-commercial, or other conditions exactly as stated in the email.

Until the exact email text is copied into the repository, this document does **not** infer conditions that were not explicitly provided.

---

## 4. Successful TRIAS Test

A successful authenticated TRIAS request returned:

- HTTP `200`
- JSON response representation after client-side conversion
- `Result count = 5`

The response timestamp observed in the test was:

`2026-09-03T19:41:42Z[GMT]`

The five arrival observations used during the matching investigation were:

| Sample | TRIAS line | StopPointRef | Timetabled arrival UTC | Estimated arrival UTC | Delay |
|---|---|---|---|---|---:|
| 1 | ICE | `de:05315:11201:7:77` | 19:14 | 19:41 | 27 min |
| 2 | RE 7 | `de:05315:11201:7:72` | 19:17 | 20:02 | 45 min |
| 3 | RB 27 | `de:05315:11201:7:73` | 19:35 | 19:58 | 23 min |
| 4 | RB 25 | `de:05315:11201:7:81` | 19:36 | 19:44 | 8 min |
| 5 | RE 9 | `de:05315:11201:7:78` | 19:37 | 19:42 | 5 min |

---

## 5. TRIAS Response Findings

### Arrival vs departure

The tested request used an arrival-oriented `StopEventRequest`.

Observed structure:

- `thisCall.callAtStop.serviceArrival` exists.
- `serviceArrival.timetabledTime` exists.
- `serviceArrival.estimatedTime` exists.
- `serviceDeparture` was not present for the inspected sample.

Therefore departure columns have **not** been added based on assumptions.

### Bay / platform information

Observed properties in `thisCall.callAtStop`:

- `plannedBay`
- `estimatedBay`

The test sample showed planned bays such as:

- `7`
- `2 A-C`
- `4 A-C`
- `11 B-C`
- `8 A-C`

`estimatedBay` was empty in the five inspected results.

Interpretation rule:

> `EstimatedBay = NULL` does **not** mean “platform unchanged”.  
> It means that no separate realtime estimated-bay value was supplied in that snapshot.

Therefore `PlatformChanged` is nullable.

### Cancellation

No direct `cancelled` property was observed in the inspected `stopEvent` / `callAtStop` structure.

Cancellation fields are therefore **not** being added until a real response demonstrates the applicable source field.

---

## 6. Realtime Staging Tables

### 6.1 `stg.MddRealtimeStopObservation`

Current logical structure:

- `ObservationKey` — bigint, PK
- `ObservedAtUtc` — datetime2, required
- `ResultId` — nvarchar, required
- `StopPointRef` — nvarchar, required
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
- `CreatedAtUtc` — datetime2, required
- `PlannedBay` — nvarchar, nullable
- `EstimatedBay` — nvarchar, nullable

Important design choice:

`ArrivalDelayMinutes` is **not** stored in staging. It is derived in `wrk`.

### 6.2 `stg.MddRealtimeSituationObservation`

Current structure:

- `SituationObservationKey` — bigint, required
- `ObservedAtUtc` — datetime2, required
- `ParticipantRef` — nvarchar, required
- `SituationNumber` — nvarchar, required
- `Summary` — nvarchar, nullable
- `Description` — nvarchar, nullable
- `Detail` — nvarchar(max), nullable
- `ValidFromUtc` — datetime2, nullable
- `ValidToUtc` — datetime2, nullable
- `CreatedAtUtc` — datetime2, required

### 6.3 `stg.MddRealtimeStopSituationLink`

Purpose:

Many-to-many bridge between a realtime stop observation and one or more situations.

Columns:

- `ObservationKey`
- `SituationObservationKey`
- `RelationScope`
- `CreatedAtUtc`

Validated constraints:

- composite primary key:
  - `ObservationKey`
  - `SituationObservationKey`
  - `RelationScope`
- FK to realtime stop observation
- FK to situation observation
- CHECK constraint restricting `RelationScope` to:
  - `SERVICE`
  - `CALL`

---

## 7. Situation / Disruption Evidence from Test Response

The response contained situation references and situation context.

Examples observed:

### RB 27

`JourneyRef = ddb:90E27::H:j26:52`

Two service-level situations were associated with the event:

1. `ZTP-PROD-132377`
   - Summary: `Kein barrierefreier Ein- und Ausstieg möglich`

2. `ZTP-PROD-138201`
   - Summary: disruption in the greater Mönchengladbach area related to construction / overhead-line work.

### RB 25

`JourneyRef = ddb:90E25::R:j26:516`

One service-level situation:

- `ZTP-PROD-138150`
- related to the Hoffnungsthal stop / a system-information issue and construction-related stop disruption.

### Other tested arrivals

The tested ICE, RE7 and RE9 observations did not have a linked service situation in the inspected result set.

This supports the analytical model:

`Realtime delay evidence -> linked situation context -> possible explanation / likely cause`

It does **not** prove causality by itself.

---

## 8. Collation Issue and Resolution

A real integration issue was found when joining TRIAS stop references to static GTFS stop identifiers.

Originally:

- `stg.MddRealtimeStopObservation.StopPointRef`
  - `SQL_Latin1_General_CP1_CI_AS`
- static GTFS `StopId`
  - `Latin1_General_100_BIN2`

This produced SQL Server error 468:

> Cannot resolve the collation conflict ... in the equal to operation.

Resolution:

`stg.MddRealtimeStopObservation.StopPointRef` was altered to:

`Latin1_General_100_BIN2`

After altering the underlying column, the metadata of:

`wrk.vwCologneRealtimeStopObservation`

still exposed the previous collation.

The view metadata was refreshed using:

`sys.sp_refreshview`

After refresh, realtime `StopPointRef` and static `StopId` both exposed:

`Latin1_General_100_BIN2`

The stop enrichment join then succeeded.

---

## 9. Static Stop Enrichment

Static GTFS at Köln Hbf contains both station-level and platform-level stops.

Examples:

Station:

`de:05315:11201` -> `Köln Hbf`

Platforms:

- `de:05315:11201:7:71` -> Gleis 1
- `de:05315:11201:7:72` -> Gleis 2
- `de:05315:11201:7:73` -> Gleis 3
- ...
- `de:05315:11201:7:81` -> Gleis 11

The TRIAS `StopPointRef` values therefore use identifiers that can directly match the static GTFS platform-level `StopId` values.

A validation query confirmed that static `StopId` maps consistently to a single `ParentStationId` and `StopName` in the current dataset.

### `wrk.vwCologneRealtimeStopEnriched`

This view enriches realtime observations with:

- `StaticParentStationId`
- `StaticStopName`
- `StaticStopMatched`

Primary rule:

`TRIAS StopPointRef = GTFS StopId`

No string truncation or guessed station-ID parsing is used as the primary mapping strategy.

---

## 10. Realtime Delay Logic

### `wrk.vwCologneRealtimeStopObservation`

This view derives:

`ArrivalDelayMinutes`

from:

- `TimetabledArrivalUtc`
- `EstimatedArrivalUtc`

using second-level difference divided by 60.

It also derives:

`PlatformChanged`

Rules:

- if `EstimatedBay` is NULL / blank -> `PlatformChanged = NULL`
- if both values exist and differ -> `1`
- if both exist and are equal -> `0`

This preserves the important distinction between:

- “no evidence of a realtime bay value”
- and
- “confirmed unchanged bay”.

---

## 11. Timezone Normalization

A major matching issue was discovered during TRIAS-to-GTFS trip matching.

TRIAS response timestamps were represented as UTC, e.g.:

`2026-09-03T19:37:00Z[GMT]`

Static GTFS uses local agency time.

For agency `5` (`DB DB Regio AG`):

`AgencyTimezone = Europe/Berlin`

The stop-level timezone for Köln Hbf platform 8 was NULL, so agency timezone applies.

All 15 agencies currently represented in `dw.DimAgency` use:

`Europe/Berlin`

For SQL Server conversion the working layer uses:

`W. Europe Standard Time`

Example:

`2026-09-03 19:37 UTC`
-> `2026-09-03 21:37 +02:00` Berlin local time.

### `wrk.vwCologneRealtimeTripMatchKey`

This view derives:

- `TimetabledArrivalLocal`
- `ServiceDateLocal`
- `ScheduledArrivalSecondsLocal`

This logic belongs in `wrk`, not staging.

---

## 12. GTFS Service-Day / After-Midnight Logic

Static GTFS schedule times are not limited to `00:00–23:59`.

Observed data:

- `24:00:00` -> `86400` seconds -> `ArrivalDayOffset = 1`
- `24:01:00` -> `86460` seconds -> `ArrivalDayOffset = 1`

Observed day-offset distribution:

- `ArrivalDayOffset = 0`
  - 1,488,108 stop events
- `ArrivalDayOffset = 1`
  - 63,231 stop events
- `ArrivalDayOffset = 2`
  - 4 stop events

Maximum observed arrival seconds:

`177780`

This corresponds to approximately:

`49:23:00`

The four `ArrivalDayOffset = 2` rows belong to an S12 trip and contain times such as:

- `48:50:00`
- `49:00:00`
- `49:13:00`
- `49:23:00`

### General matching formula

For a static candidate with `ArrivalDayOffset = N`:

`GTFS ServiceDate = TRIAS LocalCalendarDate - N days`

and:

`GTFS ScheduledArrivalSeconds = TRIAS LocalSecondsOfDay + (N * 86400)`

This logic is intentionally general and does not hard-code only offset 0 or 1.

---

## 13. TRIAS -> GTFS Trip Matching

Direct identifier equality is **not** valid.

Example:

TRIAS:

- `LineRef = ddb:90E09::R`
- `JourneyRef = ddb:90E09::R:j26:163`

Static GTFS RE9:

- `RouteId = de:nrw:re9:`
- GTFS `TripId` follows a completely different identifier scheme.

Therefore:

- `LineRef != RouteId`
- `JourneyRef != TripId`

The matching strategy is evidence-based.

### Core matching dimensions

1. normalized line name
2. stop / station
3. local scheduled time
4. GTFS service-day logic
5. active `ServiceId` on the corresponding service date

Line-name normalization currently removes spaces, e.g.:

- `RE 9` -> `RE9`
- `RB 27` -> `RB27`

### RE9 validation

TRIAS event:

- line: `RE 9`
- StopPointRef: `de:05315:11201:7:78`
- UTC planned arrival: `19:37`
- Berlin local arrival: `21:37`
- date: `2026-09-03`

Static GTFS initially produced multiple schedule candidates across services.

After applying `dw.DimService + dw.BridgeServiceDate + dw.DimDate`, only:

`ServiceId = 67358`

was active on `2026-09-03`.

The final static filter returned exactly one GTFS trip candidate:

- route: `de:nrw:re9:`
- service: `67358`
- headsign: `Aachen Hbf`
- platform-level stop: Gleis 8

This validated the general matching approach.

---

## 14. Match Hierarchy

Testing all five realtime examples showed that exact platform matching alone is insufficient.

The finalized hierarchy is:

### 1. `StaticCoverageMissing`

Use when the realtime line does not exist in the static route coverage.

### 2. `ExactStopMatch`

Use when exactly one valid active GTFS candidate matches:

- normalized line,
- service date,
- scheduled local time,
- exact `StopId`.

### 3. `ParentStationFallback`

Use when exact stop match does not exist, but exactly one candidate matches the same parent station.

### 4. `Unresolved`

Use when the event is covered by static data but the available evidence does not produce exactly one usable candidate.

### Test results

| TRIAS line | Result |
|---|---|
| ICE | `StaticCoverageMissing` |
| RE 7 | `ExactStopMatch` |
| RB 27 | `ParentStationFallback` |
| RB 25 | `ExactStopMatch` |
| RE 9 | `ExactStopMatch` |

---

## 15. RB27 Platform-Mismatch Validation

TRIAS reported:

`de:05315:11201:7:73`
-> Köln Hbf, Gleis 3

The corresponding static GTFS active trip matched at parent-station level but reported:

`de:05315:11201:7:74`
-> Köln Hbf, Gleis 4

The static candidate was:

- `RouteShortName = RB27`
- `ServiceId = 50242`
- `TripHeadsign = Troisdorf Bf`
- scheduled local arrival = `21:35`

Therefore this event is correctly classified as:

`ParentStationFallback`

This is evidence of a platform mismatch between realtime TRIAS and static GTFS, not a failed trip match.

---

## 16. ICE Static-Coverage Investigation

The ICE realtime event did not match even after removing:

- exact platform restriction,
- line-name restriction.

A direct search of the current static route and trip views for ICE returned zero rows.

Therefore, for the current static dataset:

**ICE is not represented in `wrk.vwCologneServingRoute` / `wrk.vwCologneServingTrip`.**

The event is therefore classified as:

`StaticCoverageMissing`

and **not** `MatchFailed`.

This distinction is important for future data-quality reporting.

---

## 17. `wrk.vwCologneRealtimeTripMatch`

This is now the canonical working view for realtime-to-static trip matching.

Important output columns include:

- `ExactStopCandidateCount`
- `ParentStationCandidateCount`
- `MatchStatus`
- `MatchedTripId`
- `MatchedRouteId`
- `MatchedServiceId`
- `MatchedStaticStopId`

The view preserves the source realtime identifiers while attaching a static match only when the matching rules produce a usable result.

---

## 18. `wrk.vwCologneRealtimeEvidenceSituation`

This is currently the highest-level realtime working view.

It combines:

### Realtime evidence

- observation identity
- realtime stop identity
- line / journey references
- planned and estimated arrival
- calculated delay
- planned / estimated bay
- platform-change inference

### Static enrichment

- parent station
- static stop name
- local-time normalization
- service-day matching keys
- GTFS trip match
- GTFS route match
- GTFS service match
- matched static stop

### Match quality

- candidate counts
- `MatchStatus`
- `HasUsableStaticMatch`

### Situation context

- relation scope
- situation observation key
- participant ref
- situation number
- summary
- description
- detail
- validity window

---

## 19. `HasUsableStaticMatch`

A derived `bit` column has been added to:

`wrk.vwCologneRealtimeEvidenceSituation`

Logic:

Usable:

- `ExactStopMatch`
- `ParentStationFallback`

Not usable:

- `StaticCoverageMissing`
- `Unresolved`

The expression was wrapped with `ISNULL(..., 0)` so SQL Server metadata correctly reports:

- datatype: `bit`
- nullable: `0`

This is useful for later analytics and quality KPIs.

---

## 20. Important Modeling Decisions

The following decisions are now established.

### Source vs derived data

Keep source values in `stg`.

Calculate / normalize in `wrk`.

Examples:

Source-aligned:

- TRIAS stop ref
- journey ref
- line ref
- planned bay
- estimated bay
- situation number

Derived:

- delay minutes
- platform changed
- local service time
- local scheduled seconds
- static-match status
- usable-match flag

### Do not infer absent source fields

Do not add departure or cancellation fields until an actual TRIAS response demonstrates the source structure needed to populate them.

### Do not equate TRIAS and GTFS IDs

Never assume:

- TRIAS `JourneyRef = GTFS TripId`
- TRIAS `LineRef = GTFS RouteId`

Matching must use validated schedule/service evidence.

### Parent-station fallback is legitimate

A platform mismatch does not automatically invalidate a trip match.

If exact stop fails but the same line/time/service resolves uniquely at parent-station level, classify it as:

`ParentStationFallback`

### Coverage gaps are not match failures

A realtime event whose line is absent from the static GTFS coverage must be classified separately as:

`StaticCoverageMissing`

---

## 21. Current Realtime Persistence State

During the design and validation work, the implementation intentionally avoided inserting the tested realtime response into SQL while storage/retention permission was being clarified.

A final three-table row-count checkpoint was requested for:

- `stg.MddRealtimeStopObservation`
- `stg.MddRealtimeSituationObservation`
- `stg.MddRealtimeStopSituationLink`

The row-count result was not shown in the conversation before the confirmation email was received.

Therefore the precise current database row counts should be verified before the collector is enabled.

---

## 22. Next Recommended Steps

### Compliance checkpoint

1. Add the exact confirmation-email wording to repository documentation.
2. Record any conditions or retention limits exactly.
3. Mark the permission decision and date.

### Database checkpoint

4. Confirm the current row count of all three realtime staging tables.

### Collector implementation

5. Build the production parser / collector for TRIAS arrival observations.
6. Populate:
   - realtime stop observation,
   - situation observations,
   - stop-situation bridge.
7. Keep source fields source-aligned.
8. Apply deduplication using the established observation uniqueness rules.

### Validation

9. Run the existing five-event sample through the real staging/working pipeline.
10. Verify expected statuses:
    - ICE -> `StaticCoverageMissing`
    - RE7 -> `ExactStopMatch`
    - RB27 -> `ParentStationFallback`
    - RB25 -> `ExactStopMatch`
    - RE9 -> `ExactStopMatch`
11. Verify delay calculations and situation links.
12. Verify null semantics for `EstimatedBay` and `PlatformChanged`.

### Later extensions

13. Investigate departure events with a real departure-oriented TRIAS response.
14. Investigate cancellation semantics only from real source fields.
15. Add data-quality KPIs:
    - exact-match rate,
    - parent-fallback rate,
    - unresolved rate,
    - static-coverage-missing rate.
16. Build the final realtime analytical fact only after staging and matching behavior is stable.

---

## 23. Current Architecture Summary

```text
MDD NRW / DELFI / TRIAS
        |
        v
stg.MddRealtimeStopObservation
stg.MddRealtimeSituationObservation
stg.MddRealtimeStopSituationLink
        |
        v
wrk.vwCologneRealtimeStopObservation
        |
        v
wrk.vwCologneRealtimeStopEnriched
        |
        v
wrk.vwCologneRealtimeTripMatchKey
        |
        v
wrk.vwCologneRealtimeTripMatch
        |
        +------------------------+
        |                        |
        v                        v
Static GTFS / DW            Situation links
        |                        |
        +-----------+------------+
                    |
                    v
wrk.vwCologneRealtimeEvidenceSituation
                    |
                    v
Future DW realtime fact / analytics / Power BI
```

---

## 24. Status at This Checkpoint

At the end of this checkpoint:

- MDD authentication works.
- TRIAS requests work.
- HTTP 200 realtime response confirmed.
- Arrival parsing works.
- Delay calculation logic is established.
- Situation extraction is established.
- Stop-situation relationship model is established.
- bay/platform source fields are understood.
- stop-level static enrichment works.
- collation conflict is resolved.
- UTC -> Europe/Berlin normalization is established.
- GTFS after-midnight service-day logic is validated up to `ArrivalDayOffset = 2`.
- TRIAS -> GTFS trip matching hierarchy is validated on the five-event sample.
- `StaticCoverageMissing`, `ExactStopMatch`, `ParentStationFallback`, and `Unresolved` are established statuses.
- `HasUsableStaticMatch` is available as a non-null bit.
- confirmation email regarding storage/retention has been received according to the user.
- production realtime persistence / collector activation is the next major implementation phase after compliance wording and row-count checkpoint are recorded.

---

## Compliance Update Pending Exact Email Text

A confirmation email regarding storage/retention has been received. The exact wording, permitted retention, restrictions, attribution requirements, redistribution conditions, and any other obligations will be inserted here after the user provides the email text. Until then, this document deliberately records only the fact that confirmation was received and does not infer its legal scope.
