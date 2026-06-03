using Dates
using PlantMeteo
using PlantSimEngine
using MultiScaleTreeGraph

PlantSimEngine.@process "tuzet" verbose = false
PlantSimEngine.@process "fvcb" verbose = false
PlantSimEngine.@process "leaf_eb" verbose = false
PlantSimEngine.@process "soil_water" verbose = false
PlantSimEngine.@process "scene_eb" verbose = false
PlantSimEngine.@process "alloc_a" verbose = false
PlantSimEngine.@process "alloc_b" verbose = false

sat_vp_kpa(T) = 0.6108 * exp(17.27 * T / (T + 237.3))
vpd_kpa(meteo) = max(0.02, sat_vp_kpa(meteo.T) * (1.0 - meteo.Rh))
rh_from_vpd(T, vpd) = clamp(1.0 - vpd / sat_vp_kpa(T), 0.05, 0.99)
duration_seconds(meteo) = Dates.value(Dates.Millisecond(meteo.duration)) / 1000.0

struct Tuzet <: AbstractTuzetModel
    sf::Float64
    psi50::Float64
    g1::Float64
end

PlantSimEngine.inputs_(::Tuzet) = (psi_leaf=-0.5,)
PlantSimEngine.outputs_(::Tuzet) = (fpsi=1.0, g1_eff=4.0)

function PlantSimEngine.run!(m::Tuzet, models, status, meteo, constants, extra=nothing)
    status.fpsi = clamp((1.0 + exp(m.sf * m.psi50)) / (1.0 + exp(m.sf * (m.psi50 - status.psi_leaf))), 0.0, 1.0)
    status.g1_eff = m.g1 * status.fpsi
    return nothing
end

struct FvCB <: AbstractFvcbModel
    Vcmax::Float64
    Jmax::Float64
    Rd::Float64
    gamma_star::Float64
    Kc::Float64
    g0::Float64
end

PlantSimEngine.dep(::FvCB) = (tuzet=AbstractTuzetModel,)
PlantSimEngine.inputs_(::FvCB) = (apar=0.0, Cs=400.0, Tleaf=20.0, psi_leaf=-0.5)
PlantSimEngine.outputs_(::FvCB) = (An=0.0, gs=0.02, fpsi=1.0)

function PlantSimEngine.run!(m::FvCB, models, status, meteo, constants, extra=nothing)
    run_target!(models, status, :tuzet; meteo=meteo, constants=constants, extra=extra)
    temp_factor = exp(0.06 * (status.Tleaf - 25.0))
    vcmax = m.Vcmax * temp_factor
    j = m.Jmax * status.apar / (status.apar + 2.1 * m.Jmax + eps())
    wc = vcmax * max(status.Cs - m.gamma_star, 0.0) / (status.Cs + m.Kc)
    wj = j * max(status.Cs - m.gamma_star, 0.0) / (4.0 * (status.Cs + 2.0 * m.gamma_star))
    status.An = max(0.0, min(wc, wj) - m.Rd)
    status.gs = max(m.g0, m.g0 + status.g1_eff * status.An / max(status.Cs, 80.0))
    return nothing
end

struct LeafEB <: AbstractLeaf_EbModel
    absorptance::Float64
    emissive_loss::Float64
    maxiter::Int
    tol::Float64
end

PlantSimEngine.dep(::LeafEB) = (fvcb=AbstractFvcbModel,)
PlantSimEngine.inputs_(::LeafEB) = (
    Tair=20.0,
    VPD=1.0,
    wind=1.0,
    par=600.0,
    psi_soil=-0.2,
    Kplant=6.0,
    leaf_area=0.015,
)
PlantSimEngine.outputs_(::LeafEB) = (
    apar=0.0,
    Tleaf=20.0,
    Cs=400.0,
    Dl=1.0,
    E=0.0,
    H=0.0,
    Rn=0.0,
    An=0.0,
    gs=0.02,
    fpsi=1.0,
    psi_leaf=-0.2,
    leaf_carbon=0.0,
)

function PlantSimEngine.run!(m::LeafEB, models, status, meteo, constants, extra=nothing)
    Tleaf = isfinite(status.Tleaf) ? status.Tleaf : status.Tair
    E = max(status.E, 0.0)
    for _ in 1:m.maxiter
        status.Tleaf = Tleaf
        status.psi_leaf = status.psi_soil - E / max(status.Kplant, 1.0e-6)
        status.apar = m.absorptance * status.par
        status.Dl = max(0.02, status.VPD * sat_vp_kpa(Tleaf) / sat_vp_kpa(status.Tair))
        status.Cs = clamp(400.0 - 1.6 * status.An / max(status.gs, 0.02), 120.0, 420.0)
        run_target!(models, status, :fvcb; meteo=meteo, constants=constants, extra=extra)

        gb = 0.12 + 0.08 * sqrt(max(status.wind, 0.05))
        status.Rn = m.absorptance * 0.48 * status.par - m.emissive_loss * (Tleaf - status.Tair)
        E = max(0.0, 0.20 * status.gs * status.Dl)
        lambdaE = 44.0 * E
        status.H = 22.0 * gb * (Tleaf - status.Tair)
        Tnew = status.Tair + (status.Rn - lambdaE) / max(22.0 * gb + 4.0, 1.0)
        abs(Tnew - Tleaf) < m.tol && (Tleaf = Tnew; break)
        Tleaf = 0.55 * Tleaf + 0.45 * Tnew
    end
    status.Tleaf = Tleaf
    status.E = E
    return nothing
end

struct SoilWater <: AbstractSoil_WaterModel
    theta_sat::Float64
    psi_e::Float64
    b::Float64
    depth1::Float64
    depth2::Float64
    use_second_layer::Bool
end

PlantSimEngine.inputs_(::SoilWater) = (transpiration=0.0, infiltration=0.0)
PlantSimEngine.outputs_(::SoilWater) = (theta1=0.32, theta2=0.34, psi_soil=-0.1)

function PlantSimEngine.run!(m::SoilWater, models, status, meteo, constants, extra=nothing)
    withdrawal = max(status.transpiration, 0.0)
    recharge = max(status.infiltration, 0.0)
    status.theta1 = clamp(status.theta1 + (recharge - 0.7 * withdrawal) / max(m.depth1 * 1000.0, 1.0), 0.04, m.theta_sat)
    if m.use_second_layer
        status.theta2 = clamp(status.theta2 - 0.3 * withdrawal / max(m.depth2 * 1000.0, 1.0), 0.04, m.theta_sat)
    end
    rel = clamp(status.theta1 / m.theta_sat, 0.05, 1.0)
    status.psi_soil = m.psi_e * rel^(-m.b)
    return nothing
end

struct SceneEB <: AbstractScene_EbModel
    maxiter::Int
    tol_T::Float64
    tol_VPD::Float64
end

PlantSimEngine.dep(::SceneEB) = (
    leaf_eb=HardDomains(kind=:plant, scale=:Leaf, process=:leaf_eb),
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

function PlantSimEngine.run!(m::SceneEB, models, status, meteo, constants, extra)
    leaf_targets = dependency_targets(extra, :leaf_eb)
    soil_target = only(dependency_targets(extra, :soil))
    Tair = meteo.T
    VPD = vpd_kpa(meteo)
    psi_soil = soil_target.status.psi_soil
    final_meteo = meteo

    for iter in 1:m.maxiter
        total_H = 0.0
        total_E = 0.0
        total_A = 0.0
        local_meteo = Atmosphere(
            T=Tair,
            Rh=rh_from_vpd(Tair, VPD),
            Wind=meteo.Wind,
            Ri_PAR_f=meteo.Ri_PAR_f,
            duration=meteo.duration,
        )
        for target in leaf_targets
            target.status.Tair = Tair
            target.status.VPD = VPD
            target.status.wind = meteo.Wind
            target.status.par = meteo.Ri_PAR_f
            target.status.psi_soil = psi_soil
            run_target!(target; meteo=local_meteo)
            total_H += target.status.H * target.status.leaf_area
            total_E += target.status.E * target.status.leaf_area
            total_A += target.status.An * target.status.leaf_area
        end

        Tnew = meteo.T + 0.30 * total_H / max(length(leaf_targets), 1)
        VPDnew = max(0.02, vpd_kpa(meteo) + 0.04 * (Tnew - meteo.T) - 0.30 * total_E)
        status.iterations = iter
        final_meteo = local_meteo
        if abs(Tnew - Tair) < m.tol_T && abs(VPDnew - VPD) < m.tol_VPD
            Tair = Tnew
            VPD = VPDnew
            break
        end
        Tair = 0.50 * Tair + 0.50 * Tnew
        VPD = 0.50 * VPD + 0.50 * VPDnew
    end

    total_E = 0.0
    total_A = 0.0
    for target in leaf_targets
        target.status.Tair = Tair
        target.status.VPD = VPD
        target.status.psi_soil = psi_soil
        run_target!(target; meteo=final_meteo, publish=true)
        target.status.leaf_carbon += target.status.An * target.status.leaf_area * duration_seconds(meteo) * 12.0e-6
        total_E += target.status.E * target.status.leaf_area
        total_A += target.status.An * target.status.leaf_area
    end

    transpiration_mm = total_E * duration_seconds(meteo) * 18.0e-6
    soil_target.status.transpiration = transpiration_mm
    soil_target.status.infiltration = 0.0
    run_target!(soil_target; publish=true)

    status.canopy_Tair = Tair
    status.canopy_VPD = VPD
    status.scene_transpiration = transpiration_mm
    status.scene_assimilation = total_A
    status.psi_soil = soil_target.status.psi_soil
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

has_species(node, species) = try
    node[:species] == species
catch
    false
end

function maespa_mapping()
    leaf_a = (
        ModelSpec(LeafEB(0.86, 4.5, 20, 0.02)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(FvCB(72.0, 135.0, 1.1, 42.0, 404.0, 0.015)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Tuzet(3.2, -1.4, 4.8)) |> TimeStepModel(Dates.Hour(1)),
        Status(Tair=20.0, VPD=1.0, wind=1.0, par=0.0, psi_soil=-0.1, Kplant=7.5, leaf_area=0.018, leaf_carbon=0.0),
    )
    leaf_b = (
        ModelSpec(LeafEB(0.82, 4.0, 20, 0.02)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(FvCB(58.0, 110.0, 1.3, 42.0, 404.0, 0.012)) |> TimeStepModel(Dates.Hour(1)),
        ModelSpec(Tuzet(3.8, -1.1, 3.5)) |> TimeStepModel(Dates.Hour(1)),
        Status(Tair=20.0, VPD=1.0, wind=1.0, par=0.0, psi_soil=-0.1, Kplant=5.2, leaf_area=0.014, leaf_carbon=0.0),
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
        ModelSpec(SoilWater(0.45, -0.03, 4.4, 0.25, 0.75, true)) |> TimeStepModel(Dates.Hour(1)),
        status=(theta1=0.33, theta2=0.36, psi_soil=-0.10, transpiration=0.0, infiltration=0.0),
    )
    scene = ModelMapping(
        ModelSpec(SceneEB(25, 0.03, 0.005)) |> TimeStepModel(Dates.Hour(1)),
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
