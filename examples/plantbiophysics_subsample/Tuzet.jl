#! Careful: this file is more or less a copy/paste from the original model implementation in PlantBiophysics.jl (v0.16.2). It is only used for testing.
#! If you want to use this model, use the one from PlantBiophysics.jl instead, which is more up to date and maintained.

# Generate all methods for the stomatal conductance process: several meteo time-steps, components,
#  over an MTG, and the mutating /non-mutating versions
@process "stomatal_conductance" verbose = false

# Default policy for stomatal conductance when consumed at coarser clocks.
# Conductance is typically summarized over a window rather than accumulated.
PlantSimEngine.output_policy(::Type{<:AbstractStomatal_ConductanceModel}) = (Gₛ=PlantSimEngine.Aggregate(PlantMeteo.DurationSumReducer()),)

# Gs is used a little bit differently compared to the other processes. We use two forms:
# the stomatal closure and the full computation of Gs
function PlantSimEngine.run!(Gs::Gsm, models, status, gs_closure, extra) where {Gsm<:AbstractStomatal_ConductanceModel}
    status.Gₛ = max(
        models.stomatal_conductance.gs_min,
        models.stomatal_conductance.g0 + gs_closure * status.A
    )
end

function PlantSimEngine.run!(Gs::Gsm, models, status, meteo, constants, extra) where {Gsm<:AbstractStomatal_ConductanceModel}
    status.Gₛ = max(
        models.stomatal_conductance.gs_min,
        models.stomatal_conductance.g0 + gs_closure(models.stomatal_conductance, models, status, meteo, constants, extra) * status.A
    )
end

"""
Tuzet et al. (2003) stomatal conductance model for CO₂.

# Arguments

- `g0`: intercept (μmol m⁻² s⁻¹).
- `g1`: slope.
- `Ψᵥ`: leaf water potential at which stomatal conductance is halved (MPa).
- `sf`: sensitivity factor for stomatal closure.
- `Γ`: CO₂ compensation point (mol mol⁻¹).
- `gs_min`: residual conductance (μmol m⁻² s⁻¹).

# Variables 

- `Ψₗ`: leaf water potential (MPa).
- `Cₛ`: CO₂ concentration at the leaf surface (μmol mol⁻¹).
- `A`: CO₂ assimilation rate (μmol m⁻² s⁻¹).
- `Gₛ`: stomatal conductance (μmol m⁻² s⁻¹).

# Note

The CO₂ compensation point represents the concentration of CO₂ at which photosynthesis and respiration are balanced, 
and it is typically a small positive value around 30–50 μmol mol⁻¹ under normal atmospheric conditions.

This implementation uses Cₛ instead of Cᵢ. 

# Examples

```julia
using PlantMeteo, PlantSimEngine, PlantBiophysics
meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)

leaf =
    ModelMapping(
        stomatal_conductance = Tuzet(0.03, 12.0, -1.5, 2.0, 30.0),
        status = (Cₛ = 380.0, Ψₗ = -1.0)
    )
run!(leaf, meteo)
```

# References

Tuzet, A., Perrier, A., & Leuning, R. (2003). A coupled model of stomatal conductance, photosynthesis and transpiration. Plant, Cell & Environment, 26(7), 1097-1116.
"""
struct Tuzet{T} <: AbstractStomatal_ConductanceModel
    g0::T
    g1::T
    Ψᵥ::T
    sf::T
    Γ::T
    gs_min::T
end

Tuzet(g0, g1, Ψᵥ, sf, Γ, gs_min=oftype(g0, 0.001)) = Tuzet(promote(g0, g1, Ψᵥ, sf, Γ, gs_min))
Tuzet(; g0, g1, Ψᵥ, sf, Γ, gs_min=0.001) = Tuzet(g0, g1, Ψᵥ, sf, Γ, gs_min)

function PlantSimEngine.inputs_(::Tuzet)
    (Ψₗ=-Inf, Cₛ=-Inf)
end

function PlantSimEngine.outputs_(::Tuzet)
    (Gₛ=-Inf,)
end

Base.eltype(::Tuzet{T}) where T = T

"""
    gs_closure(::Tuzet, models, status, meteo, constants=nothing, extra=nothing)

Stomatal closure for CO₂ according to Tuzet et al. (2003).

# Arguments

- `::Tuzet`: an instance of the `Tuzet` model type.
- `models::ModelMapping`: A `ModelMapping` struct holding the parameters for the models.
- `status`: A status struct holding the variables for the models.
- `meteo`: meteorology structure, see [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere). Is not used in this model.
- `constants`: A constants struct holding the constants for the models. Is not used in this model.
- `extra`: A struct holding the extra variables for the models. Is not used in this model.

# Details

The stomatal conductance is calculated as:

    FPSIF = (1 + exp(sf * psiv)) / (1 + exp(sf * (psiv - Ψₗ)))
    GSDIVA = g0 + (g1 / (Cₛ - Γ)) * FPSIF

where `Γ` is the CO₂ compensation point.
"""
function gs_closure(m::Tuzet, models, status, meteo, constants=nothing, extra=nothing)
    fpsif = (1 + exp(m.sf * m.Ψᵥ)) /
            (1 + exp(m.sf * (m.Ψᵥ - status.Ψₗ)))
    (m.g1 / (status.Cₛ - m.Γ)) * fpsif
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:Tuzet}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Tuzet}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.timestep_hint(::Type{<:Tuzet}) = (
    required=(Dates.Minute(1), Dates.Hour(6)),
    preferred=Dates.Hour(1)
)
