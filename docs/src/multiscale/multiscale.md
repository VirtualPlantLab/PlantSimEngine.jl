# Multi-scale variable mapping

The previous page showed how to convert a single-scale simulation to multi-scale.

This page provides another example showcasing the nuances in variable mapping, with a more complex fully multiscale version of a prior simulation. The models will all be taken form the [examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/main/examples).

```@contents
Pages = ["multiscale.md"]
Depth = 3
```

## Starting with a single-model mapping

Let's import the `PlantSimEngine` package and all the example models we will use in this tutorial:

```@example usepkg
using PlantSimEngine
using PlantSimEngine.Examples # Import some example models
```

Let's create a simple mapping with only one initial model, the carbon assimilation process ToyAssimModel, which will operate on leaves.
It resembles the ToyAssimGrowth model used in the single-scale simulation [Model switching](@ref) subsection.

Our mapping between scale and model is therefore:

```@example usepkg
mapping = Dict("Leaf" => ToyAssimModel())
```

Just like in single-scale simulations, we can call `to_initialize` to check whether variables need to be initialised. It will this time index by scale:

```@example usepkg
to_initialize(mapping)
```

In this example, the ToyAssimModel needs `:aPPFD` and `:soil_water_content` as inputs, which aren't initialised in our mapping.

The initialization values for the variables can be passed along via a [`Status`](@ref) object:

```@example usepkg
mapping = Dict(
    "Leaf" => (
        ToyAssimModel(),
        Status(aPPFD=1300.0, soil_water_content=0.5),
    ),
)
```

If we call [`to_initialize`](@ref) on this new mapping, it returns an empty dictionary, meaning the mapping is valid, and we can start the simulation:

```@example usepkg
to_initialize(mapping)
```

## Multiscale mapping between models and scales

The `soil_water_content` variable was provided via the mapping. No model affects it, so it is constant in the above example. We could instead provide a model that computes it based on weather data, and/or a more realistic physical process. 

It also makes sense to have that model operate at a different scale than the "Leaf" scale. There is a dummy soil model called `ToySoilModel` in the examples folder. Let's put it at a new "Soil" scale level.

ToyAssimModel is now makes use of the `soil_water_content` variable from the `"Soil"` scale, instead of at its own scale via the `Status` initialization. We therefore need to map `soil_water_content` from the "Soil" to the "Leaf" scale by wrapping `ToyAssimModel` in a `MultiScaleModel`:

```@example usepkg
mapping = Dict(
    "Soil" => ToySoilWaterModel(),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapped_variables=[:soil_water_content => "Soil" => :soil_water_content,],
        ),
        Status(aPPFD=1300.0),        
    ),
);
nothing # hide
```

In this example, we map the `soil_water_content` variable at scale "Leaf" to the `soil_water_content` variable at the `"Soil"` scale. If the name of the variable is the same between both scales, we can omit the variable name at the origin scale, *e.g.* `[:soil_water_content => "Soil"]`.

The variable `aPPFD` is still provided in the `Status` type as a constant value.

We can check again if the mapping is valid by calling [`to_initialize`](@ref):

```@example usepkg
to_initialize(mapping)
```

Once again, `to_initialize` returns an empty dictionary, meaning the mapping is valid.

## A more elaborate multiscale model mapping

Let's now expand this mapping, to showcase other ways in which variables can be mapped from one scale to another. We'll keep the first two models, and add several more to simulate a couple of other processes within our plant.

```@example usepkg
mapping = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.6),
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapped_variables=[
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(carbon_biomass=1.0),
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapped_variables=[:soil_water_content => "Soil", :aPPFD => "Plant"],
        ),
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(carbon_biomass=0.5),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
);
nothing # hide
```

This mapping might seem a little more daunting than previous examples, but several models should be recognizable in passing. In fact, you can consider this mapping to be an enhanced and more complex multi-scale version of a previous single-scale example, the coupling between photosynthesis model, a LAI model and a carbon biomass increment model, used in the [Model switching](@ref) subsection.

```julia
models2 = ModelList(
    ToyLAIModel(),
    Beer(0.5),
    ToyAssimGrowthModel(),
    status=(TT_cu=cumsum(meteo_day.TT),),
)
```

The multi-scale models simulate carbon capture via photosynthesis and carbon allocation for the plant organs' maintenance respiration and development.

The LAI and photosynthesis models are the same as in the ModelList example. The [`ToyDegreeDaysCumulModel`](@ref) provides the Cumulative Thermal Time to the plant. 

The newly introduced models have the following dynamic : 

Carbon allocation is determined (ToyCAllocationModel) for the different organs of the plant (`"Leaf"` and `"Internode"`) from the assimilation at the `"Leaf"` scale (*i.e.* the offer) and their carbon demand (ToyCDemandModel). The `"Soil"` scale is used to compute the soil water content (`ToySoilWaterModel`](@ref)), which is needed to calculate the assimilation at the `"Leaf"` scale (ToyAssimModel). Also note that maintenance respiration at computed at the `"Leaf"` and `"Internode"` scales (ToyMaintenanceRespirationModel), and aggregated to compute the total maintenance respiration at the `"Plant"` scale (ToyPlantRmModel). 

## Different possible variable mappings

The above mapping showcases the different ways to define how the variables are mapped in a `MultiScaleModel` :

```julia
 mapped_variables=[:TT_cu => "Scene",],
```

- At the "Plant" scale, the TT_cu variable is mapped as a scalar from the "Scene" scale. There is only a single "Scene" node in the MTG, and only a single "TT_cu" value per timestep for the simulation.

```julia
:carbon_allocation => ["Leaf"]
```

- On the other hand, we have `:carbon_allocation => ["Leaf"]` at the plant scale for `ToyCAllocationModel`. The `carbon_assimilation` variable is mapped as a vector: there are multiple "Leaf" nodes, but only one "Plant" node, which aggregrates the value over every single leaf. This gives us a 'many-to-one' vector mapping, and in the [`run!`](@ref) functions for models at that scale `carbon_allocation` will be available in the `status` as a vector.

```julia
:carbon_allocation => ["Leaf", "Internode"]
```

- A third type of the mapping would be `:carbon_allocation => ["Leaf", "Internode"]`, which provides values for a variable from several other scales simultaneously. In this case, the values are also available as a vector in the `carbon_assimilation` variable of the [`status`](@ref) inside the model, sorted in the same order as nodes are traversed in the graph.

```julia
:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm]
```

- Finally, to map to a specific variable name at the target scale, *e.g.* `:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm]`. This syntax is useful when the variable name is different between scales, and we want to map to a specific variable name at the target scale. In this example, the variable `Rm_organs` at plant scale takes its values (is mapped) from the variable `Rm` at the `"Leaf"` and `"Internode"` scales.

## Running a simulation

Now that we have a valid mapping, we can run a simulation. Running a multiscale simulation requires a plant graph and the definition of the output variables we want dynamically for each scale.

### Plant graph

We can import an example multi-scale tree graph like so:

```@example usepkg
mtg = import_mtg_example()
```

!!! note
    You can use `import_mtg_example` only if you previously imported the `Examples` sub-module of PlantSimEngine, *i.e.* `using PlantSimEngine.Examples`.

This graph has a root node that defines a scene, then a soil, and a plant with two internodes and two leaves.

### Output variables

For long simulations on plants with many organs, the output data can be very significant. It's possible to restrict the output variables that are tracked for the whole simulation to a subset of all the variables:

```@example usepkg
outs = Dict(
    "Scene" => (:TT, :TT_cu,),
    "Plant" => (:aPPFD, :LAI),
    "Leaf" => (:carbon_assimilation, :carbon_demand, :carbon_allocation, :TT),
    "Internode" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
)
```

This dictionary can be passed to the simulation via the optional `tracked_outputs` keyword argument to the [`run!`](@ref) function (see the next part). If no dictionary is provided, every variable will be tracked.

These variables will be available in the output returned by [`run!`](@ref), with a value for each time step. The corresponding timestep and node in the MTG are also returned. 

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
outputs_sim = run!(mtg, mapping, meteo, tracked_outputs = outs);
nothing # hide
```

And that's it! We can now access the outputs for each scale as a dictionary of vectors of NamedTuple objects.

Or as a `DataFrame` dictionary using the [`DataFrames`](https://dataframes.juliadata.org) package:

```@example usepkg
using DataFrames
df_dict = convert_outputs(outputs_sim, DataFrame)
```