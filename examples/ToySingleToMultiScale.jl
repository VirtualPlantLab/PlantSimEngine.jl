##############################
### Example single- to multi-scale conversion
##############################

# Environment setup
using CSV
using DataFrames
using PlantSimEngine
using PlantMeteo
using PlantSimEngine.Examples
using MultiScaleTreeGraph

# Weather data for all simulations
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

##############################
### Single-scale simulation
##############################

models_singlescale = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

outputs_singlescale = run!(models_singlescale, meteo_day)

##############################
#### Direct translation of the single-scale simulation
##############################
mapping_pseudo_multiscale = Dict(
"Plant" => (
   ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    Status(TT_cu=cumsum(meteo_day.TT),)
    ),
)

mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 0),)

# will generate an error as vectors can't be directly passed into a Status in multi-scale simulations
out_pseudo_multiscale = run!(mtg, mapping_pseudo_multiscale, meteo_day)

##############################
#### Ad Hoc Cumulated Thermal Time Model
##############################

PlantSimEngine.@process "tt_cu" verbose = false

struct ToyTt_CuModel <: AbstractTt_CuModel
end

function PlantSimEngine.run!(::ToyTt_CuModel, models, status, meteo, constants, extra=nothing)
    status.TT_cu +=
        meteo.TT
end

function PlantSimEngine.inputs_(::ToyTt_CuModel)
    NamedTuple()
end

function PlantSimEngine.outputs_(::ToyTt_CuModel)
    (TT_cu=-Inf,)
end

##############################
#### Actual multiscale version of the single-scale simulation
##############################

mapping_multiscale = Dict(
    "Scene" => (
        ToyTt_CuModel(),
        Status(TT_cu=0.0),
    ),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.5),
        ToyRUEGrowthModel(0.2),
    ),
)

# We now need two nodes for our MTG
mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))   
    plant = MultiScaleTreeGraph.Node(mtg_multiscale, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    outputs_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)

##############################
#### Output comparison
##############################

computed_TT_cu_multiscale = collect(Base.Iterators.flatten(outputs_multiscale["Scene"][:TT_cu]))

is_approx_equal_1 = true

for i in 1:length(computed_TT_cu_multiscale)
    if !(computed_TT_cu_multiscale[i] ≈ outputs_singlescale.TT_cu[i])
        is_approx_equal_1 = false
        break
    end
end

is_approx_equal_1

is_approx_equal_2 = length(unique(computed_TT_cu_multiscale .≈ outputs_singlescale.TT_cu)) == 1


# Note : it is also possible to get the weather data length via PlantSimEngine.get_nsteps(meteo_day)
# instead of checking for array length

is_perfectly_equal = length(unique(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)) == 1

(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)[104]
(computed_TT_cu_multiscale .== outputs_singlescale.TT_cu)[105]
