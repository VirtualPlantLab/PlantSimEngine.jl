using SHA, Test
import PlantSimEngine as PSE

include("harness/benchmark/regular_execution/xpalm.jl")
include("strict-snapshot-observations.jl")
include("finite-values.jl")
include("status-semantic-projection.jl")
include("full_science_observer.jl")
const R = RegularXPalmExecution
const S = StrictSnapshotObservations
const DAYS = 4160
const ARMDIR = dirname(Base.active_project())
const REFERENCE = PSE.JSON.parsefile(joinpath(@__DIR__, "reference.json"))

function stepped!(sim, elapsed, counts)
    counts[1] = length(PSE.runtime_model(sim).registry.objects)
    for day in eachindex(elapsed)
        start = time_ns()
        PSE.step!(sim)
        elapsed[day] = time_ns() - start
        counts[day + 1] = length(PSE.runtime_model(sim).registry.objects)
    end
    return nothing
end

function host_counters()
    vm = Dict(first(split(line)) => parse(Int, last(split(line))) for line in eachline("/proc/vmstat"))
    cpu = split(first(eachline("/proc/stat")))
    return (; swap_in=vm["pswpin"], swap_out=vm["pswpout"], steal_ticks=parse(Int, cpu[9]))
end

function model_rngs(source)
    return [R._raw_digest(copy(getfield(spec.model, name))) for spec in source.applications
        for name in fieldnames(typeof(spec.model)) if getfield(spec.model, name) isa R.Random.AbstractRNG]
end

function trajectory(mode)
    GC.gc()
    before = host_counters()
    construction = @timed R._construct()
    source = construction.value
    initial_rng = model_rngs(source)
    preparation = @timed R._prepare(source, DAYS, :none)
    sim = preparation.value
    @test model_rngs(source) == initial_rng
    elapsed = mode == :daily ? Vector{UInt64}(undef, DAYS) : UInt64[]
    counts = mode == :daily ? Vector{Int}(undef, DAYS + 1) : Int[]
    execution = @timed if mode === :daily
        stepped!(sim, elapsed, counts)
    else
        PSE.continue!(sim; steps=DAYS)
    end
    after = host_counters()
    state = StatusSemanticProjection.project_core(R.snapshot(sim))
    model = PSE.runtime_model(sim)
    setup = (; palm=source.palm, parameters=source.palm.parameters, weather=model.environment)
    companion = FullXPalmScientificObservation.companion_snapshot(sim, setup; constants=sim.constants)
    core = S.content_sha256(state)
    @test S.content_sha256(StatusSemanticProjection.project_core(R.snapshot(sim))) == core
    science = (; core, components=Dict(String(k) => S.content_sha256(state[k]) for k in keys(state)),
        companion_digest=S.content_sha256(companion), objects=length(state.states),
        retained_samples=sum(length(h.samples) for h in state.histories; init=0))
    @test state.step == DAYS
    @test science.objects == REFERENCE["objects"] && science.retained_samples == REFERENCE["retained_samples"]
    growth = diff(counts) .> 0
    if mode === :daily
        @test counts == REFERENCE["object_counts"]
        @test count(growth) == REFERENCE["growth_days"]
    end
    times = (; construction=R._timing(construction), preparation=R._timing(preparation),
        execution=R._timing(execution))
    return (; mode, times, science, before, after,
        growth_seconds=mode === :daily ? sum(elapsed[growth]) / 1e9 : nothing,
        ordinary_seconds=mode === :daily ? sum(elapsed[.!growth]) / 1e9 : nothing)
end

@testset "4,160 days, ordinary PSE on the frozen XPalm controls" begin
    @test VERSION == v"1.13.3"
    @test Threads.nthreads(:default) == 1 && Threads.ngcthreads() == 1
    @test realpath(pkgdir(PSE)) == realpath(joinpath(ARMDIR, "..", "PlantSimEngine"))
    @test realpath(pkgdir(R.XPalm)) == realpath(joinpath(ARMDIR, "..", "XPalm"))
    @test realpath(pkgdir(R.MTG)) == realpath(joinpath(ARMDIR, "..", "MultiScaleTreeGraph"))
    output_dir, role = ARGS
    mkpath(output_dir)
    rows = []
    Base.cumulative_compile_timing(true)
    try
        for (phase, mode, index) in ((:warm, :full, 0), (:warm, :daily, 0),
            ((:measure, mode, index) for mode in (:full, :daily) for index in 1:3)...)
            @info "Starting XPalm trajectory" role phase mode index
            row = trajectory(mode)
            push!(rows, (; phase, index, row...))
            report = (; role, cpu=Sys.CPU_NAME, julia=string(VERSION), julia_commit=Base.GIT_VERSION_INFO.commit,
                hostname=get(ENV, "HOSTNAME", ""), rows)
            write(joinpath(output_dir, role * ".json"), PSE.JSON.json(report))
            @test row.science == first(rows).science
            if phase === :measure
                @test all(t -> iszero(t.compile_seconds) && iszero(t.recompile_seconds), values(row.times))
            end
        end
    finally
        Base.cumulative_compile_timing(false)
    end
end

