# Public Symbol Inventory

This page records the supported default namespace. Compiler representations
and cache controls are intentionally listed separately under
[`PlantSimEngine.Advanced`](#advanced-namespace).

## Scenario composition

- CompositeModel structure: `CompositeModel`, `Object`, `ObjectId`, `CompositeModelTemplate`,
  `ObjectInstance`, `Override`.
- Applications: `ModelSpec`, `AppliesTo`, `Inputs`, `Calls`, `TimeStep`,
  `Environment`, `Updates`, `OutputRouting`.
- Application inspection: `application_name`, `applies_to`, `value_inputs`,
  `model_calls`, `environment_config`, `output_routing`, `updates`.
- Dependency defaults: `Input`, `Call`, `PreviousTimeStep`.

## Object selectors and queries

- Multiplicity: `One`, `OptionalOne`, `Many`.
- Scope and topology: `SceneScope`, `Self`, `Subtree`, `SelfPlant`, `Ancestor`,
  `Scope`, `Relation`.
- Labels: `Kind`, `Species`, `Scale`.
- Normalized addresses: `ObjectAddress`, `object_address`.
- Queries: `object_ids`, `model_objects`, `resolve_object_ids`,
  `resolve_objects`.
- Object data: `geometry`, `position`, `bounds`.

## Execution, lifecycle, and outputs

- Execution: `run!`, `continue!`, `step!`, `Simulation`, `current_step`,
  `runtime_model`.
- Output selection and collection: `OutputRequest`, `outputs`,
  `collect_outputs`.
- Lifecycle: `register_object!`, `add_organ!`, `remove_object!`,
  `reparent_object!`, `move_object!`, `update_geometry!`,
  `mark_environment_binding_dirty!`, `objects_from_mtg`.
- Hard calls: `RunContext`, `CallTarget`, `CallTargets`, `call_targets`,
  `run_call!`.

## Structured explanations

- Structure: `explain_objects`, `explain_instances`, `explain_scopes`.
- Compilation: `explain_applications`, `explain_bindings`,
  `explain_calls`, `explain_model_bundles`, `explain_writers`,
  `explain_schedule`, `explain_execution_plan`.
- Initialization, environment, and outputs: `explain_initialization`,
  `explain_environment`, `explain_environment_bindings`,
  `explain_output_retention`, `explain_outputs`.
- Supported carrier inspection: `input_carrier`, `input_value`,
  `has_reference_carrier`.

## Model-author contract

- Model identity: `AbstractModel`, `@process`, `process`.
- State: `Status`, `init_variables`, `dep`.
- Model IO: `inputs`, `outputs`, `variables`, `meteo_inputs`, `meteo_inputs_`,
  `validate_meteo_inputs`.
- Timing and routing traits: `timespec`, `output_policy`, `timestep_hint`,
  `meteo_hint`, `meteo_bindings`, `meteo_window`.

The underscore declarations `inputs_`, `outputs_`, and `meteo_inputs_` are
extension functions model authors implement with qualified
definitions such as `PlantSimEngine.inputs_(model) = ...`. `inputs_` and
`outputs_` remain intentionally unexported to avoid collisions with common
user functions.

## Time and reducers

- Scheduling: `ClockSpec`, `SchedulePolicy`, `HoldLast`, `Interpolate`,
  `Integrate`, `Aggregate`.
- Reducers: `AbstractTimeReducer`, `MeanWeighted`, `MeanReducer`, `SumReducer`,
  `MinReducer`, `MaxReducer`, `FirstReducer`, `LastReducer`,
  `RadiationEnergy`.

## Environment extension interface

- Backend contract: `AbstractEnvironmentBackend`, `EnvironmentContext`,
  `GlobalConstant`, `environment_backend`, `environment_variables`,
  `base_step_seconds`.
- Sampling and mutation: `sample`, `sample_environment`,
  `commit_environment!`, `update_index!`.
- PlantMeteo conveniences: `Atmosphere`, `Constants`, `Weather`.

## Evaluation

- Fitting and metrics: `fit`, `RMSE`, `NRMSE`, `EF`, `dr`.

## Advanced namespace

`PlantSimEngine.Advanced` contains the qualified compiler and cache API:

- registries and compiled representations: `ObjectRegistry`, `CompiledCompositeModel`,
  `CompiledModelApplication`, `CompiledModelInputBinding`,
  `CompiledModelCallBinding`, `CompiledEnvironmentBinding`,
  `CompiledEnvironmentBindings`;
- carrier and adapter implementation types: `ObjectRefVector`,
  `TimeStepTable`;
- compiler and cache operations: `compile_composite_model`, `refresh_bindings!`,
  `refresh_environment_bindings!`, `compile_environment_bindings`,
  `bind_environment`;
- cache diagnostics: `bindings_dirty`, `environment_bindings_dirty`,
  `model_revision`, `environment_revision`, `compiled_bindings`,
  `compiled_environment_bindings`.

These names require explicit qualification or `using PlantSimEngine.Advanced`.
They are not part of the concise user namespace and may evolve with compiler
implementation requirements.
