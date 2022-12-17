"""
    check_dimensions(component,weather)
    check_dimensions(status,weather)

Checks if a component status (or a status directly) and the weather have the same length, or if they can be
recycled (length 1 for one of them).

# Examples
```@repl
using PlantSimEngine, PlantMeteo

# Including an example script that implements dummy processes and models:
include(joinpath(dirname(dirname(pathof(PlantSimEngine))), "examples", "dummy.jl"))

# Creating a dummy weather:
w = Atmosphere(T = 20.0, Rh = 0.5, Wind = 1.0)

# Creating a dummy component:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=[15.0, 16.0], var2=0.3)
)

# Checking that the number of time-steps are compatible (here, they are, it returns nothing):
PlantSimEngine.check_dimensions(models, w) 

# Creating a dummy weather with 3 time-steps:
w = Weather([
    Atmosphere(T = 20.0, Rh = 0.5, Wind = 1.0),
    Atmosphere(T = 25.0, Rh = 0.5, Wind = 1.0),
    Atmosphere(T = 30.0, Rh = 0.5, Wind = 1.0)
])

# Checking that the number of time-steps are compatible (here, they are not, it throws an error):
PlantSimEngine.check_dimensions(models, w) 
```
"""
function check_dimensions(
    st::T,
    weather::TimeStepTable{A}
) where {T<:TimeStepTable,A<:PlantMeteo.AbstractAtmosphere}

    length(st) > 1 && length(st) != length(weather) &&
        throw(DimensionMismatch("Component status should have the same number of time-steps ($(length(st))) than weather data ($(length(weather)))."))

    return nothing
end

# A Status (one time-step) is always authorized with a Weather (it is recycled).
# The status is updated at each time-step, but no intermediate saving though!
function check_dimensions(
    st::T,
    weather::TimeStepTable{A}
) where {T<:Status,A<:PlantMeteo.AbstractAtmosphere}
    return nothing
end

function check_dimensions(
    st,
    weather::Atmosphere
)
    return nothing
end

# We define this one just to avoid ambiguity between the two above
function check_dimensions(component::T, w::Atmosphere) where {T<:ModelList}
    return nothing
end

function check_dimensions(component::T, w) where {T<:ModelList}
    check_dimensions(status(component), w)
end

# for several components as an array
function check_dimensions(component::T, weather::TimeStepTable{A}) where {T<:AbstractArray{<:ModelList},A<:PlantMeteo.AbstractAtmosphere}
    for i in component
        check_dimensions(i, weather)
    end
end

# for several components as a Dict
function check_dimensions(component::T, weather::TimeStepTable{A}) where {T<:AbstractDict{N,<:ModelList},A<:PlantMeteo.AbstractAtmosphere} where {N}
    for (key, val) in component
        check_dimensions(val, weather)
    end
end
