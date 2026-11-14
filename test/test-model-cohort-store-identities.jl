module CohortStoreIdentityChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine

PSE.@process "cohort_store_owner" verbose=false
PSE.@process "cohort_store_leaf" verbose=false
struct Controller{C} <: AbstractCohort_Store_OwnerModel
    capture::C
end
struct Leaf <: AbstractCohort_Store_LeafModel end
PSE.inputs_(::Controller) = NamedTuple()
PSE.outputs_(::Controller) = (ticks=0,)
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (value=0.0f0,)
function PSE.run!(model::Controller, status, environment, constants, context)
    model.capture[] = context
    run_call!(context, :first; publish=true)
    run_call!(context, :alias; publish=true)
    status.ticks += 1
    return nothing
end
function PSE.run!(::Leaf, status, environment, constants, context)
    status.value += 1.0f0
    return nothing
end

function fixture(closed)
    capture = Ref{Any}()
    model = CompositeModel(Object(:root; scale=:Scene, status=Status(ticks=0)),
        Object(1; scale=:Leaf, parent=:root, status=Status(value=0.0f0));
        applications=(
            ModelSpec(Controller(capture); name=:controller, on=One(id=:root), calls=(
                first=Many(within=Subtree(), scale=:Leaf, application=:leaf),
                alias=Many(within=Subtree(), scale=:Leaf, application=:leaf))),
            ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf))))
    if closed
        previous = model.registry
        store = PSE._closed_object_family_store(previous.objects)
        # Admit this ID/status family by the type of the real supplied Leaf.
        # No future object, value, callback or status is constructed here.
        S = typeof(model_status(model, 1))
        future = PSE.ObjectFamily{ObjectId{Symbol},S}(
            Union{Nothing,PSE.ObjectFamilyRow{ObjectId{Symbol},S}}[])
        objects = PSE.ObjectFamilyStore(
            PSE.ClosedObjectFamilyCatalog((store.catalog.families...,future)),
            store.locations, store.status_owners, copy(store.layout_cache))
        registry = PSE.ObjectRegistry(objects, previous.by_scale, previous.by_kind,
            previous.by_species, previous.ancestor_ids_by_object)
        model = PSE.CompositeModel(registry, model.applications, model.environment,
            model.instances, model.source_adapter, model.status_conversion,
            model.status_conversion_records, model.status_source_owners,
            model.status_source_identities, model.scenario_plan_cache, model.binding_cache,
            model.environment_binding_cache, model.bindings_dirty,
            model.environment_bindings_dirty, model.lifecycle_delta,
            model.input_default_status_variables, model.runtime_revision,
            model.revision, model.environment_revision)
    end
    return (;model,capture)
end

@noinline plan_cohorts(plan) = plan.cohorts

function check_store(simulation, closed)
    store = simulation.temporal_streams.cohorts
    I = closed ? Union{ObjectId{Int},ObjectId{Symbol}} : ObjectId
    O = closed ? Union{Nothing,Tuple{Symbol,I,Symbol,Symbol}} : Any
    CK = closed ? PSE.ExecutionCohortKey{O,DataType} : Tuple{O,Symbol,DataType}
    LK = closed ? PSE.ExecutionCohortKey{O,I} : Tuple{O,Symbol,I}
    @test typeof(store) === PSE.ExecutionCohortStore{I,O,CK,LK}
    @test typeof(typeof(store)()) === typeof(store)
    @test fieldtype(typeof(simulation.execution_plan), :cohorts) === typeof(store)
    @test (@inferred plan_cohorts(simulation.execution_plan)) === store
    @test fieldtype(typeof(simulation.temporal_streams), :cohorts) === typeof(store)
    @test keytype(store.cohorts) === CK
    @test keytype(store.locations) === LK
    for group in simulation.execution_plan.groups
        @test group.membership.store === store
        @test fieldtype(typeof(group.membership), :store) === typeof(store)
        @test fieldtype(typeof(group.membership), :owner) === typeof(group.membership.owner)
        for batch in group.batches
            @test batch.targets.store === store
            @test fieldtype(typeof(batch.targets), :store) === typeof(store)
            @test fieldtype(typeof(batch.targets.cohort), :owner) === O
        end
    end
    copied, emptied = copy(simulation.temporal_streams), empty(simulation.temporal_streams)
    @test typeof(copied) === typeof(emptied) === typeof(simulation.temporal_streams)
    @test isempty(copied.cohorts.locations) && isempty(emptied.cohorts.locations)
    @test copied.cohorts !== store && emptied.cohorts !== store
    return store
end

@testset "ordinary execution preserves concrete store and separate call owners" begin
    for closed in (false,true)
        data = fixture(closed)
        simulation = run!(data.model; steps=1, outputs=:all)
        store = check_store(simulation, closed)
        first_calls, alias_calls = call_targets(data.capture[], :first), call_targets(data.capture[], :alias)
        first_owner = PSE._execution_call_owner(first_calls.binding)
        alias_owner = PSE._execution_call_owner(alias_calls.binding)
        first_location = PSE.cohort_location(store, :leaf, ObjectId(1); owner=first_owner)
        alias_location = PSE.cohort_location(store, :leaf, ObjectId(1); owner=alias_owner)
        first_target = first_location.cohort.rows[first_location.row]
        alias_target = alias_location.cohort.rows[alias_location.row]
        first_context = first_target.context
        reference = PSE.refvalue(model_status(data.model, 1), :value)
        @test first_location.cohort !== alias_location.cohort
        @test first_target !== alias_target
        @test first_target.context !== alias_target.context
        @test PSE.refvalue(only(first_calls).status, :value) === reference
        @test PSE.refvalue(only(alias_calls).status, :value) === reference
        @test model_status(data.model, 1).value === 2.0f0
        @test model_status(data.model, :root).ticks == 1

        register_object!(data.model, Object(:later; scale=:Leaf, parent=:root,
            status=Status(value=0.0f0)))
        continue!(simulation; steps=1)
        @test simulation.temporal_streams.cohorts === store
        retained = PSE.cohort_location(store, :leaf, ObjectId(1); owner=first_owner)
        @test retained.cohort === first_location.cohort
        @test retained.row == first_location.row
        @test retained.cohort.rows[retained.row] === first_target
        @test first_target.context === first_context
        @test PSE.refvalue(model_status(data.model, 1), :value) === reference
        @test model_status(data.model, 1).value === 4.0f0
        @test model_status(data.model, :later).value === 2.0f0
        @test model_status(data.model, :root).ticks == 2
        @test outputs(simulation)[(:leaf,ObjectId(1),:value)] == [(1.0,2.0f0),(2.0,4.0f0)]
        check_store(simulation, closed)
    end
end

@testset "prepared host reset keeps the same identity-only store schema" begin
    for closed in (false,true)
        data = fixture(closed)
        simulation = run!(data.model; steps=0, outputs=:none)
        original = simulation.temporal_streams.cohorts
        batch = only(only(simulation.execution_plan.groups).batches)
        target = only(batch.targets)
        first_call = first(target.context.calls)
        child_batch = only(PSE._materialize_call_execution_batches!(first_call))
        child_schema = PSE.PreparedExecutionBatchSchema{Vector{typeof(child_batch)}}()
        Root = PSE._execution_batch_type_with_call_schemas(typeof(batch),
            (first=child_schema,alias=child_schema))
        schemas = (controller=PSE.PreparedExecutionBatchSchema{Vector{Root}}(),leaf=child_schema)
        prepared = PSE._prepare_execution_batch_schemas(simulation, schemas)
        @test typeof(prepared.temporal_streams.cohorts) === typeof(original)
        @test prepared.temporal_streams.cohorts !== original
        @test prepared.temporal_streams.streams === simulation.temporal_streams.streams
        continue!(prepared; steps=1)
        @test model_status(data.model, 1).value === 2.0f0
        check_store(prepared, closed)
    end
end

struct Payload{I,S,M}
    object_id::I
    status::S
    marker::M
end

@testset "bounded stores retain the open family replacement operation" begin
    data = fixture(true)
    store = PSE.ExecutionCohortStore(data.model.registry.objects)
    status = model_status(data.model, 1)
    first = Payload(ObjectId(1), status, Ref(1))
    second = Payload(ObjectId(1), status, Ref(1.0f0))
    initial = PSE.refresh_cohort_membership!(store, :leaf, [ObjectId(1)], nothing) do id, previous
        first
    end
    location = only(initial.membership.locations)
    refreshed = PSE.refresh_cohort_membership!(store, :leaf, [ObjectId(1)], [ObjectId(1)];
        previous=initial.membership) do id, previous
        second
    end
    @test refreshed.membership === initial.membership
    @test isnothing(location.cohort.rows[location.row])
    @test only(only(refreshed.membership.runs)) === second
    @test second.status === status
    @test length(store.cohorts) == 2
    @test isnothing(PSE.cohort_location(store, :leaf, ObjectId(:foreign)))
    @test_throws TypeError PSE.cohort_location(store, :leaf, ObjectId(1.0f0))
    @test_throws TypeError PSE.cohort_location(store, :leaf, ObjectId(1); owner=:foreign)

    open = PSE.ExecutionCohortStore()
    original = PSE.cohort_rows!(open, :leaf, [first]; owner=1)
    @test PSE.cohort_location(open, :leaf, ObjectId(1); owner=1.0) ===
          PSE.cohort_location(open, :leaf, ObjectId(1); owner=1)
    @test original[1] === first
end

@testset "fixed and dynamic plans share their existing concrete store" begin
    for closed in (false,true)
        data = fixture(closed)
        simulation = run!(data.model; steps=0, outputs=:all)
        original = simulation.execution_plan
        store = check_store(simulation, closed)
        batch = only(only(original.groups).batches)
        target = only(batch.targets)
        reference = PSE.refvalue(model_status(data.model, 1), :value)
        fixed = PSE._fixed_execution_plan(original)
        @test fixed.topology isa PSE.FixedExecution
        @test fixed.cohorts === original.cohorts === store
        @test fieldtype(typeof(fixed), :cohorts) === typeof(store)
        @test only(only(fixed.groups).batches) === batch
        @test only(only(only(fixed.groups).batches).targets) === target
        fixed_simulation = PSE._simulation_with_execution_plan(simulation, fixed)
        @test fixed_simulation.temporal_streams === simulation.temporal_streams
        step!(fixed_simulation)
        @test model_status(data.model, 1).value === 2.0f0
        @test PSE.refvalue(model_status(data.model, 1), :value) === reference
        check_store(fixed_simulation, closed)

        # Rebuild only container/topology metadata with the same canonical
        # constructor. The timeline, schedule, payloads and refs are retained.
        dynamic = PSE.CompiledExecutionPlan(fixed.cohorts,PSE.DynamicExecution(),
            typeof(original.groups)(collect(fixed.groups)),typeof(original.batches)(collect(fixed.batches)),
            typeof(original.groups_by_application_slot)(collect(fixed.groups_by_application_slot)),
            fixed.schedule,fixed.model_revision,fixed.environment_revision)
        dynamic_simulation = PSE._simulation_with_execution_plan(fixed_simulation, dynamic)
        @test dynamic.cohorts === store
        @test fieldtype(typeof(dynamic), :cohorts) === typeof(store)
        @test dynamic.schedule === fixed.schedule
        register_object!(data.model, Object(:later;scale=:Leaf,parent=:root,
            status=Status(value=0.0f0)))
        step!(dynamic_simulation)
        @test model_status(data.model, 1).value === 4.0f0
        @test model_status(data.model, :later).value === 2.0f0
        @test PSE.refvalue(model_status(data.model, 1), :value) === reference
        check_store(dynamic_simulation, closed)
        remove_object!(data.model, 1)
        step!(dynamic_simulation)
        @test model_status(data.model, :later).value === 4.0f0
        @test model_status(data.model, :root).ticks == 3
        @test outputs(dynamic_simulation)[(:leaf,ObjectId(1),:value)] == [(1.0,2.0f0),(2.0,4.0f0)]
        @test outputs(dynamic_simulation)[(:leaf,ObjectId(:later),:value)] == [(2.0,2.0f0),(3.0,4.0f0)]
        check_store(dynamic_simulation, closed)
    end
end

@testset "fixed plans still reject topology edits before execution" begin
    for closed in (false,true)
        data = fixture(closed)
        simulation = run!(data.model;steps=0,outputs=:none)
        fixed = PSE._fixed_execution_plan(simulation.execution_plan)
        simulation = PSE._simulation_with_execution_plan(simulation, fixed)
        newborn = register_object!(data.model,Object(:later;scale=:Leaf,parent=:root,
            status=Status(value=7.0f0)))
        @test_throws "topology and bindings must stay fixed" step!(simulation)
        @test model_status(data.model, :root).ticks == 0
        @test model_status(data.model, 1).value === 0.0f0
        @test newborn.status.value === 7.0f0
        check_store(simulation, closed)
    end
end

@testset "open refresh retires an unvisited scheduled owner through the same store" begin
    for closed in (false,true)
        data = fixture(closed)
        simulation = run!(data.model;steps=0,outputs=:none)
        previous = simulation.execution_plan
        store = check_store(simulation, closed)
        location = PSE.cohort_location(store,:controller,ObjectId(:root))
        target = location.cohort.rows[location.row]
        reference = PSE.refvalue(model_status(data.model, 1), :value)
        # A changed authored CS needs a fresh Simulation at the outer boundary.
        # This host diagnostic exercises the canonical plan-refresh worker only.
        deleteat!(data.model.applications, 1)
        current = PSE.Advanced.refresh_bindings!(data.model;force=true)
        environment = PSE.refresh_environment_bindings!(data.model,current)
        refreshed = PSE._refresh_model_execution_plan(previous,current,environment,
            simulation.temporal_streams,simulation.output_retention,simulation.constants)
        @test refreshed.plan.cohorts === store
        @test fieldtype(typeof(refreshed.plan), :cohorts) === typeof(store)
        @test (@inferred plan_cohorts(refreshed.plan)) === store
        @test only(refreshed.plan.groups).application.id === :leaf
        @test isnothing(PSE.cohort_location(store,:controller,ObjectId(:root)))
        @test isnothing(location.cohort.rows[location.row])
        @test target.status_view.status.ticks == 0
        @test model_status(data.model, 1).value === 0.0f0
        @test PSE.refvalue(model_status(data.model, 1), :value) === reference
    end
end
# This ordinary owner deliberately aliases a canonical tuple without having its
# type. Dictionary equality must not add a type/parameter tag to the owner.
struct OwnerAlias{T}
    value::T
end
Base.isequal(left::OwnerAlias, right::OwnerAlias) = isequal(left.value, right.value)
Base.isequal(left::OwnerAlias, right::Tuple) = isequal(left.value, right)
Base.isequal(left::Tuple, right::OwnerAlias) = isequal(left, right.value)
Base.hash(owner::OwnerAlias, seed::UInt) = hash(owner.value, seed)

@testset "ordinary tuple keys preserve open owner equality and hashing" begin
    data = fixture(false)
    status = model_status(data.model, 1)
    payload = Payload(ObjectId(1), status, Ref(1))
    for (stored,query) in ((1,1.0),(1.0,1),
        ((:controller,ObjectId(:root),:first,:call),
            OwnerAlias((:controller,ObjectId(:root),:first,:call))),
        (OwnerAlias((:controller,ObjectId(:root),:first,:call)),
            (:controller,ObjectId(:root),:first,:call)))
        store = PSE.ExecutionCohortStore()
        rows = PSE.cohort_rows!(store, :leaf, [payload]; owner=stored)
        location = PSE.cohort_location(store, :leaf, ObjectId(1); owner=query)
        @test location.cohort === rows.cohort
        @test location.cohort.rows[location.row] === payload
        @test PSE._execution_cohort(store, query, :leaf, typeof(payload)) === rows.cohort
        @test length(store.cohorts) == 1
        stored_key = PSE._execution_location_key(store, stored, :leaf, ObjectId(1))
        query_key = PSE._execution_location_key(store, query, :leaf, ObjectId(1))
        @test isequal(query_key, stored_key)
        @test hash(query_key) == hash(stored_key)
        @test PSE.remove_cohort_target!(store, :leaf, ObjectId(1); owner=query)
        @test isnothing(rows.cohort.rows[location.row])
        @test isempty(store.locations)
        @test PSE.refvalue(payload.status, :value) === PSE.refvalue(status, :value)
    end
end

_key_value(dict, key) = get(dict, key, 0)

@testset "bounded keys admit independent caller and callee identities" begin
    I = Union{ObjectId{Int},ObjectId{Symbol}}
    O = Union{Nothing,Tuple{Symbol,I,Symbol,Symbol}}
    store = PSE.ExecutionCohortStore{I,O}()
    K = PSE.ExecutionCohortKey{O,I}
    @test isconcretetype(K)
    @test fieldtype(K, :owner) === O
    @test fieldtype(K, :item) === I
    # Both cross-products are valid: caller identity is not the callee's type.
    for (caller,callee) in ((ObjectId(:root),ObjectId(1)),(ObjectId(1),ObjectId(:leaf)))
        first = (:controller,caller,:first,:call)
        alias = (:controller,caller,:alias,:call)
        scheduled = PSE._execution_location_key(store, nothing, :leaf, callee)
        called = PSE._execution_location_key(store, first, :leaf, callee)
        aliased = PSE._execution_location_key(store, alias, :leaf, callee)
        @test typeof(scheduled) === typeof(called) === typeof(aliased) === K
        @test !isequal(scheduled, called) && !isequal(called, aliased)
        values = Dict{K,Int}(scheduled=>1,called=>2,aliased=>3)
        @test (@inferred _key_value(values, called)) == 2
        @test values[scheduled] == 1 && values[aliased] == 3
        @test length(values) == 3
    end
    # Representation differs; owner/id semantics and the ordinary query stay exact.
    owner = (:controller,ObjectId(:root),:first,:call)
    bounded = PSE._execution_location_key(store, owner, :leaf, ObjectId(1))
    open_store = PSE.ExecutionCohortStore()
    open = @inferred PSE._execution_location_key(open_store, owner, :leaf, ObjectId(1))
    @test open === (owner,:leaf,ObjectId(1))
    @test typeof(open) === Tuple{typeof(owner),Symbol,ObjectId{Int}}
    @test isequal(PSE._execution_key_owner(bounded),PSE._execution_key_owner(open))
    @test PSE._execution_key_application(bounded) === PSE._execution_key_application(open)
    @test PSE._execution_key_item(bounded) === PSE._execution_key_item(open)
    @test PSE._execution_store_owner_type(typeof(store)) === O
    @test PSE._execution_store_owner_type(typeof(open_store)) === Any
    rebuilt = typeof(store)()
    @test typeof(rebuilt) === typeof(store)
    @test isempty(rebuilt.cohorts) && isempty(rebuilt.locations)
end

end
