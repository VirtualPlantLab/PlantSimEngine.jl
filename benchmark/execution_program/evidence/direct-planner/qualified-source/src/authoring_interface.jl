const AUTHORING_SCHEMA_VERSION = 1

"""
    ModelInterface

Versioned representation of the model contract enforced for object and instance
overrides. Local defaults remain exact; distributed defaults compare their
declaration kind and payload type because destination initialization uses the
effective model's value.
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

_model_declaration_semantics(value) = (kind=:value, value=value)
function _model_declaration_semantics(value::Distributed)
    declaration = value.declaration
    payload = declaration isa Default ?
              (kind=:default, type=typeof(declaration.value)) :
              (kind=:required, type=_input_expected_type(declaration))
    return (kind=:distributed, value=payload)
end

_model_named_declaration_semantics(declaration::NamedTuple) = Tuple(
    name => _model_declaration_semantics(declaration[name])
    for name in sort!(collect(Symbol.(keys(declaration))); by=string)
)

function _model_interface_semantics(interface::ModelInterface)
    return (
        interface.schema_version,
        interface.process,
        _model_named_declaration_semantics(interface.inputs),
        _model_named_declaration_semantics(interface.outputs),
        _model_named_declaration_semantics(interface.environment_inputs),
        _model_named_declaration_semantics(interface.environment_outputs),
        _model_named_declaration_semantics(interface.variable_contracts),
        _model_named_declaration_semantics(interface.dependencies),
        interface.timespec,
        _model_named_declaration_semantics(interface.output_policy),
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
from the base application. Distributed default values are retained for
inspection but excluded from compatibility: their kind and payload type must
match, while destination initialization reads the effective model's value.
"""
function model_interface(model::AbstractModel)
    process_name = process(model)
    outputs = _output_schema(model)
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
