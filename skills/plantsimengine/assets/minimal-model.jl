module MinimalModelExample

using Dates
using PlantSimEngine

export RadiationUseEfficiency
export direct_example, single_object_scenario
export INTERCEPTED_PAR_CONTRACT, BIOMASS_INCREMENT_CONTRACT

PlantSimEngine.@process "biomass_production" verbose=false

const INTERCEPTED_PAR_CONTRACT = VariableContract(
    unit=:mol_photon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

const BIOMASS_INCREMENT_CONTRACT = VariableContract(
    unit=:g_dry_matter,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

"""
    RadiationUseEfficiency(rue)

Minimal demonstration model for the `biomass_production` process.

`rue` is expressed in g dry matter per mol intercepted photons. This fixture
demonstrates the PlantSimEngine authoring contract; it is not a calibrated crop
model.
"""
struct RadiationUseEfficiency{T} <: AbstractBiomass_ProductionModel
    rue::T
end

PlantSimEngine.inputs_(::RadiationUseEfficiency) = (
    intercepted_par=Required(Real),
)

PlantSimEngine.outputs_(model::RadiationUseEfficiency) = (
    biomass_increment=zero(model.rue),
)

PlantSimEngine.environment_inputs_(::RadiationUseEfficiency) = NamedTuple()
PlantSimEngine.environment_outputs_(::RadiationUseEfficiency) = NamedTuple()

PlantSimEngine.variable_contracts_(::RadiationUseEfficiency) = (
    intercepted_par=INTERCEPTED_PAR_CONTRACT,
    biomass_increment=BIOMASS_INCREMENT_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::RadiationUseEfficiency) = (
    hypothesis="Biomass increment is proportional to intercepted PAR.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::RadiationUseEfficiency) = (
    rue=(
        description="Illustrative radiation-use efficiency.",
        unit=:g_dry_matter_per_mol_photon,
        domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(
    model::RadiationUseEfficiency,
    status,
    environment,
    constants,
    context,
)
    status.biomass_increment = model.rue * status.intercepted_par
    return nothing
end

"""Run the kernel directly with `T` values and return its status."""
function direct_example(::Type{T}=Float32) where {T<:Real}
    model = RadiationUseEfficiency(T(1.5))
    status = Status(
        intercepted_par=T(10),
        biomass_increment=zero(T),
    )

    PlantSimEngine.run!(model, status, NamedTuple(), nothing, nothing)
    return status
end

"""Build the smallest complete one-object scenario using `T` values."""
function single_object_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        RadiationUseEfficiency(T(1.5));
        status=(intercepted_par=T(10),),
        timestep=Day(1),
    )
end

end # module MinimalModelExample
