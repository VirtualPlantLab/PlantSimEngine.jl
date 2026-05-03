# Input types

[`run!`](@ref) usually takes two inputs: a [`ModelMapping`](@ref) and data for the meteorology. The data for the meteorology is usually provided for one time step using an `Atmosphere`, or for several time-steps using a `TimeStepTable{Atmosphere}`. The [`ModelMapping`](@ref) can also be provided as a singleton, or as a vector or dictionary of.

[`run!`](@ref) knows how to handle these data formats via the [`PlantSimEngine.DataFormat`](@ref) trait (see [this blog post](https://www.juliabloggers.com/the-emergent-features-of-julialang-part-ii-traits/) to learn more about traits). For example, we tell PlantSimEngine that a `TimeStepTable` should be handled like a table by implementing the following trait:

```julia
DataFormat(::Type{<:PlantMeteo.TimeStepTable}) = TableAlike()
```

If you need to use a different data format for the meteorology, you can implement a new trait for it. For example, if you have a table-alike data format, you can implement the trait like this:

```julia
DataFormat(::Type{<:MyTableFormat}) = TableAlike()
```

There are two other traits available: `SingletonAlike` for a data format representing one time-step only, and `TreeAlike` for trees, which is used for MultiScaleTreeGraphs nodes (not generic at this time).

## Promoting status variable types

Use the `type_promotion` keyword on [`ModelMapping`](@ref) when the default input and output values declared by models should be converted to another type:

```julia
models = ModelMapping(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2);
    status=(TT_cu=cumsum(meteo_day.TT),),
    type_promotion=Dict(Real => Float32),
)
```

For single-scale mappings, `type_promotion` is applied while the backing status is constructed. It follows the same semantics as the deprecated [`ModelList`](@ref): model-provided default values are converted, while values explicitly passed in `status` keep the type chosen by the user. If those values should also be `Float32`, pass them as `Float32` values directly.

For multiscale mappings, the per-node statuses do not exist when [`ModelMapping`](@ref) is constructed. The promotion map is stored on the mapping and applied when the MTG simulation is initialized:

```julia
mapping = ModelMapping(
    :Scene => ToyTt_CuModel(),
    :Plant => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => :Scene,
            ],
        ),
        Beer(0.5),
        ToyRUEGrowthModel(0.2),
    );
    type_promotion=Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}),
)

outputs = run!(mtg, mapping, meteo_day)
```

The same promotion can also be passed at MTG run time:

```julia
outputs = run!(
    mtg,
    mapping,
    meteo_day;
    type_promotion=Dict(Float64 => Float32, Vector{Float64} => Vector{Float32}),
)
```

In multiscale runs, type promotion is used by `GraphSimulation` during status template creation, `RefVector` creation, output preallocation, and initialization from MTG node attributes.


## Special considerations for new input types

If you want to use a custom data format for the inputs, you need to make sure some methods are implemented for your data format depending on your use-cases. 

For example if you use models that need to get data from a different time step (*e.g.* a model that needs to get the previous day's temperature), you need to make sure that the data from the other time-steps can be accessed from the current time-step.

To do so, you need to implement the following methods for your structure that defines your rows:

- `Base.parent`: return the parent table of the row, *e.g.* the full DataFrame
- `PlantMeteo.rownumber`: return the row number of the row in the parent table, *e.g.* the row number in the DataFrame
- (Optionnally) `PlantMeteo.row_from_parent(row, i)`: return row `i` from the parent table, *e.g.* the row `i` from the DataFrame. This is only needed if you want high performance, the default implementation calls `Tables.rows(parent(row))[i]`.

!!! compat
    `PlantMeteo.rownumber` is temporary. It soon will be replaced by `DataAPI.rownumber` instead, which will be also used by *e.g.* DataFrames.jl. See [this Pull Request](https://github.com/JuliaData/DataAPI.jl/issues/60).

## Working with weather data

Here's a quick example showcasing how to export the example weather data to your own file :

```julia 
meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Dates.Day)
PlantMeteo.write_weather("examples/meteo_day.csv", meteo_day, duration = Dates.Day)
```

If you wish to filter weather data, reshape it, adjust it, write it, you'll find some more examples in PlantMeteo's [API reference](https://palmstudio.github.io/PlantMeteo.jl/stable/API/).  
