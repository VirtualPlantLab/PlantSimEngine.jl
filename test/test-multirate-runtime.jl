using PlantSimEngine
using PlantSimEngine.Examples
using MultiScaleTreeGraph
using PlantMeteo
using DataFrames
using Test
using Dates

const _HAS_METEO_SAMPLER_API = isdefined(PlantMeteo, :prepare_weather_sampler) &&
                               isdefined(PlantMeteo, :RollingWindow) &&
                               isdefined(PlantMeteo, :sample_weather)

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

PlantSimEngine.@process "mrancestorsource" verbose = false
struct MRAncestorSourceModel <: AbstractMrancestorsourceModel end
PlantSimEngine.inputs_(::MRAncestorSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRAncestorSourceModel) = (Z=-Inf,)
function PlantSimEngine.run!(::MRAncestorSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.Z = 11.0
end

PlantSimEngine.@process "mrsiblingsource" verbose = false
struct MRSiblingSourceModel <: AbstractMrsiblingsourceModel end
PlantSimEngine.inputs_(::MRSiblingSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRSiblingSourceModel) = (Z=-Inf,)
function PlantSimEngine.run!(::MRSiblingSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    status.Z = 22.0
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

PlantSimEngine.@process "mrinterpsource" verbose = false
struct MRInterpSourceModel <: AbstractMrinterpsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRInterpSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRInterpSourceModel) = (XI=-Inf,)
function PlantSimEngine.run!(m::MRInterpSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XI = 2.0 * m.n[] - 1.0
end

PlantSimEngine.@process "mrinterpconsumer" verbose = false
struct MRInterpConsumerModel <: AbstractMrinterpconsumerModel end
PlantSimEngine.inputs_(::MRInterpConsumerModel) = (XI=-Inf,)
PlantSimEngine.outputs_(::MRInterpConsumerModel) = (YI=-Inf,)
function PlantSimEngine.run!(::MRInterpConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.YI = status.XI
end

PlantSimEngine.@process "mraggsource" verbose = false
struct MRAggSourceModel <: AbstractMraggsourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRAggSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRAggSourceModel) = (XA=-Inf,)
function PlantSimEngine.run!(m::MRAggSourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XA = float(m.n[])
end

PlantSimEngine.@process "mraggconsumer" verbose = false
struct MRAggConsumerModel <: AbstractMraggconsumerModel end
PlantSimEngine.inputs_(::MRAggConsumerModel) = (XA=-Inf,)
PlantSimEngine.outputs_(::MRAggConsumerModel) = (YA=-Inf,)
function PlantSimEngine.run!(::MRAggConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.YA = status.XA
end

PlantSimEngine.@process "mrdailysource" verbose = false
struct MRDailySourceModel <: AbstractMrdailysourceModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRDailySourceModel) = NamedTuple()
PlantSimEngine.outputs_(::MRDailySourceModel) = (XD=-Inf,)
function PlantSimEngine.run!(m::MRDailySourceModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XD = float(m.n[])
end

PlantSimEngine.@process "mrhourlyfromdailyconsumer" verbose = false
struct MRHourlyFromDailyConsumerModel <: AbstractMrhourlyfromdailyconsumerModel end
PlantSimEngine.inputs_(::MRHourlyFromDailyConsumerModel) = (XD=-Inf,)
PlantSimEngine.outputs_(::MRHourlyFromDailyConsumerModel) = (YD=-Inf,)
function PlantSimEngine.run!(::MRHourlyFromDailyConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.YD = status.XD
end

PlantSimEngine.@process "mrzconsumer" verbose = false
struct MRZConsumerModel <: AbstractMrzconsumerModel end
PlantSimEngine.inputs_(::MRZConsumerModel) = (Z=-Inf,)
PlantSimEngine.outputs_(::MRZConsumerModel) = (ZZ=-Inf,)
function PlantSimEngine.run!(::MRZConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.ZZ = status.Z
end

PlantSimEngine.@process "mrmissinginputconsumer" verbose = false
struct MRMissingInputConsumerModel <: AbstractMrmissinginputconsumerModel end
PlantSimEngine.inputs_(::MRMissingInputConsumerModel) = (U=-Inf,)
PlantSimEngine.outputs_(::MRMissingInputConsumerModel) = (OU=-Inf,)
function PlantSimEngine.run!(::MRMissingInputConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.OU = status.U
end

PlantSimEngine.@process "mrmeteodailyconsumer" verbose = false
struct MRMeteoDailyConsumerModel <: AbstractMrmeteodailyconsumerModel end
PlantSimEngine.inputs_(::MRMeteoDailyConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::MRMeteoDailyConsumerModel) = (MT=-Inf, MTmin=-Inf, MTmax=-Inf, MRh=-Inf, MSW=-Inf, MSWq=-Inf)
function PlantSimEngine.run!(::MRMeteoDailyConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.MT = meteo.T
    status.MTmin = meteo.Tmin
    status.MTmax = meteo.Tmax
    status.MRh = meteo.Rh
    status.MSW = meteo.Ri_SW_f
    status.MSWq = meteo.Ri_SW_q
end

PlantSimEngine.@process "mrmeteocustomconsumer" verbose = false
struct MRMeteoCustomConsumerModel <: AbstractMrmeteocustomconsumerModel end
PlantSimEngine.inputs_(::MRMeteoCustomConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::MRMeteoCustomConsumerModel) = (MRQ=-Inf, MCV=-Inf)
function PlantSimEngine.run!(::MRMeteoCustomConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.MRQ = meteo.Ri_SW_f
    status.MCV = meteo.custom_peak
end

PlantSimEngine.@process "mrrangehinta" verbose = false
struct MRRangeHintAModel <: AbstractMrrangehintaModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRRangeHintAModel) = NamedTuple()
PlantSimEngine.outputs_(::MRRangeHintAModel) = (XA=-Inf,)
function PlantSimEngine.run!(m::MRRangeHintAModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XA = float(m.n[])
end
PlantSimEngine.timestep_hint(::Type{<:MRRangeHintAModel}) = (; required=(Dates.Hour(2), Dates.Hour(4)), preferred=:finest)

PlantSimEngine.@process "mrrangehintb" verbose = false
struct MRRangeHintBModel <: AbstractMrrangehintbModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRRangeHintBModel) = NamedTuple()
PlantSimEngine.outputs_(::MRRangeHintBModel) = (XB=-Inf,)
function PlantSimEngine.run!(m::MRRangeHintBModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XB = float(m.n[])
end
PlantSimEngine.timestep_hint(::Type{<:MRRangeHintBModel}) = (Dates.Hour(3), Dates.Hour(6))

PlantSimEngine.@process "mrrangehintforced" verbose = false
struct MRRangeHintForcedModel <: AbstractMrrangehintforcedModel
    n::Base.RefValue{Int}
end
PlantSimEngine.inputs_(::MRRangeHintForcedModel) = NamedTuple()
PlantSimEngine.outputs_(::MRRangeHintForcedModel) = (XF=-Inf,)
function PlantSimEngine.run!(m::MRRangeHintForcedModel, models, status, meteo, constants=nothing, extra=nothing)
    m.n[] += 1
    status.XF = float(m.n[])
end
PlantSimEngine.timestep_hint(::Type{<:MRRangeHintForcedModel}) = (Dates.Hour(3), Dates.Hour(6))

PlantSimEngine.@process "mrmeteohintconsumer" verbose = false
struct MRMeteoHintConsumerModel <: AbstractMrmeteohintconsumerModel end
PlantSimEngine.inputs_(::MRMeteoHintConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::MRMeteoHintConsumerModel) = (HT=-Inf, HSWQ=-Inf)
function PlantSimEngine.run!(::MRMeteoHintConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.HT = meteo.T
    status.HSWQ = meteo.Ri_SW_q
end
PlantSimEngine.timestep_hint(::Type{<:MRMeteoHintConsumerModel}) = Dates.Day(1)
PlantSimEngine.meteo_hint(::Type{<:MRMeteoHintConsumerModel}) = (
    bindings=(
        T=(source=:T, reducer=MaxReducer()),
        Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
    ),
    window=CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:allow_partial),
)

@testset "Multi-rate runtime: HoldLast and conflict validation" begin
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Soil", 1, 1))
    internode = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    mapping_ok = ModelMapping(
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
    @test input_bindings(specs_leaf[:mrautosamename]).S.process == :mrsource
    @test input_bindings(specs_leaf[:mrautosamename]).S.var == :S

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

    mapping_conflict = ModelMapping(
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
    mapping_clock_trait = ModelMapping(
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
    scope = ScopeId(:global, 1)
    @test sim_clock_trait.temporal_state.last_run[ModelKey(scope, "Leaf", :mrclocksource)] == 4.0
    @test sim_clock_trait.temporal_state.last_run[ModelKey(scope, "Leaf", :mrclockconsumer)] == 3.0

    # Expectation 7: TimeStepModel override takes precedence over model timespec.
    source_counter_2 = Ref(0)
    mapping_clock_override = ModelMapping(
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
    @test sim_clock_override.temporal_state.last_run[ModelKey(scope, "Leaf", :mrclocksource)] == 4.0
    @test sim_clock_override.temporal_state.last_run[ModelKey(scope, "Leaf", :mrclockconsumer)] == 3.0

    # Expectation 7b: non-sequential executors warn and fall back to sequential behavior.
    mapping_clock_fallback_seq = ModelMapping(
        "Leaf" => (
            ModelSpec(MRClockSourceModel(Ref(0))) |> TimeStepModel(1.0),
            ModelSpec(MRClockConsumerModel()) |>
            InputBindings(; X=(process=:mrclocksource, var=:X)),
        ),
    )
    sim_clock_fallback_seq = PlantSimEngine.GraphSimulation(mtg, mapping_clock_fallback_seq, nsteps=4, check=true, outputs=Dict("Leaf" => (:X, :Y)))
    out_fallback_seq = run!(sim_clock_fallback_seq, meteo4, multirate=true, executor=SequentialEx())
    out_fallback_seq_df = convert_outputs(out_fallback_seq, DataFrame)

    mapping_clock_fallback_threaded = ModelMapping(
        "Leaf" => (
            ModelSpec(MRClockSourceModel(Ref(0))) |> TimeStepModel(1.0),
            ModelSpec(MRClockConsumerModel()) |>
            InputBindings(; X=(process=:mrclocksource, var=:X)),
        ),
    )
    sim_clock_fallback_threaded = PlantSimEngine.GraphSimulation(mtg, mapping_clock_fallback_threaded, nsteps=4, check=true, outputs=Dict("Leaf" => (:X, :Y)))
    @test_logs (:warn, r"Multi-rate MTG runs currently execute sequentially") begin
        out_fallback_threaded = run!(sim_clock_fallback_threaded, meteo4, multirate=true, executor=ThreadedEx())
        out_fallback_threaded_df = convert_outputs(out_fallback_threaded, DataFrame)
        @test out_fallback_threaded_df["Leaf"][:, :X] == out_fallback_seq_df["Leaf"][:, :X]
        @test out_fallback_threaded_df["Leaf"][:, :Y] == out_fallback_seq_df["Leaf"][:, :Y]
    end

    # Expectation 8: cross-scale hold-last resolution works with different clocks.
    # Leaf producer runs each step; Plant consumer runs every 2 steps (1, 3) and reads Leaf XS through multiscale mapping.
    source_counter_3 = Ref(0)
    mapping_cross = ModelMapping(
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

    # Expectation 8a: cross-scale producer is inferred automatically when unique.
    source_counter_3_auto = Ref(0)
    mapping_cross_auto = ModelMapping(
        "Leaf" => (
            ModelSpec(MRCrossSourceModel(source_counter_3_auto)) |> TimeStepModel(1.0),
        ),
        "Plant" => (
            ModelSpec(MRCrossConsumerModel()) |>
            MultiScaleModel([:XS => ["Leaf"]]) |>
            TimeStepModel(ClockSpec(2.0, 1.0)),
        ),
    )
    sim_cross_auto = PlantSimEngine.GraphSimulation(mtg, mapping_cross_auto, nsteps=4, check=true, outputs=Dict("Leaf" => (:XS,), "Plant" => (:XP,)))
    run!(sim_cross_auto, meteo4, multirate=true, executor=SequentialEx())
    st_plant_cross_auto = status(sim_cross_auto)["Plant"][1]
    @test st_plant_cross_auto.XP == 3.0
    spec_cross_auto = PlantSimEngine.get_model_specs(sim_cross_auto)["Plant"][:mrcrossconsumer]
    @test input_bindings(spec_cross_auto).XS.process == :mrcrosssource
    @test input_bindings(spec_cross_auto).XS.scale == "Leaf"

    # Expectation 8b: scope partitioning isolates producer streams between plants.
    scene2 = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant2_a = Node(scene2, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    plant2_b = Node(scene2, MultiScaleTreeGraph.NodeMTG("+", "Plant", 2, 1))
    internode2_a = Node(plant2_a, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    internode2_b = Node(plant2_b, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode2_a, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    Node(internode2_b, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    source_counter_scoped = Ref(0)
    mapping_scoped = ModelMapping(
        "Leaf" => (
            ModelSpec(MRCrossSourceModel(source_counter_scoped)) |> TimeStepModel(1.0) |> ScopeModel(:plant),
        ),
        "Plant" => (
            ModelSpec(MRCrossConsumerModel()) |>
            MultiScaleModel([:XS => ["Leaf"]]) |>
            TimeStepModel(1.0) |>
            ScopeModel(:plant) |>
            InputBindings(; XS=(process=:mrcrosssource, var=:XS, scale="Leaf")),
        ),
    )
    sim_scoped = PlantSimEngine.GraphSimulation(scene2, mapping_scoped, nsteps=1, check=true, outputs=Dict("Plant" => (:XP,), "Leaf" => (:XS,)))
    run!(sim_scoped, meteo, multirate=true, executor=SequentialEx())
    plant_vals = sort([st.XP for st in status(sim_scoped)["Plant"]])
    @test plant_vals == [1.0, 2.0]

    function plant_ancestor_id(node)
        current = node
        while !isnothing(current) && symbol(current) != "Plant"
            current = parent(current)
        end
        isnothing(current) && error("Expected a Plant ancestor in scoped test tree.")
        return node_id(current)
    end

    leaf_scoped_statuses = status(sim_scoped)["Leaf"]
    leaf_scoped_keys = [
        OutputKey(ScopeId(:plant, plant_ancestor_id(st.node)), "Leaf", node_id(st.node), :mrcrosssource, :XS)
        for st in leaf_scoped_statuses
    ]
    @test all(k -> haskey(sim_scoped.temporal_state.caches, k), leaf_scoped_keys)

    # Expectation 9: Interpolate policy resolves a slower producer for a faster consumer.
    # Source runs at t=1,3,5 with values 1,3,5.
    # Consumer runs every step and receives XI through Interpolate:
    # expected YI over time is [1, 1, 3, 4, 5].
    interp_counter = Ref(0)
    mapping_interp = ModelMapping(
        "Leaf" => (
            ModelSpec(MRInterpSourceModel(interp_counter)) |> TimeStepModel(ClockSpec(2.0, 1.0)),
            ModelSpec(MRInterpConsumerModel()) |>
            TimeStepModel(1.0) |>
            InputBindings(; XI=(process=:mrinterpsource, var=:XI, policy=Interpolate())),
        ),
    )
    meteo5 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 5))
    sim_interp = PlantSimEngine.GraphSimulation(mtg, mapping_interp, nsteps=5, check=true, outputs=Dict("Leaf" => (:YI,)))
    out_interp = run!(sim_interp, meteo5, multirate=true, executor=SequentialEx())
    out_interp_df = convert_outputs(out_interp, DataFrame)
    @test out_interp_df["Leaf"][:, :YI] == [1.0, 1.0, 3.0, 4.0, 5.0]

    # Expectation 10: Aggregate policy computes mean over the consumer window.
    # Source runs every step with XA=[1,2,3,4].
    # Consumer runs on t=1,3 (ClockSpec(2,1)):
    # - at t=1: window [0,1] => mean([1]) = 1
    # - at t=3: window [2,3] => mean([2,3]) = 2.5
    # Output YA over time is therefore [1, 1, 2.5, 2.5].
    agg_counter = Ref(0)
    mapping_agg = ModelMapping(
        "Leaf" => (
            ModelSpec(MRAggSourceModel(agg_counter)) |> TimeStepModel(1.0),
            ModelSpec(MRAggConsumerModel()) |>
            TimeStepModel(ClockSpec(2.0, 1.0)) |>
            InputBindings(; XA=(process=:mraggsource, var=:XA, policy=Aggregate())),
        ),
    )
    sim_agg = PlantSimEngine.GraphSimulation(mtg, mapping_agg, nsteps=4, check=true, outputs=Dict("Leaf" => (:YA,)))
    out_agg = run!(sim_agg, meteo4, multirate=true, executor=SequentialEx())
    out_agg_df = convert_outputs(out_agg, DataFrame)
    @test out_agg_df["Leaf"][:, :YA] == [1.0, 1.0, 2.5, 2.5]
    @test status(sim_agg)["Leaf"][1].YA == 2.5
    nid_agg = node_id(status(sim_agg)["Leaf"][1].node)
    key_agg = OutputKey(scope, "Leaf", nid_agg, :mraggsource, :XA)
    @test haskey(sim_agg.temporal_state.streams, key_agg)
    @test length(sim_agg.temporal_state.streams[key_agg]) <= 2
    @test sim_agg.temporal_state.producer_horizons[("Leaf", :mraggsource, :XA)] == 2.0

    # Expectation 11: parameterized Aggregate reducer is applied per window.
    # Source XA=[1,2,3,4], consumer runs at t=1,3 with reducer=MaxReducer().
    # YA over time is [1,1,3,3].
    agg_counter_max = Ref(0)
    mapping_agg_max = ModelMapping(
        "Leaf" => (
            ModelSpec(MRAggSourceModel(agg_counter_max)) |> TimeStepModel(1.0),
            ModelSpec(MRAggConsumerModel()) |>
            TimeStepModel(ClockSpec(2.0, 1.0)) |>
            InputBindings(; XA=(process=:mraggsource, var=:XA, policy=Aggregate(MaxReducer()))),
        ),
    )
    sim_agg_max = PlantSimEngine.GraphSimulation(mtg, mapping_agg_max, nsteps=4, check=true, outputs=Dict("Leaf" => (:YA,)))
    out_agg_max = run!(sim_agg_max, meteo4, multirate=true, executor=SequentialEx())
    out_agg_max_df = convert_outputs(out_agg_max, DataFrame)
    @test out_agg_max_df["Leaf"][:, :YA] == [1.0, 1.0, 3.0, 3.0]

    # Expectation 12: parameterized Integrate reducer (callable) is applied per window.
    # Source XA=[1,2,3,4], consumer runs at t=1,3 with reducer=max-min.
    # YA over time is [0,0,1,1].
    agg_counter_callable = Ref(0)
    mapping_integrate_callable = ModelMapping(
        "Leaf" => (
            ModelSpec(MRAggSourceModel(agg_counter_callable)) |> TimeStepModel(1.0),
            ModelSpec(MRAggConsumerModel()) |>
            TimeStepModel(ClockSpec(2.0, 1.0)) |>
            InputBindings(; XA=(process=:mraggsource, var=:XA, policy=Integrate(vals -> maximum(vals) - minimum(vals)))),
        ),
    )
    sim_integrate_callable = PlantSimEngine.GraphSimulation(mtg, mapping_integrate_callable, nsteps=4, check=true, outputs=Dict("Leaf" => (:YA,)))
    out_integrate_callable = run!(sim_integrate_callable, meteo4, multirate=true, executor=SequentialEx())
    out_integrate_callable_df = convert_outputs(out_integrate_callable, DataFrame)
    @test out_integrate_callable_df["Leaf"][:, :YA] == [0.0, 0.0, 1.0, 1.0]

    # Expectation 13: Interpolate policy supports hold mode and hold extrapolation.
    # Source runs at t=1,3,5 with values 1,3,5. Consumer runs each step.
    # With Interpolate(mode=:hold, extrapolation=:hold), YI is [1,1,3,3,5,5].
    interp_counter_hold = Ref(0)
    mapping_interp_hold = ModelMapping(
        "Leaf" => (
            ModelSpec(MRInterpSourceModel(interp_counter_hold)) |> TimeStepModel(ClockSpec(2.0, 1.0)),
            ModelSpec(MRInterpConsumerModel()) |>
            TimeStepModel(1.0) |>
            InputBindings(; XI=(process=:mrinterpsource, var=:XI, policy=Interpolate(; mode=:hold, extrapolation=:hold))),
        ),
    )
    meteo6 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 6))
    sim_interp_hold = PlantSimEngine.GraphSimulation(mtg, mapping_interp_hold, nsteps=6, check=true, outputs=Dict("Leaf" => (:YI,)))
    out_interp_hold = run!(sim_interp_hold, meteo6, multirate=true, executor=SequentialEx())
    out_interp_hold_df = convert_outputs(out_interp_hold, DataFrame)
    @test out_interp_hold_df["Leaf"][:, :YI] == [1.0, 1.0, 3.0, 3.0, 5.0, 5.0]

    # Expectation 14: daily producer to hourly consumer within same day uses hold-last.
    # Source runs at t=1 and t=25 (ClockSpec(24,1)), consumer runs every step.
    # YD should stay at 1 for t=1..24, then switch to 2 at t=25.
    daily_counter = Ref(0)
    mapping_daily_hourly = ModelMapping(
        "Leaf" => (
            ModelSpec(MRDailySourceModel(daily_counter)) |> TimeStepModel(ClockSpec(24.0, 1.0)),
            ModelSpec(MRHourlyFromDailyConsumerModel()) |>
            TimeStepModel(1.0) |>
            InputBindings(; XD=(process=:mrdailysource, var=:XD)),
        ),
    )
    meteo26 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65)], 26))
    sim_daily_hourly = PlantSimEngine.GraphSimulation(mtg, mapping_daily_hourly, nsteps=26, check=true, outputs=Dict("Leaf" => (:YD,)))
    out_daily_hourly = run!(sim_daily_hourly, meteo26, multirate=true, executor=SequentialEx())
    out_daily_hourly_df = convert_outputs(out_daily_hourly, DataFrame)
    @test out_daily_hourly_df["Leaf"][1:24, :YD] == fill(1.0, 24)
    @test out_daily_hourly_df["Leaf"][25:26, :YD] == [2.0, 2.0]
    @test sim_daily_hourly.temporal_state.last_run[ModelKey(scope, "Leaf", :mrdailysource)] == 25.0
    @test sim_daily_hourly.temporal_state.last_run[ModelKey(scope, "Leaf", :mrhourlyfromdailyconsumer)] == 26.0

    # Expectation 15: period-based timestep uses timeline base-step conversion.
    # Meteo has duration=Hour(1), source uses Day(1) => runs on t=1 and t=25.
    daily_counter_period = Ref(0)
    mapping_daily_period = ModelMapping(
        "Leaf" => (
            ModelSpec(MRDailySourceModel(daily_counter_period)) |> TimeStepModel(Dates.Day(1)),
            ModelSpec(MRHourlyFromDailyConsumerModel()) |>
            TimeStepModel(1.0) |>
            InputBindings(; XD=(process=:mrdailysource, var=:XD)),
        ),
    )
    meteo_hourly = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, duration=Dates.Hour(1))], 26))
    sim_daily_period = PlantSimEngine.GraphSimulation(mtg, mapping_daily_period, nsteps=26, check=true, outputs=Dict("Leaf" => (:YD,)))
    out_daily_period = run!(sim_daily_period, meteo_hourly, multirate=true, executor=SequentialEx())
    out_daily_period_df = convert_outputs(out_daily_period, DataFrame)
    @test out_daily_period_df["Leaf"][1:24, :YD] == fill(1.0, 24)
    @test out_daily_period_df["Leaf"][25:26, :YD] == [2.0, 2.0]
    @test sim_daily_period.temporal_state.last_run[ModelKey(scope, "Leaf", :mrdailysource)] == 25.0

    # Expectation 16: model timesteps shorter than meteo base step are rejected.
    mapping_substep_period = ModelMapping(
        "Leaf" => (
            ModelSpec(MRDailySourceModel(Ref(0))) |> TimeStepModel(Dates.Minute(30)),
        ),
    )
    sim_substep_period = PlantSimEngine.GraphSimulation(mtg, mapping_substep_period, nsteps=26, check=true, outputs=Dict("Leaf" => (:XD,)))
    @test_throws "shorter than simulation base step" run!(sim_substep_period, meteo_hourly, multirate=true, executor=SequentialEx())

    # Expectation 17: timestep hints infer a consensus for range-only models and keep explicit overrides.
    range_counter_a = Ref(0)
    range_counter_b = Ref(0)
    range_counter_forced = Ref(0)
    mapping_timestep_hints = ModelMapping(
        "Leaf" => (
            ModelSpec(MRRangeHintAModel(range_counter_a)),
            ModelSpec(MRRangeHintBModel(range_counter_b)),
            ModelSpec(MRRangeHintForcedModel(range_counter_forced)) |> TimeStepModel(Dates.Hour(2)),
        ),
    )
    meteo8h = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, duration=Dates.Hour(1))], 8))
    sim_timestep_hints = PlantSimEngine.GraphSimulation(mtg, mapping_timestep_hints, nsteps=8, check=true, outputs=Dict("Leaf" => (:XA, :XB, :XF)))
    run!(sim_timestep_hints, meteo8h, multirate=true, executor=SequentialEx())
    specs_hints = PlantSimEngine.get_model_specs(sim_timestep_hints)["Leaf"]
    @test Dates.value(Dates.Second(PlantSimEngine.timestep(specs_hints[:mrrangehinta]))) == 10800
    @test Dates.value(Dates.Second(PlantSimEngine.timestep(specs_hints[:mrrangehintb]))) == 10800
    @test PlantSimEngine.timestep(specs_hints[:mrrangehintforced]) == Dates.Hour(2)
    @test status(sim_timestep_hints)["Leaf"][1].XA == 3.0
    @test status(sim_timestep_hints)["Leaf"][1].XB == 3.0
    @test status(sim_timestep_hints)["Leaf"][1].XF == 4.0

    io_hints = IOBuffer()
    explained_hints = PlantSimEngine.explain_model_specs(sim_timestep_hints; io=io_hints)
    explain_hints_txt = String(take!(io_hints))
    @test any(r -> r.process == :mrrangehinta && Dates.value(Dates.Second(r.timestep)) == 10800, explained_hints)
    @test occursin("Leaf/mrrangehinta", explain_hints_txt)

    if _HAS_METEO_SAMPLER_API
        # Expectation 18: meteo is sampled at model clock using default weather aggregation.
        mapping_meteo_default = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoDailyConsumerModel()) |>
                TimeStepModel(ClockSpec(2.0, 1.0)),
            ),
        )
        meteo_mr = Weather([
            Atmosphere(T=10.0, Wind=1.0, Rh=0.50, P=100.0, Ri_SW_f=100.0, duration=Dates.Hour(1), custom_var=1.0),
            Atmosphere(T=20.0, Wind=1.0, Rh=0.60, P=100.0, Ri_SW_f=200.0, duration=Dates.Hour(1), custom_var=2.0),
            Atmosphere(T=30.0, Wind=1.0, Rh=0.70, P=100.0, Ri_SW_f=300.0, duration=Dates.Hour(1), custom_var=3.0),
            Atmosphere(T=40.0, Wind=1.0, Rh=0.80, P=100.0, Ri_SW_f=400.0, duration=Dates.Hour(1), custom_var=4.0),
        ])
        sim_meteo_default = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_default, nsteps=4, check=true, outputs=Dict("Leaf" => (:MT, :MTmin, :MTmax, :MRh, :MSW, :MSWq)))
        out_meteo_default = run!(sim_meteo_default, meteo_mr, multirate=true, executor=SequentialEx())
        out_meteo_default_df = convert_outputs(out_meteo_default, DataFrame)
        @test out_meteo_default_df["Leaf"][:, :MT] == [10.0, 10.0, 25.0, 25.0]
        @test out_meteo_default_df["Leaf"][:, :MTmin] == [10.0, 10.0, 20.0, 20.0]
        @test out_meteo_default_df["Leaf"][:, :MTmax] == [10.0, 10.0, 30.0, 30.0]
        @test out_meteo_default_df["Leaf"][:, :MRh] == [0.5, 0.5, 0.65, 0.65]
        @test out_meteo_default_df["Leaf"][:, :MSW] == [100.0, 100.0, 250.0, 250.0]
        @test isapprox(out_meteo_default_df["Leaf"][:, :MSWq][1], 0.36; atol=1.0e-9)
        @test isapprox(out_meteo_default_df["Leaf"][:, :MSWq][3], 1.8; atol=1.0e-9)

        # Expectation 18b: MTG + mapping entrypoint preserves multi-rate meteo sampling.
        out_meteo_default_mtg = run!(
            mtg,
            mapping_meteo_default,
            meteo_mr;
            multirate=true,
            executor=SequentialEx(),
            tracked_outputs=Dict("Leaf" => (:MT, :MTmin, :MTmax, :MRh, :MSW, :MSWq)),
        )
        out_meteo_default_mtg_df = convert_outputs(out_meteo_default_mtg, DataFrame)
        @test out_meteo_default_mtg_df["Leaf"][:, :MT] == [10.0, 10.0, 25.0, 25.0]
        @test out_meteo_default_mtg_df["Leaf"][:, :MTmin] == [10.0, 10.0, 20.0, 20.0]
        @test out_meteo_default_mtg_df["Leaf"][:, :MTmax] == [10.0, 10.0, 30.0, 30.0]
        @test out_meteo_default_mtg_df["Leaf"][:, :MRh] == [0.5, 0.5, 0.65, 0.65]
        @test out_meteo_default_mtg_df["Leaf"][:, :MSW] == [100.0, 100.0, 250.0, 250.0]
        @test isapprox(out_meteo_default_mtg_df["Leaf"][:, :MSWq][1], 0.36; atol=1.0e-9)
        @test isapprox(out_meteo_default_mtg_df["Leaf"][:, :MSWq][3], 1.8; atol=1.0e-9)

        # Expectation 19: meteo bindings allow custom reducers and variable remapping.
        mapping_meteo_custom = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoCustomConsumerModel()) |>
                TimeStepModel(ClockSpec(2.0, 1.0)) |>
                MeteoBindings(
                    ;
                    Ri_SW_f=RadiationEnergy(),
                    custom_peak=(source=:custom_var, reducer=MaxReducer()),
                ),
            ),
        )
        sim_meteo_custom = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_custom, nsteps=4, check=true, outputs=Dict("Leaf" => (:MRQ, :MCV)))
        out_meteo_custom = run!(sim_meteo_custom, meteo_mr, multirate=true, executor=SequentialEx())
        out_meteo_custom_df = convert_outputs(out_meteo_custom, DataFrame)
        @test isapprox.(out_meteo_custom_df["Leaf"][:, :MRQ], [0.36, 0.36, 1.8, 1.8], atol=1.0e-9) |> all
        @test out_meteo_custom_df["Leaf"][:, :MCV] == [1.0, 1.0, 3.0, 3.0]

        # Expectation 20: meteo hints infer default bindings/window when ModelSpec does not provide them.
        meteo_hint_rows = Weather([
            Atmosphere(
                date=DateTime(2025, 2, 1, h - 1, 0, 0),
                duration=Dates.Hour(1),
                T=float(h),
                Wind=1.0,
                Rh=0.50,
                P=100.0,
                Ri_SW_f=100.0,
            )
            for h in 1:24
        ])
        mapping_meteo_hint = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoHintConsumerModel()),
            ),
        )
        sim_meteo_hint = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_hint, nsteps=24, check=true, outputs=Dict("Leaf" => (:HT, :HSWQ)))
        out_meteo_hint = run!(sim_meteo_hint, meteo_hint_rows, multirate=true, executor=SequentialEx())
        out_meteo_hint_df = convert_outputs(out_meteo_hint, DataFrame)
        spec_meteo_hint = PlantSimEngine.get_model_specs(sim_meteo_hint)["Leaf"][:mrmeteohintconsumer]
        @test PlantSimEngine.timestep(spec_meteo_hint) == Dates.Day(1)
        @test meteo_window(spec_meteo_hint) isa CalendarWindow
        @test meteo_bindings(spec_meteo_hint).T.reducer isa MaxReducer
        @test out_meteo_hint_df["Leaf"][1, :HT] == 24.0
        @test isapprox(out_meteo_hint_df["Leaf"][1, :HSWQ], 8.64; atol=1.0e-9)

        # Expectation 21: CalendarWindow(:day, :current_period) aggregates over the civil day
        # (including future timesteps in the same day).
        meteo_calendar = Weather(vcat(
            [
                Atmosphere(
                    date=DateTime(2025, 1, 1, h - 1, 0, 0),
                    duration=Dates.Hour(1),
                    T=float(h),
                    Wind=1.0,
                    Rh=0.50,
                    P=100.0,
                    Ri_SW_f=100.0
                )
                for h in 1:24
            ],
            [
                Atmosphere(
                    date=DateTime(2025, 1, 2, h - 1, 0, 0),
                    duration=Dates.Hour(1),
                    T=float(100 + h),
                    Wind=1.0,
                    Rh=0.60,
                    P=100.0,
                    Ri_SW_f=200.0
                )
                for h in 1:24
            ],
        ))

        mapping_meteo_calendar_current = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoDailyConsumerModel()) |>
                TimeStepModel(1.0) |>
                MeteoWindow(CalendarWindow(:day; anchor=:current_period, week_start=1, completeness=:allow_partial)),
            ),
        )
        sim_meteo_calendar_current = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_calendar_current, nsteps=48, check=true, outputs=Dict("Leaf" => (:MT, :MTmin, :MTmax, :MRh, :MSW, :MSWq)))
        out_meteo_calendar_current = run!(sim_meteo_calendar_current, meteo_calendar, multirate=true, executor=SequentialEx())
        out_meteo_calendar_current_df = convert_outputs(out_meteo_calendar_current, DataFrame)
        @test out_meteo_calendar_current_df["Leaf"][1, :MT] == 12.5
        @test out_meteo_calendar_current_df["Leaf"][10, :MT] == 12.5
        @test out_meteo_calendar_current_df["Leaf"][25, :MT] == 112.5
        @test out_meteo_calendar_current_df["Leaf"][1, :MTmin] == 1.0
        @test out_meteo_calendar_current_df["Leaf"][1, :MTmax] == 24.0
        @test out_meteo_calendar_current_df["Leaf"][25, :MTmin] == 101.0
        @test out_meteo_calendar_current_df["Leaf"][25, :MTmax] == 124.0
        @test isapprox(out_meteo_calendar_current_df["Leaf"][1, :MSWq], 8.64; atol=1.0e-9)
        @test isapprox(out_meteo_calendar_current_df["Leaf"][25, :MSWq], 17.28; atol=1.0e-9)

        # Expectation 22: CalendarWindow(:day, :previous_complete_period) uses previous day.
        mapping_meteo_calendar_prev = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoDailyConsumerModel()) |>
                TimeStepModel(1.0) |>
                MeteoWindow(CalendarWindow(:day; anchor=:previous_complete_period, week_start=1, completeness=:allow_partial)),
            ),
        )
        sim_meteo_calendar_prev = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_calendar_prev, nsteps=48, check=true, outputs=Dict("Leaf" => (:MT, :MTmin, :MTmax, :MRh, :MSW, :MSWq)))
        out_meteo_calendar_prev = run!(sim_meteo_calendar_prev, meteo_calendar, multirate=true, executor=SequentialEx())
        out_meteo_calendar_prev_df = convert_outputs(out_meteo_calendar_prev, DataFrame)
        @test out_meteo_calendar_prev_df["Leaf"][30, :MT] == 12.5
        @test out_meteo_calendar_prev_df["Leaf"][30, :MTmin] == 1.0
        @test out_meteo_calendar_prev_df["Leaf"][30, :MTmax] == 24.0

        # Expectation 23: strict previous-complete-period errors when unavailable.
        mapping_meteo_calendar_prev_strict = ModelMapping(
            "Leaf" => (
                ModelSpec(MRMeteoDailyConsumerModel()) |>
                TimeStepModel(1.0) |>
                MeteoWindow(CalendarWindow(:day; anchor=:previous_complete_period, week_start=1, completeness=:strict)),
            ),
        )
        sim_meteo_calendar_prev_strict = PlantSimEngine.GraphSimulation(mtg, mapping_meteo_calendar_prev_strict, nsteps=48, check=true, outputs=Dict("Leaf" => (:MT, :MTmin, :MTmax, :MRh, :MSW, :MSWq)))
        @test_throws "No period available" run!(sim_meteo_calendar_prev_strict, meteo_calendar, multirate=true, executor=SequentialEx())
    end

    # Expectation 24: ambiguous same-name inferred producer is rejected at initialization.
    mapping_ambiguous_infer = ModelMapping(
        "Leaf" => (
            MRConflict1Model(),
            MRConflict2Model(),
            MRZConsumerModel(),
        ),
    )
    @test_throws "Ambiguous inferred producer for input `Z`" PlantSimEngine.GraphSimulation(mtg, mapping_ambiguous_infer, nsteps=1, check=true, outputs=Dict("Leaf" => (:ZZ,)))

    # Expectation 24a: stream-only publishers are ignored by auto input producer inference.
    mapping_stream_only_infer = ModelMapping(
        "Leaf" => (
            MRConflict1Model(),
            ModelSpec(MRConflict2Model()) |> OutputRouting(; Z=:stream_only),
            MRZConsumerModel(),
        ),
    )
    sim_stream_only_infer = PlantSimEngine.GraphSimulation(mtg, mapping_stream_only_infer, nsteps=1, check=true, outputs=Dict("Leaf" => (:ZZ,)))
    run!(sim_stream_only_infer, meteo, multirate=true, executor=SequentialEx())
    @test status(sim_stream_only_infer)["Leaf"][1].ZZ == 1.0
    spec_stream_only_infer = PlantSimEngine.get_model_specs(sim_stream_only_infer)["Leaf"][:mrzconsumer]
    @test input_bindings(spec_stream_only_infer).Z.process == :mrconflict1

    # Expectation 24b: cross-scale inference ignores sibling scales not on the same lineage.
    mapping_lineage_infer = ModelMapping(
        "Plant" => (
            MRAncestorSourceModel(),
        ),
        "Soil" => (
            MRSiblingSourceModel(),
        ),
        "Leaf" => (
            ModelSpec(MRZConsumerModel()) |>
            MultiScaleModel([:Z => "Plant"]),
        ),
    )
    sim_lineage_infer = PlantSimEngine.GraphSimulation(mtg, mapping_lineage_infer, nsteps=1, check=true, outputs=Dict("Leaf" => (:ZZ,)))
    run!(sim_lineage_infer, meteo, multirate=true, executor=SequentialEx())
    @test status(sim_lineage_infer)["Leaf"][1].ZZ == 11.0
    spec_lineage_infer = PlantSimEngine.get_model_specs(sim_lineage_infer)["Leaf"][:mrzconsumer]
    @test input_bindings(spec_lineage_infer).Z.process == :mrancestorsource
    @test input_bindings(spec_lineage_infer).Z.scale == "Plant"

    # Expectation 25: missing producer remains allowed; model can rely on initialized/forced inputs.
    mapping_missing_input = ModelMapping(
        "Leaf" => (
            MRMissingInputConsumerModel(),
            Status(U=42.0),
        ),
    )
    sim_missing_input = PlantSimEngine.GraphSimulation(mtg, mapping_missing_input, nsteps=1, check=true, outputs=Dict("Leaf" => (:OU,)))
    run!(sim_missing_input, meteo, multirate=true, executor=SequentialEx())
    @test status(sim_missing_input)["Leaf"][1].OU == 42.0

    # Expectation 26: invalid mapping-level API configuration fails during GraphSimulation init.
    mapping_bad_input = ModelMapping(
        "Leaf" => (
            MRSourceModel(),
            ModelSpec(MRConsumerModel()) |>
            InputBindings(; Z=(process=:mrsource, var=:S)),
        ),
    )
    @test_throws "declares binding for input `Z`" PlantSimEngine.GraphSimulation(mtg, mapping_bad_input, nsteps=1, check=true, outputs=Dict("Leaf" => (:B,)))

    mapping_bad_process = ModelMapping(
        "Leaf" => (
            ModelSpec(MRConsumerModel()) |>
            InputBindings(; C=(process=:unknown_process, var=:S)),
        ),
    )
    @test_throws "Unknown source process `unknown_process`" PlantSimEngine.GraphSimulation(mtg, mapping_bad_process, nsteps=1, check=true, outputs=Dict("Leaf" => (:B,)))

    mapping_bad_routing = ModelMapping(
        "Leaf" => (
            ModelSpec(MRSourceModel()) |>
            OutputRouting(; Z=:stream_only),
        ),
    )
    @test_throws "declares routing for output `Z`" PlantSimEngine.GraphSimulation(mtg, mapping_bad_routing, nsteps=1, check=true, outputs=Dict("Leaf" => (:S,)))

    mapping_bad_interp_mode = ModelMapping(
        "Leaf" => (
            MRSourceModel(),
            ModelSpec(MRConsumerModel()) |>
            InputBindings(; C=(process=:mrsource, var=:S, policy=Interpolate(:spline))),
        ),
    )
    @test_throws "Invalid interpolation mode `spline`" PlantSimEngine.GraphSimulation(mtg, mapping_bad_interp_mode, nsteps=1, check=true, outputs=Dict("Leaf" => (:B,)))

    @test_throws "Unsupported reducer value" Aggregate(:median)

    mapping_bad_period = ModelMapping(
        "Leaf" => (
            ModelSpec(MRDailySourceModel(Ref(0))) |> TimeStepModel(Dates.Month(1)),
        ),
    )
    @test_throws "non-fixed periods are not supported" PlantSimEngine.GraphSimulation(mtg, mapping_bad_period, nsteps=1, check=true, outputs=Dict("Leaf" => (:XD,)))

    mapping_bad_scope = ModelMapping(
        "Leaf" => (
            ModelSpec(MRSourceModel()) |> ScopeModel(:invalid_scope),
        ),
    )
    @test_throws "Invalid scope selector" PlantSimEngine.GraphSimulation(mtg, mapping_bad_scope, nsteps=1, check=true, outputs=Dict("Leaf" => (:S,)))

    mapping_bad_meteo = ModelMapping(
        "Leaf" => (
            ModelSpec(MRMeteoCustomConsumerModel()) |>
            MeteoBindings(; Ri_SW_f=(source=:Ri_SW_f, badfield=:oops)),
        ),
    )
    @test_throws "unsupported fields" PlantSimEngine.GraphSimulation(mtg, mapping_bad_meteo, nsteps=1, check=true, outputs=Dict("Leaf" => (:MRQ,)))

    @test_throws "Unsupported MeteoBindings value" ModelMapping(
        "Leaf" => (
            ModelSpec(MRMeteoCustomConsumerModel()) |>
            MeteoBindings(; Ri_SW_f=:radiation_energy),
        ),
    )

    @test_throws "Unsupported MeteoWindow value" ModelMapping(
        "Leaf" => (
            ModelSpec(MRMeteoCustomConsumerModel()) |>
            MeteoWindow("day"),
        ),
    )

    PlantSimEngine.@process "mrbadhintmodel" verbose = false
    struct MRBadHintModel <: AbstractMrbadhintmodelModel end
    PlantSimEngine.inputs_(::MRBadHintModel) = NamedTuple()
    PlantSimEngine.outputs_(::MRBadHintModel) = (X=-Inf,)
    PlantSimEngine.run!(::MRBadHintModel, models, status, meteo, constants=nothing, extra=nothing) = (status.X = 1.0)
    PlantSimEngine.timestep_hint(::Type{<:MRBadHintModel}) = "hourly"

    mapping_bad_hint = ModelMapping(
        "Leaf" => (
            ModelSpec(MRBadHintModel()),
        ),
    )
    @test_throws "Invalid `timestep_hint`" PlantSimEngine.GraphSimulation(mtg, mapping_bad_hint, nsteps=1, check=true, outputs=Dict("Leaf" => (:X,)))
end
