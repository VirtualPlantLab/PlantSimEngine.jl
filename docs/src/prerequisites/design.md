# Package design

`PlantSimEngine.jl` is designed to ease the process of modelling and simulation of plants, soil and atmosphere, or really any system (*e.g.* agroforestry system, agrivoltaics...). `PlantSimEngine.jl` aims at being the backbone tool for developing Functional-Structural Plant Models (FSPM) and crop models without the hassle of performance and other computer-science considerations.  

```@setup usepkg
using PlantSimEngine, PlantMeteo
using PlantSimEngine.Examples
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))
run!(leaf, meteo)
```

## Definitions

### Processes

A process in this package defines a biological or physical phenomena. Think of any process happening in a system, such as light interception, photosynthesis, water, carbon and energy fluxes, growth, yield or even electricity produced by solar panels.

A process is "declared", meaning we just define a process using [`@process`](@ref), and then we implement models for its simulation. Declaring a process generates some boilerplate code for its simulation: 

- an abstract type for the process
- a method for the `process` function, that is used internally

For example, the `light_interception` process is declared using:

```julia
@process light_interception
```

Which would generate a tutorial to help the user implement a model for the process.

The abstract process type is then used as a supertype of all models implementations for the process, and is named `Abstract<process_name>Process`, *e.g.* `AbstractLight_InterceptionModel`.

### Models (ModelList)

A process is simulated using a particular implementation, or **a model**. Each model is implemented using a structure that lists the parameters of the model. For example, PlantBiophysics provides the [`Beer`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Beer) structure for the implementation of the Beer-Lambert law of light extinction. The process of `light_interception` and the `Beer` model are provided as an example 
script in this package too at [`examples/Beer.jl`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl).

Models can use three types of entries:

- Parameters
- Meteorological information
- Variables
- Constants
- Extras

Parameters are constant values that are used by the model to compute its outputs. Meteorological information are values that are provided by the user and are used as inputs to the model. It is defined for one time-step, and `PlantSimEngine.jl` takes care of applying the model to each time-steps given by the user. Variables are either used or computed by the model and can optionally be initialized before the simulation. Constants are constant values, usually common between models, *e.g.* the universal gas constant. And extras are just extra values that can be used by a model, it is for example used to pass the current node of the Multi-Scale Tree Graph to be able to *e.g.* retrieve children or ancestors values.

Users can choose which model is used to simulate a process using the [`ModelList`](@ref) structure. `ModelList` is also used to store the values of the parameters, and to initialize variables.

For example let's instantiate a [`ModelList`](@ref) with the Beer-Lambert model of light extinction. The model is implemented with the [`Beer`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl) structure and has only one parameter: the extinction coefficient (`k`).

Importing the package:

```@example usepkg
using PlantSimEngine
```

Import the examples defined in the `Examples` sub-module (`light_interception` and `Beer`):

```julia
using PlantSimEngine.Examples
```

And then making a [`ModelList`](@ref) with the `Beer` model:

```@example usepkg
ModelList(Beer(0.5))
```

What happened here? We provided an instance of the `Beer` model to a [`ModelList`](@ref) to simulate the light interception process.

## Parameters

A parameter is a constant value that is used by a model to compute its outputs. For example, the Beer-Lambert model uses the extinction coefficient (`k`) to compute the light extinction. The Beer-Lambert model is implemented with the `Beer` structure, which has only one field: `k`. We can see that using `fieldnames` on the model structure:

```@example usepkg
fieldnames(Beer)
```

## Variables (inputs, outputs)

Variables are either input or outputs (*i.e.* computed) of models. Variables and their values are stored in the [`ModelList`](@ref) structure, and are initialized automatically or manually.

For example, the `Beer` model needs the leaf area index (`LAI`, m² m⁻²) to run.

We can see which variables are needed as inputs using [`inputs`](@ref):

```@example usepkg
inputs(Beer(0.5))
```

and the outputs of the model using [`outputs`](@ref):

```@example usepkg
outputs(Beer(0.5))
```

If we instantiate a [`ModelList`](@ref) with the Beer-Lambert model, we can see that the `:status` field has two variables: `LAI` and `PPFD`. The first is an input, the second an output (*i.e.* it is computed by the model).

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

Uninitialized variables are initialized to the value given in the `inputs` or `outputs` methods, which is usually equal to `typemin()`, *e.g.* `-Inf` for `Float64`.

!!! tip
    Prefer using `to_initialize` rather than `inputs` to check which variables should be initialized. `inputs` returns the variables that are needed by the model to run, but `to_initialize` returns the variables that are needed by the model to run and that are not initialized in the `ModelList`. Also `to_initialize` is more clever when coupling models (see below).

We can initialize the variables by providing their values to the status at instantiation:

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

Some variables are inputs of models, but outputs of other models. When we couple models, `PlantSimEngine.jl` is clever and only requests the variables that are not computed by other models.

## Climate forcing

To make a simulation, we usually need the climatic/meteorological conditions measured close to the object or component.

Users are strongly encouraged to use [`PlantMeteo.jl`](https://github.com/PalmStudio/PlantMeteo.jl), the companion package that helps manage such data, with default pre-computations and structures for efficient computations. The most basic data structure from this package is a type called [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere), which defines steady-state atmospheric conditions, *i.e.* the conditions are considered at equilibrium. Another structure is available to define different consecutive time-steps: [`TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.TimeStepTable).

The mandatory variables to provide for an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) are: `T` (air temperature in °C), `Rh` (relative humidity, 0-1) and `Wind` (the wind speed, m s⁻¹). In our example, we also need the incoming photosynthetically active radiation flux (`Ri_PAR_f`, W m⁻²). We can declare such conditions like so:

```@example usepkg
using PlantMeteo
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
```

More details are available from the [package documentation](https://vezy.github.io/PlantMeteo.jl/stable).

## Simulation

### Simulation of processes

Making a simulation is rather simple, we simply call the [`run!`](@ref) method on the `ModelList`. If some meteorological data is required for models to be simulated over several timesteps, that can be passed in as a parameter as well.

Here is an example:

```julia
run!(model_list, meteo)
```

The first argument is the model list (see [`ModelList`](@ref)), and the second defines the micro-climatic conditions.

The `ModelList` should be initialized for the given process before calling the function. See [Variables (inputs, outputs)](@ref) for more details.

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
TODO
The `status` field of a [`ModelList`](@ref) is used to initialize the variables before simulation and then to keep track of their values during and after the simulation. We can extract the simulation outputs of a model list using the [`status`](@ref) function.

The status is usually stored in a `TimeStepTable` structure from `PlantMeteo.jl`, which is a fast DataFrame-alike structure with each time step being a [`Status`](@ref). It can be also be any `Tables.jl` structure, such as a regular `DataFrame`. The weather is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

Let's look at the status of our previous simulated leaf:

```@setup usepkg
status(leaf)
```

We can extract the value of one variable using the `status` function, *e.g.* for the intercepted light:

```@example usepkg
status(leaf, :aPPFD)
```

Or similarly using the dot syntax:

```@example usepkg
leaf.status.aPPFD
```

Or much simpler (and recommended), by indexing directly into the model list:

```@example usepkg
leaf[:aPPFD]
```

Another simple way to get the results is to transform the outputs into a `DataFrame`. Which is very easy because the `TimeStepTable` implements the Tables.jl interface:

```@example usepkg
using DataFrames
DataFrame(leaf)
```

!!! note
    The output from `DataFrame` is adapted to the kind of simulation you did: one row per time-step, and per component models if you simulated several.

## Model coupling

A model can work either independently or in conjunction with other models. For example a stomatal conductance model is often associated with a photosynthesis model, *i.e.* it is called from the photosynthesis model.

`PlantSimEngine.jl` is designed to make model coupling painless for modelers and users. Please see [Model coupling for users](@ref) and [Model coupling for modelers](@ref) for more details.