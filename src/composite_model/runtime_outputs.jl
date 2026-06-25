struct OutputRetentionPlan
    retain_all::Bool
    temporal_dependencies::Set{Tuple{Symbol,Symbol}}
    requested_outputs::Set{Tuple{Symbol,Symbol}}
    dependency_horizons::Dict{Tuple{Symbol,Symbol},Float64}
    retained_application_ids::Set{Symbol}
    retained_outputs_by_application::Dict{Symbol,Vector{Symbol}}
end

"""
    RunContext

Runtime context passed as the final argument to model kernels. Use
`runtime_model`, `call_targets`, and `run_call!` instead of inspecting its
fields.
"""
struct RunContext{CS,A,CT,TS,OR,C}
    compiled::CS
    application::A
    object_id::ObjectId
    calls::CT
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
end

struct CallTarget{CS,EB,A,M,S,TS,OR,C}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::ObjectId
    model::M
    status::S
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
end

"""
    CallTargets <: AbstractVector{CallTarget}

A cached vector-like view of the compiled targets for one declared hard call.
Retrieving it does not allocate a replacement collection. Obtain it with
[`call_targets`](@ref) or as the result of
[`run_call!(::RunContext, ::Symbol)`](@ref).
"""
mutable struct CallTargets{CS,EB,B,TS,OR,C} <: AbstractVector{CallTarget}
    compiled::CS
    environment_bindings::EB
    binding::B
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
end

Base.IndexStyle(::Type{<:CallTargets}) = IndexLinear()
Base.eltype(::Type{<:CallTargets}) = CallTarget

_runtime_call_targets(compiled, environment_bindings, ::Tuple{}, args...) = ()

function _runtime_call_targets(
    compiled,
    environment_bindings,
    bindings::Tuple,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed,
)
    target = CallTargets(
        compiled,
        environment_bindings,
        first(bindings),
        temporal_streams,
        output_retention,
        float(time),
        constants,
        publication_allowed,
    )
    return (
        target,
        _runtime_call_targets(
            compiled,
            environment_bindings,
            Base.tail(bindings),
            temporal_streams,
            output_retention,
            time,
            constants,
            publication_allowed,
        )...,
    )
end

abstract type AbstractExecutionBatch end
struct UnspecifiedModelMeteo end
const _UNSPECIFIED_SCENE_METEO = UnspecifiedModelMeteo()
const _SCENE_RAW_METEO_CACHE_ID = Symbol("#raw_global_meteo")

struct CompiledExecutionTarget{M,S,MB,IB,EB}
    object_id::ObjectId
    model::M
    status::S
    models::MB
    input_bindings::IB
    environment_binding::EB
end

struct CompiledExecutionBatch{A,T<:AbstractVector} <: AbstractExecutionBatch
    application::A
    targets::T
end

struct CompiledExecutionPlan{B}
    batches::B
    model_revision::Int
    environment_revision::Int
end

"""
    Simulation

Result of running a [`CompositeModel`](@ref). Use `outputs`, `collect_outputs`,
and the explanation helpers to inspect it.
"""
mutable struct Simulation{S,CS,EB,EP,OR,TS,R,RT,C}
    model::S
    compiled::CS
    environment_bindings::EB
    execution_plan::EP
    output_retention::OR
    temporal_streams::TS
    output_requests::R
    output_request_targets::RT
    current_step::Int
    constants::C
end

"""
    runtime_model(runtime)

Return the live [`CompositeModel`](@ref) owned by a `CompositeModel`, [`RunContext`](@ref),
or [`Simulation`](@ref). Lifecycle-capable models should call this
accessor instead of reaching through runtime implementation fields.
"""
runtime_model(model::CompositeModel) = model
runtime_model(context::RunContext) = context.compiled.model
runtime_model(simulation::Simulation) = simulation.model
current_step(simulation::Simulation) = simulation.current_step

outputs(sim::Simulation) = sim.temporal_streams

# Diagnostics accept the live simulation handle without exposing its compiled
# representation. Views concerning topology and initialization use the current
# model; compiled views use the simulation's current compiled state.
explain_objects(sim::Simulation) = explain_objects(sim.model)
explain_instances(sim::Simulation) = explain_instances(sim.model)
explain_scopes(sim::Simulation) = explain_scopes(sim.model)
explain_initialization(sim::Simulation) = explain_initialization(sim.model)
explain_applications(sim::Simulation) = explain_applications(sim.compiled)
explain_schedule(sim::Simulation) = explain_schedule(sim.compiled)
explain_bindings(sim::Simulation) = explain_bindings(sim.compiled)
explain_calls(sim::Simulation) = explain_calls(sim.compiled)
explain_model_bundles(sim::Simulation) = explain_model_bundles(sim.compiled)
explain_writers(sim::Simulation) = explain_writers(sim.compiled)
explain_environment_bindings(sim::Simulation) =
    explain_environment_bindings(sim.environment_bindings)

function _compiled_application_by_id(compiled::CompiledCompositeModel, id::Symbol)
    application = get(compiled.applications_by_id, id, nothing)
    isnothing(application) && error("No compiled model application with id `$(id)`.")
    return application
end

function _environment_binding_for(env_bindings::CompiledEnvironmentBindings, application_id::Symbol, object_id::ObjectId)
    return get(env_bindings.by_target, (application_id, object_id), nothing)
end

function _model_object_status(model::CompositeModel, object_id::ObjectId)
    object = _model_object(model, object_id)
    object.status isa Status || error(
        "CompositeModel object `$(object_id.value)` has no `Status`; model runtime requires status-backed objects."
    )
    return object.status
end

function _set_status_if_present!(status::Status, variable::Symbol, value)
    variable in propertynames(status) || error(
        "Cannot materialize input `$(variable)` because consumer status has no such variable."
    )
    status[variable] = value
    return status
end

_model_stream_key(application_id::Symbol, object_id::ObjectId, variable::Symbol) =
    (application_id, object_id, variable)

function _model_retain_output(
    retention::OutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
)
    retention.retain_all && return true
    key = (application_id, variable)
    return key in retention.temporal_dependencies ||
           key in retention.requested_outputs
end

function _model_retain_application(
    retention::OutputRetentionPlan,
    application_id::Symbol,
)
    return retention.retain_all || application_id in retention.retained_application_ids
end

_model_retain_application(::Nothing, application_id::Symbol) = true

_model_retain_output(::Nothing, application_id::Symbol, variable::Symbol) = true

function _model_prune_dependency_stream!(
    samples,
    retention::OutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
    time::Real,
)
    retention.retain_all && return samples
    key = (application_id, variable)
    key in retention.requested_outputs && return samples
    key in retention.temporal_dependencies || return samples
    horizon = get(retention.dependency_horizons, key, 0.0)
    if horizon <= 0.0
        length(samples) > 1 && deleteat!(samples, 1:(length(samples) - 1))
        return samples
    end
    cutoff = float(time) - horizon + 1.0
    filter!(sample -> sample[1] >= cutoff - 1.0e-8, samples)
    return samples
end

_model_prune_dependency_stream!(samples, ::Nothing, application_id, variable, time) =
    samples

function _model_publish_outputs!(
    streams,
    application::CompiledModelApplication,
    object_id::ObjectId,
    status,
    time::Real,
    retention=nothing,
    retained_variables=nothing,
)
    isnothing(streams) && return nothing
    _model_retain_application(retention, application.id) || return nothing
    variables = isnothing(retained_variables) ? keys(outputs_(application.spec)) : retained_variables
    for variable in variables
        var = Symbol(variable)
        isnothing(retained_variables) &&
            !_model_retain_output(retention, application.id, var) && continue
        hasproperty(status, var) || error(
            "Application `$(application.id)` declares output `$(var)`, but object ",
            "`$(object_id.value)` status has no such variable."
        )
        key = _model_stream_key(application.id, object_id, var)
        value = getproperty(status, var)
        samples = get(streams, key, nothing)
        if isnothing(samples)
            samples = Tuple{Float64,typeof(value)}[]
            streams[key] = samples
        elseif !(value isa fieldtype(eltype(samples), 2))
            error(
                "Output `$(application.id).$(var)` on object `$(object_id.value)` changed ",
                "value type from `$(fieldtype(eltype(samples), 2))` to `$(typeof(value))`. ",
                "CompositeModel temporal streams require a stable output type."
            )
        end
        sample_time = float(time)
        if !isempty(samples) &&
           isapprox(last(samples)[1], sample_time; atol=1.0e-8, rtol=0.0)
            pop!(samples)
        elseif !isempty(samples) && last(samples)[1] > sample_time
            filter!(
                sample -> !isapprox(sample[1], sample_time; atol=1.0e-8, rtol=0.0),
                samples,
            )
        end
        push!(samples, (sample_time, value))
        _model_prune_dependency_stream!(
            samples,
            retention,
            application.id,
            var,
            time,
        )
    end
    return nothing
end

function _model_latest_sample(samples, time::Real)
    requested_time = float(time)
    for index in reverse(eachindex(samples))
        sample_t, value = samples[index]
        sample_t <= requested_time && return value
    end
    return nothing
end

function _model_linear_value(v_left, v_right, α)
    applicable(-, v_right, v_left) || return nothing
    delta = v_right - v_left
    increment = if applicable(*, α, delta)
        α * delta
    elseif applicable(*, delta, α)
        delta * α
    else
        return nothing
    end
    applicable(+, v_left, increment) || return nothing
    return v_left + increment
end

function _model_sample_last_le(samples, time::Real)
    low = firstindex(samples)
    high = lastindex(samples)
    found = nothing
    while low <= high
        middle = low + ((high - low) >>> 1)
        if samples[middle][1] <= time
            found = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return found
end

function _model_sample_first_ge(samples, time::Real)
    low = firstindex(samples)
    high = lastindex(samples)
    found = nothing
    while low <= high
        middle = low + ((high - low) >>> 1)
        if samples[middle][1] >= time
            found = middle
            high = middle - 1
        else
            low = middle + 1
        end
    end
    return found
end

function _model_interpolated_sample(samples, time::Real, policy::Interpolate)
    isempty(samples) && return nothing
    t = float(time)
    prev_idx = _model_sample_last_le(samples, t + 1.0e-8)
    next_idx = _model_sample_first_ge(samples, t - 1.0e-8)

    if !isnothing(prev_idx) && !isnothing(next_idx)
        t_prev, v_prev = samples[prev_idx]
        t_next, v_next = samples[next_idx]
        isapprox(t_prev, t_next; atol=1.0e-8, rtol=0.0) && return v_prev
        policy.mode == :hold && return v_prev
        α = (t - t_prev) / (t_next - t_prev)
        interpolated = _model_linear_value(v_prev, v_next, α)
        return isnothing(interpolated) ? v_prev : interpolated
    end

    if !isnothing(prev_idx)
        t_last, v_last = samples[prev_idx]
        if policy.extrapolation == :linear && prev_idx >= 2
            t_prev, v_prev = samples[prev_idx - 1]
            if !isapprox(t_last, t_prev; atol=1.0e-8, rtol=0.0)
                α = (t - t_last) / (t_last - t_prev)
                extrapolated = _model_linear_value(v_prev, v_last, one(α) + α)
                !isnothing(extrapolated) && return extrapolated
            end
        end
        return v_last
    end

    return first(samples)[2]
end

function _model_window_segments(samples, t_start::Real, t_end::Real, base_step_seconds::Real)
    value_type = fieldtype(eltype(samples), 2)
    isempty(samples) && return (value_type[], Float64[])
    window_start = float(t_start)
    window_stop = float(t_end) + 1.0
    first_index = findlast(sample -> sample[1] < window_start, samples)
    first_index = isnothing(first_index) ? firstindex(samples) : first_index

    values = value_type[]
    durations = Float64[]
    for index in first_index:lastindex(samples)
        sample_t, value = samples[index]
        sample_t >= window_stop && break
        next_t = index == lastindex(samples) ? window_stop : samples[index + 1][1]
        segment_start = max(float(sample_t), window_start)
        segment_stop = min(float(next_t), window_stop)
        segment_stop > segment_start || continue
        push!(values, value)
        push!(durations, (segment_stop - segment_start) * float(base_step_seconds))
    end
    return values, durations
end

function _model_window_reduce(values, durations, policy)
    isempty(values) && return 0.0
    reducer = policy isa Integrate ? policy.reducer : (policy isa Aggregate ? policy.reducer : PlantMeteo.SumReducer())
    f = _normalize_policy_reducer(reducer)
    applicable(f, values, durations) && return f(values, durations)
    applicable(f, values) && return f(values)
    reducer isa PlantMeteo.SumReducer && return sum(values)
    reducer isa PlantMeteo.MeanReducer && return Statistics.mean(values)
    reducer isa PlantMeteo.MinReducer && return minimum(values)
    reducer isa PlantMeteo.MaxReducer && return maximum(values)
    reducer isa PlantMeteo.FirstReducer && return first(values)
    reducer isa PlantMeteo.LastReducer && return last(values)
    error(
        "Reducer `$(reducer)` is not callable on model temporal input values for policy ",
        "`$(typeof(policy))`. Expected `(values)` or `(values, durations_seconds)`."
    )
end

function _model_duration_steps(duration, timeline)
    if duration isa Dates.Period || duration isa Dates.CompoundPeriod || duration isa Real
        seconds = _duration_to_seconds(duration)
        isnothing(seconds) && return nothing
        steps = seconds / timeline.base_step_seconds
        steps >= 1.0 || error(
            "Input window `$(duration)` is shorter than the model base step ",
            "($(timeline.base_step_seconds) seconds)."
        )
        return steps
    end
    return nothing
end

function _model_input_window_steps(binding::CompiledModelInputBinding, application::CompiledModelApplication, timeline)
    explicit = _model_duration_steps(binding.window, timeline)
    !isnothing(explicit) && return explicit
    binding.policy isa Union{Integrate,Aggregate} && return float(application.clock.dt)
    return 1.0
end

function _model_temporal_source_value(
    streams,
    application_id::Symbol,
    source_id::ObjectId,
    source_var::Symbol,
    time::Real,
    policy,
    t_start::Real,
    timeline,
)
    samples = get(streams, _model_stream_key(application_id, source_id, source_var), nothing)
    isnothing(samples) && return policy isa Union{Integrate,Aggregate} ? 0.0 : nothing
    if policy isa HoldLast
        return _model_latest_sample(samples, time)
    elseif policy isa PreviousTimeStep
        return _model_latest_sample(samples, float(time) - 1.0)
    elseif policy isa Union{Integrate,Aggregate}
        values, durations = _model_window_segments(
            samples,
            t_start,
            time,
            timeline.base_step_seconds,
        )
        return _model_window_reduce(values, durations, policy)
    elseif policy isa Interpolate
        return _model_interpolated_sample(samples, time, policy)
    end
    error("Unsupported model temporal input policy `$(typeof(policy))`.")
end

function _model_temporal_source_value(
    streams,
    application_id::Nothing,
    source_id::ObjectId,
    source_var::Symbol,
    time::Real,
    policy,
    t_start::Real,
    timeline,
)
    policy isa PreviousTimeStep && return nothing
    error(
        "Temporal model input from `$(source_id.value).$(source_var)` has no ",
        "source application for policy `$(typeof(policy))`."
    )
end

function _model_temporal_source_application(compiled::CompiledCompositeModel, binding::CompiledModelInputBinding, source_id::ObjectId)
    if binding.policy isa PreviousTimeStep && isempty(binding.source_application_ids)
        return nothing
    end
    isempty(binding.source_application_ids) && error(
        "Temporal model input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
        "has no resolved source application. Name the producer and add " *
        "`application=...` to `Inputs(...)`."
    )
    length(binding.source_application_ids) == 1 &&
        return only(binding.source_application_ids)
    matches = Symbol[
        application_id for application_id in binding.source_application_ids
        if source_id in _compiled_application_by_id(compiled, application_id).target_ids
    ]
    if length(matches) == 1
        return only(matches)
    elseif isempty(matches)
        binding.policy isa PreviousTimeStep && return nothing
        error(
            "Temporal model input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
            "has no source application matching object `$(source_id.value)`."
        )
    end
    if binding.policy isa PreviousTimeStep
        positions = Dict(application_id => index for (index, application_id) in pairs(compiled.application_order))
        return last(sort(matches; by=application_id -> get(positions, application_id, 0)))
    end
    error(
        "Temporal model input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
        "has ambiguous source applications `$(matches)`. Add `application=...` to `Inputs(...)`."
    )
end

function _model_temporal_input_value(
    compiled::CompiledCompositeModel,
    binding::CompiledModelInputBinding,
    application::CompiledModelApplication,
    status::Status,
    streams,
    time::Real,
    timeline,
)
    window_steps = _model_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    initial = _input_value(binding.carrier)
    isnothing(initial) && (initial = status[binding.input])
    if binding.multiplicity == :many
        values = [
            _model_temporal_source_value(
                streams,
                _model_temporal_source_application(compiled, binding, source_id),
                source_id,
                binding.source_var,
                time,
                binding.policy,
                t_start,
                timeline,
            )
            for source_id in binding.source_ids
        ]
        if binding.policy isa PreviousTimeStep
            initial_values = initial isa AbstractVector ? initial : ()
            return [
                isnothing(value) && index <= length(initial_values) ? initial_values[index] : value
                for (index, value) in pairs(values)
            ]
        end
        return values
    end
    source_id = only(binding.source_ids)
    value = _model_temporal_source_value(
        streams,
        _model_temporal_source_application(compiled, binding, source_id),
        source_id,
        binding.source_var,
        time,
        binding.policy,
        t_start,
        timeline,
    )
    isnothing(value) && binding.policy isa PreviousTimeStep && return initial
    isnothing(value) && error(
        "No temporal model value available for input `$(binding.input)` from ",
        "`$(source_id.value).$(binding.source_var)` at t=$(time)."
    )
    return value
end

function _model_temporal_input_value(
    compiled::CompiledCompositeModel,
    binding::CompiledModelInputBinding,
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
)
    status = _model_object_status(compiled.model, binding.consumer_id)
    return _model_temporal_input_value(
        compiled,
        binding,
        application,
        status,
        streams,
        time,
        timeline,
    )
end

function _model_assign_input_value!(status::Status, variable::Symbol, value)
    variable in propertynames(status) || error(
        "Cannot materialize input `$(variable)` because consumer status has no such variable."
    )
    current = status[variable]
    if current isa RefVector && value isa AbstractVector
        length(current) != length(value) && resize!(current, length(value))
        for i in eachindex(value)
            current[i] = value[i]
        end
        return status
    end
    status[variable] = value
    return status
end

function _materialize_model_inputs!(
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    streams=nothing,
    time::Real=1,
)
    status = _model_object_status(compiled.model, object_id)
    bindings = get(compiled.input_bindings_by_target, (application.id, object_id), ())
    timeline = nothing
    for binding in bindings
        if binding.carrier_hint == :temporal_stream
            isnothing(streams) && continue
            isnothing(timeline) && (timeline = compiled.timeline)
            value = _model_temporal_input_value(
                compiled,
                binding,
                application,
                status,
                streams,
                time,
                timeline,
            )
            _model_assign_input_value!(status, binding.input, value)
        end
    end
    return status
end

function _materialize_model_inputs!(
    status::Status,
    bindings::Tuple,
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    streams=nothing,
    time::Real=1,
)
    timeline = nothing
    for binding in bindings
        if binding.carrier_hint == :temporal_stream
            isnothing(streams) && continue
            isnothing(timeline) && (timeline = compiled.timeline)
            value = _model_temporal_input_value(
                compiled,
                binding,
                application,
                status,
                streams,
                time,
                timeline,
            )
            _model_assign_input_value!(status, binding.input, value)
        end
    end
    return status
end

function _model_meteo_for_model(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    time::Real,
)
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _model_meteo_for_binding(env_bindings, application, binding, time)
end

function _model_meteo_for_binding(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    binding,
    time::Real,
)
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    if binding.backend isa GlobalConstant
        step = Int(round(time))
        key = (application.id, step)
        haskey(env_bindings.sample_cache, key) &&
            return env_bindings.sample_cache[key]
        raw_key = (_SCENE_RAW_METEO_CACHE_ID, step)
        raw_row = get!(env_bindings.sample_cache, raw_key) do
            _meteo_row_at_step(environment_meteo(binding.backend), step)
        end
        sampler = get(env_bindings.samplers_by_application, application.id, nothing)
        if !isnothing(sampler)
            sampled = _sample_meteo_for_model(
                sampler,
                raw_row,
                step,
                application.clock,
                application.spec,
            )
            env_bindings.sample_cache[key] = sampled
            return sampled
        end
        bindings = meteo_bindings(application.spec)
        has_bindings = bindings isa NamedTuple && !isempty(keys(bindings))
        environment_sources = _environment_source_overrides(application.spec)
        if !has_bindings && isempty(keys(environment_sources))
            env_bindings.sample_cache[key] = raw_row
            return raw_row
        end
        sampled = sample_environment(
            binding.backend,
            binding.support,
            time,
            application.spec,
        )
        env_bindings.sample_cache[key] = sampled
        return sampled
    end
    return sample_environment(binding.backend, binding.support, time, application.spec)
end

function _scatter_model_environment_outputs!(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    status,
    time::Real,
)
    isempty(keys(meteo_outputs_(application.spec))) && return nothing
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _scatter_model_environment_outputs!(
        application,
        binding,
        status,
        time,
    )
end

function _scatter_model_environment_outputs!(
    application::CompiledModelApplication,
    binding,
    status,
    time::Real,
)
    isempty(keys(meteo_outputs_(application.spec))) && return nothing
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    return scatter_environment_outputs!(binding.backend, binding.support, time, application.spec, status)
end

function _push_model_model_entry!(pairs, names::Set{Symbol}, name::Symbol, model)
    name in names && return nothing
    push!(pairs, name => model)
    push!(names, name)
    return nothing
end

function _append_model_model_dependencies!(
    pairs,
    names::Set{Symbol},
    applications_by_id,
    call_bindings_by_target,
    application::CompiledModelApplication,
    object_id::ObjectId,
    seen::Set{Tuple{Symbol,ObjectId}},
)
    key = (application.id, object_id)
    key in seen && return nothing
    push!(seen, key)
    _push_model_model_entry!(
        pairs,
        names,
        application.process,
        _application_model(application, object_id),
    )
    bindings = get(call_bindings_by_target, key, ())
    for binding in bindings
        for application_id in binding.callee_application_ids
            callee_application = get(applications_by_id, application_id, nothing)
            isnothing(callee_application) && error(
                "No compiled model application with id `$(application_id)`."
            )
            matching_object_ids = ObjectId[
                callee_object_id for callee_object_id in binding.callee_object_ids
                if callee_object_id in callee_application.target_ids
            ]
            # Old-style hard-dependency kernels expect one model object per
            # process field. Multi-object model calls are exposed through
            # `call_targets(extra, name)` instead.
            length(matching_object_ids) == 1 || continue
            _append_model_model_dependencies!(
                pairs,
                names,
                applications_by_id,
                call_bindings_by_target,
                callee_application,
                only(matching_object_ids),
                seen,
            )
        end
    end
    return nothing
end

function _compile_model_model_bundle(
    applications_by_id,
    call_bindings_by_target,
    application::CompiledModelApplication,
    object_id::ObjectId,
)
    pairs = Pair{Symbol,Any}[]
    names = Set{Symbol}()
    seen = Set{Tuple{Symbol,ObjectId}}()
    _append_model_model_dependencies!(
        pairs,
        names,
        applications_by_id,
        call_bindings_by_target,
        application,
        object_id,
        seen,
    )
    return NamedTuple{Tuple(first(pair) for pair in pairs)}(Tuple(last(pair) for pair in pairs))
end

function _compile_model_model_bundles(applications, applications_by_id, call_bindings_by_target)
    bundles = Dict{Tuple{Symbol,ObjectId},Any}()
    for application in applications
        for object_id in application.target_ids
            bundles[(application.id, object_id)] = _compile_model_model_bundle(
                applications_by_id,
                call_bindings_by_target,
                application,
                object_id,
            )
        end
    end
    return bundles
end

function _model_models_for_application(
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
)
    key = (application.id, object_id)
    models = get(compiled.model_bundles_by_target, key, nothing)
    isnothing(models) && error(
        "No compiled model bundle for application `$(application.id)` on object `$(object_id.value)`."
    )
    return models
end

@inline function _run_model_application_with_calls!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    status,
    meteo_value,
    calls,
    time,
    constants,
    temporal_streams,
    output_retention,
    publish::Bool,
)
    context = RunContext(
        compiled,
        application,
        object_id,
        calls,
        temporal_streams,
        output_retention,
        float(time),
        constants,
        publish,
    )
    model = _application_model(application, object_id)
    models = _model_models_for_application(compiled, application, object_id)
    run!(model, models, status, meteo_value, constants, context)
    if publish
        _scatter_model_environment_outputs!(env_bindings, application, object_id, status, time)
        _model_publish_outputs!(
            temporal_streams,
            application,
            object_id,
            status,
            time,
            output_retention,
        )
    end
    return status
end

function _run_model_application!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
    publish::Bool=true,
    meteo=nothing,
)
    status = _materialize_model_inputs!(compiled, application, object_id, temporal_streams, time)
    meteo_value = isnothing(meteo) ? _model_meteo_for_model(env_bindings, application, object_id, time) : meteo
    if isempty(compiled.call_bindings)
        return _run_model_application_with_calls!(
            compiled,
            env_bindings,
            application,
            object_id,
            status,
            meteo_value,
            (),
            time,
            constants,
            temporal_streams,
            output_retention,
            publish,
        )
    end
    call_bindings = get(
        compiled.call_bindings_by_target,
        (application.id, object_id),
        (),
    )
    calls = _runtime_call_targets(
        compiled,
        env_bindings,
        call_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        publish,
    )
    return _run_model_application_with_calls!(
        compiled,
        env_bindings,
        application,
        object_id,
        status,
        meteo_value,
        calls,
        time,
        constants,
        temporal_streams,
        output_retention,
        publish,
    )
end

function _run_model_execution_target_without_calls!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
    meteo=_UNSPECIFIED_SCENE_METEO,
    publish_outputs::Bool=true,
    scatter_outputs::Bool=true,
    retained_outputs=nothing,
)
    status = isempty(target.input_bindings) ?
             target.status :
             _materialize_model_inputs!(
        target.status,
        target.input_bindings,
        compiled,
        application,
        temporal_streams,
        time,
    )
    meteo_value = meteo isa UnspecifiedModelMeteo ?
                  _model_meteo_for_binding(
        env_bindings,
        application,
        target.environment_binding,
        time,
    ) : meteo
    context = RunContext(
        compiled,
        application,
        target.object_id,
        (),
        temporal_streams,
        output_retention,
        float(time),
        constants,
        true,
    )
    run!(target.model, target.models, status, meteo_value, constants, context)
    scatter_outputs && _scatter_model_environment_outputs!(
        application,
        target.environment_binding,
        status,
        time,
    )
    publish_outputs && _model_publish_outputs!(
        temporal_streams,
        application,
        target.object_id,
        status,
        time,
        output_retention,
        retained_outputs,
    )
    return status
end

function _run_model_execution_target!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
    meteo=_UNSPECIFIED_SCENE_METEO,
    publish_outputs::Bool=true,
    scatter_outputs::Bool=true,
    retained_outputs=nothing,
)
    isempty(compiled.call_bindings) && return _run_model_execution_target_without_calls!(
        compiled,
        env_bindings,
        application,
        target;
        time=time,
        constants=constants,
        temporal_streams=temporal_streams,
        output_retention=output_retention,
        meteo=meteo,
        publish_outputs=publish_outputs,
        scatter_outputs=scatter_outputs,
        retained_outputs=retained_outputs,
    )
    status = isempty(target.input_bindings) ?
             target.status :
             _materialize_model_inputs!(
        target.status,
        target.input_bindings,
        compiled,
        application,
        temporal_streams,
        time,
    )
    meteo_value = meteo isa UnspecifiedModelMeteo ?
                  _model_meteo_for_binding(
        env_bindings,
        application,
        target.environment_binding,
        time,
    ) : meteo
    call_bindings = get(
        compiled.call_bindings_by_target,
        (application.id, target.object_id),
        (),
    )
    calls = _runtime_call_targets(
        compiled,
        env_bindings,
        call_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        true,
    )
    context = RunContext(
        compiled,
        application,
        target.object_id,
        calls,
        temporal_streams,
        output_retention,
        float(time),
        constants,
        true,
    )
    run!(target.model, target.models, status, meteo_value, constants, context)
    scatter_outputs && _scatter_model_environment_outputs!(
        application,
        target.environment_binding,
        status,
        time,
    )
    publish_outputs && _model_publish_outputs!(
        temporal_streams,
        application,
        target.object_id,
        status,
        time,
        output_retention,
        retained_outputs,
    )
    return status
end

function _run_model_execution_batch!(
    batch::CompiledExecutionBatch,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
)
    _model_application_should_run(batch.application, time) || return nothing
    shared_meteo = if !isempty(batch.targets) &&
                      !isnothing(first(batch.targets).environment_binding) &&
                      first(batch.targets).environment_binding.backend isa GlobalConstant
        _model_meteo_for_binding(
            env_bindings,
            batch.application,
            first(batch.targets).environment_binding,
            time,
        )
    else
        _UNSPECIFIED_SCENE_METEO
    end
    publish_outputs = _model_retain_application(output_retention, batch.application.id)
    scatter_outputs = !isempty(keys(meteo_outputs_(batch.application.spec)))
    retained_outputs = output_retention isa OutputRetentionPlan ?
                       get(
        output_retention.retained_outputs_by_application,
        batch.application.id,
        (),
    ) : nothing
    if isempty(compiled.call_bindings)
        for target in batch.targets
            _run_model_execution_target_without_calls!(
                compiled,
                env_bindings,
                batch.application,
                target;
                time=time,
                constants=constants,
                temporal_streams=temporal_streams,
                output_retention=output_retention,
                meteo=shared_meteo,
                publish_outputs=publish_outputs,
                scatter_outputs=scatter_outputs,
                retained_outputs=retained_outputs,
            )
        end
        return nothing
    end
    for target in batch.targets
        _run_model_execution_target!(
            compiled,
            env_bindings,
            batch.application,
            target;
            time=time,
            constants=constants,
            temporal_streams=temporal_streams,
            output_retention=output_retention,
            meteo=shared_meteo,
            publish_outputs=publish_outputs,
            scatter_outputs=scatter_outputs,
            retained_outputs=retained_outputs,
        )
    end
    return nothing
end

_model_application_should_run(application::CompiledModelApplication, t::Real) =
    _should_run_at_time(application.clock, float(t))

function _manual_call_application_ids(compiled::CompiledCompositeModel)
    ids = Set{Symbol}()
    for binding in compiled.call_bindings
        union!(ids, binding.callee_application_ids)
    end
    return ids
end

function _compiled_model_execution_target(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
)
    status = _model_object_status(compiled.model, object_id)
    model = _application_model(application, object_id)
    models = _model_models_for_application(compiled, application, object_id)
    input_bindings = get(
        compiled.input_bindings_by_target,
        (application.id, object_id),
        (),
    )
    temporal_input_bindings = Tuple(
        binding for binding in input_bindings
        if binding.carrier_hint == :temporal_stream
    )
    environment_binding = _environment_binding_for(
        env_bindings,
        application.id,
        object_id,
    )
    return CompiledExecutionTarget(
        object_id,
        model,
        status,
        models,
        temporal_input_bindings,
        environment_binding,
    )
end

function _typed_model_execution_targets(targets, first_index::Int, last_index::Int)
    target_type = typeof(targets[first_index])
    typed = Vector{target_type}(undef, last_index - first_index + 1)
    for (destination, source) in enumerate(first_index:last_index)
        typed[destination] = targets[source]
    end
    return typed
end

function _append_model_execution_batches!(
    batches,
    application::CompiledModelApplication,
    targets,
)
    isempty(targets) && return batches
    first_index = firstindex(targets)
    target_type = typeof(targets[first_index])
    for index in (first_index + 1):lastindex(targets)
        typeof(targets[index]) == target_type && continue
        push!(
            batches,
            CompiledExecutionBatch(
                application,
                _typed_model_execution_targets(targets, first_index, index - 1),
            ),
        )
        first_index = index
        target_type = typeof(targets[index])
    end
    push!(
        batches,
        CompiledExecutionBatch(
            application,
            _typed_model_execution_targets(targets, first_index, lastindex(targets)),
        ),
    )
    return batches
end

function compile_model_execution_plan(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
)
    manual_application_ids = _manual_call_application_ids(compiled)
    batches = AbstractExecutionBatch[]
    for application in _ordered_model_applications(compiled)
        application.id in manual_application_ids && continue
        targets = Any[
            _compiled_model_execution_target(
                compiled,
                env_bindings,
                application,
                object_id,
            )
            for object_id in application.target_ids
        ]
        _append_model_execution_batches!(batches, application, targets)
    end
    return CompiledExecutionPlan(
        batches,
        compiled.revision,
        env_bindings.environment_revision,
    )
end

function _extend_model_execution_plan(
    plan::CompiledExecutionPlan,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    added_object_ids,
)
    added = Set(added_object_ids)
    manual_application_ids = _manual_call_application_ids(compiled)
    for application in _ordered_model_applications(compiled)
        application.id in manual_application_ids && continue
        for object_id in application.target_ids
            object_id in added || continue
            target = _compiled_model_execution_target(
                compiled,
                env_bindings,
                application,
                object_id,
            )
            batch_index = findfirst(plan.batches) do batch
                batch.application.id == application.id && eltype(batch.targets) === typeof(target)
            end
            isnothing(batch_index) && return compile_model_execution_plan(compiled, env_bindings)
            push!(plan.batches[batch_index].targets, target)
        end
    end
    return CompiledExecutionPlan(
        plan.batches,
        compiled.revision,
        env_bindings.environment_revision,
    )
end

function explain_execution_plan(plan::CompiledExecutionPlan)
    return [
        (
            batch_index=index,
            application_id=batch.application.id,
            process=batch.application.process,
            object_ids=[target.object_id.value for target in batch.targets],
            batch_size=length(batch.targets),
            target_type=eltype(batch.targets),
            model_type=fieldtype(eltype(batch.targets), :model),
            status_type=fieldtype(eltype(batch.targets), :status),
            model_bundle_type=fieldtype(eltype(batch.targets), :models),
            input_bindings_type=fieldtype(eltype(batch.targets), :input_bindings),
            environment_binding_type=fieldtype(
                eltype(batch.targets),
                :environment_binding,
            ),
            inner_loop_dispatch=:concrete_homogeneous_batch,
        )
        for (index, batch) in pairs(plan.batches)
    ]
end

function explain_execution_plan(sim::Simulation)
    return explain_execution_plan(sim.execution_plan)
end

function explain_execution_plan(model::CompositeModel)
    compiled = refresh_bindings!(model)
    environment_bindings = refresh_environment_bindings!(model, compiled)
    return explain_execution_plan(
        compile_model_execution_plan(compiled, environment_bindings),
    )
end

function compile_model_output_retention(
    compiled::CompiledCompositeModel,
    output_requests;
    retain_all::Bool=false,
)
    temporal_dependencies = Set{Tuple{Symbol,Symbol}}()
    dependency_horizons = Dict{Tuple{Symbol,Symbol},Float64}()
    timeline = compiled.timeline
    for binding in compiled.input_bindings
        binding.carrier_hint == :temporal_stream || continue
        consumer = _compiled_application_by_id(compiled, binding.application_id)
        window_steps = _model_input_window_steps(binding, consumer, timeline)
        for application_id in binding.source_application_ids
            source = _compiled_application_by_id(compiled, application_id)
            required = if binding.policy isa Union{Integrate,Aggregate}
                float(window_steps) + max(0.0, float(source.clock.dt) - 1.0)
            elseif binding.policy isa Union{Interpolate,PreviousTimeStep}
                max(2.0, float(source.clock.dt) + 1.0)
            else
                0.0
            end
            key = (application_id, binding.source_var)
            push!(
                temporal_dependencies,
                key,
            )
            dependency_horizons[key] = max(
                get(dependency_horizons, key, 0.0),
                required,
            )
        end
    end

    requested_outputs = Set{Tuple{Symbol,Symbol}}()
    names = Set{Symbol}()
    for request in output_requests
        request.name in names && error(
            "Duplicate output request name `$(request.name)`. Request names must be unique."
        )
        push!(names, request.name)
        application = _model_request_application(
            compiled.model,
            compiled,
            request,
        )
        push!(requested_outputs, (application.id, request.var))
    end
    retained_outputs_by_application = Dict{Symbol,Vector{Symbol}}()
    retained_keys = if retain_all
        Set(
            (application.id, Symbol(variable))
            for application in compiled.applications
            for variable in keys(outputs_(application.spec))
        )
    else
        union(temporal_dependencies, requested_outputs)
    end
    for (application_id, variable) in retained_keys
        push!(
            get!(retained_outputs_by_application, application_id, Symbol[]),
            variable,
        )
    end
    for variables in values(retained_outputs_by_application)
        sort!(variables; by=string)
    end
    return OutputRetentionPlan(
        retain_all,
        temporal_dependencies,
        requested_outputs,
        dependency_horizons,
        Set{Symbol}(
            application_id
            for (application_id, _) in union(
                temporal_dependencies,
                requested_outputs,
            )
        ),
        retained_outputs_by_application,
    )
end

function _explain_output_retention(compiled::CompiledCompositeModel, plan)
    keys_to_explain = if plan.retain_all
        Set(
            (application.id, Symbol(variable))
            for application in compiled.applications
            for variable in keys(outputs_(application.spec))
        )
    else
        union(plan.temporal_dependencies, plan.requested_outputs)
    end
    return [
        (
            application_id=application_id,
            variable=variable,
            reasons=plan.retain_all ?
                    (:all_outputs,) :
                    Tuple(
                        reason for (reason, keys) in (
                            :temporal_dependency => plan.temporal_dependencies,
                            :output_request => plan.requested_outputs,
                        )
                        if (application_id, variable) in keys
                    ),
            retention_steps=plan.retain_all ||
                            (application_id, variable) in plan.requested_outputs ?
                            nothing :
                            get(
                                plan.dependency_horizons,
                                (application_id, variable),
                                0.0,
                            ),
            current_target_count=length(
                _compiled_application_by_id(
                    compiled,
                    application_id,
                ).target_ids,
            ),
        )
        for (application_id, variable) in sort!(
            collect(keys_to_explain);
            by=key -> (string(first(key)), string(last(key))),
        )
    ]
end


function explain_output_retention(sim::Simulation)
    return _explain_output_retention(sim.compiled, sim.output_retention)
end

function explain_output_retention(model::CompositeModel; outputs=:none)
    compiled = refresh_bindings!(model)
    output_requests, retain_all = _model_output_selection(
        outputs,
        _UNSPECIFIED_SCENE_OUTPUTS,
    )
    plan = compile_model_output_retention(
        compiled,
        output_requests;
        retain_all=retain_all,
    )
    return _explain_output_retention(compiled, plan)
end

@inline _find_call_targets(::Tuple{}, ::Val) = nothing

@inline function _find_call_targets(calls::Tuple, ::Val{name}) where {name}
    targets = first(calls)
    _compiled_call_name(targets.binding) === name && return targets
    return _find_call_targets(Base.tail(calls), Val(name))
end

Base.@constprop :aggressive function _model_call_targets(
    context::RunContext,
    name::Symbol,
)
    found = _find_call_targets(context.calls, Val(name))
    if isnothing(found)
        available = Symbol[targets.binding.call for targets in context.calls]
        error(
            "Application `$(context.application.id)` on object ",
            "`$(context.object_id.value)` did not declare call `$(name)`. ",
            "Declared calls: $(available).",
        )
    end
    return found
end

function _call_target_matches(targets::CallTargets, application, object_id::ObjectId)
    binding = targets.binding
    return (binding.multiplicity != :many &&
            length(binding.callee_application_ids) == 1) ||
           object_id in application.target_ids
end

function Base.length(targets::CallTargets)
    count = 0
    for application_id in targets.binding.callee_application_ids
        application = _compiled_application_by_id(targets.compiled, application_id)
        for object_id in targets.binding.callee_object_ids
            _call_target_matches(targets, application, object_id) && (count += 1)
        end
    end
    return count
end

Base.size(targets::CallTargets) = (length(targets),)

function _materialize_call(targets::CallTargets, application, object_id::ObjectId)
    status = _model_object_status(targets.compiled.model, object_id)
    return CallTarget(
        targets.compiled,
        targets.environment_bindings,
        application,
        object_id,
        _application_model(application, object_id),
        status,
        targets.temporal_streams,
        targets.output_retention,
        targets.time,
        targets.constants,
        targets.publication_allowed,
    )
end

function Base.getindex(targets::CallTargets, requested::Int)
    checkbounds(targets, requested)
    current = 0
    for application_id in targets.binding.callee_application_ids
        application = _compiled_application_by_id(targets.compiled, application_id)
        for object_id in targets.binding.callee_object_ids
            _call_target_matches(targets, application, object_id) || continue
            current += 1
            current == requested && return _materialize_call(targets, application, object_id)
        end
    end
    throw(BoundsError(targets, requested))
end

function Base.iterate(targets::CallTargets, state::Tuple{Int,Int}=(1, 1))
    application_index, object_index = state
    application_ids = targets.binding.callee_application_ids
    object_ids = targets.binding.callee_object_ids
    while application_index <= length(application_ids)
        application = _compiled_application_by_id(
            targets.compiled,
            application_ids[application_index],
        )
        while object_index <= length(object_ids)
            object_id = object_ids[object_index]
            object_index += 1
            _call_target_matches(targets, application, object_id) || continue
            return (
                _materialize_call(targets, application, object_id),
                (application_index, object_index),
            )
        end
        application_index += 1
        object_index = 1
    end
    return nothing
end

"""
    call_targets(context::RunContext, name::Symbol)

Return a cached, non-executing vector-like view of the targets declared for
`name` with `Calls(...)`. The collection is empty for an unresolved
`OptionalOne`, has one element for `One`, and contains every resolved target
for `Many`.

Use this accessor with [`run_call!(::CallTarget)`](@ref) when targets need
different meteorology, selective execution, a controlled order, or separate
trial and accepted publication.
"""
Base.@constprop :aggressive function call_targets(
    context::RunContext,
    name::Symbol,
)
    return _model_call_targets(context, name)
end

"""
    run_call!(target::CallTarget; publish=false, meteo=nothing)

Run one manually selected model call. By default, the call mutates its target
status without publishing outputs or environment updates, which is suitable
for trial iterations. Pass `publish=true` once for the accepted state. When
`meteo` is provided, it is forwarded directly to this target instead of using
its compiled environment binding. The method returns the same `CallTarget`.

Publication permission is inherited through the call stack. A descendant
cannot publish outputs or environment writes while any ancestor is running as
a trial.

For fine-grained control, obtain a collection with [`call_targets`](@ref), then
select or iterate its targets:

```julia
targets = call_targets(extra, :leaf_energy)
for (target, meteo) in zip(targets, trial_meteo)
    run_call!(target; meteo=meteo, publish=false)
end
for (target, meteo) in zip(targets, accepted_meteo)
    run_call!(target; meteo=meteo, publish=true)
end
```
"""
function run_call!(target::CallTarget; publish::Bool=false, meteo=nothing)
    _run_model_application!(
        target.compiled,
        target.environment_bindings,
        target.application,
        target.object_id;
        time=target.time,
        constants=target.constants,
        temporal_streams=target.temporal_streams,
        output_retention=target.output_retention,
        publish=publish && target.publication_allowed,
        meteo=meteo,
    )
    return target
end

"""
    run_call!(context::RunContext, name::Symbol; meteo=nothing, publish=false)

Execute every target of the hard call declared as `name` and return its
[`CallTargets`](@ref) collection. The return shape is always vector-like:
`One` produces one element, `OptionalOne` zero or one, and `Many` zero or more.

This is the convenient execute-all API. For finer-grained control over target
selection, order, per-target meteorology, iterative trial calls, or publication
of only an accepted result, use [`call_targets`](@ref) and execute individual
targets with [`run_call!(::CallTarget)`](@ref).
"""
function run_call!(
    context::RunContext,
    name::Symbol;
    meteo=nothing,
    publish::Bool=false,
)
    targets = call_targets(context, name)
    for target in targets
        run_call!(target; meteo=meteo, publish=publish)
    end
    return targets
end

function run_call!(context, name::Symbol; meteo=nothing, publish::Bool=false)
    throw(
        ArgumentError(
            "Hard call `$(name)` requires the compiled RunContext passed to a model kernel; got $(typeof(context)).",
        ),
    )
end

struct _UnspecifiedModelOutputs end
const _UNSPECIFIED_SCENE_OUTPUTS = _UnspecifiedModelOutputs()

function _model_output_selection(outputs, tracked_outputs)
    outputs_specified = !(outputs isa _UnspecifiedModelOutputs)
    tracked_specified = !(tracked_outputs isa _UnspecifiedModelOutputs)
    outputs_specified && tracked_specified && error(
        "Use `outputs=...`; do not pass both `outputs` and deprecated `tracked_outputs`.",
    )

    selection = if tracked_specified
        Base.depwarn(
            "`tracked_outputs` is deprecated; use `outputs=:all`, `outputs=:none`, or `outputs=requests`.",
            :run!,
        )
        isnothing(tracked_outputs) ? :all : tracked_outputs
    elseif outputs_specified
        outputs
    else
        :none
    end

    selection === :all && return (OutputRequest[], true)
    selection === :none && return (OutputRequest[], false)
    selection isa Symbol && error(
        "Unsupported output selection `$(selection)`. Use `:all`, `:none`, an `OutputRequest`, or a vector of requests.",
    )
    requests = _normalize_output_requests(selection)
    return requests, false
end

function _refresh_simulation_runtime!(simulation::Simulation)
    model = simulation.model
    if bindings_dirty(model)
        added_object_ids = isnothing(model.binding_dirty_objects) ?
                           nothing : copy(model.binding_dirty_objects)
        simulation.compiled = refresh_bindings!(model)
        simulation.environment_bindings = refresh_environment_bindings!(
            model,
            simulation.compiled,
        )
        simulation.execution_plan = isnothing(added_object_ids) ?
                                    compile_model_execution_plan(
            simulation.compiled,
            simulation.environment_bindings,
        ) : _extend_model_execution_plan(
            simulation.execution_plan,
            simulation.compiled,
            simulation.environment_bindings,
            added_object_ids,
        )
    elseif environment_bindings_dirty(model)
        simulation.environment_bindings = refresh_environment_bindings!(
            model,
            simulation.compiled,
        )
        simulation.execution_plan = compile_model_execution_plan(
            simulation.compiled,
            simulation.environment_bindings,
        )
    end
    return simulation
end

function _continue_scene!(simulation::Simulation, steps::Integer)
    steps >= 0 || error("`steps` must be non-negative, got $(steps).")
    start_step = simulation.current_step + 1
    final_step = simulation.current_step + steps
    for step in start_step:final_step
        added_object_ids = bindings_dirty(simulation.model) &&
                           !isnothing(simulation.model.binding_dirty_objects) ?
                           copy(simulation.model.binding_dirty_objects) : nothing
        _refresh_simulation_runtime!(simulation)
        _refresh_output_request_targets!(simulation, added_object_ids)
        empty!(simulation.environment_bindings.sample_cache)
        for batch in simulation.execution_plan.batches
            _run_model_execution_batch!(
                batch,
                simulation.compiled,
                simulation.environment_bindings;
                time=step,
                constants=simulation.constants,
                temporal_streams=simulation.temporal_streams,
                output_retention=simulation.output_retention,
            )
        end
        simulation.current_step = step
    end
    added_object_ids = bindings_dirty(simulation.model) &&
                       !isnothing(simulation.model.binding_dirty_objects) ?
                       copy(simulation.model.binding_dirty_objects) : nothing
    _refresh_simulation_runtime!(simulation)
    _refresh_output_request_targets!(simulation, added_object_ids)
    return simulation
end

function _initial_output_request_targets(model, compiled, output_requests)
    targets = Dict{Symbol,Tuple{Symbol,Dict{ObjectId,Any}}}()
    for request in output_requests
        application = _model_request_application(model, compiled, request)
        object_ids = resolve_object_ids(
            model,
            request.selector;
            context=request.context,
        )
        targets[request.name] = (
            application.id,
            Dict(id => _model_object(model, id).scale for id in object_ids),
        )
    end
    return targets
end

function _refresh_output_request_targets!(simulation::Simulation, added_object_ids=nothing)
    for request in simulation.output_requests
        _, object_scales = simulation.output_request_targets[request.name]
        matched_ids = if isnothing(added_object_ids)
            resolve_object_ids(
                simulation.model,
                _selector_as_many(request.selector);
                context=request.context,
            )
        else
            ObjectId[
                object_id for object_id in added_object_ids
                if _selector_matches_object_id(
                    simulation.model,
                    request.selector,
                    object_id;
                    context=request.context,
                )
            ]
        end
        match_count = isnothing(added_object_ids) ?
                      length(matched_ids) : length(object_scales) + length(matched_ids)
        if request.selector isa Union{One,OptionalOne} && match_count > 1
            error(
                "Output request `$(request.name)` expected at most one current object for selector ",
                "`$(request.selector)`, got $([id.value for id in matched_ids]).",
            )
        end
        for object_id in matched_ids
            object_scales[object_id] = _model_object(
                simulation.model,
                object_id,
            ).scale
        end
    end
    return simulation
end

"""
    run!(model; steps=1, constants=Constants(), outputs=:none)

Run a fresh simulation timeline while mutating object status in `model`.
Choose `outputs=:none`, `outputs=:all`, one [`OutputRequest`](@ref), or a
vector of requests. Use [`continue!`](@ref) on the returned
[`Simulation`](@ref) to advance without resetting time.
"""
function run!(
    model::CompositeModel;
    steps::Integer=1,
    constants=PlantMeteo.Constants(),
    outputs=_UNSPECIFIED_SCENE_OUTPUTS,
    tracked_outputs=_UNSPECIFIED_SCENE_OUTPUTS,
)
    compiled = refresh_bindings!(model)
    env_bindings = refresh_environment_bindings!(model, compiled)
    empty!(env_bindings.sample_cache)
    execution_plan = compile_model_execution_plan(compiled, env_bindings)
    output_requests, retain_all = _model_output_selection(outputs, tracked_outputs)
    output_retention = compile_model_output_retention(
        compiled,
        output_requests;
        retain_all=retain_all,
    )
    temporal_streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}()
    output_request_targets = _initial_output_request_targets(
        model,
        compiled,
        output_requests,
    )
    simulation = Simulation(
        model,
        compiled,
        env_bindings,
        execution_plan,
        output_retention,
        temporal_streams,
        output_requests,
        output_request_targets,
        0,
        constants,
    )
    return _continue_scene!(simulation, steps)
end

"""
    continue!(simulation; steps=1)

Advance an existing [`Simulation`](@ref) without resetting its timeline,
retained streams, temporal dependency history, or environment position.
"""
continue!(simulation::Simulation; steps::Integer=1) =
    _continue_scene!(simulation, steps)

"""
    step!(simulation)

Advance an existing [`Simulation`](@ref) by one timestep.
"""
step!(simulation::Simulation) = continue!(simulation; steps=1)

function _model_output_rows(sim::Simulation, filter_object=nothing, filter_var=nothing)
    rows = NamedTuple[]
    for ((application_id, object_id, variable), samples) in sort!(
        collect(sim.temporal_streams);
        by=pair -> (string(first(pair)[1]), string(first(pair)[2].value), string(first(pair)[3])),
    )
        isnothing(filter_object) || object_id == ObjectId(filter_object) || continue
        isnothing(filter_var) || variable == Symbol(filter_var) || continue
        for (time, value) in samples
            push!(
                rows,
                (
                    timestep=Int(round(time)),
                    time=time,
                    application_id=application_id,
                    object_id=object_id.value,
                    variable=variable,
                    value=value,
                ),
            )
        end
    end
    sort!(rows; by=row -> (row.timestep, string(row.object_id), string(row.variable)))
    return rows
end

function _materialize_model_output_rows(rows, sink)
    isnothing(sink) && return rows
    sink === DataFrames.DataFrame && return DataFrames.DataFrame(rows)
    return sink(rows)
end

function _model_request_application(model::CompositeModel, compiled::CompiledCompositeModel, request)
    requested_ids = Set(resolve_object_ids(
        model,
        request.selector;
        context=request.context,
    ))
    declared_scale = _selector_declared_scale(request.selector)
    candidates = CompiledModelApplication[]
    for application in compiled.applications
        request.var in keys(outputs_(application.spec)) || continue
        isnothing(request.process) || application.process == request.process || continue
        isnothing(request.application) ||
            application.id == request.application ||
            application.name == request.application ||
            continue
        target_match = any(id -> id in requested_ids, application.target_ids)
        scale_match = !isnothing(declared_scale) &&
                      _model_application_matches_scale(model, application, declared_scale)
        (target_match || scale_match) || continue
        if isnothing(request.process) &&
           isnothing(request.application) &&
           _publish_mode_for_output(application.spec, request.var) == :stream_only
            continue
        end
        push!(candidates, application)
    end
    if isempty(candidates)
        error(
            "No model output publisher found for selector `$(request.selector)` and variable `$(request.var)`",
            isnothing(request.application) ?
            (isnothing(request.process) ? "." : " from process `$(request.process)`.") :
            " from application `$(request.application)`.",
        )
    elseif length(candidates) > 1
        error(
            "Ambiguous model output publishers for selector `$(request.selector)` and variable `$(request.var)`: ",
            join((application.id for application in candidates), ", "),
            ". Provide `application=` or make one publisher canonical.",
        )
    end
    return only(candidates)
end

function _model_request_application(sim::Simulation, request)
    return _model_request_application(sim.model, sim.compiled, request)
end

function _selector_declared_scale(selector::AbstractObjectMultiplicity)
    selector_criteria = criteria(selector)
    scale = _criteria_get(selector_criteria, :scale, nothing)
    !isnothing(scale) && return scale
    for positional_selector in _criteria_get(selector_criteria, :selectors, ())
        positional_selector isa Scale && return positional_selector.scale
    end
    return nothing
end

function _model_application_matches_scale(
    model::CompositeModel,
    application::CompiledModelApplication,
    scale::Symbol,
)
    declared_scale = _selector_declared_scale(application.applies_to)
    declared_scale == scale && return true
    for object_id in application.target_ids
        object = get(model.registry.objects, object_id, nothing)
        !isnothing(object) && object.scale == scale && return true
    end
    return false
end

function _model_stream_object_matches_scale(
    model::CompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    scale::Symbol,
)
    object = get(model.registry.objects, object_id, nothing)
    !isnothing(object) && return object.scale == scale
    declared_scale = _selector_declared_scale(application.applies_to)
    return isnothing(declared_scale) || declared_scale == scale
end

function _model_request_clock(request, timeline)
    isnothing(request.clock) && return ClockSpec(1.0, 0.0)
    clock = _clock_from_spec_timestep(request.clock, timeline)
    isnothing(clock) && error(
        "Unsupported clock specification `$(typeof(request.clock))` in ",
        "OutputRequest `$(request.name)`.",
    )
    return clock
end

function _model_requested_value(samples, time, t_start, policy, timeline)
    if policy isa HoldLast
        value = _model_latest_sample(samples, time)
        return isnothing(value) ? missing : value
    elseif policy isa Interpolate
        value = _model_interpolated_sample(samples, time, policy)
        return isnothing(value) ? missing : value
    elseif policy isa Union{Integrate,Aggregate}
        values, durations = _model_window_segments(
            samples,
            t_start,
            time,
            timeline.base_step_seconds,
        )
        isempty(values) && return missing
        return _model_window_reduce(values, durations, policy)
    end
    error("Unsupported model output request policy `$(typeof(policy))`.")
end

function _model_requested_output_rows(
    sim::Simulation,
    request,
)
    application_id, requested_objects = sim.output_request_targets[request.name]
    requested_ids = keys(requested_objects)
    application = _compiled_application_by_id(sim.compiled, application_id)
    declared_scale = _selector_declared_scale(request.selector)
    timeline = _model_timeline(sim.model)
    clock = _model_request_clock(request, timeline)
    source_rows = [
        (object_id=object_id, samples=samples)
        for ((application_id, object_id, variable), samples) in sim.temporal_streams
        if application_id == application.id &&
           variable == request.var &&
           (object_id in requested_ids ||
            (!isnothing(declared_scale) &&
             _model_stream_object_matches_scale(sim.model, application, object_id, declared_scale)))
    ]
    isempty(source_rows) && return NamedTuple[]
    nonempty_source_rows = [row for row in source_rows if !isempty(row.samples)]
    isempty(nonempty_source_rows) && return NamedTuple[]
    max_time = maximum(last(row.samples)[1] for row in nonempty_source_rows)
    rows = NamedTuple[]
    for time in 1:Int(floor(max_time))
        _should_run_at_time(clock, float(time)) || continue
        t_start = float(time) - float(clock.dt) + 1.0
        for row in sort!(nonempty_source_rows; by=row -> string(row.object_id.value))
            first_sample_time = first(row.samples)[1]
            last_sample_time = last(row.samples)[1]
            first_sample_time <= float(time) <= last_sample_time || continue
            push!(
                rows,
                (
                    timestep=time,
                    time=float(time),
                    scale=isnothing(declared_scale) ?
                          get(requested_objects, row.object_id, missing) :
                          declared_scale,
                    process=application.process,
                    application_id=application.id,
                    variable=request.var,
                    object_id=row.object_id.value,
                    value=_model_requested_value(
                        row.samples,
                        float(time),
                        t_start,
                        request.policy,
                        timeline,
                    ),
                ),
            )
        end
    end
    return rows
end

function _collect_model_requested_outputs(sim::Simulation, sink)
    outputs = Dict{Symbol,Any}()
    for request in sim.output_requests
        haskey(outputs, request.name) && error(
            "Duplicate output request name `$(request.name)`. Request names must be unique."
        )
        outputs[request.name] = _materialize_model_output_rows(
            _model_requested_output_rows(sim, request),
            sink,
        )
    end
    return outputs
end

function collect_outputs(sim::Simulation; sink=DataFrames.DataFrame)
    isempty(sim.output_requests) || return _collect_model_requested_outputs(sim, sink)
    return _materialize_model_output_rows(_model_output_rows(sim), sink)
end

function collect_outputs(sim::Simulation, name::Symbol; sink=DataFrames.DataFrame)
    matches = [request for request in sim.output_requests if request.name == name]
    isempty(matches) && error(
        "No model output request named `$(name)`. Available request names are ",
        isempty(sim.output_requests) ? "none." : join((request.name for request in sim.output_requests), ", "),
    )
    length(matches) == 1 || error(
        "Duplicate model output request name `$(name)`. Request names must be unique."
    )
    request = only(matches)
    return _materialize_model_output_rows(
        _model_requested_output_rows(sim, request),
        sink,
    )
end

function collect_outputs(sim::Simulation, object_id, variable::Symbol; sink=DataFrames.DataFrame)
    return _materialize_model_output_rows(_model_output_rows(sim, object_id, variable), sink)
end

function explain_outputs(sim::Simulation)
    return [
        (
            application_id=application_id,
            object_id=object_id.value,
            variable=variable,
            nsamples=length(samples),
            first_time=isempty(samples) ? nothing : first(samples)[1],
            last_time=isempty(samples) ? nothing : last(samples)[1],
            value_type=isempty(samples) ? Union{} : typeof(last(samples)[2]),
        )
        for ((application_id, object_id, variable), samples) in sort!(
            collect(sim.temporal_streams);
            by=pair -> (string(first(pair)[1]), string(first(pair)[2].value), string(first(pair)[3])),
        )
    ]
end
