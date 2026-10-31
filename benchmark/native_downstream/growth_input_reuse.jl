module GrowthInputReuse

using PlantSimEngine
const PSE = PlantSimEngine

isdefined(PSE, :_try_reuse_input_plan_partition!) || error(
    "Growth input reuse requires the optional input-plan partition hook")

export enable_growth_input_reuse!, growth_input_reuse_report

# Cache only interpretation of the immutable plan layout. No model, plan,
# selector, source membership, default, canonical reference or carrier is kept.
struct PlanTag
    origin::Symbol
    input::Symbol
    is_many::Bool
end
struct InferredGroup
    input::Symbol
    indices::Vector{Int}
end
struct PlanPartition
    tags::Vector{PlanTag}
    explicit_indices::Vector{Int}
    inferred_groups::Vector{InferredGroup}
    share_object_queries::Bool
end

mutable struct ReuseState
    partitions::Dict{Symbol,PlanPartition}
    hook_calls::Int
    handled_consumers::Int
    empty_consumers::Int
    partition_builds::Int
    partition_hits::Int
    partition_rebuilds::Int
    validated_plan_tags::Int
    explicit_plan_dispatches::Int
    inferred_groups::Int
    singleton_writer_checks::Int
    singleton_binding_dispatches::Int
    general_match_vectors::Int
    general_candidate_checks::Int
    shared_many_reuses::Int
    appended_bindings::Int
    fallbacks::Dict{Symbol,Int}
end
ReuseState() = ReuseState(Dict{Symbol,PlanPartition}(),
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, Dict{Symbol,Int}())
const _enabled = WeakKeyDict{Any,ReuseState}()

"""Reuse symbolic input-plan partitions; resolve every live binding ordinarily.

Enable before initial logical compilation. This opt-in removes repeated
per-consumer plan grouping and the temporary match vector for a singleton
inferred group without distributed writers. It does not promote prior bindings,
cache negative matches, cache default values or bypass input validation. Every
selector query, source/writer membership check, policy and reference-carrier
construction still uses the current ordinary compiler helpers. Other input
preparation and lifecycle stages remain unchanged.
"""
function enable_growth_input_reuse!(model::PSE.CompositeModel)
    haskey(_enabled, model) && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable growth input reuse before the model's first logical compilation"))
    _enabled[model] = ReuseState()
    return model
end

function _fallback!(state, reason)
    state.fallbacks[reason] = get(state.fallbacks, reason, 0) + 1
    return false
end

Base.@nospecializeinfer @noinline function _partition_matches!(state, partition, plans)
    @nospecialize plans
    length(partition.tags) == length(plans) || return false
    for index in eachindex(partition.tags)
        plan = plans[index]
        tag = partition.tags[index]
        state.validated_plan_tags += 1
        plan.origin === tag.origin && plan.input === tag.input &&
            (plan.selector isa PSE.Many) === tag.is_many || return false
    end
    return true
end

Base.@nospecializeinfer @noinline function _build_partition(plans)
    @nospecialize plans
    tags = PlanTag[]
    explicit_indices = Int[]
    groups = InferredGroup[]
    group_positions = Dict{Symbol,Int}()
    explicit_many = 0
    for (index, plan) in pairs(plans)
        many = plan.selector isa PSE.Many
        push!(tags, PlanTag(plan.origin, plan.input, many))
        if plan.origin !== :inferred_same_object
            push!(explicit_indices, index)
            explicit_many += many
        else
            position = get(group_positions, plan.input, 0)
            if iszero(position)
                push!(groups, InferredGroup(plan.input, Int[index]))
                group_positions[plan.input] = length(groups)
            else
                push!(groups[position].indices, index)
            end
        end
    end
    return PlanPartition(tags, explicit_indices, groups, explicit_many > 1)
end

Base.@nospecializeinfer @noinline function _partition!(state, application_id, plans)
    @nospecialize plans
    previous = get(state.partitions, application_id, nothing)
    if previous !== nothing && _partition_matches!(state, previous, plans)
        state.partition_hits += 1
        return previous
    end
    previous === nothing || (state.partition_rebuilds += 1)
    partition = _build_partition(plans)
    state.partitions[application_id] = partition
    state.partition_builds += 1
    return partition
end

Base.@nospecializeinfer @noinline function PSE._try_reuse_input_plan_partition!(
    bindings, model::PSE.CompositeModel, application::PSE.CompiledModelApplication,
    consumer_id::PSE.ObjectId, input_plans, manual_application_ids,
    applications_by_object, applications_by_id, distributed_outputs,
    many_binding_cache, performance,
)
    @nospecialize bindings model application input_plans manual_application_ids applications_by_object applications_by_id distributed_outputs many_binding_cache performance
    state = get(_enabled, model, nothing)
    state === nothing && return false
    state.hook_calls += 1
    # The ordinary compiler uses dense Tuple/Vector plan collections. Unusual
    # containers take its general path before any binding is appended.
    input_plans isa Union{Tuple,Vector} || return _fallback!(state, :plan_container)
    all(plan -> plan isa PSE.CompiledModelInputPlan, input_plans) ||
        return _fallback!(state, :plan_entry)
    initial_count = length(bindings)
    if isempty(input_plans)
        state.empty_consumers += 1
        state.handled_consumers += 1
        return true
    end
    partition = _partition!(state, application.id, input_plans)
    object_query_cache = partition.share_object_queries ?
        Dict{Any,Vector{PSE.ObjectId}}() : nothing
    for index in partition.explicit_indices
        plan = input_plans[index]
        state.explicit_plan_dispatches += 1
        if many_binding_cache !== nothing
            shared = PSE._shared_many_input_binding(many_binding_cache, model, plan, consumer_id)
            if shared !== nothing
                push!(bindings, shared)
                state.shared_many_reuses += 1
                PSE._runtime_performance_count!(performance, :many_input_binding_precompile_reuses)
                continue
            end
        end
        PSE._push_model_input_binding!(bindings, model, application, consumer_id, plan,
            applications_by_object, applications_by_id, nothing, distributed_outputs;
            object_query_cache)
    end
    if !(application.id in manual_application_ids)
        for group in partition.inferred_groups
            state.inferred_groups += 1
            first_plan = input_plans[first(group.indices)]
            if length(group.indices) == 1 && distributed_outputs isa PSE.NoCompiledDistributedOutputs
                # _final_inferred_output_plans(::NoCompiledDistributedOutputs,
                # ...) is identity. Membership is deliberately rechecked live,
                # even when a preceding invocation found no matching writer.
                state.singleton_writer_checks += 1
                PSE._application_writes_object_variable(distributed_outputs,
                    applications_by_id[first_plan.application], consumer_id,
                    first_plan.source_var) || continue
                PSE._push_model_input_binding!(bindings, model, application, consumer_id,
                    first_plan, applications_by_object, applications_by_id,
                    PSE.ObjectId[consumer_id], distributed_outputs)
                state.singleton_binding_dispatches += 1
                continue
            end
            state.general_match_vectors += 1
            matches = PSE.CompiledModelInputPlan[]
            for index in group.indices
                candidate = input_plans[index]
                state.general_candidate_checks += 1
                PSE._application_writes_object_variable(distributed_outputs,
                    applications_by_id[candidate.application], consumer_id,
                    candidate.source_var) && push!(matches, candidate)
            end
            matches = PSE._final_inferred_output_plans(distributed_outputs,
                consumer_id, first_plan.source_var, matches)
            isempty(matches) && continue
            if length(matches) > 1
                error("Input `$(group.input)` on application `$(application.id)` for object `$(consumer_id.value)` ",
                    "has ambiguous same-object producers: `$([match.application for match in matches])`. ",
                    "Add `inputs=(:$(group.input) => One(...),)` to disambiguate.")
            end
            PSE._push_model_input_binding!(bindings, model, application, consumer_id,
                only(matches), applications_by_object, applications_by_id,
                PSE.ObjectId[consumer_id], distributed_outputs)
        end
    end
    state.appended_bindings += length(bindings) - initial_count
    state.handled_consumers += 1
    return true
end

Base.@nospecializeinfer @noinline function growth_input_reuse_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    fields = (:hook_calls, :handled_consumers, :empty_consumers, :partition_builds,
        :partition_hits, :partition_rebuilds, :validated_plan_tags,
        :explicit_plan_dispatches, :inferred_groups, :singleton_writer_checks,
        :singleton_binding_dispatches, :general_match_vectors,
        :general_candidate_checks, :shared_many_reuses, :appended_bindings)
    counters = NamedTuple{fields}(Tuple(state === nothing ? 0 : getfield(state, field)
        for field in fields))
    return (enabled=state !== nothing, counters...,
        cached_partitions=state === nothing ? 0 : length(state.partitions),
        fallbacks=state === nothing ? Dict{Symbol,Int}() : copy(state.fallbacks),
        cached_payload=:symbols_boolean_tags_and_integer_indices_only,
        cached_source_membership=false, cached_bindings=false, cached_defaults=false,
        runtime_policy=:ordinary_live_source_policy_carrier_defaults_and_validation,
        interpretation=:plan_interpretation_reuse_not_negative_binding_promotion)
end

end # module
