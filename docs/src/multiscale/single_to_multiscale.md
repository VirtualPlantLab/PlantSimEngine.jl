# Moving to multi-scale simulations

PlantSimEngine provides a framework for multi-scale modeling to integrate and couple models at different scales, retaining functionalities provided in single-scale simulations. ('Multi-scale' and 'single-scale' terminology is defined [here](TODO))

`ModelList` structures don't have a concept of a "scale", so are insufficient when it comes to using models which work at different plant organ levels. A similar but slightly different API is provided for multi-scale simulations.

This section showcases how to take a single-scale `ModelList` simulation, and convert it into an equivalent multi-scale simulation (with only one provided scale in practice). This eases the transition for future full-fledged multi-scale simulation which might have multiple plant organs and operate at several scales. 

There is a more detailed discussion of mappings and scales [here](TODO). You can also find a three-part tutorial implementing an example multi-scale toy plant [here](TODO)

## Multi-scale considerations

Declaring and running a multi-scale simulation follows the same general workflow as the single-scale version. 

Multi-scale simulations do have some differences : they require a Multi-scale Tree Graph (MTG) and the ModelList is replaced by a slightly more complex model mapping.

The model dependency graph will still be computed automatically, meaning users don't need to specify the order of model execution once the extra code to declare the models is written.

Multi-scale simulations also tend to require more extra ad hoc models to prepare some variables for some models.

### Multi-scale tree graphs

A multi-scale simulation is implicitely expected to operate on a plant-like object. Functional-Structural Plant Models are often about simulationg plant growth.

A multi-scale tree graph (MTG) object see TODO is therefore required to run a multi-scale simulations. It can be a dummy MTG if the simulation doesn't actually affect it, but is nevertheless a required argument to the multi-scale `run` function.

### Mappings

Some models are tied to a specific plant organ. 

For instance, a model computing a leaf's surface area depending on its age would operate at the "leaf" scale, and be called **for every leaf** at every timestep. On the other hand, a model computing the plant's total leaf area only needs to be run once per timestep, and can be run at the "Plant" scale.

When users define which models they use, PlantSimEngine cannot determine in advance which scale level they operate at. This is because the plant organs in an MTG do not have standardized names, and also because some plant organs might not be part of the initial MTG, so parsing it isn't enough to infer what scales are used.

The user therefore needs to indicate the simulation's different scales and related models.

A mapping links models to the scale at which they operate, and is implemented as a Julia `Dict`, tying a scale, such as "Leaf" to models operating at that scale, such as "LeafSurfaceAreaModel". 

Multi-scale models can be similar models to the ones found in earlier sections, or, if they need to make use of variables at other scales, may need to be wrapped as part of a `MultiScaleModel` object. Many models are not tied to a particular scale, which means those models can be reused at different scales or in single-scale simulations.

## Correspondence between single and multi-scale simulations

A single-scale simulation can be turned into a 'pseudo-multi-scale' simulation by providing a simple multi-scale tree graph, and declaring a mapping linking all models to a unique scale level.

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

Unfortunately, there is one caveat. Passing in a vector through the `Status` is possible in multi-scale mode, but requires a little more advanced tinkering with the mapping, as it generates a custom model under the hood and the implementation is less user-friendly.

If you are keen on going down that path, you can find a detailed example here TODO, but we don't recommend it for beginners.

What we'll do instead, is use a ready-made model to provide the thermal time per timestep as a variable, instead of as a single vector in the `Status`.

Our pseudo-multiscale first approach will therefore turn into a genuine multi-scale simulation.

## Adding a second scale

Let's have a model provide the thermal time to our Leaf Area Index model, instead of initializing it through the `Status`. 

There is a model for this purpose, `ToyDegreeDaysCumulModel`, which can also be found in the examples folder.TODO. 

This model doesn't represent a physiological process of the plant, rather an environmental process affecting its physiology. We could therefore have it operate at a different scale unrelated to the plant, which we'll call "Scene". 

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

We can then run the multiscale simulation, with a similar dummy MTG :

```julia
# We didn't use the previous mtg, but it is good practice to avoid unnecessarily mixing data between simulations
mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
out_multiscale = run!(mtg, mapping_multiscale, meteo_day)
```

TODO The output structure, like the mapping, is a Julia Dict structure indexed by scale.

#We can compare the biomass_increment with the equivalent ModelList output, and check results are identical :
#TODO slight result discrepancy

```julia 
out_dataframe_multiscale = collect(Base.Iterators.flatten(out_multiscale["Plant"][:biomass_increment]))
out_singlescale.biomass_increment
```