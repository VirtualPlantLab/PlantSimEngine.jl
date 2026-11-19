module FiniteExportValues
export OpenValues, RecordingValues, FiniteValues, TypeWitnesses, record_type!,
    merge_types!, finite_values, with_value

abstract type ValueAdmission end
struct OpenValues <: ValueAdmission end
mutable struct TypeWitnesses
    types::Vector{Any} # Type objects only; never scientific values/references.
    seen::Set{Any}
end
TypeWitnesses() = TypeWitnesses(Any[], Set{Any}())
struct RecordingValues <: ValueAdmission
    witnesses::TypeWitnesses
end
struct FiniteValues{T<:Tuple} <: ValueAdmission end

function record_type!(witnesses::TypeWitnesses, value)
    T = value isa Type ? Core.apply_type(Type, value) : typeof(value)
    if !(T in witnesses.seen)
        push!(witnesses.seen, T)
        push!(witnesses.types, T)
    end
    return nothing
end
function merge_types!(destination::TypeWitnesses, source::TypeWitnesses)
    for T in source.types
        if !(T in destination.seen)
            push!(destination.seen, T)
            push!(destination.types, T)
        end
    end
    return destination
end
function singleton_type_witness(T)
    return T isa DataType && T <: Type && length(T.parameters) == 1 &&
        T.parameters[1] isa Type
end
function finite_values(witnesses::TypeWitnesses)
    isempty(witnesses.types) && throw(ArgumentError("Supply real observed export types."))
    for T in witnesses.types
        isconcretetype(T) || singleton_type_witness(T) || throw(ArgumentError(
            "An export catalogue needs exact concrete/singleton type witnesses."))
    end
    return FiniteValues{Core.apply_type(Tuple, witnesses.types...)}()
end

@inline with_value(f::F, ::OpenValues, value) where {F} = f(value)
@inline function with_value(f::F, admission::RecordingValues, value) where {F}
    record_type!(admission.witnesses, value)
    return f(value)
end
@generated function with_value(f::F, ::FiniteValues{T}, value) where {F,T<:Tuple}
    branches = Expr[]
    for V in fieldtypes(T)
        if singleton_type_witness(V)
            push!(branches, :(value isa $V && return f(value::$V)))
        else
            push!(branches, :(typeof(value) === $V && return f(value::$V)))
        end
    end
    return quote
        $(branches...)
        throw(ArgumentError("A real export value is outside the observed finite catalogue."))
    end
end
end
