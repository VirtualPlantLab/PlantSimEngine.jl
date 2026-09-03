module AdapterModelExample

using Dates
using PlantSimEngine

export GroundRadiation, GroundToPlantRadiation, ObservePlantRadiation
export adapter_scenario, GROUND_PAR_CONTRACT, PLANT_PAR_CONTRACT

PlantSimEngine.@process "radiation_supply" verbose=false
PlantSimEngine.@process "radiation_basis_conversion" verbose=false
PlantSimEngine.@process "radiation_observation" verbose=false

const GROUND_PAR_CONTRACT = VariableContract(
    unit=:mol_photon,
    basis=:ground_area,
    temporal=:day,
    aggregation=:total,
    extent=:intensive,
)

const PLANT_PAR_CONTRACT = VariableContract(
    unit=:mol_photon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

"""Fixed ground-area radiation source used only by this executable fixture."""
struct GroundRadiation{T} <: AbstractRadiation_SupplyModel
    par::T
end

PlantSimEngine.inputs_(::GroundRadiation) = NamedTuple()
PlantSimEngine.outputs_(model::GroundRadiation) = (
    par_ground=zero(model.par),
)
PlantSimEngine.environment_inputs_(::GroundRadiation) = NamedTuple()
PlantSimEngine.environment_outputs_(::GroundRadiation) = NamedTuple()
PlantSimEngine.variable_contracts_(::GroundRadiation) = (
    par_ground=GROUND_PAR_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::GroundRadiation) = (
    hypothesis="A fixed illustrative daily PAR supply is expressed per ground area.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::GroundRadiation) = (
    par=(
        description="Illustrative daily PAR supply per ground area.",
        unit=:mol_photon_per_square_metre_ground,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::GroundRadiation,
    status,
    environment,
    constants,
    context,
)
    status.par_ground = model.par
    return nothing
end

"""
Convert radiation per unit ground area to radiation for one plant.

`ground_area` is the ground area represented by the plant, in m². The named
adapter makes the change of physical basis visible in both the scenario graph
and the variable contracts.
"""
struct GroundToPlantRadiation{T} <: AbstractRadiation_Basis_ConversionModel
    ground_area::T
end

PlantSimEngine.inputs_(::GroundToPlantRadiation) = (
    par_ground=Required(Real),
)
PlantSimEngine.outputs_(model::GroundToPlantRadiation) = (
    par_plant=zero(model.ground_area),
)
PlantSimEngine.environment_inputs_(::GroundToPlantRadiation) = NamedTuple()
PlantSimEngine.environment_outputs_(::GroundToPlantRadiation) = NamedTuple()
PlantSimEngine.variable_contracts_(::GroundToPlantRadiation) = (
    par_ground=GROUND_PAR_CONTRACT,
    par_plant=PLANT_PAR_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::GroundToPlantRadiation) = (
    hypothesis="Plant PAR equals ground-area PAR times represented ground area.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::GroundToPlantRadiation) = (
    ground_area=(
        description="Ground area represented by one plant.",
        unit=:square_metre_ground_per_plant,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::GroundToPlantRadiation,
    status,
    environment,
    constants,
    context,
)
    status.par_plant = status.par_ground * model.ground_area
    return nothing
end

"""Consumer used to prove the adapted contract is accepted."""
struct ObservePlantRadiation <: AbstractRadiation_ObservationModel end

PlantSimEngine.inputs_(::ObservePlantRadiation) = (
    par_plant=Required(Real),
)
PlantSimEngine.outputs_(::ObservePlantRadiation) = (
    observed_par=0.0,
)
PlantSimEngine.environment_inputs_(::ObservePlantRadiation) = NamedTuple()
PlantSimEngine.environment_outputs_(::ObservePlantRadiation) = NamedTuple()
PlantSimEngine.variable_contracts_(::ObservePlantRadiation) = (
    par_plant=PLANT_PAR_CONTRACT,
    observed_par=PLANT_PAR_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::ObservePlantRadiation) = (
    hypothesis="The observer copies plant-basis PAR without conversion.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::ObservePlantRadiation,
    status,
    environment,
    constants,
    context,
)
    status.observed_par = status.par_plant
    return nothing
end

"""Build a complete cross-object scenario with an explicit basis adapter."""
function adapter_scenario(::Type{T}=Float64) where {T<:Real}
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:plant; scale=:Plant, kind=:plant, parent=:scene);
        applications=(
            ModelSpec(
                GroundRadiation(T(12));
                name=:ground_radiation,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                GroundToPlantRadiation(T(2.5));
                name=:basis_adapter,
                on=One(scale=:Plant),
                inputs=(
                    par_ground=One(
                        scale=:Scene,
                        within=SceneScope(),
                        application=:ground_radiation,
                        var=:par_ground,
                    ),
                ),
            ),
            ModelSpec(
                ObservePlantRadiation();
                name=:observer,
                on=One(scale=:Plant),
            ),
        ),
        environment=(duration=Day(1),),
        type_promotion=Dict(Float64 => T),
    )
end

end # module AdapterModelExample
