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
function _prepare(specs, initial, root)
    scene = CompositeModel(root; applications=specs, environment=(duration=Day(1),))
    return RP.prepare(scene; initial)
end

function _instantiate(specs, initial, root; retain=true)
    program = _prepare(specs, initial, root)
    return RP.instantiate(program, map(spec -> spec.model, specs), root;
        initial, objects=_empty_objects(initial), retain)
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
    ticks = Many(scale=:Leaf, within=SelfPlant(), process=:reuse_tick)
    specs = (_application(Source(fail_id), :source, :Leaf),
        _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(; ticks)),
        _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    root = _tree([30, 10])
    program = isnothing(program) ? _prepare(specs, initial, root) : program
    return RP.instantiate(program, map(spec -> spec.model, specs), root;
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
    return _instantiate(specs, initial, _tree())
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
    return _instantiate(specs, initial, _tree())
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
    return _instantiate(specs, initial, _tree())
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
    return _instantiate(specs, initial, _tree(ids))
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
    return _instantiate(specs, initial, _tree(); retain)
end

PSE.@process "reuse_scene_creator" verbose = false
struct SceneCreator <: AbstractReuse_Scene_CreatorModel end
PSE.inputs_(::SceneCreator) = NamedTuple()
PSE.outputs_(::SceneCreator) = (scene_born=false,)
PSE.environment_inputs_(::SceneCreator) = (create=false,)
function PSE.run!(::SceneCreator, status, environment, constants, context)
    (status.scene_born || !environment.create) && return nothing
    PSE.add_organ!(PSE.source_node(context, ObjectId(3)), context, :+, :Leaf, 2;
        id=40, index=1, initial_status=(x=50.0,))
    status.scene_born = true
    return nothing
end
function _two_plants_state()
    root = _node(1, :Scene, 0)
    first_plant = _node(2, :Plant, 1, root)
    _node(3, :Plant, 1, root)
    for id in (30, 10)
        _node(id, :Leaf, 2, first_plant)
    end
    specs = (_application(Source(-1), :source, :Leaf),
        _application(SceneCreator(), :scene_creator, :Scene),
        _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(ticks=_tick(),)),
        _application(Tick(), :tick, :Leaf))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return _instantiate(specs, initial, root)
end

PSE.@process "reuse_f32_source" verbose = false
struct F32Source <: AbstractReuse_F32_SourceModel end
PSE.inputs_(::F32Source) = NamedTuple()
PSE.outputs_(::F32Source) = (x=1f0,)
PSE.environment_inputs_(::F32Source) = (delta=0f0,)
PSE.run!(::F32Source, status, environment, constants, context) = (status.x += environment.delta; nothing)
PSE.@process "reuse_f32_reader" verbose = false
struct F32Reader <: AbstractReuse_F32_ReaderModel end
PSE.inputs_(::F32Reader) = (previous_x=Required(AbstractFloat),)
PSE.outputs_(::F32Reader) = (previous_seen=0f0,)
PSE.run!(::F32Reader, status, environment, constants, context) = (status.previous_seen = status.previous_x; nothing)
PSE.@process "reuse_f32_observer" verbose = false
struct F32Observer <: AbstractReuse_F32_ObserverModel end
PSE.inputs_(::F32Observer) = (xs=Required(AbstractVector),)
PSE.outputs_(::F32Observer) = (total=0f0,)
PSE.run!(::F32Observer, status, environment, constants, context) = (status.total = sum(PSE.bound_input(context, :xs)); nothing)
function _float32_state()
    previous = (PreviousTimeStep(:previous_x) => One(within=Self(), application=:f32_source, var=:x),)
    many = Many(scale=:Leaf, within=SelfPlant(), application=:f32_source, var=:x)
    specs = (_application(F32Source(), :f32_source, :Leaf),
        _application(F32Reader(), :f32_reader, :Leaf; inputs=previous),
        _application(F32Observer(), :f32_observer, :Plant; inputs=(xs=many,)))
    initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
    return _instantiate(specs, initial, _tree([30, 10]))
end

PSE.@process "reuse_distributor" verbose = false
struct Distributor <: AbstractReuse_DistributorModel end
PSE.inputs_(::Distributor) = NamedTuple()
PSE.outputs_(::Distributor) = (
    local_count=0, leaf_flux=Distributed(Default(0.0)), scene_flux=Distributed(Default(0.0)),
)
function PSE.run!(::Distributor, status, environment, constants, context)
    leaves = PSE.output_targets(context, (:leaf_flux,))
    scene = PSE.output_targets(context, (:scene_flux,))
    leaves.columns.leaf_flux .= 2.0
    scene.columns.scene_flux .= 3.0
    status.local_count = length(PSE.object_ids(leaves))
    return nothing
end

PSE.@process "reuse_status_reader" verbose = false
struct StatusReader <: AbstractReuse_Status_ReaderModel end
PSE.inputs_(::StatusReader) = (value=Required(AbstractFloat),)
PSE.outputs_(::StatusReader) = (seen=0f0,)
PSE.run!(::StatusReader, status, environment, constants, context) =
    (status.seen = status.value; nothing)

PSE.@process "reuse_implicit_producer" verbose = false
struct ImplicitProducer <: AbstractReuse_Implicit_ProducerModel end
PSE.inputs_(::ImplicitProducer) = NamedTuple()
PSE.outputs_(::ImplicitProducer) = (value=0f0,)
PSE.run!(::ImplicitProducer, status, environment, constants, context) =
    (status.value = 5f0; nothing)

function run_checks()
    result = @testset "Full program reuse and invalidation" begin
        @testset "manual applications must use the daily clock" begin
            specs = (
                _application(Source(-1), :source, :Leaf),
                _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(ticks=_tick(),)),
                ModelSpec(Tick(); name=:tick, on=Many(scale=:Leaf), every=Day(2)),
            )
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
            @test_throws ArgumentError _prepare(specs, initial, _tree())
        end
        @testset "full call routes require a single resolved application" begin
            ticks = Many(scale=:Leaf, within=SelfPlant(), process=:reuse_tick)
            specs = (
                _application(Source(-1), :source, :Leaf),
                _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(; ticks)),
                _application(Tick(), :first_tick, :Leaf),
                _application(Tick(), :second_tick, :Leaf),
            )
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
            @test_throws ArgumentError _prepare(specs, initial, _tree([30, 10]))
        end
        @testset "partitioned distributed outputs use their resolved destinations" begin
            destinations = (
                OutputTo(Many(scale=:Scene, within=SceneScope()); vars=(:scene_flux,)),
                OutputTo(Many(scale=:Leaf, within=SelfPlant()); vars=(:leaf_flux,)),
            )
            specs = (
                _application(Source(-1), :source, :Leaf),
                _application(Distributor(), :distributor, :Plant; outputs_to=destinations),
            )
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
            state = _instantiate(specs, initial, _tree([30, 10]))
            RP.step!(state, (delta=0.0, order=Int[]))
            @test _status(state, 2).local_count == 2
            @test _status(state, 1).scene_flux == 3.0
            @test _status(state, 10).leaf_flux == _status(state, 30).leaf_flux == 2.0
        end
        @testset "explicit status inputs use the live reference without a producer" begin
            selector = One(within=Self(), var=:raw, from_status=true)
            specs = (_application(StatusReader(), :reader, :Plant; inputs=(value=selector,)),)
            initial = (Scene=NamedTuple(), Plant=(raw=1f0,))
            state = _instantiate(specs, initial, _tree())
            _status(state, 2).raw = 3f0
            RP.step!(state, NamedTuple())
            @test _status(state, 2).seen === 3f0

            filtered = One(within=Self(), var=:raw, application=:reader)
            specs = (_application(StatusReader(), :reader, :Plant; inputs=(value=filtered,)),)
            @test_throws ArgumentError _prepare(specs, initial, _tree())
        end
        @testset "implicit inputs project the same-object writer or read existing status" begin
            reader = _application(StatusReader(), :reader, :Plant)
            producer = _application(ImplicitProducer(), :producer, :Plant)
            initial = (Scene=NamedTuple(), Plant=(value=2f0,))
            state = _instantiate((reader, producer), initial, _tree())
            @test state.program.order == (Val(2), Val(1))
            @test state.program.applications[1].inputs.value isa
                RP.FullInputRoute{((2,2),),:value,false,:one,Float32}
            RP.step!(state, NamedTuple())
            @test _status(state, 2).seen === 5f0

            source_free = _instantiate((reader,), initial, _tree())
            @test source_free.program.applications[1].inputs.value isa
                RP.FullInputRoute{((2,0),),:value,false,:one,Float32}
            _status(source_free, 2).value = 3f0
            RP.step!(source_free, NamedTuple())
            @test _status(source_free, 2).seen === 3f0
        end
        @testset "dependency scopes match ordinary PSE across plants" begin
            for (selector, total) in (
                (Many(scale=:Plant, application=:producer, var=:value), 5f0),
                (Many(scale=:Plant, within=SceneScope(), application=:producer, var=:value), 10f0),
            )
                root = _tree()
                _node(3, :Plant, 1, root)
                specs = (
                    _application(ImplicitProducer(), :producer, :Plant),
                    _application(F32Observer(), :observer, :Plant; inputs=(xs=selector,)),
                )
                initial = (Scene=NamedTuple(), Plant=NamedTuple())
                state = _instantiate(specs, initial, root)
                RP.step!(state, NamedTuple())
                scene = CompositeModel(root; applications=specs, environment=(duration=Day(1),))
                ordinary = PSE.run!(scene; steps=1, outputs=:none)
                for id in (2, 3)
                    @test _status(state, id).total === PSE.final_state(ordinary, ObjectId(id)).total === total
                end
            end
        end
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
            @test isempty(state.cohorts[3].ids)
            @test Val(1) in state.program.order # Preserve the initially empty Source application.
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
        @testset "growth in another plant preserves an unchanged selected carrier" begin
            state = _two_plants_state()
            order = Int[]
            RP.step!(state, (delta=1.0, order=order, create=false))
            first_carrier = _status(state, 2).xs
            @test _status(state, 2).total == 4.0 && _status(state, 2).seen_ids == _status(state, 2).call_ids == [10, 30]
            @test _status(state, 3).total == 0.0 && isempty(_status(state, 3).seen_ids) && isempty(_status(state, 3).call_ids)
            RP.step!(state, (delta=1.0, order=order, create=true))
            @test _status(state, 2).xs === first_carrier
            @test _status(state, 2).total == 6.0 && _status(state, 2).seen_ids == _status(state, 2).call_ids == [10, 30]
            @test _status(state, 3).total == 50.0 && _status(state, 3).seen_ids == _status(state, 3).call_ids == [40]
            @test _status(state, 40).tick_count == 1
            second_carrier = _status(state, 3).xs
            RP.step!(state, (delta=1.0, order=order, create=false))
            @test _status(state, 2).xs === first_carrier && _status(state, 2).total == 8.0
            @test _status(state, 3).xs === second_carrier && _status(state, 3).total == 51.0
            @test _status(state, 2).seen_ids == _status(state, 2).call_ids == [10, 30]
            @test _status(state, 3).seen_ids == _status(state, 3).call_ids == [40]
            @test _status(state, 40).tick_count == 2
            @test order == [10, 30, 10, 30, 10, 30, 40]
        end
        @testset "Float32 live Many and same-object temporal values" begin
            state = _float32_state()
            RP.step!(state, (delta=1f0,))
            carrier = _status(state, 2).xs
            @test _status(state, 2).total === 4f0
            @test all(id -> _status(state, id).x === 2f0 && _status(state, id).previous_seen === 1f0, (10, 30))
            @test eltype(carrier) === Float32
            RP.step!(state, (delta=1f0,))
            @test _status(state, 2).total === 6f0
            @test _status(state, 2).xs === carrier
            @test all(id -> _status(state, id).x === 3f0 && _status(state, id).previous_seen === 2f0, (10, 30))
            @test all(id -> _status(state, id).previous_x isa Float32, (10, 30))
            source = state.applications[1].streams.x
            reader = state.applications[2].streams.previous_seen
            observer = state.applications[3].streams.total
            @test [sample.value for sample in source.retained if sample.object_id == 10] == [2f0, 3f0]
            @test [sample.value for sample in reader.retained if sample.object_id == 10] == [1f0, 2f0]
            @test [sample.value for sample in observer.retained] == [4f0, 6f0]
            temporal = (source.initial[10], source.prior[10].value, source.last[10].value)
            @test temporal == (1f0, 2f0, 3f0)
            @test all(value -> value isa Float32, temporal)
            @test all(application -> all(stream -> all(sample -> sample.value isa Float32,
                stream.retained), values(application.streams)), state.applications)
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
