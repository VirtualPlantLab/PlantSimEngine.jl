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
    (LAI=Required(Float64),)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=0.0,)
end
```

Write the [`run!`](@ref) function that operates on a single timestep : 

```@example usepkg
function PlantSimEngine.run!(model::Beer, status, environment, constants, context)
    status.aPPFD =
        environment.Ri_PAR_f *
        exp(-model.k * status.LAI) *
        constants.J_to_umol
    return nothing
end
```

And that is all you need to get going, for this example with a single parameter and no interdependencies. 

The [`@process`](@ref) macro does some boilerplate work described [here](@ref under_the_hood)

Some context utility functions can also be interesting to implement to make users' lives simpler. See the [Model implementation additional notes](@ref) page for details.
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
- dispatch to the right [`run!`](@ref) method when calling it

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

When implementing a new model, it is necessary to declare what variables it
reads and what variables it computes. Every input declaration must say whether
the input is required or has a genuine model default. A required input is
initialized by the user in a `Status` object or bound from another model. A
defaulted input needs neither. Output variables may be retained as simulation
outputs and/or used by other models.

In our case, the `Beer` model, computing light interception, has one input variable and one output variable:

- Inputs: `:LAI`, the leaf area index (m² m⁻²)
- Outputs: `:aPPFD`, the photosynthetic photon flux density (μmol m⁻² s⁻¹)

We declare these inputs/outputs by adding methods for the underscore extension
functions. `inputs_` returns a `NamedTuple` whose values are `Required(T)` or
`Default(value)` declarations. `outputs_` returns a `NamedTuple` whose values
are the initial output state:

```@example usepkg
function PlantSimEngine.inputs_(::Beer)
    (LAI=Required(Float64),)
end

function PlantSimEngine.outputs_(::Beer)
    (aPPFD=0.0,)
end
```

`LAI` has no scientifically meaningful fallback, so it is required. If the
model instead had an optional efficiency of `0.8`, it would declare
`efficiency=Default(0.8)`. Do not use sentinel values such as `-Inf` to mean
"required": they are ordinary values and hide the model contract.

`Required(Float64)` is an expected type, not an initialization value. A model
that supports a broader or parameterized type can declare that type instead.
PlantSimEngine does not convert status values to `Float64`.

These extension functions end with an "\_". Simulation users instead use
[`inputs`](@ref), [`outputs`](@ref), [`init_variables`](@ref), and
[`explain_initialization`](@ref) to inspect the contract.

### The run! method

When running a simulation with [`run!`](@ref), each model is run at its
scheduled timestep, following the dependency order compiled from model
applications, inputs, and manual calls. Each model has its own [`run!`](@ref)
method for updating the current state. The function takes five arguments:

```julia
function PlantSimEngine.run!(model::Beer, status, environment, constants, context)
```

- model: the current model instance, used for dispatch and parameter access.
- status: a [`Status`](@ref) object, which contains the current values (*i.e.* state) of the variables for **one** time-step (e.g. the value of the plant LAI at time t)
- environment: the sampled model-facing environment for the current target and
  timestep.
- constants: a `Constants` object, or a `NamedTuple`, which contains the values of the constants for the simulation (*e.g.* the value of the Stefan-Boltzmann constant, unit-conversion constants...)
- context: PlantSimEngine's runtime context for hard calls and lifecycle
  operations.

A typical [`run!`](@ref) function can therefore use simulation constants,
input/output variables accessible through the [`Status`](@ref) object, or
weather data.

Here is the [`run!`](@ref) implementation of the light interception model.
Note that the input and output variables are accessed through the
`status` argument:

```@example usepkg
function PlantSimEngine.run!(model::Beer, status, environment, constants, context)
    status.aPPFD =
        environment.Ri_PAR_f *
        exp(-model.k * status.LAI) *
        constants.J_to_umol
    return nothing
end
```

### Additional notes

To use this model, simulation users must supply or bind every `Required` status
input. Inputs declared with `Default` are initialized automatically. Required
environment variables and constants must also be available through their
respective contracts.

!!! Note
    [`Status`](@ref) objects contain the current state of the simulation. It is not, by default, possible to make use of earlier variable states, unless a custom model is written for that purpose.

Model parameters are read directly from the current model instance. For
example, the `k` parameter of the `Beer` model is `model.k`.

!!! warning
    Prefix functions you extend with `PlantSimEngine.`, or import them first,
    for example `import PlantSimEngine: inputs_, outputs_`. Otherwise Julia
    defines an unrelated function in your module instead of adding a method to
    PlantSimEngine's function.

OK that's it! We now a full new model implementation for the light interception process! Other models might be more complex in terms of what computations they do, or how they couple with other models, but the approach remains the same.

### Dependencies

If your model explicitly calls another model, you need to tell PlantSimEngine about it. This is called a hard dependency, in opposition to a soft dependency, which is when your model uses a variable from another model, but does not call it explicitly.

To do so, we can add a method to the [`dep`](@ref) function that tells PlantSimEngine which processes (and models) are needed for the model to run.

Our example model does not call another model, so we don't need to implement it. But we can look at *e.g.* the implementation for [`Fvcb`](https://github.com/VEZY/PlantBiophysics.jl/blob/d1d5addccbab45688a6c3797e650a640209b8359/src/processes/photosynthesis/FvCB.jl#L83) in `PlantBiophysics.jl` to see how it works:

```julia
PlantSimEngine.dep(::Fvcb) = (stomatal_conductance=AbstractStomatal_ConductanceModel,)
```

Here we say to PlantSimEngine that the `Fvcb` model needs a model of type `AbstractStomatal_ConductanceModel` in the stomatal conductance process.

This is intentionally process-based because `dep(model)` is a model-author
contract. The model author cannot know which application name a future scenario
will choose for stomatal conductance. In a concrete scenario, users should wire
the selected producer or callee with `application=...` in `ModelSpec(...; inputs=...)` or
`ModelSpec(...; calls=...)` when that application is known:

```julia
ModelSpec(ParentModel(); name=:parent, calls=(:stomata => One(scale=:Leaf, application=:stomatal_conductance)))
```

You can read more about hard dependencies in [Coupling more complex models](@ref).
