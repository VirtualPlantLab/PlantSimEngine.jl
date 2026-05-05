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
    :MultiScaleModel,
    :ModelSpec,
])

"""
    available_processes()

Return process abstract model types visible in the current Julia session.

Packages become discoverable after the user loads them with `using PackageName`.
"""
function available_processes()
    processes = Type[]
    for T in _abstract_model_subtypes()
        _is_process_type(T) || continue
        push!(processes, T)
    end
    return sort!(unique(processes); by=T -> string(process_(T)))
end

"""
    available_models()
    available_models(process::Symbol)
    available_models(process_type::Type{<:AbstractModel})

Return model implementation types visible in the current Julia session.
"""
function available_models()
    models = Type[]
    for T in _abstract_model_subtypes()
        _is_available_model_type(T) || continue
        push!(models, T)
    end
    return sort!(unique(models); by=T -> string(_process_name_for_type(T), ".", nameof(T)))
end

function available_models(process_name::Symbol)
    filter(T -> _process_name_for_type(T) == process_name, available_models())
end

function available_models(process_type::Type{<:AbstractModel})
    process_name = _is_process_type(process_type) ? process_(process_type) : _process_name_for_type(process_type)
    return available_models(process_name)
end

"""
    model_descriptor(::Type{<:AbstractModel})

Return renderer-friendly metadata for one model implementation type.
"""
function model_descriptor(::Type{T}) where {T<:AbstractModel}
    process_type = _process_type_for_model(T)
    process_name = isnothing(process_type) ? nothing : process_(process_type)
    constructor = model_constructor_descriptor(T)
    return Dict{String,Any}(
        "type" => string(T),
        "name" => string(nameof(T)),
        "process" => isnothing(process_name) ? nothing : string(process_name),
        "processType" => isnothing(process_type) ? nothing : string(process_type),
        "inputs" => _model_var_descriptor(T, inputs_),
        "outputs" => _model_var_descriptor(T, outputs_),
        "timespec" => _safe_string_trait(T, timespec),
        "outputPolicy" => _safe_string_trait(T, output_policy),
        "timestepHint" => _safe_string_trait(T, timestep_hint),
        "meteoHint" => _safe_string_trait(T, meteo_hint),
        "constructor" => constructor,
    )
end

"""
    model_constructor_descriptor(::Type{<:AbstractModel})

Return best-effort constructor metadata inferred from struct fields and an
optional zero-argument constructor.
"""
function model_constructor_descriptor(::Type{T}) where {T<:AbstractModel}
    unwrapped_type = Base.unwrap_unionall(T)
    names = collect(fieldnames(unwrapped_type))
    declared_types = collect(fieldtypes(unwrapped_type))
    default_instance = _try_zero_arg_model(T)
    has_defaults = !isnothing(default_instance)

    fields = Dict{String,Any}[]
    parameter_groups = Dict{String,Vector{String}}()
    for (i, name) in pairs(names)
        declared = declared_types[i]
        default = has_defaults ? getfield(default_instance, name) : nothing
        default_type = has_defaults ? typeof(default) : nothing
        parameter_key = _field_type_parameter_key(declared)
        inferred_choice = _parameter_choice(default_type, declared)
        field_name = string(name)
        if !isnothing(parameter_key)
            push!(get!(parameter_groups, parameter_key, String[]), field_name)
        end

        push!(fields, Dict{String,Any}(
            "name" => field_name,
            "declaredType" => string(declared),
            "hasDefault" => has_defaults,
            "default" => has_defaults ? _jsonable_value(default) : nothing,
            "defaultType" => isnothing(default_type) ? nothing : string(default_type),
            "typeParameter" => parameter_key,
            "inferredChoice" => string(inferred_choice),
            "choices" => string.(_MODEL_PARAMETER_TYPE_CHOICES),
        ))
    end

    return Dict{String,Any}(
        "type" => string(T),
        "name" => string(nameof(T)),
        "fields" => fields,
        "parameterGroups" => parameter_groups,
        "hasZeroArgConstructor" => has_defaults,
        "constructible" => true,
        "positional" => true,
        "keyword" => false,
    )
end

function _abstract_model_subtypes(root::Type=AbstractModel)
    found = Type[]
    for child in InteractiveUtils.subtypes(root)
        push!(found, child)
        append!(found, _abstract_model_subtypes(child))
    end
    return found
end

function _is_process_type(T::Type)
    isabstracttype(T) || return false
    T === AbstractModel && return false
    try
        process_(T)
        return true
    catch
        return false
    end
end

function _is_available_model_type(T::Type)
    isabstracttype(T) && return false
    nameof(T) in _MODEL_DISCOVERY_EXCLUDED_NAMES && return false
    isnothing(_process_type_for_model(T)) && return false
    return true
end

function _process_type_for_model(T::Type)
    current = T
    while current !== Any && current !== AbstractModel
        _is_process_type(current) && return current
        current = supertype(current)
    end
    return nothing
end

function _process_name_for_type(T::Type)
    process_type = _process_type_for_model(T)
    isnothing(process_type) && return Symbol(nameof(T))
    return process_(process_type)
end

function _model_var_descriptor(::Type{T}, accessor) where {T<:AbstractModel}
    instance = _try_zero_arg_model(T)
    isnothing(instance) && return Dict{String,Any}()
    vars = try
        accessor(instance)
    catch err
        return Dict{String,Any}("_error" => sprint(showerror, err))
    end
    return Dict(string(k) => _jsonable_value(v) for (k, v) in pairs(vars))
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

function _field_type_parameter_key(field_type)
    field_type isa TypeVar && return string(field_type.name)
    return nothing
end

function _parameter_choice(default_type, declared_type)
    !isnothing(default_type) && return _parameter_choice_from_type(default_type)
    return _parameter_choice_from_type(declared_type)
end

function _parameter_choice_from_type(T)
    try
        T === Nothing && return :nothing
        T === Any && return :float
        T isa TypeVar && return :float
        T === Bool && return :boolean
        T <: Integer && return :integer
        T <: AbstractFloat && return :float
        T <: Real && return :float
        T <: Symbol && return :symbol
        T <: AbstractString && return :string
    catch
        return :float
    end
    return :julia
end

function _jsonable_value(value)
    value === nothing && return nothing
    value isa Bool && return value
    value isa Real && isfinite(value) && return value
    value isa Symbol && return string(":", value)
    value isa AbstractString && return value
    value isa AbstractArray && return string(typeof(value), " length ", length(value))
    return string(value)
end
