# PlantSimEngine Agent And Developer Guide

PlantSimEngine composes process models over a unified scene/object registry.
The repository contains one scenario compiler and runtime: the scene/object
API.

## Core Model Contract

- Every model subtypes `AbstractModel`.
- `@process` defines the abstract process type.
- `process(model)` identifies the process.
- `inputs_(model)` and `outputs_(model)` declare status variables.
- `meteo_inputs_(model)` and `meteo_outputs_(model)` declare environment
  variables.
- `dep(model)` optionally returns model-author defaults using `Input(...)` and
  `Call(...)`.
- Kernels implement:

```julia
PlantSimEngine.run!(model, models, status, meteo, constants, extra)
```

`models` is a process-keyed bundle compiled from `Calls(...)`. `extra` is a
`SceneRunContext` and provides `call_target`, `call_targets`, and lifecycle
access.

## Scene Structure

- `Scene` owns a `SceneRegistry`, model applications, instances, and an
  environment.
- `Object` is one runtime entity with stable `ObjectId`, labels, parent,
  geometry, and `Status`.
- Plant architecture is not prescribed. Users choose scales and topology.
- `ObjectTemplate` and `ObjectInstance` reuse the same model definitions across
  several plants or objects.
- `Override` replaces one application model for selected objects without
  splitting the logical application.
- `objects_from_mtg` and `Scene(mtg; ...)` adapt MTG topology into the same
  registry.

## Model Applications

Use one configuration grammar:

```julia
ModelSpec(model; name=:application) |>
AppliesTo(selector) |>
Inputs(...) |>
Calls(...) |>
TimeStep(Dates.Hour(1)) |>
Environment(...)
```

- `AppliesTo` selects where the model runs.
- `Inputs` declares value dependencies.
- `Calls` declares manually executable hard dependencies.
- `Updates(:x; after=:producer)` orders intentional duplicate writers.
- `OutputRouting(; x=:stream_only)` excludes an output from canonical
  ownership while retaining its stream.

## Selectors

Multiplicity:

- `One(...)`
- `OptionalOne(...)`
- `Many(...)`

Scope and topology:

- `SceneScope()`
- `Self()`: the current object
- `SelfPlant()`: the current plant instance/root
- `Ancestor(...)`
- `Scope(name)`
- `Kind(...)`, `Species(...)`, `Scale(...)`, `Relation(...)`

`Self()` never means the model, species, or plant unless the current object is
itself that plant.

## Value Coupling

The compiler resolves `Inputs(...)` to reference carriers:

- one source uses a shared `Ref`;
- many homogeneous sources use `RefVector`;
- heterogeneous sources use `ObjectRefVector`;
- temporal policies read typed output streams.

Use `input_carrier`, `input_value`, `explain_bindings`, and
`has_reference_carrier` instead of inspecting internal fields.

Same-object input/output matches are inferred when unique. Cross-object
coupling should be explicit with `Inputs(...)`.

## Hard Calls

Hard dependencies are parent-controlled:

1. Declare them with model-level `Call(...)` or scenario-level `Calls(...)`.
2. Resolve a compiled target with `call_target(extra, name)` or
   `call_targets(extra, name)`.
3. Execute it with `run_call!`.

`run_call!` defaults to `publish=false`, which is appropriate for iterative
trial states. Publish only the accepted state with `publish=true`.

Applications used exclusively as call targets are not run by the root
scheduler and do not receive inferred soft bindings.

## Time

- `TimeStep(Dates.Period)` configures application cadence.
- `timespec(model)` provides a model default.
- `timestep_hint(model)` validates compatibility when cadence comes from the
  environment base step.
- `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` configure temporal
  input policies.
- `PreviousTimeStep(:x)` breaks same-step cycles.

Dates periods are converted using meteorology `duration`. Model code should not
know its scenario timestep unless the scientific model explicitly requires it.

## Environment

- `Environment(...)` configures provider selection and source remapping.
- Global meteorology and spatial backends use the same model-facing contract.
- Spatial object-to-cell bindings are compiled and cached.
- `move_object!`, `update_geometry!`, or
  `mark_environment_binding_dirty!` invalidate affected bindings.
- `scatter_environment_outputs!` writes model-produced microclimate variables
  back to mutable backends.

## Lifecycle

- `register_object!`, `remove_object!`, and `reparent_object!` mutate topology.
- Structural changes refresh application targets, value carriers, call
  targets, writer checks, and schedules between timesteps.
- Geometry changes refresh only affected environment bindings when possible.
- Removed objects keep their historical output samples.

## Outputs

- `run!(scene)` returns `SceneSimulation`.
- `scene_outputs(sim)` exposes retained typed streams.
- `OutputRequest` selects retained/resampled outputs.
- `collect_outputs(sim)` materializes output rows.
- `explain_output_retention(sim)` reports why each stream is retained.

Streams are keyed by application, object, and variable so repeated processes do
not overwrite each other.

## Performance Rules

- Keep model parameters and status values generic; do not force `Float64`.
- Preserve concrete model, status, carrier, and stream types.
- Do not copy values when a reference carrier is sufficient.
- Keep dynamic dispatch at compiled batch boundaries, not per object.
- Preserve cached model bundles and homogeneous execution batches.
- Test allocations for hot loops that run over many organs.

## High-Signal Files

- `src/scene_object_api.jl`: registry, selectors, compilation, execution,
  lifecycle, hard calls, temporal streams, and output collection.
- `src/ModelSpec.jl`: model application configuration.
- `src/component_models/Status.jl`: reference-based status.
- `src/component_models/RefVector.jl`: homogeneous reference vectors.
- `src/time/multirate.jl`: clocks and temporal policies.
- `src/time/runtime/clocks.jl`: Dates-based timing.
- `src/time/runtime/meteo_sampling.jl`: weather sampling.
- `src/time/runtime/environment_backends.jl`: environment backend contract.
- `test/test-unified-scene-object-api.jl`: primary behavioral coverage.

## Change Checklist

When changing compilation or runtime behavior, verify:

1. one object and many objects;
2. same-object and cross-object inputs;
3. `One`, `OptionalOne`, and `Many`;
4. hard calls and iterative publication;
5. duplicate writers and `Updates`;
6. multirate policies and `PreviousTimeStep`;
7. global and spatial environments;
8. object creation, removal, reparenting, and movement;
9. templates, instances, and overrides;
10. generic numeric types and allocation-sensitive execution.
