using Dates
using PlantMeteo
using PlantSimEngine
using MultiScaleTreeGraph

include(joinpath(@__DIR__, "plantbiophysics_subsample", "Tuzet.jl"))
include(joinpath(@__DIR__, "plantbiophysics_subsample", "FvCB.jl"))
include(joinpath(@__DIR__, "plantbiophysics_subsample", "Monteith.jl"))

PlantSimEngine.@process "soil_water" verbose = false
PlantSimEngine.@process "scene_eb" verbose = false
PlantSimEngine.@process "leaf_state" verbose = false
PlantSimEngine.@process "lai_dynamic" verbose = false
PlantSimEngine.@process "alloc_a" verbose = false
PlantSimEngine.@process "alloc_b" verbose = false

sat_vp_kpa(T) = 0.6108 * exp(17.27 * T / (T + 237.3))
vpd_kpa(meteo) = max(0.02, sat_vp_kpa(meteo.T) * (1.0 - meteo.Rh))
rh_from_vpd(T, vpd) = clamp(1.0 - vpd / sat_vp_kpa(T), 0.05, 0.99)
duration_seconds(meteo) = Dates.value(Dates.Millisecond(meteo.duration)) / 1000.0
e_sat_kpa(T) = PlantMeteo.e_sat(T)

struct SoilWater{T} <: AbstractSoil_WaterModel
    theta_sat::T
    psi_e::T
    b::T
    depth1::T
    depth2::T
end

PlantSimEngine.inputs_(::SoilWater) = (transpiration=0.0, infiltration=0.0)
PlantSimEngine.outputs_(::SoilWater) = (theta1=0.32, theta2=0.34, psi_soil=-0.1)

function PlantSimEngine.run!(m::SoilWater, models, status, meteo, constants, extra=nothing)
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

PlantSimEngine.run!(::LeafState, models, status, meteo, constants, extra=nothing) = nothing

"""
    LAIModel(area)

Compute scene leaf area and leaf area index from all leaves routed into the
scene domain.
"""
struct LAIModel{T} <: AbstractLai_DynamicModel
    area::T
end

function LAIModel(area)
    area > 0.0 || throw(ArgumentError("`area` must be strictly positive."))
    return LAIModel(area)
end

PlantSimEngine.inputs_(::LAIModel) = (leaf_areas=[-Inf],)
PlantSimEngine.outputs_(::LAIModel) = (lai=0.0, leaf_area=-Inf)

function PlantSimEngine.run!(m::LAIModel, models, status, meteo, constants, extra=nothing)
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

PlantSimEngine.dep(::SceneEB) = (
    energy_balance=HardDomains(kind=:plant, scale=:Leaf, process=:energy_balance),
    soil=HardDomains(kind=:soil, process=:soil_water),
)
PlantSimEngine.inputs_(::SceneEB) = (lai=0.0, leaf_area=0.0)
PlantSimEngine.outputs_(::SceneEB) = (
    canopy_tair=20.0,
    canopy_vpd=1.0,
    canopy_rh=0.7,
    canopy_htot=0.0,
    canopy_gcanop=0.0,
    scene_transpiration=0.0,
    scene_assimilation=0.0,
    psi_soil=-0.1,
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

function _scene_leaf_meteo(meteo, tair_canopy, vpd_canopy)
    return Atmosphere(
        T=tair_canopy,
        Rh=rh_from_vpd(tair_canopy, vpd_canopy),
        Wind=meteo.Wind,
        P=meteo.P,
        Cₐ=meteo.Cₐ,
        Ri_PAR_f=meteo.Ri_PAR_f,
        Ri_SW_f=meteo.Ri_SW_f,
        duration=meteo.duration,
    )
end

function _prepare_scene_leaf_target!(target, meteo, tair_canopy, vpd_canopy, psi_soil)
    target.status.Ra_SW_f = meteo.Ri_SW_f
    target.status.aPPFD = meteo.Ri_PAR_f
    target.status.Ψₗ = psi_soil
    return nothing
end

function _run_scene_leaf_targets!(leaf_targets, meteo, tair_canopy, vpd_canopy, psi_soil, ground_area; publish=false)
    total_rn = 0.0
    total_lambda_e = 0.0
    total_h = 0.0
    total_a = 0.0
    local_meteo = _scene_leaf_meteo(meteo, tair_canopy, vpd_canopy)
    for target in leaf_targets
        _prepare_scene_leaf_target!(target, meteo, tair_canopy, vpd_canopy, psi_soil)
        run_target!(target; meteo=local_meteo, publish=publish) # Publish is false because we iterate here and only want to publish the final solution at the end
        leaf_area = target.status.leaf_area
        total_rn += target.status.Rn * leaf_area
        total_lambda_e += target.status.λE * leaf_area
        total_h += target.status.H * leaf_area
        total_a += target.status.A * leaf_area
    end
    return (
        rn=total_rn / ground_area,
        lambda_e=total_lambda_e / ground_area,
        h=total_h / ground_area,
        a=total_a / ground_area,
        meteo=local_meteo,
    )
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

function tvpdcanopcalc(m::SceneEB, fluxes, meteo_above, canopy_meteo, constants)
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

    vpair_above = e_sat_kpa(tair_above) - vpd_above
    vpair_canopy = vpair_above + etot * canopy_meteo.γ / heat_conductance
    vpd_new = max(0.01, e_sat_kpa(tair_new) - vpair_canopy)
    vpd_new = clamp(vpd_new, max(0.01, vpd_above - 1.5), vpd_above + 1.5)
    rh_new = clamp(1.0 - vpd_new / e_sat_kpa(tair_new), 0.0, 1.0)
    return (tair=tair_new, vpd=vpd_new, rh=rh_new, htot=htot, gcanop=gbcan_ms)
end

function _solve_scene_energy_balance!(m::SceneEB, leaf_targets, soil_target, status, meteo, constants=PlantMeteo.Constants())
    tair_above = meteo.T
    vpd_above = max(0.01, meteo.VPD)
    tair_canopy = tair_above
    vpd_canopy = vpd_above
    psi_soil = soil_target.status.psi_soil
    final_meteo = meteo
    last_update = (tair=tair_canopy, vpd=vpd_canopy, rh=meteo.Rh, htot=0.0, gcanop=0.0)

    for iter in 1:m.maxiter
        # Run the energy balance of each leaf, and aggregate the fluxes at the canopy scale:
        fluxes = _run_scene_leaf_targets!(leaf_targets, meteo, tair_canopy, vpd_canopy, psi_soil, m.ground_area)
        fluxes = merge(fluxes, (lai=status.lai, rad_interc=0.0))
        # Update the canopy-scale meteo based on the leaf fluxes, and check for convergence:
        final_meteo = fluxes.meteo
        update = tvpdcanopcalc(m, fluxes, meteo, final_meteo, constants)
        last_update = update
        if abs(update.tair - tair_canopy) < m.tol_t && abs(update.vpd - vpd_canopy) < m.tol_vpd
            tair_canopy = update.tair
            vpd_canopy = update.vpd
            return SceneEBSolverResult(
                tair_canopy,
                vpd_canopy,
                update.rh,
                psi_soil,
                _scene_leaf_meteo(meteo, tair_canopy, vpd_canopy),
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

function _publish_scene_leaf_solution!(leaf_targets, solution::SceneEBSolverResult, meteo, ground_area)
    fluxes = _run_scene_leaf_targets!(
        leaf_targets,
        meteo,
        solution.tair,
        solution.vpd,
        solution.psi_soil,
        ground_area;
        publish=true,
    )
    for target in leaf_targets
        target.status.leaf_carbon += target.status.A * target.status.leaf_area * duration_seconds(meteo) * 12.0e-6
    end
    return fluxes
end

function _run_scene_soil_feedback!(soil_target, transpiration_mm)
    soil_target.status.transpiration = transpiration_mm
    soil_target.status.infiltration = 0.0
    run_target!(soil_target; publish=true)
    return soil_target.status.psi_soil
end

function PlantSimEngine.run!(m::SceneEB, models, status, meteo, constants, extra)
    leaf_targets = dependency_targets(extra, :energy_balance)
    soil_target = only(dependency_targets(extra, :soil))
    solution = _solve_scene_energy_balance!(m, leaf_targets, soil_target, status, meteo, constants)
    fluxes = _publish_scene_leaf_solution!(leaf_targets, solution, meteo, m.ground_area)
    transpiration_mm = λE_to_E(fluxes.lambda_e, solution.final_meteo.λ) * duration_seconds(meteo) * 18.0e-6
    psi_soil = _run_scene_soil_feedback!(soil_target, transpiration_mm)

    status.canopy_tair = solution.tair
    status.canopy_vpd = solution.vpd
    status.canopy_rh = solution.rh
    status.canopy_htot = solution.htot
    status.canopy_gcanop = solution.gcanop
    status.scene_transpiration = transpiration_mm
    status.scene_assimilation = fluxes.a
    status.psi_soil = psi_soil
    status.iterations = solution.iterations
    return nothing
end

alloc_inputs() = (leaf_carbon=[0.0],)
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

PlantSimEngine.run!(m::AllocA, models, status, meteo, constants, extra=nothing) =
    allocate!(status, m.leaf_fraction, m.wood_fraction)
PlantSimEngine.run!(m::AllocB, models, status, meteo, constants, extra=nothing) =
    allocate!(status, m.leaf_fraction, m.wood_fraction)

function build_maespa_scene()
    scene = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant_a = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    plant_a[:species] = :A
    axis_a = Node(plant_a, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    for i in 1:2
        leaf = Node(axis_a, MultiScaleTreeGraph.NodeMTG("+", :Leaf, i, 3))
        leaf[:species] = :A
    end

    plant_b = Node(scene, MultiScaleTreeGraph.NodeMTG("+", :Plant, 2, 1))
    plant_b[:species] = :B
    axis_b = Node(plant_b, MultiScaleTreeGraph.NodeMTG("/", :Internode, 1, 2))
    for i in 1:3
        leaf = Node(axis_b, MultiScaleTreeGraph.NodeMTG("+", :Leaf, i, 3))
        leaf[:species] = :B
    end
    return scene
end

has_species(node, species) =
    try
        node[:species] == species
    catch
        false
    end

function maespa_mapping(; scene_model=SceneEB(25, 0.03, 0.005))
    leaf_a = (
        ModelSpec(Monteith(; ε=0.955, maxiter=20, ΔT=0.02)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Fvcb(; VcMaxRef=72.0, JMaxRef=135.0, RdRef=1.1)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Tuzet(; g0=0.015, g1=4.8, Ψᵥ=-1.4, sf=3.2, Γ=42.0)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(LeafState()) |> TimeStepModel(Dates.Hour(1)),
        Status(Ra_SW_f=0.0, sky_fraction=1.0, d=0.035, aPPFD=0.0, Ψₗ=-0.1, leaf_area=0.018, leaf_carbon=0.0),
    )
    leaf_b = (
        ModelSpec(Monteith(; ε=0.955, maxiter=20, ΔT=0.02)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Fvcb(; VcMaxRef=58.0, JMaxRef=110.0, RdRef=1.3)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Tuzet(; g0=0.012, g1=3.5, Ψᵥ=-1.1, sf=3.8, Γ=42.0)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(LeafState()) |> TimeStepModel(Dates.Hour(1)),
        Status(Ra_SW_f=0.0, sky_fraction=0.8, d=0.028, aPPFD=0.0, Ψₗ=-0.1, leaf_area=0.014, leaf_carbon=0.0),
    )

    plant_a = ModelMapping(
        :Plant => (
            ModelSpec(AllocA(0.35, 0.55)) |>
            MultiScaleModel([:leaf_carbon => [:Leaf => :leaf_carbon]]) |>
            TimeStepModel(ClockSpec(24.0, 0.0)),
            Status(leaf_pool=0.0, wood_pool=0.0),
        ),
        :Leaf => leaf_a,
    )
    plant_b = ModelMapping(
        :Plant => (
            ModelSpec(AllocB(0.55, 0.35)) |>
            MultiScaleModel([:leaf_carbon => [:Leaf => :leaf_carbon]]) |>
            TimeStepModel(ClockSpec(24.0, 0.0)),
            Status(leaf_pool=0.0, wood_pool=0.0),
        ),
        :Leaf => leaf_b,
    )
    soil = ModelMapping(
        ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75)) |> TimeStepModel(Dates.Hour(1)),
        status=(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0),
    )
    ground_area = scene_model.ground_area
    scene = ModelMapping(
        ModelSpec(LAIModel(ground_area)) |> TimeStepModel(Dates.Day(1)),
        ModelSpec(scene_model) |> TimeStepModel(Dates.Hour(1)),
        status=(
            leaf_area=0.0,
            lai=0.0,
            canopy_tair=20.0,
            canopy_vpd=1.0,
            canopy_rh=0.7,
            canopy_htot=0.0,
            canopy_gcanop=0.0,
            scene_transpiration=0.0,
            scene_assimilation=0.0,
            psi_soil=-0.1,
            iterations=0,
        ),
    )
    leaf_area_route = Route(
        from=AllDomains(kind=:plant, scale=:Leaf, process=:leaf_state, var=:leaf_area),
        to=DomainRouteTarget(:scene, var=:leaf_areas, process=:lai_dynamic),
        cardinality=ManyToOneVector(),
    )

    return SimulationMapping(
        Domain(:plant_A, plant_a; kind=:plant, selector=node -> MultiScaleTreeGraph.symbol(node) == :Plant && has_species(node, :A)),
        Domain(:plant_B, plant_b; kind=:plant, selector=node -> MultiScaleTreeGraph.symbol(node) == :Plant && has_species(node, :B)),
        Domain(:soil, soil; kind=:soil),
        Domain(:scene, scene; kind=:scene);
        routes=(leaf_area_route,),
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
    mtg = build_maespa_scene()
    mapping = maespa_mapping()
    sim = run!(mtg, mapping, maespa_meteo(; nhours=nhours), check=check, executor=SequentialEx())
    return (mtg=mtg, mapping=mapping, simulation=sim)
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_maespa_example()
    sim = result.simulation
    println("leaf_count = ", length(status(sim, :Leaf)))
    println("scene_transpiration = ", status(sim, :scene).scene_transpiration)
    println("psi_soil = ", status(sim, :scene).psi_soil)
    println("plant_A = ", only(status(sim, :plant_A, :Plant)).daily_growth)
    println("plant_B = ", only(status(sim, :plant_B, :Plant)).daily_growth)
end
