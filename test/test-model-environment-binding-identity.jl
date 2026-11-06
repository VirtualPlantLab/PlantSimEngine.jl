module EnvironmentBindingsIdentityChecks
using PlantSimEngine
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
EA.bind_environment(::Backend, object::Object, context, config) =
    (cell=isnothing(geometry(object)) ? :a : geometry(object).cell,)
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
end
