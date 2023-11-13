"""
    status(m)
    status(m::AbstractArray{<:ModelList})
    status(m::AbstractDict{T,<:ModelList})

Get a ModelList status, *i.e.* the state of the input (and output) variables.

See also [`is_initialized`](@ref) and [`to_initialize`](@ref)

# Examples

```jldoctest
using PlantSimEngine

# Including example models and processes:
using PlantSimEngine.Examples;

# Create a ModelList
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status = (var1=[15.0, 16.0], var2=0.3)
);

status(models)

# Or just one variable:
status(models,:var1)


# Or the status at the ith time-step:
status(models, 2)

# Or even more simply:
models[:var1]
# output
2-element Vector{Float64}:
 15.0
 16.0
```
"""
function status(m)
    m.status
end

function status(m::T) where {T<:AbstractArray{M} where {M}}
    [status(i) for i in m]
end

function status(m::T) where {T<:AbstractDict{N,M} where {N,M}}
    Dict([k => status(v) for (k, v) in m])
end

# Status with a variable would return the variable value.
function status(m, key::Symbol)
    getproperty(m.status, key)
end

# Status with an integer returns the ith status.
function status(m, key::T) where {T<:Integer}
    getindex(m.status, key)
end

"""
    getindex(component<:ModelList, key::Symbol)
    getindex(component<:ModelList, key)

Indexing a component models structure:
    - with an integer, will return the status at the ith time-step
    - with anything else (Symbol, String) will return the required variable from the status

# Examples

```julia
using PlantSimEngine

lm = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status = (var1=[15.0, 16.0], var2=0.3)
);

lm[:var1] # Returns the value of the Tₗ variable
lm[2]  # Returns the status at the second time-step
lm[2][:var1] # Returns the value of Tₗ at the second time-step
lm[:var1][2] # Equivalent of the above

# output
16.0
```
"""
function Base.getindex(component::T, key) where {T<:ModelList}
    status(component, key)
end

function Base.setindex!(component::T, value, key) where {T<:ModelList}
    setproperty!(status(component), key, value)
end
