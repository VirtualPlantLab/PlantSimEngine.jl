 
using BenchmarkTools
using Dates

PlantSimEngine.@process "sleep" verbose = false

struct ToySleepModel <: AbstractSleepModel   
end

PlantSimEngine.inputs_(::ToySleepModel) = (a = -Inf,)
PlantSimEngine.outputs_(::ToySleepModel) = NamedTuple()

function PlantSimEngine.run!(m::ToySleepModel, models, status, meteo, constants=nothing, extra=nothing)
    # sleep for 0.01 seconds (not going to be perfectly accurate)
    Base.sleep(0.001)
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToySleepModel}) = PlantSimEngine.IsTimeStepIndependent()

@testset begin "Check number of threads"
    nthr = Threads.nthreads()
    @test nthr == 4
    
    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
    nrows = nrow(meteo_day)
    
    vc = [0 for i in 1:nrows]

    models1 = ModelList(process1=ToySleepModel(), status=(a=vc,))
    models2 = ModelList(process1=ToySleepModel(), status=(a=vc,))

    t_seq = @benchmark run!(models1, meteo_day; executor = SequentialEx())
    #t_seq = run!(models1, meteo_day; executor = SequentialEx())
    min_time_seq = minimum(t_seq).time 

    #time is in nanoseconds
    @test min_time_seq > nrows * 1000000

    t_mt = @benchmark run!(models2, meteo_day; executor = ThreadedEx())
    #t_mt = run!(models2, meteo_day; executor = ThreadedEx())
    min_time_mt = minimum(t_mt).time 

    @test min_time_mt > nrows * 1000000 / nthr

    # expecting mt to have some overhead
    @test nthr * min_time_mt > min_time_seq

    # todo DataFrame equals
    @test status(models1) == status(models2)
end


#############################################
### Simulation with many organs in the MTG (but only a few different types of organs)


PlantSimEngine.@process "organ_crazy_emergence" verbose = false

"""
    ToyInternodeCrazyEmergence(;init_TT=0.0, TT_emergence = 300)

Computes the organ emergence based on cumulated thermal time since last event.
"""
struct ToyInternodeCrazyEmergence <: AbstractOrgan_Crazy_EmergenceModel
    TT_emergence::Float64
end

ToyInternodeCrazyEmergence(; TT_emergence=300.0) = ToyInternodeCrazyEmergence(TT_emergence)

PlantSimEngine.inputs_(m::ToyInternodeCrazyEmergence) = (TT_cu=-Inf,)
PlantSimEngine.outputs_(m::ToyInternodeCrazyEmergence) = (TT_cu_emergence=0.0,)

function PlantSimEngine.run!(m::ToyInternodeCrazyEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    #root = get_root(status.node)

    #if nleaves(root) > 10000
    #    return nothing
    #end

    if length(MultiScaleTreeGraph.children(status.node)) == 1 && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence 
       
        status_new_internode = add_organ!(status.node, sim_object, "<", "Internode", 2, index=1)
        add_organ!(status_new_internode.node, sim_object, "+", "Leaf", 2, index=1)
        status_new_internode.TT_cu_emergence = status.TT_cu   
    elseif (length(MultiScaleTreeGraph.children(status.node)) >= 2 && length(MultiScaleTreeGraph.children(status.node)) < 7) && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence 
        status_new_internode = add_organ!(status.node, sim_object, "<", "Internode", 2, index=1)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=4)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=5)
        status_new_internode.TT_cu_emergence = status.TT_cu
    elseif (length(MultiScaleTreeGraph.children(status.node)) >= 7 && length(MultiScaleTreeGraph.children(status.node)) < 30) && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence 
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=6)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=7)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=8)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=9)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=10)
        add_organ!(status.node, sim_object, "+", "Leaf", 2, index=11)

    end

    return nothing
end


# Wrapped this into a function so that it doesn't plague the benchmark with variables on a global scope
#@check_allocs
function do_benchmark_on_heavier_mtg()
    mtg = import_mtg_example();

    # Example meteo, 365 timesteps :
    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
    
    #similar to the mtg growth test but with a much lower emergence threshold
    mapping = Dict(
        "Scene" => ToyDegreeDaysCumulModel(),
        "Plant" => (
            MultiScaleModel(
                model=ToyLAIModel(),
                mapping=[
                    :TT_cu => "Scene",
                ],
            ),
            Beer(0.6),
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    :carbon_assimilation => ["Leaf"],
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
        ),
        "Internode" => (
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapping=[:TT => "Scene",],
            ),
            MultiScaleModel(
                model=ToyInternodeCrazyEmergence(TT_emergence=1.0),
                mapping=[:TT_cu => "Scene"],
            ),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(carbon_biomass=1.0)
        ),
        "Leaf" => (
            MultiScaleModel(
                model=ToyAssimModel(),
                mapping=[:soil_water_content => "Soil", :aPPFD => "Plant"],
            ),
            MultiScaleModel(
                model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                mapping=[:TT => "Scene",],
            ),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            Status(carbon_biomass=1.0)
        ),
        "Soil" => (
            ToySoilWaterModel(),
        ),
    )
    
    out_vars = Dict(
        "Leaf" => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
        "Internode" => (:carbon_allocation, :TT_cu_emergence),
        "Plant" => (:carbon_allocation,),
        "Soil" => (:soil_water_content,),
    )
    
    out = run!(mtg, mapping, meteo_day, outputs=out_vars, executor=SequentialEx());
end