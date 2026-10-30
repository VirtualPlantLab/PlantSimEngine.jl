# PR243 dispatch and compiler-width investigation

This is an independent **source review**, dated 2026-10-30. It identifies one
dispatch gap and candidate compiler-cost surfaces. It does not establish the
cause or active location of either the PR243 CI cancellation or the bounded
local run. No Julia was executed for this review, no core representation was
changed, and no whole-file or aggregate regression pass is credited here.

## Two distinct incomplete runs

The reviewed PR243 head is
`d7a5d0be48fae8fb95ce276e9bf545d5b11dc3ee`, as recorded in
[upstream-baseline.json](upstream-baseline.json). The supplied complete
[Ubuntu job log](https://github.com/VirtualPlantLab/PlantSimEngine.jl/actions/runs/40837039155/job/123324129416)
reports Julia **1.13.3**, tests starting at 07:42:09 UTC on 2026-10-29,
generated-source method overwrite warnings at 08:00:16 and 08:15:45–51, and
cancellation at 10:41:50. Its recorded test-action duration is 10,798,712 ms,
approximately three hours. No active stack, compiler profile, signal report,
or failing assertion locates the work after the final warning. That warning
does not prove where the job spent its remaining time.

The local ordinary focused run used the reviewed #240/#241/#242 baseline,
without PR243 and with the experimental newborn promotion hooks disabled.
[Receipt 031](current-programs/receipts/031-ordinary-focused-result.json)
reports evaluation `c80dafb4` still running after **2m 10s**;
[receipt 032](current-programs/receipts/032-ordinary-focused-cancel.json)
records a cooperative cancellation request; and
[receipt 033](current-programs/receipts/033-bounded-check-restart.json)
confirms a fresh Julia restart. This was a deliberately bounded investigation,
not a completed regression run.

The final on-disk [ordinary-focused.log](current-programs/ordinary-focused.log.gz)
contains `BEGIN` and `END` markers for input-plan/output-metadata and
coalesced-growth/environment, then `BEGIN` for status-type/temporal. It also
contains subsequent REPL/restart output. An earlier observation had only the
first `BEGIN`; the run progressed before restart. The markers have no
timestamps or per-file assertion counts, and no final aggregate result was
written. They establish observed completion markers, not a test-pass claim or
a precise cancellation location. The local run's incompleteness predates
PR243, but does not demonstrate that the two runs share a cause.

## Confirmed PR243 dispatch gap

PR243 introduces two `_run_scheduled_model_execution_batch!` methods whose
first argument is restricted to `CompiledExecutionBatch`. Execution groups
otherwise accept `AbstractExecutionBatch` implementations and previously
dispatched directly to each implementation's numerical method. The new barrier
therefore excludes the alternative Direct, Lean, Growing, Shared and Tight
batch implementations before reaching those methods.

The independent [generic dispatch patch](pr243-generic-dispatch.patch) changes
only those **two argument annotations** to `AbstractExecutionBatch`. It keeps
the noinline barrier, `Simulation` argument, numerical calls, sampling and
publication intact. Julia can still specialize at this boundary on the
concrete batch. The profiled path continues to require the batch's
`_run_model_execution_batch_profiled!` implementation; prototype compilers that
select ordinary execution for `performance=true` retain that policy. This
patch does not invent profiling semantics for unknown batch layouts.

The patch was parsed with `git apply --stat`, but has **not been applied or
executed** in the current source tree. Normal core plans use
`CompiledExecutionBatch`; experimental backends are not loaded by the standard
suite. Consequently, this confirmed extension gap does not explain the CI
timeout. PR243 also changes status-view mutability, caches `CallTargets`
lengths, and adds aggressive constant propagation to one `run_call!` method;
their compiler effects remain separate, untested hypotheses.

## Where application width enters compiled types

The first [input-plan metadata testset](../../../test/test-model-input-plan-output-metadata.jl#L99)
runs twelve cases: `Float32`/`Float64`, inferred/explicit bindings, and counts
1/8/32. The [fixture](../../../test/test-model-input-plan-output-metadata.jl#L68)
has one source application plus one reader application per object. Count32
therefore creates **33 applications and 32 objects**, compiles declarations
twice, then executes one step with `outputs=:all`.

The final [writer-candidate testset](../../../test/test-model-input-plan-output-metadata.jl#L424)
has **36 applications**: 32 unrelated source declarations, three possible
`:sent` producers, and one reader. It begins with empty destination selectors,
then registers three objects, advances, and forces another logical refresh.
Empty targets do not remove these application declarations from scenario
metadata.

These fixtures do not create a 32-variable ordinary organ status. In the first,
each object uses the same four declared fields: source scalar/array and reader
scalar/array. Array lengths 8 and 3 are values, not distinct `Array` types. The
unrelated 32 source schemas in the final fixture initially have empty targets.
The clearest width exposure is the scenario metadata:

| Source | Type-width surface |
| --- | --- |
| [registry_topology.jl:552](../../../src/composite_model/registry_topology.jl#L552) | Authored application tuples first become `Vector{Any}`. |
| [compilation.jl:565](../../../src/composite_model/compilation.jl#L565) | Application schedule entries/indices become tuples whose lengths follow the scenario. |
| [compilation.jl:595](../../../src/composite_model/compilation.jl#L595) | Per-application plan groups and application lookup become application-name-keyed `NamedTuple`s. |
| [compilation.jl:609](../../../src/composite_model/compilation.jl#L609) | Call-owner lookup similarly encodes all application names. |
| [compilation.jl:1044](../../../src/composite_model/compilation.jl#L1044) | Application children become a name-keyed `NamedTuple` of dependency tuples. |
| [compilation.jl:1094](../../../src/composite_model/compilation.jl#L1094) | `CompiledScenarioPlan` combines application-plan tuples, keyed metadata, input/call-plan tuples and ordered plans. |
| [runtime_outputs.jl:1300](../../../src/composite_model/runtime_outputs.jl#L1300) | `Simulation` carries its compiled representation as a type parameter, exposing the nested scenario shape to specialized consumers. |

Thus varying application count, names and binding shapes can introduce several
new nested types even when scientific model and organ-state types stay simple.
This is a source-based candidate for compiler work. No profile or timing here
attributes the observed delay to tuple width, inference, invalidation, output
retention, or any particular function.

## Minimal next experiments

1. **Separate source copies first.** Keep A as the exact selected ordinary
   baseline and B as A plus PR243 and the two-line generic adapter. Record
   source hashes and use a fresh Kaimon process for each layout. Verify
   `pkgdir(PlantSimEngine)`, active project and exact Julia version before any
   measurement. A supported older Julia and 1.13.3 would be a later controlled
   comparison, not an assumed match to the local 1.13.1 process.

2. **Probe dispatch before compiling a downstream stack.** In the isolated
   candidate, use one custom `AbstractExecutionBatch` with counter-based
   ordinary/profiled numerical methods. Exercise both group paths and one
   ordinary batch. The unadapted PR should fail at the scheduled barrier for
   the custom batch; the adapted PR should invoke each method once. Use a
   genuine `RuntimePerformanceCounters` for the profiled path.

3. **Reduce the metadata diagnostic to one fixture case.** Begin with
   `Float64`, inferred inputs, count 1. Flush markers around construction,
   application/declaration planning, `run!(steps=0)`, and the first `step!`.
   Record compile time, elapsed time and allocations separately. This is a
   diagnostic derived from the fixture, not a pass of its unchanged testset.
   After it completes, increase only count to 8, then 32; stop at the first
   stage that exceeds a 60–90 second post-import budget. Do not restart the
   twelve-case whole-file run to locate a single slow stage.

4. **Distinguish outputs and scenario width only if necessary.** On the
   smallest slow count, compare `outputs=:none` with `:all` using identical
   topology/models and fresh simulations. Then compare compile-only planning
   with first execution. If evidence implicates wide scenario metadata, test
   a copied-tree alternative with stable containers for cold graph metadata
   while keeping concrete numerical batch payloads. No such representation
   change is implemented or qualified by this note.

5. **Run focused semantics after dispatch/compilation is bounded.** Prioritize
   complete retained-Many growth/removal/reparenting and cache-reentry cases
   from [reusable-call-targets](../../../test/test-model-reusable-call-targets.jl#L148)
   and [call-context-cache](../../../test/test-model-call-context-cache.jl#L274),
   plus the four complete top-level individual-environment testsets. Use
   persistent per-testset markers, proper fd-backed test streams and compact
   results. Split the PR's constprop, mutable status-view layout, target-count
   cache and scheduled barrier only after a minimal slow case exists. No
   full-suite or three-hour rerun is needed to start this investigation.

The retained-result and singleton-Many experimental fallback checks are
separately defined in
[shared_tight_fallback_checks.jl](../../native_downstream/shared_tight_fallback_checks.jl).
Their source availability is not a runtime pass.

## Reviewed source provenance

- Supplied PR243 diff SHA256:
  `302856a38b6962f4fb502aa1079c37542d99e1b47c92ec10554ba4202fd97452`.
- Supplied complete CI log SHA256:
  `4cd6b3c744188a5de6b12eab2a37eca098b571670f86937e360898febb19dea4`.
- Independent adapter SHA256:
  `5f05f520b903075b798647a10502bc8224408940bca8ed65938c9b94566840ce`.
- Reviewed input-plan metadata test SHA256:
  `dcf21206bb7d0270a5ee021256107b0f2cc0384edf3b5f5b5db2dc43c7162676`.
- Reviewed current compilation source SHA256:
  `070c379c463e7788d909eb7f813b3e886b03f78af1ce644e6203cc9d76585e75`.

Code links and line numbers describe this reviewed snapshot; subsequent source
changes require fresh provenance. The independent adapter and diagnostic plan
have source-only status.
