module PreparedCallBenchmark

using Dates, PlantSimEngine, Statistics, TOML

const PSE = PlantSimEngine
const KERNEL_EVALUATIONS = Ref(0)
const LAST_CONTEXT = Ref{Any}()

PSE.@process "benchmark_prepared_leaf" verbose = false
PSE.@process "benchmark_prepared_controller" verbose = false

struct BenchmarkPreparedLeaf{T} <: AbstractBenchmark_Prepared_LeafModel
    offset::T
end
struct BenchmarkPreparedController{M,E} <: AbstractBenchmark_Prepared_ControllerModel
    mode::M
    forcing::E
end

PSE.inputs_(::BenchmarkPreparedLeaf) = NamedTuple()
PSE.outputs_(model::BenchmarkPreparedLeaf) = (signal=zero(model.offset),)
PSE.environment_inputs_(::BenchmarkPreparedLeaf) = (T=PSE.Required(Float64),)
function PSE.run!(model::BenchmarkPreparedLeaf, status, environment, constants, context)
    KERNEL_EVALUATIONS[] += 1
    status.signal = environment.T + model.offset
    return nothing
end

function invoke(::Val{:replay}, context, forcing)
    PSE.run_call!(context, :leaves; environment=forcing, publish=false)
    targets = PSE.run_call!(context, :leaves; environment=forcing, publish=true)
    return sum(target.status.signal for target in targets)
end
function invoke(::Val{:accept}, context, forcing)
    evaluation = PSE.evaluate_call!(context, :leaves; environment=forcing)
    PSE.accept_call!(evaluation)
    return sum(target.status.signal for target in PSE.call_targets(evaluation))
end

PSE.inputs_(::BenchmarkPreparedController) = NamedTuple()
PSE.outputs_(::BenchmarkPreparedController) = (total=0.0,)
function PSE.run!(model::BenchmarkPreparedController, status, environment, constants, context)
    status.total = invoke(model.mode, context, model.forcing)
    LAST_CONTEXT[] = context
    return nothing
end

function setup(nobjects, mode; steps=1, outputs=:none)
    nobjects > 0 || throw(ArgumentError("nobjects must be positive"))
    objects = PSE.Object[PSE.Object(:scene; scale=:Scene)]
    append!(objects, [PSE.Object(Symbol(:leaf_, i); scale=:Leaf, parent=:scene)
        for i in 1:nobjects])
    forcing = (T=25.0,)
    model = PSE.CompositeModel(objects...;
        applications=(
            PSE.ModelSpec(BenchmarkPreparedController(Val(mode), forcing);
                name=:controller, on=PSE.One(id=:scene),
                calls=(leaves=PSE.Many(scale=:Leaf, within=PSE.Subtree(),
                    application=:leaf),)),
            PSE.ModelSpec(BenchmarkPreparedLeaf(0.5); name=:leaf,
                on=PSE.Many(scale=:Leaf)),
        ),
        environment=(T=20.0, duration=Minute(30)),
    )
    simulation = PSE.run!(model; steps=steps, outputs=outputs)
    return simulation, LAST_CONTEXT[], forcing
end

function call_loop(mode, context, forcing, calls)
    total = 0.0
    for _ in 1:calls
        total += invoke(mode, context, forcing)
    end
    return total
end

function measure_path(mode, nobjects; repetitions=5, calls=10_000)
    simulation, context, forcing = setup(nobjects, mode)
    selected_mode = Val(mode)
    call_loop(selected_mode, context, forcing, 100)
    records = NamedTuple[]
    for _ in 1:repetitions
        GC.gc()
        KERNEL_EVALUATIONS[] = 0
        timed = @timed call_loop(selected_mode, context, forcing, calls)
        expected_evaluations = calls * nobjects * (mode === :replay ? 2 : 1)
        @assert KERNEL_EVALUATIONS[] == expected_evaluations
        @assert timed.value == calls * nobjects * 25.5
        push!(records, (
            seconds=timed.time,
            allocated_bytes=timed.bytes,
            gc_seconds=timed.gctime,
            compilation_seconds=timed.compile_time,
            kernel_evaluations=KERNEL_EVALUATIONS[],
        ))
    end
    return (
        mode=string(mode), targets=nobjects, calls_per_sample=calls,
        ns_per_call=median(row.seconds for row in records) * 1e9 / calls,
        bytes_per_call=median(row.allocated_bytes for row in records) / calls,
        samples=records,
    )
end

function verify_retained_outputs(nobjects; prepared)
    KERNEL_EVALUATIONS[] = 0
    replay, _, _ = setup(nobjects, :replay; steps=8, outputs=:all)
    @assert KERNEL_EVALUATIONS[] == 2 * nobjects * 8
    replay_rows = PSE.collect_outputs(replay; sink=nothing)
    @assert PSE.final_state(replay, :scene).total == nobjects * 25.5
    prepared || return (exact_match="prepared API unavailable", rows=length(replay_rows))
    KERNEL_EVALUATIONS[] = 0
    accepted, _, _ = setup(nobjects, :accept; steps=8, outputs=:all)
    @assert KERNEL_EVALUATIONS[] == nobjects * 8
    accepted_rows = PSE.collect_outputs(accepted; sink=nothing)
    @assert isequal(accepted_rows, replay_rows)
    @assert isequal(PSE.final_state(accepted, PSE.Many()),
        PSE.final_state(replay, PSE.Many()))
    return (exact_match=true, rows=length(accepted_rows))
end

plain(x::NamedTuple) = Dict(string(k) => plain(v) for (k, v) in pairs(x))
plain(x::AbstractDict) = Dict(string(k) => plain(v) for (k, v) in pairs(x))
plain(x::Union{Tuple,AbstractVector}) = [plain(v) for v in x]
plain(x) = x

"""
Compare the existing replay path at every engine revision; additionally execute
the prepared evaluation/acceptance path when that public API exists. Direct-call
timings reuse one fixed current timestep with outputs=:none. Retained-history
equivalence is checked in a separate, untimed eight-step simulation.
"""
function run_benchmark(label, output_path; target_counts=(1, 16), repetitions=5,
    calls=10_000)
    prepared = isdefined(PSE, :evaluate_call!) && isdefined(PSE, :accept_call!)
    paths = NamedTuple[]
    checks = Dict{String,Any}()
    for nobjects in target_counts
        @info "Prepared-call benchmark" label nobjects prepared
        checks[string(nobjects)] = verify_retained_outputs(nobjects; prepared=prepared)
        push!(paths, measure_path(:replay, nobjects; repetitions=repetitions, calls=calls))
        prepared && push!(paths,
            measure_path(:accept, nobjects; repetitions=repetitions, calls=calls))
    end
    result = (
        label=label, julia_version=string(VERSION), threads=Threads.nthreads(),
        pse_path=Base.pathof(PSE), pse_version=string(Base.pkgversion(PSE)),
        prepared_api_available=prepared, correctness=checks, paths=paths,
    )
    mkpath(dirname(output_path))
    open(output_path, "w") do io
        TOML.print(io, plain(result); sorted=true)
    end
    return (label=label, prepared=prepared,
        paths=[(mode=path.mode, targets=path.targets, ns_per_call=path.ns_per_call,
            bytes_per_call=path.bytes_per_call) for path in paths], correctness=checks)
end

end
