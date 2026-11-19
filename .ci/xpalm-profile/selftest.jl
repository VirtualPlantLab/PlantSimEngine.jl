using Test, Profile
include("cpu_profiles.jl")
const CP = MatchedCPUProfiles
mutable struct CounterScene
    day::Int
    objects::Int
    work::Float64
end
function advance!(scene)
    scene.day += 1
    iseven(scene.day) && (scene.objects += 1)
    deadline = time_ns() + UInt64(30_000_000)
    while time_ns() < deadline
        scene.work = sin(scene.work + 0.01)
    end
    return nothing
end
@testset "Real Profile API and observed-day sampling gates" begin
    @test VERSION == v"1.13.3"
    for mode in (:none, :ordinary, :growth)
        CP.initialize!()
        scene = CounterScene(0, 1, 0.5)
        observations = CP.profile_steps!(advance!, s -> s.objects, scene, [1, 1, 2, 2, 3], mode)
        @test scene.day == 4 && scene.objects == 3
        @test [x.growth for x in observations] == [false, true, false, true]
        @test [x.sampled for x in observations] == (mode === :none ? falses(4) : mode === :growth ? [false, true, false, true] : [true, false, true, false])
        @test all(x -> x.sampled || iszero(x.profile_words), observations)
        @test !Profile.is_running()
        if mode !== :none
            summary = CP.summarize()
            @test summary.samples > 0 && !summary.buffer_full
            @test !isempty(summary.flat)
            @test summary.signature_text_recorded === false
            @test all(x -> length(x.function_name) <= 180, summary.flat)
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
