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

struct InterpolatedProducer <: AbstractReuse_Implicit_ProducerModel end
PSE.inputs_(::InterpolatedProducer) = NamedTuple()
PSE.outputs_(::InterpolatedProducer) = (value=0f0,)
PSE.output_policy(::InterpolatedProducer) = (value=PSE.Interpolate(),)
PSE.run!(::InterpolatedProducer, status, environment, constants, context) =
    (status.value = 5f0; nothing)

PSE.@process "reuse_writer_distribution" verbose = false
struct WriterDistribution <: AbstractReuse_Writer_DistributionModel
    value::Float32
    seed::Float32
end
WriterDistribution(value) = WriterDistribution(value, 0f0)
PSE.inputs_(::WriterDistribution) = NamedTuple()
PSE.outputs_(model::WriterDistribution) = (value=Distributed(Default(model.seed)),)
function PSE.run!(model::WriterDistribution, status, environment, constants, context)
    PSE.output_targets(context, (:value,)).columns.value .= model.value
    return nothing
end

PSE.@process "reuse_writer_birth" verbose = false
struct WriterBirth <: AbstractReuse_Writer_BirthModel end
PSE.inputs_(::WriterBirth) = NamedTuple()
PSE.outputs_(::WriterBirth) = NamedTuple()
function PSE.run!(::WriterBirth, status, environment, constants, context)
    PSE.add_organ!(PSE.source_node(context), context, :+, :Leaf, 2; id=20, index=1)
    return nothing
end

PSE.@process "reuse_producer_probe" verbose = false
struct ProducerProbe <: AbstractReuse_Producer_ProbeModel end
PSE.inputs_(::ProducerProbe) = (filtered=Required(AbstractVector), previous=Default(Float32[]))
PSE.outputs_(::ProducerProbe) = (live_values=Float32[], previous_values=Float32[], live_ids=Int[])
function PSE.run!(::ProducerProbe, status, environment, constants, context)
    filtered = PSE.bound_input(context, :filtered)
    previous = PSE.bound_input(context, :previous)
    status.live_values = collect(filtered)
    status.previous_values = collect(previous)
    status.live_ids = [id.value for id in PSE.object_ids(filtered)]
    return nothing
end

PSE.@process "reuse_scalar_producer_probe" verbose = false
struct ScalarProducerProbe <: AbstractReuse_Scalar_Producer_ProbeModel end
PSE.inputs_(::ScalarProducerProbe) = (previous=Default(7f0),)
PSE.outputs_(::ScalarProducerProbe) = (seen=0f0,)
function PSE.run!(::ScalarProducerProbe, status, environment, constants, context)
    status.previous += 1f0
    status.seen = status.previous
    return nothing
end

PSE.@process "reuse_writer_origin_birth" verbose = false
struct WriterOriginBirth <: AbstractReuse_Writer_Origin_BirthModel
    birth_step::Int
end
WriterOriginBirth() = WriterOriginBirth(1)
PSE.inputs_(::WriterOriginBirth) = NamedTuple()
PSE.outputs_(::WriterOriginBirth) = (origin_step=0,)
function PSE.run!(model::WriterOriginBirth, status, environment, constants, context)
    PSE.object_id(context).value == 2 || return nothing
    status.origin_step += 1
    if status.origin_step == model.birth_step
        PSE.add_organ!(PSE.source_node(context), context, :+, :Leaf, 2; id=20, index=1)
    end
    return nothing
end

const REBIND_INITIAL = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
const REBIND_PREVIOUS = (Float32[0, 0], Float32[0, 5], Float32[9, 5])

function _origin_rebind_specs()
    destinations = (OutputTo(Many(Relation(:parent); scale=:Plant)),)
    return (
        _application(ImplicitProducer(), :background, :Plant),
        _application(WriterOriginBirth(2), :birth, :Plant),
        _application(WriterDistribution(9f0), :new_writer, :Leaf;
            outputs_to=destinations, updates=Updates(:value; after=:background)),
        _application(ProducerProbe(), :probe, :Scene; inputs=(
            :filtered => Many(scale=:Plant, application=:new_writer, var=:value),
            PreviousTimeStep(:previous) => Many(scale=:Plant, var=:value),
        )),
    )
end

function _origin_rebind_tree()
    root = _tree()
    _node(3, :Plant, 1, root)
    return root
end

function _writer_distribution(name, category, value; seed=0f0)
    destinations = (OutputTo(Many(Relation(:children); scale=:Leaf)),)
    return _application(WriterDistribution(value, seed), name, category; outputs_to=destinations)
end

function _disjoint_writer_tree()
    root = _tree([10])
    plant = only(MTG.children(root))
    phytomer = _node(3, :Phytomer, 2, plant)
    _node(11, :Leaf, 2, phytomer)
    return root
end

function _ordinary_growth_tree(ids=Int[])
    root = MTG.Node(1, MTG.NodeMTG(:/, :Scene, 1, 0), NamedTuple())
    plant = MTG.Node(2, root, MTG.NodeMTG(:+, :Plant, 1, 1), NamedTuple())
    for id in ids
        MTG.Node(id, plant, MTG.NodeMTG(:+, :Leaf, 1, 2), NamedTuple())
    end
    return root
end

function _ordinary_writer_scene(specs, root)
    return CompositeModel(root; applications=specs, environment=(duration=Day(1),))
end

function run_writer_origin_rebind_checks()
    @testset "a newborn writer rebinds inputs on an existing destination" begin
        for retain in (false, true)
            specs = _origin_rebind_specs()
            root = _ordinary_growth_tree()
            MTG.Node(3, root, MTG.NodeMTG(:+, :Plant, 1, 1), NamedTuple())
            simulation = PSE.run!(_ordinary_writer_scene(specs, root);
                steps=0, outputs=retain ? :all : :none)
            state = _instantiate(specs, REBIND_INITIAL, _origin_rebind_tree(); retain)
            unrelated_key = (:background, ObjectId(3), :value)
            unrelated_stream = PSE.outputs(simulation)[unrelated_key]
            for (step, lagged) in enumerate(REBIND_PREVIOUS)
                RP.step!(state, NamedTuple())
                PSE.step!(simulation)
                actual = _status(state, 1)
                ordinary = PSE.final_state(simulation, ObjectId(1))
                @test actual.live_ids == ordinary.live_ids == (step == 1 ? Int[] : [2])
                @test actual.live_values == ordinary.live_values == (step == 1 ? Float32[] : Float32[9])
                @test actual.previous_values == ordinary.previous_values == lagged
                @test _status(state, 2).value === PSE.final_state(simulation, ObjectId(2)).value === (step == 1 ? 5f0 : 9f0)
                @test PSE.outputs(simulation)[unrelated_key] === unrelated_stream
            end
            if retain
                @test last(PSE.outputs(simulation)[(:background, ObjectId(2), :value)])[2] === 5f0
                @test last(PSE.outputs(simulation)[(:new_writer, ObjectId(2), :value)])[2] === 9f0
            end
        end
    end
end

function run_checks()
    result = @testset "Full program reuse and invalidation" begin
        @testset "an explicit manual clock must match its caller" begin
            specs = (
                _application(Source(-1), :source, :Leaf),
                _application(Observer(), :observer, :Plant; inputs=(xs=_xs(),), calls=(ticks=_tick(),)),
                ModelSpec(Tick(); name=:tick, on=Many(scale=:Leaf), every=Day(2)),
            )
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
            @test_throws "has incompatible cadence" _prepare(specs, initial, _tree([10]))
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
        @testset "producer policies cannot silently become live references" begin
            producer = ModelSpec(InterpolatedProducer(); name=:producer,
                on=Many(scale=:Plant), every=Day(2))
            reader(; kwargs...) = _application(StatusReader(), :reader, :Plant; kwargs...)
            source(; kwargs...) = One(within=Self(), application=:producer, var=:value; kwargs...)
            initial = (Scene=NamedTuple(), Plant=NamedTuple())
            for consumer in (reader(), reader(inputs=(value=source(),)))
                specs = (producer, consumer)
                ordinary = PSE.run!(_ordinary_writer_scene(specs, _tree()); steps=0)
                @test only(ordinary.compiled.input_bindings).policy isa PSE.Interpolate
                @test_throws "inherits unsupported policy" _prepare(specs, initial, _tree())
            end

            specs = (producer, reader(inputs=(value=source(policy=PSE.HoldLast()),)))
            ordinary = PSE.run!(_ordinary_writer_scene(specs, _tree()); steps=0)
            prepared = _instantiate(specs, initial, _tree())
            for _ in 1:3
                PSE.step!(ordinary)
                RP.step!(prepared, NamedTuple())
                @test _status(prepared, 2).seen === PSE.final_state(ordinary, ObjectId(2)).seen
            end
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
        @testset "pointwise scopes and relations match ordinary indexed selection" begin
            root = _tree()
            plant = only(MTG.children(root))
            leaf = _node(10, :Leaf, 2, plant)
            sibling = _node(30, :Leaf, 2, plant)
            tip = _node(40, :Tip, 3, leaf)
            scene = CompositeModel(root)
            nodes = (root, plant, leaf, sibling, tip)
            relations = (:self, :parent, :children, :ancestors, :descendants, :siblings)
            selectors = (
                map(relation -> Many(Relation(relation)), relations)...,
                Many(), Many(SceneScope()), Many(Self()), Many(Subtree()),
                Many(Subtree(), Relation(:parent)), Many(Subtree(), Relation(:descendants)),
            )
            for origin in nodes, selector in selectors
                matcher = PSE._compile_selector_matcher(scene, selector)
                selected = PSE.resolve_object_ids(scene, selector; context=ObjectId(MTG.node_id(origin)))
                projected = ObjectId[ObjectId(MTG.node_id(node)) for node in nodes
                    if RP._full_matches(matcher, origin, node)]
                @test Set(projected) == Set(selected)
            end
        end
        @testset "ancestor scopes distinguish missing roots from absent nearest matches" begin
            root = _tree()
            plant = only(MTG.children(root))
            leaf = _node(10, :Leaf, 2, plant)
            sibling = _node(30, :Leaf, 2, plant)
            scene = CompositeModel(root)
            nodes = (root, plant, leaf, sibling)
            for (selector, origin) in (
                (Many(SelfPlant()), plant),
                (Many(Ancestor(scale=:Plant)), leaf),
                (Many(Ancestor()), leaf),
                (Many(Ancestor(scale=:Plant); scale=:Plant), leaf),
                (Many(Ancestor(scale=:Plant); scale=:Plant), root),
                (Many(Ancestor(scale=:Plant), Relation(:children)), root),
            )
                matcher = PSE._compile_selector_matcher(scene, selector)
                if origin === root && matcher.relation isa Val{:children}
                    @test_throws ErrorException PSE.resolve_object_ids(scene, selector; context=ObjectId(1))
                    @test_throws ArgumentError RP._full_matches(matcher, origin, plant)
                    @test !RP._full_matches(matcher, origin, leaf)
                    continue
                end
                RP._full_validate_scope(matcher, origin)
                selected = PSE.resolve_object_ids(scene, selector; context=ObjectId(MTG.node_id(origin)))
                projected = ObjectId[ObjectId(MTG.node_id(node)) for node in nodes
                    if RP._full_matches(matcher, origin, node)]
                @test Set(projected) == Set(selected)
            end
            for selector in (Many(SelfPlant()), Many(Ancestor(scale=:Plant)))
                matcher = PSE._compile_selector_matcher(scene, selector)
                @test_throws ErrorException PSE.resolve_object_ids(scene, selector; context=ObjectId(1))
                @test_throws ArgumentError RP._full_validate_scope(matcher, root)
            end
        end
        @testset "Updates must name the immediately preceding writer" begin
            first_writer = _application(ImplicitProducer(), :first, :Plant)
            middle_writer = _application(ImplicitProducer(), :middle, :Plant;
                updates=Updates(:value; after=:first))
            final_writer(after) = _application(ImplicitProducer(), :last, :Plant;
                updates=Updates(:value; after))
            initial = (Scene=NamedTuple(), Plant=NamedTuple())
            specs = (first_writer, middle_writer, final_writer(:middle))
            state = _instantiate(specs, initial, _tree())
            @test state.program.order == (Val(1), Val(2), Val(3))
            RP.step!(state, NamedTuple())
            @test _status(state, 2).value === 5f0

            skipped = (first_writer, middle_writer, final_writer(:first))
            @test_throws "Updates" _instantiate(skipped, initial, _tree())
        end
        @testset "writers are validated on matching objects" begin
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Phytomer=NamedTuple(),
                Leaf=NamedTuple())
            specs = (_writer_distribution(:plant_writer, :Plant, 2f0),
                _writer_distribution(:phytomer_writer, :Phytomer, 3f0))
            ordinary = _ordinary_writer_scene(specs, _disjoint_writer_tree())
            PSE.run!(ordinary; steps=1)
            state = _instantiate(specs, initial, _disjoint_writer_tree())
            RP.step!(state, NamedTuple())
            for (id, expected) in ((10, 2f0), (11, 3f0))
                @test _status(state, id).value === PSE.model_status(ordinary, ObjectId(id)).value === expected
            end

            first_writer = _application(ImplicitProducer(), :first, :Plant;
                updates=Updates(:value; after=:unrelated))
            last_writer = _application(ImplicitProducer(), :last, :Plant;
                updates=Updates(:value; after=:first))
            unrelated = _application(Initialize(), :unrelated, :Plant)
            invalid = (unrelated, first_writer, last_writer)
            @test_throws "no previous writer" PSE.run!(_ordinary_writer_scene(invalid, _tree()); steps=0)
            @test_throws "previous writer" _instantiate(invalid, initial, _tree())

            # With no leaves, neither writer initially owns an object.
            # The newborn is a destination of the Plant writer and the local Leaf writer.
            birth_specs = (_writer_distribution(:plant_writer, :Plant, 2f0),
                _application(ImplicitProducer(), :leaf_writer, :Leaf),
                _application(WriterBirth(), :birth, :Plant))
            ordinary_birth = _ordinary_writer_scene(birth_specs, _ordinary_growth_tree())
            @test_throws "Ambiguous canonical writers" PSE.run!(ordinary_birth; steps=1)
            birth_state = _instantiate(birth_specs, initial, _tree())
            @test_throws "writer" RP.step!(birth_state, NamedTuple())
            @test birth_state.step == 0
            @test all(cohort -> RP._cohort_key(cohort) !== :Leaf || cohort.committed == 0,
                birth_state.cohorts)
        end
        @testset "input producers follow actual distributed destinations" begin
            inputs(scale, writer) = (
                :filtered => Many(scale=scale, application=writer, var=:value),
                PreviousTimeStep(:previous) => Many(scale=scale, var=:value),
            )
            probe(scale, writer) = _application(ProducerProbe(), :probe, :Scene;
                inputs=inputs(scale, writer))
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Phytomer=NamedTuple(),
                Leaf=NamedTuple())
            specs = (_writer_distribution(:plant_writer, :Plant, 2f0),
                _writer_distribution(:phytomer_writer, :Phytomer, 3f0),
                probe(:Leaf, :phytomer_writer))
            state = _instantiate(specs, initial, _disjoint_writer_tree())
            simulation = PSE.run!(_ordinary_writer_scene(specs, _disjoint_writer_tree()); steps=0)
            for lagged in (Float32[0,0], Float32[2,3])
                RP.step!(state, NamedTuple())
                PSE.step!(simulation)
                actual = _status(state, 1)
                ordinary = PSE.final_state(simulation, ObjectId(1))
                @test actual.live_ids == ordinary.live_ids == [11]
                @test actual.live_values == ordinary.live_values == Float32[3]
                @test actual.previous_values == ordinary.previous_values == lagged
            end

            growth_specs = (_application(WriterOriginBirth(), :birth, :Plant),
                _writer_distribution(:plant_writer, :Plant, 2f0),
                _writer_distribution(:phytomer_writer, :Phytomer, 3f0),
                probe(:Leaf, :plant_writer))
            growth_state = _instantiate(growth_specs, initial, _disjoint_writer_tree())
            ordinary_root = _ordinary_growth_tree([10])
            ordinary_plant = only(MTG.children(ordinary_root))
            ordinary_phytomer = MTG.Node(3, ordinary_plant, MTG.NodeMTG(:+, :Phytomer, 1, 2), NamedTuple())
            MTG.Node(11, ordinary_phytomer, MTG.NodeMTG(:+, :Leaf, 1, 2), NamedTuple())
            growth_sim = PSE.run!(_ordinary_writer_scene(growth_specs, ordinary_root); steps=0)
            for lagged in (Float32[0,0,0], Float32[2,3,2])
                RP.step!(growth_state, NamedTuple())
                PSE.step!(growth_sim)
                actual = _status(growth_state, 1)
                ordinary = PSE.final_state(growth_sim, ObjectId(1))
                @test actual.live_ids == ordinary.live_ids == [10, 20]
                @test actual.live_values == ordinary.live_values == Float32[2,2]
                @test actual.previous_values == ordinary.previous_values == lagged
            end
        end
        run_writer_origin_rebind_checks()
        @testset "filtered scalar inputs preserve selector cardinality and optional defaults" begin
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Phytomer=NamedTuple(),
                Leaf=NamedTuple())
            probe(selector) = _application(ScalarProducerProbe(), :scalar_probe, :Scene;
                inputs=(PreviousTimeStep(:previous) => selector,))
            writer = _writer_distribution(:phytomer_writer, :Phytomer, 3f0)
            optional = OptionalOne(scale=:Leaf, application=:phytomer_writer, var=:value)
            specs = (writer, probe(optional))
            @test_throws Exception PSE.run!(_ordinary_writer_scene(specs, _disjoint_writer_tree()); steps=0)
            @test_throws "at most one source object" _instantiate(specs, initial, _disjoint_writer_tree())

            # The object exists, but it is outside the named writer's
            # destination membership. OptionalOne keeps the consumer default.
            state = _instantiate(specs, initial, _tree([10]))
            simulation = PSE.run!(_ordinary_writer_scene(specs, _tree([10])); steps=0)
            for expected in (8f0, 9f0)
                RP.step!(state, NamedTuple())
                PSE.step!(simulation)
                ordinary = PSE.final_state(simulation, ObjectId(1))
                @test _status(state, 1).seen === ordinary.seen === expected
                @test _status(state, 1).previous === ordinary.previous === expected
            end

        end
        @testset "disjoint writers with distinct defaults require per-object seeds" begin
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Phytomer=NamedTuple(),
                Leaf=NamedTuple())
            specs = (_writer_distribution(:plant_writer, :Plant, 2f0; seed=7f0),
                _writer_distribution(:phytomer_writer, :Phytomer, 3f0; seed=9f0))
            ordinary = _ordinary_writer_scene(specs, _disjoint_writer_tree())
            PSE.run!(ordinary; steps=0)
            @test PSE.model_status(ordinary, ObjectId(10)).value === 7f0
            @test PSE.model_status(ordinary, ObjectId(11)).value === 9f0
            @test_throws "disjoint writers require identical output defaults" _instantiate(specs, initial, _disjoint_writer_tree())
        end
        @testset "a newborn origin can duplicate a writer on a committed destination" begin
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=NamedTuple())
            distribution = OutputTo(Many(Relation(:parent); scale=:Plant))
            specs = (_application(WriterDistribution(2f0), :leaf_writer, :Leaf;
                    outputs_to=(distribution,)),
                _application(WriterBirth(), :birth, :Plant))
            ordinary = _ordinary_writer_scene(specs, _ordinary_growth_tree([10]))
            @test_throws "more than one canonical writer" PSE.run!(ordinary; steps=1)
            state = _instantiate(specs, initial, _tree([10]))
            @test_throws "more than one canonical writer" RP.step!(state, NamedTuple())
            @test state.step == 0
        end
        @testset "distributed column cache refreshes committed membership and refs" begin
            initial = (Scene=NamedTuple(), Plant=NamedTuple(), Leaf=(unrelated=0,))
            specs = (_writer_distribution(:plant_writer, :Plant, 2f0),
                _application(WriterBirth(), :birth, :Plant))
            state = _instantiate(specs, initial, _tree([10]))
            app = first(state.applications)
            targets() = PSE.output_targets(
                RP.CohortContext(app, state, app.views[1], 1, NamedTuple(),
                    PSE.Constants(), state.step + 1, false), (:value,))
            first_targets = targets()
            first_column = first_targets.columns.value
            @test collect(PSE.object_ids(first_targets)) == [ObjectId(10)]
            @test targets().columns.value === first_column
            first_column[1] = 4f0
            @test _status(state, 10).value === 4f0

            RP.step!(state, NamedTuple())
            grown_targets = targets()
            grown_column = grown_targets.columns.value
            @test collect(PSE.object_ids(grown_targets)) == [ObjectId(10), ObjectId(20)]
            @test grown_column !== first_column
            @test targets().columns.value === grown_column
            @test collect(PSE.object_ids(first_targets)) == [ObjectId(10)]
            @test length(first_column) == 1

            slot, row = state.locations[10]
            cohort = state.cohorts[slot]
            previous = _status(state, 10)
            unrelated_replacement = Status(merge(PSE._status_vars(previous), (unrelated=Ref(1),)))
            RP._replace_full_status!(state, cohort, row, unrelated_replacement)
            @test _status(state, 10).unrelated === 1
            @test targets().columns.value === grown_column

            replacement = Status(merge(PSE._status_vars(unrelated_replacement), (value=Ref(8f0),)))
            RP._replace_full_status!(state, cohort, row, replacement)
            rebound_targets = targets()
            rebound_column = rebound_targets.columns.value
            @test collect(PSE.object_ids(rebound_targets)) == [ObjectId(10), ObjectId(20)]
            @test rebound_column !== grown_column
            @test grown_column[1] === 2f0
            @test rebound_column[1] === 8f0
            @test targets().columns.value === rebound_column
            rebound_column[1] = 11f0
            @test _status(state, 10).value === 11f0
            @test grown_column[1] === 2f0
        end
        @testset "literal environment validation preserves declaration order" begin
            source = Source(-1)
            @test RP._validate_full_environment(source, (order=Int[], delta=1.0)) === nothing
            @test_throws "missing global environment input" RP._validate_full_environment(
                source, (order=Int[],))
            @test_throws "incompatible global environment input" RP._validate_full_environment(
                source, (delta=1,))  # Wrong first field precedes missing second field.
            @test_throws "missing global environment input" RP._validate_full_environment(
                source, (order=1,))  # Missing first field precedes wrong second field.
            @test RP._validate_full_environment_fields(
                (delta=Required(AbstractFloat), order=Default(Int[])),
                (order=Int[], delta=1f0)) === nothing
            @test RP._validate_full_environment_fields(
                Dict(:delta => Default(1.0)), (delta=1.0,)) === nothing
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
            _, row = state.locations[10]
            initial_value = state.applications[2].bindings[row].previous_x.initial[10]
            temporal = (initial_value, source.prior[10].value, source.last[10].value)
            @test temporal == (1f0, 2f0, 3f0)
            @test all(value -> value isa Float32, temporal)
            @test all(application -> all(stream -> all(sample -> sample.value isa Float32,
                stream.retained), values(application.streams)), state.applications)
        end
        @testset "temporal lookup uses owned consumer fallback only before the first sample" begin
            history = RP.ColumnHistory(Vector{Int}, true)
            early = Dict(10 => [1])
            late = Dict(10 => [2])
            absent = Dict{Int,Vector{Int}}()
            RP._full_record!(history, :source, 10, 1, [3], false)
            first_read = RP._full_previous(history, 10, 1, early)
            @test first_read == [1]
            first_read[1] = 99
            @test early[10] == [1]
            @test RP._full_previous(history, 10, 1, late) == [2]
            RP._full_record!(history, :source, 10, 1, [4], false)
            @test RP._full_previous(history, 10, 2, absent) == [4]
            RP._full_record!(history, :source, 10, 2, [5], false)
            previous = RP._full_previous(history, 10, 2, absent)
            @test previous == [4]
            previous[1] = 99
            @test RP._full_previous(history, 10, 2, absent) == [4]
            @test_throws ArgumentError RP._full_previous(history, 10, 1, early)
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
                        @test isempty(stream.last) && isempty(stream.prior)
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
