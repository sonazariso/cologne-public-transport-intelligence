# Realtime Tiered Sampling Architecture

Status: DESIGN ONLY — NOT ACTIVE

Roadmap scope: future tiered realtime sampling dispatcher

Repository baseline: v126 / Roadmap Items 1–3 complete

This document defines the future runtime architecture for the approved
50-station realtime-monitoring panel. It does not activate that panel and does
not change the current seven-target Collector configuration.

## Scope and non-goals

The design replaces the conceptual one-target-per-heartbeat rotation with a
five-minute dispatcher that can execute every target due in the current logical
UTC bucket. It preserves target-level collection, persistence, and audit
semantics.

This document does not implement the dispatcher, a new scheduler, a claim
table, a lease, a unique constraint, a stored procedure, a Collector code
change, a sampling configuration change, a Windows Task Scheduler change, a
health-query change, an analytics change, or a Power BI change. The active
seven-target / ten-slot configuration remains the production configuration
until a later controlled rollout.

## 1. Current architecture

The source and repository documentation describe the current runtime as:

```text
Windows Task Scheduler
        |
        | every 5 minutes
        v
Run-MddRealtimeCollector.ps1
        |
        v
Invoke-MddRealtimeCollector.ps1
        |
        v
Invoke-MddRealtimeCollector
        |
        +--> ctl.uspGetMddRealtimeSamplingTarget(@AtUtc)
        |       |
        |       +--> floor UTC time to a five-minute bucket
        |       +--> enumerate enabled MddRealtimeSamplingSlot rows
        |       +--> select exactly one slot/target
        |
        +--> build one TRIAS request
        +--> bounded transient HTTP retry, when applicable
        +--> parse response
        +--> persist one snapshot atomically
        +--> complete one ctl.MddCollectorRun row
```

The current implementation audit found the following:

| Concern | Current behavior | Source evidence |
| --- | --- | --- |
| Windows heartbeat | The deployed Task Scheduler task is documented and evidenced at a five-minute cadence. The repository wrapper handles one scheduled invocation; current history reports no overlap, but the wrapper is not the future duplicate guard. | `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:359-382`; `collector/Run-MddRealtimeCollector.ps1:3-18` |
| Automatic target count | One automatic Collector invocation calls the sampling procedure once; the procedure returns `TOP (1)` enabled slot/target for the logical bucket. | `collector/MddRealtimeCollector.psm1:1365-1382`; `sql/02-staging/07-create-mdd-realtime-sampling.sql:70-136` |
| Scheduling basis | Selection is based on the UTC five-minute bucket and the enabled `ctl.MddRealtimeSamplingSlot` rotation. The ten slots form the current 50-minute cycle. | `sql/02-staging/07-create-mdd-realtime-sampling.sql:97-135`; `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:384-428` |
| Active configuration | The current active configuration remains seven enabled targets and ten slots. It is not the approved future 50-station panel. | `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:55-71, 384-428`; `docs/25-REALTIME-50-STATION-MDD-COMPATIBILITY.md:72-99` |
| Explicit StopPointRef | Supplying `-StopPointRef` is treated as a manual single-target override. It bypasses automatic sampling selection and sets `SamplingMode = Manual`. | `collector/MddRealtimeCollector.psm1:1310-1318, 1365-1385`; `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:386-392` |
| Automatic mode | With no explicit StopPointRef, the Collector sets `SamplingMode = Automatic`, resolves one database target, and uses that target's stored `NumberOfResults` unless the invocation explicitly overrides it. | `collector/MddRealtimeCollector.psm1:1313-1317, 1365-1382` |
| TRIAS request grain | One automatic execution performs one logical TRIAS request. A logical request can contain multiple HTTP attempts when the existing transient retry policy applies. | `collector/MddRealtimeCollector.psm1:1390-1405`; `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:305-321` |
| Retry policy | The current defaults are a 30-second HTTP timeout, up to three attempts, exponential 2/4-second backoff capped at 30 seconds, and retries for transient HTTP/transport failures. HTTP 408, 429, 500, 502, 503, and 504 are classified as retryable. | `collector/MddRealtimeCollector.psm1:252-380, 382-545`; `collector/Invoke-MddRealtimeCollector.ps1:5-10` |
| Collector audit grain | `ctl.MddCollectorRun` contains one row per Collector execution. The row starts as `Started` before sampling/request work, then becomes `Succeeded` or `Failed`; a killed process can leave `Started`. | `sql/02-staging/09-create-mdd-collector-run-audit.sql:8-13, 17-82, 112-181`; `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:323-351` |
| Audit detail | The audit records target identity, sampling context, HTTP status/attempts, source counts, persistence counts, error stage, and safe error text. | `sql/02-staging/09-create-mdd-collector-run-audit.sql:27-53, 154-181`; `collector/MddRealtimeCollector.psm1:1435-1461, 1523-1551` |
| Snapshot persistence | The response is parsed and passed to the existing set-based persistence procedure. Each snapshot persistence operation is atomic for that target execution. | `collector/MddRealtimeCollector.psm1:1410-1430`; `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md:288-321` |
| Execution budget | `MddCollectorExecutionBudgetSeconds = 240` currently bounds the worst-case timeout/retry duration of one Collector target execution. It is not a multi-target dispatcher budget today. | `collector/MddRealtimeCollector.psm1:1-16, 416-419` |

No database mutation is part of this design audit. The active state is treated
as the repository-documented seven-target / ten-slot state.

## 2. Why fixed SamplingSlot rotation no longer scales

The current selector maps each five-minute bucket to one ordinal in the
enabled slot list. Repeating a target in multiple slots increases its weight,
but the runtime still performs only one target collection per heartbeat. This
works for the present seven-target pilot and its fixed ten-slot, 50-minute
cycle.

The approved future panel has 50 targets with three different intervals. A
single rotating slot cannot express the required behavior without turning the
slot list into an implicit, difficult-to-audit expansion of target occurrences:

- a heartbeat must be able to produce all due targets, not one selected target;
- Tier A, B, and C require different repeat periods of two, three, and six
  five-minute buckets;
- targets in the same tier must be staggered rather than released as one burst;
- each target/bucket needs an independent claim and outcome;
- changing slot order or membership must not silently change a target's phase;
- health monitoring must reason about each target's configured due interval,
  not a global snapshot cadence.

`MddRealtimeSamplingSlot` therefore remains valid legacy scheduling metadata
for the current configuration and rollback path, but it is not the future
tiered scheduler's phase model.

## 3. Approved 50-station Tier baseline

The approved baseline contains 50 validated parent stations. Its intervals are
planning values and are not active Collector configuration.

| Tier | Approved station ranks | Targets | Planning interval | Available five-minute phases | Intended phase distribution |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tier A | 1–10 | 10 | 10 minutes | 2 | 5 / 5 |
| Tier B | 11–30 | 20 | 15 minutes | 3 | 7 / 7 / 6 |
| Tier C | 31–50 | 20 | 30 minutes | 6 | 4 / 4 / 3 / 3 / 3 / 3 |

The panel identity, station membership, rank, tier, and interval are frozen in
`docs/24-REALTIME-50-STATION-BASELINE.md`. The compatibility report in
`docs/25-REALTIME-50-STATION-MDD-COMPATIBILITY.md` records the successful live
validation: 50 approved stations, 50 HTTP 200 responses, 50 parsed results,
and 50 `CompatibleWithEvents` outcomes. Those results establish MDD/TRIAS
compatibility; they do not activate the panel or redefine production
`NumberOfResults`.

The seven currently enabled targets, their ten legacy slots, their existing
history, and all existing realtime observations remain unchanged.

## 4. Target dispatcher architecture

The future runtime is one dispatcher heartbeat with independent target
executions:

```text
Windows Task Scheduler
        |
        | every 5 minutes
        v
Tiered Sampling Dispatcher invocation
        |
        +--> resolve the current logical UTC five-minute bucket
        |
        +--> read enabled future target interval/phase configuration
        |
        +--> determine ALL targets due in this bucket
        |
        +--> atomically claim each (target, logical due bucket) once
        |
        +--> execute each claimed target independently
                 |
                 +--> internal automatic-target execution contract
                 |       (target metadata + logical due bucket)
                 +--> TRIAS request
                 +--> existing parser
                 +--> existing per-target snapshot persistence
                 +--> one target-level Collector audit row
        |
        +--> continue after target failures
        +--> write one dispatcher-level summary/log
```

The dispatcher owns bucket resolution, due-target discovery, claim
coordination, target isolation, and summary logging. The target execution owns
one request, parsing, persistence, and one target-level audit lifecycle. The
dispatcher must not wrap all target snapshots in one database transaction.

This is one scheduled task and one five-minute heartbeat, not one Windows task
per station and not 50 independent scheduled tasks. A heartbeat can therefore
produce multiple `ctl.MddCollectorRun` rows.

## 5. Five-minute heartbeat rationale

The heartbeat remains five minutes because all approved intervals are exact
multiples of five:

```text
10 minutes = 2 heartbeats
15 minutes = 3 heartbeats
30 minutes = 6 heartbeats
```

The dispatcher resolves a logical bucket by flooring the current UTC time to
the start of the current five-minute interval. The bucket is schedule time,
not the time of the last HTTP response and not a per-process counter. The
heartbeat is a trigger and coordination opportunity; it is not itself a
collection audit row.

The 50-station tier intervals are not activated by this document. The current
Task Scheduler configuration and current seven-target runtime remain in place.

## 6. Tier/phase staggering

### Phase definition

For a target with interval `I` minutes, define the number of five-minute
positions in its cycle as `Q = I / 5`. Assign a stable logical phase `P` in
`0..Q-1`. For a logical UTC bucket number `B`, the target is phase-aligned when:

```text
B modulo Q = P
```

This is a conceptual scheduling rule, not a physical SQL schema definition.
The later configuration design must validate that the interval is an approved
multiple of five and that the phase is in range.

### Stable assignment rule

Phase assignment must be stable. During a controlled rollout it may be
deterministically derived from the approved baseline rank to create the desired
cohort counts. Once the panel is activated, the resulting phase must be
persisted as configuration. Runtime scheduling must not recalculate phase from
a mutable rank, target order, or current slot list on every heartbeat.

No individual station receives a final physical phase value in this design;
the cohorts below are illustrative only.

### Intended distribution

| Tier | Cycle positions | Cohort sizes |
| --- | ---: | --- |
| A | 2 | A0 = 5, A1 = 5 |
| B | 3 | B0 = 7, B1 = 7, B2 = 6 |
| C | 6 | C0 = 4, C1 = 4, C2 = 3, C3 = 3, C4 = 3, C5 = 3 |

### Thirty-minute timing matrix

The following six-heartbeat example demonstrates the intended balance. The
cohort labels are logical examples, not assignments to named stations.

| Heartbeat in super-cycle | Tier A due | Tier B due | Tier C due | Total logical target requests |
| ---: | --- | --- | --- | ---: |
| 0 | A0 (5) | B0 (7) | C0 (4) | 16 |
| 1 | A1 (5) | B1 (7) | C1 (4) | 16 |
| 2 | A0 (5) | B2 (6) | C2 (3) | 14 |
| 3 | A1 (5) | B0 (7) | C3 (3) | 15 |
| 4 | A0 (5) | B1 (7) | C4 (3) | 15 |
| 5 | A1 (5) | B2 (6) | C5 (3) | 14 |

Across the 30-minute super-cycle there are 30 Tier A requests, 40 Tier B
requests, and 20 Tier C requests: 90 requests total, or an average of 15 per
heartbeat. The per-heartbeat range is 14–16 rather than a large same-tier
burst.

## 7. Due-target semantics

A target is due for a logical bucket only when all of the following are true:

1. the target is enabled;
2. its configured interval is valid;
3. the current UTC five-minute bucket matches its stable phase; and
4. the target has not already been claimed or executed for that same logical
   due bucket.

The scheduling clock is logical schedule time. It is not
`LastSuccessfulAtUtc`, the last response timestamp, the last persistence time,
or the elapsed time since a failure.

This prevents a repeatedly failing target from becoming continuously due and
consuming disproportionate request quota. A failed target is recorded as
failed for its scheduled execution and waits for its next normal phase-aligned
bucket.

The exact due-target query, claim operation, and physical configuration belong
to later Roadmap Items 5 and 6. No due-target SQL is introduced here.

## 8. Restart behavior

Missed historical buckets are intentionally not backfilled.

If Windows restarts, PowerShell restarts, the VM is powered off, or Task
Scheduler does not run for one or more heartbeat intervals:

- the dispatcher resumes from the current UTC five-minute bucket;
- an unclaimed target is eligible only if it is due in that current bucket;
- targets run again at their next regular phase-aligned due bucket;
- missed buckets are skipped rather than queued;
- no mass catch-up burst is created; and
- no artificial historical `ObservedAtUtc` value is generated.

If a restart occurs within a currently open bucket, a target that has not been
claimed may still be considered for that bucket. A target already claimed for
the bucket is not collected a second time. Once the bucket has passed, its
uncompleted work is not replayed.

MDD/TRIAS supplies a current snapshot. A later request cannot reconstruct a
snapshot that was missed while the VM was unavailable.

## 9. Missed-run behavior

The design distinguishes three conditions:

### A. Dispatcher was not running

No due-target batch is queued for the absent heartbeats. The next running
dispatcher evaluates only the current bucket. Each target waits for its next
normal phase if the current bucket is not one of its due buckets.

### B. Dispatcher ran but a due target failed

The target uses the existing bounded transient retry policy inside its own
execution. If the retries are exhausted, its target audit is `Failed`. The
dispatcher continues with other due targets and does not retry the failed
target every five minutes merely because it failed. The target becomes eligible
at its next normal interval/phase bucket.

### C. Dispatcher or PowerShell terminated before a target completed

The target audit may remain `Started`, matching current behavior when the
process is terminated before the completion update. A target claim already
consumed for the old bucket is not replayed. Under the future claim/audit
contract, that `Started` state must still identify or be durably associated
with the claimed target, logical due bucket, and StopPointRef even though no
completion update was reached. The target is collected again at the next
normal due bucket; no catch-up queue is created.

## 10. Failure and retry behavior

Target execution is isolated at the target boundary:

```text
Target A succeeds -> persist and audit Succeeded
Target B fails    -> audit Failed
Target C succeeds -> persist and audit Succeeded
```

One target failure must not abort the due-target batch. Each target keeps the
existing request, parser, and persistence behavior. Each successful snapshot
remains independently persisted using the current atomic snapshot persistence
semantics; the dispatcher does not create a transaction spanning all targets.

The current transient policy remains the policy inside a target execution:

- HTTP 500 and other currently classified transient HTTP statuses may be
  retried up to the configured attempt limit;
- transient HTTP transport failures such as timeouts may be retried according
  to the current classifier and backoff settings;
- a non-transient HTTP/authentication failure is not retried by the current
  policy;
- a successful HTTP response followed by a permanent parse failure is audited
  as a parse failure; the current request retry loop does not reissue an HTTP
  request for that parser failure; and
- actual HTTP attempts are retained for observability and quota accounting.

The dispatcher must continue after an exhausted retry or parse failure and
must not turn target failure into a five-minute retry loop.

## 11. Manual versus automatic execution

The current public contract has an important incompatibility with a future
dispatcher: in the current Collector, any non-empty `-StopPointRef` is treated
as a manual override. Therefore, a future dispatcher must not simply loop over
due targets and call the current public manual override path unchanged.

The future internal automatic-target contract should receive resolved metadata
such as:

- `SamplingTargetId`;
- `StopPointRef`;
- target name;
- per-target `NumberOfResults`; and
- logical due bucket.

The internal contract must explicitly set `SamplingMode = Automatic`, retain
the due-bucket context, and use the existing TRIAS request, parser, and
persistence functions. The StopPointRef is target metadata in this internal
contract; it must not be used as the signal that changes the mode to Manual.

An explicit user invocation such as
`Invoke-MddRealtimeCollector -StopPointRef <value>` continues to mean one
manual target execution with `SamplingMode = Manual`. A manual request does not
claim, complete, advance, or otherwise alter automatic scheduling state. It is
outside the automatic target/bucket claim key.

`NumberOfResults` remains a per-target Collector configuration concern. The
approved compatibility test used `NumberOfResults = 1`; the current active
seven-target configuration uses its existing values; this design does not set
all future targets to 1 or 5 and does not change the production policy.

## 12. Duplicate and overlap prevention contract

The automatic idempotency key is:

```text
(SamplingTargetId, LogicalDueBucket)
```

That key must be claimable at most once, even when:

- two dispatcher processes run concurrently;
- Windows Task Scheduler starts an overlapping invocation;
- a prior dispatcher is slow; or
- a target is still being processed when the next heartbeat begins.

The later database-backed design must provide an atomic claim/locking model.
Conceptually it should:

1. resolve candidates against the current logical bucket;
2. attempt a short, durable claim for each target/bucket key;
3. give the target execution contract only to the winner;
4. make a losing dispatcher skip that target without a second HTTP request; and
5. preserve the claim outcome for completed, failed, and interrupted work.

A future lease may identify the owning dispatcher or help diagnose abandoned
work, but lease expiry must not silently authorize a second collection of the
same target/bucket when the contract is strict at-most-once. An interrupted
target may remain `Started` and wait for its next regular bucket.

### Required claim/audit ordering invariant

For a future automatic target execution, the resolved target identity and
logical due bucket must be known before, or atomically associated with, the
durable target-execution claim/audit state. After a successful automatic
claim, an interrupted execution must remain traceable to at least:

- `SamplingTargetId`;
- `LogicalDueBucket`; and
- `StopPointRef`.

`SamplingTargetName` should also remain available whenever possible. This
traceability must exist even when the process terminates before HTTP
completion. The future implementation must not depend on
`ctl.uspCompleteMddCollectorRun` being reached in order to establish target
or bucket identity.

The conceptual sequence is:

1. resolve the automatic target identity and logical due bucket;
2. durably claim the `(SamplingTargetId, LogicalDueBucket)` key and create or
   associate the target-level `Started` audit state;
3. execute the target's HTTP request and persistence work;
4. finish the target-level audit as `Succeeded` or `Failed`.

The claim, `Started` audit state, HTTP execution, and final completion must
remain operationally correlated throughout that sequence. The physical SQL
mechanism is intentionally not prescribed here. Extending the audit-start
contract, associating a claim with `CollectorRunId`, or another atomic
database-backed design belongs to later roadmap work. The exact claim
table/procedure, locking primitive, lease representation, and physical
uniqueness enforcement remain deferred. This design does not implement
`sp_getapplock`, a claim table, a lease, or a constraint.

## 13. Target-level audit semantics

The audit grain remains one `ctl.MddCollectorRun` row per target collection
execution, not one row per dispatcher heartbeat. A heartbeat can therefore
produce 14–16 target audit rows in the approved future plan, subject to actual
claims and failures.

Each future automatic target execution must remain attributable to:

- target identity and target name;
- StopPointRef;
- logical due bucket;
- automatic/manual mode;
- HTTP status and actual HTTP attempt count;
- success/failure and failure stage;
- returned source counts; and
- persistence counts.

For automatic executions, target identity, StopPointRef, and logical due
bucket must be present in or durably associated with the target-level
`Started` state before HTTP work begins. Completion updates enrich and close
that state; they are not the first point at which target/bucket identity is
established.

The existing `Started`, `Succeeded`, and `Failed` lifecycle is retained. A
target-level row may remain `Started` if the process is killed before the
completion update, as it can today.

`SamplingSlot` is legacy scheduling metadata. The future tiered dispatcher
must not reuse or invent slot values to represent phases. Future tiered audit
rows may eventually leave that legacy attribute null. Any additional
dispatcher, claim, or phase audit fields are a later physical design decision;
`ctl.MddCollectorRun` is not modified by this task.

## 14. Execution-budget and concurrency considerations

The current constraint is:

```text
MddCollectorExecutionBudgetSeconds = 240
```

The current module uses that value to reject a timeout/retry configuration whose
worst-case HTTP/retry duration exceeds 240 seconds for one target execution.
That bound must remain a per-target bound. It must not be applied as the
lifetime budget for a batch of approximately 14–16 targets.

The future dispatcher therefore separates:

```text
dispatcher lifetime / orchestration
    from
individual target execution lifetime
```

A slow target, timeout, or bounded retry must not prevent other claimed due
targets from being attempted. The implementation should support bounded
concurrency or equivalent isolation, but this design deliberately selects no
`MaxConcurrentTargets` value. The repository does not contain a documented
MDD service concurrency or rate-limit contract from which to choose one.

The exact dispatcher lifetime, worker model, concurrency limit, shutdown
behavior, and pilot sizing belong to implementation work. They must preserve
the claim key and the per-target 240-second constraint.

## 15. Quota semantics

For a 30-day month, the approved planning tiers produce the following base
logical schedule volume:

| Tier | Calculation | Logical scheduled requests / 30-day month |
| --- | --- | ---: |
| Tier A | 10 targets × (30 × 24 × 60 / 10) | 43,200 |
| Tier B | 20 targets × (30 × 24 × 60 / 15) | 57,600 |
| Tier C | 20 targets × (30 × 24 × 60 / 30) | 28,800 |
| **Total** | — | **129,600** |

The current project limit documented in the repository is 250,000 requests per
month. The 129,600 figure is the base number of logical scheduled target
requests, not a worst-case HTTP consumption figure.

The dispatcher and audit/reporting layers must distinguish:

```text
LogicalScheduledRequestCount
    from
ActualHttpAttemptCount
```

One logical target request normally consumes one HTTP attempt. Transient
retries consume additional HTTP requests and therefore increase
`ActualHttpAttemptCount`. With the current default maximum of three attempts,
theoretical attempt volume can be materially greater than 129,600; no quota
capacity conclusion should use the base count alone.

Actual attempts, retry additions, target outcomes, and any rejected/deferred
work must be observable before activation. Quota enforcement and capacity
policy are deferred to Roadmap Item 7. Retry limits are not redesigned here.

## 16. Legacy-slot migration and rollback strategy

The intended migration is:

```text
CURRENT
MddRealtimeSamplingSlot
    + ctl.uspGetMddRealtimeSamplingTarget
    + one target per five-minute execution

FUTURE
target interval/phase configuration
    + due-target dispatcher
    + multiple independent target executions per heartbeat
```

During migration:

- the current `MddRealtimeSamplingSlot` table and selector remain deployed;
- the current seven-target configuration remains active;
- old observations and old audit rows remain historically valid;
- the future dispatcher is introduced behind a controlled activation decision;
- the approved 50-station panel is not seeded or activated by this design; and
- the legacy slot path remains available for rollback.

Rollback means returning the scheduled runtime to the current Collector path
and its existing slot configuration. Rollback must not rewrite observations,
relabel old audit rows, or delete the approved baseline. `MddRealtimeSamplingSlot`
should be deprecated or removed only in a later, separately validated change
after the future path has passed operational validation.

No migration SQL is part of this document.

## 17. Health-check and logging impacts

### Health-check contradiction

The current diagnostics contain assumptions that are correct for the active
pilot but will be false after tiered activation:

- `sql/02-staging/11-validate-realtime-collection-health.sql` uses one global
  `@ExpectedIntervalSeconds = 5 * 60` and evaluates gaps between all distinct
  snapshots;
- its panel coverage section counts configured `SamplingSlot` rows;
- current diagnostics interpret one automatic target per five-minute run and
  slot-derived target frequency, including the current 25/50-minute effective
  frequencies;
- `sql/02-staging/08-validate-mdd-realtime-sampling.sql` reports effective
  frequency from slot counts; and
- current stale-`Started` and run-health reports are target-audit reports but
  do not evaluate a target against an explicit interval/phase due schedule.

After activation, health monitoring must be target-aware. It must evaluate each
enabled target against its configured 10-, 15-, or 30-minute interval, stable
phase, logical due buckets, claim state, target outcomes, and actual attempt
counts. A global five-minute snapshot gap must not be reported as a failure
when no target was due in that bucket. These downstream changes are not made in
this branch.

### Logging contradiction

`Run-MddRealtimeCollector.ps1` currently produces one wrapper log file per
scheduled invocation. A future invocation may execute approximately 14–16
target collections. The design therefore distinguishes:

- one dispatcher-level operating-system log and summary for the heartbeat; and
- one target-level `ctl.MddCollectorRun` audit row for each target execution.

The implementation does not require one operating-system log file per target.
Dispatcher summaries should make target IDs, due bucket, claim outcome,
success/failure, and actual HTTP attempts discoverable without replacing the
target audit grain. Logging changes are deferred.

## 18. Design decisions

| Decision | Rationale |
| --- | --- |
| Keep one five-minute Windows heartbeat | 10, 15, and 30 minutes divide evenly into five-minute buckets. |
| Dispatch all due targets | The future panel needs 14–16 target requests per heartbeat, not one selected target. |
| Use logical UTC bucket time | Scheduling must be deterministic and independent of response success/failure timing. |
| Persist stable phases | Target order/rank changes must not silently move a target between due buckets after activation. |
| Do not backfill | A current MDD snapshot cannot recreate a missed historical snapshot. |
| Isolate targets | One failure must not abort successful or independent due targets. |
| Keep target-level audit grain | Operational history, retries, source counts, and persistence counts remain attributable to one target execution. |
| Keep manual and automatic contracts separate | The current public StopPointRef behavior intentionally means Manual. |
| Keep SamplingSlot as legacy metadata | It supports the active configuration and rollback but is not the future phase representation. |
| Separate dispatcher and target budgets | The existing 240-second constraint applies to one target, not a multi-target batch. |
| Do not choose concurrency yet | The repository has no documented MDD concurrency/rate-limit contract. |
| Count logical requests and HTTP attempts separately | Retries consume quota beyond the base tier schedule. |

## Risks / contradictions discovered during design audit

1. The current public Collector infers mode from whether `StopPointRef` is
   present. A future automatic dispatcher that passes a resolved StopPointRef
   through that public path would incorrectly audit the run as Manual.
2. `ctl.uspGetMddRealtimeSamplingTarget` returns one target by slot ordinal;
   it cannot be reused unchanged as an all-due target selector.
3. The current audit-start contract is insufficient for the future
   dispatcher. `ctl.uspStartMddCollectorRun` accepts only `StartedAtUtc`,
   `SamplingMode`, `StopPointRef`, and `NumberOfResults`; it does not persist
   `SamplingTargetId`, `SamplingTargetName`, or `SamplingBucketUtc`. In the
   current automatic flow, `Start-MddCollectorRun` is called before
   `ctl.uspGetMddRealtimeSamplingTarget` resolves the automatic target, and
   those target/bucket fields are populated only later through
   `ctl.uspCompleteMddCollectorRun`. A process termination before completion
   can therefore leave a `Started` row without enough identity to correlate it
   to the automatic `(SamplingTargetId, LogicalDueBucket)` claim. This
   current incompatibility must be resolved in the future design; it is not
   changed here.
4. The current audit has no future dispatcher claim identity or explicit
   at-most-once target/bucket enforcement. That protection must be designed
   before activation.
5. The current health diagnostics use global five-minute snapshot assumptions
   and legacy slot frequency. They will need a target-aware migration before
   tiered activation.
6. The current wrapper log is invocation-oriented while future work is
   target-oriented. A dispatcher summary is needed, but it must not replace
   target-level audit rows.
7. The current 240-second assertion is safe for one Collector invocation but
   cannot be applied to a future multi-target dispatcher as a single batch
   budget.
8. Task Scheduler's observed non-overlap is not an application-level
   duplicate guarantee. The future database-backed claim contract must remain
   authoritative if two invocations overlap.

These are design dependencies, not reasons to change the active runtime in
this branch.

## 19. Explicitly deferred implementation items

The following work remains outside this architecture-only change:

| Roadmap item | Deferred work |
| --- | --- |
| Item 5 | Physical configuration and claim/audit schema design, including the eventual representation of interval, stable phase, due bucket, ownership/idempotency state, automatic target identity at audit start, and logical due-bucket identity at audit start or claim association. It must also define correlation between the durable claim and `ctl.MddCollectorRun`, including interrupted `Started`-row traceability. |
| Item 6 | Exact due-target SQL, logical bucket selection, atomic claim behavior, claim/audit ordering, restart handling, and dispatcher execution mechanics. The physical design must preserve automatic target and bucket identity when a claimed execution terminates before completion. |
| Item 7 | Quota enforcement, capacity policy, retry-attempt budgeting, and any admission/defer behavior. |
| Item 8 | Collector internal automatic-target contract, multi-target orchestration, target isolation implementation, and dispatcher logging. The execution contract must carry or associate automatic target identity and logical due bucket with the target audit state before HTTP work, and must not rely on completion to establish them. |
| Item 9 | Seeding and controlled activation of the approved 50 stations. |
| Downstream validation | Target-aware health SQL, analytics/reporting changes, Power BI changes, and operational rollout validation. |

No runtime code, SQL tables, stored procedures, active sampling rows,
Task Scheduler settings, analytics views, or Power BI assets are changed here.

## 20. Scenario table

| Scenario | What executes | What is skipped | Retry? | Backlog? | What is audited | Next eligibility |
| --- | --- | --- | --- | --- | --- | --- |
| Normal five-minute heartbeat | Every enabled target due in the current bucket is claimed and executed independently. | Enabled targets whose phase does not match; already claimed target/bucket keys. | Only the existing bounded retry for a transient target failure. | No. | One target audit row per claimed collection; dispatcher summary covers the heartbeat. | The target's next normal phase-aligned bucket. |
| VM offline for 20 minutes | On recovery, only targets due in the current bucket are considered. | All missed historical buckets and targets not due now. | No catch-up retry. | No. | No row for skipped historical work; current executions receive normal target audit rows. | The next normal due bucket after recovery/current evaluation. |
| VM offline overnight | Same current-bucket evaluation as above. | The entire overnight history of missed buckets. | No catch-up retry. | No. | No synthetic observations or historical audit rows. | Each target's next regular phase-aligned bucket. |
| One target HTTP 500 | The target execution begins; other claimed targets continue independently. | None of the other due targets because one target failed. | Yes, because HTTP 500 is currently transient; bounded by existing attempt settings. | No. | Succeeded with attempts if a retry succeeds, otherwise `Failed` with HTTP status/attempts. | Next normal due bucket, even if all attempts fail. |
| One target HTTP timeout | The target execution is isolated; other due targets continue. | No unrelated due target. | Yes when classified as the existing transient transport failure; bounded by current settings. | No. | Succeeded or `Failed`, with actual attempt count and failure context. | Next normal due bucket. |
| One target permanent parse failure | Other due targets execute normally; the response for this target is not persisted as a valid snapshot. | No unrelated due target. | No additional HTTP retry under the current request/parser boundary. | No. | `Failed` with parse-stage error; no successful snapshot persistence counts. | Next normal due bucket. |
| PowerShell process killed mid-target | Work after termination stops; a new process later evaluates only its current bucket. | Remaining old-bucket targets and the interrupted target's old-bucket replay. | No replay of the killed target's old bucket. | No. | The started target may remain `Started`; no artificial completion or observation is written. | Next normal due bucket. |
| Second dispatcher starts while first is active | Only the database claim winner executes each target/bucket. | The losing dispatcher skips already claimed keys; it does not issue duplicate HTTP requests. | No duplicate retry merely because another dispatcher owns the key. | No. | Target rows belong to the winning executions; claim/overlap outcome is operationally observable later. | Normal phase schedule. |
| Manual StopPointRef request while automatic dispatcher is running | The explicit manual target request may execute through the manual path while automatic claims proceed independently. | It does not consume or replace an automatic target/bucket claim. | Manual request keeps its existing request/retry behavior. | No automatic backlog. | One `Manual` audit row for the manual execution; automatic rows retain `Automatic`. | Automatic targets remain eligible according to their unchanged phase schedule. |

## 21. Acceptance criteria for later implementation

The future implementation can be accepted only when all of the following are
demonstrated without changing historical data:

1. The active seven-target / ten-slot configuration remains unchanged until an
   explicit rollout decision; the 50-station baseline remains exactly 50
   approved stations with unchanged identity, rank, tier, and interval.
2. One five-minute dispatcher heartbeat resolves one logical UTC bucket and
   selects all enabled, valid, phase-aligned targets due in that bucket.
3. The deterministic phase allocation produces the approved approximate
   5/5, 7/7/6, and 4/4/3/3/3/3 cohorts, and persisted phases remain stable
   when target rank or row order changes.
4. Due selection is driven by logical bucket and claim state, not by the last
   successful response time.
5. `(SamplingTargetId, LogicalDueBucket)` is enforced at most once across
   overlapping dispatcher instances, with an observable claim outcome.
6. Missed buckets are not backfilled after a VM, Windows, PowerShell, or task
   outage; no artificial historical observation times are created.
7. A target HTTP 500, timeout, or parse/persistence failure is isolated and
   does not prevent other due targets from executing. The existing bounded
   transient retry behavior is preserved.
8. Automatic target executions use the internal automatic contract and audit
   as `Automatic`; explicit StopPointRef requests remain `Manual` and do not
   alter automatic scheduling state.
9. There is one target-level audit row per target collection execution,
   including logical due bucket, outcome, HTTP attempts, source counts, and
   persistence counts. If an automatic target process terminates after its
   target/bucket claim but before completion, operations can still determine
   the claimed `SamplingTargetId`, its `LogicalDueBucket`, the associated
   `StopPointRef`, and the target execution/audit state without requiring a
   successful completion update. Interrupted work can remain `Started`.
10. The per-target 240-second execution constraint is preserved without being
    applied to the complete multi-target dispatcher lifetime.
11. Actual HTTP attempts, including retry attempts, are observable separately
    from logical scheduled requests and are included in quota validation.
12. Health diagnostics evaluate target-specific due intervals/phases, and
    dispatcher logging is distinct from target-level audit, before the future
    plan is considered operationally complete.
13. A rollback to the current slot-based Collector path is tested without
    deleting or rewriting old observations, audit rows, or the approved
    baseline.

## Validation against current source

The design was checked against:

- `collector/Invoke-MddRealtimeCollector.ps1`;
- `collector/Run-MddRealtimeCollector.ps1`;
- `collector/MddRealtimeCollector.psm1`;
- `sql/02-staging/07-create-mdd-realtime-sampling.sql`;
- `sql/02-staging/08-validate-mdd-realtime-sampling.sql`;
- `sql/02-staging/09-create-mdd-collector-run-audit.sql`;
- `sql/02-staging/10-validate-mdd-collector-run-audit.sql`;
- `sql/02-staging/11-validate-realtime-collection-health.sql`;
- `docs/09-REALTIME-MDD-TRIAS-INTEGRATION-AND-GTFS-MATCHING.md`;
- `docs/24-REALTIME-50-STATION-BASELINE.md`; and
- `docs/25-REALTIME-50-STATION-MDD-COMPATIBILITY.md`.

The proposed design preserves the current request/parser/persistence flow,
the current target-level audit semantics, the approved 50-station identity and
compatibility evidence, the active seven-target configuration, and the
existing manual StopPointRef behavior. The only new behavior described is a
future orchestration boundary; it is not implemented by this change.
