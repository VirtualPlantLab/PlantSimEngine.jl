# Model coupling for modelers

```@setup usepkg
using PlantSimEngine, PlantMeteo
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))
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

This section uses notions from the previous section. If you are not familiar with the concepts of model coupling in PlantSimEngine, please read the previous section first: [Model coupling for users](@ref).

## Hard coupling

A model that calls explicitly another process is called a hard-coupled model. It is implemented by calling the process function directly.

Let's go through the example processes and models from a script provided by the package here [examples/dummy.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/dummy.jl)

In this script, we declare seven processes and seven models, one for each process. The processes are simply called "process1", "process2"..., and the model implementations are called `Process1Model`, `Process2Model`...

`Process2Model` calls `Process1Model` explicitly, which defines `Process1Model` as a hard-dependency of `Process2Model`. The is as follows:

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

A hard-dependency must always be declared to PlantSimEngine. This is done by adding a method to the `dep` function. For example, the hard-dependency to `process1` into `Process2Model` is declared as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=AbstractProcess1Model,)
```

This way PlantSimEngine knows that `Process2Model` needs a model for the simulation of the `process1` process. Note that we don't add any constraint to the type of model we have to use (we use `AbstractProcess1Model`), because we want any model implementation to work with the coupling, as we only are interested in the value of a variable, not the way it is computed.

Even if it is discouraged, you may have a valid reason to force the coupling with a particular model, or a kind of models though. For example, if we want to use only `Process1Model` for the simulation of `process1`, we would declare the dependency as follows:

```julia
PlantSimEngine.dep(::Process2Model) = (process1=Process1Model,)
```

## Soft coupling

A model that takes outputs of another model as inputs is called a soft-coupled model. There is nothing to do on the modeler side to declare a soft-dependency. The detection is done automatically by PlantSimEngine using the inputs and outputs of the models.