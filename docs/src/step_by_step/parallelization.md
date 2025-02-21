## Parallel execution

!!! note
    This section is likely to change and become outdated. In any case, parallel execution only currently applies to single-scale simulations (multi-scale simulations' changing MTGs and extra complexity don't allow for straightforward parallelisation)

### FLoops

`PlantSimEngine.jl` uses the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) package to run the simulation in sequential, parallel (multi-threaded) or distributed (multi-process) computations over objects, time-steps and independent processes. 

That means that you can provide any compatible executor to the `executor` argument of [`run!`](@ref). By default, [`run!`](@ref) uses the [`ThreadedEx`](https://juliafolds.github.io/FLoops.jl/stable/reference/api/#executor) executor, which is a multi-threaded executor. You can also use the [`SequentialEx`](https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.SequentialEx)for sequential execution (non-parallel), or [`DistributedEx`](https://juliafolds.github.io/Transducers.jl/dev/reference/manual/#Transducers.DistributedEx) for distributed computations.

### Parallel traits

`PlantSimEngine.jl` uses [Holy traits](https://invenia.github.io/blog/2019/11/06/julialang-features-part-2/) to define if a model can be run in parallel.

!!! note
    A model is executable in parallel over time-steps if it does not uses or set values from other time-steps, and over objects if it does not uses or set values from other objects.

You can define a model as executable in parallel by defining the traits for time-steps and objects. For example, the `ToyLAIModel` model from the [examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/main/examples) can be run in parallel over time-steps and objects, so it defines the following traits:

```julia
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLAIModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLAIModel}) = PlantSimEngine.IsObjectIndependent()
```

By default all models are considered not executable in parallel, because it is the safest option to avoid bugs that are difficult to catch, so you only need to define these traits if it is executable in parallel for them.

!!! tip
    A model that is defined executable in parallel will not necessarily will. First, the user has to pass a parallel `executor` to [`run!`](@ref) (*e.g.* `ThreadedEx`). Second, if the model is coupled with another model that is not executable in parallel, `PlantSimEngine` will run all models in sequential.

### Further executors

You can also take a look at [FoldsThreads.jl](https://github.com/JuliaFolds/FoldsThreads.jl) for extra thread-based executors, [FoldsDagger.jl](https://github.com/JuliaFolds/FoldsDagger.jl) for 
Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon [FoldsCUDA.jl](https://github.com/JuliaFolds/FoldsCUDA.jl) for GPU computations 
(see [this issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues/22)) and [FoldsKernelAbstractions.jl](https://github.com/JuliaFolds/FoldsKernelAbstractions.jl). You can also take a look at 
[ParallelMagics.jl](https://github.com/JuliaFolds/ParallelMagics.jl) to check if automatic parallelization is possible.

Finally, you can take a look into [Transducers.jl's documentation](https://github.com/JuliaFolds/Transducers.jl) for more information, for example if you don't know what is an executor, you can look into [this explanation](https://juliafolds.github.io/Transducers.jl/stable/explanation/glossary/#glossary-executor).
