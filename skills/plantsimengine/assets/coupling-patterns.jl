module CouplingPatternsExample

using Dates
using PlantSimEngine

export ConstantLeafSignal, ObserveOneSignal, ObserveOptionalSignal, SumLeafSignals
export coupling_scenario, LEAF_SIGNAL_CONTRACT, PLANT_SIGNAL_CONTRACT

PlantSimEngine.@process "pedagogical_leaf_signal" verbose=false
PlantSimEngine.@process "pedagogical_signal_observation" verbose=false
PlantSimEngine.@process "pedagogical_plant_signal_total" verbose=false

const LEAF_SIGNAL_CONTRACT = VariableContract(
    unit=:arbitrary_signal_unit,
    basis=:leaf,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

const PLANT_SIGNAL_CONTRACT = VariableContract(
    unit=:arbitrary_signal_unit,
    basis=:plant,
    temporal=:instantaneous,
    aggregation=:total,
    extent=:extensive,
)

"""Pedagogical constant leaf signal; not a calibrated scientific model."""
struct ConstantLeafSignal{T} <: AbstractPedagogical_Leaf_SignalModel
    signal::T
end

PlantSimEngine.inputs_(::ConstantLeafSignal) = NamedTuple()
PlantSimEngine.outputs_(model::ConstantLeafSignal) = (
    leaf_signal=zero(model.signal),
)
PlantSimEngine.environment_inputs_(::ConstantLeafSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::ConstantLeafSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::ConstantLeafSignal) = (
    leaf_signal=LEAF_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::ConstantLeafSignal) = (
    hypothesis="A leaf exposes one constant illustrative signal.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::ConstantLeafSignal) = (
    signal=(
        description="Constant illustrative signal assigned to each selected leaf.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::ConstantLeafSignal,
    status,
    environment,
    constants,
    context,
)
    status.leaf_signal = model.signal
    return nothing
end

"""Copy one explicitly selected and renamed leaf signal."""
struct ObserveOneSignal <: AbstractPedagogical_Signal_ObservationModel end

PlantSimEngine.inputs_(::ObserveOneSignal) = (
    selected_signal=Required(Real),
)
PlantSimEngine.outputs_(::ObserveOneSignal) = (one_seen=0.0,)
PlantSimEngine.environment_inputs_(::ObserveOneSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::ObserveOneSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::ObserveOneSignal) = (
    selected_signal=LEAF_SIGNAL_CONTRACT,
    one_seen=LEAF_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::ObserveOneSignal) = (
    hypothesis="An observer copies one selected leaf signal without conversion.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::ObserveOneSignal,
    status,
    environment,
    constants,
    context,
)
    status.one_seen = status.selected_signal
    return nothing
end

"""Copy an optional signal, retaining its declared zero default when absent."""
struct ObserveOptionalSignal <: AbstractPedagogical_Signal_ObservationModel end

PlantSimEngine.inputs_(::ObserveOptionalSignal) = (
    optional_signal=Default(0.0),
)
PlantSimEngine.outputs_(::ObserveOptionalSignal) = (optional_seen=0.0,)
PlantSimEngine.environment_inputs_(::ObserveOptionalSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::ObserveOptionalSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::ObserveOptionalSignal) = (
    optional_signal=LEAF_SIGNAL_CONTRACT,
    optional_seen=LEAF_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::ObserveOptionalSignal) = (
    hypothesis="An absent optional illustrative signal has a meaningful zero value.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::ObserveOptionalSignal,
    status,
    environment,
    constants,
    context,
)
    status.optional_seen = status.optional_signal
    return nothing
end

"""Sum the signals of all descendant leaves for one plant."""
struct SumLeafSignals <: AbstractPedagogical_Plant_Signal_TotalModel end

PlantSimEngine.inputs_(::SumLeafSignals) = (
    leaf_signals=Required(AbstractVector{<:Real}),
)
PlantSimEngine.outputs_(::SumLeafSignals) = (plant_total=0.0,)
PlantSimEngine.environment_inputs_(::SumLeafSignals) = NamedTuple()
PlantSimEngine.environment_outputs_(::SumLeafSignals) = NamedTuple()
PlantSimEngine.variable_contracts_(::SumLeafSignals) = (
    leaf_signals=LEAF_SIGNAL_CONTRACT,
    plant_total=PLANT_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::SumLeafSignals) = (
    hypothesis="The illustrative plant total is the sum of its descendant leaf signals.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::SumLeafSignals,
    status,
    environment,
    constants,
    context,
)
    status.plant_total = sum(status.leaf_signals; init=zero(status.plant_total))
    return nothing
end

"""Build an explicit cross-object scenario covering common selector patterns."""
function coupling_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant; scale=:Plant, kind=:plant, parent=:scene),
        Object(
            :leaf_1;
            scale=:Leaf,
            kind=:leaf,
            name=:first_leaf,
            parent=:plant,
        ),
        Object(
            :leaf_2;
            scale=:Leaf,
            kind=:leaf,
            name=:second_leaf,
            parent=:plant,
        );
        applications=(
            ModelSpec(
                ConstantLeafSignal(T(2));
                name=:leaf_source,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                ObserveOneSignal();
                name=:one_observer,
                on=One(scale=:Plant),
                inputs=(
                    selected_signal=One(
                        scale=:Leaf,
                        name=:first_leaf,
                        within=Subtree(),
                        application=:leaf_source,
                        var=:leaf_signal,
                    ),
                ),
            ),
            ModelSpec(
                ObserveOptionalSignal();
                name=:optional_observer,
                on=One(scale=:Plant),
                inputs=(
                    optional_signal=OptionalOne(
                        scale=:Flower,
                        within=Subtree(),
                        application=:leaf_source,
                        var=:leaf_signal,
                    ),
                ),
            ),
            ModelSpec(
                SumLeafSignals();
                name=:plant_total,
                on=One(scale=:Plant),
                inputs=(
                    leaf_signals=Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_source,
                        var=:leaf_signal,
                    ),
                ),
            ),
        ),
        environment=(duration=Day(1),),
        type_promotion=Dict(Float64 => T),
    )
end

end # module CouplingPatternsExample
