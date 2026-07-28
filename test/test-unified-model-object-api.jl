using Dates
using PlantSimEngine
using PlantSimEngine.Examples
using MultiScaleTreeGraph
using Test

PlantSimEngine.@process "model_object_default_input_consumer" verbose = false

struct ModelObjectDefaultInputConsumerModel <: AbstractModel_Object_Default_Input_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectDefaultInputConsumerModel) = (leaf_carbon=[0.0],)
PlantSimEngine.outputs_(::ModelObjectDefaultInputConsumerModel) = (plant_carbon=0.0,)
PlantSimEngine.dep(::ModelObjectDefaultInputConsumerModel) = (
    leaf_carbon=Input(Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)),
)

PlantSimEngine.@process "model_object_default_call_consumer" verbose = false

struct ModelObjectDefaultCallConsumerModel <: AbstractModel_Object_Default_Call_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectDefaultCallConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectDefaultCallConsumerModel) = (energy_balance=0.0,)
PlantSimEngine.dep(::ModelObjectDefaultCallConsumerModel) = (
    stomata=Call(scale=:Leaf, process=:stomatal_conductance),
)

PlantSimEngine.@process "model_object_stomata" verbose = false

struct ModelObjectStomataModel <: AbstractModel_Object_StomataModel end

PlantSimEngine.inputs_(::ModelObjectStomataModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectStomataModel) = (gs=0.0,)

PlantSimEngine.@process "model_object_leaf_energy" verbose = false

struct ModelObjectLeafEnergyModel <: AbstractModel_Object_Leaf_EnergyModel end

PlantSimEngine.inputs_(::ModelObjectLeafEnergyModel) = (leaf_areas=[0.0],)
PlantSimEngine.outputs_(::ModelObjectLeafEnergyModel) = (leaf_temperature=25.0,)
PlantSimEngine.dep(::ModelObjectLeafEnergyModel) = (
    stomata=Call(process=:model_object_stomata),
)

PlantSimEngine.@process "model_object_carrier_consumer" verbose = false

struct ModelObjectCarrierConsumerModel <: AbstractModel_Object_Carrier_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectCarrierConsumerModel) = (leaf_areas=[0.0], leaf_tokens=Any[])
PlantSimEngine.outputs_(::ModelObjectCarrierConsumerModel) = (carrier_total=0.0,)

function PlantSimEngine.run!(::ModelObjectCarrierConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.carrier_total = sum(status.leaf_areas)
    return nothing
end

PlantSimEngine.@process "model_object_environment_probe" verbose = false

struct ModelObjectEnvironmentProbeModel <: AbstractModel_Object_Environment_ProbeModel end

PlantSimEngine.inputs_(::ModelObjectEnvironmentProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectEnvironmentProbeModel) = (temperature_seen=0.0,)
PlantSimEngine.meteo_inputs_(::ModelObjectEnvironmentProbeModel) = (T=0.0, CO2=0.0)

function PlantSimEngine.run!(::ModelObjectEnvironmentProbeModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temperature_seen = meteo.T
    return nothing
end

PlantSimEngine.@process "model_object_environment_co2_probe" verbose = false

struct ModelObjectEnvironmentCO2ProbeModel <:
       AbstractModel_Object_Environment_Co2_ProbeModel end

PlantSimEngine.inputs_(::ModelObjectEnvironmentCO2ProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectEnvironmentCO2ProbeModel) =
    (temperature_seen=0.0, co2_seen=0.0)
PlantSimEngine.meteo_inputs_(::ModelObjectEnvironmentCO2ProbeModel) =
    (T=0.0, CO2=0.0)

function PlantSimEngine.run!(
    ::ModelObjectEnvironmentCO2ProbeModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.temperature_seen = meteo.T
    status.co2_seen = meteo.CO2
    return nothing
end

struct ModelObjectEnvironmentCO2HintProbeModel <:
       AbstractModel_Object_Environment_Co2_ProbeModel end

PlantSimEngine.inputs_(::ModelObjectEnvironmentCO2HintProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectEnvironmentCO2HintProbeModel) =
    (temperature_seen=0.0, co2_seen=0.0)
PlantSimEngine.meteo_inputs_(::ModelObjectEnvironmentCO2HintProbeModel) =
    (T=0.0, CO2=0.0)
PlantSimEngine.meteo_hint(::Type{<:ModelObjectEnvironmentCO2HintProbeModel}) =
    (bindings=(CO2=(source=:Ca, reducer=MeanReducer()),),)

function PlantSimEngine.run!(
    ::ModelObjectEnvironmentCO2HintProbeModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.temperature_seen = meteo.T
    status.co2_seen = meteo.CO2
    return nothing
end

struct ModelObjectAggregatedEnvironmentProbeModel <:
       AbstractModel_Object_Environment_Co2_ProbeModel end

PlantSimEngine.inputs_(::ModelObjectAggregatedEnvironmentProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectAggregatedEnvironmentProbeModel) =
    (temperature_seen=0.0, co2_seen=0.0)
PlantSimEngine.meteo_inputs_(::ModelObjectAggregatedEnvironmentProbeModel) =
    (T=0.0, CO2=0.0)
PlantSimEngine.meteo_hint(::Type{<:ModelObjectAggregatedEnvironmentProbeModel}) = (
    bindings=(
        T=(source=:T, reducer=MaxReducer()),
        CO2=(source=:Ca, reducer=MeanReducer()),
    ),
)

function PlantSimEngine.run!(
    ::ModelObjectAggregatedEnvironmentProbeModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.temperature_seen = meteo.T
    status.co2_seen = meteo.CO2
    return nothing
end

struct ModelObjectTemperatureOnlyProbeModel <:
       AbstractModel_Object_Environment_ProbeModel end

PlantSimEngine.inputs_(::ModelObjectTemperatureOnlyProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectTemperatureOnlyProbeModel) =
    (temperature_seen=0.0,)
PlantSimEngine.meteo_inputs_(::ModelObjectTemperatureOnlyProbeModel) = (T=0.0,)

function PlantSimEngine.run!(
    ::ModelObjectTemperatureOnlyProbeModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.temperature_seen = meteo.T
    return nothing
end

PlantSimEngine.@process "model_object_environment_update" verbose = false

struct ModelObjectEnvironmentUpdateModel <: AbstractModel_Object_Environment_UpdateModel end

PlantSimEngine.inputs_(::ModelObjectEnvironmentUpdateModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectEnvironmentUpdateModel) = (temperature_update=0.0,)
PlantSimEngine.meteo_inputs_(::ModelObjectEnvironmentUpdateModel) = (T=0.0,)

function PlantSimEngine.run!(::ModelObjectEnvironmentUpdateModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temperature_update = meteo.T + 1.0
    update_environment!(extra, (T=status.temperature_update, CO2=410.0))
    return nothing
end

PlantSimEngine.@process "model_object_environment_update_caller" verbose = false

struct ModelObjectEnvironmentUpdateCallerModel <: AbstractModel_Object_Environment_Update_CallerModel end

PlantSimEngine.inputs_(::ModelObjectEnvironmentUpdateCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectEnvironmentUpdateCallerModel) = (called_temperature=0.0,)

function PlantSimEngine.run!(::ModelObjectEnvironmentUpdateCallerModel, models, status, meteo, constants=nothing, extra=nothing)
    target = only(run_call!(extra, :updater; publish=false))
    status.called_temperature = target.status.temperature_update
    return nothing
end

PlantSimEngine.@process "model_object_signal_source" verbose = false

struct ModelObjectSignalSourceModel <: AbstractModel_Object_Signal_SourceModel end

PlantSimEngine.inputs_(::ModelObjectSignalSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectSignalSourceModel) = (signal=0.0,)

function PlantSimEngine.run!(::ModelObjectSignalSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "model_object_trait_clock_source" verbose = false

struct ModelObjectTraitClockSourceModel <: AbstractModel_Object_Trait_Clock_SourceModel end

PlantSimEngine.inputs_(::ModelObjectTraitClockSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectTraitClockSourceModel) = (signal=0.0,)
PlantSimEngine.timespec(::Type{<:ModelObjectTraitClockSourceModel}) = ClockSpec(2.0, 1.0)

function PlantSimEngine.run!(::ModelObjectTraitClockSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "model_object_strict_hint_source" verbose = false

struct ModelObjectStrictHintSourceModel <: AbstractModel_Object_Strict_Hint_SourceModel end

PlantSimEngine.inputs_(::ModelObjectStrictHintSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectStrictHintSourceModel) = (signal=0.0,)
PlantSimEngine.timestep_hint(::Type{<:ModelObjectStrictHintSourceModel}) = Dates.Day(1)

function PlantSimEngine.run!(::ModelObjectStrictHintSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += 1.0
    return nothing
end

struct ModelObjectTimeSignalModel{T} <: AbstractModel_Object_Signal_SourceModel
    prototype::T
end

PlantSimEngine.inputs_(::ModelObjectTimeSignalModel) = NamedTuple()
PlantSimEngine.outputs_(model::ModelObjectTimeSignalModel) = (signal=zero(model.prototype),)

function PlantSimEngine.run!(model::ModelObjectTimeSignalModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal = convert(typeof(model.prototype), extra.time)
    return nothing
end

struct ModelObjectTraitPolicySignalModel <: AbstractModel_Object_Signal_SourceModel end

PlantSimEngine.inputs_(::ModelObjectTraitPolicySignalModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectTraitPolicySignalModel) = (signal=0.0,)
PlantSimEngine.output_policy(::Type{<:ModelObjectTraitPolicySignalModel}) = (signal=Aggregate(),)

function PlantSimEngine.run!(::ModelObjectTraitPolicySignalModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += 1.0
    return nothing
end

struct ModelObjectParameterizedSignalModel{T} <: AbstractModel_Object_Signal_SourceModel
    increment::T
end

PlantSimEngine.inputs_(::ModelObjectParameterizedSignalModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectParameterizedSignalModel) = (signal=0.0,)

function PlantSimEngine.run!(model::ModelObjectParameterizedSignalModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal += model.increment
    return nothing
end

struct ModelObjectAlternativeSignalModel <: AbstractModel_Object_Signal_SourceModel end

PlantSimEngine.inputs_(::ModelObjectAlternativeSignalModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectAlternativeSignalModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::ModelObjectAlternativeSignalModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.signal += 7.0
    return nothing
end

PlantSimEngine.@process "model_object_batch_counter" verbose = false

struct ModelObjectBatchCounterModel <: AbstractModel_Object_Batch_CounterModel
    count::Base.RefValue{Int}
end

PlantSimEngine.inputs_(::ModelObjectBatchCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectBatchCounterModel) = NamedTuple()

function PlantSimEngine.run!(
    model::ModelObjectBatchCounterModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    model.count[] += 1
    return nothing
end

struct ModelObjectSignalSetModel{T} <: AbstractModel_Object_Signal_SourceModel
    value::T
end

PlantSimEngine.inputs_(::ModelObjectSignalSetModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectSignalSetModel) = (signal=0.0,)

function PlantSimEngine.run!(model::ModelObjectSignalSetModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal = model.value
    return nothing
end

PlantSimEngine.@process "model_object_plant_signal_sum" verbose = false

struct ModelObjectPlantSignalSumModel <: AbstractModel_Object_Plant_Signal_SumModel end

PlantSimEngine.inputs_(::ModelObjectPlantSignalSumModel) = (signals=[0.0],)
PlantSimEngine.outputs_(::ModelObjectPlantSignalSumModel) = (signal_total=0.0,)

function PlantSimEngine.run!(::ModelObjectPlantSignalSumModel, models, status, meteo, constants=nothing, extra=nothing)
    status.signal_total = sum(status.signals)
    return nothing
end

PlantSimEngine.@process "model_object_signal_caller" verbose = false

struct ModelObjectSignalCallerModel <: AbstractModel_Object_Signal_CallerModel end

PlantSimEngine.inputs_(::ModelObjectSignalCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectSignalCallerModel) = (called_signal=0.0,)
PlantSimEngine.dep(::ModelObjectSignalCallerModel) = (
    signal=Call(process=:model_object_signal_source),
)

PlantSimEngine.@process "model_object_manual_pair_caller" verbose = false
struct ModelObjectManualPairCallerModel <:
       AbstractModel_Object_Manual_Pair_CallerModel end
PlantSimEngine.inputs_(::ModelObjectManualPairCallerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectManualPairCallerModel) = NamedTuple()
function PlantSimEngine.run!(
    ::ModelObjectManualPairCallerModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    return nothing
end

function PlantSimEngine.run!(::ModelObjectSignalCallerModel, models, status, meteo, constants=nothing, extra=nothing)
    target = only(run_call!(extra, :signal; publish=true))
    status.called_signal = target.status.signal
    return nothing
end

PlantSimEngine.@process "model_object_meteo_call_source" verbose = false

struct ModelObjectMeteoCallSourceModel <: AbstractModel_Object_Meteo_Call_SourceModel end

PlantSimEngine.inputs_(::ModelObjectMeteoCallSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectMeteoCallSourceModel) = (temperature_seen=0.0,)
PlantSimEngine.meteo_inputs_(::ModelObjectMeteoCallSourceModel) = (T=0.0,)

function PlantSimEngine.run!(::ModelObjectMeteoCallSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temperature_seen = meteo.T
    return nothing
end

PlantSimEngine.@process "model_object_meteo_call_controller" verbose = false

struct ModelObjectMeteoCallControllerModel{T} <: AbstractModel_Object_Meteo_Call_ControllerModel
    local_temperature::T
    publish::Bool
end

PlantSimEngine.inputs_(::ModelObjectMeteoCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectMeteoCallControllerModel) = (called_temperature=0.0,)

function PlantSimEngine.run!(m::ModelObjectMeteoCallControllerModel, models, status, meteo, constants=nothing, extra=nothing)
    local_meteo = (T=m.local_temperature, CO2=410.0)
    if m.publish
        update_environment!(extra, local_meteo)
        target = only(run_call!(extra, :source; publish=true))
    else
        target = only(
            with_environment!(extra, local_meteo) do
                run_call!(extra, :source; publish=false)
            end,
        )
    end
    status.called_temperature = target.status.temperature_seen
    return nothing
end

PlantSimEngine.@process "model_object_iterative_meteo_call_controller" verbose = false

struct ModelObjectIterativeMeteoCallControllerModel{T} <:
       AbstractModel_Object_Iterative_Meteo_Call_ControllerModel
    trial_temperatures::NTuple{2,T}
    accepted_temperature::T
end

PlantSimEngine.inputs_(::ModelObjectIterativeMeteoCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectIterativeMeteoCallControllerModel) =
    (called_temperature=0.0,)

function PlantSimEngine.run!(
    m::ModelObjectIterativeMeteoCallControllerModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    target = only(call_targets(extra, :source))
    for temperature in m.trial_temperatures
        with_environment!(extra, (T=temperature, CO2=410.0)) do
            run_call!(target; publish=false)
        end
    end
    update_environment!(extra, (T=m.accepted_temperature, CO2=410.0))
    run_call!(target; publish=true)
    status.called_temperature = target.status.temperature_seen
    return nothing
end

PlantSimEngine.@process "model_object_signal_consumer" verbose = false

struct ModelObjectSignalConsumerModel <: AbstractModel_Object_Signal_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectSignalConsumerModel) = (signal=0.0,)
PlantSimEngine.outputs_(::ModelObjectSignalConsumerModel) = (observed_signal=0.0,)

function PlantSimEngine.run!(::ModelObjectSignalConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.observed_signal = status.signal
    return nothing
end

PlantSimEngine.@process "model_object_renamed_signal_consumer" verbose = false

struct ModelObjectRenamedSignalConsumerModel <:
       AbstractModel_Object_Renamed_Signal_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectRenamedSignalConsumerModel) =
    (renamed_signal=0.0,)
PlantSimEngine.outputs_(::ModelObjectRenamedSignalConsumerModel) =
    (observed_renamed_signal=0.0,)

function PlantSimEngine.run!(
    ::ModelObjectRenamedSignalConsumerModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.observed_renamed_signal = status.renamed_signal
    return nothing
end

PlantSimEngine.@process "model_object_optional_input_consumer" verbose = false

struct ModelObjectOptionalInputConsumerModel <:
       AbstractModel_Object_Optional_Input_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectOptionalInputConsumerModel) = (optional_signal=7.0,)
PlantSimEngine.outputs_(::ModelObjectOptionalInputConsumerModel) =
    (observed_optional_signal=0.0,)

function PlantSimEngine.run!(
    ::ModelObjectOptionalInputConsumerModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.observed_optional_signal = status.optional_signal
    return nothing
end

PlantSimEngine.@process "model_object_optional_call_consumer" verbose = false

struct ModelObjectOptionalCallConsumerModel <:
       AbstractModel_Object_Optional_Call_ConsumerModel end

PlantSimEngine.inputs_(::ModelObjectOptionalCallConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectOptionalCallConsumerModel) =
    (optional_call_count=0,)

function PlantSimEngine.run!(
    ::ModelObjectOptionalCallConsumerModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.optional_call_count =
        length(run_call!(extra, :optional_source; publish=true))
    return nothing
end

PlantSimEngine.@process "model_object_cycle_a" verbose = false

struct ModelObjectCycleAModel <: AbstractModel_Object_Cycle_AModel end

PlantSimEngine.inputs_(::ModelObjectCycleAModel) = (cycle_b=0.0,)
PlantSimEngine.outputs_(::ModelObjectCycleAModel) = (cycle_a=0.0,)

function PlantSimEngine.run!(::ModelObjectCycleAModel, models, status, meteo, constants=nothing, extra=nothing)
    status.cycle_a = status.cycle_b + 1.0
    return nothing
end

PlantSimEngine.@process "model_object_cycle_b" verbose = false

struct ModelObjectCycleBModel <: AbstractModel_Object_Cycle_BModel end

PlantSimEngine.inputs_(::ModelObjectCycleBModel) = (cycle_a=0.0,)
PlantSimEngine.outputs_(::ModelObjectCycleBModel) = (cycle_b=0.0,)

function PlantSimEngine.run!(::ModelObjectCycleBModel, models, status, meteo, constants=nothing, extra=nothing)
    status.cycle_b = 2.0 * status.cycle_a
    return nothing
end

PlantSimEngine.@process "model_object_temporal_sum" verbose = false

struct ModelObjectTemporalSumModel <: AbstractModel_Object_Temporal_SumModel end

PlantSimEngine.inputs_(::ModelObjectTemporalSumModel) = (signal_sum=0.0,)
PlantSimEngine.outputs_(::ModelObjectTemporalSumModel) = (temporal_total=0.0,)

function PlantSimEngine.run!(::ModelObjectTemporalSumModel, models, status, meteo, constants=nothing, extra=nothing)
    status.temporal_total = status.signal_sum
    return nothing
end

PlantSimEngine.@process "model_object_biomass_source" verbose = false

struct ModelObjectBiomassSourceModel <: AbstractModel_Object_Biomass_SourceModel end

PlantSimEngine.inputs_(::ModelObjectBiomassSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectBiomassSourceModel) = (biomass=0.0,)

function PlantSimEngine.run!(::ModelObjectBiomassSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.biomass = 10.0
    return nothing
end

PlantSimEngine.@process "model_object_biomass_pruner" verbose = false

struct ModelObjectBiomassPrunerModel <: AbstractModel_Object_Biomass_PrunerModel end

PlantSimEngine.inputs_(::ModelObjectBiomassPrunerModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectBiomassPrunerModel) = (biomass=0.0,)

function PlantSimEngine.run!(::ModelObjectBiomassPrunerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.biomass = 0.0
    return nothing
end

PlantSimEngine.@process "model_object_growth" verbose = false

struct ModelObjectGrowthModel <: AbstractModel_Object_GrowthModel end

PlantSimEngine.inputs_(::ModelObjectGrowthModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectGrowthModel) = (created_count=0,)

function PlantSimEngine.run!(::ModelObjectGrowthModel, models, status, meteo, constants=nothing, extra=nothing)
    model = runtime_model(extra)
    if isapprox(extra.time, 1.0) && !(ObjectId(:grown_leaf) in object_ids(model; scale=:Leaf))
        register_object!(
            model,
            Object(:grown_leaf; scale=:Leaf, parent=:plant_1, status=Status(signal=0.0)),
        )
        status.created_count += 1
    end
    return nothing
end

PlantSimEngine.@process "model_object_pruning" verbose = false

struct ModelObjectPruningModel <: AbstractModel_Object_PruningModel end

PlantSimEngine.inputs_(::ModelObjectPruningModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectPruningModel) = (removed_count=0,)

function PlantSimEngine.run!(::ModelObjectPruningModel, models, status, meteo, constants=nothing, extra=nothing)
    model = runtime_model(extra)
    if isapprox(extra.time, 2.0) && ObjectId(:leaf_2) in object_ids(model; scale=:Leaf)
        remove_object!(model, :leaf_2)
        status.removed_count += 1
    end
    return nothing
end

PlantSimEngine.@process "model_object_geometry_mover" verbose = false

struct ModelObjectGeometryMoverModel <: AbstractModel_Object_Geometry_MoverModel end

PlantSimEngine.inputs_(::ModelObjectGeometryMoverModel) = NamedTuple()
PlantSimEngine.outputs_(::ModelObjectGeometryMoverModel) = (move_count=0,)

function PlantSimEngine.run!(::ModelObjectGeometryMoverModel, models, status, meteo, constants=nothing, extra=nothing)
    if isapprox(extra.time, 1.0)
        update_geometry!(runtime_model(extra), :leaf_1, (cell=:cell_b,))
        status.move_count += 1
    end
    return nothing
end

mutable struct ModelObjectGridBackend <: PlantSimEngine.AbstractEnvironmentBackend
    binds::Vector{Any}
    index_updates::Vector{Any}
end

ModelObjectGridBackend(binds::Vector{Any}=Any[]) = ModelObjectGridBackend(binds, Any[])

struct ModelObjectTaggedValue
    value::Int
end

struct ModelObjectDualLike{T}
    value::T
    derivative::T
end

Base.zero(::Type{ModelObjectDualLike{T}}) where {T} =
    ModelObjectDualLike(zero(T), zero(T))
Base.:+(a::ModelObjectDualLike, b::ModelObjectDualLike) =
    ModelObjectDualLike(a.value + b.value, a.derivative + b.derivative)
Base.:(==)(a::ModelObjectDualLike, b::ModelObjectDualLike) =
    a.value == b.value && a.derivative == b.derivative

PlantSimEngine.@process "model_object_dual_like_sum" verbose = false

struct ModelObjectDualLikeSumModel <: AbstractModel_Object_Dual_Like_SumModel end

PlantSimEngine.inputs_(::ModelObjectDualLikeSumModel) =
    (values=ModelObjectDualLike{BigFloat}[],)
PlantSimEngine.outputs_(::ModelObjectDualLikeSumModel) =
    (total=zero(ModelObjectDualLike{BigFloat}),)

function PlantSimEngine.run!(
    ::ModelObjectDualLikeSumModel,
    models,
    status,
    meteo,
    constants=nothing,
    extra=nothing,
)
    status.total = sum(status.values)
    return nothing
end

PlantSimEngine.base_step_seconds(::ModelObjectGridBackend) = 3600.0
PlantSimEngine.get_nsteps(::ModelObjectGridBackend) = 1
PlantSimEngine.environment_variables(::ModelObjectGridBackend) = Set([:T, :CO2])

function PlantSimEngine.bind_environment(
    backend::ModelObjectGridBackend,
    object::Object,
    support,
    config,
)
    object_geometry = geometry(object)
    cell = isnothing(object_geometry) ? :global : object_geometry.cell
    push!(
        backend.binds,
        (
            object=object.id.value,
            application=support.application,
            cell=cell,
            config=config,
        ),
    )
    return cell
end

function PlantSimEngine.update_index!(backend::ModelObjectGridBackend, entities)
    push!(
        backend.index_updates,
        [
            (
                id=entity.id,
                scale=entity.scale,
                kind=entity.kind,
                geometry=entity.geometry,
                position=entity.position,
                bounds=entity.bounds,
            )
            for entity in entities
        ],
    )
    return nothing
end

mutable struct ModelObjectMutableEnvironmentBackend <: PlantSimEngine.AbstractEnvironmentBackend
    values::Dict{Symbol,Float64}
    cells_by_status::Dict{UInt,Symbol}
    writes::Vector{Any}
end

ModelObjectMutableEnvironmentBackend(values::Pair...) =
    ModelObjectMutableEnvironmentBackend(Dict{Symbol,Float64}(values), Dict{UInt,Symbol}(), Any[])

PlantSimEngine.base_step_seconds(::ModelObjectMutableEnvironmentBackend) = 3600.0
PlantSimEngine.get_nsteps(::ModelObjectMutableEnvironmentBackend) = 1
PlantSimEngine.environment_variables(::ModelObjectMutableEnvironmentBackend) = Set([:T, :CO2])

function PlantSimEngine.bind_environment(
    backend::ModelObjectMutableEnvironmentBackend,
    object::Object,
    support,
    config,
)
    cell = object.geometry.cell
    backend.cells_by_status[objectid(object.status)] = cell
    return cell
end

function PlantSimEngine.sample(
    backend::ModelObjectMutableEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    time,
)
    variable == :CO2 && return 410.0
    variable == :T || error("Unexpected variable `$(variable)`.")
    cell = backend.cells_by_status[objectid(support.status)]
    return backend.values[cell]
end

function PlantSimEngine.scatter!(
    backend::ModelObjectMutableEnvironmentBackend,
    variable::Symbol,
    support::EnvironmentSupport,
    value,
    time,
)
    variable == :T || error("Unexpected variable `$(variable)`.")
    cell = backend.cells_by_status[objectid(support.status)]
    backend.values[cell] = value
    push!(
        backend.writes,
        (
            application=support.application,
            process=support.process,
            cell=cell,
            variable=variable,
            value=value,
            time=time,
        ),
    )
    return nothing
end

function PlantSimEngine.update_environment!(
    backend::ModelObjectMutableEnvironmentBackend,
    support::EnvironmentSupport,
    meteo,
    time,
)
    hasproperty(meteo, :T) || error("Updated test meteo must provide `T`.")
    cell = backend.cells_by_status[objectid(support.status)]
    backend.values[cell] = meteo.T
    push!(
        backend.writes,
        (
            application=support.application,
            process=support.process,
            cell=cell,
            meteo=meteo,
            time=time,
        ),
    )
    return nothing
end

@testset "Unified model/object API" begin
    mtg_root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    mtg_plant = Node(mtg_root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    mtg_leaf = Node(mtg_plant, MultiScaleTreeGraph.NodeMTG("+", :Leaf, 1, 2))
    mtg_leaf_status = Status(signal=2.0)
    mtg_leaf[:plantsimengine_status] = mtg_leaf_status
    mtg_object_id = node -> Symbol(lowercase(string(symbol(node))), "_", node_id(node))
    adapted_objects = objects_from_mtg(
        mtg_root;
        id=mtg_object_id,
        kind=node -> symbol(node) == :Scene ? :scene : :plant,
        species=node -> symbol(node) == :Scene ? nothing : :oil_palm,
        geometry=node -> symbol(node) == :Leaf ? (x=1.0, y=2.0) : nothing,
    )
    @test [object.id for object in adapted_objects] ==
          ObjectId.([:scene_1, :plant_2, :leaf_3])
    @test only(object for object in adapted_objects if object.scale == :Leaf).status ===
          mtg_leaf_status
    mtg_scene = CompositeModel(
        mtg_root;
        id=mtg_object_id,
        kind=node -> symbol(node) == :Scene ? :scene : :plant,
        species=node -> symbol(node) == :Scene ? nothing : :oil_palm,
        geometry=node -> symbol(node) == :Leaf ? (x=1.0, y=2.0) : nothing,
        applications=(
            ModelSpec(ModelObjectParameterizedSignalModel(1.0); name=:mtg_signal) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    @test only(model_objects(mtg_scene; scale=:Leaf)).parent == ObjectId(:plant_2)
    @test only(model_objects(mtg_scene; scale=:Leaf)).status === mtg_leaf_status
    @test position(only(model_objects(mtg_scene; scale=:Leaf))) == (x=1.0, y=2.0)
    run!(mtg_scene)
    @test only(model_objects(mtg_scene; scale=:Leaf)).status.signal == 3.0

    new_leaf_status = add_organ!(
        mtg_plant,
        mtg_scene,
        :+,
        :Leaf,
        2;
        index=2,
        id=4,
        attributes=(signal=4.0, color=:green),
        initial_status=(signal=5.0, age=1),
        kind=:plant,
    )
    @test new_leaf_status.node[:plantsimengine_status] === new_leaf_status
    @test new_leaf_status.signal == 5.0
    @test new_leaf_status.color == :green
    @test new_leaf_status.age == 1
    new_leaf_object = only(
        object for object in model_objects(mtg_scene; scale=:Leaf)
        if object.id == ObjectId(:leaf_4)
    )
    @test new_leaf_object.status === new_leaf_status
    @test new_leaf_object.parent == ObjectId(:plant_2)
    @test Advanced.bindings_dirty(mtg_scene)

    child_count = length(MultiScaleTreeGraph.children(mtg_plant))
    @test_throws ErrorException add_organ!(
        mtg_plant,
        mtg_scene,
        :+,
        :Leaf,
        2;
        index=3,
        id=4,
    )
    @test length(MultiScaleTreeGraph.children(mtg_plant)) == child_count

    auto_id_leaf_status = add_organ!(
        mtg_plant,
        mtg_scene,
        :+,
        :Leaf,
        2;
        index=3,
    )
    @test node_id(auto_id_leaf_status.node) == 5
    @test auto_id_leaf_status.node[:plantsimengine_status] === auto_id_leaf_status

    model = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(x=1.0, y=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1),
    )

    @test object_ids(model; scale=:Leaf) == [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test object_ids(model; kind=:plant, species=:oil_palm) == [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:plant_1)]
    @test only(model_objects(model; scale=:Scene)).id == ObjectId(:scene)

    leaf_2 = move_object!(model, :leaf_2, (x=2.0, y=0.0))
    @test leaf_2.geometry == (x=2.0, y=0.0)
    @test geometry(leaf_2) == (x=2.0, y=0.0)
    @test position(leaf_2) == (x=2.0, y=0.0)
    @test isnothing(bounds(leaf_2))
    bounded_leaf = Object(:bounded_leaf; scale=:Leaf, geometry=(position=(x=1.0, y=2.0, z=3.0), bounds=(radius=0.5,)))
    @test position(bounded_leaf) == (x=1.0, y=2.0, z=3.0)
    @test bounds(bounded_leaf) == (radius=0.5,)

    new_axis = register_object!(model, Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm); parent=:plant_1)
    @test new_axis.parent == ObjectId(:plant_1)
    @test ObjectId(:axis_1) in only(model_objects(model; scale=:Plant)).children

    reparent_object!(model, :leaf_2, :axis_1)
    @test only(model_objects(model; name=nothing, scale=:Axis)).children == [ObjectId(:leaf_2)]
    @test ObjectId(:leaf_2) ∉ only(model_objects(model; scale=:Plant)).children

    removed_axis = remove_object!(model, :axis_1)
    @test removed_axis.id == ObjectId(:axis_1)
    @test object_ids(model; scale=:Axis) == ObjectId[]
    @test object_ids(model; name=:leaf_2) == ObjectId[]

    object_rows = explain_objects(model)
    @test length(object_rows) == 3
    @test any(row -> row.id == :leaf_1 && row.has_geometry, object_rows)
    @test any(row -> row.id == :plant_1 && row.children == [ObjectId(:leaf_1).value], object_rows)

    selector_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, status=Status(leaf_area=1.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:axis_1, status=Status(leaf_area=2.0)),
        Object(:plant_2; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_2, parent=:scene),
        Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_2, status=Status(leaf_area=3.0)),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene),
    )

    scope_rows = explain_scopes(selector_scene)
    scene_scope = only(row for row in scope_rows if row.scope_type == :scene)
    @test scene_scope.selector isa SceneScope
    @test scene_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :leaf_3, :plant_1, :plant_2, :scene, :soil]
    plant_1_scope = only(row for row in scope_rows if row.scope_type == :object_subtree && row.root_id == :plant_1)
    @test plant_1_scope.selector isa Subtree
    @test plant_1_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :plant_1]
    palm_2_scope = only(row for row in scope_rows if row.scope_type == :named_scope && row.name == :palm_2)
    @test palm_2_scope.selector isa Scope
    @test palm_2_scope.root_id == :plant_2
    @test palm_2_scope.object_ids == [:leaf_3, :plant_2]
    leaf_label_scope = only(row for row in scope_rows if row.scope_type == :scale && row.scale == :Leaf)
    @test leaf_label_scope.selector == (:scale => :Leaf)
    @test leaf_label_scope.object_ids == [:leaf_1, :leaf_2, :leaf_3]
    oil_palm_scope = only(row for row in scope_rows if row.scope_type == :species && row.species == :oil_palm)
    @test oil_palm_scope.object_ids == [:axis_1, :leaf_1, :leaf_2, :leaf_3, :plant_1, :plant_2]

    @test resolve_object_ids(selector_scene, Many(scale=:Leaf)) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]
    @test only(resolve_objects(selector_scene, One(scale=:Scene))).id == ObjectId(:scene)
    @test resolve_object_ids(selector_scene, Many(Kind(:plant), Scale(:Leaf))) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Subtree()); context=:plant_1) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Subtree()); context=:leaf_2) ==
          [ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=SelfPlant()); context=:leaf_2) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Ancestor(scale=:Axis)); context=:leaf_2) ==
          [ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Scope(:palm_2))) ==
          [ObjectId(:leaf_3)]
    @test resolve_object_ids(selector_scene, One(Relation(:parent)); context=:leaf_2) ==
          [ObjectId(:axis_1)]
    @test resolve_object_ids(selector_scene, Many(Relation(:children)); context=:plant_1) ==
          [ObjectId(:axis_1), ObjectId(:leaf_1)]
    @test resolve_object_ids(selector_scene, Many(Relation(:ancestors)); context=:leaf_2) ==
          [ObjectId(:axis_1), ObjectId(:plant_1), ObjectId(:scene)]
    @test resolve_object_ids(selector_scene, Many(Relation(:descendants), Scale(:Leaf)); context=:plant_1) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    @test resolve_object_ids(selector_scene, Many(Relation(:siblings)); context=:axis_1) ==
          [ObjectId(:leaf_1)]
    @test resolve_object_ids(
        selector_scene,
        Many(Relation(:ancestors), Scale(:Plant), within=SceneScope());
        context=:leaf_2,
    ) == [ObjectId(:plant_1)]
    @test_throws "require a current object context" resolve_object_ids(
        selector_scene,
        Many(Relation(:children)),
    )
    @test_throws "Unsupported object relation" Relation(:cousins)
    @test resolve_object_ids(selector_scene, OptionalOne(scale=:Flower)) == ObjectId[]
    @test_throws ErrorException resolve_object_ids(selector_scene, One(scale=:Flower))
    @test_throws ErrorException resolve_object_ids(selector_scene, One(scale=:Leaf))
    typo_selector_error = try
        resolve_object_ids(selector_scene, One(scale=:Leef))
        nothing
    catch error
        sprint(showerror, error)
    end
    @test contains(typo_selector_error, "requested=(scale=Leef")
    @test contains(typo_selector_error, "available=(scales = [:Axis, :Leaf, :Plant, :Scene, :Soil]")
    @test contains(typo_selector_error, "suggestions=(scale = [:Leaf]")
    ambiguous_selector_error = try
        resolve_object_ids(selector_scene, One(scale=:Leaf))
        nothing
    catch error
        sprint(showerror, error)
    end
    @test contains(ambiguous_selector_error, "matched_ids=[:leaf_1, :leaf_2, :leaf_3]")
    scope_selector_error = try
        resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Scope(:palm_3)))
        nothing
    catch error
        sprint(showerror, error)
    end
    @test contains(scope_selector_error, "available=[:axis_1")
    @test contains(scope_selector_error, "suggestions=[:palm_1, :palm_2]")
    @test_throws ErrorException resolve_object_ids(selector_scene, Many(scale=:Leaf, within=Subtree()))
    @test resolve_object_ids(selector_scene, Many(scale=:Leaf); context=:plant_1) ==
          [ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]

    relation_input_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :plant_1;
            scale=:Plant,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:plant_1,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:plant_signal) |>
            AppliesTo(One(scale=:Plant)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:leaf_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :signal => One(
                    Relation(:parent),
                    process=:model_object_signal_source,
                    var=:signal,
                ),
            ),
        ),
    )
    relation_input_compiled = Advanced.refresh_bindings!(relation_input_scene)
    relation_binding = only(
        row for row in explain_bindings(relation_input_compiled)
        if row.application_id == :leaf_consumer
    )
    @test relation_binding.source_ids == [:plant_1]
    @test object_address(relation_binding.selector).relation == :parent
    @test relation_input_compiled.application_order == [:plant_signal, :leaf_consumer]
    run!(relation_input_scene)
    @test only(model_objects(relation_input_scene; scale=:Leaf)).status.observed_signal == 1.0

    shared_signal_model = ModelObjectParameterizedSignalModel(1.0)
    shared_template_parameters = Dict(:signal_increment => 1.0)
    plant_template = CompositeModelTemplate(
        (
            ModelSpec(shared_signal_model; name=:signal_source) |>
            AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ModelObjectPlantSignalSumModel(); name=:plant_total) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(
                :signals => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    process=:model_object_signal_source,
                    var=:signal,
                ),
            ),
        );
        kind=:plant,
        species=:oil_palm,
        parameters=shared_template_parameters,
    )
    palm_1_leaf_override = ModelObjectParameterizedSignalModel(3.0)
    palm_1 = ObjectInstance(
        :palm_1,
        plant_template;
        root=Object(:templated_plant_1; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(
            Object(:templated_leaf_1; scale=:Leaf, parent=:templated_plant_1, status=Status(signal=0.0)),
            Object(:templated_leaf_1_exception; scale=:Leaf, parent=:templated_plant_1, status=Status(signal=0.0)),
        ),
        object_overrides=(
            Override(
                object=:templated_leaf_1_exception,
                application=:signal_source,
                model=palm_1_leaf_override,
            ),
        ),
    )
    palm_2_override = ModelObjectParameterizedSignalModel(2.0)
    palm_2 = ObjectInstance(
        :palm_2,
        plant_template;
        root=Object(:templated_plant_2; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(Object(:templated_leaf_2; scale=:Leaf, parent=:templated_plant_2, status=Status(signal=0.0)),),
        overrides=(model_object_signal_source=palm_2_override,),
    )
    palm_3 = ObjectInstance(
        :palm_3,
        plant_template;
        root=Object(:templated_plant_3; scale=:Plant, parent=:scene, status=Status(signals=[0.0], signal_total=0.0)),
        objects=(Object(:templated_leaf_3; scale=:Leaf, parent=:templated_plant_3, status=Status(signal=0.0)),),
    )
    templated_plant_4 = Object(
        :templated_plant_4;
        scale=:Plant,
        parent=:scene,
        status=Status(signals=[0.0], signal_total=0.0),
    )
    templated_leaf_4 = Object(
        :templated_leaf_4;
        scale=:Leaf,
        parent=:templated_plant_4,
        status=Status(signal=0.0),
    )
    palm_4 = ObjectInstance(:palm_4, plant_template; root=:templated_plant_4)
    template_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        templated_plant_4,
        templated_leaf_4,
        palm_1,
        palm_2,
        palm_3;
        instances=(palm_4,),
    )
    @test length(template_scene.applications) == 8
    @test plant_template.parameters === shared_template_parameters
    @test only(model_objects(template_scene; name=:palm_1)).id == ObjectId(:templated_plant_1)
    @test object_ids(template_scene; species=:oil_palm) == [
        ObjectId(:templated_leaf_1),
        ObjectId(:templated_leaf_1_exception),
        ObjectId(:templated_leaf_2),
        ObjectId(:templated_leaf_3),
        ObjectId(:templated_leaf_4),
        ObjectId(:templated_plant_1),
        ObjectId(:templated_plant_2),
        ObjectId(:templated_plant_3),
        ObjectId(:templated_plant_4),
    ]
    template_compiled = Advanced.compile_composite_model(template_scene)
    template_application_rows = explain_applications(template_compiled)
    @test only(row for row in template_application_rows if row.application_id == :palm_1__signal_source).target_ids ==
          [:templated_leaf_1, :templated_leaf_1_exception]
    @test only(row for row in template_application_rows if row.application_id == :palm_2__signal_source).target_ids ==
          [:templated_leaf_2]
    @test only(row for row in template_application_rows if row.application_id == :palm_3__plant_total).target_ids ==
          [:templated_plant_3]
    palm_1_signal_row = only(
        row for row in template_application_rows
        if row.application_id == :palm_1__signal_source
    )
    @test palm_1_signal_row.model_type == typeof(shared_signal_model)
    @test palm_1_signal_row.model_storage == :per_object_override
    @test palm_1_signal_row.model_dispatch == :concrete_per_object
    @test palm_1_signal_row.object_overrides == [
        (
            object_id=:templated_leaf_1_exception,
            model_type=typeof(palm_1_leaf_override),
        ),
    ]
    @test (@inferred PlantSimEngine._application_model(
        template_compiled.applications_by_id[:palm_1__signal_source],
        ObjectId(:templated_leaf_1),
    )) === shared_signal_model
    @test (@inferred PlantSimEngine._application_model(
        template_compiled.applications_by_id[:palm_1__signal_source],
        ObjectId(:templated_leaf_1_exception),
    )) === palm_1_leaf_override
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_3__signal_source].spec) === shared_signal_model
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_4__signal_source].spec) === shared_signal_model
    @test PlantSimEngine.model_(template_compiled.applications_by_id[:palm_2__signal_source].spec) === palm_2_override
    template_instance_rows = explain_instances(template_scene)
    palm_1_instance_row = only(row for row in template_instance_rows if row.name == :palm_1)
    @test palm_1_instance_row.root_id == :templated_plant_1
    @test palm_1_instance_row.object_ids ==
          [:templated_leaf_1, :templated_leaf_1_exception, :templated_plant_1]
    @test palm_1_instance_row.application_ids ==
          [:palm_1__plant_total, :palm_1__signal_source]
    @test palm_1_instance_row.object_overrides == [
        (
            object_id=:templated_leaf_1_exception,
            process=nothing,
            application=:signal_source,
            model_type=typeof(palm_1_leaf_override),
        ),
    ]
    @test palm_1_instance_row.parameters_shared_by_reference
    @test only(row for row in explain_objects(template_scene) if row.id == :templated_leaf_1).instance ==
          :palm_1
    run!(template_scene; steps=1)
    @test only(model_objects(template_scene; name=:palm_1)).status.signal_total == 4.0
    @test only(model_objects(template_scene; name=:palm_2)).status.signal_total == 2.0
    @test only(model_objects(template_scene; name=:palm_3)).status.signal_total == 1.0
    @test only(model_objects(template_scene; name=:palm_4)).status.signal_total == 1.0
    registered_template_leaf = register_object!(
        template_scene,
        Object(:templated_leaf_new; scale=:Leaf, status=Status(signal=0.0));
        parent=:templated_plant_2,
    )
    @test registered_template_leaf.kind == :plant
    @test registered_template_leaf.species == :oil_palm
    @test :templated_leaf_new in only(
        row.object_ids for row in explain_instances(template_scene)
        if row.name == :palm_2
    )
    refreshed_template = Advanced.refresh_bindings!(template_scene)
    @test ObjectId(:templated_leaf_new) in
          refreshed_template.applications_by_id[:palm_2__signal_source].target_ids
    remove_object!(template_scene, :templated_leaf_new)
    @test_throws ErrorException CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            overrides=(missing_process=shared_signal_model,),
        ),
    )
    @test_throws ErrorException CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            overrides=(signal_source=Process1Model(1.0),),
        ),
    )
    @test_throws ErrorException CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant),),
            object_overrides=(
                Override(
                    object=:outside_instance,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    @test_throws ErrorException CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant),),
            object_overrides=(
                Override(
                    object=:invalid_leaf,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
                Override(
                    object=:invalid_leaf,
                    process=:model_object_signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    unmatched_override_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :invalid_palm,
            plant_template;
            root=Object(:invalid_plant; scale=:Plant, parent=:scene),
            objects=(Object(:invalid_leaf; scale=:Leaf, parent=:invalid_plant, status=Status(signal=0.0)),),
            object_overrides=(
                Override(
                    object=:invalid_plant,
                    application=:signal_source,
                    model=shared_signal_model,
                ),
            ),
        ),
    )
    @test_throws ErrorException Advanced.compile_composite_model(unmatched_override_scene)

    call_template = CompositeModelTemplate(
        (
            ModelSpec(shared_signal_model; name=:signal_source) |>
            AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ModelObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
        species=:oil_palm,
    )
    call_override_model = ModelObjectParameterizedSignalModel(4.0)
    call_override_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :call_palm,
            call_template;
            root=Object(:call_plant; scale=:Plant, parent=:scene),
            objects=(
                Object(:call_leaf_1; scale=:Leaf, parent=:call_plant, status=Status(signal=0.0, called_signal=0.0)),
                Object(:call_leaf_2; scale=:Leaf, parent=:call_plant, status=Status(signal=0.0, called_signal=0.0)),
            ),
            object_overrides=(
                Override(
                    object=:call_leaf_2,
                    application=:signal_source,
                    model=call_override_model,
                ),
            ),
        ),
    )
    run!(call_override_scene)
    call_leaf_1 = only(object for object in model_objects(call_override_scene; scale=:Leaf) if object.id == ObjectId(:call_leaf_1))
    call_leaf_2 = only(object for object in model_objects(call_override_scene; scale=:Leaf) if object.id == ObjectId(:call_leaf_2))
    @test call_leaf_1.status.called_signal == 1.0
    @test call_leaf_2.status.called_signal == 4.0

    leaf_selector = Many(
        kind="plant",
        scale=:Leaf,
        within=Subtree(),
        process="leaf_state",
        var="leaf_area",
        policy=Integrate(),
        window=Day(1),
    )

    @test leaf_selector.criteria.kind == :plant
    @test leaf_selector.criteria.scale == :Leaf
    @test leaf_selector.criteria.within isa Subtree
    @test leaf_selector.criteria.process == :leaf_state
    @test leaf_selector.criteria.var == :leaf_area
    @test leaf_selector.criteria.policy isa Integrate
    @test leaf_selector.criteria.window == Day(1)

    address = object_address(leaf_selector)
    @test address.scope isa Subtree
    @test address.kind == :plant
    @test address.scale == :Leaf
    @test address.process == :leaf_state
    @test address.var == :leaf_area
    @test address.multiplicity == :many

    @test One(Kind(:plant), Scale(:Leaf)).criteria.selectors == (Kind(:plant), Scale(:Leaf))
    @test object_address(OptionalOne(scale=:Scene)).multiplicity == :optional_one

    default_input = Input(Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon))
    @test default_input.selector isa Many
    @test default_input.selector.criteria.within isa Subtree

    default_call = Call(process=:stomatal_conductance)
    @test default_call.selector isa One
    @test object_address(default_call.selector).process == :stomatal_conductance

    m = Process1Model(1.0)
    spec = ModelSpec(m; name=:leaf_energy) |>
           AppliesTo(Many(kind=:plant, scale=:Leaf)) |>
           Inputs(
               :leaf_areas => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_area),
               :leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon, policy=Integrate(), window=Day(1)),
           ) |>
           Calls(:stomata => One(scale=:Leaf, process=:stomatal_conductance)) |>
           TimeStep(Hour(1)) |>
           Environment(provider=:global)

    @test PlantSimEngine.model_(spec) === m
    @test application_name(spec) == :leaf_energy
    @test applies_to(spec) isa Many
    @test applies_to(spec).criteria.kind == :plant
    @test value_inputs(spec).leaf_areas isa Many
    @test PlantSimEngine.input_origins(spec).leaf_areas == :model_spec
    @test PlantSimEngine.input_origins(spec).leaf_carbon == :model_spec
    @test value_inputs(spec).leaf_carbon.criteria.policy isa Integrate
    @test value_inputs(spec).leaf_carbon.criteria.window == Day(1)
    @test model_calls(spec).stomata isa One
    @test PlantSimEngine.call_origins(spec).stomata == :model_spec
    @test object_address(model_calls(spec).stomata).process == :stomatal_conductance
    @test isempty(dep(spec))
    @test PlantSimEngine.timestep(spec) == Hour(1)
    @test environment_config(spec) isa PlantSimEngine.EnvironmentConfig
    @test environment_config(spec).config.provider == :global

    leaf_assim = ModelSpec(ToyAssimModel()) |>
                 AppliesTo(Many(scale=:Leaf)) |>
                 Inputs(:soil_water_content => One(scale=:Soil, var=:soil_water_content))
    @test value_inputs(leaf_assim).soil_water_content.criteria.scale == :Soil
    @test value_inputs(leaf_assim).soil_water_content.criteria.var ==
          :soil_water_content

    rich_selector_spec = ModelSpec(ToyAssimModel()) |>
                         Inputs(:soil_water_content => One(kind=:soil, scale=:Soil, var=:soil_water_content))
    @test value_inputs(rich_selector_spec).soil_water_content.criteria.kind == :soil

    default_input_spec = ModelSpec(ModelObjectDefaultInputConsumerModel())
    @test value_inputs(default_input_spec).leaf_carbon isa Many
    @test PlantSimEngine.input_origins(default_input_spec).leaf_carbon ==
          :model_default
    @test value_inputs(default_input_spec).leaf_carbon.criteria.within isa Subtree
    @test !haskey(dep(default_input_spec), :leaf_carbon)

    override_input_spec = ModelSpec(ModelObjectDefaultInputConsumerModel()) |>
                          Inputs(:leaf_carbon => Many(scale=:Leaf, var=:carbon_override))
    @test value_inputs(override_input_spec).leaf_carbon.criteria.var == :carbon_override
    @test PlantSimEngine.input_origins(override_input_spec).leaf_carbon ==
          :model_spec

    default_input_origin_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:plant_1,
            status=Status(leaf_carbon=2.0, carbon_override=3.0),
        ),
    )
    default_input_origin_compiled = Advanced.compile_composite_model(
        default_input_origin_scene,
        (
            default_input_spec |>
            AppliesTo(One(scale=:Plant)),
        ),
    )
    @test only(explain_bindings(default_input_origin_compiled)).origin ==
          :model_default
    override_input_origin_compiled = Advanced.compile_composite_model(
        default_input_origin_scene,
        (
            override_input_spec |>
            AppliesTo(One(scale=:Plant)),
        ),
    )
    @test only(explain_bindings(override_input_origin_compiled)).origin ==
          :model_spec

    default_call_spec = ModelSpec(ModelObjectDefaultCallConsumerModel())
    @test model_calls(default_call_spec).stomata isa One
    @test PlantSimEngine.call_origins(default_call_spec).stomata ==
          :model_default
    @test model_calls(default_call_spec).stomata.criteria.scale == :Leaf
    @test model_calls(default_call_spec).stomata.criteria.process == :stomatal_conductance
    @test isempty(dep(default_call_spec))

    override_call_spec = ModelSpec(ModelObjectDefaultCallConsumerModel()) |>
                         Calls(:stomata => One(scale=:Internode, process=:water_status))
    @test model_calls(override_call_spec).stomata.criteria.scale == :Internode
    @test PlantSimEngine.call_origins(override_call_spec).stomata ==
          :model_spec
    @test model_calls(override_call_spec).stomata.criteria.process == :water_status
    @test isempty(dep(override_call_spec))

    manual_child_scene = CompositeModel(
        Object(
            :manual_child_leaf;
            scale=:Leaf,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectManualPairCallerModel(); name=:manual_parent) |>
            AppliesTo(One(scale=:Leaf)) |>
            Calls(
                :source => One(scale=:Leaf, application=:manual_source),
                :consumer => One(scale=:Leaf, application=:manual_consumer),
            ),
            ModelSpec(ModelObjectSignalSetModel(1.0); name=:root_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalSetModel(2.0); name=:manual_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:manual_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    manual_child_compiled = Advanced.compile_composite_model(manual_child_scene)
    @test isempty(
        filter(
            binding -> binding.application_id == :manual_consumer,
            manual_child_compiled.input_bindings,
        ),
    )

    compiled_specs = (
        ModelSpec(ModelObjectStomataModel(); name=:stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(ModelObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area, policy=Integrate(), window=Day(1))),
    )
    compiled = Advanced.compile_composite_model(selector_scene, compiled_specs)
    application_rows = explain_applications(compiled)
    @test length(application_rows) == 2
    @test only(row for row in application_rows if row.application_id == :stomata).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]
    @test only(row for row in application_rows if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]

    binding_rows = explain_bindings(compiled)
    @test length(binding_rows) == 3
    leaf_2_binding = only(row for row in binding_rows if row.consumer_id == :leaf_2)
    @test leaf_2_binding.application_id == :leaf_energy
    @test leaf_2_binding.origin == :model_spec
    @test leaf_2_binding.input == :leaf_areas
    @test leaf_2_binding.source_ids == [:leaf_1, :leaf_2]
    @test leaf_2_binding.source_var == :leaf_area
    @test leaf_2_binding.carrier_hint == :temporal_stream
    @test leaf_2_binding.carrier_kind == :temporal_stream
    @test leaf_2_binding.copy_semantics == :materialized_temporal_value

    call_rows = explain_calls(compiled)
    @test length(call_rows) == 3
    leaf_2_call = only(row for row in call_rows if row.consumer_id == :leaf_2)
    @test leaf_2_call.application_id == :leaf_energy
    @test leaf_2_call.origin == :model_default
    @test leaf_2_call.call == :stomata
    @test leaf_2_call.callee_object_ids == [:leaf_2]
    @test leaf_2_call.callee_application_ids == [:stomata]
    @test leaf_2_call.process == :model_object_stomata
    @test leaf_2_call.publication_policy == :explicit_accept
    @test !leaf_2_call.default_publish
    @test leaf_2_call.accepted_publish

    leaf_2_application = compiled.applications_by_id[:leaf_energy]
    leaf_2_models = compiled.model_bundles_by_target[(:leaf_energy, ObjectId(:leaf_2))]
    @test keys(leaf_2_models) == (:model_object_leaf_energy, :model_object_stomata)
    @test leaf_2_models.model_object_leaf_energy ===
          PlantSimEngine._application_model(leaf_2_application, ObjectId(:leaf_2))
    @test leaf_2_models.model_object_stomata ===
          PlantSimEngine._application_model(compiled.applications_by_id[:stomata], ObjectId(:leaf_2))
    @test PlantSimEngine._model_models_for_application(
        compiled,
        leaf_2_application,
        ObjectId(:leaf_2),
    ) === leaf_2_models
    PlantSimEngine._model_models_for_application(compiled, leaf_2_application, ObjectId(:leaf_2))
    @test @allocated(
        PlantSimEngine._model_models_for_application(
            compiled,
            leaf_2_application,
            ObjectId(:leaf_2),
        )
    ) == 0
    bundle_row = only(
        row for row in explain_model_bundles(compiled)
        if row.application_id == :leaf_energy && row.object_id == :leaf_2
    )
    @test bundle_row.processes == [:model_object_leaf_energy, :model_object_stomata]
    @test bundle_row.model_types == [ModelObjectLeafEnergyModel, ModelObjectStomataModel]

    compiled_environment = Advanced.compile_environment_bindings(selector_scene, compiled)
    execution_plan =
        PlantSimEngine.compile_model_execution_plan(compiled, compiled_environment)
    execution_rows = explain_execution_plan(execution_plan)
    @test length(execution_rows) == 1
    @test only(execution_rows).application_id == :leaf_energy
    @test only(execution_rows).object_ids == [:leaf_1, :leaf_2, :leaf_3]
    @test only(execution_rows).batch_size == 3
    @test only(execution_rows).inner_loop_dispatch == :concrete_homogeneous_batch
    @test isconcretetype(only(execution_rows).target_type)

    batch_counter = Ref(0)
    batch_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        (
            Object(
                Symbol(:batch_leaf_, index);
                scale=:Leaf,
                kind=:plant,
                parent=:scene,
                status=Status(),
            )
            for index in 1:128
        )...;
        applications=(
            ModelSpec(
                ModelObjectBatchCounterModel(batch_counter);
                name=:batch_counter,
            ) |>
            AppliesTo(Many(scale=:Leaf)),
        ),
    )
    batch_compiled = Advanced.refresh_bindings!(batch_scene)
    batch_environment = Advanced.refresh_environment_bindings!(batch_scene, batch_compiled)
    batch_plan =
        PlantSimEngine.compile_model_execution_plan(batch_compiled, batch_environment)
    @test length(batch_plan.batches) == 1
    homogeneous_batch = only(batch_plan.batches)
    @test isconcretetype(eltype(homogeneous_batch.targets))
    PlantSimEngine._run_model_execution_batch!(
        homogeneous_batch,
        batch_compiled,
        batch_environment;
        time=1,
        temporal_streams=nothing,
    )
    @test @allocated(
        PlantSimEngine._run_model_execution_batch!(
            homogeneous_batch,
            batch_compiled,
            batch_environment;
            time=1,
            temporal_streams=nothing,
        )
    ) == 0
    @test batch_counter[] == 256

    heterogeneous_template = CompositeModelTemplate(
        (
            ModelSpec(ModelObjectParameterizedSignalModel(1.0); name=:signal) |>
            AppliesTo(Many(scale=:Leaf)),
        );
        kind=:plant,
    )
    heterogeneous_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        ObjectInstance(
            :heterogeneous_plant,
            heterogeneous_template;
            root=Object(
                :heterogeneous_plant_object;
                scale=:Plant,
                parent=:scene,
            ),
            objects=(
                Object(
                    :heterogeneous_leaf_a;
                    scale=:Leaf,
                    parent=:heterogeneous_plant_object,
                    status=Status(signal=0.0),
                ),
                Object(
                    :heterogeneous_leaf_b;
                    scale=:Leaf,
                    parent=:heterogeneous_plant_object,
                    status=Status(signal=0.0),
                ),
                Object(
                    :heterogeneous_leaf_c;
                    scale=:Leaf,
                    parent=:heterogeneous_plant_object,
                    status=Status(signal=0.0),
                ),
            ),
            object_overrides=(
                Override(
                    object=:heterogeneous_leaf_b,
                    application=:signal,
                    model=ModelObjectAlternativeSignalModel(),
                ),
            ),
        ),
    )
    heterogeneous_compiled = Advanced.refresh_bindings!(heterogeneous_scene)
    heterogeneous_environment =
        Advanced.refresh_environment_bindings!(heterogeneous_scene, heterogeneous_compiled)
    heterogeneous_plan = PlantSimEngine.compile_model_execution_plan(
        heterogeneous_compiled,
        heterogeneous_environment,
    )
    heterogeneous_rows = explain_execution_plan(heterogeneous_plan)
    @test getproperty.(heterogeneous_rows, :object_ids) == [
        [:heterogeneous_leaf_a],
        [:heterogeneous_leaf_b],
        [:heterogeneous_leaf_c],
    ]
    @test getproperty.(heterogeneous_rows, :model_type) == [
        ModelObjectParameterizedSignalModel{Float64},
        ModelObjectAlternativeSignalModel,
        ModelObjectParameterizedSignalModel{Float64},
    ]
    run!(heterogeneous_scene)
    heterogeneous_values = Dict(
        object.id.value => object.status.signal
        for object in model_objects(heterogeneous_scene; scale=:Leaf)
    )
    @test heterogeneous_values == Dict(
        :heterogeneous_leaf_a => 1.0,
        :heterogeneous_leaf_b => 7.0,
        :heterogeneous_leaf_c => 1.0,
    )

    ambiguous_call_specs = (
        ModelSpec(ModelObjectStomataModel(); name=:sunlit_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(ModelObjectStomataModel(); name=:shaded_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(ModelObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)),
    )
    @test_throws ErrorException Advanced.compile_composite_model(selector_scene, ambiguous_call_specs)

    disambiguated_call_specs = (
        ModelSpec(ModelObjectStomataModel(); name=:sunlit_stomata) |>
        AppliesTo(Many(scale=:Leaf)),
        ModelSpec(ModelObjectStomataModel(); name=:shaded_stomata) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Updates(:gs; after=:sunlit_stomata),
        ModelSpec(ModelObjectLeafEnergyModel(); name=:leaf_energy) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area)) |>
        Calls(:stomata => One(process=:model_object_stomata, application=:sunlit_stomata)),
    )
    disambiguated = Advanced.compile_composite_model(selector_scene, disambiguated_call_specs)
    disambiguated_call = only(row for row in explain_calls(disambiguated) if row.consumer_id == :leaf_2)
    @test disambiguated_call.origin == :model_spec
    @test disambiguated_call.callee_application_ids == [:sunlit_stomata]
    @test disambiguated_call.application == :sunlit_stomata
    leaf_2_call_bindings = disambiguated.call_bindings_by_target[(:leaf_energy, ObjectId(:leaf_2))]
    @test length(leaf_2_call_bindings) == 1
    @test only(leaf_2_call_bindings).call == :stomata

    optional_dependency_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(optional_signal=99.0),
        );
        applications=(
            ModelSpec(
                ModelObjectOptionalInputConsumerModel();
                name=:optional_input_consumer,
            ) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :optional_signal => OptionalOne(
                    scale=:Leaf,
                    within=SceneScope(),
                    process=:missing_optional_source,
                    var=:optional_signal,
                ),
            ),
            ModelSpec(
                ModelObjectOptionalCallConsumerModel();
                name=:optional_call_consumer,
            ) |>
            AppliesTo(One(scale=:Scene)) |>
            Calls(
                :optional_source => OptionalOne(
                    scale=:Leaf,
                    within=SceneScope(),
                    process=:missing_optional_source,
                ),
            ),
        ),
    )
    optional_compiled = Advanced.refresh_bindings!(optional_dependency_scene)
    optional_binding = only(explain_bindings(optional_compiled))
    @test optional_binding.multiplicity == :optional_one
    @test isempty(optional_binding.source_ids)
    @test isempty(optional_binding.source_application_ids)
    @test optional_binding.carrier_hint == :optional_default
    @test optional_binding.carrier_kind == :optional_default
    @test optional_binding.copy_semantics == :consumer_default
    optional_call = only(explain_calls(optional_compiled))
    @test optional_call.multiplicity == :optional_one
    @test optional_call.callee_object_ids == [:leaf_1]
    @test isempty(optional_call.callee_application_ids)
    @test !optional_call.resolved
    run!(optional_dependency_scene)
    optional_model_status =
        only(model_objects(optional_dependency_scene; scale=:Scene)).status
    @test optional_model_status.optional_signal == 7.0
    @test optional_model_status.observed_optional_signal == 7.0
    @test optional_model_status.optional_call_count == 0

    renamed_input_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(
                ModelObjectRenamedSignalConsumerModel();
                name=:renamed_consumer,
            ) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :renamed_signal => One(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:signal_source,
                    var=:signal,
                ),
            ),
            ModelSpec(ModelObjectSignalSetModel(12.5); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    renamed_compiled = Advanced.refresh_bindings!(renamed_input_scene)
    renamed_binding = only(explain_bindings(renamed_compiled))
    @test renamed_binding.input == :renamed_signal
    @test renamed_binding.source_var == :signal
    @test renamed_binding.source_application_ids == [:signal_source]
    @test renamed_binding.carrier_kind == :ref
    @test renamed_binding.copy_semantics == :live_references
    @test renamed_compiled.application_order ==
          [:signal_source, :renamed_consumer]
    renamed_status = only(model_objects(renamed_input_scene; scale=:Leaf)).status
    @test PlantSimEngine.refvalue(renamed_status, :renamed_signal) ===
          PlantSimEngine.refvalue(renamed_status, :signal)
    run!(renamed_input_scene)
    @test renamed_status.observed_renamed_signal == 12.5

    default_scope_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=1.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=2.0)),
        Object(:plant_2; scale=:Plant, kind=:plant, parent=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_3; scale=:Leaf, kind=:plant, parent=:plant_2, status=Status(leaf_area=3.0)),
    )
    plant_default_scope = Advanced.compile_composite_model(
        default_scope_scene,
        (
            ModelSpec(ModelObjectTemporalSumModel(); name=:plant_leaf_sum) |>
            AppliesTo(Many(scale=:Plant)) |>
            Inputs(:signal_sum => Many(scale=:Leaf, within=Subtree(), var=:leaf_area)),
        ),
    )
    @test only(row for row in explain_bindings(plant_default_scope) if row.consumer_id == :plant_1).source_ids ==
          [:leaf_1, :leaf_2]
    @test only(row for row in explain_bindings(plant_default_scope) if row.consumer_id == :plant_2).source_ids ==
          [:leaf_3]
    scene_default_scope = Advanced.compile_composite_model(
        default_scope_scene,
        (
            ModelSpec(ModelObjectTemporalSumModel(); name=:scene_leaf_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => Many(scale=:Leaf, var=:leaf_area)),
        ),
    )
    @test only(explain_bindings(scene_default_scope)).source_ids == [:leaf_1, :leaf_2, :leaf_3]

    inferred_input_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0)),
    )
    inferred_input_specs = (
        ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
        AppliesTo(One(scale=:Leaf)),
        ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
        AppliesTo(One(scale=:Leaf)),
    )
    inferred_compiled = Advanced.compile_composite_model(inferred_input_scene, inferred_input_specs)
    inferred_binding = only(explain_bindings(inferred_compiled))
    @test inferred_binding.application_id == :signal_consumer
    @test inferred_binding.input == :signal
    @test inferred_binding.origin == :inferred_same_object
    @test inferred_binding.source_ids == [:leaf_1]
    @test inferred_binding.source_application_ids == [:signal_source]
    @test inferred_binding.process == :model_object_signal_source
    @test inferred_binding.application == :signal_source
    @test inferred_binding.has_reference_carrier
    @test inferred_binding.carrier_kind == :ref
    @test inferred_binding.copy_semantics == :live_references
    inferred_consumer_status = only(model_objects(inferred_input_scene; scale=:Leaf)).status
    inferred_compiled_binding = only(
        binding for binding in inferred_compiled.input_bindings
        if binding.application_id == :signal_consumer
    )
    @test PlantSimEngine.refvalue(inferred_consumer_status, :signal) === input_carrier(inferred_compiled_binding)
    inferred_input_model_with_apps = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0));
        applications=inferred_input_specs,
    )
    run!(inferred_input_model_with_apps)
    @test only(model_objects(inferred_input_model_with_apps; scale=:Leaf)).status.observed_signal == 1.0

    generated_status_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    generated_status_compiled = Advanced.refresh_bindings!(generated_status_scene)
    generated_status = only(model_objects(generated_status_scene; scale=:Leaf)).status
    @test generated_status isa Status
    @test Set(propertynames(generated_status)) ==
          Set((:signal, :observed_signal))
    generated_binding = only(
        binding for binding in generated_status_compiled.input_bindings
        if binding.application_id == :signal_consumer
    )
    @test PlantSimEngine.refvalue(generated_status, :signal) === input_carrier(generated_binding)
    run!(generated_status_scene)
    @test generated_status.observed_signal == 1.0

    reversed_dependency_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0));
        applications=reverse(inferred_input_specs),
    )
    reversed_compiled = Advanced.refresh_bindings!(reversed_dependency_scene)
    @test length(reversed_compiled.applications_by_id) == length(reversed_compiled.applications)
    @test reversed_compiled.applications_by_id[:signal_source].process == :model_object_signal_source
    @test reversed_compiled.applications_by_id[:signal_consumer].process == :model_object_signal_consumer
    @test reversed_compiled.application_order == [:signal_source, :signal_consumer]
    @test [row.application_id for row in explain_schedule(reversed_compiled)] ==
          [:signal_source, :signal_consumer]
    @test [row.execution_index for row in explain_schedule(reversed_compiled)] == [1, 2]
    run!(reversed_dependency_scene)
    @test only(model_objects(reversed_dependency_scene; scale=:Leaf)).status.observed_signal == 1.0

    @test_throws ErrorException Advanced.compile_composite_model(
        CompositeModel(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(cycle_a=0.0, cycle_b=0.0)),
        ),
        (
            ModelSpec(ModelObjectCycleAModel(); name=:cycle_a) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectCycleBModel(); name=:cycle_b) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )

    lagged_cycle_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(cycle_a=0.0, cycle_b=1.0),
        );
        applications=(
            ModelSpec(ModelObjectCycleAModel(); name=:cycle_a) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                PreviousTimeStep(:cycle_b) => One(
                    scale=:Leaf,
                    process=:model_object_cycle_b,
                    var=:cycle_b,
                ),
            ),
            ModelSpec(ModelObjectCycleBModel(); name=:cycle_b) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    lagged_cycle_compiled = Advanced.refresh_bindings!(lagged_cycle_scene)
    @test lagged_cycle_compiled.application_order == [:cycle_a, :cycle_b]
    lagged_binding = only(
        row for row in explain_bindings(lagged_cycle_compiled)
        if row.application_id == :cycle_a && row.input == :cycle_b
    )
    @test lagged_binding.policy == PreviousTimeStep(:cycle_b)
    @test lagged_binding.carrier_kind == :temporal_stream
    @test lagged_binding.copy_semantics == :materialized_temporal_value
    lagged_cycle_simulation = run!(
        lagged_cycle_scene;
        steps=3,
        outputs=OutputRequest(
            :Leaf,
            :cycle_a;
            name=:lagged_cycle_a,
            application=:cycle_a,
        ),
    )
    lagged_cycle_status = only(model_objects(lagged_cycle_scene; scale=:Leaf)).status
    @test lagged_cycle_status.cycle_a == 11.0
    @test lagged_cycle_status.cycle_b == 22.0
    @test getproperty.(
        collect_outputs(
            lagged_cycle_simulation,
            :leaf_1,
            :cycle_a;
            sink=nothing,
        ),
        :value,
    ) == [2.0, 5.0, 11.0]
    lagged_source_stream = outputs(lagged_cycle_simulation)[
        (:cycle_b, ObjectId(:leaf_1), :cycle_b)
    ]
    @test getindex.(lagged_source_stream, 1) == [2.0, 3.0]
    @test getindex.(lagged_source_stream, 2) == [10.0, 22.0]
    @test only(
        row for row in explain_output_retention(lagged_cycle_simulation)
        if row.application_id == :cycle_b
    ).retention_steps == 2.0

    lagged_external_state_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(signal=4.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(signal=6.0));
        applications=(
            ModelSpec(ModelObjectPlantSignalSumModel(); name=:plant_signal_sum) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(
                PreviousTimeStep(:signals) => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    var=:signal,
                ),
            ),
        ),
    )
    lagged_external_binding = only(
        row for row in explain_bindings(Advanced.refresh_bindings!(lagged_external_state_scene))
        if row.application_id == :plant_signal_sum && row.input == :signals
    )
    @test lagged_external_binding.carrier_kind == :temporal_stream
    @test isempty(lagged_external_binding.source_application_ids)
    run!(lagged_external_state_scene; steps=2)
    @test only(model_objects(lagged_external_state_scene; scale=:Plant)).status.signal_total == 10.0

    mismatched_lag_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(cycle_a=0.0, cycle_b=1.0),
        );
        applications=(
            ModelSpec(ModelObjectCycleAModel(); name=:cycle_a) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :cycle_b => One(
                    scale=:Leaf,
                    process=:model_object_cycle_b,
                    var=:cycle_b,
                    policy=PreviousTimeStep(:other),
                ),
            ),
            ModelSpec(ModelObjectCycleBModel(); name=:cycle_b) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    @test_throws "PreviousTimeStep marker for input `cycle_b`" Advanced.refresh_bindings!(mismatched_lag_scene)

    @test_throws ErrorException Advanced.compile_composite_model(
        CompositeModel(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene),
        ),
        (
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    @test_throws ErrorException Advanced.compile_composite_model(
        inferred_input_scene,
        (
            ModelSpec(ModelObjectSignalSourceModel(); name=:sunlit_signal) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalSourceModel(); name=:shaded_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            Updates(:signal; after=:sunlit_signal),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )

    filtered_input_specs = (
        ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
        AppliesTo(One(scale=:Leaf)),
        ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
        AppliesTo(One(scale=:Leaf)) |>
        Inputs(:signal => One(scale=:Leaf, var=:signal, process=:model_object_signal_source, application=:signal_source)),
    )
    filtered_binding = only(explain_bindings(Advanced.compile_composite_model(inferred_input_scene, filtered_input_specs)))
    @test filtered_binding.origin == :model_spec
    @test filtered_binding.source_application_ids == [:signal_source]
    @test filtered_binding.process == :model_object_signal_source
    @test filtered_binding.application == :signal_source
    @test_throws ErrorException Advanced.compile_composite_model(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:signal => One(scale=:Leaf, var=:signal, application=:missing_source)),
        ),
    )
    @test_throws ErrorException Advanced.compile_composite_model(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:siggnal => One(scale=:Leaf, var=:signal, application=:signal_source)),
        ),
    )
    @test_throws ErrorException Advanced.compile_composite_model(
        inferred_input_scene,
        (
            filtered_input_specs[1],
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:signal => One(scale=:Leaf, var=:missing_signal)),
        ),
    )

    carrier_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, status=Status(leaf_area=1.0, leaf_token=ModelObjectTaggedValue(1), aPPFD=100.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, status=Status(leaf_area=2.0, leaf_token=2, aPPFD=100.0)),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene, status=Status(soil_water_content=0.31)),
    )
    carrier_specs = (
        ModelSpec(ModelObjectCarrierConsumerModel(); name=:carrier_consumer) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(
            :leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area),
            :leaf_tokens => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_token),
        ),
        ModelSpec(ToyAssimModel(); name=:assim) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Inputs(:soil_water_content => One(scale=:Soil, within=SceneScope(), var=:soil_water_content)),
    )
    carrier_compiled = Advanced.compile_composite_model(carrier_scene, carrier_specs)
    carrier_rows = explain_bindings(carrier_compiled)
    leaf_1_carrier_bindings = carrier_compiled.input_bindings_by_target[(:carrier_consumer, ObjectId(:leaf_1))]
    @test length(leaf_1_carrier_bindings) == 2
    @test Set(binding.input for binding in leaf_1_carrier_bindings) == Set((:leaf_areas, :leaf_tokens))
    @test length(carrier_compiled.input_bindings_by_target[(:assim, ObjectId(:leaf_1))]) == 1
    leaf_area_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :carrier_consumer && binding.consumer_id == ObjectId(:leaf_1) && binding.input == :leaf_areas
    )
    @test has_reference_carrier(leaf_area_binding)
    @test input_carrier(leaf_area_binding) isa PlantSimEngine.RefVector
    leaf_2_area_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :carrier_consumer &&
           binding.consumer_id == ObjectId(:leaf_2) &&
           binding.input == :leaf_areas
    )
    @test input_carrier(leaf_2_area_binding) === input_carrier(leaf_area_binding)
    @test leaf_2_area_binding.source_ids === leaf_area_binding.source_ids
    @test input_value(leaf_area_binding)[1] == 1.0
    input_value(leaf_area_binding)[1] = 4.0
    leaf_1_object = only(object for object in model_objects(carrier_scene; scale=:Leaf) if object.id == ObjectId(:leaf_1))
    @test leaf_1_object.status.leaf_area == 4.0
    leaf_area_row = only(row for row in carrier_rows if row.application_id == :carrier_consumer && row.consumer_id == :leaf_1 && row.input == :leaf_areas)
    @test leaf_area_row.has_reference_carrier
    @test leaf_area_row.carrier_kind == :ref_vector
    @test leaf_area_row.copy_semantics == :live_references

    token_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :carrier_consumer && binding.consumer_id == ObjectId(:leaf_1) && binding.input == :leaf_tokens
    )
    @test input_value(token_binding)[2] == 2
    input_value(token_binding)[2] = 20
    leaf_2_object = only(object for object in model_objects(carrier_scene; scale=:Leaf) if object.id == ObjectId(:leaf_2))
    @test leaf_2_object.status.leaf_token == 20
    token_row = only(row for row in carrier_rows if row.application_id == :carrier_consumer && row.consumer_id == :leaf_1 && row.input == :leaf_tokens)
    @test token_row.carrier_kind == :object_ref_vector
    @test token_row.copy_semantics == :live_references

    scalar_binding = only(
        binding for binding in carrier_compiled.input_bindings
        if binding.application_id == :assim && binding.consumer_id == ObjectId(:leaf_1)
    )
    @test has_reference_carrier(scalar_binding)
    @test input_carrier(scalar_binding) isa Base.RefValue
    @test input_value(scalar_binding) == 0.31
    input_carrier(scalar_binding)[] = 0.42
    @test only(model_objects(carrier_scene; scale=:Soil)).status.soil_water_content == 0.42
    scalar_row = only(row for row in carrier_rows if row.application_id == :assim && row.consumer_id == :leaf_1)
    @test scalar_row.carrier_kind == :ref
    @test scalar_row.copy_semantics == :live_references

    dual_a = ModelObjectDualLike(big"1.25", big"0.5")
    dual_b = ModelObjectDualLike(big"2.75", big"1.5")
    generic_carrier_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(dual_value=dual_a),
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(dual_value=dual_b),
        );
        applications=(
            ModelSpec(ModelObjectDualLikeSumModel(); name=:dual_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :values => Many(
                    scale=:Leaf,
                    within=SceneScope(),
                    var=:dual_value,
                ),
            ),
        ),
    )
    generic_carrier_compiled = Advanced.refresh_bindings!(generic_carrier_scene)
    generic_carrier_binding = only(generic_carrier_compiled.input_bindings)
    @test input_carrier(generic_carrier_binding) isa
          PlantSimEngine.RefVector{ModelObjectDualLike{BigFloat}}
    @test eltype(input_carrier(generic_carrier_binding)) ==
          ModelObjectDualLike{BigFloat}
    generic_carrier_sim = run!(generic_carrier_scene; outputs=:all)
    generic_model_status = only(model_objects(generic_carrier_scene; scale=:Scene)).status
    @test generic_model_status.values === input_carrier(generic_carrier_binding)
    @test generic_model_status.total == ModelObjectDualLike(big"4.0", big"2.0")
    generic_leaf_1 =
        only(object for object in model_objects(generic_carrier_scene; scale=:Leaf)
             if object.id == ObjectId(:leaf_1))
    generic_leaf_1.status.dual_value = ModelObjectDualLike(big"3.25", big"2.5")
    @test generic_model_status.values[1] ==
          ModelObjectDualLike(big"3.25", big"2.5")
    @test eltype(
        outputs(generic_carrier_sim)[
            (:dual_sum, ObjectId(:scene), :total)
        ],
    ) == Tuple{Float64,ModelObjectDualLike{BigFloat}}
    original_generic_carrier = input_carrier(generic_carrier_binding)
    register_object!(
        generic_carrier_scene,
        Object(
            :leaf_3;
            scale=:Leaf,
            kind=:plant,
            status=Status(dual_value=ModelObjectDualLike(big"4.5", big"3.5")),
        );
        parent=:scene,
    )
    extended_generic_compiled = Advanced.refresh_bindings!(generic_carrier_scene)
    extended_generic_binding = only(extended_generic_compiled.input_bindings)
    @test input_carrier(extended_generic_binding) === original_generic_carrier
    @test extended_generic_binding.source_ids ==
          ObjectId[ObjectId(:leaf_1), ObjectId(:leaf_2), ObjectId(:leaf_3)]
    @test input_value(extended_generic_binding)[3] ==
          ModelObjectDualLike(big"4.5", big"3.5")

    cache_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:axis_1; scale=:Axis, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:axis_1),
        Object(:plant_2; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_2, parent=:scene),
        Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_2),
        Object(:soil; scale=:Soil, kind=:soil, parent=:scene);
        applications=compiled_specs,
    )
    @test Advanced.bindings_dirty(cache_scene)
    cached_a = Advanced.refresh_bindings!(cache_scene)
    @test cached_a isa Advanced.CompiledCompositeModel
    @test !Advanced.bindings_dirty(cache_scene)
    @test Advanced.compiled_bindings(cache_scene) === cached_a
    @test cached_a.revision == Advanced.model_revision(cache_scene)
    @test Advanced.refresh_bindings!(cache_scene) === cached_a

    register_object!(cache_scene, Object(:leaf_4; scale=:Leaf, kind=:plant, species=:oil_palm); parent=:plant_2)
    @test Advanced.bindings_dirty(cache_scene)
    @test isnothing(Advanced.compiled_bindings(cache_scene))
    cached_b = Advanced.refresh_bindings!(cache_scene)
    @test cached_b !== cached_a
    @test cached_b.revision == Advanced.model_revision(cache_scene)
    @test only(row for row in explain_applications(cached_b) if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3, :leaf_4]
    @test only(row for row in explain_bindings(cached_b) if row.consumer_id == :leaf_3).source_ids ==
          [:leaf_3, :leaf_4]

    move_object!(cache_scene, :leaf_4, (x=3.0, y=0.0))
    @test !Advanced.bindings_dirty(cache_scene)
    @test Advanced.environment_bindings_dirty(cache_scene)
    @test Advanced.refresh_bindings!(cache_scene) === cached_b
    mark_environment_binding_dirty!(cache_scene)
    @test !Advanced.bindings_dirty(cache_scene)

    reparent_object!(cache_scene, :leaf_4, :plant_1)
    cached_c = Advanced.refresh_bindings!(cache_scene)
    @test only(row for row in explain_bindings(cached_c) if row.consumer_id == :leaf_4).source_ids ==
          [:leaf_1, :leaf_2, :leaf_4]

    remove_object!(cache_scene, :leaf_4)
    cached_d = Advanced.refresh_bindings!(cache_scene)
    @test only(row for row in explain_applications(cached_d) if row.application_id == :leaf_energy).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]

    grid_backend = ModelObjectGridBackend(Any[])
    environment_specs = (
        ModelSpec(ModelObjectEnvironmentProbeModel(); name=:probe) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Environment(provider=:grid),
        ModelSpec(ModelObjectEnvironmentUpdateModel(); name=:temperature_update) |>
        AppliesTo(Many(scale=:Leaf)) |>
        Environment(provider=:grid),
    )
    environment_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, species=:oil_palm, name=:palm_1, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(cell=:cell_a,)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, species=:oil_palm, parent=:plant_1, geometry=(cell=:cell_b,));
        applications=environment_specs,
        environment=grid_backend,
    )
    compiled_environment = Advanced.refresh_environment_bindings!(environment_scene)
    @test compiled_environment isa Advanced.CompiledEnvironmentBindings
    @test !Advanced.environment_bindings_dirty(environment_scene)
    @test Advanced.compiled_environment_bindings(environment_scene) === compiled_environment
    @test length(compiled_environment.by_target) == length(compiled_environment.bindings)
    @test compiled_environment.by_target[(:probe, ObjectId(:leaf_1))].cell == :cell_a
    @test compiled_environment.by_target[(:temperature_update, ObjectId(:leaf_2))].cell == :cell_b
    @test length(grid_backend.binds) == 4
    @test length(grid_backend.index_updates) == 1
    @test any(entity -> entity.id == :leaf_1 && entity.geometry == (cell=:cell_a,), grid_backend.index_updates[1])
    @test any(entity -> entity.id == :plant_1 && entity.scale == :Plant, grid_backend.index_updates[1])
    environment_rows = explain_environment_bindings(compiled_environment)
    @test length(environment_rows) == 4
    leaf_1_probe = only(row for row in environment_rows if row.application_id == :probe && row.object_id == :leaf_1)
    @test leaf_1_probe.provider == :grid
    @test leaf_1_probe.cell == :cell_a
    @test leaf_1_probe.required_inputs == [:T, :CO2]
    @test leaf_1_probe.produced_outputs == Symbol[]
    leaf_2_update = only(row for row in environment_rows if row.application_id == :temperature_update && row.object_id == :leaf_2)
    @test leaf_2_update.cell == :cell_b
    @test leaf_2_update.required_inputs == [:T]
    @test leaf_2_update.source_inputs == [:T]
    @test leaf_2_update.produced_outputs == Symbol[]

    missing_global_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(ModelObjectEnvironmentCO2ProbeModel(); name=:co2_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:global),
        ),
        environment=(T=20.0,),
    )
    @test_throws "co2_probe" validate_meteo_inputs(missing_global_meteo_scene)
    @test_throws "Composite model environment is missing required meteo inputs" Advanced.refresh_environment_bindings!(missing_global_meteo_scene)
    @test_throws "source `CO2`" Advanced.refresh_environment_bindings!(missing_global_meteo_scene)

    application_environment_backend =
        ModelObjectMutableEnvironmentBackend(:cell_a => 23.0)
    application_environment_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
        );
        applications=(
            ModelSpec(ModelObjectEnvironmentCO2ProbeModel(); name=:local_co2_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(backend=application_environment_backend),
        ),
        environment=(T=20.0,),
    )
    @test validate_meteo_inputs(application_environment_scene) === nothing
    @test validate_meteo_inputs(Advanced.refresh_bindings!(application_environment_scene)) ===
          nothing
    @test_throws "CO2" validate_meteo_inputs(
        Advanced.refresh_bindings!(application_environment_scene),
        (T=20.0,),
    )

    remapped_global_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(ModelObjectEnvironmentCO2ProbeModel(); name=:co2_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:global, sources=(CO2=:Ca,)),
        ),
        environment=(T=20.0, Ca=415.0),
    )
    @test validate_meteo_inputs(remapped_global_meteo_scene) === nothing
    @test_throws "Ca" validate_meteo_inputs(
        Advanced.refresh_bindings!(remapped_global_meteo_scene),
        (T=20.0, CO2=415.0),
    )
    @test validate_meteo_inputs(
        Advanced.refresh_bindings!(remapped_global_meteo_scene),
        (T=20.0, Ca=415.0),
    ) === nothing
    remapped_environment = Advanced.refresh_environment_bindings!(remapped_global_meteo_scene)
    remapped_row = only(explain_environment_bindings(remapped_environment))
    @test remapped_row.required_inputs == [:T, :CO2]
    @test remapped_row.source_inputs == [:T, :Ca]
    run!(remapped_global_meteo_scene)
    remapped_status = only(model_objects(remapped_global_meteo_scene; scale=:Leaf)).status
    @test remapped_status.temperature_seen == 20.0
    @test remapped_status.co2_seen == 415.0

    hinted_global_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(ModelObjectEnvironmentCO2HintProbeModel(); name=:co2_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:global),
        ),
        environment=(T=21.0, Ca=420.0),
    )
    @test validate_meteo_inputs(hinted_global_meteo_scene) === nothing
    hinted_environment = Advanced.refresh_environment_bindings!(hinted_global_meteo_scene)
    hinted_row = only(explain_environment_bindings(hinted_environment))
    @test hinted_row.required_inputs == [:T, :CO2]
    @test hinted_row.source_inputs == [:T, :Ca]
    hinted_application = Advanced.refresh_bindings!(hinted_global_meteo_scene).applications_by_id[:co2_probe]
    @test meteo_bindings(hinted_application.spec).CO2.source == :Ca
    run!(hinted_global_meteo_scene)
    hinted_status = only(model_objects(hinted_global_meteo_scene; scale=:Leaf)).status
    @test hinted_status.temperature_seen == 21.0
    @test hinted_status.co2_seen == 420.0

    hinted_override_global_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(ModelObjectEnvironmentCO2HintProbeModel(); name=:co2_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:global, sources=(CO2=:Cb,)),
        ),
        environment=(T=22.0, Ca=420.0, Cb=430.0),
    )
    hinted_override_row = only(
        explain_environment_bindings(Advanced.refresh_environment_bindings!(hinted_override_global_meteo_scene))
    )
    @test hinted_override_row.source_inputs == [:T, :Cb]
    hinted_override_application =
        Advanced.refresh_bindings!(hinted_override_global_meteo_scene).applications_by_id[:co2_probe]
    @test meteo_bindings(hinted_override_application.spec).CO2.source == :Cb
    @test meteo_bindings(hinted_override_application.spec).CO2.reducer isa MeanReducer
    run!(hinted_override_global_meteo_scene)
    hinted_override_status =
        only(model_objects(hinted_override_global_meteo_scene; scale=:Leaf)).status
    @test hinted_override_status.temperature_seen == 22.0
    @test hinted_override_status.co2_seen == 430.0

    if PlantSimEngine._has_meteo_sampler_api()
        windowed_weather = Weather([
            Atmosphere(
                T=10.0,
                Wind=1.0,
                Rh=0.50,
                P=100.0,
                duration=Hour(1),
                Ca=400.0,
                Cb=410.0,
            ),
            Atmosphere(
                T=20.0,
                Wind=1.0,
                Rh=0.60,
                P=100.0,
                duration=Hour(1),
                Ca=410.0,
                Cb=420.0,
            ),
            Atmosphere(
                T=30.0,
                Wind=1.0,
                Rh=0.70,
                P=100.0,
                duration=Hour(1),
                Ca=420.0,
                Cb=430.0,
            ),
            Atmosphere(
                T=40.0,
                Wind=1.0,
                Rh=0.80,
                P=100.0,
                duration=Hour(1),
                Ca=430.0,
                Cb=440.0,
            ),
        ])
        windowed_default_scene = CompositeModel(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene),
            Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:scene);
            applications=(
                ModelSpec(ModelObjectTemperatureOnlyProbeModel(); name=:temperature_probe) |>
                AppliesTo(Many(scale=:Leaf)) |>
                TimeStep(Hour(2)),
            ),
            environment=windowed_weather,
        )
        windowed_default_sim = run!(windowed_default_scene; steps=4, outputs=:all)
        for leaf in model_objects(windowed_default_scene; scale=:Leaf)
            @test leaf.status.temperature_seen == 25.0
            values = getproperty.(
                collect_outputs(
                    windowed_default_sim,
                    leaf.id.value,
                    :temperature_seen;
                    sink=nothing,
                ),
                :value,
            )
            @test values == [10.0, 25.0]
        end
        @test isempty(windowed_default_sim.environment_bindings.sample_cache)
        @test all(
            row -> row.temporal_sampler,
            explain_environment_bindings(windowed_default_sim.environment_bindings),
        )

        windowed_override_scene = CompositeModel(
            Object(:scene; scale=:Scene, kind=:scene),
            Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene);
            applications=(
                ModelSpec(
                    ModelObjectAggregatedEnvironmentProbeModel();
                    name=:aggregated_probe,
                ) |>
                AppliesTo(One(scale=:Leaf)) |>
                TimeStep(Hour(2)) |>
                Environment(provider=:global, sources=(CO2=:Cb,)),
            ),
            environment=windowed_weather,
        )
        windowed_override_application =
            Advanced.refresh_bindings!(windowed_override_scene).applications_by_id[:aggregated_probe]
        @test meteo_bindings(windowed_override_application.spec).CO2.source == :Cb
        @test meteo_bindings(windowed_override_application.spec).CO2.reducer isa MeanReducer
        windowed_override_sim = run!(windowed_override_scene; steps=4, outputs=:all)
        temperature_values = getproperty.(
            collect_outputs(
                windowed_override_sim,
                :leaf_1,
                :temperature_seen;
                sink=nothing,
            ),
            :value,
        )
        co2_values = getproperty.(
            collect_outputs(
                windowed_override_sim,
                :leaf_1,
                :co2_seen;
                sink=nothing,
            ),
            :value,
        )
        @test temperature_values == [10.0, 30.0]
        @test co2_values == [410.0, 425.0]
    end

    contract_backend = ModelObjectGridBackend()
    contract_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
        );
        applications=(
            ModelSpec(ModelObjectEnvironmentProbeModel(); name=:probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
        environment=contract_backend,
    )
    contract_compiled = Advanced.refresh_bindings!(contract_scene)
    original_contract_bindings =
        Advanced.refresh_environment_bindings!(contract_scene, contract_compiled)
    original_contract_binding =
        original_contract_bindings.by_target[(:probe, ObjectId(:leaf_1))]
    @test original_contract_binding.required_inputs == [:T, :CO2]
    @test length(contract_backend.binds) == 1
    @test length(contract_backend.index_updates) == 1

    revised_contract_compiled = Advanced.compile_composite_model(
        contract_scene,
        (
            ModelSpec(ModelObjectTemperatureOnlyProbeModel(); name=:probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
    )
    revised_contract_bindings =
        Advanced.refresh_environment_bindings!(contract_scene, revised_contract_compiled)
    revised_contract_binding =
        revised_contract_bindings.by_target[(:probe, ObjectId(:leaf_1))]
    @test revised_contract_binding.required_inputs == [:T]
    @test revised_contract_binding.cell == original_contract_binding.cell
    @test revised_contract_binding !== original_contract_binding
    @test length(contract_backend.binds) == 1
    @test length(contract_backend.index_updates) == 1
    @test Advanced.refresh_environment_bindings!(
        contract_scene,
        revised_contract_compiled,
    ) === revised_contract_bindings

    structural_environment_cache = Advanced.refresh_bindings!(environment_scene)
    move_object!(environment_scene, :leaf_2, (cell=:cell_c,))
    @test !Advanced.bindings_dirty(environment_scene)
    @test Advanced.environment_bindings_dirty(environment_scene)
    @test Advanced.refresh_bindings!(environment_scene) === structural_environment_cache
    refreshed_environment = Advanced.refresh_environment_bindings!(environment_scene)
    @test !Advanced.environment_bindings_dirty(environment_scene)
    @test length(grid_backend.binds) == 6
    @test length(grid_backend.index_updates) == 2
    @test any(entity -> entity.id == :leaf_2 && entity.geometry == (cell=:cell_c,), grid_backend.index_updates[2])
    @test only(row for row in explain_environment_bindings(refreshed_environment) if row.application_id == :probe && row.object_id == :leaf_2).cell == :cell_c

    update_geometry!(environment_scene, :leaf_1, (cell=:cell_e,); invalidate_environment=false)
    @test geometry(only(object for object in model_objects(environment_scene; scale=:Leaf) if object.id == ObjectId(:leaf_1))) == (cell=:cell_e,)
    @test !Advanced.environment_bindings_dirty(environment_scene)
    mark_environment_binding_dirty!(environment_scene, :leaf_1)
    @test Advanced.environment_bindings_dirty(environment_scene)
    refreshed_after_mark = Advanced.refresh_environment_bindings!(environment_scene)
    @test !Advanced.environment_bindings_dirty(environment_scene)
    @test length(grid_backend.binds) == 8
    @test length(grid_backend.index_updates) == 3
    @test any(entity -> entity.id == :leaf_1 && entity.geometry == (cell=:cell_e,), grid_backend.index_updates[3])
    @test only(row for row in explain_environment_bindings(refreshed_after_mark) if row.application_id == :probe && row.object_id == :leaf_1).cell == :cell_e

    register_object!(environment_scene, Object(:leaf_3; scale=:Leaf, kind=:plant, species=:oil_palm, geometry=(cell=:cell_d,)); parent=:plant_1)
    @test Advanced.bindings_dirty(environment_scene)
    @test Advanced.environment_bindings_dirty(environment_scene)
    refreshed_with_new_leaf = Advanced.refresh_environment_bindings!(environment_scene)
    @test length(grid_backend.binds) == 14
    @test length(grid_backend.index_updates) == 4
    @test any(entity -> entity.id == :leaf_3 && entity.geometry == (cell=:cell_d,), grid_backend.index_updates[4])
    @test only(row for row in explain_applications(Advanced.refresh_bindings!(environment_scene)) if row.application_id == :probe).target_ids ==
          [:leaf_1, :leaf_2, :leaf_3]
    @test only(row for row in explain_environment_bindings(refreshed_with_new_leaf) if row.application_id == :probe && row.object_id == :leaf_3).cell == :cell_d

    inherited_grid_backend = ModelObjectGridBackend()
    inherited_environment_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :plant_1;
            scale=:Plant,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
        ),
        Object(:inherited_leaf; scale=:Leaf, kind=:plant, parent=:plant_1),
        Object(
            :positioned_leaf;
            scale=:Leaf,
            kind=:plant,
            parent=:plant_1,
            geometry=(cell=:cell_c,),
        );
        applications=(
            ModelSpec(ModelObjectEnvironmentProbeModel(); name=:inherited_probe) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
        environment=inherited_grid_backend,
    )
    inherited_bindings = Advanced.refresh_environment_bindings!(inherited_environment_scene)
    inherited_rows = explain_environment_bindings(inherited_bindings)
    inherited_row = only(row for row in inherited_rows if row.object_id == :inherited_leaf)
    positioned_row = only(row for row in inherited_rows if row.object_id == :positioned_leaf)
    @test inherited_row.cell == :cell_a
    @test inherited_row.geometry_source == :ancestor
    @test inherited_row.geometry_source_object_id == :plant_1
    @test positioned_row.cell == :cell_c
    @test positioned_row.geometry_source == :self
    positioned_binding = inherited_bindings.by_target[
        (:inherited_probe, ObjectId(:positioned_leaf))
    ]

    update_geometry!(inherited_environment_scene, :plant_1, (cell=:cell_b,))
    @test Advanced.environment_bindings_dirty(inherited_environment_scene)
    refreshed_inherited_bindings =
        Advanced.refresh_environment_bindings!(inherited_environment_scene)
    refreshed_inherited_rows = explain_environment_bindings(refreshed_inherited_bindings)
    @test only(
        row for row in refreshed_inherited_rows if row.object_id == :inherited_leaf
    ).cell == :cell_b
    @test refreshed_inherited_bindings.by_target[
        (:inherited_probe, ObjectId(:positioned_leaf))
    ] === positioned_binding

    mutable_environment_backend = ModelObjectMutableEnvironmentBackend(:cell_a => 20.0, :cell_b => 30.0)
    mutable_environment_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, geometry=(cell=:cell_a,), status=Status(T=0.0, temperature_update=0.0, temperature_seen=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:scene, geometry=(cell=:cell_b,), status=Status(T=0.0, temperature_update=0.0, temperature_seen=0.0));
        applications=(
            ModelSpec(ModelObjectEnvironmentUpdateModel(); name=:temperature_update_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(ModelObjectEnvironmentProbeModel(); name=:probe_after_update) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
        environment=mutable_environment_backend,
    )
    run!(mutable_environment_scene)
    @test mutable_environment_backend.values == Dict(:cell_a => 21.0, :cell_b => 31.0)
    @test mutable_environment_backend.writes == [
        (application=:temperature_update_runtime, process=:model_object_environment_update, cell=:cell_a, meteo=(T=21.0, CO2=410.0), time=1),
        (application=:temperature_update_runtime, process=:model_object_environment_update, cell=:cell_b, meteo=(T=31.0, CO2=410.0), time=1),
    ]
    mutable_environment_statuses = Dict(object.id.value => object.status for object in model_objects(mutable_environment_scene; scale=:Leaf))
    @test mutable_environment_statuses[:leaf_1].temperature_seen == 21.0
    @test mutable_environment_statuses[:leaf_2].temperature_seen == 31.0

    trial_update_backend = ModelObjectMutableEnvironmentBackend(:cell_a => 20.0)
    trial_update_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
            status=Status(temperature_update=0.0, called_temperature=0.0),
        );
        applications=(
            ModelSpec(ModelObjectEnvironmentUpdateModel(); name=:temperature_update_runtime) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(ModelObjectEnvironmentUpdateCallerModel(); name=:temperature_update_caller) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid) |>
            Calls(:updater => One(scale=:Leaf, process=:model_object_environment_update)),
        ),
        environment=trial_update_backend,
    )
    run!(trial_update_scene)
    trial_update_status = only(model_objects(trial_update_scene; scale=:Leaf)).status
    @test trial_update_status.temperature_update == 21.0
    @test trial_update_status.called_temperature == 21.0
    @test trial_update_backend.values[:cell_a] == 20.0
    @test isempty(trial_update_backend.writes)

    runtime_model = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant_1; scale=:Plant, kind=:plant, parent=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=1.5, leaf_areas=[0.0], leaf_tokens=Any[], carrier_total=0.0, temperature_seen=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(leaf_area=2.5, leaf_areas=[0.0], leaf_tokens=Any[], carrier_total=0.0, temperature_seen=0.0));
        applications=(
            ModelSpec(ModelObjectCarrierConsumerModel(); name=:carrier_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Inputs(:leaf_areas => Many(scale=:Leaf, within=SelfPlant(), var=:leaf_area)),
            ModelSpec(ModelObjectEnvironmentProbeModel(); name=:probe_runtime) |>
            AppliesTo(Many(scale=:Leaf)) |>
            Environment(provider=:global),
        ),
        environment=(T=27.5, CO2=410.0),
    )
    run!(runtime_model)
    @test all(object.status.carrier_total == 4.0 for object in model_objects(runtime_model; scale=:Leaf))
    @test all(object.status.temperature_seen == 27.5 for object in model_objects(runtime_model; scale=:Leaf))
    runtime_compiled = Advanced.refresh_bindings!(runtime_model)
    runtime_application = runtime_compiled.applications_by_id[:carrier_runtime]
    runtime_object_id = ObjectId(:leaf_1)
    PlantSimEngine._materialize_model_inputs!(
        runtime_compiled,
        runtime_application,
        runtime_object_id,
        nothing,
        1,
    )
    runtime_status = PlantSimEngine._model_object_status(runtime_model, runtime_object_id)
    runtime_bindings = runtime_compiled.input_bindings_by_target[
        (:carrier_runtime, runtime_object_id)
    ]
    runtime_binding = only(runtime_bindings)
    @test runtime_status.leaf_areas === input_carrier(runtime_binding)
    runtime_leaf_2 = only(
        object for object in model_objects(runtime_model; scale=:Leaf)
        if object.id == ObjectId(:leaf_2)
    )
    runtime_leaf_2.status.leaf_area = 7.0
    @test runtime_status.leaf_areas[2] == 7.0
    @test @allocated(
        PlantSimEngine._materialize_model_inputs!(
            runtime_compiled,
            runtime_application,
            runtime_object_id,
            nothing,
            1,
        )
    ) == 0

    call_runtime_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, called_signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    run!(call_runtime_scene)
    call_status = only(model_objects(call_runtime_scene; scale=:Leaf)).status
    @test call_status.signal == 1.0
    @test call_status.called_signal == 1.0
    call_schedule = explain_schedule(Advanced.refresh_bindings!(call_runtime_scene))
    @test only(row for row in call_schedule if row.application_id == :signal_source).manual_call_only
    @test !only(row for row in call_schedule if row.application_id == :signal_source).root_scheduled
    @test only(row for row in call_schedule if row.application_id == :signal_caller).root_scheduled

    hard_call_meteo_backend = ModelObjectMutableEnvironmentBackend(:cell_a => 20.0)
    hard_call_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
            status=Status(T=0.0, temperature_seen=0.0, called_temperature=0.0),
        );
        applications=(
            ModelSpec(ModelObjectMeteoCallSourceModel(); name=:meteo_source) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(ModelObjectMeteoCallControllerModel(31.5, false); name=:meteo_controller) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid) |>
            Calls(:source => One(scale=:Leaf, process=:model_object_meteo_call_source)),
        ),
        environment=hard_call_meteo_backend,
    )
    run!(hard_call_meteo_scene)
    hard_call_meteo_status = only(model_objects(hard_call_meteo_scene; scale=:Leaf)).status
    @test hard_call_meteo_status.temperature_seen == 31.5
    @test hard_call_meteo_status.called_temperature == 31.5
    @test hard_call_meteo_backend.values[:cell_a] == 20.0
    @test isempty(hard_call_meteo_backend.writes)

    publish_hard_call_meteo_backend = ModelObjectMutableEnvironmentBackend(:cell_a => 20.0)
    publish_hard_call_meteo_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
            status=Status(T=0.0, temperature_seen=0.0, called_temperature=0.0),
        );
        applications=(
            ModelSpec(ModelObjectMeteoCallSourceModel(); name=:meteo_source) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(ModelObjectMeteoCallControllerModel(32.5, true); name=:meteo_controller) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid) |>
            Calls(:source => One(scale=:Leaf, process=:model_object_meteo_call_source)),
        ),
        environment=publish_hard_call_meteo_backend,
    )
    run!(publish_hard_call_meteo_scene)
    publish_hard_call_meteo_status = only(model_objects(publish_hard_call_meteo_scene; scale=:Leaf)).status
    @test publish_hard_call_meteo_status.temperature_seen == 32.5
    @test publish_hard_call_meteo_status.called_temperature == 32.5
    @test publish_hard_call_meteo_backend.values[:cell_a] == 32.5
    @test publish_hard_call_meteo_backend.writes == [
        (application=:meteo_controller, process=:model_object_meteo_call_controller, cell=:cell_a, meteo=(T=32.5, CO2=410.0), time=1),
    ]

    iterative_hard_call_backend = ModelObjectMutableEnvironmentBackend(:cell_a => 20.0)
    iterative_hard_call_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
            status=Status(T=0.0, temperature_seen=0.0, called_temperature=0.0),
        );
        applications=(
            ModelSpec(ModelObjectMeteoCallSourceModel(); name=:meteo_source) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
            ModelSpec(
            ModelObjectIterativeMeteoCallControllerModel((30.0, 31.0), 32.0);
                name=:meteo_controller,
            ) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid) |>
            Calls(:source => One(scale=:Leaf, process=:model_object_meteo_call_source)),
        ),
        environment=iterative_hard_call_backend,
    )
    iterative_hard_call_sim = run!(iterative_hard_call_scene; outputs=:all)
    iterative_hard_call_status =
        only(model_objects(iterative_hard_call_scene; scale=:Leaf)).status
    @test iterative_hard_call_status.temperature_seen == 32.0
    @test iterative_hard_call_status.called_temperature == 32.0
    @test iterative_hard_call_backend.values[:cell_a] == 32.0
    @test iterative_hard_call_backend.writes == [
        (
            application=:meteo_controller,
            process=:model_object_iterative_meteo_call_controller,
            cell=:cell_a,
            meteo=(T=32.0, CO2=410.0),
            time=1,
        ),
    ]
    accepted_call_samples = outputs(iterative_hard_call_sim)[
        (:meteo_source, ObjectId(:leaf_1), :temperature_seen)
    ]
    @test length(accepted_call_samples) == 1
    @test only(accepted_call_samples) == (1.0, 32.0)

    hard_call_order_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, called_signal=0.0, observed_signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalCallerModel(); name=:signal_caller) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    hard_call_order = Advanced.refresh_bindings!(hard_call_order_scene)
    @test hard_call_order.applications_by_id[:signal_caller].process == :model_object_signal_caller
    @test hard_call_order.application_order == [:signal_source, :signal_caller, :signal_consumer]
    run!(hard_call_order_scene)
    hard_call_order_status = only(model_objects(hard_call_order_scene; scale=:Leaf)).status
    @test hard_call_order_status.signal == 1.0
    @test hard_call_order_status.observed_signal == 1.0

    temporal_input_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:scene_temporal_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal, policy=Integrate(), window=Hour(2))) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    temporal_binding = only(
        row for row in explain_bindings(Advanced.refresh_bindings!(temporal_input_scene))
        if row.application_id == :scene_temporal_sum && row.input == :signal_sum
    )
    @test temporal_binding.carrier_hint == :temporal_stream
    temporal_input_simulation = run!(temporal_input_scene; steps=3, outputs=:all)
    @test temporal_input_simulation isa Simulation
    @test temporal_input_simulation.model === temporal_input_scene
    @test temporal_input_simulation.compiled isa Advanced.CompiledCompositeModel
    @test only(model_objects(temporal_input_scene; scale=:Leaf)).status.signal == 3.0
    @test only(model_objects(temporal_input_scene; scale=:Scene)).status.temporal_total == 5.0
    temporal_output_rows = collect_outputs(temporal_input_simulation; sink=nothing)
    @test length(temporal_output_rows) == 5
    @test size(collect_outputs(temporal_input_simulation), 1) == 5
    @test count(row -> row.object_id == :leaf_1 && row.variable == :signal, temporal_output_rows) == 3
    @test count(row -> row.object_id == :scene && row.variable == :temporal_total, temporal_output_rows) == 2
    @test collect_outputs(temporal_input_simulation, :leaf_1, :signal; sink=nothing)[end].value == 3.0
    temporal_output_summary = explain_outputs(temporal_input_simulation)
    @test only(row for row in temporal_output_summary if row.object_id == :leaf_1 && row.variable == :signal).nsamples == 3
    @test only(row for row in temporal_output_summary if row.object_id == :scene && row.variable == :temporal_total).application_id == :scene_temporal_sum

    tracked_output_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_observer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    tracked_output_request = OutputRequest(
        :Leaf,
        :signal;
        name=:signal_two_hour,
        process=:model_object_signal_source,
        policy=Integrate(),
        clock=Hour(2),
    )
    tracked_output_simulation = run!(
        tracked_output_scene;
        steps=3,
        outputs=tracked_output_request,
    )
    tracked_output_rows = collect_outputs(
        tracked_output_simulation,
        :signal_two_hour;
        sink=nothing,
    )
    @test getproperty.(tracked_output_rows, :value) == [1.0, 5.0]
    @test getproperty.(tracked_output_rows, :time) == [1.0, 3.0]
    @test all(row -> row.object_id == :leaf_1, tracked_output_rows)
    @test all(row -> row.application_id == :hourly_signal, tracked_output_rows)
    @test Set(keys(outputs(tracked_output_simulation))) == Set([
        (:hourly_signal, ObjectId(:leaf_1), :signal),
    ])
    @test explain_output_retention(tracked_output_simulation) == [
        (
            application_id=:hourly_signal,
            variable=:signal,
            reasons=(:output_request,),
            retention_steps=nothing,
            current_target_count=1,
        ),
    ]
    @test collect_outputs(tracked_output_simulation; sink=nothing)[:signal_two_hour] ==
          tracked_output_rows
    tracked_output_frames = collect_outputs(tracked_output_simulation)
    @test sort(collect(keys(tracked_output_frames))) == [:signal_two_hour]
    @test tracked_output_frames[:signal_two_hour][!, :value] == [1.0, 5.0]
    @test tracked_output_frames[:signal_two_hour][!, :application_id] ==
          [:hourly_signal, :hourly_signal]
    @test_throws "No model output request named `missing_request`" collect_outputs(
        tracked_output_simulation,
        :missing_request;
        sink=nothing,
    )

    auto_tracked_output_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    auto_tracked_output_simulation = run!(
        auto_tracked_output_scene;
        steps=3,
        outputs=OutputRequest(:Leaf, :signal; name=:signal_auto),
    )
    auto_tracked_rows = collect_outputs(
        auto_tracked_output_simulation,
        :signal_auto;
        sink=nothing,
    )
    @test getproperty.(auto_tracked_rows, :value) == [1.0, 2.0, 3.0]
    @test all(row -> row.application_id == :hourly_signal, auto_tracked_rows)

    empty_retention_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_observer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    empty_retention_simulation = run!(
        empty_retention_scene;
        outputs=:none,
    )
    @test isempty(outputs(empty_retention_simulation))
    @test isempty(explain_output_retention(empty_retention_simulation))
    @test only(model_objects(empty_retention_scene; scale=:Leaf)).status.observed_signal ==
          1.0

    selective_temporal_scene = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            status=Status(signal_sum=0.0, temporal_total=0.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:scene_temporal_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :signal_sum => One(
                    scale=:Leaf,
                    var=:signal,
                    policy=Integrate(),
                    window=Hour(2),
                ),
            ) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    selective_temporal_request = OutputRequest(
        :Scene,
        :temporal_total;
        name=:temporal_total_two_hour,
        process=:model_object_temporal_sum,
        policy=HoldLast(),
        clock=Hour(2),
    )
    selective_temporal_simulation = run!(
        selective_temporal_scene;
        steps=3,
        outputs=selective_temporal_request,
    )
    @test Set(keys(outputs(selective_temporal_simulation))) == Set([
        (:hourly_signal, ObjectId(:leaf_1), :signal),
        (:scene_temporal_sum, ObjectId(:scene), :temporal_total),
    ])
    selective_retention_rows = explain_output_retention(
        selective_temporal_simulation,
    )
    @test only(
        row for row in selective_retention_rows
        if row.application_id == :hourly_signal
    ).reasons == (:temporal_dependency,)
    @test only(
        row for row in selective_retention_rows
        if row.application_id == :hourly_signal
    ).retention_steps == 2.0
    @test only(
        row for row in selective_retention_rows
        if row.application_id == :scene_temporal_sum
    ).reasons == (:output_request,)
    @test isnothing(
        only(
            row for row in selective_retention_rows
            if row.application_id == :scene_temporal_sum
        ).retention_steps,
    )
    @test getproperty.(
        collect_outputs(
            selective_temporal_simulation,
            :temporal_total_two_hour;
            sink=nothing,
        ),
        :value,
    ) == [1.0, 5.0]

    bounded_temporal_scene = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            status=Status(signal_sum=0.0, temporal_total=0.0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:scene_temporal_sum) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :signal_sum => One(
                    scale=:Leaf,
                    var=:signal,
                    policy=Integrate(),
                    window=Hour(2),
                ),
            ) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    bounded_temporal_request = OutputRequest(
        :Scene,
        :temporal_total;
        name=:bounded_temporal_total,
        application=:scene_temporal_sum,
        policy=HoldLast(),
        clock=Hour(2),
    )
    bounded_temporal_simulation = run!(
        bounded_temporal_scene;
        steps=19,
        outputs=bounded_temporal_request,
    )
    bounded_source_samples = outputs(bounded_temporal_simulation)[
        (:hourly_signal, ObjectId(:leaf_1), :signal)
    ]
    @test length(bounded_source_samples) == 2
    @test getindex.(bounded_source_samples, 1) == [18.0, 19.0]
    @test getindex.(bounded_source_samples, 2) == [18.0, 19.0]
    @test only(model_objects(bounded_temporal_scene; scale=:Scene)).status.temporal_total ==
          37.0
    @test length(
        collect_outputs(
            bounded_temporal_simulation,
            :bounded_temporal_total;
            sink=nothing,
        ),
    ) == 10

    temporal_holdlast_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:scene_temporal_latest) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal, policy=HoldLast(), window=Hour(2))) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    temporal_holdlast_simulation = run!(
        temporal_holdlast_scene;
        steps=9,
        outputs=OutputRequest(
            :Scene,
            :temporal_total;
            name=:holdlast_total,
            application=:scene_temporal_latest,
        ),
    )
    @test only(model_objects(temporal_holdlast_scene; scale=:Scene)).status.temporal_total == 9.0
    @test length(
        outputs(temporal_holdlast_simulation)[
            (:hourly_signal, ObjectId(:leaf_1), :signal)
        ],
    ) == 1

    trait_policy_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectTraitPolicySignalModel(); name=:trait_policy_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:trait_policy_consumer) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal)) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    trait_policy_binding = only(
        row for row in explain_bindings(Advanced.refresh_bindings!(trait_policy_scene))
        if row.application_id == :trait_policy_consumer && row.input == :signal_sum
    )
    @test trait_policy_binding.policy isa Aggregate
    @test trait_policy_binding.carrier_hint == :temporal_stream
    trait_policy_simulation = run!(trait_policy_scene; steps=3, outputs=:all)
    @test only(model_objects(trait_policy_scene; scale=:Scene)).status.temporal_total == 2.5
    @test getproperty.(
        collect_outputs(
            trait_policy_simulation,
            :scene,
            :temporal_total;
            sink=nothing,
        ),
        :value,
    ) == [1.0, 2.5]

    explicit_policy_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene, status=Status(signal_sum=0.0, temporal_total=0.0)),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectTraitPolicySignalModel(); name=:trait_policy_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:explicit_policy_consumer) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(:signal_sum => One(scale=:Leaf, var=:signal, policy=Integrate())) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    explicit_policy_binding = only(
        row for row in explain_bindings(Advanced.refresh_bindings!(explicit_policy_scene))
        if row.application_id == :explicit_policy_consumer && row.input == :signal_sum
    )
    @test explicit_policy_binding.policy isa Integrate
    run!(explicit_policy_scene; steps=3)
    @test only(model_objects(explicit_policy_scene; scale=:Scene)).status.temporal_total == 5.0

    generic_integrate_scene = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            status=Status(signal_sum=big"0.0", temporal_total=big"0.0"),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=big"0.0"),
        );
        applications=(
            ModelSpec(ModelObjectTimeSignalModel(big"0.0"); name=:big_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
            ModelSpec(ModelObjectTemporalSumModel(); name=:big_integral) |>
            AppliesTo(One(scale=:Scene)) |>
            Inputs(
                :signal_sum => One(
                    scale=:Leaf,
                    process=:model_object_signal_source,
                    var=:signal,
                    policy=Integrate(),
                    window=Hour(2),
                ),
            ) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    generic_integrate_simulation = run!(generic_integrate_scene; steps=3, outputs=:all)
    generic_integrate_values = getproperty.(
        collect_outputs(
            generic_integrate_simulation,
            :scene,
            :temporal_total;
            sink=nothing,
        ),
        :value,
    )
    @test generic_integrate_values == BigFloat[1, 5]
    @test all(value -> value isa BigFloat, generic_integrate_values)

    interpolation_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=big"0.0", observed_signal=big"0.0"),
        );
        applications=(
            ModelSpec(ModelObjectTimeSignalModel(big"0.0"); name=:slow_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(2)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:fast_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :signal => One(
                    scale=:Leaf,
                    process=:model_object_signal_source,
                    var=:signal,
                    policy=Interpolate(),
                ),
            ) |>
            TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    interpolation_simulation = run!(
        interpolation_scene;
        steps=5,
        outputs=OutputRequest(
            :Leaf,
            :observed_signal;
            name=:interpolated_signal,
            application=:fast_consumer,
        ),
    )
    interpolation_stream = outputs(interpolation_simulation)[
        (:slow_signal, ObjectId(:leaf_1), :signal)
    ]
    @test eltype(interpolation_stream) == Tuple{Float64,BigFloat}
    @test getindex.(interpolation_stream, 1) == [3.0, 5.0]
    interpolated_values = getproperty.(
        collect_outputs(
            interpolation_simulation,
            :leaf_1,
            :observed_signal;
            sink=nothing,
        ),
        :value,
    )
    @test interpolated_values == BigFloat[1, 1, 3, 4, 5]
    @test all(value -> value isa BigFloat, interpolated_values)

    interpolation_hold_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectTimeSignalModel(0.0); name=:slow_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(2)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:fast_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :signal => One(
                    scale=:Leaf,
                    process=:model_object_signal_source,
                    var=:signal,
                    policy=Interpolate(; mode=:hold, extrapolation=:hold),
                ),
            ) |>
            TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    interpolation_hold_simulation = run!(interpolation_hold_scene; steps=6, outputs=:all)
    @test getproperty.(
        collect_outputs(
            interpolation_hold_simulation,
            :leaf_1,
            :observed_signal;
            sink=nothing,
        ),
        :value,
    ) == [1.0, 1.0, 3.0, 3.0, 5.0, 5.0]

    invalid_interpolation_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            status=Status(signal=0.0, observed_signal=0.0),
        );
        applications=(
            ModelSpec(ModelObjectTimeSignalModel(0.0); name=:signal_source) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(
                :signal => One(
                    scale=:Leaf,
                    process=:model_object_signal_source,
                    var=:signal,
                    policy=Interpolate(:spline),
                ),
            ),
        ),
    )
    @test_throws "Invalid interpolation mode `spline`" Advanced.refresh_bindings!(invalid_interpolation_scene)

    stream_only_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0, observed_signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSetModel(10.0); name=:stream_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            OutputRouting(; signal=:stream_only),
            ModelSpec(ModelObjectSignalSetModel(1.0); name=:canonical_signal) |>
            AppliesTo(One(scale=:Leaf)),
            ModelSpec(ModelObjectSignalConsumerModel(); name=:signal_consumer) |>
            AppliesTo(One(scale=:Leaf)),
        ),
    )
    stream_only_compiled = Advanced.refresh_bindings!(stream_only_scene)
    stream_only_writer = only(row for row in explain_writers(stream_only_compiled) if row.variable == :signal)
    @test stream_only_writer.application_ids == [:canonical_signal]
    stream_only_binding = only(row for row in explain_bindings(stream_only_compiled) if row.application_id == :signal_consumer)
    @test stream_only_binding.source_application_ids == [:canonical_signal]
    stream_only_simulation = run!(stream_only_scene; outputs=:all)
    stream_only_status = only(model_objects(stream_only_scene; scale=:Leaf)).status
    @test stream_only_status.observed_signal == 1.0
    signal_rows = collect_outputs(stream_only_simulation, :leaf_1, :signal; sink=nothing)
    @test Dict(row.application_id => row.value for row in signal_rows) ==
          Dict(:stream_signal => 10.0, :canonical_signal => 1.0)
    @test Set(row.application_id for row in explain_outputs(stream_only_simulation) if row.variable == :signal) ==
          Set([:stream_signal, :canonical_signal])
    stream_only_only_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSetModel(10.0); name=:stream_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            OutputRouting(; signal=:stream_only),
        ),
    )
    @test_throws "No model output publisher found" run!(
        stream_only_only_scene;
        outputs=OutputRequest(:Leaf, :signal; name=:stream_signal_auto_fail),
    )
    stream_only_requested = run!(
        stream_only_scene;
        outputs=OutputRequest(:Leaf, :signal; name=:canonical_signal_request),
    )
    stream_only_requested_rows = collect_outputs(
        stream_only_requested,
        :canonical_signal_request;
        sink=nothing,
    )
    @test getproperty.(stream_only_requested_rows, :application_id) == [:canonical_signal]
    @test getproperty.(stream_only_requested_rows, :value) == [1.0]
    explicit_stream_application = run!(
        stream_only_scene;
        outputs=OutputRequest(
            :Leaf,
            :signal;
            name=:stream_signal_by_application,
            application=:stream_signal,
        ),
    )
    explicit_stream_rows = collect_outputs(
        explicit_stream_application,
        :stream_signal_by_application;
        sink=nothing,
    )
    @test getproperty.(explicit_stream_rows, :application_id) == [:stream_signal]
    @test getproperty.(explicit_stream_rows, :value) == [10.0]
    explicit_canonical_application = run!(
        stream_only_scene;
        outputs=OutputRequest(
            :Leaf,
            :signal;
            name=:canonical_signal_by_application,
            application=:canonical_signal,
        ),
    )
    explicit_canonical_rows = collect_outputs(
        explicit_canonical_application,
        :canonical_signal_by_application;
        sink=nothing,
    )
    @test getproperty.(explicit_canonical_rows, :application_id) ==
          [:canonical_signal]
    @test getproperty.(explicit_canonical_rows, :value) == [1.0]
    @test_throws "application `missing_signal`" run!(
        stream_only_scene;
        outputs=OutputRequest(
            :Leaf,
            :signal;
            name=:missing_signal_application,
            application=:missing_signal,
        ),
    )
    @test_throws "Ambiguous model output publishers" run!(
        stream_only_scene;
        outputs=OutputRequest(
            :Leaf,
            :signal;
            name=:ambiguous_signal_request,
            process=:model_object_signal_source,
        ),
    )

    writer_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(biomass=-1.0)),
    )
    biomass_source =
        ModelSpec(ModelObjectBiomassSourceModel(); name=:carbon_allocation) |>
        AppliesTo(One(scale=:Leaf))
    biomass_pruner =
        ModelSpec(ModelObjectBiomassPrunerModel(); name=:leaf_pruning) |>
        AppliesTo(One(scale=:Leaf))

    @test_throws ErrorException Advanced.compile_composite_model(writer_scene, (biomass_source, biomass_pruner))
    @test_throws ErrorException Advanced.compile_composite_model(
        writer_scene,
        (biomass_source, biomass_pruner |> Updates(:biomass; after=:water_status)),
    )
    @test_throws ErrorException Advanced.compile_composite_model(
        writer_scene,
        (biomass_pruner |> Updates(:biomass; after=:carbon_allocation), biomass_source),
    )

    ordered_pruner = biomass_pruner |> Updates(:biomass; after=:carbon_allocation)
    writer_compiled = Advanced.compile_composite_model(writer_scene, (biomass_source, ordered_pruner))
    writer_row = only(row for row in explain_writers(writer_compiled) if row.variable == :biomass)
    @test writer_row.object_id == :leaf_1
    @test writer_row.duplicate
    @test writer_row.application_ids == [:carbon_allocation, :leaf_pruning]
    @test writer_row.update_application_ids == [:leaf_pruning]
    @test writer_row.update_after == [:leaf_pruning => [:carbon_allocation]]

    writer_runtime_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(biomass=-1.0));
        applications=(biomass_source, ordered_pruner),
    )
    run!(writer_runtime_scene)
    @test only(model_objects(writer_runtime_scene; scale=:Leaf)).status.biomass == 0.0

    lifecycle_scene = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            status=Status(created_count=0, removed_count=0),
        ),
        Object(
            :plant_1;
            scale=:Plant,
            kind=:plant,
            parent=:scene,
            status=Status(signals=[0.0], signal_total=0.0),
        ),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(signal=0.0)),
        Object(:leaf_2; scale=:Leaf, kind=:plant, parent=:plant_1, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectGrowthModel(); name=:growth) |>
            AppliesTo(One(scale=:Scene)),
            ModelSpec(ModelObjectSignalSourceModel(); name=:leaf_signal) |>
            AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ModelObjectPlantSignalSumModel(); name=:plant_signal_total) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(:signals => Many(scale=:Leaf, within=Subtree(), var=:signal)),
            ModelSpec(ModelObjectPruningModel(); name=:pruning) |>
            AppliesTo(One(scale=:Scene)),
        ),
        environment=(duration=Hour(1),),
    )
    lifecycle_output_request = OutputRequest(
        :Leaf,
        :signal;
        name=:leaf_signal_hourly,
        process=:model_object_signal_source,
        policy=HoldLast(),
        clock=Hour(1),
    )
    lifecycle_simulation = run!(
        lifecycle_scene;
        steps=3,
        outputs=lifecycle_output_request,
    )
    @test !Advanced.bindings_dirty(lifecycle_scene)
    @test !Advanced.environment_bindings_dirty(lifecycle_scene)
    @test lifecycle_simulation.compiled.revision == Advanced.model_revision(lifecycle_scene)
    @test Set(object_ids(lifecycle_scene; scale=:Leaf)) ==
          Set([ObjectId(:leaf_1), ObjectId(:grown_leaf)])
    lifecycle_status = only(model_objects(lifecycle_scene; scale=:Scene)).status
    @test lifecycle_status.created_count == 1
    @test lifecycle_status.removed_count == 1
    lifecycle_leaf_statuses = Dict(object.id.value => object.status for object in model_objects(lifecycle_scene; scale=:Leaf))
    @test lifecycle_leaf_statuses[:leaf_1].signal == 3.0
    @test lifecycle_leaf_statuses[:grown_leaf].signal == 2.0
    @test only(model_objects(lifecycle_scene; scale=:Plant)).status.signal_total == 5.0
    lifecycle_application = lifecycle_simulation.compiled.applications_by_id[:leaf_signal]
    @test lifecycle_application.target_ids == [ObjectId(:grown_leaf), ObjectId(:leaf_1)]
    lifecycle_execution_row = only(
        row for row in explain_execution_plan(lifecycle_simulation)
        if row.application_id == :leaf_signal
    )
    @test lifecycle_execution_row.object_ids == [:grown_leaf, :leaf_1]
    @test lifecycle_simulation.execution_plan.model_revision ==
          Advanced.model_revision(lifecycle_scene)
    @test haskey(
        lifecycle_simulation.compiled.model_bundles_by_target,
        (:leaf_signal, ObjectId(:grown_leaf)),
    )
    lifecycle_binding = only(
        row for row in explain_bindings(lifecycle_simulation.compiled)
        if row.application_id == :plant_signal_total
    )
    @test lifecycle_binding.source_ids == [:grown_leaf, :leaf_1]
    @test all(
        first(key) == :leaf_signal && last(key) == :signal
        for key in keys(outputs(lifecycle_simulation))
    )
    @test only(explain_output_retention(lifecycle_simulation)) == (
        application_id=:leaf_signal,
        variable=:signal,
        reasons=(:output_request,),
        retention_steps=nothing,
        current_target_count=2,
    )
    @test length(collect_outputs(lifecycle_simulation, :leaf_1, :signal; sink=nothing)) == 3
    @test length(collect_outputs(lifecycle_simulation, :grown_leaf, :signal; sink=nothing)) == 2
    @test length(collect_outputs(lifecycle_simulation, :leaf_2, :signal; sink=nothing)) == 2
    lifecycle_requested_rows = collect_outputs(
        lifecycle_simulation,
        :leaf_signal_hourly;
        sink=nothing,
    )
    @test count(row -> row.object_id == :leaf_1, lifecycle_requested_rows) == 3
    @test count(row -> row.object_id == :grown_leaf, lifecycle_requested_rows) == 2
    @test count(row -> row.object_id == :leaf_2, lifecycle_requested_rows) == 2

    moving_environment_backend = ModelObjectMutableEnvironmentBackend(
        :cell_a => 20.0,
        :cell_b => 30.0,
    )
    moving_environment_scene = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            geometry=(cell=:cell_a,),
            status=Status(move_count=0),
        ),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:plant,
            parent=:scene,
            geometry=(cell=:cell_a,),
            status=Status(temperature_seen=0.0),
        );
        applications=(
            ModelSpec(ModelObjectGeometryMoverModel(); name=:geometry_mover) |>
            AppliesTo(One(scale=:Scene)),
            ModelSpec(ModelObjectEnvironmentProbeModel(); name=:moving_probe) |>
            AppliesTo(One(scale=:Leaf)) |>
            Environment(provider=:grid),
        ),
        environment=moving_environment_backend,
    )
    moving_environment_simulation = run!(moving_environment_scene; steps=2, outputs=:all)
    @test !Advanced.bindings_dirty(moving_environment_scene)
    @test !Advanced.environment_bindings_dirty(moving_environment_scene)
    @test only(model_objects(moving_environment_scene; scale=:Scene)).status.move_count == 1
    @test only(model_objects(moving_environment_scene; scale=:Leaf)).status.temperature_seen == 30.0
    moving_probe_rows = collect_outputs(
        moving_environment_simulation,
        :leaf_1,
        :temperature_seen;
        sink=nothing,
    )
    @test getproperty.(moving_probe_rows, :value) == [20.0, 30.0]
    @test only(
        row for row in explain_environment_bindings(moving_environment_simulation.environment_bindings)
        if row.application_id == :moving_probe
    ).cell == :cell_b

    multirate_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectSignalSourceModel(); name=:hourly_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(2)),
        ),
        environment=(duration=Hour(1),),
    )
    multirate_compiled = Advanced.refresh_bindings!(multirate_scene)
    schedule_rows = explain_schedule(multirate_compiled)
    @test only(schedule_rows).application_id == :hourly_signal
    @test only(schedule_rows).dt_steps == 2.0
    @test only(schedule_rows).dt_seconds == 7200.0
    run!(multirate_scene; steps=5)
    @test only(model_objects(multirate_scene; scale=:Leaf)).status.signal == 3.0

    trait_clock_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectTraitClockSourceModel(); name=:trait_clock_signal) |>
            AppliesTo(One(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    trait_clock_compiled = Advanced.refresh_bindings!(trait_clock_scene)
    trait_clock_schedule = only(explain_schedule(trait_clock_compiled))
    @test trait_clock_schedule.application_id == :trait_clock_signal
    @test trait_clock_schedule.dt_steps == 2.0
    @test trait_clock_schedule.phase == 1.0
    run!(trait_clock_scene; steps=5)
    @test only(model_objects(trait_clock_scene; scale=:Leaf)).status.signal == 3.0

    trait_clock_override_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectTraitClockSourceModel(); name=:override_signal) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    override_schedule = only(explain_schedule(Advanced.refresh_bindings!(trait_clock_override_scene)))
    @test override_schedule.dt_steps == 1.0
    run!(trait_clock_override_scene; steps=5)
    @test only(model_objects(trait_clock_override_scene; scale=:Leaf)).status.signal == 5.0

    strict_hint_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectStrictHintSourceModel(); name=:strict_hint_signal) |>
            AppliesTo(One(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "outside `timestep_hint.required=1 day`" Advanced.refresh_bindings!(strict_hint_scene)

    strict_hint_override_scene = CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:plant, parent=:scene, status=Status(signal=0.0));
        applications=(
            ModelSpec(ModelObjectStrictHintSourceModel(); name=:strict_hint_override) |>
            AppliesTo(One(scale=:Leaf)) |>
            TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test only(explain_schedule(Advanced.refresh_bindings!(strict_hint_override_scene))).dt_steps == 1.0
    run!(strict_hint_override_scene; steps=2)
    @test only(model_objects(strict_hint_override_scene; scale=:Leaf)).status.signal == 2.0
end
