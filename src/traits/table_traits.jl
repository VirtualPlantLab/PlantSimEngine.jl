abstract type DataFormat end
struct TableAlike <: DataFormat end
struct SingletonAlike <: DataFormat end
struct TreeAlike <: DataFormat end

"""
    DataFormat(T::Type)

Returns the data format of the type `T`. The data format is used to determine
how to iterate over the data. The following data formats are supported:

- `TableAlike`: The data is a table-like object, e.g. a `DataFrame` or a
  `TimeStepTable`. The data is iterated over by rows using the `Tables.jl` interface.
- `SingletonAlike`: The data is a singleton-like object, e.g. a `NamedTuple`
    or a `TimeStepRow`. The data is iterated over by columns.
- `TreeAlike`: The data is a tree-like object, e.g. a `Node`.

The default implementation returns `TableAlike` for `AbstractDataFrame`,
`TimeStepTable`, `AbstractVector` and `Dict`, `TreeAlike` for `GraphSimulation`, 
`SingletonAlike` for `Status`, `ModelList`, `NamedTuple` and `TimeStepRow`.

The default implementation for `Any` throws an error. Users that want to use another input
should define this trait for the new data format, e.g.:

```julia
PlantSimEngine.DataFormat(::Type{<:MyType}) = TableAlike()
```

# Examples

```jldoctest
julia> using PlantSimEngine, PlantMeteo, DataFrames

julia> PlantSimEngine.DataFormat(DataFrame)
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(TimeStepTable([Status(a = 1, b = 2, c = 3)]))
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat([1, 2, 3])
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(Dict(:a => 1, :b => 2))
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(Status(a = 1, b = 2, c = 3))
PlantSimEngine.SingletonAlike()
```
"""
DataFormat(::Type{<:DataFrames.AbstractDataFrame}) = TableAlike()
DataFormat(::Type{<:PlantMeteo.TimeStepTable}) = TableAlike()

# Giving a ModelList as a vector or a dict of objects:
DataFormat(::Type{<:AbstractVector}) = TableAlike()
DataFormat(::Type{<:Dict}) = TableAlike()

DataFormat(::Type{<:NamedTuple}) = SingletonAlike()
DataFormat(::Type{<:Status}) = SingletonAlike()
DataFormat(::Type{<:ModelList{Mo,S,V} where {Mo,S<:Status,V}}) = SingletonAlike()
DataFormat(::Type{<:ModelList{Mo,S,V}}) where {Mo,S,V} = TableAlike()
DataFormat(::Type{<:GraphSimulation}) = TreeAlike()

DataFormat(::Type{<:PlantMeteo.AbstractAtmosphere}) = SingletonAlike()
DataFormat(::Type{<:PlantMeteo.TimeStepRow}) = SingletonAlike()
DataFormat(::Type{<:Nothing}) = SingletonAlike() # For meteo == Nothing
DataFormat(T::Type{<:Any}) = error("Unknown data format: $T.\nPlease define a `DataFormat` method, e.g.: DataFormat(::Type{$T}) method.")
DataFormat(x::T) where {T} = DataFormat(T)
DataFormat(::Type{<:DataFrames.DataFrameRow}) = SingletonAlike()