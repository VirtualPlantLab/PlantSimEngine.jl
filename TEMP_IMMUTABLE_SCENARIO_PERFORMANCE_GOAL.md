# Temporary Goal: Separate Immutable Scenario Plans From Mutable Object State

## Goal

Improve PlantSimEngine performance by compiling scenario-level information once
and updating only object-dependent runtime state when objects are created,
removed, reparented, or moved.

The goal is complete only when ordinary timesteps execute from a stable,
precompiled scenario plan, lifecycle work is proportional to the structural
delta, and the changes preserve the unified `CompositeModel`/`Object` API,
scientific results, scheduling semantics, output history, and environment
behavior.

The predecessor hard-call performance goal is complete and was removed in
commit `355e143c`. Its final implementation and acceptance record remain in the
repository history and in
[`benchmark/release_baselines/README.md`](benchmark/release_baselines/README.md).
This goal starts from that accepted hard-call runtime. It owns the broader
compiler/runtime separation and must absorb the existing hard-call target
maintenance into one shared lifecycle and invalidation architecture rather
than introducing a second hard-call-specific path.

## Working Rules

- Use Kaimon for all Julia work and keep benchmark environments isolated and
  reproducible.
- Reinspect the current branch, worktree, open goal files, and relevant recent
  commits before implementation. Another task may have changed the hard-call
  runtime since this file was written.
- Preserve unrelated working-tree changes. Inspect the worktree before staging
  each commit and stage only files belonging to this goal.
- Commit regularly in small, coherent, validated slices. Do not leave the full
  redesign in one commit.
- Run `git diff --check` before every commit.
- Do not push, force-push, merge, tag, or publish a release unless explicitly
  requested.
- Do not update numerical fixtures merely to make failures pass. Explain and
  validate every intentional numerical change.
- Keep model parameters, status values, carriers, streams, and environment
  values generic. Do not introduce `Float64` specialization into scientific
  contracts.
- Preserve reference-backed same-rate coupling and typed temporal streams.
- Keep dynamic dispatch at compiled batch boundaries, never inside the
  per-object kernel loop.
- Benchmark construction, warmed steady-state execution, explicit output
  requests, lifecycle refresh, environment refresh, and output collection as
  separate workloads.
- Use one setup followed by many timesteps as the primary throughput workload.
  Keep repeated fresh `run!` timing as a separately named construction/cold-run
  metric.
- Keep this file updated as implementation progresses. Remove it only after the
  completion criteria are met and the final result has been handed off.

## Architectural Contract

The scenario definition is fixed after compilation:

- the set of model applications and their identifiers;
- model contracts and default/override implementation families;
- declared input, call, update, environment, and output rules;
- application-level dependency edges and topological order;
- clock/cadence definitions and phases;
- selector definitions and their matching programs;
- writer/update ordering rules;
- environment provider and sampling rules;
- output-retention requirements by application and variable;
- hard-call declarations, selectors, multiplicities, publication rules, and
  typed execution rules.

Runtime objects remain mutable:

- object registry membership and parent topology;
- application target membership;
- object statuses and per-application status views;
- resolved input carriers and temporal input state;
- retained stream instances and output-request membership intervals;
- environment handles and geometry-source associations;
- homogeneous execution-batch membership;
- lifecycle-maintained hard-call object bindings and cached typed execution
  batches.

The implementation should make this separation explicit, for example through
an immutable `CompiledScenarioPlan` and a mutable `RuntimeTopologyState` or
equivalent internal types. Exact internal names may differ, but the ownership
boundary must remain clear.

Lifecycle changes may instantiate, remove, or reconnect object-level state.
They must not reinterpret model declarations, rebuild the application graph,
or rediscover application-level schedule rules.

## Existing Strengths To Preserve

- Lifecycle refresh already reuses unaffected status views and execution
  groups.
- Incremental execution-target tests already require work counts to remain
  proportional to the structural delta.
- Same-rate inputs already use reference carriers when possible.
- Runtime temporal inputs already retain direct typed stream references.
- Root execution already groups homogeneous targets so dispatch occurs at the
  batch boundary.
- Hard calls now reuse cached homogeneous `CompiledExecutionBatch` values and
  keep dynamic dispatch at the batch boundary. Literal-name `call_model` and
  bulk `run_call!(...; sampled_environment=...)` provide allocation-free
  warmed fast paths for the supported singular and bulk use cases.
- `PreviousTimeStep` materialization now reads `TemporalDependencyBuffer`
  storage directly, updates scalar references and preallocated `Many` storage
  in place, and falls back to the compiled initial value when a newly created
  object has no previous source sample yet.
- Spatial environment bindings can already be invalidated for selected
  objects.
- Removed objects retain their historical output samples.
- New objects can run applications that remain later in the current timestep,
  but applications already completed are not rerun.

Do not replace these mechanisms wholesale without evidence. Refactor them into
the immutable-plan/mutable-state boundary and remove only duplicated or
obsolete paths.

## Completed Performance Prerequisites (2026-08-11)

The task "Compare XPalm full-cycle speed" completed the prerequisite hard-call
and temporal-input work. Treat the following as the starting point for this
goal, not as work to repeat:

- `695bc2c9` replaced repeated public `CallTarget` reconstruction in the hot
  path with cached, typed `CompiledExecutionBatch` values and added focused
  correctness, allocation, and benchmark coverage.
- `f3d2974b` added allocation-free warmed bulk
  `run_call!(...; sampled_environment=...)` and singular `call_model` paths.
- PlantBiophysics commit `dbd04e0` adapted Monteith, FvCB, FvCBIter, and
  ConstantAGs to those paths without changing the retained 113,880-row
  trajectory.
- `e2604582` specialized `PreviousTimeStep` materialization; `d5480c50` added
  the missing-stream fallback needed by lifecycle-created objects and external
  initial state.
- `b5518fbf`, `1635a3d1`, and `a072803b` added pinned downstream runners,
  benchmark CI support, sample-count control, documentation, and the final
  acceptance record. `355e143c` then removed the completed temporary hard-call
  goal.

The final follow-up in that task clarified an important lifecycle invariant:
"preallocated" temporal storage is stable only between structural changes, not
permanently fixed-size. At a lifecycle refresh barrier, a newly created organ
must be added to affected execution targets, hard-call buffers, temporal status
views, and `Many` storage. Applications still remaining in the current
timestep may then run on it; applications already completed are not rerun. If
the new organ has no previous source sample, `PreviousTimeStep` must use its
compiled initial value for that first read and use the normal temporal buffer
on subsequent timesteps.

The accepted local comparison used PlantSimEngine `d5480c50`,
PlantBiophysics `dbd04e0`, and XPalm `192e43f7`:

| Workload | Accepted current result | Pinned-release ratio |
| --- | ---: | ---: |
| PlantBiophysics, 8,760 steps, `outputs=:none` | 18.414 ms | 0.216x |
| PlantBiophysics, 8,760 steps, `outputs=:all` | 32.216 ms | 0.378x |
| XPalm full cycle, 4,160 lifecycle steps and output collection | 8.035 s | 1.483x |

The XPalm result exactly matched the pinned `v0.6.1` final reference at step
4,160: 344 phytomers, LAI `5.0587602356164405`, and FTSW
`0.7991179101191216`. The prerequisite validation recorded 2,005
PlantSimEngine tests, 268 PlantBiophysics tests, 307 XPalm tests, and 68 XPalm
numerical-regression tests passing. These are pre-change baselines; every
compiler/runtime slice implemented under this goal must still rerun its
relevant tests, and final acceptance requires fresh complete validation.

One architectural limitation deliberately remains in scope here: the current
`CompiledModelApplication`, `CompiledModelInputBinding`, and
`CompiledModelCallBinding` values still contain mutable object-id vectors.
`CallTargets.execution_batches` is a lifecycle-refreshed runtime cache, not the
future immutable scenario plan itself. This goal must separate those fixed
declarations from mutable membership while preserving the accepted typed
hard-call execution path.

## Phase 0: Reconcile With The Completed Hard-Call Performance Work

- [x] Inspect the archived final hard-call goal, its implementation commits,
  and the retained benchmark acceptance record.
- [x] Identify the current ownership boundary: fixed call rules remain mixed
  with mutable `callee_object_ids`/`callee_application_ids` in
  `CompiledModelCallBinding`, while `CallTargets.execution_batches` caches the
  lifecycle-refreshed typed execution targets.
- [x] Record the accepted PlantBiophysics and XPalm performance, allocation,
  numerical, and test baselines that must not regress.
- [x] Define the shared boundary between the scenario plan, lifecycle delta,
  root execution batches, and hard-call buffers.
- [x] Move fixed call definitions into the immutable scenario plan and mutable
  resolved call membership into runtime topology state without replacing the
  accepted typed `CompiledExecutionBatch` fast path.
- [x] Ensure this goal does not create separate object-change journals,
  revision systems, selector compilers, or target-buffer update protocols for
  root execution and hard calls.
- [x] Preserve the hard-call goal's correctness, publication, nested-call,
  selective-execution, and performance requirements.
- [x] Record prerequisite ordering: hard-call optimization and downstream
  acceptance are complete; immutable-scenario work begins from commit
  `355e143c` or later and owns subsequent shared compiler/runtime refactoring.

## Phase 1: Establish Baselines And Work Counters

- [x] Preserve the pinned PlantBiophysics/XPalm release runners, accepted raw
  performance record, typed hard-call microbenchmarks, and benchmark API smoke
  tests added by the completed prerequisite work.
- [x] Record the exact branch, commit, Julia version, thread count, CPU context,
  dependency versions, benchmark parameters, output policy, warm-up policy,
  sample count, and relevant package SHAs for this goal's pre-change baseline.
- [ ] Add or preserve one-setup/many-timestep steady-state benchmarks for:
  - `outputs=:none` with no temporal dependency;
  - temporal inputs with bounded dependency streams;
  - one and several explicit `OutputRequest`s;
  - `outputs=:all`;
  - many applications with mixed cadences;
  - homogeneous targets and targets split by overrides or environment type.
- [x] Keep construction and initial compilation outside warmed step timings.
- [ ] Add lifecycle benchmarks for one and several objects covering:
  - registration/growth;
  - removal of one object and a subtree;
  - reparenting of one object and a subtree;
  - geometry movement and inherited-geometry invalidation.
- [ ] Measure selector resolution separately for `SceneScope`, `Scope`,
  `Subtree`, `SelfPlant`, `Ancestor`, and every `Relation` variant used by
  lifecycle refresh.
- [ ] Record total time, time per timestep/event, allocations, allocated bytes,
  and runtime work counters.
- [x] Add counters that distinguish immutable-plan compilation from mutable
  target instantiation and target-buffer updates.
- [x] Record the current branch-head baseline before changing behavior. Reuse
  the pinned runners and accepted comparison as historical controls, but do
  not substitute the `d5480c50` measurements for a fresh starting-point run.
- [x] Commit the benchmark harness and focused regression tests as the first
  coherent slice.

### Fresh immutable-scenario baseline (2026-08-11)

This pre-change baseline was recorded on branch `multi-plants` at
`eb87938235472484b54956c8c86db1b7e5a9f104` plus the counter-only benchmark
instrumentation in the first implementation slice. The machine was an Apple
M3 Max MacBook Pro with 36 GiB RAM, Darwin 25.5.0 on arm64. Julia 1.12.1 used
10 threads while scientific execution remained sequential. The benchmark
environment used PlantSimEngine 0.15.0, BenchmarkTools 1.8.0, and
`benchmark/Manifest.toml` SHA-256
`658c36d6259dd4ff287a19db97c80335af2e0ad242419a690f144fee97362936`.

The workload contains 256 homogeneous hourly leaf producers and one daily
plant consumer reading all leaf values through `PreviousTimeStep`. Each timing
uses one already constructed simulation after one untimed setup step, then
times 48 continuous `continue!` steps. BenchmarkTools performed its normal
warm-up; results are medians of 10 samples with one evaluation per sample.
Construction is reported separately. The explicit-request case retains one
hourly `HoldLast` request over all leaves; output collection is excluded.

| Output policy/workload | Median total | Median per step | Allocations | Allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| construction and initial one-step run, `outputs=:none` | 4.306 ms | not applicable | 54,276 | 3,073,520 |
| 48 warmed steps, `outputs=:none` | 1.704 ms | 35.502 us | 1,888 | 117,760 |
| 48 warmed steps, one explicit request | 9.481 ms | 197.516 us | 179,183 | 8,340,640 |
| 48 warmed steps, `outputs=:all` | 2.830 ms | 58.961 us | 89,086 | 4,909,056 |

The opt-in work counters cover 49 total steps including setup. Every policy
visited 98 application groups, 98 batches, and 12,593 nominal batch targets.
This proves two current steady-state costs that later phases must remove:

- `_refresh_output_request_targets!` was called 51 times for every policy even
  though topology never changed;
- the explicit request performed 51 full selector resolutions, consuming
  6.402 ms in one representative instrumented run;
- the daily application's group, batch, and nominal targets were counted on
  every hourly step even when the application was not due.

The benchmark API smoke passed 16/16 and the focused runtime/instrumentation
suite passed 322/322. The broader Phase 1 matrix remains open for scenes with
no temporal dependency, several requests, overrides/environment splits,
lifecycle removal/reparenting/movement, and selector-family microbenchmarks.

## Phase 2: Remove Unnecessary Steady-State Work

### Output-request targets

- [x] Stop calling `_refresh_output_request_targets!` on an unchanged topology.
- [x] Give output-request target state an observed topology generation or
  lifecycle-event cursor.
- [x] Refresh request membership only when a relevant lifecycle delta exists.
- [x] Preserve the history of removed objects and define explicit start/end
  membership semantics for objects that enter or leave a selector after
  reparenting.
- [x] Test that a long unchanged simulation performs zero output-selector
  resolutions after initialization.
- [x] Test additions, removals, reparenting, continuation, and collection of
  historical intervals.

### Scheduler traversal

- [x] Evaluate cadence once per application execution group, not once per
  heterogeneous batch.
- [x] Replace the four-condition dirty check after each application with one
  safe mutation-generation comparison or an equivalent single cheap signal.
- [x] Preserve immediate refresh after an application mutates structure.
- [x] Preserve the rule that newly activated applications may run only if they
  remain later in the current timestep.
- [x] Add allocation and visit-count gates for an unchanged timestep.
- [x] Commit these steady-state removals as one validated slice.

### First steady-state cleanup result (2026-08-11)

An observed model revision now gates output-request target refresh, and the
root scheduler evaluates cadence before entering an application's batches.
Using the identical baseline workload and 10-sample method:

| Output policy | Median total | Median per step | Allocations | Allocated bytes | Baseline speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| `outputs=:none` | 1.692 ms | 35.247 us | 1,712 | 90,080 | 1.01x |
| one explicit request | 2.820 ms | 58.746 us | 88,752 | 4,878,304 | 3.36x |
| `outputs=:all` | 2.604 ms | 54.247 us | 88,766 | 4,879,072 | 1.09x |

Across 49 total steps, the scheduler still considered 98 application groups,
but entered only 52 due groups/batches and 12,547 due targets instead of
counting all 12,593 nominal targets. Unchanged output-request target refreshes
and selector resolutions both fell from 51 to zero. Registering one new leaf
then caused exactly one incremental object check, and its requested output
began at the lifecycle entry step.

Output-request targets now retain explicit membership intervals. A topology
barrier closes an interval at the current step when the requested producer has
already run, or at the previous completed step when it has not. Re-entry opens
a new interval at the corresponding next eligible step and records the
object's current value as that interval's initial sample. Collection consumes
these intervals directly, so removed objects retain history and reparented
objects cannot leak samples from periods when they were outside the selector.

## Phase 3: Compile A Truly Immutable Scenario Plan

- [x] Introduce a scenario-level plan that owns immutable application metadata.
- [x] Split fixed declaration fields from the mutable `target_ids`,
  `source_ids`, `source_application_ids`, `callee_object_ids`, and
  `callee_application_ids` currently stored in `CompiledModelApplication`,
  `CompiledModelInputBinding`, and `CompiledModelCallBinding`.
- [x] Compile application identifiers to stable internal indices while keeping
  public symbolic identifiers unchanged.
- [x] Compile input-binding templates independently of current consumer objects.
- [x] Represent potential producer applications even when source or consumer
  selectors currently match zero objects.
- [x] Preserve explicit `PreviousTimeStep` semantics: it must not add a
  same-step or reverse scheduler edge.
- [x] Compile same-object inference as an application-level template plus
  object-instantiation validation. New objects must not create new graph
  definitions.
- [x] Establish cached homogeneous hard-call execution batches and the warmed
  allocation-free bulk/singular public paths. Preserve these as runtime
  consumers of the new plan.
- [x] Resolve hard-call ownership, manual-call-only application membership,
  selectors, multiplicity, and publication rules once through immutable
  application/call templates. Lifecycle refresh may change only the resolved
  object membership and cached batches.
- [x] Compile writer/update ordering independently of current target objects
  where selector overlap can be established from fixed application rules.
- [x] Define a conservative and documented policy for potential selector
  overlap that cannot be proven without an object instance.
- [x] Compile and store the application DAG and stable topological order once.
- [x] Store ordered application plans directly rather than rebuilding an
  ordered vector through symbolic dictionary lookups.
- [x] Ensure lifecycle refresh cannot rebuild or mutate the application DAG.
- [x] Add diagnostics that separately expose immutable application plans and
  current object target counts.
- [x] Test applications that start with zero targets and acquire objects later.
- [x] Test ambiguity and cycle errors at the earliest sound validation point.
- [x] Commit the immutable scenario-plan implementation as a coherent slice.

`CompiledScenarioPlan` now owns a stable tuple of `CompiledApplicationPlan`
values and the immutable timeline definition. Each application plan has a
dense, compilation-order slot while preserving its public symbolic id.
`CompiledModelApplication` contains only that fixed plan and its mutable
object-target vector, and lifecycle additions/removals reuse the exact same
scenario/application plan objects. Focused coverage starts an application at
zero leaf targets, adds a matching object, removes it again, and checks that
only the target vector and diagnostic target count change.

Authored inputs, potential same-object inference, and hard calls are now
compiled into consumer-independent `CompiledModelInputPlan` and
`CompiledModelCallPlan` values. Runtime input/call bindings retain only their
plan, consumer id, resolved object/application membership, carrier/policy
state, and call-target membership. New objects instantiate those existing
plans rather than rereading `ModelSpec`; potential same-object producers are
present even when both applications initially have zero targets. The runtime
application id index is an immutable `NamedTuple` of mutable application-state
references, which also preserves the existing warmed temporal allocation
gate after the plan split.

### Static scenario DAG completion (2026-08-12)

The scenario plan now derives potential input producers and hard-call callees
from fixed application declarations even when no object currently matches a
selector. It freezes direct hard-call ownership, manual-call-only membership,
application dependency children, and stable topological order as tuples and
`NamedTuple`s. Nested call targets are ordered through their root scheduled
owner. `PreviousTimeStep` plans retain their source metadata but contribute no
same-step edge. Writer/update edges are compiled from authored output/update
rules and fixed selector-label overlap; scale, kind, species, and name can
prove disjointness, while cases depending on topology, scope, relations, or
current membership conservatively remain potential overlaps.

`CompiledScenarioPlan.ordered_application_plans` contains only immutable
`CompiledApplicationPlan` values. The corresponding ordered tuple of mutable
`CompiledModelApplication` target state lives on `CompiledCompositeModel` and
is reused directly by root execution and lifecycle refresh. Additions,
removals, and reparenting reuse the exact scenario DAG/order objects and no
longer rebuild call ownership, application children, or topological order.
Initial performance diagnostics now report immutable application/input/call
plan counts and time `scenario_plan_compile` separately from runtime target,
binding, status-view, and execution-target construction.

Pre-commit validation passed 1,603 focused assertions: application/API
stabilization 402, hard calls 85, `PreviousTimeStep` views 60, unified
model/object behavior 677, graph view 181, binding inference 16,
configuration errors 6, multirate integration 13, output boundaries 20,
environment backends 9, numerical parity 23, status initialization 28, time
validation 13, runtime matrix 10, environment sampling 15, temporal reducers
10, and immutable-scenario benchmark API smoke 35. These are slice-level
gates, not a substitute for the complete package and downstream acceptance
runs required later in the goal.

## Phase 4: Compile An Event-Driven Multirate Schedule

- [x] Compile immutable clock/cadence definitions into a schedule that selects
  only applications due at the current base step.
- [x] Use a schedule wheel, next-due-step table, or another allocation-free
  design appropriate for the supported clock representation.
- [x] Preserve stable topological order among applications due on the same
  timestep.
- [x] Preserve phase semantics and Dates-based duration conversion.
- [x] Ensure a lifecycle refresh changes current target buffers without
  rebuilding cadence definitions.
- [x] Ensure a newly activated application runs in the current timestep only
  when it is due and remains after the mutation barrier.
- [x] Add visit-count tests proving that non-due application groups and their
  batches are not traversed.
- [x] Benchmark many small applications at several cadences.
- [x] Commit the event-driven scheduler as a coherent slice.

### Event-driven scheduler implementation (2026-08-12)

`CompiledScenarioPlan.application_schedule` now stores immutable root cadence
entries in stable topological order. Applications with `dt <= 1` use an
always-due list, exact integer clocks use a reusable next-due-step table and
binary min-heap, and general real-valued clocks retain the prior modulo and
phase semantics through a generic fallback. The due-index buffer, periodic
heap, and topological-order restoration are allocation-free after schedule
initialization. Manual-call-only applications remain outside the root
schedule.

`CompiledExecutionPlan` holds only the mutable schedule cursor and a dense
application-slot-to-current-group table. Lifecycle refresh reuses the exact
schedule cursor while replacing or updating current target groups. The root
loop traverses only due application slots; a due slot with no current targets
costs one slot lookup and does not traverse an execution group or batch.
Within-step growth can activate a due application later in topological order,
while an application whose mutation barrier has already passed waits for its
next due timestep. Output-request membership boundaries use that same static
barrier prefix.

Diagnostics now report `schedule_entry_index`, `schedule_kind`, integer period
and phase when applicable, and whether dispatch is event-driven. Performance
counters distinguish initial schedule-entry compilation, schedule dispatches,
due entries, generic-clock checks, and visited execution groups. On the
existing 49-step immutable-scenario smoke, considered groups fell from 98 to
52 while due groups, batches, 199 target visits, and final results remained
unchanged.

A 5-sample warmed, uninstrumented benchmark with setup excluded and one
evaluation per sample used 64 one-target applications cycling through 1, 2, 3,
4, 6, 8, 12, and 24-hour cadences over 240 steps. The complete continuation
had an 89.100 ms median, 33,228 allocations, and 134,139,968 allocated bytes.
The scheduler selected 4,800 due application visits rather than scanning
15,360 execution groups. A direct warmed measurement of the due-index selector
itself reported zero allocations on every tested step.

Pre-commit validation passed 1,422 focused assertions: application/API
stabilization 408, hard calls 88, multirate integration 42, time validation 13,
output boundaries 20, `PreviousTimeStep` views 60, environment sampling 15,
temporal reducers 10, runtime matrix 10, numerical parity 23, unified
model/object behavior 679, and immutable-scenario benchmark API smoke 54. The
unified lifecycle expectation was deliberately updated so an application
before the mutation barrier runs on the next timestep rather than rewinding
the current step. Exact-integer heap dispatch was additionally checked against
the prior clock predicate for periods 2 through 12 and phases -24 through 24.

## Phase 5: Introduce A Shared Lifecycle Delta

- [x] Replace coarse dirty sets with a structured append-only delta or event
  journal containing, as applicable:
  - added object ids and labels;
  - removed object ids and previous topology information;
  - reparented roots, descendants, old parents, and new parents;
  - moved objects and old/new geometry sources;
  - one structural generation and one environment generation per committed
    barrier.
- [x] Make application targets, input carriers, temporal input state,
  environment handles, output-request targets, root execution batches, and
  hard-call target buffers consume the same lifecycle delta.
- [x] Preserve the current incremental append path for monotonic `Many`
  hard-call additions, or replace it only with a measured delta-based path that
  retains its ordering and allocation advantages.
- [x] Stage updates while kernels execute and apply them only at the existing
  refresh barrier.
- [x] Never mutate a target buffer while it is being iterated.
- [x] Add bulk internal operations for registering several objects, deleting a
  subtree, and marking a reparented subtree once.
- [x] Validate a subtree once before removal rather than recursively validating
  every child.
- [x] Avoid incrementing model/environment revisions once per descendant.
- [x] Preserve object-id ordering, multiplicity checks, removed-object history,
  template/instance rules, and MTG identifier bookkeeping.
- [x] Test organ creation after temporal buffers already exist: resize or
  replace affected `Many` storage at the lifecycle barrier, use the compiled
  initial value when the new organ has no previous sample, and read its normal
  temporal buffer from the following timestep onward.
- [x] Prove that lifecycle refresh work is proportional to the affected delta
  and selector dependencies, not total objects or applications.
- [x] Commit lifecycle journaling and bulk refresh as a coherent slice.

### Shared lifecycle delta completion (2026-08-12)

`CompositeModel` now owns one `LifecycleDelta` journal instead of separate
structural and environment dirty-object sets. Added and removed objects carry
label, topology, ancestry, and geometry snapshots; reparent events retain the
old and new parent plus the affected subtree; move events retain old/new
geometry and every object inheriting that geometry. One pending structural
generation and one pending environment generation are recorded per refresh
barrier, including when a subtree contains many descendants.

The same delta now drives application targets, value carriers, temporal state,
output-request membership, direct output-stream initialization, environment
handles, root execution groups, and cached hard-call targets. Structural and
environment consumers can consume their parts at different times without
losing append-only event data. Bulk object registration records one addition
barrier, while subtree removal and reparenting compute and validate descendants
once before applying one refresh notification. Mutations remain staged until
the existing post-application barrier, so no iterated target buffer is mutated
in place.

The temporal lifecycle regression starts with populated `PreviousTimeStep`
buffers, creates a new MTG-backed leaf, observes its compiled initial value on
the first eligible read, and observes its normal temporal sample on the next
timestep. Removed-object streams remain retained. Partial-consumption tests
also prove that a binding-only refresh followed by another addition neither
duplicates nor drops targets.

Isolated lifecycle-barrier allocations stayed effectively constant between
scenes with 8 and 2,048 leaves per plant:

| Operation | 8 leaves | 2,048 leaves |
| --- | ---: | ---: |
| monotonic addition | 37,136 bytes | 37,776 bytes |
| removal | 42,144 bytes | 43,248 bytes |
| reparenting | 59,200 bytes | 60,608 bytes |
| movement | 19,328 bytes | 19,712 bytes |

The addition case deliberately uses an object id that appends in stable object
order. A non-monotonic insertion correctly rebuilds the affected `Many`
selector/carrier and therefore scales with that selector dependency rather
than taking the append fast path.

Focused validation passed 1,431 assertions: application/API stabilization
490, hard calls 88, lifecycle benchmark API smoke 25, immutable-scenario
benchmark API smoke 54, `PreviousTimeStep` views 60, environment backends 9,
output boundaries 20, and unified model/object behavior 685. `git diff
--check` also passed before the checkpoint commit.

## Phase 6: Compile Selectors And Reverse Dependency Indices

- [x] Normalize immutable selector criteria into compiled matcher objects or
  typed predicates.
- [x] Resolve named `Scope` roots once and use ancestor membership instead of
  materializing a descendant `Set` for single-object membership tests.
- [x] Add allocation-free relation membership predicates for `self`, `parent`,
  `children`, `ancestors`, `descendants`, and `siblings`.
- [x] Compile reverse candidate indices for application target selectors using
  `scale`, `kind`, `species`, `name`, scope anchors, and wildcard classes.
- [x] Extend dynamic input/call binding indices beyond the current scale-only
  coarse filter when measurements justify it.
- [x] Track which scoped bindings may be affected by a reparented subtree.
- [x] Preserve exact `One`, `OptionalOne`, `Many`, scope, topology, application,
  process, and stable-order semantics.
- [x] Add allocation tests for matching one added object against a large scene.
- [x] Commit selector compilation and reverse indices as a coherent slice.

### Compiled-selector and reverse-index result (2026-08-12)

`CompiledSelectorMatcher` now stores normalized label criteria, topology scope,
typed relation dispatch, and default-context behavior once per immutable
application, input, call, or output-request declaration. Named `Scope` values
become `CompiledNamedScope` values with a stable root `ObjectId`. Single-object
membership therefore uses cached ancestor paths directly instead of rebuilding
descendant sets, and all six relation predicates execute without allocation in
the focused matcher tests.

`SelectorCandidateIndex` partitions application plans and lifecycle-maintained
input/call bindings by `scale`, `kind`, `species`, `name`, scope anchor, or a
conservative wildcard. A lifecycle addition now tests only the union of the
new object's label and ancestor buckets. Reparenting combines the new ancestry
with bindings forced by the object's old source/call membership, so entering
and leaving scoped selectors both remain exact without a scene-wide scan.
Output requests also retain their compiled matchers for later lifecycle
refreshes.

On a scene with 64 independent plants, adding one leaf examined one of two
application plans and one of 64 plant input bindings. Reparenting a leaf from
plant 1 to plant 2 examined one application plan and exactly the two affected
input bindings; the old carrier became empty and the new carrier contained
both leaves in stable order. The equivalent hard-call reparent test examined
one reverse call-binding candidate on entry, while exit used its recorded old
membership without another reverse candidate.

Every compiled matcher check across `Self`, `Subtree`, `SelfPlant`, generic and
scaled `Ancestor`, named `Scope`, and every supported `Relation` allocated zero
bytes. The warmed incremental refresh allocated 39,152 bytes for an 8-plant
scene and 56,208 bytes for a 2,048-plant scene, a 17,056-byte increase rather
than growth proportional to total objects or bindings.

Focused validation passed 1,014 assertions: API stabilization 598, hard calls
92, graph views 181, `PreviousTimeStep` views 60, environment backends 9,
output boundaries 20, and immutable-scenario benchmark smoke 54. The broader
unified model/object integration file also passed 685/685, and `git diff
--check` passed before the checkpoint commit.

## Phase 7: Compile Output And Environment Runtime Sinks

### Outputs

- [x] Extend direct typed runtime output bindings to requested and
  `outputs=:all` historical streams, not only dependency-only streams.
- [x] Publish through precompiled stream/reference tuples without per-target
  stream-key dictionary lookup.
- [x] Compile per-application retention variables and publication capability
  into application/batch plans.
- [x] Preserve bounded temporal dependency buffers, unbounded requested
  history, stream-only routing, type-stability errors, and removed-object
  history.
- [x] Ensure lifecycle-created targets receive correctly initialized output
  sinks and membership intervals.

#### Direct output-sink result (2026-08-12)

Every retained target output now owns a typed `RuntimeOutputStream` that points
directly to both its status reference and its initialized stream. This applies
uniformly to bounded dependency buffers, explicit requests, `outputs=:all`,
root-scheduled applications, bulk hard calls, and selectively materialized
`CallTarget`s. The execution loop publishes the precompiled tuple recursively;
the obsolete per-target dictionary publisher and its duplicate retention maps
were removed.

Each `CompiledExecutionBatch` now carries one `CompiledOutputPublication`
value with the application's stable retained-variable tuple and an enabled
flag. `outputs=:none` therefore skips publication at the batch boundary, while
retaining output no longer performs application or stream-key dictionary
lookups inside the target loop. Immediate hard-call targets created after a
lifecycle mutation initialize any missing retained stream before materializing
their direct binding; the normal lifecycle barrier continues to initialize
membership intervals and preserves removed-object history.

Using the same warmed 256-leaf, 48-step, 10-sample benchmark on the output-sink
parent commit:

| Output policy | Before | After | Speedup | Allocations before/after | Bytes before/after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `outputs=:none` | 1.794 ms | 1.820 ms | 0.99x | 1,374 / 1,374 | 118,784 / 121,152 |
| one explicit request | 3.543 ms | 1.846 ms | 1.92x | 76,174 / 2,398 | 3,728,128 / 977,216 |
| `outputs=:all` | 3.206 ms | 1.813 ms | 1.77x | 76,186 / 2,398 | 3,728,608 / 977,248 |

Requested and all-output allocations fell by 96.85% and allocated bytes by
73.79%. The no-retention allocation count was unchanged; its small timing and
byte differences are within the noise/capacity variation of these short
samples. Direct publication itself allocates zero bytes in the focused test.

The fresh output-focused matrix passed 794 assertions across API
stabilization, requested/all/none outputs, lifecycle membership, bounded
`PreviousTimeStep` storage, hard-call publication, and type-stability errors.
The immutable-scenario benchmark smoke also passed 54/54, and `git diff
--check` passed before the output-sink checkpoint commit.

### Environment

- [ ] Split immutable per-application environment information from mutable
  per-object handles.
- [ ] Store backend selection, required/source/produced variables, sampling
  rules, prepared sources, and sampler objects once per application plan.
- [ ] Keep only handle, context, geometry source, and other genuinely
  object-dependent state in target bindings.
- [ ] Add reverse indices from object to existing environment bindings so
  targeted refresh does not scan every application for each dirty object.
- [ ] Replace hash-based per-step global sample caches with application slots or
  generation-stamped cache entries if benchmarks show a measurable benefit.
- [ ] Preserve transient hard-call environment overrides and accepted
  environment commits.
- [ ] Commit output and environment sink optimization in separate validated
  slices unless they require one shared internal representation.

## Phase 8: Evaluate Dense Internal Slots

Perform this phase only if profiles show tuple-key dictionaries or repeated
static metadata remain important after the preceding work.

- [ ] Assign each immutable application a dense internal application slot.
- [ ] Assign each runtime object a stable monotonic internal object slot while
  preserving its public `ObjectId` and public stable-order semantics.
- [ ] Use vector tables, bitsets, or slot-indexed adjacency structures for hot
  internal lookup where they outperform dictionaries.
- [ ] Keep tombstones or equivalent stable ownership for removed objects whose
  output history remains accessible.
- [ ] Avoid duplicating selectors, policies, model contracts, environment
  metadata, or output schemas in every object-level binding instance.
- [ ] Preserve heterogeneous object/status/model support and split typed
  execution batches only when runtime types genuinely differ.
- [ ] Measure memory as well as time for large object counts.
- [ ] Commit dense-slot changes only after focused correctness, allocation, and
  large-scene evidence.

## Phase 9: Full Validation And Documentation

- [x] Preserve the prerequisite acceptance record: PlantSimEngine 2,005/2,005,
  PlantBiophysics 268/268, XPalm 307/307, XPalm numerical regression 68/68,
  exact PlantBiophysics retained trajectory, and exact XPalm final reference.
  These counts establish the pre-change boundary and do not satisfy the fresh
  final runs below.
- [ ] Run focused tests after each compiler/runtime slice covering:
  - one object and many objects;
  - same-object and cross-object inputs;
  - `One`, `OptionalOne`, and `Many`;
  - temporal policies and `PreviousTimeStep`;
  - hard calls, nested calls, selective execution, and publication;
  - duplicate writers and `Updates`;
  - global and spatial environments;
  - addition, removal, reparenting, movement, and subtree operations;
  - templates, instances, and overrides;
  - output requests, `outputs=:all`, `outputs=:none`, and removed-object history;
  - generic numeric and status value types.
- [ ] Run the complete PlantSimEngine test suite.
- [ ] Run the complete PlantBiophysics test suite against the local checkout.
- [ ] Run the complete XPalm test suite and established 4,160-step numerical
  regression against the local checkout.
- [ ] Compare representative full trajectories, not only final scalar values,
  for changes touching time, outputs, environment sampling, or lifecycle.
- [ ] Run fair warmed multi-timestep PlantBiophysics and XPalm benchmarks after
  the major implementation milestones.
- [ ] Update diagnostics to distinguish immutable plan compilation, object
  target instantiation, lifecycle buffer updates, and steady-state execution.
- [ ] Update developer documentation for the immutable-plan/mutable-state
  architecture and lifecycle barrier.
- [ ] Update benchmark CI only after runner baselines are stable enough to
  support non-brittle thresholds.
- [ ] Update the installed PlantSimEngine skill if the resulting public or
  advanced compiler contract changes.
- [ ] Remove temporary diagnostics and benchmark-only implementation hooks.
- [ ] Record final commands, SHAs, benchmark methodology, raw results, ratios,
  allocation counts, and validation boundaries.

## Commit Checkpoints

Commit regularly, normally after each validated slice below:

1. Benchmark harness, work counters, and current baselines.
2. Output-request refresh gating and steady-state scheduler cleanup.
3. Immutable scenario plan and application-level binding templates.
4. Event-driven multirate schedule.
5. Shared lifecycle delta and bulk subtree operations.
6. Compiled selector predicates and reverse indices.
7. Direct output sinks.
8. Application-level environment plans and targeted handle refresh.
9. Dense internal slots, only if justified by profiling.
10. Downstream validation, diagnostics, documentation, and cleanup.

Before every commit:

- inspect `git status` and the staged diff;
- preserve and exclude unrelated changes;
- run the smallest relevant correctness and allocation tests;
- run `git diff --check`;
- use a commit message describing one coherent optimization or validation
  change.

## Benchmark Milestones

Run expensive downstream benchmarks only at these milestones:

0. **Accepted prerequisite (complete):** retained hard-call/temporal fast-path
   results and pinned release comparisons recorded in
   `benchmark/release_baselines/README.md`.
1. **Fresh baseline:** at the current branch head, before immutable-scenario
   implementation changes.
2. **Steady-state cleanup:** after output-request and scheduler traversal fixes.
3. **Immutable-plan milestone:** after application DAG, schedule definitions,
   and binding templates are no longer rebuilt by lifecycle events.
4. **Lifecycle milestone:** after the shared delta updates all runtime buffers.
5. **Output/environment milestone:** after direct sinks and application-level
   environment plans are active.
6. **Final acceptance:** after complete PlantSimEngine and downstream tests.

Additional expensive runs are justified only when profiling identifies a new
bottleneck or a milestone result remains outside the target range.

## Completion Criteria

This goal is complete only when all of the following are true:

- [ ] Scenario/application definitions, application dependency edges,
  topological order, cadence rules, selector programs, environment sampling
  rules, and output-retention requirements are compiled once.
- [ ] Lifecycle operations update only affected object-level targets, carriers,
  streams, environment handles, and execution buffers at a safe barrier.
- [ ] Ordinary unchanged timesteps perform no selector resolution, application
  graph reconstruction, topological sorting, output-request target refresh, or
  environment-handle reconstruction.
- [ ] Non-due multirate applications and their batches are not traversed.
- [ ] The ordinary post-lifecycle timestep returns immediately to the same
  precompiled steady-state schedule.
- [ ] New objects can activate existing application relationships without
  constructing new application-level dependency definitions.
- [ ] Temporal scalar references and `Many` storage remain allocation-stable
  between lifecycle events while still admitting newly created organs at the
  refresh barrier with correct first-sample fallback semantics.
- [ ] The root runtime and hard-call runtime consume the same lifecycle delta
  and immutable scenario ownership model.
- [ ] Homogeneous execution loops retain concrete model, status, carrier,
  stream, environment, and context types.
- [ ] Warmed focused hard-call fast paths remain allocation-free where recorded
  by the prerequisite gates, PlantBiophysics retains its exact accepted
  trajectory, and XPalm remains no more than approximately 1.5x the pinned
  release full-cycle runtime.
- [ ] Explicit output requests preserve correct dynamic membership intervals
  and removed-object history without steady-state rescans.
- [ ] Lifecycle work and allocations scale with the affected structural delta,
  not total scene size, except where selector semantics genuinely require a
  broader affected set.
- [ ] Construction, warmed steady-state execution, explicit output requests,
  output collection, lifecycle refresh, environment refresh, and full-cycle
  runtime are reported separately.
- [ ] All PlantSimEngine tests pass.
- [ ] All relevant PlantBiophysics tests pass and representative numerical
  trajectories are unchanged.
- [ ] All relevant XPalm tests and the established numerical regression pass.
- [ ] Benchmark methods, raw results, package SHAs, allocation counts, and
  validation commands are recorded reproducibly.
- [ ] All relevant changes are committed in coherent increments, with unrelated
  worktree changes preserved.

## Deferred Ideas

Do not begin these without new profiling evidence and an explicit design
decision:

- fusing adjacent same-object application kernels;
- struct-of-arrays status storage;
- parallel or distributed execution;
- changing public object ordering semantics;
- compatibility layers for superseded internal compiler types.

These may eventually benefit from the immutable scenario plan, but they are not
required to complete this goal.
