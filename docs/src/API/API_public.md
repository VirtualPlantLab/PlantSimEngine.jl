# Public API

## Unified CompositeModel/Object API

### Scenario and model applications

- `CompositeModel` stores objects, model applications, instances, and environment.
- `CompositeModel(model, models...; status=..., timestep=...)` is the concise one-object
  form and lowers to the same object/application representation.
- `Object` represents one runtime entity with stable identity and status.
- `CompositeModelTemplate` and `ObjectInstance` reuse a model across instances.
- `ModelSpec(model; name=...)` identifies one model application.
- `AppliesTo(...)` selects its target objects.

### Coupling

- `Inputs(...)` declares value dependencies.
- `Calls(...)` declares manually executable child models.
- `Updates(:variable; after=:application_id)` orders intentional duplicate writers.
- `Input(...)` and `Call(...)` express model defaults through `dep(model)`.
- `run_call!(context, :name; publish=false)` executes every resolved hard-call
  target and always returns a vector-like `CallTargets` collection.
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
- Labels and topology: `Kind(...)`, `Species(...)`, `Scale(...)`, and
  `Relation(...)`.

### Time and environment

- `TimeStep(period)` sets an application cadence.
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
- `collect_outputs(sim)` materializes retained output streams.

### Explanations

Use structured explanation helpers instead of inspecting internals:

- `explain_objects`
- `explain_instances`
- `explain_scopes`
- `explain_applications`
- `explain_bindings`
- `explain_calls`
- `explain_environment_bindings`
- `explain_schedule`
- `explain_writers`
- `explain_execution_plan`
- `explain_output_retention`
- `explain_outputs`
- `explain_initialization`

See [Migrating To The CompositeModel/Object API](../migration_composite_model.md) for
translations from removed APIs.

### CompositeModel graph visualization and editing

- `compile_model_report(model; strict=false)` preserves partial graph state and
  structured diagnostics for incomplete or cyclic composite models.
- `model_graph_view(model; level=:applications)` returns the typed graph view.
- `model_graph_view_json(model)` serializes the same DTO used by the browser.
- `write_model_graph_view(path, model)` writes a self-contained static viewer.
- `edit_graph(model)` starts the optional HTTP editor after `using HTTP`.
- `current_model(session)`, `undo!(session)`, `redo!(session)`, and
  `close(session)` control an interactive session from Julia.

See [Visualize And Edit A CompositeModel](../guides/graph_visualizer_editor.md) for the
runnable workflow, model discovery, selector previews, cycle breaking, and
Documenter embedding.

## Advanced compiler API

```@docs
PlantSimEngine.Advanced
```

Compiler representations, cache refresh operations, and low-level binding
compilers live under `PlantSimEngine.Advanced`. They are intended for package
integration, diagnostics development, and compiler work rather than ordinary
scenario composition. Prefer the public `explain_*` functions, which accept a
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
Modules = [PlantSimEngine]
Private = false
```
