module EnvironmentIndexIdentityChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

mutable struct Backend <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,Float32}
    binds::Int
    index_updates::Vector{Any}
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
    push!(backend.index_updates, (; entities, removed_object_ids))
    return nothing
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
    backend = Backend(Dict(:a => 10.0f0, :b => 20.0f0), 0, Any[])
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
