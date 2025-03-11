# Standard model coupling

```@setup usepkg
using PlantSimEngine
using PlantSimEngine.Examples
using CSV
using DataFrames
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
nothing
```
## ModelList

The `ModelList` is a container that holds a list of models, their parameter values, and the status of the variables associated to them.

If one looks at prior examples, the Modellists so far have only contained a single model, whose input variables are initialised in the Modellist `status` keyword argument. 

Example models are all taken from the example scripts in the [`examples`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/) folder.

Here's a first `ModelList` declaration with a light interception model, requiring input Leaf Area Index (LAI): 

```julia
modellist_coupling_part_1 = ModelList(Beer(0.5), status = (LAI = 2.0,))
```

Here's a second one with a Leaf Area Index model, with some example Cumulated Thermal Time as input. (This TT_cu is usually computed from weather data):

```julia
modellist_coupling_part_2 = ModelList(
    ToyLAIModel(),
    status=(TT_cu=1.0:2000.0,), # Pass the cumulated degree-days as input to the model
)
```

## Combining models

Suppose we want our `ToyLAIModel()` to compute the `LAI` for the light interception model. 

We can couple the two models by having them be part of a single `ModelList`. The `LAI` variable will then be a coupled output computed by the `ToyLAIModel`, then used as input by `Beer`. It will no longer need to be declared as part of the `status`.

This is an instance of what we call a ["soft dependency" coupling](@ref hard_dependency_def): a model depends on another model's outputs for its inputs.

Here's a first attempt : 

```@example usepkg
using PlantSimEngine
# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples

# A ModelList with two coupled models
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    status=(TT_cu=1.0:2000.0,),
)
struct UnexpectedSuccess <: Exception end #hack to enable checking an error without failing docbuild #hide
# see https://github.com/JuliaDocs/Documenter.jl/issues/1420 #hide
try #hide
run!(models)
throw(UnexpectedSuccess()) #hide
catch err; err isa UnexpectedSuccess ? rethrow(err) : showerror(stderr, err); end  #hide
```

Oops, we get an error related to the weather data : 

```julia
ERROR: type NamedTuple has no field Ri_PAR_f
Stacktrace:
  [1] getindex(mnt::Atmosphere{(), Tuple{}}, i::Symbol)
    @ PlantMeteo ~/Documents/CIRAD/dev/PlantMeteo/src/structs/atmosphere.jl:147
  [2] getcolumn(row::PlantMeteo.TimeStepRow{Atmosphere{(), Tuple{}}}, nm::Symbol)
    @ PlantMeteo ~/Documents/CIRAD/dev/PlantMeteo/src/structs/TimeStepTable.jl:205
    ...
```

The `Beer()` model requires a specific meteorological parameter. Let's fix that by importing the example weather data :

```@example usepkg
using PlantSimEngine

# PlantMeteo and CSV packages are now used
using PlantMeteo, CSV

# Import the examples defined in the `Examples` sub-module:
using PlantSimEngine.Examples

# Import example weather data
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

# A ModelList with two coupled models
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    status=(TT_cu=cumsum(meteo_day.TT),), # We can now compute a genuine cumulative thermal time from the weather data
)

# Add the weather data to the run! call
outputs_coupled = run!(models, meteo_day)

```

And there you have it. The light interception model made its computations using the Leaf Area Index computed by `ToyLAIModel`.

## Further coupling

Of course, one can keep adding models. Here's an example ModelList with another model, `ToyRUEGrowthModel`, which computes the carbon biomass increment caused by photosynthesis.

```julia
models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)

nothing # hide
```