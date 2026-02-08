const _INPUT_BINDING_FIELDS = (:process, :var, :scale, :policy)
const _MODEL_SCOPE_SELECTORS = (:global, :plant, :scene, :self)
const _METEO_BINDING_FIELDS = (:source, :reducer)
const _CALENDAR_PERIODS = (:day, :week, :month)
const _CALENDAR_ANCHORS = (:current_period, :previous_complete_period)
const _CALENDAR_COMPLETENESS = (:allow_partial, :strict)

function _validate_window_reducer(scale::String, process::Symbol, input_var::Symbol, policy_name::Symbol, reducer)
    if reducer isa DataType
        reducer <: PlantMeteo.AbstractTimeReducer || error(
            "Invalid reducer type `$(reducer)` for policy `$(policy_name)` on input `$(input_var)` ",
            "in process `$(process)` at scale `$(scale)`. ",
            "Expected a PlantMeteo reducer type/instance or a callable."
        )
        rr = try
            reducer()
        catch
            error(
                "Reducer type `$(reducer)` for policy `$(policy_name)` on input `$(input_var)` ",
                "in process `$(process)` at scale `$(scale)` cannot be instantiated without arguments."
            )
        end
        applicable(rr, [1.0, 2.0]) || error(
            "Reducer type `$(reducer)` for policy `$(policy_name)` on input `$(input_var)` in process `$(process)` at scale `$(scale)` ",
            "must be callable on a vector of numeric values."
        )
        return nothing
    elseif reducer isa PlantMeteo.AbstractTimeReducer
        applicable(reducer, [1.0, 2.0]) || error(
            "Reducer `$(typeof(reducer))` for policy `$(policy_name)` on input `$(input_var)` in process `$(process)` at scale `$(scale)` ",
            "must be callable on a vector of numeric values."
        )
        return nothing
    elseif reducer isa Function
        applicable(reducer, [1.0, 2.0]) || error(
            "Reducer for policy `$(policy_name)` on input `$(input_var)` in process `$(process)` at scale `$(scale)` ",
            "must be callable on a vector of numeric values."
        )
        return nothing
    end

    error(
        "Invalid reducer value `$(reducer)` (type `$(typeof(reducer))`) for policy `$(policy_name)` ",
        "on input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
        "Expected a PlantMeteo reducer type/instance or a callable."
    )
end

function _validate_policy_instance(scale::String, process::Symbol, input_var::Symbol, policy::SchedulePolicy)
    if policy isa HoldLast
        return nothing
    elseif policy isa Interpolate
        policy.mode in _INTERPOLATE_MODES || error(
            "Invalid interpolation mode `$(policy.mode)` for input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
            "Supported modes are $(_INTERPOLATE_MODES)."
        )
        policy.extrapolation in _INTERPOLATE_MODES || error(
            "Invalid interpolation extrapolation `$(policy.extrapolation)` for input `$(input_var)` in process `$(process)` at scale `$(scale)`. ",
            "Supported values are $(_INTERPOLATE_MODES)."
        )
        return nothing
    elseif policy isa Integrate
        _validate_window_reducer(scale, process, input_var, :Integrate, policy.reducer)
        return nothing
    elseif policy isa Aggregate
        _validate_window_reducer(scale, process, input_var, :Aggregate, policy.reducer)
        return nothing
    end

    return nothing
end

function _validate_timestep_spec(scale::String, process::Symbol, spec::ModelSpec)
    ts = timestep(spec)
    isnothing(ts) && return nothing

    if ts isa ClockSpec
        float(ts.dt) > 0 || error(
            "Invalid timestep for process `$(process)` at scale `$(scale)`: ",
            "`ClockSpec.dt` must be > 0, got $(ts.dt)."
        )
        return nothing
    end

    if ts isa Real
        float(ts) > 0 || error(
            "Invalid timestep for process `$(process)` at scale `$(scale)`: ",
            "numeric timestep must be > 0, got $(ts)."
        )
        return nothing
    end

    if ts isa Dates.Period
        ts isa Dates.FixedPeriod || error(
            "Invalid timestep for process `$(process)` at scale `$(scale)`: ",
            "non-fixed periods are not supported (`$(typeof(ts))`). ",
            "Use fixed periods such as `Second`, `Minute`, `Hour` or `Day`."
        )
        Dates.value(Dates.Second(ts)) > 0 || error(
            "Invalid timestep for process `$(process)` at scale `$(scale)`: ",
            "period must be > 0, got $(ts)."
        )
        return nothing
    end

    error(
        "Invalid timestep for process `$(process)` at scale `$(scale)`: ",
        "expected `Real`, `ClockSpec` or `Dates.Period`, got `$(typeof(ts))`."
    )
end

function _validate_scope_spec(scale::String, process::Symbol, spec::ModelSpec)
    selector = model_scope(spec)
    if selector isa ScopeId
        return nothing
    elseif selector isa Symbol
        selector in _MODEL_SCOPE_SELECTORS || error(
            "Invalid scope selector `$(selector)` for process `$(process)` at scale `$(scale)`. ",
            "Supported selectors are $(_MODEL_SCOPE_SELECTORS), `ScopeId`, or a callable."
        )
        return nothing
    elseif selector isa AbstractString
        Symbol(selector) in _MODEL_SCOPE_SELECTORS || error(
            "Invalid scope selector `$(selector)` for process `$(process)` at scale `$(scale)`. ",
            "Supported selectors are $(_MODEL_SCOPE_SELECTORS), `ScopeId`, or a callable."
        )
        return nothing
    elseif selector isa Function
        return nothing
    end

    error(
        "Invalid scope selector for process `$(process)` at scale `$(scale)`: ",
        "expected `Symbol`, `String`, `ScopeId`, or callable, got `$(typeof(selector))`."
    )
end

function _validate_binding_policy(scale::String, process::Symbol, input_var::Symbol, policy)
    if policy isa DataType
        policy <: SchedulePolicy || error(
            "Invalid policy for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
            "expected a `SchedulePolicy` type or instance, got `$(policy)`."
        )
        p = try
            policy()
        catch
            error(
                "Invalid policy type `$(policy)` for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
                "this policy type cannot be instantiated without arguments. Provide a policy instance instead."
            )
        end
        _validate_policy_instance(scale, process, input_var, p)
        return nothing
    end

    policy isa SchedulePolicy || error(
        "Invalid policy for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
        "expected a `SchedulePolicy` type or instance, got `$(typeof(policy))`."
    )
    _validate_policy_instance(scale, process, input_var, policy)

    return nothing
end

function _validate_binding_target(
    scale::String,
    process::Symbol,
    input_var::Symbol,
    source_process::Symbol,
    source_scale,
    model_specs,
    known_processes::Set{Symbol}
)
    source_process in known_processes || error(
        "Unknown source process `$(source_process)` for input `$(input_var)` in process `$(process)` at scale `$(scale)`."
    )

    isnothing(source_scale) && return nothing
    src_scale = string(source_scale)
    haskey(model_specs, src_scale) || error(
        "Unknown source scale `$(src_scale)` for input `$(input_var)` in process `$(process)` at scale `$(scale)`."
    )
    source_process in keys(model_specs[src_scale]) || error(
        "Source process `$(source_process)` for input `$(input_var)` in process `$(process)` ",
        "is not declared at scale `$(src_scale)`."
    )
    return nothing
end

function _validate_input_binding(
    scale::String,
    process::Symbol,
    input_var::Symbol,
    binding,
    model_specs,
    known_processes::Set{Symbol}
)
    source_process = nothing
    source_scale = nothing
    policy = HoldLast()

    if binding isa Symbol
        source_process = binding
    elseif binding isa Pair{Symbol,Symbol}
        source_process = first(binding)
    elseif binding isa NamedTuple
        extra = setdiff(collect(keys(binding)), collect(_INPUT_BINDING_FIELDS))
        isempty(extra) || error(
            "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
            "unsupported fields $(extra)."
        )
        haskey(binding, :process) || error(
            "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
            "field `process` is required."
        )
        binding.process isa Symbol || error(
            "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
            "`process` must be a Symbol, got `$(typeof(binding.process))`."
        )
        source_process = binding.process

        if haskey(binding, :var)
            isnothing(binding.var) || binding.var isa Symbol || error(
                "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
                "`var` must be a Symbol or `nothing`, got `$(typeof(binding.var))`."
            )
        end

        if haskey(binding, :scale)
            isnothing(binding.scale) || binding.scale isa Symbol || binding.scale isa AbstractString || error(
                "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
                "`scale` must be a Symbol, String or `nothing`, got `$(typeof(binding.scale))`."
            )
            source_scale = binding.scale
        end

        policy = haskey(binding, :policy) ? binding.policy : HoldLast()
    else
        error(
            "Invalid input binding for input `$(input_var)` in process `$(process)` at scale `$(scale)`: ",
            "unsupported binding type `$(typeof(binding))`."
        )
    end

    _validate_binding_policy(scale, process, input_var, policy)
    _validate_binding_target(scale, process, input_var, source_process, source_scale, model_specs, known_processes)
    return nothing
end

function _validate_input_bindings_for_spec(
    scale::String,
    process::Symbol,
    spec::ModelSpec,
    model_specs,
    known_processes::Set{Symbol}
)
    bindings = input_bindings(spec)
    bindings isa NamedTuple || error(
        "InputBindings for process `$(process)` at scale `$(scale)` must be a NamedTuple, got `$(typeof(bindings))`."
    )

    model_inputs = Set(keys(inputs_(model_(spec))))
    for (input_var, binding) in pairs(bindings)
        input_var isa Symbol || error(
            "InputBindings key for process `$(process)` at scale `$(scale)` must be a Symbol, got `$(typeof(input_var))`."
        )
        input_var in model_inputs || error(
            "InputBindings for process `$(process)` at scale `$(scale)` declares binding for input `$(input_var)`, ",
            "but model inputs are $(collect(model_inputs))."
        )
        _validate_input_binding(scale, process, input_var, binding, model_specs, known_processes)
    end
    return nothing
end

function _validate_output_routing_for_spec(scale::String, process::Symbol, spec::ModelSpec)
    routing = output_routing(spec)
    routing isa NamedTuple || error(
        "OutputRouting for process `$(process)` at scale `$(scale)` must be a NamedTuple, got `$(typeof(routing))`."
    )

    model_outputs = Set(keys(outputs_(model_(spec))))
    for (out_var, mode) in pairs(routing)
        out_var isa Symbol || error(
            "OutputRouting key for process `$(process)` at scale `$(scale)` must be a Symbol, got `$(typeof(out_var))`."
        )
        out_var in model_outputs || error(
            "OutputRouting for process `$(process)` at scale `$(scale)` declares routing for output `$(out_var)`, ",
            "but model outputs are $(collect(model_outputs))."
        )

        mode_sym = mode isa Symbol ? mode : (mode isa AbstractString ? Symbol(mode) : nothing)
        isnothing(mode_sym) && error(
            "OutputRouting mode for output `$(out_var)` in process `$(process)` at scale `$(scale)` ",
            "must be `:canonical` or `:stream_only`."
        )
        mode_sym in (:canonical, :stream_only) || error(
            "OutputRouting mode `$(mode_sym)` for output `$(out_var)` in process `$(process)` at scale `$(scale)` ",
            "is invalid. Allowed values: `:canonical`, `:stream_only`."
        )
    end

    return nothing
end

function _validate_meteo_binding(scale::String, process::Symbol, target_var::Symbol, binding)
    if binding isa Function || binding isa PlantMeteo.AbstractTimeReducer
        return nothing
    elseif binding isa DataType
        binding <: PlantMeteo.AbstractTimeReducer || error(
            "Invalid MeteoBindings reducer type for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
            "expected a subtype of `PlantMeteo.AbstractTimeReducer`."
        )
        try
            binding()
        catch
            error(
                "Invalid MeteoBindings reducer type for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
                "type `$(binding)` cannot be instantiated without arguments."
            )
        end
        return nothing
    elseif binding isa NamedTuple
        extra = setdiff(collect(keys(binding)), collect(_METEO_BINDING_FIELDS))
        isempty(extra) || error(
            "Invalid MeteoBindings for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
            "unsupported fields $(extra)."
        )

        if haskey(binding, :source)
            binding.source isa Symbol || binding.source isa AbstractString || error(
                "Invalid MeteoBindings source for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
                "`source` must be a Symbol or String."
            )
        end
        if haskey(binding, :reducer)
            reducer = binding.reducer
            if reducer isa DataType
                reducer <: PlantMeteo.AbstractTimeReducer || error(
                    "Invalid MeteoBindings reducer for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
                    "`reducer` type must subtype `PlantMeteo.AbstractTimeReducer`."
                )
                try
                    reducer()
                catch
                    error(
                        "Invalid MeteoBindings reducer type for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
                        "type `$(reducer)` cannot be instantiated without arguments."
                    )
                end
            else
                (reducer isa PlantMeteo.AbstractTimeReducer || reducer isa Function) || error(
                    "Invalid MeteoBindings reducer for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
                    "`reducer` must be a reducer instance/type or a callable."
                )
            end
        end
        return nothing
    end

    error(
        "Invalid MeteoBindings value for variable `$(target_var)` in process `$(process)` at scale `$(scale)`: ",
        "unsupported type `$(typeof(binding))`."
    )
end
function _validate_meteo_bindings_for_spec(scale::String, process::Symbol, spec::ModelSpec)
    bindings = meteo_bindings(spec)
    bindings isa NamedTuple || error(
        "MeteoBindings for process `$(process)` at scale `$(scale)` must be a NamedTuple, got `$(typeof(bindings))`."
    )

    for (target_var, binding) in pairs(bindings)
        target_var isa Symbol || error(
            "MeteoBindings key for process `$(process)` at scale `$(scale)` must be a Symbol, got `$(typeof(target_var))`."
        )
        _validate_meteo_binding(scale, process, target_var, binding)
    end
    return nothing
end

function _validate_meteo_window_for_spec(scale::String, process::Symbol, spec::ModelSpec)
    window = meteo_window(spec)
    isnothing(window) && return nothing

    window isa PlantMeteo.AbstractSamplingWindow || error(
        "MeteoWindow for process `$(process)` at scale `$(scale)` must be a PlantMeteo sampling-window instance, got `$(typeof(window))`."
    )

    if window isa PlantMeteo.CalendarWindow
        window.period in _CALENDAR_PERIODS || error(
            "Invalid CalendarWindow period `$(window.period)` for process `$(process)` at scale `$(scale)`. ",
            "Allowed values are $(_CALENDAR_PERIODS)."
        )
        window.anchor in _CALENDAR_ANCHORS || error(
            "Invalid CalendarWindow anchor `$(window.anchor)` for process `$(process)` at scale `$(scale)`. ",
            "Allowed values are $(_CALENDAR_ANCHORS)."
        )
        1 <= window.week_start <= 7 || error(
            "Invalid CalendarWindow week_start `$(window.week_start)` for process `$(process)` at scale `$(scale)`. ",
            "Allowed values are integers in 1:7."
        )
        window.completeness in _CALENDAR_COMPLETENESS || error(
            "Invalid CalendarWindow completeness `$(window.completeness)` for process `$(process)` at scale `$(scale)`. ",
            "Allowed values are $(_CALENDAR_COMPLETENESS)."
        )
    end

    return nothing
end

"""
    validate_model_specs_configuration(model_specs)

Validate mapping-level `ModelSpec` configuration before simulation runtime starts.
This catches invalid timestep declarations, input bindings and output routing early.
"""
function validate_model_specs_configuration(model_specs)
    known_processes = Set{Symbol}()
    for specs_at_scale in values(model_specs)
        union!(known_processes, keys(specs_at_scale))
    end

    for (scale, specs_at_scale) in pairs(model_specs)
        for (process, spec) in pairs(specs_at_scale)
            _validate_timestep_spec(scale, process, spec)
            _validate_scope_spec(scale, process, spec)
            _validate_input_bindings_for_spec(scale, process, spec, model_specs, known_processes)
            _validate_meteo_bindings_for_spec(scale, process, spec)
            _validate_meteo_window_for_spec(scale, process, spec)
            _validate_output_routing_for_spec(scale, process, spec)
        end
    end

    return nothing
end
