# Power BI Data Validation

**Phase:** Chat 04 — Data Validation in Power BI  
**Status:** COMPLETE / PASS  
**Validated:** 2026-09-14

## 1. Objective

Validate the Power BI Import model against the SQL `analytics` layer **before** creating DAX measures or report visuals.

The validation intentionally separated three concerns:

1. **Import parity** — did Power BI import the same rows/KPIs as SQL?
2. **Filter propagation** — do the explicit relationships transmit filter context correctly without duplicate paths?
3. **Disconnected behavior** — do helper/multi-grain tables remain unaffected by unrelated GTFS service-date filters?

Realtime freshness was also checked independently from Power BI parity because two stale layers can otherwise agree with each other while still being behind the live source history.

## 2. Static Import Cardinality

Power BI and SQL reconciled exactly:

| Semantic table | SQL rows | Power BI rows | Result |
|---|---:|---:|---|
| `NetworkKPI` | 1 | 1 | PASS |
| `Mode` | 7 | 7 | PASS |
| `Route` | 153 | 153 | PASS |
| `StopPosition` | 2,290 | 2,290 | PASS |
| `ParentStation` | 866 | 866 | PASS |
| `ActiveDate` | 182 | 182 | PASS |
| `DailySchedule` | 20,059 | 20,059 | PASS |

**Conclusion:** no unexpected row filtering, loss, or duplication was introduced by Power Query / Import for the static layer.

## 3. Static Baseline KPI Reconciliation

The one-row `NetworkKPI` helper view matched SQL exactly for all validated baseline metrics:

| KPI | Validated value |
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

**Result:** PASS.

## 4. Static Relationship Validation

`Mode -> Route -> DailySchedule` was tested by comparing each mode's pre-aggregated `ScheduledTripOccurrenceCount` with the sum of `DailySchedule[ScheduledTripCount]` reached through the model relationship path.

All seven modes produced `Difference = 0`.

**Result:** `Mode -> Route -> DailySchedule Filter Propagation: PASS`.

`ActiveDate -> DailySchedule` was then validated at the date grain across all 182 active dates; SQL and Power BI counts matched.

**Result:** `ActiveDate -> DailySchedule Filter Propagation: PASS`.

## 5. Realtime Freshness Check

Before validating realtime Import parity, collection freshness and derived warehouse freshness were checked separately.

At the first check on 2026-09-14:

- the Collector audit showed a current successful run;
- raw realtime observations were current to 2026-09-14;
- `dw.FactOperationalStopOutcome` still reflected an older refresh from 2026-09-08.

This was **not** a Power BI model defect and did **not** require a SQL redesign. The existing idempotent procedure was run:

```sql
EXEC dw.uspRefreshFactOperationalStopOutcome;
```

No SQL object definition or Collector code was modified.

The refresh reported:

| Refresh metric | Value |
|---|---:|
| Source observations | 2,673 |
| Usable observations | 1,857 |
| Operational outcomes | 1,643 |
| Repeated observations consolidated | 214 |
| Inserted outcomes | 1,116 |
| Updated outcomes | 3 |
| Unchanged outcomes | 524 |

Power BI was then refreshed in Import mode.

### Why this mattered

A Power BI/SQL count comparison can pass even when both are stale. Checking collection freshness separately proves that the reporting layer is reconciled to the intended warehouse snapshot rather than merely self-consistent with an old snapshot.

## 6. Realtime Fact Import Parity

After the warehouse and Power BI refreshes, `analytics.vwRealtimeReliabilityOutcome` and `RT_ReliabilityOutcome` matched on:

- row count: **1,643**;
- maximum `RefreshedAtUtc`;
- minimum service date: **2026-09-05**;
- maximum service date: **2026-09-14**.

**Result:** `Realtime Reliability Fact Import Parity: PASS`.

No realtime outcomes were present for **2026-09-12** and **2026-09-13** in that snapshot. SQL and Power BI both showed the same absence, so this is recorded as a source/data-availability observation, not a semantic-model mismatch.

## 7. Realtime Relationship / Filter Propagation

The following relationship paths were reconciled against SQL and all passed:

| Relationship path | Validation grain | Result |
|---|---|---|
| `ActiveDate -> RT_ReliabilityOutcome` | service date | PASS |
| `Route -> RT_ReliabilityOutcome` | route | PASS |
| `StopPosition -> RT_ReliabilityOutcome` | stop position | PASS |
| `ParentStation -> StopPosition -> RT_ReliabilityOutcome` | parent station | PASS |
| `Mode -> Route -> RT_ReliabilityOutcome` | mode | PASS |
| `ActiveDate -> RT_ConsolidationQuality` | service date | PASS |

At the validated snapshot, realtime outcomes were represented across 46 routes and 48 stop positions. This is compatible with the current seven-location sampling design and must not be interpreted as full Köln network realtime coverage.

## 8. Consolidation Quality Reconciliation

`RT_ConsolidationQuality` matched SQL at the service-date grain.

Snapshot totals:

| Metric | Value |
|---|---:|
| Usable observations | 1,857 |
| Operational outcomes | 1,643 |
| Repeated observations consolidated | 214 |

The relationship `ActiveDate[DateKey] -> RT_ConsolidationQuality[DateKey]` therefore propagates service-date filters correctly.

**Result:** PASS.

## 9. Disconnected Tables

Four tables intentionally remain disconnected because their grains/semantics are not compatible with a conventional shared relationship path.

A filter on `ActiveDate[DateValue] = 2026-09-14` was applied inside DAX queries. The row count / baseline value remained unchanged for each table:

| Table | Validated behavior | Result |
|---|---|---|
| `RT_CollectorRunHealth` | 376 rows before and after ActiveDate filter | PASS |
| `RT_DataQualityCoverage` | 8 rows before and after ActiveDate filter | PASS |
| `RT_ReliabilityByDimension` | 128 rows before and after ActiveDate filter | PASS |
| `NetworkKPI` | 1 row before/after; RouteCount remained 153 | PASS |

This prevents GTFS service-date context from contaminating collector-run, coverage, multi-grain helper, or whole-network baseline semantics.

## 10. Validated Semantic Conclusions

Chat 04 provides evidence that the current semantic model is safe to use as the basis for the DAX measure layer:

- Import parity is proven for the tested static and realtime sources.
- Baseline KPI values reconcile exactly with SQL.
- The explicit single-direction relationship paths transmit filters as designed.
- Chained ParentStation filtering works without a direct ParentStation-to-fact relationship.
- No extra direct Mode-to-fact relationship is required; `Mode -> Route -> Fact` is sufficient.
- Disconnected helper tables behave as intentionally disconnected tables.
- Delay remains non-additive and should be exposed through explicit measures rather than implicit summation.
- No arbitrary On-Time threshold has been introduced.
- No confirmed `Actual Delay` / `Actual Arrival` terminology has been introduced.
- No unvalidated cancellation/departure KPI has been introduced.
- Situation evidence remains association, not causality.

## 11. Reusable Validation Assets

SQL-side queries:

```text
powerbi/validation/Chat04Validation.sql
```

DAX Query View checks:

```text
powerbi/validation/Chat04Validation.dax
```

The DAX file contains **queries**, not model measures.

## 12. Next Phase

**Chat 05 — DAX Measure Layer**.

Measures can now be implemented on top of the validated model. Realtime measures must continue to use the source-supported terminology and sampling limitations already documented in the project.
