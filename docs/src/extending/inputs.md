# Input types

[`run!`](@ref) usually takes two inputs: a [`ModelList`](@ref) and data for the meteorology. The data for the meteorology is usually provided for one time step using an `Atmosphere`, or for several time-steps using a `TimeStepTable{Atmosphere}`. The [`ModelList`](@ref) can also be provided as a singleton, or as a vector or dictionary of.

[`run!`](@ref) knows how to handle these data formats via the [`PlantSimEngine.DataFormat`](@ref) trait (see [this blog post](https://www.juliabloggers.com/the-emergent-features-of-julialang-part-ii-traits/). For example, we tell PlantSimEngine that a `TimeStepTable` should be handled like a table by implementing the following trait:

```julia
DataFormat(::Type{<:PlantMeteo.TimeStepTable}) = TableAlike()
```

If you need to use a different data format for the meteorology, you can implement a new trait for it. For example, if you have a table-alike data format, you can implement the trait like this:

```julia
DataFormat(::Type{<:MyTableFormat}) = TableAlike()
```

There are two other traits available: `SingletonAlike` for a data format representing one time-step only, and `TreeAlike` for trees, which is used for MultiScaleTreeGraphs nodes (not generic at this time).


## Special considerations for new input types

If you want to use a custom data format for the inputs, you need to make sure some methods are implemented for your data format depending on the your cases. 

For example if you use models that need to get data from a different time step (e.g. a model that needs to get the previous day's temperature), you need to make sure that the data from the other time-steps can be accessed from the current time-step.

To do so, you need to implement the following methods for your structure that defines your rows:

- `Base.parent`: return the parent table of the row, *e.g.* the full DataFrame
- `PlantMeteo.rownumber`: return the row number of the row in the parent table, *e.g.* the row number in the DataFrame
- (Optionnally) `PlantMeteo.row_from_parent(row, i)`: return row `i` from the parent table, *e.g.* the row `i` from the DataFrame. This is only needed if you want high performance, the default implementation calls `Tables.rows(parent(row))[i]`.
