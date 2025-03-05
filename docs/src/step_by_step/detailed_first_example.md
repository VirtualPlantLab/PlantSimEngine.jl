# Detailed walkthrough of a simple simulation

This section walks you through the ins and outs of a basic simulation, mostly aimed at people who have less experience programming, to showcase the various concepts presented earlier and requirements for a simulation in context.

The full example discussed in this page can be found further down(TODO ref Example simulation).


```@setup usepkg
using PlantSimEngine, PlantMeteo
using PlantSimEngine.Examples
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))
out_sim = run!(leaf, meteo)
```

## Definitions

### Processes

A process in this package defines a biological or physical phenomena. Think of any process happening in a system, such as light interception, photosynthesis, water, carbon and energy fluxes, growth, yield or even electricity produced by solar panels.

A process is "declared", meaning we define a process, and then implement models for its simulation. In this example, we will make use of a process that was already defined, and for which there already is a model implementation.

### Models (ModelList)

A process is simulated using a particular implementation, or **a model**. Each model is implemented using a structure that lists the parameters of the model. For example, PlantBiophysics provides the [`Beer`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Beer) structure for the implementation of the Beer-Lambert law of light extinction. The process of `light_interception` and the `Beer` model are provided as an example 
script in this package too at [`examples/Beer.jl`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl).

Models can use several types of entries:

- Parameters
- Meteorological information
- Variables
- Constants
- Extras

- Parameters are constant values that are used by the model to compute its outputs, and are exclusive to that model. 
- Meteorological information contains values that are provided by the user and are used as inputs to the model. It is defined for one time-step, and `PlantSimEngine.jl` takes care of applying the model to each time-steps given by the user. 
- Variables are either used or computed by the model and can optionally be initialized before the simulation. They can be part of multiple models, computed by one and then used as an input by another. They can also be a global simulation output, or be provided at the start of a simulation by the user. 
- Constants are constant values, usually common between models, *e.g.* the universal gas constant. And extras are just extra values that can be used by a model.

Users declare a set of models used for simulation, as well as the necessary parameters for each model, and whatever variables need to be initialized. This is done using a [`ModelList`](@ref) structure. 

For example let's instantiate a [`ModelList`](@ref) with a single model : the Beer-Lambert model of light extinction, used to simulate the light interception process. The model is implemented with the [`Beer`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl) structure and only has one parameter: the extinction coefficient (`k`).

Importing the package:

```@example usepkg
using PlantSimEngine
```

Import the examples defined in the `Examples` sub-module (`light_interception` and `Beer`):

```julia
using PlantSimEngine.Examples
```

And then declare a [`ModelList`](@ref) with the `Beer` model:

```@example usepkg
m = ModelList(Beer(0.5))
```

What happened here? We provided an instance of the `Beer` model to a [`ModelList`](@ref) to simulate the light interception process.

## Parameters

A parameter is a value constant for a simulation that is internal to a model and used for its computations. For example, the Beer-Lambert model uses the extinction coefficient (`k`) to compute the light extinction. The `Beer` structure in the Beer-Lambert model implementation,  only has one field: `k`. We can see that using `fieldnames` on the model structure:

```@example usepkg
fieldnames(Beer)
```

## Variables (inputs, outputs)

Variables are either inputs or outputs (*i.e.* computed) of models. Variables and their values are stored in the [`ModelList`](@ref) structure, and are initialized automatically or manually.

For example, the `Beer` model needs the leaf area index (`LAI`, m² m⁻²) to run.

We can see which variables are passed in as inputs using [`inputs`](@ref):

```@example usepkg
inputs(Beer(0.5))
```

and which are computed outputs of the model using [`outputs`](@ref):

```@example usepkg
outputs(Beer(0.5))
```

The [`ModelList`](@ref) structure will keep track of every variable's current state when running the simulation, storing them in a field called `status`. We can inspect that field with the `status` function and see that in our example it has two variables: `LAI` and `PPFD`. The first is an input, the second an output (*i.e.* it is computed by the model).

```@example usepkg
m = ModelList(Beer(0.5))
keys(status(m))
```

To know which variables should be initialized, we can use [`to_initialize`](@ref):

```@example usepkg
m = ModelList(Beer(0.5))
to_initialize(m)
```

Their values are uninitialized though (hence the warnings):

```@example usepkg
(m[:LAI], m[:aPPFD])
```

Uninitialized variables are initialized to the value given in the `inputs` or `outputs` methods in the model's implementation code, which is usually equal to `typemin()`, *e.g.* `-Inf` for `Float64`.

!!! tip
    Prefer using `to_initialize` rather than `inputs` to check which variables should be initialized. `inputs` returns every variable that is needed by the model to run, but in multi-model simulations, some of them may already be computed by other models and not require initialization. `to_initialize` returns **only** the variables that are needed by the model to run and that are not initialized in the `ModelList`.

We can initialize the required variables by providing their starting values to the status when declaring the `ModelList`:

```@example usepkg
m = ModelList(Beer(0.5), status = (LAI = 2.0,))
```

Or after instantiation using [`init_status!`](@ref):

```@example usepkg
m = ModelList(Beer(0.5))

init_status!(m, LAI = 2.0)
```

We can check if a component is correctly initialized using [`is_initialized`](@ref):

```@example usepkg
is_initialized(m)
```

Some variables are inputs of models, but outputs of other models. When we couple models, `to_initialize` only requests the variables that are not computed by other models.

## Climate forcing

To make a simulation, we usually need the climatic/meteorological conditions measured close to the object or component.

Users are strongly encouraged to use [`PlantMeteo.jl`](https://github.com/PalmStudio/PlantMeteo.jl), the companion package that helps manage such data, with default pre-computations and structures for efficient computations. The most basic data structure from this package is a type called [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere), which defines steady-state atmospheric conditions, *i.e.* the conditions are considered at equilibrium. Another structure is available to define different consecutive time-steps: [`TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.TimeStepTable).

The mandatory variables to provide for an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) are: `T` (air temperature in °C), `Rh` (relative humidity, 0-1) and `Wind` (the wind speed, m s⁻¹). In our example, we also need the incoming photosynthetically active radiation flux (`Ri_PAR_f`, W m⁻²). We can declare such conditions like so:

```@example usepkg
using PlantMeteo
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
```

This `meteo` variable will therefore provide a single weather timeframe that can be used in a simulation.

More details are available from the [package documentation](https://vezy.github.io/PlantMeteo.jl/stable).

## Simulation

### Simulation of processes

To run a simulation, you can call the [`run!`](@ref) method on the `ModelList`. If some meteorological data is required for models to be simulated over several timesteps, that can be passed in as an optional argument as well.

Here is an example:

```julia
run!(model_list, meteo)
```

The first argument is the model list (see [`ModelList`](@ref)), and the second defines the micro-climatic conditions.

The `ModelList` should already be initialized for the given process before calling the function. Refer to the earlier section [Variables (inputs, outputs)](@ref) for more details.

### Example simulation

For example we can simulate the `light_interception` of a leaf like so:

```@example usepkg
using PlantSimEngine, PlantMeteo

# Import the examples defined in the `Examples` sub-module
using PlantSimEngine.Examples

meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)

leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))

outputs_example = run!(leaf, meteo)

outputs_example[:aPPFD]
```

### Outputs

The `status` field of a [`ModelList`](@ref) is used to initialize the variables before simulation and then to keep track of their values during and after the simulation. We can extract outputs of the very last timestep of a simulation using the [`status`](@ref) function.

The actual full output data is returned by the `run!` function. Data is usually stored in a `TimeStepTable` structure from `PlantMeteo.jl`, which is a fast DataFrame-like structure with each time step being a [`Status`](@ref). It can be also be any `Tables.jl` structure, such as a regular `DataFrame`. The weather is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

In our example, the simulation was only provided one weather timestep, so the outputs returned by `run!` and the ModelList's `status` field are identical.

Let's look at the outputs structure of our previous simulated leaf:

```@setup usepkg
outputs_example
```

We can extract the value of one variable by indexing into it, *e.g.* for the intercepted light:

```@example usepkg
outputs_example[:aPPFD]
```

Or similarly using the dot syntax:

```@example usepkg
outputs_example.aPPFD
```

You can then print the outputs, convert them to another format, or visualize them, using other Julia packages.
TODO
Another convenient way to get the results is to transform the outputs into a `DataFrame`. Which is very easy because the `TimeStepTable` implements the Tables.jl interface:

```@example usepkg
using DataFrames
convert_outputs(outputs_example, DataFrame)
```

## Model coupling

A model can work either independently or in conjunction with other models. For example a stomatal conductance model is often associated with a photosynthesis model, *i.e.* it is called from the photosynthesis model.

`PlantSimEngine.jl` is designed to make model coupling painless for modelers and users. Please see [Standard model coupling](@ref) and [Coupling more complex models](@ref) for more details, or Multiscale coupling considerations TODO for multi-scale specific coupling considerations.