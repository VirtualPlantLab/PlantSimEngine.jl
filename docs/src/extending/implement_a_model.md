# [Model implementation in 5 minutes](@id model_implementation_page)

```@setup usepkg
using PlantSimEngine
@gen_process_methods "light_interception" verbose = false
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

## Introduction

`PlantSimEngine.jl` was designed to make new model implementation very simple. So let's learn about how to implement your own model with a simple example: implementing a new light interception model.

## Inspiration

If you want to implement a new model, the best way to do it is to start from another implementation.

For a complete example, you can look at the code in [`PlantBiophysics.jl`](https://github.com/VEZY/PlantBiophysics.jl), were you will find *e.g.* a photosynthesis model, with the implementation of the `FvCB` model in this Julia file: [src/photosynthesis/FvCB.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/photosynthesis/FvCB.jl); an energy balance model with the implementation of the `Monteith` model in [src/energy/Monteith.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/energy/Monteith.jl); or a stomatal conductance model in [src/conductances/stomatal/medlyn.jl](https://github.com/VEZY/PlantBiophysics.jl/blob/master/src/processes/conductances/stomatal/medlyn.jl).

## Requirements

In those files, you'll see that in order to implement a new model you'll need to implement:

- a structure, used to hold the parameter values and to dispatch to the right method
- the actual model, developed as a method for the process it simulates
- some helper functions used by the package and/or the users

If you create your own process, the function will print a short tutorial on how to do all that, adapted to the process you just created (see [Implement a new process](@ref)).

In this page, we'll just implement a model for a process that exists already: the light interception. This process is defined in `PlantBiophysics.jl`, but also in an example script in this package here: [`examples/light.jl`](https://github.com/VEZY/PlantSimEngine.jl/blob/main/examples/light.jl).

We can include this file like so:

```julia
include(joinpath(dirname(dirname(pathof(PlantSimEngine))), "examples", "light.jl"))
```

But instead of just using it, we will review the script line by line.

## Example: the Beer-Lambert model

### The process

We declare the light interception process at l.7 using [`@gen_process_methods`](@ref): 

```julia
@gen_process_methods "light_interception" verbose = false
```

See [Implement a new process](@ref) for more details on how that works and how to use the process.

### The structure

The first thing to do to implement a model is to define a structure.

The purpose of the structure is two-fold:

- hold the parameter values
- dispatch to the right method when calling the process function

The structure of the model (or type) is defined as follows:

```@example usepkg
struct Beer{T} <: AbstractLight_InterceptionModel
    k::T
end
```

The first line defines the name of the model (`Beer`), which is completely free, except it is good practice to use camel case for the name, *i.e.* using capital letters for the words and no separator `LikeThis`. 

We also can see that we define the `Beer` structure as a subtype of `AbstractLight_InterceptionModel`. This step is very important as it tells to the package what kind of process the model simulates. `AbstractLight_InterceptionModel` is automatically created when defining the process "light_interception".

In our case, it tells us that `Beer` is a model to simulate the light interception process.

Then comes the parameters names, and their types. The type of the parameters is given by the user at instantiation in our example. This is done using the `T` notation as follows:

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

The models are implemented in a function named after the process and a "!\_" as a suffix. The exclamation point is used in Julia to tell users the function is mutating, *i.e.* it modifies its input.

Your implementation should always modify the input status and return nothing. This ensures that models compute fast. The "_" suffix is used to tell users that this is the internal implementation, which is only used by modelers.

Remember that PlantSimEngine only exports the generic functions of the processes to users because they are the one that handles every other details, such as checking that the object is correctly initialized, and applying the computations over objects and time-steps. This is nice because as a developer you don't have to deal with those details, and you can just concentrate on your implementation.

However, you have to remember that if your model calls another one, you'll have to use the internal implementation directly to avoid the overheads of the generic functions (you don't want all these checks).

So if you want to implement a new light interception model, you have to make your own method for the `light_interception!_` function. 

!!! warning
    We need to import all the functions we need to use or extend, so Julia knows we are extending the methods from PlantSimEngine, and not defining our own functions. To do so, we prefix the said functions by the package name, or import them before *e.g.*:
    `import PlantSimEngine: inputs_, outputs_`

So let's do it! Here is our own implementation of the light interception for a `ModelList` component models:

```@example usepkg
function light_interception!_(::Beer, models, status, meteo, constants, extras)
    status.PPFD =
        meteo.Ri_PAR_f *
        exp(-models.light_interception.k * status.LAI) *
        constants.J_to_umol
end
```

The first argument (`::Beer`) means this method will only execute when the function is called with a first argument that is of type `Beer`. This is our way of telling Julia that this method is implementing the `Beer` model for the light interception process.

An important thing to note is that our variables are stored in different structures:

- `models`: lists the processes and the models parameters (we use `k`from Beer here using `models.light_interception.k`)
- `meteo`: the micro-climatic conditions
- `status`: the input and output variables of the models
- `constants`: any constants given as a struct or a `NamedTuple`
- `extras`: any other value or object (*e.g.* it is used to pass the node when computing MTGs)

!!! note
    The micro-meteorological conditions are always given for one time-step inside the models methods, so they are always of `Atmosphere` type. The `Tables.jl` type (*e.g.* `TimeStepTable` or `DataFrame`) conditions are handled earlier by the generic functions, *i.e.* `light_interception()` and `light_interception!()`, not `light_interception!_()`.

OK ! So that's it ? Almost. One last thing to do is to define a method for inputs/outputs so that PlantSimEngine knows which variables are needed for our model, and which it computes. Remember that the actual model is implemented for `light_interception!_`, so we have to tell PlantSimEngine which ones are needed, and what are their default value:

- Inputs: `:LAI`, the leaf area index (m² m⁻²)
- Outputs: `:PPFD`, the photosynthetic photon flux density (μmol m⁻² s⁻¹)

Here is how we communicate that to PlantSimEngine:

```@example usepkg
function PlantSimEngine.inputs_(::Beer)
    (LAI=-Inf,)
end

function PlantSimEngine.outputs_(::Beer)
    (PPFD=-Inf,)
end
```

Note that both function end with an "\_". This is because these functions are internal, they will not be called by the users directly. Users will use [`inputs`](@ref) and [`outputs`](@ref) instead, which call `inputs_` and `outputs_`, but stripping out the default values.

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

Another useful thing to provide to the user is the ability to instantiate your model type with keyword values. You can do it by adding the following method:

```@example usepkg
Beer(;k) = Beer(k)
```

Did you notice the `;` before the argument? It tells Julia that we want those arguments provided as keywords, so now we can call `Beer` like this:

```@example usepkg
Beer(k = 0.7)
```

This is nice when we have a lot of parameters and some with default values, but again, this is completely optional.

One more thing to implement is a method for the `dep` function that tells PlantSimEngine which processes (and models) are needed for the model to run (*i.e.* if your model is coupled to another model).

Our example model does not call another model, so we don't need to implement it. But we can look at *e.g.* the implementation for [`Fvcb`](https://github.com/VEZY/PlantBiophysics.jl/blob/d1d5addccbab45688a6c3797e650a640209b8359/src/processes/photosynthesis/FvCB.jl#L83) in `PlantBiophysics.jl` to see how it works:

```julia
PlantSimEngine.dep(::Fvcb) = (stomatal_conductance=AbstractStomatal_ConductanceModel,)
```

Here we say to PlantSimEngine that the `Fvcb` model needs a model of type `AbstractStomatal_ConductanceModel` in the stomatal conductance process.

The last optional thing to implement is a method for the `eltype` function:

```@example usepkg
Base.eltype(x::Beer{T}) where {T} = T
```

This one helps Julia to know the type of the elements in the structure, and make it faster.

OK that's it! Now we have a full new model implementation for the light interception process! I hope it was clear and you understood everything. If you think some sections could be improved, you can make a PR on this doc, or open an issue so I can improve it.
