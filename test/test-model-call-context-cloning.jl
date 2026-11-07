module TypedCallContextCloningChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

PSE.@process "typed_context_clone_owner" verbose=false
PSE.@process "typed_context_clone_middle" verbose=false
PSE.@process "typed_context_clone_leaf" verbose=false

mutable struct Trial{T}
    values::NTuple{2,T}
end
struct AlternateTrial{T}
    values::NTuple{2,T}
end
mutable struct Backend{T} <: EA.AbstractEnvironmentBackend
    values::NTuple{2,T}
    samples::Int
    commits::Vector{T}
end
EA.base_step_seconds(::Backend) = 3600.0
EA.get_nsteps(::Backend) = 8
EA.environment_variables(::Backend) = Set((:T,))
EA.bind_environment(::Backend, object::Object, context, config) =
    (cell=isnothing(geometry(object)) ? 1 : geometry(object).cell,)
function EA.sample(backend::Backend, handle, ::Symbol, time)
    backend.samples += 1
    return backend.values[handle.cell]
end
function EA.sample(backend::Backend, handle, trial::Union{Trial,AlternateTrial}, ::Symbol, time)
    backend.samples += 1
    return trial.values[handle.cell]
end
function EA.commit_environment!(backend::Backend, handle, state, time)
    push!(backend.commits, state.T)
    return nothing
end

struct Owner{C} <: AbstractTyped_Context_Clone_OwnerModel
    capture::C
end
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end
struct Leaf{T} <: AbstractTyped_Context_Clone_LeafModel
    initial::T
end
PSE.outputs_(model::Leaf) = (seen=model.initial, visits=0)
PSE.environment_inputs_(model::Leaf) = (T=model.initial,)
PSE.environment_outputs_(model::Leaf) = (T=model.initial,)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.seen = environment.T
    status.visits += 1
    commit_environment!(context, (T=environment.T,))
    return nothing
end
struct Middle{T,C,H} <: AbstractTyped_Context_Clone_MiddleModel
    initial::T
    capture::C
    hook::H
end
PSE.outputs_(model::Middle) = (sampled=model.initial, seen=model.initial, visits=0)
PSE.environment_inputs_(model::Middle) = (T=model.initial,)
function PSE.run!(model::Middle, status, environment, constants, context)
    child = only(call_targets(context, :one))
    hook = model.hook[]
    if !isnothing(hook)
        model.hook[] = nothing
        hook()
    end
    run_call!(child; publish=true)
    model.capture[] = (; context, child)
    status.sampled = environment.T
    status.seen = child.status.seen
    status.visits += 1
    return nothing
end

function fixture(::Type{T}) where {T}
    owner_capture, middle_capture, hook = Ref{Any}(), Ref{Any}(), Ref{Any}(nothing)
    backend = Backend((T(10), T(20)), 0, T[])
    model = CompositeModel(
        Object(:owner; scale=:Scene),
        Object(:middle; scale=:Branch, parent=:owner, geometry=(cell=1,)),
        Object(:leaf; scale=:Leaf, parent=:middle, geometry=(cell=2,));
        applications=(
            ModelSpec(Owner(owner_capture); name=:owner, on=One(id=:owner),
                calls=(middle=One(id=:middle, within=Subtree(), application=:middle),)),
            ModelSpec(Middle(zero(T), middle_capture, hook); name=:middle,
                on=One(id=:middle), calls=(
                    one=One(id=:leaf, within=Subtree(), application=:leaf),
                    optional=OptionalOne(id=:leaf, within=Subtree(), application=:leaf),
                    many=Many(id=:leaf, within=Subtree(), application=:leaf)),
                environment=Environment(provider=:context_clone)),
            ModelSpec(Leaf(zero(T)); name=:leaf, on=One(id=:leaf),
                environment=Environment(provider=:context_clone)),
        ), environment=backend)
    simulation = run!(model; steps=1, outputs=:all)
    parent = only(call_targets(owner_capture[], :middle))
    return (; model, simulation, parent, backend, owner_capture, middle_capture, hook)
end

@noinline function prepare_context(target, environment; reuse=true, time=target.time, publish=false)
    return PSE._prepare_cached_call_context!(
        target.context_cache, reuse, target.compiled, target.environment_bindings,
        target.application, target.object_id, target.bound_inputs, target.output_targets,
        target.execution_target.call_bindings,
        target.temporal_streams, target.output_retention, time, target.constants,
        publish, environment,
    )
end

@testset "typed context clones isolate shells and preserve execution owners" begin
    data = fixture(Float64)
    prototype = data.parent.context_cache.default
    @test prototype isa PSE.RunContext
    one = call_targets(prototype, :one)
    many = call_targets(prototype, :many)
    @test many.execution_batches isa PSE.LazyCallExecutionBatches
    @test isnothing(many.execution_batches.batches)
    evaluation = PSE.CallEvaluationFrame()
    buffers = PSE._CallTargetBufferCache(nothing, nothing)
    snapshot = (:prepared_snapshot,)
    one.evaluation = evaluation
    one.target_buffer_cache = buffers
    one.last_single_snapshot = snapshot

    trial = Trial((30.0, 40.0))
    typed_calls = @inferred PSE._clone_runtime_call_targets(
        prototype.calls, data.parent.compiled, data.parent.environment_bindings,
        data.parent.temporal_streams, data.parent.output_retention, 2.0,
        data.parent.constants, false, trial,
    )
    @test typeof(typed_calls) === typeof(prototype.calls)
    context = prepare_context(data.parent, trial; time=2.0, publish=false)
    @test context !== prototype
    @test context === data.parent.context_cache.transient
    @test typeof(context.calls) === typeof(prototype.calls)
    @test context.time == 2.0 && !context.publication_allowed
    @test context.environment === trial
    @test context.compiled === prototype.compiled
    @test context.bound_inputs === prototype.bound_inputs
    @test context.output_targets === prototype.output_targets
    @test data.backend.samples == 0
    @test one.evaluation === evaluation
    @test one.target_buffer_cache === buffers
    @test one.last_single_snapshot === snapshot
    for cloned in context.calls
        @test isnothing(cloned.evaluation)
        @test isnothing(cloned.target_buffer_cache)
        @test isnothing(cloned.last_single_snapshot)
    end
    # Subsequent materialization may populate the original borrowing caches;
    # restoration here keeps that activity separate from clone isolation.
    one.evaluation = nothing
    one.target_buffer_cache = nothing
    one.last_single_snapshot = nothing
    for (original, cloned) in zip(prototype.calls, context.calls)
        @test cloned !== original
        @test cloned.binding === original.binding
        @test cloned.time == 2.0 && !cloned.publication_allowed
        @test cloned.environment === trial
        if original.execution_batches isa Tuple
            @test cloned.execution_batches === original.execution_batches
            old_target, new_target = only(original), only(cloned)
            @test new_target.execution_target === old_target.execution_target
            @test new_target.status === old_target.status
            @test new_target.context_cache === old_target.context_cache
        else
            @test cloned.execution_batches !== original.execution_batches
            @test cloned.execution_batches.owner === cloned
            @test original.execution_batches.owner === original
            @test cloned.tracks_full_membership
            @test isnothing(cloned.execution_batches.batches)
        end
    end
    cloned_many = call_targets(context, :many)
    @test length(cloned_many) == 1
    @test isnothing(many.execution_batches.batches) # cloning did not warm the prototype
    @test !isnothing(cloned_many.execution_batches.batches)

    # A warm Many shares prepared scientific owners but has an independent owner
    # link and snapshot/borrowing metadata on every newly leased context shell.
    @test length(many) == 1
    reentrant = prepare_context(data.parent, trial; reuse=false, publish=true)
    @test reentrant !== prototype && reentrant !== context
    @test data.parent.context_cache.transient === context
    warm_many = call_targets(reentrant, :many)
    @test warm_many.execution_batches !== many.execution_batches
    @test warm_many.execution_batches.owner === warm_many
    @test warm_many.execution_batches.batches === many.execution_batches.batches
    @test only(warm_many).execution_target === only(many).execution_target
    @test data.backend.samples == 0
end

@testset "reentry preserves outer descendants, fresh trial sampling and publication masks" begin
    for T in (Float32, Float64)
        data = fixture(T)
        trial = Trial((T(30), T(40)))
        inner_trial = AlternateTrial((T(50), T(60)))
        inner_capture, inner_parent_capture = Ref{Any}(), Ref{Any}()
        lease_checks = Bool[]
        data.hook[] = () -> begin
            push!(lease_checks, data.parent.context_cache.in_use)
            inner_parent = only(call_targets(data.owner_capture[], :middle))
            inner_parent_capture[] = inner_parent
            run_call!(inner_parent; environment=inner_trial, publish=false)
            inner_capture[] = data.middle_capture[]
            push!(lease_checks, data.parent.context_cache.in_use)
        end
        run_call!(data.parent; environment=trial, publish=true)
        outer, inner = data.middle_capture[], inner_capture[]
        @test lease_checks == [true, true]
        @test !data.parent.context_cache.in_use
        @test outer.context !== inner.context
        @test outer.context.calls !== inner.context.calls
        @test inner_parent_capture[].calls !== data.parent.calls
        @test outer.child.execution_target === inner.child.execution_target
        @test outer.child.context_cache === inner.child.context_cache
        @test outer.child.status === inner.child.status === model_status(data.model, :leaf)
        @test outer.child.environment === trial
        @test inner.child.environment === inner_trial
        @test outer.child.publication_allowed && !inner.child.publication_allowed
        @test model_status(data.model, :middle).sampled === T(30)
        @test model_status(data.model, :middle).seen === T(40)
        @test data.backend.samples == 4
        @test data.backend.commits == T[40]
        @test outputs(data.simulation)[(:leaf, ObjectId(:leaf), :seen)] == [(1.0, T(40))]
        transient = data.parent.context_cache.transient

        # Reusing the same mutable override and shell must sample its new values.
        trial.values = (T(31), T(41))
        run_call!(data.parent; environment=trial, publish=false)
        @test data.parent.context_cache.transient === transient
        @test model_status(data.model, :middle).sampled === T(31)
        @test model_status(data.model, :leaf).seen === T(41)
        @test data.backend.samples == 6
        @test data.backend.commits == T[40]
        @test outputs(data.simulation)[(:leaf, ObjectId(:leaf), :seen)] == [(1.0, T(40))]

        data.backend.values = (T(11), T(21))
        run_call!(data.parent; publish=false)
        @test model_status(data.model, :middle).sampled === T(11)
        @test model_status(data.model, :leaf).seen === T(21)
        @test data.backend.samples == 8
        @test data.backend.commits == T[40]
    end
end

@noinline function repeat_contexts(target, environment, count)
    for _ in 1:count
        prepare_context(target, environment)
    end
    return nothing
end
context_reuse_allocations(target, environment, count) =
    @allocated repeat_contexts(target, environment, count)

struct OptionalMiddle{T} <: AbstractTyped_Context_Clone_MiddleModel
    initial::T
end
PSE.outputs_(model::OptionalMiddle) = (seen=model.initial, visits=0)
function PSE.run!(::OptionalMiddle, status, environment, constants, context)
    children = call_targets(context, :child)
    if !isempty(children)
        child = only(children)
        run_call!(child; publish=true)
        status.seen = child.status.seen
    end
    status.visits += 1
    return nothing
end

@testset "stale leased OptionalOne clones rebuild the current descendant schema" begin
    for T in (Float32, Float64)
        capture = Ref{Any}()
        backend = Backend((T(10), T(20)), 0, T[])
        model = CompositeModel(Object(:owner; scale=:Scene),
            Object(:middle; scale=:Branch, parent=:owner); applications=(
                ModelSpec(Owner(capture); name=:owner, on=One(id=:owner),
                    calls=(middle=One(id=:middle, within=Subtree(), application=:middle),)),
                ModelSpec(OptionalMiddle(zero(T)); name=:middle, on=One(id=:middle),
                    calls=(child=OptionalOne(id=:newborn, within=Subtree(), application=:leaf),)),
                ModelSpec(Leaf(zero(T)); name=:leaf, on=Many(scale=:Leaf),
                    environment=Environment(provider=:context_clone)),
            ), environment=backend)
        # This fixture explicitly bypasses the Simulation lifecycle barrier to
        # test a leased context's schema. Retention is covered by the public
        # call scenarios above; this private refresh creates no output streams.
        simulation = run!(model; steps=1, outputs=:none)
        parents = call_targets(capture[], :middle)
        parent = only(parents)
        cache = parent.context_cache
        active = prepare_context(parent, parent.environment; publish=true)
        old_calls = active.calls
        old_optional = call_targets(active, :child)
        @test isempty(old_optional)
        @test old_optional.execution_batches === ()
        cache.in_use = true
        inner = nothing
        try
            register_object!(model, Object(:newborn; scale=:Leaf, parent=:middle,
                geometry=(cell=2,)))
            refreshed = PSE.Advanced.refresh_bindings!(model)
            environments = PSE.refresh_environment_bindings!(model, refreshed)
            # Synchronization can replace wrapper metadata without rebuilding
            # its eager tuple. The captured preparation generation must still
            # identify this old empty OptionalOne as stale.
            PSE._prepare_runtime_call_targets!((parents,), refreshed,
                environments, parent.temporal_streams, parent.output_retention,
                parent.time, parent.constants, true, parent.environment)
            PSE._prepare_model_execution_context!(active, refreshed, environments,
                parent.application, parent.object_id, parent.bound_inputs, parent.output_targets,
                parent.execution_target.call_bindings,
                parent.temporal_streams, parent.output_retention, parent.time,
                parent.constants, true, parent.environment,
            )
            @test active.compiled === refreshed
            @test active.environment_bindings === environments
            @test old_optional.compiled === refreshed
            @test old_optional.environment_bindings === environments
            @test old_optional.binding.callee_object_ids == ObjectId[ObjectId(:newborn)]
            inner = only(parents)
            @test inner.execution_target === parent.execution_target
            @test inner.context_cache === cache
            @test inner.calls !== old_calls
            @test typeof(inner.calls) !== typeof(old_calls)
            @test active.calls === old_calls
            @test isempty(old_optional)
            fresh_optional = only(inner.calls)
            @test fresh_optional.binding === old_optional.binding
            @test length(fresh_optional) == 1
            @test only(fresh_optional).object_id == ObjectId(:newborn)

            # The context-cache path also needs a new schema, not an assertion
            # forcing the old default's empty descendant tuple type.
            fresh_context = prepare_context(inner, inner.environment; reuse=false)
            @test typeof(fresh_context.calls) !== typeof(old_calls)
            @test length(only(fresh_context.calls)) == 1
            run_call!(inner; publish=false)
            @test model_status(model, :newborn).seen === T(20)
            @test model_status(model, :newborn).visits == 1
            @test isempty(backend.commits)
            @test isempty(old_optional)
            @test cache.in_use
        finally
            cache.in_use = false
        end
        # Once the old owner is no longer leased, preserve the freshly rebuilt
        # CT specialization and its caches instead of rebuilding it indefinitely.
        current_transient = prepare_context(inner, inner.environment)
        @test cache.transient === current_transient
        @test typeof(current_transient.calls) !== typeof(old_calls)
        for time in (1.0, 2.0, 3.0)
            repeated = prepare_context(inner, inner.environment; time, publish=true)
            @test repeated === current_transient
            @test repeated.calls === current_transient.calls
            @test repeated.time == time && repeated.publication_allowed
        end
        # The companion TMP probe measures this dynamic old-owner path without
        # conflating identity reuse with an unmeasured zero-allocation claim.
        repeat_contexts(inner, inner.environment, 10)
        @test cache.transient === current_transient
        step!(simulation)
        current = only(call_targets(capture[], :middle))
        run_call!(current; publish=false)
        @test model_status(model, :newborn).visits == 2
        @test current.status.seen === T(20)
    end
end

@testset "one context factory consumes the payload's already resolved bindings" begin
    data = fixture(Float64)
    parent = data.parent
    bindings = parent.execution_target.call_bindings
    @test length(bindings) == 3
    key = (parent.application.id,parent.object_id)
    saved = pop!(parent.compiled.call_bindings_by_target,key)
    context = nothing
    try
        # A target payload already owns these validated bindings. Context
        # construction must not silently rediscover a different/empty schema.
        context = PSE._prepare_model_execution_context!(
            nothing,parent.compiled,parent.environment_bindings,parent.application,
            parent.object_id,parent.bound_inputs,parent.output_targets,bindings,
            parent.temporal_streams,parent.output_retention,2.0,parent.constants,
            false,parent.environment,
        )
        @test !haskey(parent.compiled.call_bindings_by_target,key)
        @test context isa PSE.RunContext
        @test Tuple(PSE._compiled_call_name(target.binding) for target in context.calls) ==
            Tuple(PSE._compiled_call_name(binding) for binding in bindings)
        @test all(target.binding === binding for (target,binding) in zip(context.calls,bindings))
        @test context.time == 2.0 && !context.publication_allowed
        @test PSE.refvalue(only(call_targets(context,:one)).status,:seen) ===
            PSE.refvalue(model_status(data.model,:leaf),:seen)
        @test data.backend.samples == 0
    finally
        parent.compiled.call_bindings_by_target[key] = saved
    end
    @test parent.compiled.call_bindings_by_target[key] === saved
end

@testset "same-shaped replacement bindings do not reuse a stale prototype" begin
    data = fixture(Float64)
    parent = data.parent
    original = parent.execution_target.call_bindings
    replacement = map(original) do binding
        PSE.CompiledModelCallBinding(binding.plan, binding.consumer_id,
            copy(binding.callee_object_ids), copy(binding.callee_application_ids))
    end
    prototype = parent.context_cache.default
    @test PSE._call_context_bindings_match(prototype.calls, original)
    @test !PSE._call_context_bindings_match(prototype.calls, replacement)
    context = PSE._prepare_model_execution_context!(
        prototype,parent.compiled,parent.environment_bindings,parent.application,
        parent.object_id,parent.bound_inputs,parent.output_targets,replacement,
        parent.temporal_streams,parent.output_retention,2.0,parent.constants,
        false,parent.environment; fresh=true,
    )
    @test context !== prototype
    @test all(target.binding === binding for (target,binding) in zip(context.calls,replacement))
    @test all(target.binding === binding for (target,binding) in zip(prototype.calls,original))
    @test data.backend.samples == 0
end

end # module TypedCallContextCloningChecks
