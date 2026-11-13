struct ScenarioPreparationFailure{E,B}
    phase::Symbol
    application_id::Union{Nothing,Symbol}
    error::E
    backtrace::B
end

# Diagnostic exceptions may reference Modules/method frames. Keep the original
# exception and an independent trace while copying scientific owners normally.
function Base.deepcopy_internal(failure::ScenarioPreparationFailure, stack::IdDict)
    return get!(stack, failure) do
        ScenarioPreparationFailure(failure.phase, failure.application_id,
            failure.error, copy(failure.backtrace))
    end
end

# Diagnostic failures retain their original payload; only the cold throw
# operand crosses the inference boundary.
Base.@noinline Base.@nospecializeinfer function _throw_preparation_error(@nospecialize(exception))
    throw(exception)
end

struct AuthoredPortNames{NAMES} end
AuthoredPortNames(names::Tuple{Vararg{Symbol}}) = AuthoredPortNames{names}()
_authored_port_names(::AuthoredPortNames{NAMES}) where {NAMES} = NAMES
_authored_port_names(failure::ScenarioPreparationFailure) = _throw_preparation_error(failure.error)

struct AuthoredOutputPorts{ALL,LOCAL,DISTRIBUTED,CANONICAL} end
function AuthoredOutputPorts(all_names, local_names, distributed_names, canonical_names)
    return AuthoredOutputPorts{all_names,local_names,distributed_names,canonical_names}()
end
_output_all_names(::AuthoredOutputPorts{ALL}) where {ALL} = ALL
_output_local_names(::AuthoredOutputPorts{ALL,LOCAL}) where {ALL,LOCAL} = LOCAL
_output_distributed_names(::AuthoredOutputPorts{ALL,LOCAL,DISTRIBUTED}) where {ALL,LOCAL,DISTRIBUTED} = DISTRIBUTED
_output_canonical_names(::AuthoredOutputPorts{ALL,LOCAL,DISTRIBUTED,CANONICAL}) where {ALL,LOCAL,DISTRIBUTED,CANONICAL} = CANONICAL
@inline function Base.getproperty(ports::AuthoredOutputPorts, name::Symbol)
    name === :all_names && return _output_all_names(ports)
    name === :local_names && return _output_local_names(ports)
    name === :distributed_names && return _output_distributed_names(ports)
    name === :canonical_names && return _output_canonical_names(ports)
    return getfield(ports, name)
end
Base.propertynames(::AuthoredOutputPorts) = (:all_names, :local_names, :distributed_names, :canonical_names)

# One stable owner is shared by the authored recipe and compiled application.
# Name and type carriers preserve declarations without retaining initialization values.
mutable struct AuthoredPortInventory{I,O,IT,OT,OET,EI,EO,C}
    const inputs::I
    const outputs::O
    const input_types::IT
    const output_types::OT
    const output_element_types::OET
    const environment_inputs::EI
    const environment_outputs::EO
    const contracts::C
end
@inline function Base.getproperty(ports::AuthoredPortInventory, name::Symbol)
    name === :input_names && return _authored_port_names(getfield(ports, :inputs))
    name === :environment_input_names && return _authored_port_names(getfield(ports, :environment_inputs))
    name === :environment_output_names && return _authored_port_names(getfield(ports, :environment_outputs))
    return getfield(ports, name)
end
Base.propertynames(ports::AuthoredPortInventory) =
    (fieldnames(typeof(ports))..., :input_names, :environment_input_names, :environment_output_names)

_authored_metadata_value(value) = value
_authored_metadata_value(failure::ScenarioPreparationFailure) = _throw_preparation_error(failure.error)

function _capture_authored_metadata(operation, phase::Symbol, application_id::Union{Nothing,Symbol})
    try
        return operation()
    catch error
        error isa InterruptException && rethrow()
        return ScenarioPreparationFailure(phase, application_id, error, catch_backtrace())
    end
end

function _authored_output_ports(spec::ModelSpec, schema::NamedTuple)
    all_names = Tuple(Symbol(name) for name in keys(schema))
    local_names = Tuple(Symbol(name) for name in keys(schema) if !(schema[name] isa Distributed))
    distributed_names = Tuple(Symbol(name) for name in keys(schema) if schema[name] isa Distributed)
    canonical_names = Tuple(name for name in local_names
        if _publish_mode_for_output(spec, name) === :canonical)
    return AuthoredOutputPorts(all_names, local_names, distributed_names, canonical_names)
end

# Preparation retains the exact declaration types in the existing inventory.
# Explicit Type{T} fields prevent NamedTuple construction from widening them to
# DataType/UnionAll; later factories can read the witnesses from the owner type.
function _authored_port_types(type_for, schema::NamedTuple{Names}) where {Names}
    types = map(type_for, values(schema))
    fields = Tuple{map(T -> Type{T}, types)...}
    return NamedTuple{Names,fields}(types)
end

# Only real numeric-array defaults have element evidence. Missing fields mean
# no initializer value (e.g. Required), whereas Tuple{} means a real empty array.
_output_element_types(value) = nothing
_output_element_types(value::Distributed) = _output_element_types(value.declaration)
_output_element_types(value::Default) = _output_element_types(value.value)
function _output_element_types(value::Array{T}) where {T<:Number}
    isempty(value) && return Tuple{}
    isconcretetype(T) && return Tuple{T}
    types = DataType[]
    for element in value
        element_type = typeof(element)
        element_type in types || push!(types, element_type)
    end
    return Tuple{types...}
end

function _authored_output_element_types(schema::NamedTuple{Names}) where {Names}
    types = map(_output_element_types, values(schema))
    names = Tuple(Names[index] for index in eachindex(Names) if !isnothing(types[index]))
    selected = NamedTuple{names}(Tuple(T for T in types if !isnothing(T)))
    return _authored_port_types(identity, selected)
end

function _prepare_authored_ports(spec::ModelSpec, application_id::Symbol)
    # This is the constructor's existing output read. A failed output hook
    # retains its existing top-level authoring failure and application recovery.
    output_schema = _output_schema(spec)
    output_ports = _authored_output_ports(spec, output_schema)
    output_types = _authored_port_types(_output_value_type, output_schema)
    output_element_types = _authored_output_element_types(output_schema)
    model = model_(spec)
    input_metadata = _capture_authored_metadata(:input_ports, application_id) do
        schema = _input_schema(model)
        (AuthoredPortNames(Tuple(Symbol(name) for name in keys(schema))),
            _authored_port_types(_input_expected_type, schema))
    end
    inputs, input_types = if input_metadata isa ScenarioPreparationFailure
        input_metadata, input_metadata
    else
        input_metadata
    end
    environment_inputs = _capture_authored_metadata(:environment_input_ports, application_id) do
        AuthoredPortNames(Tuple(Symbol(name) for name in keys(environment_inputs_(model))))
    end
    environment_outputs = _capture_authored_metadata(:environment_output_ports, application_id) do
        AuthoredPortNames(Tuple(Symbol(name) for name in keys(environment_outputs_(model))))
    end
    declared_contracts = _capture_authored_metadata(:variable_contracts, application_id) do
        _variable_contract_declarations(spec)
    end
    # Shape validation precedes declared-name reads even for empty contracts.
    # Keep original failures so later phases rethrow without a callback.
    failed_names = findfirst(result -> result isa ScenarioPreparationFailure,
        (inputs, environment_inputs, environment_outputs))
    contracts = if declared_contracts isa ScenarioPreparationFailure
        declared_contracts
    elseif !isnothing(failed_names)
        (inputs, environment_inputs, environment_outputs)[failed_names]
    else
        _capture_authored_metadata(:variable_contract_names, application_id) do
            declared = Set{Symbol}(_authored_port_names(inputs))
            union!(declared, output_ports.local_names, output_ports.distributed_names,
                _authored_port_names(environment_inputs), _authored_port_names(environment_outputs))
            _validate_variable_contract_names(spec, declared_contracts, declared)
        end
    end
    return AuthoredPortInventory(inputs, output_ports, input_types, output_types,
        output_element_types, environment_inputs, environment_outputs, contracts)
end
