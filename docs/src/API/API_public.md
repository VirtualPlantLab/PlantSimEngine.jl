# Public API

This reference lists the functions for building, running, and inspecting a
simulation. For a first example, start with
[Couple Models On One Object](@ref).

An **object** is one part of your simulated system, such as a plant or leaf.
Its **status** holds its changing values. A **model application** is a model
configured with a name, selected objects, and input or timing settings.
An input **binding** connects a model to the value it reads. The **carrier**
holds that connection, usually as a shared reference to the source value;
time-based inputs can instead read saved results.

## Unified CompositeModel/Object API

### Scenario and model applications

- `CompositeModel` stores the objects, their model applications, reusable plant
  instances, and environmental data or providers.
- `CompositeModel(model, models...; status=..., timestep=...,
  type_promotion=..., status_transform=...)` is the concise one-object form and
  creates one object and its model applications.
- `Object(id; name=nothing, scale=nothing, kind=nothing, species=nothing, ...)`
  represents one entity, such as a plant or organ, with a unique ID that stays
  the same and its own status. The optional `name` is display text and does
  not need to be unique. The graph viewer shows the ID when no name is given.
- Use `One(id=:leaf_1)` to select a particular object, or
  `object_ids(model; id=:leaf_1)` to query its ID. Labels such as `scale=:Leaf`
  select groups. IDs can also be numbers, including IDs imported from an MTG.
- `object_id(model, source)` finds an object's identifier in the model's
  registry, the collection of registered objects. `source` can be an
  `ObjectId`, registered `Object` or `Status`, MTG node, or raw identifier.
  MTG nodes keep the identifier assigned by the model's `id=` function when
  the MTG was imported or the organ was created. `object_id` does not call
  that function again, and rejects copied nodes or nodes from another model.
  The same methods accept a `RunContext` or `Simulation`.
- `CompositeModelTemplate` and `ObjectInstance` reuse a set of model
  definitions for several plants or other repeated objects. An instance name
  identifies that use of the template; it does not change the root object's
  ID or display name.
- `ModelSpec(model; name=..., on=..., inputs=..., calls=..., outputs_to=...,
  every=..., environment=..., output_routing=..., updates=...)` configures a
  model application. When `name` is omitted, the process name identifies the
  application. Separate applications of the same process need explicit,
  distinct names.

### Coupling

- `ModelSpec(...; inputs=...)` describes where a model's inputs come from.
- `bound_input(context, :name)` gives a model access to both the values and
  source objects of a declared `Many` input through a `BoundMany` view.
  `object_ids(view)` returns the source identifiers in the same order as the
  values, without copying them.
- `ModelSpec(...; calls=...)` declares models that this model can run from
  inside its own calculation.
- `ModelSpec(...; outputs_to=(name=OutputTo(selector; vars=...),))`
  declares variables that this application writes into other selected objects'
  statuses. Each variable uses `Required(T)` or `Default(value)`. Before
  initializing the statuses, PlantSimEngine finds the destination objects and
  checks that competing applications do not write the same value.
- `output_targets(context, :name)` returns an [`OutputTargets`](@ref) view
  for one named `outputs_to` group. Read or write a variable's destination
  values through `targets.columns.<variable>`. `object_ids(targets)` returns
  their identifiers in the same order; those identifiers are read-only.
- `assign_outputs!(targets, table; id=:object_id)` assigns a
  Tables.jl-compatible result to objects using their identifiers. The
  `assign_outputs!(targets, ids, columns)` overload accepts an ID vector and a
  `NamedTuple` of columns directly.
- `Updates(:variable; after=:application_id)` sets the order when several
  applications deliberately update the same variable.
- `Input(...)` and `Call(...)` describe a model's default input connections
  and calls through `dep(model)`.
- `Initializer(One(application=:name, ...))` declares one normally scheduled
  application that may initialize a newly registered object during its
  creation event.
- `run_call!(context, :name; publish=false)` runs every model and object
  selected by that named call. Each such pair is a **call target**. The result
  is always a vector-like `CallTargets` collection.
- `run_call!(context, :name; sampled_environment=value)` forwards one already
  prepared set of environmental values to the selected models. It uses the
  execution groups already prepared by PlantSimEngine.
- `call_model(context, :name)` returns the model when a call selects exactly
  one target.
- `call_targets(context, :name)` returns those targets without running them,
  so you can choose individual targets to run with `run_call!(target; ...)`.
- `run_initializer!(context, :name, object)` runs a declared `Initializer`
  once on a newly created object. It sets values in that object's main stored
  status and returns that `Status`, without adding an output-history sample
  partway through the step. Use it only for initialization during object
  creation, not for trial calls or existing objects.

When assigning outputs to several objects, include every selected object ID
exactly once and provide every declared output column. Additional table or
`NamedTuple` columns are treated as metadata and ignored. A result column
may share storage with a destination column only when assigning that column
to itself in exactly the destination order.

Obtain `OutputTargets` each time the model runs. Do not keep it for later
calls after changes to the objects have been processed. If you reuse the
same ID-column object, PlantSimEngine reuses the correspondence it calculated
between result rows and destination objects. This requires the IDs and their
order to remain unchanged. Supply a new ID-column object if either changes.

### Model input schema

- `Required(T)` declares an input that you must supply in the object's status
  or connect to another model. `T` is the expected type and may be generic.
- `Default(value)` supplies a model's fallback value when no input is provided.
- `inputs_(model)` uses only these explicit declarations; plain literals are
  rejected.
- `outputs_(model)` gives the initial values of outputs.
- `init_variables(model)` returns only input defaults and initial
  output values.
- `VariableContract` describes units and physical meaning: for example,
  whether a variable is per plant or per square metre, a rate or a daily
  total, and whether amounts from several objects can be added. The description
  is stored separately from the numerical value.
- `variable_contracts(model)` returns checked declarations from
  `PlantSimEngine.variable_contracts_`, which model packages implement.
  When an input is connected to another model's output, their contracts must
  be identical if either model declares one.

### Status representation

- `CompositeModel(...; type_promotion=Dict(Float64 => Float32))` converts every
  matching status value with `convert` when the value's storage is created.
- `CompositeModel(...; status_transform=(variable, value) -> ...)` applies a
  precise transformation based on the status variable name and value. The
  returned value is then checked against the `type_promotion` mapping, so
  `status_transform` always runs first.
- Ordinary numeric arrays are converted element by element when their elements
  match a mapping rule. Their shape is preserved.
- The policy covers supplied object statuses, model input and output defaults,
  and statuses of objects added later through the object-creation functions.
- The policy is limited to status values. Model parameters, environment values,
  constants, object labels, and topology are not converted.
- Conversion occurs when status storage is created or an object is registered,
  not every time the model's equation runs.
- `Diagnostics.explain_initialization(model)` reports `declared_type`,
  `original_type`, `transformed_type`, and `effective_type`, plus flags and the
  selected mapping rule for each initialized value.

The model's calculation must support the resulting numerical type. Keeping
`Required` declarations and equations open to different types allows the same
model to use `Float32`, numbers with uncertainty estimates, or another
compatible numerical type.
See [Numerical Reliability](../guides/data/numerical_reliability.md) for
complete examples.

### Selectors

- Number of matches: `One(...)`, `OptionalOne(...)`, and `Many(...)`.
- Where to look: `SceneScope()`, `Self()`, `Subtree()`, `SelfPlant()`,
  `Ancestor(...)`, and `Scope(...)`. Use `Scope(:instance_name)` for an
  instance's root and descendants, or `Scope(ObjectId(root_id))` for a root
  chosen directly by ID.
- Object identity: `id=...`.
- Group labels: `kind=...`, `species=...`, and `scale=...`. Object display
  names do not select objects.
- Connections between objects: `Relation(...)`.

`Self()` always means the current object: the object on which the model
reading the input runs. It means a plant only when that object is itself
the plant.

Selector fields are checked where the selector is used:

| Context | Accepted criteria |
|---|---|
| `ModelSpec(...; on=...)` | `id`, `kind`, `species`, `scale`, and a scene or explicit root/instance scope |
| `ModelSpec(...; inputs=...)` | object criteria plus `process`, `application`, `var`, `policy`, `window`, `from_status`, and `after` |
| `ModelSpec(...; calls=...)` | object criteria plus `process` and `application` |
| `OutputTo(...)` in `ModelSpec(...; outputs_to=...)` | object criteria only |
| object queries and `OutputRequest` selectors | object criteria only |

Unsupported or misspelled fields fail when the selector is constructed.
Selections such as descendants or ancestors need a current object to start
from. Use them in inputs, calls, or object/output queries with that context.
They cannot select where an application runs through `ModelSpec(...; on=...)`.

### Time and environment

- `ModelSpec(...; every=period)` sets how often an application runs.
- `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` describe how an input
  uses results over time: keep the last value, interpolate, integrate, or
  combine values over an interval.
- `Environment(...)` chooses where environmental data comes from and can
  map source variable names to the names a model expects.
- Models list the environmental variables they read in `environment_inputs_`.
- A model that tries changes to its environment passes trial values with
  `run_call!(context, name; environment=trial_state)`. It stores the accepted
  values with `commit_environment!`.
- `OutputRequest(selector, variable; ...)` selects results to save and can
  resample them at a chosen interval. It uses the same selectors as object
  queries.

### Lifecycle

- `objects_from_mtg` and `CompositeModel(mtg; ...)` create registered objects
  from a MultiScaleTreeGraph (MTG).
- `add_organ!` creates and initializes a new organ when the model uses an MTG.
- `runtime_model(context)` gives a model's `run!` function access to the
  running `CompositeModel`, for example to add or remove objects.
- `object_id(context)`, `model_object(context)`, `model_status(context)`, and
  `source_node(context)` return the current object's identifier, object,
  status, and source MTG node, respectively. `model_status` returns the main
  status stored for that object. The `status` argument passed to `run!` is
  instead the view of variables used by that particular application.
- `register_object!`, `remove_object!`, and `reparent_object!` change
  the objects and their parent relationships.
- `move_object!` and `update_geometry!` change position or geometry.
- These functions mark affected connections for updating. Changes to object
  relationships are processed after the application that made them, so new
  objects can run applications still remaining in the same time step.
  Changes made between steps are processed before the next step.
- `Initializer` lets a model initialize an object it has just created, using
  an application that already ran on existing objects. Its restrictions are
  detailed below.
- `run!(model; steps=..., outputs=:none)` starts a fresh simulation history and
  returns a `Simulation`.
- `continue!(simulation; steps=...)` and `step!(simulation)` advance an
  existing simulation, preserving the values needed for time-based inputs.
- `current_step(simulation)` reports the latest completed time step.
- `final_state(simulation)` returns a snapshot of the latest values even
  when output history was not saved. Pass an object id or selector for
  multi-object simulations.
- `collect_outputs(sim)` gathers saved results into rows for analysis.

**Initializing objects during growth.** An `Initializer` application runs
before the model that creates new objects. Models that directly read the new
values run after the creator in the same step. The following restrictions
keep those new values consistent with the rest of the simulation:

- `run_initializer!` accepts exactly one target from the current creation
  event, and that event must only add objects. It rejects repeated
  initialization, existing or reparented objects, and ordinary manual-call
  bindings. It also rejects cases that require a full connection rebuild
  instead of the update limited to the new objects.
- Each initialized output must have exactly one possible application writing
  its main stored value. This check counts both local outputs and outputs
  written to other objects.
- Initialization adds no output sample partway through a step. Models that
  read the new values directly can use them in that step, but PlantSimEngine
  rejects downstream time-based inputs that could read a newly created
  object's output. The initializer itself can still use a `PreviousTimeStep`
  input.

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

Use `Authoring` to find models and inspect their definitions. Its reports
can also be read by tools such as an AI coding agent:

- `Authoring.available_processes()` and `Authoring.available_models(...)`
  find models in loaded Julia modules;
- `Authoring.describe_model(instance)` reports the model's process, current
  parameter values, inputs and outputs, variable contracts, input connections
  and calls, execution settings, descriptive information, and source location.
  Its nested `field_provenance` explains where each fact came from: the actual
  model, an explicit declaration, or information inferred from the source.
  The origins of constructor fields, defaults, and methods are reported
  separately;
- `Authoring.describe_model(ModelType)` reports whatever can be determined
  from the type. If it has no constructor that can be called without
  arguments, the report is incomplete. It never invents parameter values
  or creates a dummy instance;
- current values from `Authoring.describe_model(instance)` stay in
  `parameters`; they are never relabeled as constructor defaults. Defaults are
  inspected from a type description only when a constructor can actually be
  called without arguments;
- `Authoring.model_interface(instance)` returns the declarations checked
  when replacing a model with `Override` for an object or plant instance;
- `Authoring.model_interface(ModelType)` attempts the same inspection using
  a constructor with no arguments. If no such constructor exists, it raises
  `ArgumentError` rather than inventing parameter values;
- `Authoring.compare_models(a, b)` reports whether two models share a process,
  whether one can directly replace the other, and what settings would need to
  change. `requires_binding_changes` reports differences in inputs, outputs,
  variable contracts, dependencies, output policies, or environmental
  connections. `requires_reconfiguration` covers every
  difference preventing a direct override. Each reported difference
  records its `path`, `kind`, values, `affects_override`, and
  `affects_bindings`;
- `Authoring.validate_model(model; strict=false)` checks declarations
  without running the equation. Strict mode requires a complete
  `VariableContract` for every declared input and output, including
  environmental variables;
- `Authoring.validate_scenario(model; strict=false)` checks the simulation
  setup. If it is incomplete, the result still includes a partial report
  and diagnostic information;
- `Authoring.to_dict(report)` and `Authoring.to_json(report)` convert reports
  to dictionaries or JSON using a versioned format. They do not include
  internal compiler objects;
- `Authoring.scenario_source(model; environments=...)` reconstructs readable,
  editable Julia simulation setup code. Pass named environment values through
  `environments` so the generated code can refer to them explicitly;
- `Authoring.compiled_model_source(model_or_simulation)` produces readable,
  executable Julia code showing the chosen application order, selected
  objects, input sources, model calls, and calculation functions;
- `Authoring.write_compiled_model_source(path, value)` writes that view
  explicitly.

These functions check the declared models and their connections. They do not
guess units, assumptions, references, valid use conditions, or whether two
equations are scientifically equivalent. The generated execution code uses
the normal runtime; it does not create a separate way to schedule the models.

Use `scenario_source` to edit or save the simulation setup in version
control. Use `compiled_model_source` to inspect the calculations and
connections PlantSimEngine prepared from that setup.

A model package can implement `Authoring.model_metadata(model)` to supply a
summary, hypothesis, references, and development or validation status. It can
implement `Authoring.parameter_metadata(model)` to describe each parameter's
meaning, units, valid range, defaults, references, or other constraints.

### CompositeModel graph visualization and editing

- `GraphEditor.model_graph_view(model; level=:applications)` returns graph
  data describing the models and their connections.
- `GraphEditor.model_graph_view_json(model)` converts the same graph data
  used by the browser to JSON.
- `GraphEditor.write_model_graph_view(path, model)` writes a self-contained static viewer.
- `GraphEditor.edit_graph(model; templates=..., environments=...)` starts the
  optional HTTP editor after `using HTTP`. The editor uses the templates
  and environment values supplied from Julia.
- `GraphEditor.current_model(session)`, `GraphEditor.undo!(session)`,
  `GraphEditor.redo!(session)`, and `close(session)` control an interactive
  session from Julia.

See [Visualize And Edit A CompositeModel](../guides/graph_visualizer_editor.md) for the
runnable workflow, finding models, previewing selected objects, handling
dependency cycles, and embedding a graph in Documenter pages.

### Environment backend extensions

Packages that provide environmental data implement functions under
`EnvironmentAPI`, including
`EnvironmentAPI.AbstractEnvironmentBackend`,
`EnvironmentAPI.bind_environment`, `EnvironmentAPI.sample`,
`EnvironmentAPI.commit_environment!`, and `EnvironmentAPI.update_index!`.
The root-level `commit_environment!` is the function a model calls to store
accepted environmental values after a trial calculation.

### Fitting and evaluation

Parameter fitting and evaluation metrics are available under `Evaluation`: `Evaluation.fit`,
`Evaluation.RMSE`, `Evaluation.NRMSE`, `Evaluation.EF`, and `Evaluation.dr`.
PlantMeteo reducers are accessed from `PlantMeteo` directly rather than being
re-exported by PlantSimEngine.

## Advanced compiler API

```@docs
PlantSimEngine.Advanced
```

`PlantSimEngine.Advanced` contains the compiler's data structures and functions
for preparing connections and refreshing cached information. Use it when
integrating a package or developing the compiler and its diagnostics. For
ordinary simulations, use `Diagnostics.explain_*` with a `CompositeModel`
to inspect the setup.

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
