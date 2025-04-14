"""
    inputs(model::AbstractModel)
    inputs(...)

Get the inputs of one or several models.

Returns an empty tuple by default for `AbstractModel`s (no inputs) or `Missing` models.

# Examples

```jldoctest
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

inputs(Process1Model(1.0))

# output
(:var1, :var2)
```
"""
function inputs(model::T) where {T<:AbstractModel}
    keys(inputs_(model))
end

function inputs_(model::AbstractModel)
    NamedTuple()
end

function inputs(v::T, vars...) where {T<:AbstractModel}
    length((vars...,)) > 0 ? union(inputs(v), inputs(vars...)) : inputs(v)
end

function inputs_(model::Missing)
    NamedTuple()
end

"""
    inputs(mapping::Dict{String,T})

Get the inputs of the models in a mapping, for each process and organ type.
"""
function inputs(mapping::Dict{String,T}) where {T}
    vars = Dict{String,NamedTuple}()
    for organ in keys(mapping)
        mods = pairs(parse_models(get_models(mapping[organ])))
        push!(vars, organ => (; (i.first => (inputs(i.second)...,) for i in mods)...))
    end
    return vars
end


"""
    outputs(model::AbstractModel)
    outputs(...)

Get the outputs of one or several models.

Returns an empty tuple by default for `AbstractModel`s (no outputs) or `Missing` models.

# Examples

```jldoctest
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

outputs(Process1Model(1.0))

# output
(:var3,)
```
"""
function outputs(model::T) where {T<:AbstractModel}
    keys(outputs_(model))
end

function outputs(v::T, vars...) where {T<:AbstractModel}
    length((vars...,)) > 0 ? union(outputs(v), outputs(vars...)) : outputs(v)
end

"""
    outputs(mapping::Dict{String,T})

Get the outputs of the models in a mapping, for each process and organ type.
"""
function outputs(mapping::Dict{String,T}) where {T}
    vars = Dict{String,NamedTuple}()
    for organ in keys(mapping)
        mods = pairs(parse_models(get_models(mapping[organ])))
        push!(vars, organ => (; (i.first => (outputs(i.second)...,) for i in mods)...))
    end
    return vars
end


function outputs_(model::AbstractModel)
    NamedTuple()
end

function outputs_(model::Missing)
    NamedTuple()
end


"""
    variables(model)
    variables(model, models...)

Returns a tuple with the name of the variables needed by a model, or a union of those
variables for several models.

# Note

Each model can (and should) have a method for this function.

```jldoctest

using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

variables(Process1Model(1.0))

variables(Process1Model(1.0), Process2Model())

# output

(var1 = -Inf, var2 = -Inf, var3 = -Inf, var4 = -Inf, var5 = -Inf)
```

# See also

[`inputs`](@ref), [`outputs`](@ref) and [`variables_typed`](@ref)
"""
function variables(m::T, ms...) where {T<:Union{Missing,AbstractModel}}
    length((ms...,)) > 0 ? merge(variables(m), variables(ms...)) : merge(inputs_(m), outputs_(m))
end

function variables(m::SoftDependencyNode)
    self_variables = (inputs=inputs_(m.value), outputs=outputs_(m.value))
    # hard_dep_vars = map(variables, m.hard_dependencies)
    return self_variables
end

function variables(m::HardDependencyNode)
    return (inputs=inputs_(m.value), outputs=outputs_(m.value))
end

"""
    variables(pkg::Module)

Returns a dataframe of all variables, their description and units in a package
that has PlantSimEngine as a dependency (if implemented by the authors).

# Note to developers

Developers of a package that depends on PlantSimEngine should 
put a csv file in "data/variables.csv", then this file will be 
returned by the function.

# Examples

Here is an example with the PlantBiophysics package:

```julia
#] add PlantBiophysics
using PlantBiophysics
variables(PlantBiophysics)
```
"""
function variables(pkg::Module)
    sort!(CSV.read(joinpath(dirname(dirname(pathof(pkg))), "data", "variables.csv"), DataFrames.DataFrame))
end

"""
    variables(mapping::Dict{String,T})

Get the variables (inputs and outputs) of the models in a mapping, for each 
process and organ type.
"""
function variables(mapping::Dict{String,T}) where {T}
    vars = Dict{String,NamedTuple}()
    for organ in keys(mapping)
        mods = pairs(parse_models(get_models(mapping[organ])))
        push!(vars, organ => (; (i.first => (; variables(i.second)...,) for i in mods)...))
    end
    return vars
end

"""
    variables_typed(model)
    variables_typed(model, models...)

Returns a named tuple with the name and the types of the variables needed by a model, or a
union of those for several models.

# Examples

```jldoctest
using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

PlantSimEngine.variables_typed(Process1Model(1.0))
(var1 = Float64, var2 = Float64, var3 = Float64)

PlantSimEngine.variables_typed(Process1Model(1.0), Process2Model())

# output
(var4 = Float64, var5 = Float64, var1 = Float64, var2 = Float64, var3 = Float64)
```

# See also

[`inputs`](@ref), [`outputs`](@ref) and [`variables`](@ref)

"""
function variables_typed(m::T) where {T<:AbstractModel}

    in_vars = inputs_(m)
    in_vars_type = Dict(zip(keys(in_vars), typeof(in_vars).types))
    out_vars = outputs_(m)
    out_vars_type = Dict(zip(keys(out_vars), typeof(out_vars).types))

    # Merge both with type promotion:
    vars = mergewith(promote_type, in_vars_type, out_vars_type)

    # Checking that variables have the same type in inputs and outputs:
    vars_different_types = diff_vars(in_vars_type, out_vars_type)
    if length(vars_different_types) > 0
        @warn """The following variables have different types between models:
                    $vars_different_types, they will be promoted."""
    end

    return (; vars...)
end

function variables_typed(m::T, ms...) where {T<:AbstractModel}
    if length((ms...,)) > 0
        m_vars = variables_typed(m)
        ms_vars = variables_typed(ms...)
        m_vars_dict = Dict(zip(keys(m_vars), values(m_vars)))
        ms_vars_dict = Dict(zip(keys(ms_vars), values(ms_vars)))
        vars = mergewith(promote_type, m_vars_dict, ms_vars_dict)
        #! remove the transformation into a Dict when mergewith exist for NamedTuples.
        #! Check here: https://github.com/JuliaLang/julia/issues/36048

        vars_different_types = diff_vars(m_vars, ms_vars)
        if length(vars_different_types) > 0
            @warn """The following variables have different types between models:
            $vars_different_types, they will be promoted."""
        end

        return (; vars...)
    else
        return variables_typed(m)
    end
end

"""
    diff_vars(x, y)

Returns the names of variables that have different values in x and y.
"""
function diff_vars(x, y)
    # Checking that variables have the same value in x and y:
    common_vars = intersect(keys(x), keys(y))
    vars_different_types = []

    if length(common_vars) > 0
        for i in common_vars
            if x[i] != y[i]
                push!(vars_different_types, i)
            end
        end
    end
    return vars_different_types
end