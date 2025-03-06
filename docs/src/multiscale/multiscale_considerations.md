# Multi-scale considerations

```@contents
Pages = ["multiscale_considerations.md"]
Depth = 3
```

This page briefly details the subtle ways in which multi-scale simulations differ from prior single-scale simulations. The next few pages will showcase some of these subtleties with examples.

Declaring and running a multi-scale simulation follows the same general workflow as the single-scale version, but multi-scale simulations do have some differences : 

- a simulation requires a Multi-scale Tree Graph (MTG) to run and operates on that graph
- when running, models are tied to a scale and only access local information
- models can run multiple times per timestep, 
- the `ModelList` is replaced by a slightly more complex model mapping to link models to the scale they will operate at.

The simulation dependency graph will still be computed automatically and handle most couplings, meaning users don't need to specify the order of model execution once the extra code to declare the models is written. You will still need to declare hard dependencies, with extra considerations for multi-scale hard dependencies.

Multi-scale simulations also tend to require more extra ad hoc models to prepare some variables for some models.

## Related pages

Other pages in the multiscale section describe :

- How to write a direct conversion of a single-scale ModelList simulation to a multi-scale simulation and add a second scale to it: [Converting a single-scale simulation to multi-scale](@ref), 
- A more complex multi-scale version of the single-scale simulation showcasing different variable mappings between scales: [Multi-scale variable mapping](@ref), 
- A three-part tutorial describing how to build up a combination of models to simulate a growing toy plant: [Writing a multiscale simulation](@ref),
- Ways to handle situations where a variable ends up causing a cyclic dependency: [Avoiding cyclic dependencies](@ref),
- Multi-scale specific coupling considerations and subtleties:[Handling dependencies in a multiscale context](@ref)

## Multi-scale tree graphs

Functional-Structural Plant Models are often about simulating plant growth. A multi-scale simulation is implicitely expected to operate on a plant-like object, represented by a multi-scale tree graph.

A multi-scale tree graph (MTG) object (see the [Multi-scale Tree Graphs](@ref) subsection for a quick description) is therefore required to run a multi-scale simulations. It can be a dummy MTG if the simulation doesn't actually affect it, but is nevertheless a required argument to the multi-scale `run` function.

All the multi-scale examples make use of the companion package [MultiScaleTreeGraph.jl](https://github.com/VEZY/MultiScaleTreeGraph.jl), which we therefore recommend for running your own multi-scale simulations.

!!! note 
    Multi-scale Tree Graphs make use of conflicting terminology with PlantSimEngine's concepts, which is discussed in [Organ/Scale](@ref). If you are new to the concepts, make sure to read that section and keep note of it.

## Models run once per organ instance, not once per organ level

Some models, like the ones we've seen in single-scale simulations, work on a very simple model of a whole plant.

More fine-grained models can be tied to a specific plant organ. 

For instance, a model computing a leaf's surface area depending on its age would operate at the "leaf" scale, and be called **for every leaf** at every timestep. On the other hand, a model computing the plant's total leaf area only needs to be run once per timestep, and can be run at the "Plant" scale.

This is a major difference between a single-scale simulation and a multi-scale one. By default, any model in a single-scale simulation will only run **once** per timestep. However, in multi-scale, if a plant has several instances of an organ type -say it has a hundred leaves- then any model operating at the "Leaf" scale will by default run one hundred times per timestep, unless it is explicitely controlled by another model (which can happen in hard dependency configurations).

## Mappings

When users define which models they use, PlantSimEngine cannot determine in advance which scale level they operate at. This is partly because the plant organs in an MTG do not have standardized names, and partly because some plant organs might not be part of the initial MTG, so parsing it isn't enough to infer what scales are used.

The user therefore needs to indicate for a simulation's which models are related to which scale.

A multi-scale mapping links models to the scale at which they operate, and is implemented as a Julia `Dict`, tying a scale, such as "Leaf" to models operating at that scale, such as "LeafSurfaceAreaModel". It is the equivalent of a `ModelList` in a single-scale simulation.

Multi-scale models can be similar models to the ones found in earlier sections, or, if they need to make use of variables at other scales, may need to be wrapped as part of a `MultiScaleModel` object. Many models are not tied to a particular scale, which means those models can be reused at different scales or in single-scale simulations.

## The simulation operates on an MTG

Unlike in single-scale simulations, which make use of a `Status` object to store the current state of every variable in a simulation, multi-scale simulations operate on a per-organ basis. 

This means every organ instance has its own `Status`, with scale-specific attributes.

This has two **important** consequences in terms of running a simulation :

- First, **any scale absent from the MTG will not be run**. If your MTG contains no leaves, then no model operating at the scale "Leaf" will be able to run until a "Leaf" organ is created and a node is added in the MTG. Otherwise, it has no MTG node to operate on. The only exceptions are hard dependency models which can be called from a different scale, since they can be called directly by a model on a node at a different existing scale, even if there is no node at their own scale.

- Secondly, models only have access to **local** organ information. The `status` argument in the `run!` function only contains variables **at the model's scale**, unless variables from other scales are mapped via a `MultiScaleModel` wrapping. 

## The run! function's signature

The `run!` function differs slightly from its single-scale version. The current structure (excluding a couple of advanced/deprecated kwargs) is the following:

```julia
run!(mtg, mapping, meteo, constants, extra; nsteps, tracked_outputs)
```

Instead of a `ModelList`, it takes an MTG and a mapping. The optional `meteo` and `constants` argument are identical to the single-scale version. The `extra` argument is now reserved and should not be used. A new `nsteps` keyword argument is available to restrict the simulation to a specified number of steps. 

## Outputs

The output structure, like the mapping, is a Julia `Dict` structure indexed by scale. TODO node

Multi-scale simulations, especially for plants which have thousands of leaves, internodes, root branches, buds and fruits, may compute huge amounts of data. Just like in single-scale simulations, it is possible to keep only variables whose values you want to track for every timestep, and filter the rest out, using the `tracked_outputs` keyword argument for the `run!` function. 

Those tracked variables also need to be indexed by scale to avoid ambiguity: 

```julia
outs = Dict(
    "Scene" => (:TT, :TT_cu,),
    "Plant" => (:aPPFD, :LAI),
    "Leaf" => (:carbon_assimilation, :carbon_demand, :carbon_allocation, :TT),
    "Internode" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
)
```

## Coupling and multi-scale hard dependencies

Multi-scale brings new types of coupling: mappings are part of the approach used to handle variables used by models at different scales. A model can also have a hard dependency on another model that operates at another scale. This multi-scale-specific complexity is discussed in [Handling dependencies in a multiscale context](@ref)