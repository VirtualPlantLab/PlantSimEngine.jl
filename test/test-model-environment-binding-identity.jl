module EnvironmentBindingsIdentityChecks
using PlantSimEngine
using Serialization
using Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

mutable struct Backend{T} <: EA.AbstractEnvironmentBackend
    values::Dict{Symbol,T}
    samples::Int
end
mutable struct Trial{T}
    values::Dict{Symbol,T}
end
EA.base_step_seconds(::Backend) = 3600.0
EA.get_nsteps(::Backend) = 8
EA.environment_variables(::Backend) = Set((:T,))
mutable struct Handle
    cell::Symbol
end
EA.bind_environment(::Backend, object::Object, context, config) =
    Handle(isnothing(geometry(object)) ? :a : geometry(object).cell)
function EA.sample(backend::Backend, handle, ::Symbol, time)
    backend.samples += 1
    return backend.values[handle.cell]
end
function EA.sample(backend::Backend, handle, trial::Trial, ::Symbol, time)
    backend.samples += 1
    return trial.values[handle.cell]
end

PSE.@process "environment_shell_owner" verbose=false
PSE.@process "environment_shell_leaf" verbose=false
struct Owner{C} <: AbstractEnvironment_Shell_OwnerModel
    capture::C
end
PSE.inputs_(::Owner) = NamedTuple()
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end
struct Leaf{T} <: AbstractEnvironment_Shell_LeafModel
    initial::T
end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(model::Leaf) = (seen=model.initial, calls=0)
PSE.environment_inputs_(model::Leaf) = (T=model.initial,)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.seen = environment.T
    status.calls += 1
    return nothing
end

function fixture(::Type{T}; steps=1, environment_plan_schema=nothing) where {T}
    capture = Ref{Any}()
    backend = Backend(Dict(:a => T(10), :b => T(20)), 0)
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:scheduled_keep; scale=:Leaf, kind=:scheduled, parent=:scene, geometry=(cell=:a,)),
        Object(:scheduled_move; scale=:Leaf, kind=:scheduled, parent=:scene, geometry=(cell=:a,)),
        Object(:manual; scale=:Leaf, kind=:manual, parent=:scene, geometry=(cell=:a,));
        applications=(
            ModelSpec(Owner(capture); name=:owner, on=One(id=:scene),
                calls=(leaves=Many(kind=:manual, within=Subtree(), application=:manual_probe),)),
            ModelSpec(Leaf(zero(T)); name=:scheduled_probe, on=Many(kind=:scheduled),
                environment=Environment(provider=:shell_probe)),
            ModelSpec(Leaf(zero(T)); name=:manual_probe, on=Many(kind=:manual),
                environment=Environment(provider=:shell_probe)),
        ), environment=backend)
    simulation = if isnothing(environment_plan_schema)
        run!(model; steps, outputs=:all)
    else
        prepared = PSE._prepare_simulation!(model; steps, outputs=:all,
            constants=PSE.Constants(), environment_plan_schema)
        PSE._continue_scene!(prepared, steps)
    end
    batch = only(batch for batch in simulation.execution_plan.batches
                 if batch.application.id == :scheduled_probe)
    kept = only(target for target in batch.targets if target.object_id == ObjectId(:scheduled_keep))
    return (; model, simulation, capture, backend, batch, kept)
end

function fixture_plan_schema(::Type{T}) where {T}
    initial = fixture(T; steps=0)
    return PSE._environment_plan_schema_from_types(
        typeof(plan) for plan in initial.simulation.environment_bindings.application_plans)
end

function checkpoint_copy(simulation)
    buffer = IOBuffer()
    serialize(buffer, simulation)
    seekstart(buffer)
    return deserialize(buffer)
end

@testset "checkpointed environment owners preserve application identity" begin
    for schema in (nothing, fixture_plan_schema(Float32)), copy_simulation in (deepcopy, checkpoint_copy)
        data = fixture(Float32; environment_plan_schema=schema)
        simulation = data.simulation
        original_context = data.capture[]
        original_targets = only(original_context.calls)
        PSE._materialize_call_execution_batches!(original_targets)
        @test PSE._call_targets_preparation_is_current(original_targets,
            simulation.compiled, simulation.environment_bindings,
            simulation.temporal_streams, simulation.output_retention, simulation.constants)

        restored = copy_simulation(simulation)
        environment_bindings = restored.environment_bindings
        owner = only(group for group in restored.execution_plan.groups
            if group.application.id === :owner)
        context = only(only(owner.batches).targets).context
        targets = only(context.calls)
        @test typeof(environment_bindings.application_plan_schema) ===
            typeof(simulation.environment_bindings.application_plan_schema)
        @test context.environment_bindings.application_plan_schema ===
            environment_bindings.application_plan_schema
        cached_batches = PSE._cached_call_execution_batches(targets)
        @test !isnothing(cached_batches)

        # Inspect the restored graph before an accessor can refresh its owners.
        @test PSE._environment_bindings_match_compiled(environment_bindings, restored.compiled)
        @test !PSE._environment_bindings_match_compiled(environment_bindings, simulation.compiled)
        @test environment_bindings.compiled_applications === restored.compiled.applications
        @test environment_bindings.compiled_applications !== simulation.compiled.applications
        @test targets.preparation.compiled_applications === restored.compiled.applications
        @test PSE._call_targets_preparation_is_current(targets,
            restored.compiled, environment_bindings, restored.temporal_streams,
            restored.output_retention, restored.constants)

        # Equal application records in another vector are a different generation.
        applications = restored.compiled.applications
        restored.compiled.applications = copy(applications)
        @test !PSE._environment_bindings_match_compiled(environment_bindings, restored.compiled)
        restored.compiled.applications = applications
        @test PSE._environment_bindings_match_compiled(environment_bindings, restored.compiled)

        backend = first(environment_bindings.bindings).backend
        samples = backend.samples
        @test PSE.Advanced.refresh_environment_bindings!(restored.model, restored.compiled) ===
              environment_bindings
        @test PSE._cached_call_execution_batches(targets) === cached_batches
        @test backend.samples == samples
        @test PSE._call_targets_preparation_is_current(targets,
            restored.compiled, environment_bindings, restored.temporal_streams,
            restored.output_retention, restored.constants)

        # Reuse the restored Many preparation, then advance the ordinary scheduler.
        backend.values[:a] = data.backend.values[:a] = 13.0f0
        backend.values[:b] = data.backend.values[:b] = 23.0f0
        run_call!(context, :leaves; publish=false)
        run_call!(original_context, :leaves; publish=false)
        @test model_status(restored.model, :manual).seen === 13.0f0
        @test model_status(restored.model, :manual).calls == 1
        continue!(restored; steps=1)
        continue!(simulation; steps=1)
        @test final_state(restored, Many()) == final_state(simulation, Many())
        @test isequal(collect_outputs(restored), collect_outputs(simulation))
        @test backend.samples == data.backend.samples
    end
end

@testset "clean and dirty environment shells preserve live backend and trial sampling" begin
    for T in (Float32, Float64)
        data = fixture(T)
        original_environment = data.simulation.environment_bindings
        original_context = data.kept.context
        targets = call_targets(data.capture[], :leaves)
        first_target = only(targets)
        original_batches = PSE._cached_call_execution_batches(targets)
        trial = Trial(Dict(:a => T(30), :b => T(40)))
        run_call!(first_target; environment=trial, publish=false)
        original_transient = first_target.context_cache.transient
        trial.values[:a] = T(31)
        run_call!(first_target; environment=trial, publish=false)
        @test first_target.status.seen === T(31)
        @test first_target.context_cache.transient === original_transient
        @test first_target.environment_binding.backend === data.backend

        # A clean public refresh keeps the shell, cached membership, and view.
        @test PSE.Advanced.refresh_environment_bindings!(data.model, data.simulation.compiled) ===
              original_environment
        @test only(targets) === first_target
        @test PSE._cached_call_execution_batches(targets) === original_batches

        data.backend.values[:a] = T(11)
        move_object!(data.model, :scheduled_move, (cell=:b,))
        move_object!(data.model, :manual, (cell=:b,))
        continue!(data.simulation)
        current_environment = data.simulation.environment_bindings
        @test current_environment !== original_environment
        @test current_environment.environment_revision > original_environment.environment_revision
        @test current_environment.bindings === original_environment.bindings
        @test current_environment.by_target === original_environment.by_target
        @test all(binding -> binding.backend === data.backend,
                  current_environment.bindings)
        @test model_status(data.model, :scheduled_keep).seen === T(11)
        @test model_status(data.model, :scheduled_move).seen === T(20)
        kept = only(target for target in data.batch.targets
                    if target.object_id == ObjectId(:scheduled_keep))
        @test kept === data.kept
        @test kept.context === original_context
        @test kept.context.environment_bindings === current_environment
        @test data.batch.context_state.environment_bindings === current_environment

        refreshed_targets = call_targets(data.capture[], :leaves)
        refreshed_target = only(refreshed_targets)
        @test refreshed_targets.environment_bindings === current_environment
        @test refreshed_target.environment_binding.backend === data.backend
        @test refreshed_target.environment_binding.handle.cell === :b
        @test PSE._cached_call_execution_batches(refreshed_targets) !== original_batches
        samples = data.backend.samples
        run_call!(refreshed_target; environment=trial, publish=false)
        @test refreshed_target.status.seen === T(40)
        transient = refreshed_target.context_cache.transient
        trial.values[:b] = T(41)
        run_call!(refreshed_target; environment=trial, publish=false)
        @test refreshed_target.status.seen === T(41)
        @test refreshed_target.context_cache.transient === transient
        @test data.backend.samples == samples + 2
        @test data.backend.values == Dict(:a => T(11), :b => T(20))
        @test PSE.Advanced.refresh_environment_bindings!(data.model, data.simulation.compiled) ===
              current_environment
        @test only(refreshed_targets) === refreshed_target
        samples = data.backend.samples
        PSE._synchronize_model_execution_batch_contexts!(data.batch,
            data.simulation.compiled, current_environment,
            data.simulation.temporal_streams, data.simulation.output_retention,
            current_step(data.simulation), data.simulation.constants)
        @test data.backend.samples == samples
    end
end

@testset "partial and full environment refresh preserve scientific owners and sampling" begin
    data = fixture(Float32)
    simulation = data.simulation
    original_compiled = simulation.compiled
    kept_status = model_status(data.model, :scheduled_keep)
    moved_status = model_status(data.model, :scheduled_move)
    kept_binding = simulation.environment_bindings.by_target[(:scheduled_probe, ObjectId(:scheduled_keep))]
    moved_binding = simulation.environment_bindings.by_target[(:scheduled_probe, ObjectId(:scheduled_move))]

    move_object!(data.model, :scheduled_move, (cell=:b,))
    samples = data.backend.samples
    PSE._refresh_simulation_runtime!(simulation)
    @test data.backend.samples == samples
    @test simulation.compiled === original_compiled
    @test model_status(data.model, :scheduled_keep) === kept_status
    @test model_status(data.model, :scheduled_move) === moved_status
    @test simulation.environment_bindings.by_target[(:scheduled_probe, ObjectId(:scheduled_keep))] === kept_binding
    refreshed_move = simulation.environment_bindings.by_target[(:scheduled_probe, ObjectId(:scheduled_move))]
    @test refreshed_move !== moved_binding
    @test refreshed_move.handle.cell === :b
    @test refreshed_move.backend === data.backend
    scheduled = only(batch for batch in simulation.execution_plan.batches
        if batch.application.id === :scheduled_probe)
    @test only(target for target in scheduled.targets if target.object_id === ObjectId(:scheduled_keep)) === data.kept
    continue!(simulation)
    @test kept_status.seen === 10.0f0
    @test moved_status.seen === 20.0f0

    # A full refresh keeps the whole-application sentinel rather than treating
    # an empty set as a proof that no execution payload must be refreshed.
    data.backend.values[:a] = 12.0f0
    data.backend.values[:b] = 22.0f0
    mark_environment_binding_dirty!(data.model)
    samples = data.backend.samples
    PSE._refresh_simulation_runtime!(simulation)
    @test data.backend.samples == samples
    @test simulation.compiled === original_compiled
    @test all(binding -> binding.backend === data.backend,
        simulation.environment_bindings.bindings)
    continue!(simulation)
    @test kept_status.seen === 12.0f0
    @test moved_status.seen === 22.0f0
    @test kept_status.calls == moved_status.calls == 3
    @test outputs(simulation)[(:scheduled_probe, ObjectId(:scheduled_move), :seen)] ==
        [(1.0, 10.0f0), (2.0, 20.0f0), (3.0, 22.0f0)]
    target = only(call_targets(data.capture[], :leaves))
    run_call!(target; publish=false)
    @test target.status.seen === 12.0f0
    @test target.environment_binding.backend === data.backend
end

@testset "the typed boundary selects the current model cache after public refresh" begin
    for schema in (nothing, fixture_plan_schema(Float32))
        data = fixture(Float32; environment_plan_schema=schema)
        simulation = data.simulation
        prepared = simulation.environment_bindings
        @test PSE._current_environment_binding_owner(data.model, prepared) === prepared

        move_object!(data.model, :scheduled_move, (cell=:b,))
        partial = PSE.Advanced.refresh_environment_bindings!(data.model, simulation.compiled)
        current = PSE._current_environment_binding_owner(data.model, prepared)
        is_current_partial = current === partial && current !== prepared
        @test is_current_partial
        @test current.by_target[(:scheduled_probe, ObjectId(:scheduled_move))].handle.cell === :b
        @test all(binding -> binding.backend === data.backend, current.bindings)
        samples = data.backend.samples
        clean = PSE._refresh_environment_bindings!(data.model, simulation.compiled, current)
        same_clean = clean === partial
        @test same_clean
        @test data.backend.samples == samples

        mark_environment_binding_dirty!(data.model)
        @test isnothing(schema) ?
            isnothing(PSE._current_environment_binding_owner(data.model, prepared)) :
            PSE._current_environment_binding_owner(data.model, prepared) === partial
        full = PSE.Advanced.refresh_environment_bindings!(data.model, simulation.compiled)
        current = PSE._current_environment_binding_owner(data.model, prepared)
        is_current_full = current === full && current !== partial
        @test is_current_full
        same_schema = typeof(full) === typeof(prepared)
        @test same_schema
        @test current.by_target[(:scheduled_probe, ObjectId(:scheduled_move))].handle.cell === :b

        # Advanced compilation may replace model metadata before this Simulation
        # resumes. The current cache remains authoritative even for another set of
        # applications; the common refresh algorithm reconciles it when requested.
        alternate_compiled = PSE.Advanced.compile_composite_model(data.model, (
            ModelSpec(Leaf(0.0f0); name=:scheduled_probe, on=Many(kind=:scheduled),
                environment=Environment(provider=:shell_probe)),
        ))
        alternate = PSE.Advanced.refresh_environment_bindings!(data.model, alternate_compiled)
        current = PSE._current_environment_binding_owner(data.model, prepared)
        is_current_alternate = current === alternate && current !== full
        @test is_current_alternate
        @test length(current.bindings) == 2
        @test current.compiled_applications === alternate_compiled.applications
        @test current.application_plan_schema === schema
        samples = data.backend.samples
        restored = PSE._refresh_environment_bindings!(data.model, simulation.compiled, current)
        is_restored = restored === PSE.compiled_environment_bindings(data.model)
        @test is_restored
        @test restored.compiled_applications === simulation.compiled.applications
        @test length(restored.bindings) == 4
        @test all(binding -> binding.backend === data.backend, restored.bindings)
        @test restored.by_target[(:scheduled_probe, ObjectId(:scheduled_move))].handle.cell === :b
        @test data.backend.samples == samples
    end
end

@testset "a public refresh cannot hide stale runtime geometry bindings" begin
    for full in (false, true), pending_after_public in (false, true)
        data = fixture(Float32)
        simulation = data.simulation
        move_object!(data.model, :scheduled_move, (cell=:b,))
        full && mark_environment_binding_dirty!(data.model)
        public = PSE.Advanced.refresh_environment_bindings!(data.model, simulation.compiled)
        @test !PSE.environment_bindings_dirty(data.model)
        @test isempty(PSE.lifecycle_delta(data.model).environment_dirty_ids)
        pending_after_public && move_object!(data.model, :scheduled_keep, (cell=:b,))
        samples = data.backend.samples
        PSE._refresh_simulation_runtime!(simulation)
        @test data.backend.samples == samples
        uses_current = simulation.environment_bindings === PSE.compiled_environment_bindings(data.model)
        @test uses_current
        if !pending_after_public
            uses_public = simulation.environment_bindings === public
            @test uses_public
        end
        scheduled = only(batch for batch in simulation.execution_plan.batches
            if batch.application.id === :scheduled_probe)
        moved = only(target for target in scheduled.targets
            if target.object_id === ObjectId(:scheduled_move))
        kept = only(target for target in scheduled.targets
            if target.object_id === ObjectId(:scheduled_keep))
        @test moved.environment_binding.handle.cell === :b
        @test kept.environment_binding.handle.cell === (pending_after_public ? :b : :a)
        @test moved.environment_binding.backend === data.backend
        @test model_status(data.model, :scheduled_move).calls == 1
        continue!(simulation)
        @test model_status(data.model, :scheduled_move).seen === 20.0f0
        @test model_status(data.model, :scheduled_keep).seen === (pending_after_public ? 20.0f0 : 10.0f0)
        @test model_status(data.model, :scheduled_move).calls == 2
        @test model_status(data.model, :scheduled_keep).calls == 2
        @test outputs(simulation)[(:scheduled_probe, ObjectId(:scheduled_move), :seen)] ==
            [(1.0, 10.0f0), (2.0, 20.0f0)]
    end
end

@testset "a later addition also observes previously refreshed geometry" begin
    data = fixture(Float32)
    simulation = data.simulation
    move_object!(data.model, :scheduled_move, (cell=:b,))
    PSE.Advanced.refresh_environment_bindings!(data.model, simulation.compiled)
    newborn = register_object!(data.model, Object(:scheduled_new;
        scale=:Leaf, kind=:scheduled, parent=:scene, geometry=(cell=:a,)))
    samples = data.backend.samples
    PSE._refresh_simulation_runtime!(simulation)
    @test data.backend.samples == samples
    moved_bindings = [target.environment_binding for batch in simulation.execution_plan.batches
        for target in batch.targets if target.object_id === ObjectId(:scheduled_move)]
    @test only(moved_bindings).handle.cell === :b
    @test only(moved_bindings).backend === data.backend
    continue!(simulation)
    @test model_status(data.model, :scheduled_move).seen === 20.0f0
    @test model_status(data.model, :scheduled_move).calls == 2
    @test newborn.status.seen === 10.0f0
    @test newborn.status.calls == 1
    @test outputs(simulation)[(:scheduled_probe, ObjectId(:scheduled_move), :seen)] ==
        [(1.0, 10.0f0), (2.0, 20.0f0)]
end

@testset "a pending move reconciles an authoritative Advanced subset cache" begin
    for schema in (nothing, fixture_plan_schema(Float32))
        data = fixture(Float32; environment_plan_schema=schema)
        simulation = data.simulation
        alternate_compiled = PSE.Advanced.compile_composite_model(data.model, (
            ModelSpec(Leaf(0.0f0); name=:manual_probe, on=Many(kind=:manual),
                environment=Environment(provider=:shell_probe)),
        ))
        alternate = PSE.Advanced.refresh_environment_bindings!(data.model, alternate_compiled)
        @test alternate.application_plan_schema === schema
        @test length(alternate.bindings) == 1
        @test !haskey(alternate.application_plans_by_id, :scheduled_probe)
        move_object!(data.model, :scheduled_move, (cell=:b,))
        samples = data.backend.samples
        PSE._refresh_simulation_runtime!(simulation)
        @test data.backend.samples == samples
        uses_current = simulation.environment_bindings === PSE.compiled_environment_bindings(data.model)
        @test uses_current
        @test simulation.environment_bindings.compiled_applications === simulation.compiled.applications
        @test length(simulation.environment_bindings.bindings) == 4
        handles_current = all(batch -> all(target ->
            target.environment_binding.handle === simulation.environment_bindings.by_target[
                (batch.application.id, target.object_id)].handle, batch.targets),
            simulation.execution_plan.batches)
        @test handles_current
        scheduled = only(batch for batch in simulation.execution_plan.batches
            if batch.application.id === :scheduled_probe)
        target = only(target for target in scheduled.targets
            if target.object_id === ObjectId(:scheduled_move))
        @test target.environment_binding.handle.cell === :b
        @test target.environment_binding.backend === data.backend
        @test model_status(data.model, :scheduled_move).calls == 1
        continue!(simulation)
        @test model_status(data.model, :scheduled_move).seen === 20.0f0
        @test model_status(data.model, :scheduled_move).calls == 2
        @test model_status(data.model, :manual).calls == 0
        @test outputs(simulation)[(:scheduled_probe, ObjectId(:scheduled_move), :seen)] ==
            [(1.0, 10.0f0), (2.0, 20.0f0)]
        selected = only(call_targets(data.capture[], :leaves))
        run_call!(selected; publish=false)
        @test selected.status.seen === 10.0f0
        @test selected.environment_binding.backend === data.backend
        manual_handle_current = selected.environment_binding.handle ===
            simulation.environment_bindings.by_target[(:manual_probe, ObjectId(:manual))].handle
        @test manual_handle_current
    end
end
@testset "retained manual targets use the current public environment owner" begin
    for force in (false, true)
        data = fixture(Float32)
        targets = call_targets(data.capture[], :leaves)
        PSE._materialize_call_execution_batches!(targets)
        previous = targets.environment_bindings
        status = model_status(data.model, :manual)
        reference = PSE.refvalue(status, :seen)
        move_object!(data.model, :manual, (cell=:b,))
        current = PSE.Advanced.refresh_environment_bindings!(data.model,
            data.simulation.compiled; force)
        @test current !== previous
        @test getfield(targets, :environment_bindings) === previous
        @test !PSE.bindings_dirty(data.model) && !PSE.environment_bindings_dirty(data.model)
        samples = data.backend.samples
        PSE._synchronize_tracked_call_targets!(targets)
        @test targets.environment_bindings === current
        @test data.backend.samples == samples
        target = only(targets)
        @test target.environment_binding.backend === data.backend
        @test target.environment_binding.handle.cell === :b
        run_call!(target; publish=false)
        @test status.seen === 20f0 && status.calls == 1
        @test data.backend.samples == samples + 1
        @test PSE.refvalue(status, :seen) === reference
    end
end

@testset "cold environment indexes preserve distinct binding families" begin
    left = fixture(Float32).simulation.environment_bindings
    right = fixture(Float64).simulation.environment_bindings
    first_binding = only(binding for binding in left.bindings
                         if binding.object_id == ObjectId(:scheduled_keep))
    later_binding = only(binding for binding in right.bindings
                         if binding.object_id == ObjectId(:manual))
    @test typeof(first_binding) !== typeof(later_binding)
    bindings = PSE.CompiledEnvironmentBinding[first_binding, later_binding]
    I = typeof(ObjectId(:scheduled_keep))
    index = PSE._index_environment_bindings(bindings, I)
    @test length(index) == 2
    for binding in bindings
        @test index[PSE._environment_binding_target_key(binding, I)] === binding
    end
    empty_index = PSE._index_environment_bindings(PSE.CompiledEnvironmentBinding[], I)
    @test isempty(empty_index)
    @test typeof(empty_index) === typeof(index)
    @test_throws ErrorException PSE._index_environment_bindings(
        PSE.CompiledEnvironmentBinding[first_binding, first_binding], I)
end

mutable struct PortlessValidationBackend <: EA.AbstractEnvironmentBackend
    inventory_reads::Int
end
EA.base_step_seconds(::PortlessValidationBackend) = 3600.0
EA.get_nsteps(::PortlessValidationBackend) = 8
function EA.environment_variables(backend::PortlessValidationBackend)
    backend.inventory_reads += 1
    return Set((:unused,))
end

@testset "portless applications do not query backend inventories" begin
    backend = PortlessValidationBackend(0)
    model = CompositeModel(Object(:scene; scale=:Scene);
        applications=(ModelSpec(Owner(Ref{Any}()); name=:owner, on=One(id=:scene)),),
        environment=backend)
    simulation = run!(model; steps=0, outputs=:none)
    @test backend.inventory_reads == 0
    bindings = simulation.environment_bindings.bindings
    tables = (simulation.compiled.applications_by_id,
        Dict(application.id => application for application in simulation.compiled.applications))
    for table in tables
        @test PSE._validate_model_environment_inputs!(bindings, table, keytype(model.registry.objects)) === nothing
        @test backend.inventory_reads == 0
    end
end

@testset "environment validation preserves all missing local and spatial sources" begin
    backend = Backend(Dict(:a=>10f0, :b=>20f0), 0)
    for local_backend in (false, true)
        config = local_backend ?
            Environment(backend=(other=3f0,), sources=(T=:missing,)) :
            Environment(provider=:shell_probe, sources=(T=:missing,))
        model = CompositeModel(
            Object(:one; scale=:Leaf, geometry=(cell=:a,)),
            Object(:two; scale=:Leaf, geometry=(cell=:b,));
            applications=(ModelSpec(Leaf(0f0); name=:leaf, on=Many(scale=:Leaf),
                environment=config),), environment=backend)
        compiled = PSE.Advanced.refresh_bindings!(model)
        _, plans = PSE._compile_environment_application_plans(model,
            compiled.applications, compiled.applications_by_id)
        bindings = PSE._compile_environment_bindings_for_applications(
            model, compiled.applications, plans)
        tables = (compiled.applications_by_id,
            Dict(application.id => application for application in compiled.applications))
        messages = String[]
        expected = if local_backend
            "Composite model environment is missing required source inputs: leaf/one " *
            "(environment_shell_leaf) needs `T` from source `missing`; " *
            "available=(:other,); leaf/two (environment_shell_leaf) needs `T` from source" *
            " `missing`; available=(:other,)"
        else
            "Composite model environment is missing required source inputs: leaf/one " *
            "(environment_shell_leaf) needs `T` from source `missing`; available=(:T,); " *
            "leaf/two (environment_shell_leaf) needs `T` from source `missing`; " *
            "available=(:T,)"
        end
        for table in tables
            failure = try
                PSE._validate_model_environment_inputs!(bindings, table, keytype(model.registry.objects))
                nothing
            catch exception
                exception
            end
            @test failure isa ErrorException
            message = sprint(showerror, failure)
            @test message == expected
            @test occursin("leaf/one", message) && occursin("leaf/two", message)
            @test occursin("needs `T` from source `missing`", message)
            @test occursin("available=", message)
            @test occursin(local_backend ? "other" : "T", message)
            push!(messages, message)
        end
        @test messages[1] == messages[2]
        @test backend.samples == 0
    end
end

# These counters distinguish preparation policy changes from provider work.
mutable struct PlanPolicyBackend{T} <: EA.AbstractEnvironmentBackend
    values::NamedTuple{(:T, :U),Tuple{T,T}}
    binds::Int
    samples::Int
end
mutable struct PlanPolicySource{B}
    backend::B
    normalizations::Int
end
function EA.environment_backend(source::PlanPolicySource)
    source.normalizations += 1
    return source.backend
end
EA.base_step_seconds(::PlanPolicyBackend) = 3600.0
EA.get_nsteps(::PlanPolicyBackend) = 8
EA.environment_variables(::PlanPolicyBackend) = Set((:T, :U))
function EA.bind_environment(backend::PlanPolicyBackend, object::Object, context, config)
    backend.binds += 1
    return Handle(isnothing(geometry(object)) ? :a : geometry(object).cell)
end
function EA.sample(backend::PlanPolicyBackend, handle, variable::Symbol, time)
    backend.samples += 1
    return getproperty(backend.values, variable)
end
struct PlanPolicyProbe{V,T} <: AbstractEnvironment_Shell_LeafModel
    initial::T
end
PSE.inputs_(::PlanPolicyProbe) = NamedTuple()
PSE.outputs_(model::PlanPolicyProbe) = (seen=model.initial, calls=0)
PSE.environment_inputs_(model::PlanPolicyProbe{V}) where {V} =
    NamedTuple{(V,)}((model.initial,))
function PSE.run!(::PlanPolicyProbe{V}, status, environment, constants, context) where {V}
    status.seen = getproperty(environment, V)
    status.calls += 1
    return nothing
end

policy_spec(variable; active=true) = ModelSpec(PlanPolicyProbe{variable,Float32}(0f0);
    name=:policy_probe, on=Many(kind=active ? :active : :absent))
function policy_model(variable=:T; active=true)
    backend = PlanPolicyBackend((T=10f0, U=20f0), 0, 0)
    source = PlanPolicySource(backend, 0)
    model = CompositeModel(Object(:leaf; scale=:Leaf, kind=:active, geometry=(cell=:a,)),
        Object(1; scale=:Leaf, kind=:active, geometry=(cell=:a,));
        applications=(policy_spec(variable; active),), environment=source)
    return (; model, source, backend)
end
function prepare_policy(data; schema=nothing)
    return PSE._prepare_simulation!(data.model; steps=0, outputs=:all,
        constants=PSE.Constants(), environment_plan_schema=schema)
end
policy_counts(data) = (data.source.normalizations, data.backend.binds, data.backend.samples)
policy_types(simulation) = [typeof(plan) for plan in simulation.environment_bindings.application_plans]

@testset "fixed environment policies admit plans before any initial bind" begin
    initial = policy_model(:T)
    first_simulation = prepare_policy(initial; schema=Val(:collect))
    first_types = policy_types(first_simulation)
    initial_schema = PSE._environment_plan_schema_from_types(first_types)
    @test first_simulation.environment_bindings.application_plan_schema === nothing
    for active in (false, true)
        missing = policy_model(:U; active)
        @test_throws "policy_probe` is outside its prepared family schema" prepare_policy(missing; schema=initial_schema)
        @test missing.backend.binds == 0
        @test missing.backend.samples == 0
    end
    ordinary = policy_model(:T)
    control = prepare_policy(ordinary)
    fixed = policy_model(:T)
    compiled = prepare_policy(fixed; schema=initial_schema)
    @test policy_counts(fixed) == policy_counts(ordinary)
    @test fixed.backend.binds == 2
    @test compiled.environment_bindings.application_plan_schema === initial_schema
    @test map(binding -> binding.object_id, compiled.environment_bindings.bindings) ==
        map(binding -> binding.object_id, control.environment_bindings.bindings)
    @test Set(binding.object_id for binding in compiled.environment_bindings.bindings) ==
        Set((ObjectId(:leaf), ObjectId(1)))
    @test all(binding -> binding.backend === fixed.backend, compiled.environment_bindings.bindings)
    step!(compiled)
    step!(control)
    @test final_state(compiled, Many()) == final_state(control, Many())
    @test isequal(collect_outputs(compiled), collect_outputs(control))
    @test policy_counts(fixed) == policy_counts(ordinary)
end

@testset "zero-target plans and observed future families obey the fixed union" begin
    a = policy_model(:T; active=false)
    simulation = prepare_policy(a; schema=Val(:collect))
    first_types = policy_types(simulation)
    first_schema = PSE._environment_plan_schema_from_types(first_types)
    alternate = PSE.Advanced.compile_composite_model(a.model, (policy_spec(:U; active=false),))
    future = PSE.Advanced.refresh_environment_bindings!(a.model, alternate; force=true)
    @test isempty(future.bindings)
    @test future.application_plan_schema === nothing
    future_types = [typeof(plan) for plan in future.application_plans]
    @test first_types != future_types
    b = policy_model(:T; active=false)
    fixed = prepare_policy(b; schema=first_schema)
    alternate_b = PSE.Advanced.compile_composite_model(b.model, (policy_spec(:U; active=false),))
    @test_throws "policy_probe` is outside its prepared family schema" PSE.Advanced.refresh_environment_bindings!(b.model, alternate_b)
    @test b.backend.binds == 0
    union_schema = PSE._environment_plan_schema_from_types(vcat(first_types, future_types))
    c = policy_model(:T; active=false)
    admitted = prepare_policy(c; schema=union_schema)
    E = typeof(admitted.environment_bindings)
    alternate_c = PSE.Advanced.compile_composite_model(c.model, (policy_spec(:U; active=false),))
    current = PSE.Advanced.refresh_environment_bindings!(c.model, alternate_c; force=true)
    @test typeof(current) === E
    @test current.application_plan_schema === union_schema
    @test only(typeof.(current.application_plans)) in future_types
    @test only(policy_types(admitted)) in first_types
    @test c.backend.binds == c.backend.samples == 0
end

@testset "collection can reopen clean and dirty fixed environment owners" begin
    observed = prepare_policy(policy_model())
    schema = PSE._environment_plan_schema_from_types(policy_types(observed))
    for dirty in (false, true)
        data = policy_model()
        simulation = prepare_policy(data; schema)
        owner = simulation.environment_bindings
        if dirty
            mark_environment_binding_dirty!(data.model)
            @test data.model.environment_binding_cache === owner
            @test PSE.lifecycle_delta(data.model).full_environment
        end
        before = policy_counts(data)
        current = PSE._refresh_environment_bindings!(data.model, simulation.compiled, owner;
            plan_schema=nothing)
        delta = policy_counts(data) .- before
        @test current.application_plan_schema === nothing
        @test current.application_plans === owner.application_plans || dirty
        @test current.bindings === owner.bindings || dirty
        @test data.backend.binds == before[2] + (dirty ? 2 : 0)
        if !dirty
            @test delta == (0, 0, 0)
            @test current.by_target === owner.by_target
            @test current.sample_cache === owner.sample_cache
        end
        # A new host collection ignores an older fixed policy, including a stale
        # alternate whose newly normalized family was not in that old schema.
        data = policy_model()
        previous = prepare_policy(data; schema)
        dirty && mark_environment_binding_dirty!(data.model)
        collected = prepare_policy(data; schema=Val(:collect))
        @test collected.environment_bindings.application_plan_schema === nothing
        alternate = PSE.Advanced.compile_composite_model(data.model, (policy_spec(:U),))
        refreshed = PSE.Advanced.refresh_environment_bindings!(data.model, alternate)
        @test refreshed.application_plan_schema === nothing
        @test only(refreshed.application_plans).compiled_sampling_rules !=
            only(previous.environment_bindings.application_plans).compiled_sampling_rules
    end
end

@testset "dirty fixed policies survive checkpoints and rebuild handles" begin
    schema = fixture_plan_schema(Float32)
    for copy_simulation in (deepcopy, checkpoint_copy)
        data = fixture(Float32; environment_plan_schema=schema)
        move_object!(data.model, :scheduled_move, (cell=:b,))
        mark_environment_binding_dirty!(data.model)
        restored = copy_simulation(data.simulation)
        retained = restored.environment_bindings
        @test restored.model.environment_binding_cache === retained
        S = typeof(retained.application_plan_schema)
        current = PSE.Advanced.refresh_environment_bindings!(restored.model, restored.compiled)
        @test current !== retained
        @test typeof(current.application_plan_schema) === S
        @test current.application_plan_schema === retained.application_plan_schema
        moved = current.by_target[(:scheduled_probe, ObjectId(:scheduled_move))]
        @test moved.handle.cell === :b
        @test moved.handle !== retained.by_target[(:scheduled_probe, ObjectId(:scheduled_move))].handle
        step!(restored)
        @test model_status(restored.model, :scheduled_move).seen === 20f0
    end
end

end
