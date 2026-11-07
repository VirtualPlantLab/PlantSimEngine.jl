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

struct AuthoredPortNames{NAMES} end
AuthoredPortNames(names::Tuple{Vararg{Symbol}}) = AuthoredPortNames{names}()
_authored_port_names(::AuthoredPortNames{NAMES}) where {NAMES} = NAMES
_authored_port_names(failure::ScenarioPreparationFailure) = throw(failure.error)

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
# Name carriers preserve static schemas without retaining initialization values.
mutable struct AuthoredPortInventory{I,O,EI,EO,C}
    const inputs::I
    const outputs::O
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
_authored_metadata_value(failure::ScenarioPreparationFailure) = throw(failure.error)

function _capture_authored_metadata(operation, phase::Symbol, application_id::Union{Nothing,Symbol})
    try
        return operation()
    catch error
        error isa InterruptException && rethrow()
        return ScenarioPreparationFailure(phase, application_id, error, catch_backtrace())
    end
end

function _authored_output_ports(spec::ModelSpec)
    schema = _output_schema(spec)
    all_names = Tuple(Symbol(name) for name in keys(schema))
    local_names = Tuple(Symbol(name) for name in keys(schema) if !(schema[name] isa Distributed))
    distributed_names = Tuple(Symbol(name) for name in keys(schema) if schema[name] isa Distributed)
    canonical_names = Tuple(name for name in local_names
        if _publish_mode_for_output(spec, name) === :canonical)
    return AuthoredOutputPorts(all_names, local_names, distributed_names, canonical_names)
end

function _prepare_authored_ports(spec::ModelSpec, application_id::Symbol)
    # This is the constructor's existing output read. A failed output hook
    # retains its existing top-level authoring failure and application recovery.
    output_ports = _authored_output_ports(spec)
    model = model_(spec)
    inputs = _capture_authored_metadata(:input_ports, application_id) do
        AuthoredPortNames(Tuple(Symbol(name) for name in keys(_input_schema(model))))
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
    return AuthoredPortInventory(inputs, output_ports, environment_inputs, environment_outputs, contracts)
end
