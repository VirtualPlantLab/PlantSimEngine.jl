using PlantSimEngine
using PlantSimEngine.Examples
using Test

@testset "Multi-rate scaffolding" begin
    m = Process1Model(1.0)

    clk = timespec(m)
    @test clk.dt == 1.0
    @test clk.phase == 0.0

    @test output_policy(m) == NamedTuple()
    @test input_bindings(ModelSpec(m)) == NamedTuple()
    @test output_routing(ModelSpec(m)) == NamedTuple()
    @test model_scope(ModelSpec(m)) == :global

    spec = ModelSpec(m) |>
           TimeStepModel(24.0) |>
           InputBindings(; var1=(process=:process1, var=:var3)) |>
           OutputRouting(; var3=:stream_only) |>
           ScopeModel(:plant)
    @test PlantSimEngine.model_(spec) === m
    @test PlantSimEngine.timestep(spec) == 24.0
    @test input_bindings(spec).var1.process == :process1
    @test input_bindings(spec).var1.policy isa HoldLast
    @test output_routing(spec).var3 == :stream_only
    @test model_scope(spec) == :plant

    mspec = ModelSpec(m) |> MultiScaleModel([:var1 => "Leaf"])
    @test length(PlantSimEngine.get_mapped_variables(mspec)) == 1

    ts = TemporalState()
    @test isempty(ts.caches)
    @test isempty(ts.last_run)

    scope = ScopeId(:global, 1)
    key = OutputKey(scope, "Leaf", 7, :process1, :var3)
    ts.caches[key] = HoldLastCache(1.0, 42.0)
    @test ts.caches[key] isa HoldLastCache
    @test ts.caches[key].v == 42.0
end
