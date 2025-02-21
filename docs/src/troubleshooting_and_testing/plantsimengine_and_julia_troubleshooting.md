# Troubleshooting error messages

PlantSimEngine attempts to be as comfortable and easy to use as possible for the user, and many kinds of user error will be caught and explanations provided to resolve them, but there are still blind spots, as well as syntax errors that will often generate a Julia error (which can be less intuitive to decrypt) rather than a PlantSimEngine error.

To help people newer to Julia with troubleshooting, here are a few common 'easy-to-make' mistakes with the current API that might not be obvious to interpret, and pointers on how to fix them.

They are listed by 'nature of error', rather than by error message, so you may need to search the page to find your specific error.

## Tips and workflow

Some errors are very specific as to their cause, and the PlantSimEngine errors tend to be explicit about which parameter / variable / organ is causing the error, helping narrow down its origin.

Some generic-looking errors usually do contain some extra information to help focus the debugging hunt. For instance, a dispatch failure on run! caused by some issue with args/kwargs may highlight explicitely indicate which arguments are currently causing conflict. In VSCode, such arguments are highlighted in red (the first and last arguments in the example below) : 

```julia
a = 1
run!(a, simple_mtg, mapping, meteo_day, a)

ERROR: MethodError: no method matching run!(::Int64, ::Node{NodeMTG, Dict{…}}, ::Dict{String, Tuple{…}}, ::DataFrame, ::Int64)
The function `run!` exists, but no method is defined for this combination of argument types.

Closest candidates are:
  run!(::ToyPlantLeafSurfaceModel, ::Any, ::Any, ::Any, ::Any, ::Any)
   @ PlantSimEngine /PlantSimEngine/examples/ToyLeafSurfaceModel.jl:75
   ...
```

If you wish to search for a specific error in the current page, copy the part of the description that is not specific to your script, and Ctrl+F it here. In the above example, the generic part would be : 
```julia
ERROR: MethodError: no method matching
```

TODO forum, github
TODO

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

### Forgetting a kwarg when declaring a MultiScaleModel

A MultiScaleModel requires two kwargs, model and mapping : 

```julia
models = MultiScaleModel(
        model=ToyLAIModel(),
        mapping=[:TT_cu => "Scene",],
    )
```

Forgetting 'model=' :

```julia
models = MultiScaleModel(
        ToyLAIModel(),
        mapping=[:TT_cu => "Scene",],
    )
ERROR: MethodError: no method matching MultiScaleModel(::ToyLAIModel; mapping::Vector{Pair{Symbol, String}})
The type `MultiScaleModel` exists, but no method is defined for this combination of argument types when trying to construct it.
    
Closest candidates are:
    MultiScaleModel(::T, ::Any) where T<:AbstractModel got unsupported keyword argument "mapping"
    @ PlantSimEngine PlantSimEngine/src/mtg/MultiScaleModel.jl:188
    MultiScaleModel(; model, mapping)
    @ PlantSimEngine PlantSimEngine/src/mtg/MultiScaleModel.jl:191
```

Forgetting 'mapping=' :
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
    mapping = [should_be_symbol => "Other_Scale"] # should_be_symbol is a variable, likely not found in the current module 
),
...
),
```

Here's the correct version : 
```julia
mapping = Dict("Scale" =>
MultiScaleModel(
    model = ToyModel(),
    mapping = [:should_be_symbol => "Other_Scale"] # should_be_symbol is now a symbol
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

The fix is to add Process2Model() -or an other model for the same process- to the mapping.

### Status kwargs ?
TODO

## Forgetting to declare a scale in the mapping but having variables point to it

If there is a need to collect variables at two different scales, and one scale is completely absent from the mapping, the error currently occurs on the Julia side :

```julia
"E2" => (
        MultiScaleModel(
        model = HardDepSameScaleEchelle2Model(),
        mapping = [:c => "E1" => :c, :e3 => "E3" => :e3, :f3 => "E3" => :f3,], 
        ),
    ),
# No E3 in the mapping !

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

