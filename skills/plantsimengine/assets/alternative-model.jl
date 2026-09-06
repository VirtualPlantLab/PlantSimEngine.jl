module AlternativeModelExample

using PlantSimEngine

export LinearCarbonGain, SaturatingCarbonGain, WaterLimitedCarbonGain
export ABSORBED_PAR_CONTRACT, CARBON_GAIN_CONTRACT, FTSW_CONTRACT

PlantSimEngine.@process "carbon_gain" verbose=false

const ABSORBED_PAR_CONTRACT = VariableContract(
    unit=:mol_photon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

const CARBON_GAIN_CONTRACT = VariableContract(
    unit=:g_carbon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

const FTSW_CONTRACT = VariableContract(
    unit=:fraction,
    basis=:soil_water,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

"""Linear light-response hypothesis for the `carbon_gain` process."""
struct LinearCarbonGain{T} <: AbstractCarbon_GainModel
    efficiency::T
end

PlantSimEngine.inputs_(::LinearCarbonGain) = (
    absorbed_par=Required(Real),
)
PlantSimEngine.outputs_(model::LinearCarbonGain) = (
    carbon_gain=zero(model.efficiency),
)
PlantSimEngine.environment_inputs_(::LinearCarbonGain) = NamedTuple()
PlantSimEngine.environment_outputs_(::LinearCarbonGain) = NamedTuple()
PlantSimEngine.variable_contracts_(::LinearCarbonGain) = (
    absorbed_par=ABSORBED_PAR_CONTRACT,
    carbon_gain=CARBON_GAIN_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::LinearCarbonGain) = (
    hypothesis="Carbon gain is proportional to absorbed PAR.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::LinearCarbonGain) = (
    efficiency=(
        description="Illustrative proportional carbon-gain efficiency.",
        unit=:g_carbon_per_mol_photon,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::LinearCarbonGain,
    status,
    environment,
    constants,
    context,
)
    status.carbon_gain = model.efficiency * status.absorbed_par
    return nothing
end

"""Saturating light-response hypothesis with the same public interface."""
struct SaturatingCarbonGain{T} <: AbstractCarbon_GainModel
    maximum::T
    half_saturation::T
end

PlantSimEngine.inputs_(::SaturatingCarbonGain) = (
    absorbed_par=Required(Real),
)
PlantSimEngine.outputs_(model::SaturatingCarbonGain) = (
    carbon_gain=zero(model.maximum),
)
PlantSimEngine.environment_inputs_(::SaturatingCarbonGain) = NamedTuple()
PlantSimEngine.environment_outputs_(::SaturatingCarbonGain) = NamedTuple()
PlantSimEngine.variable_contracts_(::SaturatingCarbonGain) = (
    absorbed_par=ABSORBED_PAR_CONTRACT,
    carbon_gain=CARBON_GAIN_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::SaturatingCarbonGain) = (
    hypothesis="Carbon gain follows a rectangular saturating light response.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::SaturatingCarbonGain) = (
    maximum=(
        description="Illustrative asymptotic daily carbon gain.",
        unit=:g_carbon,
        domain=(minimum=0,),
    ),
    half_saturation=(
        description="Absorbed PAR giving half the illustrative maximum.",
        unit=:mol_photon,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::SaturatingCarbonGain,
    status,
    environment,
    constants,
    context,
)
    status.carbon_gain =
        model.maximum * status.absorbed_par /
        (model.half_saturation + status.absorbed_par)
    return nothing
end

"""
Light-response hypothesis with an additional soil-water input.

It implements the same process as `LinearCarbonGain`, but it is not a drop-in
replacement because its status interface contains `ftsw`.
"""
struct WaterLimitedCarbonGain{T} <: AbstractCarbon_GainModel
    efficiency::T
end

PlantSimEngine.inputs_(::WaterLimitedCarbonGain) = (
    absorbed_par=Required(Real),
    ftsw=Required(Real),
)
PlantSimEngine.outputs_(model::WaterLimitedCarbonGain) = (
    carbon_gain=zero(model.efficiency),
)
PlantSimEngine.environment_inputs_(::WaterLimitedCarbonGain) = NamedTuple()
PlantSimEngine.environment_outputs_(::WaterLimitedCarbonGain) = NamedTuple()
PlantSimEngine.variable_contracts_(::WaterLimitedCarbonGain) = (
    absorbed_par=ABSORBED_PAR_CONTRACT,
    ftsw=FTSW_CONTRACT,
    carbon_gain=CARBON_GAIN_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::WaterLimitedCarbonGain) = (
    hypothesis="A bounded soil-water fraction scales a linear light response.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::WaterLimitedCarbonGain) = (
    efficiency=(
        description="Illustrative proportional carbon-gain efficiency before water limitation.",
        unit=:g_carbon_per_mol_photon,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::WaterLimitedCarbonGain,
    status,
    environment,
    constants,
    context,
)
    bounded_ftsw = clamp(status.ftsw, zero(status.ftsw), one(status.ftsw))
    status.carbon_gain =
        model.efficiency * status.absorbed_par * bounded_ftsw
    return nothing
end

end # module AlternativeModelExample
