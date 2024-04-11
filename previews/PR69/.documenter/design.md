
# Package design {#Package-design}

`PlantSimEngine.jl` is designed to ease the process of modelling and simulation of plants, soil and atmosphere, or really any system (_e.g._ agroforestry system, agrivoltaics...). `PlantSimEngine.jl` aims at being the backbone tool for developing Functional-Structural Plant Models (FSPM) and crop models without the hassle of performance and other computer-science considerations.  

## Definitions {#Definitions}

### Processes {#Processes}

A process in this package defines a biological or physical phenomena. Think of any process happening in a system, such as light interception, photosynthesis, water, carbon and energy fluxes, growth, yield or even electricity produced by solar panels.

A process is &quot;declared&quot;, meaning we just define a process using [`@process`](/API#PlantSimEngine.@process-Tuple{Any,%20Vararg{Any}}), and then we implement models for its simulation. Declaring a process generates some boilerplate code for its simulation: 
- an abstract type for the process
  
- a method for the `process` function, that is used internally
  

For example, the `light_interception` process is declared using:

```julia
@process light_interception
```


Which would generate a tutorial to help the user implement a model for the process.

The abstract process type is then used as a supertype of all models implementations for the process, and is named `Abstract<process_name>Process`, _e.g._ `AbstractLight_InterceptionModel`.

### Models (ModelList) {#Models-(ModelList)}

A process is simulated using a particular implementation, or **a model**. Each model is implemented using a structure that lists the parameters of the model. For example, PlantBiophysics provides the [`Beer`](https://vezy.github.io/PlantBiophysics.jl/stable/functions/#PlantBiophysics.Beer) structure for the implementation of the Beer-Lambert law of light extinction. The process of `light_interception` and the `Beer` model are provided as an example  script in this package too at [`examples/Beer.jl`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl).

Models can use three types of entries:
- Parameters
  
- Meteorological information
  
- Variables
  
- Constants
  
- Extras
  

Parameters are constant values that are used by the model to compute its outputs. Meteorological information are values that are provided by the user and are used as inputs to the model. It is defined for one time-step, and `PlantSimEngine.jl` takes care of applying the model to each time-steps given by the user. Variables are either used or computed by the model and can optionally be initialized before the simulation. Constants are constant values, usually common between models, _e.g._ the universal gas constant. And extras are just extra values that can be used by a model, it is for example used to pass the current node of the Multi-Scale Tree Graph to be able to _e.g._ retrieve children or ancestors values.

Users can choose which model is used to simulate a process using the [`ModelList`](/model_switching#ModelList) structure. `ModelList` is also used to store the values of the parameters, and to initialize variables.

For example let&#39;s instantiate a [`ModelList`](/model_switching#ModelList) with the Beer-Lambert model of light extinction. The model is implemented with the [`Beer`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/master/examples/Beer.jl) structure and has only one parameter: the extinction coefficient (`k`).

Importing the package:

```julia
using PlantSimEngine
```


Import the examples defined in the `Examples` sub-module (`light_interception` and `Beer`):

```julia
using PlantSimEngine.Examples
```


And then making a [`ModelList`](/model_switching#ModelList) with the `Beer` model:

```julia
ModelList(Beer(0.5))
```


```
PlantSimEngine.DependencyGraph{Dict{Symbol, PlantSimEngine.SoftDependencyNode}}(Dict{Symbol, PlantSimEngine.SoftDependencyNode}(:light_interception => PlantSimEngine.Examples.Beer{Float64}
), Dict{Symbol, DataType}())TimeStepTable{Status{(:LAI, :aPPFD), Tuple{...}(1 x 2):
╭─────┬─────────┬─────────╮
│ Row │     LAI │   aPPFD │
│     │ Float64 │ Float64 │
├─────┼─────────┼─────────┤
│   1 │    -Inf │    -Inf │
╰─────┴─────────┴─────────╯

```


What happened here? We provided an instance of the `Beer` model to a [`ModelList`](/model_switching#ModelList) to simulate the light interception process.

## Parameters {#Parameters}

A parameter is a constant value that is used by a model to compute its outputs. For example, the Beer-Lambert model uses the extinction coefficient (`k`) to compute the light extinction. The Beer-Lambert model is implemented with the `Beer` structure, which has only one field: `k`. We can see that using `fieldnames` on the model structure:

```julia
fieldnames(Beer)
```


```
(:k,)
```


## Variables (inputs, outputs) {#Variables-(inputs,-outputs)}

Variables are either input or outputs (_i.e._ computed) of models. Variables and their values are stored in the [`ModelList`](/model_switching#ModelList) structure, and are initialized automatically or manually.

Hence, [`ModelList`](/model_switching#ModelList) objects stores two fields:

```julia
fieldnames(ModelList)
```


```
(:models, :status, :vars_not_propagated)
```


The first field is a list of models associated to the processes they simulate. The second, `:status`, is used to hold all inputs and outputs of our models, called variables. For example the `Beer` model needs the leaf area index (`LAI`, m² m⁻²) to run.

We can see which variables are needed as inputs using [`inputs`](/API#PlantSimEngine.inputs-Tuple{T}%20where%20T<:AbstractModel):

```julia
inputs(Beer(0.5))
```


```
(:LAI,)
```


and the outputs of the model using [`outputs`](/API#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation,%20Any}):

```julia
outputs(Beer(0.5))
```


```
(:aPPFD,)
```


If we instantiate a [`ModelList`](/model_switching#ModelList) with the Beer-Lambert model, we can see that the `:status` field has two variables: `LAI` and `PPFD`. The first is an input, the second an output (_i.e._ it is computed by the model).

```julia
m = ModelList(Beer(0.5))
keys(status(m))
```


```
(:LAI, :aPPFD)
```


To know which variables should be initialized, we can use [`to_initialize`](/API#PlantSimEngine.to_initialize-Tuple{ModelList}):

```julia
m = ModelList(Beer(0.5))
to_initialize(m)
```


```
(light_interception = (:LAI,),)
```


Their values are uninitialized though (hence the warnings):

```julia
(m[:LAI], m[:aPPFD])
```


```
([-Inf], [-Inf])
```


Uninitialized variables are initialized to the value given in the `inputs` or `outputs` methods, which is usually equal to `typemin()`, _e.g._ `-Inf` for `Float64`.

::: tip Tip

Prefer using `to_initialize` rather than `inputs` to check which variables should be initialized. `inputs` returns the variables that are needed by the model to run, but `to_initialize` returns the variables that are needed by the model to run and that are not initialized in the `ModelList`. Also `to_initialize` is more clever when coupling models (see below).

:::

We can initialize the variables by providing their values to the status at instantiation:

```julia
m = ModelList(Beer(0.5), status = (LAI = 2.0,))
```


```
PlantSimEngine.DependencyGraph{Dict{Symbol, PlantSimEngine.SoftDependencyNode}}(Dict{Symbol, PlantSimEngine.SoftDependencyNode}(:light_interception => PlantSimEngine.Examples.Beer{Float64}
), Dict{Symbol, DataType}())TimeStepTable{Status{(:LAI, :aPPFD), Tuple{...}(1 x 2):
╭─────┬─────────┬─────────╮
│ Row │     LAI │   aPPFD │
│     │ Float64 │ Float64 │
├─────┼─────────┼─────────┤
│   1 │     2.0 │    -Inf │
╰─────┴─────────┴─────────╯

```


Or after instantiation using [`init_status!`](/API#PlantSimEngine.init_status!-Tuple{Dict{String,%20ModelList}}):

```julia
m = ModelList(Beer(0.5))

init_status!(m, LAI = 2.0)
```


```
[ Info: Some variables must be initialized before simulation: (light_interception = (:LAI,),) (see `to_initialize()`)
```


We can check if a component is correctly initialized using [`is_initialized`](/API#PlantSimEngine.is_initialized-Tuple{T}%20where%20T<:ModelList):

```julia
is_initialized(m)
```


```
true
```


Some variables are inputs of models, but outputs of other models. When we couple models, `PlantSimEngine.jl` is clever and only requests the variables that are not computed by other models.

## Climate forcing {#Climate-forcing}

To make a simulation, we usually need the climatic/meteorological conditions measured close to the object or component.

Users are strongly encouraged to use [`PlantMeteo.jl`](https://github.com/PalmStudio/PlantMeteo.jl), the companion package that helps manage such data, with default pre-computations and structures for efficient computations. The most basic data structure from this package is a type called [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere), which defines steady-state atmospheric conditions, _i.e._ the conditions are considered at equilibrium. Another structure is available to define different consecutive time-steps: [`TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.TimeStepTable).

The mandatory variables to provide for an [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere) are: `T` (air temperature in °C), `Rh` (relative humidity, 0-1) and `Wind` (the wind speed, m s⁻¹). In our example, we also need the incoming photosynthetically active radiation flux (`Ri_PAR_f`, W m⁻²). We can declare such conditions like so:

```julia
using PlantMeteo
meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)
```


```
Atmosphere(date = Dates.DateTime("2024-04-11T16:41:01.565"), duration = Dates.Second(1), T = 20.0, Wind = 1.0, P = 101.325, Rh = 0.65, Precipitations = 0.0, Cₐ = 400.0, e = 1.5255470730405223, eₛ = 2.3469954969854188, VPD = 0.8214484239448965, ρ = 1.2040822421461452, λ = 2.4537e6, γ = 0.06725339460440805, ε = 0.5848056484857892, Δ = 0.14573378083416522, clearness = Inf, Ri_SW_f = Inf, Ri_PAR_f = 500.0, Ri_NIR_f = Inf, Ri_TIR_f = Inf, Ri_custom_f = Inf)
```


More details are available from the [package documentation](https://vezy.github.io/PlantMeteo.jl/stable).

## Simulation {#Simulation}

### Simulation of processes {#Simulation-of-processes}

Making a simulation is rather simple, we simply use [`run!`](/API#PlantSimEngine.run!) on the `ModelList`:

The call to [`run!`](/API#PlantSimEngine.run!) is the same whatever the models you choose for simulating the processes. This is some magic allowed by `PlantSimEngine.jl`! Here is an example:

```julia
run!(model_list, meteo)
```


The first argument is the model list (see [`ModelList`](/model_switching#ModelList)), and the second defines the micro-climatic conditions.

The `ModelList` should be initialized for the given process before calling the function. See [Variables (inputs, outputs)](/design#Variables-(inputs,-outputs)) for more details.

### Example simulation {#Example-simulation}

For example we can simulate the `light_interception` of a leaf like so:

```julia
using PlantSimEngine, PlantMeteo

# Import the examples defined in the `Examples` sub-module
using PlantSimEngine.Examples

meteo = Atmosphere(T = 20.0, Wind = 1.0, Rh = 0.65, Ri_PAR_f = 500.0)

leaf = ModelList(Beer(0.5), status = (LAI = 2.0,))

run!(leaf, meteo)

leaf[:aPPFD]
```


```
1-element Vector{Float64}:
 1444.3954769232544
```


### Outputs {#Outputs}

The `status` field of a [`ModelList`](/model_switching#ModelList) is used to initialize the variables before simulation and then to keep track of their values during and after the simulation. We can extract the simulation outputs of a model list using the [`status`](/API#PlantSimEngine.status-Tuple{Any}) function.

The status is usually stored in a `TimeStepTable` structure from `PlantMeteo.jl`, which is a fast DataFrame-alike structure with each time step being a [`Status`](/API#PlantSimEngine.Status). It can be also be any `Tables.jl` structure, such as a regular `DataFrame`. The weather is also usually stored in a `TimeStepTable` but with each time step being an `Atmosphere`.

Let&#39;s look at the status of our previous simulated leaf:

We can extract the value of one variable using the `status` function, _e.g._ for the intercepted light:

```julia
status(leaf, :aPPFD)
```


```
1-element Vector{Float64}:
 1444.3954769232544
```


Or similarly using the dot syntax:

```julia
leaf.status.aPPFD
```


```
1-element Vector{Float64}:
 1444.3954769232544
```


Or much simpler (and recommended), by indexing directly into the model list:

```julia
leaf[:aPPFD]
```


```
1-element Vector{Float64}:
 1444.3954769232544
```


Another simple way to get the results is to transform the outputs into a `DataFrame`. Which is very easy because the `TimeStepTable` implements the Tables.jl interface:

```julia
using DataFrames
DataFrame(leaf)
```


::: tip Note

The output from `DataFrame` is adapted to the kind of simulation you did: one row per time-step, and per component models if you simulated several.

:::

## Model coupling {#Model-coupling}

A model can work either independently or in conjunction with other models. For example a stomatal conductance model is often associated with a photosynthesis model, _i.e._ it is called from the photosynthesis model.

`PlantSimEngine.jl` is designed to make model coupling painless for modelers and users. Please see [Model coupling for users](/model_coupling/model_coupling_user#Model-coupling-for-users) and [Model coupling for modelers](/model_coupling/model_coupling_modeler#Model-coupling-for-modelers) for more details.
