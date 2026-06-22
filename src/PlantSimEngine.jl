module PlantSimEngine

# Data formatting:
import DataFrames
import Tables
import Dates

# Reading CSV files in `variables`.
import CSV

import Term
import Markdown
import JSON
import InteractiveUtils
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

# CompositeModel/object compiler and runtime:
include("composite_model_api.jl")

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

# Model discovery for static and interactive graph tooling:
include("model_discovery.jl")

# CompositeModel timing and environment runtime:
include("time/runtime/clocks.jl")
include("time/runtime/output_export.jl")
include("time/runtime/meteo_sampling.jl")
include("time/runtime/environment_backends.jl")

# Static CompositeModel graph compilation and visualization:
include("visualization/model_graph_view.jl")
include("visualization/model_graph_editor_api.jl")

# Fitting
include("evaluation/fit.jl")

# Examples
include("examples_import.jl")

"""
    PlantSimEngine.Advanced

Qualified compiler, cache, and low-level runtime extension APIs. These symbols
are available for diagnostics, package integration, and compiler development,
but are intentionally not part of the default user namespace.
"""
module Advanced
import ..PlantSimEngine:
    ObjectRegistry,
    CompiledCompositeModel,
    CompiledModelApplication,
    CompiledModelInputBinding,
    CompiledModelCallBinding,
    CompiledEnvironmentBinding,
    CompiledEnvironmentBindings,
    ObjectRefVector,
    TimeStepTable,
    compile_composite_model,
    refresh_bindings!,
    refresh_environment_bindings!,
    compile_environment_bindings,
    bind_environment,
    bindings_dirty,
    environment_bindings_dirty,
    model_revision,
    environment_revision,
    compiled_bindings,
    compiled_environment_bindings

export ObjectRegistry
export CompiledCompositeModel, CompiledModelApplication
export CompiledModelInputBinding, CompiledModelCallBinding
export CompiledEnvironmentBinding, CompiledEnvironmentBindings
export ObjectRefVector, TimeStepTable
export compile_composite_model, refresh_bindings!, refresh_environment_bindings!
export compile_environment_bindings, bind_environment
export bindings_dirty, environment_bindings_dirty
export model_revision, environment_revision
export compiled_bindings, compiled_environment_bindings
end

export PreviousTimeStep
export AbstractModel
export ClockSpec
export SchedulePolicy, HoldLast, Interpolate, Integrate, Aggregate
export AbstractTimeReducer, MeanWeighted, MeanReducer, SumReducer, MinReducer, MaxReducer, FirstReducer, LastReducer, RadiationEnergy
export OutputRequest, collect_outputs
export CompositeModel, Object, ObjectId, CompositeModelTemplate, ObjectInstance, Override
export add_organ!, register_object!, remove_object!, reparent_object!, move_object!, update_geometry!
export mark_environment_binding_dirty!
export objects_from_mtg, object_ids, model_objects, resolve_object_ids, resolve_objects, explain_objects, explain_instances, explain_scopes
export geometry, position, bounds
export explain_applications, explain_bindings, explain_calls, explain_model_bundles, explain_writers
export input_carrier, input_value, has_reference_carrier
export RunContext, CallTarget, Simulation, runtime_model, current_step, outputs, explain_outputs
export explain_initialization
export explain_execution_plan, explain_output_retention
export explain_environment_bindings
export SceneScope, Self, Subtree, SelfPlant, Ancestor, Scope, Kind, Species, Scale, Relation
export One, OptionalOne, Many, ObjectAddress, object_address
export Input, Call, AppliesTo, Inputs, Calls, TimeStep, Environment
export application_name, applies_to, value_inputs, model_calls, environment_config
export ModelSpec, Updates, OutputRouting
export call_target, call_targets, run_call!, explain_schedule
export RMSE, NRMSE, EF, dr
export Status
export @process, process
export init_variables, dep
export inputs, outputs, variables
export timespec, output_policy, timestep_hint, meteo_hint
export meteo_bindings, meteo_window, output_routing, updates
export meteo_inputs, meteo_inputs_, meteo_outputs, meteo_outputs_
export validate_meteo_inputs
export available_processes, available_models, model_descriptor, model_constructor_descriptor
export ModelGraphDiagnostic, CompositeModelCompilationReport, ModelGraphView
export compile_model_report, compile_model_graph, model_graph_view
export model_graph_view_json, model_graph_view_html, write_model_graph_view
export AbstractModelGraphEdit, AddModelApplication, RemoveModelApplication, RemoveModelTemplateApplication
export ReplaceModelApplicationModel, UpdateModelApplication, UpdateModelTemplateApplication
export RenameModelApplication, SetModelApplicationTargets
export SetModelInputBinding, RemoveModelInputBinding, SetModelCallBinding, RemoveModelCallBinding
export SetModelApplicationTimeStep, SetModelApplicationEnvironment
export SetModelOutputRouting, SetModelUpdateOrdering
export MarkModelPreviousTimeStep, UnmarkModelPreviousTimeStep, BreakModelCycle
export AddModelObject, RemoveModelObject, ReparentModelObject
export SetModelObjectStatus, SetModelObjectStatuses, RemoveModelObjectStatus, SetModelObjectMetadata
export SetModelInstanceOverride, RemoveModelInstanceOverride
export SetModelObjectOverride, RemoveModelObjectOverride, apply_model_graph_edit
export AbstractModelGraphEditorSession, edit_graph, current_model, apply_edit!, undo!, redo!
export AbstractEnvironmentBackend, EnvironmentSupport, GlobalConstant
export environment_backend, environment_variables, base_step_seconds
export sample, sample_environment, scatter!, update_index!
export scatter_environment_outputs!
export explain_environment
export run!, continue!, step!
export fit
export Advanced

# Re-exporting PlantMeteo main functions:
export Atmosphere, Constants, Weather

end
