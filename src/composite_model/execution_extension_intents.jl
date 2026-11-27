# Ephemeral staging metadata for the existing call-extension algorithm. These
# buffers never belong to the scene, runtime store, targets or call contexts.
struct AppendIntent{Rows,T}
    rows::Rows
    target::T
end

struct BindingIntent{CT,B}
    targets::CT
    binding::B
end

_prepared_intent_batch_container(::Type{<:PreparedExecutionBatchSchema{BT}}) where {BT} = BT

# Pure type recipe. Initializers keep their binding update, but cannot append
# manual-call batches: their actual execution_batches is the genuine empty ().
function _execution_extension_intent_layout(::Type{C}) where {C<:Tuple}
    _validate_prepared_context_calls(C)
    append_types = Any[]
    binding_types = Any[]
    append_cases = Any[]
    for CT in fieldtypes(C)
        B = fieldtype(CT, :binding)
        Binding = BindingIntent{CT,B}
        Binding in binding_types || push!(binding_types, Binding)
        _prepared_call_mode(B) === :initializer && continue
        BT = _prepared_intent_batch_container(fieldtype(CT, :batch_schema))
        for Batch in _prepared_execution_batch_types(BT)
            Rows = fieldtype(Batch, :targets)
            Target = eltype(Rows)
            Intent = AppendIntent{Rows,Target}
            Intent in append_types || push!(append_types, Intent)
            case = (CT, B, Rows, Target)
            case in append_cases || push!(append_cases, case)
        end
    end
    return (; append_types, binding_types, append_cases)
end

_execution_append_intent_buffer(::OpenContextCallSchema) = Tuple{Any,Any}[]
_execution_binding_intent_buffer(::OpenContextCallSchema) = Tuple{Any,Any}[]
@generated function _execution_append_intent_buffer(::PreparedContextCallSchema{C}) where {C}
    types = _execution_extension_intent_layout(C).append_types
    return :(Vector{$(Union{types...})}())
end
@generated function _execution_binding_intent_buffer(::PreparedContextCallSchema{C}) where {C}
    types = _execution_extension_intent_layout(C).binding_types
    return :(Vector{$(Union{types...})}())
end

@inline function _execution_extension_binding_owner_matches(targets, binding)
    return isequal(_execution_call_owner(targets.binding), _execution_call_owner(binding))
end

# Closed admission also proves the real namespace, independent of matching
# target/row types. Distinct callers may have identical concrete target schemas.
@inline function _execution_extension_append_owner_matches(targets, binding, rows, target)
    storage = targets.temporal_streams
    storage isa RuntimeStorage || return false
    expected_owner = _execution_call_owner(binding)
    stored_owner = rows.cohort.owner
    stored_owner isa typeof(expected_owner) || return false
    return _execution_extension_binding_owner_matches(targets, binding) &&
           rows.store === storage.cohorts &&
           isequal(stored_owner::typeof(expected_owner), expected_owner) &&
           rows.cohort.application_id === target.context.application.id &&
           target.context.object_id == target.object_id &&
           target.context.temporal_streams === storage
end

@inline function _stage_execution_append!(buffer, ::OpenContextCallSchema,
    targets, binding, rows, target)
    push!(buffer, (rows, target))
    return true
end
@inline function _stage_execution_binding!(buffer, ::OpenContextCallSchema, targets, binding)
    push!(buffer, (targets, binding))
    return true
end

@generated function _stage_execution_append!(buffer, ::PreparedContextCallSchema{C},
    targets, binding, rows, target) where {C}
    branches = Expr[]
    for (CT, B, Rows, T) in _execution_extension_intent_layout(C).append_cases
        Intent = AppendIntent{Rows,T}
        push!(branches, quote
            if targets isa $CT && binding isa $B && rows isa $Rows && target isa $T
                _execution_extension_append_owner_matches(targets, binding, rows, target) || return false
                push!(buffer, $Intent(rows::$Rows, target::$T))
                return true
            end
        end)
    end
    return quote
        $(branches...)
        return false
    end
end

@generated function _stage_execution_binding!(buffer, ::PreparedContextCallSchema{C},
    targets, binding) where {C}
    branches = Expr[]
    for Intent in _execution_extension_intent_layout(C).binding_types
        CT, B = fieldtypes(Intent)
        push!(branches, quote
            if targets isa $CT && binding isa $B
                _execution_extension_binding_owner_matches(targets, binding) || return false
                push!(buffer, $Intent(targets::$CT, binding::$B))
                return true
            end
        end)
    end
    return quote
        $(branches...)
        return false
    end
end

@inline _with_execution_append_intent(f, ::OpenContextCallSchema, intent) = f(intent[1], intent[2])
@inline _with_execution_binding_intent(f, ::OpenContextCallSchema, intent) = f(intent[1], intent[2])
@generated function _with_execution_append_intent(f, ::PreparedContextCallSchema{C}, intent) where {C}
    branches = [:(intent isa $I && return f(intent.rows, intent.target))
        for I in _execution_extension_intent_layout(C).append_types]
    return quote
        $(branches...)
        throw(ArgumentError("An append intent is outside its prepared call schema."))
    end
end
@generated function _with_execution_binding_intent(f, ::PreparedContextCallSchema{C}, intent) where {C}
    branches = [:(intent isa $I && return f(intent.targets, intent.binding))
        for I in _execution_extension_intent_layout(C).binding_types]
    return quote
        $(branches...)
        throw(ArgumentError("A binding intent is outside its prepared call schema."))
    end
end

@inline function _execution_binding_commit_admitted(::PreparedContextCallSchema,
    targets::CT, binding, compiled, environment_bindings) where {CT}
    return binding isa fieldtype(CT, :binding) &&
           compiled isa fieldtype(CT, :compiled) &&
           environment_bindings isa fieldtype(CT, :environment_bindings) &&
           _execution_extension_binding_owner_matches(targets, binding)
end

@inline _preflight_execution_binding_intents(::OpenContextCallSchema, bindings, compiled, environment_bindings) = true
function _preflight_execution_binding_intents(scope::PreparedContextCallSchema,
    bindings, compiled, environment_bindings)
    for intent in bindings
        admitted = _with_execution_binding_intent(scope, intent) do targets, binding
            _execution_binding_commit_admitted(scope, targets, binding, compiled, environment_bindings)
        end
        admitted || return false
    end
    return true
end

# Stage callers retain the compiler's unique application/owner/object order.
# All live-row checks AND all binding/stamp type checks precede the first write.
# This is schema admission, not rollback for a later unexpected runtime error.
function _commit_execution_call_extension!(scope, appends, bindings, compiled, environment_bindings)
    _preflight_execution_binding_intents(scope, bindings, compiled, environment_bindings) || return false
    for intent in appends
        _with_execution_append_intent(scope, intent) do rows, target
            _check_execution_cohort_append(rows, target)
        end
    end
    for intent in appends
        _with_execution_append_intent(scope, intent) do rows, target
            _append_execution_cohort_target!(rows, target)
        end
    end
    for intent in bindings
        _with_execution_binding_intent(scope, intent) do targets, binding
            targets.binding = binding
            _record_extended_call_execution_batch_cache!(targets, compiled, environment_bindings, binding)
        end
    end
    return true
end

# The dictionary keeps the outer tuple erased. Prove the complete target field
# schema before staging, so the final assignment/signature also stay concrete.
@inline _admitted_current_execution_call_bindings(::OpenContextCallSchema, target, bindings) = bindings
@generated function _admitted_current_execution_call_bindings(::PreparedContextCallSchema,
    target::T, bindings) where {T<:CompiledExecutionTarget}
    B = fieldtype(T, :call_bindings)
    return :(bindings isa $B ? bindings::$B : nothing)
end

# Admit every current declaration before constructing any replacement child.
# A later incompatible binding must not fail after an earlier child owner writes.
@inline _preflight_current_execution_calls(::OpenContextCallSchema, calls, bindings, compiled, environment_bindings) = true
@generated function _preflight_current_execution_calls(scope::PreparedContextCallSchema{C},
    calls::C, bindings::Tuple, compiled, environment_bindings) where {C}
    _validate_prepared_context_calls(C)
    checks = Expr[]
    for (index, CT) in enumerate(fieldtypes(C))
        B = fieldtype(CT, :binding)
        value = gensym(:binding)
        push!(checks, :($value = getfield(bindings, $index)))
        push!(checks, :($value isa $B || return false))
        push!(checks, :(_execution_binding_commit_admitted(scope, getfield(calls, $index),
            $value::$B, compiled, environment_bindings) || return false))
    end
    return quote
        length(bindings) == $(fieldcount(C)) || return false
        $(checks...)
        return true
    end
end

@inline _with_current_execution_call(f, ::OpenContextCallSchema, calls::Tuple,
    bindings::Tuple, index::Int) = f(calls[index], bindings[index])
@generated function _with_current_execution_call(f, ::PreparedContextCallSchema{C},
    calls::C, bindings::Tuple, index::Int) where {C}
    _validate_prepared_context_calls(C)
    branches = Expr[]
    for (slot, CT) in enumerate(fieldtypes(C))
        B = fieldtype(CT, :binding)
        push!(branches, quote
            if index == $slot
                binding = getfield(bindings, $slot)
                binding isa $B || throw(ArgumentError("A current call binding is outside its admitted context schema."))
                return f(getfield(calls, $slot), binding::$B)
            end
        end)
    end
    return quote
        length(bindings) == $(fieldcount(C)) || throw(ArgumentError("The current call count differs from its admitted context schema."))
        $(branches...)
        throw(BoundsError(calls, index))
    end
end

function _execution_call_batches_match_applications(schema, batches, application_ids)
    for raw_batch in batches
        matches = _with_execution_batch(schema, raw_batch) do batch
            batch.application.id in application_ids
        end
        matches || return false
    end
    return true
end

function _execution_call_batches_for_application(schema, application_schema, batches, application_id)
    selected = _execution_batch_buffer(application_schema)
    for raw_batch in batches
        _with_execution_batch(schema, raw_batch) do batch
            batch.application.id == application_id || return nothing
            _with_execution_batch(application_schema, batch) do admitted
                push!(selected, admitted)
            end
            return nothing
        end
    end
    return selected
end

# Keep the running count in this typed operation. The outer loop receives only
# a scalar result, avoiding a captured mutable counter across batch callbacks.
function _execution_call_prefix_end(schema, raw_batch, current_ids, previous_count,
    changed_target_ids, application_id)
    return _with_execution_batch(schema, raw_batch) do batch
        count = previous_count
        for execution_target in batch.targets
            count += 1
            count <= length(current_ids) || return nothing
            execution_target.object_id == current_ids[count] || return nothing
            (application_id, execution_target.object_id) in changed_target_ids && return nothing
        end
        return count
    end
end
