# Model execution 

## Simulation order 

`PlantSimEngine.jl` uses the [`ModelList`](@ref) to automatically compute a dependency graph between the models and run the simulation in the correct order. When running a simulation with [`run!`](@ref), the models are then executed following this simple set of rules:

1. Independent models are run first. A model is independent if it can be run independently from other models, only using initializations (or nothing). 
2. Then, models that have a dependency on other models are run. The first ones are the ones that depend on an independent model. Then the ones that are children of the second ones, and then their children ... until no children are found anymore. There are two types of children models (*i.e.* dependencies): hard and soft dependencies:
   1. Hard dependencies are always run before soft dependencies. A hard dependency is a model that list dependencies in their own method for `dep`. See [this example](https://github.com/VEZY/PlantSimEngine.jl/blob/3d91bb053ddbd087d38dcffcedd33a9db35a0fcc/examples/dummy.jl#L39) that shows `Process2Model` defining a hard dependency on any model that simulate `process1`. Inner hard dependency graphs (*i.e.* consecutive hard-dependency children) are considered as a single soft dependency.
   2. Soft dependencies are then run sequentially. A model has a soft dependency on another model if one or more of its inputs is computed by another model. If a soft dependency has several parent nodes (*e.g.* two different models compute two inputs of the model), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.

## Parallel execution

`PlantSimEngine.jl` uses the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) package to run the simulation in sequential, parallel (multi-threaded) or distributed (multi-process) computations over objects, time-steps and independent processes. 

That means that you can provide any compatible executor to the `executor` argument of [`run!`](@ref). By default, [`run!`](@ref) uses the [`ThreadedEx`](https://juliafolds.github.io/FLoops.jl/stable/reference/api/#executor) executor, which is a multi-threaded executor. You can also use the [`SequentialEx`](https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.SequentialEx)for sequential execution (non-parallel), or [`DistributedEx`](https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.DistributedEx) for distributed computations.

You can also take a look at [FoldsThreads.jl](https://github.com/JuliaFolds/FoldsThreads.jl) for extra thread-based executors, [FoldsDagger.jl](https://github.com/JuliaFolds/FoldsDagger.jl) for 
Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon [FoldsCUDA.jl](https://github.com/JuliaFolds/FoldsCUDA.jl) for GPU computations 
(see [this issue](https://github.com/VEZY/PlantSimEngine.jl/issues/22)) and [FoldsKernelAbstractions.jl](https://github.com/JuliaFolds/FoldsKernelAbstractions.jl). You can also take a look at 
[ParallelMagics.jl](https://github.com/JuliaFolds/ParallelMagics.jl) to check if automatic parallelization is possible.

Finally, you can take a look into [Transducers.jl's documentation](https://github.com/JuliaFolds/Transducers.jl) for more information, for example if you don't know what is an executor, you can look into [this explanation](https://juliafolds.github.io/Transducers.jl/stable/explanation/glossary/#glossary-executor).