# PlantSimEngine Agent And Developer Guide

PlantSimEngine composes process models over a unified composite-model/object registry.
The repository contains one scenario compiler and runtime: the composite-model/object
API.

## Core Model Contract

- Every model subtypes `AbstractModel`.
- `@process` defines the abstract process type.
- `process(model)` identifies the process.
- `inputs_(model)` and `outputs_(model)` declare status variables.
- `environment_inputs_(model)` and `environment_outputs_(model)` declare environment
  variables.
- `dep(model)` optionally returns model-author defaults using `Input(...)` and
  `Call(...)`.
- Kernels implement:

```julia
PlantSimEngine.run!(model, status, environment, constants, context)
```

Read the current model's parameters directly from `model`. `context` is a
`RunContext` and provides `run_call!`, `call_targets`, and lifecycle access.

## CompositeModel Structure

- `CompositeModel` owns a `ObjectRegistry`, model applications, instances, and an
  environment.
- `Object` is one runtime entity with stable `ObjectId`, labels, parent,
  geometry, and `Status`.
- Plant architecture is not prescribed. Users choose scales and topology.
- `CompositeModelTemplate` and `ObjectInstance` reuse the same model definitions across
  several plants or objects.
- `Override` replaces one application model for selected objects without
  splitting the logical application.
- `objects_from_mtg` and `CompositeModel(mtg; ...)` adapt MTG topology into the same
  registry.

## Model Applications

Use one configuration grammar:

```julia
ModelSpec(model; name=:application, on=selector, inputs=(...), calls=(...), every=Dates.Hour(1), environment=Environment(...))
```

- `on` selects where the model runs.
- `inputs` declares value dependencies.
- `calls` declares manually executable hard dependencies.
- `Updates(:x; after=:producer)` orders intentional duplicate writers.
- `output_routing=(x=:stream_only,)` excludes an output from canonical
  ownership while retaining its stream.

## Selectors

Multiplicity:

- `One(...)`
- `OptionalOne(...)`
- `Many(...)`

Scope and topology:

- `SceneScope()`
- `Self()`: the current object
- `Subtree()`: the current object and its descendants
- `SelfPlant()`: the current plant instance/root
- `Ancestor(...)`
- `Scope(name)`
- `Relation(...)`

Use keyword criteria for object labels: `kind=:plant`, `species=:oil_palm`,
`scale=:Leaf`, and `name=:leaf_1`.

`Self()` never means the model, species, or plant unless the current object is
itself that plant.

## Value Coupling

The compiler resolves `ModelSpec(...; inputs=...)` to reference carriers:

- one source uses a shared `Ref`;
- many homogeneous sources use `RefVector`;
- heterogeneous sources use `ObjectRefVector`;
- temporal policies read typed output streams.

Use `Diagnostics.input_carrier`, `Diagnostics.input_value`, `Diagnostics.explain_bindings`, and
`Diagnostics.has_reference_carrier` instead of inspecting internal fields.

Same-object input/output matches are inferred when unique. Cross-object
coupling should be explicit with `ModelSpec(...; inputs=...)`.

## Hard Calls

Hard dependencies are parent-controlled:

1. Declare them with model-level `Call(...)` or scenario-level `ModelSpec(...; calls=...)`.
2. Execute all resolved targets with `run_call!(context, name)`. It always
   returns a vector-like `CallTargets` collection.
3. For selective or iterative execution, inspect `call_targets(context, name)`
   and execute individual `CallTarget`s with `run_call!`.

`run_call!` defaults to `publish=false`, which is appropriate for iterative
trial states. Publish only the accepted state with `publish=true`.

Applications used exclusively as call targets are not run by the root
scheduler and do not receive inferred soft bindings.

## Time

- `ModelSpec(...; every=Dates.Period)` configures application cadence.
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
- Spatial object-to-environment handles are compiled and cached.
- `move_object!`, `update_geometry!`, or
  `mark_environment_binding_dirty!` invalidate affected bindings.
- `run_call!(context, name; environment=trial_state)` samples transient
  backend-specific state through each target's compiled handle.
- `environment_outputs_` declares environment variables a controller may commit, and
  `commit_environment!` commits only the accepted state.

## Lifecycle

- `add_organ!` is the high-level operation for MTG-backed growth. It creates
  the node, reuses the model's MTG status policy, applies initial values,
  attaches the status, and registers the object.
- `register_object!`, `remove_object!`, and `reparent_object!` mutate topology.
- Use `register_object!` directly only when the caller already owns a fully
  initialized `Object`.
- Structural changes refresh application targets, value carriers, call
  targets, writer checks, and schedules after the application that made the
  change; new objects can run applications that remain later in the timestep.
- Geometry changes refresh only affected environment bindings when possible.
- Removed objects keep their historical output samples.

## Outputs

- `run!(model; outputs=:none)` starts a fresh timeline and returns
  `Simulation`; use `outputs=:all` or output requests to retain streams.
- `continue!(simulation)` and `step!(simulation)` advance the same timeline.
- `final_state(simulation)` returns the latest one-object status snapshot;
  pass an object id or selector for multi-object simulations.
- `outputs(sim)` exposes retained typed streams.
- `OutputRequest` selects retained/resampled outputs.
- `collect_outputs(sim)` materializes output rows.
- `Diagnostics.explain_output_retention(sim)` reports why each stream is retained.

Streams are keyed by application, object, and variable so repeated processes do
not overwrite each other.

## Performance Rules

- Keep model parameters and status values generic; do not force `Float64`.
- Preserve concrete model, status, carrier, and stream types.
- Do not copy values when a reference carrier is sufficient.
- Keep dynamic dispatch at compiled batch boundaries, not per object.
- Preserve cached hard-call targets and homogeneous execution batches.
- Test allocations for hot loops that run over many organs.

## High-Signal Files

- `src/composite_model_api.jl`: dependency-ordered include boundary for the sole
  CompositeModel/Object compiler and runtime.
- `src/composite_model/registry_topology.jl`: objects, registry, templates,
  instances, overrides, topology, and lifecycle ownership.
- `src/composite_model/selectors.jl`: selector normalization and resolution.
- `src/composite_model/compilation.jl`: applications, carriers, calls, writer
  validation, schedules, and structured compilation explanations.
- `src/composite_model/environment_bindings.jl`: global/spatial environment
  bindings and invalidation.
- `src/composite_model/runtime_outputs.jl`: execution, temporal streams, hard-call
  publication, retention, and output collection.
- `src/composite_model/scenario_dsl.jl`: small scenario construction helpers.
- `src/ModelSpec.jl`: model application configuration.
- `src/component_models/Status.jl`: reference-based status.
- `src/component_models/RefVector.jl`: homogeneous reference vectors.
- `src/time/multirate.jl`: clocks and temporal policies.
- `src/time/runtime/clocks.jl`: Dates-based timing.
- `src/time/runtime/environment_sampling.jl`: model-facing environment sampling.
- `src/time/runtime/environment_backends.jl`: environment backend contract.
- `test/test-unified-model-object-api.jl`: broad integration coverage.
- `test/test-model-*.jl`: focused CompositeModel/Object behavioral contracts.

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

## API evolution policy

This project is in active development and has no stable public API yet.

When implementing API changes:

- Do not preserve backward compatibility unless explicitly requested.
- Do not add deprecated aliases, compatibility wrappers, fallback methods, old keyword support, migration layers, or dual APIs.
- Prefer a clean breaking change over supporting both old and new APIs.
- Update all internal call sites, tests, and documentation to the new API.
- Remove obsolete code instead of keeping it.
- If existing tests fail because they expect the old API, update the tests to match the new API.
- Before adding compatibility code, stop and ask for confirmation.
