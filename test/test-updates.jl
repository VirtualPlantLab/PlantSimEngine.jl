using Dates

PlantSimEngine.@process "update_carbon_allocation" verbose = false
PlantSimEngine.@process "update_leaf_pruning" verbose = false
PlantSimEngine.@process "update_leaf_senescence" verbose = false
PlantSimEngine.@process "update_biomass_observer" verbose = false

struct UpdateCarbonAllocationModel <: AbstractUpdate_Carbon_AllocationModel end
PlantSimEngine.inputs_(::UpdateCarbonAllocationModel) = NamedTuple()
PlantSimEngine.outputs_(::UpdateCarbonAllocationModel) = (leaf_biomass=0.0,)
function PlantSimEngine.run!(::UpdateCarbonAllocationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_biomass = 10.0
    return nothing
end

struct UpdateLeafPruningModel <: AbstractUpdate_Leaf_PruningModel end
PlantSimEngine.inputs_(::UpdateLeafPruningModel) = NamedTuple()
PlantSimEngine.outputs_(::UpdateLeafPruningModel) = (leaf_biomass=0.0,)
function PlantSimEngine.run!(::UpdateLeafPruningModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_biomass = 0.0
    return nothing
end

struct UpdateLeafSenescenceModel <: AbstractUpdate_Leaf_SenescenceModel end
PlantSimEngine.inputs_(::UpdateLeafSenescenceModel) = NamedTuple()
PlantSimEngine.outputs_(::UpdateLeafSenescenceModel) = (leaf_biomass=0.0,)
function PlantSimEngine.run!(::UpdateLeafSenescenceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_biomass *= 0.5
    return nothing
end

struct UpdateBiomassObserverModel <: AbstractUpdate_Biomass_ObserverModel end
PlantSimEngine.inputs_(::UpdateBiomassObserverModel) = (leaf_biomass=0.0,)
PlantSimEngine.outputs_(::UpdateBiomassObserverModel) = (observed_biomass=0.0,)
function PlantSimEngine.run!(::UpdateBiomassObserverModel, models, status, meteo, constants=nothing, extra=nothing)
    status.observed_biomass = status.leaf_biomass
    return nothing
end

@testset "ModelSpec Updates" begin
    meteo = Atmosphere(T=20.0, Rh=0.65, Wind=1.0, duration=Dates.Hour(1))

    @test_throws "Ambiguous canonical writers" ModelMapping(
        UpdateCarbonAllocationModel(),
        UpdateLeafPruningModel(),
        status=(leaf_biomass=1.0,),
    )

    mapping = ModelMapping(
        UpdateCarbonAllocationModel(),
        ModelSpec(UpdateLeafPruningModel()) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        UpdateBiomassObserverModel(),
        status=(leaf_biomass=1.0, observed_biomass=-1.0),
    )

    outputs = run!(mapping, meteo; executor=SequentialEx())
    @test only(outputs[:leaf_biomass]) == 0.0
    @test only(outputs[:observed_biomass]) == 0.0

    graph_nodes = PlantSimEngine.traverse_dependency_graph(dep(mapping), false)
    pruning_node = only(filter(node -> node.process == :update_leaf_pruning, graph_nodes))
    @test any(parent -> parent.process == :update_carbon_allocation, pruning_node.parent)

    @test_throws "without an ordering relation" ModelMapping(
        UpdateCarbonAllocationModel(),
        ModelSpec(UpdateLeafPruningModel()) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        ModelSpec(UpdateLeafSenescenceModel()) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        status=(leaf_biomass=1.0,),
    )

    ordered_updates = ModelMapping(
        UpdateCarbonAllocationModel(),
        ModelSpec(UpdateLeafSenescenceModel()) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        ModelSpec(UpdateLeafPruningModel()) |>
        Updates(:leaf_biomass; after=(:update_carbon_allocation, :update_leaf_senescence)),
        UpdateBiomassObserverModel(),
        status=(leaf_biomass=1.0, observed_biomass=-1.0),
    )
    ordered_outputs = run!(ordered_updates, meteo; executor=SequentialEx())
    @test only(ordered_outputs[:leaf_biomass]) == 0.0
    @test only(ordered_outputs[:observed_biomass]) == 0.0
end
