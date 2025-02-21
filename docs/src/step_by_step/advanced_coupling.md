# Coupling more complex models

```@setup usepkg
using PlantSimEngine, PlantMeteo
# Import the example models defined in the `Examples` sub-module:
using PlantSimEngine.Examples

m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
)
```

When two or more models have a two-way interdependency (rather than variables flowing out only one-way from one model into the next), we describe it as a [hard dependency](TODO).

This kind of interdependency requires a little more work from the user/modeler for PlantSimEngine to be able to automatically create the dependency graph.

## Declaring hard dependencies

A model that explicitly and directly calls another process in its `run!` function is part of a hard dependency, or a hard-coupled model. 

Let's go through the example processes and models from a script provided by the package here [examples/dummy.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/dummy.jl)

In this script, we declare seven processes and seven models, one for each process. The processes are simply called "process1", "process2"..., and the model implementations are called `Process1Model`, `Process2Model`...

When run, `Process2Model` calls another process's `run!` function which requires defining that process as a hard-dependency of `Process2Model` :

```julia
function PlantSimEngine.run!(::Process2Model, models, status, meteo, constants, extra)
    # computing var3 using process1:
    run!(models.process1, models, status, meteo, constants)
    # computing var4 and var5:
    status.var4 = status.var3 * 2.0
    status.var5 = status.var4 + 1.0 * meteo.T + 2.0 * meteo.Wind + 3.0 * meteo.Rh
end
```

We see that coupling a model (`Process2Model`) to another process (`process1`) is done by calling the `run!` function again. The `run!` function is called with the same arguments as the `run!` function of the model that calls it, except that we pass the process we want to simulate as the first argument.

!!! note
    We don't enforce any type of model to simulate `process1`. This is the reason why we can switch so easily between model implementations for any process, by just changing the model in the `ModelList`.

A hard-dependency must always be declared to PlantSimEngine. This is done by adding a method to the `dep` function when implementing the model. For example, the hard-dependency to `process1` into `Process2Model` is declared as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=AbstractProcess1Model,)
```

This way PlantSimEngine knows that `Process2Model` needs a model for the simulation of the `process1` process. To avoid imposing a specific model to be coupled with `Process2Model`, the dependency only requires a model that is a subtype of the abstract parent type `AbstractProcess1Model`. This avoids constraining to the specific `Process1Model` implementation, meaning an alternate model computing the same variables for the same process is still interchangeable with `Process1Model`.

While not encouraged, if you have a valid reason to force the coupling with a particular model, you can force the dependency to require that model specifically. For example, if we want to use only `Process1Model` for the simulation of `process1`, we would declare the dependency as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=Process1Model,)
```

## 

There are examples in PlantBioPhysics of such models TODO. 