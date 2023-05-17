
"""
    ModelList(models::M, status::S)
    ModelList(;
        status=nothing,
        init_fun::Function=init_fun_default,
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
- `nsteps=nothing`: the number of time steps to pre-allocated. If `nothing`, the number of time steps is deduced from the status (or 1 if no status is given).
- `init_fun`: a function that initializes the status based on a vector of NamedTuples (see details).
- `type_promotion`: optional type conversion for the variables with default values.
`nothing` by default, *i.e.* no conversion. Note that conversion is not applied to the
variables input by the user as `kwargs` (need to do it manually).
Should be provided as a Dict with current type as keys and new type as values.
- `variables_check=true`: check that all needed variables are initialized by the user.
- `kwargs`: the models, named after the process they simulate.

# Details

The argument `init_fun` is set by default to `init_fun_default` which initializes the status with a `TimeStepTable`
of `Status` structures.

If you change `init_fun` by another function, make sure the type you are using (*i.e.* in place of `TimeStepTable`) 
implements the `Tables.jl` interface (*e.g.* DataFrame does). And if you still use `TimeStepTable` but only change
`Status`, make sure the type you give is indexable using the dot synthax (*e.g.* `x.var`).

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

Including an example script that implements dummy processes and models:

```jldoctest 1
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"));
```

```jldoctest 1
julia> models = ModelList(process1=Process1Model(1.0), process2=Process2Model(), process3=Process3Model());
[ Info: Some variables must be initialized before simulation: (process1 = (:var1, :var2), process2 = (:var1,)) (see `to_initialize()`)
```

```jldoctest 1
julia> typeof(models)
ModelList{NamedTuple{(:process1, :process2, :process3), Tuple{Process1Model, Process2Model, Process3Model}}, TimeStepTable{Status{(:var4, :var5, :var6, :var1, :var3, :var2), NTuple{6, Base.RefValue{Float64}}}}}
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
 Row │ var4     var5     var6     var1     var3     var2    
     │ Float64  Float64  Float64  Float64  Float64  Float64 
─────┼──────────────────────────────────────────────────────
   1 │    -Inf     -Inf     -Inf   13.747     -Inf      1.0
   2 │    -Inf     -Inf     -Inf   13.8       -Inf      1.0
```

Note that computations will be slower using DataFrame, so if performance is an issue, use
TimeStepTable instead (or a NamedTuple as shown in the example).
"""
struct ModelList{M<:NamedTuple,S}
    models::M
    status::S
end

# General interface:
function ModelList(
    args...;
    status=nothing,
    init_fun::Function=init_fun_default,
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
    ts_kwargs = homogeneous_ts_kwargs(status, nsteps)

    # Add the missing variables required by the models (set to default value):
    ts_kwargs = add_model_vars(ts_kwargs, mods, type_promotion; init_fun=init_fun, nsteps=nsteps)

    model_list = ModelList(
        mods,
        ts_kwargs
    )
    variables_check && !is_initialized(model_list)

    return model_list
end

parse_models(m::Tuple) = NamedTuple([process(i) => i for i in m])

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
function add_model_vars(x, models, type_promotion; init_fun=init_fun_default, nsteps=nothing)
    ref_vars = merge(init_variables(models; verbose=false)...)
    # If no variable is required, we return the input:
    length(ref_vars) == 0 && return x

    # If the user gave a status, we check if all the variables are already initialized:
    vars_in_x = status_keys(x)
    all([k in vars_in_x for k in keys(ref_vars)]) && return x # If so, we return the input

    # Else, we add the variables by making a new object (carefull, this is a copy so it takes more time):

    # Convert model variables types to the one required by the user:
    ref_vars = convert_vars(type_promotion, ref_vars)

    # If the user gave an empty status, we initialize all variables to their default values:
    if x === nothing || (!Tables.istable(x) && length(x) == 0)
        if nsteps === nothing
            return init_fun(fill(ref_vars, 1))
        else
            return init_fun(fill(ref_vars, nsteps))
        end
    end

    # Making a vars for each ith value in the user vars:
    x_full = []
    for r in Tables.rows(x)
        push!(x_full, merge(ref_vars, NamedTuple(r)))
    end

    return init_fun(x_full)
end

function status_keys(st)
    Tables.istable(st) && return Tables.columnnames(st)
    return keys(st)
end

status_keys(::Nothing) = NamedTuple()

# If the user doesn't give any initializations, we initialize all variables to their default values:
function add_model_vars(x::Nothing, models, type_promotion)
    ref_vars = merge(init_variables(models; verbose=false)...)
    length(ref_vars) == 0 && return x
    # Convert model variables types to the one required by the user:
    return convert_vars(type_promotion, ref_vars)
end

"""
    homogeneous_ts_kwargs(kwargs)

By default, the function returns its argument.
"""
homogeneous_ts_kwargs(kwargs, nsteps) = kwargs

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
function homogeneous_ts_kwargs(kwargs::NamedTuple{N,T}, nsteps) where {N,T}
    length(kwargs) == 0 && return kwargs
    vars_vals = collect(Any, values(kwargs))
    length_vars = [length(i) for i in vars_vals]

    # One of the variable is given as an array, meaning this is actually several
    # time-steps. In this case we make an array of vars.
    max_length_st = nsteps !== nothing ? nsteps : maximum(length_vars)

    for i in eachindex(vars_vals)
        # If the ith vars has length one, repeat its value to match the max time-steps:
        if length_vars[i] == 1
            vars_vals[i] = repeat([vars_vals[i]], max_length_st)
        else
            length_vars[i] != max_length_st && @error "$(keys(kwargs)[i]) should be length $max_length_st or 1"
        end
    end

    # Making a vars for each ith value in the user vars:
    vars_array = NamedTuple[NamedTuple{keys(kwargs)}(j[i] for j in vars_vals) for i in 1:max_length_st]

    return vars_array
end

"""
    Base.copy(l::ModelList)
    Base.copy(l::ModelList, status)

Copy a [`ModelList`](@ref), eventually with new values for the status.

# Examples

```@example
using PlantSimEngine

# Including an example script that implements dummy processes and models:
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

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
        deepcopy(m.status)
    )
end

function Base.copy(m::T, status) where {T<:ModelList}
    ModelList(
        m.models,
        status
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
    convert_vars(type_promotion::Dict{DataType,DataType}, ref_vars)
    convert_vars(type_promotion::Nothing, ref_vars)

Convert the status variables to the type specified in the type promotion dictionary.

# Examples

If we want all the variables that are Reals to be Float32, we can use:

```julia
using PlantSimEngine

# Including an example script that implements dummy processes and models:
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

ref_vars = init_variables(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
)
type_promotion = Dict(Real => Float32)

PlantSimEngine.convert_vars(type_promotion, ref_vars.process3)
```
"""
function convert_vars(type_promotion::Dict{DataType,DataType}, ref_vars)
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

# This is the generic one, with no convertion:
function convert_vars(type_promotion::Nothing, ref_vars)
    return ref_vars
end


function Base.show(io::IO, ::MIME"text/plain", t::ModelList)
    print(io, dep(t, verbose=false))
    print(io, status(t))
end

# Short form printing (e.g. inside another object)
function Base.show(io::IO, t::ModelList)
    print(io, "ModelList", (; zip(keys(t.models), typeof.(values(t.models)))...))
end