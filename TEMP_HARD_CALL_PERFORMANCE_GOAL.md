# Temporary Goal: Restore Hard-Call Performance

## Goal

Restore the steady-state execution performance of PlantSimEngine hard dependencies while preserving the unified `CompositeModel`/`Object` API, lifecycle behavior, hard-call semantics, and downstream numerical results.

The goal is complete only when the current implementation is approximately as fast as the older direct-call implementation. The primary acceptance target is a median runtime no more than about **1.5× the pinned release baseline** on fair, warmed, multi-timestep benchmarks. A result around 4× slower is not acceptable.

## Working Rules

- Use Kaimon for all Julia work and keep benchmark environments isolated and reproducible.
- Preserve unrelated working-tree changes. Inspect the worktree before staging each commit and stage only files belonging to this goal.
- Commit regularly in small, coherent, validated slices. Do not leave the entire implementation in one large commit.
- Run `git diff --check` before every commit.
- Do not push, force-push, merge, tag, or publish a release unless explicitly requested.
- Do not update numerical fixtures merely to make failures pass. Explain and validate any intentional numerical change.
- Do not benchmark after every small edit. Use cheap correctness and allocation gates during development; run the expensive downstream benchmarks at the milestones defined below and for final acceptance.
- Keep this file updated as work progresses. Remove it only after the completion criteria are met and the final result has been handed off.

## Architectural Contract

- The hard-dependency graph is fixed when the scenario dependency graph is compiled:
  - call names;
  - caller and callee applications;
  - selectors and scopes;
  - multiplicity (`One`, `OptionalOne`, or `Many`);
  - ordering and publication semantics;
  - execution and batching rules.
- Runtime objects may still be created, removed, or reparented during growth.
- Separate the implementation into:
  - an immutable compiled hard-call plan; and
  - lifecycle-maintained buffers containing the currently resolved object execution targets.
- Lifecycle operations may update affected target buffers once at the structural refresh barrier. Ordinary timesteps must immediately return to the cached steady-state path.
- Existing hard-call plans must not be reinterpreted or rebuilt every timestep.
- New objects may instantiate already-compiled application and hard-call relationships, but they must not require reconstructing the dependency graph.

## Current Performance Problem

- `CallTargets` caches the collection but currently materializes large `CallTarget` values while iterating or indexing it.
- `_materialize_call` repeatedly retrieves status views, nested calls, environment bindings, applications, and models inside iterative scientific kernels.
- The cached execution targets use `Dict{Tuple{Symbol,ObjectId},Any}`, which breaks inference before the concrete model invocation.
- PlantBiophysics calls hard dependencies repeatedly inside Monteith and FvCB iterations, amplifying this overhead at every timestep.
- The existing root execution scheduler already demonstrates the intended approach: homogeneous, concretely typed execution batches with dynamic dispatch restricted to batch boundaries.

## Baseline Record (2026-08-11)

The baseline machine is an Apple M3 Max MacBook Pro with 14 CPU cores and 36 GB
RAM, running macOS/Darwin 25.5.0 on arm64. All measurements below used Julia
1.12.1 with one Julia thread, 12 samples, one evaluation per sample, and an
explicit warm-up before sampling.

Pinned sources:

- release PlantSimEngine `v0.14.1` at `503af98c3709a0b1207407e3741b7cb09ebfbcf7`;
- release PlantBiophysics `v0.17.0` at `9f39af4ffd48bab234e5d80b89cd52c67b9f3f82`;
- pre-optimization PlantSimEngine at `5437ed3fe2d8eec7e9520d57ba390779a5c7e541`;
- current PlantBiophysics at `b733e05032cde9b60e527cc2b33a472281c995fb`.

The primary workload constructs one leaf scene outside the timed region and
runs one continuous 8,760-hour weather trajectory. The release API retains its
normal outputs. The current API is measured both with `outputs=:none` and with
`outputs=:all`.

| Stack and output policy | Median total | Median per step | Allocations | Allocated bytes | Release ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| release, normal retained outputs | 121.665 ms | 13.889 us | 3,825,487 | 239,901,760 | 1.00x |
| pre-optimization current, `outputs=:none` | 331.677 ms | 37.863 us | 7,170,970 | 807,184,352 | 2.73x |
| pre-optimization current, `outputs=:all` | 356.192 ms | 40.661 us | 7,751,391 | 829,093,296 | 2.93x |

The in-repository benchmark introduced by this goal reproduced the current
steady-state cost in a fresh benchmark process at 310.588 ms (35.455 us per
step, 3,971,290 allocations, 629,223,952 bytes) for `outputs=:none` and 322.146
ms (36.775 us per step, 4,551,711 allocations, 651,132,896 bytes) for
`outputs=:all`. It also records construction separately at 17.289 ms and the
100-scene one-step fan-out workload separately at 15.681 ms. The first table is
the acceptance comparison because its release and current values came from the
same temporary comparison harness. A checked-in pinned release runner remains
to be added so the comparison can be repeated without reconstructing that
temporary environment.

### First typed-batch milestone

After replacing per-call `Dict{...,Any}` lookup and repeated target
reconstruction with typed `CompiledExecutionBatch` tuples, the same fresh
current benchmark process measured:

| Current output policy | Median total | Median per step | Allocations | Allocated bytes | Release ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `outputs=:none` | 44.961 ms | 5.132 us | 393,374 | 86,500,304 | 0.37x |
| `outputs=:all` | 54.910 ms | 6.268 us | 973,795 | 108,409,248 | 0.45x |

The focused singular, repeated, nested, `Many`, and heterogeneous override
invocations allocate zero bytes after warm-up when unpublished. Accepted
publication currently allocates 192 bytes in the minimal gate. Construction
and the one-step fan-out workload remain separate and were 17.542 ms and 15.524
ms respectively at this milestone.

## Phase 1: Lock Down Baselines And Regression Tests

- [x] Record the exact branch, commit, Julia version, thread count, CPU context, package versions, benchmark parameters, output policy, sample count, and warm-up policy for every baseline.
- [ ] Preserve a pinned PlantBiophysics release environment using PlantBiophysics `v0.17.0` and PlantSimEngine `v0.14.1`.
- [ ] Preserve a pinned XPalm release environment using the established XPalm release scenario and compatible PlantSimEngine release.
- [x] Add a deterministic, one-setup/many-timestep PlantBiophysics benchmark:
  - construct the leaf scene outside the timed region;
  - run one continuous weather trajectory over many timesteps;
  - use identical scientific parameters and forcing in current and release environments;
  - report total time, time per timestep, allocations, and allocated bytes;
  - measure a no-retention throughput case and the closest comparable retained-output case.
- [x] Keep construction timing as a separate benchmark rather than mixing it into the steady-state result.
- [x] Keep the independent one-step/many-scenes workload, but label it as a cold-run or fan-out metric rather than the primary PlantBiophysics performance result.
- [ ] Add small hard-call microbenchmarks using no-op or minimal kernels for:
  - one singular hard dependency;
  - nested hard dependencies;
  - repeated iterative calls;
  - `Many` targets;
  - homogeneous and heterogeneous/override targets;
  - pre-sampled environments;
  - unpublished trials and accepted publication.
- [x] Add warmed allocation gates that isolate framework overhead from model-kernel allocations.
- [x] Record the current baseline before changing the runtime.
- [ ] Commit the benchmark harness and regression tests as the first coherent slice.

## Phase 2: Compile Immutable Hard-Call Plans

- [x] Define a compiled hard-call plan that owns immutable call metadata and does not contain timestep-varying state.
- [x] Compile call plans once with the rest of the dependency graph.
- [x] Store calls in a type-stable structure keyed by their compile-time names, preferably a typed tuple or `NamedTuple` that can constant-propagate literal symbols.
- [x] Reuse the existing `CompiledExecutionTarget` and homogeneous batch concepts where possible instead of maintaining a second execution design.
- [x] Remove `Dict{Tuple{Symbol,ObjectId},Any}` from the steady-state hard-call execution path.
- [x] Ensure concrete model, status, input-binding, environment-binding, nested-call, and context types are visible inside each homogeneous batch loop.
- [x] Add a specialization/function barrier for any unavoidable heterogeneous lookup so dynamic dispatch occurs once per batch, never once per object field access or kernel operation.
- [x] Keep heavy target materialization only for explicit diagnostics or introspection, not for normal execution.
- [x] Validate the focused correctness and allocation tests.
- [ ] Commit the immutable-plan implementation as a coherent slice.

## Phase 3: Add Lifecycle-Maintained Target Buffers

- [x] Give each compiled hard-call plan a stable runtime buffer of currently resolved execution targets.
- [x] Group targets into homogeneous typed batches; create separate batches for overrides or genuinely different runtime types.
- [x] Build reverse indices that identify which applications and call plans can be affected by object creation, removal, or reparenting.
- [x] Update only affected buffers during the existing structural refresh barrier after the lifecycle-mutating application completes.
- [x] Do not mutate a target buffer while it is being iterated. Stage updates and swap or patch buffers safely at the refresh barrier.
- [x] Preserve stable ordering by object id and existing selector semantics.
- [x] Revalidate `One` and `OptionalOne` multiplicity whenever a lifecycle change affects their target buffers.
- [x] Ensure new objects can run applications that remain later in the same timestep, while never rerunning applications that already completed.
- [ ] Ensure removed objects retain their historical output samples.
- [x] Prove that an ordinary timestep after a lifecycle event performs no graph rebuild or selector resolution for unchanged call plans.
- [x] Test creation, removal, reparenting, templates, instances, overrides, and nested hard calls.
- [ ] Commit lifecycle target-buffer maintenance as a coherent slice.

## Phase 4: Provide Allocation-Free Public Execution Paths

- [ ] Add a bulk hard-call path accepting an already sampled model environment, for example:

  ```julia
  run_call!(
      context,
      :photosynthesis;
      sampled_environment=environment,
      publish=false,
  )
  ```

- [ ] Keep `sampled_environment` distinct from the existing transient backend `environment` override semantics.
- [ ] Ensure the bulk path executes cached typed batches directly without enumerating public `CallTarget` wrappers.
- [ ] Design an allocation-free singular-target mechanism for algorithms such as FvCB that must inspect the selected stomatal model before executing it.
- [ ] Use a typed callback/function barrier or an equivalent cached handle so `gs_closure` dispatch and model parameter access remain concrete.
- [ ] Preserve selective or iterative execution where required without imposing its cost on the ordinary bulk path.
- [ ] Preserve trial publication semantics: iterative calls default to unpublished, and only accepted state is published.
- [ ] Update diagnostics and docstrings so caching claims distinguish cached plans/buffers from explicitly materialized introspection views.
- [ ] Validate the focused correctness and allocation tests.
- [ ] Commit the public fast-path API as a coherent slice.

## Phase 5: Adapt PlantBiophysics

- [ ] Update Monteith to use the cached bulk hard-call path with its already sampled environment.
- [ ] Update FvCB to use the cached singular stomatal target/model path without materializing a `CallTarget` during each iteration.
- [ ] Preserve the exact numerical behavior of Monteith, FvCB, Medlyn, environment sampling, convergence, and publication.
- [ ] Run the complete PlantBiophysics test suite against the local PlantSimEngine checkout.
- [ ] Compare representative final values and full output trajectories with the pre-optimization implementation.
- [ ] Run cheap warmed allocation checks after the adaptation.
- [ ] Run the fair multi-timestep PlantBiophysics benchmark after this major milestone.
- [ ] If the median current/release ratio remains above 1.5×, profile the remaining per-timestep overhead before proceeding to final acceptance.
- [ ] Commit the PlantBiophysics adaptation separately in its repository, preserving unrelated changes there.

## Phase 6: Validate PlantSimEngine And XPalm

- [ ] Run focused PlantSimEngine hard-call, execution-plan, environment, publication, and lifecycle tests after each relevant implementation slice.
- [ ] Run the complete PlantSimEngine test suite before final downstream validation.
- [ ] Run the complete XPalm test suite against the local PlantSimEngine checkout.
- [ ] Run the established 4,160-step XPalm numerical regression and confirm the reference values remain unchanged within their existing tolerances.
- [ ] Verify growth-related object creation, hard-call target attachment, schedules, output retention, and final-state behavior in XPalm.
- [ ] Run the fair XPalm full-cycle benchmark in isolated current and pinned-release environments.
- [ ] Report construction, `outputs=:none`, requested-output collection, lifecycle refresh, and full-cycle timing separately when applicable.
- [ ] If XPalm exceeds the 1.5× performance target, profile it independently rather than assuming the PlantBiophysics fix covers all runtime costs.
- [ ] Commit any required XPalm adaptation separately in the XPalm repository, preserving unrelated changes there.

## Phase 7: Documentation, CI, And Skill Updates

- [ ] Update the PlantSimEngine hard-call documentation to explain immutable call plans and lifecycle-maintained object target buffers.
- [ ] Update modeler examples to use the allocation-free bulk and singular hard-call APIs.
- [ ] Update `Diagnostics.explain_calls` or related diagnostics if needed to expose compiled plans, current target counts, batch types, and lifecycle refresh state without exposing unstable implementation fields.
- [ ] Update the regular benchmark CI to run a reasonably sized multi-timestep PlantBiophysics workload.
- [ ] Update the full-performance workflow to run the longer PlantBiophysics and XPalm acceptance benchmarks.
- [ ] Keep construction, steady-state execution, lifecycle refresh, output retention/materialization, and full-cycle measurements separately named.
- [ ] Add regression thresholds only after stable baselines have been collected on comparable runners; avoid brittle thresholds based on a single noisy run.
- [ ] Update the installed `plantsimengine` skill to match the final public API and performance contract.
- [ ] Run documentation checks and benchmark API smoke tests.
- [ ] Commit documentation, CI, and skill-facing repository changes in coherent slices.

## Commit Checkpoints

Commit regularly, normally after each validated slice below:

1. Benchmark harness and focused regression/allocation tests.
2. Immutable compiled hard-call plans and typed execution batches.
3. Lifecycle-maintained target buffers and structural refresh tests.
4. Bulk pre-sampled-environment and singular-target public APIs.
5. PlantBiophysics adaptation and its tests.
6. PlantSimEngine lifecycle/downstream corrections discovered during validation.
7. XPalm adaptation, if required, and its tests.
8. Documentation, diagnostics, CI benchmarks, and final cleanup.

Before every commit:

- inspect `git status` and the staged diff;
- preserve and exclude unrelated changes;
- run the smallest relevant correctness and allocation tests;
- run `git diff --check`;
- use a commit message describing one coherent performance or validation change.

## Benchmark Milestones

Run expensive benchmarks only at these points:

1. **Baseline:** before runtime implementation changes.
2. **First hot-path milestone:** after typed compiled hard-call execution is working.
3. **Downstream milestone:** after PlantBiophysics uses the new public fast paths.
4. **Final acceptance:** after PlantSimEngine, PlantBiophysics, and XPalm tests pass.

Additional benchmark runs are justified only when profiling identifies a new bottleneck or a milestone result remains above the acceptance threshold.

## Completion Criteria

This goal is complete only when all of the following are true:

- [ ] The hard-dependency definition is compiled once and remains immutable during simulation.
- [ ] Runtime object growth/removal/reparenting updates only affected cached target buffers at lifecycle barriers.
- [ ] Ordinary hard-call execution performs no selector resolution, application lookup, target reconstruction, or dependency-graph rebuild.
- [ ] Homogeneous hard-call loops retain concrete model, status, environment, and context types.
- [ ] Warmed framework overhead for the focused hard-call microbenchmarks is allocation-free or reduced to a documented, justified minimum.
- [ ] All PlantSimEngine tests pass.
- [ ] All PlantBiophysics tests pass and representative numerical trajectories are unchanged.
- [ ] All XPalm tests and the established numerical regression pass.
- [ ] The fair multi-timestep PlantBiophysics benchmark is no more than approximately **1.5× slower** than the pinned release stack on the primary comparable metric.
- [ ] The fair XPalm full-cycle benchmark is no more than approximately **1.5× slower** than its pinned release baseline, unless a separately measured and explicitly accepted non-hard-call cost explains the difference.
- [ ] Construction, steady-state execution, lifecycle refresh, output retention/materialization, and full-cycle measurements are reported separately.
- [ ] Benchmark scripts used by CI match the supported API and represent one-setup/many-timestep workloads where appropriate.
- [ ] Final benchmark methodology, raw results, ratios, package SHAs, and validation commands are recorded for reproducibility.
- [ ] All relevant changes have been committed in coherent increments, with unrelated changes preserved.

If either primary downstream benchmark remains around 4× slower, the goal is not complete even if correctness tests pass.
