
"""
    ModelList(models::M, status::S)
    ModelList(;
        status=nothing,
        type_promotion=nothing,
        variables_check=true,
        kwargs...
    )

List the models for a simulation (`models`), and does all boilerplate for variable initialization, 
type promotion, time steps handling.

!!! note
    The status field depends on the input models. You can get the variables needed by a model
    using [`variables`](@ref) on the instantiation of a model. You can also use [`inputs`](@ref)
    and [`outputs`](@ref) instead.

# Arguments

- `models`: a list of models. Usually given as a `NamedTuple`, but can be any other structure that 
implements `getproperty`.
- `status`: a structure containing the initializations for the variables of the models. Usually a NamedTuple
when given as a kwarg, or any structure that implements the Tables interface from `Tables.jl` (*e.g.* DataFrame, see details).
- `type_promotion`: optional type conversion for the variables with default values.
`nothing` by default, *i.e.* no conversion. Note that conversion is not applied to the
variables input by the user as `kwargs` (need to do it manually).
Should be provided as a Dict with current type as keys and new type as values.
- `variables_check=true`: check that all needed variables are initialized by the user.
- `kwargs`: the models, named after the process they simulate.

# Details

If you need to input a custom Type for the status and make your users able to only partially initialize 
the `status` field in the input, you'll have to implement a method for `add_model_vars!`, a function that 
adds the models variables to the type in case it is not fully initialized. The default method is compatible 
with any type that implements the `Tables.jl` interface (*e.g.* DataFrame), and `NamedTuples`.

Note that `ModelList`makes a copy of the input `status` if it does not list all needed variables.

## Examples

We'll use the dummy models from the `dummy.jl` in the examples folder of the package. It 
implements three dummy processes: `Process1Model`, `Process2Model` and `Process3Model`, with
one model implementation each: `Process1Model`, `Process2Model` and `Process3Model`.

```jldoctest 1
julia> using PlantSimEngine;
```

Including example processes and models:

```jldoctest 1
julia> using PlantSimEngine.Examples;
```

```jldoctest 1
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model());
[ Info: Some variables must be initialized before simulation: (process1 = (:var1, :var2), process2 = (:var1,)) (see `to_initialize()`)
```

```jldoctest 1
julia> typeof(models)
ModelList{@NamedTuple{process1::Process1Model, process2::Process2Model, process3::Process3Model}, TimeStepTable{Status{(:var5, :var4, :var6, :var1, :var3, :var2), NTuple{6, Base.RefValue{Float64}}}}, Tuple{}}
```

No variables were given as keyword arguments, that means that the status of the ModelList is not
set yet, and all variables are initialized to their default values given in the inputs and outputs (usually `typemin(Type)`, *i.e.* `-Inf` for floating
point numbers). This component cannot be simulated yet.

To know which variables we need to initialize for a simulation, we use [`to_initialize`](@ref):

```jldoctest 1
julia> to_initialize(models)
(process1 = (:var1, :var2), process2 = (:var1,))
```

We can now provide values for these variables in the `status` field, and simulate the `ModelList`, 
*e.g.* for `process3` (coupled with `process1` and `process2`):

```jldoctest 1
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0, var2=0.3));
```

```jldoctest 1
julia> meteo = Atmosphere(T = 22.0, Wind = 0.8333, P = 101.325, Rh = 0.4490995);
```

```jldoctest 1
julia> run!(models,meteo)
```

```jldoctest 1
julia> models[:var6]
1-element Vector{Float64}:
 58.0138985
```

If we want to use special types for the variables, we can use the `type_promotion` argument:

```jldoctest 1
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0, var2=0.3), type_promotion = Dict(Float64 => Float32));
```

We used `type_promotion` to force the status into Float32:

```jldoctest 1
julia> [typeof(models[i][1]) for i in keys(status(models))]
6-element Vector{DataType}:
 Float32
 Float32
 Float32
 Float64
 Float64
 Float32
```

But we see that only the default variables (the ones that are not given in the status arguments)
were converted to Float32, the two other variables that we gave were not converted. This is
because we want to give the ability to users to give any type for the variables they provide 
in the status. If we want all variables to be converted to Float32, we can pass them as Float32:

```jldoctest 1
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=(var1=15.0f0, var2=0.3f0), type_promotion = Dict(Float64 => Float32));
```

We used `type_promotion` to force the status into Float32:

```jldoctest 1
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

```jldoctest 1
julia> using DataFrames;
```

```jldoctest 1
julia> df = DataFrame(:var1 => [13.747, 13.8], :var2 => [1.0, 1.0]);
```

```jldoctest 1
julia> m = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model(), status=df, init_fun=x -> DataFrame(x));
```

Note that we use `init_fun` to force the status into a `DataFrame`, otherwise it would
be automatically converted into a `TimeStepTable{Status}`.

```jldoctest 1
julia> status(m)
2×6 DataFrame
 Row │ var5     var4     var6     var1     var3     var2    
     │ Float64  Float64  Float64  Float64  Float64  Float64 
─────┼──────────────────────────────────────────────────────
   1 │    -Inf     -Inf     -Inf   13.747     -Inf      1.0
   2 │    -Inf     -Inf     -Inf   13.8       -Inf      1.0
```

Note that computations will be slower using DataFrame, so if performance is an issue, use
TimeStepTable instead (or a NamedTuple as shown in the example).
"""
struct ModelList{M<:NamedTuple,S#=,O=#,V<:Tuple{Vararg{Symbol}}}
    models::M
    status::S
    #outputs::O
    vars_not_propagated::V
end

function ModelList(models::M, status::Status#=, outputs::O=#) where {#=O,=# M<:NamedTuple{names,T} where {names,T<:NTuple{N,<:AbstractModel} where {N}}}
    ModelList(models, status, ())#outputs, ())
end

# General interface:
function ModelList(
    args...;
    status=nothing,
    #outputs=nothing,
    type_promotion::Union{Nothing,Dict}=nothing,
    variables_check::Bool=true,
    nsteps=nothing,
    kwargs...
)

    # Get all the variables needed by the models and their default values:
    if length(args) > 0
        args = parse_models(args)
    else
        args = NamedTuple()
    end

    if length(kwargs) > 0
        kwargs = (; kwargs...)
    else
        kwargs = ()
    end

    if length(args) == 0 && length(kwargs) == 0
        error("No models were given")
    end

    mods = merge(args, kwargs)

    # Make a vector of NamedTuples from the input (please implement yours if you need it)
    ts_kwargs = homogeneous_ts_kwargs(status)

    # Variables for which a value was given for each time-step by the user:
    vector_vars = get_vars_not_propagated(status)
    # Note: that the length was checked in homogeneous_ts_kwargs, so we don't need to check it again here.
    # Note 2: we need to know these variables because they will not be propagated between time-steps, but set at 
    # the given value instead.

    # Add the missing variables required by the models (set to default value):
    ts_kwargs = add_model_vars(ts_kwargs, mods, type_promotion)

    #=user_outputs = outputs # todo : tuple to array

    # todo check outputs are all amongst the variables provided by the user and models
    f = []
    
    for i in 1:length(mods)
        bb = keys(init_variables(mods[i]))
        for j in 1:length(bb)
            push!(f, bb[j])
        end
        #f = (f..., bb...)
    end

    f = unique!(f)
            
    # default implicit behaviour, track everything
    if isnothing(user_outputs)
        user_outputs = (f...,)
            #all_vars = merge((keys(init_variables(object.models[i])) for i in 1:length(object.models))...)
    else
        unexpected_outputs = setdiff(user_outputs, f)
        if !isempty(unexpected_outputs)
            @error "Some output variable(s) requested was not found / were not found amongst the model variables : "
            for i in 1:length(unexpected_outputs)
                 @error "$(unexpected_outputs[i])"
            end
        end
    end

    # Can't preallocate outputs without knowing which are filtered
    # And creating a TSTable for all of them doesn't help, as a TST of a subset 
    # of the outputs is not of the same type and conversion fails
    status_flattened, vec_vars = flatten_status(deepcopy(ts_kwargs))
    user_outputs = TimeStepTable([status_flattened])=#

    model_list = ModelList(
        mods,
        ts_kwargs,
        #init_fun_default(user_outputs),
        vector_vars
    )
    variables_check && !is_initialized(model_list)

    return model_list
end

outputs(m::ModelList) = m.outputs

parse_models(m) = NamedTuple([process(i) => i for i in m])

init_fun_default(x::Vector{T}) where {T} = TimeStepTable([Status(i) for i in x])
init_fun_default(x::N) where {N<:NamedTuple} = TimeStepTable([Status(x)])
init_fun_default(x) = x

"""
    add_model_vars(x, models, type_promotion; init_fun=init_fun_default)

Check which variables in `x` are not initialized considering a set of `models` and the variables
needed for their simulation. If some variables are uninitialized, initialize them to their default values.

This function needs to be implemented for each type of `x`. The default method works for 
any Tables.jl-compatible `x` and for NamedTuples.

Careful, the function makes a copy of the input `x` if it does not list all needed variables.
"""
function add_model_vars(x, models, type_promotion)
    ref_vars = merge(init_variables(models; verbose=false)...)
    # If no variable is required, we return the input:
    length(ref_vars) == 0 && return isa(x, Status) ? x : Status(x)

    # If the user gave a status, we check if all the variables are already initialized:
    vars_in_x = status_keys(x)
    status_x = 
    all([k in vars_in_x for k in keys(ref_vars)]) && return isa(x, Status) ? x : Status(x)  # If so, we return the input

    # Else, we add the variables by making a new object (carefull, this is a copy so it takes more time):

    # Convert model variables types to the one required by the user:
    ref_vars = convert_vars(ref_vars, type_promotion)

    # If the user gave an empty status, we initialize all variables to their default values:
    if x === nothing
       return Status(ref_vars)
    end

    x_full = merge(ref_vars, NamedTuple(x))

    return Status(x_full)
end

function status_keys(st)
    #Tables.istable(st) && return Tables.columnnames(st)
    return keys(st)
end

status_keys(::Nothing) = NamedTuple()

# If the user doesn't give any initializations, we initialize all variables to their default values:
function add_model_vars(x::Nothing, models, type_promotion)
    ref_vars = merge(init_variables(models; verbose=false)...)
    length(ref_vars) == 0 && return x
    # Convert model variables types to the one required by the user:
    return Status(convert_vars(ref_vars, type_promotion))
end

"""
    homogeneous_ts_kwargs(kwargs)

By default, the function returns its argument.
"""
homogeneous_ts_kwargs(kwargs) = kwargs

"""
    kwargs_to_timestep(kwargs::NamedTuple{N,T}) where {N,T}

Takes a NamedTuple with optionnaly vector of values for each variable, and makes a 
vector of NamedTuple, with each being a time step.
It is used to be able to *e.g.* give constant values for all time-steps for one variable.

# Examples

```@example
PlantSimEngine.homogeneous_ts_kwargs((Tₗ=[25.0, 26.0], aPPFD=1000.0))
```
"""
function homogeneous_ts_kwargs(kwargs::NamedTuple{N,T}) where {N,T}
    length(kwargs) == 0 && return kwargs
    vars_vals = collect(Any, values(kwargs))
    #length_vars = [isa(i, RefVector) ? 1 : length(i) for i in vars_vals]
    #Note: length is 1 for RefVector because it is a vector of references to other scales, 
    # not a vector of values

    # One of the variable is given as an array, meaning this is actually several
    # time-steps. In this case we make an array of vars.
    max_length_st = 1#nsteps !== nothing ? nsteps : maximum(length_vars)

    #=for i in eachindex(vars_vals)
        # If the ith vars has length one, repeat its value to match the max time-steps:
        if length_vars[i] == 1
            vars_vals[i] = repeat([vars_vals[i]], max_length_st)
        else
            length_vars[i] != max_length_st && @error "$(keys(kwargs)[i]) should be length $max_length_st or 1"
        end
    end=#

    # Making a vars for each ith value in the user vars:
    vars_array = NamedTuple{keys(kwargs)}(j for j in vars_vals)

    return vars_array
end


"""
    get_vars_not_propagated(status)

Returns all variables that are given for several time-steps in the status.
"""
get_vars_not_propagated(status) = (findall(x -> length(x) > 1, status)...,)
get_vars_not_propagated(df::DataFrames.DataFrame) = (propertynames(df)...,)
get_vars_not_propagated(::Nothing) = ()

"""
    Base.copy(l::ModelList)
    Base.copy(l::ModelList, status)

Copy a [`ModelList`](@ref), eventually with new values for the status.

# Examples

```@example
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
"""
function Base.copy(m::T) where {T<:ModelList}
    ModelList(
        m.models,
        deepcopy(m.status),
        m.vars_not_propagated
    )
end

function Base.copy(m::T, status) where {T<:ModelList}
    ModelList(
        m.models,
        status,
        m.vars_not_propagated
    )
end

"""
    Base.copy(l::AbstractArray{<:ModelList})

Copy an array-alike of [`ModelList`](@ref)
"""
function Base.copy(l::T) where {T<:AbstractArray{<:ModelList}}
    return [copy(i) for i in l]
end

"""
    Base.copy(l::AbstractDict{N,<:ModelList} where N)

Copy a Dict-alike [`ModelList`](@ref)
"""
function Base.copy(l::T) where {T<:AbstractDict{N,<:ModelList} where {N}}
    return Dict([k => v for (k, v) in l])
end


"""
    convert_vars(ref_vars, type_promotion::Dict{DataType,DataType})
    convert_vars(ref_vars, type_promotion::Nothing)
    convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Dict{DataType,DataType})
    convert_vars!(ref_vars::Dict{Symbol}, type_promotion::Nothing)

Convert the status variables to the type specified in the type promotion dictionary.
*Note: the mutating version only works with a dictionary of variables.*

# Examples

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
"""
convert_vars, convert_vars!

function convert_vars(ref_vars, type_promotion::Dict{DataType,DataType})
    dict_ref_vars = Dict{Symbol,Any}(zip(keys(ref_vars), values(ref_vars)))
    for (suptype, newtype) in type_promotion
        vars = []
        for var in keys(ref_vars)
            if isa(dict_ref_vars[var], suptype)
                dict_ref_vars[var] = convert(newtype, dict_ref_vars[var])
                push!(vars, var)
            end
        end
        # length(vars) > 1 && @info "$(join(vars, ", ")) are $suptype and were promoted to $newtype"
    end

    return NamedTuple(dict_ref_vars)
end

# Mutating version of the function, needs a dictionary of variables:
function convert_vars!(ref_vars::Dict{Symbol,Any}, type_promotion::Dict)
    for (suptype, newtype) in type_promotion
        for var in keys(ref_vars)
            if isa(ref_vars[var], suptype)
                ref_vars[var] = convert(newtype, ref_vars[var])
            elseif isa(ref_vars[var], MappedVar) && isa(mapped_default(ref_vars[var]), suptype)
                ref_mapped_var = ref_vars[var]
                old_default = mapped_default(ref_vars[var])

                if isa(old_default, AbstractArray)
                    new_val = [convert(newtype, i) for i in old_default]
                else
                    new_val = convert(newtype, old_default)
                end

                ref_vars[var] = MappedVar(
                    source_organs(ref_mapped_var),
                    mapped_variable(ref_mapped_var),
                    source_variable(ref_mapped_var),
                    new_val,
                )
            elseif isa(ref_vars[var], UninitializedVar) && isa(ref_vars[var].value, suptype)
                ref_mapped_var = ref_vars[var]
                old_default = ref_vars[var].value

                if isa(old_default, AbstractArray)
                    new_val = [convert(newtype, i) for i in old_default]
                else
                    new_val = convert(newtype, old_default)
                end

                ref_vars[var] = UninitializedVar(var, new_val)
            end
        end
    end
end

# This is the generic one, with no convertion:
function convert_vars(ref_vars, type_promotion::Nothing)
    return ref_vars
end

function convert_vars!(ref_vars::Dict{String,Dict{Symbol,Any}}, type_promotion::Nothing)
    return ref_vars
end

"""
    convert_vars!(mapped_vars::Dict{String,Dict{String,Any}}, type_promotion)

Converts the types of the variables in a mapping (`mapped_vars`) using the `type_promotion` dictionary.

The mapping should be a dictionary with organ name as keys and a dictionary of variables as values,
with variable names as symbols and variable value as value.
"""
function convert_vars!(mapped_vars::Dict{String,Dict{Symbol,Any}}, type_promotion)
    for (organ, vars) in mapped_vars
        convert_vars!(vars, type_promotion)
    end
end

function Base.show(io::IO, ::MIME"text/plain", t::ModelList)
    print(io, dep(t, verbose=false))
    print(io, status(t))
end

# Short form printing (e.g. inside another object)
function Base.show(io::IO, t::ModelList)
    print(io, "ModelList", (; zip(keys(t.models), typeof.(values(t.models)))...))
end