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
PlantSimEngine.@process "alloc_a" verbose = false
PlantSimEngine.@process "alloc_b" verbose = false

sat_vp_kpa(T) = 0.6108 * exp(17.27 * T / (T + 237.3))
vpd_kpa(meteo) = max(0.02, sat_vp_kpa(meteo.T) * (1.0 - meteo.Rh))
rh_from_vpd(T, vpd) = clamp(1.0 - vpd / sat_vp_kpa(T), 0.05, 0.99)
duration_seconds(meteo) = Dates.value(Dates.Millisecond(meteo.duration)) / 1000.0

struct SoilWater <: AbstractSoil_WaterModel
    theta_sat::Float64
    psi_e::Float64
    b::Float64
    depth1::Float64
    depth2::Float64
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

struct SceneEB <: AbstractScene_EbModel
    maxiter::Int
    tol_T::Float64
    tol_VPD::Float64
end

PlantSimEngine.dep(::SceneEB) = (
    energy_balance=HardDomains(kind=:plant, scale=:Leaf, process=:energy_balance),
    soil=HardDomains(kind=:soil, process=:soil_water),
)
PlantSimEngine.inputs_(::SceneEB) = NamedTuple()
PlantSimEngine.outputs_(::SceneEB) = (
    canopy_Tair=20.0,
    canopy_VPD=1.0,
    scene_transpiration=0.0,
    scene_assimilation=0.0,
    psi_soil=-0.1,
    iterations=0,
)

struct SceneEBSolverResult
    Tair::Float64
    VPD::Float64
    psi_soil::Float64
    final_meteo
    iterations::Int
end

function _scene_leaf_meteo(meteo, Tair, VPD)
    return Atmosphere(
        T=Tair,
        Rh=rh_from_vpd(Tair, VPD),
        Wind=meteo.Wind,
        P=meteo.P,
        Cₐ=meteo.Cₐ,
        Ri_PAR_f=meteo.Ri_PAR_f,
        Ri_SW_f=meteo.Ri_SW_f,
        duration=meteo.duration,
    )
end

function _prepare_scene_leaf_target!(target, meteo, Tair, VPD, psi_soil)
    target.status.Ra_SW_f = meteo.Ri_SW_f
    target.status.aPPFD = meteo.Ri_PAR_f
    target.status.Ψₗ = psi_soil
    return nothing
end

function _run_scene_leaf_targets!(leaf_targets, meteo, Tair, VPD, psi_soil; publish=false)
    total_H = 0.0
    total_E = 0.0
    total_A = 0.0
    local_meteo = _scene_leaf_meteo(meteo, Tair, VPD)
    for target in leaf_targets
        _prepare_scene_leaf_target!(target, meteo, Tair, VPD, psi_soil)
        run_target!(target; meteo=local_meteo, publish=publish)
        total_H += target.status.H * target.status.leaf_area
        total_E += λE_to_E(target.status.λE, local_meteo.λ) * target.status.leaf_area
        total_A += target.status.A * target.status.leaf_area
    end
    return (H=total_H, E=total_E, A=total_A, meteo=local_meteo)
end

function _solve_scene_energy_balance!(m::SceneEB, leaf_targets, soil_target, meteo)
    Tair = meteo.T
    VPD = vpd_kpa(meteo)
    psi_soil = soil_target.status.psi_soil
    final_meteo = meteo

    for iter in 1:m.maxiter
        fluxes = _run_scene_leaf_targets!(leaf_targets, meteo, Tair, VPD, psi_soil)
        Tnew = meteo.T + 0.30 * fluxes.H / max(length(leaf_targets), 1)
        VPDnew = max(0.02, vpd_kpa(meteo) + 0.04 * (Tnew - meteo.T) - 0.30 * fluxes.E)
        final_meteo = fluxes.meteo
        if abs(Tnew - Tair) < m.tol_T && abs(VPDnew - VPD) < m.tol_VPD
            Tair = Tnew
            VPD = VPDnew
            return SceneEBSolverResult(Tair, VPD, psi_soil, _scene_leaf_meteo(meteo, Tair, VPD), iter)
        end
        Tair = 0.50 * Tair + 0.50 * Tnew
        VPD = 0.50 * VPD + 0.50 * VPDnew
    end

    error(
        "SceneEB did not converge after $(m.maxiter) iterations ",
        "(tol_T=$(m.tol_T), tol_VPD=$(m.tol_VPD))."
    )
end

function _publish_scene_leaf_solution!(leaf_targets, solution::SceneEBSolverResult, meteo)
    fluxes = _run_scene_leaf_targets!(
        leaf_targets,
        meteo,
        solution.Tair,
        solution.VPD,
        solution.psi_soil;
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
    solution = _solve_scene_energy_balance!(m, leaf_targets, soil_target, meteo)
    fluxes = _publish_scene_leaf_solution!(leaf_targets, solution, meteo)
    transpiration_mm = fluxes.E * duration_seconds(meteo) * 18.0e-6
    psi_soil = _run_scene_soil_feedback!(soil_target, transpiration_mm)

    status.canopy_Tair = solution.Tair
    status.canopy_VPD = solution.VPD
    status.scene_transpiration = transpiration_mm
    status.scene_assimilation = fluxes.A
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
    scene = ModelMapping(
        ModelSpec(scene_model) |> TimeStepModel(Dates.Hour(1)),
        status=(canopy_Tair=20.0, canopy_VPD=1.0, scene_transpiration=0.0, scene_assimilation=0.0, psi_soil=-0.1, iterations=0),
    )

    return SimulationMapping(
        Domain(:plant_A, plant_a; kind=:plant, selector=node -> MultiScaleTreeGraph.symbol(node) == :Plant && has_species(node, :A)),
        Domain(:plant_B, plant_b; kind=:plant, selector=node -> MultiScaleTreeGraph.symbol(node) == :Plant && has_species(node, :B)),
        Domain(:soil, soil; kind=:soil),
        Domain(:scene, scene; kind=:scene),
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
