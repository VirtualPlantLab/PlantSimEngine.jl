"""
    VariableContract(; unit, basis=nothing, temporal=nothing,
                       aggregation=nothing, extent=nothing)

Scientific meaning attached to a model variable without wrapping its runtime
numeric value.

- `unit` names the physical numerator unit, for example `:mol_photon`.
- `basis` names the normalization basis, for example `:leaf_area`,
  `:ground_area`, or `:plant`.
- `temporal` names the time basis, for example `:second`, `:day`, or `:step`.
- `aggregation` distinguishes values such as `:instantaneous`, `:rate`,
  `:mean`, `:total`, and `:accumulated`.
- `extent` distinguishes `:intensive` and `:extensive` quantities when useful.

Tokens are intentionally open `Symbol`s so packages can extend the vocabulary.
The compiler compares complete contracts exactly; two connected model
variables must therefore use the same tokens. Runtime payloads remain ordinary
numbers or arrays.
"""
struct VariableContract
    unit::Symbol
    basis::Union{Nothing,Symbol}
    temporal::Union{Nothing,Symbol}
    aggregation::Union{Nothing,Symbol}
    extent::Union{Nothing,Symbol}
end

function VariableContract(
    ;
    unit,
    basis=nothing,
    temporal=nothing,
    aggregation=nothing,
    extent=nothing,
)
    fields = (
        unit=unit,
        basis=basis,
        temporal=temporal,
        aggregation=aggregation,
        extent=extent,
    )
    for (name, value) in pairs(fields)
        value isa Symbol || (name != :unit && isnothing(value)) || throw(
            ArgumentError(
                "VariableContract `$(name)` must be a Symbol" *
                (name == :unit ? "." : " or `nothing`."),
            ),
        )
    end
    return VariableContract(unit, basis, temporal, aggregation, extent)
end

"""
    variable_contracts_(model::AbstractModel)

Trait declaring the scientific contracts of status and environment variables
used by `model`. Return a named tuple whose keys are variables declared by
`inputs_`, `outputs_`, `environment_inputs_`, or `environment_outputs_`, and
whose values are [`VariableContract`](@ref)s. A model that produces values only
through distributed output groups may also declare those names; each compiled
`ModelSpec` must then include them in `outputs_to`.

The default is empty for incremental adoption. Once either side of a compiled
model-to-model input binding declares a contract, the other side must declare
the same complete contract. This prevents a contracted variable from silently
falling back to name-only coupling.
"""
variable_contracts_(::AbstractModel) = NamedTuple()
variable_contracts_(::Missing) = NamedTuple()

"""
    variable_contracts(model)

Return the structurally validated variable-contract declaration for `model`.
Compilation additionally checks each key against the concrete ModelSpec,
including its distributed output declarations.
"""
variable_contracts(model::Union{AbstractModel,Missing}) =
    _variable_contract_schema(model)

function _declared_contract_variable_names(model)
    declared = Set{Symbol}()
    union!(declared, Symbol.(keys(_input_schema(model))))
    union!(declared, Symbol.(keys(outputs_(model))))
    union!(declared, Symbol.(keys(environment_inputs_(model))))
    union!(declared, Symbol.(keys(environment_outputs_(model))))
    return declared
end

_validate_variable_contract_names(model, schema) = schema

@noinline function _invalid_variable_contract_schema_error(model, message)
    error("`variable_contracts_($(typeof(model)))` $(message)")
end

function _variable_contract_schema(model)
    schema = variable_contracts_(model)
    schema isa NamedTuple || return _invalid_variable_contract_schema_error(
        model,
        "must return a NamedTuple of `VariableContract` values; got " *
        "`$(typeof(schema))`.",
    )
    invalid_values = Pair{Symbol,Any}[
        Symbol(name) => value for (name, value) in pairs(schema)
        if !(value isa VariableContract)
    ]
    isempty(invalid_values) || return _invalid_variable_contract_schema_error(
        model,
        "must contain only `VariableContract` values. Invalid declaration(s): " *
        join(
            ["`$(name)=$(repr(value))`" for (name, value) in invalid_values],
            ", ",
        ) * ".",
    )
    return _validate_variable_contract_names(model, schema)
end

function _variable_contract(model, variable::Symbol)
    contracts = _variable_contract_schema(model)
    variable in keys(contracts) || return nothing
    return contracts[variable]
end

function _contract_fields(contract::VariableContract)
    return (
        unit=contract.unit,
        basis=contract.basis,
        temporal=contract.temporal,
        aggregation=contract.aggregation,
        extent=contract.extent,
    )
end

function _contract_mismatches(
    producer::VariableContract,
    consumer::VariableContract,
)
    producer_fields = _contract_fields(producer)
    consumer_fields = _contract_fields(consumer)
    return Tuple(
        name => (producer=producer_fields[name], consumer=consumer_fields[name])
        for name in keys(producer_fields)
        if producer_fields[name] != consumer_fields[name]
    )
end

function _validate_model_variable_contract!(
    consumer_application,
    input::Symbol,
    producer_application,
    source_variable::Symbol,
)
    consumer_model = consumer_application.spec
    producer_model = producer_application.spec
    consumer_contract = _variable_contract(consumer_model, input)
    producer_contract = _variable_contract(producer_model, source_variable)
    isnothing(consumer_contract) && isnothing(producer_contract) && return nothing

    if isnothing(consumer_contract)
        error(
            "Input `$(input)` on application `$(consumer_application.id)` is bound " *
            "to contracted output `$(source_variable)` from application " *
            "`$(producer_application.id)`, but the consumer declares no contract. " *
            "Add `$(input)=VariableContract(...)` to " *
            "`variable_contracts_($(typeof(model_(consumer_model))))`.",
        )
    end
    if isnothing(producer_contract)
        error(
            "Input `$(input)` on application `$(consumer_application.id)` declares " *
            "a VariableContract, but source output `$(source_variable)` from " *
            "application `$(producer_application.id)` declares none. Add " *
            "`$(source_variable)=VariableContract(...)` to " *
            "`variable_contracts_($(typeof(model_(producer_model))))`.",
        )
    end

    mismatches = _contract_mismatches(producer_contract, consumer_contract)
    isempty(mismatches) && return nothing
    error(
        "Incompatible variable contracts for input `$(input)` on application " *
        "`$(consumer_application.id)` and output `$(source_variable)` from " *
        "application `$(producer_application.id)`: " *
        join(
            [
                "$(name) producer=$(repr(values.producer)), " *
                "consumer=$(repr(values.consumer))"
                for (name, values) in mismatches
            ],
            "; ",
        ) * ". Rename or convert the variable at an explicit model boundary.",
    )
end
