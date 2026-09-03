# Public API

## Unified CompositeModel/Object API

### Scenario and model applications

- `CompositeModel` stores objects, model applications, instances, and environment.
- `CompositeModel(model, models...; status=..., timestep=...,
  type_promotion=..., status_transform=...)` is the concise one-object form and
  lowers to the same object/application representation.
- `Object` represents one runtime entity with stable identity and status.
- `object_id(model, source)` resolves an `ObjectId`, registered `Object` or
  `Status`, MTG node, or raw identifier against the live registry. MTG nodes
  retain the exact identity assigned by the model's `id=` accessor during
  adaptation or organogenesis; `object_id` does not reevaluate that accessor,
  and copied or foreign nodes are rejected. The same methods accept a
  `RunContext` or `Simulation`.
- `CompositeModelTemplate` and `ObjectInstance` reuse a model across instances.
- `ModelSpec(model; name=..., on=..., inputs=..., calls=..., outputs_to=...,
  every=..., environment=..., output_routing=..., updates=...)` is the one
  application construction form.

### Coupling

- `ModelSpec(...; inputs=...)` declares value dependencies.
- `bound_input(context, :name)` opts a model kernel into an identity-aware
  `BoundMany` view for one of its declared `Many` inputs; `object_ids(view)`
  returns the aligned object identities without copying them.
- `ModelSpec(...; calls=...)` declares manually executable child models.
- `ModelSpec(...; outputs_to=(name=OutputTo(selector; vars=...),))`
  declares status variables owned by the application but stored on selected
  destination objects. Each variable uses `Required(T)` or `Default(value)`;
  the compiler resolves identities and rejects ambiguous writers before
  initializing statuses.
- `output_targets(context, :name)` returns the compiled [`OutputTargets`](@ref)
  view for one named `outputs_to` group. Destination columns are exposed
  explicitly as `targets.columns.<variable>`, and `object_ids(targets)` returns
  their aligned, read-only identities.
- `assign_outputs!(targets, table; id=:object_id)` assigns a
  Tables.jl-compatible result by identity. The lower-level
  `assign_outputs!(targets, ids, columns)` overload accepts an ID vector and a
  `NamedTuple` of columns directly.
- `Updates(:variable; after=:application_id)` orders intentional duplicate writers.
- `Input(...)` and `Call(...)` express model defaults through `dep(model)`.
- `Initializer(One(application=:name, ...))` declares one normally scheduled
  application that may initialize a newly registered object during its
  creation event.
- `run_call!(context, :name; publish=false)` executes every resolved hard-call
  target and always returns a vector-like `CallTargets` collection.
- `run_call!(context, :name; sampled_environment=value)` forwards one already
  sampled model-facing environment through cached typed execution batches.
- `call_model(context, :name)` returns the concrete model when a call resolves
  to exactly one target.
- `call_targets(context, :name)` returns the same non-executing collection for
  fine-grained execution with `run_call!(target; ...)`.
- `run_initializer!(context, :name, object)` runs an `Initializer` binding once
  on that newborn object, initializes canonical local status without an extra
  mid-step output sample, and returns its canonical `Status`. It is not a
  trial-call or existing-object API.

Distributed assignment requires exact destination coverage. Every selected
object ID must occur exactly once and every declared output column must be
present; additional table or `NamedTuple` columns are treated as metadata and
ignored. Result columns may alias destination storage only for direct
self-assignment of the same column in exact destination order.

Obtain `OutputTargets` inside each model invocation and do not retain it across
a lifecycle barrier. Reusing the same ID-column object lets PlantSimEngine
reuse its compiled row permutation and promises that the IDs and their order
have not been mutated. Replace the ID-column object when either changes.

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
- `VariableContract` records a variable's unit, spatial or object basis,
  temporal basis, aggregation meaning, and intensive/extensive character
  without wrapping its runtime value.
- `variable_contracts(model)` returns validated declarations from the
  package-extension trait `PlantSimEngine.variable_contracts_`. A compiled
  producer-consumer binding must have identical contracts once either side
  declares one.

### Status representation

- `CompositeModel(...; type_promotion=Dict(Float64 => Float32))` converts every
  matching status value with `convert` when its storage is materialized.
- `CompositeModel(...; status_transform=(variable, value) -> ...)` applies a
  precise transformation based on the status variable name and value. The
  returned value becomes the candidate for the general `type_promotion`
  mapping, so the transform always runs first.
- Ordinary numeric arrays are converted element by element when their elements
  match a mapping rule. Their shape is preserved.
- The policy covers supplied object statuses, model input and output defaults,
  and statuses of objects registered later through the lifecycle API.
- The policy is limited to status values. Model parameters, environment values,
  constants, object labels, and topology are not converted.
- Conversion occurs during status materialization or object registration, not
  on every call to a model kernel.
- `Diagnostics.explain_initialization(model)` reports `declared_type`,
  `original_type`, `transformed_type`, and `effective_type`, plus flags and the
  selected mapping rule for each initialized value.

The effective status type must be supported by the model kernel. Generic
`Required` declarations and generic computations allow the same model to use
`Float32`, uncertainty-carrying numbers, or another compatible numeric type.
See [Numerical Reliability](../guides/data/numerical_reliability.md) for
complete examples.

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
| `OutputTo(...)` in `ModelSpec(...; outputs_to=...)` | object criteria only |
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
- `object_id(context)`, `model_object(context)`, `model_status(context)`, and
  `source_node(context)` resolve the current execution target. The status
  accessor returns canonical registry state rather than the application-local
  status view passed to a kernel.
- `register_object!`, `remove_object!`, and `reparent_object!` change
  topology.
- `move_object!` and `update_geometry!` change spatial state.
- Supported lifecycle operations automatically invalidate and refresh the
  affected structural or spatial bindings before the next timestep.
- A creator that must run an application which already completed on existing
  objects declares an `Initializer` call. The compiler orders the scheduled
  target before the creator and the creator before direct non-temporal
  same-step consumers;
  `run_initializer!` admits exactly one target from the current pure-addition
  event and rejects repeat, existing, reparented, manual-call, and
  refresh-fallback execution. Each initialized output must have one potential
  canonical writer across local and distributed destinations. Because
  `run_initializer!` emits no mid-step stream sample,
  downstream temporal consumers of a possible newborn output are rejected at
  compilation; a `PreviousTimeStep` input used by the initializer itself
  remains supported.
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
- `Diagnostics.explain_output_bindings`
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

See [Migrating To The CompositeModel/Object API](../migration_composite_model.md) for
translations from removed APIs.

### Model authoring and scenario validation

Use the neutral `Authoring` namespace for model discovery and machine-readable
validation:

- `Authoring.available_processes()` and `Authoring.available_models(...)`
  discover models from loaded Julia modules;
- `Authoring.describe_model(instance)` records explicit process identity plus
  the parameter values, ports, contracts, dependencies, traits, metadata, and
  source location of a concrete instance. Its nested `field_provenance`
  separately marks exact or declared model information, inferred source
  information, and the independent provenance of constructor fields, defaults,
  and methods;
- `Authoring.describe_model(ModelType)` is explicitly best effort and returns
  an incomplete report when no real zero-argument constructor exists. It never
  fabricates parameter values or constructs a dummy instance;
- current values from `Authoring.describe_model(instance)` stay in
  `parameters`; they are never relabeled as constructor defaults. Defaults are
  inspected only from a real zero-argument type description;
- `Authoring.model_interface(instance)` returns the exact interface enforced
  for object and instance overrides;
- `Authoring.model_interface(ModelType)` is best effort only when that type has
  a real zero-argument constructor; otherwise it raises `ArgumentError` rather
  than inventing parameter values;
- `Authoring.compare_models(a, b)` distinguishes common process identity from
  direct override compatibility, binding changes, and other scenario
  reconfiguration. Inspect `requires_binding_changes` for interface differences
  that affect binding configuration and `requires_reconfiguration` for any
  difference that prevents a direct override; each structured difference
  records its `path`, `kind`, values, `affects_override`, and
  `affects_bindings`;
- `Authoring.validate_model(model; strict=false)` validates declarations
  without executing the scientific kernel. Strict mode requires a complete
  `VariableContract` for every declared port;
- `Authoring.validate_scenario(model; strict=false)` preserves a partial
  compilation report and structured diagnostics for incomplete scenarios;
- `Authoring.to_dict(report)` and `Authoring.to_json(report)` expose the
  versioned report schema without serializing compiler internals;
- `Authoring.scenario_source(model; environments=...)` reconstructs readable,
  editable Julia scenario code. Pass named runtime environment values through
  `environments` so the generated code can refer to them explicitly;
- `Authoring.compiled_model_source(model_or_simulation)` produces an executable,
  readable view of the resolved application order, targets, input provenance,
  calls, and invoked kernel bodies;
- `Authoring.write_compiled_model_source(path, value)` writes that view
  explicitly.

These functions validate declared structure and coupling. They do not infer
units, assumptions, references, domains of validity, or scientific
equivalence. The compiled source is an explanatory execution view over the
normal compiled runtime, not a second scheduler. Use `scenario_source` when the
goal is to edit or version the scenario declaration; use
`compiled_model_source` when the goal is to inspect what compilation resolved.
A package may extend `Authoring.model_metadata(model)` with explicit metadata
such as summary, hypothesis, references, and maturity. It may extend
`Authoring.parameter_metadata(model)` with descriptions, units, domains,
defaults, references, or constraints for the fields of the model type.

### CompositeModel graph visualization and editing

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
    PlantSimEngine.Authoring,
    PlantSimEngine.Diagnostics,
    PlantSimEngine.GraphEditor,
    PlantSimEngine.EnvironmentAPI,
    PlantSimEngine.Evaluation,
]
Private = false
```
