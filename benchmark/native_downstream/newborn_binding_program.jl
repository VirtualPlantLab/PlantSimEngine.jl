module NewbornBindingProgram

using PlantSimEngine
const PSE = PlantSimEngine
for name in (:_prepare_newborn_binding_program!, :_try_newborn_binding_instruction!)
    isdefined(PSE, name) || error("Newborn binding programs require the optional core hooks")
end

export enable_newborn_binding_program!, newborn_binding_program_report

const _DEFAULT_INSTANCE_POLICY = which(PSE.output_policy, Tuple{PSE.AbstractModel})
const _DEFAULT_TYPE_POLICY = which(PSE.output_policy, Tuple{Type{PSE.AbstractModel}})

struct ScalarInstruction
    slot::Int
    application_slot::Int
    application_id::Symbol
    input::Symbol
    source_var::Symbol
    origin::Symbol
    producer::Union{Nothing,Symbol}
    policy_proof::Symbol
    selector_snapshot::Any
    matcher_snapshot::Any
    process_filter::Union{Nothing,Symbol}
    application_filter::Union{Nothing,Symbol}
    policy_token::Symbol
end

# Weak application identities are the logical compilation epoch. Partial
# targeted shells are resolved through the passed global by-id table. A full
# compilation registers new application identities; old live simulations may
# retain their own programs. Values contain only fixed scalar instructions and
# recursively immutable selector/matcher declaration snapshots: no models,
# resolved source memberships, bindings, defaults, or canonical references.
struct BindingProgram
    world::UInt
    applications::Dict{Symbol,WeakRef}
    instructions::Dict{Int,ScalarInstruction}
end

mutable struct ProgramState
    programs::WeakKeyDict{Any,BindingProgram}
    declaration_proofs::Dict{Tuple{Any,UInt},Any}
    counts::Dict{Symbol,Int}
    misses::Dict{Symbol,Int}
    compile_skips::Dict{Symbol,Int}
    per_input::Dict{Tuple{Symbol,Symbol},Int}
    delta::WeakRef
    added_cursor::Int
    added_ids::Set{PSE.ObjectId}
end
ProgramState() = ProgramState(WeakKeyDict{Any,BindingProgram}(), Dict{Tuple{Any,UInt},Any}(),
    Dict{Symbol,Int}(), Dict{Symbol,Int}(), Dict{Symbol,Int}(),
    Dict{Tuple{Symbol,Symbol},Int}(), WeakRef(nothing), 0, Set{PSE.ObjectId}())
const _enabled = WeakKeyDict{Any,ProgramState}()

function enable_newborn_binding_program!(model::PSE.CompositeModel)
    haskey(_enabled, model) && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable newborn binding programs before initial logical compilation"))
    _enabled[model] = ProgramState()
    return model
end

_count!(state, name, amount=1) = (state.counts[name] = get(state.counts, name, 0) + amount)
function _miss!(state, reason, resolved=nothing)
    state.misses[reason] = get(state.misses, reason, 0) + 1
    if resolved !== nothing
        _count!(state, :resolved_fallbacks)
        return resolved
    end
    return false
end

function _is_core_policy_method(method)
    return method.module === PSE && endswith(replace(String(method.file), '\\' => '/'),
        "/processes/models_inputs_outputs.jl")
end

Base.@nospecializeinfer @noinline function _core_default_policy(application)
    @nospecialize application
    model_type = typeof(PSE._application_default_model(application))
    return _is_core_policy_method(_DEFAULT_INSTANCE_POLICY) &&
        _is_core_policy_method(_DEFAULT_TYPE_POLICY) &&
        which(PSE.output_policy, Tuple{model_type}) === _DEFAULT_INSTANCE_POLICY &&
        which(PSE.output_policy, Tuple{Type{model_type}}) === _DEFAULT_TYPE_POLICY
end

Base.@nospecializeinfer @noinline function _immutable_metadata(value, depth=0)
    @nospecialize value
    depth <= 16 || return false
    value isa Union{Symbol,String,Type} && return true
    isbits(value) && return true
    ismutabletype(typeof(value)) && return false
    for index in 1:fieldcount(typeof(value))
        isdefined(value, index) || return false
        _immutable_metadata(getfield(value, index), depth + 1) || return false
    end
    return true
end

function _policy_token(selector)
    PSE._selector_has_policy(selector) || return :absent
    raw = PSE._selector_policy(selector)
    return raw isa PSE.HoldLast ? :holdlast_instance :
        raw === PSE.HoldLast ? :holdlast_type : :unsupported
end

Base.@nospecializeinfer @noinline function _declaration_proof!(state, model_type)
    @nospecialize model_type
    world = Base.get_world_counter()
    key = (model_type, world)
    old = get(state.declaration_proofs, key, nothing)
    if old !== nothing
        _count!(state, :declaration_proof_hits)
        return old
    end
    _count!(state, :declaration_proofs_built)
    # Type/effect inference does not execute the declaration on a live model.
    # Both strict bits must be ALWAYS_TRUE; conditional effects do not qualify.
    inferred = Base.promote_op(PSE.outputs_, model_type)
    effects = Base.infer_effects(PSE.outputs_, Tuple{model_type}; world)
    always = getfield(parentmodule(typeof(effects)), :ALWAYS_TRUE)
    stable = effects.consistent == always && effects.effect_free == always && effects.nothrow
    fixed = inferred isa DataType && inferred <: NamedTuple && isconcretetype(inferred) &&
        inferred.parameters[1] isa Tuple
    proof = stable && fixed ? (reason=:proved,
        names=inferred.parameters[1], field_types=fieldtypes(inferred)) :
        (reason=stable ? :output_names_not_concrete : :output_declaration_effects,
            names=(), field_types=())
    state.declaration_proofs[key] = proof
    return proof
end

Base.@nospecializeinfer @noinline function _instruction(state, plan, applications_by_id)
    @nospecialize plan applications_by_id
    selector = plan.selector
    selector isa PSE.One || return (nothing, :non_one_selector)
    isnothing(plan.window) || return (nothing, :temporal_window)
    _immutable_metadata(selector) && _immutable_metadata(plan.matcher) ||
        return (nothing, :mutable_selector_metadata)
    from_status = PSE._selector_from_status(selector)
    if from_status
        # The ordinary validated plan forbids policy/window/producer filters.
        return ScalarInstruction(plan.slot, plan.application_slot, plan.application_id,
            plan.input, plan.source_var, plan.origin, nothing, :live_status,
            selector, plan.matcher, plan.process, plan.application, _policy_token(selector)), :eligible
    end
    length(plan.potential_source_application_ids) == 1 || return (nothing, :nonunique_producer)
    producer = only(plan.potential_source_application_ids)
    source = get(applications_by_id, producer, nothing)
    source === nothing && return (nothing, :missing_producer)
    # Match the ordinary `_local_output_schema(source.spec)` declaration entry,
    # including the normal ModelSpec/ObjectModelOverrides delegation. This also
    # keeps a pre-existing custom ModelSpec declaration on the guarded path.
    proof = _declaration_proof!(state, typeof(source.spec))
    proof.reason === :proved || return (nothing, proof.reason)
    position = findfirst(==(plan.source_var), proof.names)
    position === nothing && return (nothing, :nonlocal_source_port)
    typeintersect(proof.field_types[position], PSE.Distributed) === Union{} ||
        return (nothing, :distributed_or_unknown_port_type)
    PSE._publish_mode_for_output(source.spec, plan.source_var) === :canonical ||
        return (nothing, :stream_only_source)
    policy_proof = if PSE._selector_has_policy(selector)
        raw = PSE._selector_policy(selector)
        raw isa PSE.HoldLast || raw === PSE.HoldLast || return (nothing, :non_holdlast_policy)
        :explicit_holdlast
    else
        # A custom instance/type output_policy may depend on mutable parameters.
        # Even when it currently returns HoldLast, leave it to the ordinary path.
        _core_default_policy(source) || return (nothing, :custom_output_policy)
        :core_default_holdlast
    end
    return ScalarInstruction(plan.slot, plan.application_slot, plan.application_id,
        plan.input, plan.source_var, plan.origin, producer, policy_proof,
        selector, plan.matcher, plan.process, plan.application, _policy_token(selector)), :eligible
end

Base.@nospecializeinfer @noinline function PSE._prepare_newborn_binding_program!(
    model::PSE.CompositeModel, applications, plans_by_application,
    applications_by_id, distributed_outputs,
)
    @nospecialize model applications plans_by_application applications_by_id distributed_outputs
    state = get(_enabled, model, nothing)
    state === nothing && return nothing
    collection_world = Base.get_world_counter()
    instructions = Dict{Int,ScalarInstruction}()
    weak_applications = Dict{Symbol,WeakRef}()
    for application in applications
        weak_applications[application.id] = WeakRef(application)
        for plan in PSE._application_plans(plans_by_application, application.slot)
            instruction, reason = try
                _instruction(state, plan, applications_by_id)
            catch error
                error isa Union{InterruptException,OutOfMemoryError,StackOverflowError} && rethrow()
                # Optional compilation cannot move a normal binding error ahead
                # of earlier consumers. Let the ordinary code diagnose it later.
                (nothing, :metadata_not_supported)
            end
            if instruction === nothing
                state.compile_skips[reason] = get(state.compile_skips, reason, 0) + 1
            else
                instructions[plan.slot] = instruction
                _count!(state, :instructions_compiled)
            end
        end
    end
    # A declaration method introduced during collection must not bless an
    # earlier certificate with its newer world. Runtime equality rejects that
    # program and preserves the ordinary path until the next full compilation.
    program = BindingProgram(collection_world, weak_applications, instructions)
    for application in applications
        state.programs[application] = program
    end
    _count!(state, :programs_built)
    return nothing
end

function _same_header(op, plan)
    return op.slot == plan.slot && op.application_slot == plan.application_slot &&
        op.application_id === plan.application_id && op.input === plan.input &&
        op.source_var === plan.source_var && op.origin === plan.origin &&
        plan.selector isa PSE.One && isnothing(plan.window) &&
        plan.selector === op.selector_snapshot && plan.matcher === op.matcher_snapshot &&
        plan.process === op.process_filter && plan.application === op.application_filter &&
        _policy_token(plan.selector) === op.policy_token &&
        PSE._selector_from_status(plan.selector) === (op.producer === nothing) &&
        (op.producer === nothing ? isempty(plan.potential_source_application_ids) :
            length(plan.potential_source_application_ids) == 1 &&
                only(plan.potential_source_application_ids) === op.producer)
end

Base.@nospecializeinfer @noinline function _live_local_member(source, source_id, producer, applications_by_object)
    @nospecialize source applications_by_object
    first(PSE._sorted_object_id_position(getfield(source, :target_ids), source_id)) &&
        return true
    # The targeted initializer overlay can contain newborn membership before
    # the compiled global application's target vector is extended.
    for candidate in get(applications_by_object, source_id, ())
        candidate.id === producer && candidate.spec === source.spec && return true
    end
    return false
end

function _local_owner_proof(distributed, source_id, variable, producer)
    distributed isa PSE.NoCompiledDistributedOutputs && return true
    distributed isa PSE.CompiledDistributedOutputs || return false
    for owner in get(distributed.writer_ownership, (source_id, variable), ())
        owner.kind === :application_target && owner.application_id === producer &&
            owner.execution_object_id == source_id || return false
    end
    # An empty key is normal for targeted newborns before global extension.
    # Their live local/overlay membership was checked separately. Never cache
    # that absence: this per-field owner proof is repeated for every execution.
    return true
end

function _newborn_consumer!(state, model, consumer_id)
    model.binding_cache === nothing && return false
    delta = PSE.lifecycle_delta(model)
    if state.delta.value !== delta || length(delta.added) < state.added_cursor
        state.delta = WeakRef(delta)
        state.added_cursor = 0
        empty!(state.added_ids)
    end
    # LifecycleDelta.added is append-only; consumption replaces the delta object.
    # Each new ID is visited once even with an initializer after every insertion.
    for index in (state.added_cursor + 1):length(delta.added)
        push!(state.added_ids, delta.added[index].id)
    end
    state.added_cursor = length(delta.added)
    return consumer_id in state.added_ids
end

Base.@nospecializeinfer @noinline function PSE._try_newborn_binding_instruction!(
    bindings, model::PSE.CompositeModel, application::PSE.CompiledModelApplication,
    consumer_id::PSE.ObjectId, plan::PSE.CompiledModelInputPlan,
    applications_by_object, applications_by_id, source_ids_override,
    distributed_outputs, object_query_cache,
)
    @nospecialize bindings model application plan applications_by_object applications_by_id source_ids_override distributed_outputs object_query_cache
    state = get(_enabled, model, nothing)
    state === nothing && return false
    _count!(state, :instruction_attempts)
    logical = get(applications_by_id, application.id, nothing)
    logical === nothing && return _miss!(state, :logical_application_missing)
    program = get(state.programs, logical, nothing)
    program === nothing && return _miss!(state, :unregistered_program_epoch)
    program.world == Base.get_world_counter() || return _miss!(state, :method_world_changed)
    op = get(program.instructions, plan.slot, nothing)
    op === nothing && return _miss!(state, :unsupported_instruction)
    _same_header(op, plan) || return _miss!(state, :plan_header_changed)
    _count!(state, :instruction_cache_hits)
    source = nothing
    if op.producer !== nothing
        source = get(applications_by_id, op.producer, nothing)
        expected = get(program.applications, op.producer, nothing)
        source !== nothing && expected !== nothing && expected.value === source ||
            return _miss!(state, :producer_program_epoch_changed)
    end
    source_ids_override === nothing || source_ids_override isa Vector{PSE.ObjectId} ||
        return _miss!(state, :source_override_container)
    source_ids = source_ids_override === nothing ?
        PSE._cached_dependency_object_ids(object_query_cache, model, plan.selector,
            plan.matcher, consumer_id) : source_ids_override
    length(source_ids) == 1 || return _miss!(state, :resolved_source_count, source_ids)
    source_id = only(source_ids)
    if op.producer !== nothing
        _live_local_member(source, source_id, op.producer, applications_by_object) ||
            return _miss!(state, :live_source_membership, source_ids)
        _local_owner_proof(distributed_outputs, source_id, op.source_var, op.producer) ||
            return _miss!(state, :distributed_or_competing_owner, source_ids)
    end
    policy = PSE.HoldLast()
    PSE._validate_policy_instance(something(PSE._model_object(model, consumer_id).scale, :Default),
        application.process, op.input, policy)
    carrier = PSE._status_ref_or_nothing(PSE._model_object(model, source_id).status, op.source_var)
    carrier isa Ref || return _miss!(state, :canonical_reference_unavailable, source_ids)
    PSE._validate_model_input_source!(model, application, consumer_id, op.input,
        op.source_var, source_ids, carrier, :shared_ref)
    producer_ids = op.producer === nothing ? Symbol[] : Symbol[op.producer]
    push!(bindings, PSE.CompiledModelInputBinding(plan, consumer_id, source_ids,
        producer_ids, policy, :shared_ref, carrier))
    _count!(state, :instruction_executions)
    _count!(state, :synthesized_bindings)
    _count!(state, op.producer === nothing ? :status_instruction_executions : :producer_instruction_executions)
    if _newborn_consumer!(state, model, consumer_id)
        _count!(state, :newborn_positive_executions)
        _count!(state, op.producer === nothing ?
            :newborn_status_executions : :newborn_producer_executions)
        _count!(state, applications_by_object isa PSE._ApplicationsByObjectOverlay ?
            :newborn_targeted_executions : :newborn_global_refresh_executions)
    elseif model.binding_cache === nothing
        _count!(state, :initial_positive_executions)
    else
        _count!(state, :existing_positive_executions)
    end
    key = (op.application_id, op.input)
    state.per_input[key] = get(state.per_input, key, 0) + 1
    return true
end

Base.@nospecializeinfer @noinline function newborn_binding_program_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    fields = (:programs_built, :instructions_compiled, :instruction_attempts,
        :instruction_cache_hits, :instruction_executions, :synthesized_bindings,
        :newborn_positive_executions, :initial_positive_executions,
        :existing_positive_executions, :resolved_fallbacks,
        :declaration_proofs_built, :declaration_proof_hits,
        :status_instruction_executions, :producer_instruction_executions,
        :newborn_status_executions, :newborn_producer_executions,
        :newborn_targeted_executions, :newborn_global_refresh_executions)
    counters = NamedTuple{fields}(Tuple(state === nothing ? 0 : get(state.counts, field, 0)
        for field in fields))
    return (enabled=state !== nothing, counters,
        misses=state === nothing ? Dict{Symbol,Int}() : copy(state.misses),
        compile_skips=state === nothing ? Dict{Symbol,Int}() : copy(state.compile_skips),
        per_input=state === nothing ? NamedTuple[] : [(application=key[1], input=key[2], executions=count)
            for (key, count) in sort!(collect(state.per_input); by=first)],
        program_scope=:weak_logical_application_identity_per_full_compilation,
        optimized_operation=:scalar_canonical_HoldLast_binding_with_live_membership_and_reference,
        cached_bindings=false, cached_source_membership=false, cached_defaults=false,
        policy_safety=:explicit_HoldLast_or_core_default_output_policy_only,
        declaration_safety=:concrete_output_names_and_strict_consistent_effect_free_nothrow_proof,
        fallback=:ordinary_pipeline_with_resolved_ids_when_already_queried)
end

end # module
