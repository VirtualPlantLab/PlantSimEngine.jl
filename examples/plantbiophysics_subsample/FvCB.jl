# Generate all methods for the photosynthesis process: several meteo time-steps, components,
#  over an MTG, and the mutating /non-mutating versions
@process "photosynthesis" verbose = false

# Default policy for assimilation rates when consumed at coarser clocks.
# An explicit scene `Inputs(...)` policy overrides this default.
PlantSimEngine.output_policy(::Type{<:AbstractPhotosynthesisModel}) = (A=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),)


"""
Farquhar–von Caemmerer–Berry (FvCB) model for C3 photosynthesis (Farquhar et al., 1980;
von Caemmerer and Farquhar, 1981) coupled with a conductance model.
"""
struct Fvcb{T} <: AbstractPhotosynthesisModel
    Tᵣ::T
    VcMaxRef::T
    JMaxRef::T
    RdRef::T
    TPURef::T
    Eₐᵣ::T
    O₂::T
    Eₐⱼ::T
    Hdⱼ::T
    Δₛⱼ::T
    Eₐᵥ::T
    Hdᵥ::T
    Δₛᵥ::T
    α::T
    θ::T
end

function Fvcb(; Tᵣ=25.0, VcMaxRef=200.0, JMaxRef=250.0, RdRef=0.6, TPURef=9999.0, Eₐᵣ=46390.0,
    O₂=210.0, Eₐⱼ=29680.0, Hdⱼ=200000.0, Δₛⱼ=631.88, Eₐᵥ=58550.0, Hdᵥ=200000.0,
    Δₛᵥ=629.26, α=0.425, θ=0.7)

    Fvcb(promote(Tᵣ, VcMaxRef, JMaxRef, RdRef, TPURef, Eₐᵣ, O₂, Eₐⱼ, Hdⱼ, Δₛⱼ, Eₐᵥ, Hdᵥ, Δₛᵥ, α, θ)...)
end

function PlantSimEngine.inputs_(::Fvcb)
    (aPPFD=-Inf, Tₗ=-Inf, Cₛ=-Inf)
end

function PlantSimEngine.outputs_(::Fvcb)
    (A=-Inf, Gₛ=-Inf, Cᵢ=-Inf)
end

Base.eltype(x::Fvcb) = typeof(x).parameters[1]

PlantSimEngine.dep(::Fvcb) = (stomatal_conductance=AbstractStomatal_ConductanceModel,)
PlantSimEngine.timestep_hint(::Type{<:Fvcb}) = (
    required=(Dates.Minute(1), Dates.Hour(6)),
    preferred=Dates.Hour(1)
)

PlantSimEngine.output_policy(::Type{<:Fvcb}) = (
    A=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()), # from μmol m-2 s-1 to μmol m-2 timerstep-1
    Cᵢ=PlantSimEngine.Integrate(PlantMeteo.MeanReducer()),
    Gₛ=PlantSimEngine.Integrate(PlantMeteo.DurationSumReducer()),
)

function arrhenius(kref, Eₐ, Tₖ, Tᵣₖ, R)
    kref * exp(Eₐ * (Tₖ - Tᵣₖ) / (R * Tₖ * Tᵣₖ))
end

function arrhenius(kref, Eₐ, Tₖ, Tᵣₖ, Hd, Δₛ, R)
    activation = arrhenius(kref, Eₐ, Tₖ, Tᵣₖ, R)
    deactivation_ref = 1.0 + exp((Tᵣₖ * Δₛ - Hd) / (R * Tᵣₖ))
    deactivation = 1.0 + exp((Tₖ * Δₛ - Hd) / (R * Tₖ))
    return activation * deactivation_ref / deactivation
end

function Γ_star(Tₖ, Tᵣₖ, R=PlantMeteo.Constants().R)
    arrhenius(oftype(Tₖ, 42.75), oftype(Tₖ, 37830.0), Tₖ, Tᵣₖ, R)
end

function get_km(Tₖ, Tᵣₖ, O₂, R=PlantMeteo.Constants().R)
    KC = arrhenius(oftype(Tₖ, 404.9), oftype(Tₖ, 79430.0), Tₖ, Tᵣₖ, R)
    KO = arrhenius(oftype(Tₖ, 278.4), oftype(Tₖ, 36380.0), Tₖ, Tᵣₖ, R)
    return KC * (1.0 + O₂ / KO)
end

function PlantSimEngine.run!(m::Fvcb, models, status, meteo, constants=PlantMeteo.Constants(), extra=nothing)

    # Tranform Celsius temperatures in Kelvin:
    Tₖ = status.Tₗ - constants.K₀
    Tᵣₖ = m.Tᵣ - constants.K₀

    # Temperature dependence of the parameters:
    Γˢ = Γ_star(Tₖ, Tᵣₖ, constants.R) # Gamma star (CO2 compensation point) in μmol mol-1
    Km = get_km(Tₖ, Tᵣₖ, m.O₂, constants.R) # effective Michaelis–Menten coefficient for CO2

    # Maximum electron transport rate at the given leaf temperature (μmol m-2 s-1):
    JMax = arrhenius(m.JMaxRef, m.Eₐⱼ, Tₖ, Tᵣₖ, m.Hdⱼ, m.Δₛⱼ, constants.R)
    # Maximum rate of Rubisco activity at the given models temperature (μmol m-2 s-1):
    VcMax = arrhenius(m.VcMaxRef, m.Eₐᵥ, Tₖ, Tᵣₖ, m.Hdᵥ, m.Δₛᵥ, constants.R)
    # Rate of mitochondrial respiration at the given leaf temperature (μmol m-2 s-1):
    Rd = arrhenius(m.RdRef, m.Eₐᵣ, Tₖ, Tᵣₖ, constants.R)
    # Rd is also described as the CO2 release in the light by processes other than the PCO
    # cycle, and termed "day" respiration, or "light respiration" (Harley et al., 1986).

    # Actual electron transport rate (considering intercepted PAR and leaf temperature):
    J = get_J(status.aPPFD, JMax, m.α, m.θ) # in μmol m-2 s-1
    # RuBP regeneration
    Vⱼ = J / 4

    # Stomatal conductance (mol[CO₂] m-2 s-1), dispatched on type of first argument (gs_closure):
    st_closure = gs_closure(models.stomatal_conductance, models, status, meteo, extra)

    Cᵢⱼ = get_Cᵢⱼ(Vⱼ, Γˢ, status.Cₛ, Rd, models.stomatal_conductance.g0, st_closure)

    # Electron-transport-limited rate of CO2 assimilation (RuBP regeneration-limited):
    Wⱼ = Vⱼ * (Cᵢⱼ - Γˢ) / (Cᵢⱼ + 2.0 * Γˢ) # also called Aⱼ
    # See Von Caemmerer, Susanna. 2000. Biochemical models of leaf photosynthesis.
    # Csiro publishing, eq. 2.23.
    # NB: here the equation is modified because we use Vⱼ instead of J, but it is the same.

    # If Rd is larger than Wⱼ, no assimilation:
    if Wⱼ - Rd < 1.0e-6
        Cᵢⱼ = Γˢ
        Wⱼ = Vⱼ * (Cᵢⱼ - Γˢ) / (Cᵢⱼ + 2.0 * Γˢ)
    end

    Cᵢᵥ = get_Cᵢᵥ(VcMax, Γˢ, status.Cₛ, Rd, models.stomatal_conductance.g0, st_closure, Km)

    # Rubisco-carboxylation-limited rate of CO₂ assimilation (RuBP activity-limited):
    if Cᵢᵥ <= 0.0 || Cᵢᵥ > status.Cₛ
        Wᵥ = 0.0
    else
        Wᵥ = VcMax * (Cᵢᵥ - Γˢ) / (Cᵢᵥ + Km)
    end

    # Net assimilation (μmol m-2 s-1)
    status.A = min(Wᵥ, Wⱼ, 3 * m.TPURef) - Rd

    # Stomatal conductance (mol[CO₂] m-2 s-1)
    PlantSimEngine.run!(models.stomatal_conductance, models, status, st_closure, extra)

    # Intercellular CO₂ concentration (Cᵢ, μmol mol)
    status.Cᵢ = min(status.Cₛ, status.Cₛ - status.A / status.Gₛ)
    nothing
end

function get_J(aPPFD, JMax, α, θ)
    (α * aPPFD + JMax - sqrt((α * aPPFD + JMax)^2 - 4 * α * θ * aPPFD * JMax)) / (2 * θ)
end

function get_Cᵢⱼ(Vⱼ, Γˢ, Cₛ, Rd, g0, st_closure)
    a = g0 + st_closure * (Vⱼ - Rd)
    b = (1.0 - Cₛ * st_closure) * (Vⱼ - Rd) + g0 * (2.0 * Γˢ - Cₛ) -
        st_closure * (Vⱼ * Γˢ + 2.0 * Γˢ * Rd)
    c = -(1.0 - Cₛ * st_closure) * Γˢ * (Vⱼ + 2.0 * Rd) -
        g0 * 2.0 * Γˢ * Cₛ

    return positive_root(a, b, c)
end

function get_Cᵢᵥ(VcMAX, Γˢ, Cₛ, Rd, g0, st_closure, Km)
    a = g0 + st_closure * (VcMAX - Rd)
    b = (1.0 - Cₛ * st_closure) * (VcMAX - Rd) + g0 * (Km - Cₛ) - st_closure * (VcMAX * Γˢ + Km * Rd)
    c = -(1.0 - Cₛ * st_closure) * (VcMAX * Γˢ + Km * Rd) - g0 * Km * Cₛ

    return positive_root(a, b, c)
end

function max_root(a, b, c)
    Δ = b^2.0 - 4.0 * a * c
    x1 = (-b + sqrt(Δ)) / (2.0 * a)
    x2 = (-b - sqrt(Δ)) / (2.0 * a)
    return max(x1, x2)
end

function positive_root(a, b, c)
    Δ = b^2.0 - 4.0 * a * c
    return Δ >= 0.0 ? (-b + sqrt(Δ)) / (2.0 * a) : 0.0
end

function negative_root(a, b, c)
    Δ = b^2.0 - 4.0 * a * c
    return Δ >= 0.0 ? (-b - sqrt(Δ)) / (2.0 * a) : 0.0
end
