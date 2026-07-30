# Unified CompositeModel/Object Completion Audit

This audit records the evidence used to assess the breaking composite-model/object
redesign against `composite_model_design.md` and
`composite_model_implementation_plan.md`.

Audit date: June 12, 2026.

## Result

The unified composite-model/object redesign is implemented as the primary public
configuration API.

The superseded mapping implementation and the unreleased intermediate
prototype were removed after the composite-model/object runtime replaced them.

## Public Contract

The exported scenario vocabulary centers on:

```julia
CompositeModel
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

Legacy scenario constructors such as `ModelMapping` and `MultiScaleModel` were
removed.

Evidence:

- `src/PlantSimEngine.jl`
- `docs/src/API/API_public.md`
- `docs/src/migration_composite_model.md`
- `README.md`

## Requirement Evidence

| Requirement | Evidence |
| --- | --- |
| One model object registry without prescribing plant topology | `CompositeModel`, `Object`, selectors, relations, scopes, and `objects_from_mtg` in `src/composite_model_api.jl`; selector and MTG adapter tests in `test/test-unified-model-object-api.jl` |
| Reusable species models and repeated plant instances | `CompositeModelTemplate`, `ObjectInstance`, `Override`, shared model ownership, and homogeneous/heterogeneous batches; four-instance and override tests |
| Soft/value dependencies | Compiled `Inputs(...)` bindings, same-object inference, scalar references, `RefVector`, `Advanced.ObjectRefVector`, temporal carriers, renaming, and optional inputs |
| Manual hard dependencies | Compiled `Calls(...)`, vector-like `CallTargets`, `run_call!(context, name)`, and fine-grained `run_call!(target)`; trial calls default to `publish=false` and accepted calls publish explicitly |
| Model-author dependency defaults | `Input(...)` and `Call(...)` entries from `dep(model)`, with `ModelSpec` overrides and binding provenance in explanations |
| Multirate execution | `TimeStep(Dates.Period)`, model `timespec`, input policies, explicit windows, `PreviousTimeStep`, and stable compiled scheduling |
| Generic value types | Reference and temporal tests using `ModelObjectDualLike{BigFloat}` and `BigFloat` interpolation/integration without `Float64` conversion |
| Reference semantics and low-copy execution | Shared scalar references, typed many-object carriers, preinstalled status bindings, zero-allocation materialization tests, and a zero-allocation warmed 128-object execution batch |
| Duplicate writers | Canonical writer validation and `Updates(:variable; after=...)`, including pruning-after-allocation tests |
| Growth, pruning, reparenting, and movement | Central lifecycle APIs, structural/environment cache invalidation, dynamic target/carrier rebuilding, removed-object output history, and object-scoped geometry refresh tests |
| Automatic meteorology and microclimate | `environment_inputs_`, global and spatial backends, ancestor geometry fallback, source remapping, model hints, tabular aggregation, cached opaque handles, `run_call!(...; environment=trial_state)` trial sampling, and `commit_environment!` accepted mutable commits |
| Structured agent explanations | Object, instance, scope, application, binding, call, model-bundle, environment, schedule, writer, execution-plan, output, and retention explanations returning structured rows |
| Initialization workflow | `Required(T)` and `Default(value)` make the input contract explicit; `explain_initialization` classifies required, defaulted, supplied, generated, producer-bound, and environment-bound variables before strict compilation |
| Runtime model access | `runtime_model` is the public accessor used by lifecycle-capable kernels and accepts `CompositeModel`, `RunContext`, and `Simulation` |
| One-object ergonomics | `CompositeModel(model, models...; status=...)` lowers to the same object/application compiler and runtime as explicit construction |
| Output ownership and retention | Application-qualified streams, `OutputRouting`, `OutputRequest(application=...)`, dynamic-object exports, and bounded policy-specific dependency histories |
| MAESPA acceptance case | `build_maespa_scene` and `run_maespa_example` use `CompositeModelTemplate`, `ObjectInstance`, `AppliesTo`, `Inputs`, `Calls`, and `TimeStep`; verified by `test/test-maespa-model-example.jl` |
| Documentation and migration | CompositeModel/object-first README, home page, quickstart, execution guide, public API, migration guide, and explicitly labeled legacy reference sections |

## Verification

The following gates passed from a clean, controllable Kaimon Julia session:

```text
test/test-unified-model-object-api.jl  576 passed
test/runtests.jl                       885 passed
docs/make.jl                           passed
PlantBiophysics/test/runtests.jl       117 passed
git diff --check                       passed
```

The complete package suite includes Aqua, all focused restoration files, the
broad unified runtime regression, examples, fitting, and doctests. The
documentation build completed its executable examples, doctests,
cross-references, document checks, and HTML rendering successfully.

The current uncommitted XPalm CompositeModel/Object migration loads this PlantSimEngine
worktree and executes 74 of 75 downstream assertions. Its remaining assertion
expects the removed runtime's first-step LAI (`0.000272`); the current compiled
dependency order correctly runs leaf area before plant and model aggregation,
so the initial zero-biomass leaf produces `0.0`. This is a downstream fixture
expectation in a dirty migration worktree, not a package-specific behavior to
restore in PlantSimEngine. No XPalm workaround was added here.

## Compatibility Boundary

Historical mapping source and tests were removed. Migration guidance remains
in the documentation for downstream packages moving to the composite-model/object API.
The branch-only intermediate prototype was also removed because it was never
released and has no compatibility boundary.

Requested output histories are still materialized after a run. Dependency-only
temporal histories are bounded, but a fully online output sink would be an
additional optimization rather than a missing requirement of this redesign.
