"""
    DataFrame(components <: AbstractArray{<:ModelMapping})
    DataFrame(components <: AbstractDict{N,<:ModelMapping})

Fetch the data from a [`ModelMapping`](@ref) (or an Array/Dict of) status into a DataFrame.

# Examples

```@example
using PlantSimEngine
using DataFrames

# Creating a ModelMapping
models = ModelMapping(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

# Converting to a DataFrame
df = DataFrame(models)

# Converting to a Dict of ModelMappings
models = ModelMapping(
    "Leaf" => ModelMapping(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    ),
    "InterNode" => ModelMapping(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    )
)

# Converting to a DataFrame
df = DataFrame(models)
```
"""
function DataFrames.DataFrame(components::T) where {T<:AbstractArray{<:ModelMapping}}
    df = DataFrame[]
    for (k, v) in enumerate(components)
        df_c = DataFrames.DataFrame(v)
        df_c[!, :component] .= k
        push!(df, df_c)
    end
    reduce(vcat, df)
end

function DataFrames.DataFrame(components::T) where {T<:AbstractDict{N,<:ModelMapping} where {N}}
    df = DataFrames.DataFrame[]
    for (k, v) in components
        df_c = DataFrames.DataFrame(v)
        df_c[!, :component] .= k
        push!(df, df_c)
    end
    reduce(vcat, df)
end

"""
    DataFrame(components::ModelMapping{T,S}) where {T,S<:Status}

Implementation of `DataFrame` for a `ModelMapping` model with one time step.
"""
function DataFrames.DataFrame(components::ModelMapping{T}) where {T}
    DataFrames.DataFrame([NamedTuple(status(components)[1])])
end
