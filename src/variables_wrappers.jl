""" 
    UninitializedVar(variable, value)

A variable that is not initialized yet, it is given a name and a default value.
"""
struct UninitializedVar{T}
    variable::Symbol
    value::T
end

Base.eltype(u::UninitializedVar{T}) where {T} = T
source_variable(m::UninitializedVar) = m.variable
source_variable(m::UninitializedVar, org) = m.variable

"""
    PreviousTimeStep(variable)

A structure to manually flag a variable in a model to use the value computed on the previous time-step. 
This implies that the variable is not used to build the dependency graph because the dependency graph only 
applies on the current time-step. This is used to avoid circular dependencies when a variable depends on itself.
The value can be initialized in the Status if needed.
"""
struct PreviousTimeStep
    variable::Symbol
end