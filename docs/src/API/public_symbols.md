# Public Symbol Inventory

This page lists public names by purpose. Names for compiler data structures
and cached information are listed separately under
[`PlantSimEngine.Advanced`](@ref "Advanced namespace").

`using PlantSimEngine` makes the usual modeling and simulation functions
available, along with the `Authoring`, `Diagnostics`, `GraphEditor`,
`EnvironmentAPI`, and `Evaluation` module names. Functions in those modules
keep their prefix, such as `Diagnostics.explain_bindings`, unless you import
the module's functions explicitly.

An object's **status** stores its changing values. A **model application**
configures a model's name, objects, connections, and timing. An input
**binding** connects a model to a source value, and its **carrier** holds
that connection, usually through a shared reference. The [Public API](@ref)
explains the functions and their requirements in detail.

## Scenario composition

- Building a simulation: `CompositeModel`, `Object`, `ObjectId`, `CompositeModelTemplate`,
  `ObjectInstance`, `Override`.
- Configuring model applications: `ModelSpec`, `OutputTo`, `Environment`, and `Updates`.
- Inspecting application settings: `application_name`, `applies_to`, `value_inputs`,
  `model_calls`, `outputs_to`, `environment_config`, `output_routing`,
  `updates`.
- Default input connections and calls: `Input`, `Call`, `Initializer`, `PreviousTimeStep`.

## Object selectors and queries

- Choosing the number of objects: `One`, `OptionalOne`, `Many`.
- Choosing where to look and how objects are connected: `SceneScope`, `Self`, `Subtree`, `SelfPlant`, `Ancestor`,
  `Scope`, `Relation`.
- Label criteria are selector keywords: `kind`, `species`, `scale`, and
  `name`.
- Finding objects and their identifiers: `object_id`, `object_ids`, `model_objects`,
  `resolve_object_ids`, `resolve_objects`.
- Object data: `geometry`, `position`, `bounds`.

## Execution, lifecycle, and outputs

- Running and advancing a simulation: `run!`, `continue!`, `step!`, `Simulation`, `current_step`,
  `runtime_model`, `final_state`.
- Output selection and collection: `OutputRequest`, `outputs`,
  `collect_outputs`.
- Writing results to several objects: `OutputTargets`, `output_targets`, and
  `assign_outputs!`. Access each variable's destination values through
  `targets.columns.<variable>` and their object identifiers, in the same
  order, through `object_ids(targets)`.
- Adding, removing, or moving objects: `register_object!`, `add_organ!`, `remove_object!`,
  `reparent_object!`, `move_object!`, `update_geometry!`,
  `mark_environment_binding_dirty!`, `objects_from_mtg`.
- Running another model from within a calculation: `RunContext`, `CallTarget`, `CallTargets`, `call_model`,
  `call_targets`, `run_call!`.
- Setting initial values when an object is created: `Initializer`, `run_initializer!`.

## Diagnostics namespace

`PlantSimEngine.Diagnostics` explains how the simulation is set up and what
happened during execution:

- Structure: `Diagnostics.explain_objects`, `Diagnostics.explain_instances`, `Diagnostics.explain_scopes`.
- Model connections and execution order: `Diagnostics.explain_applications`, `Diagnostics.explain_bindings`,
  `Diagnostics.explain_calls`, `Diagnostics.explain_output_bindings`,
  `Diagnostics.explain_writers`,
  `Diagnostics.explain_schedule`, `Diagnostics.explain_execution_plan`.
- Initialization, environment, and outputs: `Diagnostics.explain_initialization`,
  `Diagnostics.explain_environment`, `Diagnostics.explain_environment_bindings`,
  `Diagnostics.explain_output_retention`, `Diagnostics.explain_outputs`.
- Inspecting an input's connection and current value: `Diagnostics.input_carrier`, `Diagnostics.input_value`,
  `Diagnostics.has_reference_carrier`.
- Consistent descriptions of selected objects: `Diagnostics.ObjectAddress`,
  `Diagnostics.object_address`.

## Authoring namespace

`PlantSimEngine.Authoring` helps model authors and coding agents find,
inspect, and check models:

- Finding loaded models: `Authoring.available_processes` and
  `Authoring.available_models`.
- Describing a model with its chosen parameters: `Authoring.describe_model` and
  `Authoring.model_interface`.
- Comparing alternatives: `Authoring.compare_models`, including separate
  `requires_binding_changes` and `requires_reconfiguration` results.
- Checking declarations and connections: `Authoring.validate_model` and
  `Authoring.validate_scenario`.
- Supplying scientific descriptions: `Authoring.model_metadata` and
  `Authoring.parameter_metadata`.
- Converting reports to versioned dictionaries or JSON: `Authoring.to_dict`, `Authoring.to_json`, and
  `Authoring.SCHEMA_VERSION`.
- Generating editable simulation setup code: `Authoring.scenario_source`.
- Showing the calculations and connections prepared for execution: `Authoring.compiled_model_source` and
  `Authoring.write_compiled_model_source`.
- Typed reports: `Authoring.ModelDescription`, `Authoring.ModelComparison`,
  `Authoring.ModelValidationReport`, and
  `Authoring.ScenarioValidationReport`.

A description of a model instance includes its declared `process` and
actual parameter values. The nested `field_provenance` records where each
piece of information came from; declarations, source information, and
constructor information can have different origins.

When you supply a type rather than an instance, the description reports only
what can be determined. It never invents constructor arguments or creates a
dummy model. To obtain the model interface from a type, that type must have
a constructor that can be called without arguments. These checks concern
model definitions and connections; they do not prove scientific validity.

## Model-author contract

- Model identity: `AbstractModel`, `@process`, `process`.
- Declaring variables and initial values: `Status`, `Required`, `Default`,
  `VariableContract`, `variable_contracts`, `init_variables`, `dep`.
- Inspecting inputs and outputs: `inputs`, `outputs`, `variables`,
  `environment_inputs`, `environment_outputs`,
  `validate_environment_inputs`.
- Reading several input values together with their source object identifiers: `bound_input`, `BoundMany`, and
  `object_ids`.
- Timing and environment settings: `timespec`, `output_policy`, `timestep_hint`,
  `environment_hint`, `environment_bindings`, `environment_window`.

Model authors implement `inputs_`, `outputs_`, `environment_inputs_`,
`environment_outputs_`, and `variable_contracts_` with the package prefix, such as
`PlantSimEngine.inputs_(model) = ...`. `inputs_` must return explicit
`Required(T)` or `Default(value)` declarations; `outputs_` returns initial
output values; `variable_contracts_` returns `VariableContract` descriptions
of declared status or environment variables. These functions ending in `_`
are not imported by `using PlantSimEngine`.

## Time and reducers

- Choosing when models run and how inputs combine values over time: `ClockSpec`, `SchedulePolicy`, `HoldLast`, `Interpolate`,
  `Integrate`, `Aggregate`.
- Meteorology reducers are not re-exported. Use qualified PlantMeteo names,
  for example `PlantMeteo.MeanReducer` or `PlantMeteo.RadiationEnergy`.

## EnvironmentAPI namespace

- Implementing a provider of environmental data: `EnvironmentAPI.AbstractEnvironmentBackend`, `EnvironmentAPI.EnvironmentContext`,
  `EnvironmentAPI.GlobalConstant`, `EnvironmentAPI.environment_backend`, `EnvironmentAPI.environment_variables`,
  `EnvironmentAPI.base_step_seconds`, `EnvironmentAPI.get_nsteps`, and
  `EnvironmentAPI.bind_environment`.
- Reading and updating environmental values: `EnvironmentAPI.sample`,
  `EnvironmentAPI.sample_environment`, `EnvironmentAPI.commit_environment!`,
  and `EnvironmentAPI.update_index!`.
- PlantMeteo conveniences: `Atmosphere`, `Constants`, `Weather`.

## GraphEditor namespace

- Graph data: `GraphEditor.ModelGraphView` and
  `GraphEditor.model_graph_view`.
- Saving graph data and displaying static graphs: `GraphEditor.model_graph_view_json`,
  `GraphEditor.model_graph_view_html`, and
  `GraphEditor.write_model_graph_view`.
- Editing models and connections, and controlling editor sessions:
  `GraphEditor.AddModelApplication`, `GraphEditor.apply_model_graph_edit`,
  `GraphEditor.edit_graph`, `GraphEditor.current_model`,
  `GraphEditor.undo!`, and `GraphEditor.redo!`.

## Evaluation namespace

- Fitting and metrics: `Evaluation.fit`, `Evaluation.RMSE`,
  `Evaluation.NRMSE`, `Evaluation.EF`, and `Evaluation.dr`.

## Advanced namespace

`PlantSimEngine.Advanced` contains the compiler's data structures and the
functions that prepare and update cached information:

- registries and compiled representations: `ObjectRegistry`, `CompiledCompositeModel`,
  `CompiledModelApplication`, `CompiledModelInputBinding`,
  `CompiledModelCallBinding`, `CompiledModelOutputDestinationPlan`,
  `CompiledModelOutputDestinationBinding`, `CompiledDistributedOutputPlans`,
  `CompiledDistributedOutputs`, `CompiledEnvironmentBinding`,
  `CompiledEnvironmentBindings`;
- carrier and adapter implementation types: `ObjectRefVector`,
  `TimeStepTable`;
- compiler and cache operations: `compile_composite_model`, `refresh_bindings!`,
  `refresh_environment_bindings!`, `compile_environment_bindings`;
- cache diagnostics: `bindings_dirty`, `environment_bindings_dirty`,
  `model_revision`, `environment_revision`, `compiled_bindings`,
  `compiled_environment_bindings`.

Use these names with the `Advanced` prefix, or import them with
`using PlantSimEngine.Advanced`. They are not imported by
`using PlantSimEngine` and may change as the compiler develops.

The test in `test/test-model-api-stabilization.jl` compares the full set of
public names with an explicit list and checks each submodule separately.
When adding or removing an exported name, update that list as well.
