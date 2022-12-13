"""
    DataFrame(components <: AbstractArray{<:ModelList})
    DataFrame(components <: AbstractDict{N,<:ModelList})

Fetch the data from a [`ModelList`](@ref) (or an Array/Dict of) status into
a DataFrame.
"""
function DataFrames.DataFrame(components::T) where {T<:Union{ModelList,AbstractArray{<:ModelList}}}
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

# NB: could use dispatch on concrete types but would enforce specific implementation for each


"""
    DataFrame(components::T) where {T<:ModelList}

Generic implementation of `DataFrame` for a single `ModelList` model.
"""
function DataFrames.DataFrame(components::T) where {T<:ModelList}
    st = status(components)
    if isa(st, TimeStepTable)
        DataFrames.DataFrame([(NamedTuple(j)..., timestep=i) for (i, j) in enumerate(st)])
    else
        DataFrames.DataFrame([NamedTuple(st)])
    end
end

"""
    DataFrame(components::ModelList{T,<:TimeStepTable})

Implementation of `DataFrame` for a `ModelList` model with several time steps.
"""
function DataFrames.DataFrame(components::ModelList{T,S}) where {T,S<:TimeStepTable}
    DataFrames.DataFrame([(NamedTuple(j)..., timestep=i) for (i, j) in enumerate(status(components))])
end

"""
    DataFrame(components::ModelList{T,S}) where {T,S<:AbstractDict}

Implementation of `DataFrame` for a `ModelList` model with one time step.
"""
function DataFrames.DataFrame(components::ModelList{T,S}) where {T,S<:Status}
    DataFrames.DataFrame([NamedTuple(status(components)[1])])
end
