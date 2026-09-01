"""
    ValidationDiagnostic

Stable diagnostic returned by the public authoring validation API. `context`
contains structured identities supplied by the underlying compiler, such as an
application, object, variable, or validation field.
"""
struct ValidationDiagnostic
    code::Symbol
    severity::Symbol
    message::String
    context::Dict{String,Any}
    suggestions::Vector{String}
end

"""Exact parameter value captured from a concrete model instance."""
struct ModelParameterDescription
    name::Symbol
    declared_type::String
    value_type::String
    value::Any
    julia::String
    metadata::NamedTuple
end

"""Structured status or environment port declared by a model instance."""
struct ModelPortDescription
    name::Symbol
    role::Symbol
    declaration::Symbol
    expected_type::String
    initial_value::Any
    variable_contract::Union{Nothing,VariableContract}
end

"""Structured model-level `Input`, `Call`, or `Initializer` declaration."""
struct ModelDependencyDescription
    name::Symbol
    kind::Symbol
    selector::Any
    julia::String
end

"""
    ModelDescription

Versioned description of a model instance or type. Descriptions created from
an instance have `provenance == :exact`; descriptions requested from a type are
marked `:best_effort` and are complete only when a real zero-argument
constructor exists. `field_provenance` qualifies each part independently so
tooling never mistakes inferred source locations or best-effort constructor
metadata for exact model declarations. Type descriptions never invent
parameter values by dummy construction.
"""
struct ModelDescription
    schema_version::Int
    provenance::Symbol
    field_provenance::NamedTuple
    complete::Bool
    model_type::String
    name::Symbol
    module_name::String
    package::Union{Nothing,String}
    process_type::Union{Nothing,String}
    process::Symbol
    source_file::Union{Nothing,String}
    source_line::Union{Nothing,Int}
    parameters::Vector{ModelParameterDescription}
    interface::Union{Nothing,ModelInterface}
    ports::Vector{ModelPortDescription}
    dependencies::Vector{ModelDependencyDescription}
    traits::NamedTuple
    metadata::NamedTuple
    constructor::Dict{String,Any}
    diagnostics::Vector{ValidationDiagnostic}
end

const _EXACT_MODEL_FIELD_PROVENANCE = (
    model_type=:declared,
    name=:declared,
    var"module"=:declared,
    package=:inferred,
    process_type=:declared,
    process=:declared,
    source=:inferred,
    parameters=(values=:exact, metadata=:declared),
    interface=(instance=:exact, schemas=:declared, contracts=:declared, dependencies=:declared, traits=:declared),
    ports=(declarations=:declared, contracts=:declared),
    dependencies=:declared,
    traits=:declared,
    metadata=:declared,
    constructor=(fields=:declared, defaults=:unavailable, methods=:inferred),
)

const _ZERO_ARG_TYPE_FIELD_PROVENANCE = merge(
    _EXACT_MODEL_FIELD_PROVENANCE,
    (
        parameters=(values=:best_effort, metadata=:best_effort),
        interface=(instance=:best_effort, schemas=:best_effort, contracts=:best_effort, dependencies=:best_effort, traits=:best_effort),
        ports=(declarations=:best_effort, contracts=:best_effort),
        dependencies=:best_effort,
        traits=:best_effort,
        metadata=:best_effort,
        constructor=(fields=:declared, defaults=:best_effort, methods=:inferred),
    ),
)

const _INCOMPLETE_TYPE_FIELD_PROVENANCE = merge(
    _EXACT_MODEL_FIELD_PROVENANCE,
    (
        parameters=:unavailable,
        interface=:unavailable,
        ports=:unavailable,
        dependencies=:unavailable,
        traits=:unavailable,
        metadata=:unavailable,
        constructor=(fields=:declared, defaults=:unavailable, methods=:inferred),
    ),
)

"""One structured difference between two model implementations."""
struct ModelDifference
    path::String
    kind::Symbol
    left::Any
    right::Any
    affects_override::Bool
    affects_bindings::Bool
end

"""
    ModelComparison

Comparison of two concrete model instances. `override_compatible` is computed
from [`model_interface`](@ref), the same representation enforced by runtime
object and instance overrides. `requires_binding_changes` identifies port,
contract, dependency, output-policy, or environment-binding changes;
`requires_reconfiguration` also covers schedule-only trait differences.
"""
struct ModelComparison
    schema_version::Int
    left_type::String
    right_type::String
    same_process::Bool
    override_compatible::Bool
    requires_binding_changes::Bool
    requires_reconfiguration::Bool
    compatibility::Symbol
    differences::Vector{ModelDifference}
end

"""Typed result of structurally validating one model instance."""
struct ModelValidationReport
    schema_version::Int
    valid::Bool
    strict::Bool
    description::Union{Nothing,ModelDescription}
    diagnostics::Vector{ValidationDiagnostic}
end

"""
    ScenarioValidationReport

Typed, versioned validation result for a `CompositeModel`. `compilation`
retains the existing best-effort compilation report for Julia consumers;
[`Authoring.to_dict`](@ref) and [`Authoring.to_json`](@ref) serialize its stable summary and
diagnostics rather than compiler internals.
"""
struct ScenarioValidationReport
    schema_version::Int
    valid::Bool
    strict::Bool
    summary::NamedTuple
    diagnostics::Vector{ValidationDiagnostic}
    compilation::CompositeModelCompilationReport
end

"""
    model_metadata(model)

Optional author-declared model metadata. Downstream packages may return a
`NamedTuple` containing fields such as `summary`, `hypothesis`, `references`,
or `maturity`. PlantSimEngine does not infer scientific metadata.
"""
model_metadata(::AbstractModel) = NamedTuple()

"""
    parameter_metadata(model)

Optional metadata keyed by fields of `model`. Each value must be a `NamedTuple`;
authors may use fields such as `description`, `unit`, `domain`, `default`,
`reference`, or `constraints`. PlantSimEngine validates only the structure and
never invents scientific metadata or constructor defaults.
"""
parameter_metadata(::AbstractModel) = NamedTuple()

function _model_run_methods(::Type{T}) where {T<:AbstractModel}
    found = Method[]
    for method in methods(run!)
        signature = Base.unwrap_unionall(method.sig)
        parameters = signature.parameters
        length(parameters) >= 6 || continue
        model_argument = parameters[2]
        while model_argument isa TypeVar
            model_argument = model_argument.ub
        end
        model_argument isa Type || continue
        intersects = try
            typeintersect(T, model_argument) !== Union{}
        catch
            false
        end
        intersects && push!(found, method)
    end
    sort!(found; by=method -> begin
        signature = Base.unwrap_unionall(method.sig)
        isequal(signature.parameters[2], T) ? 0 : 1
    end)
    return found
end

function _model_source_location(::Type{T}) where {T<:AbstractModel}
    methods_ = _model_run_methods(T)
    isempty(methods_) && return nothing, nothing
    location = try
        Base.functionloc(first(methods_))
    catch
        nothing
    end
    isnothing(location) && return nothing, nothing
    file, line = location
    return string(file), Int(line)
end

function _validated_parameter_metadata(model::AbstractModel)
    metadata = parameter_metadata(model)
    metadata isa NamedTuple || error(
        "`parameter_metadata($(typeof(model)))` must return a NamedTuple; got " *
        "`$(typeof(metadata))`.",
    )
    model_fields = Set(fieldnames(typeof(model)))
    unknown = sort!(Symbol[name for name in keys(metadata) if name ∉ model_fields]; by=string)
    isempty(unknown) || error(
        "`parameter_metadata($(typeof(model)))` references unknown model field(s) " *
        "`$(Tuple(unknown))`.",
    )
    invalid = Pair{Symbol,Any}[
        Symbol(name) => value
        for (name, value) in pairs(metadata)
        if !(value isa NamedTuple)
    ]
    isempty(invalid) || error(
        "Each `parameter_metadata($(typeof(model)))` entry must be a NamedTuple. " *
        "Invalid entry or entries: `$(invalid)`.",
    )
    return metadata
end

function _model_parameters(model::AbstractModel)
    type = typeof(model)
    names = fieldnames(type)
    declared_types = fieldtypes(type)
    metadata = _validated_parameter_metadata(model)
    return ModelParameterDescription[
        ModelParameterDescription(
            Symbol(name),
            string(declared_types[index]),
            string(typeof(getfield(model, name))),
            getfield(model, name),
            repr(getfield(model, name)),
            get(metadata, name, NamedTuple()),
        )
        for (index, name) in pairs(names)
    ]
end

_model_constructor_type(type) = Base.typename(Base.unwrap_unionall(type)).wrapper

function _with_interface_provenance(interface::ModelInterface, provenance::Symbol)
    return ModelInterface(
        interface.schema_version,
        provenance,
        interface.process,
        interface.inputs,
        interface.outputs,
        interface.environment_inputs,
        interface.environment_outputs,
        interface.variable_contracts,
        interface.dependencies,
        interface.timespec,
        interface.output_policy,
        interface.timestep_hint,
        interface.environment_hint,
    )
end

"""
    model_interface(::Type{<:AbstractModel})

Return a best-effort interface only when the type has a real zero-argument
constructor. If it does not, pass the concrete model instance instead; this
method never constructs placeholder parameter values.
"""
function model_interface(::Type{T}) where {T<:AbstractModel}
    instance = _try_zero_arg_model(T)
    isnothing(instance) && throw(ArgumentError(
        "A concrete instance is required to inspect the interface of `$(T)`; " *
        "the type has no zero-argument constructor.",
    ))
    return _with_interface_provenance(model_interface(instance), :best_effort)
end

function _model_ports(model::AbstractModel)
    contracts = variable_contracts(model)
    ports = ModelPortDescription[]
    for (name_, declaration) in pairs(_input_schema(model))
        name = Symbol(name_)
        initial_value = declaration isa Default ? declaration.value : nothing
        push!(ports, ModelPortDescription(
            name,
            :input,
            declaration isa Required ? :required : :defaulted,
            string(_input_expected_type(declaration)),
            initial_value,
            haskey(contracts, name) ? contracts[name] : nothing,
        ))
    end
    for (role, declarations) in (
        :output => outputs_(model),
        :environment_input => environment_inputs_(model),
        :environment_output => environment_outputs_(model),
    )
        declarations isa NamedTuple || error(
            "`$(role)_($(typeof(model)))` must return a NamedTuple; got " *
            "`$(typeof(declarations))`.",
        )
        for (name_, initial_value) in pairs(declarations)
            name = Symbol(name_)
            push!(ports, ModelPortDescription(
                name,
                role,
                :initial,
                string(typeof(initial_value)),
                initial_value,
                haskey(contracts, name) ? contracts[name] : nothing,
            ))
        end
    end
    return ports
end

function _model_dependencies(model::AbstractModel)
    dependencies = dep(model)
    dependencies isa NamedTuple || error(
        "`dep($(typeof(model)))` must return a NamedTuple; got " *
        "`$(typeof(dependencies))`.",
    )
    result = ModelDependencyDescription[]
    for (name_, declaration) in pairs(dependencies)
        kind, selector = if declaration isa Input
            :input, declaration.selector
        elseif declaration isa Call
            :call, declaration.selector
        elseif declaration isa Initializer
            :initializer, declaration.selector
        else
            :invalid, declaration
        end
        push!(result, ModelDependencyDescription(
            Symbol(name_),
            kind,
            selector,
            repr(declaration),
        ))
    end
    return result
end

function _model_traits(model::AbstractModel)
    return (
        timespec=timespec(model),
        output_policy=output_policy(model),
        timestep_hint=timestep_hint(model),
        environment_hint=environment_hint(model),
    )
end

function _validated_model_metadata(model::AbstractModel)
    metadata = model_metadata(model)
    metadata isa NamedTuple || error(
        "`model_metadata($(typeof(model)))` must return a NamedTuple; got " *
        "`$(typeof(metadata))`.",
    )
    return metadata
end

"""
    describe_model(model::AbstractModel)
    describe_model(::Type{<:AbstractModel})

Describe a concrete instance exactly, including current parameter names, types,
and values. The type method is explicitly best-effort: it uses a real
zero-argument constructor when one exists and otherwise returns an incomplete
description with a diagnostic. `field_provenance` distinguishes exact model
declarations from inferred locations and constructor metadata. Neither method
creates a dummy parameter instance; the instance method never calls another
model constructor or relabels current parameter values as constructor defaults.
"""
function describe_model(model::AbstractModel)
    type = typeof(model)
    process_type = _process_type_for_model(type)
    module_ = parentmodule(type)
    source_file, source_line = _model_source_location(type)
    return ModelDescription(
        AUTHORING_SCHEMA_VERSION,
        :exact,
        _EXACT_MODEL_FIELD_PROVENANCE,
        true,
        string(type),
        nameof(type),
        string(module_),
        _model_package_name(module_),
        isnothing(process_type) ? nothing : string(process_type),
        process(model),
        source_file,
        source_line,
        _model_parameters(model),
        model_interface(model),
        _model_ports(model),
        _model_dependencies(model),
        _model_traits(model),
        _validated_model_metadata(model),
        _model_constructor_descriptor(_model_constructor_type(type), nothing),
        ValidationDiagnostic[],
    )
end

function describe_model(::Type{T}) where {T<:AbstractModel}
    instance = _try_zero_arg_model(T)
    if !isnothing(instance)
        exact = try
            describe_model(instance)
        catch err
            diagnostic = ValidationDiagnostic(
                :model_description_failed,
                :error,
                sprint(showerror, err),
                Dict("field" => "type", "modelType" => string(T)),
                ["Inspect a concrete instance with validate_model(model) to locate the invalid declaration."],
            )
            return _incomplete_type_description(T, diagnostic, instance)
        end
        return ModelDescription(
            exact.schema_version,
            :best_effort,
            _ZERO_ARG_TYPE_FIELD_PROVENANCE,
            exact.complete,
            exact.model_type,
            exact.name,
            exact.module_name,
            exact.package,
            exact.process_type,
            exact.process,
            exact.source_file,
            exact.source_line,
            exact.parameters,
            _with_interface_provenance(exact.interface, :best_effort),
            exact.ports,
            exact.dependencies,
            exact.traits,
            exact.metadata,
            _model_constructor_descriptor(T, instance),
            exact.diagnostics,
        )
    end

    diagnostic = ValidationDiagnostic(
        :model_instance_required,
        :warning,
        "An exact description of `$(T)` requires a concrete model instance.",
        Dict("field" => "instance"),
        ["Call describe_model with the parameterized model instance used by the scenario."],
    )
    return _incomplete_type_description(T, diagnostic, nothing)
end

function _incomplete_type_description(
    ::Type{T},
    diagnostic::ValidationDiagnostic,
    constructor_instance,
) where {T<:AbstractModel}
    module_ = parentmodule(T)
    process_type = _process_type_for_model(T)
    source_file, source_line = _model_source_location(T)
    return ModelDescription(
        AUTHORING_SCHEMA_VERSION,
        :best_effort,
        _INCOMPLETE_TYPE_FIELD_PROVENANCE,
        false,
        string(T),
        nameof(T),
        string(module_),
        _model_package_name(module_),
        isnothing(process_type) ? nothing : string(process_type),
        _process_name_for_type(T),
        source_file,
        source_line,
        ModelParameterDescription[],
        nothing,
        ModelPortDescription[],
        ModelDependencyDescription[],
        NamedTuple(),
        NamedTuple(),
        _model_constructor_descriptor(T, constructor_instance),
        [diagnostic],
    )
end

function _push_schema_differences!(
    differences,
    field::Symbol,
    left::NamedTuple,
    right::NamedTuple;
    affects_bindings::Bool,
)
    left_names = Tuple(Symbol.(keys(left)))
    right_names = Tuple(Symbol.(keys(right)))
    left_set = Set(left_names)
    right_set = Set(right_names)
    for name in sort!(collect(setdiff(left_set, right_set)); by=string)
        push!(differences, ModelDifference(
            string(field, ".", name),
            :removed,
            left[name],
            nothing,
            true,
            affects_bindings,
        ))
    end
    for name in sort!(collect(setdiff(right_set, left_set)); by=string)
        push!(differences, ModelDifference(
            string(field, ".", name),
            :added,
            nothing,
            right[name],
            true,
            affects_bindings,
        ))
    end
    for name in sort!(collect(intersect(left_set, right_set)); by=string)
        isequal(left[name], right[name]) && continue
        push!(differences, ModelDifference(
            string(field, ".", name),
            :changed,
            left[name],
            right[name],
            true,
            affects_bindings,
        ))
    end
    return differences
end

function _push_contract_differences!(differences, left::NamedTuple, right::NamedTuple)
    names = sort!(collect(union(Set(Symbol.(keys(left))), Set(Symbol.(keys(right))))); by=string)
    for name in names
        left_contract = haskey(left, name) ? left[name] : nothing
        right_contract = haskey(right, name) ? right[name] : nothing
        isequal(left_contract, right_contract) && continue
        kind = isnothing(left_contract) ? :added :
               isnothing(right_contract) ? :removed : :changed
        push!(differences, ModelDifference(
            string("variable_contracts.", name),
            kind,
            left_contract,
            right_contract,
            true,
            true,
        ))
    end
    return differences
end

function _push_interface_value_difference!(
    differences,
    path,
    left,
    right;
    affects_bindings::Bool,
)
    isequal(left, right) && return differences
    push!(differences, ModelDifference(
        String(path),
        :changed,
        left,
        right,
        true,
        affects_bindings,
    ))
    return differences
end

"""
    compare_models(left::AbstractModel, right::AbstractModel)

Compare two concrete implementations. The report distinguishes a direct
runtime override from a same-process alternative that requires scenario
reconfiguration, and from a model for a different process. Direct compatibility
uses the same complete [`ModelInterface`](@ref) enforced by runtime overrides:
full port schemas, contracts, dependencies, and compiled timing/environment
traits must all match.
"""
function compare_models(left::AbstractModel, right::AbstractModel)
    left_interface = model_interface(left)
    right_interface = model_interface(right)
    differences = ModelDifference[]

    if left_interface.process != right_interface.process
        push!(differences, ModelDifference(
            "process",
            :changed,
            left_interface.process,
            right_interface.process,
            true,
            true,
        ))
    end
    for field in (
        :inputs,
        :outputs,
        :environment_inputs,
        :environment_outputs,
    )
        _push_schema_differences!(
            differences,
            field,
            getfield(left_interface, field),
            getfield(right_interface, field),
            affects_bindings=true,
        )
    end
    _push_contract_differences!(
        differences,
        left_interface.variable_contracts,
        right_interface.variable_contracts,
    )
    _push_schema_differences!(
        differences,
        :dependencies,
        left_interface.dependencies,
        right_interface.dependencies,
        affects_bindings=true,
    )
    for (field, affects_bindings) in (
        :timespec => false,
        :output_policy => true,
        :timestep_hint => false,
        :environment_hint => true,
    )
        _push_interface_value_difference!(
            differences,
            string("traits.", field),
            getfield(left_interface, field),
            getfield(right_interface, field),
            affects_bindings=affects_bindings,
        )
    end

    same_process = left_interface.process == right_interface.process
    override_compatible = isequal(left_interface, right_interface)
    requires_binding_changes = any(difference -> difference.affects_bindings, differences)
    requires_reconfiguration = !override_compatible
    compatibility = override_compatible ? :direct_override :
                    same_process ? :same_process_requires_reconfiguration :
                    :different_process
    return ModelComparison(
        AUTHORING_SCHEMA_VERSION,
        string(typeof(left)),
        string(typeof(right)),
        same_process,
        override_compatible,
        requires_binding_changes,
        requires_reconfiguration,
        compatibility,
        differences,
    )
end

function _validation_diagnostic(
    code,
    error;
    field=nothing,
    severity=:error,
    suggestions=String[],
    context=Dict{String,Any}(),
)
    context_ = Dict{String,Any}(context)
    isnothing(field) || (context_["field"] = string(field))
    return ValidationDiagnostic(
        Symbol(code),
        Symbol(severity),
        error isa AbstractString ? String(error) : sprint(showerror, error),
        context_,
        String[String(item) for item in suggestions],
    )
end

function _capture_validation!(operation, diagnostics, code; kwargs...)
    try
        return operation()
    catch err
        push!(diagnostics, _validation_diagnostic(code, err; kwargs...))
        return nothing
    end
end

function _validate_named_model_declaration(model, name::Symbol, accessor)
    declaration = accessor(model)
    declaration isa NamedTuple || error(
        "`$(name)($(typeof(model)))` must return a NamedTuple; got " *
        "`$(typeof(declaration))`.",
    )
    return declaration
end

"""
    validate_model(model::AbstractModel; strict=false)

Validate a model's structural declarations without executing its scientific
kernel. With `strict=true`, every declared status and environment port must
have a `VariableContract`. The default remains incremental-adoption compatible.
"""
function validate_model(model::AbstractModel; strict::Bool=false)
    diagnostics = ValidationDiagnostic[]
    process_name = _capture_validation!(
        () -> begin
            value = process(model)
            value isa Symbol || error("`process(model)` must return a Symbol; got `$(typeof(value))`.")
            value
        end,
        diagnostics,
        :invalid_process;
        field=:process,
    )
    inputs = _capture_validation!(
        () -> _input_schema(model),
        diagnostics,
        :invalid_inputs;
        field=:inputs,
    )
    outputs = _capture_validation!(
        () -> _validate_named_model_declaration(model, :outputs_, outputs_),
        diagnostics,
        :invalid_outputs;
        field=:outputs,
    )
    environment_inputs = _capture_validation!(
        () -> _validate_named_model_declaration(
            model,
            :environment_inputs_,
            environment_inputs_,
        ),
        diagnostics,
        :invalid_environment_inputs;
        field=:environment_inputs,
    )
    environment_outputs = _capture_validation!(
        () -> _validate_named_model_declaration(
            model,
            :environment_outputs_,
            environment_outputs_,
        ),
        diagnostics,
        :invalid_environment_outputs;
        field=:environment_outputs,
    )
    contracts = _capture_validation!(
        () -> variable_contracts(model),
        diagnostics,
        :invalid_variable_contracts;
        field=:variable_contracts,
    )

    if !isnothing(contracts) && !(contracts isa NamedTuple)
        push!(diagnostics, _validation_diagnostic(
            :invalid_variable_contracts,
            "`variable_contracts($(typeof(model)))` must return a NamedTuple; got `$(typeof(contracts))`.";
            field=:variable_contracts,
        ))
        contracts = nothing
    end

    if !isnothing(contracts)
        declared = Set{Symbol}()
        for declaration in (inputs, outputs, environment_inputs, environment_outputs)
            isnothing(declaration) || union!(declared, Symbol.(keys(declaration)))
        end
        unbound = sort!(Symbol[name for name in keys(contracts) if name ∉ declared]; by=string)
        isempty(unbound) || push!(diagnostics, _validation_diagnostic(
            :unbound_variable_contract,
            "Variable contract(s) `$(Tuple(unbound))` are not model ports. They are valid only when a ModelSpec declares matching distributed outputs.";
            field=:variable_contracts,
            severity=:warning,
            suggestions=["Declare matching outputs_to variables in every ModelSpec using this model."],
        ))
        if strict
            missing = sort!(collect(setdiff(declared, Set(Symbol.(keys(contracts))))); by=string)
            isempty(missing) || push!(diagnostics, _validation_diagnostic(
                :missing_variable_contract,
                "Strict validation requires VariableContract declarations for `$(Tuple(missing))`.";
                field=:variable_contracts,
                suggestions=["Declare the scientific unit, basis, temporal meaning, aggregation, and extent explicitly."],
            ))
            for (name_, contract) in pairs(contracts)
                name = Symbol(name_)
                missing_fields = Symbol[
                    Symbol(field)
                    for (field, value) in pairs(_contract_fields(contract))
                    if isnothing(value)
                ]
                isempty(missing_fields) && continue
                push!(diagnostics, _validation_diagnostic(
                    :incomplete_variable_contract,
                    "Strict validation requires all five VariableContract fields for `$(name)`; missing `$(Tuple(missing_fields))`.";
                    field=:variable_contracts,
                    context=Dict{String,Any}(
                        "variable" => string(name),
                        "missingFields" => string.(missing_fields),
                    ),
                    suggestions=["Declare unit, basis, temporal, aggregation, and extent without inventing scientific meaning."],
                ))
            end
        end
    end

    dependencies = _capture_validation!(
        () -> begin
            declarations = dep(model)
            declarations isa NamedTuple || error(
                "`dep($(typeof(model)))` must return a NamedTuple; got `$(typeof(declarations))`.",
            )
            invalid = Pair{Symbol,Any}[
                Symbol(name) => declaration
                for (name, declaration) in pairs(declarations)
                if !(declaration isa Union{Input,Call,Initializer})
            ]
            isempty(invalid) || error(
                "`dep($(typeof(model)))` must contain only Input, Call, or Initializer declarations. Invalid declaration(s): `$(invalid)`.",
            )
            declarations
        end,
        diagnostics,
        :invalid_dependencies;
        field=:dependencies,
    )
    if !isnothing(dependencies) && !isnothing(inputs)
        unknown_inputs = sort!(Symbol[
            name for (name, declaration) in pairs(dependencies)
            if declaration isa Input && name ∉ keys(inputs)
        ]; by=string)
        isempty(unknown_inputs) || push!(diagnostics, _validation_diagnostic(
            :unknown_input_dependency,
            "Input dependencies `$(Tuple(unknown_inputs))` do not match inputs_ declarations.";
            field=:dependencies,
            suggestions=["Rename the dependency or declare the corresponding input port."],
        ))
    end

    _capture_validation!(
        () -> begin
            clock = timespec(model)
            clock isa ClockSpec || error("`timespec(model)` must return ClockSpec; got `$(typeof(clock))`.")
            float(clock.dt) > 0 || error("The model clock interval must be positive.")
            clock
        end,
        diagnostics,
        :invalid_timespec;
        field=:timespec,
    )
    _capture_validation!(
        () -> begin
            policies = output_policy(model)
            policies isa NamedTuple || error(
                "`output_policy(model)` must return a NamedTuple; got `$(typeof(policies))`.",
            )
            if !isnothing(outputs)
                unknown = setdiff(Set(Symbol.(keys(policies))), Set(Symbol.(keys(outputs))))
                isempty(unknown) || error(
                    "Output policies reference undeclared output(s) `$(Tuple(sort!(collect(unknown); by=string)))`.",
                )
            end
            for (name, policy) in pairs(policies)
                _as_schedule_policy(policy; context="output_policy for `$(name)`")
            end
            policies
        end,
        diagnostics,
        :invalid_output_policy;
        field=:output_policy,
    )
    if !isnothing(process_name)
        _capture_validation!(
            () -> _normalize_timestep_hint(:model, process_name, timestep_hint(model)),
            diagnostics,
            :invalid_timestep_hint;
            field=:timestep_hint,
        )
        _capture_validation!(
            () -> _normalize_environment_hint(:model, process_name, environment_hint(model)),
            diagnostics,
            :invalid_environment_hint;
            field=:environment_hint,
        )
    end
    _capture_validation!(
        () -> _validated_model_metadata(model),
        diagnostics,
        :invalid_model_metadata;
        field=:metadata,
    )
    _capture_validation!(
        () -> _validated_parameter_metadata(model),
        diagnostics,
        :invalid_parameter_metadata;
        field=:parameter_metadata,
    )
    isempty(_model_run_methods(typeof(model))) && push!(diagnostics, _validation_diagnostic(
        :missing_run_method,
        "No five-argument PlantSimEngine.run! kernel was found for `$(typeof(model))`.";
        field=:run!,
        suggestions=["Implement PlantSimEngine.run!(model, status, environment, constants, context)."],
    ))

    description = _capture_validation!(
        () -> describe_model(model),
        diagnostics,
        :model_description_failed;
        field=:description,
    )
    valid = all(diagnostic -> diagnostic.severity != :error, diagnostics)
    return ModelValidationReport(
        AUTHORING_SCHEMA_VERSION,
        valid,
        strict,
        description,
        diagnostics,
    )
end

function _validation_diagnostic(diagnostic::ModelGraphDiagnostic)
    return ValidationDiagnostic(
        diagnostic.code,
        diagnostic.severity,
        diagnostic.message,
        Dict{String,Any}(
            "phase" => string(diagnostic.phase),
            "applicationIds" => string.(diagnostic.application_ids),
            "objectIds" => _authoring_json_value(diagnostic.object_ids),
            "variable" => isnothing(diagnostic.variable) ? nothing : string(diagnostic.variable),
        ),
        copy(diagnostic.suggestions),
    )
end

function _scenario_model_groups(compilation)
    groups = IdDict{Any,Vector{Symbol}}()
    for application in compilation.applications
        model = _application_default_model(application)
        push!(get!(groups, model, Symbol[]), application.id)
        isnothing(application.model_overrides) && continue
        for replacement in values(application.model_overrides)
            application_ids = get!(groups, replacement, Symbol[])
            application.id in application_ids || push!(application_ids, application.id)
        end
    end
    return groups
end

"""
    validate_scenario(model::CompositeModel; strict=false)

Validate a scenario through the existing best-effort compiler and return its
partial result even when an application, binding, writer, or schedule is
invalid. `strict=true` additionally requires exact compiler acceptance and
strict validation of each resolved model instance.
"""
function validate_scenario(model::CompositeModel; strict::Bool=false)
    compilation = compile_model_report(model; strict=false)
    diagnostics = ValidationDiagnostic[
        _validation_diagnostic(diagnostic)
        for diagnostic in compilation.diagnostics
    ]

    if strict && all(diagnostic -> diagnostic.severity != :error, diagnostics)
        try
            compilation = compile_model_report(model; strict=true)
        catch err
            push!(diagnostics, _validation_diagnostic(
                :strict_compilation_failed,
                err;
                field=:scenario,
                suggestions=["Inspect the partial compilation diagnostics and correct the authored scenario."],
            ))
        end
    end

    if !isnothing(compilation.compiled)
        initialization = _capture_validation!(
            () -> explain_initialization(model),
            diagnostics,
            :initialization_inspection_failed;
            field=:initialization,
        )
        if !isnothing(initialization)
            for row in initialization
                row.disposition in (:required, :unresolved) || continue
                code = row.role == :environment_input ?
                       :unresolved_environment_input : :unresolved_required_input
                suggestions = isnothing(row.detail) ? String[] : [String(row.detail)]
                push!(diagnostics, ValidationDiagnostic(
                    code,
                    :error,
                    something(
                        row.detail,
                        "`$(row.variable)` is unresolved for application `$(row.application_id)`.",
                    ),
                    Dict{String,Any}(
                        "applicationIds" => [string(row.application_id)],
                        "objectIds" => [_authoring_json_value(row.object_id)],
                        "variable" => string(row.variable),
                        "role" => string(row.role),
                    ),
                    suggestions,
                ))
            end
        end
    end

    for (scenario_model, application_ids) in _scenario_model_groups(compilation)
        model_report = validate_model(scenario_model; strict=strict)
        for diagnostic in model_report.diagnostics
            context = copy(diagnostic.context)
            context["applicationIds"] = string.(application_ids)
            context["modelType"] = string(typeof(scenario_model))
            push!(diagnostics, ValidationDiagnostic(
                diagnostic.code,
                diagnostic.severity,
                diagnostic.message,
                context,
                copy(diagnostic.suggestions),
            ))
        end
    end

    summary = (
        application_count=length(compilation.applications),
        input_binding_count=length(compilation.input_bindings),
        call_binding_count=length(compilation.call_bindings),
        cycle_count=length(compilation.cycles),
        compiled=!isnothing(compilation.compiled),
    )
    valid = summary.compiled &&
            all(diagnostic -> diagnostic.severity != :error, diagnostics)
    return ScenarioValidationReport(
        AUTHORING_SCHEMA_VERSION,
        valid,
        strict,
        summary,
        diagnostics,
        compilation,
    )
end

function _authoring_json_value(value)
    value === nothing && return nothing
    value === missing && return nothing
    value isa Bool && return value
    value isa Integer && return value isa BigInt ? string(value) : value
    if value isa Union{Float16,Float32,Float64}
        return isfinite(value) ? value : string(value)
    end
    value isa Real && return string(value)
    value isa AbstractString && return String(value)
    value isa Symbol && return string(value)
    value isa Type && return string(value)
    value isa Module && return string(value)
    value isa ObjectId && return _authoring_json_value(value.value)
    value isa Required && return Dict{String,Any}(
        "kind" => "required",
        "expectedType" => string(_input_expected_type(value)),
    )
    value isa Default && return Dict{String,Any}(
        "kind" => "default",
        "valueType" => string(typeof(value.value)),
        "value" => _authoring_json_value(value.value),
    )
    value isa ClockSpec && return Dict{String,Any}(
        "dt" => _authoring_json_value(value.dt),
        "phase" => _authoring_json_value(value.phase),
    )
    value isa SchedulePolicy && return Dict{String,Any}(
        "kind" => string(nameof(typeof(value))),
        "fields" => Dict{String,Any}(
            string(name) => _authoring_json_value(getfield(value, name))
            for name in fieldnames(typeof(value))
        ),
    )
    value isa Union{Input,Call,Initializer} && return Dict{String,Any}(
        "kind" => string(nameof(typeof(value))),
        "selector" => _authoring_json_value(value.selector),
    )
    value isa Dates.Period && return string(value)
    value isa VariableContract && return Dict{String,Any}(
        string(name) => _authoring_json_value(field)
        for (name, field) in pairs(_contract_fields(value))
    )
    value isa Pair && return Dict{String,Any}(
        "first" => _authoring_json_value(first(value)),
        "second" => _authoring_json_value(last(value)),
    )
    if value isa NamedTuple || value isa AbstractDict
        return Dict{String,Any}(
            string(name) => _authoring_json_value(field)
            for (name, field) in pairs(value)
        )
    end
    if value isa AbstractSet
        return [_authoring_json_value(item) for item in sort!(collect(value); by=repr)]
    end
    if value isa Tuple || value isa AbstractArray
        return [_authoring_json_value(item) for item in value]
    end
    return repr(value)
end

function to_dict(interface::ModelInterface)
    return Dict{String,Any}(
        "schemaVersion" => interface.schema_version,
        "kind" => "modelInterface",
        "provenance" => string(interface.provenance),
        "process" => string(interface.process),
        "inputs" => _authoring_json_value(interface.inputs),
        "outputs" => _authoring_json_value(interface.outputs),
        "environmentInputs" => _authoring_json_value(interface.environment_inputs),
        "environmentOutputs" => _authoring_json_value(interface.environment_outputs),
        "variableContracts" => _authoring_json_value(interface.variable_contracts),
        "dependencies" => _authoring_json_value(interface.dependencies),
        "traits" => Dict{String,Any}(
            "timespec" => _authoring_json_value(interface.timespec),
            "outputPolicy" => _authoring_json_value(interface.output_policy),
            "timestepHint" => _authoring_json_value(interface.timestep_hint),
            "environmentHint" => _authoring_json_value(interface.environment_hint),
        ),
    )
end

"""
    to_dict(value)

Return the stable, JSON-compatible dictionary representation of an Authoring
description, comparison, diagnostic, or validation report.
"""
function to_dict(diagnostic::ValidationDiagnostic)
    return Dict{String,Any}(
        "code" => string(diagnostic.code),
        "severity" => string(diagnostic.severity),
        "message" => diagnostic.message,
        "context" => _authoring_json_value(diagnostic.context),
        "suggestions" => diagnostic.suggestions,
    )
end

function to_dict(parameter::ModelParameterDescription)
    return Dict{String,Any}(
        "name" => string(parameter.name),
        "declaredType" => parameter.declared_type,
        "valueType" => parameter.value_type,
        "value" => _authoring_json_value(parameter.value),
        "julia" => parameter.julia,
        "metadata" => _authoring_json_value(parameter.metadata),
    )
end

function to_dict(port::ModelPortDescription)
    return Dict{String,Any}(
        "name" => string(port.name),
        "role" => string(port.role),
        "declaration" => string(port.declaration),
        "expectedType" => port.expected_type,
        "initialValue" => _authoring_json_value(port.initial_value),
        "variableContract" => _authoring_json_value(port.variable_contract),
    )
end

function to_dict(dependency::ModelDependencyDescription)
    return Dict{String,Any}(
        "name" => string(dependency.name),
        "kind" => string(dependency.kind),
        "selector" => _authoring_json_value(dependency.selector),
        "julia" => dependency.julia,
    )
end

function to_dict(description::ModelDescription)
    source = isnothing(description.source_file) ? nothing : Dict{String,Any}(
        "file" => description.source_file,
        "line" => description.source_line,
    )
    return Dict{String,Any}(
        "schemaVersion" => description.schema_version,
        "kind" => "modelDescription",
        "provenance" => string(description.provenance),
        "fieldProvenance" => _authoring_json_value(description.field_provenance),
        "complete" => description.complete,
        "modelType" => description.model_type,
        "name" => string(description.name),
        "module" => description.module_name,
        "package" => description.package,
        "processType" => description.process_type,
        "process" => string(description.process),
        "source" => source,
        "parameters" => [to_dict(parameter) for parameter in description.parameters],
        "interface" => isnothing(description.interface) ? nothing :
                       to_dict(description.interface),
        "ports" => [to_dict(port) for port in description.ports],
        "dependencies" => [to_dict(dependency) for dependency in description.dependencies],
        "traits" => _authoring_json_value(description.traits),
        "metadata" => _authoring_json_value(description.metadata),
        "constructor" => _authoring_json_value(description.constructor),
        "diagnostics" => [to_dict(diagnostic) for diagnostic in description.diagnostics],
    )
end

function to_dict(difference::ModelDifference)
    return Dict{String,Any}(
        "path" => difference.path,
        "kind" => string(difference.kind),
        "left" => _authoring_json_value(difference.left),
        "right" => _authoring_json_value(difference.right),
        "affectsOverride" => difference.affects_override,
        "affectsBindings" => difference.affects_bindings,
    )
end

function to_dict(comparison::ModelComparison)
    return Dict{String,Any}(
        "schemaVersion" => comparison.schema_version,
        "kind" => "modelComparison",
        "leftType" => comparison.left_type,
        "rightType" => comparison.right_type,
        "sameProcess" => comparison.same_process,
        "overrideCompatible" => comparison.override_compatible,
        "requiresBindingChanges" => comparison.requires_binding_changes,
        "requiresReconfiguration" => comparison.requires_reconfiguration,
        "compatibility" => string(comparison.compatibility),
        "differences" => [to_dict(difference) for difference in comparison.differences],
    )
end

function to_dict(report::ModelValidationReport)
    return Dict{String,Any}(
        "schemaVersion" => report.schema_version,
        "kind" => "modelValidation",
        "valid" => report.valid,
        "strict" => report.strict,
        "description" => isnothing(report.description) ? nothing :
                         to_dict(report.description),
        "diagnostics" => [to_dict(diagnostic) for diagnostic in report.diagnostics],
    )
end

function to_dict(report::ScenarioValidationReport)
    return Dict{String,Any}(
        "schemaVersion" => report.schema_version,
        "kind" => "scenarioValidation",
        "valid" => report.valid,
        "strict" => report.strict,
        "summary" => _authoring_json_value(report.summary),
        "diagnostics" => [to_dict(diagnostic) for diagnostic in report.diagnostics],
    )
end

"""Return a JSON representation of any public Authoring description or report."""
to_json(value) = replace(JSON.json(to_dict(value)), "</" => "<\\/")
