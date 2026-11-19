# Only Status implementation types are abstracted. Every other type constructor,
# parameter, literal and union member is preserved. Labels for types containing
# no Status are byte-identical to the original encoder. A Status inside Ref,
# array, Tuple, NamedTuple or another model cannot leak a changed storage label.
status_type(T) = T !== Union{} && T isa Type && T <: PSE.Status
function contains_status_type(T)
    status_type(T) && return true
    T isa Union && return any(contains_status_type, Base.uniontypes(T))
    T isa UnionAll && return contains_status_type(T.var) || contains_status_type(T.body)
    T isa TypeVar && return contains_status_type(T.lb) || contains_status_type(T.ub)
    T isa DataType && return any(contains_status_type, T.parameters)
    T isa Core.TypeofVararg && return isdefined(T, :T) && contains_status_type(T.T)
    T isa Tuple && return any(contains_status_type, T)
    return false
end
function semantic_type_parameter(parameter)
    parameter isa Union{Type,TypeVar,Core.TypeofVararg} && return semantic_type_label(parameter)
    if parameter isa Tuple && contains_status_type(parameter)
        return (kind=:tuple_type_parameter, values=map(semantic_type_parameter, parameter))
    end
    return (kind=:literal_type_parameter,
        type=sprint(show, typeof(parameter); context=:module=>nothing), representation=repr(parameter))
end
function semantic_type_label(T)
    status_type(T) && return (kind=:semantic_status_type, contract=:status_names_v1)
    contains_status_type(T) || return sprint(show, T; context=:module=>nothing)
    if T isa Union
        members=Any[semantic_type_label(member) for member in Base.uniontypes(T)]
        # Distinct physical Status families can project to the same semantic
        # leaf. Collapse only those duplicates; no non-Status member is lost.
        sort!(members; by=repr)
        unique!(members)
        length(members)==1 && return only(members)
        return (kind=:union_type, members)
    elseif T isa UnionAll
        return (kind=:union_all_type, variable=semantic_type_label(T.var), body=semantic_type_label(T.body))
    elseif T isa TypeVar
        return (kind=:type_variable, name=T.name,
            lower=semantic_type_label(T.lb), upper=semantic_type_label(T.ub))
    elseif T isa Core.TypeofVararg
        return (kind=:vararg_type, element=semantic_type_label(T.T),
            count_defined=isdefined(T, :N), count=isdefined(T, :N) ? semantic_type_parameter(T.N) : nothing)
    elseif T isa DataType
        return (kind=:type_with_semantic_status,
            constructor=string(parentmodule(T), ".", nameof(T)),
            parameters=Any[semantic_type_parameter(parameter) for parameter in T.parameters])
    end
    error("A Status-bearing type needs an explicit exact semantic type projection.")
end
