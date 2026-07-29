#! Careful: this file is a copy/paste from the original model implementation in PlantBiophysics.jl (v0.16.2). It is only used for testing.
#! If you want to use this model, use the one from PlantBiophysics.jl instead, which is more up to date and maintained.

@process "energy_balance" verbose = false
"""
    black_body(T, K₀, σ)
    black_body(T)

Thermal infrared, *i.e.* longwave radiation emitted from a black body at temperature T.

- `T`: temperature of the object in Celsius degree
- `K₀`: absolute zero (°C)
- `σ` (``W\\ m^{-2}\\ K^{-4}``) [Stefan-Boltzmann constant](https://en.wikipedia.org/wiki/Stefan%E2%80%93Boltzmann_law)

# Note

`K₀` and `σ` are taken from `PlantMeteo.Constants` if not provided.

"""
function black_body(T, K₀, σ)
    Tₖ = T - K₀
    σ * (Tₖ^4.0)
end

function black_body(T)
    constants = PlantMeteo.Constants()
    black_body(T, constants.K₀, constants.σ)
end


"""
Thermal infrared, *i.e.* longwave radiation emitted from an object at temperature T.

- `T`: temperature of the object in Celsius degree
- `ε` object [emissivity](https://en.wikipedia.org/wiki/Emissivity) (not to confuse with ε the
ratio of molecular weights from `PlantMeteo.Constants`). A typical value for a leaf is 0.955.
- `K₀`: absolute zero (°C)
- `σ` (``W\\ m^{-2}\\ K^{-4}``) [Stefan-Boltzmann constant](https://en.wikipedia.org/wiki/Stefan%E2%80%93Boltzmann_law)

# Note

`K₀` and `σ` are taken from `PlantMeteo.Constants` if not provided.

# Examples

```julia
# Thermal infrared radiation of water at 25 °C:
grey_body(25.0, 0.96)
```
"""
function grey_body(T, ε, K₀, σ)
    ε * black_body(T, K₀, σ)
end

function grey_body(T, ε)
    constants = PlantMeteo.Constants()
    grey_body(T, ε, constants.K₀, constants.σ)
end


"""
    net_longwave_radiation(T₁,T₂,ε₁,ε₂,F₁,K₀,σ)
    net_longwave_radiation(T₁,T₂,ε₁,ε₂,F₁)

Net longwave radiation fluxes (*i.e.* thermal radiation, W m-2) between an object and another.
The object of interest is at temperature T₁ and has an emissivity ε₁, and the object with
which it exchanges energy is at temperature T₂ and has an emissivity ε₂.

If the result is positive, then the object of interest gain energy.

# Arguments

- `T₁` (Celsius degree): temperature of the target object (object 1)
- `T₂` (Celsius degree): temperature of the object with which there is potential exchange (object 2)
- `ε₁`: object 1 emissivity
- `ε₂`: object 2 emissivity
- `F₁`: view factor (0-1), *i.e.* visible fraction of object 2 from object 1 (see note)
- `K₀`: absolute zero (°C)
- `σ` (``W\\ m^{-2}\\ K^{-4}``) [Stefan-Boltzmann constant](https://en.wikipedia.org/wiki/Stefan%E2%80%93Boltzmann_law)

# Note

`F₁`, the view factor (also called shape factor) is a coefficient applied to the semi-hemisphere
field of view of object 1 that "sees" object 2. E.g. a leaf can be viewed as a plane. If one side
of the leaf sees only object 2 in its field of view (e.g. the sky), then `F₁ = 1`.
Then the net longwave radiation flux for this part of the leaf is multiplied by its actual
surface to get the exchange. Note that we apply reciprocity between the two objects for
the view factor (they have the same value), *i.e.*: A₁F₁₂ = A₂F₂₁.

Then, if we take a leaf as object 1, and the sky as object 2, the visible fraction of
sky viewed by the leaf would be:

- `0.5` if the leaf is on top of the canopy, *i.e.* the upper side of the leaf sees the sky,
the side bellow sees other leaves and the soil.
- between 0 and 0.5 if it is within the canopy and partly shaded by other objects.

Note that `A₁` for a leaf is twice its common used leaf area, because `A₁` is the **total**
leaf area of the object that exchange energy.

```julia
# Net thermal radiation fluxes between a leaf and the sky considering the leaf at the top of
# the canopy:
Tₗ = 25.0 ; Tₐ = 20.0
ε₁ = 0.955 ; ε₂ = 1.0
Ra_LW_f = net_longwave_radiation(Tₗ,Tₐ,ε₁,ε₂,1.0)
Ra_LW_f

# Ra_LW_f is the net longwave radiation flux between the leaf and the atmosphere per surface area.
# To get the actual net longwave radiation flux we need to multiply by the surface of the
# leaf, e.g. for a leaf of 2cm²:
leaf_area = 2e-4 # in m²
Ra_LW_f * leaf_area

# The leaf lose ~0.0055 W towards the atmosphere.
```

# References

Cengel, Y, et Transfer Mass Heat. 2003. A practical approach. New York, NY, USA: McGraw-Hill.
"""
function net_longwave_radiation(T₁, T₂, ε₁, ε₂, F₁, K₀, σ)
    (black_body(T₂, K₀, σ) - black_body(T₁, K₀, σ)) / (1.0 / ε₁ + 1.0 / ε₂ - 1.0) * F₁
end

function net_longwave_radiation(T₁, T₂, ε₁, ε₂, F₁)
    constants = PlantMeteo.Constants()
    net_longwave_radiation(T₁, T₂, ε₁, ε₂, F₁, constants.K₀, constants.σ)
end

"""
    gbₕ_free(Tₐ,Tₗ,d,Dₕ₀)
    gbₕ_free(Tₐ,Tₗ,d)

Leaf boundary layer conductance for heat under **free** convection (m s-1).

# Arguments

- `Tₐ` (°C): air temperature
- `Tₗ` (°C): leaf temperature
- `d` (m): characteristic dimension, *e.g.* leaf width (see eq. 10.9 from Monteith and Unsworth, 2013).
- `Dₕ₀ = 21.5e-6`: molecular diffusivity for heat at base temperature. Use value from
`PlantMeteo.Constants` if not provided.

# Note

`R` and `Dₕ₀` can be found using `PlantMeteo.Constants`. To transform in ``mol\\ m^{-2}\\ s^{-1}``,
use [`ms_to_mol`](@ref).

# References

Leuning, R., F. M. Kelliher, DGG de Pury, et E.-D. SCHULZE. 1995. « Leaf nitrogen,
photosynthesis, conductance and transpiration: scaling from leaves to canopies ». Plant,
Cell & Environment 18 (10): 1183‑1200.

Monteith, John, et Mike Unsworth. 2013. Principles of environmental physics: plants,
animals, and the atmosphere. Academic Press. Paragraph 10.1.3, eq. 10.9.
"""
function gbₕ_free(Tₐ, Tₗ, d, Dₕ₀=PlantMeteo.Constants().Dₕ₀)
    zeroT = zero(Tₐ) # make it type stable

    if abs(Tₗ - Tₐ) > zeroT
        Gr = 1.58e8 * d^3.0 * abs(Tₗ - Tₐ) # Grashof number (Monteith and Unsworth, 2013)
        # !Note: Leuning et al. (1995) use 1.6e8 (eq. E4).
        # Leuning et al. (1995) eq. E3:
        Gbₕ_free = 0.5 * get_Dₕ(Tₐ, Dₕ₀) * (Gr^0.25) / d
    else
        Gbₕ_free = zeroT
    end

    return Gbₕ_free
end


"""
    gbₕ_forced(Wind,d)

Boundary layer conductance for heat under **forced** convection (m s-1). See eq. E1 from
Leuning et al. (1995) for more details.

# Arguments

- `Wind` (m s-1): wind speed
- `d` (m): characteristic dimension, *e.g.* leaf width (see eq. 10.9 from Monteith and Unsworth, 2013).

# Notes

`d` is the minimal dimension of the surface of an object in contact with the air.

# References

Leuning, R., F. M. Kelliher, DGG de Pury, et E.-D. SCHULZE. 1995. « Leaf nitrogen,
photosynthesis, conductance and transpiration: scaling from leaves to canopies ». Plant,
Cell & Environment 18 (10): 1183‑1200.
"""
function gbₕ_forced(Wind, d)
    0.003 * sqrt(Wind / d)
end


"""
    get_Dₕ(T,Dₕ₀)
    get_Dₕ(T)

Dₕ -molecular diffusivity for heat at base temperature- from Dₕ₀ (corrected by temperature).
See Monteith and Unsworth (2013, eq. 3.10).

# Arguments

- `Tₐ` (°C): temperature
- `Dₕ₀`: molecular diffusivity for heat at base temperature. Use value from `PlantMeteo.Constants`
if not provided.

# References

Monteith, John, et Mike Unsworth. 2013. Principles of environmental physics: plants,
animals, and the atmosphere. Academic Press. Paragraph 10.1.3.
"""
function get_Dₕ(T, Dₕ₀=PlantMeteo.Constants().Dₕ₀)
    Dₕ₀ * (1 + 0.007 * T)
end

"""
    ms_to_mol(G,T,P,R,K₀)
    ms_to_mol(G,T,P)

Conversion of a conductance `G` from ``m\\ s^{-1}`` to ``mol\\ m^{-2}\\ s^{-1}``.

# Arguments

- `G` (``m\\ s^{-1}``): conductance
- `T` (°C): air temperature
- `P` (kPa): air pressure
- `R` (``J\\ mol^{-1}\\ K^{-1}``): universal gas constant.
- `K₀` (°C): absolute zero

# See also

[`mol_to_ms`](@ref) for the inverse process.
"""
function ms_to_mol(G, T, P, R, K₀)
    G * f_ms_to_mol(T, P, R, K₀)
end

function ms_to_mol(G, T, P)
    constants = PlantMeteo.Constants()
    ms_to_mol(G, T, P, constants.R, constants.K₀)
end

"""
    ms_to_mol(G,T,P,R,K₀)
    ms_to_mol(G,T,P)

Conversion of a conductance `G` from ``mol\\ m^{-2}\\ s^{-1}`` to ``m\\ s^{-1}``.

# Arguments

- `G` (``m\\ s^{-1}``): conductance
- `T` (°C): air temperature
- `P` (kPa): air pressure
- `R` (``J\\ mol^{-1}\\ K^{-1}``): universal gas constant.
- `K₀` (°C): absolute zero

# See also

[`ms_to_mol`](@ref) for the inverse process.
"""
function mol_to_ms(G, T, P, R, K₀)
    G / f_ms_to_mol(T, P, R, K₀)
end

function mol_to_ms(G, T, P)
    constants = PlantMeteo.Constants()
    mol_to_ms(G, T, P, constants.R, constants.K₀)
end

"""
Conversion factor between conductance in ``m\\ s^{-1}`` to ``mol\\ m^{-2}\\ s^{-1}``.

# Arguments

- `T` (°C): air temperature
- `P` (kPa): air pressure
- `R` (``J\\ mol^{-1}\\ K^{-1}``): universal gas constant.
- `K₀` (°C): absolute zero
"""
function f_ms_to_mol(T, P, R, K₀)
    (P * 1000) / (R * (T - K₀))
end

"""
    gbh_to_gbw(gbh, Gbₕ_to_Gbₕ₂ₒ = PlantMeteo.Constants().Gbₕ_to_Gbₕ₂ₒ)
    gbw_to_gbh(gbh, Gbₕ_to_Gbₕ₂ₒ = PlantMeteo.Constants().Gbₕ_to_Gbₕ₂ₒ)

Boundary layer conductance for water vapor from boundary layer conductance for heat.

# Arguments

- `gbh` (m s-1): boundary layer conductance for heat under mixed convection.
- `Gbₕ_to_Gbₕ₂ₒ`: conversion factor.

# Note

Gbₕ is the sum of free and forced convection. See [`gbₕ_free`](@ref) and [`gbₕ_forced`](@ref).
"""
function gbh_to_gbw(gbh, Gbₕ_to_Gbₕ₂ₒ=PlantMeteo.Constants().Gbₕ_to_Gbₕ₂ₒ)
    gbh * Gbₕ_to_Gbₕ₂ₒ
end

function gbw_to_gbh(gbh, Gbₕ_to_Gbₕ₂ₒ=PlantMeteo.Constants().Gbₕ_to_Gbₕ₂ₒ)
    gbh / Gbₕ_to_Gbₕ₂ₒ
end


"""
    gsc_to_gsw(Gₛ, Gsc_to_Gsw = PlantMeteo.Constants().Gsc_to_Gsw)

Conversion of a stomatal conductance for CO₂ into stomatal conductance for H₂O.
"""
function gsc_to_gsw(Gₛ, Gsc_to_Gsw=PlantMeteo.Constants().Gsc_to_Gsw)
    Gₛ * Gsc_to_Gsw
end

"""
    gsw_to_gsc(Gₛ, Gsc_to_Gsw = PlantMeteo.Constants().Gsc_to_Gsw)

Conversion of a stomatal conductance for H₂O into stomatal conductance for CO₂.
"""
function gsw_to_gsc(Gₛ, Gsc_to_Gsw=PlantMeteo.Constants().Gsc_to_Gsw)
    Gₛ / Gsc_to_Gsw
end

"""
γ_star(γ, a_sh, a_s, rbv, Rsᵥ, Rbₕ)

γ∗, the apparent value of psychrometer constant (kPa K−1).

# Arguments

- `γ` (kPa K−1): psychrometer constant
- `aₛₕ` (1,2): number of faces exchanging heat fluxes (see Schymanski et al., 2017)
- `aₛᵥ` (1,2): number of faces exchanging water fluxes (see Schymanski et al., 2017)
- `Rbᵥ` (s m-1): boundary layer resistance to water vapor
- `Rsᵥ` (s m-1): stomatal resistance to water vapor
- `Rbₕ` (s m-1): boundary layer resistance to heat

# Note

Using the corrigendum from Schymanski et al. (2017) in here so the definition of
[`latent_heat`](@ref) remains generic.

Not to be confused with [`Γ_star`](@ref) the CO₂ compensation point.

# References

Monteith, John L., et Mike H. Unsworth. 2013. « Chapter 13 - Steady-State Heat Balance: (i)
Water Surfaces, Soil, and Vegetation ». In Principles of Environmental Physics (Fourth Edition),
edited by John L. Monteith et Mike H. Unsworth, 217‑47. Boston: Academic Press.

Schymanski, Stanislaus J., et Dani Or. 2017. Leaf-Scale Experiments Reveal an Important
Omission in the Penman–Monteith Equation ». Hydrology and Earth System Sciences 21 (2): 685‑706.
https://doi.org/10.5194/hess-21-685-2017.
"""
function γ_star(γ, aₛₕ, aₛᵥ, Rbᵥ, Rsᵥ, Rbₕ)
    γ * aₛₕ / aₛᵥ * (Rbᵥ + Rsᵥ) / Rbₕ # rv + Rsᵥ= Boundary + stomatal conductance to water vapour
end

"""
    λE_to_E(λE, λ, Mₕ₂ₒ=PlantMeteo.Constants().Mₕ₂ₒ)
    E_to_λE(E, λ, Mₕ₂ₒ=PlantMeteo.Constants().Mₕ₂ₒ)

Conversion from latent heat (W m-2) to evaporation (mol[H₂O] m-2 s-1) or the
opposite (`E_to_λE`).

# Arguments

- `λE`: latent heat flux (W m-2)
- `E`: water evaporation (mol[H₂O] m-2 s-1)
- `λ` (J kg-1): latent heat of vaporization
- `Mₕ₂ₒ = 18.0e-3` (kg mol-1): Molar mass for water.

# Note

`λ` can be computed using:

    λ = latent_heat_vaporization(T, constants.λ₀)

It is also directly available from the [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) structure, and by extention in [`Weather`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Weather).

To convert E from mol[H₂O] m-2 s-1 to mm s-1 you can simply do:

    E_mms = E_mol / constants.Mₕ₂ₒ

mm[H₂O] s-1 is equivalent to kg[H₂O] m-2 s-1, wich is equivalent to l[H₂O] m-2 s-1.

"""
function λE_to_E(λE, λ, Mₕ₂ₒ=PlantMeteo.Constants().Mₕ₂ₒ)
    λE / λ * Mₕ₂ₒ
end

function E_to_λE(E, λ, Mₕ₂ₒ=PlantMeteo.Constants().Mₕ₂ₒ)
    E / Mₕ₂ₒ * λ
end

"""
Struct to hold parameter and values for the energy model close to the one in
Monteith and Unsworth (2013)

# Arguments

- `aₛₕ = 2`: number of faces of the object that exchange sensible heat fluxes
- `aₛᵥ = 1`: number of faces of the object that exchange latent heat fluxes (hypostomatous => 1)
- `ε = 0.955`: emissivity of the object
- `maxiter = 10`: maximal number of iterations allowed to close the energy balance
- `ΔT = 0.01` (°C): maximum difference in object temperature between two iterations to consider convergence

# Examples

```julia
energy_model = Monteith() # a leaf in an illuminated chamber
```
"""
struct Monteith{T,S} <: AbstractEnergy_BalanceModel
    aₛₕ::S
    aₛᵥ::S
    ε::T
    maxiter::S
    ΔT::T
end

function Monteith(; aₛₕ=2, aₛᵥ=1, ε=0.955, maxiter=10, ΔT=0.01)
    param_int = promote(aₛₕ, aₛᵥ, maxiter)
    param_float = promote(ε, ΔT)
    Monteith(param_int[1], param_int[2], param_float[1], param_int[3], param_float[2])
end

function PlantSimEngine.inputs_(::Monteith)
    (Ra_SW_f=-Inf, sky_fraction=-Inf, d=-Inf)
end

function PlantSimEngine.meteo_inputs_(::Monteith)
    (
        T=0.0,
        Rh=0.0,
        Wind=0.0,
        P=0.0,
        Cₐ=0.0,
        ε=0.0,
        VPD=0.0,
        γ=0.0,
        Δ=0.0,
        ρ=0.0,
    )
end

function PlantSimEngine.outputs_(::Monteith)
    (
        Tₗ=-Inf, Rn=-Inf, Ra_LW_f=-Inf, H=-Inf, λE=-Inf, Cₛ=-Inf, Cᵢ=-Inf,
        A=-Inf, Gₛ=-Inf, Gbₕ=-Inf, Dₗ=-Inf, Gbc=-Inf, iter=typemin(Int)
    )
end

Base.eltype(x::Monteith) = typeof(x).parameters[1]
# Multi-rate default for energy balance: keep relatively fine cadence.
PlantSimEngine.timestep_hint(::Type{<:Monteith}) = (
    required=(Dates.Minute(1), Dates.Hour(2)),
    preferred=Dates.Hour(1)
)
PlantSimEngine.output_policy(::Type{<:Monteith}) = (
    A=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),
    Tₗ=PlantSimEngine.Integrate(PlantMeteo.MeanReducer()),
    Rn=PlantSimEngine.Integrate(PlantMeteo.RadiationEnergy()), # W m-2 to MJ m-2 timestep-1
    Ra_LW_f=PlantSimEngine.Integrate(PlantMeteo.RadiationEnergy()),
    H=PlantSimEngine.Integrate(PlantMeteo.RadiationEnergy()),
    λE=PlantSimEngine.Integrate(PlantMeteo.RadiationEnergy()),
    Cₛ=PlantSimEngine.Integrate(PlantMeteo.MeanReducer()),
    Cᵢ=PlantSimEngine.Integrate(PlantMeteo.MeanReducer()),
    Gₛ=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),
    Gbₕ=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),
    Dₗ=PlantSimEngine.Integrate(PlantMeteo.MeanReducer()),
    Gbc=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),
    iter=PlantSimEngine.Integrate(PlantMeteo.MeanReducer())
)

PlantSimEngine.dep(::Monteith) = (
    photosynthesis=PlantSimEngine.Call(
        PlantSimEngine.One(scale=:Leaf, process=:photosynthesis),
    ),
)

"""
    run!(::Monteith, models, status, meteo, constants=Constants())

Leaf energy balance according to Monteith and Unsworth (2013), and corrigendum from
Schymanski et al. (2017). The computation is close to the one from the MAESPA model (Duursma
et al., 2012, Vezy et al., 2018) here. The leaf temperature is computed iteratively to close
the energy balance using the mass flux (~ Rn - λE).

# Arguments

- `::Monteith`: a Monteith model, usually from a model list (*i.e.* m.energy_balance)
- `models`: the process-keyed model bundle supplied by the model runtime, with
initialisations for:
    - `Ra_SW_f` (W m-2): net shortwave radiation (PAR + NIR). Often computed from a light interception model
    - `sky_fraction` (0-2): view factor between the object and the sky for both faces (see details).
    - `d` (m): characteristic dimension, *e.g.* leaf width (see eq. 10.9 from Monteith and Unsworth, 2013).
- `status`: the status of the model, usually the model list status (*i.e.* leaf.status)
- `meteo`: meteorology structure, see [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere)
- `constants = PlantMeteo.Constants()`: physical constants. See `PlantMeteo.Constants` for more details

# Details

The sky_fraction in the variables is equal to 2 if all the leaf is viewing is sky (e.g. in a
controlled chamber), 1 if the leaf is *e.g.* up on the canopy where the upper side of the
leaf sees the sky, and the side bellow sees soil + other leaves that are all considered at
the same temperature than the leaf, or less than 1 if it is partly shaded.

# Notes

If you want the algorithm to print a message whenever it does not reach convergence, use the
debugging mode by executing this in the REPL: `ENV["JULIA_DEBUG"] = PlantBiophysics`.

More information [here](https://docs.julialang.org/en/v1/stdlib/Logging/#Environment-variables).

# References

Duursma, R. A., et B. E. Medlyn. 2012. « MAESPA: a model to study interactions between water
limitation, environmental drivers and vegetation function at tree and stand levels, with an
example application to [CO2] × drought interactions ». Geoscientific Model Development 5 (4):
919‑40. https://doi.org/10.5194/gmd-5-919-2012.

Monteith, John L., et Mike H. Unsworth. 2013. « Chapter 13 - Steady-State Heat Balance: (i)
Water Surfaces, Soil, and Vegetation ». In Principles of Environmental Physics (Fourth Edition),
edited by John L. Monteith et Mike H. Unsworth, 217‑47. Boston: Academic Press.

Schymanski, Stanislaus J., et Dani Or. 2017. « Leaf-Scale Experiments Reveal an Important
Omission in the Penman–Monteith Equation ». Hydrology and Earth System Sciences 21 (2): 685‑706.
https://doi.org/10.5194/hess-21-685-2017.

Vezy, Rémi, Mathias Christina, Olivier Roupsard, Yann Nouvellon, Remko Duursma, Belinda Medlyn,
Maxime Soma, et al. 2018. « Measuring and modelling energy partitioning in canopies of varying
complexity using MAESPA model ». Agricultural and Forest Meteorology 253‑254 (printemps): 203‑17.
https://doi.org/10.1016/j.agrformet.2018.02.005.
"""
function PlantSimEngine.run!(::Monteith, models, status, meteo, constants=PlantMeteo.Constants(), extra=nothing)

    # Initialisations
    status.Tₗ = meteo.T - 0.2
    Tₗ_new = zero(meteo.T)
    status.Cₛ = meteo.Cₐ
    status.Dₗ = PlantMeteo.e_sat(status.Tₗ) - PlantMeteo.e_sat(meteo.T) * meteo.Rh
    γˢ = Rbₕ = Δ = zero(meteo.T)
    status.Rn = status.Ra_SW_f
    iter = 0
    # ?NB: We use iter = 0 and not 1 to get the right number of iterations at the end
    # of the for loop, because we use iter += 1 at the end (so it increments once again)

    # Iterative resolution of the energy balance
    for i in 1:models.energy_balance.maxiter

        # Update A, Gₛ, Cᵢ from models.status:
        PlantSimEngine.run_call!(
            only(PlantSimEngine.call_targets(extra, :photosynthesis));
            meteo=meteo,
            publish=false,
        )

        # Stomatal resistance to water vapor
        Rsᵥ = 1.0 / (gsc_to_gsw(mol_to_ms(status.Gₛ, meteo.T, meteo.P, constants.R, constants.K₀),
            constants.Gsc_to_Gsw))

        # Re-computing the net radiation according to simulated leaf temperature:
        status.Ra_LW_f = net_longwave_radiation(status.Tₗ, meteo.T, models.energy_balance.ε, meteo.ε,
            status.sky_fraction, constants.K₀, constants.σ)
        #= ? NB: we use the sky fraction here (0-2) instead of the view factor (0-1) because:
            - we consider both sides of the leaf at the same time (1 -> leaf sees sky on one face)
            - we consider all objects in the model have the same temperature as the leaf
            of interest except the atmosphere. So the leaf exchange thermal energy_balance only with
            the atmosphere. =#
        # status.Ra_LW_f = (grey_body(meteo.T,1.0) - grey_body(status.Tₗ, 1.0))*status.sky_fraction

        status.Rn = status.Ra_SW_f + status.Ra_LW_f

        # Leaf boundary conductance for heat (m s-1), one sided:
        status.Gbₕ = gbₕ_free(meteo.T, status.Tₗ, status.d, constants.Dₕ₀) +
                     gbₕ_forced(meteo.Wind, status.d)
        # NB, in MAESPA we use Rni so we add the radiation conductance also (not here)

        # Leaf boundary resistance for heat (s m-1):
        Rbₕ = 1 / status.Gbₕ

        # Leaf boundary resistance for water vapor (s m-1):
        Rbᵥ = 1 / gbh_to_gbw(status.Gbₕ)

        # Leaf boundary conductance for CO₂ (mol[CO₂] m-2 s-1):
        status.Gbc = ms_to_mol(status.Gbₕ, meteo.T, meteo.P, constants.R, constants.K₀) /
                     constants.Gbc_to_Gbₕ

        # Update Cₛ using boundary layer conductance to CO₂ and assimilation:
        status.Cₛ = min(meteo.Cₐ, meteo.Cₐ - status.A / (status.Gbc * models.energy_balance.aₛᵥ))

        # Apparent value of psychrometer constant (kPa K−1)
        γˢ = γ_star(meteo.γ, models.energy_balance.aₛₕ, models.energy_balance.aₛᵥ, Rbᵥ, Rsᵥ, Rbₕ)

        status.λE = latent_heat(status.Rn, meteo.VPD, γˢ, Rbₕ, meteo.Δ, meteo.ρ,
            models.energy_balance.aₛₕ, constants.Cₚ)

        # If potential evaporation is needed, here is how to compute it:
        # γˢₑ = γ_star(meteo.γ, energy_balance.aₛₕ, 1, Rbᵥ, 1.0e-9, Rbₕ) # Rsᵥ is inf. low
        # Ev = latent_heat(status.Rn, meteo.VPD, γˢₑ, Rbₕ, meteo.Δ, meteo.ρ, energy_balance.aₛₕ, constants.Cₚ)

        Tₗ_new = meteo.T + (status.Rn - status.λE) /
                           (meteo.ρ * constants.Cₚ * (models.energy_balance.aₛₕ / Rbₕ))

        if abs(Tₗ_new - status.Tₗ) <= models.energy_balance.ΔT
            break
        end

        status.Tₗ = Tₗ_new

        # Vapour pressure difference between the surface and the saturation vapour pressure:
        status.Dₗ = PlantMeteo.e_sat(status.Tₗ) - PlantMeteo.e_sat(meteo.T) * meteo.Rh

        iter += 1
    end

    status.H = sensible_heat(status.Rn, meteo.VPD, γˢ, Rbₕ, meteo.Δ, meteo.ρ,
        models.energy_balance.aₛₕ, constants.Cₚ)

    status.iter = iter

    @debug begin
        if iter == models.energy_balance.maxiter
            "`run!` algorithm did not converge. Please check the value."
        end
    end

    # Transpiration (mol[H₂O] m-2 s-1):
    # ET = status.λE / meteo.λ * constants.Mₕ₂ₒ
    # ET / constants.Mₕ₂ₒ to get mm s-1 <=> kg m-2 s-1 <=> l m-2 s-1

    nothing
end

"""
    latent_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, Cₚ)
    latent_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ)

λE -the latent heat flux (W m-2)- using the Monteith and Unsworth (2013) definition corrected by
Schymanski et al. (2017), eq.22.

- `Rn` (W m-2): net radiation. Carefull: not the isothermal net radiation
- `VPD` (kPa): air vapor pressure deficit
- `γˢ` (kPa K−1): apparent value of psychrometer constant (see `PlantMeteo.γ_star`)
- `Rbₕ` (s m-1): resistance for heat transfer by convection, i.e. resistance to sensible heat
- `Δ` (KPa K-1): rate of change of saturation vapor pressure with temperature (see `PlantMeteo.e_sat_slope`)
- `ρ` (kg m-3): air density of moist air.
- `aₛₕ` (1,2): number of sides that exchange energy for heat (2 for leaves)
- `Cₚ` (J K-1 kg-1): specific heat of air for constant pressure

# References

Monteith, J. and Unsworth, M., 2013. Principles of environmental physics: plants, animals, and the atmosphere. Academic Press. See eq. 13.33.

Schymanski et al. (2017), Leaf-scale experiments reveal an important omission in the Penman–Monteith equation,
Hydrology and Earth System Sciences. DOI: https://doi.org/10.5194/hess-21-685-2017. See equ. 22.

# Examples

```julia
Tₐ = 20.0 ; P = 100.0 ;
ρ = air_density(Tₐ, P) # in kg m-3
Δ = e_sat_slope(Tₐ)

latent_heat(300.0, 2.0, 0.1461683, 50.0, Δ, ρ, 2.0)
```
"""
function latent_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, Cₚ)
    (Δ * Rn + ρ * Cₚ * VPD * (aₛₕ / Rbₕ)) / (Δ + γˢ)
end

function latent_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ)
    latent_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, PlantMeteo.Constants().Cₚ)
end


"""
    sensible_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, Cₚ)
    sensible_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ)

H -the sensible heat flux (W m-2)- using the Monteith and Unsworth (2013) definition corrected by
Schymanski et al. (2017), eq.22.

- `Rn` (W m-2): net radiation. Carefull: not the isothermal net radiation
- `VPD` (kPa): air vapor pressure deficit
- `γˢ` (kPa K−1): apparent value of psychrometer constant (see `PlantMeteo.γ_star`)
- `Rbₕ` (s m-1): resistance for heat transfer by convection, i.e. resistance to sensible heat
- `Δ` (KPa K-1): rate of change of saturation vapor pressure with temperature (see `PlantMeteo.e_sat_slope`)
- `ρ` (kg m-3): air density of moist air.
- `aₛₕ` (1,2): number of sides that exchange energy for heat (2 for leaves)
- `Cₚ` (J K-1 kg-1): specific heat of air for constant pressure

# References

Monteith, J. and Unsworth, M., 2013. Principles of environmental physics: plants, animals, and the atmosphere. Academic Press. See eq. 13.33.

Schymanski et al. (2017), Leaf-scale experiments reveal an important omission in the Penman–Monteith equation,
Hydrology and Earth System Sciences. DOI: https://doi.org/10.5194/hess-21-685-2017. See equ. 22.

# Examples

```julia
Tₐ = 20.0 ; P = 100.0 ;
ρ = air_density(Tₐ, P) # in kg m-3
Δ = PlantMeteo.e_sat_slope(Tₐ)

sensible_heat(300.0, 2.0, 0.1461683, 50.0, Δ, ρ, 2.0)
```
"""
function sensible_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, Cₚ)
    (γˢ * Rn - ρ * Cₚ * VPD * (aₛₕ / Rbₕ)) / (Δ + γˢ)
end

function sensible_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ)
    sensible_heat(Rn, VPD, γˢ, Rbₕ, Δ, ρ, aₛₕ, PlantMeteo.Constants().Cₚ)
end
