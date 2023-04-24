module PlantSimEngine

# FOr data formatting:
import DataFrames
import Tables

import CSV # For reading csv files with variables()

# For graph dependency:
import AbstractTrees
import Term
import Markdown

# For multi-threading:
import FLoops: @floop, ThreadedEx, SequentialEx

# For MTG compatibility:
import MultiScaleTreeGraph

# To compute mean:
import Statistics

using PlantMeteo

# Models:
include("Abstract_model_structs.jl")

# Simulation row (status):
include("component_models/Status.jl")

# Simulation table (time-step table, from PlantMeteo):
include("component_models/TimeStepTable.jl")

# List of models:
include("component_models/ModelList.jl")

# Getters / setters for status:
include("component_models/get_status.jl")

# Transform into a dataframe:
include("dataframe.jl")

# MTG compatibility:
include("mtg/mtg_helpers.jl")
include("mtg/init_mtg_models.jl")

# Model evaluation (statistics):
include("evaluation/statistics.jl")

# Tables traits
include("table_traits.jl")

# Model dependencies:
include("dependencies/dependency_graph.jl")
include("dependencies/soft_dependencies.jl")
include("dependencies/hard_dependencies.jl")
include("dependencies/dependencies.jl")

# Processes:
include("processes/model_initialisation.jl")
include("processes/models_inputs_outputs.jl")
include("processes/process_generation.jl")
include("checks/dimensions.jl")

# Simulation:
include("run.jl")

# Fitting
include("evaluation/fit.jl")

export AbstractModel
export ModelList
export init_mtg_models!
export RMSE, NRMSE, EF, dr
export Status, TimeStepTable, status
export init_status!
export @process, process
export to_initialize, is_initialized, init_variables, dep
export inputs, outputs, variables
export run!
export fit

# Re-exporting PlantMeteo main functions:
export Atmosphere, TimeStepTable, Constants, Weather

end
