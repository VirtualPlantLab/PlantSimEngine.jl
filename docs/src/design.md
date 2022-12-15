# Package design

`PlantSimEngine.jl` is designed to ease the process of modelling and simulation of plants, soil and atmosphere, or really any system (*e.g.* agroforestry system, agrivoltaics...). `PlantSimEngine.jl` aims at being the backbone tool for developing Functional-Structural Plant Models (FSPM) and crop models without the hassle of performance and other computer-science considerations.  

```@setup usepkg
using PlantSimEngine, PlantMeteo
include(joinpath(dirname(dirname(pathof(PlantSimEngine))),"examples","light.jl"))

meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)
leaf = ModelList(light_interception = Beer(0.5), status = (LAI = 2.0,))
light_interception!(leaf, meteo)
```

## Definitions

### Processes

A process in this package defines a biological or physical phenomena. Think of any process happening in a system, such as light interception, photosynthesis, water, carbon and energy fluxes, growth, yield or even electricity produced by solar panels.

A process is "declared", meaning we just define a process using [`@gen_process_methods`](@ref), and then we implement models for its simulation. Declaring a process automatically generates three functions, for example `light_interception` from `PlantBiophysics.jl` has:

- `light_interception`: the generic function that makes a copy of the `modelList` and returns directly the status (not very efficient but easy to use)
- `light_interception!`: the faster, mutating, generic function. Here the user need to extract the outputs from the status after the simulation (note the `!` at the end of the name)
- `light_interception!_`: the basic implementation with a method for each model. PlantSimEngine uses multiple dispatch to choose the right method based on the model type. This is the function we need to extend when implementing a new model for the process.

### Models

A process is simulated using a particular implementation, or **a model**. Each model is implemented using a structure that lists the parameters of the model. For example, PlantBiophysics provides the [`Beer`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Beer) structure for the implementation of the Beer-Lambert law of light extinction. The process of `light_interception` and the `Beer` model are provided as an example 
script in this package too at [`examples/light.jl`](https://github.com/VEZY/PlantSimEngine.jl/blob/master/examples/light.jl).

Models can use three types of entries:

- Parameters
- Meteorological information
- Variables
- Constants
- Extras

Parameters are constant values that are used by the model to compute its outputs. Meteorological information are values that are provided by the user and are used as inputs to the model. It is defined for one time-step, and `PlantSimEngine.jl` takes care of applying the model to each time-steps given by the user. Variables are either used or computed by the model and can optionally be initialized before the simulation. Constants are constant values, usually common between models, *e.g.* the universal gas constant. And extras are just extra values that can be used by a model, it is for example used to pass the current node of the Multi-Scale Tree Graph to be able to *e.g.* retrieve children or ancestors values.

Users can choose which model is used to simulate a process using the [`ModelList`](@ref) structure. `ModelList` is also used to store the values of the parameters, and to initialize variables.

For example let's instantiate a [`ModelList`](@ref) with the Beer-Lambert model of light extinction. The model is implemented with the [`Beer`](https://github.com/VEZY/PlantSimEngine.jl/blob/master/examples/light.jl) structure and has only one parameter: the extinction coefficient (`k`).

```@example usepkg
using PlantSimEngine
# Including the script defining light_interception and Beer:
include(joinpath(dirname(dirname(pathof(PlantSimEngine))),"examples","light.jl"))
ModelList(light_interception = Beer(0.5))
```

What happened here? We provided an instance of a model to the process it simulates. The model is provided as a keyword argument to the [`ModelList`](@ref), with the process name given as the keyword, and the instantiated model as the value. The keyword must match **exactly** the name of the process it simulates because it is used to match the models to the function than run its simulation, *e.g.* `light_interception` for the `light_interception` process.

## Parameters

A parameter is a constant value that is used by a model to compute its outputs. For example, the Beer-Lambert model uses the extinction coefficient (`k`) to compute the light extinction. The Beer-Lambert model is implemented with the `Beer` structure, which has only one field: `k`. We can see that using `fieldnames`:

```@example usepkg
fieldnames(Beer)
```

## Variables (inputs, outputs)

Variables are either input or outputs (*i.e.* computed) by models, and can optionally be initialized before the simulation. Variables and their values are stored in the [`ModelList`](@ref) structure, and are initialized automatically or manually.

Hence, [`ModelList`](@ref) objects stores two fields:

```@example usepkg
fieldnames(ModelList)
```

The first field is a list of models associated to the processes they simulate. The second, `:status`, is used to hold all inputs and outputs of our models, called variables. For example the `Beer` model needs the leaf area index (`LAI`, m^{2} \cdot m^{-2}) to run.

We can see which variables are needed as inputs using [`inputs`](@ref):

```@example usepkg
using PlantSimEngine
inputs(Beer(0.5))
```

We can also see the outputs of the model using [`outputs`](@ref):

```@example usepkg
outputs(Beer(0.5))
```

If we instantiate a [`ModelList`](@ref) with the Beer-Lambert model, we can see that the `:status` field has two variables: `LAI` and `PPDF`. The first is an input, the second an output (*i.e.* it is computed by the model).

```@example usepkg
m = ModelList(light_interception = Beer(0.5))
keys(m.status)
```

To know which variables should be initialized, we can use [`to_initialize`](@ref):

```@example usepkg
m = ModelList(light_interception = Beer(0.5))

to_initialize(m)
```

Their values are uninitialized though (hence the warnings):

```@example usepkg
(m[:LAI], m[:PPFD])
```

Uninitialized variables have the value returned by `typemin()`, *e.g.* `-Inf` for `Float64`:

```@example usepkg
typemin(Float64)
```

!!! tip
    Prefer using `to_initialize` rather than `inputs` to check which variables should be initialized. `inputs` returns the variables that are needed by the model to run, but `to_initialize` returns the variables that are needed by the model to run and that are not initialized. Also `to_initialize` is more clever when coupling models (see below).

We can initialize the variables by providing their values to the status at instantiation:

```@example usepkg
m = ModelList(light_interception = Beer(0.5), status = (LAI = 2.0,))
```

Or after instantiation using [`init_status!`](@ref):

```@example usepkg
m = ModelList(light_interception = Beer(0.5))

init_status!(m, LAI = 2.0)
```

We can check if a component is correctly initialized using [`is_initialized`](@ref):

```@example usepkg
is_initialized(m)
```

Some variables are inputs of models, but outputs of other models. When we couple models, we have to be careful to initialize only the variables that are not computed, and `PlantSimEngine.jl` is here to help users in this task.

## Climate forcing

To make a simulation, we usually need the climatic/meteorological conditions measured close to the object or component.

Users are strongly encouraged to use [`PlantMeteo.jl`](https://github.com/PalmStudio/PlantMeteo.jl), the companion package that helps manage such data, with default pre-computations and structures for efficient computations. The most basic data structure from this package is a type called [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere), which defines steady-state atmospheric conditions, *i.e.* the conditions are considered at equilibrium. Another structure is available to define different consecutive time-steps: [`TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.TimeStepTable).

The mandatory variables to provide for an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) are: `T` (air temperature in °C), `Rh` (relative humidity, 0-1) and `Wind` (the wind speed in m s-1). We can declare such conditions like so:

```@example usepkg
using PlantMeteo
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65)
```

More details are available from the [package documentation](https://vezy.github.io/PlantMeteo.jl/stable).

## Simulation

### Simulation of processes

Making a simulation is rather simple, we simply use the function with the name of the process we want to simulate, for example `PlantBiophysics.jl` implements:

- `stomatal_conductance` for the stomatal conductance
- `photosynthesis` for the photosynthesis
- `energy_balance` for the energy balance
- `light_interception` for the energy balance

!!! note
    All functions exist in a mutating and a non-mutating form. Just add `!` at the end of the name of the function (*e.g.* `energy_balance!`) to use the mutating form for speed! 🚀

The call to the function is the same whatever the model you choose for simulating the process. This is some magic allowed by `PlantSimEngine.jl`! A call to a function is made as follows:

```julia
stomatal_conductance(model_list, meteo)
photosynthesis(model_list, meteo)
energy_balance(model_list, meteo)
light_interception(model_list, meteo)
```

The first argument is the model list (see [`ModelList`](@ref)), and the second defines the micro-climatic conditions.

The `ModelList` should be initialized for the given process before calling the function. See [Variables (inputs, outputs)](@ref) for more details.

### Example simulation

For example we can simulate the `light_interception` of a leaf like so:

```@example usepkg
using PlantSimEngine, PlantMeteo
# Including the script defining light_interception and Beer:
include(joinpath(dirname(dirname(pathof(PlantSimEngine))),"examples","light.jl"))

meteo = Atmosphere(T = 20.0, Wind = 1.0, P = 101.3, Rh = 0.65)

leaf = ModelList(
    light_interception = Beer(0.5), 
    status = (LAI = 2.0,)
)

light_interception!(leaf, meteo)

leaf[:PPFD]
```

### Outputs

The `status` field of a [`ModelList`](@ref) is used to initialize the variables before simulation and then to keep track of their values during and after the simulation. We can extract the simulation outputs of a model list using the [`status`](@ref) function.

!!! note
    Getting the status is only useful when using the mutating version of the function (*e.g.* `light_interception!`), as the non-mutating version returns the output directly.

The status usually is stored in a `TimeStepTable` structure from `PlantMeteo.jl` with each time step being a [`Status`](@ref), but it can be any `Tables.jl` structure, such as a `DataFrame`. The weather is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

Let's look at the status of our previous simulated leaf:

```@setup usepkg
status(leaf)
```

We can extract the value of one variable using the `status` function, *e.g.* for the light intercepted:

```@example usepkg
status(leaf, :PPFD)
```

Or similarly using the dot syntax:

```@example usepkg
leaf.status.PPFD
```

Or much simpler (and recommended), by indexing directly the model list:

```@example usepkg
leaf[:PPFD]
```

Another simple way to get the results is to transform the outputs into a `DataFrame`:

```@example usepkg
using DataFrames
DataFrame(leaf)
```

!!! note
    The output from `DataFrame` is adapted to the kind of simulation you did: one row per time-step, and per component models if you simulated several.

## Model coupling

A model can work either independently or in conjunction with other models. For example a stomatal conductance model is often associated with a photosynthesis model, *i.e.* it is called from the photosynthesis model.

`PlantSimEngine.jl` is designed to make model coupling painless for the modeler, and for the user. The modeler implements a model, and if the model needs another model to compute one of its variable, the modeler only needs to call the generic function for the process, and then the user choose which model is used for this computation.

See [Model coupling for users](@ref) and [Model coupling for modelers](@ref) for more details.