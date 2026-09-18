"""
    ModelSpec(model; name=nothing, on=nothing, inputs=NamedTuple(),
              calls=NamedTuple(), outputs_to=(),
              environment=nothing, every=nothing,
              environment_bindings=NamedTuple(), environment_window=nothing,
              output_routing=NamedTuple(), updates=())

Configuration for one model application in a `CompositeModel`.

`ModelSpec` is the single scenario-construction form. `on` selects the target
objects, `inputs` and `calls` declare coupling, and a `calls` entry may wrap its
selector in [`Initializer`](@ref) for targeted newborn initialization.
`outputs_to` declares status outputs owned by this application but stored on
selected destination objects, `every` selects application cadence, and
`environment` accepts an [`Environment`](@ref) configuration. Output routing
and intentional duplicate-writer ordering are declared directly with
`output_routing` and `updates`.

# Example

```julia
ModelSpec(
    model;
    name=:leaf_energy,
    on=Many(scale=:Leaf),
    inputs=(:soil_water => One(scale=:Soil, var=:water),),
    calls=(:stomata => One(within=Self(), application=:stomata),),
    every=Dates.Hour(1),
    environment=Environment(provider=:canopy),
    output_routing=(temperature=:stream_only,),
    updates=Updates(:temperature; after=:radiation),
)
```
"""
struct ModelSpec{M,N,AT,IN,IO,CA,CO,OT,EV,TS,MB,MW,OR,UP}
    model::M
    name::N
    applies_to::AT
    inputs::IN
    input_origins::IO
    calls::CA
    call_origins::CO
    outputs_to::OT
    environment::EV
    timestep::TS
    environment_bindings::MB
    environment_window::MW
    output_routing::OR
    updates::UP
end

_normalize_output_to_variables(::Nothing) = nothing

function _normalize_output_to_variables(vars::Tuple)
    isempty(vars) && throw(ArgumentError("`OutputTo(...; vars=...)` requires at least one variable name."))
    all(name -> name isa Symbol, vars) || throw(ArgumentError(
        "`OutputTo(...; vars=...)` requires a tuple of variable names as Symbols.",
    ))
    length(unique(vars)) == length(vars) || throw(ArgumentError(
        "`OutputTo(...; vars=...)` contains duplicate variable names.",
    ))
    return vars
end

function _normalize_output_to_variables(vars)
    throw(ArgumentError(
        "`OutputTo(...; vars=...)` requires a non-empty tuple of variable names, " *
        "or omit `vars` to infer all distributed outputs for a single destination; got `$(typeof(vars))`.",
    ))
end

function _normalize_output_to_coverage(coverage)
    coverage === :exact || error(
        "Unsupported `OutputTo` coverage `$(repr(coverage))`. Only `coverage=:exact` ",
        "is currently supported."
    )
    return coverage
end

"""
    OutputTo(selector; vars=nothing, coverage=:exact)

Bind distributed model outputs to objects selected by `selector`.

Declare each variable in `outputs_` using [`Distributed`](@ref). `vars` lists
those names as a tuple. With a single `OutputTo`, omitted `vars` binds all
`Distributed` outputs. With multiple destinations, every entry must specify
`vars`. The compiler rejects missing, duplicate, unknown, and local-output
bindings before initializing destination status.

`coverage=:exact` requires one result for every selected destination.

# Example

```julia
OutputTo(Many(scale=:Leaf, within=SceneScope()))
OutputTo(Many(scale=:Leaf, within=SceneScope()); vars=(:incident_par, :absorbed_par))
```
"""
struct OutputTo{S,V,C}
    selector::S
    vars::V
    coverage::C

    function OutputTo(selector; vars=nothing, coverage=:exact)
        normalized_selector = _validate_selector_context(selector, :output_destination)
        normalized_vars = _normalize_output_to_variables(vars)
        normalized_coverage = _normalize_output_to_coverage(coverage)
        return new{
            typeof(normalized_selector),
            typeof(normalized_vars),
            typeof(normalized_coverage),
        }(normalized_selector, normalized_vars, normalized_coverage)
    end
end

function _normalize_outputs_to(destinations::Tuple)
    all(destination -> destination isa OutputTo, destinations) || throw(ArgumentError(
        "`outputs_to` requires a tuple of anonymous `OutputTo(...)` declarations.",
    ))
    return destinations
end

function _normalize_outputs_to(destinations)
    throw(ArgumentError(
        "`outputs_to` requires a tuple of anonymous `OutputTo(...)` declarations; " *
        "got `$(typeof(destinations))`.",
    ))
end

function _resolved_output_destinations(spec::ModelSpec, effective_model=model_(spec))
    schema = _distributed_output_schema(effective_model)
    destinations = spec.outputs_to
    application = isnothing(spec.name) ? process(effective_model) : spec.name
    context = "Application `$(application)`"
    for name in keys(schema)
        get(spec.output_routing, name, :canonical) === :stream_only && throw(ArgumentError(
            "$(context) cannot route Distributed output `$(name)` as stream_only: " *
            "output targets write destination status. Use canonical routing for this variable.",
        ))
    end
    used = Set{Symbol}()
    resolved = map(destinations) do destination
        inferred = isnothing(destination.vars)
        inferred && length(destinations) != 1 && throw(ArgumentError(
            "$(context) has multiple OutputTo destinations; specify `vars` for every entry.",
        ))
        names = inferred ? keys(schema) : destination.vars
        isempty(names) && throw(ArgumentError(
            "$(context) has no Distributed outputs to infer for OutputTo.",
        ))
        for name in names
            haskey(schema, name) || throw(ArgumentError(
                "$(context) binds `$(name)` in OutputTo, but it is not declared as " *
                "a Distributed output. Declared distributed outputs: `$(keys(schema))`.",
            ))
            name in used && throw(ArgumentError(
                "$(context) binds distributed output `$(name)` more than once in outputs_to.",
            ))
            push!(used, name)
        end
        (
            selector=destination.selector,
            vars=NamedTuple{names}(map(name -> schema[name], names)),
            coverage=destination.coverage,
            origin=inferred ? :inferred : :explicit,
        )
    end
    missing = Tuple(name for name in keys(schema) if !(name in used))
    isempty(missing) || throw(ArgumentError(
        "$(context) declares Distributed output(s) `$(missing)` without an " *
        "OutputTo binding in `outputs_to`.",
    ))
    return resolved
end

"""
    Updates(vars...; after=nothing)

Scenario-level declaration that a model updates variables which may also be
computed by another model at the same scale.

`after` contains canonical application identifiers. It is intentionally
scenario-level metadata: the model implementation stays reusable, while the
simulation setup can declare ordering constraints that only exist in this
coupling.
"""
struct Updates{V,A}
    variables::V
    after::A
end

function Updates(vars::Vararg{Union{Symbol,AbstractString}}; after=nothing)
    isempty(vars) && error("Updates(...) requires at least one variable.")
    return Updates(Tuple(Symbol(v) for v in vars), _normalize_update_after(after))
end

function _normalize_update_after(after)
    isnothing(after) && return ()
    after isa Union{Symbol,AbstractString} && return (Symbol(after),)
    return Tuple(Symbol(v) for v in after)
end

_normalize_updates(updates::Updates) = (updates,)

function _normalize_updates(updates::Tuple)
    all(update -> update isa Updates, updates) || error(
        "Unsupported updates tuple. Use `Updates(:var; after=:application)` entries."
    )
    return updates
end

function _normalize_updates(updates::AbstractVector)
    all(update -> update isa Updates, updates) || error(
        "Unsupported updates vector. Use `Updates(:var; after=:application)` entries."
    )
    return Tuple(updates)
end

function _normalize_updates(updates)
    updates == NamedTuple() && return ()
    updates == () && return ()
    error(
        "Unsupported updates metadata `$(updates)` of type `$(typeof(updates))`. ",
        "Use `Updates(:var; after=:application)` or a tuple/vector of `Updates`."
    )
end

function ModelSpec(
    model::AbstractModel;
    name=nothing,
    on=nothing,
    inputs=NamedTuple(),
    calls=NamedTuple(),
    outputs_to=(),
    environment=nothing,
    every=nothing,
    environment_bindings=NamedTuple(),
    environment_window=nothing,
    output_routing=NamedTuple(),
    updates=(),
)
    return _build_model_spec(
        model;
        name=name,
        on=on,
        inputs=inputs,
        calls=calls,
        outputs_to=outputs_to,
        environment=environment,
        every=every,
        environment_bindings=environment_bindings,
        environment_window=environment_window,
        output_routing=output_routing,
        updates=updates,
    )
end

function _build_model_spec(
    base_model::AbstractModel;
    name=nothing,
    on=nothing,
    inputs=NamedTuple(),
    input_origins=nothing,
    calls=NamedTuple(),
    call_origins=nothing,
    outputs_to=(),
    environment=nothing,
    every=nothing,
    environment_bindings=NamedTuple(),
    environment_window=nothing,
    output_routing=NamedTuple(),
    updates=(),
)
    normalized_name = _normalize_application_name(name)
    normalized_on = isnothing(on) ? nothing :
                    _validate_selector_context(on, :application_target)
    default_inputs = _model_default_value_inputs(base_model)
    explicit_inputs = _normalize_application_bindings(inputs)
    normalized_inputs = _merge_value_inputs(default_inputs, explicit_inputs)
    for selector in values(normalized_inputs)
        _validate_selector_context(selector, :input)
    end
    normalized_input_origins = isnothing(input_origins) ?
                               _binding_origins(default_inputs, explicit_inputs) :
                               _normalize_binding_origins(input_origins, normalized_inputs)
    _validate_scenario_application_references!(
        normalized_inputs,
        normalized_input_origins,
        :inputs,
    )
    default_calls = _model_default_model_calls(base_model)
    explicit_calls = _normalize_application_bindings(calls)
    normalized_calls = _merge_value_inputs(default_calls, explicit_calls)
    for binding in values(normalized_calls)
        _validate_selector_context(_call_binding_selector(binding), :call)
    end
    normalized_call_origins = isnothing(call_origins) ?
                              _binding_origins(default_calls, explicit_calls) :
                              _normalize_binding_origins(call_origins, normalized_calls)
    _validate_scenario_application_references!(
        normalized_calls,
        normalized_call_origins,
        :calls,
    )
    normalized_outputs_to = _normalize_outputs_to(outputs_to)
    normalized_environment = _normalize_model_environment(environment)
    normalized_environment_bindings = _normalize_environment_bindings(environment_bindings)
    normalized_environment_window = _normalize_environment_window(environment_window)
    normalized_output_routing = _normalize_output_routing(output_routing)
    normalized_updates = _normalize_updates(updates)
    return ModelSpec{typeof(base_model),typeof(normalized_name),typeof(normalized_on),typeof(normalized_inputs),typeof(normalized_input_origins),typeof(normalized_calls),typeof(normalized_call_origins),typeof(normalized_outputs_to),typeof(normalized_environment),typeof(every),typeof(normalized_environment_bindings),typeof(normalized_environment_window),typeof(normalized_output_routing),typeof(normalized_updates)}(
        base_model,
        normalized_name,
        normalized_on,
        normalized_inputs,
        normalized_input_origins,
        normalized_calls,
        normalized_call_origins,
        normalized_outputs_to,
        normalized_environment,
        every,
        normalized_environment_bindings,
        normalized_environment_window,
        normalized_output_routing,
        normalized_updates
    )
end

function _validate_scenario_application_references!(
    bindings::NamedTuple,
    origins::NamedTuple,
    field::Symbol,
)
    for (name, binding) in pairs(bindings)
        getproperty(origins, name) == :model_spec || continue
        selector = field == :calls ? _call_binding_selector(binding) : binding
        selector isa Union{One,OptionalOne} || continue
        selector_criteria = criteria(selector)
        isnothing(_criteria_get(selector_criteria, :process, nothing)) &&
            continue
        isnothing(_criteria_get(selector_criteria, :application, nothing)) ||
            continue
        error(
            "`process=` in scenario `ModelSpec(...; $(field)=...)` is not ",
            "supported for `One` or `OptionalOne`. Name the target ",
            "application and use `application=...`; model-authored `Input` ",
            "and `Call` defaults may still use `process=...`.",
        )
    end
    return nothing
end

function _replace_model_spec(
    spec::ModelSpec;
    model=spec.model,
    name=spec.name,
    on=spec.applies_to,
    inputs=spec.inputs,
    input_origins=spec.input_origins,
    calls=spec.calls,
    call_origins=spec.call_origins,
    outputs_to=spec.outputs_to,
    environment=spec.environment,
    every=spec.timestep,
    environment_bindings=spec.environment_bindings,
    environment_window=spec.environment_window,
    output_routing=spec.output_routing,
    updates=spec.updates,
)
    return _build_model_spec(
        model;
        name=name,
        on=on,
        inputs=inputs,
        input_origins=input_origins,
        calls=calls,
        call_origins=call_origins,
        outputs_to=outputs_to,
        environment=environment,
        every=every,
        environment_bindings=environment_bindings,
        environment_window=environment_window,
        output_routing=output_routing,
        updates=updates,
    )
end

as_model_spec(spec::ModelSpec) = spec
as_model_spec(model::AbstractModel) = ModelSpec(model)

function _normalize_environment_binding(binding)
    if binding isa DataType
        binding <: PlantMeteo.AbstractTimeReducer || error(
            "Unsupported environment reducer type `$(binding)`. ",
            "Use a PlantMeteo reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
        )
        return binding
    elseif binding isa PlantMeteo.AbstractTimeReducer
        return binding
    elseif binding isa Function
        return binding
    elseif binding isa NamedTuple
        return binding
    end
    error(
        "Unsupported environment binding `$(binding)` of type `$(typeof(binding))`. ",
        "Use a PlantMeteo reducer type/instance, callable, or NamedTuple(source=..., reducer=...)."
    )
end

function _normalize_environment_bindings(bindings::NamedTuple)
    normalized = Pair{Symbol,Any}[]
    for (k, v) in pairs(bindings)
        push!(normalized, k => _normalize_environment_binding(v))
    end
    return (; normalized...)
end

function _normalize_environment_bindings(bindings)
    error("Unsupported environment bindings `$(bindings)` of type `$(typeof(bindings))`.")
end

function _normalize_environment_window(window)
    if isnothing(window)
        return nothing
    elseif window isa DataType
        window <: PlantMeteo.AbstractSamplingWindow || error(
            "Unsupported environment sampling-window type `$(window)`. ",
            "Use a PlantMeteo sampling-window type/instance."
        )
        return window()
    elseif window isa PlantMeteo.AbstractSamplingWindow
        return window
    end

    error(
        "Unsupported environment sampling window `$(window)` of type `$(typeof(window))`. ",
        "Use a PlantMeteo sampling-window type/instance."
    )
end

function _normalize_output_routing(routing::NamedTuple)
    normalized = Pair{Symbol,Symbol}[]
    for (k, v) in pairs(routing)
        mode = Symbol(v)
        mode in (:canonical, :stream_only) || error(
            "Unsupported output routing mode `$(mode)` for output `$(k)`. ",
            "Allowed values are `:canonical` and `:stream_only`."
        )
        push!(normalized, k => mode)
    end
    return (; normalized...)
end

function _normalize_output_routing(routing)
    error(
        "Unsupported output routing value `$(routing)` of type `$(typeof(routing))`. ",
        "Use a NamedTuple, e.g. `output_routing=(x=:stream_only,)`.",
    )
end

"""
    Environment(config)
    Environment(; kwargs...)

Environment configuration for a [`ModelSpec`](@ref).

Pass the result directly with `environment=Environment(...)`.
"""
Environment(config) = config isa EnvironmentConfig ? config : EnvironmentConfig(config)
Environment(; kwargs...) = Environment((; kwargs...))

_normalize_model_environment(::Nothing) = nothing
_normalize_model_environment(config::EnvironmentConfig) = config
function _normalize_model_environment(config)
    error(
        "Unsupported model environment configuration `$(config)` of type ",
        "`$(typeof(config))`. Use `environment=Environment(...)`.",
    )
end

model_(m::ModelSpec) = m.model
process(m::ModelSpec) = process(model_(m))
timestep(m::ModelSpec) = m.timestep
inputs_(m::ModelSpec) = inputs_(model_(m))
outputs_(m::ModelSpec) = outputs_(model_(m))

function dep(spec::ModelSpec)
    dependencies = dep(model_(spec))
    kept = Pair{Symbol,Any}[]
    for (name, selector) in pairs(dependencies)
        selector isa Union{Input,Call,Initializer} && continue
        push!(kept, name => selector)
    end
    return (; kept...)
end
environment_inputs_(m::ModelSpec) = environment_inputs_(model_(m))
environment_outputs_(m::ModelSpec) = environment_outputs_(model_(m))
variable_contracts_(m::ModelSpec) = variable_contracts_(model_(m))

_declared_contract_variable_names(spec::ModelSpec) =
    _declared_contract_variable_names(model_(spec))

function _validate_variable_contract_names(spec::ModelSpec, schema)
    declared = _declared_contract_variable_names(spec)
    unknown = sort!(
        Symbol[name for name in keys(schema) if Symbol(name) ∉ declared];
        by=string,
    )
    isempty(unknown) || return _invalid_variable_contract_schema_error(
        spec,
        "declares unknown variable(s) `$(Tuple(unknown))`. Contract keys must " *
        "also appear in `inputs_`, `outputs_`, `environment_inputs_`, " *
        "`environment_outputs_`. Declare distributed outputs with `Distributed` in `outputs_`.",
    )
    return schema
end

function run!(m::ModelSpec, status, environment, constants=nothing, context=nothing)
    return run!(model_(m), status, environment, constants, context)
end
