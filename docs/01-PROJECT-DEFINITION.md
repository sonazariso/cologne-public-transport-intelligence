# Cologne Public Transport Intelligence

**Last updated:** 2026-09-04

## 1. Project Goal

The goal of this project is to build an end-to-end **Data Analytics and Business Intelligence solution for public transport in Cologne (Köln), Germany**.

The central analytical question is:

> **How reliable and efficient is Cologne's public transport network, where do delays and disruptions occur, what are their likely causes, and what improvements could have the greatest operational impact?**

The project demonstrates practical skills in:

- SQL Server and analytical SQL
- GTFS schedule modeling
- realtime public-transport integration
- ETL / ELT and data quality
- dimensional modeling
- schedule-to-realtime matching
- delay and disruption analysis
- root-cause evidence handling
- Power BI and KPI design
- technical documentation and portfolio communication

## 2. Geographic Scope

The primary analytical scope is **Cologne**. The static GTFS source is regional, but the working layer derives a Cologne-specific scope from stop/service evidence.

The current static municipality rule uses the global stop-ID prefix:

```text
de:05315:
```

The project does not attempt to analyze all NRW cities in its first version.

## 3. Transport Scope

The static baseline currently contains seven analytical categories:

1. Stadtbahn / Tram
2. S-Bahn
3. Regional Express (RE)
4. Regional Bahn (RB)
5. Urban Bus (KVB)
6. Regional / Other Bus
7. Rail Replacement Bus (SEV)

The realtime DELFI/TRIAS source may return services that are not represented in the current static Cologne GTFS scope. The validated example is **ICE**, which is classified as `StaticCoverageMissing` during schedule matching rather than as a failed match.

## 4. Current Data Sources

### Static schedule baseline

The primary schedule source is the VRS/go.Rheinland static GTFS feed. It supplies agencies, routes, trips, stops, stop times, calendars, calendar exceptions, shapes, transfers, and feed metadata.

### Realtime operational source

The currently validated realtime source is the **MDD NRW direct DELFI interface using TRIAS 1.2**:

```text
POST https://mdd.gorheinland.com/delfi
Content-Type: application/xml
Header: x-api-key
```

A successful authenticated `StopEventRequest` has been validated with realtime arrival estimates, line/journey references, stop-point references, bays/platforms, and situation context.

The current MDD NRW monthly request limit for the project is **250,000 requests**.

### Realtime compliance status

A confirmation email regarding realtime data storage/retention has been received. The exact wording and conditions are intentionally **not inferred** here; they will be transcribed into the documentation after the email text is supplied.

## 5. Current Implementation Status

The project is no longer static-only. The following have been implemented and validated:

- static GTFS staging, working layer, warehouse, analytics, and Power BI baseline;
- MDD/TRIAS authentication and request execution;
- parsing of realtime stop-event responses;
- arrival delay calculation;
- planned/estimated bay handling;
- situation/disruption extraction and linking;
- TRIAS stop enrichment with static GTFS stop hierarchy;
- UTC to Europe/Berlin normalization;
- GTFS service-day matching including times beyond 24:00;
- TRIAS-to-GTFS trip matching with explicit match quality;
- evidence/situation working view for later root-cause analysis.

## 6. Main Analytical Questions

### Network and supply

- How large is the scheduled Cologne network?
- Which modes, routes, stops, and stations carry the largest planned service volume?
- How does planned service vary by day and time?

### Reliability

After the realtime collector is operational at historical scale:

- What percentage of observed services are on time?
- What are average, median, and high-percentile delays?
- Which routes, stops, stations, and time periods are least reliable?
- How often do platform changes occur where the source explicitly reports them?

### Disruptions and likely causes

- Which delayed events have linked situation/disruption evidence?
- Which categories repeatedly overlap with delay hotspots?
- When is evidence insufficient to assign a likely cause?

The project must distinguish **evidence, association, likely contributing factor, and confirmed cause**.

## 7. Matching Quality Contract

Realtime-to-static matching uses these statuses:

```text
ExactStopMatch
ParentStationFallback
StaticCoverageMissing
Unresolved
```

`ExactStopMatch` and `ParentStationFallback` are considered usable static matches. `StaticCoverageMissing` means the realtime service is outside current static coverage. `Unresolved` means static coverage exists but the available evidence does not produce one defensible candidate.

## 8. Data Architecture

```text
Static GTFS                     MDD NRW / DELFI / TRIAS
    |                                     |
    v                                     v
source-faithful staging (`stg`) + realtime observation staging
                     |
                     v
             working layer (`wrk`)
      scope / normalization / matching
                     |
           +---------+---------+
           |                   |
           v                   v
   static warehouse (`dw`)   realtime evidence
           |                   |
           +---------+---------+
                     |
                     v
              analytics views
                     |
                     v
                  Power BI
                     |
                     v
problem -> evidence -> likely cause -> impact -> recommendation
```

## 9. Key Design Principles

- Static GTFS is the schedule baseline, not proof of actual operation.
- Realtime snapshots are observations, not separate trips.
- Source-faithful values belong in `stg`; derived logic belongs in `wrk`.
- TRIAS `JourneyRef` is not assumed equal to GTFS `TripId`.
- TRIAS `LineRef` is not assumed equal to GTFS `RouteId`.
- GTFS times above `24:00:00` preserve service-day meaning.
- Missing realtime bay data is not interpreted as “platform unchanged.”
- Ambiguous or uncovered records must not silently enter reliability KPIs.
- Correlation is not automatically causation.

## 10. Portfolio Deliverables

The repository should contain:

```text
docs/
sql/
collector/
powerbi/
images/
```

The documentation set is numbered so the project can be read in implementation order. The realtime implementation is documented in:

```text
09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md
```

## 11. Definition of Done

The project is complete when:

- static multimodal Cologne data is validated and modeled;
- realtime collection runs reliably under the approved usage terms;
- raw observations are consolidated into defensible dated operational outcomes;
- delay, cancellation, platform, disruption, and data-quality KPIs are documented;
- root-cause analysis clearly separates evidence from inference;
- Power BI tells a coherent management story;
- findings lead to evidence-based recommendations;
- another technical person can understand and reproduce the pipeline from repository documentation.

## 12. Non-Goals for the First Version

- all-NRW operational analytics;
- machine-learning delay prediction;
- passenger mobile application;
- realtime control-room software;
- route optimization;
- exhaustive integration of every transport API;
- undocumented causal claims.
