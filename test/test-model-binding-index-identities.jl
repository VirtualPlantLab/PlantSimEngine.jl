module ModelBindingIndexIdentityChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "binding_index_leaf" verbose=false
PSE.@process "binding_index_capture" verbose=false
PSE.@process "binding_index_reader" verbose=false

struct Leaf <: AbstractBinding_Index_LeafModel end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (x=0f0,)
PSE.run!(::Leaf, status, environment, constants, context) =
    (status.x += 1f0; nothing)

struct Capture <: AbstractBinding_Index_CaptureModel
    context::Base.RefValue{Any}
end
PSE.inputs_(::Capture) = NamedTuple()
PSE.outputs_(::Capture) = (visits=0,)
function PSE.run!(model::Capture, status, environment, constants, context)
    model.context[] = context
    status.visits += 1
    return nothing
end

struct Reader <: AbstractBinding_Index_ReaderModel end
struct ManyReader <: AbstractBinding_Index_ReaderModel end
PSE.inputs_(::Reader) = (single=Required(Float32), values=Default(Float64[]))
PSE.inputs_(::ManyReader) = (values=Default(Float64[]),)
PSE.outputs_(::Union{Reader,ManyReader}) = (total=0.0,)
function PSE.run!(::Reader, status, environment, constants, context)
    status.total = Float64(status.single) + sum(bound_input(context, :values); init=0.0)
    return nothing
end
function PSE.run!(::ManyReader, status, environment, constants, context)
    status.total = sum(bound_input(context, :values); init=0.0)
    return nothing
end

# Close only the actual complete schemas already present in this call fixture.
# This introduces no scientific object, default evaluation, or type probe.
function close_registry(model::CompositeModel)
    previous = model.registry
    registry = PSE.ObjectRegistry(PSE._closed_object_family_store(previous.objects),
        previous.by_scale, previous.by_kind, previous.by_species,
        previous.ancestor_ids_by_object)
    return PSE.CompositeModel(registry, model.applications, model.environment,
        model.instances, model.source_adapter, model.status_conversion,
        model.status_conversion_records, model.status_source_owners,
        model.status_source_identities, model.scenario_plan_cache,
        model.binding_cache, model.environment_binding_cache, model.bindings_dirty,
        model.environment_bindings_dirty, model.lifecycle_delta,
        model.input_default_status_variables, model.runtime_revision,
        model.revision, model.environment_revision)
end

function call_fixture(closed)
    capture = Ref{Any}(nothing)
    model = CompositeModel(
        Object(:root; scale=:Plant, status=Status(visits=0)),
        Object(:other; scale=:Plant, status=Status(visits=0)),
        Object(1; scale=:Leaf, parent=:root, status=Status(x=3f0)),
        Object(:leaf; scale=:Leaf, parent=:root, status=Status(x=5f0)),
        Object(:outside; scale=:Leaf, parent=:other, status=Status(x=100f0));
        applications=(
            ModelSpec(Capture(capture); name=:capture, on=One(id=:root), calls=(
                one=One(id=1, within=Subtree(), application=:leaf),
                many=Many(scale=:Leaf, within=Subtree(), application=:leaf))),
            ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
        ))
    closed && (model = close_registry(model))
    simulation = run!(model; steps=0, outputs=:all)
    target = only(only(only(simulation.execution_plan.groups).batches).targets)
    return (; model, simulation, capture, context=target.context)
end

function check_index(model, bindings, index)
    I = keytype(model.registry.objects)
    @test keytype(index) === Tuple{Symbol,I}
    @test valtype(index) === Any
    rebuilt = PSE._index_model_bindings(bindings, I)
    @test keytype(rebuilt) === Tuple{Symbol,I}
    @test valtype(rebuilt) === Any
    @test Set(keys(rebuilt)) == Set(keys(index))
    for (key, values) in rebuilt
        expected = Tuple(binding for binding in bindings
            if (binding.application_id, binding.consumer_id) == key)
        @test values === expected
        @test index[key] === expected
        @test all(PSE._model_binding_target_key(binding, I) === key for binding in values)
    end
    empty_index = PSE._index_model_bindings(empty(bindings), I)
    @test isempty(empty_index)
    @test keytype(empty_index) === Tuple{Symbol,I}
    @test valtype(empty_index) === Any
    return nothing
end

function check_indexes(model, simulation)
    compiled = simulation.compiled
    check_index(model, compiled.input_bindings, compiled.input_bindings_by_target)
    check_index(model, compiled.call_bindings, compiled.call_bindings_by_target)
end

@testset "binding indexes keep registry identities for cold and observed calls" begin
    for closed in (false, true)
        data = call_fixture(closed)
        model, simulation = data.model, data.simulation
        I = keytype(model.registry.objects)
        @test I === (closed ? Union{ObjectId{Int},ObjectId{Symbol}} : ObjectId)
        check_indexes(model, simulation)
        bindings = simulation.compiled.call_bindings
        @test Tuple(binding.call for binding in bindings) == (:one, :many)
        @test simulation.compiled.call_bindings_by_target[(:capture, ObjectId(:root))] ===
            Tuple(bindings)
        repeated = [bindings; first(bindings)]
        @test PSE._index_model_bindings(repeated, I)[(:capture, ObjectId(:root))] ===
            Tuple(repeated)
        @test_throws TypeError PSE._model_binding_target_key(first(bindings), ObjectId{String})
        one = call_targets(data.context, :one)
        many = call_targets(data.context, :many)
        @test many.execution_batches isa PSE.LazyCallExecutionBatches
        if many.execution_batches isa PSE.LazyCallExecutionBatches
            @test isnothing(many.execution_batches.batches)
        end
        @test !PSE._compiled_call_membership_is_observed(many.binding)
        @test only(one).object_id === ObjectId(1)
        first_ref = PSE.refvalue(model_status(model, 1), :x)
        step!(simulation)
        run_call!(data.capture[], :one; publish=true)
        run_call!(data.capture[], :many; publish=true)
        @test model_status(model, 1).x === 5f0
        @test model_status(model, :leaf).x === 6f0
        @test model_status(model, :outside).x === 100f0
        @test PSE._compiled_call_membership_is_observed(call_targets(data.capture[], :many).binding)
        check_indexes(model, simulation)

        register_object!(model, Object(2; scale=:Leaf, parent=:root, status=Status(x=7f0)))
        step!(simulation)
        run_call!(data.capture[], :many; publish=true)
        @test [target.object_id for target in call_targets(data.capture[], :many)] ==
            [ObjectId(1), ObjectId(2), ObjectId(:leaf)]
        @test model_status(model, 2).x === 8f0
        @test model_status(model, :leaf).x === 7f0
        check_indexes(model, simulation)

        reparent_object!(model, 2, :other)
        step!(simulation)
        run_call!(data.capture[], :many; publish=true)
        @test [target.object_id for target in call_targets(data.capture[], :many)] ==
            [ObjectId(1), ObjectId(:leaf)]
        @test model_status(model, 2).x === 8f0
        @test model_status(model, :leaf).x === 8f0
        check_indexes(model, simulation)

        remove_object!(model, :leaf)
        step!(simulation)
        run_call!(data.capture[], :many; publish=true)
        @test only(call_targets(data.capture[], :many)).object_id === ObjectId(1)
        @test model_status(model, 1).x === 8f0
        @test model_status(model, :root).visits == 4
        @test PSE.refvalue(model_status(model, 1), :x) === first_ref
        @test only(call_targets(data.capture[], :one)).status.x === 8f0
        @test outputs(simulation)[(:leaf, ObjectId(:leaf), :x)] ==
            [(1.0, 6f0), (2.0, 7f0), (3.0, 8f0)]
        check_indexes(model, simulation)
    end
end

@testset "input binding tuple schemas may change without widening registry keys" begin
    first_status = Status(x=3f0)
    model = CompositeModel(Object(:root; scale=:Plant), Object(:other; scale=:Plant),
        Object(1; scale=:Leaf, parent=:root, status=first_status),
        Object(:leaf; scale=:Leaf, parent=:root, status=Status(x=5f0));
        applications=(ModelSpec(Reader(); name=:reader, on=One(id=:root), inputs=(
            single=One(id=1, within=Subtree(), var=:x, from_status=true),
            values=Many(scale=:Leaf, within=Subtree(), var=:x, from_status=true))),))
    simulation = run!(model; steps=1, outputs=:all)
    check_indexes(model, simulation)
    key = (:reader, ObjectId(:root))
    before = simulation.compiled.input_bindings_by_target[key]
    @test Tuple(binding.input for binding in before) == (:single, :values)
    single = first(before)
    first_ref = PSE.refvalue(first_status, :x)
    @test single.carrier === first_ref
    @test model_status(model, :root).total === 11.0
    many = last(before).carrier
    @test all(reference === PSE.refvalue(model_status(model, id), :x)
        for (id, reference) in zip(last(before).source_ids, parent(many)))
    @test_throws TypeError PSE._model_binding_target_key(single, ObjectId{String})

    new_status = Status(x=9.0)
    register_object!(model, Object(2; scale=:Leaf, parent=:root, status=new_status))
    step!(simulation)
    after = simulation.compiled.input_bindings_by_target[key]
    @test typeof(after) !== typeof(before)
    @test last(after).carrier isa PSE.ObjectRefVector
    @test first(after).carrier === first_ref
    @test model_status(model, :root).total === 20.0
    @test PSE.refvalue(new_status, :x)[] === 9.0
    check_indexes(model, simulation)

    reparent_object!(model, 2, :other)
    step!(simulation)
    @test model_status(model, :root).total === 11.0
    @test first(simulation.compiled.input_bindings_by_target[key]).carrier === first_ref
    remove_object!(model, :leaf)
    step!(simulation)
    @test model_status(model, :root).total === 6.0
    @test PSE.refvalue(model_status(model, 1), :x) === first_ref
    @test outputs(simulation)[(:reader, ObjectId(:root), :total)] ==
        [(1.0, 11.0), (2.0, 20.0), (3.0, 11.0), (4.0, 6.0)]
    check_indexes(model, simulation)
end

@testset "initially empty Many changes its real carrier schema after birth" begin
    model = CompositeModel(Object(:root; scale=:Plant);
        applications=(ModelSpec(ManyReader(); name=:reader, on=One(id=:root), inputs=(
            values=Many(scale=:Leaf, within=Subtree(), var=:x, from_status=true),)),))
    simulation = run!(model; steps=1, outputs=:all)
    key = (:reader, ObjectId(:root))
    previous = simulation.compiled.input_bindings_by_target[key]
    @test isempty(only(previous).source_ids)
    @test isempty(only(previous).carrier)
    @test model_status(model, :root).total === 0.0
    check_indexes(model, simulation)
    status = Status(x=7.0)
    reference = PSE.refvalue(status, :x)
    register_object!(model, Object(1; scale=:Leaf, parent=:root, status))
    step!(simulation)
    current = simulation.compiled.input_bindings_by_target[key]
    @test typeof(current) !== typeof(previous)
    @test only(current).source_ids == [ObjectId(1)]
    @test only(parent(only(current).carrier)) === reference
    @test model_status(model, :root).total === 7.0
    @test outputs(simulation)[(:reader, ObjectId(:root), :total)] ==
        [(1.0, 0.0), (2.0, 7.0)]
    check_indexes(model, simulation)
end

@testset "cold Many excludes pending births with mixed registry identities" begin
    for closed in (false, true)
        data = call_fixture(closed)
        model, simulation = data.model, data.simulation
        binding = only(binding for binding in simulation.compiled.call_bindings
            if binding.call === :many)
        references = Dict(id => PSE.refvalue(model_status(model, id), :x)
            for id in (1, :leaf))
        register_object!(model, Object(2; scale=:Leaf, parent=:root,
            status=Status(x=7f0)))
        register_object!(model, Object(:new_leaf; scale=:Leaf, parent=:root,
            status=Status(x=9f0)))

        ids, applications = PSE._resolved_compiled_call_membership(
            simulation.compiled, binding)
        @test ids == [ObjectId(1), ObjectId(:leaf)]
        @test applications == [:leaf]
        @test !PSE._compiled_call_membership_is_observed(binding)
        step!(simulation)
        run_call!(data.capture[], :many; publish=true)
        @test [target.object_id for target in call_targets(data.capture[], :many)] ==
            [ObjectId(1), ObjectId(2), ObjectId(:leaf), ObjectId(:new_leaf)]
        @test model_status(model, 2).x === 8f0
        @test model_status(model, :new_leaf).x === 10f0
        @test all(PSE.refvalue(model_status(model, id), :x) === ref
            for (id, ref) in references)
        check_indexes(model, simulation)
    end
end

@testset "selector results preserve the registry identity family" begin
    for closed in (false, true)
        data = call_fixture(closed)
        model, simulation = data.model, data.simulation
        I = keytype(model.registry.objects)
        references = Dict(id => PSE.refvalue(model_status(model, id), :x)
            for id in (1, :leaf))
        matcher = PSE._compile_selector_matcher(model, Many())
        candidates = (ObjectId(1), ObjectId(1.25), ObjectId(:leaf))
        ids = PSE._matching_selector_ids(model, matcher, candidates,
            nothing, false, nothing, false)
        @test eltype(ids) === I
        @test ids == [ObjectId(1), ObjectId(:leaf)]
        selected = resolve_object_ids(model, Many(Subtree(); scale=:Leaf); context=:root)
        @test eltype(selected) === I
        @test selected == ids
        self = resolve_object_ids(model, One(within=Self()); context=:root)
        @test eltype(self) === I
        @test only(self) === ObjectId(:root)
        missing = resolve_object_ids(model, Many(id=1.25))
        @test isempty(missing) && eltype(missing) === I
        @test_throws "No model object with id" resolve_object_ids(model,
            One(within=Self()); context=ObjectId(1.25))
        @test all(PSE.refvalue(model_status(model, id), :x) === reference
            for (id, reference) in references)
        check_indexes(model, simulation)
    end
end

@testset "selector diagnostics preserve available labels and suggestions" begin
    ordinary = call_fixture(false).model
    closed = call_fixture(true).model
    message(model, selector) = try
        resolve_object_ids(model, selector)
        ""
    catch error
        sprint(showerror, error)
    end
    for selector in (One(scale=:Leaf), One(scale=:Leef))
        expected = message(ordinary, selector)
        @test occursin("Expected exactly one object", expected)
        @test occursin("available=", expected) && occursin("suggestions=", expected)
        @test message(closed, selector) == expected
    end
    @test occursin("suggestions=(scale = [:Leaf]", message(closed, One(scale=:Leef)))
end

end
