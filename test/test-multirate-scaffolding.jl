using PlantSimEngine
using PlantSimEngine.Examples
using MultiScaleTreeGraph
using Test

@testset "Multi-rate scaffolding" begin
    m = Process1Model(1.0)

    clk = timespec(m)
    @test clk.dt == 1.0
    @test clk.phase == 0.0

    @test output_policy(m) == NamedTuple()
    @test isnothing(timestep_hint(m))
    @test isnothing(meteo_hint(m))
    @test meteo_inputs(m) == ()
    @test meteo_outputs(m) == ()
    @test meteo_inputs(ModelSpec(m)) == ()
    @test meteo_outputs(ModelSpec(m)) == ()
    @test input_bindings(ModelSpec(m)) == NamedTuple()
    @test output_routing(ModelSpec(m)) == NamedTuple()
    @test model_scope(ModelSpec(m)) == :global
    @test updates(ModelSpec(m)) == ()
    @test_throws "String scope selectors are not supported" ModelSpec(m; scope="plant")
    @test_throws "String scope selectors are not supported" PlantSimEngine.ScopeModel("plant")(m)

    scope_node = Node(MultiScaleTreeGraph.NodeMTG("/", :Leaf, 1, 1))
    @test_throws "must return `ScopeId` or `Symbol`" PlantSimEngine._scope_from_selector(
        (node, scale, process) -> "plant",
        scope_node,
        :Leaf,
        :process1,
    )

    mapping = Dict(:Leaf => (m,))
    resolved_specs = resolved_model_specs(mapping)
    @test haskey(resolved_specs, :Leaf)
    @test haskey(resolved_specs[:Leaf], :process1)

    io = IOBuffer()
    explained = explain_model_specs(mapping; io=io)
    explain_txt = String(take!(io))
    @test length(explained) == 1
    @test explained[1].process == :process1
    @test occursin("Resolved model specs:", explain_txt)
    @test occursin("Leaf/process1", explain_txt)
    @test occursin("input_bindings=", explain_txt)

    spec = ModelSpec(m) |>
           TimeStep(24.0) |>
           PlantSimEngine.InputBindings(; var1=(process=:process1, var=:var3)) |>
           OutputRouting(; var3=:stream_only) |>
           PlantSimEngine.ScopeModel(:plant) |>
           Updates(:var3; after=:process1) |>
           Updates(:var3; after=:process2)
    @test PlantSimEngine.model_(spec) === m
    @test PlantSimEngine.timestep(spec) == 24.0
    @test input_bindings(spec).var1.process == :process1
    @test input_bindings(spec).var1.policy isa HoldLast
    @test output_routing(spec).var3 == :stream_only
    @test model_scope(spec) == :plant
    @test updates(spec)[1].variables == (:var3,)
    @test updates(spec)[1].after == (:process1,)
    @test updates(spec)[2].variables == (:var3,)
    @test updates(spec)[2].after == (:process2,)

    mspec = ModelSpec(m) |> PlantSimEngine.MultiScaleModel([:var1 => (:Leaf => :var1)])
    @test length(PlantSimEngine.get_mapped_variables(mspec)) == 1

    ts = TemporalState()
    @test isempty(ts.caches)
    @test isempty(ts.last_run)
    @test isempty(ts.streams)
    @test isempty(ts.producer_horizons)
    @test isempty(ts.export_plans)
    @test isempty(ts.export_rows)

    scope = ScopeId(:global, 1)
    key = OutputKey(scope, :Leaf, 7, :process1, :var3)
    ts.caches[key] = HoldLastCache(1.0, 42.0)
    @test ts.caches[key] isa HoldLastCache
    @test ts.caches[key].v == 42.0

    vals = [1.0, 2.0, 3.0]
    durs = [1.0, 1.0, 1.0]
    @test Integrate().reducer isa SumReducer
    @test Aggregate().reducer isa MeanReducer
    @test PlantSimEngine._window_reduce(vals, durs, Integrate()) == 6.0
    @test PlantSimEngine._window_reduce(vals, durs, Aggregate()) == 2.0
    @test PlantSimEngine._window_reduce(vals, durs, Integrate(MeanReducer())) ==
          PlantSimEngine._window_reduce(vals, durs, Aggregate(MeanReducer()))
    @test PlantSimEngine._window_reduce(vals, durs, Integrate(SumReducer())) ==
          PlantSimEngine._window_reduce(vals, durs, Aggregate(SumReducer()))
end
