# Public API

## Unified Scene/Object API

### Scenario and model applications

- `Scene` stores objects, model applications, instances, and environment.
- `Object` represents one runtime entity with stable identity and status.
- `ObjectTemplate` and `ObjectInstance` reuse a model across instances.
- `ModelSpec(model; name=...)` identifies one model application.
- `AppliesTo(...)` selects its target objects.

### Coupling

- `Inputs(...)` declares value dependencies.
- `Calls(...)` declares manually executable child models.
- `Updates(:variable; after=...)` orders intentional duplicate writers.
- `Input(...)` and `Call(...)` express model defaults through `dep(model)`.
- `run_call!(target; publish=false)` executes a trial hard call.

### Selectors

- Multiplicity: `One(...)`, `OptionalOne(...)`, and `Many(...)`.
- Scope: `SceneScope()`, `Self()`, `SelfPlant()`, `Ancestor(...)`, and
  `Scope(name)`.
- Labels and topology: `Kind(...)`, `Species(...)`, `Scale(...)`, and
  `Relation(...)`.

### Time and environment

- `TimeStep(period)` sets an application cadence.
- `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` define temporal
  input policies.
- `Environment(...)` configures environment providers and source remapping.
- Models declare environment variables with `meteo_inputs_` and
  `meteo_outputs_`.
- `OutputRequest(...)` selects retained and resampled scene output streams.

### Lifecycle

- `objects_from_mtg` and `Scene(mtg; ...)` adapt an MTG into the object
  registry.
- `register_object!`, `remove_object!`, and `reparent_object!` change
  topology.
- `move_object!` and `update_geometry!` change spatial state.
- `refresh_bindings!` recompiles structural bindings.
- `refresh_environment_bindings!` recompiles spatial environment bindings.
- `run!(scene; steps=...)` returns a `SceneSimulation`.
- `collect_outputs(sim)` materializes retained output streams.

### Explanations

Use structured explanation helpers instead of inspecting internals:

- `explain_objects`
- `explain_instances`
- `explain_scopes`
- `explain_scene_applications`
- `explain_bindings`
- `explain_calls`
- `explain_environment_bindings`
- `explain_schedule`
- `explain_writers`
- `explain_model_bundles`
- `explain_execution_plan`
- `explain_output_retention`
- `explain_outputs`

See [Migrating To The Scene/Object API](../migration_scene_object.md) for
translations from removed APIs.

## Index

```@index
Pages = ["API_public.md"]
```

## API Documentation

```@autodocs
Modules = [PlantSimEngine]
Private = false
```
