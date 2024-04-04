# Multi-scale modeling

## What is multi-scale modeling?

Multi-scale modeling is the process of simulating a system at multiple levels of detail simultaneously. For example, some models can run at the organ scale while others run at the plot scale. Each model can access variables at its scale and other scales if needed, allowing for a more comprehensive system representation. It can also help identify emergent properties that are not apparent at a single level of detail. 

For example, a model of photosynthesis at the leaf scale can be combined with a model of carbon allocation at the plant scale to simulate the growth and development of the plant. Another example is a combination of models to simulate the energy balance of a forest. To simulate it, you need a model for each organ type of the plant, another for the soil, and finally, one at the plot scale, integrating all others.

PlantSimEngine provides a framework for multi-scale modeling to seamlessly integrate models at different scales, keeping all nice functionalities provided at one scale. A nice feature is that models do not need to be aware of the scale at which they are running, nor about the scales at which their inputs are computed, or outputs will be given, which means the model can be reused at different scales or no scale.

PlantSimEngine automatically computes the dependency graph between mono and multi-scale models, considering every combination of models at any scale, to determine the order of model execution. This means that the user does not need to worry about the order of model execution and can focus on the model definition and the mapping between models and scales.

Using PlantSimEngine for multi-scale modeling is relatively easy and follows the same rules as mono-scale models. Let's dive into the details with a short tutorial.

## Simple mapping between models and scales

To get started, we have to define a mapping between models and scales.

Let's import the `PlantSimEngine` package and example models we will use in this tutorial:

```@example usepkg
using PlantSimEngine
using PlantSimEngine.Examples # Import some example models
```

!!! note
    The `Examples` submodule exports a few simple models we will use in this tutorial. The models are also found in the `examples` folder of the package.

We now have access to models for the simulation of different processes. We can associate each model with a scale by defining a mapping between models and scales. The mapping is a dictionary with the name of the scale as the key and the model as the value. For example, we can define a mapping to simulate the assimilation process at the leaf scale with `ToyAssimModel` as follows:

```@example usepkg
mapping = Dict("Leaf" => ToyAssimModel())
```

In this example, the dictionary's key is the name of the scale (`"Leaf"`), and the value is the model. The model is an example model provided by `PlantSimEngine`, so we must prefix it with the module name.

We can check if the mapping is valid by calling `to_initialize`:

```@example usepkg
to_initialize(mapping)
```

The `to_initialize` function checks if models from any scale need further initialization before simulation. This is the case when some input variables of the model are not computed by another model. In this example, the `ToyAssimModel` needs `:aPPFD` and `:soil_water_content` as inputs. To run a simulation, we must provide a value for the variables or a model that simulates them.

The initialization values for the variables can be provided using the `Status` type along with the model, *e.g.*:

```@example usepkg
mapping = Dict(
    "Leaf" => (
        ToyAssimModel(),
        Status(aPPFD=1300.0, soil_water_content=0.5),
    ),
)
```

!!! note 
    The model and the `Status` are provided as a `Tuple` to the `"Leaf"` scale.

If we re-execute `to_initialize`, we get an empty dictionary, meaning the mapping is valid, and we can start the simulation:

```@example usepkg
to_initialize(mapping)
```

## Multiscale mapping between models and scales

In our previous example, we provided the value for the `soil_water_content` variable. However, we could also provide a model that simulates it at the soil scale. The only difference now is that we have to tell PlantSimEngine that our 
`ToyAssimModel` is now multiscale and takes the `soil_water_content` variable from the `"Soil"` scale. We can do that by wrapping the `ToyAssimModel` in a `MultiScaleModel`:

```@example usepkg
mapping = Dict(
    "Soil" => ToySoilWaterModel(),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil" => :soil_water_content,],
        ),
        Status(aPPFD=1300.0),        
    ),
);
nothing # hide
```

The `MultiScaleModel` takes two arguments: the model and the mapping between the model and the scales. The mapping is a vector of pairs of pairs mapping the variable's name with the name of the scale its value comes from, and the name of the variable at that scale. In this example, we map the `soil_water_content` variable at scale "Leaf" to the `soil_water_content` variable at the `"Soil"` scale. If the name of the variable is the same between both scales, we can omit the variable name at the origin scale, *e.g.* `[:soil_water_content => "Soil"]`.

!!! note 
    The variable `aPPFD` is still provided in the `Status` type as a constant value.

We can check again if the mapping is valid by calling `to_initialize`:

```@example usepkg
to_initialize(mapping)
```

`to_initialize` returns an empty dictionary, meaning the mapping is valid.

## More on MultiScaleModel

`MultiScaleModel` is a wrapper around a model that allows it to take inputs or give outputs from other scales. It takes two arguments: the model and the mapping between the model and the scales. The mapping is a vector of pairs of pairs mapping the variable's name with the name of the scale its value comes from, and its name at that scale.

The variable can map a single value if there is only one node to map to or a vector of values if there are several. It can also map to several types of nodes at the same time.

Let's take a look at a more complex example of a mapping:

```@example usepkg
mapping = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapping=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.6),
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapping=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(biomass=1.0),
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil", :aPPFD => "Plant"],
        ),
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapping=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(biomass=0.5),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
);
nothing # hide
```

In this example, we expect to make a simulation at five different scales: `"Scene"`, `"Plant"`, `"Internode"`, `"Leaf"`, and `"Soil"`. The `"Scene"` scale represents the whole scene, where one or several plants can live. The `"Plant"` scale is, well, the whole plant scale, `"Internode"` and `"Leaf"` are organ scales, and `"Soil"` is the soil scale. This mapping is used to compute the carbon allocation (`ToyCAllocationModel`) to the different organs of the plant (`"Leaf"` and `"Internode"`) from the assimilation at the `"Leaf"` scale (*i.e.* the offer) and their carbon demand (`ToyCDemandModel`). The `"Soil"` scale is used to compute the soil water content (`ToySoilWaterModel`), which is needed to calculate the assimilation at the `"Leaf"` scale (`ToyAssimModel`). We also can note that we compute the maintenance respiration at the `"Leaf"` and `"Internode"` scales (`ToyMaintenanceRespirationModel`), which is summed up to compute the total maintenance respiration at the `"Plant"` scale (`ToyPlantRmModel`). 

We see that all scales are interconnected, with computations at the organ scale that may depend on the soil scale and at the plant scale that depends on the organ scale and scene scale.

Something important to note here is that we have different ways to define the mapping for the `MultiScaleModel`. For example, we have `:carbon_assimilation => ["Leaf"]` at the plant scale for `ToyCAllocationModel`. This mapping means that the variable `carbon_assimilation` is mapped to the `"Leaf"` scale. However, we could also have `:carbon_assimilation => "Leaf"`, which is not completely equivalent.

!!! note
    Note the difference between `:carbon_assimilation => ["Leaf"]` and `:carbon_assimilation => "Leaf"` is that "Leaf" is given as a vector in the first definition, and as a scalar in the second one.

The difference is that the first one maps to a vector of values, while the second one maps to a single value. The first one is useful when we don't know how many nodes there will be in the plant of type `"Leaf"`. In this case, the values are available as a vector in the `carbon_assimilation` variable of the `status` inside the model. The second one should only be used if we are sure that there will be only one node at this scale, and in this case, the one and single value is given as a scalar in the `carbon_assimilation` variable of the `status` inside the model.

A third form for the mapping would be `:carbon_assimilation => ["Leaf", "Internode"]`. This form is useful when we need values for a variable from several scales simultaneously. In this case, the values are available as a vector in the `carbon_assimilation` variable of the `status` inside the model, sorted in the same order as nodes are traversed in the graph.

A last form is to map to a specific variable name at the target scale, *e.g.* `:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm]`. This form is useful when the variable name is different between scales, and we want to map to a specific variable name at the target scale. In this example, the variable `Rm_organs` at plant scale takes its values (is mapped) from the variable `Rm` at the `"Leaf"` and `"Internode"` scales.

## Running a simulation

Now that we have a valid mapping, we can run a simulation. Running a multiscale simulation requires two more things compared to what we saw previously: a plant graph and the definition of the output variables we want dynamically for each scale.

### Plant graph

We can import an example multi-scale tree graph like so:

```@example usepkg
mtg = import_mtg_example()
```

!!! note
    You can use `import_mtg_example` only if you previously imported the `Examples` sub-module of PlantSimEngine, *i.e.* `using PlantSimEngine.Examples`.

This graph has a root node that defines a scene, then a soil, and a plant with two internodes and two leaves.

### Output variables

Models can access only one time step at a time, so the output at the end of a simulation is only the last time step. However, we can define a list of variables we want to get dynamically for each time step and each scale. This list is given as a dictionary with the name of the scale as the key and a vector of variables as the value. For example, we can define a list of variables we want to get at each time step for different scales as follows:

```@example usepkg
outs = Dict(
    "Scene" => (:TT, :TT_cu, :node),
    "Plant" => (:aPPFD, :LAI),
    "Leaf" => (:carbon_assimilation, :carbon_demand, :carbon_allocation, :TT),
    "Internode" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
)
```

These variables will be available in the `outputs` field of the simulation object, with a value for each time step. 

### Meteorological data

As for mono-scale models, we need to provide meteorological data to run a simulation. We can use the `PlantMeteo` package to generate some dummy data for two time steps:

```@example usepkg
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f = 200.0),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8, Ri_PAR_f = 180.0)
]
)
```

### Simulation

Let's make a simulation using the graph and outputs we just defined:

```@example usepkg
sim = run!(mtg, mapping, meteo, outputs = outs);
nothing # hide
```

And that's it! 

We can now access the outputs for each scale as a dictionary of vectors of values per variable and scale like this:

```@example usepkg
outputs(sim);
nothing # hide
```

Or as a `DataFrame` using the `DataFrames` package:

```@example usepkg
using DataFrames
outputs(sim, DataFrame)
```

The values for the last time-step of the simulation are also available from the statuses:

```@example usepkg
status(sim);
nothing # hide
```

This is a dictionary with the scale as the key and a vector of `Status` as values, one per node of that scale. So, in this example, the `"Leaf"` scale has two nodes, so the value is a vector of two `Status` objects, and the `"Soil"` scale has only one node, so the value is a vector of one `Status` object.

### Wrapping up

In this section, we saw how to define a mapping between models and scales, run a simulation, and access the outputs.

This is just a simple example, but PlantSimEngine can be used to define and combine much more complex models at multiple scales of detail. With its modular architecture and intuitive API, PlantSimEngine is a powerful tool for multi-scale plant growth and development modeling.