"""
    DataFrame(components <: AbstractArray{<:ModelList})
    DataFrame(components <: AbstractDict{N,<:ModelList})

Fetch the data from a [`ModelList`](@ref) (or an Array/Dict of) status into
a DataFrame.

# Examples

```@example
using PlantSimEngine
using DataFrames

# Creating a ModelList
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

# Converting to a DataFrame
df = DataFrame(models)

# Converting to a Dict of ModelLists
models = Dict(
    "Leaf" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    ),
    "InterNode" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    )
)

# Converting to a DataFrame
df = DataFrame(models)
```
"""
function DataFrames.DataFrame(components::T) where {T<:AbstractArray{<:ModelList}}
    df = DataFrame[]
    for (k, v) in enumerate(components)
        df_c = DataFrames.DataFrame(v)
        df_c[!, :component] .= k
        push!(df, df_c)
    end
    reduce(vcat, df)
end

function DataFrames.DataFrame(components::T) where {T<:AbstractDict{N,<:ModelList} where {N}}
    df = DataFrames.DataFrame[]
    for (k, v) in components
        df_c = DataFrames.DataFrame(v)
        df_c[!, :component] .= k
        push!(df, df_c)
    end
    reduce(vcat, df)
end

"""
    DataFrame(components::ModelList{T,S}) where {T,S<:Status}

Implementation of `DataFrame` for a `ModelList` model with one time step.
"""
function DataFrames.DataFrame(components::ModelList{T,S}) where {T,S<:Status}
    DataFrames.DataFrame([NamedTuple(status(components)[1])])
end
