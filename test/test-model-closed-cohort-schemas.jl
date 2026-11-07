module ClosedCohortSchemaChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine

mutable struct Target{I,S,C}
    object_id::I
    status::S
    context::C
end
make_target(id, value) = Target(ObjectId(id), Status(value=value), Ref(0))
ids(values) = ObjectId{Int}[ObjectId(value) for value in values]
flatten(membership) = [target for rows in membership.runs for target in rows]
schema_for(targets...) = PSE._closed_execution_cohort_schema(Tuple{map(typeof, targets)...})

function refresh(store, targets, current, changed=nothing; previous=nothing, owner=nothing, schema=PSE.OpenExecutionCohortSchema())
    PSE.refresh_cohort_membership!(store, :growth, ids(current), isnothing(changed) ? nothing : ids(changed);
        previous, owner, schema) do object_id, old
        targets[object_id]
    end
end

@testset "closed replacement admits old and new payloads before clearing" begin
    store = PSE.ExecutionCohortStore()
    first, last = make_target(1, 1.0), make_target(3, 3.0)
    changed = make_target(1, 5.0f0)
    schema = schema_for(first, changed)
    targets = Dict{ObjectId,Any}(first.object_id => first, last.object_id => last)
    membership = refresh(store, targets, (1, 3); schema).membership
    old_rows = only(membership.runs)
    first_location = PSE.cohort_location(store, :growth, first.object_id)
    last_location = PSE.cohort_location(store, :growth, last.object_id)
    last_reference = PSE.refvalue(last.status, :value)
    @test isconcretetype(fieldtype(typeof(first_location), :cohort))
    @test eltype(membership.object_ids) === ObjectId{Int}
    @test eltype(membership.locations) !== PSE.ExecutionCohortLocation
    @test eltype(membership.runs) !== PSE.ExecutionCohortRows

    targets[first.object_id] = changed
    replaced = refresh(store, targets, (1, 3), (1,); previous=membership, schema)
    @test replaced.membership === membership
    @test flatten(membership) == [changed, last]
    @test isnothing(first_location.cohort.rows[first_location.row])
    @test Base.last(membership.runs) === old_rows
    @test old_rows.indices == [last_location.row]
    @test only(old_rows) === last
    @test_throws ArgumentError PSE._execution_cohort_target(first_location)
    @test PSE.cohort_location(store, :growth, last.object_id) === last_location
    @test PSE.refvalue(last.status, :value) === last_reference

    targets[first.object_id] = first
    restored = refresh(store, targets, (1, 3), (1,); previous=membership, schema)
    @test flatten(restored.membership) == [first, last]
    @test PSE.cohort_location(store, :growth, first.object_id) === first_location
    @test PSE.refvalue(last.status, :value) === last_reference
end

@testset "root and distinct calls keep separate execution owners" begin
    store = PSE.ExecutionCohortStore()
    root = make_target(1, 2.0)
    first_call = Target(root.object_id, root.status, Ref(1))
    second_call = Target(root.object_id, root.status, Ref(2))
    owners = (nothing,
        (:first, ObjectId(10), :call, :manual),
        (:second, ObjectId(20), :call, :manual))
    schema = schema_for(root)
    memberships = map(zip(owners, (root, first_call, second_call))) do (owner, target)
        refresh(store, Dict{ObjectId,Any}(target.object_id => target), (1,); owner, schema).membership
    end
    @test length(unique([only(membership.runs).cohort for membership in memberships])) == 3
    @test all(membership -> only(flatten(membership)).status === root.status, memberships)
    @test collect(map(membership -> only(flatten(membership)).context[], memberships)) == [0, 1, 2]
    called = Ref(false)
    foreign = PSE.cohort_location(store, :growth, root.object_id; owner=owners[2])
    @test_throws ArgumentError PSE._with_execution_cohort_location(schema, store, foreign,
        owners[3], :growth, root.object_id) do admitted
        called[] = true
    end
    @test !called[]
    @test PSE.remove_cohort_target!(store, :growth, root.object_id; owner=owners[2], schema)
    @test only(flatten(memberships[1])) === root
    @test only(flatten(memberships[3])) === second_call
end

@testset "removing an interleaved family preserves order and merges runs" begin
    store = PSE.ExecutionCohortStore()
    first, middle, last = make_target(1, 1.0), make_target(2, 2.0f0), make_target(3, 3.0)
    targets = Dict{ObjectId,Any}(target.object_id => target for target in (first, middle, last))
    schema = schema_for(first, middle)
    membership = refresh(store, targets, 1:3; schema).membership
    @test length(membership.runs) == 3
    original_left = Base.first(membership.runs)
    original_last = PSE.cohort_location(store, :growth, last.object_id)
    removed = refresh(store, targets, (1, 3), (2,); previous=membership, schema)
    @test removed.targets_removed == 1
    @test only(membership.runs) === original_left
    @test membership.run_starts == [1]
    @test flatten(membership) == [first, last]
    @test PSE.cohort_location(store, :growth, last.object_id) === original_last
    @test getproperty.(flatten(membership), :object_id) == ids((1, 3))
end

@testset "an empty future schema creates no target or scientific default" begin
    S = Status{(:value,),Tuple{Base.RefValue{Float64}}}
    T = Target{ObjectId{Int},S,Base.RefValue{Int}}
    schema = PSE._closed_execution_cohort_schema(Tuple{T})
    store = PSE.ExecutionCohortStore()
    calls = Ref(0)
    created = Ref{Any}()
    builder = (object_id, old) -> begin
        calls[] += 1
        created[] = make_target(object_id.value, 3.0)
    end
    membership = PSE.refresh_cohort_membership!(builder, store, :growth, ids(()), nothing; schema).membership
    @test calls[] == 0
    @test !isassigned(created)
    @test isempty(store.cohorts) && isempty(store.locations)
    @test isempty(membership.runs) && isempty(membership.locations)
    @test eltype(membership.object_ids) === ObjectId{Int}
    added = PSE.refresh_cohort_membership!(builder, store, :growth, ids((7,)), ids((7,)); previous=membership)
    @test calls[] == 1
    witness = created[]
    location = PSE.cohort_location(store, :growth, witness.object_id)
    @test only(flatten(added.membership)) === witness
    PSE.refresh_cohort_membership!(builder, store, :growth, ids(()), ids((7,)); previous=membership)
    @test isempty(membership.runs)
    @test isnothing(location.cohort.rows[location.row])
    PSE.refresh_cohort_membership!(builder, store, :growth, ids((7,)), ids((7,)); previous=membership)
    @test calls[] == 2
    @test PSE.cohort_location(store, :growth, witness.object_id) === location
    @test only(flatten(membership)) === created[]
    @test created[] !== witness
end

@testset "schema and identity admission precede any removal or splice" begin
    store = PSE.ExecutionCohortStore()
    first, second = make_target(1, 1.0), make_target(2, 2.0)
    schema = schema_for(first)
    targets = Dict{ObjectId,Any}(first.object_id => first, second.object_id => second)
    membership = refresh(store, targets, (1, 2); schema).membership
    original_ids = copy(membership.object_ids)
    original_runs = copy(membership.runs)
    original_locations = copy(membership.locations)
    targets[second.object_id] = make_target(2, 2.0f0)
    @test_throws ArgumentError refresh(store, targets, (2,), (1, 2); previous=membership, schema)
    @test membership.object_ids == original_ids
    @test all(a === b for (a, b) in zip(membership.runs, original_runs))
    @test membership.locations == original_locations
    @test flatten(membership) == [first, second]
    @test length(store.locations) == 2
    @test_throws ArgumentError PSE.refresh_cohort_membership!((id, old) -> first,
        store, :growth, ObjectId[ObjectId(:foreign)], nothing; schema)
    @test flatten(membership) == [first, second]

    # A same-family append must never silently clear a different family.
    changed = make_target(1, 4.0f0)
    changed_rows = PSE.cohort_rows!(store, :growth, [changed])
    rows = original_runs[1]
    @test_throws ArgumentError PSE._append_execution_cohort_target!(rows, first)
    @test length(rows) == 2
    @test changed_rows[1] === changed
    @test isnothing(original_locations[1].cohort.rows[original_locations[1].row])
end

PSE.@process "closed_cohort_owner" verbose=false
PSE.@process "closed_cohort_middle" verbose=false
PSE.@process "closed_cohort_leaf" verbose=false
struct Owner{C} <: AbstractClosed_Cohort_OwnerModel
    capture::C
end
struct Middle <: AbstractClosed_Cohort_MiddleModel end
struct Leaf <: AbstractClosed_Cohort_LeafModel end
PSE.outputs_(::Owner) = (owner_visits=0,)
PSE.outputs_(::Middle) = (middle_visits=0,)
PSE.outputs_(::Leaf) = (leaf_visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    run_call!(context, :middle; publish=true)
    status.owner_visits += 1
    return nothing
end
function PSE.run!(::Middle, status, environment, constants, context)
    run_call!(context, :leaf; publish=true)
    status.middle_visits += 1
    return nothing
end
PSE.run!(::Leaf, status, environment, constants, context) = (status.leaf_visits += 1; nothing)

@testset "real two-level calls remain outside the runtime store type" begin
    capture = Ref{Any}()
    model = CompositeModel(Object(:plant; scale=:Plant); applications=(
        ModelSpec(Owner(capture); name=:owner, on=One(id=:plant),
            calls=(middle=One(within=Self(), application=:middle),)),
        ModelSpec(Middle(); name=:middle, on=One(id=:plant),
            calls=(leaf=One(within=Self(), application=:leaf),)),
        ModelSpec(Leaf(); name=:leaf, on=One(id=:plant)),
    ))
    simulation = run!(model; steps=1, outputs=:all)
    state = model_status(model, :plant)
    @test (state.owner_visits, state.middle_visits, state.leaf_visits) == (1, 1, 1)
    middle = only(call_targets(capture[], :middle))
    batches = capture[].calls[1].execution_batches
    schema = PSE._execution_cohort_schema(batches)
    @test schema isa PSE.ClosedExecutionCohortSchema
    @test fieldtype(typeof(only(batches).targets), :store) === PSE.ExecutionCohortStore{ObjectId,Any,Tuple{Any,Symbol,DataType},Tuple{Any,Symbol,ObjectId}}
    @test fieldtype(typeof(simulation.temporal_streams), :cohorts) === PSE.ExecutionCohortStore{ObjectId,Any,Tuple{Any,Symbol,DataType},Tuple{Any,Symbol,ObjectId}}
    @test typeof(simulation.temporal_streams.cohorts) === PSE.ExecutionCohortStore{ObjectId,Any,Tuple{Any,Symbol,DataType},Tuple{Any,Symbol,ObjectId}}
    owner = PSE._execution_call_owner(capture[].calls[1].binding)
    location = PSE.cohort_location(simulation.temporal_streams.cohorts,:middle,
        ObjectId(:plant);owner)
    @test PSE._execution_cohort_target(location) === middle.execution_target
    original_context = middle.context_cache.default
    original_stamp = middle.context_cache.execution_stamp
    middle_reference = PSE.refvalue(state,:middle_visits)
    leaf_reference = PSE.refvalue(state,:leaf_visits)
    @test isnothing(PSE._model_execution_target_change_reason(middle.execution_target,
        middle.compiled,middle.environment_bindings,middle.application,
        middle.output_retention,middle.temporal_streams))
    rebuilt = PSE._compiled_call_execution_batches(middle.compiled, middle.environment_bindings,
        capture[].calls[1].binding, middle.temporal_streams, middle.output_retention, middle.constants;
        cohort_schema=schema)
    @test only(only(rebuilt).targets) === middle.execution_target
    @test only(only(rebuilt).targets).context === original_context
    @test only(only(rebuilt).targets).call_context_cache === middle.context_cache
    @test middle.context_cache.execution_stamp === original_stamp
    @test PSE.refvalue(state,:middle_visits) === middle_reference
    @test PSE.refvalue(state,:leaf_visits) === leaf_reference
    @test (state.owner_visits,state.middle_visits,state.leaf_visits) == (1,1,1)
    prototype = middle.context_cache.default
    leased = PSE._prepare_cached_call_context!(
        middle.context_cache, false, middle.compiled, middle.environment_bindings,
        middle.application, middle.object_id, middle.bound_inputs, middle.output_targets,
        middle.execution_target.call_bindings, middle.temporal_streams,
        middle.output_retention, middle.time, middle.constants,
        middle.publication_allowed, middle.environment,
    )
    @test leased !== prototype
    original_leaf = call_targets(prototype, :leaf)
    leased_leaf = call_targets(leased, :leaf)
    @test leased_leaf !== original_leaf
    @test leased_leaf.execution_batches === original_leaf.execution_batches
    original_leaf.last_single_snapshot = (:private_borrowing_marker,)
    @test isnothing(leased_leaf.last_single_snapshot)
    original_leaf.last_single_snapshot = nothing
    @test only(leased_leaf).execution_target === only(original_leaf).execution_target
    # This tests the common factory under a supplied witness, not automatic
    # closure of cold/lazy calls; that admission boundary remains explicit.
    middle_stream = outputs(simulation)[(:middle, ObjectId(:plant), :middle_visits)]
    leaf_stream = outputs(simulation)[(:leaf, ObjectId(:plant), :leaf_visits)]
    before_middle, before_leaf = collect(middle_stream), collect(leaf_stream)
    evaluation = evaluate_call!(middle)
    @test (state.middle_visits, state.leaf_visits) == (2, 2)
    @test collect(middle_stream) == before_middle
    @test collect(leaf_stream) == before_leaf
    accept_call!(evaluation)
    @test (state.middle_visits, state.leaf_visits) == (2, 2)
    @test length(middle_stream) == length(before_middle)
    @test length(leaf_stream) == length(before_leaf)
    @test last(middle_stream) == (last(before_middle)[1], 2)
    @test last(leaf_stream) == (last(before_leaf)[1], 2)
    continue!(simulation; steps=1)
    @test (state.owner_visits, state.middle_visits, state.leaf_visits) == (2, 3, 3)
    @test [sample[2] for sample in middle_stream] == [2, 3]
    @test [sample[2] for sample in leaf_stream] == [2, 3]
end

function closed_append_allocations(count)
    store = PSE.ExecutionCohortStore()
    first = make_target(1, 1.0)
    schema = schema_for(first)
    builder = (object_id, old) -> make_target(object_id.value, Float64(object_id.value))
    current = ids(1:count)
    membership = PSE.refresh_cohort_membership!(builder, store, :growth, current, nothing; schema).membership
    push!(current, ObjectId(count + 1))
    changed = ids((count + 1,))
    return @allocated PSE.refresh_cohort_membership!(builder, store, :growth, current, changed; previous=membership)
end

@testset "closed append keeps the existing membership allocation budget" begin
    closed_append_allocations(8)
    small = minimum(closed_append_allocations(8) for _ in 1:2)
    large = minimum(closed_append_allocations(4096) for _ in 1:2)
    @test large <= small + 4096
end

function closed_from_open_append_allocations(count)
    store = PSE.ExecutionCohortStore()
    builder = (object_id, old) -> make_target(object_id.value, Float64(object_id.value))
    current = ids(1:count)
    opened = PSE.refresh_cohort_membership!(builder, store, :growth, current, nothing).membership
    original_last = flatten(opened)[end]
    original_reference = PSE.refvalue(original_last.status, :value)
    original_context = original_last.context
    original_run = only(opened.runs)
    schema = schema_for(original_last)
    closed = PSE._close_execution_cohort_membership(opened, schema)
    @test closed !== opened
    @test closed.object_ids !== opened.object_ids
    @test closed.locations !== opened.locations
    @test closed.runs !== opened.runs
    @test closed.run_starts !== opened.run_starts
    @test only(closed.runs) === original_run
    @test flatten(closed) == flatten(opened)
    @test PSE._close_execution_cohort_membership(closed, schema) === closed
    push!(current, ObjectId(count + 1))
    changed = ids((count + 1,))
    allocated = @allocated PSE.refresh_cohort_membership!(builder,
        store, :growth, current, changed; previous=closed)
    targets = flatten(closed)
    @test closed.object_ids == current
    @test getproperty.(targets, :object_id) == current
    @test [target.status.value for target in targets] == Float64.(1:(count + 1))
    @test targets[count] === original_last
    @test PSE.refvalue(targets[count].status, :value) === original_reference
    @test targets[count].context === original_context
    @test only(closed.runs) === original_run
    return allocated
end

@testset "host Open to closed preparation preserves the append capacity budget" begin
    closed_from_open_append_allocations(8)
    small = minimum(closed_from_open_append_allocations(8) for _ in 1:2)
    large = minimum(closed_from_open_append_allocations(4096) for _ in 1:2)
    @test large <= small + 4096
end

@testset "same-schema close validates ownership before reusing its owner" begin
    store = PSE.ExecutionCohortStore()
    target = make_target(1, 1.0)
    schema = schema_for(target)
    closed = refresh(store, Dict{ObjectId,Any}(target.object_id => target), (1,); schema).membership
    wrong_owner = PSE.ExecutionCohortMembership(closed.store,
        (:foreign, ObjectId(99), :call, :manual), closed.application_id,
        closed.schema, closed.object_ids, closed.locations, closed.runs, closed.run_starts)
    wrong_store = PSE.ExecutionCohortMembership(PSE.ExecutionCohortStore(),
        closed.owner, closed.application_id, closed.schema,
        closed.object_ids, closed.locations, closed.runs, closed.run_starts)
    @test_throws ArgumentError PSE._close_execution_cohort_membership(wrong_owner, schema)
    @test_throws ArgumentError PSE._close_execution_cohort_membership(wrong_store, schema)
    @test PSE._close_execution_cohort_membership(closed, schema) === closed
    @test only(flatten(closed)) === target
end

end
