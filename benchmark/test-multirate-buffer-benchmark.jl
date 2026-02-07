using PlantSimEngine
using MultiScaleTreeGraph
using PlantMeteo
using Dates

PlantSimEngine.@process "mrbenchsource" verbose = false
struct MRBenchSourceModel <: AbstractMrbenchsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRBenchSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRBenchSourceModel) = (X=-Inf,)
function PlantSimEngine.run!(m::MRBenchSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.X = float(m.n[])
end

PlantSimEngine.@process "mrbenchconsumer4" verbose = false
struct MRBenchConsumer4Model <: AbstractMrbenchconsumer4Model end
PlantSimEngine.inputs_(::MRBenchConsumer4Model) = (X=[-Inf],)
PlantSimEngine.outputs_(::MRBenchConsumer4Model) = (Y4=-Inf,)
function PlantSimEngine.run!(::MRBenchConsumer4Model, models, status, meteo, constants=nothing, extra=nothing)
    status.Y4 = sum(status.X)
end

PlantSimEngine.@process "mrbenchconsumer24" verbose = false
struct MRBenchConsumer24Model <: AbstractMrbenchconsumer24Model end
PlantSimEngine.inputs_(::MRBenchConsumer24Model) = (X=[-Inf],)
PlantSimEngine.outputs_(::MRBenchConsumer24Model) = (Y24=-Inf,)
function PlantSimEngine.run!(::MRBenchConsumer24Model, models, status, meteo, constants=nothing, extra=nothing)
    status.Y24 = sum(status.X)
end

function _build_multirate_benchmark_mtg(nleaves::Int)
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))

    for i in 1:nleaves
        Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", i, 2))
    end

    return mtg
end

function setup_multirate_buffer_benchmark(; nleaves=2000, ndays=30)
    mtg = _build_multirate_benchmark_mtg(nleaves)

    mapping = Dict(
        "Leaf" => (
            ModelSpec(MRBenchSourceModel(Ref(0))) |> TimeStepModel(1.0),
        ),
        "Plant" => (
            ModelSpec(MRBenchConsumer4Model()) |>
            MultiScaleModel([:X => ["Leaf"]]) |>
            TimeStepModel(ClockSpec(4.0, 1.0)) |>
            InputBindings(; X=(process=:mrbenchsource, var=:X, scale="Leaf", policy=Integrate())),
            ModelSpec(MRBenchConsumer24Model()) |>
            MultiScaleModel([:X => ["Leaf"]]) |>
            TimeStepModel(ClockSpec(24.0, 1.0)) |>
            InputBindings(; X=(process=:mrbenchsource, var=:X, scale="Leaf", policy=Integrate())),
        ),
    )

    nsteps = 24 * ndays
    meteo = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], nsteps))

    reqs = [
        OutputRequest("Leaf", :X; name=:x_hourly, process=:mrbenchsource, policy=HoldLast()),
        OutputRequest("Leaf", :X; name=:x_daily_sum, process=:mrbenchsource, policy=Integrate(), clock=ClockSpec(24.0, 1.0)),
    ]

    tracked = Dict("Plant" => (:Y4, :Y24), "Leaf" => (:X,))
    return mtg, mapping, meteo, reqs, tracked, nsteps
end

function benchmark_multirate_status_tracked_run(mtg, mapping, meteo, tracked, nsteps)
    run!(
        mtg,
        mapping,
        meteo,
        nsteps=nsteps,
        check=true,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=tracked
    )
end

function benchmark_multirate_output_request_run(mtg, mapping, meteo, reqs, tracked, nsteps)
    run!(
        mtg,
        mapping,
        meteo,
        nsteps=nsteps,
        check=true,
        multirate=true,
        executor=SequentialEx(),
        tracked_outputs=reqs
    )
end
