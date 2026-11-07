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

function fixture(::Type{T}) where {T}
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
    simulation = run!(model; steps=1, outputs=:all)
    batch = only(batch for batch in simulation.execution_plan.batches
                 if batch.application.id == :scheduled_probe)
    kept = only(target for target in batch.targets if target.object_id == ObjectId(:scheduled_keep))
    return (; model, simulation, capture, backend, batch, kept)
end

function checkpoint_copy(simulation)
    buffer = IOBuffer()
    serialize(buffer, simulation)
    seekstart(buffer)
    return deserialize(buffer)
end

@testset "checkpointed environment owners preserve application identity" begin
    for copy_simulation in (deepcopy, checkpoint_copy)
        data = fixture(Float32)
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
    data = fixture(Float32)
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
    @test isnothing(PSE._current_environment_binding_owner(data.model, prepared))
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
    data = fixture(Float32)
    simulation = data.simulation
    alternate_compiled = PSE.Advanced.compile_composite_model(data.model, (
        ModelSpec(Leaf(0.0f0); name=:manual_probe, on=Many(kind=:manual),
            environment=Environment(provider=:shell_probe)),
    ))
    alternate = PSE.Advanced.refresh_environment_bindings!(data.model, alternate_compiled)
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
