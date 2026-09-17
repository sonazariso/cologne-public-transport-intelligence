# Power BI Chat 18 — Final Data Refresh & Technical Validation

**Status:** PARTIAL — SQL validation completed; Power BI Desktop/DAX Query View evidence is still required.

**SQL snapshot:** 2026-09-16 18:43:28 UTC freshness check, immediately after the final aligned warehouse refresh completed at 18:39:53 UTC.

This handoff follows the Chat 18 validation scope. It does not redesign SQL, the Collector, the semantic model, relationships, DAX measures, Power Query, report pages, navigation, accessibility, or visual design. Chat 19 was not started.

## A. Refresh decision

**REFRESH REQUIRED.**

The first freshness check showed current raw observations through `2026-09-16 17:58:48 UTC`, while the operational fact stopped at `2026-09-14 11:13:51 UTC` and its latest refresh was `2026-09-14 11:14:56 UTC`. The live Collector continued while validation ran, so later freshness checks also showed the fact behind the source. No refresh was run merely to force parity.

The existing `dw.uspRefreshFactOperationalStopOutcome` procedure was used without modification. Final returned metrics:

| Metric | Value |
|---|---:|
| Refresh status | Succeeded |
| Refresh started / completed UTC | 2026-09-16 18:39:48 / 18:39:53 |
| Source observations | 4,425 |
| Usable observations | 3,262 |
| Source operational outcome grains | 2,980 |
| Operational outcomes | 2,980 |
| Repeated observations consolidated | 282 |
| Inserted outcomes | 10 |
| Updated outcomes | 0 |
| Unchanged outcomes | 2,970 |

The existing operational validation script’s repeatability test was also executed. At its captured repeatability boundary, both comparisons were `PASS` with 2,970 rows before/after and zero state differences. The later closing refresh incorporated newly arrived source grains.

## B. Collector snapshot

The current genuine source snapshot reported:

| Metric | Value |
|---|---:|
| Earliest raw observation UTC | 2026-09-05 08:27:28 |
| Latest raw observation UTC | 2026-09-16 18:38:42 |
| Stop observations | 4,425 |
| Snapshots | 886 |
| Distinct UTC collection dates | 10 |
| Inclusive calendar span | 12 days |
| Maximum snapshot gap | 213,085 seconds |
| Gaps over expected five-minute interval | 364 |
| Enabled sampling targets | 7 |
| Enabled targets with historical observations | 7 |
| Collector runs | 733 |
| Successful runs | 717 |
| Failed runs | 14 |
| Currently `Started` runs | 2 |
| Stale `Started` runs | 2 |
| Completed runs | 731 |
| Success rate | 98.08% |

The seven enabled targets remain a **Sampling Panel**, not full Cologne network coverage:

`Köln Heumarkt`, `Köln Hbf`, `Köln Rodenkirchen Bf`, `Köln Bf Ehrenfeld`, `Köln Worringen S-Bahn`, `Köln Porz Markt`, and `Köln Bf Mülheim`.

Failed-run categories were `Parse = 1`, `Persistence = 10`, and `Request = 3`. The two stale `Started` rows were CollectorRunIds `299` and `10611`; they remain open issues to investigate and were not relabeled or fabricated into failures.

Trusted multi-target realtime history begins at `2026-09-07 20:03:53 UTC`. The raw earliest date above includes preserved legacy Hbf-only history. The trusted multi-target span is approximately 8 days 22 hours 35 minutes at this snapshot.

The 14-day milestone at `2026-09-21 20:03:53 UTC` is **NOT YET COMPLETE**. The 28-day milestone at `2026-10-05 20:03:53 UTC` is **NOT YET COMPLETE**. No missing periods were backfilled or fabricated.

## C. SQL validation

### Operational fact

The existing `sql/04-warehouse/07-validate-operational-stop-outcome.sql` was run. The final targeted result contained 22 zero-violation checks, all `PASS`:

- no duplicate operational grain or surrogate key;
- positive observation counts and valid first/latest ordering;
- valid match statuses and all first/latest source lineage;
- valid Date, ScheduledStopEvent, Trip, Route, Stop, Mode, and Service keys;
- zero consolidation ordering violations;
- zero `SituationLinkCount` mismatches;
- zero Changed-platform evidence violations;
- zero Unchanged-platform evidence violations;
- zero Unknown-platform evidence violations;
- zero usable-match/fact grain differences.

Additional existing-script checks were `PASS`: latest static warehouse load completed, static warehouse row counts reconciled, nine fact foreign keys were trusted/enabled, and repeatability produced zero differences.

Final fact scope was `2026-09-05` through `2026-09-16`. Service dates `2026-09-12` and `2026-09-13` had no operational outcomes inside that range. This is recorded as a data-availability observation, not automatically a model defect.

### Realtime analytics

The existing `sql/05-analytics/04-validate-realtime-analytics-views.sql` was run. All required views were queryable and all visible validation checks were `PASS`.

| Analytics view | SQL row count |
|---|---:|
| `analytics.vwRealtimeCollectorRunHealth` | 733 |
| `analytics.vwRealtimeDataQualityCoverage` | 10 |
| `analytics.vwRealtimeOperationalConsolidationQuality` | 10 |
| `analytics.vwRealtimeReliabilityOutcome` | 2,980 |
| `analytics.vwRealtimeReliabilityByDimension` | 130 |
| `analytics.vwRealtimeDelayHotspot` | 93 |
| `analytics.vwRealtimePlatformChangeEvidence` | 753 |
| `analytics.vwRealtimeSituationLinkedOutcome` | 388 |

Coverage bounds, match-status accounting, fact/reliability parity, all six dimension types (`Overall`, `Date`, `Route`, `Stop`, `Mode`, `Hour`), platform labels, situation evidence, and the sampling-panel semantic note all passed. Overall SQL metrics were average observed estimated delay `8.98` minutes, median `3.00`, and P95 `36.00`; no approved on-time threshold is applied.

### Static analytics

The existing `sql/05-analytics/02-validate-static-analytics-views.sql` and targeted current-value checks returned `MATCH` for all static row counts, KPIs, mode values, and date coverage. The stable baseline is:

- 15 agencies, 7 modes, 153 routes;
- 866 parent stations, 2,290 stop positions, 2,287 used stop positions;
- 3,947 service patterns, 182 active service dates;
- 90,331 scheduled trip patterns, 1,878,944 scheduled trip occurrences;
- 1,551,343 scheduled stop-event patterns;
- active dates `2026-06-14` through `2026-12-12`.

## D. SQL row-count snapshot for imported semantic tables

This is the final SQL snapshot. Power BI values were not collected in this environment.

| Semantic table | SQL source view | SQL row count | Power BI | Difference | Result |
|---|---|---:|---:|---:|---|
| `NetworkKPI` | `analytics.vwNetworkBaselineKpi` | 1 | NOT RUN | N/A | PENDING |
| `Mode` | `analytics.vwModeScheduleProfile` | 7 | NOT RUN | N/A | PENDING |
| `Route` | `analytics.vwRouteScheduleProfile` | 153 | NOT RUN | N/A | PENDING |
| `ScheduledTripProfile` | `analytics.vwScheduledTripProfile` | 90,331 | NOT RUN | N/A | PENDING |
| `ActiveDate` | `analytics.vwActiveDateProfile` | 182 | NOT RUN | N/A | PENDING |
| `DailySchedule` | `analytics.vwDailyScheduledTripProfile` | 20,059 | NOT RUN | N/A | PENDING |
| `StopPosition` | `analytics.vwStopPositionScheduleProfile` | 2,290 | NOT RUN | N/A | PENDING |
| `ParentStation` | `analytics.vwParentStationScheduleProfile` | 866 | NOT RUN | N/A | PENDING |
| `RT_CollectorRunHealth` | `analytics.vwRealtimeCollectorRunHealth` | 733 | NOT RUN | N/A | PENDING |
| `RT_DataQualityCoverage` | `analytics.vwRealtimeDataQualityCoverage` | 10 | NOT RUN | N/A | PENDING |
| `RT_ConsolidationQuality` | `analytics.vwRealtimeOperationalConsolidationQuality` | 10 | NOT RUN | N/A | PENDING |
| `RT_ReliabilityOutcome` | `analytics.vwRealtimeReliabilityOutcome` | 2,980 | NOT RUN | N/A | PENDING |
| `RT_ReliabilityByDimension` | `analytics.vwRealtimeReliabilityByDimension` | 130 | NOT RUN | N/A | PENDING |

## E. SQL ↔ Power BI reconciliation still required

The Power BI side is intentionally marked `NOT RUN`; no value is inferred from PBIP source text.

### Static KPI SQL values

| KPI | SQL | Power BI | Result |
|---|---:|---:|---|
| AgencyCount | 15 | NOT RUN | PENDING |
| ModeCount | 7 | NOT RUN | PENDING |
| RouteCount | 153 | NOT RUN | PENDING |
| ParentStationCount | 866 | NOT RUN | PENDING |
| StopPositionCount | 2,290 | NOT RUN | PENDING |
| UsedStopPositionCount | 2,287 | NOT RUN | PENDING |
| ServicePatternCount | 3,947 | NOT RUN | PENDING |
| ActiveServiceDateCount | 182 | NOT RUN | PENDING |
| ScheduledTripPatternCount | 90,331 | NOT RUN | PENDING |
| ScheduledTripOccurrenceCount | 1,878,944 | NOT RUN | PENDING |
| ScheduledStopEventPatternCount | 1,551,343 | NOT RUN | PENDING |

### Realtime fact parity

| Value | SQL | Power BI | Result |
|---|---|---|---|
| Row count | 2,980 | NOT RUN | PENDING |
| Minimum ServiceDate | 2026-09-05 | NOT RUN | PENDING |
| Maximum ServiceDate | 2026-09-16 | NOT RUN | PENDING |
| Maximum RefreshedAtUtc | 2026-09-16 18:39:48 | NOT RUN | PENDING |

### SQL relationship grouping snapshot

The SQL side produced these grouping snapshots for comparison with the existing DAX queries in `powerbi/validation/Chat04Validation.dax`:

| Relationship test | SQL groups | SQL totals |
|---|---:|---|
| ActiveDate → DailySchedule | 182 | Scheduled trips = 1,878,944 |
| ActiveDate → RT_ReliabilityOutcome | 10 | Outcomes = 2,980 |
| Route → RT_ReliabilityOutcome | 46 | Outcomes = 2,980 |
| StopPosition → RT_ReliabilityOutcome | 48 | Outcomes = 2,980 |
| ParentStation → StopPosition → RT_ReliabilityOutcome | 7 | Outcomes = 2,980 |
| Mode → Route → RT_ReliabilityOutcome | 6 | Outcomes = 2,980 |
| ActiveDate → RT_ConsolidationQuality | 10 | Usable observations = 3,262; outcomes = 2,980; repeated consolidated = 282 |

The checked-in relationship topology contains the intended ActiveDate, Mode, Route, StopPosition, ParentStation, DailySchedule, RT_ReliabilityOutcome, and RT_ConsolidationQuality relationships. The intentionally disconnected-table behavior for `RT_CollectorRunHealth`, `RT_DataQualityCoverage`, `RT_ReliabilityByDimension`, and `NetworkKPI` is structurally preserved; DAX filter-behavior results remain pending.

## F. SQL-side KPI snapshot

These are direct SQL/analytics-view values, not claimed Power BI measure results:

| KPI group | Current SQL value |
|---|---|
| Scheduled Trips / Baseline Routes / Baseline Parent Stations | 1,878,944 / 153 / 866 |
| Observed Matched Services | 2,980 |
| Average / Median / P95 Observed Estimated Delay | 8.98 / 3.00 / 36.00 minutes |
| Usable Matches / Rate | 3,262 / 73.72% |
| Exact Stop Match Rate | 71.82% |
| Parent Station Fallback Rate | 1.90% |
| Static Coverage Missing Rate | 25.08% |
| Unresolved Match Rate | 1.20% |
| Collector Runs / Successful / Failed | 733 / 717 / 14 |
| Collector Success Rate | 98.08% |
| Sampling Panel Targets Observed | 7 |
| Situation-Linked Outcomes / Share | 388 / 13.02% |
| Platform Changed Outcomes / Share | 18 / 0.60% |
| Platform Unchanged Outcomes / Share | 0 / 0.00% |
| Platform Unknown Outcomes / Share | 2,962 / 99.40% |

## G. Power BI Desktop refresh and exact remaining validation steps

Power BI Desktop, Import Refresh, DAX Query View, and report rendering were not available in this macOS execution environment. Therefore:

1. Open `powerbi/CologneTransitIntelligence.pbip` in Power BI Desktop.
2. Run **Home → Refresh** and wait for the complete Import refresh.
3. Confirm no query-refresh error, model-load error, or PBIR warning; save the PBIP.
4. Run the existing blocks in `powerbi/validation/Chat04Validation.dax`.
5. Add/run this DAX row-count block:

```DAX
EVALUATE
UNION (
    ROW ( "TableName", "RT_CollectorRunHealth", "PowerBIRowCount", COUNTROWS ( 'RT_CollectorRunHealth' ) ),
    ROW ( "TableName", "RT_DataQualityCoverage", "PowerBIRowCount", COUNTROWS ( 'RT_DataQualityCoverage' ) ),
    ROW ( "TableName", "RT_ConsolidationQuality", "PowerBIRowCount", COUNTROWS ( 'RT_ConsolidationQuality' ) ),
    ROW ( "TableName", "RT_ReliabilityOutcome", "PowerBIRowCount", COUNTROWS ( 'RT_ReliabilityOutcome' ) ),
    ROW ( "TableName", "RT_ReliabilityByDimension", "PowerBIRowCount", COUNTROWS ( 'RT_ReliabilityByDimension' ) )
)
ORDER BY [TableName]
```

6. Run the existing DAX static KPI, realtime parity, relationship, and disconnected-table blocks. Every SQL/DAX difference must be zero where a value is comparable.
7. Capture the major measure values from the existing measures only, including the delay, data-quality, Collector, and evidence measures.
8. Smoke-test pages 01–08: page opening, visual rendering, navigation, no blank/error visuals, Page 07 loadability, Methodology readability, and preserved Chat 17 Alt Text/tab order.

## H. Semantic guardrails

**SQL/definition layer: PASS. Desktop measure/render confirmation: PENDING.**

- Observed Estimated Delay remains distinct from Actual Delay.
- No arbitrary On-Time threshold or invented OnTimeRate is present.
- Situation Evidence remains evidence, not causality.
- Platform Unknown remains distinct from Platform Unchanged.
- StaticCoverageMissing and Unresolved remain data-quality states.
- No cancellation or departure KPI was invented.
- Seven realtime locations remain a Sampling Panel.
- Repeated observations are consolidated, not treated as separate services.
- Realtime scope remains arrival-estimate evidence only.

## I. PBIR and Git state

The structural audit parsed 132 Power BI JSON files with zero JSON parse errors. The preserved Page 07 repairs remain structurally present: `707c` has no query `sortDefinition`, and `707h`/`707i` have no `prototypeQuery` or `dataTransforms`.

The preflight worktree was clean. During the run, 78 current Power BI report files appeared modified with Desktop-style canonicalization/content changes; they were not reverted or rewritten by Chat 18. No SQL, Collector, semantic-model relationship, or measure-definition file was changed by this task. Temporary SQL probe files and the temporary client handshake edit were removed/restored.

There is no Git commit for Chat 18. Current status is **not clean** because those 78 Power BI files remain modified and the handoff document is new. Review and commit them only after the Desktop refresh/save and smoke-test results are available. No PBIX backup, cache, or local-settings noise was added by this task.

## J. Final handoff

**Power BI Chat 18 — Final Data Refresh & Technical Validation**

- **Status:** PARTIAL
- **Warehouse refresh:** REQUIRED — final existing-procedure refresh succeeded.
- **Collector health:** genuine 12-calendar-day raw span; seven-target Sampling Panel; 14 failed and 2 stale Started runs remain open issues.
- **14-day milestone:** NOT YET COMPLETE.
- **28-day milestone:** NOT YET COMPLETE.
- **SQL validations:** PASS for operational fact, static analytics, realtime analytics, static-load compatibility, fact foreign keys, and captured repeatability checks.
- **SQL ↔ Power BI reconciliation:** PENDING Power BI Desktop Import refresh and DAX Query View output.
- **Relationship validation:** SQL grouping snapshots PASS/queryable; DAX propagation comparison PENDING.
- **Disconnected tables:** checked-in topology preserved; DAX behavior PENDING.
- **Final KPI snapshot:** SQL values recorded in Section F; Power BI measure values PENDING.
- **Power BI refresh:** NOT RUN in this environment.
- **Report smoke test:** NOT RUN in this environment.
- **Semantic guardrails:** PASS at SQL/definition layer; Desktop confirmation PENDING.
- **Open issues:** Power BI Desktop/DAX evidence, page smoke test, Collector failed/stale-run follow-up, and the 14/28-day history milestones.
- **Files changed intentionally:** this handoff document only; 78 current Power BI modifications were preserved and not reverted.
- **Git commit:** none.
- **Git status:** not clean; see Section I.

**Power BI Chat 18 — Final Data Refresh & Technical Validation is not COMPLETE/CLOSED. It remains PARTIAL and requires the listed Power BI Desktop/DAX validation before closure.**
