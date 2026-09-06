module LifecycleOutputExample

using Dates
using PlantSimEngine

export LeafInitializer, RegisterLeaf, DistributeLeafSignal
export lifecycle_scenario, distributed_output_scenario
export COUNT_CONTRACT, BOOLEAN_CONTRACT, DISTRIBUTED_SIGNAL_CONTRACT

PlantSimEngine.@process "pedagogical_leaf_initializer" verbose=false
PlantSimEngine.@process "pedagogical_leaf_registration" verbose=false
PlantSimEngine.@process "pedagogical_distributed_signal" verbose=false

const COUNT_CONTRACT = VariableContract(
    unit=:count,
    basis=:model_invocation,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

const BOOLEAN_CONTRACT = VariableContract(
    unit=:boolean,
    basis=:model_state,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

const DISTRIBUTED_SIGNAL_CONTRACT = VariableContract(
    unit=:arbitrary_signal_unit,
    basis=:leaf,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

struct LeafInitializer <: AbstractPedagogical_Leaf_InitializerModel end

PlantSimEngine.inputs_(::LeafInitializer) = NamedTuple()
PlantSimEngine.outputs_(::LeafInitializer) = (initializer_runs=0,)
PlantSimEngine.environment_inputs_(::LeafInitializer) = NamedTuple()
PlantSimEngine.environment_outputs_(::LeafInitializer) = NamedTuple()
PlantSimEngine.variable_contracts_(::LeafInitializer) = (
    initializer_runs=COUNT_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::LeafInitializer) = (
    hypothesis="A newly registered leaf records one explicit initializer call.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::LeafInitializer,
    status,
    environment,
    constants,
    context,
)
    status.initializer_runs += one(status.initializer_runs)
    return nothing
end

"""
Register one runtime leaf and execute its one-shot initializer.

This fixture has no MTG owner, so `register_object!` is intentional. An
MTG-backed growth model should use `add_organ!` instead.
"""
struct RegisterLeaf <: AbstractPedagogical_Leaf_RegistrationModel end

PlantSimEngine.inputs_(::RegisterLeaf) = NamedTuple()
PlantSimEngine.outputs_(::RegisterLeaf) = (
    created=false,
    initializer_runs_seen=0,
)
PlantSimEngine.environment_inputs_(::RegisterLeaf) = NamedTuple()
PlantSimEngine.environment_outputs_(::RegisterLeaf) = NamedTuple()
PlantSimEngine.variable_contracts_(::RegisterLeaf) = (
    created=BOOLEAN_CONTRACT,
    initializer_runs_seen=COUNT_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::RegisterLeaf) = (
    hypothesis="One illustrative leaf is registered once and initialized immediately.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::RegisterLeaf,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing

    leaf = register_object!(
        runtime_model(context),
        Object(
            :new_leaf;
            scale=:Leaf,
            kind=:leaf,
            parent=:scene,
        ),
    )
    initialized = run_initializer!(context, :leaf, leaf)
    status.initializer_runs_seen = initialized.initializer_runs
    status.created = true
    return nothing
end

struct DistributeLeafSignal{T} <: AbstractPedagogical_Distributed_SignalModel
    base::T
end

PlantSimEngine.inputs_(::DistributeLeafSignal) = NamedTuple()
PlantSimEngine.outputs_(::DistributeLeafSignal) = (assigned_count=0,)
PlantSimEngine.environment_inputs_(::DistributeLeafSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::DistributeLeafSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::DistributeLeafSignal) = (
    assigned_count=COUNT_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::DistributeLeafSignal) = (
    hypothesis="A scene assigns one identity-keyed illustrative signal to every leaf.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::DistributeLeafSignal) = (
    base=(
        description="Base value used to construct identity-keyed leaf signals.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::DistributeLeafSignal,
    status,
    environment,
    constants,
    context,
)
    targets = output_targets(context, :leaves)
    result_ids = reverse(collect(object_ids(targets)))
    values = [
        model.base + convert(typeof(model.base), index)
        for index in eachindex(result_ids)
    ]
    assign_outputs!(targets, result_ids, (incident_signal=values,))
    status.assigned_count = length(result_ids)
    return nothing
end

"""Build a non-MTG lifecycle scenario with one runtime leaf initializer."""
function lifecycle_scenario()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene);
        applications=(
            ModelSpec(
                LeafInitializer();
                name=:leaf_initializer,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                RegisterLeaf();
                name=:leaf_creator,
                on=One(scale=:Scene),
                calls=(
                    leaf=Initializer(
                        One(
                            scale=:Leaf,
                            within=SceneScope(),
                            application=:leaf_initializer,
                        ),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

"""Build an identity-aware distributed-output scenario for two leaves."""
function distributed_output_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:leaf, parent=:scene),
        Object(:leaf_2; scale=:Leaf, kind=:leaf, parent=:scene);
        applications=(
            ModelSpec(
                DistributeLeafSignal(T(10));
                name=:distributed_signal,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(incident_signal=Default(zero(T)),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => T),
    )
end

end # module LifecycleOutputExample
