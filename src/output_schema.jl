"""
    Distributed(Default(value))
    Distributed(Required(T))

Declare an output in `outputs_` that is stored on destination objects
selected by [`OutputTo`](@ref). The execution object receives this field only
if it is itself selected as a destination.
`Default(value)` initializes an absent destination field; `Required(T)`
requires a compatible field to exist already. The declaration contains no
scale or destination-group name.

```julia
PlantSimEngine.outputs_(::MyLightModel) = (
    incident_par=Distributed(Default(0.0)),
    absorbed_par=Distributed(Required(Real)),
)
```
"""
struct Distributed{D}
    declaration::D

    function Distributed(declaration)
        _is_input_declaration(declaration) || throw(ArgumentError(
            "`Distributed` requires `Default(value)` or `Required(T)`; got " *
            "`$(repr(declaration))`.",
        ))
        return new{typeof(declaration)}(declaration)
    end
end

function _output_schema(model)
    schema = outputs_(model)
    schema isa NamedTuple || throw(ArgumentError(
        "`outputs_($(typeof(model)))` must return a NamedTuple; got `$(typeof(schema))`.",
    ))
    return schema
end

function _local_output_schema(model)
    schema = _output_schema(model)
    any(value -> value isa Distributed, values(schema)) || return schema
    names = Tuple(name for name in keys(schema) if !(schema[name] isa Distributed))
    return NamedTuple{names}(map(name -> schema[name], names))
end

function _distributed_output_schema(model)
    schema = _output_schema(model)
    names = Tuple(name for name in keys(schema) if schema[name] isa Distributed)
    return NamedTuple{names}(map(name -> schema[name].declaration, names))
end

_output_value_type(value) = typeof(value)
_output_value_type(value::Distributed) = _input_expected_type(value.declaration)
