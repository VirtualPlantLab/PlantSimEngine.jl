using Dates

PlantSimEngine.@process "domain_absorbed_radiation" verbose = false
PlantSimEngine.@process "domain_plant_transpiration" verbose = false
PlantSimEngine.@process "domain_soil_water" verbose = false
PlantSimEngine.@process "domain_soil_evaporation" verbose = false
PlantSimEngine.@process "domain_scene_evapotranspiration" verbose = false
PlantSimEngine.@process "domain_scene_plant_evapotranspiration" verbose = false
PlantSimEngine.@process "domain_hard_leaf_conductance" verbose = false
PlantSimEngine.@process "domain_hard_leaf_energy" verbose = false
PlantSimEngine.@process "domain_scene_conductance_sum" verbose = false
PlantSimEngine.@process "domain_hard_target_signal" verbose = false
PlantSimEngine.@process "domain_scene_hard_target_sum" verbose = false
PlantSimEngine.@process "domain_hard_target_leaf_counter" verbose = false
PlantSimEngine.@process "domain_scene_hard_target_leaf_sum" verbose = false
PlantSimEngine.@process "domain_scene_routed_vector" verbose = false
PlantSimEngine.@process "domain_scene_routed_aggregate" verbose = false
PlantSimEngine.@process "domain_mtg_leaf_flux" verbose = false
PlantSimEngine.@process "domain_scene_dependency_flux_sum" verbose = false
PlantSimEngine.@process "domain_mtg_leaf_soil_flux" verbose = false
PlantSimEngine.@process "domain_growth_leaf_emergence" verbose = false
PlantSimEngine.@process "domain_growth_leaf_flux" verbose = false
PlantSimEngine.@process "domain_growth_integrated_flux" verbose = false
PlantSimEngine.@process "domain_scene_growth_flux_sum" verbose = false
PlantSimEngine.@process "domain_update_allocation" verbose = false
PlantSimEngine.@process "domain_update_pruning" verbose = false
PlantSimEngine.@process "domain_update_observer" verbose = false
PlantSimEngine.@process "domain_removal_leaf_flux" verbose = false
PlantSimEngine.@process "domain_removal_pruning" verbose = false
PlantSimEngine.@process "domain_churn_leaf_flux" verbose = false
PlantSimEngine.@process "domain_churn_leaf_controller" verbose = false
PlantSimEngine.@process "domain_subtree_internode_flux" verbose = false
PlantSimEngine.@process "domain_subtree_leaf_flux" verbose = false
PlantSimEngine.@process "domain_subtree_pruning" verbose = false
PlantSimEngine.@process "domain_reparent_leaf_controller" verbose = false

struct DomainAbsorbedRadiationModel <: AbstractDomain_Absorbed_RadiationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DomainAbsorbedRadiationModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainAbsorbedRadiationModel) = (absorbed_radiation=0.0,)
PlantSimEngine.meteo_inputs_(::DomainAbsorbedRadiationModel) = (Ri_PAR_f=0.0,)

function PlantSimEngine.run!(model::DomainAbsorbedRadiationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.absorbed_radiation = model.coefficient * meteo.Ri_PAR_f
    return nothing
end

struct DomainPlantTranspirationModel <: AbstractDomain_Plant_TranspirationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DomainPlantTranspirationModel) = (absorbed_radiation=0.0,)
PlantSimEngine.outputs_(::DomainPlantTranspirationModel) = (transpiration=0.0,)

function PlantSimEngine.run!(model::DomainPlantTranspirationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.transpiration = model.coefficient * status.absorbed_radiation
    return nothing
end

struct DomainSoilWaterModel <: AbstractDomain_Soil_WaterModel
    baseline::Float64
end

PlantSimEngine.inputs_(::DomainSoilWaterModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSoilWaterModel) = (soil_water_content=0.0,)
PlantSimEngine.meteo_inputs_(::DomainSoilWaterModel) = (T=0.0,)

function PlantSimEngine.run!(model::DomainSoilWaterModel, models, status, meteo, constants=nothing, extra=nothing)
    status.soil_water_content = model.baseline - 0.001 * meteo.T
    return nothing
end

struct DomainSoilEvaporationModel <: AbstractDomain_Soil_EvaporationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DomainSoilEvaporationModel) = (soil_water_content=0.0,)
PlantSimEngine.outputs_(::DomainSoilEvaporationModel) = (evaporation=0.0,)
PlantSimEngine.meteo_inputs_(::DomainSoilEvaporationModel) = (T=0.0,)

function PlantSimEngine.run!(model::DomainSoilEvaporationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.evaporation = model.coefficient * status.soil_water_content * meteo.T
    return nothing
end

struct DomainSceneEvapotranspirationModel <: AbstractDomain_Scene_EvapotranspirationModel
end

PlantSimEngine.inputs_(::DomainSceneEvapotranspirationModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneEvapotranspirationModel) = (evapotranspiration=0.0,)

PlantSimEngine.dep(::DomainSceneEvapotranspirationModel) = (
    plant_transpiration=AllDomains(kind=:plant, process=:domain_plant_transpiration, policy=Integrate()),
    soil_evaporation=AllDomains(kind=:soil, process=:domain_soil_evaporation, policy=Integrate()),
)

function PlantSimEngine.run!(::DomainSceneEvapotranspirationModel, models, status, meteo, constants=nothing, extra=nothing)
    plant_values = dependency_values(extra, :plant_transpiration, :transpiration)
    soil_values = dependency_values(extra, :soil_evaporation, :evaporation)
    status.evapotranspiration = sum(filter(x -> !isnothing(x), plant_values)) + sum(filter(x -> !isnothing(x), soil_values))
    return nothing
end

struct DomainScenePlantEvapotranspirationModel <: AbstractDomain_Scene_Plant_EvapotranspirationModel
end

PlantSimEngine.inputs_(::DomainScenePlantEvapotranspirationModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainScenePlantEvapotranspirationModel) = (plant_evapotranspiration=0.0,)

PlantSimEngine.dep(::DomainScenePlantEvapotranspirationModel) = (
    plant_transpiration=AllDomains(kind=:plant, process=:domain_plant_transpiration, policy=Integrate()),
)

function PlantSimEngine.run!(::DomainScenePlantEvapotranspirationModel, models, status, meteo, constants=nothing, extra=nothing)
    plant_values = dependency_values(extra, :plant_transpiration, :transpiration)
    status.plant_evapotranspiration = sum(filter(x -> !isnothing(x), plant_values))
    return nothing
end

struct DomainHardLeafConductanceModel <: AbstractDomain_Hard_Leaf_ConductanceModel
end

PlantSimEngine.inputs_(::DomainHardLeafConductanceModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainHardLeafConductanceModel) = (conductance=0.0,)

function PlantSimEngine.run!(::DomainHardLeafConductanceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.conductance = 2.0
    return nothing
end

struct DomainHardLeafEnergyModel <: AbstractDomain_Hard_Leaf_EnergyModel
end

PlantSimEngine.dep(::DomainHardLeafEnergyModel) = (domain_hard_leaf_conductance=AbstractDomain_Hard_Leaf_ConductanceModel,)
PlantSimEngine.inputs_(::DomainHardLeafEnergyModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainHardLeafEnergyModel) = (leaf_temperature=0.0,)

function PlantSimEngine.run!(::DomainHardLeafEnergyModel, models, status, meteo, constants=nothing, extra=nothing)
    run_target!(models, status, :domain_hard_leaf_conductance; meteo=meteo, constants=constants, extra=extra)
    status.leaf_temperature = 20.0 + status.conductance
    return nothing
end

struct DomainSceneConductanceSumModel <: AbstractDomain_Scene_Conductance_SumModel
end

PlantSimEngine.inputs_(::DomainSceneConductanceSumModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneConductanceSumModel) = (conductance_sum=0.0,)

PlantSimEngine.dep(::DomainSceneConductanceSumModel) = (
    conductance=AllDomains(kind=:plant, process=:domain_hard_leaf_conductance, var=:conductance, policy=Integrate()),
)

function PlantSimEngine.run!(::DomainSceneConductanceSumModel, models, status, meteo, constants=nothing, extra=nothing)
    conductance_values = dependency_values(extra, :conductance)
    status.conductance_sum = sum(filter(x -> !isnothing(x), conductance_values))
    return nothing
end

struct DomainHardTargetSignalModel{T} <: AbstractDomain_Hard_Target_SignalModel
    coefficient::T
end

PlantSimEngine.inputs_(::DomainHardTargetSignalModel) = (call_count=0,)
PlantSimEngine.outputs_(::DomainHardTargetSignalModel) = (call_count=0, signal=0.0,)

function PlantSimEngine.run!(model::DomainHardTargetSignalModel, models, status, meteo, constants=nothing, extra=nothing)
    status.call_count += 1
    status.signal = model.coefficient * status.call_count
    return nothing
end

struct DomainSceneHardTargetSumModel <: AbstractDomain_Scene_Hard_Target_SumModel end

PlantSimEngine.inputs_(::DomainSceneHardTargetSumModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneHardTargetSumModel) = (hard_target_total=0.0,)

PlantSimEngine.dep(::DomainSceneHardTargetSumModel) = (
    plant_signal=HardDomains(kind=:plant, process=:domain_hard_target_signal),
)

function PlantSimEngine.run!(::DomainSceneHardTargetSumModel, models, status, meteo, constants=nothing, extra=nothing)
    targets = dependency_targets(extra, :plant_signal)
    for target in targets
        run_target!(target)
        run_target!(target)
    end
    status.hard_target_total = sum(target.status.signal for target in targets)
    return nothing
end

struct DomainHardTargetLeafCounterModel{T} <: AbstractDomain_Hard_Target_Leaf_CounterModel
    coefficient::T
end

PlantSimEngine.inputs_(::DomainHardTargetLeafCounterModel) = (call_count=0,)
PlantSimEngine.outputs_(::DomainHardTargetLeafCounterModel) = (call_count=0, leaf_signal=0.0,)

function PlantSimEngine.run!(model::DomainHardTargetLeafCounterModel, models, status, meteo, constants=nothing, extra=nothing)
    status.call_count += 1
    status.leaf_signal = model.coefficient * status.call_count
    return nothing
end

struct DomainSceneHardTargetLeafSumModel <: AbstractDomain_Scene_Hard_Target_Leaf_SumModel end

PlantSimEngine.inputs_(::DomainSceneHardTargetLeafSumModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneHardTargetLeafSumModel) = (leaf_hard_target_total=0.0,)

PlantSimEngine.dep(::DomainSceneHardTargetLeafSumModel) = (
    leaf_calls=HardDomains(kind=:plant, scale=:Leaf, process=:domain_hard_target_leaf_counter),
)

function PlantSimEngine.run!(::DomainSceneHardTargetLeafSumModel, models, status, meteo, constants=nothing, extra=nothing)
    targets = dependency_targets(extra, :leaf_calls)
    for target in targets
        run_target!(target; publish=true)
    end
    status.leaf_hard_target_total = sum(target.status.leaf_signal for target in targets)
    return nothing
end

struct DomainSceneRoutedVectorModel <: AbstractDomain_Scene_Routed_VectorModel end

PlantSimEngine.inputs_(::DomainSceneRoutedVectorModel) = (plant_transpirations=Float64[],)
PlantSimEngine.outputs_(::DomainSceneRoutedVectorModel) = (routed_total=0.0,)

function PlantSimEngine.run!(::DomainSceneRoutedVectorModel, models, status, meteo, constants=nothing, extra=nothing)
    status.routed_total = sum(status.plant_transpirations)
    return nothing
end

struct DomainSceneRoutedAggregateModel <: AbstractDomain_Scene_Routed_AggregateModel end

PlantSimEngine.inputs_(::DomainSceneRoutedAggregateModel) = (daily_plant_transpiration=0.0,)
PlantSimEngine.outputs_(::DomainSceneRoutedAggregateModel) = (daily_routed_total=0.0,)

function PlantSimEngine.run!(::DomainSceneRoutedAggregateModel, models, status, meteo, constants=nothing, extra=nothing)
    status.daily_routed_total = status.daily_plant_transpiration
    return nothing
end

struct DomainMTGLeafFluxModel{T} <: AbstractDomain_Mtg_Leaf_FluxModel
    coefficient::T
end

PlantSimEngine.inputs_(::DomainMTGLeafFluxModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainMTGLeafFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(model::DomainMTGLeafFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = model.coefficient
    return nothing
end

struct DomainMTGLeafSoilFluxModel{T} <: AbstractDomain_Mtg_Leaf_Soil_FluxModel
    coefficient::T
end

PlantSimEngine.inputs_(::DomainMTGLeafSoilFluxModel) = (soil_signal=0.0,)
PlantSimEngine.outputs_(::DomainMTGLeafSoilFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(model::DomainMTGLeafSoilFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = model.coefficient * status.soil_signal
    return nothing
end

struct DomainGrowthLeafEmergenceModel <: AbstractDomain_Growth_Leaf_EmergenceModel end

PlantSimEngine.inputs_(::DomainGrowthLeafEmergenceModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainGrowthLeafEmergenceModel) = (grown_leaves=0.0,)

function PlantSimEngine.run!(::DomainGrowthLeafEmergenceModel, models, status, meteo, constants=nothing, extra=nothing)
    if length(PlantSimEngine.status(extra)[:Leaf]) == 0
        add_organ!(status.node, extra, "+", :Leaf, 2; check=true)
    end
    status.grown_leaves = length(PlantSimEngine.status(extra)[:Leaf])
    return nothing
end

struct DomainGrowthLeafFluxModel{T} <: AbstractDomain_Growth_Leaf_FluxModel
    coefficient::T
end

PlantSimEngine.inputs_(::DomainGrowthLeafFluxModel) = (grown_leaves=0.0,)
PlantSimEngine.outputs_(::DomainGrowthLeafFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(model::DomainGrowthLeafFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = model.coefficient * status.grown_leaves
    return nothing
end

struct DomainGrowthIntegratedFluxModel <: AbstractDomain_Growth_Integrated_FluxModel end

PlantSimEngine.inputs_(::DomainGrowthIntegratedFluxModel) = (leaf_flux=-Inf,)
PlantSimEngine.outputs_(::DomainGrowthIntegratedFluxModel) = (integrated_leaf_flux=0.0,)

function PlantSimEngine.run!(::DomainGrowthIntegratedFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.integrated_leaf_flux = sum(status.leaf_flux)
    return nothing
end

struct DomainSceneDependencyFluxSumModel <: AbstractDomain_Scene_Dependency_Flux_SumModel end

PlantSimEngine.inputs_(::DomainSceneDependencyFluxSumModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneDependencyFluxSumModel) = (dependency_total=0.0, grouped_dependency_total=0.0,)

PlantSimEngine.dep(::DomainSceneDependencyFluxSumModel) = (
    leaf_fluxes=AllDomains(kind=:plant, scale=:Leaf, process=:domain_mtg_leaf_flux, var=:leaf_flux),
)

function PlantSimEngine.run!(::DomainSceneDependencyFluxSumModel, models, status, meteo, constants=nothing, extra=nothing)
    grouped_values = dependency_values(extra, :leaf_fluxes)
    flattened_values = dependency_values(extra, :leaf_fluxes; flatten=true)
    status.grouped_dependency_total = sum(sum, grouped_values)
    status.dependency_total = sum(flattened_values)
    return nothing
end

struct DomainSceneGrowthFluxSumModel <: AbstractDomain_Scene_Growth_Flux_SumModel end

PlantSimEngine.inputs_(::DomainSceneGrowthFluxSumModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSceneGrowthFluxSumModel) = (growth_flux_total=0.0,)

PlantSimEngine.dep(::DomainSceneGrowthFluxSumModel) = (
    leaf_fluxes=AllDomains(kind=:plant, scale=:Leaf, process=:domain_growth_leaf_flux, var=:leaf_flux),
)

function PlantSimEngine.run!(::DomainSceneGrowthFluxSumModel, models, status, meteo, constants=nothing, extra=nothing)
    status.growth_flux_total = sum(dependency_values(extra, :leaf_fluxes; flatten=true))
    return nothing
end

struct DomainUpdateAllocationModel <: AbstractDomain_Update_AllocationModel end

PlantSimEngine.inputs_(::DomainUpdateAllocationModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainUpdateAllocationModel) = (leaf_biomass=0.0,)

function PlantSimEngine.run!(::DomainUpdateAllocationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_biomass = 10.0
    return nothing
end

struct DomainUpdatePruningModel <: AbstractDomain_Update_PruningModel end

PlantSimEngine.inputs_(::DomainUpdatePruningModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainUpdatePruningModel) = (leaf_biomass=0.0,)

function PlantSimEngine.run!(::DomainUpdatePruningModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_biomass = 0.0
    return nothing
end

struct DomainUpdateObserverModel <: AbstractDomain_Update_ObserverModel end

PlantSimEngine.inputs_(::DomainUpdateObserverModel) = (leaf_biomass=0.0,)
PlantSimEngine.outputs_(::DomainUpdateObserverModel) = (observed_biomass=0.0,)

function PlantSimEngine.run!(::DomainUpdateObserverModel, models, status, meteo, constants=nothing, extra=nothing)
    status.observed_biomass = status.leaf_biomass
    return nothing
end

struct DomainRemovalLeafFluxModel <: AbstractDomain_Removal_Leaf_FluxModel end

PlantSimEngine.inputs_(::DomainRemovalLeafFluxModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainRemovalLeafFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(::DomainRemovalLeafFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = 1.0
    return nothing
end

struct DomainRemovalPruningModel <: AbstractDomain_Removal_PruningModel end

PlantSimEngine.inputs_(::DomainRemovalPruningModel) = (leaf_flux=Float64[], removed_count=0, removed_node_id=0,)
PlantSimEngine.outputs_(::DomainRemovalPruningModel) = (remaining_leaf_flux=0.0, removed_count=0, removed_node_id=0,)

function PlantSimEngine.run!(::DomainRemovalPruningModel, models, status, meteo, constants=nothing, extra=nothing)
    if status.removed_count == 0 && length(status.leaf_flux) > 1
        leaf_status = first(PlantSimEngine.status(extra)[:Leaf])
        status.removed_node_id = node_id(leaf_status.node)
        remove_organ!(leaf_status.node, extra)
        status.removed_count = 1
    end
    status.remaining_leaf_flux = sum(status.leaf_flux)
    return nothing
end

struct DomainChurnLeafFluxModel <: AbstractDomain_Churn_Leaf_FluxModel end

PlantSimEngine.inputs_(::DomainChurnLeafFluxModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainChurnLeafFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(::DomainChurnLeafFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = 1.0
    return nothing
end

struct DomainChurnLeafControllerModel <: AbstractDomain_Churn_Leaf_ControllerModel end

PlantSimEngine.inputs_(::DomainChurnLeafControllerModel) = (
    leaf_flux=Float64[],
    created_count=0,
    removed_count=0,
    active_leaf_count=0,
    last_removed_node_id=0,
)
PlantSimEngine.outputs_(::DomainChurnLeafControllerModel) = (
    created_count=0,
    removed_count=0,
    active_leaf_count=0,
    last_removed_node_id=0,
)

function PlantSimEngine.run!(::DomainChurnLeafControllerModel, models, status, meteo, constants=nothing, extra=nothing)
    if isempty(status.leaf_flux)
        add_organ!(status.node, extra, "+", :Leaf, 2; check=true)
        status.created_count += 1
    else
        leaf_status = first(PlantSimEngine.status(extra)[:Leaf])
        status.last_removed_node_id = node_id(leaf_status.node)
        remove_organ!(leaf_status.node, extra)
        status.removed_count += 1
    end
    status.active_leaf_count = length(status.leaf_flux)
    return nothing
end

struct DomainSubtreeInternodeFluxModel <: AbstractDomain_Subtree_Internode_FluxModel end
struct DomainSubtreeLeafFluxModel <: AbstractDomain_Subtree_Leaf_FluxModel end

PlantSimEngine.inputs_(::DomainSubtreeInternodeFluxModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSubtreeInternodeFluxModel) = (internode_flux=0.0,)

function PlantSimEngine.run!(::DomainSubtreeInternodeFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.internode_flux = 2.0
    return nothing
end

PlantSimEngine.inputs_(::DomainSubtreeLeafFluxModel) = NamedTuple()
PlantSimEngine.outputs_(::DomainSubtreeLeafFluxModel) = (leaf_flux=0.0,)

function PlantSimEngine.run!(::DomainSubtreeLeafFluxModel, models, status, meteo, constants=nothing, extra=nothing)
    status.leaf_flux = 1.0
    return nothing
end

struct DomainSubtreePruningModel <: AbstractDomain_Subtree_PruningModel end

PlantSimEngine.inputs_(::DomainSubtreePruningModel) = (
    internode_flux=Float64[],
    leaf_flux=Float64[],
    removed_count=0,
    removed_internode_id=0,
    removed_leaf_id=0,
    remaining_internode_count=0,
    remaining_leaf_count=0,
)
PlantSimEngine.outputs_(::DomainSubtreePruningModel) = (
    removed_count=0,
    removed_internode_id=0,
    removed_leaf_id=0,
    remaining_internode_count=0,
    remaining_leaf_count=0,
)

function PlantSimEngine.run!(::DomainSubtreePruningModel, models, status, meteo, constants=nothing, extra=nothing)
    graph_status = PlantSimEngine.status(extra)
    if status.removed_count == 0 && !isempty(get(graph_status, :Internode, Status[]))
        internode_status = first(graph_status[:Internode])
        leaf_status = first(graph_status[:Leaf])
        status.removed_internode_id = node_id(internode_status.node)
        status.removed_leaf_id = node_id(leaf_status.node)
        remove_organ!(internode_status.node, extra; recursive=true)
        status.removed_count = 1
    end
    status.remaining_internode_count = length(status.internode_flux)
    status.remaining_leaf_count = length(status.leaf_flux)
    return nothing
end

struct DomainReparentLeafControllerModel <: AbstractDomain_Reparent_Leaf_ControllerModel end

PlantSimEngine.inputs_(::DomainReparentLeafControllerModel) = (
    leaf_flux=Float64[],
    reparented_count=0,
    new_parent_id=0,
    leaf_parent_id=0,
    active_leaf_count=0,
)
PlantSimEngine.outputs_(::DomainReparentLeafControllerModel) = (
    reparented_count=0,
    new_parent_id=0,
    leaf_parent_id=0,
    active_leaf_count=0,
)

function PlantSimEngine.run!(::DomainReparentLeafControllerModel, models, status, meteo, constants=nothing, extra=nothing)
    graph_status = PlantSimEngine.status(extra)
    if status.reparented_count == 0
        leaf_status = only(graph_status[:Leaf])
        new_parent_status = graph_status[:Internode][2]
        reparent_organ!(leaf_status.node, new_parent_status.node, extra)
        status.reparented_count = 1
        status.new_parent_id = node_id(new_parent_status.node)
    end
    leaf_status = only(graph_status[:Leaf])
    status.leaf_parent_id = node_id(parent(leaf_status.node))
    status.active_leaf_count = length(status.leaf_flux)
    return nothing
end

@testset "Domain simulation: two plants, soil, and daily scene aggregation" begin
    hourly_meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:25
    ])

    oil_palm_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.01)) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )

    maize_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.3)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.02)) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )

    soil_mapping = ModelMapping(
        ModelSpec(DomainSoilWaterModel(0.35)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainSoilEvaporationModel(0.2)) |> TimeStepModel(Dates.Hour(1)),
        status=(soil_water_content=0.0, evaporation=0.0),
    )

    scene_mapping = ModelMapping(
        ModelSpec(DomainSceneEvapotranspirationModel()) |> TimeStepModel(Dates.Day(1)),
        status=(evapotranspiration=0.0,),
    )

    simulation_mapping = SimulationMapping(
        Domain(:oil_palm, oil_palm_mapping; kind=:plant),
        Domain(:maize, maize_mapping; kind=:plant),
        Domain(:soil, soil_mapping; kind=:soil),
        Domain(:scene, scene_mapping; kind=:scene),
    )

    domain_rows = explain_domains(simulation_mapping)
    @test length(domain_rows) == 4
    @test any(row -> row.domain == :oil_palm && row.kind == :plant, domain_rows)

    model_rows = explain_domain_models(simulation_mapping)
    @test length(model_rows) == 7
    @test any(row -> row.domain == :oil_palm && row.process == :domain_absorbed_radiation && haskey(row.meteo_inputs, :Ri_PAR_f), model_rows)

    sim = run!(simulation_mapping, hourly_meteo, check=true)
    @test status(sim, :oil_palm).transpiration ≈ 0.01 * 0.5 * 100.0
    @test outputs(sim) === sim.outputs

    schedule = explain_schedule(sim)
    @test any(row -> row.domain == :scene && row.dt_seconds == 86_400.0, schedule)
    @test any(row -> row.domain == :oil_palm && row.dt_seconds == 3_600.0, schedule)

    deps = explain_domain_dependencies(sim)
    @test length(deps) == 3
    @test count(row -> row.dependency == :plant_transpiration, deps) == 2
    @test count(row -> row.dependency == :soil_evaporation, deps) == 1
    @test all(row -> isnothing(row.variable), deps)

    scene_key = DomainModelKey(:scene, :Default, :domain_scene_evapotranspiration)
    scene_values = sim.outputs[(scene_key, :evapotranspiration)]

    # Dates.Day(1) currently aligns to step 1, then step 25 when the base step is hourly.
    # The second scene value integrates producer values from steps 2:25.
    hourly_plant_sum = 0.01 * 0.5 * 100.0 + 0.02 * 0.3 * 100.0
    hourly_soil = 0.2 * (0.35 - 0.001 * 20.0) * 20.0
    expected_daily_et = 24.0 * (hourly_plant_sum + hourly_soil)

    @test length(scene_values) == 2
    @test scene_values[2] ≈ expected_daily_et
end

@testset "Domain simulation validation" begin
    hourly_meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    plant_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.01)) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )

    raw_domain = Domain(
        :plant_kw;
        kind=:plant,
        mapping=(
            ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
            ModelSpec(DomainPlantTranspirationModel(0.01)) |> TimeStepModel(Dates.Hour(1)),
            Status(absorbed_radiation=0.0, transpiration=0.0),
        ),
    )
    @test raw_domain.mapping isa ModelMapping

    @test_throws ErrorException SimulationMapping(
        Domain(:plant, plant_mapping; kind=:plant),
        Domain(:plant, plant_mapping; kind=:plant),
    )

    daily_meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:25
    ])
    mixed_rate_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.01)) |> TimeStepModel(Dates.Day(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )
    mixed_sim = run!(
        SimulationMapping(Domain(:mixed_plant, mixed_rate_mapping; kind=:plant)),
        daily_meteo,
        check=true,
    )
    absorbed_key = DomainModelKey(:mixed_plant, :Default, :domain_absorbed_radiation)
    transpiration_key = DomainModelKey(:mixed_plant, :Default, :domain_plant_transpiration)
    @test length(mixed_sim.outputs[(absorbed_key, :absorbed_radiation)]) == 25
    @test length(mixed_sim.outputs[(transpiration_key, :transpiration)]) == 2

    unmatched_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneEvapotranspirationModel()) |> TimeStepModel(Dates.Day(1)),
        status=(evapotranspiration=0.0,),
    )
    unmatched_error = try
        run!(
            SimulationMapping(Domain(:scene, unmatched_scene_mapping; kind=:scene)),
            hourly_meteo,
            check=true,
        )
        ""
    catch err
        sprint(showerror, err)
    end
    @test occursin("Domain dependency `plant_transpiration`", unmatched_error)
    @test occursin("consumer `scene/Default/domain_scene_evapotranspiration`", unmatched_error)
    @test occursin("AllDomains(kind=:plant, process=:domain_plant_transpiration, policy=Integrate())", unmatched_error)
    @test occursin("Available producers:", unmatched_error)

    multi_process_scene_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainScenePlantEvapotranspirationModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, plant_evapotranspiration=0.0),
    )
    multi_scene_sim = run!(
        SimulationMapping(
            Domain(:plant, plant_mapping; kind=:plant),
            Domain(:scene, multi_process_scene_mapping; kind=:scene),
        ),
        hourly_meteo,
        check=true,
    )
    @test status(multi_scene_sim, :scene).plant_evapotranspiration > 0.0

    hard_plant_mapping = ModelMapping(
        ModelSpec(DomainHardLeafConductanceModel()) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainHardLeafEnergyModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(conductance=0.0, leaf_temperature=0.0),
    )
    conductance_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneConductanceSumModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(conductance_sum=0.0,),
    )
    hard_sim = run!(
        SimulationMapping(
            Domain(:hard_plant, hard_plant_mapping; kind=:plant),
            Domain(:scene, conductance_scene_mapping; kind=:scene),
        ),
        hourly_meteo,
        check=true,
    )
    conductance_key = DomainModelKey(:hard_plant, :Default, :domain_hard_leaf_conductance)
    @test hard_sim.outputs[(conductance_key, :conductance)] == [2.0, 2.0]
    @test status(hard_sim, :scene).conductance_sum == 2.0
    hard_deps = explain_domain_dependencies(hard_sim)
    @test only(hard_deps).variable == :conductance

    hard_target_plant_mapping = ModelMapping(
        ModelSpec(DomainHardTargetSignalModel(2.0)) |> TimeStepModel(Dates.Hour(1)),
        status=(call_count=0, signal=0.0),
    )
    hard_target_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneHardTargetSumModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(hard_target_total=0.0,),
    )
    hard_target_sim = run!(
        SimulationMapping(
            Domain(:hard_target_plant, hard_target_plant_mapping; kind=:plant),
            Domain(:scene, hard_target_scene_mapping; kind=:scene),
        ),
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1)),
        check=true,
    )
    @test status(hard_target_sim, :hard_target_plant).call_count == 2
    @test status(hard_target_sim, :hard_target_plant).signal ≈ 4.0
    @test status(hard_target_sim, :scene).hard_target_total ≈ 4.0
    @test only(explain_domain_dependencies(hard_target_sim)).mode == :hard_domain

    route_source = AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:transpiration)
    bad_route_source = AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:missing_output)
    route_selector_error = try
        run!(
            SimulationMapping(
                Domain(:plant, plant_mapping; kind=:plant),
                Domain(:scene, multi_process_scene_mapping; kind=:scene);
                routes=(Route(
                    from=bad_route_source,
                    to=DomainRouteTarget(:scene, var=:plant_transpirations),
                ),),
            ),
            hourly_meteo,
            check=true,
        )
        ""
    catch err
        sprint(showerror, err)
    end
    @test occursin("Route 1 from `AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:missing_output)`", route_selector_error)
    @test occursin("Models matching all selector fields except `var=:missing_output`", route_selector_error)
    @test occursin("plant/Default/domain_plant_transpiration outputs=(:transpiration)", route_selector_error)

    missing_target_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedAggregateModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(daily_plant_transpiration=0.0, daily_routed_total=0.0),
    )
    @test_throws "does not contain variable `plant_transpirations`" run!(
        SimulationMapping(
            Domain(:plant, plant_mapping; kind=:plant),
            Domain(:scene, missing_target_scene_mapping; kind=:scene);
            routes=(Route(
                from=route_source,
                to=DomainRouteTarget(:scene, var=:plant_transpirations),
            ),),
        ),
        hourly_meteo,
        check=true,
    )

    wrong_process_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedAggregateModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(plant_transpirations=[0.0], daily_plant_transpiration=0.0, daily_routed_total=0.0),
    )
    @test_throws "does not consume variable `plant_transpirations`" run!(
        SimulationMapping(
            Domain(:plant, plant_mapping; kind=:plant),
            Domain(:scene, wrong_process_scene_mapping; kind=:scene);
            routes=(Route(
                from=route_source,
                to=DomainRouteTarget(:scene, var=:plant_transpirations, process=:domain_scene_routed_aggregate),
            ),),
        ),
        hourly_meteo,
        check=true,
    )

    @test_throws "has a selector but uses a single-status ModelMapping" run!(
        Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0)),
        SimulationMapping(Domain(:plant, plant_mapping; kind=:plant, selector=:Plant)),
        hourly_meteo,
        check=true,
    )
end

@testset "Domain simulation routes" begin
    hourly_meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:25
    ])

    oil_palm_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.01)) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )

    maize_mapping = ModelMapping(
        ModelSpec(DomainAbsorbedRadiationModel(0.3)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(DomainPlantTranspirationModel(0.02)) |> TimeStepModel(Dates.Hour(1)),
        status=(absorbed_radiation=0.0, transpiration=0.0),
    )

    hourly_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedVectorModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(plant_transpirations=[0.0], routed_total=0.0),
    )

    vector_route = Route(
        from=AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:transpiration),
        to=DomainRouteTarget(:scene, var=:plant_transpirations, process=:domain_scene_routed_vector),
        cardinality=ManyToOneVector(),
    )

    vector_sim = run!(
        SimulationMapping(
            Domain(:oil_palm, oil_palm_mapping; kind=:plant),
            Domain(:maize, maize_mapping; kind=:plant),
            Domain(:scene, hourly_scene_mapping; kind=:scene);
            routes=(vector_route,),
        ),
        hourly_meteo,
        check=true,
    )
    hourly_plant_sum = 0.01 * 0.5 * 100.0 + 0.02 * 0.3 * 100.0
    @test status(vector_sim, :scene).plant_transpirations ≈ [0.5, 0.6]
    @test status(vector_sim, :scene).routed_total ≈ hourly_plant_sum

    route_rows = explain_routes(vector_sim)
    @test length(route_rows) == 2
    @test all(row -> row.target_var == :plant_transpirations, route_rows)
    @test all(row -> row.cardinality == ManyToOneVector, route_rows)

    reordered_collector_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedVectorModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(plant_transpirations=[0.0], routed_total=0.0),
    )
    reordered_route = Route(
        from=AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:transpiration),
        to=DomainRouteTarget(:collector, var=:plant_transpirations, process=:domain_scene_routed_vector),
        cardinality=ManyToOneVector(),
    )
    reordered_sim = run!(
        SimulationMapping(
            Domain(:collector, reordered_collector_mapping; kind=:soil),
            Domain(:oil_palm, oil_palm_mapping; kind=:plant);
            routes=(reordered_route,),
        ),
        hourly_meteo,
        check=true,
    )
    @test status(reordered_sim, :collector).plant_transpirations ≈ [0.5]
    @test status(reordered_sim, :collector).routed_total ≈ 0.5

    cyclic_scene_source_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedVectorModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(plant_transpirations=[0.0], routed_total=0.0),
    )
    cyclic_route = Route(
        from=AllDomains(kind=:scene, process=:domain_scene_routed_vector, var=:routed_total),
        to=DomainRouteTarget(:oil_palm, var=:absorbed_radiation, process=:domain_plant_transpiration),
        cardinality=ManyToOneAggregate(sum),
    )
    @test_throws "Cyclic domain run-order constraints" run!(
        SimulationMapping(
            Domain(:oil_palm, oil_palm_mapping; kind=:plant),
            Domain(:scene, cyclic_scene_source_mapping; kind=:scene);
            routes=(cyclic_route,),
        ),
        hourly_meteo,
        check=true,
    )

    daily_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedAggregateModel()) |> TimeStepModel(Dates.Day(1)),
        status=(daily_plant_transpiration=0.0, daily_routed_total=0.0),
    )

    aggregate_route = Route(
        from=AllDomains(kind=:plant, process=:domain_plant_transpiration, var=:transpiration),
        to=DomainRouteTarget(:scene, var=:daily_plant_transpiration, process=:domain_scene_routed_aggregate),
        cardinality=ManyToOneAggregate(sum),
        policy=Integrate(),
    )

    aggregate_sim = run!(
        SimulationMapping(
            Domain(:oil_palm, oil_palm_mapping; kind=:plant),
            Domain(:maize, maize_mapping; kind=:plant),
            Domain(:scene, daily_scene_mapping; kind=:scene);
            routes=(aggregate_route,),
        ),
        hourly_meteo,
        check=true,
    )
    @test status(aggregate_sim, :scene).daily_plant_transpiration ≈ 24.0 * hourly_plant_sum
    @test status(aggregate_sim, :scene).daily_routed_total ≈ 24.0 * hourly_plant_sum

    aggregate_rows = explain_routes(aggregate_sim)
    @test length(aggregate_rows) == 2
    @test all(row -> row.dt_seconds == 86_400.0, aggregate_rows)
    @test all(row -> row.cardinality <: ManyToOneAggregate, aggregate_rows)
end

@testset "Domain graph dependency policy with changing topology" begin
    first_step = PlantSimEngine.DomainNodeValues([11, 12], Any[1.0, 2.0])
    second_step = PlantSimEngine.DomainNodeValues([11, 13], Any[3.0, 4.0])

    integrated = PlantSimEngine._apply_dependency_policy(Any[first_step, second_step], Integrate())
    @test integrated.ids == [11, 12, 13]
    @test integrated.values ≈ [4.0, 2.0, 4.0]

    aggregated = PlantSimEngine._apply_dependency_policy(Any[first_step, second_step], Aggregate())
    @test aggregated.ids == [11, 12, 13]
    @test aggregated.values ≈ [2.0, 2.0, 4.0]

    no_ids_first_step = PlantSimEngine.DomainNodeValues(Any[1.0, 2.0])
    no_ids_second_step = PlantSimEngine.DomainNodeValues(Any[3.0])
    @test_throws "changing vector lengths" PlantSimEngine._apply_dependency_policy(
        Any[no_ids_first_step, no_ids_second_step],
        Integrate(),
    )
end

@testset "Staged MTG-backed domain simulation" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    oil_palm = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    oil_axis = Node(oil_palm, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    Node(oil_axis, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 3))
    maize = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 2, 1))
    maize_axis = Node(maize, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    Node(maize_axis, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 3))

    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1)),
        Atmosphere(T=25.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1)),
    ])

    oil_leaf_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainMTGLeafFluxModel(0.5)) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    maize_leaf_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainMTGLeafFluxModel(0.7)) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    scene_mapping = ModelMapping(
        ModelSpec(DomainSceneRoutedVectorModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(plant_transpirations=[0.0], routed_total=0.0),
    )
    route = Route(
        from=AllDomains(kind=:plant, scale=:Leaf, process=:domain_mtg_leaf_flux, var=:leaf_flux),
        to=DomainRouteTarget(:scene, var=:plant_transpirations, process=:domain_scene_routed_vector),
        cardinality=ManyToOneVector(),
    )

    sim = run!(
        scene,
        SimulationMapping(
            Domain(:oil_palm, oil_leaf_mapping; kind=:plant, selector=oil_palm),
            Domain(:maize, maize_leaf_mapping; kind=:plant, selector=maize),
            Domain(:scene, scene_mapping; kind=:scene);
            routes=(route,),
        ),
        meteo,
        check=true,
    )

    @test length(status(sim, :oil_palm, :Leaf)) == 1
    @test length(status(sim, :maize, :Leaf)) == 1
    @test length(status(sim, :Leaf)) == 2
    @test length(status(sim, :Default)) == 1
    @test status(sim, :scene).plant_transpirations ≈ [0.5, 0.7]
    @test status(sim, :scene).routed_total ≈ 1.2
    @test sim.outputs[(DomainModelKey(:scene, :Default, :domain_scene_routed_vector), :routed_total)] ≈ [1.2, 1.2]
    @test sim.outputs[(DomainModelKey(:oil_palm, :Leaf, :domain_mtg_leaf_flux), :leaf_flux)] == [[0.5], [0.5]]
    @test sim.outputs[(DomainModelKey(:maize, :Leaf, :domain_mtg_leaf_flux), :leaf_flux)] == [[0.7], [0.7]]
    status_rows = explain_domain_statuses(sim)
    @test sum(row -> row.scale == :Leaf, status_rows) == 2
    @test only(row.nstatuses for row in status_rows if row.domain == :scene && row.scale == :Default) == 1

    forest_leaf_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainMTGLeafFluxModel(0.4)) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    forest_sim = run!(
        scene,
        SimulationMapping(
            Domain(:forest, forest_leaf_mapping; kind=:plant, selector=:Plant),
            Domain(:scene, scene_mapping; kind=:scene);
            routes=(route,),
        ),
        meteo,
        check=true,
    )
    @test length(status(forest_sim, :forest, :Leaf)) == 2
    @test length(status(forest_sim, :Leaf)) == 2
    @test status(forest_sim, :scene).plant_transpirations ≈ [0.4, 0.4]
    @test status(forest_sim, :scene).routed_total ≈ 0.8
    @test forest_sim.outputs[(DomainModelKey(:forest, :Leaf, :domain_mtg_leaf_flux), :leaf_flux)] == [[0.4, 0.4], [0.4, 0.4]]
    @test only(row.nstatuses for row in explain_domain_statuses(forest_sim) if row.domain == :forest && row.scale == :Leaf) == 2

    @test_throws "matched overlapping MTG roots" run!(
        scene,
        SimulationMapping(
            Domain(
                :overlapping_forest,
                forest_leaf_mapping;
                kind=:plant,
                selector=node -> symbol(node) in (:Plant, :Leaf),
            ),
        ),
        meteo,
        check=true,
    )

    dependency_scene_mapping = ModelMapping(
        ModelSpec(DomainSceneDependencyFluxSumModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(dependency_total=0.0, grouped_dependency_total=0.0),
    )
    dependency_sim = run!(
        scene,
        SimulationMapping(
            Domain(:oil_palm, oil_leaf_mapping; kind=:plant, selector=oil_palm),
            Domain(:maize, maize_leaf_mapping; kind=:plant, selector=maize),
            Domain(:scene, dependency_scene_mapping; kind=:scene),
        ),
        meteo,
        check=true,
    )
    @test status(dependency_sim, :scene).dependency_total ≈ 1.2
    @test status(dependency_sim, :scene).grouped_dependency_total ≈ 1.2

    soil_mapping = ModelMapping(
        ModelSpec(DomainSoilWaterModel(0.35)) |> TimeStepModel(Dates.Hour(1)),
        status=(soil_water_content=0.0,),
    )
    soil_leaf_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainMTGLeafSoilFluxModel(2.0)) |> TimeStepModel(Dates.Hour(1)),
        ),
    )
    soil_route = Route(
        from=AllDomains(kind=:soil, process=:domain_soil_water, var=:soil_water_content),
        to=DomainRouteTarget(:oil_palm, scale=:Leaf, var=:soil_signal, process=:domain_mtg_leaf_soil_flux),
        cardinality=OneToManyBroadcast(),
    )
    soil_to_graph_sim = run!(
        scene,
        SimulationMapping(
            Domain(:soil, soil_mapping; kind=:soil),
            Domain(:oil_palm, soil_leaf_mapping; kind=:plant, selector=oil_palm);
            routes=(soil_route,),
        ),
        meteo,
        check=true,
    )
    expected_soil_signals = [0.35 - 0.001 * 20.0, 0.35 - 0.001 * 25.0]
    @test only(status(soil_to_graph_sim, :oil_palm, :Leaf)).soil_signal ≈ expected_soil_signals[2]
    @test soil_to_graph_sim.outputs[(DomainModelKey(:oil_palm, :Leaf, :domain_mtg_leaf_soil_flux), :leaf_flux)] == [[2.0 * expected_soil_signals[1]], [2.0 * expected_soil_signals[2]]]

    reordered_soil_to_graph_sim = run!(
        scene,
        SimulationMapping(
            Domain(:oil_palm, soil_leaf_mapping; kind=:plant, selector=oil_palm),
            Domain(:soil, soil_mapping; kind=:soil);
            routes=(soil_route,),
        ),
        meteo,
        check=true,
    )
    @test only(status(reordered_soil_to_graph_sim, :oil_palm, :Leaf)).soil_signal ≈ expected_soil_signals[2]
    @test reordered_soil_to_graph_sim.outputs[(DomainModelKey(:oil_palm, :Leaf, :domain_mtg_leaf_soil_flux), :leaf_flux)] == [[2.0 * expected_soil_signals[1]], [2.0 * expected_soil_signals[2]]]
end

@testset "Hard-domain targets from MTG-backed domains" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))

    meteo = Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
    plant_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainHardTargetLeafCounterModel(1.5)) |> TimeStepModel(Dates.Hour(1)),
            Status(call_count=0, leaf_signal=0.0),
        ),
    )
    scene_mapping = ModelMapping(
        ModelSpec(DomainSceneHardTargetLeafSumModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(leaf_hard_target_total=0.0,),
    )

    sim = run!(
        scene,
        SimulationMapping(
            Domain(:hard_target_plant, plant_mapping; kind=:plant, selector=plant),
            Domain(:scene, scene_mapping; kind=:scene),
        ),
        meteo,
        check=true,
    )

    leaf_statuses = status(sim, :hard_target_plant, :Leaf)
    @test length(leaf_statuses) == 2
    @test all(st -> st.call_count == 1, leaf_statuses)
    @test all(st -> st.leaf_signal ≈ 1.5, leaf_statuses)
    @test status(sim, :scene).leaf_hard_target_total ≈ 3.0
    @test sim.outputs[(DomainModelKey(:hard_target_plant, :Leaf, :domain_hard_target_leaf_counter), :leaf_signal)] == [1.5, 1.5]
end

@testset "MTG-backed domain growth registration" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))

    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    growth_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainGrowthLeafEmergenceModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
        :Leaf => (
            ModelSpec(DomainGrowthLeafFluxModel(0.9)) |>
                MultiScaleModel([:grown_leaves => (:Plant => :grown_leaves)]) |>
                TimeStepModel(Dates.Hour(1)),
        ),
    )
    scene_mapping = ModelMapping(
        ModelSpec(DomainSceneGrowthFluxSumModel()) |> TimeStepModel(Dates.Hour(1)),
        status=(growth_flux_total=0.0,),
    )

    sim = run!(
        scene,
        SimulationMapping(
            Domain(:growing_plant, growth_mapping; kind=:plant, selector=plant),
            Domain(:scene, scene_mapping; kind=:scene),
        ),
        meteo,
        check=true,
    )

    @test length(status(sim, :growing_plant, :Leaf)) == 1
    @test length(status(sim, :Leaf)) == 1
    @test only(status(sim, :growing_plant, :Leaf)).grown_leaves == 1.0
    @test only(status(sim, :growing_plant, :Leaf)).leaf_flux ≈ 0.9
    @test status(sim, :scene).growth_flux_total ≈ 0.9
    @test sim.outputs[(DomainModelKey(:growing_plant, :Leaf, :domain_growth_leaf_flux), :leaf_flux)] == [[0.9], [0.9]]
    @test sim.outputs[(DomainModelKey(:scene, :Default, :domain_scene_growth_flux_sum), :growth_flux_total)] ≈ [0.9, 0.9]
    @test only(row.nstatuses for row in explain_domain_statuses(sim) if row.domain == :growing_plant && row.scale == :Leaf) == 1

    multirate_scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    multirate_plant = Node(multirate_scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    multirate_meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:25
    ])
    multirate_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainGrowthLeafEmergenceModel()) |> TimeStepModel(Dates.Hour(1)),
            ModelSpec(DomainGrowthIntegratedFluxModel()) |>
                MultiScaleModel([:leaf_flux => [:Leaf]]) |>
                InputBindings(; leaf_flux=(process=:domain_growth_leaf_flux, scale=:Leaf, var=:leaf_flux, policy=Integrate())) |>
                TimeStepModel(Dates.Day(1)),
        ),
        :Leaf => (
            ModelSpec(DomainGrowthLeafFluxModel(0.9)) |>
                MultiScaleModel([:grown_leaves => (:Plant => :grown_leaves)]) |>
                TimeStepModel(Dates.Hour(1)),
        ),
    )
    multirate_sim = run!(
        multirate_scene,
        SimulationMapping(Domain(:growing_plant, multirate_mapping; kind=:plant, selector=multirate_plant)),
        multirate_meteo,
        check=true,
    )

    @test length(status(multirate_sim, :growing_plant, :Leaf)) == 1
    @test only(status(multirate_sim, :growing_plant, :Plant)).integrated_leaf_flux ≈ 24.0 * 0.9
    integrated_outputs = multirate_sim.outputs[(DomainModelKey(:growing_plant, :Plant, :domain_growth_integrated_flux), :integrated_leaf_flux)]
    @test only.(integrated_outputs) ≈ [0.9, 24.0 * 0.9]
    @test length(integrated_outputs) == 2
end

@testset "MTG-backed domain variable updates" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))

    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    update_mapping = ModelMapping(
        :Leaf => (
            ModelSpec(DomainUpdateAllocationModel()) |> TimeStepModel(Dates.Hour(1)),
            ModelSpec(DomainUpdatePruningModel()) |>
                Updates(:leaf_biomass; after=:domain_update_allocation) |>
                TimeStepModel(Dates.Hour(1)),
            ModelSpec(DomainUpdateObserverModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    resolved_update_specs = resolved_model_specs(update_mapping)
    inferred_update_binding = input_bindings(resolved_update_specs[:Leaf][:domain_update_observer]).leaf_biomass
    @test inferred_update_binding.process == :domain_update_pruning

    sim = run!(
        scene,
        SimulationMapping(Domain(:updated_plant, update_mapping; kind=:plant, selector=plant)),
        meteo,
        check=true,
    )

    leaf_status = only(status(sim, :updated_plant, :Leaf))
    @test leaf_status.leaf_biomass == 0.0
    @test leaf_status.observed_biomass == 0.0
    @test sim.outputs[(DomainModelKey(:updated_plant, :Leaf, :domain_update_pruning), :leaf_biomass)] == [[0.0], [0.0]]
    @test sim.outputs[(DomainModelKey(:updated_plant, :Leaf, :domain_update_observer), :observed_biomass)] == [[0.0], [0.0]]
end

@testset "MTG-backed domain leaf removal registration" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))

    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    removal_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainRemovalPruningModel()) |>
                MultiScaleModel([:leaf_flux => [:Leaf]]) |>
                TimeStepModel(Dates.Hour(1)),
            Status(removed_count=0, removed_node_id=0, remaining_leaf_flux=0.0),
        ),
        :Leaf => (
            ModelSpec(DomainRemovalLeafFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    sim = run!(
        scene,
        SimulationMapping(Domain(:pruned_plant, removal_mapping; kind=:plant, selector=plant)),
        meteo,
        check=true,
    )

    plant_status = only(status(sim, :pruned_plant, :Plant))
    @test length(status(sim, :pruned_plant, :Leaf)) == 1
    @test length(status(sim, :Leaf)) == 1
    @test length(plant_status.leaf_flux) == 1
    @test plant_status.removed_count == 1
    @test plant_status.removed_node_id > 0
    @test plant_status.remaining_leaf_flux ≈ 1.0
    @test sim.outputs[(DomainModelKey(:pruned_plant, :Leaf, :domain_removal_leaf_flux), :leaf_flux)] == [[1.0], [1.0]]
    @test sim.outputs[(DomainModelKey(:pruned_plant, :Plant, :domain_removal_pruning), :remaining_leaf_flux)] == [[1.0], [1.0]]
    @test_throws ErrorException remove_organ!(plant, only(sim.domain_states[:pruned_plant].simulations))

    multirate_scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    multirate_plant = Node(multirate_scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    Node(multirate_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    Node(multirate_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 2, 2))
    multirate_removal_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainRemovalPruningModel()) |>
                MultiScaleModel([:leaf_flux => [:Leaf]]) |>
                InputBindings(; leaf_flux=(process=:domain_removal_leaf_flux, scale=:Leaf, var=:leaf_flux, policy=Integrate())) |>
                TimeStepModel(Dates.Day(1)),
            Status(removed_count=0, removed_node_id=0, remaining_leaf_flux=0.0),
        ),
        :Leaf => (
            ModelSpec(DomainRemovalLeafFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    multirate_sim = run!(
        multirate_scene,
        SimulationMapping(Domain(:pruned_plant, multirate_removal_mapping; kind=:plant, selector=multirate_plant)),
        meteo,
        check=true,
    )

    multirate_plant_status = only(status(multirate_sim, :pruned_plant, :Plant))
    multirate_graph = only(multirate_sim.domain_states[:pruned_plant].simulations)
    @test length(status(multirate_sim, :pruned_plant, :Leaf)) == 1
    @test length(multirate_plant_status.leaf_flux) == 1
    @test multirate_plant_status.remaining_leaf_flux ≈ 1.0
    @test all(key -> key.node_id != multirate_plant_status.removed_node_id, keys(multirate_graph.temporal_state.streams))
    @test all(key -> key.node_id != multirate_plant_status.removed_node_id, keys(multirate_graph.temporal_state.caches))
end

@testset "MTG-backed domain repeated create/remove churn" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:4
    ])

    churn_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainChurnLeafControllerModel()) |>
                MultiScaleModel([:leaf_flux => [:Leaf]]) |>
                InputBindings(; leaf_flux=(process=:domain_churn_leaf_flux, scale=:Leaf, var=:leaf_flux, policy=HoldLast())) |>
                TimeStepModel(Dates.Hour(1)),
            Status(created_count=0, removed_count=0, active_leaf_count=0, last_removed_node_id=0),
        ),
        :Leaf => (
            ModelSpec(DomainChurnLeafFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    sim = run!(
        scene,
        SimulationMapping(Domain(:churn_plant, churn_mapping; kind=:plant, selector=plant)),
        meteo,
        check=true,
    )

    plant_status = only(status(sim, :churn_plant, :Plant))
    graph_sim = only(sim.domain_states[:churn_plant].simulations)
    @test plant_status.created_count == 2
    @test plant_status.removed_count == 2
    @test plant_status.active_leaf_count == 0
    @test length(plant_status.leaf_flux) == 0
    @test get(status(graph_sim), :Leaf, Status[]) == Status[]
    @test get(status(sim.domain_states[:churn_plant]), :Leaf, Status[]) == Status[]
    @test status(sim, :churn_plant, :Leaf) == Status[]
    @test status(sim, :Leaf) == Status[]
    @test only(row.nstatuses for row in explain_domain_statuses(sim) if row.domain == :churn_plant && row.scale == :Leaf) == 0
    @test all(key -> key.scale != :Leaf, keys(graph_sim.temporal_state.streams))
    @test all(key -> key.scale != :Leaf, keys(graph_sim.temporal_state.caches))
    @test sim.outputs[(DomainModelKey(:churn_plant, :Plant, :domain_churn_leaf_controller), :created_count)] == [[1], [1], [2], [2]]
    @test sim.outputs[(DomainModelKey(:churn_plant, :Plant, :domain_churn_leaf_controller), :removed_count)] == [[0], [1], [1], [2]]
    @test sim.outputs[(DomainModelKey(:churn_plant, :Plant, :domain_churn_leaf_controller), :active_leaf_count)] == [[1], [0], [1], [0]]
end

@testset "MTG-backed domain recursive subtree removal" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    leaf = Node(internode, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 3))
    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    subtree_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainSubtreePruningModel()) |>
                MultiScaleModel([
                    :internode_flux => [:Internode],
                    :leaf_flux => [:Leaf],
                ]) |>
                InputBindings(;
                    internode_flux=(process=:domain_subtree_internode_flux, scale=:Internode, var=:internode_flux, policy=HoldLast()),
                    leaf_flux=(process=:domain_subtree_leaf_flux, scale=:Leaf, var=:leaf_flux, policy=HoldLast()),
                ) |>
                TimeStepModel(Dates.Hour(1)),
            Status(
                removed_count=0,
                removed_internode_id=0,
                removed_leaf_id=0,
                remaining_internode_count=0,
                remaining_leaf_count=0,
            ),
        ),
        :Internode => (
            ModelSpec(DomainSubtreeInternodeFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
        :Leaf => (
            ModelSpec(DomainSubtreeLeafFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    sim = run!(
        scene,
        SimulationMapping(Domain(:subtree_plant, subtree_mapping; kind=:plant, selector=plant)),
        meteo,
        check=true,
    )

    plant_status = only(status(sim, :subtree_plant, :Plant))
    graph_sim = only(sim.domain_states[:subtree_plant].simulations)
    @test plant_status.removed_count == 1
    @test plant_status.removed_internode_id == node_id(internode)
    @test plant_status.removed_leaf_id == node_id(leaf)
    @test plant_status.remaining_internode_count == 0
    @test plant_status.remaining_leaf_count == 0
    @test length(plant_status.internode_flux) == 0
    @test length(plant_status.leaf_flux) == 0
    @test get(status(graph_sim), :Internode, Status[]) == Status[]
    @test get(status(graph_sim), :Leaf, Status[]) == Status[]
    @test status(sim, :subtree_plant, :Internode) == Status[]
    @test status(sim, :subtree_plant, :Leaf) == Status[]
    @test status(sim, :Internode) == Status[]
    @test status(sim, :Leaf) == Status[]
    @test only(row.nstatuses for row in explain_domain_statuses(sim) if row.domain == :subtree_plant && row.scale == :Internode) == 0
    @test only(row.nstatuses for row in explain_domain_statuses(sim) if row.domain == :subtree_plant && row.scale == :Leaf) == 0
    @test all(key -> key.node_id != plant_status.removed_internode_id, keys(graph_sim.temporal_state.streams))
    @test all(key -> key.node_id != plant_status.removed_leaf_id, keys(graph_sim.temporal_state.streams))
    @test all(key -> key.node_id != plant_status.removed_internode_id, keys(graph_sim.temporal_state.caches))
    @test all(key -> key.node_id != plant_status.removed_leaf_id, keys(graph_sim.temporal_state.caches))
    @test sim.outputs[(DomainModelKey(:subtree_plant, :Internode, :domain_subtree_internode_flux), :internode_flux)] == [[], []]
    @test sim.outputs[(DomainModelKey(:subtree_plant, :Leaf, :domain_subtree_leaf_flux), :leaf_flux)] == [[], []]
    @test sim.outputs[(DomainModelKey(:subtree_plant, :Plant, :domain_subtree_pruning), :remaining_internode_count)] == [[0], [0]]
    @test sim.outputs[(DomainModelKey(:subtree_plant, :Plant, :domain_subtree_pruning), :remaining_leaf_count)] == [[0], [0]]
end

@testset "MTG-backed domain topology reparenting" begin
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    internode_1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    internode_2 = Node(plant, MultiScaleTreeGraph.NodeMTG("+", :Internode, 2, 2))
    leaf = Node(internode_1, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 3))
    meteo = Weather([
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Dates.Hour(1))
        for _ in 1:2
    ])

    reparent_mapping = ModelMapping(
        :Plant => (
            ModelSpec(DomainReparentLeafControllerModel()) |>
                MultiScaleModel([:leaf_flux => [:Leaf]]) |>
                InputBindings(; leaf_flux=(process=:domain_subtree_leaf_flux, scale=:Leaf, var=:leaf_flux, policy=HoldLast())) |>
                TimeStepModel(Dates.Hour(1)),
            Status(reparented_count=0, new_parent_id=0, leaf_parent_id=0, active_leaf_count=0),
        ),
        :Internode => (
            ModelSpec(DomainSubtreeInternodeFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
        :Leaf => (
            ModelSpec(DomainSubtreeLeafFluxModel()) |> TimeStepModel(Dates.Hour(1)),
        ),
    )

    sim = run!(
        scene,
        SimulationMapping(Domain(:reparented_plant, reparent_mapping; kind=:plant, selector=plant)),
        meteo,
        check=true,
    )

    plant_status = only(status(sim, :reparented_plant, :Plant))
    graph_sim = only(sim.domain_states[:reparented_plant].simulations)
    @test parent(leaf) === internode_2
    @test !any(node -> node === leaf, children(internode_1))
    @test count(node -> node === leaf, children(internode_2)) == 1
    @test plant_status.reparented_count == 1
    @test plant_status.new_parent_id == node_id(internode_2)
    @test plant_status.leaf_parent_id == node_id(internode_2)
    @test plant_status.active_leaf_count == 1
    @test length(plant_status.leaf_flux) == 1
    @test length(status(sim, :reparented_plant, :Internode)) == 2
    @test length(status(sim, :reparented_plant, :Leaf)) == 1
    @test all(key -> key.node_id != 0, keys(graph_sim.temporal_state.streams))
    @test sim.outputs[(DomainModelKey(:reparented_plant, :Leaf, :domain_subtree_leaf_flux), :leaf_flux)] == [[1.0], [1.0]]
    @test sim.outputs[(DomainModelKey(:reparented_plant, :Plant, :domain_reparent_leaf_controller), :leaf_parent_id)] == [[node_id(internode_2)], [node_id(internode_2)]]
    @test_throws ErrorException reparent_organ!(internode_2, leaf, graph_sim)
end
