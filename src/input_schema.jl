"""
    Required(T)

Declare a status input that must be supplied by object state or resolved from
another model application.

`T` is an expected type, not an initialization value. It may be abstract or
parametric so model declarations remain generic.
"""
struct Required{T} end

Required(T::Type) = Required{T}()

"""
    Default(value)

Declare a status input with a genuine model-provided default. The compiler adds
`value` to a target object's status only when the variable is neither supplied
by the user nor already present.
"""
struct Default{T}
    value::T
end

_is_input_declaration(value) = value isa Union{Required,Default}
@generated function _has_only_input_declarations(
    declarations::NamedTuple{names,types},
) where {names,types}
    checks = [
        fieldtype(types, index) <: Union{Required,Default} ?
        :(true) :
        :(_is_input_declaration(getfield(declarations, $index)))
        for index in eachindex(names)
    ]
    isempty(checks) && return :(true)
    return foldr((left, right) -> :($left && $right), checks)
end

_input_expected_type(::Required{T}) where {T} = T
_input_expected_type(declaration::Default) = typeof(declaration.value)

_has_input_default(::Required) = false
_has_input_default(::Default) = true

function _input_default(declaration::Default)
    return declaration.value
end

_private_initial_value(value) = deepcopy(value)

@noinline function _invalid_input_schema_error(model, schema)
    context = "`inputs_($(typeof(model)))`"
    schema isa NamedTuple || error(
        context,
        " must return a `NamedTuple` of `Required(T)` and `Default(value)` declarations; ",
        "got `$(typeof(schema))`.",
    )
    invalid = Pair{Symbol,Any}[
        Symbol(name) => value
        for (name, value) in pairs(schema)
        if !_is_input_declaration(value)
    ]
    isempty(invalid) || error(
        context,
        " must make every input explicit with `Required(T)` or `Default(value)`. ",
        "Invalid declaration(s): ",
        join(
            ["`$(name)=$(repr(value))`" for (name, value) in invalid],
            ", ",
        ),
        ".",
    )
    error("Invalid input schema.")
end

@inline _input_schema(model) = _validated_input_schema(model, inputs_(model))

@inline function _validated_input_schema(model, schema::NamedTuple)
    _has_only_input_declarations(schema) ||
        return _invalid_input_schema_error(model, schema)
    return schema
end

@noinline _validated_input_schema(model, schema) =
    _invalid_input_schema_error(model, schema)

function _input_default_values(schema::NamedTuple)
    pairs_ = Pair{Symbol,Any}[]
    for (name, declaration) in pairs(schema)
        declaration isa Default || continue
        push!(pairs_, Symbol(name) => declaration.value)
    end
    return (; pairs_...)
end
