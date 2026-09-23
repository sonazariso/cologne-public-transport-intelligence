# StaticCoverageMissing Root-Cause Investigation

Status: DIAGNOSTIC COMPLETE; REMEDIATION VALIDATED

This document records the read-only investigation requested by
prompts/05-OptimSql/o4-7.md. Instructions in that prompt were treated as the
analysis specification; that original investigation did not authorize a
production matching change. The separate remediation and validation sections
below record the subsequent v132 work.

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

## Original v131 root-cause investigation

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

The v131 investigation diagnosed the RouteShortName-only defect. The v132
remediation changed the production matching view, and the focused frozen-scope
validator below measures that semantic change independently of the later
append-only live population.

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
| v132 probe validation rerun | 2026-09-23 10:11:16.1611203 UTC; current status reconciliation `PASS` over 7,737 rows |
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

## Post-remediation validation

The focused validator is the authoritative causal measurement of the v132
matching change. The later root-cause rerun is a separate live snapshot over
an append-only observation population.

### Frozen-scope status migration and validation

The focused validator froze 7,697 observation keys for both implementations.
The v131 short-name-only baseline and the deployed implementation reconciled as
follows:

The primary remediation metric is the frozen-scope comparison, not the
cross-time live snapshot below:

| Frozen-scope metric | Count / rate |
| --- | ---: |
| Legacy short-name-only `StaticCoverageMissing` | 1,742 |
| New validated `StaticCoverageMissing` | 999 |
| Frozen-scope reduction | 743 |
| Frozen-scope reduction rate | 42.652124% |

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

### RouteName consistency check

The fallback-selected `RouteKey` is the existing warehouse `RouteKey` from
`FactScheduledStopEvent`; the analytics `RouteLabels` logic consumes that same
key from `dw.DimRoute`, so no identifier remapping is introduced. The current
analytics rule uses populated `RouteShortName`, then `RouteLongName` when the
short name is empty, and `RouteId` only as the final fallback. Accordingly, the
validated fallback RouteKeys resolve to the canonical analytics names `RE1
(RRX)`, `RE5 (RRX)`, and `RE6 (RRX)` for the corresponding fallback RouteIds
`de:nrw:re1:`, `de:nrw:re5:`, and `de:nrw:re6:`. No RouteName logic or analytics
view was changed.

### Root-cause rerun results

The required root-cause script was rerun after deployment. Its status
reconciliation was `PASS` and it completed with no SQL errors. The table below
preserves the earlier 09:36 UTC live snapshot used for the remediation impact
record. The later 10:11 UTC validation-only rerun also returned `PASS`, with
7,737 current observations: 6,499 exact, 143 parent-station, 1,005
`StaticCoverageMissing`, and 90 unresolved. Because the realtime source is
append-only, these live populations are not expected to equal the frozen 7,697
observations.

| Metric | v131 live diagnostic snapshot | Recorded post-remediation live snapshot |
| --- | ---: | ---: |
| Total observations | 7,622 | 7,702 |
| ExactStopMatch | 5,693 | 6,470 |
| ParentStationFallback | 121 | 143 |
| StaticCoverageMissing | 1,727 | 999 |
| StaticCoverageMissing rate | 22.658095% | 12.970657% |
| Unresolved | 81 | 90 |

This separate cross-time live snapshot comparison shows a reduction of 728
observations, or 42.154024%; it is not the exact causal measurement of the
matching change. The frozen validator above is the primary remediation metric:
1,742 legacy frozen `StaticCoverageMissing` observations became 999, a
743-observation / 42.652124% reduction.

### High-volume line results

The before values are the v131 live affected-population counts. The after
values are the later live root-cause rerun counts; this is a cross-time view,
not the frozen causal measurement. Small ICE/IC increases reflect the
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

### Original diagnostic investigation

- sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql
- docs/28-STATIC-COVERAGE-MISSING-ROOT-CAUSE.md

### Production remediation

- sql/03-working/03-create-cologne-realtime-working-layer.sql
- sql/03-working/05-validate-static-coverage-route-long-fallback.sql
- docs/28-STATIC-COVERAGE-MISSING-ROOT-CAUSE.md

The original diagnostic SQL remains reusable and read-only: it uses SELECT
statements, CTEs, session-scoped temporary tables, and temporary indexes. The
remediation changed the working-layer matching view as documented above; no
collector, warehouse data/procedure, Power BI, sampling, or timing behavior
was changed.

## v133 analytical transport-scope correction

Status: VALIDATED

This additive section records the follow-up requested in
`prompts/05-OptimSql/o4-10.md`. The historical v131 investigation and v132
RouteLongName remediation above are preserved unchanged. This correction
separates technical static coverage from the defined seven-category Cologne
analytical transport scope; it does not invent long-distance train matches.

### Execution record

| Field | Value |
| --- | --- |
| Branch | `fix/realtime-analytical-transport-scope` |
| Requested baseline | v133 |
| Development database | `CologneTransitIntelligence` |
| Working-layer deployment | `sql/03-working/03-create-cologne-realtime-working-layer.sql` completed successfully |
| Analytics deployment | `sql/05-analytics/03-create-realtime-analytics-views.sql` completed successfully |
| Read-only validator | `sql/03-working/06-validate-realtime-analytical-transport-scope.sql` |
| Root-cause diagnostic | `sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql` completed with no SQL errors |
| Fact refresh | Not executed |

### Scope rule

The technical view `wrk.vwCologneRealtimeTripMatch` remains the source of
`MatchStatus` and all matching keys. The new
`wrk.vwCologneRealtimeTripMatchScoped` wrapper sets
`IsInAnalyticalTransportScope = 0` only when all of the following are true:

1. `PtMode = RAIL`;
2. the normalized label is not a regional/suburban `S`/`RE`/`RB` service;
3. `LineRef` is present; and
4. there is either a proven long-distance label (`ICE`, `IC`, `FLIXTRAIN`,
   `NJ`, or `THA`) or a long-distance rail submode
   (`HIGH_SPEED_RAIL`, `INTERNATIONAL`, or `INTERREGIONAL_RAIL`) together with
   a non-empty `OperatorRef`.

`RailSubmode` is not used alone. BUS, TRAM, and SEV/BSV replacement-bus rows
remain in scope, and unknown combinations default to in scope for review.
Origin or destination is not used as an exclusion rule. Technical `MatchStatus`
remains unchanged and is not the scope predicate. Raw observations stay in
staging and remain traceable; only the analytical KPI denominator uses the
scope flag.

### Validator snapshot and valid-service evidence

The detailed row-level validator snapshot used for the service-class and
scope-metric tables contained 7,812 raw observations. Raw, technical-match, and
scoped-match row counts were all 7,812; the scope split was 6,972 in scope plus
840 out of scope. The duplicate-ObservationKey result was empty. All three
row/status reconciliation checks returned `PASS`. A later post-hardening
validator run saw 7,827 rows, with the same PASS results; the source is
append-only, so live totals can advance between result sets.

| Current service class | Observations | Out of scope | Result |
| --- | ---: | ---: | --- |
| Defined non-rail modes (BUS/TRAM) | 4,250 | 0 | PASS |
| Rail Replacement Bus (SEV/BSV labels) | 56 | 0 | PASS |
| Regional Bahn (RB) | 492 | 0 | PASS |
| Regional Express (RE) | 1,147 | 0 | PASS |
| S-Bahn | 1,083 | 0 | PASS |

Existing successful matching identity was unchanged in the detailed snapshot:
6,707 technical `ExactStopMatch`/`ParentStationFallback` rows, 6,707 in-scope
successful rows, zero out-of-scope successful rows, and zero differences in
either direction across the full matching identity comparison. The later
post-hardening run reported 6,720/6,720/0 with the same zero-difference result.
Both validators returned `PASS`.

### Excluded long-distance population

The detailed validator excluded 840 observations. All are technical
`StaticCoverageMissing` rail rows. The complete line/ref-level result is
emitted by validator result set 6; the class roll-up is:

| Service class | Observations | Distinct LineRefs | Distinct StopPoints | Distinct Parents |
| --- | ---: | ---: | ---: | ---: |
| ICE (including `ICE 126 ICE International` and `ICE 29 InterCityExpress`) | 688 | 28 | 8 | 2 |
| IC | 149 | 5 | 5 | 2 |
| FlixTrain | 1 | 1 | 1 | 1 |
| NJ 403 NightJet | 1 | 1 | 1 | 1 |
| THA 9471 Thalys | 1 | 1 | 1 | 1 |

No EC, Eurostar, or other additional long-distance class occurred in this
current excluded snapshot. The rule is evidence-based and is not a closed
hardcoded list of today's labels: an unproven rail combination remains in
scope for review.

### Parent-station distribution

Physical stop points were rolled up through the static stop hierarchy:

| Service class | ParentStationId | ParentStationName | Observations | Distinct StopPoints |
| --- | --- | --- | ---: | ---: |
| ICE | `de:05315:11201` | Köln Hbf | 687 | 7 |
| ICE | `de:05315:14201` | Köln Bf Ehrenfeld | 1 | 1 |
| IC | `de:05315:11201` | Köln Hbf | 148 | 4 |
| IC | `de:05315:14201` | Köln Bf Ehrenfeld | 1 | 1 |
| FlixTrain | `de:05315:11201` | Köln Hbf | 1 | 1 |
| NJ 403 NightJet | `de:05315:11201` | Köln Hbf | 1 | 1 |
| THA 9471 Thalys | `de:05315:11201` | Köln Hbf | 1 | 1 |

No excluded observation in this snapshot rolled up to Köln Messe/Deutz or
Köln/Bonn Flughafen.

### Analytical quality results

The raw technical count remains non-zero by design; the business KPI is the
in-scope rate. The two observed append-only snapshots were:

| Metric | Detailed validator snapshot | Latest post-hardening validator |
| --- | ---: | ---: |
| RawRealtimeObservationCount | 7,812 | 7,827 |
| OutOfAnalyticalTransportScopeObservationCount | 840 | 841 |
| InAnalyticalTransportScopeObservationCount | 6,972 | 6,986 |
| RawTechnicalStaticCoverageMissingCount | 1,015 | 1,017 |
| OutOfScopeStaticCoverageMissingCount | 840 | 841 |
| InScopeStaticCoverageMissingCount | 175 | 176 |
| InScopeStaticCoverageMissingRate | 2.510000% | 2.519324% |
| InScopeUnresolvedCount | 90 | 90 |
| InScopeExactStopMatchCount | 6,563 | 6,575 |
| InScopeParentStationFallbackCount | 144 | 145 |
| InScopeUsableMatchCount | 6,707 | 6,720 |
| InScopeUsableMatchRate | 96.127300% | 96.192385% |

The deployed `analytics.vwRealtimeDataQualityCoverage` exposes the same raw,
out-of-scope, in-scope, status-count, and in-scope-rate fields. Its smoke check
reconciled the source and match grains; append-only totals are expected to move.

### RouteLongName fallback regression

The existing RouteShortName-primary / RouteLongName-fallback architecture was
not changed. The validator found all current RRX examples in scope and with
zero scope conflicts:

| LineName | Observations | Successful | RouteLongName fallback successful | Scope status |
| --- | ---: | ---: | ---: | --- |
| RE 1 (RRX) | 440 | 431 | 431 | PASS |
| RE 5 (RRX) | 162 | 162 | 162 | PASS |
| RE 6 (RRX) | 143 | 143 | 143 | PASS |
| RE1 (RRX) | 1 | 1 | 1 | PASS |
| RE5 (RRX) | 1 | 1 | 1 | PASS |
| RE6 (RRX) | 1 | 1 | 1 | PASS |

### Remaining in-scope StaticCoverageMissing worklist

The root-cause diagnostic's detailed in-scope worklist contained 175
`StaticCoverageMissing` observations. Every row below is a BUS/SEV residual;
`RailSubmode` is NULL. Counts are from the same append-only diagnostic
snapshot and are grouped by the existing root-cause classification. The later
validator snapshot contains one additional in-scope residual row; rerunning the
diagnostic is intentionally a separate append-only snapshot operation.

| LineName | Observations | StopPoints | Parents | PtMode | RailSubmode | Existing root cause |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 188 | 10 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| 188 | 17 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| 885 | 87 | 3 | 1 | BUS | — | StaticRouteExistsButOutsideCurrentCologneScope |
| 885E | 4 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| 885E | 1 | 1 | 1 | BUS | — | StaticScheduleCandidateAmbiguous |
| BSV 11008 8211008 | 1 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| SEV | 2 | 1 | 0 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV RB38 | 2 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV RE 1 | 2 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV RE6X | 1 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV RE8 | 1 | 1 | 0 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV S 11 | 6 | 2 | 2 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| SEV S 11 | 5 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV S 19 | 1 | 1 | 1 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV S 6 | 20 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| SEV S 6X | 5 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| SEV S11 | 1 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |
| SEV S11 | 3 | 2 | 2 | BUS | — | NoMatchingRouteInLoadedStaticFeed |
| SEV S6 | 6 | 1 | 1 | BUS | — | CurrentRouteNameRuleMissesDeterministicStaticRoute |

No additional matching fallback was added for this residual worklist.

### Scope correction non-goals

This change did not analyze or modify Timing Unavailable, refresh
`dw.FactOperationalStopOutcome`, change collector parsing/persistence, change
sampling or tiered scheduling, activate the 50-station panel, change Power BI,
implement Actual Physical Delay, or delete raw observations. Those remain
separate tasks.

### v133 changed files

- `sql/03-working/03-create-cologne-realtime-working-layer.sql`
- `sql/03-working/06-validate-realtime-analytical-transport-scope.sql`
- `sql/05-analytics/03-create-realtime-analytics-views.sql`
- `sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql`
- `docs/01-PROJECT-DEFINITION.md`
- `docs/03-COLOGNE-SCOPE-AND-MODE-CLASSIFICATION.md`
- `docs/28-STATIC-COVERAGE-MISSING-ROOT-CAUSE.md`

## Residual in-scope StaticCoverageMissing resolution

Status: DIAGNOSTICALLY COMPLETE; DETERMINISTIC SEV FIX IMPLEMENTED

This section records the v135 residual task from
`prompts/05-OptimSql/o4-11.md`. The prompt was treated as the task
specification; it was not treated as a request to change unrelated collector,
warehouse, scope, timing, sampling, or reporting behavior.

### Frozen baseline

The task-start freeze was captured on 2026-09-23 at approximately 14:06 CEST
(the database run emitted `2026-09-23T14:06:16.111995+02:00`). The frozen
observed-at range was 2026-09-07 21:03:48 through 2026-09-23 11:53:50 UTC.

| Metric | Frozen value |
| --- | ---: |
| Frozen in-scope StaticCoverageMissing observations | 177 |
| Distinct LineName values | 15 |
| Distinct LineRef values | 16 |
| Distinct StopPointRef values | 12 |
| Distinct analytical parents | 4 |
| Null LineName / LineRef / JourneyRef / DirectionRef / OperatorRef / PtMode / TimetabledArrivalUtc | 0 |
| Null EstimatedArrivalUtc | 82 |
| Null RailSubmode | 177 |

The complete frozen labels were `885`, `188`, `885E`, the observed SEV
variants, and `BSV 11008 8211008`. The production change did not hardcode the
177-row value; the validator freezes `ObservationKey` values at execution
time.

### Evidence conclusions

#### Line 885

The 87 realtime rows use two BVR LineRefs (`bvr:88885::H` and
`bvr:88885::R`), 31 JourneyRefs, one operator reference (`bvr:88`), and three
Cologne stop-point labels under parent `de:05315:16601`. The realtime stop
namespace is genuinely Cologne evidence; one observed point was not present
in the loaded static stop lookup, but it was still a Cologne namespace value.

The only loaded exact short-name route was `de:vrs:885:111`, operated by RVK
(agency 13), with seven trips and 46 stop-time rows, none serving a Cologne
stop. No exact equality proved `LineRef = RouteId`, `OperatorRef = AgencyId`,
or `JourneyRef = TripId`.

Conclusion: `DifferentRouteIdentityDespiteSameLineName`. This is not proof
that the realtime service is outside Cologne. The 87 rows remain in scope and
are treated as a static-feed coverage gap/identity contradiction, not excluded
by a line-name rule.

#### Line 188

All 28 rows use `vrs:01188:B:R`, operator `vrs:`, direction `inward`, and the
Cologne stop `de:05315:17311:2:22` under `de:05315:17311`. No loaded route has
short name, long name, or route identity `188`. Ten rows have one
route-independent parent-station schedule candidate on route `154`; the other
18 have no candidate. The candidate is a coincidental route-154 parent match,
not proof that the realtime 188 service is route 154.

Conclusion: `GenuineStaticFeedCoverageGap`. No 188 production match was
added.

#### Line 885E

The five rows use `bvr:88889::H` and the Cologne Worringen stop
`de:05315:16601:2:21`. No loaded static route proves that the `E` suffix is an
express-equivalence or source-label decoration. One row has two parent-station
schedule candidates (S6 and 980), and four have no candidate.

Conclusion: `AmbiguousStaticCandidate` for one row and
`GenuineStaticFeedCoverageGap` for four rows. The `E` suffix was not stripped.

#### SEV and BSV residuals

The tested diagnostic normalization removes only a leading `SEV` token and
spaces, then matches the resulting label only to a Cologne-serving static
route classified as `Replacement Service / Rail Replacement Bus (SEV)`.
`BSV` was not normalized. The successful-population conflict check returned
zero conflicts.

| Realtime label | Frozen rows | Unique exact recoveries | Remain unresolved because no unique active event | Remain static-gap evidence |
| --- | ---: | ---: | ---: | ---: |
| `SEV S 6` | 21 | 21 | 0 | 0 |
| `SEV S6` | 6 | 6 | 0 | 0 |
| `SEV S 6X` | 5 | 5 | 0 | 0 |
| `SEV S 11` | 11 | 6 | 5 | 0 |
| `SEV S11` | 4 | 1 | 3 | 0 |
| `SEV RB38` | 2 | 0 | 2 | 0 |
| `SEV RE8` | 1 | 0 | 1 | 0 |
| `SEV S 19` | 1 | 0 | 1 | 0 |
| `SEV` | 2 | 0 | 0 | 2 |
| `SEV RE 1` | 2 | 0 | 0 | 2 |
| `SEV RE6X` | 1 | 0 | 0 | 1 |
| `BSV 11008 8211008` | 1 | 0 | 0 | 1 |
| **Total** | **57** | **39** | **12** | **6** |

The 39 recoveries are all exact-stop matches: 21 on static `S6` replacement
route `de:nrw:s6:4`, six on the same replacement route, five on replacement
`S6X` route `de:nrw:s6:3`, six on replacement `S11` route `de:nrw:s11:4`, and
one more `S11` variant on that same replacement route. The 12 unresolved rows
have replacement-route coverage but no unique active date/time/stop event.
The six remaining static-gap labels have no proven route identity under the
tested normalization.

### Deterministic production correction

`sql/03-working/03-create-cologne-realtime-working-layer.sql` now adds one
production candidate path, `SEVReplacementRoute`. It is eligible only when:

1. the realtime label begins with `SEV`;
2. the prefix-stripped, space-normalized suffix matches a curated
   Cologne-serving replacement route short name;
3. the ordinary RouteShortName and RouteLongName paths do not cover the
   original label; and
4. active service date, scheduled time, exact stop or validated parent, and
   unique-candidate rules select the event.

No fuzzy matching, schedule-only matching, manual ObservationKey mapping,
`BSV` stripping, `885E` stripping, or scope exclusion was added. The existing
RouteShortName-primary / RouteLongName-fallback branches and the analytical
scope wrapper were preserved.

### Frozen before/after result

The required validator is
`sql/03-working/07-validate-residual-in-scope-static-coverage.sql`. Its
frozen semantic migration is:

| Before status | After status | Frozen rows |
| --- | --- | ---: |
| StaticCoverageMissing | ExactStopMatch | 39 |
| StaticCoverageMissing | ParentStationFallback | 0 |
| StaticCoverageMissing | Unresolved | 12 |
| StaticCoverageMissing | StaticCoverageMissing | 126 |

No frozen residual row was proven or changed to out of scope. The final root
cause distribution across the 177 frozen rows is:

| Final category | Rows | Meaning |
| --- | ---: | --- |
| SafelyRecoveredExactStopMatch | 39 | Deterministic SEV replacement route/event match |
| StaticCoverageExistsButNoUniqueActiveEvent | 12 | Replacement route is proven, but no unique active event exists |
| StaticRouteOutsideCologneButRealtimeIdentityContradictory | 87 | 885 same-name static route is not proven to be the realtime service |
| GenuineStaticFeedCoverageGap | 32 | 28 rows for 188 and four rows for 885E |
| AmbiguousStaticCandidate | 1 | One 885E parent-station collision |
| InsufficientEvidence_ExternalStaticFeedIdentityRequired | 6 | Bare/unsupported SEV/BSV identities |
| **Total** | **177** | **Fully assigned** |

Therefore the frozen final in-scope `StaticCoverageMissing` count is 126.
At the frozen baseline in-scope denominator of 7,036, this is 1.790790%.
A later append-only live snapshot after the change contained 129 residual rows
out of 7,059 in-scope rows (1.827454%); that moving snapshot is reported only
as operational context, not as the before/after semantic comparison.

The direct `GenuineStaticFeedCoverageGap` count is 32. Including the separate
885 identity contradiction, 119 rows remain explained by missing or
contradictory static-feed coverage; one is ambiguous, 12 are unresolved due to
missing active events on a proven replacement route, and six require an
external static source/identity correction. Proven out-of-scope count: zero.

### Regression results

The frozen pre-existing successful population contained 6,768 in-scope
`ExactStopMatch`/`ParentStationFallback` rows. The full identity comparison
for `ObservationKey`, status, matched trip/route/service/stop, scheduled
event, trip/route/stop/mode/service/date keys, and service date returned zero
differences, zero missing observations, and zero duplicate keys.

The long-distance scope correction remained unchanged. The validation
snapshot retained all ICE, IC, FlixTrain, NightJet, and Thalys observations
out of scope, while BUS/TRAM, RB, RE, S-Bahn, and SEV/BSV remained in scope.
The live post-change scope counts were: ICE 692, IC 151, FlixTrain 1,
NightJet 1, Thalys 1 out of scope; BUS 2,590, TRAM 1,663, RE 1,155, RB 498,
S-Bahn 1,096, and SEV/BSV 57 in scope. These are append-only snapshot counts,
not hardcoded scope rules.

### Completion and non-goals

The residual `StaticCoverageMissing` investigation is fully explained for
the frozen population: every row is safely recovered, correctly unresolved,
ambiguous, a proven static-feed gap/identity contradiction, or explicitly
awaiting external static-feed identity evidence. The 126 remaining technical
`StaticCoverageMissing` rows are intentional outcomes of that classification,
not unexplained leftovers.

Files changed for this task:

- `sql/03-working/03-create-cologne-realtime-working-layer.sql`
- `sql/03-working/07-validate-residual-in-scope-static-coverage.sql`
- `sql/05-analytics/08-analyze-static-coverage-missing-root-cause.sql`
- `docs/28-STATIC-COVERAGE-MISSING-ROOT-CAUSE.md`

No Timing Unavailable population, collector behavior, warehouse table or
procedure, operational fact refresh, Power BI logic, sampling configuration,
tiered-sampling implementation, or Actual Physical Delay behavior was
changed. `dw.FactOperationalStopOutcome` was not refreshed, and no raw
observations were deleted.
