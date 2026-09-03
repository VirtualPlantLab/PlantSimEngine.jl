struct StatusConversionPolicy{R,F}
    rules::R
    transform::F
end

struct StatusConversionRecord
    variable::Symbol
    object_id
    application_id
    origin::Symbol
    declared_type
    original_type
    transformed_type
    effective_type
    transform_applied::Bool
    transform_changed::Bool
    mapping_applied::Bool
    mapping_changed::Bool
    mapping_rule
    storage_changed::Bool
    original_value
    effective_value
end

_no_status_conversion(policy::StatusConversionPolicy) =
    isempty(policy.rules) && isnothing(policy.transform)

function _normalize_status_type_rules(type_promotion)
    isnothing(type_promotion) && return ()
    type_promotion isa AbstractDict || error(
        "`type_promotion` must be an `AbstractDict` mapping source types to " *
        "target types, or `nothing`; got `$(typeof(type_promotion))`.",
    )
    normalized = Pair{Any,Any}[]
    sizehint!(normalized, length(type_promotion))
    for (source, target) in pairs(type_promotion)
        source isa Type || error(
            "`type_promotion` source keys must be types; got `$(repr(source))` " *
            "with type `$(typeof(source))`.",
        )
        target isa Type || error(
            "`type_promotion` target values must be types; got `$(repr(target))` " *
            "with type `$(typeof(target))` for source `$(source)`.",
        )
        push!(normalized, source => target)
    end
    sort!(normalized; by=rule -> (string(first(rule)), string(last(rule))))
    _validate_status_type_rule_overlaps(normalized)
    return Tuple(normalized)
end

function _validate_status_type_rule_overlaps(rules)
    for left_index in eachindex(rules)
        left = first(rules[left_index])
        for right_index in (left_index + 1):lastindex(rules)
            right = first(rules[right_index])
            (left <: right || right <: left) && continue
            overlap = typeintersect(left, right)
            overlap === Union{} && continue
            any(rule -> first(rule) === overlap, rules) && continue
            error(
                "Ambiguous `type_promotion` rules: source types `$(left)` and " *
                "`$(right)` overlap at `$(overlap)` but neither is more specific. " *
                "Add an exact rule for the overlap or remove one source type.",
            )
        end
    end
    return rules
end

function _status_conversion_policy(type_promotion, status_transform)
    return StatusConversionPolicy(
        _normalize_status_type_rules(type_promotion),
        status_transform,
    )
end

_status_conversion_rules(model) = model.status_conversion.rules
_status_transform(model) = model.status_conversion.transform

function _status_conversion_context(; object_id=nothing, application_id=nothing, origin=:unknown)
    parts = String["status variable"]
    isnothing(object_id) || push!(parts, "on object `$(ObjectId(object_id).value)`")
    isnothing(application_id) || push!(parts, "for application `$(application_id)`")
    origin === :unknown || push!(parts, "from `$(origin)`")
    return join(parts, " ")
end

function _matching_status_type_rule_for_type(rules, value_type)
    matches = Pair{Any,Any}[
        rule for rule in rules
        if value_type <: first(rule)
    ]
    isempty(matches) && return nothing

    exact = Pair{Any,Any}[rule for rule in matches if first(rule) === value_type]
    length(exact) == 1 && return only(exact)
    length(exact) > 1 && error(
        "Internal error: duplicate exact `type_promotion` rules for `$(value_type)`.",
    )

    most_specific = Pair{Any,Any}[]
    for candidate in matches
        candidate_source = first(candidate)
        shadowed = any(matches) do other
            other === candidate && return false
            other_source = first(other)
            return other_source <: candidate_source &&
                   !(candidate_source <: other_source)
        end
        shadowed || push!(most_specific, candidate)
    end
    length(most_specific) == 1 && return only(most_specific)
    sources = join(sort!(string.(first.(most_specific))), ", ")
    error(
        "Ambiguous `type_promotion` rules for value type `$(value_type)`: " *
        "$(sources). Add an exact rule for `$(value_type)` or remove an " *
        "overlapping source type.",
    )
end


_matching_status_type_rule(rules, value) =
    _matching_status_type_rule_for_type(rules, typeof(value))

function _convert_numeric_array_elements(rules, value::Array{<:Number}; context)
    if isempty(value)
        rule = _matching_status_type_rule_for_type(rules, eltype(value))
        isnothing(rule) && return value, false, nothing
        target = last(rule)
        isconcretetype(target) || error(
            "Failed to apply `type_promotion` to $(context): the element target " *
            "type `$(target)` must be concrete for an empty numeric array.",
        )
        return similar(value, target), target !== eltype(value), rule
    end

    converted_values = Vector{Any}(undef, length(value))
    applied_rules = Pair{Any,Any}[]
    changed = false
    for (position, index) in enumerate(eachindex(value))
        converted, element_changed, rule = _convert_status_type_rules(
            rules,
            value[index];
            context="$(context) at numeric-array index `$(index)`",
        )
        converted_values[position] = converted
        changed |= element_changed
        isnothing(rule) || push!(applied_rules, rule)
    end
    changed || return value, false, nothing

    effective_eltype = foldl(
        typejoin,
        (typeof(element) for element in converted_values),
    )
    converted_array = similar(value, effective_eltype)
    for (index, converted) in zip(eachindex(converted_array), converted_values)
        converted_array[index] = converted
    end
    unique!(applied_rules)
    applied_rule = length(applied_rules) == 1 ?
                   only(applied_rules) :
                   Tuple(applied_rules)
    return converted_array, true, applied_rule
end

function _convert_status_type_rules(rules, value; context)
    rule = _matching_status_type_rule(rules, value)
    if !isnothing(rule)
        source, target = rule
        converted = try
            convert(target, value)
        catch exception
            error(
                "Failed to apply `type_promotion` to $(context): cannot convert " *
                "`$(typeof(value))` to `$(target)` using rule `$(source) => " *
                "$(target)`: $(sprint(showerror, exception))",
            )
        end
        changed = converted !== value || typeof(converted) !== typeof(value)
        return converted, changed, source => target
    end

    value isa Array{<:Number} || return value, false, nothing
    return _convert_numeric_array_elements(rules, value; context=context)
end

function _transform_status_value(transform, variable::Symbol, value; context)
    isnothing(transform) && return value, false
    applicable(transform, variable, value) || error(
        "`status_transform` is not callable as `(variable, value)` for $(context) " *
        "`$(variable)` with value type `$(typeof(value))`.",
    )
    transformed = try
        transform(variable, value)
    catch exception
        error(
            "Failed to apply `status_transform` to $(context) `$(variable)` with " *
            "value type `$(typeof(value))`: $(sprint(showerror, exception))",
        )
    end
    return transformed, transformed !== value || typeof(transformed) !== typeof(value)
end

function _convert_status_value(
    policy::StatusConversionPolicy,
    variable::Symbol,
    value;
    object_id=nothing,
    application_id=nothing,
    origin=:unknown,
)
    context = _status_conversion_context(
        ; object_id=object_id, application_id=application_id, origin=origin,
    )
    transformed, transformed_changed = _transform_status_value(
        policy.transform,
        variable,
        value;
        context=context,
    )
    converted, mapped_changed, rule = _convert_status_type_rules(
        policy.rules,
        transformed;
        context="$(context) `$(variable)`",
    )
    return converted, (
        transformed=transformed,
        transform_applied=!isnothing(policy.transform),
        transform_changed=transformed_changed,
        mapping_applied=!isnothing(rule),
        mapping_changed=mapped_changed,
        mapping_rule=rule,
        storage_changed=transformed_changed || mapped_changed,
    )
end

function _status_conversion_record_key(
    variable::Symbol;
    object_id=nothing,
    application_id=nothing,
    origin=:unknown,
)
    return (Symbol(origin), application_id, object_id, variable)
end

function _cached_status_materialization(record, value, private_copy::Bool)
    record isa StatusConversionRecord || return nothing
    record.original_type === typeof(value) || return nothing
    isequal(record.original_value, value) || return nothing
    effective = private_copy ?
                _private_initial_value(record.effective_value) :
                record.effective_value
    return effective, record.storage_changed, record.mapping_rule
end

function _materialize_status_value(
    model,
    variable::Symbol,
    value;
    object_id=nothing,
    application_id=nothing,
    origin=:unknown,
    private_copy::Bool=false,
    reuse::Bool=false,
    declared_type=typeof(value),
    conversion_records=model.status_conversion_records,
)
    if _no_status_conversion(model.status_conversion)
        initial = private_copy ? _private_initial_value(value) : value
        return initial, false, nothing
    end
    key = _status_conversion_record_key(
        variable;
        object_id=object_id,
        application_id=application_id,
        origin=origin,
    )
    if reuse
        cached = _cached_status_materialization(
            get(conversion_records, key, nothing),
            value,
            private_copy,
        )
        isnothing(cached) || return cached
    end

    original_snapshot = reuse ? _private_initial_value(value) : nothing
    initial = private_copy ? _private_initial_value(value) : value
    effective, details = _convert_status_value(
        model.status_conversion,
        variable,
        initial;
        object_id=object_id,
        application_id=application_id,
        origin=origin,
    )
    conversion_records[key] = StatusConversionRecord(
        variable,
        object_id,
        application_id,
        Symbol(origin),
        declared_type,
        typeof(value),
        typeof(details.transformed),
        typeof(effective),
        details.transform_applied,
        details.transform_changed,
        details.mapping_applied,
        details.mapping_changed,
        details.mapping_rule,
        details.storage_changed,
        original_snapshot,
        reuse ? _private_initial_value(effective) : nothing,
    )
    return effective, details.storage_changed, details.mapping_rule
end

function _convert_registered_status(model, object_id, status)
    status isa Status || return status
    _no_status_conversion(model.status_conversion) && return status
    names = propertynames(status)
    changed = false
    references = ntuple(length(names)) do index
        variable = names[index]
        reference = refvalue(status, variable)
        converted, variable_changed, _ = _materialize_status_value(
            model,
            variable,
            reference[];
            object_id=object_id,
            origin=:supplied_status,
        )
        changed |= variable_changed
        return variable_changed ? Ref(converted) : reference
    end
    return changed ? Status(NamedTuple{names}(references)) : status
end
