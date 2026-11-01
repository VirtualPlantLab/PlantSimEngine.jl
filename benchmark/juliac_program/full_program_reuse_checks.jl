isdefined(Main, :ReusableProgram) || include(joinpath(@__DIR__, "app", "src", "program.jl"))

module FullProgramReuseChecks
using Dates
using Test
using PlantSimEngine
import MultiScaleTreeGraph as MTG
import ..ReusableProgram as RP
const PSE = PlantSimEngine
const NativeNode = MTG.Node{MTG.NodeMTG,NamedTuple{(),Tuple{}}}

function _node(id, category, level, parent=nothing)
    node = NativeNode(id, nothing, NativeNode[], MTG.NodeMTG(isnothing(parent) ? :/ : :+, category, 1, level), NamedTuple(), nothing)
    isnothing(parent) || MTG.addchild!(parent, node)
    return node
end
function _tree(ids=Int[])
    root = _node(1, :Scene, 0)
    plant = _node(2, :Plant, 1, root)
    for id in ids
        _node(id, :Leaf, 2, plant)
    end
    return root
end
_empty_objects(initial) = map(_ -> typeof((object_id=ObjectId(1), values=NamedTuple()))[], initial)
function _status(state, id)
    slot, row = state.locations[id]
    return state.cohorts[slot].rows[row]
end
_application(model, name, category; kwargs...) = ModelSpec(model; name,
    on=Many(scale=category), every=Day(1), kwargs...)
_xs() = Many(scale=:Leaf, within=SelfPlant(), application=:source, var=:x)
_tick(multiplicity=Many) = multiplicity(scale=:Leaf, within=SelfPlant(), application=:tick)

PSE.@process "reuse_source" verbose = false
struct Source <: AbstractReuse_SourceModel
    fail_id::Int
end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(::Source) = (x=1.0,)
PSE.environment_inputs_(::Source) = (delta=0.0, order=Int[])
function PSE.run!(model::Source, status, environment, constants, context)
    id = PSE.object_id(context).value
    push!(environment.order, id)
    status.x += environment.delta
    id == model.fail_id && error("intentional ordered partial failure")
    return nothing
end

PSE.@process "reuse_tick" verbose = false
struct Tick <: AbstractReuse_TickModel end
PSE.inputs_(::Tick) = NamedTuple()
PSE.outputs_(::Tick) = (tick_count=0,)
PSE.run!(::Tick, status, environment, constants, context) = (status.tick_count += 1; nothing)

PSE.@process "reuse_observer" verbose = false
struct Observer <: AbstractReuse_ObserverModel end
PSE.inputs_(::Observer) = (xs=Required(AbstractVector),)
PSE.outputs_(::Observer) = (total=0.0, seen_ids=Int[], call_ids=Int[])
function PSE.run!(::Observer, status, environment, constants, context)
    view = PSE.bound_input(context, :xs)
    status.total = sum(view)
    status.seen_ids = [id.value for id in PSE.object_ids(view)]
    targets = PSE.call_targets(context, :ticks)
    status.call_ids = [target.object_id.value for target in targets]
    for target in targets
        PSE.run_call!(target; publish=true)
    end
    return nothing
end
function _observer_state(; program=nothing, fail_id=-1)
    specs = (_application(Source(fail_id), :source, :Leaf),
        _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(ticks=_tick(),)),
        _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    program = isnothing(program) ? RP.prepare(specs; initial) : program
    return RP.instantiate(program, map(spec -> spec.model, specs), _tree([30, 10]);
        initial, objects=_empty_objects(initial), retain=true)
end

PSE.@process "reuse_initializer" verbose = false
struct Initialize <: AbstractReuse_InitializerModel end
PSE.inputs_(::Initialize) = NamedTuple()
PSE.outputs_(::Initialize) = (initialized=0,)
PSE.run!(::Initialize, status, environment, constants, context) = (status.initialized += 1; nothing)
PSE.@process "reuse_creator" verbose = false
struct Creator <: AbstractReuse_CreatorModel end
PSE.inputs_(::Creator) = (xs=Required(AbstractVector),)
PSE.outputs_(::Creator) = (born=false, before_many=0, after_many=0,
    before_calls=0, after_calls=0, targeted_ticks=0, initializations=0)
function PSE.run!(::Creator, status, environment, constants, context)
    status.before_many = length(PSE.bound_input(context, :xs))
    status.before_calls = length(PSE.call_targets(context, :all_ticks))
    status.born && return nothing
    newborn = PSE.add_organ!(PSE.source_node(context, ObjectId(2)), context, :+, :Leaf, 2;
        id=5, index=1, initial_status=(x=20.0,))
    status.after_many = length(PSE.bound_input(context, :xs))
    status.after_calls = length(PSE.call_targets(context, :all_ticks))
    id = PSE.object_id(context, newborn)
    target = only(PSE.run_call!(context, :one_tick; objects=id))
    status.targeted_ticks = target.status.tick_count
    initialized = PSE.run_initializer!(context, :initialize, id)
    status.initializations = initialized.initialized
    status.born = true
    return nothing
end
function _growth_state()
    specs = (_application(Source(-1), :source, :Leaf),
        _application(Initialize(), :initialize, :Leaf),
        _application(Creator(), :creator, :Plant; inputs=(xs=_xs(),),
            calls=(all_ticks=_tick(), one_tick=_tick(One),
                initialize=Initializer(One(scale=:Leaf, within=SelfPlant(), application=:initialize)))),
        _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(ticks=_tick(),)),
        _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return RP.instantiate(RP.prepare(specs; initial), map(spec -> spec.model, specs), _tree();
        initial, objects=_empty_objects(initial), retain=true)
end

PSE.@process "reuse_optional_observer" verbose = false
struct OptionalObserver <: AbstractReuse_Optional_ObserverModel end
PSE.inputs_(::OptionalObserver) = (value=Default(-1.0), xs=Required(AbstractVector))
PSE.outputs_(::OptionalObserver) = (observed=0.0, source_count=0)
function PSE.run!(::OptionalObserver, status, environment, constants, context)
    status.observed = status.value
    status.source_count = length(PSE.bound_input(context, :xs))
    return nothing
end
PSE.@process "reuse_delayed_creator" verbose = false
struct DelayedCreator <: AbstractReuse_Delayed_CreatorModel end
PSE.inputs_(::DelayedCreator) = NamedTuple()
PSE.outputs_(::DelayedCreator) = (delayed_born=false,)
PSE.environment_inputs_(::DelayedCreator) = (create=false,)
function PSE.run!(::DelayedCreator, status, environment, constants, context)
    (status.delayed_born || !environment.create) && return nothing
    PSE.add_organ!(PSE.source_node(context, ObjectId(2)), context, :+, :Leaf, 2;
        id=5, index=1, initial_status=(x=20.0,))
    status.delayed_born = true
    return nothing
end
function _optional_state()
    optional = OptionalOne(scale=:Leaf, within=SelfPlant(), application=:source, var=:x)
    specs = (_application(Source(-1), :source, :Leaf),
        _application(DelayedCreator(), :delayed_creator, :Plant),
        _application(OptionalObserver(), :optional, :Plant; inputs=(value=optional, xs=_xs())))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return RP.instantiate(RP.prepare(specs; initial), map(spec -> spec.model, specs), _tree();
        initial, objects=_empty_objects(initial), retain=true)
end

PSE.@process "reuse_one_cardinality_creator" verbose = false
struct OneCardinalityCreator <: AbstractReuse_One_Cardinality_CreatorModel end
PSE.inputs_(::OneCardinalityCreator) = (counts=Required(AbstractVector),)
PSE.outputs_(::OneCardinalityCreator) = (initial_targets=0, first_ticks=0, reached_after_second=false)
function PSE.run!(::OneCardinalityCreator, status, environment, constants, context)
    status.initial_targets = length(PSE.bound_input(context, :counts))
    parent = PSE.source_node(context, ObjectId(2))
    first_leaf = PSE.add_organ!(parent, context, :+, :Leaf, 2; id=5, index=1)
    first_id = PSE.object_id(context, first_leaf)
    first_target = only(PSE.run_call!(context, :one_tick; objects=first_id, publish=true))
    status.first_ticks = first_target.status.tick_count
    PSE.add_organ!(parent, context, :+, :Leaf, 2; id=6, index=2)
    # The prior successful targeted One has populated its membership cache. The
    # second birth must invalidate full-scope cardinality before any second call.
    PSE.run_call!(context, :one_tick; objects=first_id, publish=true)
    status.reached_after_second = true
    return nothing
end
function _one_cardinality_state(; multiplicity=One)
    specs = (_application(OneCardinalityCreator(), :one_creator, :Plant;
        inputs=(counts=Many(scale=:Leaf, within=SelfPlant(), application=:tick, var=:tick_count),),
        calls=(one_tick=_tick(multiplicity),)), _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return RP.instantiate(RP.prepare(specs; initial), map(spec -> spec.model, specs), _tree();
        initial, objects=_empty_objects(initial), retain=true)
end

PSE.@process "reuse_optional_call_probe" verbose = false
struct OptionalCallProbe <: AbstractReuse_Optional_Call_ProbeModel end
PSE.inputs_(::OptionalCallProbe) = (counts=Required(AbstractVector),)
PSE.outputs_(::OptionalCallProbe) = (source_count=0, target_count=-1)
function PSE.run!(::OptionalCallProbe, status, environment, constants, context)
    status.source_count = length(PSE.bound_input(context, :counts))
    targets = PSE.call_targets(context, :optional)
    status.target_count = length(targets)
    for target in targets
        PSE.run_call!(target; publish=true)
    end
    return nothing
end
function _optional_call_state(ids)
    specs = (_application(OptionalCallProbe(), :optional_caller, :Plant;
        inputs=(counts=Many(scale=:Leaf, within=SelfPlant(), application=:tick, var=:tick_count),),
        calls=(optional=_tick(OptionalOne),)), _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return RP.instantiate(RP.prepare(specs; initial), map(spec -> spec.model, specs), _tree(ids);
        initial, objects=_empty_objects(initial), retain=true)
end

PSE.@process "reuse_array_producer" verbose = false
struct ArrayProducer <: AbstractReuse_Array_ProducerModel end
PSE.inputs_(::ArrayProducer) = NamedTuple()
PSE.outputs_(::ArrayProducer) = (payload=[1.0], unused=0)
function PSE.run!(::ArrayProducer, status, environment, constants, context)
    status.payload[1] += 1.0
    status.unused += 1
    return nothing
end
PSE.@process "reuse_array_update" verbose = false
struct ArrayUpdate <: AbstractReuse_Array_UpdateModel end
PSE.inputs_(::ArrayUpdate) = (payload=Required(AbstractVector),)
PSE.outputs_(::ArrayUpdate) = (payload=[1.0],)
PSE.run!(::ArrayUpdate, status, environment, constants, context) = (status.payload[1] += 100.0; nothing)
PSE.@process "reuse_array_mutator" verbose = false
struct ArrayMutator <: AbstractReuse_Array_MutatorModel end
PSE.inputs_(::ArrayMutator) = (previous_payload=Required(AbstractVector),)
PSE.outputs_(::ArrayMutator) = (saw_a=0.0,)
function PSE.run!(::ArrayMutator, status, environment, constants, context)
    status.saw_a = status.previous_payload[1]
    status.previous_payload[1] = 9999.0
    return nothing
end
PSE.@process "reuse_array_reader" verbose = false
struct ArrayReader <: AbstractReuse_Array_ReaderModel end
PSE.inputs_(::ArrayReader) = (previous_payload=Required(AbstractVector),)
PSE.outputs_(::ArrayReader) = (saw_b=0.0,)
PSE.run!(::ArrayReader, status, environment, constants, context) = (status.saw_b = status.previous_payload[1]; nothing)
function _array_state(retain)
    previous = (PreviousTimeStep(:previous_payload) => One(within=Self(), application=:producer, var=:payload),)
    specs = (_application(ArrayProducer(), :producer, :Plant),
        _application(ArrayUpdate(), :update, :Plant; updates=Updates(:payload; after=:producer)),
        _application(ArrayMutator(), :mutator, :Plant; inputs=previous),
        _application(ArrayReader(), :reader, :Plant; inputs=previous))
    initial = (Scene=NamedTuple(), Plant=NamedTuple())
    return RP.instantiate(RP.prepare(specs; initial), map(spec -> spec.model, specs), _tree();
        initial, objects=_empty_objects(initial), retain)
end

function run_checks()
    result = @testset "Full program reuse and invalidation" begin
        @testset "stable memberships, live values and real Ref replacement" begin
            state = _observer_state()
            environment = (delta=1.0, order=Int[])
            RP.step!(state, environment)
            carrier = _status(state, 2).xs
            @test _status(state, 2).total == 4.0
            @test _status(state, 2).seen_ids == _status(state, 2).call_ids == [10, 30]
            RP.step!(state, environment)
            @test _status(state, 2).xs === carrier
            @test _status(state, 2).total == 6.0
            slot, row = state.locations[10]
            cohort = state.cohorts[slot]
            old_reference = PSE.refvalue(cohort.rows[row], :x)
            replacement = Status(merge(NamedTuple(cohort.rows[row]), (x=100.0,)))
            RP._replace_full_status!(state, cohort, row, replacement)
            RP.step!(state, environment)
            @test _status(state, 2).total == 105.0
            @test _status(state, 10).tick_count == 3
            @test old_reference[] == 3.0
            @test PSE.refvalue(_status(state, 10), :x) !== old_reference
            refreshed = _status(state, 2).xs
            _status(state, 10).x = 500.0
            RP.step!(state, environment)
            @test _status(state, 2).total == 506.0
            @test _status(state, 2).xs === refreshed
            @test environment.order == repeat([10, 30], 4)
            ticks = state.applications[3].streams.tick_count.retained
            @test [sample.step for sample in ticks if sample.object_id == 10] == [1, 2, 3, 4]
            right = _observer_state(; program=state.program)
            @test PSE.refvalue(_status(state, 10), :x) !== PSE.refvalue(_status(right, 10), :x)
            RP.step!(state, environment)
            @test _status(right, 10).x == 1.0 && _status(right, 2).total == 0.0 && right.step == 0
        end
        @testset "pending sources versus targeted newborn visibility" begin
            state = _growth_state()
            environment = (delta=1.0, order=Int[])
            RP.step!(state, environment)
            parent = _status(state, 2)
            @test (parent.before_many, parent.after_many, parent.before_calls, parent.after_calls) == (0, 0, 0, 0)
            @test parent.targeted_ticks == parent.initializations == 1
            @test parent.total == 20.0 && parent.seen_ids == parent.call_ids == [5]
            @test _status(state, 5).tick_count == 2 && _status(state, 5).initialized == 1
            RP.step!(state, environment)
            @test parent.before_many == parent.before_calls == 1
            @test parent.total == 21.0 && _status(state, 5).tick_count == 3
            @test environment.order == [5]
        end
        @testset "OptionalOne cache follows empty to singleton membership" begin
            state = _optional_state()
            observed = Float64[]; canonical = Float64[]; counts = Int[]
            for step in 1:3
                RP.step!(state, (delta=1.0, order=Int[], create=step == 2))
                push!(observed, _status(state, 2).observed)
                push!(canonical, _status(state, 2).value)
                push!(counts, _status(state, 2).source_count)
            end
            @test observed == [-1.0, 20.0, 21.0]
            @test counts == [0, 1, 1]
            _status(state, 5).x = 900.0
            RP.step!(state, (delta=1.0, order=Int[], create=false))
            @test _status(state, 2).observed == 901.0
            push!(canonical, _status(state, 2).value)
            @test canonical == [-1.0, 20.0, 21.0, 901.0]
        end
        @testset "cached manual One revalidates cardinality after another birth" begin
            state = _one_cardinality_state()
            @test_throws ArgumentError RP.step!(state, NamedTuple())
            @test _status(state, 2).initial_targets == 0 && _status(state, 2).first_ticks == 1 && !_status(state, 2).reached_after_second
            @test _status(state, 5).tick_count == 1 && _status(state, 6).tick_count == 0
            samples = state.applications[2].streams.tick_count.retained
            @test length(samples) == 1 && only(samples).object_id == 5 && only(samples).value == 1
            @test_throws ArgumentError RP.step!(state, NamedTuple())
            @test _status(state, 5).tick_count == 1 && _status(state, 6).tick_count == 0
        end
        @testset "OptionalOne calls allow zero and reject ambiguous membership" begin
            empty_state = _optional_call_state(Int[])
            RP.step!(empty_state, NamedTuple())
            @test _status(empty_state, 2).target_count == 0
            @test isempty(empty_state.applications[2].streams.tick_count.retained)
            ambiguous = _optional_call_state([30, 10])
            @test_throws ArgumentError RP.step!(ambiguous, NamedTuple())
            @test _status(ambiguous, 2).source_count == 2 && _status(ambiguous, 2).target_count == -1
            @test _status(ambiguous, 10).tick_count == _status(ambiguous, 30).tick_count == 0
            targeted = _one_cardinality_state(; multiplicity=OptionalOne)
            @test_throws ArgumentError RP.step!(targeted, NamedTuple())
            @test _status(targeted, 2).first_ticks == 1 && !_status(targeted, 2).reached_after_second
            @test _status(targeted, 5).tick_count == 1 && _status(targeted, 6).tick_count == 0
            @test_throws ArgumentError RP.step!(targeted, NamedTuple())
        end
        @testset "partial errors preserve entered work and reject replay" begin
            state = _observer_state(; fail_id=10)
            environment = (delta=1.0, order=Int[])
            @test_throws Exception RP.step!(state, environment)
            @test environment.order == [10] && _status(state, 10).x == 2.0 && _status(state, 30).x == 1.0
            @test_throws ArgumentError RP.step!(state, environment)
            @test environment.order == [10] && _status(state, 2).total == 0.0
        end
        @testset "temporal arrays, consumer isolation and producer snapshots" begin
            for retain in (true, false)
                state = _array_state(retain)
                observed_a = Float64[]; observed_b = Float64[]
                for _ in 1:3
                    RP.step!(state, NamedTuple())
                    push!(observed_a, _status(state, 2).saw_a)
                    push!(observed_b, _status(state, 2).saw_b)
                end
                @test observed_a == observed_b == [1.0, 2.0, 103.0]
                producer = state.applications[1].streams
                updated = state.applications[2].streams.payload
                @test _status(state, 2).payload == [304.0]
                @test producer.payload.last[2].value == [204.0]
                @test producer.payload.prior[2].value == [103.0]
                if retain
                    @test [sample.value for sample in producer.payload.retained] == [[2.0], [103.0], [204.0]]
                    @test [sample.value for sample in updated.retained] == [[102.0], [203.0], [304.0]]
                else
                    @test producer.payload.temporal
                    @test all(application -> all(stream -> isempty(stream.retained), values(application.streams)), state.applications)
                    for application in state.applications, stream in values(application.streams)
                        stream.temporal && continue
                        @test isempty(stream.initial) && isempty(stream.last) && isempty(stream.prior)
                    end
                end
            end
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes + counts.cumulative_passes,
        fails=counts.fails + counts.cumulative_fails, errors=counts.errors + counts.cumulative_errors)
end
end # module FullProgramReuseChecks
