struct LinearResponse{T} <: AbstractFixture_Signal_ResponseModel
    slope::T
end

PlantSimEngine.inputs_(::LinearResponse) = (signal=Required(Real),)
PlantSimEngine.outputs_(model::LinearResponse) = (response=zero(model.slope),)
PlantSimEngine.environment_inputs_(::LinearResponse) = NamedTuple()
PlantSimEngine.environment_outputs_(::LinearResponse) = NamedTuple()
PlantSimEngine.variable_contracts_(::LinearResponse) = (
    signal=FIXTURE_SIGNAL_CONTRACT,
    response=FIXTURE_SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::LinearResponse) = (
    hypothesis="Response is proportional to an illustrative input signal.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::LinearResponse) = (
    slope=(
        description="Dimensionless illustrative response slope.",
        unit=:one,
    ),
)

function PlantSimEngine.run!(
    model::LinearResponse,
    status,
    environment,
    constants,
    context,
)
    status.response = model.slope * status.signal
    return nothing
end
