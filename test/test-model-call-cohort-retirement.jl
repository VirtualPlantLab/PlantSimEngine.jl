module CallCohortRetirementChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "retirement_caller" verbose=false
PSE.@process "retirement_leaf" verbose=false
struct Caller <: AbstractRetirement_CallerModel
    capture::Base.RefValue{Any}
end
struct Leaf <: AbstractRetirement_LeafModel end
PSE.inputs_(::Union{Caller,Leaf}) = NamedTuple()
PSE.outputs_(::Caller) = (caller_visits=0,)
PSE.outputs_(::Leaf) = (leaf_visits=0,)
function PSE.run!(model::Caller, status, environment, constants, context)
    model.capture[] = context
    status.caller_visits += 1
    run_call!(context, :left; publish=false)
    run_call!(context, :right; publish=false)
    return nothing
end
PSE.run!(::Leaf, status, environment, constants, context) = (status.leaf_visits += 1; nothing)

# Real authored bindings: the caller has a Symbol identity, its callees Int IDs.
function fixture(; transform=identity, outputs=:none)
    capture = Ref{Any}(nothing)
    model = CompositeModel(
        Object(:caller; scale=:Scene, status=Status(caller_visits=0)),
        Object(1; scale=:Leaf, parent=:caller, status=Status(leaf_visits=0)),
        Object(2; scale=:Leaf, parent=:caller, status=Status(leaf_visits=0));
        applications=(
            ModelSpec(Caller(capture); name=:caller, on=One(id=:caller, scale=:Scene),
                calls=(left=Many(scale=:Leaf, application=:leaf),
                    right=Many(scale=:Leaf, application=:leaf))),
            ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf)),
        ))
    model = transform(model)
    simulation = run!(model; steps=0, outputs)
    target = only(only(only(simulation.execution_plan.groups).batches).targets)
    left = call_targets(target.context, :left)
    right = call_targets(target.context, :right)
    return (; model, simulation, target, left, right, capture)
end

# Unit payloads exercise the storage protocol without inventing a Status,
# Required value, default, scientific object or model callback for a type witness.
mutable struct Payload{I,V}
    object_id::I
    value::V
end
payload(id, value) = Payload(ObjectId(id), Ref(value))
schema_for(values...) = PSE._closed_execution_cohort_schema(Tuple{map(typeof, values)...})
storage() = PSE.RuntimeStorage(Dict{Tuple{Symbol,ObjectId,Symbol},Any}())
batch(rows) = (application=(id=:leaf,), targets=rows)
function prefix(rows, count)
    return PSE.ExecutionCohortRows{eltype(rows)}(rows.store, rows.cohort, rows.indices[1:count])
end

@testset "caller identity remains independent from the callee schema" begin
    data = fixture()
    application = data.simulation.compiled.applications_by_id[:caller]
    for calls in (data.left, data.right)
        binding = calls.binding
        @test fieldtype(typeof(binding), :consumer_id) === ObjectId{Symbol}
        @test binding.consumer_id === ObjectId(:caller)
        @test eltype(binding.callee_object_ids) === ObjectId
        @test all(id -> id isa ObjectId{Int}, binding.callee_object_ids)
        @test PSE._current_call_binding_for_application(data.simulation.compiled,
            application, binding) === binding
        @test PSE._prepared_call_mode(typeof(binding)) === :manual
        @test PSE._prepared_call_name(typeof(binding)) in (:left, :right)
    end
    @test PSE._execution_call_owner(data.left.binding) != PSE._execution_call_owner(data.right.binding)
    @test model_status(data.model, :caller).caller_visits == 0
    @test model_status(data.model, 1).leaf_visits == 0
end

@testset "closed retirement removes only its call namespace and preserves references" begin
    data = fixture()
    runtime = storage()
    left_owner, right_owner = map(PSE._execution_call_owner, (data.left.binding, data.right.binding))
    first, second = payload(1, 1.0), payload(2, 2.0)
    other_first = Payload(first.object_id, first.value)
    other_second = Payload(second.object_id, second.value)
    left = PSE.cohort_rows!(runtime.cohorts, :leaf, [first, second]; owner=left_owner)
    right = PSE.cohort_rows!(runtime.cohorts, :leaf, [other_first, other_second]; owner=right_owner)
    # An unrelated ordinary namespace has a different identity domain. Owner
    # filtering must precede closed callee-ID admission.
    unrelated = payload(:unrelated, 7.0)
    ordinary = PSE.cohort_rows!(runtime.cohorts, :leaf, [unrelated]; owner=:ordinary)
    schema = schema_for(first)
    @test eltype(PSE._call_retirement_obsolete(schema)) === Tuple{Symbol,ObjectId{Int}}
    before_right = copy(right.indices)
    right_location = PSE.cohort_location(runtime.cohorts, :leaf, second.object_id; owner=right_owner)
    PSE._retire_call_cohort_targets!(runtime, data.left.binding, (batch(prefix(left, 1)),); schema)
    @test left[1] === first
    @test_throws ArgumentError left[2]
    @test right.indices == before_right
    @test right[1] === other_first && right[2] === other_second
    @test PSE.cohort_location(runtime.cohorts, :leaf, second.object_id; owner=right_owner) === right_location
    @test right[2].value === second.value
    @test first.value[] == 1.0 && second.value[] == 2.0
    @test ordinary[1] === unrelated
end

@testset "mixed admitted callee identities retire through the same algorithm" begin
    data = fixture()
    runtime = storage()
    owner = PSE._execution_call_owner(data.left.binding)
    integer, symbolic = payload(1, 1.0), payload(:leaf, 2.0f0)
    integer_rows = PSE.cohort_rows!(runtime.cohorts, :leaf, [integer]; owner)
    symbol_rows = PSE.cohort_rows!(runtime.cohorts, :leaf, [symbolic]; owner)
    schema = schema_for(integer, symbolic)
    I = Union{ObjectId{Int},ObjectId{Symbol}}
    @test eltype(PSE._call_retirement_obsolete(schema)) === Tuple{Symbol,I}
    PSE._retire_call_cohort_targets!(runtime, data.left.binding, (); schema)
    @test isempty(runtime.cohorts.locations)
    @test_throws ArgumentError integer_rows[1]
    @test_throws ArgumentError symbol_rows[1]
    @test integer.value[] === 1.0 && symbolic.value[] === 2.0f0
end

@testset "all identities and old payload families are admitted before the first clear" begin
    data = fixture()
    owner = PSE._execution_call_owner(data.left.binding)
    for invalid in (:identity, :payload)
        runtime = storage()
        first = payload(1, 1.0)
        second = invalid === :identity ? payload(:outside, 2.0) : payload(2, 2.0f0)
        first_rows = PSE.cohort_rows!(runtime.cohorts, :leaf, [first]; owner)
        second_rows = PSE.cohort_rows!(runtime.cohorts, :leaf, [second]; owner)
        locations = copy(runtime.cohorts.locations)
        schema = schema_for(first)
        @test_throws ArgumentError PSE._retire_call_cohort_targets!(runtime, data.left.binding, (); schema)
        @test runtime.cohorts.locations == locations
        @test first_rows[1] === first && second_rows[1] === second
        @test first.value[] === 1.0
        @test second.value[] === (invalid === :identity ? 2.0 : 2.0f0)
    end
end

struct OwnerAlias{T}
    value::T
end
Base.isequal(left::OwnerAlias, right::Tuple) = isequal(left.value, right)
Base.isequal(left::Tuple, right::OwnerAlias) = isequal(left, right.value)
Base.hash(owner::OwnerAlias, seed::UInt) = hash(owner.value, seed)

@testset "ordinary arbitrary owners keep their existing equality semantics" begin
    data = fixture()
    runtime = storage()
    owner = PSE._execution_call_owner(data.left.binding)
    alias = OwnerAlias(owner)
    value = payload(1, 3.0)
    rows = PSE.cohort_rows!(runtime.cohorts, :leaf, [value]; owner=alias)
    location = PSE.cohort_location(runtime.cohorts, :leaf, value.object_id; owner=alias)
    @test PSE._execution_cohort_owner_matches(PSE.OpenExecutionCohortSchema(), alias, owner)
    @test !PSE._execution_cohort_owner_matches(schema_for(value), alias, owner)
    @test PSE._check_execution_cohort_location(location, owner, :leaf, value.object_id) === nothing
    @test_throws ArgumentError PSE._with_execution_cohort_location(identity, schema_for(value),
        runtime.cohorts, location, owner, :leaf, value.object_id)
    @test rows[1] === value
    PSE._retire_call_cohort_targets!(runtime, data.left.binding, ())
    @test isempty(runtime.cohorts.locations)
    @test_throws ArgumentError rows[1]
    @test value.value[] === 3.0
end

# The future Symbol Leaf descriptor uses the type of an actual complete Leaf
# status already owned by this scene. It constructs no future Status or object.
function closed_registry_with_future_leaf(model)
    previous = model.registry
    closed = PSE._closed_object_family_store(previous.objects)
    S = typeof(model_status(model, 1))
    future = PSE.ObjectFamily{ObjectId{Symbol},S}(
        Union{Nothing,PSE.ObjectFamilyRow{ObjectId{Symbol},S}}[])
    families = (closed.catalog.families..., future)
    store = PSE.ObjectFamilyStore(PSE.ClosedObjectFamilyCatalog(families),
        closed.locations, closed.status_owners, copy(closed.layout_cache))
    registry = PSE.ObjectRegistry(store, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    return PSE.CompositeModel(
        registry, model.applications, model.environment, model.instances,
        model.source_adapter, model.status_conversion, model.status_conversion_records,
        model.status_source_owners, model.status_source_identities,
        model.scenario_plan_cache, model.binding_cache, model.environment_binding_cache,
        model.bindings_dirty, model.environment_bindings_dirty, model.lifecycle_delta,
        model.input_default_status_variables, model.runtime_revision, model.revision,
        model.environment_revision,
    )
end
current_target(simulation) = only(only(only(simulation.execution_plan.groups).batches).targets)
view_ids(values) = [target.object_id for target in values]
live_state(model) = Dict(object.id => deepcopy(NamedTuple(object.status)) for object in model_objects(model))
stream_values(simulation) = Dict(key => collect(stream) for (key, stream) in outputs(simulation))

# Bottom-up descriptors come from the real zero-step batches, not fake statuses,
# model invocation or a default used as a scientific witness.
function prepared_tree(data)
    left_batches = PSE._materialize_call_execution_batches!(data.left)
    right_batches = PSE._materialize_call_execution_batches!(data.right)
    LeafB = typeof(only(left_batches))
    @test typeof(only(right_batches)) === LeafB
    leaf_schema = PSE.PreparedExecutionBatchSchema{Vector{LeafB}}()
    root_batch = only(only(data.simulation.execution_plan.groups).batches)
    RootB = PSE._execution_batch_type_with_call_schemas(typeof(root_batch),
        (left=leaf_schema, right=leaf_schema))
    simulation = PSE._prepare_execution_batch_schemas(data.simulation,
        (caller=PSE.PreparedExecutionBatchSchema{Vector{RootB}}(), leaf=leaf_schema))
    target = current_target(simulation)
    return merge(data, (simulation=simulation, target=target,
        left=call_targets(target.context, :left), right=call_targets(target.context, :right)))
end

function publish_current_left!(data)
    step!(data.simulation)
    context = data.capture[]
    @test context isa PSE.RunContext
    run_call!(context, :left; publish=true)
    return context
end

@testset "closed memberships use the global future identity schema" begin
    data = fixture(; transform=closed_registry_with_future_leaf)
    I = Union{ObjectId{Symbol},ObjectId{Int}}
    @test keytype(data.model.registry.objects) === I
    applications = data.simulation.compiled.applications_by_id
    for name in (:caller, :leaf)
        @test eltype(applications[name].target_ids) === I
    end
    @test all(id -> id isa ObjectId{Int}, applications[:leaf].target_ids)
    for calls in (data.left, data.right)
        @test fieldtype(typeof(calls.binding), :consumer_id) === ObjectId{Symbol}
        @test eltype(calls.binding.callee_object_ids) === I
        @test PSE._current_call_binding_for_application(data.simulation.compiled,
            applications[:caller], calls.binding) === calls.binding
    end
    partial = PSE._partial_model_application(applications[:leaf], ObjectId{Int}[ObjectId(1)])
    @test eltype(partial.target_ids) === I
    @test partial.target_ids == [ObjectId(1)]
    @test partial.target_ids !== applications[:leaf].target_ids
    snapshot = PSE._prepare_scenario_plan(data.model)
    @test all(ids -> eltype(ids) === I, snapshot.target_ids)
    copied = PSE._scenario_applications(snapshot)
    for app in copied
        @test eltype(app.target_ids) === I
        @test app.target_ids == applications[app.id].target_ids
        @test app.target_ids !== applications[app.id].target_ids
    end
    selected = call_targets(data.target.context, :left; objects=(1,))
    @test eltype(selected.binding.callee_object_ids) === I
    @test typeof(selected.binding) === typeof(data.left.binding)
    @test view_ids(selected) == [ObjectId(1)]
end

@testset "ordinary and prepared public calls retain state histories and membership through birth and removal" begin
    ordinary = fixture(; transform=closed_registry_with_future_leaf, outputs=:all)
    prepared = prepared_tree(fixture(; transform=closed_registry_with_future_leaf, outputs=:all))
    fixtures = (ordinary, prepared)
    references = [PSE.refvalue(model_status(data.model, 2), :leaf_visits) for data in fixtures]
    held = [data.left for data in fixtures]
    for data in fixtures
        publish_current_left!(data)
        @test model_status(data.model, 1).leaf_visits == 3
        @test model_status(data.model, 2).leaf_visits == 3
        register_object!(data.model, Object(3; scale=:Leaf, parent=:caller,
            status=Status(leaf_visits=0)))
        context = publish_current_left!(data)
        @test model_status(data.model, 1).leaf_visits == 6
        @test model_status(data.model, 2).leaf_visits == 6
        @test model_status(data.model, 3).leaf_visits == 3
        selected = call_targets(context, :left; objects=(3,))
        @test eltype(selected.binding.callee_object_ids) === keytype(data.model.registry.objects)
        @test view_ids(selected) == [ObjectId(3)]
    end
    @test live_state(ordinary.model) == live_state(prepared.model)
    @test stream_values(ordinary.simulation) == stream_values(prepared.simulation)
    for (data, full_view) in zip(fixtures, held)
        @test view_ids(full_view) == [ObjectId(1), ObjectId(2), ObjectId(3)]
        remove_object!(data.model, 1)
        context = publish_current_left!(data)
        @test view_ids(full_view) == [ObjectId(2), ObjectId(3)]
        @test eltype(full_view.binding.callee_object_ids) === keytype(data.model.registry.objects)
        @test model_status(data.model, 2).leaf_visits == 9
        @test model_status(data.model, 3).leaf_visits == 6
        @test model_status(data.model, :caller).caller_visits == 3
        @test view_ids(call_targets(context, :left; objects=(2,))) == [ObjectId(2)]
        @test collect(outputs(data.simulation)[(:leaf, ObjectId(1), :leaf_visits)]) == [(1.0,3), (2.0,6)]
    end
    for (data, reference) in zip(fixtures, references)
        @test PSE.refvalue(model_status(data.model, 2), :leaf_visits) === reference
    end
    @test live_state(ordinary.model) == live_state(prepared.model)
    @test stream_values(ordinary.simulation) == stream_values(prepared.simulation)
end

@testset "ordinary open identity domains still accept a later Symbol Leaf" begin
    data = fixture()
    continue!(data.simulation; steps=2)
    register_object!(data.model, Object(:later_leaf; scale=:Leaf, parent=:caller,
        status=Status(leaf_visits=0)))
    step!(data.simulation)
    @test keytype(data.model.registry.objects) === ObjectId
    @test model_status(data.model, :later_leaf).leaf_visits == 2
    @test ObjectId(:later_leaf) in view_ids(call_targets(data.capture[], :left))
end

@testset "an initially empty Many keeps its explicit future Symbol Leaf identity family" begin
    function empty_closed(model)
        closed = closed_registry_with_future_leaf(model)
        remove_object!(closed, 1)
        remove_object!(closed, 2)
        return closed
    end
    data = fixture(; transform=empty_closed)
    I = Union{ObjectId{Symbol},ObjectId{Int}}
    leaf = data.simulation.compiled.applications_by_id[:leaf]
    @test isempty(leaf.target_ids)
    @test eltype(leaf.target_ids) === I
    @test eltype(data.left.binding.callee_object_ids) === I
    @test isempty(data.left)
    register_object!(data.model, Object(:future_leaf; scale=:Leaf, parent=:caller,
        status=Status(leaf_visits=0)))
    step!(data.simulation)
    @test model_status(data.model, :future_leaf).leaf_visits == 2
    @test view_ids(data.left) == [ObjectId(:future_leaf)]
    @test eltype(data.left.binding.callee_object_ids) === I
    # Identity metadata under ordinary open execution: no full prepared Target
    # family for a future Symbol is claimed by this case.
    @test data.left.batch_schema isa PSE.OpenExecutionBatchSchema
end

@testset "changed targets preserve the admitted identity family and sorting" begin
    changed = Set{Tuple{Symbol,ObjectId}}(((:leaf, ObjectId(13)),
        (:leaf, ObjectId(1)), (:leaf, ObjectId(:future)), (:caller, ObjectId(:caller))))
    original = copy(changed)
    for I in (ObjectId, Union{ObjectId{Int},ObjectId{Symbol}})
        grouped = PSE._changed_execution_target_ids_by_application(changed, I)
        @test eltype(grouped[:leaf]) === I
        @test grouped[:leaf] == [ObjectId(1), ObjectId(13), ObjectId(:future)]
        @test grouped[:caller] == [ObjectId(:caller)]
        @test changed == original
    end
end

end # module CallCohortRetirementChecks
