using PlantSimEngine
using Dates

PlantSimEngine.@process "mrbenchsource" verbose = false
struct MRBenchSourceModel <: AbstractMrbenchsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRBenchSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRBenchSourceModel) = (X=-Inf,)
function PlantSimEngine.run!(m::MRBenchSourceModel, status, environment, constants=nothing, context=nothing)
    m.n[] += 1
    status.X = float(m.n[])
end

PlantSimEngine.@process "mrbenchconsumer4" verbose = false
struct MRBenchConsumer4Model <: AbstractMrbenchconsumer4Model end
PlantSimEngine.inputs_(::MRBenchConsumer4Model) = (X=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::MRBenchConsumer4Model) = (Y4=-Inf,)
function PlantSimEngine.run!(::MRBenchConsumer4Model, status, environment, constants=nothing, context=nothing)
    status.Y4 = sum(status.X)
end

PlantSimEngine.@process "mrbenchconsumer24" verbose = false
struct MRBenchConsumer24Model <: AbstractMrbenchconsumer24Model end
PlantSimEngine.inputs_(::MRBenchConsumer24Model) = (X=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::MRBenchConsumer24Model) = (Y24=-Inf,)
function PlantSimEngine.run!(::MRBenchConsumer24Model, status, environment, constants=nothing, context=nothing)
    status.Y24 = sum(status.X)
end

function _build_multirate_benchmark_objects(nleaves::Int)
    objects = Object[
        Object(:plant; scale=:Plant),
    ]
    append!(
        objects,
        [Object(Symbol(:leaf_, i); scale=:Leaf, parent=:plant) for i in 1:nleaves],
    )
    return objects
end

function setup_multirate_buffer_benchmark(; nleaves=2000, ndays=30)
    objects = _build_multirate_benchmark_objects(nleaves)
    applications = (
        ModelSpec(MRBenchSourceModel(Ref(0)); name=:hourly_source) |>
            AppliesTo(Many(scale=:Leaf)) |>
            TimeStep(Hour(1)),
        ModelSpec(MRBenchConsumer4Model(); name=:four_hour_consumer) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(:X => Many(
                scale=:Leaf,
                within=Subtree(),
                application=:hourly_source,
                var=:X,
                policy=Integrate(),
                window=Hour(4),
            )) |>
            TimeStep(Hour(4)),
        ModelSpec(MRBenchConsumer24Model(); name=:daily_consumer) |>
            AppliesTo(One(scale=:Plant)) |>
            Inputs(:X => Many(
                scale=:Leaf,
                within=Subtree(),
                application=:hourly_source,
                var=:X,
                policy=Integrate(),
                window=Day(1),
            )) |>
            TimeStep(Day(1)),
    )

    nsteps = 24 * ndays
    environment = [(T=20.0, Wind=1.0, Rh=0.65, duration=Hour(1)) for _ in 1:nsteps]
    model = CompositeModel(objects...; applications=applications, environment=environment)

    reqs = [
        OutputRequest(:Plant, :Y4; name=:four_hour_total, application=:four_hour_consumer),
        OutputRequest(:Plant, :Y24; name=:daily_total, application=:daily_consumer),
        OutputRequest(:Leaf, :X; name=:x_daily_sum, application=:hourly_source, policy=Integrate(), clock=Day(1)),
    ]
    return model, reqs, nsteps
end

function benchmark_multirate_retain_all_run(model, nsteps)
    return run!(model; steps=nsteps, outputs=:all)
end

function benchmark_multirate_output_request_run(model, reqs, nsteps)
    return run!(model; steps=nsteps, outputs=reqs)
end
