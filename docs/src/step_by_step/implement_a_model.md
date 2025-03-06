# [Implementing a model](@id model_implementation_page)

```@setup usepkg
using PlantSimEngine
@process "light_interception" verbose = false
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

For your own simulations, you might want to move beyond simple usage at some point and implement your own models. In this page, we'll go through the required steps for writing a new model. The detailed version is tailored for people less familiar with programming.

## Quick version

Declare a new process : 

```julia
@process "light_interception" verbose = false
```

Declare your model struct, and its parameters : 

```@example usepkg
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

Declare the `inputs_` and `outputs_` methods for that model (note the '_', these methods are distinct from `inputs` and `outputs`)

```@example usepkg
function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=-Inf,)
end
```

Write the `run!` function that operates on a single timestep : 

```@example usepkg
function run!(::Beer, models, status, meteo, constants, extras)
    status.PPFD =
        meteo.Ri_PAR_f *
        exp(-models.light_interception.k * status.LAI) *
        constants.J_to_umol
end
```

Determine if parallelization is possible, and which traits to declare :

```@example usepkg
PlantSimEngine.ObjectDependencyTrait(::Type{<:Beer}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Beer}) = PlantSimEngine.IsTimeStepIndependent()
```

And that is all you need to get going, for this example with a single parameter and no interdependencies. 

The `@process` macro does some boilerplate work described [here](@ref under_the_hood)

Some extra utility functions can also be interesting to implement to make users' lives simpler. See the [Model implementation additional notes](@ref) page for details.
If your custom model needs to handle more complex couplings than the simple input/output described in this example, check out the [Coupling more complex models](@ref) page.

## Detailed version

`PlantSimEngine.jl` was designed to make new model implementation very simple. So let's learn about how to implement your own model with a simple example: implementing a new light interception model.

The model we'll (re)implement is available as an example model from the `Examples` sub-module. You can access the script from here: [`examples/Beer.jl`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/Beer.jl). It is also available in the `PlantBioPhysics.jl` package.

You can import the model and PlantSimEngine's other example models into your environment with `using`:

```julia
# Import the example models defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```

## Other examples

`PlantSimEngine`'s other toy models can be found in the [examples](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples) folder.

For other examples, you can look at the code in [`PlantBiophysics.jl`](https://github.com/VEZY/PlantBiophysics.jl), where you will find *e.g.* a photosynthesis model, with the implementation of the `FvCB` model in [src/photosynthesis/FvCB.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/photosynthesis/FvCB.jl); an energy balance model with the implementation of the `Monteith` model in [src/energy/Monteith.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/energy/Monteith.jl); or a stomatal conductance model in [src/conductances/stomatal/medlyn.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/conductances/stomatal/medlyn.jl).

## Requirements

If you have a look at example models, you'll see that in order to implement a new model you'll need to implement:

- a structure, used to hold the parameter values and to dispatch to the right method
- the actual model, developed as a method for the process it simulates
- some helper functions used by the package and/or the users

TODO If you create your own process, the function will print a short tutorial on how to do all that, adapted to the process you just created (see [Implementing a new process](@ref)).

## Example: the Beer-Lambert model

### The process

We start by declaring the light interception process at l.7 using [`@process`](@ref): 

```julia
@process "light_interception" verbose = false
```

See [Implementing a new process](@ref) for more details on how that works and how to use the process.

### The structure

To implement a model, the first thing to do is to define a structure. The purpose of this structure is two-fold:

- hold the parameter values
- dispatch to the right `run!` method when calling it

The structure of the model (or type) is defined as follows:

```@example usepkg
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

The first line defines the name of the model (`Beer`). It is good practice to use camel case for the name, *i.e.* using capital letters for the words and no separator `LikeThis`. 

The `Beer` structure is defined as a subtype of `AbstractLight_InterceptionModel` indicating what kind of process the model simulates. The `AbstractLight_InterceptionModel` type is automatically created when defining the process "light_interception".

We can therefore infer from the declaration that `Beer` is a model to simulate the light interception process.

Then come the parameters names, and their types. 

### User types and parametric types

There is a little Julia specificity here, to enable the user to pass their own types to the simulation.

- `Beer` is a parameterized `struct`, indicated by the `{T}` annotation
- We indicate the `k` parameter is of type `T` by adding `::T` after the name.

The `T` is an arbitrary letter here. If you have parameters that you know will be of different types, you can either force their type, or make them parameterizable too, using another letter, *e.g.*:

```julia
struct CustomModel{T,S} <: AbstractLight_InterceptionModel
    k::T
    x::T
    y::T
    z::S
end
```

Parameterized types are practical because they let the user choose the type of the parameters, and potentially change them at runtime. For example a user could use the `Particles` type from [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) for automatic uncertainty propagation throughout the simulation. We refer you to the [Parametric types](@ref) subsection of the [Model implementation additional notes](@ref) page for more information on parametric types.

### Inputs and outputs

When implementing a new model, it is necessary to declare what variables will be required, whether provided as an input to our model or computed for every timestep as an output. Input variables will either be initialized by the user in a `Status` object, or provided by another model. Output variables may be global simulation outputs and/or used by other models.

In our case, the `Beer` model, computing light interception, has one input variable and one output variable:

- Inputs: `:LAI`, the leaf area index (m² m⁻²)
- Outputs: `:aPPFD`, the photosynthetic photon flux density (μmol m⁻² s⁻¹)

We declare these inputs/outputs by adding a method for the [`inputs`](@ref) and [`outputs`](@ref) functions. These functions take the type of the model as argument, and return a `NamedTuple` with the names of the variables as keys, and their default values as values:

```@example usepkg
function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=-Inf,)
end
```

These functions are internal, and end with an "\_". Users instead use [`inputs`](@ref) and [`outputs`](@ref) to query model variables.

### The run! method

When running a simulation with `run!`, each model is run in turn at every timestep, following whatever order was deduced from the ModelList definition and Status. Each model also has its [`run!`](@ref) method for that purpose that update the simulation's current state, with a slightly different signature. The function takes six arguments:

```julia
function run!(::Beer, models, status, meteo, constants, extras)
```

- the model's type
- models: a `ModelList` object, which contains all the models of the simulation
- status: a `Status` object, which contains the current values (*i.e.* state) of the variables for **one** time-step (e.g. the value of the plant LAI at time t)
- meteo: (usually) an `Atmosphere` object, or a row of the meteorological data, which contains the current values of the meteorological variables for **one** time-step (*e.g.* the value of the PAR at time t)
- constants: a `Constants` object, or a `NamedTuple`, which contains the values of the constants for the simulation (*e.g.* the value of the Stefan-Boltzmann constant, unit-conversion constants...)
- extras: any other object you want to pass to your model, mostly for advanced usage, not detailed here

A typical `run!` function can therefore make use of simulation constants, input/output variables accessible through the `Status` object, or weather data. 

Here is the `run!` implementation of the light interception for a `ModelList` component models. Note that the input and output variable are accessed through the `status` argument :

```@example usepkg
function run!(::Beer, models, status, meteo, constants, extras)
    status.PPFD =
        meteo.Ri_PAR_f *
        exp(-models.light_interception.k * status.LAI) *
        constants.J_to_umol
end
```

### Additional notes

To use this model, users will have to make sure that the variables for that model are defined in the `Status` object, the meteorology, and the `Constants` object.

!!! Note
    `Status` objects contain the current state of the simulation. It is not, by default, possible to make use of earlier variable states, unless a custom model is written for that purpose.

Model parameters are available from the `ModelList` that is passed via the `models` argument. Index by the process name, then the parameter name. For example, the `k` parameter of the `Beer` model is found in `models.light_interception.k`.

TODO
!!! warning
    You need to import all the functions you want to extend, so Julia knows your intention of adding a method to the function from PlantSimEngine, and not defining your own function. To do so, you have to prefix the said functions by the package name, or import them before *e.g.*: `import PlantSimEngine: inputs_, outputs_`

### Parallelization traits

`PlantSimEngine` defines traits to get additional information about the models. At the moment, there are two traits implemented that help the package to know if a model can be run in parallel over space (*i.e.* objects) and/or time (*i.e.* time-steps).

By default, all models are assumed to be **not** parallelizable over objects and time-steps, because it is the safest default. If your model is parallelizable, you should add the trait to the model.

For example, if we want to add the trait for parallelization over objects to our `Beer` model, we would do:

```@example usepkg
PlantSimEngine.ObjectDependencyTrait(::Type{<:Beer}) = PlantSimEngine.IsObjectIndependent()
```

And if we want to add the trait for parallelization over time-steps to our `Beer` model, we would do:

```@example usepkg
PlantSimEngine.TimeStepDependencyTrait(::Type{<:Beer}) = PlantSimEngine.IsTimeStepIndependent()
```

!!! note
    A model is parallelizable over objects if it does not call another model directly inside its code. Similarly, a model is parallelizable over time-steps if it does not get values from other time-steps directly inside its code. In practice, most of the models are parallelizable one way or another, but it is safer to assume they are not.

OK that's it! Now we have a full new model implementation for the light interception process! I hope it was clear and you understood everything. If you think some sections could be improved, you can make a PR on this doc, or open an issue.


### Dependencies

If your model explicitly calls another model, you need to tell PlantSimEngine about it. This is called a hard dependency, in opposition to a soft dependency, which is when your model uses a variable from another model, but does not call it explicitly.

To do so, we can add a method to the `dep` function that tells PlantSimEngine which processes (and models) are needed for the model to run.

Our example model does not call another model, so we don't need to implement it. But we can look at *e.g.* the implementation for [`Fvcb`](https://github.com/VEZY/PlantBiophysics.jl/blob/d1d5addccbab45688a6c3797e650a640209b8359/src/processes/photosynthesis/FvCB.jl#L83) in `PlantBiophysics.jl` to see how it works:

```julia
PlantSimEngine.dep(::Fvcb) = (stomatal_conductance=AbstractStomatal_ConductanceModel,)
```

Here we say to PlantSimEngine that the `Fvcb` model needs a model of type `AbstractStomatal_ConductanceModel` in the stomatal conductance process.

You can read more about hard dependencies in [Coupling more complex models](@ref).
