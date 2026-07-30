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

PlantSimEngine.inputs_(m::ToyInternodeCrazyEmergence) = (TT_cu=Required(Float64),)
PlantSimEngine.outputs_(m::ToyInternodeCrazyEmergence) = (TT_cu_emergence=0.0,)

function PlantSimEngine.run!(m::ToyInternodeCrazyEmergence, status, environment, constants=nothing, context=nothing)

    model = runtime_model(context)

    #root = get_root(status.node)

    #if nleaves(root) > 10000
    #    return nothing
    #end

    if length(MultiScaleTreeGraph.children(status.node)) == 1 && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence

        status_new_internode = add_organ!(status.node, model, "<", :Internode, 2; index=1, initial_status=(carbon_biomass=1.0, TT_cu_emergence=0.0))
        add_organ!(status_new_internode.node, model, "+", :Leaf, 2; index=1, initial_status=(carbon_biomass=1.0,))
        status_new_internode.TT_cu_emergence = status.TT_cu
    elseif (length(MultiScaleTreeGraph.children(status.node)) >= 2 && length(MultiScaleTreeGraph.children(status.node)) < 7) && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence
        status_new_internode = add_organ!(status.node, model, "<", :Internode, 2; index=1, initial_status=(carbon_biomass=1.0, TT_cu_emergence=0.0))
        add_organ!(status.node, model, "+", :Leaf, 2; index=4, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=5, initial_status=(carbon_biomass=1.0,))
        status_new_internode.TT_cu_emergence = status.TT_cu
    elseif (length(MultiScaleTreeGraph.children(status.node)) >= 7 && length(MultiScaleTreeGraph.children(status.node)) < 30) && status.TT_cu - status.TT_cu_emergence >= m.TT_emergence
        add_organ!(status.node, model, "+", :Leaf, 2; index=6, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=7, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=8, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=9, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=10, initial_status=(carbon_biomass=1.0,))
        add_organ!(status.node, model, "+", :Leaf, 2; index=11, initial_status=(carbon_biomass=1.0,))

    end

    return nothing
end


function _benchmark_mtg_status(node)
    data = Dict{Symbol,Any}(:node => node)
    scale = MultiScaleTreeGraph.symbol(node)
    scale in (:Leaf, :Internode) && (data[:carbon_biomass] = 1.0)
    scale == :Plant && (data[:carbon_allocation] = zeros(4))
    return Status((; data...))
end

function setup_heavier_model_benchmark()
    mtg = import_mtg_example()

    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
    applications = (
        ModelSpec(ToyDegreeDaysCumulModel(); name=:scene_degree_days, on=One(scale=:Scene)),
        ModelSpec(ToyLAIModel(); name=:plant_lai, on=Many(scale=:Plant), inputs=(:TT_cu => One(scale=:Scene, within=SceneScope(), application=:scene_degree_days, var=:TT_cu))),
        ModelSpec(PlantSimEngine.Examples.Beer(0.6); name=:plant_light, on=Many(scale=:Plant)),
        ModelSpec(ToyPlantRmModel(); name=:plant_rm, on=Many(scale=:Plant), inputs=(:Rm_organs => Many(scale=(:Leaf, :Internode), within=Subtree(), var=:Rm))),
        ModelSpec(ToyCAllocationModel(); name=:plant_allocation, on=Many(scale=:Plant), inputs=(:carbon_assimilation => Many(scale=:Leaf, within=Subtree(), application=:leaf_assimilation, var=:carbon_assimilation),
                :carbon_demand => Many(scale=(:Leaf, :Internode), within=Subtree(), var=:carbon_demand),)),
        ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0); name=:internode_demand, on=Many(scale=:Internode), inputs=(:TT => One(scale=:Scene, within=SceneScope(), application=:scene_degree_days, var=:TT))),
        ModelSpec(ToyInternodeCrazyEmergence(TT_emergence=1.0); name=:internode_emergence, on=Many(scale=:Internode), inputs=(:TT_cu => One(scale=:Scene, within=SceneScope(), application=:scene_degree_days, var=:TT_cu))),
        ModelSpec(ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004); name=:internode_respiration, on=Many(scale=:Internode)),
        ModelSpec(ToyAssimModel(); name=:leaf_assimilation, on=Many(scale=:Leaf), inputs=(:soil_water_content => One(scale=:Soil, within=SceneScope(), application=:soil_water, var=:soil_water_content),
                :aPPFD => One(scale=:Plant, within=Ancestor(scale=:Plant), application=:plant_light, var=:aPPFD),)),
        ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0); name=:leaf_demand, on=Many(scale=:Leaf), inputs=(:TT => One(scale=:Scene, within=SceneScope(), application=:scene_degree_days, var=:TT))),
        ModelSpec(ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025); name=:leaf_respiration, on=Many(scale=:Leaf)),
        ModelSpec(ToySoilWaterModel(); name=:soil_water, on=One(scale=:Soil)),
    )

    model = CompositeModel(
        mtg;
        applications=applications,
        environment=meteo_day,
        status=_benchmark_mtg_status,
    )
    requests = OutputRequest[
        OutputRequest(:Leaf, :carbon_assimilation; name=:leaf_assimilation, application=:leaf_assimilation),
        OutputRequest(:Leaf, :carbon_demand; name=:leaf_demand, application=:leaf_demand),
        OutputRequest(:Internode, :TT_cu_emergence; name=:internode_emergence, application=:internode_emergence),
        OutputRequest(:Plant, :carbon_offer; name=:plant_carbon_offer, application=:plant_allocation),
        OutputRequest(:Soil, :soil_water_content; name=:soil_water, application=:soil_water),
    ]
    return model, requests, length(meteo_day)
end

function benchmark_heavier_scene(model, requests, nsteps)
    return run!(model; steps=nsteps, outputs=requests)
end

function do_benchmark_on_heavier_mtg()
    model, requests, nsteps = setup_heavier_model_benchmark()
    return benchmark_heavier_scene(model, requests, nsteps)
end
