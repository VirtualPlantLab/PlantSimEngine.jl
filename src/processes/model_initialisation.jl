"""
    to_initialize(; verbose=true, vars...)
    to_initialize(m::T)  where T <: ModelList
    to_initialize(m::DependencyGraph)
    to_initialize(mapping::Dict{String,T}, graph=nothing)

Return the variables that must be initialized providing a set of models and processes. The
function takes into account model coupling and only returns the variables that are needed
considering that some variables that are outputs of some models are used as inputs of others.

# Arguments

- `verbose`: if `true`, print information messages.
- `vars...`: the models and processes to consider.
- `m::T`: a [`ModelList`](@ref).
- `m::DependencyGraph`: a [`DependencyGraph`](@ref).
- `mapping::Dict{String,T}`: a mapping that associates models to organs.
- `graph`: a graph representing a plant or a scene, *e.g.* a multiscale tree graph. The graph
  is used to check if variables that are not initialized can be found in the graph nodes attributes.

# Examples

```@example
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

```@example
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
"""
function to_initialize(m::ModelList; verbose::Bool=true)
    needed_variables = to_initialize(dep(m; verbose=verbose))
    to_init = Dict{Symbol,Tuple}()
    for (process, vars) in needed_variables
        # default_values = needed_variables[:process1]
        # st = m.status
        not_init = vars_not_init_(m.status, vars)
        length(not_init) > 0 && push!(to_init, process => not_init)
    end
    return NamedTuple(to_init)
end

function to_initialize(m::DependencyGraph)
    dependencies = traverse_dependency_graph(m, to_initialize)

    outputs_all = Set{Symbol}()
    for (key, value) in dependencies
        outputs_all = union(outputs_all, keys(value.outputs))
    end

    needed_variables_process = Dict{Symbol,NamedTuple}()
    for (key, value) in dependencies
        for (key_in, val_in) in pairs(value.inputs)
            if key_in ∉ outputs_all
                if haskey(needed_variables_process, key)
                    needed_variables_process[key] = merge(needed_variables_process[key], NamedTuple{(key_in,)}(val_in))
                else
                    push!(needed_variables_process, key => NamedTuple{(key_in,)}(val_in))
                end
            end
        end
    end
    # note: needed_variables_process is e.g.:
    # Dict{Symbol, NamedTuple} with 2 entries:
    #     :process1 => (var1 = -Inf, var2 = -Inf)
    #     :process2 => (var1 = -Inf,)
    return needed_variables_process
end

"""
    to_initialize(m::AbstractDependencyNode)

Return the variables that must be initialized providing a set of models and processes. The
function just returns the inputs and outputs of each model, with their default values.
To take into account model coupling, use the function at an upper-level instead, *i.e.* 
`to_initialize(m::ModelList)` or `to_initialize(m::DependencyGraph)`.
"""
function to_initialize(m::AbstractDependencyNode)
    return (inputs=inputs_(m.value), outputs=outputs_(m.value))
end

function to_initialize(m::T) where {T<:Dict{String,ModelList}}
    toinit = Dict{String,NamedTuple}()
    for (key, value) in m
        # key = "Leaf"; value = m[key]
        toinit_ = to_initialize(value)

        if length(toinit_) > 0
            push!(toinit, key => toinit_)
        end
    end

    return toinit
end


function to_initialize(; verbose=true, vars...)
    needed_variables = to_initialize(dep(; verbose=verbose, (; vars...)...))
    to_init = Dict{Symbol,Tuple}()
    for (process, vars) in pairs(needed_variables)
        not_init = keys(vars)
        length(not_init) > 0 && push!(to_init, process => not_init)
    end
    return NamedTuple(to_init)
end

# For the list of mapping given to an MTG:
function to_initialize(mapping::Dict{String,T}, graph=nothing) where {T}
    # Get the variables in the MTG:
    if isnothing(graph)
        vars_in_mtg = Symbol[]
    else
        vars_in_mtg = names(graph)
    end

    # Get the reverse mapping between scales:
    rev_mapping = reverse_mapping(mapping; all=true)

    var_need_init = Dict{String,NamedTuple{(:need_initialisation, :need_models_from_scales, :need_var_from_mtg),Tuple{Vector{Symbol},Vector{NamedTuple{(:var, :scale, :need_scales),Tuple{Symbol,String,Union{String,Vector{String}}}}},Vector{VarFromMTG}}}}()
    for organ in keys(mapping)
        # organ = "Plant"
        # Get all mapping for the organ:
        mods = get_models(mapping[organ])
        map_vars = get_mapping(mapping[organ])
        user_st = get_status(mapping[organ]) # User status

        if isnothing(user_st)
            user_st = NamedTuple()
        else
            user_st = NamedTuple(user_st)
        end

        multiscale_vars = collect(first(i) for i in map_vars)
        ins = merge(inputs_.(mods)...)
        outs = merge(outputs_.(mods)...)

        # Variables in the node that are defined as multiscale:
        multi_scale_ins = intersect(keys(ins), multiscale_vars) # inputs: variables that are taken from another scale

        # Variables we need to initialise for this scale:
        vars_needed_this_scale = setdiff(keys(ins), keys(outs))
        # And that are not provided by the user:
        setdiff!(vars_needed_this_scale, keys(user_st))

        need_initialisation = Symbol[]
        need_var_from_mtg = VarFromMTG[]
        need_models_from_scales = NamedTuple{(:var, :scale, :need_scales),Tuple{Symbol,String,Union{String,Vector{String}}}}[]

        for var in vars_needed_this_scale # e.g. var_ = :carbon_demand
            # If the variable is multiscale (it is computed by anothe model), we check if there is a model at the 
            # other scale(s) that computes it:
            if var in multi_scale_ins
                # Scale(s) at which the variable is computed:
                from_scales = last(map_vars[findfirst(i -> i == var, multiscale_vars)])
                # We check if there is a model at the other scale(s) that computes it:
                outputs_from_scales = PlantSimEngine.map_scale(mapping, from_scales) do m, s
                    # We check that the node type exist in the model list:
                    haskey(m, s) || error(
                        "Nodes of type $organ are mapping to variable `:$var` computed from nodes of type $s, but there is no type $s in the list of mapping."
                    )
                    # If it does, we get the outputs of its mapping:
                    merge(outputs_.(get_models(m[s]))...)
                end

                outputs_from_scales = merge(outputs_from_scales...)
                if var in keys(outputs_from_scales)
                    # If the variable is computed by a model at the other scale, we don't need to initialise it:
                    continue
                else
                    # If the variable is not found, it may be computed by another scale onto this one (in this case we return an error).
                    PlantSimEngine.map_scale(mapping, from_scales) do m, s
                        map_vars = get_mapping(mapping[s])
                        multiscale_vars = collect(first(i) for i in map_vars)

                        computed_elsewhere = filter(x -> x.first == var, get_mapping(mapping[s]))
                        if length(computed_elsewhere) > 0
                            # found[1] = true
                            computed_elsewhere = computed_elsewhere[1].second

                            # The variable if not computed at the scale given by the user, but we found it at another scale:
                            error(
                                "Nodes of type $organ are mapping variable `:$var` computed from nodes of type $s, but type $s does not compute this variable. ",
                                "The variable is computed by nodes of type $computed_elsewhere."
                            )
                        end
                    end

                    # If still not found, add the variable into need_models_from_scales:
                    push!(need_models_from_scales, (var=var, scale=organ, need_scales=from_scales))
                end
            else
                # In this case the variable is an input of the model, and is not computed by other mapping at this scale or the others.
                if var in vars_in_mtg
                    # If the variable can be found in the MTG, we will take it from there:
                    push!(need_var_from_mtg, VarFromMTG(var, organ))
                else
                    # Else, the user need to initialise it:
                    push!(need_initialisation, var)
                end
            end
            # Note: if the variable is an output of the model for another scale (in `multi_scale_outs`), we don't need to initialise it at this scale.
        end
        if length(need_initialisation) > 0 || length(need_var_from_mtg) > 0 || length(need_models_from_scales) > 0
            var_need_init[organ] = (; need_initialisation, need_models_from_scales, need_var_from_mtg)
        end
    end

    return var_need_init
end

"""
    init_status!(object::Dict{String,ModelList};vars...)
    init_status!(component::ModelList;vars...)

Initialise model variables for components with user input.

# Examples

```@example
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
"""
function init_status!(object::Dict{String,ModelList}; vars...)
    new_vals = (; vars...)

    for (component_name, component) in object
        for j in keys(new_vals)
            if !in(j, keys(component.status))
                @info "Key $j not found as a variable for any provided models in $component_name" maxlog = 1
                continue
            end
            setproperty!(component.status, j, new_vals[j])
        end
    end
end

function init_status!(component::T; vars...) where {T<:ModelList}
    new_vals = (; vars...)
    for j in keys(new_vals)
        if !in(j, keys(component.status))
            @info "Key $j not found as a variable for any provided models"
            continue
        end
        setproperty!(component.status, j, new_vals[j])
    end
end

"""
    init_variables(models...)

Initialized model variables with their default values. The variables are taken from the
inputs and outputs of the models.

# Examples

```@example
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

init_variables(Process1Model(2.0))
init_variables(process1=Process1Model(2.0), process2=Process2Model())
```
"""
function init_variables(model::T; verbose::Bool=true) where {T<:AbstractModel}
    # Only one model is provided:
    in_vars = inputs_(model)
    out_vars = outputs_(model)
    # Merge both:
    vars = merge(in_vars, out_vars)

    return vars
end

function init_variables(m::ModelList; verbose::Bool=true)
    init_variables(dep(m; verbose=verbose))
end

function init_variables(m::DependencyGraph)
    dependencies = traverse_dependency_graph(m, init_variables)
    return NamedTuple(dependencies)
end

function init_variables(node::AbstractDependencyNode)
    return init_variables(node.value)
end

# Models are provided as keyword arguments:
function init_variables(; verbose::Bool=true, kwargs...)
    mods = (; kwargs...)
    init_variables(dep(; verbose=verbose, mods...))
end

# Models are provided as a NamedTuple:
function init_variables(models::T; verbose::Bool=true) where {T<:NamedTuple}
    init_variables(dep(; verbose=verbose, models...))
end

"""
    is_initialized(m::T) where T <: ModelList
    is_initialized(m::T, models...) where T <: ModelList

Check if the variables that must be initialized are, and return `true` if so, and `false` and
an information message if not.

# Note

There is no way to know before-hand which process will be simulated by the user, so if you
have a component with a model for each process, the variables to initialize are always the
smallest subset of all, meaning it is considered the user will simulate the variables needed
for other models.

# Examples

```@example
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
"""
function is_initialized(m::T; verbose=true) where {T<:ModelList}
    var_names = to_initialize(m; verbose=verbose)

    if any([length(to_init) > 0 for (process, to_init) in pairs(var_names)])
        verbose && @info "Some variables must be initialized before simulation: $var_names (see `to_initialize()`)" maxlog = 1
        return false
    else
        return true
    end
end

function is_initialized(models...; verbose=true)
    var_names = to_initialize(models...)
    if length(var_names) > 0
        verbose && @info "Some variables must be initialized before simulation: $(var_names) (see `to_initialize()`)" maxlog = 1
        return false
    else
        return true
    end
end

"""
    vars_not_init_(st<:Status, var_names)

Get which variable is not properly initialized in the status struct.
"""
function vars_not_init_(st::T, default_values) where {T<:Status}
    length(default_values) == 0 && return () # no variables

    not_init = Symbol[]
    for i in keys(default_values)
        # if the variable value is equal to the default value, or if it is an uninitialized RefVector (length == 0):
        if getproperty(st, i) == default_values[i] || (isa(getproperty(st, i), RefVector) && length(getproperty(st, i)) == 0)
            push!(not_init, i)
        end
    end
    return (not_init...,)
end

# For components with a status with multiple time-steps:
function vars_not_init_(status, default_values)
    length(default_values) == 0 && return () # no variables

    not_init = Set{Symbol}()
    for st in Tables.rows(status), i in eachindex(default_values)
        if getproperty(st, i) == getproperty(default_values, i)
            push!(not_init, i)
        end
    end

    return Tuple(not_init)
end

"""
    init_variables_manual(models...;vars...)

Return an initialisation of the model variables with given values.

# Examples

```@example
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
"""
function init_variables_manual(status, vars)
    for i in keys(vars)
        !in(i, keys(status)) && error("Key $i not found as a variable of the status.")
        setproperty!(status, i, vars[i])
    end
    status
end
