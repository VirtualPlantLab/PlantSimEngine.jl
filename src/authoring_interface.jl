const AUTHORING_SCHEMA_VERSION = 1

"""
    ModelInterface

Versioned representation of every model declaration that the compiler takes
from the base application when it installs an object or instance override.
Two model instances are directly override-compatible when their semantic
fields are equal. `provenance` records whether the declarations were read from
the supplied instance (`:exact`) or from a real zero-argument instance created
for type-only inspection (`:best_effort`); it does not change compatibility.
"""
struct ModelInterface
    schema_version::Int
    provenance::Symbol
    process::Symbol
    inputs::NamedTuple
    outputs::NamedTuple
    environment_inputs::NamedTuple
    environment_outputs::NamedTuple
    variable_contracts::NamedTuple
    dependencies::NamedTuple
    timespec::Any
    output_policy::Any
    timestep_hint::Any
    environment_hint::Any
end

function _model_interface_semantics(interface::ModelInterface)
    named_semantics(declaration) = Tuple(
        name => declaration[name]
        for name in sort!(collect(Symbol.(keys(declaration))); by=string)
    )
    return (
        interface.schema_version,
        interface.process,
        named_semantics(interface.inputs),
        named_semantics(interface.outputs),
        named_semantics(interface.environment_inputs),
        named_semantics(interface.environment_outputs),
        named_semantics(interface.variable_contracts),
        named_semantics(interface.dependencies),
        interface.timespec,
        named_semantics(interface.output_policy),
        interface.timestep_hint,
        interface.environment_hint,
    )
end

Base.isequal(left::ModelInterface, right::ModelInterface) =
    isequal(_model_interface_semantics(left), _model_interface_semantics(right))
Base.:(==)(left::ModelInterface, right::ModelInterface) = isequal(left, right)
Base.hash(interface::ModelInterface, seed::UInt) =
    hash(_model_interface_semantics(interface), seed)

function _authoring_named_declaration(model, name::Symbol, value)
    value isa NamedTuple || error(
        "`$(name)($(typeof(model)))` must return a NamedTuple; got " *
        "`$(typeof(value))`.",
    )
    return value
end

"""
    model_interface(model::AbstractModel)

Return the exact public interface enforced when `model` is used as an object or
instance override. This method reads the supplied instance; it never creates a
dummy model or guesses parameter values.

The interface includes the full status and environment schemas, scientific
contracts, model-level dependencies, clock, output policy, timestep hint, and
environment hint because object overrides execute behind declarations compiled
from the base application.
"""
function model_interface(model::AbstractModel)
    process_name = process(model)
    outputs = _authoring_named_declaration(model, :outputs_, outputs_(model))
    return ModelInterface(
        AUTHORING_SCHEMA_VERSION,
        :exact,
        process_name,
        _input_schema(model),
        outputs,
        _authoring_named_declaration(
            model,
            :environment_inputs_,
            environment_inputs_(model),
        ),
        _authoring_named_declaration(
            model,
            :environment_outputs_,
            environment_outputs_(model),
        ),
        variable_contracts(model),
        _authoring_named_declaration(model, :dep, dep(model)),
        timespec(model),
        _authoring_named_declaration(model, :output_policy, output_policy(model)),
        timestep_hint(model),
        environment_hint(model),
    )
end
