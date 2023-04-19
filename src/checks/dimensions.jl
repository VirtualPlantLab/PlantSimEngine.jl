"""
    check_dimensions(component,weather)
    check_dimensions(status,weather)

Checks if a component status (or a status directly) and the weather have the same length, or if they can be
recycled (length 1 for one of them).

# Examples
```jldoctest
using PlantSimEngine, PlantMeteo

# Including an example script that implements dummy processes and models:
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

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

# output
ERROR: DimensionMismatch: Component status should have the same number of time-steps (2) than weather data (3).
```
"""
check_dimensions(component, weather) = check_dimensions(DataFormat(component), DataFormat(weather), component, weather)

# Here we add methods for applying to a component, an array or a dict of:
function check_dimensions(component::T, w) where {T<:ModelList}
    check_dimensions(status(component), w)
end

# for several components as an array
function check_dimensions(component::T, weather) where {T<:AbstractArray{<:ModelList}}
    for i in component
        check_dimensions(i, weather)
    end
end

# for several components as a Dict
function check_dimensions(component::T, weather) where {T<:AbstractDict{N,<:ModelList} where {N}}
    for (key, val) in component
        check_dimensions(val, weather)
    end
end


function check_dimensions(::TableAlike, ::TableAlike, st, weather)
    length(st) > 1 && length(st) != length(weather) &&
        throw(DimensionMismatch("Component status should have the same number of time-steps ($(length(st))) than weather data ($(length(weather)))."))
    return nothing
end

# A Status (one time-step) is always authorized with a Weather (it is recycled).
# The status is updated at each time-step, but no intermediate saving though!
function check_dimensions(::SingletonAlike, ::TableAlike, st, weather)
    return nothing
end

function check_dimensions(s, ::SingletonAlike, st, weather)
    return nothing
end

function check_dimensions(::SingletonAlike, ::SingletonAlike, st, weather)
    return nothing
end