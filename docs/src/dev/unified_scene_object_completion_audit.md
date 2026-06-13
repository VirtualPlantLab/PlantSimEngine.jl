# Unified Scene/Object Completion Audit

This audit records the evidence used to assess the breaking scene/object
redesign against `unified_scene_object_design.md` and
`unified_scene_object_implementation_plan.md`.

Audit date: June 12, 2026.

## Result

The unified scene/object redesign is implemented as the primary public
configuration API.

The retained mapping implementation forms an explicitly qualified
compatibility and regression layer. The unreleased domain prototype was
removed after the scene/object runtime replaced it.

## Public Contract

The exported scenario vocabulary centers on:

```julia
Scene
Object
ModelSpec
AppliesTo
Inputs
Calls
Updates
TimeStep
Environment
```

Legacy scenario constructors such as `ModelMapping` and `MultiScaleModel` are
not exported.

Evidence:

- `src/PlantSimEngine.jl`
- `docs/src/API/API_public.md`
- `docs/src/migration_scene_object.md`
- `README.md`

## Requirement Evidence

| Requirement | Evidence |
| --- | --- |
| One scene object registry without prescribing plant topology | `Scene`, `Object`, selectors, relations, scopes, and `objects_from_mtg` in `src/scene_object_api.jl`; selector and MTG adapter tests in `test/test-unified-scene-object-api.jl` |
| Reusable species models and repeated plant instances | `ObjectTemplate`, `ObjectInstance`, `Override`, shared model ownership, and homogeneous/heterogeneous batches; four-instance and override tests |
| Soft/value dependencies | Compiled `Inputs(...)` bindings, same-object inference, scalar references, `RefVector`, `ObjectRefVector`, temporal carriers, renaming, and optional inputs |
| Manual hard dependencies | Compiled `Calls(...)`, `SceneCallTarget`, `call_target(s)`, and `run_call!`; trial calls default to `publish=false` and accepted calls publish explicitly |
| Model-author dependency defaults | `Input(...)` and `Call(...)` entries from `dep(model)`, with `ModelSpec` overrides and binding provenance in explanations |
| Multirate execution | `TimeStep(Dates.Period)`, model `timespec`, input policies, explicit windows, `PreviousTimeStep`, and stable compiled scheduling |
| Generic value types | Reference and temporal tests using `SceneObjectDualLike{BigFloat}` and `BigFloat` interpolation/integration without `Float64` conversion |
| Reference semantics and low-copy execution | Shared scalar references, typed many-object carriers, preinstalled status bindings, zero-allocation materialization tests, and a zero-allocation warmed 128-object execution batch |
| Duplicate writers | Canonical writer validation and `Updates(:variable; after=...)`, including pruning-after-allocation tests |
| Growth, pruning, reparenting, and movement | Central lifecycle APIs, structural/environment cache invalidation, dynamic target/carrier rebuilding, removed-object output history, and object-scoped geometry refresh tests |
| Automatic meteorology and microclimate | `meteo_inputs_`, `meteo_outputs_`, global and spatial backends, ancestor geometry fallback, source remapping, model hints, tabular aggregation, cached bindings, and mutable backend scattering |
| Structured agent explanations | Object, instance, scope, application, binding, call, model-bundle, environment, schedule, writer, execution-plan, output, and retention explanations returning structured rows |
| Output ownership and retention | Application-qualified streams, `OutputRouting`, `OutputRequest(application=...)`, dynamic-object exports, and bounded policy-specific dependency histories |
| MAESPA acceptance case | `build_maespa_scene` and `run_maespa_example` use `ObjectTemplate`, `ObjectInstance`, `AppliesTo`, `Inputs`, `Calls`, and `TimeStep`; verified by `test/test-maespa-scene-example.jl` |
| Documentation and migration | Scene/object-first README, home page, quickstart, execution guide, public API, migration guide, and explicitly labeled legacy reference sections |

## Verification

The following gates passed from a clean, controllable Kaimon Julia session:

```text
test/test-unified-scene-object-api.jl
test/test-maespa-scene-example.jl
test/test-multirate-output-export.jl
test/runtests.jl
docs/make.jl
git diff --check
```

The complete package suite finished successfully in approximately ten minutes.
The documentation build, including examples and doctests, also completed
successfully.

`Aqua.jl` was not installed in the active environment, so the optional
`lint_package` gate could not be run. This is not a package test dependency and
does not weaken the behavioral verification above.

## Compatibility Boundary

Historical mapping source and tests remain intentionally available for:

- migration comparison;
- regression evidence;
- downstream users that need a qualified transition path.

They must remain qualified as `PlantSimEngine.*` and must not be presented as
the primary API. The branch-only domain prototype and its tests were removed
because they were never released and no longer serve as a compatibility
boundary.

Requested output histories are still materialized after a run. Dependency-only
temporal histories are bounded, but a fully online output sink would be an
additional optimization rather than a missing requirement of this redesign.
