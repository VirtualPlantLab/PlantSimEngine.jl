# Public Symbol Inventory

This page records the supported default namespace and the four focused public
submodules. Compiler representations and cache controls are intentionally
listed separately under [`PlantSimEngine.Advanced`](#advanced-namespace).

`using PlantSimEngine` imports the ordinary model-author and simulation-user
workflow plus the `Diagnostics`, `GraphEditor`, `EnvironmentAPI`, and
`Evaluation` module names. Their members remain qualified unless a user
explicitly imports one of those submodules.

## Scenario composition

- CompositeModel structure: `CompositeModel`, `Object`, `ObjectId`, `CompositeModelTemplate`,
  `ObjectInstance`, `Override`.
- Applications: `ModelSpec`, `OutputTo`, `Environment`, and `Updates`.
- Application inspection: `application_name`, `applies_to`, `value_inputs`,
  `model_calls`, `outputs_to`, `environment_config`, `output_routing`,
  `updates`.
- Dependency defaults: `Input`, `Call`, `Initializer`, `PreviousTimeStep`.

## Object selectors and queries

- Multiplicity: `One`, `OptionalOne`, `Many`.
- Scope and topology: `SceneScope`, `Self`, `Subtree`, `SelfPlant`, `Ancestor`,
  `Scope`, `Relation`.
- Label criteria are selector keywords: `kind`, `species`, `scale`, and
  `name`.
- Identity and queries: `object_id`, `object_ids`, `model_objects`,
  `resolve_object_ids`, `resolve_objects`.
- Object data: `geometry`, `position`, `bounds`.

## Execution, lifecycle, and outputs

- Execution: `run!`, `continue!`, `step!`, `Simulation`, `current_step`,
  `runtime_model`, `final_state`.
- Output selection and collection: `OutputRequest`, `outputs`,
  `collect_outputs`.
- Distributed output assignment: `OutputTargets`, `output_targets`, and
  `assign_outputs!`. Access destination carriers through
  `targets.columns.<variable>` and aligned identities through
  `object_ids(targets)`.
- Lifecycle: `register_object!`, `add_organ!`, `remove_object!`,
  `reparent_object!`, `move_object!`, `update_geometry!`,
  `mark_environment_binding_dirty!`, `objects_from_mtg`.
- Hard calls: `RunContext`, `CallTarget`, `CallTargets`, `call_model`,
  `call_targets`, `run_call!`.
- Newborn initialization: `Initializer`, `run_initializer!`.

## Diagnostics namespace

`PlantSimEngine.Diagnostics` owns structured explanations and supported
inspection:

- Structure: `Diagnostics.explain_objects`, `Diagnostics.explain_instances`, `Diagnostics.explain_scopes`.
- Compilation: `Diagnostics.explain_applications`, `Diagnostics.explain_bindings`,
  `Diagnostics.explain_calls`, `Diagnostics.explain_output_bindings`,
  `Diagnostics.explain_writers`,
  `Diagnostics.explain_schedule`, `Diagnostics.explain_execution_plan`.
- Initialization, environment, and outputs: `Diagnostics.explain_initialization`,
  `Diagnostics.explain_environment`, `Diagnostics.explain_environment_bindings`,
  `Diagnostics.explain_output_retention`, `Diagnostics.explain_outputs`.
- Supported carrier inspection: `Diagnostics.input_carrier`, `Diagnostics.input_value`,
  `Diagnostics.has_reference_carrier`.
- Normalized selector addresses: `Diagnostics.ObjectAddress`,
  `Diagnostics.object_address`.

## Model-author contract

- Model identity: `AbstractModel`, `@process`, `process`.
- State schema and initialization: `Status`, `Required`, `Default`,
  `VariableContract`, `variable_contracts`, `init_variables`, `dep`.
- Model IO inspection: `inputs`, `outputs`, `variables`,
  `environment_inputs`, `environment_outputs`,
  `validate_environment_inputs`.
- Identity-aware many-input access: `bound_input`, `BoundMany`, and
  `object_ids`.
- Timing and routing traits: `timespec`, `output_policy`, `timestep_hint`,
  `environment_hint`, `environment_bindings`, `environment_window`.

The underscore declarations `inputs_`, `outputs_`, `environment_inputs_`,
`environment_outputs_`, and `variable_contracts_` are intentionally
unexported extension functions.
Model authors implement them with qualified definitions such as
`PlantSimEngine.inputs_(model) = ...`. `inputs_` must return explicit
`Required(T)` or `Default(value)` declarations; `outputs_` returns initial
output-state values; `variable_contracts_` returns `VariableContract` metadata
for declared status or environment variables.

## Time and reducers

- Scheduling: `ClockSpec`, `SchedulePolicy`, `HoldLast`, `Interpolate`,
  `Integrate`, `Aggregate`.
- Meteorology reducers are not re-exported. Use qualified PlantMeteo names,
  for example `PlantMeteo.MeanReducer` or `PlantMeteo.RadiationEnergy`.

## EnvironmentAPI namespace

- Backend contract: `EnvironmentAPI.AbstractEnvironmentBackend`, `EnvironmentAPI.EnvironmentContext`,
  `EnvironmentAPI.GlobalConstant`, `EnvironmentAPI.environment_backend`, `EnvironmentAPI.environment_variables`,
  `EnvironmentAPI.base_step_seconds`, `EnvironmentAPI.get_nsteps`, and
  `EnvironmentAPI.bind_environment`.
- Sampling and mutation: `EnvironmentAPI.sample`,
  `EnvironmentAPI.sample_environment`, `EnvironmentAPI.commit_environment!`,
  and `EnvironmentAPI.update_index!`.
- PlantMeteo conveniences: `Atmosphere`, `Constants`, `Weather`.

## GraphEditor namespace

- Discovery and DTOs: `GraphEditor.available_models`,
  `GraphEditor.model_descriptor`, `GraphEditor.compile_model_report`,
  `GraphEditor.ModelGraphView`, and `GraphEditor.model_graph_view`.
- Serialization and static views: `GraphEditor.model_graph_view_json`,
  `GraphEditor.model_graph_view_html`, and
  `GraphEditor.write_model_graph_view`.
- Semantic edits and sessions live under the same namespace, including
  `GraphEditor.AddModelApplication`, `GraphEditor.apply_model_graph_edit`,
  `GraphEditor.edit_graph`, `GraphEditor.current_model`,
  `GraphEditor.undo!`, and `GraphEditor.redo!`.

## Evaluation namespace

- Fitting and metrics: `Evaluation.fit`, `Evaluation.RMSE`,
  `Evaluation.NRMSE`, `Evaluation.EF`, and `Evaluation.dr`.

## Advanced namespace

`PlantSimEngine.Advanced` contains the qualified compiler and cache API:

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

These names require explicit qualification or `using PlantSimEngine.Advanced`.
They are not part of the concise user namespace and may evolve with compiler
implementation requirements.

The namespace-boundary test in `test/test-model-api-stabilization.jl` compares
the complete default public-name set with an explicit inventory and separately
checks every focused submodule. Adding or removing an export therefore requires
an intentional inventory update.
