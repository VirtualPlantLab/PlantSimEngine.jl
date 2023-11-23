# Model coupling for users

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

`PlantSimEngine.jl` is designed to make model coupling simple for both the modeler and the user. For example, `PlantBiophysics.jl` implements the [`Fvcb`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Fvcb) model to simulate the photosynthesis process. This model needs the stomatal conductance process to be simulated, so it calls again `run!` inside its implementation at some point. Note that it does not force any kind of conductance model over another, just that there is one to simulate the process. This ensures that users can choose whichever model they want to use for this simulation, independent of the photosynthesis model.

We provide an example script that implements seven dummy processes in [`examples/dummy`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/dummy.jl). The processes are simply called "process1", "process2"..., and the model implementations are called `Process1Model`, `Process2Model`... 

## Hard coupled models

The `Process3Model` calls `Process2Model`, and `Process2Model` calls `Process1Model`. This explicit call is called a hard-dependency in PlantSimEngine.

The other models for the other processes are called `Process4Model`, `Process5Model`... and they do not call explicitly other models when running, but some outputs of the models are used as inputs of other models. This is called a soft-dependency in PlantSimEngine.

!!! tip
    Hard-coupling of models is usually done when there are some kind of iterative computation in one of the models that depend on one another. This is not the case in our example here as it is obviously just a simple one. In this case the coupling is not really necessary as models could just be called sequentially one after the other. For a more representative example, you can look at the energy balance computation of Monteith in `PlantBiophysics.jl`, which is hard-coupled to a photosynthesis model.

Back to our example, using `Process3Model` requires a "process2" model, and in our case the only model available is `Process2Model`. The latter also requires a "process1" model, and again we only have one model implementation for this process, which is `Process1Model`. 

Let's use the `Examples` sub-module so we can play around:

```julia
# Import the example models defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```

!!! tip
    Use subtype(x) to know which models are available for a process, e.g. for "process1" you can do `subtypes(AbstractProcess1Model)`.

Here is how we can make the model coupling:

```@example usepkg
m = ModelList(Process1Model(2.0), Process2Model(), Process3Model())
nothing # hide
```

We can see that only the first model has a parameter. You can usually know that by looking at the help of the structure (*e.g.* `?Process1Model`), else, you can still look at the field names of the structure like so `fieldnames(Process1Model)`.

Note that the user only declares the models, not the way the models are coupled because `PlantSimEngine.jl` deals with that automatically.

Now the example above returns some warnings saying we need to initialize some variables: `var1` and `var2`. `PlantSimEngine.jl` automatically computes which variables should be initialized based on the inputs and outputs of all models, considering their hard or soft-coupling.

For example, `Process1Model` requires the following variables as inputs:

```@example usepkg
inputs(Process1Model(2.0))
```

And `Process2Model` requires the following variables:

```@example usepkg
inputs(Process2Model())
```

We see that `var1` is needed as inputs of both models, but we also see that `var3` is an output of `Process2Model`:

```@example usepkg
outputs(Process2Model())
```

So considering those two models, we only need `var1` and `var2` to be initialized, as `var3` is computed. This is why we recommend [`to_initialize`](@ref) instead of [`inputs`](@ref), because it returns only the variables that need to be initialized, considering that some inputs are duplicated between models, and some are computed by other models (they are outputs of a model):

```@example usepkg
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    variables_check=false # Just so we don't have the warning printed out
)

to_initialize(m)
```

The most straightforward way of initializing a model list is by giving the initializations to the `status` keyword argument during instantiation:

```@example usepkg
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    status = (var1=15.0, var2=0.3)
)
nothing # hide
```

Our component models structure is now fully parameterized and initialized for a simulation!

Let's simulate it:

```@example usepkg
using PlantMeteo
meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995)

run!(m, meteo)

m[:var5]
```


## Soft coupled models

All following models (`Process4Model` to `Process7Model`) do not call explicitly other models when running, but some outputs of the models are used as inputs of other models. This is called a soft-dependency in PlantSimEngine.

Let's make a new model list including the soft-coupled models:

```@example usepkg
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
)
nothing # hide
```

With this list of models, we only need to initialize `var0`, that is an input of `Process4Model` and `Process7Model`:

```@example usepkg
to_initialize(m)
```

We can initialize it like so:

```@example usepkg
m = ModelList(
    Process1Model(2.0), 
    Process2Model(),
    Process3Model(),
    Process4Model(),
    Process5Model(),
    Process6Model(),
    Process7Model(),
    status = (var0=15.0,)
)
nothing # hide
```

Let's simulate it:

```@example usepkg
using PlantMeteo
meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995)

run!(m, meteo)

status(m)
```

## Simulation order

When calling `run!`, the models are run in the right order using a dependency graph that is computed automatically based on the hard and soft dependencies of the models following a simple set of rules:

1. Independent models are run first. A model is independent if it can be run alone, or only using initializations. It is not dependent on any other model.
2. From their children dependencies:
   1. Hard dependencies are always run before soft dependencies. Inner hard dependency graphs are considered as a whole, *i.e.* as a single soft dependency.
   2. Soft dependencies are then run sequentially. If a soft dependency has several parent nodes (*i.e.* its inputs are computed by several models), it is run only if all its parent nodes have been run already. In practice, when we visit a node that has one of its parent that did not run already, we stop the visit of this branch. The node will eventually be visited from the branch of the last parent that was run.
