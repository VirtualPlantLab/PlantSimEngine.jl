# Model coupling for users

```@setup usepkg
using PlantSimEngine
include(joinpath(dirname(dirname(pathof(PlantSimEngine))), "examples", "dummy.jl"))
```

`PlantSimEngine.jl` is designed to make model coupling simple for both the modeler and the user. For example, `PlantBiophysics.jl` implements the [`Fvcb`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Fvcb) model to simulate the photosynthesis process. This model needs the stomatal conductance process to be simulated, so it calls the `stomatal_conductance_` function at some point. Note that it does not force any model for its computation, just the process. This ensures that users can choose whichever model they want to use for this simulation, independent of the photosynthesis model.

We provide an example script that implements three dummy processes in [`examples/dummy`](https://github.com/VEZY/PlantSimEngine.jl/blob/main/examples/dummy.jl). We also provide an example model implementation for each, that makes a sequential coupling, meaning that the third model uses the second one, which uses the first one.

!!! tip
    Model coupling is usually done when there are some kind of iterative computation in one of the models that depend on one another. This is not the case in our example here as it is obviously just a simple one. In this case the coupling is not really necessary as models could just be called sequentially one after the other. For a more representative example, you can look at the energy balance computation of Monteith in `PlantBiophysics.jl`, which is coupled to a photosynthesis model.

Back to our example, we have three processes called "process1", "process2" and "process3". Then we have one model implementation for each, called `Process1Model`, `Process2Model` and `Process3Model`.
So in practice, using `Process3Model` requires a "process2" model, and in our case the only model available is `Process2Model`. The latter also requires a "process1" model, and again we only have one model implementation for this process, which is `Process1Model`. 

Let's include this script so we can play around:

```@example usepkg
include(joinpath(dirname(dirname(pathof(PlantSimEngine))), "examples", "dummy.jl"))
```

!!! tip
    Use subtype(x) to know which models are available for a process, e.g. for "process1" you can do `subtypes(AbstractProcess1Model)`.

Here is how we can make the models coupling:

```@example usepkg
m = ModelList(
    process1 = Process1Model(2.0), 
    process2 = Process2Model(),
    process3 = Process3Model()
)
```

We can see that only the first model has a parameter. You can usually know that by looking at the help of the structure (*e.g.* `?Process1Model`), else, you can still look at the field names of the structure like so `fieldnames(Process1Model)`.

Note that the user only declares the models, not the way the models are coupled, because `PlantSimEngine.jl` deals with that automatically.

Now the example above returns some warnings saying we need to initialize some variables: `var1` and `var2`. `PlantSimEngine.jl` automatically computes which variables should be initialized based on the inputs and outputs of all models, considering their coupling.

For example `Process1Model` requires the following variables as inputs:

```@example usepkg
inputs(Process1Model(2.0))
```

And the `Process2Model` model requires the following variables:

```@example usepkg
inputs(Process2Model())
```

We see that `var1` is needed as inputs of both models, but we also see that `var3` is an output of `Process2Model`:

```@example usepkg
outputs(Process2Model())
```

So considering those two models, we only need `var1` and `var2` to be initialized as `var3` is computed. This is why we recommend [`to_initialize`](@ref) instead of [`inputs`](@ref), because it returns only the variables that need to be initialized, considering that some inputs are duplicated between models, and some are computed by other models (they are outputs of a model):

```@example usepkg
m = ModelList(
    process1 = Process1Model(2.0), 
    process2 = Process2Model(),
    process3 = Process3Model(),
    variables_check=false # Just so we don't have the warning printed out
)

to_initialize(m)
```

The most straightforward way of initializing a model list is by giving the initializations to the `status` keyword argument during instantiation:

```@example usepkg
m = ModelList(
    process1 = Process1Model(2.0), 
    process2 = Process2Model(),
    process3 = Process3Model(),
    status = (var1=15.0, var2=0.3)
)
```

Our component models structure is now fully parameterized and initialized for a simulation!

Let's simulate it:

```@example usepkg
process3(m)
```