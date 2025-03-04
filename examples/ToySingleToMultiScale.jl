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

# Single-scale simulation
models_singlescale = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

out_singlescale = run!(models_singlescale, meteo_day)

# Direct translation of the single-scale simulation
mapping_pseudo_multiscale = Dict(
"Plant" => (
   ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    Status(TT_cu=cumsum(meteo_day.TT),)
    ),
)

mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 0),)
#plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))

# will generate an error as vectors can't be directly passed into a Status in multi-scale simulations
out_pseudo_multiscale = run!(mtg, mapping_pseudo_multiscale, meteo_day)


# TODO This seems to have a bug, generates an error
mapping_2 = PlantSimEngine.replace_mapping_status_vectors_with_generated_models(mapping_pseudo_multiscale, "Plant", PlantSimEngine.get_nsteps(meteo_day))
#=new_status, generated_models = PlantSimEngine.generate_model_from_status_vector_variable(mapping_pseudo_multiscale, "Plant",  Status(TT_cu=cumsum(meteo_day.TT)), "Plant", PlantSimEngine.get_nsteps(meteo_day))
mapping_pseudo_multiscale_adjusted = Dict("Plant" => (
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2), generated_models..., 
    PlantSimEngine.HelperNextTimestepModel(),
    MultiScaleModel(
        model=PlantSimEngine.HelperCurrentTimestepModel(),
        mapped_variables=[PreviousTimeStep(:next_timestep),],
        ),
        new_status,
),
)
out_pseudo_multiscale = run!(mtg, mapping_pseudo_multiscale_adjusted, meteo_day)
=#



# Actual multiscale version of the single-scale simulation

mapping_multiscale = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
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

# The previous mtg wasn't affected, but it is good practice to avoid unnecessarily mixing data between simulations
mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
out_multiscale = run!(mtg, mapping_multiscale, meteo_day)


#out_dataframe_multiscale = collect(Base.Iterators.flatten(out_multiscale["Plant"][:TT_cu]))
#out_singlescale.TT_cu