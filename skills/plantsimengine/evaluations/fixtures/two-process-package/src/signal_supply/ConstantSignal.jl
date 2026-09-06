struct ConstantSignal{T} <: AbstractFixture_Signal_SupplyModel
    value::T
end

PlantSimEngine.inputs_(::ConstantSignal) = NamedTuple()
PlantSimEngine.outputs_(model::ConstantSignal) = (signal=zero(model.value),)
PlantSimEngine.environment_inputs_(::ConstantSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::ConstantSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::ConstantSignal) = (
    signal=FIXTURE_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::ConstantSignal) = (
    hypothesis="A constant illustrative signal is supplied to one object.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::ConstantSignal) = (
    value=(
        description="Constant illustrative signal.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::ConstantSignal,
    status,
    environment,
    constants,
    context,
)
    status.signal = model.value
    return nothing
end
