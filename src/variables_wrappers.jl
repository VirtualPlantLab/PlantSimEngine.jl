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

The process is added when building the MultiScaleModel, to avoid conflicts between processes with the same variable name.
For exemple one process can define a variable `:carbon_biomass` as a `PreviousTimeStep`, but the othe process would use 
the variable as a dependency for the current time-step (and it would be fine because theyr don't share the same issue of cyclic dependency).
"""
struct PreviousTimeStep
    variable::Symbol
    process::Symbol
end

PreviousTimeStep(v::Symbol) = PreviousTimeStep(v, :unknown)