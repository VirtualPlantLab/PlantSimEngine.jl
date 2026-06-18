module PlantSimEngine

# Data formatting:
import DataFrames
import Tables
import Dates

# Reading CSV files in `variables`.
import CSV

import Term
import Markdown
import Base: position

# For MTG compatibility:
import MultiScaleTreeGraph
import MultiScaleTreeGraph: symbol, node_id

# Statistics helpers:
import Statistics

# Keep PlantMeteo names available for re-export without local wrapper types.
using PlantMeteo

# Temporal input marker:
include("variables_wrappers.jl")

# Models:
include("Abstract_model_structs.jl")

# Multi-rate scaffolding:
include("time/multirate.jl")

# Object status and reference carriers:
include("component_models/Status.jl")
include("component_models/RefVector.jl")

# Scene/object compiler and runtime:
include("scene_object_api.jl")

# Time-step table adapter:
include("component_models/TimeStepTable.jl")

# Model application configuration:
include("ModelSpec.jl")

# Model evaluation (statistics):
include("evaluation/statistics.jl")

# Traits
include("traits/table_traits.jl")

# Processes:
include("processes/models_inputs_outputs.jl")
include("processes/process_generation.jl")

# Scene timing and environment runtime:
include("time/runtime/clocks.jl")
include("time/runtime/output_export.jl")
include("time/runtime/meteo_sampling.jl")
include("time/runtime/environment_backends.jl")

# Fitting
include("evaluation/fit.jl")

# Examples
include("examples_import.jl")

export PreviousTimeStep
export AbstractModel
export ClockSpec
export SchedulePolicy, HoldLast, Interpolate, Integrate, Aggregate
export AbstractTimeReducer, MeanWeighted, MeanReducer, SumReducer, MinReducer, MaxReducer, FirstReducer, LastReducer, RadiationEnergy
export OutputRequest, collect_outputs
export Scene, Object, ObjectId, SceneRegistry, ObjectTemplate, ObjectInstance, Override
export register_object!, remove_object!, reparent_object!, move_object!, update_geometry!, refresh_bindings!
export bindings_dirty, environment_bindings_dirty, scene_revision, environment_revision
export compiled_bindings, compiled_environment_bindings, mark_environment_binding_dirty!
export refresh_environment_bindings!, compile_environment_bindings, bind_environment
export objects_from_mtg, object_ids, scene_objects, resolve_object_ids, resolve_objects, explain_objects, explain_instances, explain_scopes
export geometry, position, bounds
export CompiledScene, CompiledSceneApplication, CompiledSceneInputBinding, CompiledSceneCallBinding
export compile_scene, explain_scene_applications, explain_bindings, explain_calls, explain_model_bundles, explain_writers
export ObjectRefVector, input_carrier, input_value, has_reference_carrier
export SceneRunContext, SceneCallTarget, SceneSimulation, scene_outputs, explain_outputs
export explain_execution_plan, explain_output_retention
export CompiledEnvironmentBinding, CompiledEnvironmentBindings, explain_environment_bindings
export SceneScope, Self, SelfPlant, Ancestor, Scope, Kind, Species, Scale, Relation
export One, OptionalOne, Many, ObjectAddress, object_address
export Input, Call, AppliesTo, Inputs, Calls, TimeStep, Environment
export application_name, applies_to, value_inputs, model_calls, environment_config
export ModelSpec, Updates, OutputRouting
export call_target, call_targets, run_call!, explain_schedule
export RMSE, NRMSE, EF, dr
export Status, TimeStepTable
export @process, process
export init_variables, dep
export inputs, outputs, variables
export timespec, output_policy, timestep_hint, meteo_hint
export meteo_bindings, meteo_window, output_routing, updates
export meteo_inputs, meteo_inputs_, meteo_outputs, meteo_outputs_
export validate_meteo_inputs
export AbstractEnvironmentBackend, EnvironmentSupport, GlobalConstant
export environment_backend, environment_variables, base_step_seconds
export sample, sample_environment, scatter!, update_index!
export scatter_environment_outputs!
export explain_environment
export run!
export fit

# Re-exporting PlantMeteo main functions:
export Atmosphere, Constants, Weather

end
