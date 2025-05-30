# Model execution

## Simulation order

`PlantSimEngine.jl` uses the [`ModelList`](@ref) to automatically compute a dependency graph between the models and run the simulation in the correct order. When running a simulation with [`run!`](@ref), the models are then executed following this simple set of rules:

1. Independent models are run first. A model is independent if it can be run independently from other models, only using initializations (or nothing).
2. Then, models that have a dependency on other models are run. The first ones are the ones that depend on an independent model. Then the ones that are children of the second ones, and then their children ... until no children are found anymore. There are two types of children models (*i.e.* dependencies): hard and soft dependencies:
   1. Hard dependencies are always run before soft dependencies. A hard dependency is a model that is directly called by another model. It is declared as such by its parent that lists its hard-dependencies as `dep`. See [this example](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/3d91bb053ddbd087d38dcffcedd33a9db35a0fcc/examples/dummy.jl#L39) that shows `Process2Model` defining a hard dependency on any model that simulates `process1`.
   2. Soft dependencies are then run sequentially. A model has a soft dependency on another model if one or more of its inputs is computed by another model. If a soft dependency has several parent nodes (*e.g.* two different models compute two inputs of the model), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.
