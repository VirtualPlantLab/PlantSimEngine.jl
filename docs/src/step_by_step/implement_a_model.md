# [Model implementation in 5 minutes](@id model_implementation_page)

```@setup usepkg
using PlantSimEngine
@process "light_interception" verbose = false
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

You'll probably want to move beyond simple usage at some point and implement your own models.

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

And that is all you need to get going, for this simple example with a single parameter and no interdependencies. 

The `@process` macro does some boilerplate work described [here](@ref under_the_hood)

If you have more than one parameter, then type conversion utility functions might also be interesting to implement. See here TODO
If you need to deal with more complex couplings, the hard dependency section will detail

## Detailed version

`PlantSimEngine.jl` was designed to make new model implementation very simple. So let's learn about how to implement your own model with a simple example: implementing a new light interception model.

## Inspiration

If you want to implement a new model, the best way to do it is to start from another implementation.

For a complete example, you can look at the code in [`PlantBiophysics.jl`](https://github.com/VEZY/PlantBiophysics.jl), were you will find *e.g.* a photosynthesis model, with the implementation of the `FvCB` model in this Julia file: [src/photosynthesis/FvCB.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/photosynthesis/FvCB.jl); an energy balance model with the implementation of the `Monteith` model in [src/energy/Monteith.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/energy/Monteith.jl); or a stomatal conductance model in [src/conductances/stomatal/medlyn.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/conductances/stomatal/medlyn.jl).

`PlantSimEngine` also provide toy models that can be used as a base to better understand how to implement a new model: 

- The Beer model for light interception in [examples/Beer.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/Beer.jl)
- A toy LAI development in [examples/ToyLAIModel.jl](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyLAIModel.jl)

## Requirements

In those files, you'll see that in order to implement a new model you'll need to implement:

- a structure, used to hold the parameter values and to dispatch to the right method
- the actual model, developed as a method for the process it simulates
- some helper functions used by the package and/or the users

If you create your own process, the function will print a short tutorial on how to do all that, adapted to the process you just created (see [Implementing a new process](@ref)).

In this page, we'll just implement a model for a process that already exists: the light interception. This process is defined in `PlantBiophysics.jl`, and also made available as an example model from the `Examples` sub-module. You can access the script from here: [`examples/Beer.jl`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/Beer.jl).

We can import the model like so:

```julia
# Import the example models defined in the `Examples` sub-module:
using PlantSimEngine.Examples
```

But instead of just using it, we will review the script line by line.

## Example: the Beer-Lambert model

### The process

We declare the light interception process at l.7 using [`@process`](@ref): 

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

The first line defines the name of the model (`Beer`), which is completely free, except it is good practice to use camel case for the name, *i.e.* using capital letters for the words and no separator `LikeThis`. 

We also can see that we define the `Beer` structure as a subtype of `AbstractLight_InterceptionModel`. This step is very important as it tells to the package what kind of process the model simulates. `AbstractLight_InterceptionModel` is automatically created when defining the process "light_interception".

In our case, it tells us that `Beer` is a model to simulate the light interception process.

Then comes the parameters names, and their types. The type of parameters is given by the user at instantiation in our example. This is done using the `T` notation as follows:

- we say that our structure `Beer` is a parameterized `struct` by putting `T` in between brackets after the name of the `struct`
- We put `::T` after our parameter name in the `struct`. This way Julia knows that our parameter will be of type `T`.

The `T` is completely free, you can use any other letter or word instead. If you have parameters that you know will be of different types, you can either force their type, or make them parameterizable too, using another letter, *e.g.*:

```julia
struct YourStruct{T,S} <: AbstractLight_InterceptionModel
    k::T
    x::T
    y::T
    z::S
end
```

Parameterized types are very useful because they let the user choose the type of the parameters, and potentially dispatch on them.

But why not forcing the type such as the following:

```julia
struct YourStruct <: AbstractLight_InterceptionModel
    k::Float64
    x::Float64
    y::Float64
    z::Int
end
```

Well, you can do that. But you'll lose a lot of the magic Julia has to offer this way.

For example a user could use the `Particles` type from [MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl) to make automatic uncertainty propagation, and this is only possible if the type is parameterizable.

### The method

The models are implemented by adding a method for its type to the [`run!`](@ref) function. The exclamation point at the end of the function name is used in Julia to tell users that the function is mutating, *i.e.* it modifies its input.

The function takes six arguments:

- the type of your model
- models: a `ModelList` object, which contains all the models of the simulation
- status: a `Status` object, which contains the current values (*i.e.* state) of the variables for **one** time-step (e.g. the value of the plant LAI at time t)
- meteo: (usually) an `Atmosphere` object, or a row of the meteorological data, which contains the current values of the meteorological variables for **one** time-step (*e.g.* the value of the PAR at time t)
- constants: a `Constants` object, or a `NamedTuple`, which contains the values of the constants for the simulation (*e.g.* the value of the Stefan-Boltzmann constant)
- extras: any other object you want to pass to your model. This is for advanced users, and is not used in this example. Note that it is used to pass the `Node` when simulating a MultiScaleTreeGraph.

Your implementation can use any variables or parameters in these objects. The only thing you have to do is to make sure that the variables you use are defined in the `Status` object, the meteorology, and the `Constants` object.

The variables you use from the `Status` must be declared as inputs of your model. And the ones you modify must be declared as outputs. We'll that below.

!!! warning
    Models implementations are done for **one** time-step by design. The values of the previous time-step is always available in the `status` (*e.g.* `status.biomass`) as long as the variable is an output of your model. This is because at the end of a time-step, the `Status` object is recycled for the next time-step and so the latest computed values are always available. This is why it is possible to increment a value every time-step using *e.g.* `status.biomass += 1.0`. By design models don't have access to values prior to the one before. If you're not convinced by this approach, ask yourself how the plant knows the value of *e.g.* LAI from 15 days ago. It doesn't. It only knows its current state. Most of the time-sensitive variables really are just an accumulation of values until a threshold anyway. BUt if you really need to use values from the past (*e.g.* 15 time-steps before), you can add a variable to the `Status` object that is uses like a queue (see *e.g.* [DataStructures.jl](https://juliacollections.github.io/DataStructures.jl/stable/)).

`PlantSimEngine` then automatically deals with every other detail, such as checking that the object is correctly initialized, applying the computations over objects and time-steps. This is nice because as a developer you don't have to deal with those details, and you can just concentrate on your model implementation.

!!! warning
    You need to import all the functions you want to extend, so Julia knows your intention of adding a method to the function from PlantSimEngine, and not defining your own function. To do so, you have to prefix the said functions by the package name, or import them before *e.g.*: `import PlantSimEngine: inputs_, outputs_`

So let's do it! Here is our own implementation of the light interception for a `ModelList` component models:

```@example usepkg
function run!(::Beer, models, status, meteo, constants, extras)
    status.PPFD =
        meteo.Ri_PAR_f *
        exp(-models.light_interception.k * status.LAI) *
        constants.J_to_umol
end
```

The first argument (`::Beer`) means this method will only execute when the function is called with a first argument that is of type `Beer`. This is our way of telling Julia that this method implements the `Beer` model for the light interception process.

An important thing to note is that the model parameters are available from the `ModelList` that is passed via the `models` argument. Then parameters are found in field called by the process name, and the parameter name. For example, the `k` parameter of the `Beer` model is found in `models.light_interception.k`.

One last thing to do is to define the inputs and outputs of our model. This is done by adding a method for the [`inputs`](@ref) and [`outputs`](@ref) functions. These functions take the type of the model as argument, and return a `NamedTuple` with the names of the variables as keys, and their default values as values.

In our case, the `Beer` model has one input and one output:

- Inputs: `:LAI`, the leaf area index (m² m⁻²)
- Outputs: `:aPPFD`, the photosynthetic photon flux density (μmol m⁻² s⁻¹)

Here is how we communicate that to PlantSimEngine:

```@example usepkg
function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=-Inf,)
end
```

Note that both functions end with an "\_". This is because these functions are internal, they will not be called by the users directly. Users will use [`inputs`](@ref) and [`outputs`](@ref) instead, which call `inputs_` and `outputs_`, but stripping out the default values.

### The utility functions

Before running a simulation, you can do a little bit more for your implementation (optional).

First, you can add a method for type promotion. It wouldn't make any sense for our example because we have only one parameter. But we can make another example with a new model that would be called `Beer2` that would take two parameters:

```julia
struct Beer2{T} <: AbstractLight_InterceptionModel
    k::T
    x::T
end
```

To add type promotion to `Beer2` we would do:

```julia
function Beer2(k,x)
    Beer2(promote(k,x))
end
```

This would allow users to instantiate the model parameters using different types of inputs. For example they may use this:

```julia
Beer2(0.6,2)
```

You don't see a problem? Well your users won't either. But there's one: `Beer2` is a parametric type, so all fields share the same type `T`. This is the `T` in `Beer2{T}` and then in `k::T` and `x::T`. And this force the user to give all parameters with the same type.

And in our example above, the user provides `0.6` for `k`, which is a `Float64`, and `2` for `x`, which is an `Int`. ANd if you don't have type promotion, Julia will return an error because both should be either `Float64` or `Int`. That's were the promotion comes in handy, it will convert all your inputs to a common type (when possible). In our example it will convert `2` to `2.0`.

A second thing also is to help your user with default values for some parameters (if applicable). For example a user will almost never change the value of `k`. So we can provide a default value like so:

```@example usepkg
Beer() = Beer(0.6)
```

Now the user can call `Beer` with zero value, and `k` will default to `0.6`.

Another useful thing is the ability to instantiate your model type with keyword arguments, *i.e.* naming the arguments. You can do it by adding the following method:

```@example usepkg
Beer(;k) = Beer(k)
```

Did you notice the `;` before the argument? It tells Julia that we want those arguments provided as keywords, so now we can call `Beer` like this:

```@example usepkg
Beer(k = 0.7)
```

This is nice when we have a lot of parameters and some with default values, but again, this is completely optional.

The last optional thing to implement is a method for the `eltype` function:

```@example usepkg
Base.eltype(x::Beer{T}) where {T} = T
```

This one helps Julia know the type of the elements in the structure, and make it faster.

### Traits

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
