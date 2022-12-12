module PlantSimEngine

import DataFrames
import Tables

# For tree dependency:
import AbstractTrees
import Term
import Markdown

# For MTG compatibility:
import MultiScaleTreeGraph

# To compute mean:
import Statistics

using PlantMeteo

include("Abstract_model_structs.jl")
include("component_models/Status.jl")
include("component_models/TimeStepTable.jl")
include("component_models/ModelList.jl")
include("component_models/get_status.jl")
include("dataframe.jl")
include("mtg/mtg_helpers.jl")
include("mtg/init_mtg_models.jl")
include("evaluation/statistics.jl")
include("processes/models_dependency.jl")
include("processes/model_initialisation.jl")
include("processes/models_inputs_outputs.jl")
include("processes/process_methods_generation.jl")
include("checks/dimensions.jl")

export AbstractModel
export AbstractModelList
export ModelList
export init_mtg_models!
export RMSE, NRMSE, EF, dr
export Status, TimeStepTable, status
export init_status!
export @gen_process_methods
export to_initialize, is_initialized, init_variables, dep
export inputs, outputs

# Re-exporting PlantMeteo main functions:
export Atmosphere, Weather, Constants

end
