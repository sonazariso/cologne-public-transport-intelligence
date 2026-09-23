# StaticCoverageMissing Root-Cause Investigation

Status: DIAGNOSTIC COMPLETE

This document records the read-only investigation requested by
prompts/05-OptimSql/o4-7.md. Instructions in that prompt were treated as the
analysis specification; this document does not authorize a production matching
change.

## Execution record

| Field | Value |
| --- | --- |
| Branch | analysis/static-coverage-missing-root-cause |
| Database | CologneTransitIntelligence |
| Analysis script | sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql |
| AnalysisRunAtUtc | 2026-09-23 08:18:29.9785538 |
| Realtime observation range | 2026-09-05 08:27:28 through 2026-09-23 08:13:52 UTC |
| Execution status | PASS — one batch, 21 result sets, no SQL errors |
| Persistence | Session-scoped temporary tables and indexes only |

[FACT] The diagnostic executed against the current production matching views
and loaded static feed. It did not change collector parsing, warehouse
objects, MatchStatus logic, Power BI logic, sampling, or timing logic.

Timing Unavailable was intentionally outside this investigation. No conclusion
below should be read as a Timing Unavailable analysis.

## Current matching chain

The audited chain is:

| Stage | Object or source | Relevant evidence |
| --- | --- | --- |
| Realtime persistence | stg.MddRealtimeStopObservation | Stores the parsed stop observation fields listed in the realtime inventory below. |
| Realtime observation view | wrk.vwCologneRealtimeStopObservation | Carries the staging row into the working layer and derives delay/platform values. |
| Static stop enrichment | wrk.vwCologneRealtimeStopEnriched | Uses dw.DimStop and dw.FactScheduledStopEvent for exact stop and parent-station evidence. |
| Match key | wrk.vwCologneRealtimeTripMatchKey | Derives local timetabled arrival, service date, and scheduled local seconds. |
| Current route coverage | wrk.vwCologneServingRoute | Derives the Cologne-serving route set from GTFS trips and stop times containing a de:05315:% stop. |
| Trip match | wrk.vwCologneRealtimeTripMatch | Applies route coverage, active service date, stop/time constraints, and MatchStatus. |

[FACT] The current route coverage comparison is the normalized realtime
LineName against the normalized RouteShortName set from
wrk.vwCologneServingRoute. The production branch is effectively:

    WHEN route coverage is absent THEN StaticCoverageMissing

[FACT] The static route-name join is required before the current scheduled-stop
candidate logic can produce ExactStopMatch or ParentStationFallback. The
diagnostic therefore materializes route-independent candidates separately; it
does not change the production view.

## Population and status reconciliation

| MatchStatus | Count | Rate |
| --- | ---: | ---: |
| ExactStopMatch | 5,693 | 74.691682% |
| ParentStationFallback | 121 | 1.587510% |
| StaticCoverageMissing | 1,727 | 22.658095% |
| Unresolved | 81 | 1.062713% |
| Total | 7,622 | 100% |

[FACT] The status counts reconcile to 7,622 observations. The investigation
therefore covers 1,727 affected observations, 28 distinct LineName values,
and 26 distinct StopPointRef values.

## Realtime field inventory

[FACT] The inventory below is for the current 1,727
StaticCoverageMissing observations. Non-null and null counts are row counts;
distinct counts are distinct non-null values. Result set 3 of the SQL script
also emits the top five representative values for every audited field.

| Field | Total rows | Non-null | Null | Distinct |
| --- | ---: | ---: | ---: | ---: |
| DirectionRef | 1,727 | 1,727 | 0 | 2 |
| EstimatedArrivalUtc | 1,727 | 1,572 | 155 | 1,296 |
| EstimatedBay | 1,727 | 76 | 1,651 | 16 |
| JourneyRef | 1,727 | 1,727 | 0 | 642 |
| LineName | 1,727 | 1,727 | 0 | 28 |
| LineRef | 1,727 | 1,727 | 0 | 60 |
| ObservationKey | 1,727 | 1,727 | 0 | 1,727 |
| ObservedAtUtc | 1,727 | 1,727 | 0 | 768 |
| OperatorRef | 1,727 | 1,727 | 0 | 8 |
| PlannedBay | 1,727 | 1,610 | 117 | 25 |
| PtMode | 1,727 | 1,727 | 0 | 2 |
| RailSubmode | 1,727 | 1,557 | 170 | 4 |
| ResultId | 1,727 | 1,727 | 0 | 1,727 |
| StopName | 1,727 | 1,727 | 0 | 5 |
| StopPointRef | 1,727 | 1,727 | 0 | 26 |
| TimetabledArrivalUtc | 1,727 | 1,727 | 0 | 1,143 |

Representative values from the current run include:

| Field | Representative value |
| --- | --- |
| DirectionRef | inward |
| EstimatedArrivalUtc | 2026-09-06 21:08:00 |
| EstimatedBay | 6 |
| JourneyRef | ddb:90E01::R:j26:518 |
| LineName | ICE |
| LineRef | ddb:90E01::R |
| ObservationKey | 1 |
| ObservedAtUtc | 2026-09-06 16:33:49 |
| OperatorRef | ddb:80 |
| PlannedBay | 9 D-G |
| PtMode | RAIL |
| RailSubmode | LOCAL |
| ResultId | ID-0046B369-F740-4116-A0EA-CA2558FC8442 |
| StopName | Köln Hbf |
| StopPointRef | de:05315:11201:7:77 |
| TimetabledArrivalUtc | 2026-09-06 20:11:00 |

## Collector parser lineage

[FACT] ConvertFrom-MddTriasResponse in
collector/MddRealtimeCollector.psm1 parses and persists the following service
and stop fields:

| Persisted field | Parser source |
| --- | --- |
| ObservedAtUtc | serviceDelivery.responseTimestamp |
| ResultId | result.resultId |
| StopPointRef | call.stopPointRef |
| StopName | call.stopPointName |
| LineName | serviceSection.publishedLineName |
| LineRef | serviceSection.lineRef |
| JourneyRef | service.journeyRef |
| DirectionRef | serviceSection.directionRef |
| OperatorRef | serviceSection.operatorRef |
| PtMode | serviceSection.ptMode |
| RailSubmode | serviceSection.railSubmode |
| TimetabledArrivalUtc | serviceArrival.timetabledTime |
| EstimatedArrivalUtc | serviceArrival.estimatedTime |
| PlannedBay | call.plannedBay |
| EstimatedBay | call.estimatedBay |

ObservationKey is identity-generated and CreatedAtUtc is database-defaulted.
The parser separately handles situations and situation links, but the current
persisted stop-observation contract does not store a raw TRIAS response or
additional unparsed service-identification fields. No additional matching
identifier is therefore claimed without a source-contract change.

## Loaded static identifiers and schedules

[FACT] The static identifier inventory used by the diagnostic is:

| Source object | Field | Total rows | Non-null | Null | Distinct |
| --- | --- | ---: | ---: | ---: | ---: |
| dw.BridgeServiceDate + dw.DimDate | ServiceDate | 99,399 | 99,399 | 0 | 182 |
| stg.GtfsRoutes | AgencyId | 981 | 981 | 0 | 36 |
| stg.GtfsRoutes | RouteDesc | 981 | 844 | 137 | 787 |
| stg.GtfsRoutes | RouteId | 981 | 981 | 0 | 980 |
| stg.GtfsRoutes | RouteLongName | 981 | 12 | 969 | 6 |
| stg.GtfsRoutes | RouteShortName | 981 | 969 | 12 | 834 |
| stg.GtfsRoutes | RouteType | 981 | 981 | 0 | 4 |
| stg.GtfsStops | ParentStation | 30,719 | 20,755 | 9,964 | 9,964 |
| stg.GtfsStops | StopId | 30,719 | 30,719 | 0 | 30,719 |
| stg.GtfsStopTimes | ArrivalTime | 3,818,617 | 3,818,617 | 0 | 1,768 |
| stg.GtfsStopTimes | DepartureTime | 3,818,617 | 3,818,617 | 0 | 1,765 |
| stg.GtfsStopTimes | StopId | 3,818,617 | 3,818,617 | 0 | 20,722 |
| stg.GtfsStopTimes | StopSequence | 3,818,617 | 3,818,617 | 0 | 83 |
| stg.GtfsTrips | BlockId | 167,386 | 0 | 167,386 | 0 |
| stg.GtfsTrips | DirectionId | 167,386 | 167,386 | 0 | 2 |
| stg.GtfsTrips | RouteId | 167,386 | 167,386 | 0 | 980 |
| stg.GtfsTrips | ServiceId | 167,386 | 167,386 | 0 | 6,337 |
| stg.GtfsTrips | ShapeId | 167,386 | 167,386 | 0 | 13,695 |
| stg.GtfsTrips | TripHeadsign | 167,386 | 167,386 | 0 | 2,224 |
| stg.GtfsTrips | TripId | 167,386 | 167,386 | 0 | 167,386 |

The audited static fields are present in the loaded feed, but field presence
does not prove that the realtime and GTFS identifiers share a namespace.

## Deterministic identifier comparisons

The diagnostic performs exact comparisons only. It does not use fuzzy
matching, inferred prefixes, or an invented namespace map.

| Test | Definition | Evidence in the affected population |
| --- | --- | --- |
| A. LineName vs RouteShortName | Exact normalized text against all loaded GTFS routes | 83 observations; 1 distinct static RouteId |
| B. Trimmed LineName vs RouteLongName | Exact equality after LTRIM/RTRIM | 3 observations; 9 distinct static RouteIds |
| C. Spaces-removed LineName vs RouteLongName | Exact equality after removing spaces | 737 observations; 9 distinct static RouteIds |
| D. Trimmed LineName vs RouteShortName | Exact equality after LTRIM/RTRIM | Materialized per observation as TrimmedLineNameRouteShortNameCount; not promoted to a production rule |
| E. Current production rule | Spaces-removed LineName against the Cologne-serving RouteShortName set | 0 current serving-route matches for the affected population; 83 matches exist only in the complete loaded route set |

The direct identifier tests requested by the investigation produced no exact
affected-observation evidence:

| Test | Result | Interpretation |
| --- | ---: | --- |
| LineRef = RouteId | 0 | Exact text comparison only; no project namespace transformation is defined |
| OperatorRef = AgencyId | 0 | OperatorRef and AgencyId are separate fields with no project mapping |
| JourneyRef = TripId | 0 | Exact opaque-text comparison only |
| DirectionRef = DirectionId | 0 | Exact textual comparison only; no conversion or mapping |

PtMode and RailSubmode are tested only against schedule candidate ModeGroup,
ModeDetail, and do not establish a cross-system identifier namespace.

## Route-independent schedule candidates

[FACT] Candidate resolution deliberately ignores LineName, LineRef,
RouteShortName, and RouteLongName. It uses:

- exact StopId, with parent-station fallback only when no exact stop candidate exists;
- local scheduled arrival seconds;
- active service date through BridgeServiceDate and DimDate.

| Candidate result for affected observations | Count |
| --- | ---: |
| No candidate | 530 |
| Exactly one candidate | 1,030 |
| Multiple candidates | 167 |
| Total | 1,727 |

The exactly-one result set includes the full realtime identity, static RouteId,
RouteShortName, RouteLongName, AgencyId, TripId, TripHeadsign, DirectionId,
StopId, scheduled arrival, and mode. Examples include:

| Realtime evidence | Unique static candidate | Current condition that blocked the production match |
| --- | --- | --- |
| ICE; LineRef ddb:98X39::R; stop de:05315:11201:7:75; timetabled 2026-09-05 08:06:00 | Route de:nrw:s11:, Trip 32156-1211-005-9690.7.74:093300-19-3_6FBB505E-03E4-44AB-8D2E-B4B3014A1B6C, static short name S11 | Current production coverage requires normalized LineName = normalized RouteShortName in the Cologne-serving route set |
| ICE; LineRef ddb:98X79::H; stop de:05315:11201:7:74; timetabled 2026-09-05 08:16:00 | Route de:nrw:s6:, static short name S6, headsign Dellbrück S-Bahn | Same route-name and serving-scope condition |
| RE1 (RRX); LineRef ddb:90E01::R; stop de:05315:19201:7:71; timetabled 2026-09-23 07:01:00 | Route de:nrw:re1:, static short name NULL, long name RE1 (RRX), Aachen Hbf | Realtime label is represented by RouteLongName while the current RouteShortName join has no value |

The multiple-candidate evidence test is intentionally applied one evidence type
at a time:

| Evidence test | Multiple observations | Zero candidates | Exactly one | Still multiple |
| --- | ---: | ---: | ---: | ---: |
| Before additional evidence | 167 | 0 | 0 | 167 |
| LineRef = RouteId | 167 | 167 | 0 | 0 |
| JourneyRef = TripId | 167 | 167 | 0 | 0 |
| OperatorRef = AgencyId | 167 | 167 | 0 | 0 |
| DirectionRef = DirectionId | 167 | 167 | 0 | 0 |
| PtMode = ModeGroup or ModeDetail | 167 | 0 | 10 | 157 |
| RailSubmode = ModeDetail | 167 | 167 | 0 | 0 |

[FACT] The exact identifier comparisons eliminate the candidate set rather
than select a candidate. PtMode produces ten unique results but leaves 157
ambiguous; it is not sufficient as a standalone production rule.

## No-candidate evidence

The 530 no-candidate observations have the following directly evidenced
conditions. These are evidence buckets, not an alternative mutually exclusive
root-cause assignment.

| Evidence reason | Observations | Distinct lines | Distinct stops | Evidence |
| --- | ---: | ---: | ---: | --- |
| NoDeterministicRouteOrActiveScheduleEvidence | 421 | 9 | 12 | Static stop matched and timetabled time present, but no deterministic route or active schedule candidate was found |
| RealtimeStopNotFoundInWarehouseStaticStopDimension | 42 | 9 | 7 | StaticStopMatched = 0; timetabled time was present |
| StaticRouteEvidenceExistsButNoActiveStopTimeServiceDateCandidate | 67 | 2 | 4 | Static route identifier/label evidence exists, but no active stop/time/service-date candidate was found |

No no-candidate row in this run was caused by a missing
TimetabledArrivalUtc.

## Mutually exclusive observation-level root causes

The root category is assigned once per affected observation, with precedence
defined in the SQL script. The categories reconcile exactly to 1,727.

| Root cause category | Observations | Share |
| --- | ---: | ---: |
| CurrentRouteNameRuleMissesDeterministicStaticRoute | 1,030 | 59.640996% |
| NoMatchingRouteInLoadedStaticFeed | 441 | 25.535611% |
| StaticRouteExistsButOutsideCurrentCologneScope | 83 | 4.806022% |
| StaticScheduleCandidateAmbiguous | 167 | 9.669948% |
| StaticStopOrScheduleEvidenceMissing | 6 | 0.347423% |
| IdentifierNamespaceNotComparable | 0 | Not assigned; no project namespace mapping was proven |
| OtherProvenCause | 0 | No other proven cause in the audited evidence |
| Unexplained fallback | 0 | 0 |
| Total | 1,727 | 100% |

[CONCLUSION] The current route-name rule is materially responsible for a
substantial portion of the misses, but not all of them. It explains a
deterministic schedule candidate for 1,030 observations. The remaining
observations are split between no loaded-feed evidence, ambiguous schedule
evidence, a loaded route outside the current Cologne scope, and six missing
static stop/schedule evidence cases.

## Current Cologne-serving scope finding

The loaded route found by the current normalized short-name rule but absent
from the current Cologne-serving route set is:

| RouteId | ShortName | LongName | Agency | Loaded trips | Static stops | Cologne static stops | Affected observations |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| de:vrs:885:111 | 885 | NULL | RVK Regionalverkehr Köln GmbH NL Euskirchen | 7 | 18 | 0 | 83 |

[FACT] The route's loaded static stop locations are outside the Cologne
monitored-stop scope, including Kall and Hellenthal locations. The affected
realtime observations nevertheless occurred at three Cologne monitored
StopPointRef values. This is an observed data-scope contradiction; the
diagnostic does not infer whether the static feed, realtime feed, or scope
configuration is the source of the contradiction.

The complete line-level result set records LineRefs
bvr:88885::H and bvr:88885::R for this affected 885 group.

## Complete affected-line result

The SQL result set 16 is the authoritative complete table and includes the
distinct LineRefs, observation count, stop count, and explanation for every
line/category row. The compact table below contains all 39 rows; long raw
LineRef lists are kept in the result set so the report remains readable.

| LineName | Root cause category | Observations | Stops |
| --- | --- | ---: | ---: |
| 188 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 9 | 1 |
| 188 | NoMatchingRouteInLoadedStaticFeed | 17 | 1 |
| 885 | StaticRouteExistsButOutsideCurrentCologneScope | 83 | 3 |
| 885E | NoMatchingRouteInLoadedStaticFeed | 4 | 1 |
| 885E | StaticScheduleCandidateAmbiguous | 1 | 1 |
| BSV 11008 8211008 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 1 | 1 |
| FlixTrain | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| IC | CurrentRouteNameRuleMissesDeterministicStaticRoute | 29 | 3 |
| IC | NoMatchingRouteInLoadedStaticFeed | 101 | 4 |
| IC | StaticScheduleCandidateAmbiguous | 18 | 2 |
| ICE | CurrentRouteNameRuleMissesDeterministicStaticRoute | 234 | 7 |
| ICE | NoMatchingRouteInLoadedStaticFeed | 298 | 8 |
| ICE | StaticScheduleCandidateAmbiguous | 135 | 5 |
| ICE 126 ICE International | StaticScheduleCandidateAmbiguous | 1 | 1 |
| ICE 29 InterCityExpress | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| NJ 403 NightJet | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| RE 1 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 424 | 6 |
| RE 1 (RRX) | StaticScheduleCandidateAmbiguous | 2 | 1 |
| RE 1 (RRX) | StaticStopOrScheduleEvidenceMissing | 6 | 2 |
| RE 5 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 161 | 3 |
| RE 6 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 131 | 2 |
| RE 6 (RRX) | StaticScheduleCandidateAmbiguous | 10 | 2 |
| RE1 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 1 | 1 |
| RE5 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 1 | 1 |
| RE6 (RRX) | CurrentRouteNameRuleMissesDeterministicStaticRoute | 1 | 1 |
| SEV | NoMatchingRouteInLoadedStaticFeed | 2 | 1 |
| SEV RB38 | NoMatchingRouteInLoadedStaticFeed | 2 | 1 |
| SEV RE 1 | NoMatchingRouteInLoadedStaticFeed | 2 | 1 |
| SEV RE6X | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| SEV RE8 | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| SEV S 11 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 6 | 2 |
| SEV S 11 | NoMatchingRouteInLoadedStaticFeed | 5 | 1 |
| SEV S 19 | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |
| SEV S 6 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 20 | 1 |
| SEV S 6X | CurrentRouteNameRuleMissesDeterministicStaticRoute | 5 | 1 |
| SEV S11 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 1 | 1 |
| SEV S11 | NoMatchingRouteInLoadedStaticFeed | 3 | 2 |
| SEV S6 | CurrentRouteNameRuleMissesDeterministicStaticRoute | 6 | 1 |
| THA 9471 Thalys | NoMatchingRouteInLoadedStaticFeed | 1 | 1 |

## High-volume line groups

[FACT] The requested high-volume groups were investigated with distinct
LineRefs, journeys, operators, modes, schedule-candidate counts, and root
distribution. The exact raw LineRef, JourneyRef, and candidate RouteId lists
are emitted by result set 14.

| LineName | Obs | Stops | Distinct LineRefs | Journeys | Operators | Mode / submode | No candidate | Exactly one | Multiple |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| ICE | 667 | 8 | 28 | 250 | 2 | RAIL / HIGH_SPEED_RAIL | 298 | 234 | 135 |
| IC | 148 | 5 | 5 | 62 | 1 | RAIL / INTERNATIONAL | 101 | 29 | 18 |
| RE 1 (RRX) | 432 | 6 | 4 | 100 | 1 | RAIL / LOCAL | 6 | 424 | 2 |
| RE 5 (RRX) | 161 | 3 | 3 | 59 | 1 | RAIL / LOCAL | 0 | 161 | 0 |
| RE 6 (RRX) | 141 | 2 | 2 | 64 | 1 | RAIL / LOCAL | 0 | 131 | 10 |

High-volume findings:

- ICE has no direct loaded GTFS RouteId/RouteShortName/RouteLongName evidence
  in the diagnostic fields; its route-independent schedule candidates span
  multiple NRW regional and S-Bahn route IDs.
- IC has the same absence of direct loaded GTFS route evidence, with a mixed
  candidate set.
- RE 1, RE 5, and RE 6 have loaded routes whose RouteLongName values are
  RE1 (RRX), RE5 (RRX), and RE6 (RRX), while RouteShortName is NULL in the
  affected loaded rows. This explains why the current RouteShortName rule
  misses the label, but it does not by itself prove a unique route in every
  case.
- Root distributions for the groups are: ICE current-rule 234, no loaded
  match 298, ambiguous 135; IC current-rule 29, no loaded match 101,
  ambiguous 18; RE 1 current-rule 424, ambiguous 2, static stop/schedule
  evidence missing 6; RE 5 current-rule 161; RE 6 current-rule 131,
  ambiguous 10.

## Explicit answer and future strategy evaluation

### Does the current short-name rule materially cause StaticCoverageMissing?

**PARTIALLY.**

[FACT] The route-name rule is materially causal for 1,030 of 1,727 affected
observations (59.640996%) under the narrow definition used here: one
route-independent stop/time/service-date candidate, or one candidate after one
individual exact identifier test. It is not a complete explanation because 441
observations have no matching route or active schedule evidence, 167 remain
ambiguous, 83 are outside the current Cologne scope, and 6 lack static
stop/schedule evidence. Unexplained fallback is zero.

### Candidate strategy results

| Strategy | Evidence observations | Unique resolutions | Ambiguous | No evidence | Evaluation |
| --- | ---: | ---: | ---: | ---: | --- |
| LineName -> loaded RouteShortName | 83 | 83 | 0 | 1,644 | Evidence is outside current serving scope for the affected rows; not a safe production change by itself |
| LineName -> RouteLongName, trimmed or spaces removed | 737 | 0 | 737 | 990 | Recovers label evidence but never uniquely resolves an affected observation |
| LineRef -> RouteId | 0 | 0 | 0 | 1,727 | No exact evidence in the current namespaces |
| Unique stop + service date + scheduled time | 1,197 | 1,030 | 167 | 530 | Useful diagnostic candidate set; uniqueness is not sufficient for production matching without regression controls |

### Regression safety against successful matches

The successful population is the current ExactStopMatch plus
ParentStationFallback population: 5,814 observations in this run
(5,693 exact and 121 parent-station fallback).

| Strategy | Preserve same route | Conflicting route | Ambiguous | No evidence | Safety result |
| --- | ---: | ---: | ---: | ---: | --- |
| LineRef -> RouteId | 0 | 0 | 0 | 5,814 | No evidence to apply |
| LineName -> loaded RouteShortName | 2,642 | 0 | 3,172 | 0 | Requires review; many successful rows have multiple loaded route candidates |
| LineName -> RouteLongName | 0 | 0 | 0 | 5,814 | No evidence to apply |
| Unique stop + service date + scheduled time | 5,307 | 11 | 496 | 0 | Not safe as a standalone production rule |

[FACT] The schedule-only strategy would introduce 11 conflicting routes and
496 ambiguous candidates among currently successful observations. It is
therefore diagnostic evidence, not an implementation recommendation.

### Future changes — not implemented

The evidence supports future investigation of:

1. a validated source-specific mapping between realtime LineRef/JourneyRef and
   GTFS RouteId/TripId, if the feed owner can document that namespace;
2. a curated route-label strategy that treats RouteLongName as supporting
   evidence only and requires unique stop/time/service-date and scope checks;
3. a static-feed validation gate for routes with NULL RouteShortName,
   contradictory Cologne scope, or missing active stop/time/service-date rows;
4. an explicit ambiguity policy that preserves ExactStopMatch and
   ParentStationFallback behavior and rejects unresolved candidates.

These were future design options at the time of the v131 investigation; that
diagnostic branch did not implement any of them.

## Production remediation

Status: VALIDATED

This section records the production matching correction separately from the
completed v131 investigation above. The historical findings and their original
counts are preserved unchanged.

### Execution record

| Field | Value |
| --- | --- |
| Branch | fix/static-coverage-route-long-name-fallback |
| Implementation timestamp | 2026-09-23 09:12:18 UTC |
| Development database | CologneTransitIntelligence |
| Working-layer deployment | `sql/03-working/03-create-cologne-realtime-working-layer.sql` completed successfully |
| Focused validator | `sql/03-working/05-validate-static-coverage-route-long-fallback.sql` |
| Validator execution | 2026-09-23 09:30:48–09:31:28 UTC |
| Root-cause rerun | 2026-09-23 09:36:17.6027703 UTC |
| Operational fact refresh | Not executed |

### Exact matching change

`wrk.vwCologneRealtimeTripMatch` now has an explicit primary/fallback
architecture:

1. The existing normalized `LineName -> RouteShortName` candidate path remains
   primary, with its joins, scheduled-arrival-second predicate, active service
   date, `ArrivalDayOffset`, exact stop, and parent-station rules unchanged.
2. Only when no current Cologne-serving `RouteShortName` coverage exists, the
   view evaluates a secondary `LineName -> RouteLongName` path.
3. The fallback uses only ordinary-space removal after trim. Punctuation and
   parentheses remain significant; no fuzzy or regex-like transformation is
   performed.
4. Fallback routes are the intersection of `wrk.vwCologneServingRoute` and
   the corresponding `dw.DimRoute` rows. An arbitrary `stg.GtfsRoutes` row is
   not eligible.
5. Candidate selection remains unique exact stop first, then unique
   parent-station fallback; all other covered cases remain `Unresolved`.

`RouteShortName` was kept primary because changing it to
`COALESCE(RouteShortName, RouteLongName)` or using a broad `OR` join would
change successful-match semantics and could introduce ambiguity. The fallback
is gated so observations with valid short-name coverage never receive
RouteLongName candidates.

Schedule-only matching was rejected. The v131 regression evidence showed 11
conflicting routes and 496 ambiguous candidates among currently successful
observations. No schedule-only production fallback was added.

No LineRef/RouteId, JourneyRef/TripId, OperatorRef/AgencyId, DirectionRef,
PtMode, RailSubmode, TripHeadsign, manual alias, SEV-prefix, ICE/IC, or other
unproven identifier strategy was added.

### Frozen-scope status migration and validation

The focused validator froze 7,697 observation keys for both implementations.
The v131 short-name-only baseline and the deployed implementation reconciled as
follows:

| Legacy v131 status | New status | ObservationCount |
| --- | --- | ---: |
| ExactStopMatch | ExactStopMatch | 5,752 |
| ParentStationFallback | ParentStationFallback | 122 |
| StaticCoverageMissing | ExactStopMatch | 713 |
| StaticCoverageMissing | ParentStationFallback | 21 |
| StaticCoverageMissing | StaticCoverageMissing | 999 |
| StaticCoverageMissing | Unresolved | 9 |
| Unresolved | Unresolved | 81 |

All other cells in the validator's complete 4 x 4 matrix are zero. In
particular:

- protected `ExactStopMatch` regression: 0;
- protected `ParentStationFallback` regression: 0;
- legacy `Unresolved` changes: 0;
- fallback validation violations: 0;
- row-grain violations: 0;
- total and distinct `ObservationKey` counts before/after: 7,697 / 7,697.

The newly matched count is 734: 713 `ExactStopMatch` and 21
`ParentStationFallback`. The newly `Unresolved` count is 9; these observations
have qualifying Cologne-serving RouteLongName coverage but do not satisfy a
unique stop candidate rule. The frozen-scope residual is 999
`StaticCoverageMissing` observations (12.979083%).

### Fallback result groups

| LineName | NewMatchStatus | MatchedRouteId | ObservationCount | DistinctStopPointRefCount |
| --- | --- | --- | ---: | ---: |
| RE 1 (RRX) | ExactStopMatch | de:nrw:re1: | 416 | 6 |
| RE 1 (RRX) | ParentStationFallback | de:nrw:re1: | 11 | 2 |
| RE 5 (RRX) | ExactStopMatch | de:nrw:re5: | 162 | 3 |
| RE 6 (RRX) | ExactStopMatch | de:nrw:re6: | 132 | 2 |
| RE 6 (RRX) | ParentStationFallback | de:nrw:re6: | 10 | 2 |
| RE1 (RRX) | ExactStopMatch | de:nrw:re1: | 1 | 1 |
| RE5 (RRX) | ExactStopMatch | de:nrw:re5: | 1 | 1 |
| RE6 (RRX) | ExactStopMatch | de:nrw:re6: | 1 | 1 |

Fallback-covered rows that remained unresolved were grouped as:

| LineName | ObservationCount |
| --- | ---: |
| RE 1 (RRX) | 9 |

These names are reported outcomes, not hardcoded acceptance criteria.

### Root-cause rerun results

The required root-cause script was rerun after deployment. Its status
reconciliation was `PASS` and it completed with no SQL errors. Because the
realtime source is append-only, five observations arrived between the frozen
validator and this rerun; therefore the live rerun total is 7,702 rather than
7,697.

| Metric | v131 diagnostic baseline | Post-remediation rerun |
| --- | ---: | ---: |
| Total observations | 7,622 | 7,702 |
| ExactStopMatch | 5,693 | 6,470 |
| ParentStationFallback | 121 | 143 |
| StaticCoverageMissing | 1,727 | 999 |
| StaticCoverageMissing rate | 22.658095% | 12.970657% |
| Unresolved | 81 | 90 |

StaticCoverageMissing therefore fell by 728 observations, a 42.154024%
reduction against the v131 diagnostic baseline. The diagnostic's legacy
single-branch condition probe reports `REVIEW` after this change because it is
looking for the old expression; the result-set population reconciliation and
the focused validator are the acceptance checks for this semantic fix.

### High-volume line results

The before values are the v131 affected-population counts. The after values
are the current root-cause rerun counts; small ICE/IC increases reflect the
append-only observations noted above.

| LineName | StaticCoverageMissing before | StaticCoverageMissing after |
| --- | ---: | ---: |
| ICE | 667 | 672 |
| IC | 148 | 149 |
| RE 1 (RRX) | 432 | 0 |
| RE 5 (RRX) | 161 | 0 |
| RE 6 (RRX) | 141 | 0 |

The rerun's current affected-line candidate results were ICE 672
(299 no-candidate, 235 exactly-one, 138 multiple) and IC 149
(101 no-candidate, 29 exactly-one, 19 multiple). RE 1, RE 5, and RE 6 no
longer appear in the StaticCoverageMissing affected-line result. ICE and IC
were not force-matched without qualifying static route evidence.

### Remaining unresolved root causes and explicit non-goals

The post-remediation StaticCoverageMissing population remains expected and is
distributed by the rerun as 313 current route-name misses with no qualifying
fallback resolution, 442 with no matching loaded route or active schedule
evidence, 159 ambiguous schedule candidates, and 85 routes outside the current
Cologne-serving scope. The fix does not attempt to resolve:

- genuinely missing static routes;
- routes outside the current Cologne scope, including the proven 885 case;
- ambiguous static schedules;
- ICE or IC observations without qualifying Cologne-serving static route
  evidence;
- Timing Unavailable or any refreshed operational fact population.

No collector behavior, sampling configuration, tiered sampling, Power BI,
Actual Physical Delay, warehouse data, or `dw.uspRefreshFactOperationalStopOutcome`
execution was changed in this remediation.

## Changed files

This investigation adds only:

- sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql
- docs/28-STATIC-COVERAGE-MISSING-ROOT-CAUSE.md

The SQL is reusable and read-only: it uses SELECT statements, CTEs,
session-scoped temporary tables, and temporary indexes. No permanent DML,
permanent DDL, stored procedure, collector, warehouse, Power BI, sampling, or
timing change was made.
