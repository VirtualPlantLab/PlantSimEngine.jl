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
end
