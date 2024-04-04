""" 
    UninitializedVar(variable, value)

A variable that is not initialized yet, it is given a name and a default value.
"""
struct UninitializedVar{T}
    variable::Symbol
    value::T
end

Base.eltype(u::UninitializedVar{T}) where {T} = T