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
- [ ] Define the shared boundary between the scenario plan, lifecycle delta,
  root execution batches, and hard-call buffers.
- [ ] Move fixed call definitions into the immutable scenario plan and mutable
  resolved call membership into runtime topology state without replacing the
  accepted typed `CompiledExecutionBatch` fast path.
- [ ] Ensure this goal does not create separate object-change journals,
  revision systems, selector compilers, or target-buffer update protocols for
  root execution and hard calls.
- [ ] Preserve the hard-call goal's correctness, publication, nested-call,
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
- [ ] Add counters that distinguish immutable-plan compilation from mutable
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
- [ ] Preserve the history of removed objects and define explicit start/end
  membership semantics for objects that enter or leave a selector after
  reparenting.
- [x] Test that a long unchanged simulation performs zero output-selector
  resolutions after initialization.
- [ ] Test additions, removals, reparenting, continuation, and collection of
  historical intervals.

### Scheduler traversal

- [x] Evaluate cadence once per application execution group, not once per
  heterogeneous batch.
- [ ] Replace the four-condition dirty check after each application with one
  safe mutation-generation comparison or an equivalent single cheap signal.
- [ ] Preserve immediate refresh after an application mutates structure.
- [ ] Preserve the rule that newly activated applications may run only if they
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

## Phase 3: Compile A Truly Immutable Scenario Plan

- [ ] Introduce a scenario-level plan that owns immutable application metadata.
- [ ] Split fixed declaration fields from the mutable `target_ids`,
  `source_ids`, `source_application_ids`, `callee_object_ids`, and
  `callee_application_ids` currently stored in `CompiledModelApplication`,
  `CompiledModelInputBinding`, and `CompiledModelCallBinding`.
- [ ] Compile application identifiers to stable internal indices while keeping
  public symbolic identifiers unchanged.
- [ ] Compile input-binding templates independently of current consumer objects.
- [ ] Represent potential producer applications even when source or consumer
  selectors currently match zero objects.
- [ ] Preserve explicit `PreviousTimeStep` semantics: it must not add a
  same-step or reverse scheduler edge.
- [ ] Compile same-object inference as an application-level template plus
  object-instantiation validation. New objects must not create new graph
  definitions.
- [x] Establish cached homogeneous hard-call execution batches and the warmed
  allocation-free bulk/singular public paths. Preserve these as runtime
  consumers of the new plan.
- [ ] Resolve hard-call ownership, manual-call-only application membership,
  selectors, multiplicity, and publication rules once through immutable
  application/call templates. Lifecycle refresh may change only the resolved
  object membership and cached batches.
- [ ] Compile writer/update ordering independently of current target objects
  where selector overlap can be established from fixed application rules.
- [ ] Define a conservative and documented policy for potential selector
  overlap that cannot be proven without an object instance.
- [ ] Compile and store the application DAG and stable topological order once.
- [ ] Store ordered application plans directly rather than rebuilding an
  ordered vector through symbolic dictionary lookups.
- [ ] Ensure lifecycle refresh cannot rebuild or mutate the application DAG.
- [ ] Add diagnostics that separately expose immutable application plans and
  current object target counts.
- [ ] Test applications that start with zero targets and acquire objects later.
- [ ] Test ambiguity and cycle errors at the earliest sound validation point.
- [ ] Commit the immutable scenario-plan implementation as a coherent slice.

## Phase 4: Compile An Event-Driven Multirate Schedule

- [ ] Compile immutable clock/cadence definitions into a schedule that selects
  only applications due at the current base step.
- [ ] Use a schedule wheel, next-due-step table, or another allocation-free
  design appropriate for the supported clock representation.
- [ ] Preserve stable topological order among applications due on the same
  timestep.
- [ ] Preserve phase semantics and Dates-based duration conversion.
- [ ] Ensure a lifecycle refresh changes current target buffers without
  rebuilding cadence definitions.
- [ ] Ensure a newly activated application runs in the current timestep only
  when it is due and remains after the mutation barrier.
- [ ] Add visit-count tests proving that non-due application groups and their
  batches are not traversed.
- [ ] Benchmark many small applications at several cadences.
- [ ] Commit the event-driven scheduler as a coherent slice.

## Phase 5: Introduce A Shared Lifecycle Delta

- [ ] Replace coarse dirty sets with a structured append-only delta or event
  journal containing, as applicable:
  - added object ids and labels;
  - removed object ids and previous topology information;
  - reparented roots, descendants, old parents, and new parents;
  - moved objects and old/new geometry sources;
  - one structural generation and one environment generation per committed
    barrier.
- [ ] Make application targets, input carriers, temporal input state,
  environment handles, output-request targets, root execution batches, and
  hard-call target buffers consume the same lifecycle delta.
- [ ] Preserve the current incremental append path for monotonic `Many`
  hard-call additions, or replace it only with a measured delta-based path that
  retains its ordering and allocation advantages.
- [ ] Stage updates while kernels execute and apply them only at the existing
  refresh barrier.
- [ ] Never mutate a target buffer while it is being iterated.
- [ ] Add bulk internal operations for registering several objects, deleting a
  subtree, and marking a reparented subtree once.
- [ ] Validate a subtree once before removal rather than recursively validating
  every child.
- [ ] Avoid incrementing model/environment revisions once per descendant.
- [ ] Preserve object-id ordering, multiplicity checks, removed-object history,
  template/instance rules, and MTG identifier bookkeeping.
- [ ] Prove that lifecycle refresh work is proportional to the affected delta
  and selector dependencies, not total objects or applications.
- [ ] Commit lifecycle journaling and bulk refresh as a coherent slice.

## Phase 6: Compile Selectors And Reverse Dependency Indices

- [ ] Normalize immutable selector criteria into compiled matcher objects or
  typed predicates.
- [ ] Resolve named `Scope` roots once and use ancestor membership instead of
  materializing a descendant `Set` for single-object membership tests.
- [ ] Add allocation-free relation membership predicates for `self`, `parent`,
  `children`, `ancestors`, `descendants`, and `siblings`.
- [ ] Compile reverse candidate indices for application target selectors using
  `scale`, `kind`, `species`, `name`, scope anchors, and wildcard classes.
- [ ] Extend dynamic input/call binding indices beyond the current scale-only
  coarse filter when measurements justify it.
- [ ] Track which scoped bindings may be affected by a reparented subtree.
- [ ] Preserve exact `One`, `OptionalOne`, `Many`, scope, topology, application,
  process, and stable-order semantics.
- [ ] Add allocation tests for matching one added object against a large scene.
- [ ] Commit selector compilation and reverse indices as a coherent slice.

## Phase 7: Compile Output And Environment Runtime Sinks

### Outputs

- [ ] Extend direct typed runtime output bindings to requested and
  `outputs=:all` historical streams, not only dependency-only streams.
- [ ] Publish through precompiled stream/reference tuples without per-target
  stream-key dictionary lookup.
- [ ] Compile per-application retention variables and publication capability
  into application/batch plans.
- [ ] Preserve bounded temporal dependency buffers, unbounded requested
  history, stream-only routing, type-stability errors, and removed-object
  history.
- [ ] Ensure lifecycle-created targets receive correctly initialized output
  sinks and membership intervals.

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
