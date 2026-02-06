using PlantSimEngine
using PlantSimEngine.Examples
using MultiScaleTreeGraph
using PlantMeteo
using Test

# Producer stream: writes :S.
PlantSimEngine.@process "mrsource" verbose = false
struct MRSourceModel <: AbstractMrsourceModel end
PlantSimEngine.inputs_(::MRSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRSourceModel) = (S=-Inf,)
function PlantSimEngine.run!(::MRSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.S = 10.0
end

# Writes :C in status, but is declared stream-only for canonical publication checks.
PlantSimEngine.@process "mroverwrite" verbose = false
struct MROverwriteModel <: AbstractMroverwriteModel end
PlantSimEngine.inputs_(::MROverwriteModel) = (S=-Inf,)
PlantSimEngine.outputs_(::MROverwriteModel) = (C=-Inf,)
function PlantSimEngine.run!(::MROverwriteModel, models, status, meteo, constants=nothing, extra=nothing)
    status.C = -999.0
end

# Consumer reads :C and writes :B.
PlantSimEngine.@process "mrconsumer" verbose = false
struct MRConsumerModel <: AbstractMrconsumerModel end
PlantSimEngine.inputs_(::MRConsumerModel) = (C=-Inf,)
PlantSimEngine.outputs_(::MRConsumerModel) = (B=-Inf,)
function PlantSimEngine.run!(::MRConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.B = status.C
end

# Direct mapping case: same variable name on producer and consumer (:S -> :S).
PlantSimEngine.@process "mrdirectconsumer" verbose = false
struct MRDirectConsumerModel <: AbstractMrdirectconsumerModel end
PlantSimEngine.inputs_(::MRDirectConsumerModel) = (S=-Inf,)
PlantSimEngine.outputs_(::MRDirectConsumerModel) = (D=-Inf,)
function PlantSimEngine.run!(::MRDirectConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.D = status.S
end

PlantSimEngine.@process "mrautosamename" verbose = false
struct MRAutoSameNameModel <: AbstractMrautosamenameModel end
PlantSimEngine.inputs_(::MRAutoSameNameModel) = (S=-Inf,)
PlantSimEngine.outputs_(::MRAutoSameNameModel) = (E=-Inf,)
function PlantSimEngine.run!(::MRAutoSameNameModel, models, status, meteo, constants=nothing, extra=nothing)
    status.E = status.S
end

PlantSimEngine.@process "mrconflict1" verbose = false
struct MRConflict1Model <: AbstractMrconflict1Model end
PlantSimEngine.inputs_(::MRConflict1Model) = NamedTuple()
PlantSimEngine.outputs_(::MRConflict1Model) = (Z=-Inf,)
function PlantSimEngine.run!(::MRConflict1Model, models, status, meteo, constants=nothing, extra=nothing)
    status.Z = 1.0
end

PlantSimEngine.@process "mrconflict2" verbose = false
struct MRConflict2Model <: AbstractMrconflict2Model end
PlantSimEngine.inputs_(::MRConflict2Model) = NamedTuple()
PlantSimEngine.outputs_(::MRConflict2Model) = (Z=-Inf,)
function PlantSimEngine.run!(::MRConflict2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.Z = 2.0
end

PlantSimEngine.@process "mrclocksource" verbose = false
struct MRClockSourceModel <: AbstractMrclocksourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRClockSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRClockSourceModel) = (X=-Inf,)
function PlantSimEngine.run!(m::MRClockSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.X = float(m.n[])
end

PlantSimEngine.@process "mrclockconsumer" verbose = false
struct MRClockConsumerModel <: AbstractMrclockconsumerModel end
PlantSimEngine.inputs_(::MRClockConsumerModel) = (X=-Inf,)
PlantSimEngine.outputs_(::MRClockConsumerModel) = (Y=-Inf,)
function PlantSimEngine.run!(::MRClockConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.Y = status.X
end
PlantSimEngine.timespec(::Type{<:MRClockConsumerModel}) = ClockSpec(2.0, 1.0)

PlantSimEngine.@process "mrcrosssource" verbose = false
struct MRCrossSourceModel <: AbstractMrcrosssourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRCrossSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRCrossSourceModel) = (XS=-Inf,)
function PlantSimEngine.run!(m::MRCrossSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XS = float(m.n[])
end

PlantSimEngine.@process "mrcrossconsumer" verbose = false
struct MRCrossConsumerModel <: AbstractMrcrossconsumerModel end
PlantSimEngine.inputs_(::MRCrossConsumerModel) = (XS=-Inf,)
PlantSimEngine.outputs_(::MRCrossConsumerModel) = (XP=-Inf,)
function PlantSimEngine.run!(::MRCrossConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.XP = sum(status.XS)
end

@testset "Multi-rate runtime: HoldLast and conflict validation" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    mapping_ok = Dict(
        "Leaf" => (
            MRSourceModel(),
            ModelSpec(MROverwriteModel()) |> OutputRouting(; C=:stream_only),
            ModelSpec(MRConsumerModel()) |>
            InputBindings(; C=(process=:mrsource, var=:S)),
            ModelSpec(MRDirectConsumerModel()) |>
            InputBindings(; S=(process=:mrsource, var=:S)),
            MRAutoSameNameModel(),
        ),
    )

    out_ok = Dict("Leaf" => (:S, :C, :B, :D, :E))
    sim_ok = PlantSimEngine.GraphSimulation(mtg, mapping_ok, nsteps=1, check=true, outputs=out_ok)
    meteo = Atmosphere(T=20.0, Wind=1.0, Rh=0.65)
    run!(sim_ok, meteo, multirate=true, executor=SequentialEx())

    specs_leaf = PlantSimEngine.get_model_specs(sim_ok)["Leaf"]
    @test input_bindings(specs_leaf[:mrconsumer]).C.var == :S
    @test input_bindings(specs_leaf[:mrconsumer]).C.policy isa HoldLast
    @test output_routing(specs_leaf[:mroverwrite]).C == :stream_only

    st_leaf = status(sim_ok)["Leaf"][1]
    # Expectation 1: consumer :C input is remapped from mrsource/:S via mapping-level InputBindings.
    @test st_leaf.C == 10.0
    @test st_leaf.B == 10.0
    # Expectation 2: direct same-name binding (:S -> :S) also resolves and is visible in :D.
    @test st_leaf.D == 10.0
    # Expectation 3: with no input_bindings method, same-name input :S is auto-resolved.
    @test st_leaf.E == 10.0
    nid = MultiScaleTreeGraph.node_id(st_leaf.node)
    scope = ScopeId(:global, 1)
    key_src = OutputKey(scope, "Leaf", nid, :mrsource, :S)
    key_ovr = OutputKey(scope, "Leaf", nid, :mroverwrite, :C)
    key_dir = OutputKey(scope, "Leaf", nid, :mrdirectconsumer, :D)
    key_auto = OutputKey(scope, "Leaf", nid, :mrautosamename, :E)
    # Expectation 4: temporal stream caches track producer outputs (including stream-only outputs).
    @test haskey(sim_ok.temporal_state.caches, key_src)
    @test haskey(sim_ok.temporal_state.caches, key_ovr)
    @test haskey(sim_ok.temporal_state.caches, key_dir)
    @test haskey(sim_ok.temporal_state.caches, key_auto)
    @test sim_ok.temporal_state.caches[key_src].v == 10.0
    @test sim_ok.temporal_state.caches[key_ovr].v == -999.0
    @test sim_ok.temporal_state.caches[key_dir].v == 10.0
    @test sim_ok.temporal_state.caches[key_auto].v == 10.0

    mapping_conflict = Dict(
        "Leaf" => (
            MRConflict1Model(),
            MRConflict2Model(),
        ),
    )
    sim_conflict = PlantSimEngine.GraphSimulation(mtg, mapping_conflict, nsteps=1, check=true, outputs=Dict("Leaf" => (:Z,)))
    # Expectation 5: two canonical publishers of the same output are rejected.
    @test_throws "Ambiguous canonical publishers" run!(sim_conflict, meteo, multirate=true, executor=SequentialEx())

    # Expectation 6: models run at different clocks; slower model holds last value between runs.
    source_counter = Ref(0)
    mapping_clock_trait = Dict(
        "Leaf" => (
            ModelSpec(MRClockSourceModel(source_counter)) |> TimeStepModel(1.0),
            ModelSpec(MRClockConsumerModel()) |>
            InputBindings(; X=(process=:mrclocksource, var=:X)),
        ),
    )
    sim_clock_trait = PlantSimEngine.GraphSimulation(mtg, mapping_clock_trait, nsteps=4, check=true, outputs=Dict("Leaf" => (:X, :Y)))
    meteo4 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 4))
    run!(sim_clock_trait, meteo4, multirate=true, executor=SequentialEx())
    st_clock = status(sim_clock_trait)["Leaf"][1]
    @test st_clock.X == 4.0
    @test st_clock.Y == 3.0

    # Expectation 7: TimeStepModel override takes precedence over model timespec.
    source_counter_2 = Ref(0)
    mapping_clock_override = Dict(
        "Leaf" => (
            ModelSpec(MRClockSourceModel(source_counter_2)) |> TimeStepModel(1.0),
            ModelSpec(MRClockConsumerModel()) |>
            TimeStepModel(3.0) |>
            InputBindings(; X=(process=:mrclocksource, var=:X)),
        ),
    )
    sim_clock_override = PlantSimEngine.GraphSimulation(mtg, mapping_clock_override, nsteps=4, check=true, outputs=Dict("Leaf" => (:X, :Y)))
    run!(sim_clock_override, meteo4, multirate=true, executor=SequentialEx())
    st_clock_override = status(sim_clock_override)["Leaf"][1]
    @test st_clock_override.X == 4.0
    @test st_clock_override.Y == 3.0

    # Expectation 8: cross-scale hold-last resolution works with different clocks.
    # Leaf producer runs each step; Plant consumer runs every 2 steps (1, 3) and reads Leaf XS through multiscale mapping.
    source_counter_3 = Ref(0)
    mapping_cross = Dict(
        "Leaf" => (
            ModelSpec(MRCrossSourceModel(source_counter_3)) |> TimeStepModel(1.0),
        ),
        "Plant" => (
            ModelSpec(MRCrossConsumerModel()) |>
            MultiScaleModel([:XS => ["Leaf"]]) |>
            TimeStepModel(ClockSpec(2.0, 1.0)) |>
            InputBindings(; XS=(process=:mrcrosssource, var=:XS, scale="Leaf")),
        ),
    )
    sim_cross = PlantSimEngine.GraphSimulation(mtg, mapping_cross, nsteps=4, check=true, outputs=Dict("Leaf" => (:XS,), "Plant" => (:XP,)))
    run!(sim_cross, meteo4, multirate=true, executor=SequentialEx())
    st_leaf_cross = status(sim_cross)["Leaf"][1]
    st_plant_cross = status(sim_cross)["Plant"][1]
    @test st_leaf_cross.XS == 4.0
    @test st_plant_cross.XP == 3.0
end
