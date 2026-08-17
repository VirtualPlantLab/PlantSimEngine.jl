"""
    PreviousTimeStep(variable)

A structure to flag a model input as using the value computed on the previous
model timestep. This breaks same-timestep coupling cycles.
The value can be initialized in the Status if needed.
"""
struct PreviousTimeStep
    variable::Symbol
    process::Symbol
end

PreviousTimeStep(v::Symbol) = PreviousTimeStep(v, :unknown)
