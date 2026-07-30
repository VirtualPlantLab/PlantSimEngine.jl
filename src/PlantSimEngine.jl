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
include("input_schema.jl")

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
include("time/runtime/environment_sampling.jl")
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
    bindings_dirty,
    environment_bindings_dirty,
    model_revision,
    environment_revision,
    compiled_bindings,
    compiled_environment_bindings,
    RuntimePerformanceCounters,
    runtime_performance

export ObjectRegistry
export CompiledCompositeModel, CompiledModelApplication
export CompiledModelInputBinding, CompiledModelCallBinding
export CompiledEnvironmentBinding, CompiledEnvironmentBindings
export ObjectRefVector, TimeStepTable
export compile_composite_model, refresh_bindings!, refresh_environment_bindings!
export compile_environment_bindings
export bindings_dirty, environment_bindings_dirty
export model_revision, environment_revision
export compiled_bindings, compiled_environment_bindings
export RuntimePerformanceCounters, runtime_performance
end

"""
    PlantSimEngine.Diagnostics

Structured compiler/runtime explanations and supported carrier inspection.
"""
module Diagnostics
import ..PlantSimEngine:
    ObjectAddress,
    object_address,
    explain_objects,
    explain_instances,
    explain_scopes,
    explain_applications,
    explain_bindings,
    explain_calls,
    explain_writers,
    input_carrier,
    input_value,
    has_reference_carrier,
    explain_outputs,
    explain_initialization,
    explain_execution_plan,
    explain_output_retention,
    explain_environment_bindings,
    explain_schedule,
    explain_environment

export ObjectAddress, object_address
export explain_objects, explain_instances, explain_scopes
export explain_applications, explain_bindings, explain_calls, explain_writers
export input_carrier, input_value, has_reference_carrier
export explain_outputs, explain_initialization, explain_execution_plan
export explain_output_retention, explain_environment_bindings
export explain_schedule, explain_environment
end

"""
    PlantSimEngine.GraphEditor

Static graph DTOs, model discovery, graph edits, and interactive editor
sessions.
"""
module GraphEditor
import ..PlantSimEngine:
    available_processes,
    available_models,
    model_descriptor,
    model_constructor_descriptor,
    ModelGraphDiagnostic,
    CompositeModelCompilationReport,
    ModelGraphView,
    compile_model_report,
    compile_model_graph,
    model_graph_view,
    model_graph_view_json,
    model_graph_view_html,
    write_model_graph_view,
    AbstractModelGraphEdit,
    AddModelApplication,
    RemoveModelApplication,
    RemoveModelTemplateApplication,
    ReplaceModelApplicationModel,
    UpdateModelApplication,
    UpdateModelTemplateApplication,
    RenameModelApplication,
    SetModelApplicationTargets,
    SetModelInputBinding,
    RemoveModelInputBinding,
    SetModelCallBinding,
    RemoveModelCallBinding,
    SetModelApplicationTimeStep,
    SetModelApplicationEnvironment,
    SetModelOutputRouting,
    SetModelUpdateOrdering,
    MarkModelPreviousTimeStep,
    UnmarkModelPreviousTimeStep,
    BreakModelCycle,
    AddModelObject,
    RemoveModelObject,
    ReparentModelObject,
    SetModelObjectStatus,
    SetModelObjectStatuses,
    RemoveModelObjectStatus,
    SetModelObjectMetadata,
    SetModelInstanceOverride,
    RemoveModelInstanceOverride,
    SetModelObjectOverride,
    RemoveModelObjectOverride,
    apply_model_graph_edit,
    AbstractModelGraphEditorSession,
    edit_graph,
    current_model,
    apply_edit!,
    undo!,
    redo!

export available_processes, available_models
export model_descriptor, model_constructor_descriptor
export ModelGraphDiagnostic, CompositeModelCompilationReport, ModelGraphView
export compile_model_report, compile_model_graph, model_graph_view
export model_graph_view_json, model_graph_view_html, write_model_graph_view
export AbstractModelGraphEdit, AddModelApplication, RemoveModelApplication
export RemoveModelTemplateApplication, ReplaceModelApplicationModel
export UpdateModelApplication, UpdateModelTemplateApplication
export RenameModelApplication, SetModelApplicationTargets
export SetModelInputBinding, RemoveModelInputBinding
export SetModelCallBinding, RemoveModelCallBinding
export SetModelApplicationTimeStep, SetModelApplicationEnvironment
export SetModelOutputRouting, SetModelUpdateOrdering
export MarkModelPreviousTimeStep, UnmarkModelPreviousTimeStep, BreakModelCycle
export AddModelObject, RemoveModelObject, ReparentModelObject
export SetModelObjectStatus, SetModelObjectStatuses, RemoveModelObjectStatus
export SetModelObjectMetadata, SetModelInstanceOverride, RemoveModelInstanceOverride
export SetModelObjectOverride, RemoveModelObjectOverride, apply_model_graph_edit
export AbstractModelGraphEditorSession, edit_graph, current_model
export apply_edit!, undo!, redo!
end

"""
    PlantSimEngine.EnvironmentAPI

Extension protocol for global and spatial environment backends.
"""
module EnvironmentAPI
import ..PlantSimEngine:
    AbstractEnvironmentBackend,
    EnvironmentContext,
    GlobalConstant,
    environment_backend,
    environment_variables,
    base_step_seconds,
    get_nsteps,
    bind_environment,
    sample,
    sample_environment,
    update_index!,
    commit_environment!

export AbstractEnvironmentBackend, EnvironmentContext, GlobalConstant
export environment_backend, environment_variables, base_step_seconds
export get_nsteps, bind_environment, sample, sample_environment, update_index!
export commit_environment!
end

"""
    PlantSimEngine.Evaluation

Generic model-fitting interface and simulation evaluation metrics.
"""
module Evaluation
import ..PlantSimEngine: fit, RMSE, NRMSE, EF, dr

export fit, RMSE, NRMSE, EF, dr
end

export PreviousTimeStep
export AbstractModel
export ClockSpec
export SchedulePolicy, HoldLast, Interpolate, Integrate, Aggregate
export OutputRequest, collect_outputs
export CompositeModel, Object, ObjectId, CompositeModelTemplate, ObjectInstance, Override
export add_organ!, register_object!, remove_object!, reparent_object!, move_object!, update_geometry!
export mark_environment_binding_dirty!
export objects_from_mtg, object_ids, model_objects, resolve_object_ids, resolve_objects
export geometry, position, bounds
export RunContext, CallTarget, CallTargets, Simulation, runtime_model, current_step, outputs
export SceneScope, Self, Subtree, SelfPlant, Ancestor, Scope, Relation
export One, OptionalOne, Many
export Input, Call, Environment
export application_name, applies_to, value_inputs, model_calls, environment_config
export ModelSpec, Updates
export call_targets, run_call!, commit_environment!
export Status
export Required, Default
export @process, process
export init_variables, dep
export inputs, outputs, variables
export timespec, output_policy, timestep_hint, environment_hint
export environment_bindings, environment_window, output_routing, updates
export environment_inputs, environment_outputs
export validate_environment_inputs
export run!, continue!, step!
export Advanced, Diagnostics, GraphEditor, EnvironmentAPI, Evaluation

# Re-exporting PlantMeteo main functions:
export Atmosphere, Constants, Weather

end
