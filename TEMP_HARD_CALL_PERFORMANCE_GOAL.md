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
RAM, running macOS/Darwin 25.5.0 on arm64. The PlantBiophysics release/current
measurements below used Julia 1.12.1 with 10 Julia threads, 12 samples, one
evaluation per sample, and an explicit warm-up before sampling. The scientific
model execution remained sequential. The staged XPalm profiling harness was
also exercised separately with one Julia thread.

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
same temporary comparison harness. Reproducible pinned release runners are now
checked in under `benchmark/release_baselines/` for both PlantBiophysics and
XPalm.

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

### PlantBiophysics fast-API milestone

After PlantBiophysics switched its iterative kernels to the bulk
`sampled_environment` path and singular `call_model` access, the same fresh
benchmark process measured:

| Current output policy | Median total | Median per step | Allocations | Allocated bytes | Release ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| `outputs=:none` | 19.514 ms | 2.228 us | 288,137 | 25,883,792 | 0.16x |
| `outputs=:all` | 36.431 ms | 4.159 us | 868,558 | 47,792,736 | 0.30x |

The complete PlantBiophysics suite passed with 268 tests after the adaptation.
Construction remained separate at 17.398 ms, and the one-step fan-out workload
was 15.521 ms.

The full 8,760-hour retained-output trajectory was also compared against the
pinned pre-optimization PlantSimEngine `5437ed3f` with PlantBiophysics
`b733e05`. All 113,880 output rows, including their timestep, application,
object, variable, and value fields, were exactly identical. The maximum
absolute numerical difference was 0.0.

### Final downstream acceptance

On the final one-thread PlantBiophysics run, the current 8,760-step workload
measured 18.414 ms with `outputs=:none` and 32.216 ms with `outputs=:all`. The
pinned release retained-output workload measured 85.142 ms. The closest
retained-output ratio is therefore 0.378x, and the current runtime is faster
than the release baseline on both output policies.

The final XPalm comparison used five warmed samples on both current and pinned
release stacks. Each timed sample called the high-level `XPalm.xpalm` workflow,
including scene construction, 4,160 lifecycle steps, requested outputs, and
DataFrame materialization, but excluding meteorology/Palm preparation, Julia
startup, and package loading. Both sides used 10 Julia threads while executing
the scientific model sequentially.

| XPalm stack | Median full cycle | Per step | Release ratio |
| --- | ---: | ---: | ---: |
| `v0.6.1` with PlantSimEngine `v0.14.1` | 5.416 s | 1.302 ms | 1.000x |
| current XPalm with PlantSimEngine `d5480c50` | 8.035 s | 1.931 ms | **1.483x** |

The current final state exactly matched the `v0.6.1` reference: step 4,160,
344 phytomers, LAI `5.0587602356164405`, and FTSW
`0.7991179101191216`. Raw samples, allocations, construction, output-retention,
and lifecycle-profile measurements are recorded permanently in
`benchmark/release_baselines/README.md`.

## Phase 1: Lock Down Baselines And Regression Tests

- [x] Record the exact branch, commit, Julia version, thread count, CPU context, package versions, benchmark parameters, output policy, sample count, and warm-up policy for every baseline.
- [x] Preserve a pinned PlantBiophysics release environment using PlantBiophysics `v0.17.0` and PlantSimEngine `v0.14.1`.
- [x] Preserve a pinned XPalm release environment using the established XPalm release scenario and compatible PlantSimEngine release.
- [x] Add a deterministic, one-setup/many-timestep PlantBiophysics benchmark:
  - construct the leaf scene outside the timed region;
  - run one continuous weather trajectory over many timesteps;
  - use identical scientific parameters and forcing in current and release environments;
  - report total time, time per timestep, allocations, and allocated bytes;
  - measure a no-retention throughput case and the closest comparable retained-output case.
- [x] Keep construction timing as a separate benchmark rather than mixing it into the steady-state result.
- [x] Keep the independent one-step/many-scenes workload, but label it as a cold-run or fan-out metric rather than the primary PlantBiophysics performance result.
- [x] Add small hard-call microbenchmarks using no-op or minimal kernels for:
  - one singular hard dependency;
  - nested hard dependencies;
  - repeated iterative calls;
  - `Many` targets;
  - homogeneous and heterogeneous/override targets;
  - pre-sampled environments;
  - unpublished trials and accepted publication.
- [x] Add warmed allocation gates that isolate framework overhead from model-kernel allocations.
- [x] Record the current baseline before changing the runtime.
- [x] Commit the benchmark harness and regression tests as the first coherent slice (`c1340dca`).

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
- [x] Commit the immutable-plan implementation as a coherent slice (`695bc2c9`).

## Phase 3: Add Lifecycle-Maintained Target Buffers

- [x] Give each compiled hard-call plan a stable runtime buffer of currently resolved execution targets.
- [x] Group targets into homogeneous typed batches; create separate batches for overrides or genuinely different runtime types.
- [x] Build reverse indices that identify which applications and call plans can be affected by object creation, removal, or reparenting.
- [x] Update only affected buffers during the existing structural refresh barrier after the lifecycle-mutating application completes.
- [x] Do not mutate a target buffer while it is being iterated. Stage updates and swap or patch buffers safely at the refresh barrier.
- [x] Preserve stable ordering by object id and existing selector semantics.
- [x] Revalidate `One` and `OptionalOne` multiplicity whenever a lifecycle change affects their target buffers.
- [x] Ensure new objects can run applications that remain later in the same timestep, while never rerunning applications that already completed.
- [x] Ensure removed objects retain their historical output samples.
- [x] Prove that an ordinary timestep after a lifecycle event performs no graph rebuild or selector resolution for unchanged call plans.
- [x] Test creation, removal, reparenting, templates, instances, overrides, and nested hard calls.
- [x] Commit lifecycle target-buffer maintenance as a coherent slice (`695bc2c9`).

## Phase 4: Provide Allocation-Free Public Execution Paths

- [x] Add a bulk hard-call path accepting an already sampled model environment, for example:

  ```julia
  run_call!(
      context,
      :photosynthesis;
      sampled_environment=environment,
      publish=false,
  )
  ```

- [x] Keep `sampled_environment` distinct from the existing transient backend `environment` override semantics.
- [x] Ensure the bulk path executes cached typed batches directly without enumerating public `CallTarget` wrappers.
- [x] Design an allocation-free singular-target mechanism for algorithms such as FvCB that must inspect the selected stomatal model before executing it.
- [x] Use a typed callback/function barrier or an equivalent cached handle so `gs_closure` dispatch and model parameter access remain concrete.
- [x] Preserve selective or iterative execution where required without imposing its cost on the ordinary bulk path.
- [x] Preserve trial publication semantics: iterative calls default to unpublished, and only accepted state is published.
- [x] Update diagnostics and docstrings so caching claims distinguish cached plans/buffers from explicitly materialized introspection views.
- [x] Validate the focused correctness and allocation tests.
- [x] Commit the public fast-path API as a coherent slice (`f3d2974b`).

## Phase 5: Adapt PlantBiophysics

- [x] Update Monteith to use the cached bulk hard-call path with its already sampled environment.
- [x] Update FvCB to use the cached singular stomatal target/model path without materializing a `CallTarget` during each iteration.
- [x] Preserve the exact numerical behavior of Monteith, FvCB, Medlyn, environment sampling, convergence, and publication.
- [x] Run the complete PlantBiophysics test suite against the local PlantSimEngine checkout.
- [x] Compare representative final values and full output trajectories with the pre-optimization implementation.
- [x] Run cheap warmed allocation checks after the adaptation.
- [x] Run the fair multi-timestep PlantBiophysics benchmark after this major milestone.
- [x] If the median current/release ratio remains above 1.5×, profile the remaining per-timestep overhead before proceeding to final acceptance.
- [x] Commit the PlantBiophysics adaptation separately in its repository, preserving unrelated changes there (`dbd04e0`).

## Phase 6: Validate PlantSimEngine And XPalm

- [x] Run focused PlantSimEngine hard-call, execution-plan, environment, publication, and lifecycle tests after each relevant implementation slice.
- [x] Rerun the complete PlantSimEngine test suite on the final committed runtime after the focused lifecycle regression fix (2,005 tests passed).
- [x] Run the complete XPalm test suite against the local PlantSimEngine checkout (307 tests passed).
- [x] Run the established 4,160-step XPalm numerical regression and confirm the reference values remain unchanged within their existing tolerances (68 tests passed with the exact `v0.6.1` reference state).
- [x] Verify growth-related object creation, hard-call target attachment, schedules, output retention, and final-state behavior in XPalm.
- [x] Run the fair XPalm full-cycle benchmark in isolated current and pinned-release environments.
- [x] Report construction, `outputs=:none`, requested-output collection, lifecycle refresh, and full-cycle timing separately when applicable.
- [x] Profile XPalm independently; this identified previous-step temporal input materialization as its remaining hot path and led to `e2604582` and `d5480c50`.
- [x] Confirm that no XPalm adaptation or commit is required; the XPalm worktree remained clean.

## Phase 7: Documentation, CI, And Skill Updates

- [x] Update the PlantSimEngine hard-call documentation to explain immutable call plans and lifecycle-maintained object target buffers.
- [x] Update modeler examples to use the allocation-free bulk and singular hard-call APIs.
- [x] Review `Diagnostics.explain_calls`; no new unstable implementation fields were needed because the existing call explanation and public target materialization remain the explicit introspection boundary.
- [x] Update the regular benchmark CI to run a reasonably sized multi-timestep PlantBiophysics workload.
- [x] Update the full-performance workflow to run the longer PlantBiophysics and XPalm acceptance benchmarks.
- [x] Keep construction, steady-state execution, lifecycle refresh, output retention/materialization, and full-cycle measurements separately named.
- [x] Avoid brittle thresholds based on a single noisy run; the workflows preserve measurements for runner-specific baselining.
- [x] Update and install the `plantsimengine` skill to match the final public API and performance contract.
- [x] Run documentation checks and benchmark API smoke tests (documentation build completed and release-baseline bootstrap smoke passed 14/14).
- [x] Commit documentation, CI, and skill-facing repository changes in coherent slices (`b5518fbf`).

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

- [x] The hard-dependency definition is compiled once and remains immutable during simulation.
- [x] Runtime object growth/removal/reparenting updates only affected cached target buffers at lifecycle barriers.
- [x] Ordinary hard-call execution performs no selector resolution, application lookup, target reconstruction, or dependency-graph rebuild.
- [x] Homogeneous hard-call loops retain concrete model, status, environment, and context types.
- [x] Warmed framework overhead for the focused hard-call microbenchmarks is allocation-free or reduced to a documented, justified minimum.
- [x] All PlantSimEngine tests pass (2,005/2,005).
- [x] All PlantBiophysics tests pass (268/268) and representative numerical trajectories are unchanged.
- [x] All XPalm tests (307/307) and the established numerical regression (68/68) pass.
- [x] The fair multi-timestep PlantBiophysics benchmark is no more than approximately **1.5× slower** than the pinned release stack on the primary comparable metric (0.378x for the closest retained-output comparison).
- [x] The fair XPalm full-cycle benchmark is no more than approximately **1.5× slower** than its pinned release baseline (1.483x).
- [x] Construction, steady-state execution, lifecycle refresh, output retention/materialization, and full-cycle measurements are reported separately.
- [x] Benchmark scripts used by CI match the supported API and represent one-setup/many-timestep workloads where appropriate.
- [x] Final benchmark methodology, raw results, ratios, package SHAs, and validation commands are recorded for reproducibility.
- [x] All relevant changes have been committed in coherent increments, with unrelated changes preserved.

If either primary downstream benchmark remains around 4× slower, the goal is not complete even if correctness tests pass.
