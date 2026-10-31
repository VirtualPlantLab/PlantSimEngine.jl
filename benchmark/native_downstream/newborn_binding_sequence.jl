module NewbornBindingSequence

using PlantSimEngine
const PSE = PlantSimEngine
isdefined(Main, :NewbornBindingProgram) || error("Load NewbornBindingProgram first")
const NBP = getfield(Main, :NewbornBindingProgram)
for name in (:_try_newborn_binding_sequence!, :_push_model_input_binding_ordinary!)
    isdefined(PSE, name) || error("Newborn binding sequences require the optional core hooks")
end
isdefined(NBP, :_execute_prepared_instruction!) || error("Load the sequence-ready binding program")

export enable_newborn_binding_sequence!, newborn_binding_sequence_report

struct PlanTag
    slot::Int
    origin::Symbol
    input::Symbol
    is_many::Bool
end
struct InferredGroup
    input::Symbol
    indices::Vector{Int}
end
struct ConsumerSequence
    program::NBP.BindingProgram
    tags::Vector{PlanTag}
    explicit_indices::Vector{Int}
    inferred_groups::Vector{InferredGroup}
    share_object_queries::Bool
end

# Fixed aggregate counts remain enabled in every timed candidate. Detailed
# per-input and reason dictionaries are optional and are reported as such.
mutable struct SequenceCounters
    programs_built::Int
    instructions_compiled::Int
    sequences_built::Int
    preparation_skips::Int
    consumer_lookups::Int
    consumer_program_executions::Int
    consumer_program_fallbacks::Int
    instruction_attempts::Int
    instruction_cache_hits::Int
    instruction_executions::Int
    synthesized_bindings::Int
    newborn_positive_executions::Int
    initial_positive_executions::Int
    existing_positive_executions::Int
    resolved_fallbacks::Int
    instruction_fallbacks::Int
    status_instruction_executions::Int
    producer_instruction_executions::Int
    newborn_status_executions::Int
    newborn_producer_executions::Int
    newborn_targeted_executions::Int
    newborn_global_refresh_executions::Int
    ordinary_binding_dispatches::Int
    shared_many_reuses::Int
    singleton_group_checks::Int
    singleton_group_shortcuts::Int
    general_inferred_groups::Int
end
SequenceCounters() = SequenceCounters(ntuple(_ -> 0, fieldcount(SequenceCounters))...)

mutable struct SequenceState
    base::NBP.ProgramState
    sequences::WeakKeyDict{Any,ConsumerSequence}
    counts::SequenceCounters
    details::Bool
    misses::Dict{Symbol,Int}
    per_input::Dict{Tuple{Symbol,Symbol},Int}
    delta::WeakRef
    added_cursor::Int
    added_ids::Set{PSE.ObjectId}
end
SequenceState(base, details) = SequenceState(base, WeakKeyDict{Any,ConsumerSequence}(),
    SequenceCounters(), details, Dict{Symbol,Int}(), Dict{Tuple{Symbol,Symbol},Int}(),
    WeakRef(nothing), 0, Set{PSE.ObjectId}())
const _enabled = WeakKeyDict{Any,SequenceState}()

"""Execute an ordered binding program with fresh memberships and canonical refs.

Enable before initial logical compilation. The sequence reuses the base
program's conservative declaration proofs and exact scalar-binding executor.
It hoists program acquisition to one consumer invocation and removes repeated
inferred grouping. A singleton inferred group can omit its temporary matching
vector only when the sole candidate's current GLOBAL local membership is
proved. All other groups retain the ordinary writer/final-owner/error rules.
No sampled environment, default, membership, carrier, or binding is cached.

`details=false` keeps fixed aggregate execution counters and omits hot per-input
and fallback-reason dictionary updates. Use `details=true` for a diagnostic
companion, with its extra work included if that mode itself is timed.
"""
function enable_newborn_binding_sequence!(model::PSE.CompositeModel; details::Bool=false)
    previous = get(_enabled, model, nothing)
    if previous !== nothing
        previous.details === details || throw(ArgumentError(
            "Choose sequence detail mode before enabling the model"))
        return model
    end
    NBP.enable_newborn_binding_program!(model)
    _enabled[model] = SequenceState(NBP._enabled[model], details)
    return model
end

@inline function NBP._count!(state::SequenceState, name::Symbol, amount::Int=1)
    counts = state.counts
    setfield!(counts, name, getfield(counts, name) + amount)
    return nothing
end

function NBP._miss!(state::SequenceState, reason, resolved=nothing)
    state.counts.instruction_fallbacks += 1
    if state.details
        state.misses[reason] = get(state.misses, reason, 0) + 1
    end
    if resolved !== nothing
        state.counts.resolved_fallbacks += 1
        return resolved
    end
    return false
end

function NBP._record_input_execution!(state::SequenceState, application_id, input)
    if state.details
        key = (application_id, input)
        state.per_input[key] = get(state.per_input, key, 0) + 1
    end
    return nothing
end

function _consumer_fallback!(state, reason)
    state.counts.consumer_program_fallbacks += 1
    if state.details
        state.misses[reason] = get(state.misses, reason, 0) + 1
    end
    return false
end

Base.@nospecializeinfer @noinline function _build_sequence(program, plans)
    @nospecialize plans
    plans isa Union{Tuple,Vector} || return nothing
    all(plan -> plan isa PSE.CompiledModelInputPlan, plans) || return nothing
    tags = PlanTag[]
    explicit = Int[]
    groups = InferredGroup[]
    positions = Dict{Symbol,Int}()
    explicit_many = 0
    for (index, plan) in pairs(plans)
        many = plan.selector isa PSE.Many
        push!(tags, PlanTag(plan.slot, plan.origin, plan.input, many))
        if plan.origin !== :inferred_same_object
            push!(explicit, index)
            explicit_many += many
        else
            position = get(positions, plan.input, 0)
            if iszero(position)
                push!(groups, InferredGroup(plan.input, Int[index]))
                positions[plan.input] = length(groups)
            else
                push!(groups[position].indices, index)
            end
        end
    end
    return ConsumerSequence(program, tags, explicit, groups, explicit_many > 1)
end

Base.@nospecializeinfer @noinline function NBP._binding_program_prepared!(
    model::PSE.CompositeModel, base::NBP.ProgramState, program::NBP.BindingProgram,
    applications, plans_by_application,
)
    @nospecialize model applications plans_by_application
    state = get(_enabled, model, nothing)
    state === nothing && return nothing
    for application in applications
        plans = PSE._application_plans(plans_by_application, application.slot)
        sequence = _build_sequence(program, plans)
        if sequence === nothing
            state.counts.preparation_skips += 1
        else
            state.sequences[application] = sequence
            state.counts.sequences_built += 1
        end
    end
    state.counts.programs_built += 1
    state.counts.instructions_compiled += length(program.instructions)
    return nothing
end

Base.@nospecializeinfer @noinline function _layout_matches(sequence, plans)
    @nospecialize plans
    plans isa Union{Tuple,Vector} || return false
    length(sequence.tags) == length(plans) || return false
    for index in eachindex(sequence.tags)
        plan = plans[index]
        plan isa PSE.CompiledModelInputPlan || return false
        tag = sequence.tags[index]
        plan.slot == tag.slot && plan.origin === tag.origin &&
            plan.input === tag.input && (plan.selector isa PSE.Many) === tag.is_many ||
            return false
    end
    return true
end

# Every per-op fallback continues at the original binding position. Once any
# binding has been appended, this executor never declines the whole consumer.
Base.@nospecializeinfer @noinline function _dispatch_plan!(
    state::SequenceState, program::NBP.BindingProgram, bindings, model,
    application, consumer_id, plan, applications_by_object, applications_by_id,
    source_ids_override, distributed_outputs, object_query_cache,
)
    @nospecialize bindings model application plan applications_by_object applications_by_id source_ids_override distributed_outputs object_query_cache
    state.counts.instruction_attempts += 1
    op = get(program.instructions, plan.slot, nothing)
    outcome = if program.world != Base.get_world_counter()
        NBP._miss!(state, :method_world_changed)
    elseif op === nothing
        NBP._miss!(state, :unsupported_instruction)
    else
        NBP._execute_prepared_instruction!(state, program, op, bindings, model,
            application, consumer_id, plan, applications_by_object,
            applications_by_id, source_ids_override, distributed_outputs,
            object_query_cache)
    end
    if outcome !== true
        resolved = outcome isa Vector{PSE.ObjectId} ? outcome : source_ids_override
        PSE._push_model_input_binding_ordinary!(bindings, model, application,
            consumer_id, plan, applications_by_object, applications_by_id,
            resolved, distributed_outputs; object_query_cache)
        state.counts.ordinary_binding_dispatches += 1
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _singleton_local_member(
    program::NBP.BindingProgram, plan, consumer_id, applications_by_id,
)
    @nospecialize plan applications_by_id
    program.world == Base.get_world_counter() || return false
    op = get(program.instructions, plan.slot, nothing)
    op === nothing && return false
    op.producer !== nothing && plan.application === op.producer || return false
    NBP._same_header(op, plan) || return false
    source = get(applications_by_id, op.producer, nothing)
    expected = get(program.applications, op.producer, nothing)
    source !== nothing && expected !== nothing && expected.value === source || return false
    # Ordinary inferred grouping checks the global application, not the
    # targeted newborn overlay. An overlay-only candidate must fall back.
    return first(PSE._sorted_object_id_position(getfield(source, :target_ids), consumer_id))
end

Base.@nospecializeinfer @noinline function PSE._try_newborn_binding_sequence!(
    bindings, model::PSE.CompositeModel, application::PSE.CompiledModelApplication,
    consumer_id::PSE.ObjectId, input_plans, manual_application_ids,
    applications_by_object, applications_by_id, distributed_outputs,
    many_binding_cache, performance,
)
    @nospecialize bindings model application input_plans manual_application_ids applications_by_object applications_by_id distributed_outputs many_binding_cache performance
    state = get(_enabled, model, nothing)
    state === nothing && return false
    state.counts.consumer_lookups += 1
    logical = get(applications_by_id, application.id, nothing)
    logical === nothing && return _consumer_fallback!(state, :logical_application_missing)
    sequence = get(state.sequences, logical, nothing)
    sequence === nothing && return _consumer_fallback!(state, :unregistered_sequence_epoch)
    program = sequence.program
    program.world == Base.get_world_counter() ||
        return _consumer_fallback!(state, :method_world_changed)
    _layout_matches(sequence, input_plans) ||
        return _consumer_fallback!(state, :plan_layout_changed)
    # All consumer-wide guards precede mutation. Subsequent failures are
    # resolved by the individual ordinary binding/group path in place.
    state.counts.consumer_program_executions += 1
    object_query_cache = sequence.share_object_queries ?
        Dict{Any,Vector{PSE.ObjectId}}() : nothing
    for index in sequence.explicit_indices
        plan = input_plans[index]
        if many_binding_cache !== nothing
            shared = PSE._shared_many_input_binding(many_binding_cache, model, plan, consumer_id)
            if shared !== nothing
                push!(bindings, shared)
                state.counts.shared_many_reuses += 1
                PSE._runtime_performance_count!(performance, :many_input_binding_precompile_reuses)
                continue
            end
        end
        _dispatch_plan!(state, program, bindings, model, application, consumer_id,
            plan, applications_by_object, applications_by_id, nothing,
            distributed_outputs, object_query_cache)
    end
    if !(application.id in manual_application_ids)
        for group in sequence.inferred_groups
            first_plan = input_plans[first(group.indices)]
            if length(group.indices) == 1
                state.counts.singleton_group_checks += 1
                if _singleton_local_member(program, first_plan, consumer_id, applications_by_id)
                    # With one proved match, final-owner filtering returns
                    # that match even when its owner is absent from the table.
                    state.counts.singleton_group_shortcuts += 1
                    _dispatch_plan!(state, program, bindings, model, application,
                        consumer_id, first_plan, applications_by_object,
                        applications_by_id, PSE.ObjectId[consumer_id],
                        distributed_outputs, nothing)
                    continue
                end
            end
            state.counts.general_inferred_groups += 1
            matches = PSE.CompiledModelInputPlan[]
            for index in group.indices
                candidate = input_plans[index]
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
            _dispatch_plan!(state, program, bindings, model, application,
                consumer_id, only(matches), applications_by_object,
                applications_by_id, PSE.ObjectId[consumer_id],
                distributed_outputs, nothing)
        end
    end
    return true
end

Base.@nospecializeinfer @noinline function newborn_binding_sequence_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    fields = fieldnames(SequenceCounters)
    counters = NamedTuple{fields}(Tuple(state === nothing ? 0 : getfield(state.counts, field)
        for field in fields))
    return (enabled=state !== nothing, counters,
        details_enabled=state !== nothing && state.details,
        misses=state === nothing ? Dict{Symbol,Int}() : copy(state.misses),
        per_input=state === nothing ? NamedTuple[] : [(application=key[1], input=key[2], executions=count)
            for (key, count) in sort!(collect(state.per_input); by=first)],
        base_program=NBP.newborn_binding_program_report(model),
        counter_scope=:actual_fixed_aggregate_counts_with_optional_detail_dictionaries,
        sequence_scope=:weak_logical_application_identity_per_full_compilation,
        singleton_proof=:one_inferred_candidate_fixed_local_port_and_current_global_target,
        cached_bindings=false, cached_source_membership=false, cached_defaults=false,
        fallback=:ordinary_consumer_before_mutation_or_ordinary_operation_in_place)
end

end # module
