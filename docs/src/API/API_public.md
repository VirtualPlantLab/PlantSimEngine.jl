# Public API

## Unified CompositeModel/Object API

### Scenario and model applications

- `CompositeModel` stores objects, model applications, instances, and environment.
- `CompositeModel(model, models...; status=..., timestep=...)` is the concise one-object
  form and lowers to the same object/application representation.
- `Object` represents one runtime entity with stable identity and status.
- `CompositeModelTemplate` and `ObjectInstance` reuse a model across instances.
- `ModelSpec(model; name=..., on=..., inputs=..., calls=..., every=...,
  environment=..., output_routing=..., updates=...)` is the one application
  construction form.

### Coupling

- `ModelSpec(...; inputs=...)` declares value dependencies.
- `ModelSpec(...; calls=...)` declares manually executable child models.
- `Updates(:variable; after=:application_id)` orders intentional duplicate writers.
- `Input(...)` and `Call(...)` express model defaults through `dep(model)`.
- `run_call!(context, :name; publish=false)` executes every resolved hard-call
  target and always returns a vector-like `CallTargets` collection.
- `run_call!(context, :name; sampled_environment=value)` forwards one already
  sampled model-facing environment through cached typed execution batches.
- `call_model(context, :name)` returns the concrete model when a call resolves
  to exactly one target.
- `call_targets(context, :name)` returns the same non-executing collection for
  fine-grained execution with `run_call!(target; ...)`.

### Model input schema

- `Required(T)` declares an input that object state or another application must
  supply. `T` is an expected type and may be generic.
- `Default(value)` declares a true model fallback that needs no user
  initialization.
- `inputs_(model)` uses only these explicit declarations; plain literals are
  rejected.
- `outputs_(model)` literals remain initial output-state values.
- `init_variables(model)` returns only genuine input defaults and initial
  output values.

### Selectors

- Multiplicity: `One(...)`, `OptionalOne(...)`, and `Many(...)`.
- Scope: `SceneScope()`, `Self()`, `Subtree()`, `SelfPlant()`,
  `Ancestor(...)`, and `Scope(name)`.
- Label criteria: `kind=...`, `species=...`, `scale=...`, and `name=...`.
- Topology relations: `Relation(...)`.

`Self()` always means the current object: the object on which the consuming
application runs. It means a plant only when that object is itself the plant.

Selector fields are checked where the selector is used:

| Context | Accepted criteria |
|---|---|
| `ModelSpec(...; on=...)` | `kind`, `species`, `scale`, `name`, and a scene or named scope |
| `ModelSpec(...; inputs=...)` | object criteria plus `process`, `application`, `var`, `policy`, `window`, `from_status`, and `after` |
| `ModelSpec(...; calls=...)` | object criteria plus `process` and `application` |
| object queries and `OutputRequest` selectors | object criteria only |

Unsupported or misspelled fields fail when the selector is constructed.
Object-relative scopes and relations require a current object, so they belong
in inputs, calls, or contextual object/output queries rather than application
targets.

### Time and environment

- `ModelSpec(...; every=period)` sets an application cadence.
- `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` define temporal
  input policies.
- `Environment(...)` configures environment providers and source remapping.
- Models declare sampled environment variables with `environment_inputs_`.
- Mutable environment controllers pass trial state with
  `run_call!(context, name; environment=trial_state)` and commit accepted state
  with `commit_environment!`.
- `OutputRequest(selector, variable; ...)` selects retained and optionally
  resampled streams using the same object selector grammar.

### Lifecycle

- `objects_from_mtg` and `CompositeModel(mtg; ...)` adapt an MTG into the object
  registry.
- `add_organ!` creates and initializes a new organ in an MTG-backed model.
- `runtime_model(context)` gives lifecycle-capable kernels sanctioned access to
  the live model from their `RunContext`.
- `register_object!`, `remove_object!`, and `reparent_object!` change
  topology.
- `move_object!` and `update_geometry!` change spatial state.
- Supported lifecycle operations automatically invalidate and refresh the
  affected structural or spatial bindings before the next timestep.
- `run!(model; steps=..., outputs=:none)` starts a fresh result timeline and
  returns a `Simulation`.
- `continue!(simulation; steps=...)` and `step!(simulation)` advance an
  existing timeline without resetting temporal state.
- `current_step(simulation)` reports the accepted timeline position.
- `final_state(simulation)` returns a latest-state snapshot without
  requiring output retention; pass an object id or selector for multi-object
  simulations.
- `collect_outputs(sim)` materializes retained output streams.

### Explanations

Use the `Diagnostics` namespace instead of inspecting internals:

- `Diagnostics.explain_objects`
- `Diagnostics.explain_instances`
- `Diagnostics.explain_scopes`
- `Diagnostics.explain_applications`
- `Diagnostics.explain_bindings`
- `Diagnostics.explain_calls`
- `Diagnostics.explain_environment_bindings`
- `Diagnostics.explain_schedule`
- `Diagnostics.explain_writers`
- `Diagnostics.explain_execution_plan`
- `Diagnostics.explain_output_retention`
- `Diagnostics.explain_outputs`
- `Diagnostics.explain_initialization`
- `Diagnostics.input_carrier`, `Diagnostics.input_value`, and
  `Diagnostics.has_reference_carrier`
- `Diagnostics.object_address`

### Readable generated source

- `compile_model_source(model; function_name=:compiled_model!)` translates a
  resolved `CompositeModel` into deterministic, human-oriented Julia source.
- `compile_model_source(simulation; ...)` uses an existing simulation's
  resolved scenario and defines an entry point that can continue it.
- `write_compiled_model(path, model; ...)` writes the same source to a loadable
  `.jl` file.

This is an explanatory source generator, distinct from
`Advanced.compile_composite_model`, which builds the optimized runtime plan.
See [Generate readable model source](../guides/readable_model_source.md) for the
complete workflow and supported source shapes.

See [Migrating To The CompositeModel/Object API](../migration_composite_model.md) for
translations from removed APIs.

### CompositeModel graph visualization and editing

- `GraphEditor.compile_model_report(model; strict=false)` preserves partial graph state and
  structured diagnostics for incomplete or cyclic composite models.
- `GraphEditor.model_graph_view(model; level=:applications)` returns the typed graph view.
- `GraphEditor.model_graph_view_json(model)` serializes the same DTO used by the browser.
- `GraphEditor.write_model_graph_view(path, model)` writes a self-contained static viewer.
- `GraphEditor.edit_graph(model; templates=..., environments=...)` starts the optional HTTP editor after `using HTTP` and keeps catalog values authoritative in Julia.
- `GraphEditor.current_model(session)`, `GraphEditor.undo!(session)`,
  `GraphEditor.redo!(session)`, and `close(session)` control an interactive
  session from Julia.

See [Visualize And Edit A CompositeModel](../guides/graph_visualizer_editor.md) for the
runnable workflow, model discovery, selector previews, cycle breaking, and
Documenter embedding.

### Environment backend extensions

Backend packages extend the protocol under `EnvironmentAPI`, including
`EnvironmentAPI.AbstractEnvironmentBackend`,
`EnvironmentAPI.bind_environment`, `EnvironmentAPI.sample`,
`EnvironmentAPI.commit_environment!`, and `EnvironmentAPI.update_index!`.
The root-level `commit_environment!` remains part of the ordinary model-kernel
workflow for committing an accepted controller state.

### Fitting and evaluation

Generic fitting and metrics live under `Evaluation`: `Evaluation.fit`,
`Evaluation.RMSE`, `Evaluation.NRMSE`, `Evaluation.EF`, and `Evaluation.dr`.
PlantMeteo reducers are accessed from `PlantMeteo` directly rather than being
re-exported by PlantSimEngine.

## Advanced compiler API

```@docs
PlantSimEngine.Advanced
```

Compiler representations, cache refresh operations, and low-level binding
compilers live under `PlantSimEngine.Advanced`. They are intended for package
integration, diagnostics development, and compiler work rather than ordinary
scenario composition. Prefer `Diagnostics.explain_*`, which accepts a
`CompositeModel` directly, over manually compiling and inspecting fields.

Examples include `Advanced.compile_composite_model`, `Advanced.refresh_bindings!`, and
the `Advanced.CompiledCompositeModel` family. These qualified APIs may evolve more
quickly than the default modeling interface.

## Index

```@index
Pages = ["API_public.md"]
```

## API Documentation

```@autodocs
Modules = [
    PlantSimEngine,
    PlantSimEngine.Diagnostics,
    PlantSimEngine.GraphEditor,
    PlantSimEngine.EnvironmentAPI,
    PlantSimEngine.Evaluation,
]
Private = false
```
