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
    keys(_input_schema(model))
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
    timespec(model::AbstractModel)
    timespec(::Type{<:AbstractModel})

Clock definition for a model. Default is single-rate behaviour (`dt=1.0`, `phase=0.0`).
"""
timespec(model::AbstractModel) = timespec(typeof(model))
timespec(::Type{<:AbstractModel}) = ClockSpec(1.0, 0.0)

"""
    output_policy(model::AbstractModel)
    output_policy(::Type{<:AbstractModel})

Per-output scheduling policy for a model. Default is empty, meaning all outputs
fallback to hold-last behaviour.

When multi-rate input bindings are inferred automatically, this trait also
provides the default cross-clock policy (`HoldLast`, `Integrate`, `Aggregate`,
or `Interpolate`) for each producer output.
"""
output_policy(model::AbstractModel) = output_policy(typeof(model))
output_policy(::Type{<:AbstractModel}) = NamedTuple()

function _policy_for_output(model, variable::Symbol)
    policies = output_policy(model)
    variable in keys(policies) || return HoldLast()
    return _as_schedule_policy(
        policies[variable];
        context="output_policy for `$(variable)` in $(typeof(model))",
    )
end

function _publish_mode_for_output(spec::ModelSpec, variable::Symbol)
    modes = output_routing(spec)
    mode = variable in keys(modes) ? modes[variable] : :canonical
    mode in (:canonical, :stream_only) || error(
        "Unsupported output routing mode `$(mode)` for `$(variable)`."
    )
    return mode
end

"""
    application_name(spec::ModelSpec)

Optional stable name for one model application in the unified composite-model/object API.
"""
application_name(spec::ModelSpec) = spec.name

"""
    applies_to(spec::ModelSpec)

Object selector where a model application runs in the unified composite-model/object API.
"""
applies_to(spec::ModelSpec) = spec.applies_to

"""
    value_inputs(spec::ModelSpec)

Unified composite-model/object value-input bindings declared with the
`ModelSpec(...; inputs=...)` keyword.
"""
value_inputs(spec::ModelSpec) = spec.inputs
input_origins(spec::ModelSpec) = spec.input_origins

"""
    model_calls(spec::ModelSpec)

Unified composite-model/object call bindings declared with the
`ModelSpec(...; calls=...)` keyword. Ordinary object selectors declare manual
calls; [`Initializer`](@ref) wraps a selector for targeted newborn
initialization while leaving the callee normally scheduled.
"""
model_calls(spec::ModelSpec) = spec.calls
call_origins(spec::ModelSpec) = spec.call_origins

"""
    outputs_to(spec::ModelSpec)

Named distributed-output destinations declared with the
`ModelSpec(...; outputs_to=...)` keyword.
"""
outputs_to(spec::ModelSpec) = spec.outputs_to

"""
    environment_config(spec::ModelSpec)

Optional composite-model/object environment configuration declared with
`ModelSpec(...; environment=Environment(...))`.
"""
environment_config(spec::ModelSpec) = spec.environment

"""
    output_routing(spec::ModelSpec)

Per-output routing mode for multi-rate runs.
Allowed values are:
- `:canonical` (default): output participates in canonical status publication.
- `:stream_only`: output is only tracked in temporal streams.
"""
output_routing(spec::ModelSpec) = spec.output_routing

"""
    updates(spec::ModelSpec)

Scenario-level metadata for variables intentionally updated by this model after
another producer on the same object.
"""
updates(spec::ModelSpec) = spec.updates

"""
    environment_bindings(spec::ModelSpec)

Optional explicit weather aggregation bindings used by the model runtime.
Each key is the target environment variable exposed to the model at execution time.
Each value can be:
- PlantMeteo reducer instance/type (e.g. `MeanWeighted()`, `MaxReducer`)
- `Function`: custom reducer callable
- `NamedTuple`: optional fields `source` and `reducer`
"""
environment_bindings(spec::ModelSpec) = spec.environment_bindings

"""
    environment_window(spec::ModelSpec)

Optional weather window-selection strategy used by the model runtime.
Defaults to `nothing` (runtime falls back to `PlantMeteo.RollingWindow()` behavior).
"""
environment_window(spec::ModelSpec) = spec.environment_window

"""
    environment_inputs(model::AbstractModel)
    environment_inputs_(model::AbstractModel)

Environment variables read directly by a model.

This trait is separate from `inputs_` because meteorology may be constant,
table-backed, or produced by a microclimate backend. The default is empty.
"""
environment_inputs(model::AbstractModel) = keys(environment_inputs_(model))
environment_inputs(spec::ModelSpec) = keys(environment_inputs_(spec))
environment_inputs_(model::AbstractModel) = NamedTuple()
environment_inputs_(model::Missing) = NamedTuple()

"""
    environment_outputs(model::AbstractModel)
    environment_outputs_(model::AbstractModel)

Environment variables that a controller model is allowed to
commit with [`commit_environment!`](@ref), for example local microclimate
variables computed over a canopy, voxel, or octree backend.

These declarations are environment capabilities, not status outputs.
Declare diagnostic status values separately with `outputs_`.
"""
environment_outputs(model::AbstractModel) = keys(environment_outputs_(model))
environment_outputs(spec::ModelSpec) = keys(environment_outputs_(spec))
environment_outputs_(model::AbstractModel) = NamedTuple()
environment_outputs_(model::Missing) = NamedTuple()

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

function outputs_(model::AbstractModel)
    NamedTuple()
end

function outputs_(model::Missing)
    NamedTuple()
end


"""
    variables(model)
    variables(model, models...)

Return the values PlantSimEngine can initialize without user input: genuine
input defaults declared with `Default(value)` and initial output-state values.
Required inputs have no initialization value and are therefore omitted.

# Note

Each model can (and should) have a method for this function.

```jldoctest

using PlantSimEngine;

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples;

variables(Process1Model(1.0))

variables(Process1Model(1.0), Process2Model())

# output

(var3 = -Inf, var4 = -Inf, var5 = -Inf)
```

# See also

[`inputs`](@ref), [`outputs`](@ref) and [`variables_typed`](@ref)
"""
function variables(m::T, ms...) where {T<:Union{Missing,AbstractModel}}
    if length((ms...,)) > 0
        return merge(variables(m), variables(ms...))
    end
    input_defaults = m isa Missing ?
                     NamedTuple() :
                     _input_default_values(_input_schema(m))
    return merge(input_defaults, outputs_(m))
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
    init_variables(model)

Return the merged genuine input defaults and initial output-state values
declared by `model`. Inputs declared with `Required(T)` are omitted.
"""
init_variables(model::AbstractModel; verbose::Bool=true) = variables(model)
init_variables(spec::ModelSpec; verbose::Bool=true) = init_variables(model_(spec); verbose=verbose)

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

    in_vars = _input_schema(m)
    in_vars_type = Dict(
        Symbol(name) => _input_expected_type(declaration)
        for (name, declaration) in pairs(in_vars)
    )
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
