# Converting a single-scale simulation to multi-scale

A single-scale simulation can be turned into a 'pseudo-multi-scale' simulation by providing a simple multi-scale tree graph, and declaring a mapping linking all models to a unique scale level.

This section showcases the conversion, and then adds a model at a new scale to make the simulation genuinely multi-scale.

The full script for this section can be found in TODO

# Converting the ModelList to a multi-scale mapping

For example, let's consider the `ModelList` coupling a light interception model, a Leaf Area Index model, and a carbon biomass increment model that was discussed [here](Further coupling) : 

```julia
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

models = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
```

Those models all operate on a simplified model of a single plant, without any organ-local information. We can therefore consider them to be working at the 'whole plant' scale. Their variables also operate at that "plant" scale, so there is no need to map any variable to other scales.

We can therefore convert this into the following mapping : 

```julia 
mapping = Dict(
"Plant" => (
   ToyLAIModel(),
    Beer(0.5),
    ToyRUEGrowthModel(0.2),
    Status(TT_cu=cumsum(meteo_day.TT),)
    ),
)
```
Note the slight difference in syntax for the `Status`. This is due to an implementation quirk (sorry).

None of these models operate on a multi-scale tree graph, either. There is no concept of organ creation or growth. We still need to provide a multi-scale tree graph to a multi-scale simulation, so we can -for now- declare a very simple MTG, with a single node :

```julia
mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
```

## Running the multi-scale simulation

We now have **almost** what we need to run the multiscale simulation.

This first conversion step can be a starting point for a more elaborate multi-scale simulation. 

The signature of the `run!` function in multi-scale differs slightly from the ModelList version : 

```julia
out_multiscale = run!(mtg, mapping, meteo_day)
```

(Some of the optional arguments also change slightly)

Unfortunately, there is one caveat. Passing in a vector through the `Status` is still possible in multi-scale mode, but requires a little more advanced tinkering with the mapping, as it generates a custom model under the hood and the implementation is less user-friendly.

If you are keen on going down that path, you can find a detailed example here TODO, but we don't recommend it for beginners.

What we'll do instead, is write our own model provide the thermal time per timestep as a variable, instead of as a single vector in the `Status`.

Our 'pseudo-multiscale' first approach will therefore turn into a genuine multi-scale simulation.

## Adding a second scale

Let's have a model provide the Cumulated Thermal Time to our Leaf Area Index model, instead of initializing it through the `Status`. 

Let's instead implement our own `ToyTT_cuModel`.

### TT_cu model implementation

This model doesn't require any outside data or input variables, it only operates on the weather data and outputs our desired TT_cu. The implementation doesn't require any advanced coupling and is very straightforward.

```julia
PlantSimEngine.@process "tt_cu" verbose = false

struct ToyTt_CuModel <: AbstractTt_CuModel
end

function PlantSimEngine.run!(::ToyTt_CuModel, models, status, meteo, constants, extra=nothing)
    status.TT_cu +=
        meteo.TT
end

function PlantSimEngine.inputs_(::ToyTt_CuModel)
    NamedTuple() # No input variables
end

function PlantSimEngine.outputs_(::ToyTt_CuModel)
    (TT_cu=-Inf,)
end
```

!!! note
    The only accessible variables in the `run!` function via the status are the ones that are local to the "Scene" scale. This isn't explicit at first glance, but very important to keep in mind when developing models, or using them at different scales. If variables from other scales are required, then they need to be mapped via a `MultiScaleModel`, or sometimes a more complex coupling is necessary.

### Linking the new TT_cu model to a scale in the mapping

We now have our model implementation. How does it fit into our mapping ?

Our new model doesn't really relate to a specific organ of our plant. In fact, this model doesn't represent a physiological process of the plant, but rather an environmental process affecting its physiology. We could therefore have it operate at a different scale unrelated to the plant, which we'll call "Scene". This makes sense.

Note that we now need to add a "Scene" node to our Multi-scale Tree Graph, otherwise our model will not run, since no other model calls it. See []TODO

```julia
mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
    plant = MultiScaleTreeGraph.Node(mtg_multiscale, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
```

### Mapping between scales : the MultiScaleModel wrapper

The cumulated thermal time (`:TT_cu`) which was previously provided to the LAI model as a simulation parameter now needs to be mapped from the "Scene" scale level. 

This is done by wrapping our `ToyLAIModel` in a dedicated structure called a `MultiScaleModel`. A `MultiScaleModel` requires two keyword arguments : `model`, indicating the model for which some variables are mapped, and `mapped_variables`, indicating which scale link to which variables, and potentially renaming them.

There can be different kinds of variable mapping with slightly different syntax, but in our case, only a single scalar value of the TT_cu is passed from the "Scene" to the "Plant" scale.

This gives us the following declaration : 

```julia
MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
```
and the new mapping with two scales :

```julia
mapping_multiscale = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.5),
        ToyRUEGrowthModel(0.2),
    ),
)
```

We can then run the multiscale simulation, with our two-node MTG :

```julia
out_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)
```

### Comparing outputs between single- and multi-scale

The outputs structures are slightly different : multi-scale outputs are indexed by scale, and a variable has a value for every node of the scale it operates at (for instance, there would be a "leaf_surface" value for every leaf in a plant), stored in an array.

In our simple example, we only have one MTG scene node and one plant node, so the arrays for each variable in the multi-scale output only contain one value.

We can access the output variables at the "Scene" scale by indexing our outputs:

```julia
outputs_multiscale["Scene"]
```
and then the computed `:TT_cu`:
```julia
outputs_multiscale["Scene"][:TT_cu]
```

As you can see, it is a `Vector{Vector{T}}`, whereas our single-scale output is a `Vector{T}`:
```julia
outputs_singlescale.TT_cu
```

To compare them value-by-value, we can flatten the multiscale Vector and then do a piecewise approximate equality test :
```julia
computed_TT_cu_multiscale = collect(Base.Iterators.flatten(outputs_multiscale["Scene"][:TT_cu]))

for i in 1:length(computed_TT_cu_multiscale)
    if !(computed_TT_cu_multiscale[i] ≈ outputs_singlescale.TT_cu[i])
        println(i)
    end
end
```
or equivalently, with broadcasting, we can write :
```julia
is_approx_equal = length(unique(multiscale_TT_cu .≈ out_singlescale.TT_cu)) == 1
```

!!! note
    You may be wondering why we check for approximate equality rather than strict equality. The reason for that is due to floating-point accumulation errors, which are discussed in more detail [here]TODO.

## ToyDegreeDaysCumulModel

There is a model able to provide Thermal Time based on weather temperature data, `ToyDegreeDaysCumulModel`, which can also be found in the examples folder. 

We didn't make use of it here for learning purposes. It also computes a thermal time based on default parameters that don't correspond to the thermal time in the example weather data, so results differ from the thermal time already present in the weather data without tinkering with the parameters. 