"""
    check_dimensions(component,weather)
    check_dimensions(status,weather)

Checks if a component status (or a status directly) and the weather have the same length, or if they can be
recycled (length 1 for one of them).

# Examples
```jldoctest
using PlantSimEngine, PlantMeteo

# Including an example script that implements dummy processes and models:
using PlantSimEngine.Examples

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
ERROR: DimensionMismatch: Component status has a vector variable : var1 implying multiple timesteps but weather data only provides a single timestep.
```
"""
check_dimensions(component, weather) = check_dimensions(DataFormat(weather), component, weather)

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


# Note : everything is at the smallest timestep
# A few variables on the slower timesteps will have many redundant values 

# A Status (one time-step) is always authorized with a Weather (it is recycled).
# The status is updated at each time-step, but no intermediate saving though!
function check_dimensions(::TableAlike, st::Status, weather)
    weather_len = get_nsteps(weather)

    for (var, value) in zip(keys(st), st)
        if length(value) > 1
            if length(value) != weather_len
                throw(DimensionMismatch("Component status has a vector variable : $(var) of length $(length(value)) but the weather data expects $(weather_len) timesteps."))
            end
        end
    end

    return nothing
end

function check_dimensions(::SingletonAlike, st::Status, weather)
    for (var, value) in zip(keys(st), st)
        if length(value) > 1 
            throw(DimensionMismatch("Component status has a vector variable : $(var) implying multiple timesteps but weather data only provides a single timestep."))
        end
    end

    return nothing
end

function check_dimensions(::SingletonAlike, ::SingletonAlike, st, weather)
    return nothing
end


"""
    get_nsteps(t)

Get the number of steps in the object.
"""
function get_nsteps(t)
    get_nsteps(DataFormat(t), t)
end

function get_nsteps(::SingletonAlike, t)
    1
end

function get_nsteps(::TableAlike, t)
    DataAPI.nrow(t)
end