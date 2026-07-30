using Dates
using PlantMeteo
using PlantSimEngine

include(joinpath(@__DIR__, "plantbiophysics_subsample", "Tuzet.jl"))
include(joinpath(@__DIR__, "plantbiophysics_subsample", "FvCB.jl"))
include(joinpath(@__DIR__, "plantbiophysics_subsample", "Monteith.jl"))

PlantSimEngine.@process "soil_water" verbose = false
PlantSimEngine.@process "scene_eb" verbose = false
PlantSimEngine.@process "leaf_state" verbose = false
PlantSimEngine.@process "lai_dynamic" verbose = false
PlantSimEngine.@process "alloc_a" verbose = false
PlantSimEngine.@process "alloc_b" verbose = false

duration_seconds(environment) = Dates.value(Dates.Millisecond(environment.duration)) / 1000.0
mutable struct MaespaSingleLayerEnvironment{F,C} <:
               PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend
    forcing::F # MAESPA forcing data (Meteo data from above the canopy)
    canopy::C # Within-canopy computed microclimate
end

struct MaespaEnvironmentHandle
    provider::Symbol
    sink::Union{Nothing,Symbol}
end

function MaespaSingleLayerEnvironment(forcing; canopy=_maespa_meteo_row(forcing, 1))
    canopy = Atmosphere(
        T=canopy.T,
        Rh=canopy.Rh,
        Wind=canopy.Wind,
        P=canopy.P,
        Cₐ=canopy.Cₐ,
        Ri_PAR_f=canopy.Ri_PAR_f,
        Ri_SW_f=canopy.Ri_SW_f,
        duration=canopy.duration,
    )
    return MaespaSingleLayerEnvironment(
        forcing,
        canopy,
    )
end

_maespa_meteo_row(environment, time) =
    first(Iterators.drop(environment, clamp(Int(round(time)), 1, PlantSimEngine.get_nsteps(environment)) - 1))

PlantSimEngine.EnvironmentAPI.base_step_seconds(
    backend::MaespaSingleLayerEnvironment,
) = PlantSimEngine.EnvironmentAPI.base_step_seconds(
    PlantSimEngine.EnvironmentAPI.environment_backend(backend.forcing),
)
PlantSimEngine.EnvironmentAPI.get_nsteps(
    backend::MaespaSingleLayerEnvironment,
) = PlantSimEngine.EnvironmentAPI.get_nsteps(backend.forcing)
PlantSimEngine.EnvironmentAPI.environment_variables(
    ::MaespaSingleLayerEnvironment,
) = Set([
    :T, :Rh, :Wind, :P, :Cₐ, :Ri_PAR_f, :Ri_SW_f, :duration, :VPD, :ε, :γ, :Δ, :ρ, :λ,
])

function PlantSimEngine.EnvironmentAPI.bind_environment(
    backend::MaespaSingleLayerEnvironment,
    object::Object,
    context::PlantSimEngine.EnvironmentAPI.EnvironmentContext,
    config,
)
    provider = isnothing(config) ? :canopy : Symbol(config.provider)
    sink = isnothing(config) || !haskey(config, :sink) ? nothing : Symbol(config.sink)
    provider in (:forcing, :canopy) || error(
        "MAESPA single-layer environment provider must be `:forcing` or `:canopy`, got `$(provider)`."
    )
    isnothing(sink) || sink == :canopy || error(
        "MAESPA single-layer environment sink must be `:canopy`, got `$(sink)`."
    )
    return MaespaEnvironmentHandle(provider, sink)
end

function PlantSimEngine.EnvironmentAPI.sample(
    backend::MaespaSingleLayerEnvironment,
    handle::MaespaEnvironmentHandle,
    variable::Symbol,
    time,
)
    environment = handle.provider == :forcing ?
            _maespa_meteo_row(backend.forcing, time) :
            backend.canopy
    return getproperty(environment, variable)
end

function PlantSimEngine.EnvironmentAPI.sample(
    backend::MaespaSingleLayerEnvironment{F,C},
    handle::MaespaEnvironmentHandle,
    state::C,
    variable::Symbol,
    time,
) where {F,C}
    environment = handle.provider == :forcing ?
            _maespa_meteo_row(backend.forcing, time) :
            state
    return getproperty(environment, variable)
end

function PlantSimEngine.EnvironmentAPI.commit_environment!(
    backend::MaespaSingleLayerEnvironment{F,C},
    handle::MaespaEnvironmentHandle,
    state::C,
    time,
) where {F,C}
    handle.sink == :canopy || error(
        "MAESPA environment handle for provider `$(handle.provider)` has no `:canopy` commit sink."
    )
    backend.canopy = state
    return nothing
end

struct SoilWater{T} <: AbstractSoil_WaterModel
    theta_sat::T
    psi_e::T
    b::T
    depth1::T
    depth2::T
end

PlantSimEngine.inputs_(::SoilWater) = (transpiration=Required(Float64), infiltration=Required(Float64))
PlantSimEngine.outputs_(::SoilWater) = (theta1=0.32, theta2=0.34, psi_soil=-0.1)

function PlantSimEngine.run!(m::SoilWater, status, environment, constants, context)
    withdrawal = max(status.transpiration, 0.0)
    recharge = max(status.infiltration, 0.0)
    status.theta1 = clamp(status.theta1 + (recharge - 0.7 * withdrawal) / max(m.depth1 * 1000.0, 1.0), 0.04, m.theta_sat)
    status.theta2 = clamp(status.theta2 - 0.3 * withdrawal / max(m.depth2 * 1000.0, 1.0), 0.04, m.theta_sat)
    rel = clamp(status.theta1 / m.theta_sat, 0.05, 1.0)
    status.psi_soil = m.psi_e * rel^(-m.b)
    return nothing
end

struct LeafState <: AbstractLeaf_StateModel end

PlantSimEngine.inputs_(::LeafState) = NamedTuple()
PlantSimEngine.outputs_(::LeafState) = (leaf_area=0.0, leaf_carbon=0.0)

PlantSimEngine.run!(::LeafState, status, environment, constants, context) = nothing

"""
    LAIModel(area)

Compute model leaf area and leaf area index from all selected leaves.
"""
struct LAIModel{T} <: AbstractLai_DynamicModel
    area::T

    function LAIModel(area::T) where {T}
        area > 0 || throw(ArgumentError("`area` must be strictly positive."))
        new{T}(area)
    end
end

PlantSimEngine.inputs_(::LAIModel) = (leaf_areas=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::LAIModel) = (lai=0.0, leaf_area=(-Inf))

function PlantSimEngine.run!(m::LAIModel, status, environment, constants, context)
    status.leaf_area = sum(status.leaf_areas)
    status.lai = status.leaf_area / m.area
    return nothing
end

struct SceneEB{I,T} <: AbstractScene_EbModel
    maxiter::I
    tol_t::T
    tol_vpd::T
    tree_height::T
    zht::T
    zpd::T
    z0ht::T
    ground_area::T
    qc::T
    gbcan_min::T
    von_karman::T
end

function SceneEB(
    maxiter,
    tol_t,
    tol_vpd;
    tree_height=2.0,
    zht=4.0,
    zpd=0.75 * tree_height,
    z0ht=0.1 * tree_height,
    ground_area=1.0,
    qc=0.0,
    gbcan_min=0.0123,
    von_karman=0.41,
)
    ground_area > 0.0 || throw(ArgumentError("`ground_area` must be strictly positive."))
    tree_height > 0.0 || throw(ArgumentError("`tree_height` must be strictly positive."))
    zht > 0.0 || throw(ArgumentError("`zht` must be strictly positive."))
    return SceneEB(
        maxiter,
        promote(tol_t,
            tol_vpd,
            tree_height,
            zht,
            zpd,
            z0ht,
            ground_area,
            qc,
            gbcan_min,
            von_karman)...
    )
end

PlantSimEngine.inputs_(::SceneEB) = (
    lai=Required(Float64),
    leaf_area=Required(Float64),
    leaf_areas=Required(Vector{Float64}),
    leaf_carbon=Required(Vector{Float64}),
    leaf_Ra_SW_f=Required(Vector{Float64}),
    leaf_aPPFD=Required(Vector{Float64}),
    Ψₗ=Required(Vector{Float64}),
    leaf_rn=Required(Vector{Float64}),
    leaf_lambda_e=Required(Vector{Float64}),
    leaf_h=Required(Vector{Float64}),
    leaf_a=Required(Vector{Float64}),
    psi_soil=Required(Float64),
)
PlantSimEngine.environment_inputs_(::SceneEB) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    P=0.0,
    Cₐ=0.0,
    Ri_PAR_f=0.0,
    Ri_SW_f=0.0,
    duration=Dates.Hour(1),
    VPD=0.0,
    λ=0.0,
)
PlantSimEngine.environment_outputs_(::SceneEB) = (T=0.0, Rh=0.0)
PlantSimEngine.outputs_(::SceneEB) = (
    canopy_rn=0.0,
    canopy_lambda_e=0.0,
    canopy_h=0.0,
    canopy_tair=20.0,
    canopy_vpd=1.0,
    canopy_rh=0.7,
    canopy_htot=0.0,
    canopy_gcanop=0.0,
    scene_transpiration=0.0,
    scene_infiltration=0.0,
    scene_assimilation=0.0,
    iterations=0,
)

struct SceneEBSolverResult
    tair::Float64
    vpd::Float64
    rh::Float64
    psi_soil::Float64
    final_meteo
    iterations::Int
    htot::Float64
    gcanop::Float64
    lai::Float64
end

function _model_leaf_meteo(environment, tair_canopy, vpd_canopy)
    return Atmosphere(
        T=tair_canopy,
        Rh=rh_from_vpd(vpd_canopy, e_sat(tair_canopy)),
        Wind=environment.Wind,
        P=environment.P,
        Cₐ=environment.Cₐ,
        Ri_PAR_f=environment.Ri_PAR_f,
        Ri_SW_f=environment.Ri_SW_f,
        duration=environment.duration,
    )
end

function _check_leaf_vector_lengths(status, variables)
    n = length(status.leaf_areas)
    for variable in variables
        length(getproperty(status, variable)) == n ||
            throw(DimensionMismatch("`$(variable)` must have the same length as `leaf_areas`."))
    end
    return n
end

function _aggregate_model_leaf_fluxes(status, ground_area, local_meteo)
    n = _check_leaf_vector_lengths(status, (:leaf_rn, :leaf_lambda_e, :leaf_h, :leaf_a))
    total_rn = 0.0
    total_lambda_e = 0.0
    total_h = 0.0
    total_a = 0.0
    for i in 1:n
        leaf_area = status.leaf_areas[i]
        total_rn += status.leaf_rn[i] * leaf_area
        total_lambda_e += status.leaf_lambda_e[i] * leaf_area
        total_h += status.leaf_h[i] * leaf_area
        total_a += status.leaf_a[i] * leaf_area
    end
    fluxes = (
        rn=total_rn / ground_area,
        lambda_e=total_lambda_e / ground_area,
        h=total_h / ground_area,
        a=total_a / ground_area,
        environment=local_meteo,
    )
    status.canopy_rn = fluxes.rn
    status.canopy_lambda_e = fluxes.lambda_e
    status.canopy_h = fluxes.h
    status.scene_assimilation = fluxes.a
    return fluxes
end

function _prepare_model_leaf_inputs!(status, environment, psi_soil)
    # Prepare the leaf status for each leaf target, and run the energy balance for each leaf:
    status.leaf_Ra_SW_f .= environment.Ri_SW_f
    status.leaf_aPPFD .= environment.Ri_PAR_f
    status.Ψₗ .= psi_soil
    return nothing
end

function _run_model_leaf_targets!(context, status, local_meteo, meteo_above, psi_soil, ground_area; publish=false)
    _prepare_model_leaf_inputs!(status, meteo_above, psi_soil)
    run_call!(
        context,
        :energy_balance;
        environment=local_meteo,
        publish=publish,
    )
    fluxes = _aggregate_model_leaf_fluxes(status, ground_area, local_meteo)
    return fluxes
end

function _run_model_leaf_targets_from_environment!(context, status, local_meteo, meteo_above, psi_soil, ground_area; publish=false)
    _prepare_model_leaf_inputs!(status, meteo_above, psi_soil)
    run_call!(context, :energy_balance; publish=publish)
    fluxes = _aggregate_model_leaf_fluxes(status, ground_area, local_meteo)
    return fluxes
end

function gbcanms(wind, zht, tree_height; gbcan_min=0.0123, von_karman=0.41)
    zpd = 0.75 * tree_height
    z0 = 0.1 * tree_height
    zstar = max(zht, eps(Float64))
    wind2 = max(wind, 1.0e-6)

    if zstar <= tree_height
        wind2 *= exp(0.13155 * (tree_height / zstar - 1.0))
        zstar = 2.0 * tree_height
    end

    zstar = max(zstar, zpd + z0 + 1.0e-6)
    windstar = wind2 * von_karman / log((zstar - zpd) / z0)
    alpha1 = 1.5
    zw = zpd + alpha1 * (tree_height - zpd)
    gbcanmsini = windstar * von_karman / log((zstar - zpd) / (zw - zpd))
    gbcanmsrou = windstar * von_karman / ((zw - tree_height) / (zw - zpd))
    canopy_air_ms = max(1.0 / (1.0 / gbcanmsini + 1.0 / gbcanmsrou), gbcan_min)

    alpha = 2.0
    z0ht2 = 0.01
    kh = alpha1 * von_karman * windstar * (tree_height - zpd)
    soil_denominator = tree_height * exp(alpha) *
                       (exp(-alpha * z0ht2 / tree_height) - exp(-alpha * (zpd + z0) / tree_height))
    soil_canopy_ms = max(alpha * kh / soil_denominator, 0.0)
    return (canopy_air_ms=canopy_air_ms, soil_canopy_ms=soil_canopy_ms)
end

function canopy_air_update(m::SceneEB, fluxes, meteo_above, canopy_meteo, constants)
    gbs = gbcanms(
        meteo_above.Wind,
        m.zht,
        m.tree_height;
        gbcan_min=m.gbcan_min,
        von_karman=m.von_karman,
    )
    gbcan_ms = gbs.canopy_air_ms
    tair_above = meteo_above.T
    vpd_above = max(0.01, meteo_above.VPD)
    qn = fluxes.rn
    qe = fluxes.lambda_e
    rad_interc = get(fluxes, :rad_interc, 0.0)
    rnettot = qn + rad_interc
    etot = qe
    htot = rnettot - etot - m.qc
    heat_conductance = constants.Cₚ * canopy_meteo.ρ * gbcan_ms

    tair_new = tair_above + htot / heat_conductance
    tair_new = clamp(tair_new, tair_above - 10.0, tair_above + 10.0)

    vpair_above = PlantMeteo.e_sat(tair_above) - vpd_above
    vpair_canopy = vpair_above + etot * canopy_meteo.γ / heat_conductance
    vpd_new = max(0.01, PlantMeteo.e_sat(tair_new) - vpair_canopy)
    vpd_new = clamp(vpd_new, max(0.01, vpd_above - 1.5), vpd_above + 1.5)
    environment = _model_leaf_meteo(meteo_above, tair_new, vpd_new)
    return (environment=environment, tair=tair_new, vpd=vpd_new, rh=environment.Rh, htot=htot, gcanop=gbcan_ms)
end

function _solve_model_energy_balance!(
    m::SceneEB,
    context,
    status,
    environment,
    constants=PlantMeteo.Constants(),
)
    tair_above = environment.T
    vpd_above = max(0.01, environment.VPD)
    tair_canopy = tair_above
    vpd_canopy = vpd_above
    psi_soil = status.psi_soil
    final_meteo = environment
    last_update = (tair=tair_canopy, vpd=vpd_canopy, rh=environment.Rh, htot=0.0, gcanop=0.0)

    for iter in 1:m.maxiter
        # Run the energy balance of each leaf, and aggregate the fluxes at the canopy scale:
        trial_meteo = _model_leaf_meteo(environment, tair_canopy, vpd_canopy)
        fluxes = _run_model_leaf_targets!(context, status, trial_meteo, environment, psi_soil, m.ground_area)
        # Update the canopy-scale environment based on the leaf fluxes, and check for convergence:
        final_meteo = fluxes.environment
        update = canopy_air_update(m, fluxes, environment, trial_meteo, constants)
        status.canopy_tair = update.tair
        status.canopy_vpd = update.vpd
        status.canopy_rh = update.rh
        status.canopy_htot = update.htot
        status.canopy_gcanop = update.gcanop
        last_update = update
        if abs(update.tair - tair_canopy) < m.tol_t && abs(update.vpd - vpd_canopy) < m.tol_vpd
            tair_canopy = update.tair
            vpd_canopy = update.vpd
            return SceneEBSolverResult(
                tair_canopy,
                vpd_canopy,
                update.rh,
                psi_soil,
                update.environment,
                iter,
                update.htot,
                update.gcanop,
                status.lai,
            )
        end
        tair_canopy = 0.5 * (tair_canopy + update.tair) # take the average to help convergence
        vpd_canopy = 0.5 * (vpd_canopy + update.vpd)
    end

    error(
        "SceneEB did not converge after $(m.maxiter) iterations ",
        "(tol_t=$(m.tol_t), tol_vpd=$(m.tol_vpd), ",
        "last_tair=$(last_update.tair), last_vpd=$(last_update.vpd))."
    )
end

function _publish_model_leaf_solution!(context, status, solution::SceneEBSolverResult, environment, ground_area)
    commit_environment!(context, solution.final_meteo)
    fluxes = _run_model_leaf_targets_from_environment!(
        context,
        status,
        solution.final_meteo,
        environment,
        solution.psi_soil,
        ground_area;
        publish=true,
    )
    n = _check_leaf_vector_lengths(status, (:leaf_carbon, :leaf_a))
    for i in 1:n
        status.leaf_carbon[i] += status.leaf_a[i] * status.leaf_areas[i] * duration_seconds(environment) * 12.0e-6
    end
    return fluxes
end

function PlantSimEngine.run!(m::SceneEB, status, environment, constants, context)
    solution = _solve_model_energy_balance!(m, context, status, environment, constants)
    fluxes = _publish_model_leaf_solution!(context, status, solution, environment, m.ground_area)
    transpiration_mm = λE_to_E(fluxes.lambda_e, solution.final_meteo.λ) * duration_seconds(environment) * 18.0e-6

    status.canopy_tair = solution.tair
    status.canopy_vpd = solution.vpd
    status.canopy_rh = solution.rh
    status.canopy_htot = solution.htot
    status.canopy_gcanop = solution.gcanop
    status.scene_transpiration = transpiration_mm
    status.scene_infiltration = 0.0
    status.scene_assimilation = fluxes.a
    status.iterations = solution.iterations
    run_call!(context, :soil; publish=true)
    return nothing
end

alloc_inputs() = (leaf_carbon=Required(Vector{Float64}),)
alloc_outputs() = (daily_growth=0.0, leaf_pool=0.0, wood_pool=0.0)

function allocate!(status, leaf_fraction, wood_fraction)
    carbon = sum(status.leaf_carbon)
    status.daily_growth = carbon
    status.leaf_pool += leaf_fraction * carbon
    status.wood_pool += wood_fraction * carbon
    return nothing
end

struct AllocA <: AbstractAlloc_AModel
    leaf_fraction::Float64
    wood_fraction::Float64
end

struct AllocB <: AbstractAlloc_BModel
    leaf_fraction::Float64
    wood_fraction::Float64
end

PlantSimEngine.inputs_(::AllocA) = alloc_inputs()
PlantSimEngine.outputs_(::AllocA) = alloc_outputs()
PlantSimEngine.inputs_(::AllocB) = alloc_inputs()
PlantSimEngine.outputs_(::AllocB) = alloc_outputs()

PlantSimEngine.run!(m::AllocA, status, environment, constants, context) =
    allocate!(status, m.leaf_fraction, m.wood_fraction)
PlantSimEngine.run!(m::AllocB, status, environment, constants, context) =
    allocate!(status, m.leaf_fraction, m.wood_fraction)

function _maespa_leaf_status(; leaf_area, sky_fraction, d)
    return Status(
        Ra_SW_f=0.0,
        sky_fraction=sky_fraction,
        d=d,
        aPPFD=0.0,
        Ψₗ=-0.1,
        leaf_area=leaf_area,
        leaf_carbon=0.0,
        Tₗ=20.0,
        Rn=0.0,
        Ra_LW_f=0.0,
        H=0.0,
        λE=0.0,
        Cₛ=400.0,
        Cᵢ=300.0,
        A=0.0,
        Gₛ=0.0,
        Gbₕ=0.0,
        Dₗ=0.0,
        Gbc=0.0,
        iter=0,
    )
end

_maespa_plant_status() = Status(leaf_carbon=[0.0], daily_growth=0.0, leaf_pool=0.0, wood_pool=0.0)

function _maespa_model_status()
    return Status(
        leaf_areas=[0.0],
        leaf_carbon=[0.0],
        leaf_Ra_SW_f=[0.0],
        leaf_aPPFD=[0.0],
        Ψₗ=[-0.1],
        leaf_rn=[0.0],
        leaf_lambda_e=[0.0],
        leaf_h=[0.0],
        leaf_a=[0.0],
        canopy_rn=0.0,
        canopy_lambda_e=0.0,
        canopy_h=0.0,
        leaf_area=0.0,
        lai=0.0,
        canopy_tair=20.0,
        canopy_vpd=1.0,
        canopy_rh=0.7,
        canopy_htot=0.0,
        canopy_gcanop=0.0,
        scene_transpiration=0.0,
        scene_infiltration=0.0,
        scene_assimilation=0.0,
        psi_soil=-0.1,
        iterations=0,
    )
end

function _maespa_soil_status()
    return Status(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0)
end

function _maespa_species_template(species; monteith, fvcb, tuzet, allocation)
    return CompositeModelTemplate(
        (
            ModelSpec(monteith; name=:energy_balance, on=Many(scale=:Leaf), calls=(:photosynthesis => One(scale=:Leaf, application=:photosynthesis)), environment=Environment(provider=:canopy), every=Dates.Hour(1)),
            ModelSpec(fvcb; name=:photosynthesis, on=Many(scale=:Leaf), calls=(:stomatal_conductance => One(scale=:Leaf, application=:stomatal_conductance)), every=Dates.Hour(1)),
            ModelSpec(tuzet; name=:stomatal_conductance, on=Many(scale=:Leaf), every=Dates.Hour(1)),
            ModelSpec(LeafState(); name=:leaf_state, on=Many(scale=:Leaf), every=Dates.Hour(1)),
            ModelSpec(allocation; name=:allocation, on=One(scale=:Plant), inputs=(:leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)), every=Dates.Day(1)),
        );
        kind=:plant,
        species=species,
    )
end

function _maespa_plant_instance(name, template; nleaves, leaf_area, sky_fraction, d)
    plant_id = Symbol(name)
    axis_id = Symbol(name, "_axis")
    leaves = ntuple(nleaves) do index
        Object(
            Symbol(name, "_leaf_", index);
            scale=:Leaf,
            parent=axis_id,
            status=_maespa_leaf_status(; leaf_area=leaf_area, sky_fraction=sky_fraction, d=d),
        )
    end
    return ObjectInstance(
        name,
        template;
        root=Object(plant_id; scale=:Plant, parent=:model, status=_maespa_plant_status()),
        objects=(
            Object(Symbol(name, "_axis"); scale=:Internode, parent=plant_id),
            leaves...,
        ),
    )
end

function build_maespa_model(; scene_model=SceneEB(25, 0.03, 0.005), environment=maespa_meteo())
    environment = environment isa MaespaSingleLayerEnvironment ? environment : MaespaSingleLayerEnvironment(environment)
    template_a = _maespa_species_template(
        :A;
        monteith=Monteith(; ε=0.955, maxiter=20, ΔT=0.02),
        fvcb=Fvcb(; VcMaxRef=72.0, JMaxRef=135.0, RdRef=1.1),
        tuzet=Tuzet(; g0=0.015, g1=4.8, Ψᵥ=-1.4, sf=3.2, Γ=42.0),
        allocation=AllocA(0.35, 0.55),
    )
    template_b = _maespa_species_template(
        :B;
        monteith=Monteith(; ε=0.955, maxiter=20, ΔT=0.02),
        fvcb=Fvcb(; VcMaxRef=58.0, JMaxRef=110.0, RdRef=1.3),
        tuzet=Tuzet(; g0=0.012, g1=3.5, Ψᵥ=-1.1, sf=3.8, Γ=42.0),
        allocation=AllocB(0.55, 0.35),
    )
    ground_area = scene_model.ground_area
    return CompositeModel(
        Object(:model; scale=:Scene, kind=:model, status=_maespa_model_status()),
        Object(:soil; scale=:Soil, kind=:soil, parent=:model, status=_maespa_soil_status()),
        _maespa_plant_instance(
            :plant_A,
            template_a;
            nleaves=2,
            leaf_area=0.018,
            sky_fraction=1.0,
            d=0.035,
        ),
        _maespa_plant_instance(
            :plant_B,
            template_b;
            nleaves=3,
            leaf_area=0.014,
            sky_fraction=0.8,
            d=0.028,
        );
        applications=(
            ModelSpec(LAIModel(ground_area); name=:lai_dynamic, on=One(scale=:Scene), inputs=(:leaf_areas => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    process=:leaf_state,
                    var=:leaf_area,
                ),), every=Dates.Day(1)),
            ModelSpec(scene_model; name=:scene_eb, on=One(scale=:Scene), inputs=(:leaf_areas => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    process=:leaf_state,
                    var=:leaf_area,
                ),
                :leaf_carbon => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    process=:leaf_state,
                    var=:leaf_carbon,
                ),
                :leaf_Ra_SW_f => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    var=:Ra_SW_f,
                ),
                :leaf_aPPFD => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    var=:aPPFD,
                ),
                :Ψₗ => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    var=:Ψₗ,
                ),
                :leaf_rn => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    policy=HoldLast(),
                    var=:Rn,
                ),
                :leaf_lambda_e => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    policy=HoldLast(),
                    var=:λE,
                ),
                :leaf_h => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    policy=HoldLast(),
                    var=:H,
                ),
                :leaf_a => Many(
                    kind=:plant,
                    scale=:Leaf,
                    within=SceneScope(),
                    policy=HoldLast(),
                    var=:A,
                ),
                :psi_soil => One(
                    kind=:soil,
                    scale=:Soil,
                    application=:soil_water,
                    var=:psi_soil,
                ),), calls=(:energy_balance => Many(kind=:plant, scale=:Leaf, process=:energy_balance),
                :soil => One(kind=:soil, scale=:Soil, application=:soil_water),), environment=Environment(provider=:forcing, sink=:canopy), every=Dates.Hour(1)),
            ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75); name=:soil_water, on=One(kind=:soil, scale=:Soil), inputs=(:transpiration => One(
                    scale=:Scene,
                    within=SceneScope(),
                    application=:scene_eb,
                    var=:scene_transpiration,
                ),
                :infiltration => One(
                    scale=:Scene,
                    within=SceneScope(),
                    application=:scene_eb,
                    var=:scene_infiltration,
                ),), every=Dates.Hour(1)),
        ),
        environment=environment,
    )
end

function maespa_meteo(; nhours=24)
    return Weather([
        Atmosphere(
            T=22.0 + 5.0 * sinpi((hour - 7) / 12),
            Rh=clamp(0.72 - 0.22 * sinpi((hour - 7) / 12), 0.35, 0.90),
            Wind=1.2 + 0.3 * sinpi(hour / 12),
            Ri_PAR_f=max(0.0, 900.0 * sinpi((hour - 6) / 12)),
            Ri_SW_f=max(0.0, 450.0 * sinpi((hour - 6) / 12)),
            duration=Dates.Hour(1),
        )
        for hour in 1:nhours
    ])
end

function run_maespa_example(; nhours=24, check=true)
    model = build_maespa_model(; environment=maespa_meteo(; nhours=nhours))
    compiled = Advanced.compile_composite_model(model)
    check && Advanced.refresh_environment_bindings!(model, compiled)
    simulation = run!(
        model;
        steps=nhours,
        constants=PlantMeteo.Constants(),
        outputs=:all,
    )
    return (
        model=model,
        compiled=simulation.compiled,
        environment=simulation.environment_bindings,
        simulation=simulation,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_maespa_example()
    model = result.model
    println("leaf_count = ", length(model_objects(model; scale=:Leaf)))
    println(
        "scene_transpiration = ",
        only(model_objects(model; scale=:Scene)).status.scene_transpiration,
    )
    println("psi_soil = ", only(model_objects(model; kind=:soil)).status.psi_soil)
    println("plant_A = ", only(model_objects(model; name=:plant_A)).status.daily_growth)
    println("plant_B = ", only(model_objects(model; name=:plant_B)).status.daily_growth)
end
