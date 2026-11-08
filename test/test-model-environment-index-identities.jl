module EnvironmentIndexIdentityChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

mutable struct Backend <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float32}
    binds::Int
    index_updates::Vector{Any}
    on_index::Any
end
mutable struct Handle
    cell::Symbol
    generation::Int
end
EA.base_step_seconds(::Backend) = 3600.0
EA.get_nsteps(::Backend) = 6
EA.environment_variables(::Backend) = Set((:T,))
function EA.bind_environment(backend::Backend, object::Object, context, config)
    backend.binds += 1
    return Handle(geometry(object).cell, backend.binds)
end
EA.sample(backend::Backend, handle::Handle, ::Symbol, time) =
    backend.values[handle.cell] + Float32(handle.generation)
function EA.update_index!(backend::Backend, entities, removed_object_ids)
    push!(backend.index_updates, (; phase=:index, backend_id=objectid(backend), entities, removed_object_ids))
    isnothing(backend.on_index) || backend.on_index()
    return nothing
end

struct IndexDiscoverySource{B}
    backend::B
    name::Symbol
end
function EA.environment_backend(source::IndexDiscoverySource)
    push!(source.backend.index_updates,
        (phase=:discover, name=source.name, backend_id=objectid(source.backend)))
    return source.backend
end

PSE.@process "environment_identity_index" verbose=false
struct Probe <: AbstractEnvironment_Identity_IndexModel end
PSE.inputs_(::Probe) = NamedTuple()
PSE.outputs_(::Probe) = (seen=0.0f0, visits=0)
PSE.environment_inputs_(::Probe) = (T=0.0f0,)
function PSE.run!(::Probe, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    return nothing
end

function close_registry(model::CompositeModel)
    previous = model.registry
    objects = PSE._closed_object_family_store(previous.objects)
    registry = PSE.ObjectRegistry(objects, previous.by_scale, previous.by_kind,
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

function fixture(closed::Bool)
    backend = Backend(Dict(:a => 10.0f0, :b => 20.0f0), 0, Any[], nothing)
    model = CompositeModel(
        Object(:root; scale=:Scene, status=Status(seen=0.0f0, visits=0)),
        Object(1; scale=:Leaf, parent=:root, geometry=(cell=:a,),
            status=Status(seen=0.0f0, visits=0)),
        Object(:leaf; scale=:Leaf, parent=:root, geometry=(cell=:b,),
            status=Status(seen=0.0f0, visits=0));
        applications=(ModelSpec(Probe(); name=:probe, on=Many(scale=:Leaf),
            environment=Environment(provider=:identity_probe)),), environment=backend)
    closed && (model = close_registry(model))
    simulation = run!(model; steps=1, outputs=:all)
    return (; model, simulation, backend)
end

function index_discovery_fixture(closed::Bool; extra_applications::Int=0)
    events = Any[]
    backend_a = Backend(Dict(:a => 10.0f0, :b => 20.0f0), 0, events, nothing)
    backend_b = Backend(copy(backend_a.values), 0, events, nothing)
    extra_objects = ntuple(extra_applications) do index
        Object(Symbol(:extra_, index); scale=:Leaf, parent=:root, geometry=(cell=:a,),
            status=Status(seen=0.0f0, visits=0))
    end
    extra_specs = ntuple(extra_applications) do index
        name = Symbol(:extra_, index)
        ModelSpec(Probe(); name, on=One(id=name),
            environment=Environment(backend=IndexDiscoverySource(backend_a, name)))
    end
    model = CompositeModel(
        Object(:root; scale=:Scene, status=Status(seen=0.0f0, visits=0)),
        Object(1; scale=:Leaf, parent=:root, geometry=(cell=:a,), status=Status(seen=0.0f0, visits=0)),
        Object(:leaf; scale=:Leaf, parent=:root, geometry=(cell=:b,), status=Status(seen=0.0f0, visits=0)),
        Object(:other; scale=:Leaf, parent=:root, geometry=(cell=:a,), status=Status(seen=0.0f0, visits=0)),
        Object(:global; scale=:Leaf, parent=:root, geometry=(cell=:b,), status=Status(seen=0.0f0, visits=0)),
        extra_objects...;
        applications=(
            ModelSpec(Probe(); name=:first, on=One(id=1),
                environment=Environment(backend=IndexDiscoverySource(backend_a, :first))),
            ModelSpec(Probe(); name=:shared, on=One(id=:leaf),
                environment=Environment(backend=IndexDiscoverySource(backend_a, :shared), provider=:shared)),
            ModelSpec(Probe(); name=:other, on=One(id=:other),
                environment=Environment(backend=IndexDiscoverySource(backend_b, :other))),
            ModelSpec(Probe(); name=:global, on=One(id=:global),
                environment=Environment(backend=EA.GlobalConstant((T=30.0f0,)))),
            extra_specs...,
        ),
        environment=backend_a)
    closed && (model = close_registry(model))
    return (; model, backend_a, backend_b, events)
end

index_trace(events) = [
    (event.phase, event.phase === :discover ? event.name : event.backend_id)
    for event in events
]

struct ApplicationIDCollector
    ids::Vector{Symbol}
end
(collector::ApplicationIDCollector)(application) = push!(collector.ids, application.id)

@testset "environment backend admission preserves discovery and index callback order" begin
    observed = index_discovery_fixture(false)
    control = PSE._prepare_simulation!(observed.model; steps=0, outputs=:none,
        constants=PSE.Constants())
    plan_types = unique(typeof.(control.environment_bindings.application_plans))
    # Two distinct plan families share the same backend type. One index callback
    # must not be repeated for each matching family witness.
    @test count(P -> fieldtype(P, :backend) === Backend, plan_types) == 2
    schema = PSE._environment_plan_schema_from_types(plan_types)
    for fixed in (false, true)
        data = index_discovery_fixture(fixed)
        model, events = data.model, data.events
        active_schema = fixed ? schema : nothing
        simulation = PSE._prepare_simulation!(model; steps=0, outputs=:none,
            constants=PSE.Constants(), environment_plan_schema=active_schema)
        compiled = simulation.compiled
        application_ids = Symbol[]
        collector = ApplicationIDCollector(application_ids)
        @test !(collector isa Function)
        @test isnothing(PSE._foreach_object_application(collector, compiled, ObjectId(1)))
        @test application_ids == [:first]
        discoveries = [(:discover, :first), (:discover, :shared), (:discover, :other)]
        indexed = [(:index, objectid(data.backend_a)), (:index, objectid(data.backend_b))]
        # Initial preparation has its existing discovery pass, then index calls,
        # then the separate existing application-plan normalization pass.
        @test index_trace(events) == vcat(discoveries, indexed, discoveries)
        @test simulation.environment_bindings.application_plan_schema === active_schema

        empty!(events)
        PSE._update_model_environment_indices!(model, compiled)
        @test index_trace(events) == vcat(discoveries, indexed)
        updates = filter(event -> event.phase === :index, events)
        @test updates[1].entities === updates[2].entities
        @test updates[1].removed_object_ids === updates[2].removed_object_ids
        @test data.backend_a !== data.backend_b
        @test data.backend_a.values == data.backend_b.values

        empty!(events)
        owner = model.environment_binding_cache
        changed = ObjectId[ObjectId(:leaf), ObjectId(1)]
        PSE._update_model_environment_indices_for_objects!(model, compiled, owner, changed)
        @test index_trace(events) == [(:index, objectid(data.backend_a))]
        @test [entity.id for entity in only(events).entities] == [:leaf, 1]

        empty!(events)
        mark_environment_binding_dirty!(model)
        owner = PSE.Advanced.refresh_environment_bindings!(model, compiled)
        @test owner.application_plan_schema === active_schema
        @test index_trace(events) == vcat(discoveries, indexed, discoveries)

        # A different current geometry owner must preserve its schema and the
        # newly discovered backend order, rather than the witness-table order.
        alternate = PSE.Advanced.compile_composite_model(model,
            (model.applications[3], model.applications[2], model.applications[1], model.applications[4]))
        empty!(events)
        PSE.Advanced.refresh_environment_bindings!(model, alternate; force=true)
        alternate_discoveries = [(:discover, :other), (:discover, :shared), (:discover, :first)]
        @test index_trace(events) == vcat(alternate_discoveries, reverse(indexed), alternate_discoveries)
        empty!(events)
        update_geometry!(model, 1, (cell=:b,))
        restored = PSE.Advanced.refresh_environment_bindings!(model, compiled)
        @test restored.application_plan_schema === active_schema
        @test index_trace(events) == vcat(discoveries, [(:index, objectid(data.backend_a))])
        @test only(last(events).entities).geometry == (cell=:b,)

        empty!(events)
        forbidden_iteration = (error("Global sources must not collect index entities") for _ in 1:1)
        @test isnothing(PSE._update_model_environment_indices!(model,
            Any[EA.GlobalConstant((T=1.0f0,))], forbidden_iteration))
        @test isempty(events)
    end
end

@testset "environment discovery retains actual values beyond 32 applications" begin
    observed = index_discovery_fixture(false)
    control = PSE._prepare_simulation!(observed.model; steps=0, outputs=:none,
        constants=PSE.Constants())
    schema = PSE._environment_plan_schema_from_types(
        unique(typeof.(control.environment_bindings.application_plans)))
    for fixed in (false, true)
        data = index_discovery_fixture(fixed; extra_applications=36)
        simulation = PSE._prepare_simulation!(data.model; steps=0, outputs=:none,
            constants=PSE.Constants(), environment_plan_schema=fixed ? schema : nothing)
        compiled = simulation.compiled
        names = [:first, :shared, :other, [Symbol(:extra_, index) for index in 1:36]...]
        discoveries = [(:discover, name) for name in names]
        indexed = [(:index, objectid(data.backend_a)), (:index, objectid(data.backend_b))]
        @test length(compiled.applications) == 40
        @test index_trace(data.events) == vcat(discoveries, indexed, discoveries)

        empty!(data.events)
        backends, slots = PSE._model_environment_backends(data.model, compiled.applications_by_id)
        @test backends isa PSE.CompiledMetadataTable
        @test length(backends) == 40
        @test slots == [1, 3, 4]
        @test backends[:first] === backends[:shared] === data.backend_a
        @test backends[:other] === data.backend_b
        @test all(index -> backends[Symbol(:extra_, index)] === data.backend_a, 1:36)
        @test index_trace(data.events) == discoveries

        empty!(data.events)
        PSE._update_model_environment_indices!(data.model, compiled)
        @test index_trace(data.events) == vcat(discoveries, indexed)
    end
end

@testset "partial index updates snapshot selected plans and retain previous application IDs" begin
    observed = index_discovery_fixture(false)
    control = PSE._prepare_simulation!(observed.model; steps=0, outputs=:none,
        constants=PSE.Constants())
    schema = PSE._environment_plan_schema_from_types(
        unique(typeof.(control.environment_bindings.application_plans)))
    for fixed in (false, true)
        data = index_discovery_fixture(fixed)
        model, events = data.model, data.events
        simulation = PSE._prepare_simulation!(model; steps=0, outputs=:none,
            constants=PSE.Constants(), environment_plan_schema=fixed ? schema : nothing)
        compiled, owner = simulation.compiled, simulation.environment_bindings

        # A previous target remains relevant even when the supplied compiled
        # application set no longer contains that application ID.
        subset = PSE.Advanced.compile_composite_model(model, (model.applications[1],))
        empty!(events)
        PSE._update_model_environment_indices_for_objects!(model, subset, owner, [ObjectId(:other)])
        @test index_trace(events) == [(:index, objectid(data.backend_b))]

        # Preserve the Set's actual order. The first callback replaces a later
        # dictionary entry; its already-selected immutable plan must still run.
        application_ids = Set{Symbol}()
        push!(application_ids, :first)
        push!(application_ids, :other)
        first_id, second_id = collect(application_ids)
        first_plan = owner.application_plans_by_id[first_id]
        second_plan = owner.application_plans_by_id[second_id]
        @test !ismutabletype(typeof(first_plan))
        @test first_plan.backend !== second_plan.backend
        first_plan.backend.on_index = () -> (owner.application_plans_by_id[second_id] = first_plan)
        empty!(events)
        PSE._update_model_environment_indices_for_objects!(model, compiled, owner,
            [ObjectId(1), ObjectId(:other)])
        @test index_trace(events) == [(:index, objectid(first_plan.backend)),
            (:index, objectid(second_plan.backend))]
        @test owner.application_plans_by_id[second_id] === first_plan

        first_plan.backend.on_index = nothing
        owner.application_plans_by_id[second_id] = second_plan
        remove_object!(model, :other)
        empty!(events)
        PSE._update_model_environment_indices_for_objects!(model, subset, owner, [ObjectId(:other)])
        @test index_trace(events) == [(:index, objectid(data.backend_b))]
        @test isempty(only(events).entities)
        @test only(events).removed_object_ids == [ObjectId(:other)]
    end
end

@testset "environment index metadata preserves mixed values, order and live aliases" begin
    for closed in (false, true)
        data = fixture(closed)
        model, backend = data.model, data.backend
        initial = first(backend.index_updates)
        # The backend boundary deliberately accepts heterogeneous NamedTuple rows,
        # including an empty batch; it does not infer a concrete row eltype.
        @test eltype(initial.entities) === NamedTuple
        @test [entity.id for entity in initial.entities] ==
            [object.id.value for object in model_objects(model)]
        @test isempty(initial.removed_object_ids)

        position_a = Float32[1, 2, 3]
        bounds_a = Dict(:radius => 0.5f0)
        geometry_a = (cell=:a, position=position_a, bounds=bounds_a)
        geometry_b = (cell=:b, position=(x=4.0, y=5.0, z=6.0), bounds=(width=2.0,))
        update_geometry!(model, 1, geometry_a; invalidate_environment=false)
        update_geometry!(model, :leaf, geometry_b; invalidate_environment=false)
        changed = ObjectId[ObjectId(:leaf), ObjectId(1), ObjectId(:leaf)]
        before = length(backend.index_updates)
        PSE._update_model_environment_indices!(model, [backend], changed)
        @test length(backend.index_updates) == before + 1
        batch = last(backend.index_updates)
        @test eltype(batch.entities) === NamedTuple
        @test [entity.id for entity in batch.entities] == [:leaf, 1, :leaf]
        @test isempty(batch.removed_object_ids)
        @test batch.entities[1].object === batch.entities[3].object === model_object(model, :leaf)
        integer = batch.entities[2]
        @test integer.object === model_object(model, 1)
        @test integer.geometry === geometry_a
        @test batch.entities[1].geometry === geometry_b
        @test typeof(integer.geometry) !== typeof(batch.entities[1].geometry)
        @test integer.position === position_a
        @test integer.bounds === bounds_a

        position_a[1] = 7f0
        bounds_a[:radius] = 2f0
        model_status(model, 1).seen = 70f0
        @test integer.geometry.position[1] === 7f0
        @test integer.bounds[:radius] === 2f0
        @test geometry(integer.object).position === position_a
        @test integer.object.status.seen === 70f0

        replacement = (cell=:a, position=Float32[8, 9, 10], bounds=Dict(:radius => 3f0))
        update_geometry!(model, 1, replacement; invalidate_environment=false)
        @test geometry(integer.object) === replacement
        @test integer.geometry === geometry_a
        PSE._update_model_environment_indices!(model, [backend], ObjectId[ObjectId(1)])
        @test only(last(backend.index_updates).entities).geometry === replacement

        remove_object!(model, :leaf)
        PSE._update_model_environment_indices!(model, [backend], changed)
        surviving = last(backend.index_updates)
        @test [entity.id for entity in surviving.entities] == [1]
        @test surviving.removed_object_ids == ObjectId[ObjectId(:leaf), ObjectId(:leaf)]
        remove_object!(model, 1)
        PSE._update_model_environment_indices!(model, [backend], changed)
        removed = last(backend.index_updates)
        @test isempty(removed.entities)
        @test eltype(removed.entities) === NamedTuple
        @test removed.removed_object_ids == changed
        @test typeof.(removed.removed_object_ids) ==
            [ObjectId{Symbol}, ObjectId{Int}, ObjectId{Symbol}]
    end
end

function check_indexes(model, owner)
    I = keytype(model.registry.objects)
    K = Tuple{Symbol,I}
    @test keytype(owner.by_target) === K
    @test keytype(owner.positions_by_target) === K
    @test keytype(owner.targets_by_object) === I
    @test valtype(owner.targets_by_object) === Vector{K}
    for (position, binding) in pairs(owner.bindings)
        target = PSE._environment_binding_target_key(binding, I)
        @test owner.by_target[target] === binding
        @test owner.positions_by_target[target] == position
        @test target in owner.targets_by_object[target[2]]
    end
end

@testset "environment indexes retain admitted identity pools" begin
    for closed in (false, true)
        data = fixture(closed)
        I = keytype(data.model.registry.objects)
        @test I === (closed ? Union{ObjectId{Int},ObjectId{Symbol}} : ObjectId)
        check_indexes(data.model, data.simulation.environment_bindings)
        bindings = data.simulation.environment_bindings.bindings
        empty_bindings = empty(bindings)
        @test isempty(PSE._index_environment_bindings(empty_bindings, I))
        @test keytype(PSE._index_environment_bindings(empty_bindings, I)) === Tuple{Symbol,I}
        @test keytype(PSE._index_environment_binding_positions(empty_bindings, I)) === Tuple{Symbol,I}
        @test keytype(PSE._index_environment_targets_by_object(empty_bindings, I)) === I
        @test_throws "duplicate" PSE._index_environment_bindings(
            [bindings; first(bindings)], I)
        @test_throws TypeError PSE._environment_binding_target_key(
            first(bindings), ObjectId{String})
    end
end

@testset "public full environment invalidation rebuilds fresh handles and sources" begin
    for closed in (false, true)
        data = fixture(closed)
        model, simulation, backend = data.model, data.simulation, data.backend
        previous = simulation.environment_bindings
        old_integer = previous.by_target[(:probe, ObjectId(1))]
        old_symbol = previous.by_target[(:probe, ObjectId(:leaf))]
        seen_ref = PSE.refvalue(model_status(model, 1), :seen)
        @test backend.binds == 2
        @test model_status(model, 1).seen === 11.0f0
        @test model_status(model, :leaf).seen === 22.0f0

        backend.values[:a] = 30.0f0
        backend.values[:b] = 40.0f0
        mark_environment_binding_dirty!(model)
        @test isnothing(model.environment_binding_cache)
        @test model.lifecycle_delta.full_environment
        @test simulation.environment_bindings === previous
        continue!(simulation; steps=1)
        current = simulation.environment_bindings
        @test current !== previous
        @test current === model.environment_binding_cache
        @test backend.binds == 4
        integer = current.by_target[(:probe, ObjectId(1))]
        symbol = current.by_target[(:probe, ObjectId(:leaf))]
        @test integer.handle !== old_integer.handle
        @test symbol.handle !== old_symbol.handle
        @test integer.handle.generation == 3
        @test symbol.handle.generation == 4
        @test model_status(model, 1).seen === 33.0f0
        @test model_status(model, :leaf).seen === 44.0f0
        @test model_status(model, 1).visits == model_status(model, :leaf).visits == 2
        @test PSE.refvalue(model_status(model, 1), :seen) === seen_ref
        check_indexes(model, current)

        # Sampling must still read fresh mutable source values with the same owner.
        backend.values[:a] = 31.0f0
        backend.values[:b] = 41.0f0
        continue!(simulation; steps=1)
        @test simulation.environment_bindings === current
        @test backend.binds == 4
        @test model_status(model, 1).seen === 34.0f0
        @test model_status(model, :leaf).seen === 45.0f0
        @test outputs(simulation)[(:probe, ObjectId(1), :seen)] ==
            [(1.0, 11.0f0), (2.0, 33.0f0), (3.0, 34.0f0)]
        @test outputs(simulation)[(:probe, ObjectId(:leaf), :seen)] ==
            [(1.0, 22.0f0), (2.0, 44.0f0), (3.0, 45.0f0)]
    end
end

@testset "partial growth and retirement update the same environment indexes" begin
    for closed in (false, true)
        data = fixture(closed)
        model, simulation = data.model, data.simulation
        previous = simulation.environment_bindings
        register_object!(model, Object(2; scale=:Leaf, parent=:root, geometry=(cell=:a,),
            status=Status(seen=0.0f0, visits=0)))
        continue!(simulation; steps=1)
        current = simulation.environment_bindings
        @test current.by_target === previous.by_target
        @test current.positions_by_target === previous.positions_by_target
        @test current.targets_by_object === previous.targets_by_object
        @test length(current.bindings) == 3
        @test model_status(model, 2).seen === 13.0f0
        @test model_status(model, 2).visits == 1
        newborn_ref = PSE.refvalue(model_status(model, 2), :seen)
        check_indexes(model, current)

        remove_object!(model, 1)
        continue!(simulation; steps=1)
        @test !haskey(simulation.environment_bindings.by_target, (:probe, ObjectId(1)))
        @test !haskey(simulation.environment_bindings.targets_by_object, ObjectId(1))
        @test length(simulation.environment_bindings.bindings) == 2
        @test PSE.refvalue(model_status(model, 2), :seen) === newborn_ref
        @test model_status(model, 2).visits == 2
        @test outputs(simulation)[(:probe, ObjectId(1), :seen)] ==
            [(1.0, 11.0f0), (2.0, 11.0f0)]
        check_indexes(model, simulation.environment_bindings)
    end
end

end

module SwitchingBackendRepro
using PlantSimEngine, Dates, Test
import ..EnvironmentIndexIdentityChecks: close_registry
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

mutable struct Backend{Tag} <: EA.AbstractEnvironmentBackend
    events::Vector{Any}
end
mutable struct Source{A,B}
    a::A
    b::B
    calls::Int
end
tag(::Backend{Tag}) where {Tag} = Tag
function EA.environment_backend(source::Source)
    source.calls += 1
    backend = isodd(source.calls) ? source.a : source.b
    push!(backend.events, (; phase=:discover, call=source.calls,
        tag=tag(backend), backend_id=objectid(backend)))
    return backend
end
EA.base_step_seconds(::Backend) = 3600.0
EA.get_nsteps(::Backend) = 1
EA.environment_variables(::Backend) = Set((:T,))
EA.bind_environment(::Backend, ::Object, context, config) = nothing
EA.sample(::Backend, ::Nothing, ::Symbol, time) = 5.0f0
function EA.update_index!(backend::Backend, entities, removed_object_ids)
    push!(backend.events, (; phase=:index, tag=tag(backend),
        backend_id=objectid(backend), entity_ids=[entity.id for entity in entities],
        removed_count=length(removed_object_ids)))
    return nothing
end

PSE.@process "switching_backend_probe" verbose=false
struct Probe <: AbstractSwitching_Backend_ProbeModel end
PSE.inputs_(::Probe) = NamedTuple()
PSE.outputs_(::Probe) = (seen=0.0f0,)
PSE.environment_inputs_(::Probe) = (T=0.0f0,)
function PSE.run!(::Probe, status, environment, constants, context)
    status.seen = environment.T
    return nothing
end

function fixture(closed::Bool)
    events = Any[]
    a = Backend{:A}(events)
    b = Backend{:B}(events)
    source = Source(a, b, 0)
    model = CompositeModel(
        Object(:root; scale=:Scene, status=Status(seen=0.0f0));
        applications=(ModelSpec(Probe(); name=:probe, on=One(id=:root),
            every=Dates.Hour(1), environment=Environment(backend=source)),),
        environment=b)
    closed && (model = close_registry(model))
    return (; model, source, a, b, events)
end

@testset "discovered backend is independent of the later normalized plan family" begin
    opened = fixture(false)
    open_simulation = PSE._prepare_simulation!(opened.model; steps=0, outputs=:none,
        constants=PSE.Constants(), environment_plan_schema=Val(:collect))
    @test opened.source.calls == 2
    @test [(event.phase, event.tag) for event in opened.events] ==
        [(:discover, :A), (:index, :A), (:discover, :B)]
    @test only(filter(event -> event.phase === :index, opened.events)).backend_id == objectid(opened.a)
    @test only(open_simulation.environment_bindings.application_plans).backend === opened.b
    plan_types = unique(typeof.(open_simulation.environment_bindings.application_plans))
    @test length(plan_types) == 1
    @test fieldtype(only(plan_types), :backend) === typeof(opened.b)
    schema = PSE._environment_plan_schema_from_types(plan_types)

    closed = fixture(true)
    simulation = PSE._prepare_simulation!(closed.model; steps=0, outputs=:none,
        constants=PSE.Constants(), environment_plan_schema=schema)
    @test closed.source.calls == 2
    @test [(event.phase, event.tag) for event in closed.events] ==
        [(:discover, :A), (:index, :A), (:discover, :B)]
    updates = filter(event -> event.phase === :index, closed.events)
    @test only(updates).backend_id == objectid(closed.a)
    @test only(updates).entity_ids == [:root]
    @test only(updates).removed_count == 0
    @test only(simulation.environment_bindings.application_plans).backend === closed.b
    @test simulation.environment_bindings.application_plan_schema === schema
end
end
