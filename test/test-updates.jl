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

function update_scene(applications...)
    Scene(
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(leaf_biomass=1.0, observed_biomass=-1.0),
        );
        applications=applications,
        environment=Atmosphere(
            T=20.0,
            Rh=0.65,
            Wind=1.0,
            duration=Dates.Hour(1),
        ),
    )
end

@testset "ModelSpec Updates" begin
    @test_throws "Ambiguous canonical writers" compile_scene(
        update_scene(
            ModelSpec(UpdateCarbonAllocationModel()) |> AppliesTo(One(scale=:Leaf)),
            ModelSpec(UpdateLeafPruningModel()) |> AppliesTo(One(scale=:Leaf)),
        ),
    )

    scene = update_scene(
        ModelSpec(UpdateCarbonAllocationModel()) |> AppliesTo(One(scale=:Leaf)),
        ModelSpec(UpdateLeafPruningModel()) |>
        AppliesTo(One(scale=:Leaf)) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        ModelSpec(UpdateBiomassObserverModel()) |> AppliesTo(One(scale=:Leaf)),
    )
    run!(scene)
    leaf = only(scene_objects(scene; scale=:Leaf))
    @test leaf.status.leaf_biomass == 0.0
    @test leaf.status.observed_biomass == 0.0

    @test_throws "without an ordering relation" compile_scene(
        update_scene(
            ModelSpec(UpdateCarbonAllocationModel()) |> AppliesTo(One(scale=:Leaf)),
            ModelSpec(UpdateLeafPruningModel()) |>
            AppliesTo(One(scale=:Leaf)) |>
            Updates(:leaf_biomass; after=:update_carbon_allocation),
            ModelSpec(UpdateLeafSenescenceModel()) |>
            AppliesTo(One(scale=:Leaf)) |>
            Updates(:leaf_biomass; after=:update_carbon_allocation),
        ),
    )

    ordered = update_scene(
        ModelSpec(UpdateCarbonAllocationModel()) |> AppliesTo(One(scale=:Leaf)),
        ModelSpec(UpdateLeafSenescenceModel()) |>
        AppliesTo(One(scale=:Leaf)) |>
        Updates(:leaf_biomass; after=:update_carbon_allocation),
        ModelSpec(UpdateLeafPruningModel()) |>
        AppliesTo(One(scale=:Leaf)) |>
        Updates(
            :leaf_biomass;
            after=(:update_carbon_allocation, :update_leaf_senescence),
        ),
        ModelSpec(UpdateBiomassObserverModel()) |> AppliesTo(One(scale=:Leaf)),
    )
    run!(ordered)
    ordered_leaf = only(scene_objects(ordered; scale=:Leaf))
    @test ordered_leaf.status.leaf_biomass == 0.0
    @test ordered_leaf.status.observed_biomass == 0.0
end
