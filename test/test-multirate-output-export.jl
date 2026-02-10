using PlantSimEngine
using MultiScaleTreeGraph
using PlantMeteo
using DataFrames
using Test

PlantSimEngine.@process "mrexportsource" verbose = false
struct MRExportSourceModel <: AbstractMrexportsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRExportSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRExportSourceModel) = (X=-Inf,)
function PlantSimEngine.run!(m::MRExportSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.X = float(m.n[])
end

PlantSimEngine.@process "mrdefaultleafsource" verbose = false
struct MRDefaultLeafSourceModel <: AbstractMrdefaultleafsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRDefaultLeafSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRDefaultLeafSourceModel) = (X=-Inf,)
function PlantSimEngine.run!(m::MRDefaultLeafSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.X = float(m.n[])
end

PlantSimEngine.@process "mrdefaultplantagg" verbose = false
struct MRDefaultPlantAggModel <: AbstractMrdefaultplantaggModel end
PlantSimEngine.inputs_(::MRDefaultPlantAggModel) = (X=-Inf,)
PlantSimEngine.outputs_(::MRDefaultPlantAggModel) = (XP=-Inf,)
function PlantSimEngine.run!(::MRDefaultPlantAggModel, models, status, meteo, constants=nothing, extra=nothing)
    status.XP = sum(status.X) + 100.0
end
PlantSimEngine.timespec(::Type{<:MRDefaultPlantAggModel}) = ClockSpec(2.0, 1.0)

PlantSimEngine.@process "mrdefaultsceneagg" verbose = false
struct MRDefaultSceneAggModel <: AbstractMrdefaultsceneaggModel end
PlantSimEngine.inputs_(::MRDefaultSceneAggModel) = (XP=-Inf,)
PlantSimEngine.outputs_(::MRDefaultSceneAggModel) = (XS=-Inf,)
function PlantSimEngine.run!(::MRDefaultSceneAggModel, models, status, meteo, constants=nothing, extra=nothing)
    status.XS = sum(status.XP) + 1000.0
end
PlantSimEngine.timespec(::Type{<:MRDefaultSceneAggModel}) = ClockSpec(4.0, 1.0)

@testset "Multi-rate output export API" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    meteo4 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 4))

    # Stream-only producer remains exportable when process is explicit.
    mapping_stream = Dict(
        "Leaf" => (
            ModelSpec(MRExportSourceModel(Ref(0))) |>
            TimeStepModel(1.0) |>
            OutputRouting(; X=:stream_only),
        ),
    )

    req_hold = OutputRequest("Leaf", :X; name=:x_hold, process=:mrexportsource, policy=HoldLast())
    req_sum2 = OutputRequest("Leaf", :X; name=:x_sum2, process=:mrexportsource, policy=Integrate(), clock=ClockSpec(2.0, 1.0))

    sim_stream = PlantSimEngine.GraphSimulation(mtg, mapping_stream, nsteps=4, check=true, outputs=Dict("Leaf" => (:X,)))
    run!(
        sim_stream,
        meteo4,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[req_hold, req_sum2],
    )
    exported = collect_outputs(sim_stream; sink=DataFrame)

    @test exported[:x_hold][:, :timestep] == [1, 2, 3, 4]
    @test exported[:x_hold][:, :value] == [1.0, 2.0, 3.0, 4.0]
    @test exported[:x_sum2][:, :timestep] == [1, 3]
    @test exported[:x_sum2][:, :value] == [1.0, 5.0]

    # Without process and with stream-only routing, canonical source resolution should fail.
    @test_throws "No canonical publisher found" run!(
        sim_stream,
        meteo4,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[OutputRequest("Leaf", :X; name=:x_auto_fail)],
    )

    # Canonical routing allows omitting process in requests.
    mapping_canonical = Dict(
        "Leaf" => (
            ModelSpec(MRExportSourceModel(Ref(0))) |>
            TimeStepModel(1.0),
        ),
    )

    sim_canonical = PlantSimEngine.GraphSimulation(mtg, mapping_canonical, nsteps=4, check=true, outputs=Dict("Leaf" => (:X,)))
    run!(
        sim_canonical,
        meteo4,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[OutputRequest("Leaf", :X; name=:x_auto, policy=HoldLast())],
    )
    exported_auto = collect_outputs(sim_canonical; sink=DataFrame)
    @test exported_auto[:x_auto][:, :value] == [1.0, 2.0, 3.0, 4.0]

    # Optional direct export return from run! on GraphSimulation.
    sim_direct = PlantSimEngine.GraphSimulation(
        mtg,
        Dict(
            "Leaf" => (
                ModelSpec(MRExportSourceModel(Ref(0))) |>
                TimeStepModel(1.0),
            ),
        ),
        nsteps=4,
        check=true,
        outputs=Dict("Leaf" => (:X,)),
    )
    out_status, out_requested = run!(
        sim_direct,
        meteo4,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[OutputRequest("Leaf", :X; name=:x_direct, policy=HoldLast())],
        return_requested_outputs=true,
    )
    @test haskey(out_status, "Leaf")
    @test out_requested[:x_direct][:, :value] == [1.0, 2.0, 3.0, 4.0]

    # Optional direct export return from run! on MTG + mapping entry point.
    out_status_mtg, out_requested_mtg = run!(
        mtg,
        Dict(
            "Leaf" => (
                ModelSpec(MRExportSourceModel(Ref(0))) |>
                TimeStepModel(1.0),
            ),
        ),
        meteo4;
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[OutputRequest("Leaf", :X; name=:x_mtg, policy=HoldLast())],
        return_requested_outputs=true,
    )
    @test haskey(out_status_mtg, "Leaf")
    @test out_requested_mtg[:x_mtg][:, :value] == [1.0, 2.0, 3.0, 4.0]
end

@testset "Multi-rate output export defaults on multi-scale mapping with timespec traits" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    meteo8 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 8))

    mapping_defaults = Dict(
        "Leaf" => (
            MultiScaleModel(
                model=MRDefaultLeafSourceModel(Ref(0)),
                mapped_variables=[:X => "Plant"],
            ),
        ),
        "Plant" => (
            MultiScaleModel(
                model=MRDefaultPlantAggModel(),
                mapped_variables=[:XP => "Scene"],
            ),
        ),
        "Scene" => (
            MRDefaultSceneAggModel(),
        ),
    )

    sim_defaults = PlantSimEngine.GraphSimulation(
        mtg,
        mapping_defaults,
        nsteps=8,
        check=true,
        outputs=Dict("Leaf" => (:X,), "Plant" => (:XP,), "Scene" => (:XS,)),
    )

    run!(
        sim_defaults,
        meteo8,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=[
            OutputRequest("Plant", :XP),
            OutputRequest("Scene", :XS),
        ],
    )

    exported_defaults = collect_outputs(sim_defaults; sink=DataFrame)

    @test sort(collect(keys(exported_defaults))) == [:XP, :XS]
    @test exported_defaults[:XP][:, :timestep] == collect(1:8)
    @test exported_defaults[:XS][:, :timestep] == collect(1:8)
end
