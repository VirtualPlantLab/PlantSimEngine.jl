module PlantSimEngine

# FOr data formatting:
import DataFrames
import Tables
import DataAPI
import Dates

import CSV # For reading csv files with variables()

# For graph dependency:
import AbstractTrees
import Term
import Markdown

# For multi-threading:
import FLoops: @floop, @init, ThreadedEx, SequentialEx, DistributedEx

# For MTG compatibility:
import MultiScaleTreeGraph
import MultiScaleTreeGraph: symbol, node_id

# To compute mean:
import Statistics

# For avoiding name conflicts when generating models from status vectors
import SHA: sha1

using PlantMeteo

# UninitializedVar + PreviousTimeStep:
include("variables_wrappers.jl")

# Docs templates:
include("doc_templates/mtg-related.jl")

# Models:
include("Abstract_model_structs.jl")

# Multi-rate scaffolding:
include("time/multirate.jl")

# Simulation row (status):
include("component_models/Status.jl")
include("component_models/RefVector.jl")

# Simulation table (time-step table, from PlantMeteo):
include("component_models/TimeStepTable.jl")

# Declaring the dependency graph
include("dependencies/dependency_graph.jl")

# List of models:
include("component_models/ModelList.jl")
include("mtg/MultiScaleModel.jl")
include("mtg/ModelSpec.jl")

# Getters / setters for status:
include("component_models/get_status.jl")

# Transform into a dataframe:
include("dataframe.jl")

# Computing model dependencies:
include("dependencies/soft_dependencies.jl")
include("dependencies/hard_dependencies.jl")
include("dependencies/traversal.jl")
include("dependencies/is_graph_cyclic.jl")
include("dependencies/printing.jl")
include("dependencies/dependencies.jl")
include("dependencies/get_model_in_dependency_graph.jl")

# MTG compatibility:
include("mtg/GraphSimulation.jl")
include("mtg/mapping/getters.jl")
include("mtg/mapping/mapping.jl")
include("mtg/mapping/compute_mapping.jl")
include("mtg/mapping/reverse_mapping.jl")
include("mtg/model_spec_validation.jl")
include("mtg/initialisation.jl")
include("mtg/save_results.jl")
include("mtg/add_organ.jl")

# Model evaluation (statistics):
include("evaluation/statistics.jl")

# Traits
include("traits/table_traits.jl")
include("traits/parallel_traits.jl")

# Processes:
include("processes/model_initialisation.jl")
include("processes/models_inputs_outputs.jl")
include("processes/process_generation.jl")
include("checks/dimensions.jl")

# Multi-rate runtime:
include("time/runtime/clocks.jl")
include("time/runtime/scopes.jl")
include("time/runtime/bindings.jl")
include("time/runtime/input_resolution.jl")
include("time/runtime/publishers.jl")
include("time/runtime/output_export.jl")
include("time/runtime/meteo_sampling.jl")

# Simulation:
include("run.jl")

# Fitting
include("evaluation/fit.jl")

# Utilities for mapping initialisation
include("mtg/mapping/model_generation_from_status_vectors.jl")

# Examples
include("examples_import.jl")

export PreviousTimeStep
export AbstractModel
export ScopeId, ClockSpec, ModelKey, OutputKey
export SchedulePolicy, HoldLast, Interpolate, Integrate, Aggregate
export AbstractTimeReducer, MeanWeighted, MeanReducer, SumReducer, MinReducer, MaxReducer, FirstReducer, LastReducer, RadiationEnergy
export OutputCache, HoldLastCache, InterpolateCache, IntegrateCache, AggregateCache
export TemporalState
export OutputRequest, collect_outputs
export ModelList, MultiScaleModel, ModelSpec, TimeStepModel, InputBindings, MeteoBindings, MeteoWindow, OutputRouting, ScopeModel
export RMSE, NRMSE, EF, dr
export Status, TimeStepTable, status
export init_status!
export add_organ!
export @process, process
export to_initialize, is_initialized, init_variables, dep
export inputs, outputs, variables, convert_outputs
export timespec, output_policy, input_bindings, meteo_bindings, meteo_window, output_routing, model_scope
export run!
export fit

# Re-exporting PlantMeteo main functions:
export Atmosphere, TimeStepTable, Constants, Weather

# Re-exporting FLoops executors:
export SequentialEx, ThreadedEx, DistributedEx
end
