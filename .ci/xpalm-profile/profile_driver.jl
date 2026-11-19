using Profile
include("science_control.jl")
include("cpu_profiles.jl")
const CP = MatchedCPUProfiles
const OUT, ROLE = ARGS
@assert ROLE in ("main", "historical", "candidate")
mkpath(OUT)
write_json(name, value) = write(joinpath(OUT, name), PSE.JSON.json(value))
function trajectory(label, mode, sampled_class)
    @info "Profile diagnostic trajectory" role=ROLE label mode sampled_class
    GC.gc()
    construction = @timed R._construct()
    source = construction.value
    initial_rng = model_rngs(source)
    preparation = @timed R._prepare(source, DAYS, :none)
    sim = preparation.value
    @test model_rngs(source) == initial_rng
    @test !Profile.is_running()
    execution = @timed if mode === :full
        PSE.continue!(sim; steps=DAYS)
    else
        CP.profile_steps!(PSE.step!, object_count, sim, COUNTS, sampled_class)
    end
    @test !Profile.is_running()
    days = mode === :daily ? execution.value : nothing
    tail_days = isnothing(days) ? Int[] : [x.day for x in days if x.sampled && x.tail_window]
    profile = sampled_class === :none ? nothing : CP.summarize(sampled_class;
        after_word=first(days).raw_word_begin, tail_window_days=tail_days)
    if mode === :daily
        @test length(days) == DAYS
        @test count(x -> x.growth, days) == REF["growth_days"]
        if sampled_class !== :none
            @test count(x -> x.sampled, days) == (sampled_class === :growth ? REF["growth_days"] : DAYS - REF["growth_days"])
            @test all(x -> (x.marker_exit_ns > 0) == x.sampled, days)
            write_json(ROLE * "-" * String(sampled_class) * "-days.json", days)
        end
    end
    if profile !== nothing
        @test profile.samples > 0
        @test !isempty(tail_days) && profile.late_window_samples > 0
        @test !profile.buffer_full
        @test iszero(execution.compile_time) && iszero(execution.recompile_time)
        write_json(ROLE * "-" * String(sampled_class) * "-profile.json", profile)
    end
    observed = science(sim, source)
    return (; label, phase=sampled_class === :none ? :warm : :profile, mode, sampled_class, science=observed,
        times=(; construction=R._timing(construction), preparation=R._timing(preparation), execution=R._timing(execution)),
        measured_performance=false,
        timing_scope=sampled_class === :none ? "unprofiled warm-up diagnostic; includes cold JIT where present" : "includes Profile timer and observer bookkeeping; never a benchmark",
        sampled_days=isnothing(days) ? 0 : count(x -> x.sampled, days),
        samples=isnothing(profile) ? 0 : profile.samples,
        buffer_full=isnothing(profile) ? false : profile.buffer_full)
end

@testset "Matched real-day CPU profiles preserve complete scientific observations" begin
    @test VERSION == v"1.13.3"
    @test Threads.nthreads(:default) == 1 && Threads.ngcthreads() == 1
    @test realpath(pkgdir(PSE)) == realpath(joinpath(ENVIRONMENT, "..", "PlantSimEngine"))
    @test realpath(pkgdir(R.XPalm)) == realpath(joinpath(ENVIRONMENT, "..", "XPalm"))
    @test length(COUNTS) == DAYS + 1
    CP.initialize!()
    rows = []
    Base.cumulative_compile_timing(true)
    try
        for (label, mode, sampled) in ((:warm_full, :full, :none), (:warm_daily, :daily, :none),
            (:ordinary_profile, :daily, :ordinary), (:growth_profile, :daily, :growth))
            row = trajectory(label, mode, sampled)
            push!(rows, row)
            @test row.science == first(rows).science
            report = (; role=ROLE, cpu=Sys.CPU_NAME, hostname=get(ENV, "HOSTNAME", ""), julia=string(VERSION), julia_commit=Base.GIT_VERSION_INFO.commit,
                rows, kind="CPU profile diagnostic; all times separate from official uninstrumented benchmark", accepted_performance_result=false)
            write_json(ROLE * ".json", report)
        end
    finally
        Base.cumulative_compile_timing(false)
    end
end
