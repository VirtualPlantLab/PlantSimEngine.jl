# Model coupling for users

`PlantSimEngine.jl` is designed to make model coupling simple for both the modeler and the user. For example, `PlantBiophysics.jl` implements the [`Fvcb`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Fvcb) model to simulate the photosynthesis process. This model needs the stomatal conductance process to be simulated, so it calls the `stomatal_conductance_` function at some point. Note that it does not force any model for its computation, just the process. This ensures that users can choose whichever model they want to use for this simulation, independent of the photosynthesis model. 

So in practice, using `Fvcb` requires a stomatal conductance model in the `ModelList` to compute `Gₛ`. We can use the one from Medlyn et al. (2011) as an example:

```@example usepkg
m = ModelList(photosynthesis = Fvcb(), stomatal_conductance = Medlyn(0.03, 12.0))
```

Note that the user only declares the models, not the way the models are coupled, because `PlantSimEngine.jl` deals with that automatically.

Now the example above returns some warnings saying we need to initialize some variables. The `Fvcb` model requires the following variables as inputs:

```@example usepkg
inputs(Fvcb())
```

And the [`Medlyn`](@ref) model requires the following variables:

```@example usepkg
inputs(Medlyn(0.03, 12.0))
```

We see that `A` is needed as input of `Medlyn`, but we also know that it is an output of `Fvcb`. This is why we prefer using [`to_initialize`](@ref) instead of [`inputs`](@ref), because it returns only the variables that need to be initialized, considering that some inputs are duplicated between models, and some are computed by other models (they are outputs of a model):

```@example usepkg
m = ModelList(
    photosynthesis = Fvcb(),
    stomatal_conductance = Medlyn(0.03, 12.0)
)

to_initialize(m)
```

The most straightforward way of initializing a model list is by giving the initializations to the `status` keyword argument during instantiation:

```@example usepkg
m = ModelList(
    photosynthesis = Fvcb(),
    stomatal_conductance = Medlyn(0.03, 12.0),
    status = (Tₗ = 25.0, PPFD = 1000.0, Cₛ = 400.0, Dₗ = 0.82)
)
```

Our component models structure is now fully parameterized and initialized for a simulation!

Let's simulate it:

```@example usepkg
photosynthesis(m)
```