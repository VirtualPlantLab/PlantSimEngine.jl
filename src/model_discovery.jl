const _MODEL_PARAMETER_TYPE_CHOICES = (
    :float,
    :integer,
    :boolean,
    :symbol,
    :string,
    :nothing,
    :julia,
)

const _MODEL_DISCOVERY_EXCLUDED_NAMES = Set{Symbol}([
    :ObjectModelOverrides,
    :ModelSpec,
])

"""
    available_processes()

Return process abstract model types visible in the current Julia session.
Loading another package with `using PackageName` makes its process and model
types discoverable without a separate registry.
"""
function available_processes()
    processes = Type[]
    for type in _abstract_model_subtypes()
        _is_process_type(type) || continue
        push!(processes, type)
    end
    return sort!(unique(processes); by=type -> string(process_(type)))
end

"""
    available_models()
    available_models(process::Symbol)
    available_models(process_type::Type{<:AbstractModel})

Return concrete model implementation types visible in the current Julia
session.
"""
function available_models()
    models = Type[]
    for type in _abstract_model_subtypes()
        _is_available_model_type(type) || continue
        push!(models, type)
    end
    return sort!(unique(models); by=type -> string(_process_name_for_type(type), ".", nameof(type)))
end

available_models(process_name::Symbol) =
    filter(type -> _process_name_for_type(type) == process_name, available_models())

function available_models(process_type::Type{<:AbstractModel})
    process_name = _is_process_type(process_type) ?
                   process_(process_type) :
                   _process_name_for_type(process_type)
    return available_models(process_name)
end

"""
    model_descriptor(::Type{<:AbstractModel})

Return JSON-compatible discovery metadata for a model implementation type.
Input and output metadata is inferred best-effort from a zero-argument or dummy
instance when the type can be constructed safely.
"""
function model_descriptor(::Type{T}) where {T<:AbstractModel}
    process_type = _process_type_for_model(T)
    process_name = isnothing(process_type) ? nothing : process_(process_type)
    module_ = parentmodule(T)
    return Dict{String,Any}(
        "type" => string(T),
        "name" => string(nameof(T)),
        "module" => string(module_),
        "package" => _model_package_name(module_),
        "process" => isnothing(process_name) ? nothing : string(process_name),
        "processType" => isnothing(process_type) ? nothing : string(process_type),
        "inputs" => _model_var_descriptor(T, inputs_),
        "outputs" => _model_var_descriptor(T, outputs_),
        "environmentInputs" => _model_var_descriptor(T, meteo_inputs_),
        "environmentOutputs" => _model_var_descriptor(T, meteo_outputs_),
        "timespec" => _safe_string_trait(T, timespec),
        "outputPolicy" => _safe_string_trait(T, output_policy),
        "timestepHint" => _safe_string_trait(T, timestep_hint),
        "meteoHint" => _safe_string_trait(T, meteo_hint),
        "constructor" => model_constructor_descriptor(T),
    )
end

"""
    model_constructor_descriptor(::Type{<:AbstractModel})

Return constructor metadata inferred from struct fields and an optional
zero-argument constructor. Fields that share a type parameter share a type
choice in the editor.
"""
function model_constructor_descriptor(::Type{T}) where {T<:AbstractModel}
    unwrapped_type = Base.unwrap_unionall(T)
    names = collect(fieldnames(unwrapped_type))
    declared_types = collect(fieldtypes(unwrapped_type))
    default_instance = _try_zero_arg_model(T)
    has_defaults = !isnothing(default_instance)
    positional_values = _dummy_constructor_values(declared_types)
    positional_constructible = !isnothing(positional_values) &&
                               _can_construct_with(T, positional_values)

    fields = Dict{String,Any}[]
    parameter_groups = Dict{String,Vector{String}}()
    for (index, name) in pairs(names)
        declared = declared_types[index]
        default = has_defaults ? getfield(default_instance, name) : nothing
        default_type = has_defaults ? typeof(default) : nothing
        parameter_key = _field_type_parameter_key(declared)
        field_name = string(name)
        if !isnothing(parameter_key)
            push!(get!(parameter_groups, parameter_key, String[]), field_name)
        end
        push!(fields, Dict{String,Any}(
            "name" => field_name,
            "declaredType" => string(declared),
            "hasDefault" => has_defaults,
            "default" => has_defaults ? _jsonable_model_value(default) : nothing,
            "defaultJulia" => has_defaults ? repr(default) : nothing,
            "defaultType" => isnothing(default_type) ? nothing : string(default_type),
            "typeParameter" => parameter_key,
            "inferredChoice" => string(_parameter_choice(default_type, declared)),
            "choices" => string.(_MODEL_PARAMETER_TYPE_CHOICES),
        ))
    end

    return Dict{String,Any}(
        "type" => string(T),
        "name" => string(nameof(T)),
        "fields" => fields,
        "parameterGroups" => parameter_groups,
        "hasZeroArgConstructor" => has_defaults,
        "constructible" => has_defaults || positional_constructible,
        "positional" => true,
        "keyword" => false,
    )
end

function _abstract_model_subtypes(root::Type=AbstractModel, seen=Set{Type}())
    found = Type[]
    root in seen && return found
    push!(seen, root)
    for child in InteractiveUtils.subtypes(root)
        child in seen && continue
        push!(found, child)
        append!(found, _abstract_model_subtypes(child, seen))
    end
    return found
end

function _is_process_type(type::Type)
    isabstracttype(type) || return false
    type === AbstractModel && return false
    try
        process_(type)
        return true
    catch
        return false
    end
end

function _is_available_model_type(type::Type)
    isabstracttype(type) && return false
    nameof(type) in _MODEL_DISCOVERY_EXCLUDED_NAMES && return false
    return !isnothing(_process_type_for_model(type))
end

function _process_type_for_model(type::Type)
    current = type
    while current !== Any && current !== AbstractModel
        _is_process_type(current) && return current
        current = supertype(current)
    end
    return nothing
end

function _process_name_for_type(type::Type)
    process_type = _process_type_for_model(type)
    return isnothing(process_type) ? Symbol(nameof(type)) : process_(process_type)
end

function _model_var_descriptor(::Type{T}, accessor) where {T<:AbstractModel}
    instance = _try_zero_arg_model(T)
    isnothing(instance) && (instance = _try_dummy_model(T))
    isnothing(instance) && return Dict{String,Any}()
    variables = try
        accessor(instance)
    catch err
        return Dict{String,Any}("_error" => sprint(showerror, err))
    end
    return Dict(string(name) => _jsonable_model_value(value) for (name, value) in pairs(variables))
end

function _safe_string_trait(::Type{T}, trait) where {T<:AbstractModel}
    value = try
        trait(T)
    catch
        instance = _try_zero_arg_model(T)
        isnothing(instance) && return nothing
        try
            trait(instance)
        catch err
            return string("error: ", sprint(showerror, err))
        end
    end
    return string(value)
end

function _try_zero_arg_model(::Type{T}) where {T<:AbstractModel}
    try
        return T()
    catch
        return nothing
    end
end

function _try_dummy_model(::Type{T}) where {T<:AbstractModel}
    unwrapped_type = Base.unwrap_unionall(T)
    names = fieldnames(unwrapped_type)
    isempty(names) && return nothing
    values = _dummy_constructor_values(fieldtypes(unwrapped_type))
    isnothing(values) && return nothing
    try
        return T(values...)
    catch
        return nothing
    end
end

function _dummy_constructor_values(field_types)
    values = Any[]
    for field_type in field_types
        value = _dummy_field_value(field_type)
        isnothing(value) && return nothing
        push!(values, value)
    end
    return values
end

function _can_construct_with(::Type{T}, values) where {T<:AbstractModel}
    try
        T(values...)
        return true
    catch
        return false
    end
end

_dummy_field_value(::TypeVar) = 0.0

function _dummy_field_value(type)
    try
        type === Any && return 0.0
        type === Bool && return false
        type <: Integer && return zero(type)
        type <: AbstractFloat && return zero(type)
        type <: Real && return zero(type)
        type <: Symbol && return :value
        type <: AbstractString && return ""
    catch
        return nothing
    end
    return nothing
end

_field_type_parameter_key(field_type) = field_type isa TypeVar ? string(field_type.name) : nothing

function _parameter_choice(default_type, declared_type)
    !isnothing(default_type) && return _parameter_choice_from_type(default_type)
    return _parameter_choice_from_type(declared_type)
end

function _parameter_choice_from_type(type)
    try
        type === Nothing && return :nothing
        type === Any && return :float
        type isa TypeVar && return :float
        type === Bool && return :boolean
        type <: Integer && return :integer
        type <: AbstractFloat && return :float
        type <: Real && return :float
        type <: Symbol && return :symbol
        type <: AbstractString && return :string
    catch
        return :float
    end
    return :julia
end

function _jsonable_model_value(value)
    value === nothing && return nothing
    value isa Bool && return value
    value isa Real && isfinite(value) && return value
    value isa Symbol && return string(":", value)
    value isa AbstractString && return value
    value isa AbstractArray && return string(typeof(value), " length ", length(value))
    return string(value)
end

function _model_package_name(module_::Module)
    root = Base.moduleroot(module_)
    root in (Base, Core, Main) && return nothing
    return string(nameof(root))
end
