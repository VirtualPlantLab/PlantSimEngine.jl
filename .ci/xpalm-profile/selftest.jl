using Test, Profile
include("cpu_profiles.jl")
const CP = MatchedCPUProfiles
mutable struct CounterScene
    day::Int
    objects::Int
    work::Float64
end
Base.@noinline function ordinary_work!(scene)
    value = scene.work
    for _ in 1:1_500_000
        value = sin(value + 0.01)
    end
    scene.work = value
    return nothing
end
Base.@noinline function growth_work!(scene)
    value = scene.work
    for _ in 1:1_500_000
        value = sin(value + 0.02)
    end
    scene.work = value
    return nothing
end
function advance!(scene)
    scene.day += 1
    if iseven(scene.day)
        scene.objects += 1
        growth_work!(scene)
    else
        ordinary_work!(scene)
    end
    return nothing
end
@testset "Real Profile API and observed-day sampling gates" begin
    @test VERSION == v"1.13.3"
    reference_state = nothing
    CP.initialize!()
    for mode in (:none, :ordinary, :growth)
        scene = CounterScene(0, 1, 0.5)
        observations = CP.profile_steps!(advance!, s -> s.objects, scene, [1, 1, 2, 2, 3], mode)
        @test scene.day == 4 && scene.objects == 3
        @test [x.growth for x in observations] == [false, true, false, true]
        @test [x.sampled for x in observations] == (mode === :none ? falses(4) : mode === :growth ? [false, true, false, true] : [true, false, true, false])
        @test all(x -> (x.marker_exit_ns > 0) == (mode === :none || x.sampled), observations)
        state = (scene.day, scene.objects, scene.work)
        if mode === :none
            reference_state = state
        else
            @test state === reference_state
        end
        @test !Profile.is_running()
        if mode !== :none
            tail_days = [x.day for x in observations if x.sampled && x.tail_window]
            summary = CP.summarize(mode; after_word=first(observations).raw_word_begin,
                tail_window_days=tail_days)
            @test summary.samples > 0 && !summary.buffer_full
            @test tail_days == [mode === :ordinary ? 3 : 4]
            @test summary.late_window_samples > 0
            @test summary.tail_window_days == tail_days
            @test summary.buffer_capacity_words == 20_000_000
            @test summary.after_word == first(observations).raw_word_begin
            @test summary.complete_through_word >= summary.after_word
            @test !isempty(summary.flat)
            @test summary.signature_text_recorded === false
            @test all(x -> length(x.function_name) <= 180, summary.flat)
            good = mode === :ordinary ? "ordinary_work!" : "growth_work!"
            bad = mode === :ordinary ? "growth_work!" : "ordinary_work!"
            @test any(x -> x.module_name == "Main" && x.function_name == good, summary.flat)
            @test !any(x -> x.module_name == "Main" && x.function_name == bad, summary.flat)
            @test summary.raw_samples == summary.samples + summary.discarded_outside_scope_samples
            @test summary.scope.module_name == string(CP)
            @test summary.scope.function_name == (mode === :ordinary ? "ordinary_step!" : "growth_step!")
        end
    end
end

include("cold_phase.jl")
@testset "Cold phase markers and portable driver syntax" begin
    io = IOBuffer()
    @test @cold_phase(io, :probe, 17) === 17
    text = String(take!(io))
    @test occursin("COLD_PHASE\tbefore\tprobe", text)
    @test occursin("COLD_PHASE\tafter\tprobe", text)
    @test occursin("compile_seconds=", text)
    @test_throws ErrorException @cold_phase(io, :failure, error("expected cold failure"))
    @test occursin("COLD_PHASE\tfailed\tfailure", String(take!(io)))
    contains_error(ex) = ex isa Expr && (ex.head in (:error, :incomplete) || any(contains_error, ex.args))
    for name in ("science_control.jl", "profile_driver.jl", "cold_driver.jl", "cold_phase.jl")
        expression = Meta.parseall(read(joinpath(@__DIR__, name), String))
        @test expression.head === :toplevel
        @test !contains_error(expression)
    end
end
