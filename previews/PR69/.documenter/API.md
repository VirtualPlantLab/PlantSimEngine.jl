
# API {#API}

## Index {#Index}
- [`PlantSimEngine.Examples`](#PlantSimEngine.Examples)
- [`PlantSimEngine.AbstractModel`](#PlantSimEngine.AbstractModel)
- [`PlantSimEngine.AbstractNodeMapping`](#PlantSimEngine.AbstractNodeMapping)
- [`PlantSimEngine.DataFormat`](#PlantSimEngine.DataFormat-Tuple{Type{<:AbstractDataFrame}})
- [`PlantSimEngine.DependencyGraph`](#PlantSimEngine.DependencyGraph)
- [`PlantSimEngine.DependencyTrait`](#PlantSimEngine.DependencyTrait)
- [`PlantSimEngine.GraphSimulation`](#PlantSimEngine.GraphSimulation)
- [`PlantSimEngine.MappedVar`](#PlantSimEngine.MappedVar)
- [`PlantSimEngine.ModelList`](#PlantSimEngine.ModelList)
- [`PlantSimEngine.MultiNodeMapping`](#PlantSimEngine.MultiNodeMapping)
- [`PlantSimEngine.MultiScaleModel`](#PlantSimEngine.MultiScaleModel)
- [`PlantSimEngine.ObjectDependencyTrait`](#PlantSimEngine.ObjectDependencyTrait)
- [`PlantSimEngine.PreviousTimeStep`](#PlantSimEngine.PreviousTimeStep)
- [`PlantSimEngine.RefVariable`](#PlantSimEngine.RefVariable)
- [`PlantSimEngine.RefVector`](#PlantSimEngine.RefVector)
- [`PlantSimEngine.SelfNodeMapping`](#PlantSimEngine.SelfNodeMapping)
- [`PlantSimEngine.SingleNodeMapping`](#PlantSimEngine.SingleNodeMapping)
- [`PlantSimEngine.Status`](#PlantSimEngine.Status)
- [`PlantSimEngine.TimeStepDependencyTrait`](#PlantSimEngine.TimeStepDependencyTrait-Tuple{Type})
- [`PlantSimEngine.UninitializedVar`](#PlantSimEngine.UninitializedVar)
- [`PlantSimEngine.EF`](#PlantSimEngine.EF-Tuple{Any,%20Any})
- [`PlantSimEngine.NRMSE`](#PlantSimEngine.NRMSE-Tuple{Any,%20Any})
- [`PlantSimEngine.RMSE`](#PlantSimEngine.RMSE-Tuple{Any,%20Any})
- [`PlantSimEngine.add_mapped_variables_with_outputs_as_inputs!`](#PlantSimEngine.add_mapped_variables_with_outputs_as_inputs!-Tuple{Any})
- [`PlantSimEngine.add_model_vars`](#PlantSimEngine.add_model_vars-Tuple{Any,%20Any,%20Any})
- [`PlantSimEngine.add_organ!`](#PlantSimEngine.add_organ!-Tuple{MultiScaleTreeGraph.Node,%20Vararg{Any,%204}})
- [`PlantSimEngine.check_dimensions`](#PlantSimEngine.check_dimensions-Tuple{Any,%20Any})
- [`PlantSimEngine.convert_reference_values!`](#PlantSimEngine.convert_reference_values!-Tuple{Dict{String,%20Dict{Symbol,%20Any}}})
- [`PlantSimEngine.convert_vars`](#PlantSimEngine.convert_vars)
- [`PlantSimEngine.convert_vars!`](#PlantSimEngine.convert_vars!)
- [`PlantSimEngine.convert_vars!`](#PlantSimEngine.convert_vars!-Tuple{Dict{String,%20Dict{Symbol,%20Any}},%20Any})
- [`PlantSimEngine.default_variables_from_mapping`](#PlantSimEngine.default_variables_from_mapping)
- [`PlantSimEngine.dep`](#PlantSimEngine.dep)
- [`PlantSimEngine.diff_vars`](#PlantSimEngine.diff_vars-Tuple{Any,%20Any})
- [`PlantSimEngine.dr`](#PlantSimEngine.dr-Tuple{Any,%20Any})
- [`PlantSimEngine.draw_guide`](#PlantSimEngine.draw_guide-NTuple{5,%20Any})
- [`PlantSimEngine.draw_panel`](#PlantSimEngine.draw_panel-NTuple{5,%20Any})
- [`PlantSimEngine.drop_process`](#PlantSimEngine.drop_process-Tuple{Any,%20Symbol})
- [`PlantSimEngine.fit`](#PlantSimEngine.fit-Tuple{Type{PlantSimEngine.Examples.Beer},%20Any})
- [`PlantSimEngine.fit`](#PlantSimEngine.fit)
- [`PlantSimEngine.flatten_vars`](#PlantSimEngine.flatten_vars-Tuple{Any})
- [`PlantSimEngine.get_mapping`](#PlantSimEngine.get_mapping-Tuple{Any})
- [`PlantSimEngine.get_models`](#PlantSimEngine.get_models-Tuple{Any})
- [`PlantSimEngine.get_multiscale_default_value`](#PlantSimEngine.get_multiscale_default_value)
- [`PlantSimEngine.get_nsteps`](#PlantSimEngine.get_nsteps-Tuple{Any})
- [`PlantSimEngine.get_status`](#PlantSimEngine.get_status-Tuple{Any})
- [`PlantSimEngine.get_vars_not_propagated`](#PlantSimEngine.get_vars_not_propagated-Tuple{Any})
- [`PlantSimEngine.hard_dependencies`](#PlantSimEngine.hard_dependencies-Tuple{Any})
- [`PlantSimEngine.homogeneous_ts_kwargs`](#PlantSimEngine.homogeneous_ts_kwargs-Tuple{Any,%20Any})
- [`PlantSimEngine.homogeneous_ts_kwargs`](#PlantSimEngine.homogeneous_ts_kwargs-Union{Tuple{T},%20Tuple{N},%20Tuple{NamedTuple{N,%20T},%20Any}}%20where%20{N,%20T})
- [`PlantSimEngine.init_node_status!`](#PlantSimEngine.init_node_status!)
- [`PlantSimEngine.init_simulation`](#PlantSimEngine.init_simulation-Tuple{Any,%20Any})
- [`PlantSimEngine.init_status!`](#PlantSimEngine.init_status!-Tuple{Dict{String,%20ModelList}})
- [`PlantSimEngine.init_statuses`](#PlantSimEngine.init_statuses)
- [`PlantSimEngine.init_variables`](#PlantSimEngine.init_variables-Tuple{T}%20where%20T<:AbstractModel)
- [`PlantSimEngine.init_variables_manual`](#PlantSimEngine.init_variables_manual-Tuple{Any,%20Any})
- [`PlantSimEngine.inputs`](#PlantSimEngine.inputs-Tuple{T}%20where%20T<:AbstractModel)
- [`PlantSimEngine.inputs`](#PlantSimEngine.inputs-Union{Tuple{Dict{String,%20T}},%20Tuple{T}}%20where%20T)
- [`PlantSimEngine.is_graph_cyclic`](#PlantSimEngine.is_graph_cyclic-Tuple{PlantSimEngine.DependencyGraph})
- [`PlantSimEngine.is_initialized`](#PlantSimEngine.is_initialized-Tuple{T}%20where%20T<:ModelList)
- [`PlantSimEngine.mapped_variables`](#PlantSimEngine.mapped_variables)
- [`PlantSimEngine.mapped_variables_no_outputs_from_other_scale`](#PlantSimEngine.mapped_variables_no_outputs_from_other_scale)
- [`PlantSimEngine.model_`](#PlantSimEngine.model_-Tuple{AbstractModel})
- [`PlantSimEngine.object_parallelizable`](#PlantSimEngine.object_parallelizable-Tuple{T}%20where%20T)
- [`PlantSimEngine.outputs`](#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation,%20Any})
- [`PlantSimEngine.outputs`](#PlantSimEngine.outputs-Tuple{T}%20where%20T<:AbstractModel)
- [`PlantSimEngine.outputs`](#PlantSimEngine.outputs-Union{Tuple{Dict{String,%20T}},%20Tuple{T}}%20where%20T)
- [`PlantSimEngine.parallelizable`](#PlantSimEngine.parallelizable-Tuple{T}%20where%20T)
- [`PlantSimEngine.pre_allocate_outputs`](#PlantSimEngine.pre_allocate_outputs-Tuple{Any,%20Any,%20Any})
- [`PlantSimEngine.propagate_values!`](#PlantSimEngine.propagate_values!-Tuple{Any,%20Any,%20Any})
- [`PlantSimEngine.ref_var`](#PlantSimEngine.ref_var-Tuple{Any})
- [`PlantSimEngine.reverse_mapping`](#PlantSimEngine.reverse_mapping-Union{Tuple{Dict{String,%20T}},%20Tuple{T}}%20where%20T)
- [`PlantSimEngine.run!`](#PlantSimEngine.run!)
- [`PlantSimEngine.run!`](#PlantSimEngine.run!)
- [`PlantSimEngine.save_results!`](#PlantSimEngine.save_results!-Tuple{PlantSimEngine.GraphSimulation,%20Any})
- [`PlantSimEngine.search_inputs_in_multiscale_output`](#PlantSimEngine.search_inputs_in_multiscale_output-NTuple{5,%20Any})
- [`PlantSimEngine.search_inputs_in_output`](#PlantSimEngine.search_inputs_in_output-Tuple{Any,%20Any,%20Any})
- [`PlantSimEngine.soft_dependencies`](#PlantSimEngine.soft_dependencies)
- [`PlantSimEngine.status`](#PlantSimEngine.status-Tuple{Any})
- [`PlantSimEngine.status_from_template`](#PlantSimEngine.status_from_template-Tuple{Dict{Symbol}})
- [`PlantSimEngine.timestep_parallelizable`](#PlantSimEngine.timestep_parallelizable-Tuple{T}%20where%20T)
- [`PlantSimEngine.to_initialize`](#PlantSimEngine.to_initialize-Tuple{PlantSimEngine.AbstractDependencyNode})
- [`PlantSimEngine.to_initialize`](#PlantSimEngine.to_initialize-Tuple{ModelList})
- [`PlantSimEngine.transform_single_node_mapped_variables_as_self_node_output!`](#PlantSimEngine.transform_single_node_mapped_variables_as_self_node_output!-Tuple{Any})
- [`PlantSimEngine.traverse_dependency_graph`](#PlantSimEngine.traverse_dependency_graph-Tuple{PlantSimEngine.DependencyGraph,%20Function})
- [`PlantSimEngine.traverse_dependency_graph!`](#PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.SoftDependencyNode,%20Function,%20Vector})
- [`PlantSimEngine.traverse_dependency_graph!`](#PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.HardDependencyNode,%20Function,%20Vector})
- [`PlantSimEngine.variables`](#PlantSimEngine.variables-Union{Tuple{T},%20Tuple{T,%20Vararg{Any}}}%20where%20T<:Union{Missing,%20AbstractModel})
- [`PlantSimEngine.variables`](#PlantSimEngine.variables-Tuple{Module})
- [`PlantSimEngine.variables`](#PlantSimEngine.variables-Union{Tuple{Dict{String,%20T}},%20Tuple{T}}%20where%20T)
- [`PlantSimEngine.variables`](#PlantSimEngine.variables-Tuple{PlantSimEngine.SoftDependencyNode})
- [`PlantSimEngine.variables_multiscale`](#PlantSimEngine.variables_multiscale)
- [`PlantSimEngine.variables_outputs_from_other_scale`](#PlantSimEngine.variables_outputs_from_other_scale-Tuple{Any})
- [`PlantSimEngine.variables_typed`](#PlantSimEngine.variables_typed-Tuple{T}%20where%20T<:AbstractModel)
- [`PlantSimEngine.vars_not_init_`](#PlantSimEngine.vars_not_init_-Union{Tuple{T},%20Tuple{T,%20Any}}%20where%20T<:Status)
- [`PlantSimEngine.@process`](#PlantSimEngine.@process-Tuple{Any,%20Vararg{Any}})


## API documentation {#API-documentation}
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantMeteo.TimeStepTable-Union{Tuple{DataFrame}, Tuple{Status}, Tuple{DataFrame, Any}} where Status' href='#PlantMeteo.TimeStepTable-Union{Tuple{DataFrame}, Tuple{Status}, Tuple{DataFrame, Any}} where Status'>#</a>&nbsp;<b><u>PlantMeteo.TimeStepTable</u></b> &mdash; <i>Method</i>.




```julia
TimeStepTable{Status}(df::DataFrame)
```


Method to build a `TimeStepTable` (from [PlantMeteo.jl](https://palmstudio.github.io/PlantMeteo.jl/stable/))  from a `DataFrame`, but with each row being a `Status`.

**Note**

[`ModelList`](/model_switching#ModelList) uses `TimeStepTable{Status}` by default (see examples below).

**Examples**

```julia
using PlantSimEngine, DataFrames

# A TimeStepTable from a DataFrame:
df = DataFrame(
    Tₗ=[25.0, 26.0],
    aPPFD=[1000.0, 1200.0],
    Cₛ=[400.0, 400.0],
    Dₗ=[1.0, 1.2],
)
TimeStepTable{Status}(df)

# A leaf with several values for at least one of its variable will automatically use 
# TimeStepTable{Status} with the time steps:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

# The status of the leaf is a TimeStepTable:
status(models)

# Of course we can also create a TimeStepTable with Status manually:
TimeStepTable(
    [
        Status(Tₗ=25.0, aPPFD=1000.0, Cₛ=400.0, Dₗ=1.0),
        Status(Tₗ=26.0, aPPFD=1200.0, Cₛ=400.0, Dₗ=1.2),
    ]
)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/TimeStepTable.jl#L2-L46)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.AbstractModel' href='#PlantSimEngine.AbstractModel'>#</a>&nbsp;<b><u>PlantSimEngine.AbstractModel</u></b> &mdash; <i>Type</i>.




Abstract model type. All models are subtypes of this one.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/Abstract_model_structs.jl#L1-L3)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.ModelList' href='#PlantSimEngine.ModelList'>#</a>&nbsp;<b><u>PlantSimEngine.ModelList</u></b> &mdash; <i>Type</i>.




```julia
ModelList(models::M, status::S)
ModelList(;
    status=nothing,
    init_fun::Function=init_fun_default,
    type_promotion=nothing,
    variables_check=true,
    kwargs...
)
```


List the models for a simulation (`models`), and does all boilerplate for variable initialization,  type promotion, time steps handling.

::: tip Note

The status field depends on the input models. You can get the variables needed by a model using [`variables`](/API#PlantSimEngine.variables-Tuple{Module}) on the instantiation of a model. You can also use [`inputs`](/API#PlantSimEngine.inputs-Tuple{T}%20where%20T<:AbstractModel) and [`outputs`](/API#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation,%20Any}) instead.

:::

**Arguments**
- `models`: a list of models. Usually given as a `NamedTuple`, but can be any other structure that 
  

implements `getproperty`.
- `status`: a structure containing the initializations for the variables of the models. Usually a NamedTuple
  

when given as a kwarg, or any structure that implements the Tables interface from `Tables.jl` (_e.g._ DataFrame, see details).
- `nsteps=nothing`: the number of time steps to pre-allocated. If `nothing`, the number of time steps is deduced from the status (or 1 if no status is given).
  
- `init_fun`: a function that initializes the status based on a vector of NamedTuples (see details).
  
- `type_promotion`: optional type conversion for the variables with default values.
  

`nothing` by default, _i.e._ no conversion. Note that conversion is not applied to the variables input by the user as `kwargs` (need to do it manually). Should be provided as a Dict with current type as keys and new type as values.
- `variables_check=true`: check that all needed variables are initialized by the user.
  
- `kwargs`: the models, named after the process they simulate.
  

**Details**

The argument `init_fun` is set by default to `init_fun_default` which initializes the status with a `TimeStepTable` of `Status` structures.

If you change `init_fun` by another function, make sure the type you are using (_i.e._ in place of `TimeStepTable`)  implements the `Tables.jl` interface (_e.g._ DataFrame does). And if you still use `TimeStepTable` but only change `Status`, make sure the type you give is indexable using the dot synthax (_e.g._ `x.var`).

If you need to input a custom Type for the status and make your users able to only partially initialize  the `status` field in the input, you&#39;ll have to implement a method for `add_model_vars!`, a function that  adds the models variables to the type in case it is not fully initialized. The default method is compatible  with any type that implements the `Tables.jl` interface (_e.g._ DataFrame), and `NamedTuples`.

Note that `ModelList`makes a copy of the input `status` if it does not list all needed variables.

**Examples**

We&#39;ll use the dummy models from the `dummy.jl` in the examples folder of the package. It  implements three dummy processes: `Process1Model`, `Process2Model` and `Process3Model`, with one model implementation each: `Process1Model`, `Process2Model` and `Process3Model`.

```julia
julia> using PlantSimEngine;
```


Including example processes and models:

```julia
julia> using PlantSimEngine.Examples;
```


```julia
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model());
[ Info: Some variables must be initialized before simulation: (process1 = (:var1, :var2), process2 = (:var1,)) (see `to_initialize()`)
```


```julia
julia> typeof(models)
ModelList{@NamedTuple{process1::Process1Model, process2::Process2Model, process3::Process3Model}, TimeStepTable{Status{(:var5, :var4, :var6, :var1, :var3, :var2), NTuple{6, Base.RefValue{Float64}}}}, Tuple{}}
```


No variables were given as keyword arguments, that means that the status of the ModelList is not set yet, and all variables are initialized to their default values given in the inputs and outputs (usually `typemin(Type)`, _i.e._ `-Inf` for floating point numbers). This component cannot be simulated yet.

To know which variables we need to initialize for a simulation, we use [`to_initialize`](/API#PlantSimEngine.to_initialize-Tuple{ModelList}):

```julia
julia> to_initialize(models)
(process1 = (:var1, :var2), process2 = (:var1,))
```


We can now provide values for these variables in the `status` field, and simulate the `ModelList`,  _e.g._ for `process3` (coupled with `process1` and `process2`):

```julia
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0, var2=0.3));
```


```julia
julia> meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995);
```


```julia
julia> run!(models,meteo)
```


```julia
julia> models[:var6]
1-element Vector{Float64}:
 58.0138985
```


If we want to use special types for the variables, we can use the `type_promotion` argument:

```julia
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0, var2=0.3), type_promotion = Dict(Float64 => Float32));
```


We used `type_promotion` to force the status into Float32:

```julia
julia> [typeof(models[i][1]) for i in keys(status(models))]
6-element Vector{DataType}:
 Float32
 Float32
 Float32
 Float64
 Float64
 Float32
```


But we see that only the default variables (the ones that are not given in the status arguments) were converted to Float32, the two other variables that we gave were not converted. This is because we want to give the ability to users to give any type for the variables they provide  in the status. If we want all variables to be converted to Float32, we can pass them as Float32:

```julia
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0f0, var2=0.3f0), type_promotion = Dict(Float64 => Float32));
```


We used `type_promotion` to force the status into Float32:

```julia
julia> [typeof(models[i][1]) for i in keys(status(models))]
6-element Vector{DataType}:
 Float32
 Float32
 Float32
 Float32
 Float32
 Float32
```


We can also use DataFrame as the status type:

```julia
julia> using DataFrames;
```


```julia
julia> df = DataFrame(:var1 => [13.747, 13.8], :var2 => [1.0, 1.0]);
```


```julia
julia> m = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=df, init_fun=x -> DataFrame(x));
```


Note that we use `init_fun` to force the status into a `DataFrame`, otherwise it would be automatically converted into a `TimeStepTable{Status}`.

```julia
julia> status(m)
2×6 DataFrame
 Row │ var5     var4     var6     var1     var3     var2    
     │ Float64  Float64  Float64  Float64  Float64  Float64 
─────┼──────────────────────────────────────────────────────
   1 │    -Inf     -Inf     -Inf   13.747     -Inf      1.0
   2 │    -Inf     -Inf     -Inf   13.8       -Inf      1.0
```


Note that computations will be slower using DataFrame, so if performance is an issue, use TimeStepTable instead (or a NamedTuple as shown in the example).


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L2-L179)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.MultiScaleModel' href='#PlantSimEngine.MultiScaleModel'>#</a>&nbsp;<b><u>PlantSimEngine.MultiScaleModel</u></b> &mdash; <i>Type</i>.




```julia
MultiScaleModel(model, mapping)
```


A structure to make a model multi-scale. It defines a mapping between the variables of a  model and the nodes symbols from which the values are taken from.

**Arguments**
- `model<:AbstractModel`: the model to make multi-scale
  
- `mapping<:Vector{Pair{Symbol,Union{AbstractString,Vector{AbstractString}}}}`: a vector of pairs of symbols and strings or vectors of strings
  

The mapping can be of the form:
1. `[:variable_name => "Plant"]`: We take one value from the Plant node
  
1. `[:variable_name => ["Leaf"]]`: We take a vector of values from the Leaf nodes
  
1. `[:variable_name => ["Leaf", "Internode"]]`: We take a vector of values from the Leaf and Internode nodes
  
1. `[:variable_name => "Plant" => :variable_name_in_plant_scale]`: We take one value from another variable name in the Plant node
  
1. `[:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]`: We take a vector of values from the Leaf and Internode nodes with different names
  
1. `[PreviousTimeStep(:variable_name) => ...]`: We flag the variable to be initialized with the value from the previous time step, and we do not use it to build the dep graph
  
1. `[:variable_name => :variable_name_from_another_model]`: We take the value from another model at the same scale but rename it
  
1. `[PreviousTimeStep(:variable_name),]`: We just flag the variable as a PreviousTimeStep to not use it to build the dep graph
  

Details about the different forms:
1. The variable `variable_name` of the model will be taken from the `Plant` node, assuming only one node has the `Plant` symbol.
  

In this case the value available from the status will be a scalar, and so the user must guaranty that only one node of type `Plant` is available in the MTG.
1. The variable `variable_name` of the model will be taken from the `Leaf` nodes. Notice it is given as a vector, indicating that the values will be taken 
  

from all the nodes of type `Leaf`. The model should be able to handle a vector of values. Note that even if there is only one node of type `Leaf`, the value will be taken as a vector of one element.
1. The variable `variable_name` of the model will be taken from the `Leaf` and `Internode` nodes. The values will be taken from all the nodes of type `Leaf` 
  

and `Internode`.
1. The variable `variable_name` of the model will be taken from the variable called `variable_name_in_plant_scale` in the `Plant` node. This is useful
  

when the variable name in the model is different from the variable name in the scale it is taken from.
1. The variable `variable_name` of the model will be taken from the variable called `variable_name_1` in the `Leaf` node and `variable_name_2` in the `Internode` node.
  
1. The variable `variable_name` of the model uses the value computed on the previous time-step. This implies that the variable is not used to build the dependency graph
  

because the dependency graph only applies on the current time-step. This is used to avoid circular dependencies when a variable depends on itself. The value can be initialized in the Status if needed.
1. The variable `variable_name` of the model will be taken from another model at the same scale, but with another variable name.
  
1. The variable `variable_name` of the model is just flagged as a PreviousTimeStep variable, so it is not used to build the dependency graph.
  

Note that the mapping does not make any copy of the values, it only references them. This means that if the values are updated in the status of one node, they will be updated in the other nodes.

**Examples**

```julia
julia> using PlantSimEngine;
```


Including example processes and models:

```julia
julia> using PlantSimEngine.Examples;
```


Let&#39;s take a model:

```julia
julia> model = ToyCAllocationModel()
ToyCAllocationModel()
```


We can make it multi-scale by defining a mapping between the variables of the model and the nodes symbols from which the values are taken from:

For example, if the `carbon_allocation` comes from the `Leaf` and `Internode` nodes, we can define the mapping as follows:

```julia
julia> mapping = [:carbon_allocation => ["Leaf", "Internode"]]
1-element Vector{Pair{Symbol, Vector{String}}}:
 :carbon_allocation => ["Leaf", "Internode"]
```


The mapping is a vector of pairs of symbols and strings or vectors of strings. In this case, we have only one pair to define the mapping between the `carbon_allocation` variable and the `Leaf` and `Internode` nodes.

We can now make the model multi-scale by passing the model and the mapping to the `MultiScaleModel` constructor :

```julia
julia> multiscale_model = PlantSimEngine.MultiScaleModel(model, mapping)
MultiScaleModel{ToyCAllocationModel, Vector{Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}}}(ToyCAllocationModel(), Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}[:carbon_allocation => ["Leaf" => :carbon_allocation, "Internode" => :carbon_allocation]])
```


We can access the mapping and the model:

```julia
julia> PlantSimEngine.mapping_(multiscale_model)
1-element Vector{Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}}:
 :carbon_allocation => ["Leaf" => :carbon_allocation, "Internode" => :carbon_allocation]
```


```julia
julia> PlantSimEngine.model_(multiscale_model)
ToyCAllocationModel()
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/MultiScaleModel.jl#L1-L104)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.PreviousTimeStep' href='#PlantSimEngine.PreviousTimeStep'>#</a>&nbsp;<b><u>PlantSimEngine.PreviousTimeStep</u></b> &mdash; <i>Type</i>.




```julia
PreviousTimeStep(variable)
```


A structure to manually flag a variable in a model to use the value computed on the previous time-step.  This implies that the variable is not used to build the dependency graph because the dependency graph only  applies on the current time-step. This is used to avoid circular dependencies when a variable depends on itself. The value can be initialized in the Status if needed.

The process is added when building the MultiScaleModel, to avoid conflicts between processes with the same variable name. For exemple one process can define a variable `:carbon_biomass` as a `PreviousTimeStep`, but the othe process would use  the variable as a dependency for the current time-step (and it would be fine because theyr don&#39;t share the same issue of cyclic dependency).


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/variables_wrappers.jl#L15-L26)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Status' href='#PlantSimEngine.Status'>#</a>&nbsp;<b><u>PlantSimEngine.Status</u></b> &mdash; <i>Type</i>.




```julia
Status(vars)
```


Status type used to store the values of the variables during simulation. It is mainly used as the structure to store the variables in the `TimeStepRow` of a `TimeStepTable` (see  [`PlantMeteo.jl` docs](https://palmstudio.github.io/PlantMeteo.jl/stable/)) of a [`ModelList`](/model_switching#ModelList).

Most of the code is taken from MasonProtter/MutableNamedTuples.jl, so `Status` is a MutableNamedTuples with a few modifications, so in essence, it is a stuct that stores a `NamedTuple` of the references to the values of the variables, which makes it mutable.

**Examples**

A leaf with one value for all variables will make a status with one time step:

```julia
julia> using PlantSimEngine
```


```julia
julia> st = PlantSimEngine.Status(Rₛ=13.747, sky_fraction=1.0, d=0.03, aPPFD=1500.0);
```


All these indexing methods are valid:

```julia
julia> st[:Rₛ]
13.747
```


```julia
julia> st.Rₛ
13.747
```


```julia
julia> st[1]
13.747
```


Setting a Status variable is very easy:

```julia
julia> st[:Rₛ] = 20.0
20.0
```


```julia
julia> st.Rₛ = 21.0
21.0
```


```julia
julia> st[1] = 22.0
22.0
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/Status.jl#L1-L56)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.EF-Tuple{Any, Any}' href='#PlantSimEngine.EF-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.EF</u></b> &mdash; <i>Method</i>.




```julia
EF(obs,sim)
```


Returns the Efficiency Factor between observations `obs` and simulations `sim` using NSE (Nash-Sutcliffe efficiency) model. More information can be found at https://en.wikipedia.org/wiki/Nash%E2%80%93Sutcliffe_model_efficiency_coefficient.

The closer to 1 the better.

**Examples**

```julia
using PlantSimEngine

obs = [1.0, 2.0, 3.0]
sim = [1.1, 2.1, 3.1]

EF(obs, sim)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/evaluation/statistics.jl#L45-L63)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.NRMSE-Tuple{Any, Any}' href='#PlantSimEngine.NRMSE-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.NRMSE</u></b> &mdash; <i>Method</i>.




```julia
NRMSE(obs,sim)
```


Returns the Normalized Root Mean Squared Error between observations `obs` and simulations `sim`. Normalization is performed using division by observations range (max-min).

**Examples**

```julia
using PlantSimEngine

obs = [1.0, 2.0, 3.0]
sim = [1.1, 2.1, 3.1]

NRMSE(obs, sim)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/evaluation/statistics.jl#L24-L40)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.RMSE-Tuple{Any, Any}' href='#PlantSimEngine.RMSE-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.RMSE</u></b> &mdash; <i>Method</i>.




```julia
RMSE(obs,sim)
```


Returns the Root Mean Squared Error between observations `obs` and simulations `sim`.

The closer to 0 the better.

**Examples**

```julia
using PlantSimEngine

obs = [1.0, 2.0, 3.0]
sim = [1.1, 2.1, 3.1]

RMSE(obs, sim)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/evaluation/statistics.jl#L2-L19)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.add_organ!-Tuple{MultiScaleTreeGraph.Node, Vararg{Any, 4}}' href='#PlantSimEngine.add_organ!-Tuple{MultiScaleTreeGraph.Node, Vararg{Any, 4}}'>#</a>&nbsp;<b><u>PlantSimEngine.add_organ!</u></b> &mdash; <i>Method</i>.




```julia
add_organ!(node::MultiScaleTreeGraph.Node, sim_object, link, symbol, scale; index=0, id=MultiScaleTreeGraph.new_id(MultiScaleTreeGraph.get_root(node)), attributes=Dict{Symbol,Any}(), check=true)
```


Add an organ to the graph, automatically taking care of initialising the status of the organ (multiscale-)variables.

This function should be called from a model that implements organ emergence, for example in function of thermal time.

**Arguments**
- `node`: the node to which the organ is added (the parent organ of the new organ)
  
- `sim_object`: the simulation object, e.g. the `GraphSimulation` object from the `extra` argument of a model.
  
- `link`: the link type between the new node and the organ:
  - `"<"`: the new node is following the parent organ
    
  - `"+"`: the new node is branching the parent organ
    
  - `"/"`: the new node is decomposing the parent organ, _i.e._ we change scale
    
  
- `symbol`: the symbol of the organ, _e.g._ `"Leaf"`
  
- `scale`: the scale of the organ, _e.g._ `2`.
  
- `index`: the index of the organ, _e.g._ `1`. The index may be used to easily identify branching order, or growth unit index on the axis. It is different from the node `id` that is unique.
  
- `id`: the unique id of the new node. If not provided, a new id is generated.
  
- `attributes`: the attributes of the new node. If not provided, an empty dictionary is used.
  
- `check`: a boolean indicating if variables initialisation should be checked. Passed to `init_node_status!`.
  

**Returns**
- `status`: the status of the new node
  

**Examples**

See the `ToyInternodeEmergence` example model from the `Examples` module (also found in the `examples` folder), or the `test-mtg-dynamic.jl` test file for an example usage.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/add_organ.jl#L1-L31)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.dep' href='#PlantSimEngine.dep'>#</a>&nbsp;<b><u>PlantSimEngine.dep</u></b> &mdash; <i>Function</i>.




```julia
dep(m::ModelList, nsteps=1; verbose::Bool=true)
dep(mapping::Dict{String,T}; verbose=true)
```


Get the model dependency graph given a ModelList or a multiscale model mapping. If one graph is returned,  then all models are coupled. If several graphs are returned, then only the models inside each graph are coupled, and the models in different graphs are not coupled. `nsteps` is the number of steps the dependency graph will be used over. It is used to determine the length of the `simulation_id` argument for each soft dependencies in the graph. It is set to `1` in the case of a  multiscale mapping.

**Details**

The dependency graph is computed by searching the inputs of each process in the outputs of its own scale, or the other scales. There are five cases for every model (one model simulates one process):
1. The process has no inputs. It is completely independent, and is placed as one of the roots of the dependency graph.
  
1. The process needs inputs from models at its own scale. We put it as a child of this other process.
  
1. The process needs inputs from another scale. We put it as a child of this process at another scale.
  
1. The process needs inputs from its own scale and another scale. We put it as a child of both.
  
1. The process is a hard dependency of another process (only possible at the same scale). In this case, the process is set as a hard-dependency of the 
  

other process, and its simulation is handled directly from this process.

For the 4th case, the process have two parent processes. This is OK because the process will only be computed once during simulation as we check if both  parents were run before running the process. 

Note that in the 5th case, we still need to check if a variable is needed from another scale. In this case, the parent node is  used as a child of the process at the other scale. Note there can be several levels of hard dependency graph, so this is done recursively.

How do we do all that? We identify the hard dependencies first. Then we link the inputs/outputs of the hard dependencies roots  to other scales if needed. Then we transform all these nodes into soft dependencies, that we put into a Dict of Scale =&gt; Dict(process =&gt; SoftDependencyNode). Then we traverse all these and we set nodes that need outputs from other nodes as inputs as children/parents. If a node has no dependency, it is set as a root node and pushed into a new Dict (independant_process_root). This Dict is the returned dependency graph. And  it presents root nodes as independent starting points for the sub-graphs, which are the models that are coupled together. We can then traverse each of  these graphs independently to retrieve the models that are coupled together, in the right order of execution.

**Examples**

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

dep(models)

# or directly with the processes:
models = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

dep(;models...)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/dependencies.jl#L3-L69)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.dr-Tuple{Any, Any}' href='#PlantSimEngine.dr-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.dr</u></b> &mdash; <i>Method</i>.




```julia
dr(obs,sim)
```


Returns the Willmott’s refined index of agreement dᵣ. Willmot et al. 2011. A refined index of model performance. https://rmets.onlinelibrary.wiley.com/doi/10.1002/joc.2419

The closer to 1 the better.

**Examples**

```julia
using PlantSimEngine

obs = [1.0, 2.0, 3.0]
sim = [1.1, 2.1, 3.1]

dr(obs, sim)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/evaluation/statistics.jl#L70-L88)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.fit' href='#PlantSimEngine.fit'>#</a>&nbsp;<b><u>PlantSimEngine.fit</u></b> &mdash; <i>Function</i>.




```julia
fit()
```


Optimize the parameters of a model using measurements and (potentially) initialisation values. 

Modellers should implement a method to `fit` for their model, with the following design pattern:

The call to the function should take the model type as the first argument (T::Type{&lt;:AbstractModel}),  the data as the second argument (as a `Table.jl` compatible type, such as `DataFrame`), and the  parameters initializations as keyword arguments (with default values when necessary).

For example the method for fitting the `Beer` model from the example script (see `src/examples/Beer.jl`) looks like  this:

```julia
function PlantSimEngine.fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)
    k = Statistics.mean(log.(df.Ri_PAR_f ./ (df.PPFD ./ J_to_umol)) ./ df.LAI)
    return (k=k,)
end
```


The function should return the optimized parameters as a `NamedTuple` of the form `(parameter_name=parameter_value,)`.

Here is an example usage with the `Beer` model, where we fit the `k` parameter from &quot;measurements&quot; of `PPFD`, `LAI`  and `Ri_PAR_f`. 

```julia
# Including example processes and models:
using PlantSimEngine.Examples;

m = ModelList(Beer(0.6), status=(LAI=2.0,))
meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0)
run!(m, meteo)
df = DataFrame(aPPFD=m[:aPPFD][1], LAI=m.status.LAI[1], Ri_PAR_f=meteo.Ri_PAR_f[1])
fit(Beer, df)
```


Note that this is a dummy example to show that the fitting method works, as we simulate the PPFD  using the Beer-Lambert law with a value of `k=0.6`, and then use the simulated PPFD to fit the `k` parameter again, which gives the same value as the one used on the simulation.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/evaluation/fit.jl#L2-L42)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_status!-Tuple{Dict{String, ModelList}}' href='#PlantSimEngine.init_status!-Tuple{Dict{String, ModelList}}'>#</a>&nbsp;<b><u>PlantSimEngine.init_status!</u></b> &mdash; <i>Method</i>.




```julia
init_status!(object::Dict{String,ModelList};vars...)
init_status!(component::ModelList;vars...)
```


Initialise model variables for components with user input.

**Examples**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

models = Dict(
    "Leaf" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    ),
    "InterNode" => ModelList(
        process1=Process1Model(1.0),
    )
)

init_status!(models, var1=1.0 , var2=2.0)
status(models["Leaf"])
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L168-L196)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_variables-Tuple{T} where T<:AbstractModel' href='#PlantSimEngine.init_variables-Tuple{T} where T<:AbstractModel'>#</a>&nbsp;<b><u>PlantSimEngine.init_variables</u></b> &mdash; <i>Method</i>.




```julia
init_variables(models...)
```


Initialized model variables with their default values. The variables are taken from the inputs and outputs of the models.

**Examples**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

init_variables(Process1Model(2.0))
init_variables(process1=Process1Model(2.0), process2=Process2Model())
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L222-L239)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.inputs-Tuple{T} where T<:AbstractModel' href='#PlantSimEngine.inputs-Tuple{T} where T<:AbstractModel'>#</a>&nbsp;<b><u>PlantSimEngine.inputs</u></b> &mdash; <i>Method</i>.




```julia
inputs(model::AbstractModel)
inputs(...)
```


Get the inputs of one or several models.

Returns an empty tuple by default for `AbstractModel`s (no inputs) or `Missing` models.

**Examples**

```julia
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

inputs(Process1Model(1.0))

# output
(:var1, :var2)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L1-L22)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.inputs-Union{Tuple{Dict{String, T}}, Tuple{T}} where T' href='#PlantSimEngine.inputs-Union{Tuple{Dict{String, T}}, Tuple{T}} where T'>#</a>&nbsp;<b><u>PlantSimEngine.inputs</u></b> &mdash; <i>Method</i>.




```julia
inputs(mapping::Dict{String,T})
```


Get the inputs of the models in a mapping, for each process and organ type.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L39-L43)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.is_initialized-Tuple{T} where T<:ModelList' href='#PlantSimEngine.is_initialized-Tuple{T} where T<:ModelList'>#</a>&nbsp;<b><u>PlantSimEngine.is_initialized</u></b> &mdash; <i>Method</i>.




```julia
is_initialized(m::T) where T <: ModelList
is_initialized(m::T, models...) where T <: ModelList
```


Check if the variables that must be initialized are, and return `true` if so, and `false` and an information message if not.

**Note**

There is no way to know before-hand which process will be simulated by the user, so if you have a component with a model for each process, the variables to initialize are always the smallest subset of all, meaning it is considered the user will simulate the variables needed for other models.

**Examples**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model()
)

is_initialized(models)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L274-L304)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation, Any}' href='#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.outputs</u></b> &mdash; <i>Method</i>.




```julia
outputs(sim::GraphSimulation, sink)
```


Get the outputs from a simulation made on a plant graph.

**Details**

The first method returns a vector of `NamedTuple`, the second formats it  sing the sink function, for exemple a `DataFrame`.

**Arguments**
- `sim::GraphSimulation`: the simulation object, typically returned by `run!`.
  
- `sink`: a sink compatible with the Tables.jl interface (_e.g._ a `DataFrame`)
  
- `refvectors`: if `false` (default), the function will remove the RefVector values, otherwise it will keep them
  
- `no_value`: the value to replace `nothing` values. Default is `nothing`. Usually used to replace `nothing` values 
  

by `missing` in DataFrames.

**Examples**

```julia
using PlantSimEngine, MultiScaleTreeGraph, DataFrames, PlantSimEngine.Examples
```


Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```julia
julia> using PlantSimEngine.Examples;
```


```julia
mapping = Dict( "Plant" =>  ( MultiScaleModel(  model=ToyCAllocationModel(), mapping=[ :carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :carbon_allocation => ["Leaf", "Internode"] ], ), 
        MultiScaleModel(  model=ToyPlantRmModel(), mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],] ), ),"Internode" => ( ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004), Status(TT=10.0) ), "Leaf" => ( MultiScaleModel( model=ToyAssimModel(), mapping=[:soil_water_content => "Soil",], ), ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025), Status(aPPFD=1300.0, TT=10.0), ), "Soil" => ( ToySoilWaterModel(), ), )
```


```julia
mtg = import_mtg_example();
```


```julia
sim = run!(mtg, mapping, meteo, outputs = Dict(
    "Leaf" => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
    "Internode" => (:carbon_allocation,),
    "Plant" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
));
```


```julia
outputs(sim, DataFrames)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/GraphSimulation.jl#L42-L90)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.outputs-Tuple{T} where T<:AbstractModel' href='#PlantSimEngine.outputs-Tuple{T} where T<:AbstractModel'>#</a>&nbsp;<b><u>PlantSimEngine.outputs</u></b> &mdash; <i>Method</i>.




```julia
outputs(model::AbstractModel)
outputs(...)
```


Get the outputs of one or several models.

Returns an empty tuple by default for `AbstractModel`s (no outputs) or `Missing` models.

**Examples**

```julia
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

outputs(Process1Model(1.0))

# output
(:var3,)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L54-L75)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.outputs-Union{Tuple{Dict{String, T}}, Tuple{T}} where T' href='#PlantSimEngine.outputs-Union{Tuple{Dict{String, T}}, Tuple{T}} where T'>#</a>&nbsp;<b><u>PlantSimEngine.outputs</u></b> &mdash; <i>Method</i>.




```julia
outputs(mapping::Dict{String,T})
```


Get the outputs of the models in a mapping, for each process and organ type.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L84-L88)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.run!' href='#PlantSimEngine.run!'>#</a>&nbsp;<b><u>PlantSimEngine.run!</u></b> &mdash; <i>Function</i>.




```julia
run!(object, meteo, constants, extra=nothing; check=true, executor=Floops.ThreadedEx())
run!(object, mapping, meteo, constants, extra; nsteps, outputs, check, executor)
```


Run the simulation for each model in the model list in the correct order, _i.e._ respecting the dependency graph.

If several time-steps are given, the models are run sequentially for each time-step.

**Arguments**
- `object`: a [`ModelList`](/model_switching#ModelList), an array or dict of `ModelList`, or a plant graph (MTG).
  
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
  

[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
  
- `extra`: extra parameters, not available for simulation of plant graphs (the simulation object is passed using this).
  
- `check`: if `true`, check the validity of the model list before running the simulation (takes a little bit of time), and return more information while running.
  
- `executor`: the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) executor used to run the simulation either in sequential (`executor=SequentialEx()`), in a 
  

multi-threaded way (`executor=ThreadedEx()`, the default), or in a distributed way (`executor=DistributedEx()`).
- `mapping`: a mapping between the MTG and the model list.
  
- `nsteps`: the number of time-steps to run, only needed if no meteo is given (else it is infered from it).
  
- `outputs`: the outputs to get in dynamic for each node type of the MTG.
  

**Returns**

Modifies the status of the object in-place. Users may retrieve the results from the object using  the [`status`](https://virtualplantlab.github.io/PlantSimEngine.jl/stable/API/#PlantSimEngine.status-Tuple{Any})  function (see examples).

**Details**

**Model execution**

The models are run according to the dependency graph. If a model has a soft dependency on another model (_i.e._ its inputs are computed by another model), the other model is run first. If a model has several soft dependencies, the parents (the soft dependencies) are always computed first.

**Parallel execution**

Users can ask for parallel execution by providing a compatible executor to the `executor` argument. The package will also automatically check if the execution can be parallelized. If it is not the case and the user asked for a parallel computation, it return a warning and run the simulation sequentially. We use the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) package to run the simulation in parallel. That means that you can provide any compatible executor to the `executor` argument. You can take a look at [FoldsThreads.jl](https://github.com/JuliaFolds/FoldsThreads.jl) for extra thread-based executors, [FoldsDagger.jl](https://github.com/JuliaFolds/FoldsDagger.jl) for  Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon [FoldsCUDA.jl](https://github.com/JuliaFolds/FoldsCUDA.jl) for GPU computations  (see [this issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues/22)) and [FoldsKernelAbstractions.jl](https://github.com/JuliaFolds/FoldsKernelAbstractions.jl). You can also take a look at  [ParallelMagics.jl](https://github.com/JuliaFolds/ParallelMagics.jl) to check if automatic parallelization is possible.

**Example**

Import the packages: 

```julia
julia> using PlantSimEngine, PlantMeteo;
```


Load the dummy models given as example in the `Examples` sub-module:

```julia
julia> using PlantSimEngine.Examples;
```


Create a model list:

```julia
julia> models = ModelList(Process1Model(1.0), Process2Model(), Process3Model(), status = (var1=1.0, var2=2.0));
```


Create meteo data:

```julia
julia> meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0);
```


Run the simulation:

```julia
julia> run!(models, meteo);
```


Get the results:

```julia
julia> (models[:var4],models[:var6])
([12.0], [41.95])
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/run.jl#L1-L86)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.status-Tuple{Any}' href='#PlantSimEngine.status-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.status</u></b> &mdash; <i>Method</i>.




```julia
status(m)
status(m::AbstractArray{<:ModelList})
status(m::AbstractDict{T,<:ModelList})
```


Get a ModelList status, _i.e._ the state of the input (and output) variables.

See also [`is_initialized`](/API#PlantSimEngine.is_initialized-Tuple{T}%20where%20T<:ModelList) and [`to_initialize`](/API#PlantSimEngine.to_initialize-Tuple{ModelList})

**Examples**

```julia
using PlantSimEngine

# Including example models and processes:
using PlantSimEngine.Examples;

# Create a ModelList
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status = (var1=[15.0, 16.0], var2=0.3)
);

status(models)

# Or just one variable:
status(models,:var1)


# Or the status at the ith time-step:
status(models, 2)

# Or even more simply:
models[:var1]
# output
2-element Vector{Float64}:
 15.0
 16.0
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/get_status.jl#L1-L42)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.to_initialize-Tuple{ModelList}' href='#PlantSimEngine.to_initialize-Tuple{ModelList}'>#</a>&nbsp;<b><u>PlantSimEngine.to_initialize</u></b> &mdash; <i>Method</i>.




```julia
to_initialize(; verbose=true, vars...)
to_initialize(m::T)  where T <: ModelList
to_initialize(m::DependencyGraph)
to_initialize(mapping::Dict{String,T}, graph=nothing)
```


Return the variables that must be initialized providing a set of models and processes. The function takes into account model coupling and only returns the variables that are needed considering that some variables that are outputs of some models are used as inputs of others.

**Arguments**
- `verbose`: if `true`, print information messages.
  
- `vars...`: the models and processes to consider.
  
- `m::T`: a [`ModelList`](/model_switching#ModelList).
  
- `m::DependencyGraph`: a [`DependencyGraph`](/API#PlantSimEngine.DependencyGraph).
  
- `mapping::Dict{String,T}`: a mapping that associates models to organs.
  
- `graph`: a graph representing a plant or a scene, _e.g._ a multiscale tree graph. The graph is used to check if variables that are not initialized can be found in the graph nodes attributes.
  

**Examples**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

to_initialize(process1=Process1Model(1.0), process2=Process2Model())

# Or using a component directly:
models = ModelList(process1=Process1Model(1.0), process2=Process2Model())
to_initialize(models)

m = ModelList(
    (
        process1=Process1Model(1.0),
        process2=Process2Model()
    ),
    Status(var1 = 5.0, var2 = -Inf, var3 = -Inf, var4 = -Inf, var5 = -Inf)
)

to_initialize(m)
```


Or with a mapping:

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

mapping = Dict(
    "Leaf" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    ),
    "Internode" => ModelList(
        process1=Process1Model(1.0),
    )
)

to_initialize(mapping)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L1-L67)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.to_initialize-Tuple{PlantSimEngine.AbstractDependencyNode}' href='#PlantSimEngine.to_initialize-Tuple{PlantSimEngine.AbstractDependencyNode}'>#</a>&nbsp;<b><u>PlantSimEngine.to_initialize</u></b> &mdash; <i>Method</i>.




```julia
to_initialize(m::AbstractDependencyNode)
```


Return the variables that must be initialized providing a set of models and processes. The function just returns the inputs and outputs of each model, with their default values. To take into account model coupling, use the function at an upper-level instead, _i.e._  `to_initialize(m::ModelList)` or `to_initialize(m::DependencyGraph)`.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L107-L114)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables-Tuple{Module}' href='#PlantSimEngine.variables-Tuple{Module}'>#</a>&nbsp;<b><u>PlantSimEngine.variables</u></b> &mdash; <i>Method</i>.




```julia
variables(pkg::Module)
```


Returns a dataframe of all variables, their description and units in a package that has PlantSimEngine as a dependency (if implemented by the authors).

**Note to developers**

Developers of a package that depends on PlantSimEngine should  put a csv file in &quot;data/variables.csv&quot;, then this file will be  returned by the function.

**Examples**

Here is an example with the PlantBiophysics package:

```julia
#] add PlantBiophysics
using PlantBiophysics
variables(PlantBiophysics)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L159-L180)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables-Tuple{PlantSimEngine.SoftDependencyNode}' href='#PlantSimEngine.variables-Tuple{PlantSimEngine.SoftDependencyNode}'>#</a>&nbsp;<b><u>PlantSimEngine.variables</u></b> &mdash; <i>Method</i>.




```julia
variables(m::AbstractDependencyNode)
```


Returns a tuple with the name of the inputs and outputs variables needed by a model in  a dependency graph.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L143-L148)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables-Union{Tuple{Dict{String, T}}, Tuple{T}} where T' href='#PlantSimEngine.variables-Union{Tuple{Dict{String, T}}, Tuple{T}} where T'>#</a>&nbsp;<b><u>PlantSimEngine.variables</u></b> &mdash; <i>Method</i>.




```julia
variables(mapping::Dict{String,T})
```


Get the variables (inputs and outputs) of the models in a mapping, for each  process and organ type.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L185-L190)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables-Union{Tuple{T}, Tuple{T, Vararg{Any}}} where T<:Union{Missing, AbstractModel}' href='#PlantSimEngine.variables-Union{Tuple{T}, Tuple{T, Vararg{Any}}} where T<:Union{Missing, AbstractModel}'>#</a>&nbsp;<b><u>PlantSimEngine.variables</u></b> &mdash; <i>Method</i>.




```julia
variables(model)
variables(model, models...)
```


Returns a tuple with the name of the variables needed by a model, or a union of those variables for several models.

**Note**

Each model can (and should) have a method for this function.

```julia

using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

variables(Process1Model(1.0))

variables(Process1Model(1.0), Process2Model())

# output

(var1 = -Inf, var2 = -Inf, var3 = -Inf, var4 = -Inf, var5 = -Inf)
```


**See also**

[`inputs`](/API#PlantSimEngine.inputs-Tuple{T}%20where%20T<:AbstractModel), [`outputs`](/API#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation,%20Any}) and [`variables_typed`](/API#PlantSimEngine.variables_typed-Tuple{T}%20where%20T<:AbstractModel)


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L108-L138)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.@process-Tuple{Any, Vararg{Any}}' href='#PlantSimEngine.@process-Tuple{Any, Vararg{Any}}'>#</a>&nbsp;<b><u>PlantSimEngine.@process</u></b> &mdash; <i>Macro</i>.




```julia
@process(process::String, doc::String=""; verbose::Bool=true)
```


This macro generate the abstract type and some boilerplate code for the simulation of a process, along  with its documentation. It also prints out a short tutorial for implementing a model if `verbose=true`.

The abstract process type is then used as a supertype of all models implementations for the  process, and is named &quot;Abstract&lt;ProcessName&gt;Model&quot;, _e.g._ `AbstractGrowthModel` for a process called growth.

The first argument to `@process` is the new process name,  the second is any additional documentation that should be added  to the `Abstract<ProcessName>Model` type, and the third determines whether  the short tutorial should be printed or not.

Newcomers are encouraged to use this macro because it explains in detail what to do next with the process. But more experienced users may want to directly define their process without  printing the tutorial. To do so, you can just define a new abstract type and define it as a  subtype of `AbstractModel`:

```julia
abstract type MyNewProcess <: AbstractModel end
```


**Examples**

```julia
@process "dummy_process" "This is a dummy process that shall not be used"
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L1-L30)

</div>
<br>

## Un-exported {#Un-exported}

Private functions, types or constants from `PlantSimEngine`. These are not exported, so you need to use `PlantSimEngine.` to access them (_e.g._ `PlantSimEngine.DataFormat`). 
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='DataFrames.DataFrame-Tuple{T} where T<:(AbstractArray{<:ModelList})' href='#DataFrames.DataFrame-Tuple{T} where T<:(AbstractArray{<:ModelList})'>#</a>&nbsp;<b><u>DataFrames.DataFrame</u></b> &mdash; <i>Method</i>.




```julia
DataFrame(components <: AbstractArray{<:ModelList})
DataFrame(components <: AbstractDict{N,<:ModelList})
```


Fetch the data from a [`ModelList`](/model_switching#ModelList) (or an Array/Dict of) status into a DataFrame.

**Examples**

```julia
using PlantSimEngine
using DataFrames

# Creating a ModelList
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

# Converting to a DataFrame
df = DataFrame(models)

# Converting to a Dict of ModelLists
models = Dict(
    "Leaf" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    ),
    "InterNode" => ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model()
    )
)

# Converting to a DataFrame
df = DataFrame(models)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dataframe.jl#L1-L42)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='DataFrames.DataFrame-Union{Tuple{ModelList{T, S, V}}, Tuple{V}, Tuple{S}, Tuple{T}} where {T, S<:Status, V}' href='#DataFrames.DataFrame-Union{Tuple{ModelList{T, S, V}}, Tuple{V}, Tuple{S}, Tuple{T}} where {T, S<:Status, V}'>#</a>&nbsp;<b><u>DataFrames.DataFrame</u></b> &mdash; <i>Method</i>.




```julia
DataFrame(components::ModelList{T,S,V}) where {T,S<:Status,V}
```


Implementation of `DataFrame` for a `ModelList` model with one time step.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dataframe.jl#L75-L79)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='DataFrames.DataFrame-Union{Tuple{ModelList{T, S, V}}, Tuple{V}, Tuple{S}, Tuple{T}} where {T, S<:TimeStepTable, V}' href='#DataFrames.DataFrame-Union{Tuple{ModelList{T, S, V}}, Tuple{V}, Tuple{S}, Tuple{T}} where {T, S<:TimeStepTable, V}'>#</a>&nbsp;<b><u>DataFrames.DataFrame</u></b> &mdash; <i>Method</i>.




```julia
DataFrame(components::ModelList{T,<:TimeStepTable})
```


Implementation of `DataFrame` for a `ModelList` model with several time steps.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dataframe.jl#L66-L70)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.AbstractNodeMapping' href='#PlantSimEngine.AbstractNodeMapping'>#</a>&nbsp;<b><u>PlantSimEngine.AbstractNodeMapping</u></b> &mdash; <i>Type</i>.




```julia
AbstractNodeMapping
```


Abstract type for the type of node mapping, _e.g._ single node mapping or multiple node mapping.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/mapping.jl#L1-L5)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.DataFormat-Tuple{Type{<:AbstractDataFrame}}' href='#PlantSimEngine.DataFormat-Tuple{Type{<:AbstractDataFrame}}'>#</a>&nbsp;<b><u>PlantSimEngine.DataFormat</u></b> &mdash; <i>Method</i>.




```julia
DataFormat(T::Type)
```


Returns the data format of the type `T`. The data format is used to determine how to iterate over the data. The following data formats are supported:
- `TableAlike`: The data is a table-like object, e.g. a `DataFrame` or a `TimeStepTable`. The data is iterated over by rows using the `Tables.jl` interface.
  
- `SingletonAlike`: The data is a singleton-like object, e.g. a `NamedTuple`   or a `TimeStepRow`. The data is iterated over by columns.
  
- `TreeAlike`: The data is a tree-like object, e.g. a `Node`.
  

The default implementation returns `TableAlike` for `AbstractDataFrame`, `TimeStepTable`, `AbstractVector` and `Dict`, `TreeAlike` for `GraphSimulation`,  `SingletonAlike` for `Status`, `ModelList`, `NamedTuple` and `TimeStepRow`.

The default implementation for `Any` throws an error. Users that want to use another input should define this trait for the new data format, e.g.:

```julia
PlantSimEngine.DataFormat(::Type{<:MyType}) = TableAlike()
```


**Examples**

```julia
julia> using PlantSimEngine, PlantMeteo, DataFrames

julia> PlantSimEngine.DataFormat(DataFrame)
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(TimeStepTable([Status(a = 1, b = 2, c = 3)]))
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat([1, 2, 3])
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(Dict(:a => 1, :b => 2))
PlantSimEngine.TableAlike()

julia> PlantSimEngine.DataFormat(Status(a = 1, b = 2, c = 3))
PlantSimEngine.SingletonAlike()
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/table_traits.jl#L6-L49)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.DependencyGraph' href='#PlantSimEngine.DependencyGraph'>#</a>&nbsp;<b><u>PlantSimEngine.DependencyGraph</u></b> &mdash; <i>Type</i>.




```julia
DependencyGraph{T}(roots::T, not_found::Dict{Symbol,DataType})
```


A graph of dependencies between models.

**Arguments**
- `roots::T`: the root nodes of the graph.
  
- `not_found::Dict{Symbol,DataType}`: the models that were not found in the graph.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/dependency_graph.jl#L32-L41)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.DependencyTrait' href='#PlantSimEngine.DependencyTrait'>#</a>&nbsp;<b><u>PlantSimEngine.DependencyTrait</u></b> &mdash; <i>Type</i>.




```julia
DependencyTrait(T::Type)
```


Returns information about the eventual dependence of a model `T` to other time-steps or objects for its computation. The dependence trait is used to determine if a model is parallelizable  or not.

The following dependence traits are supported:
- `TimeStepDependencyTrait`: Trait that defines whether a model can be parallelizable over time-steps for its computation.
  
- `ObjectDependencyTrait`: Trait that defines whether a model can be parallelizable over objects for its computation.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L1-L12)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.GraphSimulation' href='#PlantSimEngine.GraphSimulation'>#</a>&nbsp;<b><u>PlantSimEngine.GraphSimulation</u></b> &mdash; <i>Type</i>.




```julia
GraphSimulation(graph, mapping)
GraphSimulation(graph, statuses, dependency_graph, models, outputs)
```


A type that holds all information for a simulation over a graph.

**Arguments**
- `graph`: an graph, such as an MTG
  
- `mapping`: a dictionary of model mapping
  
- `statuses`: a structure that defines the status of each node in the graph
  
- `status_templates`: a dictionary of status templates
  
- `reverse_multiscale_mapping`: a dictionary of mapping for other scales
  
- `var_need_init`: a dictionary indicating if a variable needs to be initialized
  
- `dependency_graph`: the dependency graph of the models applied to the graph
  
- `models`: a dictionary of models
  
- `outputs`: a dictionary of outputs
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/GraphSimulation.jl#L1-L18)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.MappedVar' href='#PlantSimEngine.MappedVar'>#</a>&nbsp;<b><u>PlantSimEngine.MappedVar</u></b> &mdash; <i>Type</i>.




```julia
MappedVar(source_organ, variable, source_variable, source_default)
```


A variable mapped to another scale.

**Arguments**
- `source_organ`: the organ(s) that are targeted by the mapping
  
- `variable`: the name of the variable that is mapped
  
- `source_variable`: the name of the variable from the source organ (the one that computes the variable)
  
- `source_default`: the default value of the variable
  

**Examples**

```julia
julia> using PlantSimEngine
```


```julia
julia> PlantSimEngine.MappedVar(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
PlantSimEngine.MappedVar{PlantSimEngine.SingleNodeMapping, Symbol, Symbol, Float64}(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/mapping.jl#L41-L63)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.MultiNodeMapping' href='#PlantSimEngine.MultiNodeMapping'>#</a>&nbsp;<b><u>PlantSimEngine.MultiNodeMapping</u></b> &mdash; <i>Type</i>.




```julia
MultiNodeMapping(scale)
```


Type for the multiple node mapping, _e.g._ `[:carbon_assimilation => ["Leaf"],]`. Note that &quot;Leaf&quot; is given as a vector, which means `:carbon_assimilation` will be a vector of values taken from each &quot;Leaf&quot; in the plant graph.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/mapping.jl#L29-L34)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.ObjectDependencyTrait' href='#PlantSimEngine.ObjectDependencyTrait'>#</a>&nbsp;<b><u>PlantSimEngine.ObjectDependencyTrait</u></b> &mdash; <i>Type</i>.




```julia
ObjectDependencyTrait(::Type{T})
```


Defines the trait about the eventual dependence of a model `T` to other objects for its computation. This dependency trait is used to determine if a model is parallelizable over objects or not.

The following dependency traits are supported:
- `IsObjectDependent`: The model depends on other objects for its computation, it cannot be run in parallel.
  
- `IsObjectIndependent`: The model does not depend on other objects for its computation, it can be run in parallel.
  

All models are object dependent by default (_i.e._ `IsObjectDependent`). This is probably not right for the majority of models, but:
1. It is the safest default, as it will not lead to incorrect results if the user forgets to override this trait
  

which is not the case for the opposite (i.e. `IsObjectIndependent`)
1. It is easy to override this trait for models that are object independent
  

**See also**
- [`timestep_parallelizable`](/API#PlantSimEngine.timestep_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
  
- [`object_parallelizable`](/API#PlantSimEngine.object_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
  
- [`parallelizable`](/API#PlantSimEngine.parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable, and `false` otherwise.
  
- [`TimeStepDependencyTrait`](/API#PlantSimEngine.TimeStepDependencyTrait-Tuple{Type}): Defines the trait about the eventual dependence of a model to other time-steps for its computation.
  

**Examples**

Define a dummy process:

```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```


Define a model that is object independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```


Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # false
```


Define a model that is object dependent:

```julia
struct MyModel2 <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel2}) = IsObjectDependent()
```


Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # true
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L135-L199)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.RefVariable' href='#PlantSimEngine.RefVariable'>#</a>&nbsp;<b><u>PlantSimEngine.RefVariable</u></b> &mdash; <i>Type</i>.




```julia
RefVariable(reference_variable)
```


A structure to manually flag a variable in a model to use the value of another variable **at the same scale**. This is used for variable renaming, when a variable is computed by a model but is used by another model with a different name.

Note: we don&#39;t really rename the variable in the status (we need it for the other models), but we create a new one that is a reference to the first one.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/variables_wrappers.jl#L34-L41)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.RefVector' href='#PlantSimEngine.RefVector'>#</a>&nbsp;<b><u>PlantSimEngine.RefVector</u></b> &mdash; <i>Type</i>.




```julia
RefVector(field::Symbol, sts...)
RefVector(field::Symbol, sts::Vector{<:Status})
RefVector(v::Vector{Base.RefValue{T}})
```


A vector of references to a field of a vector of structs. This is used to efficiently pass the values between scales.

**Arguments**
- `field`: the field of the struct to reference
  
- `sts...`: the structs to reference
  
- `sts::Vector{<:Status}`: a vector of structs to reference
  

**Examples**

```julia
julia> using PlantSimEngine
```


Let&#39;s take two Status structs:

```julia
julia> status1 = Status(a = 1.0, b = 2.0, c = 3.0);
```


```julia
julia> status2 = Status(a = 2.0, b = 3.0, c = 4.0);
```


We can make a RefVector of the field `a` of the structs `st1` and `st2`:

```julia
julia> rv = PlantSimEngine.RefVector(:a, status1, status2)
2-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
```


Which is equivalent to:

```julia
julia> rv = PlantSimEngine.RefVector(:a, [status1, status2])
2-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
```


We can access the values of the RefVector:

```julia
julia> rv[1]
1.0
```


Updating the value in the RefVector will update the value in the original struct:

```julia
julia> rv[1] = 10.0
10.0
```


```julia
julia> status1.a
10.0
```


We can also make a RefVector from a vector of references:

```julia
julia> vec = [Ref(1.0), Ref(2.0), Ref(3.0)]
3-element Vector{Base.RefValue{Float64}}:
 Base.RefValue{Float64}(1.0)
 Base.RefValue{Float64}(2.0)
 Base.RefValue{Float64}(3.0)
```


```julia
julia> rv = PlantSimEngine.RefVector(vec)
3-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
 3.0
```


```julia
julia> rv[1]
1.0
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/RefVector.jl#L1-L90)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.SelfNodeMapping' href='#PlantSimEngine.SelfNodeMapping'>#</a>&nbsp;<b><u>PlantSimEngine.SelfNodeMapping</u></b> &mdash; <i>Type</i>.




```julia
SelfNodeMapping()
```


Type for the self node mapping, _i.e._ a node that maps onto itself. This is used to flag variables that will be referenced as a scalar value by other models. It can happen in two conditions:     - the variable is computed by another scale, so we need this variable to exist as an input to this scale (it is not      computed at this scale otherwise)     - the variable is used as input to another scale but as a single value (scalar), so we need to reference it as a scalar.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/mapping.jl#L18-L26)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.SingleNodeMapping' href='#PlantSimEngine.SingleNodeMapping'>#</a>&nbsp;<b><u>PlantSimEngine.SingleNodeMapping</u></b> &mdash; <i>Type</i>.




```julia
SingleNodeMapping(scale)
```


Type for the single node mapping, _e.g._ `[:soil_water_content => "Soil",]`. Note that &quot;Soil&quot; is given as a scalar, which means that `:soil_water_content` will be a scalar value taken from the unique &quot;Soil&quot; node in the plant graph.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/mapping.jl#L8-L13)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.TimeStepDependencyTrait-Tuple{Type}' href='#PlantSimEngine.TimeStepDependencyTrait-Tuple{Type}'>#</a>&nbsp;<b><u>PlantSimEngine.TimeStepDependencyTrait</u></b> &mdash; <i>Method</i>.




```julia
TimeStepDependencyTrait(::Type{T})
```


Defines the trait about the eventual dependence of a model `T` to other time-steps for its computation.  This dependency trait is used to determine if a model is parallelizable over time-steps or not.

The following dependency traits are supported:
- `IsTimeStepDependent`: The model depends on other time-steps for its computation, it cannot be run in parallel.
  
- `IsTimeStepIndependent`: The model does not depend on other time-steps for its computation, it can be run in parallel.
  

All models are time-step dependent by default (_i.e._ `IsTimeStepDependent`). This is probably not right for the  majority of models, but:
1. It is the safest default, as it will not lead to incorrect results if the user forgets to override this trait
  

which is not the case for the opposite (i.e. `IsTimeStepIndependent`)
1. It is easy to override this trait for models that are time-step independent
  

**See also**
- [`timestep_parallelizable`](/API#PlantSimEngine.timestep_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
  
- [`object_parallelizable`](/API#PlantSimEngine.object_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
  
- [`parallelizable`](/API#PlantSimEngine.parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable, and `false` otherwise.
  
- [`ObjectDependencyTrait`](/API#PlantSimEngine.ObjectDependencyTrait): Defines the trait about the eventual dependence of a model to other objects for its computation.
  

**Examples**

Define a dummy process:

```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```


Define a model that is time-step independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()
```


Check if the model is parallelizable over time-steps:

```julia
timestep_parallelizable(MyModel()) # false
```


Define a model that is time-step dependent:

```julia
struct MyModel2 <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel2}) = IsTimeStepDependent()
```


Check if the model is parallelizable over time-steps:

```julia
timestep_parallelizable(MyModel()) # true
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L19-L83)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.UninitializedVar' href='#PlantSimEngine.UninitializedVar'>#</a>&nbsp;<b><u>PlantSimEngine.UninitializedVar</u></b> &mdash; <i>Type</i>.




```julia
UninitializedVar(variable, value)
```


A variable that is not initialized yet, it is given a name and a default value.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/variables_wrappers.jl#L1-L6)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='Base.copy-Tuple{T} where T<:(AbstractArray{<:ModelList})' href='#Base.copy-Tuple{T} where T<:(AbstractArray{<:ModelList})'>#</a>&nbsp;<b><u>Base.copy</u></b> &mdash; <i>Method</i>.




```julia
Base.copy(l::AbstractArray{<:ModelList})
```


Copy an array-alike of [`ModelList`](/model_switching#ModelList)


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L411-L415)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='Base.copy-Tuple{T} where T<:(AbstractDict{N, <:ModelList} where N)' href='#Base.copy-Tuple{T} where T<:(AbstractDict{N, <:ModelList} where N)'>#</a>&nbsp;<b><u>Base.copy</u></b> &mdash; <i>Method</i>.




```julia
Base.copy(l::AbstractDict{N,<:ModelList} where N)
```


Copy a Dict-alike [`ModelList`](/model_switching#ModelList)


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L420-L424)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='Base.copy-Tuple{T} where T<:ModelList' href='#Base.copy-Tuple{T} where T<:ModelList'>#</a>&nbsp;<b><u>Base.copy</u></b> &mdash; <i>Method</i>.




```julia
Base.copy(l::ModelList)
Base.copy(l::ModelList, status)
```


Copy a [`ModelList`](/model_switching#ModelList), eventually with new values for the status.

**Examples**

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

# Create a model list:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

# Copy the model list:
ml2 = copy(models)

# Copy the model list with new status:
ml3 = copy(models, TimeStepTable([Status(var1=20.0, var2=0.5))])
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L366-L394)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='Base.getindex-Union{Tuple{T}, Tuple{T, Any}} where T<:ModelList' href='#Base.getindex-Union{Tuple{T}, Tuple{T, Any}} where T<:ModelList'>#</a>&nbsp;<b><u>Base.getindex</u></b> &mdash; <i>Method</i>.




```julia
getindex(component<:ModelList, key::Symbol)
getindex(component<:ModelList, key)
```


Indexing a component models structure:     - with an integer, will return the status at the ith time-step     - with anything else (Symbol, String) will return the required variable from the status

**Examples**

```julia
using PlantSimEngine

lm = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status = (var1=[15.0, 16.0], var2=0.3)
);

lm[:var1] # Returns the value of the Tₗ variable
lm[2]  # Returns the status at the second time-step
lm[2][:var1] # Returns the value of Tₗ at the second time-step
lm[:var1][2] # Equivalent of the above

# output
16.0
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/get_status.jl#L65-L93)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.add_mapped_variables_with_outputs_as_inputs!-Tuple{Any}' href='#PlantSimEngine.add_mapped_variables_with_outputs_as_inputs!-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.add_mapped_variables_with_outputs_as_inputs!</u></b> &mdash; <i>Method</i>.




```julia
add_mapped_variables_with_outputs_as_inputs!(mapped_vars)
```


Add the variables that are computed at a scale and written to another scale into the mapping.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L133-L137)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.add_model_vars-Tuple{Any, Any, Any}' href='#PlantSimEngine.add_model_vars-Tuple{Any, Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.add_model_vars</u></b> &mdash; <i>Method</i>.




```julia
add_model_vars(x, models, type_promotion; init_fun=init_fun_default)
```


Check which variables in `x` are not initialized considering a set of `models` and the variables needed for their simulation. If some variables are uninitialized, initialize them to their default values.

This function needs to be implemented for each type of `x`. The default method works for  any Tables.jl-compatible `x` and for NamedTuples.

Careful, the function makes a copy of the input `x` if it does not list all needed variables.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L248-L258)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.check_dimensions-Tuple{Any, Any}' href='#PlantSimEngine.check_dimensions-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.check_dimensions</u></b> &mdash; <i>Method</i>.




```julia
check_dimensions(component,weather)
check_dimensions(status,weather)
```


Checks if a component status (or a status directly) and the weather have the same length, or if they can be recycled (length 1 for one of them).

**Examples**

```julia
using PlantSimEngine, PlantMeteo

# Including an example script that implements dummy processes and models:
using PlantSimEngine.Examples

# Creating a dummy weather:
w = Atmosphere(T = 20.0, Rh = 0.5, Wind = 1.0)

# Creating a dummy component:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=[15.0, 16.0], var2=0.3)
)

# Checking that the number of time-steps are compatible (here, they are, it returns nothing):
PlantSimEngine.check_dimensions(models, w) 

# Creating a dummy weather with 3 time-steps:
w = Weather([
    Atmosphere(T = 20.0, Rh = 0.5, Wind = 1.0),
    Atmosphere(T = 25.0, Rh = 0.5, Wind = 1.0),
    Atmosphere(T = 30.0, Rh = 0.5, Wind = 1.0)
])

# Checking that the number of time-steps are compatible (here, they are not, it throws an error):
PlantSimEngine.check_dimensions(models, w)

# output
ERROR: DimensionMismatch: Component status should have the same number of time-steps (2) than weather data (3).
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/checks/dimensions.jl#L1-L42)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.convert_reference_values!-Tuple{Dict{String, Dict{Symbol, Any}}}' href='#PlantSimEngine.convert_reference_values!-Tuple{Dict{String, Dict{Symbol, Any}}}'>#</a>&nbsp;<b><u>PlantSimEngine.convert_reference_values!</u></b> &mdash; <i>Method</i>.




```julia
convert_reference_values!(mapped_vars::Dict{String,Dict{Symbol,Any}})
```


Convert the variables that are `MappedVar{SelfNodeMapping}` or `MappedVar{SingleNodeMapping}` to RefValues that reference a  common value for the variable; and convert `MappedVar{MultiNodeMapping}` to RefVectors that reference the values for the variable in the source organs.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L281-L287)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.convert_vars' href='#PlantSimEngine.convert_vars'>#</a>&nbsp;<b><u>PlantSimEngine.convert_vars</u></b> &mdash; <i>Function</i>.




```julia
convert_vars(ref_vars, type_promotion::Dict{DataType,DataType})
convert_vars(ref_vars, type_promotion::Nothing)
convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Dict{DataType,DataType})
convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Nothing)
```


Convert the status variables to the type specified in the type promotion dictionary. _Note: the mutating version only works with a dictionary of variables._

**Examples**

If we want all the variables that are Reals to be Float32, we can use:

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

ref_vars = init_variables(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
)
type_promotion = Dict(Real => Float32)

PlantSimEngine.convert_vars(type_promotion, ref_vars.process3)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L430-L458)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.convert_vars!' href='#PlantSimEngine.convert_vars!'>#</a>&nbsp;<b><u>PlantSimEngine.convert_vars!</u></b> &mdash; <i>Function</i>.




```julia
convert_vars(ref_vars, type_promotion::Dict{DataType,DataType})
convert_vars(ref_vars, type_promotion::Nothing)
convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Dict{DataType,DataType})
convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Nothing)
```


Convert the status variables to the type specified in the type promotion dictionary. _Note: the mutating version only works with a dictionary of variables._

**Examples**

If we want all the variables that are Reals to be Float32, we can use:

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

ref_vars = init_variables(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
)
type_promotion = Dict(Real => Float32)

PlantSimEngine.convert_vars(type_promotion, ref_vars.process3)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L430-L458)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.convert_vars!-Tuple{Dict{String, Dict{Symbol, Any}}, Any}' href='#PlantSimEngine.convert_vars!-Tuple{Dict{String, Dict{Symbol, Any}}, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.convert_vars!</u></b> &mdash; <i>Method</i>.




```julia
convert_vars!(mapped_vars::Dict{String,Dict{String,Any}}, type_promotion)
```


Converts the types of the variables in a mapping (`mapped_vars`) using the `type_promotion` dictionary.

The mapping should be a dictionary with organ name as keys and a dictionary of variables as values, with variable names as symbols and variable value as value.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L524-L531)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.default_variables_from_mapping' href='#PlantSimEngine.default_variables_from_mapping'>#</a>&nbsp;<b><u>PlantSimEngine.default_variables_from_mapping</u></b> &mdash; <i>Function</i>.




```julia
default_variables_from_mapping(mapped_vars, verbose=true)
```


Get the default values for the mapped variables by recursively searching from the mapping to find the original mapped value.

**Arguments**
- `mapped_vars::Dict{String,Dict{Symbol,Any}}`: the variables mapped to each organ.
  
- `verbose::Bool`: whether to print the stacktrace of the search for the default value in the mapping.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L245-L254)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.diff_vars-Tuple{Any, Any}' href='#PlantSimEngine.diff_vars-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.diff_vars</u></b> &mdash; <i>Method</i>.




```julia
diff_vars(x, y)
```


Returns the names of variables that have different values in x and y.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L271-L275)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.draw_guide-NTuple{5, Any}' href='#PlantSimEngine.draw_guide-NTuple{5, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.draw_guide</u></b> &mdash; <i>Method</i>.




```julia
draw_guide(h, w, prefix, isleaf, guides)
```


Draw the line guide for one node of the dependency graph.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/printing.jl#L117-L121)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.draw_panel-NTuple{5, Any}' href='#PlantSimEngine.draw_panel-NTuple{5, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.draw_panel</u></b> &mdash; <i>Method</i>.




```julia
draw_panel(node, graph, prefix, dep_graph_guides, parent; title="Soft-coupled model")
```


Draw the panels for all dependencies


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/printing.jl#L32-L36)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.drop_process-Tuple{Any, Symbol}' href='#PlantSimEngine.drop_process-Tuple{Any, Symbol}'>#</a>&nbsp;<b><u>PlantSimEngine.drop_process</u></b> &mdash; <i>Method</i>.




```julia
drop_process(proc_vars, process)
```


Return a new `NamedTuple` with the process `process` removed from the `NamedTuple` `proc_vars`.

**Arguments**
- `proc_vars::NamedTuple`: the `NamedTuple` from which we want to remove the process `process`.
  
- `process::Symbol`: the process we want to remove from the `NamedTuple` `proc_vars`.
  

**Returns**

A new `NamedTuple` with the process `process` removed from the `NamedTuple` `proc_vars`.

**Example**

```julia
julia> drop_process((a = 1, b = 2, c = 3), :b)
(a = 1, c = 3)

julia> drop_process((a = 1, b = 2, c = 3), (:a, :c))
(b = 2,)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/soft_dependencies.jl#L268-L291)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.flatten_vars-Tuple{Any}' href='#PlantSimEngine.flatten_vars-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.flatten_vars</u></b> &mdash; <i>Method</i>.




```julia
flatten_vars(vars)
```


Return a set of the variables in the `vars` dictionary.

**Arguments**
- `vars::Dict{Symbol, Tuple{Symbol, Vararg{Symbol}}}`: a dict of process =&gt; namedtuple of variables =&gt; value.
  

**Returns**

A set of the variables in the `vars` dictionary.

**Example**

```julia
julia> flatten_vars(Dict(:process1 => (:var1, :var2), :process2 => (:var3, :var4)))
Set{Symbol} with 4 elements:
  :var4
  :var3
  :var2
  :var1
```


```julia
julia> flatten_vars([:process1 => (var1 = -Inf, var2 = -Inf), :process2 => (var3 = -Inf, var4 = -Inf)])
(var2 = -Inf, var4 = -Inf, var3 = -Inf, var1 = -Inf)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/soft_dependencies.jl#L459-L487)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_mapping-Tuple{Any}' href='#PlantSimEngine.get_mapping-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.get_mapping</u></b> &mdash; <i>Method</i>.




```julia
get_mapping(m)
```


Get the mapping of a dictionary of model mapping.

**Arguments**
- `m::Dict{String,Any}`: a dictionary of model mapping
  

Returns a vector of pairs of symbols and strings or vectors of strings

**Examples**

See [`get_models`](/API#PlantSimEngine.get_models-Tuple{Any}) for examples.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/getters.jl#L92-L106)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_models-Tuple{Any}' href='#PlantSimEngine.get_models-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.get_models</u></b> &mdash; <i>Method</i>.




```julia
get_models(m)
```


Get the models of a dictionary of model mapping.

**Arguments**
- `m::Dict{String,Any}`: a dictionary of model mapping
  

Returns a vector of models

**Examples**

```julia
julia> using PlantSimEngine;
```


Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```julia
julia> using PlantSimEngine.Examples;
```


If we just give a MultiScaleModel, we get its model as a one-element vector:

```julia
julia> models = MultiScaleModel( model=ToyCAllocationModel(), mapping=[ :carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :carbon_allocation => ["Leaf", "Internode"] ], );
```


```julia
julia> PlantSimEngine.get_models(models)
1-element Vector{ToyCAllocationModel}:
 ToyCAllocationModel()
```


If we give a tuple of models, we get each model in a vector:

```julia
julia> models2 = (  MultiScaleModel( model=ToyAssimModel(), mapping=[:soil_water_content => "Soil",], ), ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), Status(aPPFD=1300.0, TT=10.0), );
```


Notice that we provide &quot;Soil&quot;, not [&quot;Soil&quot;] in the mapping because a single value is expected for the mapping here.

```julia
julia> PlantSimEngine.get_models(models2)
2-element Vector{AbstractModel}:
 ToyAssimModel{Float64}(0.2)
 ToyCDemandModel{Float64}(10.0, 200.0)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/getters.jl#L1-L50)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_multiscale_default_value' href='#PlantSimEngine.get_multiscale_default_value'>#</a>&nbsp;<b><u>PlantSimEngine.get_multiscale_default_value</u></b> &mdash; <i>Function</i>.




```julia
get_multiscale_default_value(mapped_vars, val, mapping_stacktrace=[])
```


Get the default value of a variable from a mapping.

**Arguments**
- `mapped_vars::Dict{String,Dict{Symbol,Any}}`: the variables mapped to each organ.
  
- `val::Any`: the variable to get the default value of.
  
- `mapping_stacktrace::Vector{Any}`: the stacktrace of the search for the value in ascendind the mapping.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L198-L208)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_nsteps-Tuple{Any}' href='#PlantSimEngine.get_nsteps-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.get_nsteps</u></b> &mdash; <i>Method</i>.




```julia
get_nsteps(t)
```


Get the number of steps in the object.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/checks/dimensions.jl#L86-L90)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_status-Tuple{Any}' href='#PlantSimEngine.get_status-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.get_status</u></b> &mdash; <i>Method</i>.




```julia
get_status(m)
```


Get the status of a dictionary of model mapping.

**Arguments**
- `m::Dict{String,Any}`: a dictionary of model mapping
  

Returns a [`Status`](/API#PlantSimEngine.Status) or `nothing`.

**Examples**

See [`get_models`](/API#PlantSimEngine.get_models-Tuple{Any}) for examples.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/getters.jl#L70-L84)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.get_vars_not_propagated-Tuple{Any}' href='#PlantSimEngine.get_vars_not_propagated-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.get_vars_not_propagated</u></b> &mdash; <i>Method</i>.




```julia
get_vars_not_propagated(status)
```


Returns all variables that are given for several time-steps in the status.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L357-L361)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.hard_dependencies-Tuple{Any}' href='#PlantSimEngine.hard_dependencies-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.hard_dependencies</u></b> &mdash; <i>Method</i>.




```julia
hard_dependencies(models; verbose::Bool=true)
hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true)
```


Compute the hard dependencies between models.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/hard_dependencies.jl#L1-L6)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.homogeneous_ts_kwargs-Tuple{Any, Any}' href='#PlantSimEngine.homogeneous_ts_kwargs-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.homogeneous_ts_kwargs</u></b> &mdash; <i>Method</i>.




```julia
homogeneous_ts_kwargs(kwargs)
```


By default, the function returns its argument.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L310-L314)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.homogeneous_ts_kwargs-Union{Tuple{T}, Tuple{N}, Tuple{NamedTuple{N, T}, Any}} where {N, T}' href='#PlantSimEngine.homogeneous_ts_kwargs-Union{Tuple{T}, Tuple{N}, Tuple{NamedTuple{N, T}, Any}} where {N, T}'>#</a>&nbsp;<b><u>PlantSimEngine.homogeneous_ts_kwargs</u></b> &mdash; <i>Method</i>.




```julia
kwargs_to_timestep(kwargs::NamedTuple{N,T}) where {N,T}
```


Takes a NamedTuple with optionnaly vector of values for each variable, and makes a  vector of NamedTuple, with each being a time step. It is used to be able to _e.g._ give constant values for all time-steps for one variable.

**Examples**

```julia
PlantSimEngine.homogeneous_ts_kwargs((Tₗ=[25.0, 26.0], aPPFD=1000.0))
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/ModelList.jl#L317-L329)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_node_status!' href='#PlantSimEngine.init_node_status!'>#</a>&nbsp;<b><u>PlantSimEngine.init_node_status!</u></b> &mdash; <i>Function</i>.




```julia
init_node_status!(
    node, 
    statuses, 
    mapped_vars, 
    reverse_multiscale_mapping,
    vars_need_init=Dict{String,Any}(),
    type_promotion=nothing;
    check=true
)
```


Initialise the status of a plant graph node, taking into account the multiscale mapping, and add it to the statuses dictionary.

**Arguments**
- `node`: the node to initialise
  
- `statuses`: the dictionary of statuses by node type
  
- `mapped_vars`: the template of status for each node type
  
- `reverse_multiscale_mapping`: the variables that are mapped to other scales
  
- `var_need_init`: the variables that are not initialised or computed by other models
  
- `nodes_with_models`: the nodes that have a model defined for their symbol
  
- `type_promotion`: the type promotion to use for the variables
  
- `check`: whether to check the mapping for errors (see details)
  

**Details**

Most arguments can be computed from the graph and the mapping:
- `statuses` is given by the first initialisation: `statuses = Dict(i => Status[] for i in nodes_with_models)`
  
- `mapped_vars` is computed using `mapped_variables()`, see code in `init_statuses`
  
- `vars_need_init` is computed using `vars_need_init = Dict(org =&gt; filter(x -&gt; isa(last(x), UninitializedVar), vars) |&gt; keys for (org, vars) in mapped_vars) |&gt;
  

filter(x -&gt; length(last(x)) &gt; 0)`

The `check` argument is a boolean indicating if variables initialisation should be checked. In the case that some variables need initialisation (partially initialized mapping), we check if the value can be found  in the node attributes (using the variable name). If `true`, the function returns an error if the attribute is missing, otherwise it uses the default value from the model.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/initialisation.jl#L56-L91)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_simulation-Tuple{Any, Any}' href='#PlantSimEngine.init_simulation-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.init_simulation</u></b> &mdash; <i>Method</i>.




```julia
init_simulation(mtg, mapping; nsteps=1, outputs=nothing, type_promotion=nothing, check=true, verbose=true)
```


Initialise the simulation. Returns:
- the mtg
  
- a status for each node by organ type, considering multi-scale variables
  
- the dependency graph of the models
  
- the models parsed as a Dict of organ type =&gt; NamedTuple of process =&gt; model mapping
  
- the pre-allocated outputs
  

**Arguments**
- `mtg`: the MTG
  
- `mapping::Dict{String,Any}`: a dictionary of model mapping
  
- `nsteps`: the number of steps of the simulation
  
- `outputs`: the dynamic outputs needed for the simulation
  
- `type_promotion`: the type promotion to use for the variables
  
- `check`: whether to check the mapping for errors. Passed to `init_node_status!`.
  
- `verbose`: print information about errors in the mapping
  

**Details**

The function first computes a template of status for each organ type that has a model in the mapping. This template is used to initialise the status of each node of the MTG, taking into account the user-defined  initialisation, and the (multiscale) mapping. The mapping is used to make references to the variables that are defined at another scale, so that the values are automatically updated when the variable is changed at the other scale. Two types of multiscale variables are available: `RefVector` and `MappedVar`. The first one is used when the variable is mapped to a vector of nodes, and the second one when it is mapped to a single node. This  is given by the user through the mapping, using a string for a single node (_e.g._ `=> "Leaf"`), and a vector of strings for a vector of nodes (_e.g._ `=> ["Leaf"]` for one type of node or `=> ["Leaf", "Internode"]` for several). 

The function also computes the dependency graph of the models, i.e. the order in which the models should be called, considering the dependencies between them. The dependency graph is used to call the models in the right order when the simulation is run.

Note that if a variable is not computed by models or initialised from the mapping, it is searched in the MTG attributes.  The value is not a reference to the one in the attribute of the MTG, but a copy of it. This is because we can&#39;t reference  a value in a Dict. If you need a reference, you can use a `Ref` for your variable in the MTG directly, and it will be  automatically passed as is.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/initialisation.jl#L259-L299)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_statuses' href='#PlantSimEngine.init_statuses'>#</a>&nbsp;<b><u>PlantSimEngine.init_statuses</u></b> &mdash; <i>Function</i>.




```julia
init_statuses(mtg, mapping, dependency_graph=dep(mapping); type_promotion=nothing, verbose=true, check=true)
```


Get the status of each node in the MTG by node type, pre-initialised considering multi-scale variables.

**Arguments**
- `mtg`: the plant graph
  
- `mapping`: a dictionary of model mapping
  
- `dependency_graph::DependencyGraph`: the first-order dependency graph where each model in the mapping is assigned a node. 
  

However, models that are identified as hard-dependencies are not given individual nodes. Instead, they are nested as child  nodes under other models.
- `type_promotion`: the type promotion to use for the variables
  
- `verbose`: print information when compiling the mapping
  
- `check`: whether to check the mapping for errors. Passed to `init_node_status!`.
  

**Return**

A NamedTuple of status by node type, a dictionary of status templates by node type, a dictionary of variables mapped to other scales, a dictionary of variables that need to be initialised or computed by other models, and a vector of nodes that have a model defined for their symbol:

`(;statuses, status_templates, reverse_multiscale_mapping, vars_need_init, nodes_with_models)`


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/initialisation.jl#L1-L23)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.init_variables_manual-Tuple{Any, Any}' href='#PlantSimEngine.init_variables_manual-Tuple{Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.init_variables_manual</u></b> &mdash; <i>Method</i>.




```julia
init_variables_manual(models...;vars...)
```


Return an initialisation of the model variables with given values.

**Examples**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model()
)

PlantSimEngine.init_variables_manual(status(models), (var1=20.0,))
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L358-L379)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.is_graph_cyclic-Tuple{PlantSimEngine.DependencyGraph}' href='#PlantSimEngine.is_graph_cyclic-Tuple{PlantSimEngine.DependencyGraph}'>#</a>&nbsp;<b><u>PlantSimEngine.is_graph_cyclic</u></b> &mdash; <i>Method</i>.




```julia
is_graph_cyclic(dependency_graph::DependencyGraph; full_stack=false, verbose=true)
```


Check if the dependency graph is cyclic.

**Arguments**
- `dependency_graph::DependencyGraph`: the dependency graph to check.
  
- `full_stack::Bool=false`: if `true`, return the full stack of nodes that makes the cycle, otherwise return only the cycle.
  
- `warn::Bool=true`: if `true`, print a stylised warning message when a cycle is detected.
  

Return a boolean indicating if the graph is cyclic, and the stack of nodes as a vector.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/is_graph_cyclic.jl#L1-L13)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.mapped_variables' href='#PlantSimEngine.mapped_variables'>#</a>&nbsp;<b><u>PlantSimEngine.mapped_variables</u></b> &mdash; <i>Function</i>.




```julia
mapped_variables(mapping, dependency_graph=hard_dependencies(mapping; verbose=false); verbose=false)
```


Get the variables for each organ type from a dependency graph, with `MappedVar`s for the multiscale mapping.

**Arguments**
- `mapping::Dict{String,T}`: the mapping between models and scales.
  
- `dependency_graph::DependencyGraph`: the first-order dependency graph where each model in the mapping is assigned a node. 
  

However, models that are identified as hard-dependencies are not given individual nodes. Instead, they are nested as child  nodes under other models.
- `verbose::Bool`: whether to print the stacktrace of the search for the default value in the mapping.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L1-L13)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.mapped_variables_no_outputs_from_other_scale' href='#PlantSimEngine.mapped_variables_no_outputs_from_other_scale'>#</a>&nbsp;<b><u>PlantSimEngine.mapped_variables_no_outputs_from_other_scale</u></b> &mdash; <i>Function</i>.




```julia
mapped_variables_no_outputs_from_other_scale(mapping, dependency_graph=hard_dependencies(mapping; verbose=false))
```


Get the variables for each organ type from a dependency graph, without the variables that are outputs from another scale.

**Arguments**
- `mapping::Dict{String,T}`: the mapping between models and scales.
  
- `dependency_graph::DependencyGraph`: the first-order dependency graph where each model in the mapping is assigned a node. 
  

However, models that are identified as hard-dependencies are not given individual nodes. Instead, they are nested as child  nodes under other models.

**Details**

This function returns a dictionary with the (multiscale-) inputs and outputs variables for each organ type. 

Note that this function does not include the variables that are outputs from another scale and not computed by this scale, see `mapped_variables_with_outputs_as_inputs` for that.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L38-L56)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.model_-Tuple{AbstractModel}' href='#PlantSimEngine.model_-Tuple{AbstractModel}'>#</a>&nbsp;<b><u>PlantSimEngine.model_</u></b> &mdash; <i>Method</i>.




```julia
model_(m::AbstractModel)
```


Get the model of an AbstractModel (it is the model itself if it is not a MultiScaleModel).


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/Abstract_model_structs.jl#L19-L23)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.object_parallelizable-Tuple{T} where T' href='#PlantSimEngine.object_parallelizable-Tuple{T} where T'>#</a>&nbsp;<b><u>PlantSimEngine.object_parallelizable</u></b> &mdash; <i>Method</i>.




```julia
object_parallelizable(x::T)
object_parallelizable(x::DependencyGraph)
```


Returns `true` if the model `x` is parallelizable, i.e. if the model can be computed in parallel for different objects, or `false` otherwise. 

The default implementation returns `false` for all models. If you develop a model that is parallelizable over objects, you should add a method to [`ObjectDependencyTrait`](/API#PlantSimEngine.ObjectDependencyTrait) for your model.

Note that this method can also be applied on a [`DependencyGraph`](/API#PlantSimEngine.DependencyGraph) directly, in which case it returns `true` if all models in the graph are parallelizable, and `false` otherwise.

**See also**
- [`timestep_parallelizable`](/API#PlantSimEngine.timestep_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
  
- [`parallelizable`](/API#PlantSimEngine.parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable, and `false` otherwise.
  
- [`ObjectDependencyTrait`](/API#PlantSimEngine.ObjectDependencyTrait): Defines the trait about the eventual dependence of a model to other objects for its computation.
  

**Examples**

Define a dummy process:

```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```


Define a model that is object independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```


Check if the model is parallelizable over objects:

```julia
object_parallelizable(MyModel()) # true
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L205-L249)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.parallelizable-Tuple{T} where T' href='#PlantSimEngine.parallelizable-Tuple{T} where T'>#</a>&nbsp;<b><u>PlantSimEngine.parallelizable</u></b> &mdash; <i>Method</i>.




```julia
parallelizable(::T)
object_parallelizable(x::DependencyGraph)
```


Returns `true` if the model `T` or the whole dependency graph is parallelizable, _i.e._ if the model can be computed in parallel for different time-steps or objects. The default implementation returns `false` for all models.

**See also**
- [`timestep_parallelizable`](/API#PlantSimEngine.timestep_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
  
- [`object_parallelizable`](/API#PlantSimEngine.object_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over objects, and `false` otherwise.
  
- [`TimeStepDependencyTrait`](/API#PlantSimEngine.TimeStepDependencyTrait-Tuple{Type}): Defines the trait about the eventual dependence of a model to other time-steps for its computation.
  

**Examples**

Define a dummy process:

```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```


Define a model that is parallelizable:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()

# Override the object dependency trait:
PlantSimEngine.ObjectDependencyTrait(::Type{MyModel}) = IsObjectIndependent()
```


Check if the model is parallelizable:

```julia
parallelizable(MyModel()) # true
```


Or if we want to be more explicit:

```julia
timestep_parallelizable(MyModel())
object_parallelizable(MyModel())
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L254-L301)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.pre_allocate_outputs-Tuple{Any, Any, Any}' href='#PlantSimEngine.pre_allocate_outputs-Tuple{Any, Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.pre_allocate_outputs</u></b> &mdash; <i>Method</i>.




```julia
pre_allocate_outputs(statuses, outs, nsteps; check=true)
```


Pre-allocate the outputs of needed variable for each node type in vectors of vectors. The first level vectors have length nsteps, and the second level vectors have length n_nodes of this type.

Note that we pre-allocate the vectors for the time-steps, but not for each organ, because we don&#39;t  know how many nodes will be in each organ in the future (organs can appear or disapear).

**Arguments**
- `statuses`: a dictionary of status by node type
  
- `outs`: a dictionary of outputs by node type
  
- `nsteps`: the number of time-steps
  
- `check`: whether to check the mapping for errors. Default (`true`) returns an error if some variables do not exist.
  

If false and some variables are missing, return an info, remove the unknown variables and continue.

**Returns**
- A dictionary of pre-allocated output of vector of time-step and vector of node of that type.
  

**Examples**

```julia
julia> using PlantSimEngine, MultiScaleTreeGraph, PlantSimEngine.Examples
```


Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```julia
julia> using PlantSimEngine.Examples;
```


Define the models mapping:

```julia
julia> mapping = Dict( "Plant" =>  ( MultiScaleModel(  model=ToyCAllocationModel(), mapping=[ :carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :carbon_allocation => ["Leaf", "Internode"] ], ), 
        MultiScaleModel(  model=ToyPlantRmModel(), mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],] ), ),"Internode" => ( ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004), Status(TT=10.0, carbon_biomass=1.0) ), "Leaf" => ( MultiScaleModel( model=ToyAssimModel(), mapping=[:soil_water_content => "Soil",], ), ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025), Status(aPPFD=1300.0, TT=10.0, carbon_biomass=1.0), ), "Soil" => ( ToySoilWaterModel(), ), );
```


Importing an example MTG provided by the package:

```julia
julia> mtg = import_mtg_example();
```


```julia
julia> statuses, = PlantSimEngine.init_statuses(mtg, mapping);
```


```julia
julia> outs = Dict("Leaf" => (:carbon_assimilation, :carbon_demand), "Soil" => (:soil_water_content,));
```


Pre-allocate the outputs as a dictionary:

```julia
julia> preallocated_vars = PlantSimEngine.pre_allocate_outputs(statuses, outs, 2);
```


The dictionary has a key for each organ from which we want outputs:

```julia
julia> collect(keys(preallocated_vars))
2-element Vector{String}:
 "Soil"
 "Leaf"
```


Each organ has a dictionary of variables for which we want outputs from,  with the pre-allocated empty vectors (one per time-step that will be filled with one value per node):

```julia
julia> collect(keys(preallocated_vars["Leaf"]))
3-element Vector{Symbol}:
 :carbon_assimilation
 :node
 :carbon_demand
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/save_results.jl#L1-L80)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.propagate_values!-Tuple{Any, Any, Any}' href='#PlantSimEngine.propagate_values!-Tuple{Any, Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.propagate_values!</u></b> &mdash; <i>Method</i>.




```julia
propagate_values!(status1::Dict, status2::Dict, vars_not_propagated::Set)
```


Propagates the values of all variables in `status1` to `status2`, except for vars in `vars_not_propagated`.

**Arguments**
- `status1::Dict`: A dictionary containing the current values of variables.
  
- `status2::Dict`: A dictionary to which the values of variables will be propagated.
  
- `vars_not_propagated::Set`: A set of variables whose values should not be propagated.
  

**Examples**

```julia
julia> status1 = Status(var1 = 15.0, var2 = 0.3);
```


```julia
julia> status2 = Status(var1 = 16.0, var2 = -Inf);
```


```julia
julia> vars_not_propagated = (:var1,);

```


jldoctest st1 julia&gt; PlantSimEngine.propagate_values!(status1, status2, vars_not_propagated);

```

```


jldoctest st1 julia&gt; status2.var2 == status1.var2 true

```

```


jldoctest st1 julia&gt; status2.var1 == status1.var1 false ```


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/component_models/Status.jl#L130-L167)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.ref_var-Tuple{Any}' href='#PlantSimEngine.ref_var-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.ref_var</u></b> &mdash; <i>Method</i>.




```julia
ref_var(v)
```


Create a reference to a variable. If the variable is already a `Base.RefValue`, it is returned as is, else it is returned as a Ref to the copy of the value, or a Ref to the `RefVector` (in case `v` is a `RefVector`).

**Examples**

```julia
julia> using PlantSimEngine;
```


```julia
julia> PlantSimEngine.ref_var(1.0)
Base.RefValue{Float64}(1.0)
```


```julia
julia> PlantSimEngine.ref_var([1.0])
Base.RefValue{Vector{Float64}}([1.0])
```


```julia
julia> PlantSimEngine.ref_var(Base.RefValue(1.0))
Base.RefValue{Float64}(1.0)
```


```julia
julia> PlantSimEngine.ref_var(Base.RefValue([1.0]))
Base.RefValue{Vector{Float64}}([1.0])
```


```julia
julia> PlantSimEngine.ref_var(PlantSimEngine.RefVector([Ref(1.0), Ref(2.0), Ref(3.0)]))
Base.RefValue{PlantSimEngine.RefVector{Float64}}(RefVector{Float64}[1.0, 2.0, 3.0])
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/initialisation.jl#L215-L252)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.reverse_mapping-Union{Tuple{Dict{String, T}}, Tuple{T}} where T' href='#PlantSimEngine.reverse_mapping-Union{Tuple{Dict{String, T}}, Tuple{T}} where T'>#</a>&nbsp;<b><u>PlantSimEngine.reverse_mapping</u></b> &mdash; <i>Method</i>.




```julia
reverse_mapping(mapping::Dict{String,Tuple{Any,Vararg{Any}}}; all=true)
reverse_mapping(mapped_vars::Dict{String,Dict{Symbol,Any}})
```


Get the reverse mapping of a dictionary of model mapping, _i.e._ the variables that are mapped to other scales, or in other words, what variables are given to other scales from a given scale. This is used for _e.g._ knowing which scales are needed to add values to others.

**Arguments**
- `mapping::Dict{String,Any}`: A dictionary of model mapping.
  
- `all::Bool`: Whether to get all the variables that are mapped to other scales, including the ones that are mapped as single values.
  

**Returns**

A dictionary of organs (keys) with a dictionary of organs =&gt; vector of pair of variables. You can read the output as: &quot;for each organ (source organ), to which other organ (target organ) it is giving values for its own variables. Then for each of these source organs, which variable it is giving to the target organ (first symbol in the pair), and to which variable it is mapping the value into the target organ (second symbol in the pair)&quot;.

**Examples**

```julia
julia> using PlantSimEngine
```


Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```julia
julia> using PlantSimEngine.Examples;
```


```julia
julia> mapping = Dict( "Plant" => MultiScaleModel( model=ToyCAllocationModel(), mapping=[ :carbon_assimilation => ["Leaf"], :carbon_demand => ["Leaf", "Internode"], :carbon_allocation => ["Leaf", "Internode"] ], ), "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), "Leaf" => ( MultiScaleModel( model=ToyAssimModel(), mapping=[:soil_water_content => "Soil",], ), ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), Status(aPPFD=1300.0, TT=10.0), ), "Soil" => ( ToySoilWaterModel(), ), );
```


Notice we provide &quot;Soil&quot;, not [&quot;Soil&quot;] in the mapping of the `ToyAssimModel` for the `Leaf`. This is because we expect a single value for the `soil_water_content` to be mapped here (there is only one soil). This allows  to get the value as a singleton instead of a vector of values.

```julia
julia> PlantSimEngine.reverse_mapping(mapping)
Dict{String, Dict{String, Dict{Symbol, Any}}} with 3 entries:
  "Soil"      => Dict("Leaf"=>Dict(:soil_water_content=>:soil_water_content))
  "Internode" => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
  "Leaf"      => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/reverse_mapping.jl#L1-L47)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.save_results!-Tuple{PlantSimEngine.GraphSimulation, Any}' href='#PlantSimEngine.save_results!-Tuple{PlantSimEngine.GraphSimulation, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.save_results!</u></b> &mdash; <i>Method</i>.




```julia
save_results!(object::GraphSimulation, i)
```


Save the results of the simulation for time-step `i` into the  object. For a `GraphSimulation` object, this will save the results from the `status(object)` in the `outputs(object)`.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/save_results.jl#L185-L191)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.search_inputs_in_multiscale_output-NTuple{5, Any}' href='#PlantSimEngine.search_inputs_in_multiscale_output-NTuple{5, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.search_inputs_in_multiscale_output</u></b> &mdash; <i>Method</i>.




```julia
search_inputs_in_multiscale_output(process, organ, inputs, soft_dep_graphs)
```


**Arguments**
- `process::Symbol`: the process for which we want to find the soft dependencies at other scales.
  
- `organ::String`: the organ for which we want to find the soft dependencies.
  
- `inputs::Dict{Symbol, Vector{Pair{Symbol}, Tuple{Symbol, Vararg{Symbol}}}}`: a dict of process =&gt; [:subprocess =&gt; (:var1, :var2)].
  
- `soft_dep_graphs::Dict{String, ...}`: a dict of organ =&gt; (soft_dep_graph, inputs, outputs).
  
- `rev_mapping::Dict{Symbol, Symbol}`: a dict of mapped variable =&gt; source variable (this is the reverse mapping).
  

**Details**

The inputs (and similarly, outputs) give the inputs of each process, classified by the process it comes from. It can come from itself (its own inputs), or from another process that is a hard-dependency.

**Returns**

A dictionary with the soft dependencies variables found in outputs of other scales for each process, e.g.:

```julia
Dict{String, Dict{Symbol, Vector{Symbol}}} with 2 entries:
    "Internode" => Dict(:carbon_demand=>[:carbon_demand])
    "Leaf"      => Dict(:carbon_assimilation=>[:carbon_assimilation], :carbon_demand=>[:carbon_demand])
```


This means that the variable `:carbon_demand` is computed by the process `:carbon_demand` at the scale &quot;Internode&quot;, and the variable `:carbon_assimilation`  is computed by the process `:carbon_assimilation` at the scale &quot;Leaf&quot;. Those variables are used as inputs for the process that we just passed.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/soft_dependencies.jl#L374-L402)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.search_inputs_in_output-Tuple{Any, Any, Any}' href='#PlantSimEngine.search_inputs_in_output-Tuple{Any, Any, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.search_inputs_in_output</u></b> &mdash; <i>Method</i>.




```julia
search_inputs_in_output(process, inputs, outputs)
```


Return a dictionary with the soft dependencies of the processes in the dependency graph `d`. A soft dependency is a dependency that is not explicitely defined in the model, but that can be inferred from the inputs and outputs of the processes.

**Arguments**
- `process::Symbol`: the process for which we want to find the soft dependencies.
  
- `inputs::Dict{Symbol, Vector{Pair{Symbol}, Tuple{Symbol, Vararg{Symbol}}}}`: a dict of process =&gt; symbols of inputs per process.
  
- `outputs::Dict{Symbol, Tuple{Symbol, Vararg{Symbol}}}`: a dict of process =&gt; symbols of outputs per process.
  

**Details**

The inputs (and similarly, outputs) give the inputs of each process, classified by the process it comes from. It can  come from itself (its own inputs), or from another process that is a hard-dependency.

**Returns**

A dictionary with the soft dependencies for the processes.

**Example**

```julia
in_ = Dict(
    :process3 => [:process3=>(:var4, :var5), :process2=>(:var1, :var3), :process1=>(:var1, :var2)],
    :process4 => [:process4=>(:var0,)],
    :process6 => [:process6=>(:var7, :var9)],
    :process5 => [:process5=>(:var5, :var6)],
)

out_ = Dict(
    :process3 => Pair{Symbol}[:process3=>(:var4, :var6), :process2=>(:var4, :var5), :process1=>(:var3,)],
    :process4 => [:process4=>(:var1, :var2)],
    :process6 => [:process6=>(:var8,)],
    :process5 => [:process5=>(:var7,)],
)

search_inputs_in_output(:process3, in_, out_)
(process4 = (:var1, :var2),)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/soft_dependencies.jl#L295-L337)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.soft_dependencies' href='#PlantSimEngine.soft_dependencies'>#</a>&nbsp;<b><u>PlantSimEngine.soft_dependencies</u></b> &mdash; <i>Function</i>.




```julia
soft_dependencies(d::DependencyGraph)
```


Return a [`DependencyGraph`](/API#PlantSimEngine.DependencyGraph) with the soft dependencies of the processes in the dependency graph `d`. A soft dependency is a dependency that is not explicitely defined in the model, but that can be inferred from the inputs and outputs of the processes.

**Arguments**
- `d::DependencyGraph`: the hard-dependency graph.
  

**Example**

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

# Create a model list:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
)

# Create the hard-dependency graph:
hard_dep = hard_dependencies(models.models, verbose=true)

# Get the soft dependencies graph:
soft_dep = soft_dependencies(hard_dep)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/soft_dependencies.jl#L1-L36)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.status_from_template-Tuple{Dict{Symbol}}' href='#PlantSimEngine.status_from_template-Tuple{Dict{Symbol}}'>#</a>&nbsp;<b><u>PlantSimEngine.status_from_template</u></b> &mdash; <i>Method</i>.




```julia
status_from_template(d::Dict{Symbol,Any})
```


Create a status from a template dictionary of variables and values. If the values  are already RefValues or RefVectors, they are used as is, else they are converted to Refs.

**Arguments**
- `d::Dict{Symbol,Any}`: A dictionary of variables and values.
  

**Returns**
- A [`Status`](/API#PlantSimEngine.Status).
  

**Examples**

```julia
julia> using PlantSimEngine
```


```julia
julia> a, b = PlantSimEngine.status_from_template(Dict(:a => 1.0, :b => 2.0));
```


```julia
julia> a
1.0
```


```julia
julia> b
2.0
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/initialisation.jl#L164-L197)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.timestep_parallelizable-Tuple{T} where T' href='#PlantSimEngine.timestep_parallelizable-Tuple{T} where T'>#</a>&nbsp;<b><u>PlantSimEngine.timestep_parallelizable</u></b> &mdash; <i>Method</i>.




```julia
timestep_parallelizable(x::T)
timestep_parallelizable(x::DependencyGraph)
```


Returns `true` if the model `x` is parallelizable, i.e. if the model can be computed in parallel over time-steps, or `false` otherwise.

The default implementation returns `false` for all models. If you develop a model that is parallelizable over time-steps, you should add a method to [`ObjectDependencyTrait`](/API#PlantSimEngine.ObjectDependencyTrait) for your model.

Note that this method can also be applied on a [`DependencyGraph`](/API#PlantSimEngine.DependencyGraph) directly, in which case it returns `true` if all models in the graph are parallelizable, and `false` otherwise.

**See also**
- [`object_parallelizable`](/API#PlantSimEngine.object_parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable over time-steps, and `false` otherwise.
  
- [`parallelizable`](/API#PlantSimEngine.parallelizable-Tuple{T}%20where%20T): Returns `true` if the model is parallelizable, and `false` otherwise.
  
- [`TimeStepDependencyTrait`](/API#PlantSimEngine.TimeStepDependencyTrait-Tuple{Type}): Defines the trait about the eventual dependence of a model to other time-steps for its computation.
  

**Examples**

Define a dummy process:

```julia
using PlantSimEngine

# Define a test process:
@process "TestProcess"
```


Define a model that is time-step independent:

```julia
struct MyModel <: AbstractTestprocessModel end

# Override the time-step dependency trait:
PlantSimEngine.TimeStepDependencyTrait(::Type{MyModel}) = IsTimeStepIndependent()
```


Check if the model is parallelizable over objects:

```julia
timestep_parallelizable(MyModel()) # true
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/traits/parallel_traits.jl#L86-L130)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.transform_single_node_mapped_variables_as_self_node_output!-Tuple{Any}' href='#PlantSimEngine.transform_single_node_mapped_variables_as_self_node_output!-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.transform_single_node_mapped_variables_as_self_node_output!</u></b> &mdash; <i>Method</i>.




```julia
transform_single_node_mapped_variables_as_self_node_output!(mapped_vars)
```


Find variables that are inputs to other scales as a `SingleNodeMapping` and declare them as MappedVar from themselves in the source scale. This helps us declare it as a reference when we create the template status objects.

These node are found in the mapping as `[:variable_name => "Plant"]` (notice that &quot;Plant&quot; is a scalar value).


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L154-L161)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.HardDependencyNode, Function, Vector}' href='#PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.HardDependencyNode, Function, Vector}'>#</a>&nbsp;<b><u>PlantSimEngine.traverse_dependency_graph!</u></b> &mdash; <i>Method</i>.




```julia
traverse_dependency_graph(node::HardDependencyNode, f::Function, var::Vector)
```


Apply function `f` to `node`, and then its children (hard-dependency nodes).

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/traversal.jl#L113-L119)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.SoftDependencyNode, Function, Vector}' href='#PlantSimEngine.traverse_dependency_graph!-Tuple{PlantSimEngine.SoftDependencyNode, Function, Vector}'>#</a>&nbsp;<b><u>PlantSimEngine.traverse_dependency_graph!</u></b> &mdash; <i>Method</i>.




```julia
traverse_dependency_graph(node::SoftDependencyNode, f::Function, var::Vector; visit_hard_dep=true)
```


Apply function `f` to `node`, visit its hard dependency nodes (if `visit_hard_dep=true`), and  then its soft dependency children.

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/traversal.jl#L84-L91)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.traverse_dependency_graph-Tuple{PlantSimEngine.DependencyGraph, Function}' href='#PlantSimEngine.traverse_dependency_graph-Tuple{PlantSimEngine.DependencyGraph, Function}'>#</a>&nbsp;<b><u>PlantSimEngine.traverse_dependency_graph</u></b> &mdash; <i>Method</i>.




```julia
traverse_dependency_graph(graph::DependencyGraph, f::Function; visit_hard_dep=true)
```


Traverse the dependency `graph` and apply the function `f` to each node. The first-level soft-dependencies are traversed first, then their hard-dependencies (if `visit_hard_dep=true`), and then the children of the soft-dependencies.

Return a vector of pairs of the node and the result of the function `f`.

**Example**

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

function f(node)
    node.value
end

vars = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

graph = dep(vars)
traverse_dependency_graph(graph, f)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/traversal.jl#L1-L35)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables_multiscale' href='#PlantSimEngine.variables_multiscale'>#</a>&nbsp;<b><u>PlantSimEngine.variables_multiscale</u></b> &mdash; <i>Function</i>.




```julia
variables_multiscale(node, organ, mapping, st=NamedTuple())
```


Get the variables of a HardDependencyNode, taking into account the multiscale mapping, _i.e._ defining variables as `MappedVar` if they are mapped to another scale. The default values are  taken from the model if not given by the user (`st`), and are marked as `UninitializedVar` if  they are inputs of the node.

Return a NamedTuple with the variables and their default values.

**Arguments**
- `node::HardDependencyNode`: the node to get the variables from.
  
- `organ::String`: the organ type, _e.g._ &quot;Leaf&quot;.
  
- `vars_mapping::Dict{String,T}`: the mapping of the models (see details below).
  
- `st::NamedTuple`: an optional named tuple with default values for the variables.
  

**Details**

The `vars_mapping` is a dictionary with the organ type as key and a dictionary as value. It is  computed from the user mapping like so:

```julia
full_vars_mapping = Dict(first(mod) => Dict(get_mapping(last(mod))) for mod in mapping)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/dependencies/dependency_graph.jl#L80-L105)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables_outputs_from_other_scale-Tuple{Any}' href='#PlantSimEngine.variables_outputs_from_other_scale-Tuple{Any}'>#</a>&nbsp;<b><u>PlantSimEngine.variables_outputs_from_other_scale</u></b> &mdash; <i>Method</i>.




```julia
variables_outputs_from_other_scale(mapped_vars)
```


For each organ in the `mapped_vars`, find the variables that are outputs from another scale and not computed at this scale otherwise. This function is used with mapped_variables


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/mtg/mapping/compute_mapping.jl#L65-L70)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.variables_typed-Tuple{T} where T<:AbstractModel' href='#PlantSimEngine.variables_typed-Tuple{T} where T<:AbstractModel'>#</a>&nbsp;<b><u>PlantSimEngine.variables_typed</u></b> &mdash; <i>Method</i>.




```julia
variables_typed(model)
variables_typed(model, models...)
```


Returns a named tuple with the name and the types of the variables needed by a model, or a union of those for several models.

**Examples**

```julia
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

PlantSimEngine.variables_typed(Process1Model(1.0))
(var1 = Float64, var2 = Float64, var3 = Float64)

PlantSimEngine.variables_typed(Process1Model(1.0), Process2Model())

# output
(var4 = Float64, var5 = Float64, var1 = Float64, var2 = Float64, var3 = Float64)
```


**See also**

[`inputs`](/API#PlantSimEngine.inputs-Tuple{T}%20where%20T<:AbstractModel), [`outputs`](/API#PlantSimEngine.outputs-Tuple{PlantSimEngine.GraphSimulation,%20Any}) and [`variables`](/API#PlantSimEngine.variables-Tuple{Module})


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/models_inputs_outputs.jl#L200-L228)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.vars_not_init_-Union{Tuple{T}, Tuple{T, Any}} where T<:Status' href='#PlantSimEngine.vars_not_init_-Union{Tuple{T}, Tuple{T, Any}} where T<:Status'>#</a>&nbsp;<b><u>PlantSimEngine.vars_not_init_</u></b> &mdash; <i>Method</i>.




```julia
vars_not_init_(st<:Status, var_names)
```


Get which variable is not properly initialized in the status struct.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/model_initialisation.jl#L326-L330)

</div>
<br>

## Example models {#Example-models}

PlantSimEngine provides example processes and models to users. They are available from a sub-module called `Examples`. To get access to these models, you can simply use this sub-module:

```julia
using PlantSimEngine.Examples
```


The models are detailed below.
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples' href='#PlantSimEngine.Examples'>#</a>&nbsp;<b><u>PlantSimEngine.Examples</u></b> &mdash; <i>Module</i>.




A sub-module with example models.

Examples used in the documentation for a set of multiscale models. The models can be found in the `examples` folder of the package, and are stored  in the following files:
- `ToyAssimModel.jl`
  
- `ToyCDemandModel.jl`
  
- `ToyCAllocationModel.jl`
  
- `ToySoilModel.jl`
  

**Examples**

```jl
using PlantSimEngine
using PlantSimEngine.Examples
ToyAssimModel()
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/examples_import.jl#L1-L20)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractCarbon_AllocationModel' href='#PlantSimEngine.Examples.AbstractCarbon_AllocationModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractCarbon_AllocationModel</u></b> &mdash; <i>Type</i>.




`carbon_allocation` process abstract model. 

All models implemented to simulate the `carbon_allocation` process must be a subtype of this type, _e.g._  `struct MyCarbon_AllocationModel <: AbstractCarbon_AllocationModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractCarbon_AllocationModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractCarbon_AssimilationModel' href='#PlantSimEngine.Examples.AbstractCarbon_AssimilationModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractCarbon_AssimilationModel</u></b> &mdash; <i>Type</i>.




`carbon_assimilation` process abstract model. 

All models implemented to simulate the `carbon_assimilation` process must be a subtype of this type, _e.g._  `struct MyCarbon_AssimilationModel <: AbstractCarbon_AssimilationModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractCarbon_AssimilationModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractCarbon_BiomassModel' href='#PlantSimEngine.Examples.AbstractCarbon_BiomassModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractCarbon_BiomassModel</u></b> &mdash; <i>Type</i>.




`carbon_biomass` process abstract model. 

All models implemented to simulate the `carbon_biomass` process must be a subtype of this type, _e.g._  `struct MyCarbon_BiomassModel <: AbstractCarbon_BiomassModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractCarbon_BiomassModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractCarbon_DemandModel' href='#PlantSimEngine.Examples.AbstractCarbon_DemandModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractCarbon_DemandModel</u></b> &mdash; <i>Type</i>.




`carbon_demand` process abstract model. 

All models implemented to simulate the `carbon_demand` process must be a subtype of this type, _e.g._  `struct MyCarbon_DemandModel <: AbstractCarbon_DemandModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractCarbon_DemandModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractDegreedaysModel' href='#PlantSimEngine.Examples.AbstractDegreedaysModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractDegreedaysModel</u></b> &mdash; <i>Type</i>.




`Degreedays` process abstract model. 

All models implemented to simulate the `Degreedays` process must be a subtype of this type, _e.g._  `struct MyDegreedaysModel <: AbstractDegreedaysModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractDegreedaysModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractGrowthModel' href='#PlantSimEngine.Examples.AbstractGrowthModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractGrowthModel</u></b> &mdash; <i>Type</i>.




`growth` process abstract model. 

All models implemented to simulate the `growth` process must be a subtype of this type, _e.g._  `struct MyGrowthModel <: AbstractGrowthModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractGrowthModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractLai_DynamicModel' href='#PlantSimEngine.Examples.AbstractLai_DynamicModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractLai_DynamicModel</u></b> &mdash; <i>Type</i>.




`LAI_Dynamic` process abstract model. 

All models implemented to simulate the `LAI_Dynamic` process must be a subtype of this type, _e.g._  `struct MyLai_DynamicModel <: AbstractLai_DynamicModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractLai_DynamicModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractLeaf_SurfaceModel' href='#PlantSimEngine.Examples.AbstractLeaf_SurfaceModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractLeaf_SurfaceModel</u></b> &mdash; <i>Type</i>.




`leaf_surface` process abstract model. 

All models implemented to simulate the `leaf_surface` process must be a subtype of this type, _e.g._  `struct MyLeaf_SurfaceModel <: AbstractLeaf_SurfaceModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractLeaf_SurfaceModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractLight_InterceptionModel' href='#PlantSimEngine.Examples.AbstractLight_InterceptionModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractLight_InterceptionModel</u></b> &mdash; <i>Type</i>.




`light_interception` process abstract model. 

All models implemented to simulate the `light_interception` process must be a subtype of this type, _e.g._  `struct MyLight_InterceptionModel <: AbstractLight_InterceptionModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractLight_InterceptionModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractLight_PartitioningModel' href='#PlantSimEngine.Examples.AbstractLight_PartitioningModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractLight_PartitioningModel</u></b> &mdash; <i>Type</i>.




`light_partitioning` process abstract model. 

All models implemented to simulate the `light_partitioning` process must be a subtype of this type, _e.g._  `struct MyLight_PartitioningModel <: AbstractLight_PartitioningModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractLight_PartitioningModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractMaintenance_RespirationModel' href='#PlantSimEngine.Examples.AbstractMaintenance_RespirationModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractMaintenance_RespirationModel</u></b> &mdash; <i>Type</i>.




`maintenance_respiration` process abstract model. 

All models implemented to simulate the `maintenance_respiration` process must be a subtype of this type, _e.g._  `struct MyMaintenance_RespirationModel <: AbstractMaintenance_RespirationModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractMaintenance_RespirationModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractOrgan_EmergenceModel' href='#PlantSimEngine.Examples.AbstractOrgan_EmergenceModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractOrgan_EmergenceModel</u></b> &mdash; <i>Type</i>.




`organ_emergence` process abstract model. 

All models implemented to simulate the `organ_emergence` process must be a subtype of this type, _e.g._  `struct MyOrgan_EmergenceModel <: AbstractOrgan_EmergenceModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractOrgan_EmergenceModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess1Model' href='#PlantSimEngine.Examples.AbstractProcess1Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess1Model</u></b> &mdash; <i>Type</i>.




`process1` process abstract model. 

All models implemented to simulate the `process1` process must be a subtype of this type, _e.g._  `struct MyProcess1Model <: AbstractProcess1Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess1Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess2Model' href='#PlantSimEngine.Examples.AbstractProcess2Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess2Model</u></b> &mdash; <i>Type</i>.




`process2` process abstract model. 

All models implemented to simulate the `process2` process must be a subtype of this type, _e.g._  `struct MyProcess2Model <: AbstractProcess2Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess2Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess3Model' href='#PlantSimEngine.Examples.AbstractProcess3Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess3Model</u></b> &mdash; <i>Type</i>.




`process3` process abstract model. 

All models implemented to simulate the `process3` process must be a subtype of this type, _e.g._  `struct MyProcess3Model <: AbstractProcess3Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess3Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess4Model' href='#PlantSimEngine.Examples.AbstractProcess4Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess4Model</u></b> &mdash; <i>Type</i>.




`process4` process abstract model. 

All models implemented to simulate the `process4` process must be a subtype of this type, _e.g._  `struct MyProcess4Model <: AbstractProcess4Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess4Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess5Model' href='#PlantSimEngine.Examples.AbstractProcess5Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess5Model</u></b> &mdash; <i>Type</i>.




`process5` process abstract model. 

All models implemented to simulate the `process5` process must be a subtype of this type, _e.g._  `struct MyProcess5Model <: AbstractProcess5Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess5Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess6Model' href='#PlantSimEngine.Examples.AbstractProcess6Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess6Model</u></b> &mdash; <i>Type</i>.




`process6` process abstract model. 

All models implemented to simulate the `process6` process must be a subtype of this type, _e.g._  `struct MyProcess6Model <: AbstractProcess6Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess6Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractProcess7Model' href='#PlantSimEngine.Examples.AbstractProcess7Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractProcess7Model</u></b> &mdash; <i>Type</i>.




`process7` process abstract model. 

All models implemented to simulate the `process7` process must be a subtype of this type, _e.g._  `struct MyProcess7Model <: AbstractProcess7Model end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractProcess7Model)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.AbstractSoil_WaterModel' href='#PlantSimEngine.Examples.AbstractSoil_WaterModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.AbstractSoil_WaterModel</u></b> &mdash; <i>Type</i>.




`soil_water` process abstract model. 

All models implemented to simulate the `soil_water` process must be a subtype of this type, _e.g._  `struct MySoil_WaterModel <: AbstractSoil_WaterModel end`.

You can list all models implementing this process using `subtypes`:

**Examples**

```julia
subtypes(AbstractSoil_WaterModel)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/processes/process_generation.jl#L69-L82)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Beer' href='#PlantSimEngine.Examples.Beer'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Beer</u></b> &mdash; <i>Type</i>.




```julia
Beer(k)
```


Beer-Lambert law for light interception.

Required inputs: `LAI` in m² m⁻². Required meteorology data: `Ri_PAR_f`, the incident flux of atmospheric radiation in the PAR, in W m[soil]⁻² (== J m[soil]⁻² s⁻¹).

Output: aPPFD, the absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[leaf]⁻² s⁻¹.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/Beer.jl#L9-L19)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process1Model' href='#PlantSimEngine.Examples.Process1Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process1Model</u></b> &mdash; <i>Type</i>.




```julia
Process1Model(a)
```


A dummy model implementing a &quot;process1&quot; process for testing purposes.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L8-L12)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process2Model' href='#PlantSimEngine.Examples.Process2Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process2Model</u></b> &mdash; <i>Type</i>.




```julia
Process2Model()
```


A dummy model implementing a &quot;process2&quot; process for testing purposes.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L29-L33)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process3Model' href='#PlantSimEngine.Examples.Process3Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process3Model</u></b> &mdash; <i>Type</i>.




```julia
Process3Model()
```


A dummy model implementing a &quot;process3&quot; process for testing purposes.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L53-L57)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process4Model' href='#PlantSimEngine.Examples.Process4Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process4Model</u></b> &mdash; <i>Type</i>.




```julia
Process4Model()
```


A dummy model implementing a &quot;process4&quot; process for testing purposes. It computes the inputs needed for the coupled processes 1-2-3.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L79-L84)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process5Model' href='#PlantSimEngine.Examples.Process5Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process5Model</u></b> &mdash; <i>Type</i>.




```julia
Process5Model()
```


A dummy model implementing a &quot;process5&quot; process for testing purposes. It needs the outputs from the coupled processes 1-2-3.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L102-L107)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process6Model' href='#PlantSimEngine.Examples.Process6Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process6Model</u></b> &mdash; <i>Type</i>.




```julia
Process6Model()
```


A dummy model implementing a &quot;process6&quot; process for testing purposes. It needs the outputs from the coupled processes 1-2-3, but also from process 7 that is itself independant.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L123-L129)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.Process7Model' href='#PlantSimEngine.Examples.Process7Model'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.Process7Model</u></b> &mdash; <i>Type</i>.




```julia
Process7Model()
```


A dummy model implementing a &quot;process7&quot; process for testing purposes. It is independent (needs :var0 only as for Process4Model), but its outputs are used by Process6Model, so it is a soft-coupling.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/dummy.jl#L145-L151)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyAssimGrowthModel' href='#PlantSimEngine.Examples.ToyAssimGrowthModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyAssimGrowthModel</u></b> &mdash; <i>Type</i>.




```julia
ToyAssimGrowthModel(Rm_factor, Rg_cost)
ToyAssimGrowthModel(; LUE=0.2, Rm_factor = 0.5, Rg_cost = 1.2)
```


Computes the biomass growth of a plant.

**Arguments**
- `LUE=0.2`: the light use efficiency, in gC mol[PAR]⁻¹
  
- `Rm_factor=0.5`: the fraction of assimilation that goes into maintenance respiration
  
- `Rg_cost=1.2`: the cost of growth maintenance, in gram of carbon biomass per gram of assimilate
  

**Inputs**
- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² time-step⁻¹
  

**Outputs**
- `carbon_assimilation`: the assimilation, in gC m⁻² time-step⁻¹
  
- `Rm`: the maintenance respiration, in gC m⁻² time-step⁻¹
  
- `Rg`: the growth respiration, in gC m⁻² time-step⁻¹
  
- `biomass_increment`: the daily biomass increment, in gC m⁻² time-step⁻¹
  
- `biomass`: the plant biomass, in gC m⁻² time-step⁻¹
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyAssimGrowthModel.jl#L5-L28)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyAssimModel' href='#PlantSimEngine.Examples.ToyAssimModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyAssimModel</u></b> &mdash; <i>Type</i>.




```julia
ToyAssimModel(LUE)
```


Computes the assimilation of a plant (= photosynthesis).

**Arguments**
- `LUE=0.2`: the light use efficiency, in gC mol[PAR]⁻¹
  

**Inputs**
- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² time-step⁻¹
  
- `soil_water_content`: the soil water content, in %
  

**Outputs**
- `carbon_assimilation`: the assimilation or photosynthesis, also sometimes denoted `A`, in gC m⁻² time-step⁻¹
  

**Details**

The assimilation is computed as the product of the absorbed photosynthetic photon flux density (aPPFD) and the light use efficiency (LUE), so the units of the assimilation usually are in gC m⁻² time-step⁻¹, but they could be in another spatial or temporal unit depending on the unit of `aPPFD`, _e.g._  if `aPPFD` is in mol[PAR] plant⁻¹ time-step⁻¹, the assimilation will be in gC plant⁻¹ time-step⁻¹.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyAssimModel.jl#L7-L30)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyCAllocationModel' href='#PlantSimEngine.Examples.ToyCAllocationModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyCAllocationModel</u></b> &mdash; <i>Type</i>.




```julia
ToyCAllocationModel()
```


Computes the carbon allocation to each organ of a plant based on the plant total carbon offer and individual organ demand. This model should be used at the plant scale, because it first computes the carbon availaible for allocation as the minimum between the total demand  (sum of organs&#39; demand) and total carbon offer (sum of organs&#39; assimilation - total maintenance respiration), and then allocates the carbon relative  to each organ&#39;s demand.

**Inputs**
- `carbon_assimilation`: a vector of the assimilation of all photosynthetic organs, usually in gC m⁻² time-step⁻¹
  
- `Rm`: the maintenance respiration of the plant, usually in gC m⁻² time-step⁻¹
  
- `carbon_demand`: a vector of the carbon demand of the organs, usually in gC m⁻² time-step⁻¹
  

**Outputs**
- `carbon_assimilation`: the carbon assimilation, usually in gC m⁻² time-step⁻¹
  

**Details**

The units usually are in gC m⁻² time-step⁻¹, but they could be in another spatial or temporal unit depending on the unit of the inputs, _e.g._ in gC plant⁻¹ time-step⁻¹.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyCAllocationModel.jl#L7-L29)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyCBiomassModel' href='#PlantSimEngine.Examples.ToyCBiomassModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyCBiomassModel</u></b> &mdash; <i>Type</i>.




```julia
ToyCBiomassModel(construction_cost)
```


Computes the carbon biomass of an organ based on the carbon allocation and construction cost.

**Arguments**
- `construction_cost`: the construction cost of the organ, usually in gC gC⁻¹. Should be understood as the amount of carbon needed to build 1g of carbon biomass.
  

**Inputs**
- `carbon_allocation`: the carbon allocation to the organ for the time-step, usually in gC m⁻² time-step⁻¹
  

**Outputs**
- `carbon_biomass_increment`: the increment of carbon biomass, usually in gC time-step⁻¹
  
- `carbon_biomass`: the carbon biomass, usually in gC
  
- `growth_respiration`: the growth respiration, usually in gC time-step⁻¹
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyCBiomassModel.jl#L5-L24)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyCDemandModel' href='#PlantSimEngine.Examples.ToyCDemandModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyCDemandModel</u></b> &mdash; <i>Type</i>.




```julia
ToyCDemandModel(optimal_biomass, development_duration)
ToyCDemandModel(; optimal_biomass, development_duration)
```


Computes the carbon demand of an organ depending on its biomass under optimal conditions and the duration of its development in degree days. The model assumes that the carbon demand is linear througout the duration of the development.

**Arguments**
- `optimal_biomass`: the biomass of the organ under optimal conditions, in gC
  
- `development_duration`: the duration of the development of the organ, in degree days
  

**Inputs**
- `TT`: the thermal time, in degree days
  

**Outputs**
- `carbon_demand`: the carbon demand, in gC
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyCDemandModel.jl#L7-L26)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyDegreeDaysCumulModel' href='#PlantSimEngine.Examples.ToyDegreeDaysCumulModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyDegreeDaysCumulModel</u></b> &mdash; <i>Type</i>.




```julia
ToyDegreeDaysCumulModel(;init_TT=0.0, T_base=10.0, T_max=43.0)
```


Computes the thermal time in degree days and cumulated degree-days based on the average daily temperature (`T`), the initial cumulated degree days, the base temperature below which there is no growth, and the maximum  temperature for growh.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyDegreeDays.jl#L7-L13)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyInternodeEmergence' href='#PlantSimEngine.Examples.ToyInternodeEmergence'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyInternodeEmergence</u></b> &mdash; <i>Type</i>.




```julia
ToyInternodeEmergence(;init_TT=0.0, TT_emergence = 300)
```


Computes the organ emergence based on cumulated thermal time since last event.


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyInternodeEmergence.jl#L7-L11)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyLAIModel' href='#PlantSimEngine.Examples.ToyLAIModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyLAIModel</u></b> &mdash; <i>Type</i>.




```julia
ToyLAIModel(;max_lai=8.0, dd_incslope=800, inc_slope=110, dd_decslope=1500, dec_slope=20)
```


Computes the Leaf Area Index (LAI) based on a sigmoid function of thermal time.

**Arguments**
- `max_lai`: the maximum LAI value
  
- `dd_incslope`: the thermal time at which the LAI starts to increase
  
- `inc_slope`: the slope of the increase
  
- `dd_decslope`: the thermal time at which the LAI starts to decrease
  
- `dec_slope`: the slope of the decrease
  

**Inputs**
- `TT_cu`: the cumulated thermal time since the beginning of the simulation, usually in °C days
  

**Outputs**
- `LAI`: the Leaf Area Index, usually in m² m⁻²
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyLAIModel.jl#L8-L28)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyLAIfromLeafAreaModel' href='#PlantSimEngine.Examples.ToyLAIfromLeafAreaModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyLAIfromLeafAreaModel</u></b> &mdash; <i>Type</i>.




```julia
ToyLAIfromLeafAreaModel()
```


Computes the Leaf Area Index (LAI) of the scene based on the plants leaf area.

**Arguments**
- `scene_area`: the area of the scene, usually in m²
  

**Inputs**
- `surface`: a vector of plant leaf surfaces, usually in m²
  

**Outputs**
- `LAI`: the Leaf Area Index of the scene, usually in m² m⁻²
  
- `total_surface`: the total surface of the plants, usually in m²
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyLAIModel.jl#L66-L83)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyLeafSurfaceModel' href='#PlantSimEngine.Examples.ToyLeafSurfaceModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyLeafSurfaceModel</u></b> &mdash; <i>Type</i>.




```julia
ToyLeafSurfaceModel(SLA)
```


Computes the individual leaf surface from its biomass using the SLA.

**Arguments**
- `SLA`: the specific leaf area, usually in **m² gC⁻¹**. Should be understood as the surface area of a leaf per unit of carbon biomass.
  

Values typically range from 0.002 to 0.027 m² gC⁻¹.

**Inputs**
- `carbon_biomass`: the carbon biomass of the leaf, usually in gC
  

**Outputs**
- `surface`: the leaf surface, usually in m²
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyLeafSurfaceModel.jl#L5-L23)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyLightPartitioningModel' href='#PlantSimEngine.Examples.ToyLightPartitioningModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyLightPartitioningModel</u></b> &mdash; <i>Type</i>.




```julia
ToyLightPartitioningModel()
```


Computes the light partitioning based on relative surface.

**Inputs**
- `aPPFD`: the absorbed photosynthetic photon flux density at the larger scale (_e.g._ scene), in mol[PAR] m⁻² time-step⁻¹ 
  

**Outputs**
- `aPPFD`: the assimilation or photosynthesis, also sometimes denoted `A`, in gC time-step⁻¹
  

**Details**


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyLightPartitioningModel.jl#L7-L23)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyMaintenanceRespirationModel' href='#PlantSimEngine.Examples.ToyMaintenanceRespirationModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyMaintenanceRespirationModel</u></b> &mdash; <i>Type</i>.




```julia
RmQ10FixedN(Q10, Rm_base, T_ref, P_alive, nitrogen_content)
```


Maintenance respiration based on a Q10 computation with fixed nitrogen values  and proportion of living cells in the organs.

**Arguments**
- `Q10`: Q10 factor (values should usually range between: 1.5 - 2.5, with 2.1 being the most common value)
  
- `Rm_base`: Base maintenance respiration (gC gDM⁻¹ time-step⁻¹). Should be around 0.06.
  
- `T_ref`: Reference temperature at which Q10 was measured (usually around 25.0°C)
  
- `P_alive`: proportion of living cells in the organ
  
- `nitrogen_content`: nitrogen content of the organ (gN gC⁻¹)
  

**Inputs**
- `carbon_biomass`: the carbon biomass of the organ in gC
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyMaintenanceRespirationModel.jl#L4-L24)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyPlantLeafSurfaceModel' href='#PlantSimEngine.Examples.ToyPlantLeafSurfaceModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyPlantLeafSurfaceModel</u></b> &mdash; <i>Type</i>.




```julia
ToyPlantLeafSurfaceModel()
```


Computes the leaf surface at plant scale by summing the individual leaf surfaces.

**Inputs**
- `leaf_surfaces`: a vector of leaf surfaces, usually in m²
  

**Outputs**
- `surface`: the leaf surface at plant scale, usually in m²
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyLeafSurfaceModel.jl#L49-L62)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyPlantRmModel' href='#PlantSimEngine.Examples.ToyPlantRmModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyPlantRmModel</u></b> &mdash; <i>Type</i>.




```julia
ToyPlantRmModel()
```


Total plant maintenance respiration based on the sum of `Rm_organs`, the maintenance respiration of the organs.

**Intputs**
- `Rm_organs`: a vector of maintenance respiration from all organs in the plant in gC time-step⁻¹
  

**Outputs**
- `Rm`: the total plant maintenance respiration in gC time-step⁻¹
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyMaintenanceRespirationModel.jl#L42-L54)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToyRUEGrowthModel' href='#PlantSimEngine.Examples.ToyRUEGrowthModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToyRUEGrowthModel</u></b> &mdash; <i>Type</i>.




```julia
ToyRUEGrowthModel(efficiency)
```


Computes the carbon biomass increment of a plant based on the radiation use efficiency principle.

**Arguments**
- `efficiency`: the radiation use efficiency, in gC[biomass] mol[PAR]⁻¹
  

**Inputs**
- `aPPFD`: the absorbed photosynthetic photon flux density, in mol[PAR] m⁻² time-step⁻¹
  

**Outputs**
- `biomass_increment`: the daily biomass increment, in gC[biomass] m⁻² time-step⁻¹
  
- `biomass`: the plant biomass, in gC[biomass] m⁻² time-step⁻¹
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToyRUEGrowthModel.jl#L7-L24)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.ToySoilWaterModel' href='#PlantSimEngine.Examples.ToySoilWaterModel'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.ToySoilWaterModel</u></b> &mdash; <i>Type</i>.




```julia
ToySoilWaterModel(values=[0.5])
```


A toy model to compute the soil water content. The model simply take a random value in the `values` range using `rand`.

**Outputs**
- `soil_water_content`: the soil water content (%).
  

**Arguments**
- `values`: a range of `soil_water_content` values to sample from. Can be a vector of values `[0.5,0.6]` or a range `0.1:0.1:1.0`. Default is `[0.5]`.
  


[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/ToySoilModel.jl#L5-L18)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.Examples.import_mtg_example-Tuple{}' href='#PlantSimEngine.Examples.import_mtg_example-Tuple{}'>#</a>&nbsp;<b><u>PlantSimEngine.Examples.import_mtg_example</u></b> &mdash; <i>Method</i>.




```julia
import_mtg_example()
```


Returns an example multiscale tree graph (MTG) with a scene, a soil, and a plant with two internodes and two leaves.

**Examples**

```julia
julia> using PlantSimEngine.Examples
```


```julia
julia> import_mtg_example()
/ 1: Scene
├─ / 2: Soil
└─ + 3: Plant
   └─ / 4: Internode
      ├─ + 5: Leaf
      └─ < 6: Internode
         └─ + 7: Leaf
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/src/examples_import.jl#L42-L63)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.fit-Tuple{Type{PlantSimEngine.Examples.Beer}, Any}' href='#PlantSimEngine.fit-Tuple{Type{PlantSimEngine.Examples.Beer}, Any}'>#</a>&nbsp;<b><u>PlantSimEngine.fit</u></b> &mdash; <i>Method</i>.




```julia
fit(::Type{Beer}, df; J_to_umol=PlantMeteo.Constants().J_to_umol)
```


Compute the `k` parameter of the Beer-Lambert law from measurements.

**Arguments**
- `::Type{Beer}`: the model type
  
- `df`: a `DataFrame` with the following columns:
  - `aPPFD`: the measured absorbed Photosynthetic Photon Flux Density in μmol[PAR] m[leaf]⁻² s⁻¹
    
  - `LAI`: the measured leaf area index in m² m⁻²
    
  - `Ri_PAR_f`: the measured incident flux of atmospheric radiation in the PAR, in W m[soil]⁻² (== J m[soil]⁻² s⁻¹)
    
  

**Examples**

Import the example models defined in the `Examples` sub-module:

```julia
using PlantSimEngine
using PlantSimEngine.Examples
```


Create a model list with a Beer model, and fit it to the data:

```julia
m = ModelList(Beer(0.6), status=(LAI=2.0,))
meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0)
run!(m, meteo)
df = DataFrame(aPPFD=m[:aPPFD][1], LAI=m.status.LAI[1], Ri_PAR_f=meteo.Ri_PAR_f[1])
fit(Beer, df)
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/Beer.jl#L73-L104)

</div>
<br>
<div style='border-width:1px; border-style:solid; border-color:black; padding: 1em; border-radius: 25px;'>
<a id='PlantSimEngine.run!-2' href='#PlantSimEngine.run!-2'>#</a>&nbsp;<b><u>PlantSimEngine.run!</u></b> &mdash; <i>Function</i>.




```julia
run!(::Beer, object, meteo, constants=Constants(), extra=nothing)
```


Computes the photosynthetic photon flux density (`aPPFD`, µmol m⁻² s⁻¹) absorbed by an  object using the incoming PAR radiation flux (`Ri_PAR_f`, W m⁻²) and the Beer-Lambert law of light extinction.

**Arguments**
- `::Beer`: a Beer model, from the model list (_i.e._ m.light_interception)
  
- `models`: A `ModelList` struct holding the parameters for the model with
  

initialisations for `LAI` (m² m⁻²): the leaf area index.
- `status`: the status of the model, usually the model list status (_i.e._ m.status)
  
- `meteo`: meteorology structure, see [`Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/#PlantMeteo.Atmosphere)
  
- `constants = PlantMeteo.Constants()`: physical constants. See `PlantMeteo.Constants` for more details
  
- `extra = nothing`: extra arguments, not used here.
  

**Examples**

```julia
m = ModelList(Beer(0.5), status=(LAI=2.0,))

meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_q=300.0)

run!(m, meteo)

m[:aPPFD]
```



[source](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/9577dfef9fbe8b2464f27fa9ccd569bfba2224b2/examples/Beer.jl#L28-L56)

</div>
<br>
