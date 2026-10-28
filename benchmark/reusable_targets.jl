module ReusableTargetsBenchmark

using Dates, PlantSimEngine, Statistics, SHA
const PSE = PlantSimEngine
PSE.@process "reusable_buffer_benchmark_owner" verbose=false
PSE.@process "reusable_buffer_benchmark_leaf" verbose=false

struct Owner{C} <: AbstractReusable_Buffer_Benchmark_OwnerModel
    capture::C
end
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end
struct Leaf{T} <: AbstractReusable_Buffer_Benchmark_LeafModel
    initial::T
end
PSE.inputs_(model::Leaf) = (driver=Default(model.initial),)
PSE.outputs_(model::Leaf) = (result=zero(model.initial),)
PSE.run!(::Leaf, status, environment, constants, context) = (status.result = status.driver; nothing)

function fixture(count, ::Type{T}) where {T}
    capture = Ref{Any}()
    model = CompositeModel(Object(:owner; scale=:Scene),
        (Object(Symbol(:leaf_,i); scale=:Leaf, parent=:owner,
            status=Status(driver=T(2), result=zero(T))) for i in 1:count)...;
        applications=(ModelSpec(Owner(capture); name=:owner, on=One(id=:owner),
            calls=(leaves=Many(scale=:Leaf, within=SceneScope(), application=:leaves),)),
            ModelSpec(Leaf(T(2)); name=:leaves, on=Many(scale=:Leaf))),
        environment=(duration=Hour(1),))
    simulation = run!(model; steps=1, outputs=:none)
    targets = call_targets(capture[], :leaves)
    @assert length(targets) == count
    return (; simulation, targets)
end

Base.@noinline function read_values(values)
    result = 0.0
    for target in values
        result += target.status.driver
    end
    return result
end
Base.@noinline fresh_read(targets) = read_values(collect(targets))
Base.@noinline borrowed_read(targets) = PSE.with_call_targets(read_values, targets)
function repeated(f::F, targets, count) where {F}
    result = 0.0
    for _ in 1:count
        result += f(targets)
    end
    return result
end
function measure(f, targets; operations, repetitions)
    repeated(f, targets, 2_304)
    samples = map(1:repetitions) do _
        GC.gc()
        timing = @timed repeated(f, targets, operations)
        @assert timing.value == operations * 2 * length(targets)
        (ns_per_operation=1e9*timing.time/operations,
            bytes_per_operation=timing.bytes/operations,
            compilation_seconds=timing.compile_time,
            recompilation_seconds=timing.recompile_time)
    end
    return (ns_per_operation=median(x.ns_per_operation for x in samples),
        bytes_per_operation=median(x.bytes_per_operation for x in samples), samples=samples)
end

"""
    run_benchmark(; operations=10_000, repetitions=5, counts=(8,64))

Compare fresh typed collection plus actual Status reads with scoped borrowing
when available in the loaded engine. Include this same file at both revisions.
Construction and 2,304 warmup operations precede timing. Borrowed storage's first
preparation is excluded here; complete fresh MAESPA scenarios must include it.
Allocation slope across target counts checks for boxed temporary views. This
optional diagnostic adds no dependencies to the default benchmark suite.
"""
function run_benchmark(; operations=10_000, repetitions=5, counts=(8,64))
    operations > 0 && repetitions > 0 || throw(ArgumentError("positive sample sizes required"))
    rows = NamedTuple[]
    for count in counts
        data = fixture(count, Float64)
        push!(rows, (targets=count, mode=:fresh,
            measurement=measure(fresh_read, data.targets; operations,repetitions)))
        if isdefined(PSE, :with_call_targets)
            identity = Ref{Any}(nothing)
            PSE.with_call_targets(data.targets) do values
                identity[] = values
                @assert Base.allocatedinline(eltype(values))
                @assert read_values(values) == 2count
            end
            PSE.with_call_targets(data.targets) do values
                @assert values === identity[]
            end
            push!(rows, (targets=count, mode=:borrowed,
                measurement=measure(borrowed_read, data.targets; operations,repetitions)))
        end
    end
    return (julia_version=string(VERSION), project=Base.active_project(),
        pse_path=pathof(PSE), operations,repetitions, rows,
        runner_sha256=bytes2hex(sha256(read(@__FILE__))))
end
end
