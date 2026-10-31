module NewbornPreparation

using PlantSimEngine
const PSE = PlantSimEngine

for name in (:_record_newborn_input_preparation!, :_try_promote_newborn_input_bindings!)
    isdefined(PSE, name) || error(
        "Apply /private/tmp/pse_newborn_promotion.patch before loading NewbornPreparation")
end

export prepare_newborn, enable_newborn_preparation!, disable_newborn_preparation!,
    newborn_preparation_report

mutable struct PreparationCounters
    enabled::Bool
    captured_targets::Int
    captured_bindings::Int
    promotion_attempts::Int
    promoted_targets::Int
    promoted_bindings::Int
    misses::Dict{Symbol,Int}
end
PreparationCounters(enabled=true) = PreparationCounters(enabled, 0, 0, 0, 0, 0,
    Dict{Symbol,Int}())

# This registry stores counters only. Scientific references belong to the
# event-owned cache on _TargetedTopologyRuntime, not to a global model cache.
const _enabled = WeakKeyDict{Any,PreparationCounters}()

struct BindingStamp
    binding::Any
    source_ids::Vector{PSE.ObjectId}
    source_applications::Vector{Symbol}
    source_references::Vector{Any}
end

struct PreparedInputs
    delta::WeakRef
    compiled::WeakRef
    model_revision::Int
    environment_revision::Int
    mutation_generation::UInt64
    execution_generation::UInt64
    application_plan::Any
    input_plans::Any
    consumer_id::PSE.ObjectId
    input_schema::Vector{Tuple{Symbol,Any}}
    bindings::Vector{PSE.CompiledModelInputBinding}
    stamps::Vector{BindingStamp}
    prepared_at::Float64
end

mutable struct PreparationCache
    records::Dict{Tuple{Symbol,PSE.ObjectId},PreparedInputs}
end
PreparationCache() = PreparationCache(Dict{Tuple{Symbol,PSE.ObjectId},PreparedInputs}())

function enable_newborn_preparation!(model::PSE.CompositeModel)
    hasfield(PSE._TargetedTopologyRuntime, :preparation_cache) || error(
        "Targeted topology runtime is missing its event-owned preparation cache field")
    _enabled[model] = PreparationCounters()
    return model
end

function disable_newborn_preparation!(model::PSE.CompositeModel)
    state = get(_enabled, model, nothing)
    isnothing(state) || (state.enabled = false)
    return model
end

function _miss!(state, reason)
    state.misses[reason] = get(state.misses, reason, 0) + 1
    return false
end

function _capture_miss!(state, reason)
    _miss!(state, Symbol("capture_", reason))
    return nothing
end

function _strict_addition(delta)
    delta.structural_kind === :addition && !isempty(delta.added) &&
        !delta.full_environment && isempty(delta.removed) &&
        isempty(delta.reparented) && isempty(delta.moved) || return false
    return all(id -> id in delta.structural_dirty_ids, delta.environment_dirty_ids)
end

function _canonical_reference(model, object_id, variable)
    haskey(model.registry.objects, object_id) || return nothing
    status = PSE._model_object(model, object_id).status
    status isa PSE.Status && hasproperty(status, variable) || return nothing
    return PSE.refvalue(status, variable)
end

function _carrier_references(binding)
    carrier = binding.carrier
    if binding.multiplicity === :many
        carrier isa Union{PSE.RefVector,PSE.ObjectRefVector} || return nothing
        return Any[reference for reference in parent(carrier)]
    end
    isnothing(carrier) && isempty(binding.source_ids) && return Any[]
    carrier isa Ref || return nothing
    return Any[carrier]
end

function _source_writer_rejection(model, compiled, binding, distributed_outputs)
    # Inspect ownership by the actual destination field, including from_status
    # bindings whose source_application_ids are intentionally empty. Recheck
    # with refreshed distributed_outputs at promotion, before touching bindings.
    isempty(binding.source_ids) && return nothing
    for application_id in binding.source_application_ids
        application = get(compiled.applications_by_id, application_id, nothing)
        isnothing(application) && return :source_application_missing
        haskey(PSE._distributed_output_schema(application.spec), binding.source_var) &&
            return :distributed_source_declaration
        haskey(PSE._local_output_schema(application.spec), binding.source_var) ||
            return :source_declaration_changed
        PSE._publish_mode_for_output(application.spec, binding.source_var) === :canonical ||
            return :noncanonical_source_writer
    end
    for source_id in binding.source_ids
        if distributed_outputs isa PSE.CompiledDistributedOutputs
            owners = get(distributed_outputs.writer_ownership,
                (source_id, binding.source_var), ())
            any(owner -> owner.kind === :output_destination, owners) &&
                return :distributed_source_owner
        end
        isempty(binding.source_application_ids) && continue
        runtime = PSE.lifecycle_delta(model).targeted_topology_runtime
        added = runtime isa PSE._TargetedTopologyRuntime && runtime.compiled === compiled ?
            get(runtime.added_applications_by_object, source_id, nothing) : nothing
        applications = isnothing(added) ?
            get(compiled.applications_by_object, source_id, ()) : added
        local_writer_count = 0
        for application_id in binding.source_application_ids
            local_writer_count += any(candidate -> candidate.id == application_id, applications)
        end
        iszero(local_writer_count) && return :source_writer_membership_changed
        # Distributed-scene ownership is extended at the ordinary barrier.
        # Do not promote a targeted pre-refresh Many list whose duplicate
        # local writers could acquire a different final canonical owner then.
        local_writer_count == 1 || return :ambiguous_selected_local_writers
    end
    return nothing
end

function _binding_stamp(model, compiled, binding)
    binding.policy isa Union{PSE.HoldLast,PSE.PreviousTimeStep} ||
        return (nothing, :unsupported_temporal_policy)
    isnothing(binding.window) || return (nothing, :temporal_window)
    PSE._has_stream_only_input_source(binding.source_application_ids,
        binding.source_var, compiled.applications_by_id) &&
        return (nothing, :stream_only_source)
    reason = _source_writer_rejection(model, compiled, binding, compiled.distributed_outputs)
    isnothing(reason) || return (nothing, reason)
    references = _carrier_references(binding)
    isnothing(references) && return (nothing, :nonreference_carrier)
    length(references) == length(binding.source_ids) ||
        return (nothing, :source_reference_alignment)
    for (id, reference) in zip(binding.source_ids, references)
        _canonical_reference(model, id, binding.source_var) === reference ||
            return (nothing, :noncanonical_source_reference)
    end
    return (BindingStamp(binding, copy(binding.source_ids),
        copy(binding.source_application_ids), references), nothing)
end

function _input_port_schema(model, object_id, plans)
    status = PSE._model_object(model, object_id).status
    status isa PSE.Status || return nothing
    names = unique(Symbol[plan.input for plan in plans])
    return Tuple{Symbol,Any}[(name, hasproperty(status, name) ?
        typeof(PSE.refvalue(status, name)) : nothing) for name in names]
end

function _schema_matches(model, record)
    haskey(model.registry.objects, record.consumer_id) || return false
    status = PSE._model_object(model, record.consumer_id).status
    status isa PSE.Status || return false
    for (name, T) in record.input_schema
        current = hasproperty(status, name) ? typeof(PSE.refvalue(status, name)) : nothing
        current === T || return false
    end
    return true
end

function _references_match(model, stamp)
    binding = stamp.binding
    binding.source_ids == stamp.source_ids &&
        binding.source_application_ids == stamp.source_applications || return false
    references = _carrier_references(binding)
    isnothing(references) && return false
    length(references) == length(stamp.source_references) || return false
    for (id, current, captured) in zip(stamp.source_ids, references, stamp.source_references)
        current === captured || return false
        _canonical_reference(model, id, binding.source_var) === captured || return false
    end
    return true
end

"""
Capture only resolved logical bindings. Kernel execution, status views, temporal
scratch values, samples, handles, output bindings and call leases stay original.
"""
Base.@nospecializeinfer @noinline function PSE._record_newborn_input_preparation!(
    model::PSE.CompositeModel, context::PSE.RunContext, runtime,
    callee_applications, bindings,
)
    @nospecialize model context runtime callee_applications bindings
    state = get(_enabled, model, nothing)
    (isnothing(state) || !state.enabled) && return nothing
    delta = PSE.lifecycle_delta(model)
    _strict_addition(delta) || return _capture_miss!(state, :nonaddition_event)
    cache = runtime.preparation_cache
    if isnothing(cache)
        cache = PreparationCache()
        runtime.preparation_cache = cache
    end
    cache isa PreparationCache || return _capture_miss!(state, :foreign_preparation_cache)
    by_target = PSE._index_model_bindings(bindings, :application_id, :consumer_id)
    for application in callee_applications
        plans = PSE._application_plans(
            context.compiled.scenario_plan.input_plans_by_application, application.slot)
        for consumer_id in application.target_ids
            if !(consumer_id in delta.structural_dirty_ids)
                _capture_miss!(state, :not_newborn)
                continue
            end
            delete!(cache.records, (application.id, consumer_id))
            selected = PSE.CompiledModelInputBinding[
                binding for binding in get(by_target, (application.id, consumer_id), ())]
            stamps = BindingStamp[]
            supported = true
            for binding in selected
                stamp, reason = _binding_stamp(model, context.compiled, binding)
                if isnothing(stamp)
                    _capture_miss!(state, reason)
                    supported = false
                    break
                end
                push!(stamps, stamp)
            end
            supported || continue
            schema = _input_port_schema(model, consumer_id, plans)
            if isnothing(schema)
                _capture_miss!(state, :missing_input_schema)
                continue
            end
            cache.records[(application.id, consumer_id)] = PreparedInputs(
                WeakRef(delta), WeakRef(context.compiled), model.revision,
                model.environment_revision, delta.mutation_generation,
                context.compiled.execution_generation, application.plan, plans,
                consumer_id, schema, selected, stamps, float(context.time))
            state.captured_targets += 1
            state.captured_bindings += length(selected)
        end
    end
    return nothing
end

"""
Promote references only at the ordinary new-consumer insertion site. All
normal default/required validation, Many sharing, canonical rewiring, temporal
view construction and environment sampling run afterwards in their old order.
"""
Base.@nospecializeinfer @noinline function PSE._try_promote_newborn_input_bindings!(
    destination, model::PSE.CompositeModel, compiled::PSE.CompiledCompositeModel,
    application::PSE.CompiledModelApplication, consumer_id::PSE.ObjectId,
    plans, distributed_outputs, performance,
)
    @nospecialize destination model compiled application plans distributed_outputs performance
    state = get(_enabled, model, nothing)
    (isnothing(state) || !state.enabled) && return false
    state.promotion_attempts += 1
    isnothing(performance) || return _miss!(state, :instrumented_execution)
    delta = PSE.lifecycle_delta(model)
    _strict_addition(delta) || return _miss!(state, :nonaddition_event)
    runtime = delta.targeted_topology_runtime
    runtime isa PSE._TargetedTopologyRuntime || return _miss!(state, :no_targeted_runtime)
    cache = runtime.preparation_cache
    cache isa PreparationCache || return _miss!(state, :no_preparation_cache)
    record = get(cache.records, (application.id, consumer_id), nothing)
    isnothing(record) && return _miss!(state, :uncached_target)
    record.delta.value === delta && record.compiled.value === compiled ||
        return _miss!(state, :event_or_compiler_identity)
    record.model_revision == model.revision &&
        record.environment_revision == model.environment_revision &&
        record.mutation_generation == delta.mutation_generation &&
        record.execution_generation == compiled.execution_generation ||
        return _miss!(state, :epoch_changed)
    consumer_id in delta.structural_dirty_ids || return _miss!(state, :not_newborn)
    record.application_plan === application.plan && record.input_plans === plans ||
        return _miss!(state, :plan_changed)
    _schema_matches(model, record) || return _miss!(state, :input_schema_changed)
    all(stamp -> _references_match(model, stamp), record.stamps) ||
        return _miss!(state, :canonical_reference_changed)
    for binding in record.bindings
        reason = _source_writer_rejection(model, compiled, binding, distributed_outputs)
        isnothing(reason) || return _miss!(state, reason)
    end
    # No mutation of destination occurs on any rejection path above.
    append!(destination, record.bindings)
    state.promoted_targets += 1
    state.promoted_bindings += length(record.bindings)
    return true
end

function prepare_newborn(model::PSE.CompositeModel; steps::Integer=1,
    constants=PSE.PlantMeteo.Constants(), outputs=:none, performance::Bool=false)
    enable_newborn_preparation!(model)
    performance && disable_newborn_preparation!(model)
    return PSE.run!(model; steps, constants, outputs, performance)
end

function newborn_preparation_report(model::PSE.CompositeModel)
    state = get(_enabled, model, nothing)
    isnothing(state) && return (enabled=false, captured_targets=0,
        captured_bindings=0, promotion_attempts=0, promoted_targets=0,
        promoted_bindings=0, misses=Dict{Symbol,Int}(),
        capture_rejections=Dict{Symbol,Int}())
    return (enabled=state.enabled, captured_targets=state.captured_targets,
        captured_bindings=state.captured_bindings,
        promotion_attempts=state.promotion_attempts,
        promoted_targets=state.promoted_targets, promoted_bindings=state.promoted_bindings,
        misses=copy(state.misses),
        capture_rejections=Dict(key => count for (key, count) in state.misses
            if startswith(string(key), "capture_")),
        cached_scientific_values=false,
        promoted_status_views=false, promoted_environment_bindings=false,
        storage=:lifecycle_owned_preparation_cache,
        guard=:event_compiler_revision_mutation_execution_plan_ports_and_source_refs)
end
newborn_preparation_report(simulation::PSE.Simulation) =
    newborn_preparation_report(PSE.runtime_model(simulation))

end # module
