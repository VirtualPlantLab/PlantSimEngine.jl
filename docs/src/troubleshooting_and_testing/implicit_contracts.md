This page summarizes some of the assumptions, coupling constraints and inner workings of PlantSimEngine which may be particular relevant when implementing new models.

If you are unsure of an implementation subtlety, check this page out to see whether it answers your question.

```@contents
Pages = ["implicit_contracts.md"]
Depth = 2
```

## Weather data provides the simulation timestep, but models can veer away from it

The weather data timesteps, whether hourly or daily, provide the pace at which most other models run.

In XPalm, weather data for most models is provided daily, meaning biomass calculations are also provided daily. 

Many models are considered to be steady-state over that timeframe, but not all : the leaf pruning model pertubes the plant in a non-steady state fashion, for example. Models that require computations over several iterations to stabilise (often part of hard dependencies) might also have a timestep unrelated to the weather data.

!!! Note
    Implicitely, this means any vector variables given as input to the simulation must be consistent with the number of weather timesteps. Providing one weather value but a larger vector variable is an exception : the weather data is replicated over each timestep. (This may be subject to change in the future when support for different timesteps in a single simulation is implemented)

## Weather data must be interpolated prior to simulation

If your weather data isn't adjusted to conform to a regular timestep, you will need to adjust it to fit that constraint. PlantSimEngine does no interpolation prior to simulation and expects regular weather timesteps.

## No cyclic dependencies in the simplified dependency graph

The model dependency graph used for running the simulation is comprised of soft and hard dependency nodes, and the final version only links soft dependency nodes together, and is expected to contain no cycles.

Any user model coupling which causes a cyclic dependency to occur will require some extra tinkering to run : either design models differently, create a hard dependency with some of the problematic models, or break the cycle by having a variable take the previous timestep's value as input.

See [Dependency graphs](@ref) and the following subsections for more discussion related to dependency graph constraints.

Note : Only the previous timestep is accessible in PlantSimEngine without any kind of dedicated model. How to create a model to store more past timesteps of a specific variable is described in the [Tips and workarounds](@ref) page: [Making use of past states in multi-scale simulations](@ref)

## Hard dependencies need to be declared in the model definition

Hard dependencies are handled internally by their owning soft dependency model, ie the hard dep's run! function is directly called by the soft dependency's run!.

The current way in which PlantSimEngine creates its dependency graph requires users to declare what process is required in the hard dependency and which scale it pulls the model and its variables from.

## Parallelisation opportunities must be part of the model definition

Traits that indicate that a model is independent or objects need to be part of the model definition. Modelers need to keep this in mind when implementing new models.

This is currently mostly a concern for single-scale simulations, as multi-scale simulations are not currently parallelised ; a more involved scheduler would need to be implemented when MTGs are modified by models, and to handle more interesting parallelisation opportunities at specific scales. 

There may be new parallelisation features for multi-plant simulations further down the road.

## Hard dependencies can only have one parent in the dependency graph

The final dependency graph is comprised only of soft dependency nodes, and is guaranteed to contain no cycles. Hard dependencies are handled internally by their soft dependency ancestor. To avoid any ambiguity in terms of processing order, only one soft dependency node can 'own' a hard dependency And similarly, nested hard dependencies only have a single soft dependency ancestor.

This is not solely an implementation detail of PlantSimEngine's internal mechanisms ; if your simulation requires complex coupling, you might need to carefully consider how to manage your hard dependencies, or insert an extra intermediate model to simplify things.

## A model can only be used once per scale

Similarly, to avoid depedency graph ambiguity (and for simulation cohesion), PlantSimEngine currently assumes a model describing a process only occurs once per scale.

Model renaming and duplicating works around this assumption. It may change once multi-plant/multi-species features are implemented.

## No two variables with the same name at the same scale

This rule avoids potential ambiguity which could then cause both problems in terms of model ordering during the simulation, as well as incorrectly coupling models with the wrong variable.

A workaround for some of the situations where this occurs is described here : [Having a variable simultaneously as input and output of a model](@ref)

## TODO Organs missing in the MTG but declared in the mapping ?

## Status template intialisation order TODO 

## TODO simulation order, node order, etc.

## Simulation order instability when adding models

An important aspect to bear in mind is that PlantSimEngine automatically determines an order in which models are run from the dependency graph it generates by coupling models together. 

This order of simulation depends on the way the models link together. If you replace a model by a new set of models, or pass in new variables that create new links between models, you may change the simulation order.

When iterating and slowly making a simulation more physiologically realistic and complex, it is therefore fully possible that the order in which two models are run is flipped by a user change. 

This design choice implementation -a concession made for ease of use and flexibility when developing a simulation- means that until your set of models is fully stabilized and you know which variables are `PreviousTimestep` and what order models run in, as you expand and change the set you might see differences of execution of one timestep for some models. It isn't a conceptual problem as most models are steady-state, and simulation order is stable for a given set of models, but it does mean PlantSimEngine will be less conveient for some types of simulation.