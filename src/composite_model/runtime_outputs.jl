struct OutputRetentionPlan
    retain_all::Bool
    temporal_dependencies::Set{Tuple{Symbol,Symbol}}
    requested_outputs::Set{Tuple{Symbol,Symbol}}
    dependency_horizons::Dict{Tuple{Symbol,Symbol},Float64}
    retained_application_ids::Set{Symbol}
    retained_outputs_by_application::Dict{Symbol,Vector{Symbol}}
end

"""
    TemporalDependencyBuffer{T} <: AbstractVector{Tuple{Float64,T}}

Typed, bounded storage for an output retained only to satisfy temporal model
dependencies. Requested and `outputs=:all` streams continue to use append-only
vectors. The logical indexing order is oldest to newest, independently of the
physical circular-buffer layout.
"""
mutable struct TemporalDependencyBuffer{T} <: AbstractVector{Tuple{Float64,T}}
    times::Vector{Float64}
    values::Vector{T}
    first_slot::Int
    sample_count::Int
end

function TemporalDependencyBuffer{T}(capacity::Integer) where {T}
    capacity > 0 || throw(
        ArgumentError("Temporal dependency capacity must be positive."),
    )
    return TemporalDependencyBuffer{T}(
        Vector{Float64}(undef, capacity),
        Vector{T}(undef, capacity),
        1,
        0,
    )
end

Base.IndexStyle(::Type{<:TemporalDependencyBuffer}) = IndexLinear()
Base.size(buffer::TemporalDependencyBuffer) = (buffer.sample_count,)

@inline function _temporal_dependency_slot(
    buffer::TemporalDependencyBuffer,
    index::Int,
)
    @boundscheck checkbounds(buffer, index)
    return mod1(buffer.first_slot + index - 1, length(buffer.times))
end

@inline function Base.getindex(buffer::TemporalDependencyBuffer, index::Int)
    slot = _temporal_dependency_slot(buffer, index)
    return (@inbounds buffer.times[slot], @inbounds buffer.values[slot])
end

@inline function Base.setindex!(
    buffer::TemporalDependencyBuffer{T},
    sample::Tuple{Float64,T},
    index::Int,
) where {T}
    slot = _temporal_dependency_slot(buffer, index)
    @inbounds buffer.times[slot] = first(sample)
    @inbounds buffer.values[slot] = last(sample)
    return sample
end

@inline function Base.push!(
    buffer::TemporalDependencyBuffer{T},
    sample::Tuple{Float64,T},
) where {T}
    capacity = length(buffer.times)
    if buffer.sample_count < capacity
        slot = mod1(buffer.first_slot + buffer.sample_count, capacity)
        buffer.sample_count += 1
    else
        slot = buffer.first_slot
        buffer.first_slot = mod1(buffer.first_slot + 1, capacity)
    end
    @inbounds buffer.times[slot] = first(sample)
    @inbounds buffer.values[slot] = last(sample)
    return buffer
end

@inline function Base.pop!(buffer::TemporalDependencyBuffer)
    isempty(buffer) && throw(ArgumentError("array must be non-empty"))
    sample = buffer[end]
    buffer.sample_count -= 1
    buffer.sample_count == 0 && (buffer.first_slot = 1)
    return sample
end

@inline function _temporal_dependency_popfirst!(
    buffer::TemporalDependencyBuffer,
)
    isempty(buffer) && throw(ArgumentError("array must be non-empty"))
    sample = buffer[1]
    buffer.first_slot = mod1(buffer.first_slot + 1, length(buffer.times))
    buffer.sample_count -= 1
    buffer.sample_count == 0 && (buffer.first_slot = 1)
    return sample
end

"""
    RuntimeTemporalInput

Per-simulation temporal input state compiled into an execution target. It
shares direct references to the producer streams with every compatible
consumer, avoiding a global stream-dictionary lookup in the per-target loop.
"""
struct RuntimeTemporalInput{C,S}
    compiled::C
    source_streams::S
end

"""
    RuntimePerformanceCounters

Opt-in coarse runtime instrumentation used by the performance regression
suite. Pass `performance=true` to [`run!`](@ref), then inspect a copy of the
recorded counters with [`runtime_performance`](@ref).

The disabled path stores `nothing` in the simulation and does not call
`time_ns()`. Counters deliberately cover compiler/runtime boundaries rather
than individual scientific kernels so instrumentation does not change kernel
dispatch or allocation behavior.
"""
mutable struct RuntimePerformanceCounters
    counts::Dict{Symbol,Int}
    elapsed_ns::Dict{Symbol,UInt64}
end

RuntimePerformanceCounters() =
    RuntimePerformanceCounters(Dict{Symbol,Int}(), Dict{Symbol,UInt64}())

@inline _runtime_performance_start(::Nothing) = UInt64(0)
@inline _runtime_performance_start(::RuntimePerformanceCounters) = time_ns()

@inline _runtime_performance_finish!(::Nothing, ::Symbol, ::UInt64) = nothing

@inline function _runtime_performance_finish!(
    counters::RuntimePerformanceCounters,
    name::Symbol,
    started_at::UInt64,
)
    elapsed = time_ns() - started_at
    counters.elapsed_ns[name] = get(counters.elapsed_ns, name, UInt64(0)) + elapsed
    return nothing
end

@inline _runtime_performance_count!(::Nothing, ::Symbol, amount::Int=1) = nothing

@inline function _runtime_performance_count!(
    counters::RuntimePerformanceCounters,
    name::Symbol,
    amount::Int=1,
)
    counters.counts[name] = get(counters.counts, name, 0) + amount
    return nothing
end

"""
    RunContext

Runtime context passed as the final argument to model kernels. Use
`runtime_model`, `call_targets`, and `run_call!` instead of inspecting its
fields.
"""
struct NoEnvironmentOverride end
const _NO_ENVIRONMENT_OVERRIDE = NoEnvironmentOverride()

mutable struct RunContext{CS,A,CT,TS,OR,C,E}
    compiled::CS
    environment_bindings::CompiledEnvironmentBindings
    application::A
    object_id::ObjectId
    calls::CT
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
    environment::E
end

struct CallTarget{CS,EB,A,M,S,TS,OR,C,E}
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
    environment::E
end

"""
    CallTargets <: AbstractVector{CallTarget}

A cached vector-like view of the compiled targets for one declared hard call.
Retrieving it does not allocate a replacement collection. Obtain it with
[`call_targets`](@ref) or as the result of
[`run_call!(::RunContext, ::Symbol)`](@ref).
"""
mutable struct CallTargets{CS,EB,B,TS,OR,C,E} <: AbstractVector{CallTarget}
    compiled::CS
    environment_bindings::EB
    binding::B
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
    environment::E
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
    environment,
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
        environment,
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
            environment,
        )...,
    )
end

@inline _prepare_runtime_call_targets!(
    ::Tuple{},
    compiled,
    environment_bindings,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed,
    environment,
) = nothing

@inline function _prepare_runtime_call_targets!(
    calls::Tuple,
    compiled,
    environment_bindings,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed,
    environment,
)
    targets = first(calls)
    targets.compiled = compiled
    targets.environment_bindings = environment_bindings
    targets.temporal_streams = temporal_streams
    targets.output_retention = output_retention
    targets.time = float(time)
    targets.constants = constants
    targets.publication_allowed = publication_allowed
    targets.environment = environment
    _prepare_runtime_call_targets!(
        Base.tail(calls),
        compiled,
        environment_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        publication_allowed,
        environment,
    )
    return nothing
end

abstract type AbstractExecutionBatch end
struct UnspecifiedModelMeteo end
const _UNSPECIFIED_SCENE_METEO = UnspecifiedModelMeteo()
const _SCENE_RAW_METEO_CACHE_ID = Symbol("#raw_global_meteo")

struct CompiledExecutionTarget{M,S,CS,MB,IB,CB,EB,RC}
    object_id::ObjectId
    model::M
    status::S
    canonical_status::CS
    models::MB
    input_bindings::IB
    call_bindings::CB
    environment_binding::EB
    context::RC
end

struct CompiledExecutionBatch{A,T<:AbstractVector} <: AbstractExecutionBatch
    application::A
    targets::T
end

struct CompiledApplicationExecutionGroup{A,B}
    application::A
    batches::B
end

struct CompiledExecutionPlan{G,B}
    groups::G
    batches::B
    model_revision::Int
    environment_revision::Int
end

"""
    Simulation

Result of running a [`CompositeModel`](@ref). Use `outputs`, `collect_outputs`,
and the explanation helpers to inspect it.
"""
mutable struct Simulation{S,CS,EB,EP,OR,TS,R,RT,C,P}
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
    performance::P
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

"""
    runtime_performance(simulation)

Return a stable snapshot of opt-in runtime performance counters, or `nothing`
when the simulation was not started with `performance=true`. Elapsed values are
reported in seconds while the internal counters retain nanosecond resolution.
"""
function runtime_performance(simulation::Simulation)
    counters = simulation.performance
    isnothing(counters) && return nothing
    return (
        counts=copy(counters.counts),
        elapsed_seconds=Dict(
            name => Float64(elapsed) / 1.0e9
            for (name, elapsed) in counters.elapsed_ns
        ),
    )
end

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

@inline function _model_status_view_for_application(
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
)
    key = (application.id, object_id)
    haskey(compiled.status_views_by_target, key) || error(
        "No compiled status view for application `$(application.id)` on object ",
        "`$(object_id.value)`.",
    )
    return compiled.status_views_by_target[key]
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

function _model_dependency_only_output(
    retention::OutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
)
    retention.retain_all && return false
    key = (application_id, variable)
    return key in retention.temporal_dependencies &&
           !(key in retention.requested_outputs)
end

_model_dependency_only_output(::Nothing, application_id::Symbol, variable::Symbol) =
    false

function _model_dependency_capacity(
    retention::OutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
)
    horizon = get(retention.dependency_horizons, (application_id, variable), 0.0)
    return max(1, ceil(Int, horizon))
end

function _model_new_output_stream(
    value,
    retention,
    application_id::Symbol,
    variable::Symbol,
)
    if _model_dependency_only_output(retention, application_id, variable)
        capacity = _model_dependency_capacity(retention, application_id, variable)
        return TemporalDependencyBuffer{typeof(value)}(capacity)
    end
    return Tuple{Float64,typeof(value)}[]
end

function _initialize_model_temporal_streams!(
    streams,
    compiled::CompiledCompositeModel,
    retention::OutputRetentionPlan,
)
    for (application_id, variable) in retention.temporal_dependencies
        application = _compiled_application_by_id(compiled, application_id)
        for object_id in application.target_ids
            key = _model_stream_key(application_id, object_id, variable)
            haskey(streams, key) && continue
            status = _model_status_view_for_application(
                compiled,
                application,
                object_id,
            ).canonical_status
            hasproperty(status, variable) || error(
                "Application `$(application_id)` declares temporal output ",
                "`$(variable)`, but object `$(object_id.value)` status has no ",
                "such variable.",
            )
            streams[key] = _model_new_output_stream(
                getproperty(status, variable),
                retention,
                application_id,
                variable,
            )
        end
    end
    return streams
end

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

function _model_prune_dependency_stream!(
    samples::TemporalDependencyBuffer,
    retention::OutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
    time::Real,
)
    horizon = get(retention.dependency_horizons, (application_id, variable), 0.0)
    cutoff = horizon <= 0.0 ? float(time) : float(time) - horizon + 1.0
    while !isempty(samples) && first(samples)[1] < cutoff - 1.0e-8
        _temporal_dependency_popfirst!(samples)
    end
    return samples
end

_model_prune_dependency_stream!(samples, ::Nothing, application_id, variable, time) =
    samples

function _model_remove_sample_time!(
    samples::TemporalDependencyBuffer,
    sample_time::Float64,
)
    write_index = 1
    original_length = length(samples)
    for read_index in 1:original_length
        sample = samples[read_index]
        isapprox(first(sample), sample_time; atol=1.0e-8, rtol=0.0) && continue
        write_index == read_index || (samples[write_index] = sample)
        write_index += 1
    end
    samples.sample_count = write_index - 1
    samples.sample_count == 0 && (samples.first_slot = 1)
    return samples
end

function _model_remove_sample_time!(samples, sample_time::Float64)
    filter!(
        sample -> !isapprox(sample[1], sample_time; atol=1.0e-8, rtol=0.0),
        samples,
    )
    return samples
end

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
            samples = _model_new_output_stream(
                value,
                retention,
                application.id,
                var,
            )
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
            _model_remove_sample_time!(samples, sample_time)
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
    return _model_temporal_sample_value(
        samples,
        time,
        policy,
        t_start,
        timeline,
    )
end

function _model_temporal_sample_value(
    samples,
    time::Real,
    policy,
    t_start::Real,
    timeline,
)
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

function _model_assign_private_temporal_value!(
    temporal_input::CompiledTemporalInput,
    value,
)
    current = temporal_input.reference[]
    if current isa AbstractVector && value isa AbstractVector
        if current isa Vector && length(current) != length(value)
            resize!(current, length(value))
        end
        axes(current) == axes(value) || error(
            "Temporal input `$(temporal_input.binding.input)` changed shape from ",
            "`$(axes(current))` to ",
            "`$(axes(value))`; use a stable vector shape or a `Many(...)` binding.",
        )
        copyto!(current, value)
        return temporal_input
    end
    temporal_input.reference[] = value
    return temporal_input
end

function _materialize_model_temporal_input!(
    status::Status,
    temporal_input::CompiledTemporalInput,
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
)
    binding = temporal_input.binding
    window_steps = _model_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    if binding.multiplicity == :many
        storage = temporal_input.reference[]
        storage isa AbstractVector || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` has non-vector private storage ",
            "`$(typeof(storage))`.",
        )
        length(storage) == length(binding.source_ids) || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` has $(length(storage)) private values for ",
            "$(length(binding.source_ids)) resolved source objects. Refresh the ",
            "compiled lifecycle bindings before execution.",
        )
        for index in eachindex(binding.source_ids)
            value = _model_temporal_source_value(
                streams,
                temporal_input.source_applications[index],
                binding.source_ids[index],
                binding.source_var,
                time,
                binding.policy,
                t_start,
                timeline,
            )
            if isnothing(value)
                binding.policy isa PreviousTimeStep || error(
                    "No temporal model value available for input ",
                    "`$(binding.input)` from ",
                    "`$(binding.source_ids[index].value).$(binding.source_var)` ",
                    "at t=$(time).",
                )
                value = temporal_input.initial[index]
            end
            storage[index] = value
        end
        return status
    end
    source_id = only(binding.source_ids)
    value = _model_temporal_source_value(
        streams,
        only(temporal_input.source_applications),
        source_id,
        binding.source_var,
        time,
        binding.policy,
        t_start,
        timeline,
    )
    if isnothing(value)
        binding.policy isa PreviousTimeStep || error(
            "No temporal model value available for input `$(binding.input)` from ",
            "`$(source_id.value).$(binding.source_var)` at t=$(time).",
        )
        value = temporal_input.initial
    end
    _model_assign_private_temporal_value!(temporal_input, value)
    return status
end

function _materialize_model_temporal_input!(
    status::Status,
    runtime_input::RuntimeTemporalInput,
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
)
    temporal_input = runtime_input.compiled
    binding = temporal_input.binding
    window_steps = _model_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    if binding.multiplicity == :many
        storage = temporal_input.reference[]
        storage isa AbstractVector || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` has non-vector private storage ",
            "`$(typeof(storage))`.",
        )
        length(storage) == length(binding.source_ids) || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` has $(length(storage)) private values for ",
            "$(length(binding.source_ids)) resolved source objects. Refresh the ",
            "compiled lifecycle bindings before execution.",
        )
        for index in eachindex(binding.source_ids)
            value = _model_temporal_sample_value(
                runtime_input.source_streams[index],
                time,
                binding.policy,
                t_start,
                timeline,
            )
            if isnothing(value)
                binding.policy isa PreviousTimeStep || error(
                    "No temporal model value available for input ",
                    "`$(binding.input)` from ",
                    "`$(binding.source_ids[index].value).$(binding.source_var)` ",
                    "at t=$(time).",
                )
                value = temporal_input.initial[index]
            end
            storage[index] = value
        end
        return status
    end
    source_id = only(binding.source_ids)
    value = _model_temporal_sample_value(
        runtime_input.source_streams,
        time,
        binding.policy,
        t_start,
        timeline,
    )
    if isnothing(value)
        binding.policy isa PreviousTimeStep || error(
            "No temporal model value available for input `$(binding.input)` from ",
            "`$(source_id.value).$(binding.source_var)` at t=$(time).",
        )
        value = temporal_input.initial
    end
    _model_assign_private_temporal_value!(temporal_input, value)
    return status
end

function _materialize_model_inputs!(
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    streams=nothing,
    time::Real=1,
)
    isnothing(streams) &&
        return _model_object_status(compiled.model, object_id)
    view = _model_status_view_for_application(compiled, application, object_id)
    return _materialize_model_inputs!(
        view.status,
        view.temporal_inputs,
        compiled,
        application,
        streams,
        time,
    )
end

function _materialize_model_inputs!(
    status::Status,
    bindings::Tuple,
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    streams=nothing,
    time::Real=1,
)
    isnothing(streams) && return status
    timeline = compiled.timeline
    for temporal_input in bindings
        _materialize_model_temporal_input!(
            status,
            temporal_input,
            application,
            streams,
            time,
            timeline,
        )
    end
    return status
end

function _model_meteo_for_model(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    time::Real,
    environment=_NO_ENVIRONMENT_OVERRIDE,
)
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _model_meteo_for_binding(
        env_bindings,
        application,
        binding,
        time,
        environment,
    )
end

function _model_meteo_for_binding(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    binding,
    time::Real,
    environment=_NO_ENVIRONMENT_OVERRIDE,
)
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    if !(environment isa NoEnvironmentOverride)
        return sample_environment(
            binding.backend,
            binding.handle,
            environment,
            time,
            application.spec,
        )
    end
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
            binding.handle,
            time,
            application.spec,
        )
        env_bindings.sample_cache[key] = sampled
        return sampled
    end
    return sample_environment(
        binding.backend,
        binding.handle,
        time,
        application.spec,
    )
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

@inline function _prepare_model_execution_context!(
    context::RunContext,
    compiled,
    environment_bindings,
    application,
    object_id,
    temporal_streams,
    output_retention,
    time,
    constants,
)
    context.compiled = compiled
    context.environment_bindings = environment_bindings
    context.application = application
    context.object_id = object_id
    context.temporal_streams = temporal_streams
    context.output_retention = output_retention
    context.time = float(time)
    context.constants = constants
    context.publication_allowed = true
    context.environment = _NO_ENVIRONMENT_OVERRIDE
    _prepare_runtime_call_targets!(
        context.calls,
        compiled,
        environment_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        true,
        _NO_ENVIRONMENT_OVERRIDE,
    )
    return context
end

@inline function _prepare_model_execution_context!(
    ::Nothing,
    compiled,
    environment_bindings,
    application,
    object_id,
    temporal_streams,
    output_retention,
    time,
    constants,
)
    call_bindings = get(
        compiled.call_bindings_by_target,
        (application.id, object_id),
        (),
    )
    calls = _runtime_call_targets(
        compiled,
        environment_bindings,
        call_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        true,
        _NO_ENVIRONMENT_OVERRIDE,
    )
    return RunContext(
        compiled,
        environment_bindings,
        application,
        object_id,
        calls,
        temporal_streams,
        output_retention,
        float(time),
        constants,
        true,
        _NO_ENVIRONMENT_OVERRIDE,
    )
end

@inline function _run_model_application_with_calls!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    status,
    canonical_status,
    meteo_value,
    calls,
    time,
    constants,
    temporal_streams,
    output_retention,
    publish::Bool,
    environment,
)
    context = RunContext(
        compiled,
        env_bindings,
        application,
        object_id,
        calls,
        temporal_streams,
        output_retention,
        float(time),
        constants,
        publish,
        environment,
    )
    model = _application_model(application, object_id)
    models = _model_models_for_application(compiled, application, object_id)
    run!(model, models, status, meteo_value, constants, context)
    if publish
        _model_publish_outputs!(
            temporal_streams,
            application,
            object_id,
            canonical_status,
            time,
            output_retention,
        )
    end
    return status
end

@inline function _run_model_application!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    time::Real,
    constants,
    temporal_streams,
    output_retention,
    publish::Bool,
    meteo,
    environment,
)
    status_view = _model_status_view_for_application(
        compiled,
        application,
        object_id,
    )
    status = _materialize_model_inputs!(
        status_view.status,
        status_view.temporal_inputs,
        compiled,
        application,
        temporal_streams,
        time,
    )
    meteo_value = meteo isa UnspecifiedModelMeteo ?
                  _model_meteo_for_model(
        env_bindings,
        application,
        object_id,
        time,
        environment,
    ) : meteo
    call_bindings = get(
        compiled.call_bindings_by_target,
        (application.id, object_id),
        (),
    )
    if isempty(call_bindings)
        return _run_model_application_with_calls!(
            compiled,
            env_bindings,
            application,
            object_id,
            status,
            status_view.canonical_status,
            meteo_value,
            (),
            time,
            constants,
            temporal_streams,
            output_retention,
            publish,
            environment,
        )
    end
    calls = _runtime_call_targets(
        compiled,
        env_bindings,
        call_bindings,
        temporal_streams,
        output_retention,
        time,
        constants,
        publish,
        environment,
    )
    return _run_model_application_with_calls!(
        compiled,
        env_bindings,
        application,
        object_id,
        status,
        status_view.canonical_status,
        meteo_value,
        calls,
        time,
        constants,
        temporal_streams,
        output_retention,
        publish,
        environment,
    )
end

@inline function _run_model_execution_target_without_calls!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget,
    time::Real,
    constants,
    temporal_streams,
    output_retention,
    meteo,
    publish_outputs::Bool,
    retained_outputs,
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
    context = if target.context isa RunContext
        _prepare_model_execution_context!(
            target.context,
            compiled,
            env_bindings,
            application,
            target.object_id,
            temporal_streams,
            output_retention,
            time,
            constants,
        )
    else
        RunContext(
            compiled,
            env_bindings,
            application,
            target.object_id,
            (),
            temporal_streams,
            output_retention,
            float(time),
            constants,
            true,
            _NO_ENVIRONMENT_OVERRIDE,
        )
    end
    run!(target.model, target.models, status, meteo_value, constants, context)
    publish_outputs && _model_publish_outputs!(
        temporal_streams,
        application,
        target.object_id,
        target.canonical_status,
        time,
        output_retention,
        retained_outputs,
    )
    return status
end

@inline function _run_model_execution_target!(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget,
    time::Real,
    constants,
    temporal_streams,
    output_retention,
    meteo,
    publish_outputs::Bool,
    retained_outputs,
)
    isempty(target.call_bindings) && return _run_model_execution_target_without_calls!(
        compiled,
        env_bindings,
        application,
        target,
        time,
        constants,
        temporal_streams,
        output_retention,
        meteo,
        publish_outputs,
        retained_outputs,
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
    context = _prepare_model_execution_context!(
        target.context,
        compiled,
        env_bindings,
        application,
        target.object_id,
        temporal_streams,
        output_retention,
        time,
        constants,
    )
    run!(target.model, target.models, status, meteo_value, constants, context)
    publish_outputs && _model_publish_outputs!(
        temporal_streams,
        application,
        target.object_id,
        target.canonical_status,
        time,
        output_retention,
        retained_outputs,
    )
    return status
end

@inline function _run_model_execution_batch!(
    batch::CompiledExecutionBatch,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    time::Real,
    constants,
    temporal_streams,
    output_retention,
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
    retained_outputs = output_retention isa OutputRetentionPlan ?
                       get(
        output_retention.retained_outputs_by_application,
        batch.application.id,
        (),
    ) : nothing
    if isempty(first(batch.targets).call_bindings)
        if isnothing(temporal_streams)
            for target in batch.targets
                _run_model_execution_target_without_calls!(
                    compiled,
                    env_bindings,
                    batch.application,
                    target,
                    time,
                    constants,
                    temporal_streams,
                    output_retention,
                    shared_meteo,
                    publish_outputs,
                    retained_outputs,
                )
            end
            return nothing
        end
        for target in batch.targets
            status = isempty(target.input_bindings) ?
                     target.status :
                     _materialize_model_inputs!(
                target.status,
                target.input_bindings,
                compiled,
                batch.application,
                temporal_streams,
                time,
            )
            meteo_value = shared_meteo isa UnspecifiedModelMeteo ?
                          _model_meteo_for_binding(
                env_bindings,
                batch.application,
                target.environment_binding,
                time,
            ) : shared_meteo
            context = target.context
            if context isa RunContext
                context.compiled = compiled
                context.environment_bindings = env_bindings
                context.application = batch.application
                context.object_id = target.object_id
                context.temporal_streams = temporal_streams
                context.output_retention = output_retention
                context.time = float(time)
                context.constants = constants
                context.publication_allowed = true
                context.environment = _NO_ENVIRONMENT_OVERRIDE
            else
                context = _prepare_model_execution_context!(
                    context,
                    compiled,
                    env_bindings,
                    batch.application,
                    target.object_id,
                    temporal_streams,
                    output_retention,
                    time,
                    constants,
                )
            end
            run!(
                target.model,
                target.models,
                status,
                meteo_value,
                constants,
                context,
            )
            publish_outputs && _model_publish_outputs!(
                temporal_streams,
                batch.application,
                target.object_id,
                target.canonical_status,
                time,
                output_retention,
                retained_outputs,
            )
        end
        return nothing
    end
    for target in batch.targets
        _run_model_execution_target!(
            compiled,
            env_bindings,
            batch.application,
            target,
            time,
            constants,
            temporal_streams,
            output_retention,
            shared_meteo,
            publish_outputs,
            retained_outputs,
        )
    end
    return nothing
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
    return _run_model_execution_batch!(
        batch,
        compiled,
        env_bindings,
        time,
        constants,
        temporal_streams,
        output_retention,
    )
end

_model_application_should_run(application::CompiledModelApplication, t::Real) =
    _should_run_at_time(application.clock, float(t))

function _manual_call_application_ids(compiled::CompiledCompositeModel)
    ids = Set{Symbol}()
    for binding in compiled.call_bindings
        union!(ids, binding.callee_application_ids)
        isnothing(binding.application) || push!(ids, binding.application)
    end
    return ids
end

function _typed_temporal_source_streams(source_streams::Vector{Any})
    isempty(source_streams) && return ()
    source_type = typeof(first(source_streams))
    all(source -> typeof(source) === source_type, source_streams) ||
        return source_streams
    typed = Vector{source_type}(undef, length(source_streams))
    copyto!(typed, source_streams)
    return typed
end

function _runtime_temporal_source_stream(
    streams,
    temporal_input::CompiledTemporalInput,
    index::Int,
)
    application_id = temporal_input.source_applications[index]
    isnothing(application_id) && return nothing
    binding = temporal_input.binding
    key = _model_stream_key(
        application_id,
        binding.source_ids[index],
        binding.source_var,
    )
    stream = get(streams, key, nothing)
    isnothing(stream) && error(
        "No initialized temporal source stream for application ",
        "`$(application_id)` on object `$(binding.source_ids[index].value)` ",
        "and variable `$(binding.source_var)`.",
    )
    return stream
end

function _runtime_temporal_input(
    temporal_input::CompiledTemporalInput,
    streams,
)
    binding = temporal_input.binding
    if binding.multiplicity == :many
        source_streams = Any[
            _runtime_temporal_source_stream(streams, temporal_input, index)
            for index in eachindex(binding.source_ids)
        ]
        return RuntimeTemporalInput(
            temporal_input,
            _typed_temporal_source_streams(source_streams),
        )
    end
    return RuntimeTemporalInput(
        temporal_input,
        _runtime_temporal_source_stream(streams, temporal_input, 1),
    )
end

_runtime_model_temporal_inputs(temporal_inputs::Tuple, ::Nothing) =
    temporal_inputs

function _runtime_model_temporal_inputs(temporal_inputs::Tuple, streams)
    return Tuple(
        _runtime_temporal_input(temporal_input, streams)
        for temporal_input in temporal_inputs
    )
end

function _compiled_model_execution_context(
    compiled,
    env_bindings,
    application,
    object_id,
    call_bindings,
    temporal_streams,
    output_retention,
    constants,
)
    isnothing(temporal_streams) && return nothing
    calls = _runtime_call_targets(
        compiled,
        env_bindings,
        call_bindings,
        temporal_streams,
        output_retention,
        0.0,
        constants,
        true,
        _NO_ENVIRONMENT_OVERRIDE,
    )
    return RunContext(
        compiled,
        env_bindings,
        application,
        object_id,
        calls,
        temporal_streams,
        output_retention,
        0.0,
        constants,
        true,
        _NO_ENVIRONMENT_OVERRIDE,
    )
end

function _compiled_model_execution_target(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing,
)
    status_view = _model_status_view_for_application(
        compiled,
        application,
        object_id,
    )
    model = _application_model(application, object_id)
    models = _model_models_for_application(compiled, application, object_id)
    call_bindings = get(
        compiled.call_bindings_by_target,
        (application.id, object_id),
        (),
    )
    environment_binding = _environment_binding_for(
        env_bindings,
        application.id,
        object_id,
    )
    context = _compiled_model_execution_context(
        compiled,
        env_bindings,
        application,
        object_id,
        call_bindings,
        temporal_streams,
        output_retention,
        constants,
    )
    return CompiledExecutionTarget(
        object_id,
        model,
        status_view.status,
        status_view.canonical_status,
        models,
        _runtime_model_temporal_inputs(
            status_view.temporal_inputs,
            temporal_streams,
        ),
        call_bindings,
        environment_binding,
        context,
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
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing,
)
    manual_application_ids = _manual_call_application_ids(compiled)
    groups = CompiledApplicationExecutionGroup[]
    batches = AbstractExecutionBatch[]
    for application in _ordered_model_applications(compiled)
        application.id in manual_application_ids && continue
        first_batch = length(batches) + 1
        targets = Any[
            _compiled_model_execution_target(
                compiled,
                env_bindings,
                application,
                object_id,
                temporal_streams,
                output_retention,
                constants,
            )
            for object_id in application.target_ids
        ]
        _append_model_execution_batches!(batches, application, targets)
        first_batch > length(batches) && continue
        push!(
            groups,
            CompiledApplicationExecutionGroup(
                application,
                batches[first_batch:end],
            ),
        )
    end
    return CompiledExecutionPlan(
        groups,
        batches,
        compiled.revision,
        env_bindings.environment_revision,
    )
end

function _model_execution_inputs_match(
    runtime_inputs::Tuple,
    compiled_inputs::Tuple,
)
    length(runtime_inputs) == length(compiled_inputs) || return false
    for index in eachindex(runtime_inputs)
        runtime_input = runtime_inputs[index]
        compiled_input = compiled_inputs[index]
        if runtime_input isa RuntimeTemporalInput
            runtime_input.compiled === compiled_input || return false
        else
            runtime_input === compiled_input || return false
        end
    end
    return true
end

function _model_execution_target_change_reason(
    target::CompiledExecutionTarget,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
)
    object_id = target.object_id
    key = (application.id, object_id)
    status_view = get(compiled.status_views_by_target, key, nothing)
    isnothing(status_view) && return :missing_status_view
    target.model === _application_model(application, object_id) ||
        return :model
    target.status === status_view.status || return :status_view
    target.canonical_status === status_view.canonical_status ||
        return :canonical_status
    target.models ===
    _model_models_for_application(compiled, application, object_id) ||
        return :model_bundle
    _model_execution_inputs_match(
        target.input_bindings,
        status_view.temporal_inputs,
    ) ||
        return :temporal_inputs
    target.call_bindings ===
    get(compiled.call_bindings_by_target, key, ()) ||
        return :call_bindings
    target.environment_binding === _environment_binding_for(
        env_bindings,
        application.id,
        object_id,
    ) || return :environment_binding
    return nothing
end

function _count_model_execution_target_rebuild!(::Nothing, reason)
    return nothing
end

function _count_model_execution_target_rebuild!(
    performance::RuntimePerformanceCounters,
    reason,
)
    counter = if reason === :new_target
        :execution_target_rebuild_new
    elseif reason === :missing_status_view
        :execution_target_rebuild_missing_status_view
    elseif reason === :model
        :execution_target_rebuild_model
    elseif reason === :status_view
        :execution_target_rebuild_status_view
    elseif reason === :canonical_status
        :execution_target_rebuild_canonical_status
    elseif reason === :model_bundle
        :execution_target_rebuild_model_bundle
    elseif reason === :temporal_inputs
        :execution_target_rebuild_temporal_inputs
    elseif reason === :call_bindings
        :execution_target_rebuild_call_bindings
    elseif reason === :environment_binding
        :execution_target_rebuild_environment_binding
    else
        :execution_target_rebuild_unknown
    end
    return _runtime_performance_count!(performance, counter)
end

function _model_execution_group_reusable(
    group::CompiledApplicationExecutionGroup,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
)
    group.application === application || return false
    target_index = 0
    for batch in group.batches
        for target in batch.targets
            target_index += 1
            target_index <= length(application.target_ids) || return false
            target.object_id == application.target_ids[target_index] ||
                return false
            isnothing(_model_execution_target_change_reason(
                target,
                compiled,
                env_bindings,
                application,
            )) || return false
        end
    end
    return target_index == length(application.target_ids)
end

function _refresh_model_execution_plan(
    previous::CompiledExecutionPlan,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing,
    performance=nothing,
)
    manual_application_ids = _manual_call_application_ids(compiled)
    previous_groups = Dict(
        group.application.id => group for group in previous.groups
    )
    groups = CompiledApplicationExecutionGroup[]
    batches = AbstractExecutionBatch[]
    targets_constructed = 0
    batches_constructed = 0
    groups_reused = 0

    for application in _ordered_model_applications(compiled)
        application.id in manual_application_ids && continue
        previous_group = get(previous_groups, application.id, nothing)
        if !isnothing(previous_group) &&
           _model_execution_group_reusable(
            previous_group,
            compiled,
            env_bindings,
            application,
        )
            push!(groups, previous_group)
            append!(batches, previous_group.batches)
            groups_reused += 1
            continue
        end

        targets = Any[]
        previous_batch_index = 1
        previous_target_index = 1
        for object_id in application.target_ids
            previous_target = nothing
            while !isnothing(previous_group) &&
                  previous_batch_index <= length(previous_group.batches)
                previous_batch =
                    previous_group.batches[previous_batch_index]
                if previous_target_index > length(previous_batch.targets)
                    previous_batch_index += 1
                    previous_target_index = 1
                    continue
                end
                candidate =
                    previous_batch.targets[previous_target_index]
                if candidate.object_id == object_id
                    previous_target = candidate
                    previous_target_index += 1
                    break
                elseif _object_id_isless(candidate.object_id, object_id)
                    previous_target_index += 1
                    continue
                end
                break
            end
            change_reason = isnothing(previous_target) ?
                            :new_target :
                            _model_execution_target_change_reason(
                previous_target,
                compiled,
                env_bindings,
                application,
            )
            if isnothing(change_reason)
                push!(targets, previous_target)
            else
                push!(
                    targets,
                    _compiled_model_execution_target(
                        compiled,
                        env_bindings,
                        application,
                        object_id,
                        temporal_streams,
                        output_retention,
                        constants,
                    ),
                )
                _count_model_execution_target_rebuild!(
                    performance,
                    change_reason,
                )
                targets_constructed += 1
            end
        end

        application_batches = AbstractExecutionBatch[]
        _append_model_execution_batches!(
            application_batches,
            application,
            targets,
        )
        isempty(application_batches) && continue
        push!(
            groups,
            CompiledApplicationExecutionGroup(
                application,
                application_batches,
            ),
        )
        append!(batches, application_batches)
        batches_constructed += length(application_batches)
    end

    return (
        plan=CompiledExecutionPlan(
            groups,
            batches,
            compiled.revision,
            env_bindings.environment_revision,
        ),
        targets_constructed=targets_constructed,
        batches_constructed=batches_constructed,
        groups_reused=groups_reused,
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
            call_bindings_type=fieldtype(eltype(batch.targets), :call_bindings),
            call_capability=isempty(first(batch.targets).call_bindings) ?
                            :no_calls :
                            :compiled_calls,
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

function _model_temporal_retention_horizon(
    binding,
    consumer,
    source,
    timeline,
)
    window_steps = _model_input_window_steps(binding, consumer, timeline)
    return if binding.policy isa Union{Integrate,Aggregate}
        float(window_steps) + max(0.0, float(source.clock.dt) - 1.0)
    elseif binding.policy isa Union{Interpolate,PreviousTimeStep}
        max(2.0, float(source.clock.dt) + 1.0)
    else
        0.0
    end
end

function _model_output_retention_covers_binding(
    plan::OutputRetentionPlan,
    compiled::CompiledCompositeModel,
    binding,
)
    plan.retain_all && return true
    consumer = _compiled_application_by_id(compiled, binding.application_id)
    for application_id in binding.source_application_ids
        source = _compiled_application_by_id(compiled, application_id)
        required = _model_temporal_retention_horizon(
            binding,
            consumer,
            source,
            compiled.timeline,
        )
        key = (application_id, binding.source_var)
        key in plan.temporal_dependencies || return false
        get(plan.dependency_horizons, key, -Inf) >= required || return false
    end
    return true
end

function _model_output_retention_covers_addition(
    plan::OutputRetentionPlan,
    previous_status_views,
    compiled::CompiledCompositeModel,
)
    for (key, view) in compiled.status_views_by_target
        get(previous_status_views, key, nothing) === view && continue
        for temporal_input in view.temporal_inputs
            _model_output_retention_covers_binding(
                plan,
                compiled,
                temporal_input.binding,
            ) || return false
        end
    end
    return true
end

function _model_status_view_refresh_is_pure_addition(
    previous_status_views,
    current_status_views,
)
    previous_keys = keys(previous_status_views)
    current_keys = keys(current_status_views)
    all(key -> haskey(current_status_views, key), previous_keys) || return false
    new_keys = [
        key for key in current_keys if !haskey(previous_status_views, key)
    ]
    isempty(new_keys) && return false
    previous_object_ids = Set(last(key) for key in previous_keys)
    added_object_ids = Set(
        last(key) for key in new_keys if !(last(key) in previous_object_ids)
    )
    isempty(added_object_ids) && return false
    return all(key -> last(key) in added_object_ids, new_keys)
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
        for application_id in binding.source_application_ids
            source = _compiled_application_by_id(compiled, application_id)
            required = _model_temporal_retention_horizon(
                binding,
                consumer,
                source,
                timeline,
            )
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
    status = _model_status_view_for_application(
        targets.compiled,
        application,
        object_id,
    ).status
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
        targets.environment,
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
    call_targets(context::RunContext, name::Symbol; objects=nothing)

Return a cached, non-executing vector-like view of the targets declared for
`name` with `Calls(...)`. The collection is empty for an unresolved
`OptionalOne`, has one element for `One`, and contains every resolved target
for `Many`.

When `objects` is provided, resolve the declared call against the current
object topology and restrict the result to those objects. This explicit form is
intended for models that create objects and immediately initialize selected
applications on them. Ordinary scheduled execution still observes structural
changes at the next timestep boundary. Each requested object may be an
[`ObjectId`](@ref), [`Object`](@ref), an MTG node, or the [`Status`](@ref)
returned by [`add_organ!`](@ref).

Use this accessor with [`run_call!(::CallTarget)`](@ref) when targets need
different meteorology, selective execution, a controlled order, or separate
trial and accepted publication.
"""
Base.@constprop :aggressive function call_targets(
    context::RunContext,
    name::Symbol,
    ;
    objects=nothing,
)
    isnothing(objects) ||
        return _current_topology_call_targets(context, name, objects)
    return _model_call_targets(context, name)
end

function _call_target_object_id(model::CompositeModel, target)
    target isa ObjectId && return target
    target isa Object && return target.id
    if target isa Status
        hasproperty(target, :node) || error(
            "A `Status` used as a hard-call object filter must contain its source `node`."
        )
        return _call_target_object_id(model, target.node)
    end
    adapter = model.source_adapter
    if adapter isa MTGObjectAdapter && target isa MultiScaleTreeGraph.Node
        return ObjectId(adapter.id(target))
    end
    return ObjectId(target)
end

function _call_target_object_ids(model::CompositeModel, objects)
    requested = objects isa Union{Tuple,AbstractVector,AbstractSet} ?
                objects : (objects,)
    ids = ObjectId[_call_target_object_id(model, object) for object in requested]
    unique!(ids)
    return ids
end

function _current_topology_call_targets(
    context::RunContext,
    name::Symbol,
    objects,
)
    model = runtime_model(context)
    compiled = refresh_bindings!(model)
    environment_bindings = refresh_environment_bindings!(model, compiled)
    bindings = get(
        compiled.call_bindings_by_target,
        (context.application.id, context.object_id),
        (),
    )
    binding = findfirst(
        candidate -> _compiled_call_name(candidate) === name,
        bindings,
    )
    if isnothing(binding)
        available = Symbol[candidate.call for candidate in bindings]
        error(
            "Application `$(context.application.id)` on object ",
            "`$(context.object_id.value)` did not declare call `$(name)`. ",
            "Declared calls: $(available).",
        )
    end
    resolved_binding = bindings[binding]
    requested_ids = _call_target_object_ids(model, objects)
    unresolved_ids = setdiff(requested_ids, resolved_binding.callee_object_ids)
    isempty(unresolved_ids) || error(
        "Hard call `$(name)` from application `$(context.application.id)` does not ",
        "resolve requested object(s) `$(Tuple(id.value for id in unresolved_ids))`."
    )
    selected_binding = CompiledModelCallBinding(
        resolved_binding.application_id,
        resolved_binding.consumer_id,
        resolved_binding.call,
        resolved_binding.selector,
        resolved_binding.origin,
        requested_ids,
        resolved_binding.callee_application_ids,
        resolved_binding.process,
        resolved_binding.application,
        resolved_binding.multiplicity,
    )
    return CallTargets(
        compiled,
        environment_bindings,
        selected_binding,
        context.temporal_streams,
        context.output_retention,
        context.time,
        context.constants,
        context.publication_allowed,
        context.environment,
    )
end

function _environment_binding_for_current_context(context::RunContext)
    binding = _environment_binding_for(
        context.environment_bindings,
        context.application.id,
        context.object_id,
    )
    if isnothing(binding) || isnothing(binding.backend)
        error(
            "Cannot commit environment state for `$(context.application.id)` on object ",
            "`$(context.object_id.value)`: no environment binding is configured. ",
            "Attach an environment with `CompositeModel(...; environment=...)` and ",
            "`ModelSpec(model) |> Environment(...)`."
        )
    end
    return binding
end

function _validate_environment_commit(context::RunContext, state)
    declared = Symbol.(collect(keys(meteo_outputs_(context.application.spec))))
    isempty(declared) && error(
        "Application `$(context.application.id)` cannot commit environment state because ",
        "its model declares no `meteo_outputs_` variables.",
    )
    missing = Symbol[variable for variable in declared if !hasproperty(state, variable)]
    isempty(missing) || error(
        "Environment state committed by application `$(context.application.id)` is missing ",
        "declared `meteo_outputs_` variable(s) `$(Tuple(missing))`.",
    )
    return nothing
end

"""
    commit_environment!(context::RunContext, state)

Commit an accepted environment `state` through the opaque handle compiled for
the currently running model application/object. The model must declare the
variables it commits with `meteo_outputs_`.

Commits are ignored while the current model is executing as a non-publishing
hard call. Trial environment states should instead be passed to
`run_call!(context, name; environment=state)`.
"""
function commit_environment!(context::RunContext, state)
    context.publication_allowed || return nothing
    binding = _environment_binding_for_current_context(context)
    _validate_environment_commit(context, state)
    return commit_environment!(
        binding.backend,
        binding.handle,
        state,
        context.time,
    )
end

function commit_environment!(context, state)
    throw(
        ArgumentError(
            "`commit_environment!` requires the compiled RunContext passed to a model kernel; got $(typeof(context)).",
        ),
    )
end

"""
    run_call!(target::CallTarget; publish=false, meteo=nothing)

Run one manually selected model call. By default, the call mutates its target
status without publishing outputs or environment updates, which is suitable
for trial iterations. Pass `publish=true` once for the accepted state. When
`meteo` is provided, it is forwarded directly to this target instead of using
its compiled environment binding. This is the fine-grained escape hatch for
one selected target; execute provider-aware trial states for all targets with
`run_call!(context, name; environment=state)`.

The method returns the same `CallTarget`.

Publication permission is inherited through the call stack. A descendant
cannot publish outputs or environment writes while any ancestor is running as
a trial.

For fine-grained control, obtain a collection with [`call_targets`](@ref), then
select or iterate its targets:

```julia
targets = call_targets(extra, :leaf_energy)
for (target, target_meteo) in zip(targets, leaf_meteo)
    run_call!(target; meteo=target_meteo, publish=false)
end

accepted = accepted_meteo(model, status)
commit_environment!(extra, accepted)
for target in targets
    run_call!(target; publish=true)
end
```
"""
@inline function _run_call!(
    target::CallTarget,
    publish::Bool,
    meteo,
    environment,
)
    _run_model_application!(
        target.compiled,
        target.environment_bindings,
        target.application,
        target.object_id,
        target.time,
        target.constants,
        target.temporal_streams,
        target.output_retention,
        publish && target.publication_allowed,
        meteo,
        environment,
    )
    return target
end

function run_call!(
    target::CallTarget;
    publish::Bool=false,
    meteo=_UNSPECIFIED_SCENE_METEO,
)
    return _run_call!(target, publish, meteo, target.environment)
end

"""
    run_call!(context::RunContext, name::Symbol; environment, publish=false)

Execute every target of the hard call declared as `name` and return its
[`CallTargets`](@ref) collection. The return shape is always vector-like:
`One` produces one element, `OptionalOne` zero or one, and `Many` zero or more.

When `environment` is supplied, every target keeps its own opaque compiled
backend handle and samples that transient backend-specific state. The state is
inherited by nested hard calls. Omit it to sample the committed backend state.

For finer-grained target selection, order, or direct per-target meteorology,
use [`call_targets`](@ref) and [`run_call!(::CallTarget)`](@ref). Commit an
accepted mutable state with [`commit_environment!`](@ref) before publishing the
accepted descendants.
"""
function run_call!(
    context::RunContext,
    name::Symbol;
    environment=_NO_ENVIRONMENT_OVERRIDE,
    publish::Bool=false,
    objects=nothing,
)
    targets = isnothing(objects) ?
              call_targets(context, name) :
              call_targets(context, name; objects=objects)
    selected_environment = environment isa NoEnvironmentOverride ?
                           context.environment :
                           environment
    for target in targets
        _run_call!(
            target,
            publish,
            _UNSPECIFIED_SCENE_METEO,
            selected_environment,
        )
    end
    return targets
end

function run_call!(
    context,
    name::Symbol;
    environment=_NO_ENVIRONMENT_OVERRIDE,
    publish::Bool=false,
    objects=nothing,
)
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
    if bindings_dirty(model) ||
       simulation.compiled.revision != model_revision(model)
        dirty_object_count = isnothing(model.binding_dirty_objects) ?
                             length(model.registry.objects) :
                             length(model.binding_dirty_objects)
        previous_status_views = simulation.compiled.status_views_by_target
        started_at = _runtime_performance_start(simulation.performance)
        simulation.compiled = refresh_bindings!(model)
        _runtime_performance_finish!(
            simulation.performance,
            :binding_refresh,
            started_at,
        )
        _runtime_performance_count!(
            simulation.performance,
            :binding_refreshes,
        )
        _runtime_performance_count!(
            simulation.performance,
            :dirty_binding_objects,
            dirty_object_count,
        )
        _runtime_performance_count!(
            simulation.performance,
            :status_views_constructed,
            count(
                key_and_view ->
                    get(
                        previous_status_views,
                        first(key_and_view),
                        nothing,
                    ) !== last(key_and_view),
                simulation.compiled.status_views_by_target,
            ),
        )
        pure_object_addition = _model_status_view_refresh_is_pure_addition(
            previous_status_views,
            simulation.compiled.status_views_by_target,
        )
        if pure_object_addition &&
           _model_output_retention_covers_addition(
            simulation.output_retention,
            previous_status_views,
            simulation.compiled,
        )
            _runtime_performance_count!(
                simulation.performance,
                :output_retention_reuses,
            )
        else
            started_at = _runtime_performance_start(simulation.performance)
            simulation.output_retention = compile_model_output_retention(
                simulation.compiled,
                simulation.output_requests;
                retain_all=simulation.output_retention.retain_all,
            )
            _runtime_performance_finish!(
                simulation.performance,
                :output_retention_compile,
                started_at,
            )
            _runtime_performance_count!(
                simulation.performance,
                :output_retention_compiles,
            )
        end
        _initialize_model_temporal_streams!(
            simulation.temporal_streams,
            simulation.compiled,
            simulation.output_retention,
        )
        started_at = _runtime_performance_start(simulation.performance)
        simulation.environment_bindings = refresh_environment_bindings!(
            model,
            simulation.compiled,
        )
        _runtime_performance_finish!(
            simulation.performance,
            :environment_refresh,
            started_at,
        )
        _runtime_performance_count!(
            simulation.performance,
            :environment_refreshes,
        )
        started_at = _runtime_performance_start(simulation.performance)
        execution_refresh = _refresh_model_execution_plan(
            simulation.execution_plan,
            simulation.compiled,
            simulation.environment_bindings,
            simulation.temporal_streams,
            simulation.output_retention,
            simulation.constants,
            simulation.performance,
        )
        simulation.execution_plan = execution_refresh.plan
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_compile,
            started_at,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_plan_compiles,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_targets_constructed,
            execution_refresh.targets_constructed,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_batches_constructed,
            execution_refresh.batches_constructed,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_groups_reused,
            execution_refresh.groups_reused,
        )
    elseif environment_bindings_dirty(model) ||
           simulation.environment_bindings.environment_revision !=
           environment_revision(model)
        started_at = _runtime_performance_start(simulation.performance)
        simulation.environment_bindings = refresh_environment_bindings!(
            model,
            simulation.compiled,
        )
        _runtime_performance_finish!(
            simulation.performance,
            :environment_refresh,
            started_at,
        )
        _runtime_performance_count!(
            simulation.performance,
            :environment_refreshes,
        )
        started_at = _runtime_performance_start(simulation.performance)
        execution_refresh = _refresh_model_execution_plan(
            simulation.execution_plan,
            simulation.compiled,
            simulation.environment_bindings,
            simulation.temporal_streams,
            simulation.output_retention,
            simulation.constants,
            simulation.performance,
        )
        simulation.execution_plan = execution_refresh.plan
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_compile,
            started_at,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_plan_compiles,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_targets_constructed,
            execution_refresh.targets_constructed,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_batches_constructed,
            execution_refresh.batches_constructed,
        )
        _runtime_performance_count!(
            simulation.performance,
            :execution_groups_reused,
            execution_refresh.groups_reused,
        )
    end
    return simulation
end

function _simulation_runtime_dirty(simulation::Simulation)
    model = simulation.model
    return bindings_dirty(model) ||
           simulation.compiled.revision != model_revision(model) ||
           environment_bindings_dirty(model) ||
           simulation.environment_bindings.environment_revision !=
           environment_revision(model)
end

function _run_model_execution_step!(simulation::Simulation, step::Integer)
    started_at = _runtime_performance_start(simulation.performance)
    empty!(simulation.environment_bindings.sample_cache)
    groups = simulation.execution_plan.groups
    group_index = firstindex(groups)
    completed_applications = nothing
    while group_index <= length(groups)
        group = groups[group_index]
        for batch in group.batches
            _run_model_execution_batch!(
                batch,
                simulation.compiled,
                simulation.environment_bindings,
                step,
                simulation.constants,
                simulation.temporal_streams,
                simulation.output_retention,
            )
            _runtime_performance_count!(
                simulation.performance,
                :execution_batches_visited,
            )
            _runtime_performance_count!(
                simulation.performance,
                :execution_targets_visited,
                length(batch.targets),
            )
        end
        _runtime_performance_count!(
            simulation.performance,
            :application_groups_visited,
        )

        if !_simulation_runtime_dirty(simulation)
            group_index += 1
            continue
        end
        if isnothing(completed_applications)
            completed_applications = Set(
                groups[index].application.id
                for index in firstindex(groups):group_index
            )
        else
            push!(completed_applications, group.application.id)
        end
        added_object_ids = bindings_dirty(simulation.model) &&
                           !isnothing(simulation.model.binding_dirty_objects) ?
                           copy(simulation.model.binding_dirty_objects) : nothing
        _refresh_simulation_runtime!(simulation)
        _refresh_output_request_targets!(simulation, added_object_ids)
        empty!(simulation.environment_bindings.sample_cache)
        groups = simulation.execution_plan.groups
        next_group = findfirst(
            candidate ->
                !(candidate.application.id in completed_applications),
            groups,
        )
        isnothing(next_group) && break
        group_index = next_group
    end
    _runtime_performance_finish!(
        simulation.performance,
        :step_execution,
        started_at,
    )
    _runtime_performance_count!(
        simulation.performance,
        :steps_executed,
    )
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
        _run_model_execution_step!(simulation, step)
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
            Dict(
                id => (
                    scale=_model_object(model, id).scale,
                    initial=getproperty(
                        _model_status_view_for_application(
                            compiled,
                            application,
                            id,
                        ).canonical_status,
                        request.var,
                    ),
                    start_time=0.0,
                )
                for id in object_ids
            ),
        )
    end
    return targets
end

function _refresh_output_request_targets!(simulation::Simulation, added_object_ids=nothing)
    for request in simulation.output_requests
        application_id, object_targets =
            simulation.output_request_targets[request.name]
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
                      length(matched_ids) :
                      length(union(Set(keys(object_targets)), Set(matched_ids)))
        if request.selector isa Union{One,OptionalOne} && match_count > 1
            error(
                "Output request `$(request.name)` expected at most one current object for selector ",
                "`$(request.selector)`, got $([id.value for id in matched_ids]).",
            )
        end
        application = _compiled_application_by_id(
            simulation.compiled,
            application_id,
        )
        for object_id in matched_ids
            haskey(object_targets, object_id) && continue
            object_targets[object_id] = (
                scale=_model_object(simulation.model, object_id).scale,
                initial=getproperty(
                    _model_status_view_for_application(
                        simulation.compiled,
                        application,
                        object_id,
                    ).canonical_status,
                    request.var,
                ),
                start_time=float(simulation.current_step + 1),
            )
        end
    end
    return simulation
end

"""
    run!(model; steps=1, constants=Constants(), outputs=:none, performance=false)

Run a fresh simulation timeline while mutating object status in `model`.
Choose `outputs=:none`, `outputs=:all`, one [`OutputRequest`](@ref), or a
vector of requests. Use [`continue!`](@ref) on the returned
[`Simulation`](@ref) to advance without resetting time. Set
`performance=true` to record coarse compiler/runtime timing and work counters
for diagnostics and performance regression tests.
"""
function run!(
    model::CompositeModel;
    steps::Integer=1,
    constants=PlantMeteo.Constants(),
    outputs=_UNSPECIFIED_SCENE_OUTPUTS,
    tracked_outputs=_UNSPECIFIED_SCENE_OUTPUTS,
    performance::Bool=false,
)
    performance_counters = performance ? RuntimePerformanceCounters() : nothing
    started_at = _runtime_performance_start(performance_counters)
    compiled = refresh_bindings!(model)
    _runtime_performance_finish!(
        performance_counters,
        :initial_binding_compile,
        started_at,
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_status_views_constructed,
        length(compiled.status_views_by_target),
    )
    started_at = _runtime_performance_start(performance_counters)
    env_bindings = refresh_environment_bindings!(model, compiled)
    _runtime_performance_finish!(
        performance_counters,
        :initial_environment_compile,
        started_at,
    )
    empty!(env_bindings.sample_cache)
    output_requests, retain_all = _model_output_selection(outputs, tracked_outputs)
    started_at = _runtime_performance_start(performance_counters)
    output_retention = compile_model_output_retention(
        compiled,
        output_requests;
        retain_all=retain_all,
    )
    _runtime_performance_finish!(
        performance_counters,
        :initial_output_retention_compile,
        started_at,
    )
    temporal_streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}()
    _initialize_model_temporal_streams!(
        temporal_streams,
        compiled,
        output_retention,
    )
    started_at = _runtime_performance_start(performance_counters)
    execution_plan = compile_model_execution_plan(
        compiled,
        env_bindings,
        temporal_streams,
        output_retention,
        constants,
    )
    _runtime_performance_finish!(
        performance_counters,
        :initial_execution_plan_compile,
        started_at,
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_execution_targets_constructed,
        sum((length(batch.targets) for batch in execution_plan.batches); init=0),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_execution_batches_constructed,
        length(execution_plan.batches),
    )
    started_at = _runtime_performance_start(performance_counters)
    output_request_targets = _initial_output_request_targets(
        model,
        compiled,
        output_requests,
    )
    _runtime_performance_finish!(
        performance_counters,
        :initial_output_target_compile,
        started_at,
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
        performance_counters,
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
    application = _compiled_application_by_id(sim.compiled, application_id)
    declared_scale = _selector_declared_scale(request.selector)
    timeline = _model_timeline(sim.model)
    clock = _model_request_clock(request, timeline)
    source_rows = [
        (
            object_id=object_id,
            scale=target.scale,
            samples=vcat(
                [(target.start_time, target.initial)],
                get(
                    sim.temporal_streams,
                    (application.id, object_id, request.var),
                    Tuple{Float64,typeof(target.initial)}[],
                ),
            ),
        )
        for (object_id, target) in requested_objects
    ]
    isempty(source_rows) && return NamedTuple[]
    nonempty_source_rows = [row for row in source_rows if !isempty(row.samples)]
    isempty(nonempty_source_rows) && return NamedTuple[]
    max_time = request.policy isa HoldLast ?
               sim.current_step :
               maximum(last(row.samples)[1] for row in nonempty_source_rows)
    rows = NamedTuple[]
    for time in 1:Int(floor(max_time))
        _should_run_at_time(clock, float(time)) || continue
        t_start = float(time) - float(clock.dt) + 1.0
        for row in sort!(nonempty_source_rows; by=row -> string(row.object_id.value))
            first_sample_time = first(row.samples)[1]
            is_current_target =
                haskey(sim.model.registry.objects, row.object_id) &&
                _selector_matches_object_id(
                    sim.model,
                    request.selector,
                    row.object_id;
                    context=request.context,
                )
            last_sample_time = request.policy isa HoldLast &&
                               is_current_target ?
                               float(sim.current_step) :
                               last(row.samples)[1]
            first_sample_time <= float(time) <= last_sample_time || continue
            push!(
                rows,
                (
                    timestep=time,
                    time=float(time),
                    scale=isnothing(declared_scale) ?
                          row.scale :
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
    started_at = _runtime_performance_start(sim.performance)
    collected = isempty(sim.output_requests) ?
                _materialize_model_output_rows(_model_output_rows(sim), sink) :
                _collect_model_requested_outputs(sim, sink)
    _runtime_performance_finish!(
        sim.performance,
        :output_collection,
        started_at,
    )
    _runtime_performance_count!(sim.performance, :output_collections)
    return collected
end

function collect_outputs(sim::Simulation, name::Symbol; sink=DataFrames.DataFrame)
    started_at = _runtime_performance_start(sim.performance)
    matches = [request for request in sim.output_requests if request.name == name]
    isempty(matches) && error(
        "No model output request named `$(name)`. Available request names are ",
        isempty(sim.output_requests) ? "none." : join((request.name for request in sim.output_requests), ", "),
    )
    length(matches) == 1 || error(
        "Duplicate model output request name `$(name)`. Request names must be unique."
    )
    request = only(matches)
    collected = _materialize_model_output_rows(
        _model_requested_output_rows(sim, request),
        sink,
    )
    _runtime_performance_finish!(
        sim.performance,
        :output_collection,
        started_at,
    )
    _runtime_performance_count!(sim.performance, :output_collections)
    return collected
end

function collect_outputs(sim::Simulation, object_id, variable::Symbol; sink=DataFrames.DataFrame)
    started_at = _runtime_performance_start(sim.performance)
    collected = _materialize_model_output_rows(
        _model_output_rows(sim, object_id, variable),
        sink,
    )
    _runtime_performance_finish!(
        sim.performance,
        :output_collection,
        started_at,
    )
    _runtime_performance_count!(sim.performance, :output_collections)
    return collected
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
