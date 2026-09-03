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
import Random
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
include("variable_contracts.jl")
include("authoring_interface.jl")

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

# Reconstructible source for authored CompositeModel scenarios:
include("scenario_source.jl")

# Public model-authoring and scenario-inspection reports:
include("authoring.jl")

# Fitting
include("evaluation/fit.jl")

"""
    PlantSimEngine.Authoring

Stable model discovery, exact instance descriptions, interface comparison, and
structured model/scenario validation for model authors and tooling.
"""
module Authoring
import ..PlantSimEngine:
    AUTHORING_SCHEMA_VERSION,
    ModelInterface,
    ValidationDiagnostic,
    ModelParameterDescription,
    ModelPortDescription,
    ModelDependencyDescription,
    ModelDescription,
    ModelDifference,
    ModelComparison,
    ModelValidationReport,
    ScenarioValidationReport,
    available_processes,
    available_models,
    describe_model,
    model_interface,
    compare_models,
    validate_model,
    validate_scenario,
    model_metadata,
    parameter_metadata,
    scenario_source,
    compiled_model_source,
    write_compiled_model_source,
    to_dict,
    to_json

const SCHEMA_VERSION = AUTHORING_SCHEMA_VERSION

export SCHEMA_VERSION
export ModelInterface, ModelDescription, ModelParameterDescription
export ModelPortDescription, ModelDependencyDescription
export ModelDifference, ModelComparison
export ValidationDiagnostic, ModelValidationReport, ScenarioValidationReport
export available_processes, available_models
export describe_model, model_interface, compare_models
export validate_model, validate_scenario, model_metadata, parameter_metadata
export scenario_source, compiled_model_source, write_compiled_model_source
export to_dict, to_json
end

"""
    PlantSimEngine.Advanced

Qualified compiler, cache, and low-level runtime extension APIs. These symbols
are available for diagnostics, package integration, and compiler development,
but are intentionally not part of the default user namespace.
"""
module Advanced
import ..PlantSimEngine:
    ObjectRegistry,
    LifecycleObjectSnapshot,
    LifecycleReparentEvent,
    LifecycleMoveEvent,
    LifecycleDelta,
    CompiledApplicationPlan,
    CompiledModelInputPlan,
    CompiledModelCallPlan,
    CompiledModelOutputDestinationPlan,
    CompiledScenarioPlan,
    CompiledCompositeModel,
    CompiledModelApplication,
    CompiledModelInputBinding,
    CompiledModelCallBinding,
    CompiledModelOutputDestinationBinding,
    CompiledDistributedOutputPlans,
    CompiledDistributedOutputs,
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
    lifecycle_delta,
    model_revision,
    environment_revision,
    compiled_bindings,
    compiled_environment_bindings,
    RuntimePerformanceCounters,
    runtime_performance

export ObjectRegistry
export LifecycleObjectSnapshot, LifecycleReparentEvent, LifecycleMoveEvent
export LifecycleDelta, lifecycle_delta
export CompiledApplicationPlan, CompiledModelInputPlan, CompiledModelCallPlan
export CompiledModelOutputDestinationPlan
export CompiledScenarioPlan
export CompiledCompositeModel, CompiledModelApplication
export CompiledModelInputBinding, CompiledModelCallBinding
export CompiledModelOutputDestinationBinding
export CompiledDistributedOutputPlans, CompiledDistributedOutputs
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
    explain_output_bindings,
    explain_writers,
    input_carrier,
    input_value,
    has_reference_carrier,
    explain_outputs,
    explain_initialization,
    explain_execution_plan,
    explain_runtime_performance,
    explain_output_retention,
    explain_environment_bindings,
    explain_schedule,
    explain_environment

export ObjectAddress, object_address
export explain_objects, explain_instances, explain_scopes
export explain_applications, explain_bindings, explain_calls, explain_writers
export explain_output_bindings
export input_carrier, input_value, has_reference_carrier
export explain_outputs, explain_initialization, explain_execution_plan
export explain_runtime_performance
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
    ModelGraphDiagnostic,
    ModelGraphView,
    compile_model_graph,
    model_graph_view,
    model_graph_view_json,
    model_graph_view_html,
    write_model_graph_view,
    AbstractModelGraphEdit,
    ModelApplicationRef,
    GlobalApplicationRef,
    TemplateApplicationRef,
    AddModelApplication,
    RemoveModelApplication,
    ReplaceModelApplicationModel,
    UpdateModelApplication,
    RenameModelApplication,
    SetModelApplicationTargets,
    SetModelInputBinding,
    RemoveModelInputBinding,
    SetModelCallBinding,
    RemoveModelCallBinding,
    SetModelApplicationCadence,
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
    AddModelInstance,
    RemoveModelInstance,
    SetCompositeModelEnvironment,
    apply_model_graph_edit,
    AbstractModelGraphEditorSession,
    edit_graph,
    current_model,
    apply_edit!,
    undo!,
    redo!

export ModelGraphDiagnostic, ModelGraphView
export compile_model_graph, model_graph_view
export model_graph_view_json, model_graph_view_html, write_model_graph_view
export AbstractModelGraphEdit, ModelApplicationRef
export GlobalApplicationRef, TemplateApplicationRef
export AddModelApplication, RemoveModelApplication, ReplaceModelApplicationModel
export UpdateModelApplication
export RenameModelApplication, SetModelApplicationTargets
export SetModelInputBinding, RemoveModelInputBinding
export SetModelCallBinding, RemoveModelCallBinding
export SetModelApplicationCadence, SetModelApplicationEnvironment
export SetModelOutputRouting, SetModelUpdateOrdering
export MarkModelPreviousTimeStep, UnmarkModelPreviousTimeStep, BreakModelCycle
export AddModelObject, RemoveModelObject, ReparentModelObject
export SetModelObjectStatus, SetModelObjectStatuses, RemoveModelObjectStatus
export SetModelObjectMetadata, SetModelInstanceOverride, RemoveModelInstanceOverride
export SetModelObjectOverride, RemoveModelObjectOverride, apply_model_graph_edit
export AddModelInstance, RemoveModelInstance, SetCompositeModelEnvironment
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

# Examples are loaded after the public namespaces so shipped extension examples
# use the same qualified API as downstream packages.
include("examples_import.jl")

export PreviousTimeStep
export AbstractModel
export ClockSpec
export SchedulePolicy, HoldLast, Interpolate, Integrate, Aggregate
export OutputRequest, collect_outputs
export CompositeModel, Object, ObjectId, CompositeModelTemplate, ObjectInstance, Override
export add_organ!, register_object!, remove_object!, reparent_object!, move_object!, update_geometry!
export mark_environment_binding_dirty!
export objects_from_mtg, object_id, object_ids, model_object, model_status, source_node
export model_objects, resolve_object_ids, resolve_objects
export geometry, position, bounds
export RunContext, CallTarget, CallTargets, Simulation, BoundMany, OutputTargets
export runtime_model, current_step, final_state, outputs
export SceneScope, Self, Subtree, SelfPlant, Ancestor, Scope, Relation
export One, OptionalOne, Many
export Input, Call, Initializer, Environment
export application_name, applies_to, value_inputs, model_calls, outputs_to
export environment_config
export ModelSpec, OutputTo, Updates
export call_targets, call_model, run_call!, run_initializer!, commit_environment!
export bound_input, output_targets, assign_outputs!
export Status
export Required, Default
export VariableContract, variable_contracts
export @process, process
export init_variables, dep
export inputs, outputs, variables
export timespec, output_policy, timestep_hint, environment_hint
export environment_bindings, environment_window, output_routing, updates
export environment_inputs, environment_outputs
export validate_environment_inputs
export run!, continue!, step!
export Authoring, Advanced, Diagnostics, GraphEditor, EnvironmentAPI, Evaluation

# Re-exporting PlantMeteo main functions:
export Atmosphere, Constants, Weather

end
