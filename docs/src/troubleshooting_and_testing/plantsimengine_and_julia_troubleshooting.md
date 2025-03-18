# Troubleshooting error messages

PlantSimEngine attempts to be as comfortable and easy to use as possible for the user, and many kinds of user error will be caught and explanations provided to resolve them, but there are still blind spots, as well as syntax errors that will often generate a Julia error (which can be less intuitive to decrypt) rather than a PlantSimEngine error.

To help people newer to Julia with troubleshooting, here are a few common 'easy-to-make' mistakes with the current API that might not be obvious to interpret, and pointers on how to fix them.

They are listed by 'nature of error', rather than by error message, so you may need to search the page to find your specific error.

If you need more help to decode Julia errors, you can find help on the [Julia Discourse forums](https://discourse.julialang.org).
If you need some advice on the FSPM side, the research community has [its own discourse forum](https://fspm.discourse.group).

If the issue seems PlantSimEngine-related, or you have questions regarding modeling or have suggestions, you can also [file an issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues) on Github.

```@contents
Pages = ["plantsimengine_and_julia_troubleshooting.md"]
Depth = 3
```

## Tips and workflow

Some errors are very specific as to their cause, and the PlantSimEngine errors tend to be explicit about which parameter / variable / organ is causing the error, helping narrow down its origin.

Some generic-looking errors usually do contain some extra information to help focus the debugging hunt. For instance, a dispatch failure on run! caused by some issue with args/kwargs may highlight explicitely indicate which arguments are currently causing conflict. In VSCode, such arguments are highlighted in red (the first and last arguments in the example below) : 

```julia
a = 1
run!(a, simple_mtg, mapping, meteo_day, a)

ERROR: MethodError: no method matching run!(::Int64, ::Node{NodeMTG, Dict{…}}, ::Dict{String, Tuple{…}}, ::DataFrame, ::Int64)
The function [`run!`](@ref) exists, but no method is defined for this combination of argument types.

Closest candidates are:
  run!(::ToyPlantLeafSurfaceModel, ::Any, ::Any, ::Any, ::Any, ::Any)
   @ PlantSimEngine /PlantSimEngine/examples/ToyLeafSurfaceModel.jl:75
   ...
```

If you wish to search for a specific error in the current page, copy the part of the description that is not specific to your script, and Ctrl+F it here. In the above example, the generic part would be : 
```julia
ERROR: MethodError: no method matching
```

## Common Julia errors

### NamedTuples with a single value require a comma :

This one is easy to miss.

Empty NamedTuple objects are initialised with x = NamedTuple(). Ones with more than one variable can be initialised like this : 
```julia
a = (var1 = 0, var2 = 0)
```
or like this : 
```julia
a = (var1 = 0, var2 = 0,)
```
The second comma being optional.

However, if there is only a single variable, notation has to be : 
```julia
a = (var1 = 0,)
```
The comma is compulsory. If it is forgotten : 
```julia
a = (var1 = 0)
```
the line will be interpreted as setting the variable a to the value var1 is set to, hence a will be an Int64 of value 0.

This is a liability when writing custom models as some functions work with NamedTuples : 
```julia
function PlantSimEngine.inputs_(::HardDepSameScaleAvalModel)
    (e2 = -Inf,)
end
```

The error returned will likely be a Julia error along the lines of : 
```julia
[ERROR: MethodError: no method matching merge(::Float64, ::@NamedTuple{g::Float64})

Closest candidates are:
merge(::NamedTuple{()}, ::NamedTuple)
@ Base namedtuple.jl:337
merge(::NamedTuple{an}, ::NamedTuple{bn}) where {an, bn}
@ Base namedtuple.jl:324
merge(::NamedTuple, ::NamedTuple, NamedTuple...)
@ Base namedtuple.jl:343

Stacktrace:
[1] variables_multiscale(node::PlantSimEngine.HardDependencyNode{…}, organ::String, vars_mapping::Dict{…}, st::@NamedTuple{})
...
```
It is sometimes properly detected and explained on PlantSimEngine's side (when passing in tracked_outputs, for instance), but may also occur when declaring statuses.

### Incorrectly declaring empty inputs or outputs

The syntax for an empty NamedTuple is `NamedTuple()`. If instead one types `()` or `(,)`an error returned respectively by PlantSimEngine or Julia will be returned.

## PlantSimEngine user errors

Most of the following errors occur exclusively in multi-scale simulations, which has a slightly more complex API, but some are common to both single- and multi-scale simulations.

### Implementing a model: forgetting to import or prefix functions

When implementing a model, you need to make sure that your implementation is correctly recognised as extending `PlantSimEngine` methods and types, and not writing new independent ones.

In the following working toy model implementation, note that the `inputs_`, `outputs_` and [`run!`](@ref) function are all prefixed with the module name. If there were hard dependencies to manage, the [`dep`](@ref) function would also be identically prefixed.

```julia
using PlantSimEngine
@process "toy" verbose = false

struct ToyToyModel{T} <: AbstractToyModel 
    internal_constant::T
end

function PlantSimEngine.inputs_(::ToyToyModel)
    (a = -Inf, b = -Inf, c = -Inf)
end

function PlantSimEngine.outputs_(::ToyToyModel)
    (d = -Inf, e = -Inf)
end


function PlantSimEngine.run!(m::ToyToyModel, models, status, meteo, constants=nothing, extra_args=nothing)
    status.d = m.internal_constant * status.a 
    status.e += m.internal_constant
end

meteo = Weather([
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=200.0),
        Atmosphere(T=18.0, Wind=1.0, Rh=0.65, Ri_PAR_f=100.0),
])

model = ModelList(
    ToyToyModel(1),
   status = ( a = 1, b = 0, c = 0),
)
to_initialize(model) 
sim = PlantSimEngine.run!(model, meteo)
```

If you declare these functions without importing them first, or prefixing them with the module name, they will be considered to be part of your current environment, and won't be extending PlantSimEngine methods, which means PlantSimEngine will not be able to properly make use of your functions, and simulations are likely to error, or run incorrectly.

Forgetting to prefix the [`run!`](@ref) function definition gives the following error : 
```julia
ERROR: MethodError: no method matching run!(::ModelList{@NamedTuple{…}, Status{…}}, ::TimeStepTable{Atmosphere{…}})
The function [`run!`](@ref) exists, but no method is defined for this combination of argument types.

Closest candidates are:
  run!(::ToyToyModel, ::Any, ::Any, ::Any, ::Any, ::Any)
   @ Main ~/path/to/file.jl:20
```

Forgetting to prefix the `inputs_`or `outputs_` functions for your model might not always generate an error, depending on whether the variables declared in this function are present in your ModelList or mapping's corresponding Status.

In cases where they do throw an error, you may get the following kind of output:
```julia
ERROR: type NamedTuple has no field d
Stacktrace:
 [1] setproperty!(mnt::Status{(:a, :b, :c), Tuple{…}}, s::Symbol, x::Int64)
   @ PlantSimEngine ~/path/to/package/PlantSimEngine/src/component_models/Status.jl:100
 [2] run!(m::ToyToyModel{…}, models::@NamedTuple{…}, status::Status{…}, meteo::PlantMeteo.TimeStepRow{…}, constants::Constants{…}, extra_args::Nothing)
 ...
```

!!! note
    There may be more we can do on our end in the future to make the issue more obvious, but in the meantime it is safest to consistently prefix the methods you need to declare and call with `PlantSimEngine.`, or to explicitely import the functions you wish to extend, *e.g.*: `import PlantSimEngine: inputs_, outputs_`.

### MultiScaleModel : forgetting a kwarg in the declaration

A MultiScaleModel requires two kwargs, model and mapped_variables : 

```julia
models = MultiScaleModel(
        model=ToyLAIModel(),
        mapped_variables=[:TT_cu => "Scene",],
    )
```

Forgetting 'model=' :

```julia
models = MultiScaleModel(
        ToyLAIModel(),
        mapped_variables=[:TT_cu => "Scene",],
    )
ERROR: MethodError: no method matching MultiScaleModel(::ToyLAIModel; mapped_variables::Vector{Pair{Symbol, String}})
The type `MultiScaleModel` exists, but no method is defined for this combination of argument types when trying to construct it.
    
Closest candidates are:
    MultiScaleModel(::T, ::Any) where T<:AbstractModel got unsupported keyword argument "mapped_variables"
    @ PlantSimEngine PlantSimEngine/src/mtg/MultiScaleModel.jl:188
    MultiScaleModel(; model, mapped_variables)
    @ PlantSimEngine PlantSimEngine/src/mtg/MultiScaleModel.jl:191
```

Forgetting 'mapped_variables=' :
```julia
models = MultiScaleModel(
        model=ToyLAIModel(),
        [:TT_cu => "Scene",],
    )

ERROR: MethodError: no method matching MultiScaleModel(::Vector{Pair{Symbol, String}}; model::ToyLAIModel)
The type `MultiScaleModel` exists, but no method is defined for this combination of argument types when trying to construct it.

Closest candidates are:
  MultiScaleModel(; model, mapping)
   @ PlantSimEngine PlantSimEngine/src/mtg/MultiScaleModel.jl:191
  MultiScaleModel(::T, ::Any) where T<:AbstractModel got unsupported keyword argument "model"
```

The message 'got unsupported keyword argument "model"' can be misleading, as in the error in this case is not that a kwarg is *unsupported*, but rather that a keyword argument is *missing*.

### MultiScaleModel : variable not defined in Module

A possible cause for this error is that a variable was declared instead of a symbol in a mapping for a multiscale model :

```julia
mapping = Dict("Scale" =>
MultiScaleModel(
    model = ToyModel(),
    mapped_variables = [should_be_symbol => "Other_Scale"] # should_be_symbol is a variable, likely not found in the current module 
),
...
),
```

Here's the correct version : 
```julia
mapping = Dict("Scale" =>
MultiScaleModel(
    model = ToyModel(),
    mapped_variables=[:should_be_symbol => "Other_Scale"] # should_be_symbol is now a symbol
),
...
),
```

### Kwarg and arg parameter issues when calling run!

There are, unfortunately, multiple ways of passing in arguments to the run! functions that will confuse dynamic dispatch. Some of it is due to imperfections in type declarations on PlantSimEngine's end and may be improved upon in the future. 

Here are a few examples when modifying the usual multiscale run! call in this working example : 

```julia
    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
    var1 = 15.0

    mapping = Dict(
        "Leaf" => (
            Process1Model(1.0),
            Process2Model(),
            Process3Model(),
            Status(var1=var1,)
        )
    )

    outs = Dict(
        "Leaf" => (:var1,), # :non_existing_variable is not computed by any model
    )

run!(mtg, mapping, meteo_day, PlantMeteo.Constants(), tracked_outputs=outs)
```

The exact signature is this : 
```julia
function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::Dict{String,T} where {T},
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    nsteps=nothing,
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx()
```

Arguments after the mtg and mapping all have a default value and are optional, and arguments after the ';' delimiter are kwargs and need to be named.

If one forgets the mtg, a flaw in the way run! is defined will lead to this error :
```julia
run!(mapping, meteo_day, PlantMeteo.Constants(), tracked_outputs=outs)

ERROR: MethodError: no method matching check_dimensions(::PlantSimEngine.TableAlike, ::Tuple{…}, ::DataFrame)
The function `check_dimensions` exists, but no method is defined for this combination of argument types.

Closest candidates are:
  check_dimensions(::Any, ::Any)
   @ PlantSimEngine PlantSimEngine/src/checks/dimensions.jl:43
 ...
```

If one forgets the necessary 'tracked_outputs=' in the definition, outs will be interpreted as the 'extra' arg instead of a kwarg. 'extra' usually defaults to nothing, and is reserved in multiscale mode, leading to the following error :

```julia
run!(mtg, mapping, meteo_day, PlantMeteo.Constants(), outs)

ERROR: Extra parameters are not allowed for the simulation of an MTG (already used for statuses).
Stacktrace:
 [1] error(s::String)
   @ Base ./error.jl:35
 [2] run!(::PlantSimEngine.TreeAlike, object::PlantSimEngine.GraphSimulation{…}, meteo::DataFrames.DataFrameRows{…}, constants::Constants{…}, extra::Dict{…}; tracked_outputs::Nothing, check::Bool, executor::ThreadedEx{…})
```

In case of a more generic error that returns a 
For example, if one does the opposite and adds a non-existent kwarg, the generic dispatch failure has some more specific information : 
`got unsupported keyword argument "constants"`

```julia
run!(mtg, mapping, meteo_day, constants=PlantMeteo.Constants(), tracked_outputs=outs)

ERROR: MethodError: no method matching run!(::Node{…}, ::Dict{…}, ::DataFrame, ::Dict{…}, ::Nothing; constants::Constants{…})
This error has been manually thrown, explicitly, so the method may exist but be intentionally marked as unimplemented.

Closest candidates are:
  run!(::Node, ::Dict{String}, ::Any, ::Any, ::Any; nsteps, tracked_outputs, check, executor) got unsupported keyword argument "constants"
```

### Hard dependency process not present in the mapping

Another weakness in the current error checking leads to an unclear Julia error if a model A is present in a mapping and has a hard dependency on a model B, but B is absent from the mapping.

In the following example, A corresponds to Process3Model, which requires a model B implementing 'Process2Model' and referred to as 'process2'. 
Looking at the source code for Process3Model, the hard dependency is declared here : 
```julia
PlantSimEngine.dep(::Process3Model) = (process2=Process2Model,)
```

However, the model provided in the examples, Process2Model is absent from the mapping :

```julia
simple_mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))    
mapping = Dict(
    "Leaf" => (
        Process3Model(),
        Status(var5=15.0,)
    )
)
outs = Dict(
    "Leaf" => (:var5,),
)
run!(simple_mtg, mapping, meteo_day, tracked_outputs=outs)

ERROR: type NamedTuple has no field process2
Stacktrace:
 [1] getproperty(x::@NamedTuple{process3::Process3Model}, f::Symbol)
   @ Base ./Base.jl:49
 [2] run!(::Process3Model, models::@NamedTuple{…}, status::Status{…}, meteo::DataFrameRow{…}, constants::Constants{…}, extra::PlantSimEngine.GraphSimulation{…})
 ...
```

The fix is to add Process2Model() -or another model for the same process- to the mapping.

### Status API ambiguity

One current problem with PlantSimEngine's API is that declaring a simulation's Status or Statuses differs between single- and multi-scale.

Returning to the example in [Implementing a model: forgetting to import or prefix functions](@ref), the `ModelList` status was declared like this:

```julia
model = ModelList(
    ToyToyModel(1),
   status = ( a = 1, b = 0, c = 0),
)
```
If instead you replace `status = ...`with the multi-scale declaration: `Status(...)`, you will get the following error:

```julia
ERROR: MethodError: no method matching process(::Status{(:a, :b, :c), Tuple{Base.RefValue{Int64}, Base.RefValue{Int64}, Base.RefValue{Int64}}})
The function `process` exists, but no method is defined for this combination of argument types.

Closest candidates are:
  process(::Pair{Symbol, A}) where A<:AbstractModel
   @ PlantSimEngine ~/path/to/pkg/PlantSimEngine/src/Abstract_model_structs.jl:16
  process(::A) where A<:AbstractModel
   @ PlantSimEngine ~/path/to/pkg/PlantSimEngine/src/Abstract_model_structs.jl:13

Stacktrace:
 [1] (::PlantSimEngine.var"#5#6")(i::Status{(:a, :b, :c), Tuple{Base.RefValue{…}, Base.RefValue{…}, Base.RefValue{…}}})
   @ PlantSimEngine ./none:0
 [2] iterate
```

If you do the opposite in a multi-scale simulation by replacing the necessary `Status(...)` with `status = ...`, you may get an `ERROR: syntax: invalid named tuple element` error. Here's some output when tinkering with the Toy Plant tutorial's mapping:

```julia
ERROR: syntax: invalid named tuple element "MultiScaleModel(...)" around /path/to/Pkg/PlantSimEngine/examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl:196
Stacktrace:
 [1] top-level scope
   @ ~/path/to/pkg/PlantSimEngine/examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl:196
```
or 
```julia
ERROR: syntax: invalid named tuple element "ToyRootGrowthModel(50, 10)" around /path/to/Pkg/PlantSimEngine/examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl:196
Stacktrace:
 [1] top-level scope
   @ ~/path/to/Pkg/PlantSimEngine/examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl:196
```

## Forgetting to declare a scale in the mapping but having variables point to it

If there is a need to collect variables at two different scales, and one scale is completely absent from the mapping, the error currently occurs on the Julia side :

```julia
# No models at the E3 scale in the mapping !

"E2" => (
        MultiScaleModel(
        model = HardDepSameScaleEchelle2Model(),
        mapped_variables=[:c => "E1" => :c, :e3 => "E3" => :e3, :f3 => "E3" => :f3,], 
        ),
    ),

Exception has occurred: KeyError
*
KeyError: key "E3" not found
Stacktrace:
[1] hard_dependencies(mapping::Dict{String, Tuple{Any, Any}}; verbose::Bool)
@ PlantSimEngine ......./src/dependencies/hard_dependencies.jl:175
...
```

### Parenthesis placement when declaring a mapping

An unintuitive error encountered in the past when defining a mapping : 

```julia
ERROR: ArgumentError: AbstractDict(kv): kv needs to be an iterator of 2-tuples or pairs
```
may occur when forgetting the parenthesis after '=>' in a mapping declaration, and combining it with another parenthesis error.
```julia
mapping = Dict( "Scale" => (ToyAssimGrowthModel(0.0, 0.0, 0.0), ToyCAllocationModel(), Status( TT_cu=Vector(cumsum(meteo_day.TT))), ), )
```

Other errors such as : 
```julia
ERROR: MethodError: no method matching Dict(::Pair{String, ToyAssimGrowthModel{Float64}}, ::ToyCAllocationModel, ::Status{(:TT_cu,), Tuple{Base.RefValue{…}}})
The type `Dict` exists, but no method is defined for this combination of argument types when trying to construct it.

Closest candidates are:
  Dict(::Pair{K, V}...) where {K, V}
```
often indicate a likely syntax error somewhere in the mapping definition.

### Empty status vectors in multi-scale simulations

This situation won't trigger an error. Unexpectedly empty vectors can be returned as outputs if you happen to forget to a node at the corresponding scale in the MTG, and no organ creation occurs for that node.

Here's an example taken from the [Converting a single-scale simulation to multi-scale](@ref) page. It was modified by removing the "Plant" node in the dummy MTG passed into the [`run!`](@ref)function. Without that "Plant" node, only "Scene"-scale models can run initially, and since no nodes are created, "Plant"-scale models will never be run.

```julia
PlantSimEngine.@process "tt_cu" verbose = false

struct ToyTt_CuModel <: AbstractTt_CuModel end

function PlantSimEngine.run!(::ToyTt_CuModel, models, status, meteo, constants, extra=nothing)
    status.TT_cu +=
        meteo.TT
end

function PlantSimEngine.inputs_(::ToyTt_CuModel)
    NamedTuple() # No input variables
end

function PlantSimEngine.outputs_(::ToyTt_CuModel)
    (TT_cu=-Inf,)
end

mapping_multiscale = Dict(
    "Scene" => ToyTt_CuModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.5),
        ToyRUEGrowthModel(0.2),
    ),
)

mtg_multiscale = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 0, 0),)
#plant = MultiScaleTreeGraph.Node(mtg_multiscale, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))

out_multiscale = run!(mtg_multiscale, mapping_multiscale, meteo_day)

out_multiscale["Plant"][:LAI]
```

In the above code, uncommenting the second line will add a "Plant" node to the MTG, and the simulation will then behave as intuitively expected.