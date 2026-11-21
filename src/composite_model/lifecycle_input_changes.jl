# Binding changes across a lifecycle barrier. The registered objects already
# exist. New consumer bindings and fallible changes to existing source groups
# borrow the normal resolver, then publish the admitted cells and memberships.

struct _StagedManyInputCache{L,P,I,S}
    local_cache::L
    published::P
    added::I
    statuses::S
    pure_addition::Bool
end

function _shared_many_input_binding(staged::_StagedManyInputCache, model, plan, consumer)
    shared = _shared_many_input_binding(staged.local_cache, model, plan, consumer)
    isnothing(shared) || return shared
    # A settled source and a single writer keep the prepared Many carrier
    # family stable on addition. Borrow the cell and recover its final
    # membership from the live cache after the ordinary refresh has run.
    staged.pure_addition && (plan.application !== nothing ||
        _input_route_from_status(plan.route) || length(plan.potential_source_application_ids) == 1) ||
        return nothing
    previous = _shared_many_input_binding(staged.published, model, plan, consumer)
    isnothing(previous) && return nothing
    if isempty(previous.source_ids)
        # An empty live group can receive its first column. Check only the
        # incoming cells against the existing carrier's admitted element type.
        scope = _default_dependency_scope(model, consumer)
        R = eltype(parent(previous.carrier))
        for id in staged.added
            _selector_matches_object_id(model, plan.matcher, id, consumer, true, scope, false) || continue
            ref = _input_source_cell(staged.statuses, model.registry.objects, id, _input_route_source(plan.route))
            ref isa R || return nothing
        end
    end
    return previous
end

struct _PendingStatusInputChanges{B,I}
    candidates::Vector{Int}
    added::I
    bindings::B
    updates::Dict{Int,Tuple{Symbol,Int}}
end

struct _StagedConsumerBindings{B,S,R,C,M,A}
    entries::B
    statuses::S
    ranges::R
    cache::Union{Nothing,C}
    model::M
    existing::Union{Nothing,_PendingStatusInputChanges{B,A}}
    reused::BitSet

    function _StagedConsumerBindings(entries, statuses, ranges, cache, model, existing, has_routes::Bool)
        return new{typeof(entries),typeof(statuses),typeof(ranges),typeof(cache),typeof(model),typeof(cache.added)}(
            entries, statuses, ranges, has_routes ? cache : nothing, model, existing, BitSet())
    end
end
Base.length(bindings::_StagedConsumerBindings) = length(bindings.entries)
Base.push!(bindings::_StagedConsumerBindings, binding) = push!(bindings.entries, binding)

_push_shared_many_input!(bindings, binding) = push!(bindings, binding)
function _push_shared_many_input!(staged::_StagedConsumerBindings, binding)
    push!(staged.entries, binding)
    push!(staged.reused, length(staged.entries))
    return nothing
end

function _record_consumer_input_bindings!(staged::_StagedConsumerBindings, bindings,
    application_id::Symbol, object_id, first_binding, last_binding)
    first_binding <= last_binding || return nothing
    range = first_binding:last_binding
    push!(staged.ranges, (application_id, object_id, range))
    for i in range
        _store_shared_many_input_binding!(staged.cache.local_cache, staged.model,
            staged.entries, i)
    end
    return nothing
end

@inline _has_consumer_input_routes(recipe, manual::Bool) =
    !isempty(recipe.explicit) || (!manual && !isempty(recipe.inferred))

function _new_consumer_input_storage(compiled, model, applications, added, pure_addition, candidates)
    plan = compiled.scenario_plan
    any_routes = false
    for application in applications
        id = application.id
        if _with_metadata_entry(_has_consumer_input_routes, plan.input_recipes_by_application, id,
            id in plan.manual_application_ids)
            any_routes = true
            break
        end
    end
    existing = _pending_status_input_changes(compiled, candidates, added, pure_addition)
    any_routes || !isnothing(existing) || return nothing
    I = keytype(model.registry.objects)
    entries = similar(compiled.input_bindings, 0)
    statuses = _output_status_preparation(model)
    # Only new consumers need a writable query cache. A refresh of existing
    # readers needs its storage type, which the published cache already supplies.
    local_cache = any_routes ? _empty_many_input_binding_cache(I, entries) : compiled.many_input_binding_cache
    cache = _StagedManyInputCache(local_cache,
        compiled.many_input_binding_cache, added, statuses, pure_addition)
    ranges = Tuple{Symbol,I,UnitRange{Int}}[]
    return _StagedConsumerBindings(entries, statuses, ranges, cache, model, existing, any_routes)
end

function _stage_added_scene_inputs!(compiled, model, applications, output_applications,
    outputs, destinations, ::Nothing, performance)
    _prepare_model_output_statuses!(model, output_applications, compiled.applications_by_id; performance)
    isempty(destinations) || _prepare_model_output_destination_statuses!(model, destinations)
    return nothing
end

function _stage_added_scene_inputs!(compiled, model, applications, output_applications,
    outputs, destinations, staged::_StagedConsumerBindings, performance)
    empty!(staged.entries)
    empty!(staged.ranges)
    empty!(staged.reused)
    if !isnothing(staged.cache)
        empty!(staged.cache.local_cache.by_query)
        empty!(staged.cache.local_cache.by_plan)
    end
    _stage_model_output_statuses!(staged.statuses, model, output_applications, compiled.applications_by_id)
    for record in destinations
        _stage_model_output_destination_statuses!(model, record, staged.statuses.recipes,
            staged.statuses.recipe_order, staged.statuses.conversion_records)
    end
    if !isnothing(staged.cache)
        _compile_model_input_bindings!(staged, model, applications,
            compiled.scenario_plan.manual_application_ids, compiled.scenario_plan.input_recipes_by_application,
            outputs, compiled.applications_by_object, compiled.applications_by_id, staged.cache, performance, staged)
    end
    _stage_existing_status_inputs!(staged.existing, compiled, model, outputs, staged.statuses, performance)
    _commit_model_output_statuses!(model, staged.statuses; performance)
    return nothing
end

_publish_added_consumer_bindings!(recorder, input_bindings, ::Nothing, args...) = nothing

function _publish_shared_consumer_input!(binding, destination, cache, model, consumer)
    shared = _shared_many_input_binding(cache, model, binding.plan, consumer)
    push!(destination, isnothing(shared) ? binding : shared)
    return nothing
end

function _publish_added_consumer_bindings!(recorder, input_bindings, staged::_StagedConsumerBindings,
    model, many_binding_cache, previous_binding_count)
    for (id, consumer, range) in staged.ranges
        for index in range
            binding = staged.entries[index]
            if index in staged.reused
                _with_model_input_binding(_publish_shared_consumer_input!, staged.entries,
                    binding, input_bindings, many_binding_cache, model, consumer)
            else
                push!(input_bindings, binding)
            end
        end
        _record_consumer_input_bindings!(recorder, input_bindings, id, consumer,
            previous_binding_count + first(range), previous_binding_count + last(range))
    end
    return nothing
end

# A raw status reader can select a new object with no cell for its variable.
# A singular route can also acquire a second source. Stage those fallible
# changes in the same barrier as the new consumers, without copying old IDs.

function _pending_status_input_changes(compiled, candidates, added, pure_addition)
    pure_addition && !isempty(candidates) || return nothing
    indices = Int[]
    for index in candidates
        raw = compiled.input_bindings[index]
        needed = _with_model_input_binding(compiled.input_bindings, raw) do binding
            binding.multiplicity !== :many || _input_route_from_status(binding.plan.route)
        end
        needed && push!(indices, index)
    end
    isempty(indices) && return nothing
    return _PendingStatusInputChanges(sort!(indices), added, similar(compiled.input_bindings, 0),
        Dict{Int,Tuple{Symbol,Int}}())
end

_stage_existing_status_inputs!(::Nothing, args...) = nothing
function _stage_existing_status_inputs!(pending, compiled, model, outputs, statuses, performance)
    empty!(pending.bindings)
    empty!(pending.updates)
    for index in pending.candidates
        _with_model_input_binding(_stage_existing_status_input!, compiled.input_bindings,
            compiled.input_bindings[index], pending, index, compiled, model, outputs, statuses, performance)
    end
    return nothing
end

function _stage_existing_status_input!(binding, pending, index, compiled, model, outputs, statuses, performance)
    if binding.multiplicity === :many && binding.carrier isa Union{RefVector,ObjectRefVector}
        delta = _prepare_added_many_sources(model, binding, pending.added,
            compiled.applications_by_object, compiled.applications_by_id, outputs; statuses)
        if delta isa _UnchangedManyInput
            pending.updates[index] = (:unchanged, 0)
            return nothing
        elseif !isnothing(delta)
            push!(pending.bindings, delta)
            pending.updates[index] = (:append, length(pending.bindings))
            return nothing
        end
    elseif binding.multiplicity !== :many
        scope = _default_dependency_scope(model, binding.consumer_id)
        _selector_matches_any_object_id(model, binding.matcher, pending.added, binding.consumer_id,
            true, scope) || return nothing
    end
    sources = _resolve_input_sources(model, binding.consumer_id, binding.plan,
        compiled.applications_by_object, compiled.applications_by_id, nothing, outputs)
    replacement = _materialize_input_route(model, binding.application_id,
        compiled.applications_by_id[binding.application_id].process, binding.consumer_id, binding.plan,
        sources, compiled.applications_by_id, statuses)
    push!(pending.bindings, replacement)
    pending.updates[index] = (:replace, length(pending.bindings))
    return nothing
end

_pending_input_update(::Nothing, index) = nothing
_pending_input_update(pending, index) = get(pending.updates, index, nothing)

function _discard_added_memberships!(compiled, new_targets)
    for (id, targets) in new_targets
        _with_metadata_entry(compiled.applications_by_id, id) do application
            for object_id in targets
                found, position = _sorted_object_id_position(application.target_ids, object_id)
                found && deleteat!(application.target_ids, position)
                delete!(compiled.applications_by_object, object_id)
            end
            return nothing
        end
    end
    return nothing
end
