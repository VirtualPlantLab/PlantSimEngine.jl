struct OutputRetentionPlan
    retain_all::Bool
    temporal_dependencies::Set{Tuple{Symbol,Symbol}}
    requested_outputs::Set{Tuple{Symbol,Symbol}}
    dependency_horizons::Dict{Tuple{Symbol,Symbol},Float64}
    retained_outputs_by_application::Dict{Symbol,Vector{Symbol}}
    # Shared across call contexts and retained-plan refreshes. Empty accepted
    # calls matter too: newborns created afterwards first belong to the next
    # publication interval. Only explicitly requested manual apps are tracked.
    accepted_call_times::Dict{Symbol,Float64}
end

@inline _record_model_call_publication!(plan, application_id, time) = nothing

@inline function _record_model_call_publication!(
    plan::OutputRetentionPlan,
    application_id::Symbol,
    time::Float64,
)
    haskey(plan.accepted_call_times, application_id) &&
        (plan.accepted_call_times[application_id] = time)
    return nothing
end

mutable struct OutputRequestMembership{T}
    start_time::Float64
    end_time::Union{Nothing,Float64}
    initial::T
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

function _grow_temporal_dependency_buffer!(
    buffer::TemporalDependencyBuffer{T},
    capacity::Int,
) where {T}
    capacity <= length(buffer.times) && return buffer
    times = Vector{Float64}(undef, capacity)
    values = Vector{T}(undef, capacity)
    for index in eachindex(buffer)
        times[index], values[index] = buffer[index]
    end
    # Keep the buffer itself: compiled consumers and publishers share it.
    buffer.times = times
    buffer.values = values
    buffer.first_slot = 1
    return buffer
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

struct RuntimeOutputStream{V,S,R}
    stream::S
    reference::R
    dependency_horizon::Float64
end

_runtime_output_variable(::RuntimeOutputStream{V}) where {V} = V

"""Columnar retained streams for one distributed output variable."""
struct RuntimeDistributedOutputStream{V,B,S,R}
    binding::B
    streams::S
    references::R
    dependency_horizon::Float64
end

_runtime_output_variable(::RuntimeDistributedOutputStream{V}) where {V} = V

struct CompiledOutputPublication{V}
    variables::V
    enabled::Bool
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

function _same_compiled_binding_tuple(previous, current)
    length(previous) == length(current) || return false
    return all(
        previous[index] === current[index]
        for index in eachindex(previous)
    )
end

function _changed_compiled_binding_target_count(previous, current)
    return count(pairs(current)) do (key, bindings)
        previous_bindings = get(previous, key, nothing)
        isnothing(previous_bindings) ||
            !_same_compiled_binding_tuple(previous_bindings, bindings)
    end
end

function _removed_compiled_binding_target_count(previous, current)
    return count(key -> !haskey(current, key), keys(previous))
end

function _changed_environment_binding_count(previous, current)
    return count(pairs(current)) do (key, binding)
        get(previous, key, nothing) !== binding
    end
end

function _removed_environment_binding_count(previous, current)
    return count(key -> !haskey(current, key), keys(previous))
end

struct NoEnvironmentOverride end
const _NO_ENVIRONMENT_OVERRIDE = NoEnvironmentOverride()

include("call_evaluation_types.jl")

"""
    RunContext

Runtime context passed as the final argument to model kernels. Use
[`runtime_model`](@ref), [`bound_input`](@ref), [`output_targets`](@ref),
[`call_targets`](@ref), and [`run_call!`](@ref) instead of inspecting its
fields.
"""
mutable struct RunContext{CS,A,CT,BI,OT,TS,OR,C,E,I<:ObjectId,EB<:CompiledEnvironmentBindings}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::I
    calls::CT
    bound_inputs::BI
    output_targets::OT
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
    environment::E
end

# A manual target owns its execution shells. Keep the normal typed context and
# at most one transient specialization; materialized views share this lease.
mutable struct CallContextCache{C}
    const execution_stamp::Base.RefValue{UInt64}
    default::C
    transient::Any
    in_use::Bool
    evaluation::Union{Nothing,CallEvaluationFrame}
end

CallContextCache(context, stamp::Base.RefValue{UInt64}) =
    CallContextCache(stamp, context, nothing, false, nothing)

function RunContext(
    compiled,
    environment_bindings,
    application,
    object_id,
    calls,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed,
    environment,
)
    return RunContext(
        compiled,
        environment_bindings,
        application,
        object_id,
        calls,
        NamedTuple(),
        _runtime_model_output_targets(compiled, application, object_id),
        temporal_streams,
        output_retention,
        time,
        constants,
        publication_allowed,
        environment,
    )
end

function RunContext(
    compiled,
    environment_bindings,
    application,
    object_id,
    calls,
    bound_inputs,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed,
    environment,
)
    return RunContext(
        compiled,
        environment_bindings,
        application,
        object_id,
        calls,
        bound_inputs,
        _runtime_model_output_targets(compiled, application, object_id),
        temporal_streams,
        output_retention,
        time,
        constants,
        publication_allowed,
        environment,
    )
end

"""
    bound_input(context::RunContext, input)

Return an identity-aware [`BoundMany`](@ref) view for the declared `Many`
input named `input` on the application currently executing. The view reuses
the compiler-owned object identities and the live vector already installed in
the model status.
"""
@inline Base.@constprop :aggressive function bound_input(
    context::RunContext,
    input::Symbol,
)
    return bound_input(context, Val(input))
end

@inline function bound_input(
    context::RunContext,
    ::Val{input},
) where {input}
    hasproperty(context.bound_inputs, input) || throw(
        ArgumentError(
            "Application `$(context.application.id)` on object " *
            "`$(context.object_id.value)` has no declared Many input " *
            "`$(input)`. Available identity-aware inputs: " *
            "`$(propertynames(context.bound_inputs))`.",
        ),
    )
    return getproperty(context.bound_inputs, input)
end

function bound_input(context::RunContext, input)
    throw(
        ArgumentError(
            "`bound_input` expects a declared Many input name as a Symbol; " *
            "got `$(repr(input))` of type `$(typeof(input))` for application " *
            "`$(context.application.id)`.",
        ),
    )
end

function bound_input(context, input)
    throw(
        ArgumentError(
            "`bound_input` requires the compiled RunContext passed to a model " *
            "kernel; got `$(typeof(context))` for input `$(input)`.",
        ),
    )
end

"""
    output_targets(context::RunContext, variables::Tuple)

Return a compiled destination view for the named distributed outputs, for
example `output_targets(context, (:incident_par, :absorbed_par))`. A combined
view requires identical destination ObjectIds for every requested variable
and exposes only those columns. Use a one-element tuple for one variable.

Names resolve through the typed execution context; destination alignment is
prepared during compilation and refreshed after lifecycle changes.
"""
@inline Base.@constprop :aggressive function output_targets(
    context::RunContext,
    variables::Tuple,
)
    return output_targets(context, Val(variables))
end

@noinline function _missing_distributed_output_target(context, name)
    throw(ArgumentError(
        "Application `$(context.application.id)` on object `$(context.object_id.value)` " *
        "has no distributed output `$(name)`. Available variables: " *
        "`$(propertynames(context.output_targets))`.",
    ))
end

@noinline function _unaligned_distributed_output_targets(context, variables)
    throw(ArgumentError(
        "Distributed outputs `$(variables)` on application `$(context.application.id)` " *
        "have different destination ObjectIds. Request separate output target views.",
    ))
end

# Names are fixed by the kernel's tuple. Select each field explicitly so views
# spanning different destination declarations retain concrete carrier types.
@generated function output_targets(context::RunContext, ::Val{variables}) where {variables}
    if !(variables isa Tuple) || isempty(variables) || !all(name -> name isa Symbol, variables)
        return :(throw(ArgumentError("`output_targets` requires a non-empty tuple of output variable names.")))
    end
    if length(unique(variables)) != length(variables)
        return :(throw(ArgumentError("`output_targets` requires distinct output variable names.")))
    end
    checks = map(variables) do name
        :(hasproperty(context.output_targets, $(QuoteNode(name))) ||
          _missing_distributed_output_target(context, $(QuoteNode(name))))
    end
    first_name = QuoteNode(first(variables))
    alignment_checks = map(Base.tail(variables)) do name
        :(getproperty(context.output_targets, $(QuoteNode(name))).alignment_id == first_target.alignment_id ||
          _unaligned_distributed_output_targets(context, $(QuoteNode(variables))))
    end
    columns = Expr(:tuple, map(variables) do name
        :(getproperty(getproperty(context.output_targets, $(QuoteNode(name))).columns, $(QuoteNode(name))))
    end...)
    return quote
        $(checks...)
        first_target = getproperty(context.output_targets, $first_name)
        $(alignment_checks...)
        columns = NamedTuple{$(QuoteNode(variables))}($columns)
        binding = OutputTargetColumns(first_target.binding, columns)
        OutputTargets(binding, first_target.assignment_cache, first_target.alignment_id)
    end
end

function output_targets(context::RunContext, variables)
    throw(ArgumentError(
        "`output_targets` expects a non-empty tuple of output variable names; " *
        "got `$(repr(variables))` of type `$(typeof(variables))`.",
    ))
end

function output_targets(context, variables)
    throw(ArgumentError(
        "`output_targets` requires the compiled RunContext passed to a model kernel; " *
        "got `$(repr(context))` of type `$(typeof(context))`.",
    ))
end

"""
    CallTarget

One resolved executable target of a declared hard call. Obtain targets from a
[`CallTargets`](@ref) collection with [`call_targets`](@ref), then pass an
individual target to [`run_call!(::CallTarget)`](@ref). A target is a runtime
view owned by its compiled simulation; construct hard-call relationships with
`ModelSpec(...; calls=...)` rather than constructing this type directly.
"""
struct CallTarget{T,CS,EB,A,CT,TS,OR,C,E,I<:ObjectId}
    # Keep the execution owner by reference; only caller-specific metadata and
    # the descendant-call snapshot belong to a materialized view. Owners are
    # replaced when their model/status/binding identity changes.
    execution_target::T
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::I
    calls::CT
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
    environment::E
end

# Bind the existential variables once, rather than constructing fresh
# TypeVar/UnionAll objects while checking each singular target view.
const _SingleCallTargetView{T,CS,EB,A,TS,OR,C,I} =
    CallTarget{T,CS,EB,A,CT,TS,OR,C,E,I} where {CT,E}

# A dynamic batch lookup may erase payload/application/descendant/environment
# types. The collection still owns these five caller metadata types.
const _CallTargetMetadata{CS,EB,TS,OR,C} =
    CallTarget{T,CS,EB,A,CT,TS,OR,C,E,I} where {T,A,CT,E,I<:ObjectId}

# V fixes caller metadata while allowing descendant and environment types to change.
# The concrete mutable slot crosses the dispatch boundary without unboxing its
# immutable snapshot or erasing the metadata types needed by the caller.
mutable struct _TransientSingleCallSlot{V}
    snapshot::V
end

@inline function Base.getproperty(target::CallTarget, name::Symbol)
    name === :model && return getfield(getfield(target, :execution_target), :model)
    name === :status && return getfield(getfield(getfield(target, :execution_target), :status_view), :status)
    name === :canonical_status && return getfield(getfield(getfield(target, :execution_target), :status_view), :canonical_status)
    name === :temporal_inputs && return getfield(getfield(target, :execution_target), :input_bindings)
    name === :output_bindings && return getfield(getfield(target, :execution_target), :output_bindings)
    name === :bound_inputs && return getfield(getfield(target, :execution_target), :bound_inputs)
    name === :output_targets && return getfield(getfield(target, :execution_target), :output_targets)
    name === :environment_binding && return getfield(getfield(target, :execution_target), :environment_binding)
    name === :context_cache && return getfield(getfield(target, :execution_target), :call_context_cache)
    return getfield(target, name)
end

function Base.propertynames(::CallTarget, private::Bool=false)
    names = (
        :compiled, :environment_bindings, :application, :object_id, :model,
        :status, :canonical_status, :temporal_inputs, :output_bindings, :calls,
        :bound_inputs, :output_targets, :environment_binding, :temporal_streams,
        :output_retention, :time, :constants, :publication_allowed, :environment,
        :context_cache,
    )
    return private ? (names..., :execution_target) : names
end

abstract type AbstractExecutionBatch end

mutable struct LazyCallExecutionBatches <: AbstractVector{AbstractExecutionBatch}
    owner::Any
    batches::Any
end

LazyCallExecutionBatches() = LazyCallExecutionBatches(nothing, nothing)

struct _TrackedCallExecutionBatchCache
    # Keep the already-boxed runtime values behind `Any` fields. This cache is
    # itself stored behind an `Any` boundary; parameterizing its fields would
    # recover their types only through an existential cache type and re-box
    # them on every hot `Many` validity check or execution.
    batches::Any
    binding::Any
    membership_generation::UInt64
    compiled::Any
    environment_bindings::Any
end

Base.IndexStyle(::Type{LazyCallExecutionBatches}) = IndexLinear()

mutable struct _CallTargetBuffer{V}
    values::V
    batches::Any
    binding::Any
    compiled::Any
    environment_bindings::Any
    environment_type::Any
    in_use::Bool
end

mutable struct _CallTargetBufferCache
    first::Any
    second::Any
end

# A wrapper's invocation metadata can be synchronized while its execution
# batches remain a retained snapshot. Capture preparation independently so a
# leased old owner cannot share an obsolete One/OptionalOne tuple after growth.
struct CallTargetsPreparation{CS,EB,TS,OR,C}
    compiled::CS
    environment_bindings::EB
    temporal_streams::TS
    output_retention::OR
    constants::C
    model_revision::Int
    environment_revision::Int
    # The actual vector is an identity token, never a source of executable data.
    compiled_applications::Any
    membership_reference::Base.RefValue{UInt64}
    membership_generation::UInt64
end

function _call_targets_preparation(
    compiled, environment_bindings, binding, temporal_streams, output_retention, constants,
)
    return CallTargetsPreparation(
        compiled, environment_bindings, temporal_streams, output_retention, constants,
        compiled.revision, environment_bindings.environment_revision,
        environment_bindings.compiled_applications,
        getfield(binding, :membership_generation),
        _compiled_call_membership_generation(binding),
    )
end

"""
    CallTargets <: AbstractVector{CallTarget}

A cached vector-like view of the compiled targets for one declared hard call.
Retrieving it does not allocate a replacement collection. Obtain it with
[`call_targets`](@ref) or as the result of
[`run_call!(::RunContext, ::Symbol)`](@ref).

`collect(targets)` creates fresh target views and chooses their element type
from the values: homogeneous targets retain a concrete type, while mixed target
types widen as needed. Empty collections have element type `CallTarget`. Use
`collect(CallTarget, targets)` when the resulting vector must accept additional
target types. Each view captures its caller metadata and shares the live status
references; collecting does not copy numerical state.
"""
mutable struct CallTargets{CS,EB,B,TS,OR,C,BT,S} <: AbstractVector{CallTarget}
    compiled::CS
    environment_bindings::EB
    binding::B
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
    publication_allowed::Bool
    # This is synchronization metadata for explicitly materialized CallTarget
    # views, not part of the typed execution path. A transient backend override
    # may legitimately change its concrete type between invocations.
    environment::Any
    execution_batches::BT
    # Readiness of prepared storage only; ordinary Lazy batches retain their
    # existing cache state. A strict empty buffer may be cold, independently of
    # context freshness, so targeted calls do not invalidate pending full Many.
    execution_batches_materialized::Bool
    const batch_schema::S
    const tracks_full_membership::Bool
    preparation::CallTargetsPreparation{CS,EB,TS,OR,C}
    evaluation::Union{Nothing,CallEvaluationFrame}
    target_buffer_cache::Union{Nothing,_CallTargetBufferCache}
    # One singular snapshot or transient slot; numerical state stays in its owner.
    last_single_snapshot::Any
end

@inline function _invalidate_single_call_snapshot!(
    targets::CallTargets,
    compiled,
    environment_bindings,
)
    if targets.last_single_snapshot !== nothing &&
       (targets.compiled !== compiled ||
        targets.environment_bindings !== environment_bindings)
        targets.last_single_snapshot = nothing
    end
    return nothing
end

function CallTargets(
    compiled, environment_bindings, binding, temporal_streams, output_retention,
    time, constants, publication_allowed, environment;
    tracks_full_membership::Bool=true,
    batch_schema=OpenExecutionBatchSchema(),
)
    execution_batches = _call_execution_batches_for_schema(batch_schema,
        compiled, environment_bindings, binding, temporal_streams,
        output_retention, constants, tracks_full_membership)
    return _prepared_call_targets(compiled, environment_bindings, binding,
        temporal_streams, output_retention, time, constants, publication_allowed,
        environment, execution_batches, batch_schema, tracks_full_membership,
        _call_execution_batches_start_materialized(batch_schema, binding))
end

# Both graph preparation and a leased context's clone use this fully specified
# shell constructor. Execution owners and scientific reference carriers belong
# to the prepared batches; mutable views and their borrowing caches do not.
@inline function _prepared_call_targets(
    compiled, environment_bindings, binding, temporal_streams, output_retention,
    time, constants, publication_allowed, environment, execution_batches,
    batch_schema, tracks_full_membership::Bool, execution_batches_materialized::Bool,
)
    Storage = _call_execution_batch_storage_type(batch_schema, binding, execution_batches)
    targets = CallTargets{
        typeof(compiled), typeof(environment_bindings), typeof(binding),
        typeof(temporal_streams), typeof(output_retention), typeof(constants),
        Storage, typeof(batch_schema)
    }(
        compiled, environment_bindings, binding, temporal_streams, output_retention,
        float(time), constants, publication_allowed, environment, execution_batches,
        execution_batches_materialized, batch_schema, tracks_full_membership,
        _call_targets_preparation(
            compiled, environment_bindings, binding, temporal_streams, output_retention, constants,
        ),
        nothing, nothing, nothing,
    )
    execution_batches isa LazyCallExecutionBatches &&
        (execution_batches.owner = targets)
    return targets
end

@inline function _call_targets_preparation_is_current(
    targets::CallTargets, compiled, environment_bindings, temporal_streams,
    output_retention, constants,
)
    prepared = targets.preparation
    return prepared.compiled === compiled &&
           prepared.environment_bindings === environment_bindings &&
           prepared.temporal_streams === temporal_streams &&
           prepared.output_retention === output_retention &&
           prepared.constants === constants &&
           prepared.model_revision == compiled.revision &&
           prepared.environment_revision == environment_bindings.environment_revision &&
           prepared.compiled_applications === environment_bindings.compiled_applications &&
           prepared.membership_reference === getfield(targets.binding, :membership_generation) &&
           prepared.membership_generation == _compiled_call_membership_generation(targets.binding)
end

@inline _call_context_preparation_is_current(::Tuple{}, args...) = true

@inline function _call_context_preparation_is_current(
    calls::Tuple, compiled, environment_bindings, temporal_streams,
    output_retention, constants,
)
    _call_targets_preparation_is_current(
        first(calls), compiled, environment_bindings, temporal_streams,
        output_retention, constants,
    ) || return false
    return _call_context_preparation_is_current(
        Base.tail(calls), compiled, environment_bindings, temporal_streams,
        output_retention, constants,
    )
end

@inline _clone_call_execution_batches(batches::Tuple) = batches
@inline _clone_call_execution_batches(::Nothing) = nothing

@inline function _clone_call_execution_batches(batches::LazyCallExecutionBatches)
    # A lazy wrapper points at its owning CallTargets. Share its prepared state,
    # never its owner link; cloning must leave a cold Many membership cold.
    return LazyCallExecutionBatches(
        nothing, batches.batches,
    )
end

@inline _clone_runtime_call_targets(::Tuple{}, args...) = ()

@inline function _clone_runtime_call_targets(
    calls::Tuple, compiled, environment_bindings, temporal_streams,
    output_retention, time, constants, publication_allowed, environment,
)
    prototype = first(calls)
    targets = _prepared_call_targets(
        compiled, environment_bindings, prototype.binding, temporal_streams,
        output_retention, time, constants, publication_allowed, environment,
        _clone_call_execution_batches(prototype.execution_batches),
        prototype.batch_schema, prototype.tracks_full_membership,
        prototype.execution_batches_materialized,
    )
    remaining = _clone_runtime_call_targets(
        Base.tail(calls), compiled, environment_bindings, temporal_streams,
        output_retention, time, constants, publication_allowed, environment,
    )
    return (targets, remaining...)
end

function _current_call_binding_for_retained_view(compiled::CompiledCompositeModel,
    binding::CompiledModelCallBinding,
)
    return _compiled_application_by_id(compiled,binding.application_id) do application
        _current_call_binding_for_application(compiled,application,binding)
    end
end

@inline function _environment_bindings_match_compiled(
    environment_bindings,
    compiled::CompiledCompositeModel,
)
    return environment_bindings isa CompiledEnvironmentBindings &&
           environment_bindings.model_revision == compiled.revision &&
           environment_bindings.compiled_applications === compiled.applications
end

function _prebarrier_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    fallback,
)
    cached = compiled_environment_bindings(model)
    _environment_bindings_match_compiled(cached, compiled) && return cached
    _environment_bindings_match_compiled(fallback, compiled) && return fallback
    return nothing
end

function _synchronize_tracked_call_targets!(targets::CallTargets{CS,EB}) where {CS,EB}
    binding = targets.binding
    model = targets.compiled.model
    topology_dirty = bindings_dirty(model)
    cached = getfield(model,:binding_cache)
    current_compiled = if isnothing(cached)
        targets.compiled
    else
        cached isa CS || _unprepared_runtime_configuration()
        cached::CS
    end
    candidate_environment = topology_dirty ?
        _prebarrier_environment_bindings(model,current_compiled,targets.environment_bindings) :
        _refresh_environment_bindings!(model,current_compiled,
            _current_environment_binding_owner(model,targets.environment_bindings);
            environment_schema=targets.environment_bindings.environment_schema)
    if isnothing(candidate_environment)
        current_compiled = targets.compiled
        current_environment_bindings = targets.environment_bindings
    else
        candidate_environment isa EB || _unprepared_runtime_configuration()
        current_environment_bindings = candidate_environment::EB
    end
    _invalidate_single_call_snapshot!(targets,current_compiled,current_environment_bindings)
    if current_compiled !== targets.compiled
        current_binding = _current_call_binding_for_retained_view(current_compiled,binding)
        targets.compiled = current_compiled
        targets.binding = current_binding
    end
    targets.environment_bindings = current_environment_bindings
    return targets
end

@inline function _call_execution_batch_cache_is_current(
    cached::LazyCallExecutionBatches,
    targets::CallTargets,
)
    state = cached.batches
    isnothing(state) && return false
    targets.tracks_full_membership || return true
    state isa _TrackedCallExecutionBatchCache || return false
    return state.binding === targets.binding &&
           state.membership_generation ==
           _compiled_call_membership_generation(targets.binding) &&
           state.compiled === targets.compiled &&
           state.environment_bindings === targets.environment_bindings
end

@inline function _tracked_call_execution_batch_cache_can_reuse(
    cached::LazyCallExecutionBatches,
    targets::CallTargets,
)
    _call_execution_batch_cache_is_current(cached, targets) || return false
    model = targets.compiled.model
    if bindings_dirty(model)
        prebarrier_compiled = getfield(model, :binding_cache)
        if prebarrier_compiled isa CompiledCompositeModel
            prebarrier_compiled === targets.compiled || return false
        end
        prebarrier_environment = _prebarrier_environment_bindings(
            model,
            targets.compiled,
            targets.environment_bindings,
        )
        return prebarrier_environment === targets.environment_bindings
    end
    environment_bindings_dirty(model) && return false
    compiled_bindings(model) === targets.compiled || return false
    current_environment_bindings = compiled_environment_bindings(model)
    # With both dirty flags clear, the model-owned compiled and environment
    # caches are a coherent pair. Identity against both retained values is the
    # sufficient hot-path check; recomputing their revision/object identity
    # here introduces a small allocation before every materialized `Many` call.
    return current_environment_bindings === targets.environment_bindings
end

function _record_call_execution_batch_cache!(
    cached::LazyCallExecutionBatches,
    targets::CallTargets,
    batches;
    cohort_schema=OpenExecutionCohortSchema(),
)
    if targets.tracks_full_membership
        _retire_call_cohort_targets!(targets.temporal_streams, targets.binding, batches;
            schema=cohort_schema, batch_schema=targets.batch_schema)
    end
    targets.last_single_snapshot = nothing
    cached.batches = if targets.tracks_full_membership
        _TrackedCallExecutionBatchCache(
            batches,
            targets.binding,
            _compiled_call_membership_generation(targets.binding),
            targets.compiled,
            targets.environment_bindings,
        )
    else
        batches
    end
    targets.preparation = _call_targets_preparation(
        targets.compiled, targets.environment_bindings, targets.binding,
        targets.temporal_streams, targets.output_retention, targets.constants,
    )
    # Explicit `objects=` selections share the call owner's payloads with its
    # complete cached view. Only that complete membership can retire rows;
    # absence from one selection does not remove a target from the call.
    return batches
end

function _record_extended_call_execution_batch_cache!(
    targets::CallTargets,
    compiled::CompiledCompositeModel,
    environment_bindings::CompiledEnvironmentBindings,
    binding::CompiledModelCallBinding,
)
    targets.last_single_snapshot = nothing
    targets.preparation = _call_targets_preparation(
        compiled, environment_bindings, binding, targets.temporal_streams,
        targets.output_retention, targets.constants,
    )
    cached = targets.execution_batches
    cached isa LazyCallExecutionBatches || return targets
    targets.tracks_full_membership || return targets
    batches = _cached_call_execution_batches(targets)
    isnothing(batches) && return targets
    cached.batches = _TrackedCallExecutionBatchCache(
        batches,
        binding,
        _compiled_call_membership_generation(binding),
        compiled,
        environment_bindings,
    )
    return targets
end

@inline _materialize_call_execution_batches!(targets::CallTargets) =
    _materialize_call_execution_batches!(targets.batch_schema, targets)

function _materialize_open_call_execution_batches!(targets::CallTargets)
    cached = targets.execution_batches
    cached isa LazyCallExecutionBatches || return cached
    if targets.tracks_full_membership
        _tracked_call_execution_batch_cache_can_reuse(cached, targets) &&
            return _cached_call_execution_batches(targets)
        _synchronize_tracked_call_targets!(targets)
        _call_execution_batch_cache_is_current(cached, targets) &&
            return _cached_call_execution_batches(targets)
    elseif !isnothing(cached.batches)
        return cached.batches
    end
    # A complete manual `Many` view becomes lifecycle-tracked only here. Merely
    # retrieving the cached CallTargets wrapper, diagnostics, and targeted
    # `objects=` calls leave the full membership cold.
    if targets.tracks_full_membership
        _observe_compiled_call_membership!(
            targets.compiled,
            targets.binding;
            resolve_current=!bindings_dirty(targets.compiled.model),
        )
    end
    batches = _compiled_call_execution_batches(
        targets.compiled,
        targets.environment_bindings,
        targets.binding,
        targets.temporal_streams,
        targets.output_retention,
        targets.constants,
    )
    return _record_call_execution_batch_cache!(cached, targets, batches)
end

function _cached_call_execution_batches(targets::CallTargets)
    cached = targets.execution_batches
    cached isa LazyCallExecutionBatches || return cached
    state = cached.batches
    state isa _TrackedCallExecutionBatchCache && return state.batches
    return state
end

_call_execution_batches_materialized(targets::CallTargets) =
    !isnothing(_cached_call_execution_batches(targets))

Base.length(batches::LazyCallExecutionBatches) =
    length(_materialize_call_execution_batches!(batches.owner))

Base.size(batches::LazyCallExecutionBatches) = (length(batches),)

Base.getindex(batches::LazyCallExecutionBatches, index::Int) =
    getindex(_materialize_call_execution_batches!(batches.owner), index)

Base.iterate(batches::LazyCallExecutionBatches, state...) =
    iterate(_materialize_call_execution_batches!(batches.owner), state...)

Base.IndexStyle(::Type{<:CallTargets}) = IndexLinear()
Base.eltype(::Type{<:CallTargets}) = CallTarget

function _runtime_call_targets(
    compiled, environment_bindings, bindings::Tuple, temporal_streams,
    output_retention, time, constants, publication_allowed, environment;
    call_schema=OpenContextCallSchema(),
)
    return _assemble_runtime_call_targets(call_schema, compiled, environment_bindings,
        bindings, temporal_streams, output_retention, time, constants,
        publication_allowed, environment)
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
    _invalidate_single_call_snapshot!(targets, compiled, environment_bindings)
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

struct UnspecifiedModelEnvironment end
const _UNSPECIFIED_SCENE_ENVIRONMENT = UnspecifiedModelEnvironment()
struct RawGlobalModelEnvironment{M}
    sampled_environment::M
end

struct CachedGlobalModelEnvironment{B}
    binding::B
end

mutable struct CompiledExecutionTarget{M,V<:CompiledModelStatusView,IB,BI,OT,OB,CB,EB,RC,I<:ObjectId}
    object_id::I
    model::M
    const status_view::V
    input_bindings::IB
    bound_inputs::BI
    output_targets::OT
    output_bindings::OB
    call_bindings::CB
    call_bindings_signature::UInt
    environment_binding::EB
    context::RC
    call_context_cache::CallContextCache{RC}
end

function Base.show(io::IO, target::CompiledExecutionTarget)
    print(io, "CompiledExecutionTarget(", target.object_id,
        ", model=", nameof(typeof(target.model)), ")")
end

function _call_bindings_signature(call_bindings)
    signature = hash(length(call_bindings))
    for binding in call_bindings
        signature = hash(_compiled_call_name(binding), signature)
        # Lifecycle code advances this generation whenever either callee
        # vector changes, so signature refresh remains independent of the
        # number of organs selected by the call.
        signature = hash(
            _compiled_call_membership_generation(binding),
            signature,
        )
    end
    return signature
end

# Fully specified payload construction shared by scheduled, manual, and
# pre-barrier newborn execution. Binding resolution and cache ownership stay
# with their callers; this factory neither interns targets nor refreshes time.
function _compiled_execution_target(
    object_id::ObjectId,
    model,
    status_view::CompiledModelStatusView,
    input_bindings,
    bound_inputs,
    output_targets,
    output_bindings,
    call_bindings,
    environment_binding,
    context,
    call_context_cache::CallContextCache,
)
    return CompiledExecutionTarget(
        object_id, model, status_view, input_bindings, bound_inputs,
        output_targets, output_bindings, call_bindings,
        _call_bindings_signature(call_bindings), environment_binding,
        context, call_context_cache,
    )
end

mutable struct ExecutionBatchContextState
    # Scheduled root batches always use the default publication/environment
    # state. Hard-call batches deliberately bypass this synchronization cache.
    compiled::Any
    environment_bindings::Any
end

struct CompiledExecutionBatch{A,T<:AbstractVector,MP,OP} <: AbstractExecutionBatch
    application::A
    targets::T
    environment_provider::MP
    output_publication::OP
    context_state::ExecutionBatchContextState
end

CompiledExecutionBatch(
    application,
    targets,
    environment_provider,
    output_publication,
) = CompiledExecutionBatch(
    application,
    targets,
    environment_provider,
    output_publication,
    ExecutionBatchContextState(nothing, nothing),
)

mutable struct CompiledApplicationExecutionGroup{A,B,M<:ExecutionCohortMembership}
    application::A
    batches::B
    membership::M
end

function _compiled_application_execution_group(application, batches, membership;
    batch_schema=OpenExecutionBatchSchema(),
)
    if batch_schema isa PreparedExecutionBatchSchema
        return CompiledApplicationExecutionGroup(application,
            _finish_execution_batches(batch_schema,batches),membership)
    end
    if !isempty(batches)
        batch_type = typeof(first(batches))
        eltype(batches) === batch_type &&
            return CompiledApplicationExecutionGroup(application, batches, membership)
        if all(batch -> typeof(batch) === batch_type, batches)
            # Dispatch once at the application boundary, then retain the batch
            # schema through its loop. Counts and object identities remain
            # runtime data, including after same-schema lifecycle changes.
            typed = Vector{batch_type}(undef, length(batches))
            copyto!(typed, batches)
            return CompiledApplicationExecutionGroup(application, typed, membership)
        end
    end
    return CompiledApplicationExecutionGroup(application, batches, membership)
end

# Host preparation can declare an exact future batch family without creating
# an object, status, model invocation, sample, or a fake execution target.
function _empty_model_execution_group(application, ::Type{B}, cohorts::ExecutionCohortStore) where {B<:CompiledExecutionBatch}
    isempty(application.target_ids) || throw(ArgumentError("A future group must start with empty membership."))
    isconcretetype(B) && fieldtype(B, :application) === typeof(application) ||
        throw(ArgumentError("The batch schema does not match the prepared application."))
    Rows = fieldtype(B, :targets)
    Rows <: ExecutionCohortRows || throw(ArgumentError("Prepared batches require canonical cohort rows."))
    _execution_cohort(cohorts, nothing, application.id, eltype(Rows))
    schema = _execution_cohort_schema(Tuple{B})
    membership = _new_execution_cohort_membership(cohorts,nothing,application.id,0,schema)
    return CompiledApplicationExecutionGroup(application,B[],membership)
end

# Prepare the membership witness before fixing the group's container types.
# Batch/Rows/Target/context schemas are unchanged: only metadata vectors close.
function _close_execution_group_cohorts(group::CompiledApplicationExecutionGroup; batches=group.batches)
    schema = group.membership.schema isa ClosedExecutionCohortSchema ?
        group.membership.schema : _execution_cohort_schema(Tuple(group.batches))
    schema isa ClosedExecutionCohortSchema || throw(ArgumentError(
        "An empty group needs an explicit future batch witness before closure.",
    ))
    membership = _close_execution_cohort_membership(group.membership, schema)
    return CompiledApplicationExecutionGroup(group.application, batches, membership)
end

# Same-schema metadata refresh keeps the existing owner, including its formerly
# empty slot. A genuinely different open schema keeps the newly compiled group.
_retain_execution_group(::Nothing, current::CompiledApplicationExecutionGroup) = current
_retain_execution_group(previous::CompiledApplicationExecutionGroup, current::CompiledApplicationExecutionGroup) = current
function _retain_execution_group(previous::G, current::G) where {G<:CompiledApplicationExecutionGroup}
    previous.application === current.application || return current
    previous.batches = current.batches
    previous.membership = current.membership
    return previous
end

mutable struct RuntimeApplicationSchedule{P}
    const definition::P
    next_due_steps::Vector{Int}
    heap::Vector{Int}
    due_entry_indices::Vector{Int}
    last_step::Int
end

struct CompiledExecutionPlan{G,B,I,S,TP,C<:ExecutionCohortStore}
    cohorts::C
    topology::TP
    groups::G
    batches::B
    groups_by_application_slot::I
    schedule::S
    model_revision::Int
    environment_revision::Int
end

function _periodic_schedule_due_on_or_after(
    entry::CompiledApplicationScheduleEntry,
    first_step::Int,
)
    period_steps = something(entry.period_steps)
    phase_step = something(entry.phase_step)
    offset = mod(
        mod(phase_step, period_steps) - mod(first_step, period_steps),
        period_steps,
    )
    first_step > typemax(Int) - offset && return typemax(Int)
    return first_step + offset
end

@inline function _schedule_heap_isless(
    schedule::RuntimeApplicationSchedule,
    left::Int,
    right::Int,
)
    left_due = schedule.next_due_steps[left]
    right_due = schedule.next_due_steps[right]
    return left_due < right_due || (left_due == right_due && left < right)
end

function _schedule_heap_push!(
    schedule::RuntimeApplicationSchedule,
    entry_index::Int,
)
    heap = schedule.heap
    push!(heap, entry_index)
    child = length(heap)
    while child > 1
        parent = child >>> 1
        _schedule_heap_isless(schedule, heap[child], heap[parent]) || break
        heap[child], heap[parent] = heap[parent], heap[child]
        child = parent
    end
    return schedule
end

function _schedule_heap_pop!(schedule::RuntimeApplicationSchedule)
    heap = schedule.heap
    root = first(heap)
    tail = pop!(heap)
    isempty(heap) && return root
    heap[1] = tail
    parent = 1
    while true
        left = parent << 1
        left > length(heap) && break
        right = left + 1
        child = right <= length(heap) &&
                _schedule_heap_isless(schedule, heap[right], heap[left]) ?
                right : left
        _schedule_heap_isless(schedule, heap[child], heap[parent]) || break
        heap[parent], heap[child] = heap[child], heap[parent]
        parent = child
    end
    return root
end

function _runtime_application_schedule(
    plan::CompiledApplicationSchedule;
    after_step::Int=0,
)
    entry_count = length(plan.entries)
    schedule = RuntimeApplicationSchedule(
        plan,
        fill(typemax(Int), entry_count),
        Int[],
        Int[],
        after_step,
    )
    sizehint!(schedule.heap, length(plan.periodic_entry_indices))
    sizehint!(schedule.due_entry_indices, entry_count)
    first_step = after_step == typemax(Int) ? after_step : after_step + 1
    for entry_index in plan.periodic_entry_indices
        schedule.next_due_steps[entry_index] =
            _periodic_schedule_due_on_or_after(
                plan.entries[entry_index],
                first_step,
            )
        _schedule_heap_push!(schedule, entry_index)
    end
    return schedule
end

# Author/configuration refresh can replace the cadence or its root order.
# Ordinary lifecycle refresh shares its immutable definition and reuses the heap.
@inline function _refreshed_runtime_application_schedule(
    previous::RuntimeApplicationSchedule, definition::CompiledApplicationSchedule,
)
    previous.definition === definition && return previous
    return _runtime_application_schedule(definition; after_step=previous.last_step)
end

@inline function _generic_schedule_entry_is_due(
    entry::CompiledApplicationScheduleEntry,
    step::Int,
)
    return isapprox(
        mod(float(step) - entry.phase, entry.dt),
        0.0;
        atol=1.0e-8,
        rtol=0.0,
    )
end

function _due_application_schedule_entries!(
    schedule::RuntimeApplicationSchedule,
    plan::CompiledApplicationSchedule,
    step::Int,
)
    step > schedule.last_step || error(
        "Application schedule expected a step after $(schedule.last_step), got $(step).",
    )
    due = schedule.due_entry_indices
    empty!(due)
    for entry_index in plan.always_entry_indices
        push!(due, entry_index)
    end
    while !isempty(schedule.heap)
        entry_index = first(schedule.heap)
        schedule.next_due_steps[entry_index] <= step || break
        _schedule_heap_pop!(schedule)
        entry = plan.entries[entry_index]
        candidate = schedule.next_due_steps[entry_index]
        candidate < step &&
            (candidate = _periodic_schedule_due_on_or_after(entry, step))
        if candidate == step
            push!(due, entry_index)
            candidate = step == typemax(Int) ?
                        typemax(Int) :
                        _periodic_schedule_due_on_or_after(entry, step + 1)
        end
        schedule.next_due_steps[entry_index] = candidate
        candidate == typemax(Int) ||
            _schedule_heap_push!(schedule, entry_index)
    end
    for entry_index in plan.generic_entry_indices
        _generic_schedule_entry_is_due(plan.entries[entry_index], step) &&
            push!(due, entry_index)
    end
    sort!(due)
    schedule.last_step = step
    return due
end

function _execution_groups_by_application_slot(groups, application_count::Int)
    groups_by_slot = fill!(
        Vector{Union{Nothing,CompiledApplicationExecutionGroup}}(
            undef,
            application_count,
        ),
        nothing,
    )
    for index in eachindex(groups)
        _with_metadata_entry(groups, index) do group
            slot = group.application.slot
            1 <= slot <= application_count || throw(ArgumentError(
                "An execution group selected a slot outside the prepared application layout.",
            ))
            groups_by_slot[slot] = group
            return nothing
        end
    end
    return groups_by_slot
end

"""
    Simulation

Result of running a [`CompositeModel`](@ref). Use `outputs`, `collect_outputs`,
[`final_state`](@ref), and `PlantSimEngine.Diagnostics` to inspect it.
"""
mutable struct Simulation{S,CS,EB,EP,OR,TS,DT,R,RM,RT,C,P}
    model::S
    compiled::CS
    environment_bindings::EB
    execution_plan::EP
    output_retention::OR
    temporal_streams::TS
    output_datetimes::DT
    output_requests::R
    output_request_matchers::RM
    output_request_targets::RT
    output_request_model_revision::Int
    runtime_revision::Int
    current_step::Int
    constants::C
    performance::P
end

include("execution_batch_schemas.jl")
include("execution_extension_intents.jl")

function Base.show(io::IO, simulation::Simulation)
    print(
        io,
        "Simulation(steps=",
        simulation.current_step,
        ", objects=",
        length(simulation.model.registry.objects),
        ", applications=",
        length(simulation.compiled.applications),
        ", retained_streams=",
        length(simulation.temporal_streams),
        ")",
    )
end

function Base.show(io::IO, ::MIME"text/plain", simulation::Simulation)
    retained_streams = length(simulation.temporal_streams)
    println(io, "Simulation")
    println(io, "  elapsed steps: ", simulation.current_step)
    println(io, "  objects: ", length(simulation.model.registry.objects))
    println(io, "  applications: ", length(simulation.compiled.applications))
    print(io, "  retained streams: ", retained_streams)
    if iszero(retained_streams)
        print(
            io,
            "\n  hint: no output history retained; rerun with ",
            "`outputs=:all` or an `OutputRequest`.",
        )
    end
end

"""
    runtime_model(runtime)

Return the live [`CompositeModel`](@ref) owned by a `CompositeModel`, [`RunContext`](@ref),
or [`Simulation`](@ref). Lifecycle-capable models should call this
accessor instead of reaching through runtime implementation fields.
"""
runtime_model(model::CompositeModel) = model
runtime_model(context::RunContext) = context.compiled.model
runtime_model(target::CallTarget) = target.model
runtime_model(simulation::Simulation) = simulation.model
# A CallTarget exposes its scientific model through runtime_model; registry
# accessors still resolve identities and canonical state through its owner.
@inline _runtime_registry_owner(runtime::Union{RunContext,CallTarget}) = runtime.compiled.model
@inline _runtime_registry_owner(runtime::Simulation) = runtime.model
object_id(runtime::Union{RunContext,CallTarget,Simulation}, source) =
    object_id(_runtime_registry_owner(runtime), source)
model_object(runtime::Union{RunContext,CallTarget,Simulation}, source) =
    model_object(_runtime_registry_owner(runtime), source)
model_status(runtime::Union{RunContext,CallTarget,Simulation}, source) =
    model_status(_runtime_registry_owner(runtime), source)
source_node(runtime::Union{RunContext,CallTarget,Simulation}, source) =
    source_node(_runtime_registry_owner(runtime), source)

"""
    object_id(context::Union{RunContext,CallTarget})
    model_object(context::Union{RunContext,CallTarget})
    model_status(context::Union{RunContext,CallTarget})
    source_node(context::Union{RunContext,CallTarget})

Resolve the current execution target. `model_status(context)` returns the
canonical registry Status, not the application-local status view passed to the
kernel. `source_node(context)` is available for MTG-backed models and avoids
requiring a topology node inside that local status view.
"""
object_id(runtime::Union{RunContext,CallTarget}) =
    object_id(_runtime_registry_owner(runtime), getfield(runtime, :object_id))
model_object(runtime::Union{RunContext,CallTarget}) =
    model_object(_runtime_registry_owner(runtime), object_id(runtime))
model_status(runtime::Union{RunContext,CallTarget}) =
    model_status(_runtime_registry_owner(runtime), object_id(runtime))
source_node(runtime::Union{RunContext,CallTarget}) =
    source_node(_runtime_registry_owner(runtime), object_id(runtime))
current_step(simulation::Simulation) = simulation.current_step

outputs(sim::Simulation) = sim.temporal_streams

@inline function _final_state_snapshot(simulation::Simulation, object_id)
    return deepcopy(NamedTuple(_model_object_status(simulation.model, ObjectId(object_id))))
end

"""
    final_state(simulation)
    final_state(simulation, object_id)
    final_state(simulation, selector; context=nothing)

Return a `NamedTuple` snapshot of the latest canonical object status.
The no-selector form requires the simulation to contain exactly one object.
`One` returns one snapshot, `OptionalOne` returns one snapshot or `nothing`,
and `Many` returns a dictionary from object ids to snapshots.

This accessor reports final state, independently of output retention. Use
`collect_outputs` for retained history.
"""
final_state(simulation::Simulation) = final_state(simulation, One())

function final_state(simulation::Simulation, object_id)
    return _final_state_snapshot(simulation, object_id)
end

function final_state(
    simulation::Simulation,
    selector::AbstractObjectMultiplicity;
    context=nothing,
)
    object_ids = resolve_object_ids(
        simulation.model,
        selector;
        context=context,
    )
    if selector isa One
        return _final_state_snapshot(simulation, only(object_ids))
    elseif selector isa OptionalOne
        return isempty(object_ids) ?
               nothing :
               _final_state_snapshot(simulation, only(object_ids))
    end
    return Dict(
        object_id.value => _final_state_snapshot(simulation, object_id)
        for object_id in object_ids
    )
end

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

const _IMMUTABLE_PLAN_PERFORMANCE_METRICS = Set((
    :scenario_plan_compile,
    :initial_application_plans_compiled,
    :initial_application_schedule_entries_compiled,
    :initial_input_plans_compiled,
    :initial_call_plans_compiled,
))

const _OBJECT_TARGET_PERFORMANCE_METRICS = Set((
    :application_target_compile,
    :call_binding_compile,
    :input_binding_compile,
    :status_view_compile,
    :initial_status_views_constructed,
    :initial_input_bindings_constructed,
    :initial_call_bindings_constructed,
    :initial_environment_compile,
    :initial_environment_bindings_constructed,
    :initial_output_retention_compile,
    :initial_execution_plan_compile,
    :initial_execution_plan_and_model_bundle_compile,
    :initial_execution_targets_constructed,
    :initial_execution_batches_constructed,
    :initial_output_target_compile,
))

const _INITIAL_TOTAL_PERFORMANCE_METRICS = Set((
    :initial_binding_compile,
    :initial_composite_compile,
))

@inline function _runtime_performance_phase(metric::Symbol)
    metric in _IMMUTABLE_PLAN_PERFORMANCE_METRICS &&
        return :immutable_plan_compilation
    metric in _OBJECT_TARGET_PERFORMANCE_METRICS &&
        return :object_target_instantiation
    metric in _INITIAL_TOTAL_PERFORMANCE_METRICS &&
        return :initial_compilation_total
    name = String(metric)
    (startswith(name, "lifecycle_") ||
     occursin("_refresh", name) ||
     occursin("_delta", name) ||
     occursin("_reused", name) ||
     occursin("_rebuilt", name)) &&
        return :lifecycle_buffer_update
    startswith(name, "output_collection") && return :output_collection
    return :steady_state_execution
end

"""
    explain_runtime_performance(simulation)

Group the opt-in counters produced by `run!(...; performance=true)` into
immutable plan compilation, object-target instantiation, lifecycle buffer
updates, steady-state execution, output collection, and initial-total rows.
Each row reports either or both of `count` and `elapsed_seconds`. The function
returns an empty vector when performance instrumentation was disabled.
"""
function explain_runtime_performance(simulation::Simulation)
    performance = runtime_performance(simulation)
    isnothing(performance) && return NamedTuple[]
    metrics = union(
        Set(keys(performance.counts)),
        Set(keys(performance.elapsed_seconds)),
    )
    rows = [
        (
            phase=_runtime_performance_phase(metric),
            metric=metric,
            count=get(performance.counts, metric, nothing),
            elapsed_seconds=get(
                performance.elapsed_seconds,
                metric,
                nothing,
            ),
        )
        for metric in metrics
    ]
    sort!(rows; by=row -> (string(row.phase), string(row.metric)))
    return rows
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
explain_writers(sim::Simulation) = explain_writers(sim.compiled)
explain_environment_bindings(sim::Simulation) =
    explain_environment_bindings(sim.environment_bindings)

@inline function _compiled_application_by_id(f::F, compiled::CompiledCompositeModel,
    id::Symbol,
) where {F}
    haskey(compiled.applications_by_id, id) ||
        error("No compiled model application with id `$(id)`.")
    return _with_metadata_entry(f, compiled.applications_by_id, id)
end

_compiled_application_by_id(compiled::CompiledCompositeModel, id::Symbol) =
    _compiled_application_by_id(identity, compiled, id)

function _environment_binding_for(env_bindings::CompiledEnvironmentBindings, application_id::Symbol, object_id::ObjectId)
    binding = get(env_bindings.by_target, (application_id, object_id), nothing)::Union{Nothing,CompiledEnvironmentBinding}
    isnothing(binding) && return nothing
    return _with_environment_binding(identity, env_bindings.environment_schema, binding)
end

function _model_object_status(model::CompositeModel, object_id::ObjectId)
    status = model_status(model, object_id)
    status isa Status || error(
        "CompositeModel object `$(object_id.value)` has no `Status`; model runtime requires status-backed objects."
    )
    return status
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
    return compiled.status_views_by_target[key]::CompiledModelStatusView
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

function _model_output_object_ids(
    compiled,
    application,
    variable::Symbol,
    ::NoCompiledDistributedOutputs,
)
    return application.target_ids
end

function _model_output_object_ids(
    compiled,
    application,
    variable::Symbol,
    distributed_outputs::CompiledDistributedOutputs,
)
    destination_ids = get(
        distributed_outputs.destination_ids_by_application_variable,
        (application.id, variable),
        nothing,
    )
    variable in _model_output_names(application) ||
        return isnothing(destination_ids) ? ObjectId[] : destination_ids
    isnothing(destination_ids) && return application.target_ids
    object_ids = copy(application.target_ids)
    append!(object_ids, destination_ids)
    _sort_object_ids!(object_ids)
    unique!(object_ids)
    return object_ids
end

_model_output_object_ids(compiled, application, variable::Symbol) =
    _model_output_object_ids(
        compiled,
        application,
        variable,
        compiled.distributed_outputs,
    )

function _model_output_reference(
    compiled,
    application,
    object_id::ObjectId,
    variable::Symbol,
)
    if variable in _model_output_names(application) &&
       haskey(
           compiled.status_views_by_target,
           (application.id, object_id),
       )
        status = _model_status_view_for_application(
            compiled,
            application,
            object_id,
        ).status
        return refvalue(status, variable)
    end
    return refvalue(
        _model_object(compiled.model, object_id).status,
        variable,
    )
end

function _initialize_model_output_stream!(
    streams,
    compiled::CompiledCompositeModel,
    retention::OutputRetentionPlan,
    application,
    object_id::ObjectId,
    variable::Symbol,
    sizehint_steps::Integer,
)
    key = _model_stream_key(application.id, object_id, variable)
    if haskey(streams, key)
        stream = streams[key]
        if stream isa TemporalDependencyBuffer
            _grow_temporal_dependency_buffer!(
                stream,
                _model_dependency_capacity(retention, application.id, variable),
            )
        end
        return streams
    end
    reference = _model_output_reference(
        compiled,
        application,
        object_id,
        variable,
    )
    isnothing(reference) && error(
        "Application `$(application.id)` declares retained output ",
        "`$(variable)`, but object `$(object_id.value)` status has no ",
        "such variable.",
    )
    stream = _model_new_output_stream(
        reference[],
        retention,
        application.id,
        variable,
    )
    if stream isa Vector && sizehint_steps > 0
        sizehint!(
            stream,
            max(
                1,
                ceil(
                    Int,
                    float(sizehint_steps) /
                    float(application.clock.dt),
                ),
            ),
        )
    end
    streams[key] = stream
    return streams
end

function _initialize_changed_model_output_streams!(
    streams,
    compiled::CompiledCompositeModel,
    retention::OutputRetentionPlan,
    sizehint_steps::Integer,
    target_keys,
)
    for (application_id, object_id) in target_keys
        variables = get(
            retention.retained_outputs_by_application,
            application_id,
            (),
        )
        isempty(variables) && continue
        _compiled_application_by_id(compiled, application_id) do application
            model_outputs = _model_output_names(application)
            if haskey(compiled.status_views_by_target, (application_id, object_id))
                for variable in variables
                    variable in model_outputs || continue
                    _initialize_model_output_stream!(
                        streams,
                        compiled,
                        retention,
                        application,
                        object_id,
                        variable,
                        sizehint_steps,
                    )
                end
            end
            compiled.distributed_outputs isa CompiledDistributedOutputs || return nothing
            groups = get(
                compiled.distributed_outputs.by_execution_target,
                (application_id, object_id),
                nothing,
            )
            isnothing(groups) && return nothing
            for binding in values(groups)
                for variable_ in binding.plan.variable_names
                    variable = Symbol(variable_)
                    variable in variables || continue
                    for destination_id in binding.destination_ids
                        _initialize_model_output_stream!(
                            streams,
                            compiled,
                            retention,
                            application,
                            destination_id,
                            variable,
                            sizehint_steps,
                        )
                    end
                end
            end
        end
    end
    return streams
end

function _initialize_model_output_streams!(
    streams,
    compiled::CompiledCompositeModel,
    retention::OutputRetentionPlan,
    sizehint_steps::Integer=0,
    target_keys=nothing,
)
    !isnothing(target_keys) && return _initialize_changed_model_output_streams!(
        streams,
        compiled,
        retention,
        sizehint_steps,
        target_keys,
    )
    for (application_id, variables) in retention.retained_outputs_by_application
        _compiled_application_by_id(compiled, application_id) do application
            for variable in variables
                for object_id in _model_output_object_ids(
                    compiled,
                    application,
                    variable,
                )
                    _initialize_model_output_stream!(
                        streams,
                        compiled,
                        retention,
                        application,
                        object_id,
                        variable,
                        sizehint_steps,
                    )
                end
            end
        end
    end
    return streams
end

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

@inline function _model_publish_sample!(samples, sample_time::Float64, value; copy_value::Bool=true)
    if !isempty(samples) &&
       isapprox(last(samples)[1], sample_time; atol=1.0e-8, rtol=0.0)
        pop!(samples)
    elseif !isempty(samples) && last(samples)[1] > sample_time
        _model_remove_sample_time!(samples, sample_time)
    end
    # A model may update an array or a nested mutable value in place on its next
    # execution. Published history must remain independent of that live state.
    # `deepcopy` leaves scalar/isbits values unchanged.
    push!(samples, (sample_time, copy_value ? deepcopy(value) : value))
    return samples
end

@inline function _model_prune_dependency_samples!(stream, sample_time::Float64, horizon::Float64)
    stream isa TemporalDependencyBuffer || return nothing
    cutoff = horizon <= 0.0 ? sample_time : sample_time - horizon + 1.0
    # Keep a preceding sample for PreviousTimeStep and linear extrapolation
    # when fractional clocks or manual calls leave a gap in the cadence.
    while length(stream) > 2 && first(stream)[1] < cutoff - 1.0e-8
        _temporal_dependency_popfirst!(stream)
    end
    return nothing
end

@inline function _model_publish_runtime_output_value!(
    output,
    stream,
    value,
    time::Real,
    ; copy_value::Bool=true,
)
    expected_type = fieldtype(eltype(stream), 2)
    value isa expected_type || error(
        "Output `$(_runtime_output_variable(output))` changed value type from ",
        "`$(expected_type)` to `$(typeof(value))`. CompositeModel temporal ",
        "streams require a stable output type.",
    )
    sample_time = Float64(time)
    _model_publish_sample!(
        stream,
        sample_time,
        value,
        ; copy_value=copy_value,
    )
    _model_prune_dependency_samples!(stream, sample_time, output.dependency_horizon)
    return nothing
end

@inline function _model_publish_runtime_output!(
    output::RuntimeOutputStream,
    time::Real,
)
    _model_publish_runtime_output_value!(
        output,
        output.stream,
        output.reference[],
        time,
    )
    return nothing
end

@inline function _model_publish_runtime_output!(
    output::RuntimeDistributedOutputStream,
    time::Real,
)
    references = output.references
    streams = output.streams
    @inbounds for index in eachindex(references)
        _model_publish_runtime_output_value!(
            output,
            streams[index],
            references[index],
            time,
        )
    end
    return nothing
end

@inline _model_publish_runtime_outputs!(::Tuple{}, time::Real) = nothing

@inline function _model_publish_runtime_outputs!(
    outputs::Tuple,
    time::Real,
)
    _model_publish_runtime_output!(first(outputs), time)
    _model_publish_runtime_outputs!(Base.tail(outputs), time)
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

@inline function _model_latest_sample(
    samples::TemporalDependencyBuffer,
    time::Real,
)
    requested_time = float(time)
    capacity = length(samples.times)
    for offset in (samples.sample_count - 1):-1:0
        slot = mod1(samples.first_slot + offset, capacity)
        sample_time = @inbounds samples.times[slot]
        sample_time <= requested_time &&
            return @inbounds samples.values[slot]
    end
    return nothing
end

function _model_linear_value(v_left, v_right, α)
    interpolation_factor = if typeof(v_left) === typeof(v_right) &&
                              v_left isa AbstractFloat
        convert(typeof(v_left), α)
    elseif typeof(v_left) === typeof(v_right) &&
           v_left isa Array{<:AbstractFloat}
        convert(eltype(v_left), α)
    else
        α
    end
    applicable(-, v_right, v_left) || return nothing
    delta = v_right - v_left
    increment = if applicable(*, interpolation_factor, delta)
        interpolation_factor * delta
    elseif applicable(*, delta, interpolation_factor)
        delta * interpolation_factor
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
    explicit = _model_duration_steps(getfield(binding, :plan).window, timeline)
    !isnothing(explicit) && return explicit
    getfield(binding, :policy) isa Union{Integrate,Aggregate} &&
        return float(application.clock.dt)
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
            "Temporal input `$(getfield(temporal_input.binding, :plan).input)` changed shape from ",
            "`$(axes(current))` to ",
            "`$(axes(value))`; use a stable vector shape or a `Many(...)` binding.",
        )
        private_value = isbitstype(eltype(value)) ? value : _private_temporal_value(value)
        copyto!(current, private_value)
        return temporal_input
    end
    temporal_input.reference[] = _private_temporal_value(value)
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
    plan = getfield(binding, :plan)
    source_ids = getfield(binding, :source_ids)
    policy = getfield(binding, :policy)
    window_steps = _model_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    if plan.multiplicity == :many
        storage = temporal_input.reference[]
        storage isa AbstractVector || error(
            "Temporal `Many` input `$(plan.input)` on application ",
            "`$(plan.application_id)` has non-vector private storage ",
            "`$(typeof(storage))`.",
        )
        length(storage) == length(source_ids) || error(
            "Temporal `Many` input `$(plan.input)` on application ",
            "`$(plan.application_id)` has $(length(storage)) private values for ",
            "$(length(source_ids)) resolved source objects. Refresh the ",
            "compiled lifecycle bindings before execution.",
        )
        for index in eachindex(source_ids)
            value = _model_temporal_source_value(
                streams,
                temporal_input.source_applications[index],
                source_ids[index],
                plan.source_var,
                time,
                policy,
                t_start,
                timeline,
            )
            if isnothing(value)
                policy isa PreviousTimeStep || error(
                    "No temporal model value available for input ",
                    "`$(plan.input)` from ",
                    "`$(source_ids[index].value).$(plan.source_var)` ",
                    "at t=$(time).",
                )
                value = temporal_input.initial[index]
            end
            storage[index] = _private_temporal_value(value)
        end
        return status
    end
    source_id = only(source_ids)
    value = _model_temporal_source_value(
        streams,
        only(temporal_input.source_applications),
        source_id,
        plan.source_var,
        time,
        policy,
        t_start,
        timeline,
    )
    if isnothing(value)
        policy isa PreviousTimeStep || error(
            "No temporal model value available for input `$(plan.input)` from ",
            "`$(source_id.value).$(plan.source_var)` at t=$(time).",
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
    return _materialize_model_temporal_input!(
        status,
        runtime_input,
        application,
        streams,
        time,
        timeline,
        getfield(runtime_input.compiled.binding, :policy),
    )
end

@inline function _previous_time_step_sample(samples, time::Real)
    return _model_latest_sample(samples, float(time) - 1.0)
end

@inline _previous_time_step_sample(::Nothing, time::Real) = nothing

@inline function _previous_time_step_sample(
    samples::TemporalDependencyBuffer,
    time::Real,
)
    remaining = samples.sample_count
    remaining == 0 && return nothing
    capacity = length(samples.times)
    slot = samples.first_slot + remaining - 1
    slot > capacity && (slot -= capacity)
    requested_time = float(time) - 1.0
    while remaining > 0
        sample_time = @inbounds samples.times[slot]
        sample_time <= requested_time &&
            return @inbounds samples.values[slot]
        slot = slot == 1 ? capacity : slot - 1
        remaining -= 1
    end
    return nothing
end

@inline function _materialize_previous_time_step_input!(
    temporal_input,
    source_streams,
    time::Real,
    ::Many,
)
    storage = temporal_input.reference[]
    initial = temporal_input.initial
    @boundscheck length(storage) == length(source_streams) || error(
        "Temporal `Many` input `$(getfield(temporal_input.binding, :plan).input)` has ",
        "$(length(storage)) private values for $(length(source_streams)) ",
        "compiled source streams. Refresh the compiled lifecycle bindings ",
        "before execution.",
    )
    @inbounds for index in eachindex(source_streams)
        value = _previous_time_step_sample(source_streams[index], time)
        if isnothing(value)
            storage[index] = _private_temporal_value(initial[index])
        else
            storage[index] = _private_temporal_value(value)
        end
    end
    return temporal_input
end

@inline function _materialize_previous_time_step_input!(
    temporal_input,
    source_stream,
    time::Real,
    selector,
)
    value = _previous_time_step_sample(source_stream, time)
    isnothing(value) && (value = temporal_input.initial)
    return _model_assign_private_temporal_value!(temporal_input, value)
end

@inline function _materialize_model_temporal_input!(
    status::Status,
    runtime_input::RuntimeTemporalInput,
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
    ::PreviousTimeStep,
)
    temporal_input = runtime_input.compiled
    _materialize_previous_time_step_input!(
        temporal_input,
        runtime_input.source_streams,
        time,
        getfield(temporal_input.binding, :plan).selector,
    )
    return status
end

function _materialize_model_temporal_input!(
    status::Status,
    runtime_input::RuntimeTemporalInput,
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
    policy,
)
    temporal_input = runtime_input.compiled
    binding = temporal_input.binding
    plan = getfield(binding, :plan)
    source_ids = getfield(binding, :source_ids)
    policy = getfield(binding, :policy)
    window_steps = _model_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    if plan.multiplicity == :many
        storage = temporal_input.reference[]
        storage isa AbstractVector || error(
            "Temporal `Many` input `$(plan.input)` on application ",
            "`$(plan.application_id)` has non-vector private storage ",
            "`$(typeof(storage))`.",
        )
        length(storage) == length(source_ids) || error(
            "Temporal `Many` input `$(plan.input)` on application ",
            "`$(plan.application_id)` has $(length(storage)) private values for ",
            "$(length(source_ids)) resolved source objects. Refresh the ",
            "compiled lifecycle bindings before execution.",
        )
        for index in eachindex(source_ids)
            value = _evaluated_temporal_sample_value(
                runtime_input.source_streams[index],
                time,
                policy,
                t_start,
                timeline,
            )
            if isnothing(value)
                policy isa PreviousTimeStep || error(
                    "No temporal model value available for input ",
                    "`$(plan.input)` from ",
                    "`$(source_ids[index].value).$(plan.source_var)` ",
                    "at t=$(time).",
                )
                value = temporal_input.initial[index]
            end
            storage[index] = _private_temporal_value(value)
        end
        return status
    end
    source_id = only(source_ids)
    value = _evaluated_temporal_sample_value(
        runtime_input.source_streams,
        time,
        policy,
        t_start,
        timeline,
    )
    if isnothing(value)
        policy isa PreviousTimeStep || error(
            "No temporal model value available for input `$(plan.input)` from ",
            "`$(source_id.value).$(plan.source_var)` at t=$(time).",
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
    timeline = compiled.scenario_plan.timeline
    return _materialize_model_temporal_inputs!(
        status,
        bindings,
        application,
        streams,
        time,
        timeline,
    )
end

@inline function _materialize_model_temporal_inputs!(
    status::Status,
    ::Tuple{},
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
)
    return status
end

@inline function _materialize_model_temporal_inputs!(
    status::Status,
    bindings::Tuple{T,Vararg},
    application::CompiledModelApplication,
    streams,
    time::Real,
    timeline,
) where {T}
    _materialize_model_temporal_input!(
        status,
        first(bindings),
        application,
        streams,
        time,
        timeline,
    )
    return _materialize_model_temporal_inputs!(
        status,
        Base.tail(bindings),
        application,
        streams,
        time,
        timeline,
    )
end

function _model_environment_for_model(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    time::Real,
    environment=_NO_ENVIRONMENT_OVERRIDE,
)
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _model_environment_for_binding(
        env_bindings,
        application,
        binding,
        time,
        environment,
    )
end

function _model_environment_for_binding(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    binding,
    time::Real,
    environment=_NO_ENVIRONMENT_OVERRIDE,
)
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    if !(environment isa NoEnvironmentOverride)
        if binding.backend isa GlobalConstant
            row = _environment_row_at_step(environment, Int(round(time)))
            binding.uses_raw_global_source && return row
            return _sample_compiled_global_environment_row(
                row,
                binding.compiled_sampling_rules,
            )
        end
        return sample_environment(
            binding.backend,
            binding.handle,
            environment,
            time,
            _prepared_environment_inputs(binding.compiled_sampling_rules),
        )
    end
    if binding.backend isa GlobalConstant
        step = Int(round(time))
        key = (application.id, step)
        haskey(env_bindings.sample_cache, key) &&
            return _global_environment_sample_value(
                binding.plan.sample_schema, env_bindings.sample_cache[key],
            )
        sampled = _sample_compiled_global_environment(
            binding,
            application,
            step,
        )
        env_bindings.sample_cache[key] = sampled
        return _global_environment_sample_value(binding.plan.sample_schema, sampled)
    end
    return sample_environment(
        binding.backend,
        binding.handle,
        time,
        _prepared_environment_inputs(binding.compiled_sampling_rules),
    )
end

@inline function _sample_compiled_global_environment(
    binding,
    application,
    step::Int,
)
    raw_row = _environment_row_at_step(binding.prepared_source, step)
    sampler = binding.sampler
    if !isnothing(sampler)
        return _sample_environment_for_model(
            sampler,
            raw_row,
            step,
            application.clock,
            application.spec,
        )
    end
    binding.uses_raw_global_source && return raw_row
    return _sample_compiled_global_environment_row(
        raw_row,
        binding.compiled_sampling_rules,
    )
end

# The execution payload owns the already resolved current call bindings.
# Context creation never rediscovers that dependency schema through a global map.
# A fresh shell either clones a current prototype or rebuilds from those bindings;
# updating an existing shell retains its leased descendant views.
@inline function _prepare_model_execution_context!(
    context::Union{Nothing,RunContext},
    compiled,
    environment_bindings,
    application,
    object_id,
    bound_inputs,
    output_targets,
    call_bindings::Tuple,
    temporal_streams,
    output_retention,
    time,
    constants,
    publication_allowed::Bool,
    environment;
    fresh::Bool=false,
    call_schema=_context_call_schema(context),
)
    if isnothing(context) || fresh
        calls = if context isa RunContext && _call_context_clone_is_current(
            context, compiled, environment_bindings, application, object_id,
            bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
        )
            _clone_runtime_call_targets(
                context.calls, compiled, environment_bindings, temporal_streams,
                output_retention, time, constants, publication_allowed, environment,
            )
        else
            _runtime_call_targets(
                compiled, environment_bindings, call_bindings, temporal_streams,
                output_retention, time, constants, publication_allowed, environment;
                call_schema,
            )
        end
        return RunContext(
            compiled, environment_bindings, application, object_id, calls,
            bound_inputs, output_targets, temporal_streams, output_retention,
            Float64(time), constants, publication_allowed, environment,
        )
    end
    runtime_changed =
        context.compiled !== compiled ||
        context.environment_bindings !== environment_bindings
    if runtime_changed
        context.compiled = compiled
        context.environment_bindings = environment_bindings
        context.application = application
        context.object_id = object_id
        context.bound_inputs = bound_inputs
        context.output_targets = output_targets
        context.temporal_streams = temporal_streams
        context.output_retention = output_retention
        context.constants = constants
    end
    _synchronize_current_call_context!(context, time, publication_allowed, environment)
    if runtime_changed
        _prepare_runtime_call_targets!(
            context.calls, compiled, environment_bindings, temporal_streams,
            output_retention, time, constants, publication_allowed, environment,
        )
    end
    return context
end

function _synchronize_model_execution_batch_contexts!(
    batch::CompiledExecutionBatch,
    compiled,
    environment_bindings,
    temporal_streams,
    output_retention,
    time::Real,
    constants,
)
    state = batch.context_state
    state.compiled === compiled &&
        state.environment_bindings === environment_bindings && return nothing
    for target in batch.targets
        context = target.context
        context isa RunContext || continue
        _prepare_model_execution_context!(
            context,
            compiled,
            environment_bindings,
            batch.application,
            target.object_id,
            target.bound_inputs,
            target.output_targets,
            target.call_bindings,
            temporal_streams,
            output_retention,
            time,
            constants,
            true,
            _NO_ENVIRONMENT_OVERRIDE,
        )
    end
    # Mark the batch current only after every retained context has been
    # synchronized. If preparation throws, the next execution retries the
    # complete slow path.
    state.compiled = compiled
    state.environment_bindings = environment_bindings
    return nothing
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
    sampled_environment,
    publish_outputs::Bool,
    performance::Union{Nothing,RuntimePerformanceCounters}=nothing,
)
    started_at = _runtime_performance_start(performance)
    status = isempty(target.input_bindings) ?
             target.status_view.status :
             _materialize_model_inputs!(
        target.status_view.status,
        target.input_bindings,
        compiled,
        application,
        temporal_streams,
        time,
    )
    _runtime_performance_finish!(performance, :temporal_input_materialization, started_at)
    started_at = _runtime_performance_start(performance)
    environment_value = sampled_environment isa UnspecifiedModelEnvironment ?
                        _model_environment_for_binding(
        env_bindings,
        application,
        target.environment_binding,
        time,
    ) : sampled_environment
    _runtime_performance_finish!(performance, :environment_sampling, started_at)
    context = if target.context isa RunContext
        target.context.time = time
        target.context
    else
        _prepare_model_execution_context!(
            target.context,
            compiled,
            env_bindings,
            application,
            target.object_id,
            target.bound_inputs,
            target.output_targets,
            target.call_bindings,
            temporal_streams,
            output_retention,
            time,
            constants,
            true,
            _NO_ENVIRONMENT_OVERRIDE,
        )
    end
    started_at = _runtime_performance_start(performance)
    run!(target.model, status, environment_value, constants, context)
    _runtime_performance_finish!(performance, :scientific_kernel_execution, started_at)
    if publish_outputs
        started_at = _runtime_performance_start(performance)
        isempty(target.output_bindings) ||
            _model_publish_runtime_outputs!(target.output_bindings, time)
        _runtime_performance_finish!(performance, :output_publication, started_at)
    end
    return status
end

@inline _model_execution_batch_environment(
    ::Nothing,
    env_bindings,
    application,
    time,
) = nothing

@inline _model_execution_batch_environment(
    ::UnspecifiedModelEnvironment,
    env_bindings,
    application,
    time,
) = _UNSPECIFIED_SCENE_ENVIRONMENT

@inline function _model_execution_batch_environment(
    provider::RawGlobalModelEnvironment,
    env_bindings,
    application,
    time,
)
    return _environment_row_at_step(
        provider.sampled_environment,
        Int(round(time)),
    )
end

@inline function _model_execution_batch_environment(
    provider::RawGlobalModelEnvironment{<:PreparedGlobalEnvironmentRows},
    env_bindings,
    application,
    time,
)
    return @inbounds provider.sampled_environment.rows[Int(round(time))]
end

@inline function _model_execution_batch_environment(
    provider::CachedGlobalModelEnvironment,
    env_bindings,
    application,
    time,
)
    return _sample_compiled_global_environment(
        provider.binding,
        application,
        Int(round(time)),
    )
end

@inline function _run_model_execution_batch!(
    batch::CompiledExecutionBatch,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    time::Real,
    constants,
    temporal_streams,
    output_retention,
    performance::Union{Nothing,RuntimePerformanceCounters}=nothing,
)
    batch_time = float(time)
    started_at = _runtime_performance_start(performance)
    shared_environment = _model_execution_batch_environment(
        batch.environment_provider,
        env_bindings,
        batch.application,
        time,
    )
    _runtime_performance_finish!(performance, :environment_sampling, started_at)
    _synchronize_model_execution_batch_contexts!(
        batch,
        compiled,
        env_bindings,
        temporal_streams,
        output_retention,
        batch_time,
        constants,
    )
    publish_outputs = batch.output_publication.enabled
    for target in batch.targets
        _run_model_execution_target!(
            compiled,
            env_bindings,
            batch.application,
            target,
            batch_time,
            constants,
            temporal_streams,
            output_retention,
            shared_environment,
            publish_outputs,
            performance,
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
    _model_application_should_run(batch.application, time) || return nothing
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
    return compiled.scenario_plan.manual_application_ids
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

_runtime_model_output_streams(
    status,
    application,
    object_id,
    ::Nothing,
    ::Nothing,
) = ()

_runtime_model_output_streams(
    status,
    application,
    object_id,
    ::Nothing,
    ::OutputRetentionPlan,
) = ()

Base.@nospecializeinfer function _runtime_model_output_streams(
    status,
    application,
    object_id,
    streams,
    output_retention::OutputRetentionPlan,
    initialize_missing::Bool=false,
)
    @nospecialize status application
    variables = get(
        output_retention.retained_outputs_by_application,
        application.id,
        (),
    )
    isempty(variables) && return ()
    # Assemble once without specializing a generator on the entire model/status.
    # The returned tuple still has concrete stream and reference types.
    declared_outputs = _model_output_names(application)
    runtime_streams = RuntimeOutputStream[]
    for variable in variables
        variable in declared_outputs || continue
        key = _model_stream_key(application.id, object_id, variable)
        stream = get(streams, key, nothing)
        if isnothing(stream)
            initialize_missing || error(
                "No initialized retained output stream for application ",
                "`$(application.id)` on object `$(object_id.value)` and variable ",
                "`$(variable)`.",
            )
            stream = _model_new_output_stream(
                getproperty(status, variable),
                output_retention,
                application.id,
                variable,
            )
            streams[key] = stream
        end
        reference = refvalue(status, variable)
        runtime_stream = RuntimeOutputStream{
            variable,
            typeof(stream),
            typeof(reference),
        }(
            stream,
            reference,
            get(
                output_retention.dependency_horizons,
                (application.id, variable),
                0.0,
            ),
        )
        push!(runtime_streams, runtime_stream)
    end
    return Tuple(runtime_streams)
end

function _runtime_model_output_streams(
    status,
    application,
    object_id,
    streams,
    ::Nothing,
)
    return ()
end

_runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    streams,
    output_retention,
    ::NoCompiledDistributedOutputs,
) = ()

_runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    ::Nothing,
    output_retention,
    distributed_outputs::CompiledDistributedOutputs,
) = ()

_runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    ::Nothing,
    ::Nothing,
    distributed_outputs::CompiledDistributedOutputs,
) = ()

_runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    ::Nothing,
    output_retention::OutputRetentionPlan,
    distributed_outputs::CompiledDistributedOutputs,
) = ()

_runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    streams,
    ::Nothing,
    distributed_outputs::CompiledDistributedOutputs,
) = ()

function _runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    streams,
    output_retention::OutputRetentionPlan,
    distributed_outputs::CompiledDistributedOutputs,
)
    retained_variables = get(
        output_retention.retained_outputs_by_application,
        application.id,
        (),
    )
    isempty(retained_variables) && return ()
    groups = get(
        distributed_outputs.by_execution_target,
        (application.id, object_id),
        nothing,
    )
    isnothing(groups) && return ()
    outputs = Any[]
    for binding in values(groups)
        for variable_ in binding.plan.variable_names
            variable = Symbol(variable_)
            variable in retained_variables || continue
            source_streams = Any[
                get(
                    streams,
                    _model_stream_key(
                        application.id,
                        destination_id,
                        variable,
                    ),
                    nothing,
                )
                for destination_id in binding.destination_ids
            ]
            any(isnothing, source_streams) && error(
                "No initialized retained distributed output stream for application ",
                "`$(application.id)`, group `$(binding.group)`, and variable ",
                "`$(variable)`.",
            )
            typed_streams = _typed_temporal_source_streams(source_streams)
            references = getproperty(binding.columns, variable)
            push!(
                outputs,
                RuntimeDistributedOutputStream{
                    variable,
                    typeof(binding),
                    typeof(typed_streams),
                    typeof(references),
                }(
                    binding,
                    typed_streams,
                    references,
                    get(
                        output_retention.dependency_horizons,
                        (application.id, variable),
                        0.0,
                    ),
                ),
            )
        end
    end
    return Tuple(outputs)
end

function _runtime_model_distributed_output_streams(
    compiled,
    application,
    object_id,
    streams,
    output_retention,
)
    return _runtime_model_distributed_output_streams(
        compiled,
        application,
        object_id,
        streams,
        output_retention,
        compiled.distributed_outputs,
    )
end

_runtime_model_output_targets(
    compiled,
    application,
    object_id,
    ::NoCompiledDistributedOutputs,
) = NamedTuple()

function _runtime_model_output_targets(
    compiled,
    application,
    object_id,
    distributed_outputs::CompiledDistributedOutputs,
)
    groups = get(
        distributed_outputs.by_execution_target,
        (application.id, object_id),
        nothing,
    )
    isnothing(groups) && return NamedTuple()
    names = Symbol[]
    targets = Any[]
    anchors = Any[]
    for binding in values(groups)
        alignment_id = findfirst(anchor -> anchor.destination_ids == binding.destination_ids, anchors)
        if isnothing(alignment_id)
            push!(anchors, binding)
            alignment_id = length(anchors)
        end
        target = OutputTargets(binding, alignment_id)
        for name in binding.plan.variable_names
            push!(names, name)
            push!(targets, target)
        end
    end
    return NamedTuple{Tuple(names)}(Tuple(targets))
end

_runtime_model_output_targets(compiled, application, object_id) =
    _runtime_model_output_targets(
        compiled,
        application,
        object_id,
        compiled.distributed_outputs,
    )

function _compiled_model_execution_target(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    object_id::ObjectId,
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing;
    owner=nothing,
    cohort_schema=OpenExecutionCohortSchema(),
)
    if temporal_streams isa RuntimeStorage
        location = cohort_location(temporal_streams.cohorts, application.id, object_id; owner)
        return _with_execution_cohort_location(cohort_schema, temporal_streams.cohorts, location, owner, application.id, object_id) do admitted
            previous = isnothing(admitted) ? nothing : _execution_cohort_target(admitted)
            _compiled_model_execution_target_from_previous(previous, compiled, env_bindings,
                application, object_id, temporal_streams, output_retention, constants;
                target_schema=cohort_schema)
        end
    end
    return _new_model_execution_target(compiled, env_bindings, application, object_id,
        temporal_streams, output_retention, constants; target_schema=cohort_schema)
end

function _compiled_model_execution_target_from_previous(previous, compiled, env_bindings,
    application, object_id, temporal_streams, output_retention, constants;
    target_schema=OpenExecutionCohortSchema())
    if !isnothing(previous) && isnothing(_model_execution_target_change_reason(
        previous, compiled, env_bindings, application, output_retention, temporal_streams,
    ))
        return previous
    end
    return _new_model_execution_target(compiled, env_bindings, application, object_id,
        temporal_streams, output_retention, constants; target_schema)
end

function _new_model_execution_target(
    compiled::CompiledCompositeModel, env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication, object_id::ObjectId,
    temporal_streams, output_retention, constants;
    target_schema=OpenExecutionCohortSchema(),
)
    status_view = _model_status_view_for_application(compiled, application, object_id)
    model = _application_model(application, object_id)
    distributed_targets = _runtime_model_output_targets(compiled, application, object_id)
    call_bindings = get(compiled.call_bindings_by_target, (application.id, object_id), ())
    environment_binding = _environment_binding_for(env_bindings, application.id, object_id)
    fields = (object_id=object_id, model=model, output_targets=distributed_targets,
        call_bindings=call_bindings, environment_binding=environment_binding)
    owners = (compiled=compiled, environment_bindings=env_bindings,
        temporal_streams=temporal_streams,
        output_retention=output_retention, constants=constants,
        environment=_NO_ENVIRONMENT_OVERRIDE)
    return _with_execution_target_type(_new_model_execution_target, target_schema,
        application, status_view, fields, owners)
end

function _new_model_execution_target(::Val{Target}, actual_application, actual, owner,
    call_schema,
) where {Target}
    input_bindings = isnothing(Target) ?
        _runtime_model_temporal_inputs(actual.status_view.temporal_inputs, owner.temporal_streams) :
        _prepared_runtime_temporal_inputs(fieldtype(Target,:input_bindings),
            actual.status_view.temporal_inputs,owner.temporal_streams)
    output_bindings = if isnothing(Target)
        local_outputs = _runtime_model_output_streams(actual.status_view.status,
            actual_application,actual.object_id,owner.temporal_streams,owner.output_retention)
        distributed_outputs = _runtime_model_distributed_output_streams(owner.compiled,
            actual_application,actual.object_id,owner.temporal_streams,owner.output_retention)
        (local_outputs...,distributed_outputs...)
    else
        _prepared_runtime_outputs(fieldtype(Target,:output_bindings),actual.status_view,
            actual.output_targets,actual_application,actual.object_id,owner.compiled,
            owner.temporal_streams,owner.output_retention,false)
    end
    context = if isnothing(owner.temporal_streams) && isempty(actual.output_targets)
        nothing
    else
        _prepare_model_execution_context!(nothing, owner.compiled, owner.environment_bindings,
            actual_application, actual.object_id, actual.bound_inputs,
            actual.output_targets, actual.call_bindings, owner.temporal_streams,
            owner.output_retention, 0.0, owner.constants, true, owner.environment;
            call_schema)
    end
    target = _compiled_execution_target(actual.object_id, actual.model,
        actual.status_view, input_bindings, actual.bound_inputs,
        actual.output_targets, output_bindings, actual.call_bindings,
        actual.environment_binding, context,
        CallContextCache(context, actual.status_view.execution_stamp))
    return isnothing(Target) ? target : target::Target
end

function _compiled_model_execution_environment_provider(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget,
)
    binding = target.environment_binding
    isnothing(binding) && return nothing
    binding.backend isa GlobalConstant ||
        return _UNSPECIFIED_SCENE_ENVIRONMENT

    if binding.uses_raw_global_source
        return RawGlobalModelEnvironment(binding.prepared_source)
    end
    return CachedGlobalModelEnvironment(binding)
end

function _compiled_output_publication(
    output_retention::OutputRetentionPlan,
    application::CompiledModelApplication,
)
    variables = Tuple(get(
        output_retention.retained_outputs_by_application,
        application.id,
        (),
    ))
    return CompiledOutputPublication(variables, !isempty(variables))
end

_compiled_output_publication(::Nothing, application) =
    CompiledOutputPublication((), false)

function _execution_batch_matches(
    batch, application, provider, output_publication,
)
    return batch.application === application &&
           isequal(batch.environment_provider, provider) &&
           batch.output_publication.variables == output_publication.variables &&
           batch.output_publication.enabled == output_publication.enabled
end

# Retained ordered views already describe the current concrete payloads. Check
# their providers and publication contract before allocating reconciliation
# indexes; an unchanged layout needs no new batch-list owner.
function _execution_batches_match_membership(
    env_bindings,application,membership,publication,previous_group,batch_schema,
)
    isnothing(previous_group) && return false
    previous_group.application === application || return false
    batches = previous_group.batches
    length(batches) == length(membership.runs) || return false
    for index in eachindex(membership.runs)
        matches = _with_execution_cohort_rows(membership.schema,membership.store,membership.runs[index]) do rows
            _with_execution_batch(batch_schema,batches[index]) do batch
                batch.targets === rows || return false
                provider = _compiled_model_execution_environment_provider(env_bindings,
                    application,first(rows))
                return _execution_batch_matches(batch,application,provider,publication)
            end
        end
        matches || return false
    end
    return true
end

function _model_execution_batches(
    env_bindings::CompiledEnvironmentBindings,application::CompiledModelApplication,
    membership::ExecutionCohortMembership,output_retention,previous_group=nothing;
    batch_schema=OpenExecutionBatchSchema(),
)
    publication = _batch_output_publication(batch_schema,output_retention,application)
    if _execution_batches_match_membership(env_bindings,application,membership,
        publication,previous_group,batch_schema)
        return (batches=previous_group.batches,batches_constructed=0)
    end
    live_views = IdDict{ExecutionCohortRows,Nothing}(rows => nothing for rows in membership.runs)
    previous_by_view = IdDict{ExecutionCohortRows,Any}()
    spare_by_cohort = IdDict{AbstractExecutionCohort,Vector{Any}}()
    next_spare = IdDict{AbstractExecutionCohort,Int}()
    if !isnothing(previous_group) && previous_group.application === application
        for index in eachindex(previous_group.batches)
            _with_execution_batch(batch_schema,previous_group.batches[index]) do batch
                previous_by_view[batch.targets] = batch
                if !haskey(live_views,batch.targets)
                    candidates = get!(spare_by_cohort,batch.targets.cohort) do
                        Any[]
                    end
                    push!(candidates,batch)
                end
                return nothing
            end
        end
    end
    batches = _execution_batch_buffer(batch_schema)
    batches_constructed = 0
    for index in eachindex(membership.runs)
        constructed = _with_execution_cohort_rows(membership.schema,membership.store,membership.runs[index]) do rows
            provider = _compiled_model_execution_environment_provider(env_bindings,
                application,first(rows))
            reused = _compatible_execution_batch(batch_schema,
                get(previous_by_view,rows,nothing),application,provider,publication)
            if isnothing(reused)
                candidates = get(spare_by_cohort,rows.cohort,())
                candidate_index = get(next_spare,rows.cohort,1)
                while candidate_index <= length(candidates)
                    candidate = _compatible_execution_batch(batch_schema,
                        candidates[candidate_index],application,provider,publication)
                    candidate_index += 1
                    if !isnothing(candidate)
                        reused = candidate
                        break
                    end
                end
                next_spare[rows.cohort] = candidate_index
            end
            if isnothing(reused)
                _with_new_execution_batch(batch_schema,application,rows,provider,publication) do batch
                    push!(batches,batch)
                    return nothing
                end
                return 1
            end
            _with_execution_batch(batch_schema,reused) do batch
                if batch.targets !== rows
                    if batch.targets.indices !== rows.indices
                        empty!(batch.targets.indices)
                        append!(batch.targets.indices,rows.indices)
                    end
                    membership.runs[index] = batch.targets
                end
                push!(batches,batch)
                return nothing
            end
            return 0
        end
        batches_constructed += constructed
    end
    return (batches=batches,batches_constructed=batches_constructed)
end

function _compiled_call_execution_batches(
    compiled::CompiledCompositeModel, env_bindings::CompiledEnvironmentBindings,
    binding, temporal_streams, output_retention, constants;
    cohort_schema=OpenExecutionCohortSchema(),
    batch_schema=OpenExecutionBatchSchema(),
)
    cohorts = _execution_cohort_store(temporal_streams)
    owner = _execution_call_owner(binding)
    admission = _call_cohort_admission(batch_schema,cohort_schema)
    batches = _execution_batch_buffer(batch_schema)
    for application_id in binding.callee_application_ids
        _compiled_application_by_id(compiled,application_id) do application
            application_schema = _call_batch_schema_for_application(batch_schema,application)
            current_ids = [object_id for object_id in binding.callee_object_ids
                if _call_binding_target_matches(binding,application,object_id)]
            refreshed = refresh_cohort_membership!(cohorts,application.id,current_ids,
                nothing;owner,schema=admission) do object_id, previous_target
                _compiled_model_execution_target_from_previous(previous_target,
                    compiled,env_bindings,application,object_id,temporal_streams,
                    output_retention,constants;target_schema=admission)
            end
            assembled = _model_execution_batches(env_bindings,application,
                refreshed.membership,output_retention;batch_schema=application_schema)
            for index in eachindex(assembled.batches)
                _with_execution_batch(application_schema,assembled.batches[index]) do batch
                    push!(batches,batch)
                    return nothing
                end
            end
            return nothing
        end
    end
    return _finish_execution_batches(batch_schema,batches)
end

function compile_model_execution_plan(
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing;
    batch_schemas=nothing,
)
    isnothing(batch_schemas) || _prepared_application_schema_order(compiled,batch_schemas)
    cohorts = _execution_cohort_store(temporal_streams)
    manual_application_ids = _manual_call_application_ids(compiled)
    groups = CompiledApplicationExecutionGroup[]
    batches = AbstractExecutionBatch[]
    for application in _ordered_model_applications(compiled)
        application.id in manual_application_ids && continue
        previous_group = isnothing(batch_schemas) ? nothing :
            _prepared_execution_group(application,getproperty(batch_schemas,application.id),cohorts)
        refreshed = _refresh_model_execution_group!(
            previous_group, cohorts, compiled, env_bindings, application,
            temporal_streams, output_retention, constants, nothing, nothing,
        )
        isnothing(refreshed.group) && continue
        push!(groups, refreshed.group)
        append!(batches, refreshed.group.batches)
    end
    application_count = length(compiled.scenario_plan.applications)
    return CompiledExecutionPlan(
        cohorts,
        DynamicExecution(),
        groups,
        batches,
        _execution_groups_by_application_slot(groups, application_count),
        _runtime_application_schedule(compiled.scenario_plan.application_schedule),
        compiled.revision,
        env_bindings.environment_revision,
    )
end

# Every staged source was checked against the destination's element type before
# any destination is changed. Keep that proof at the append boundary after
# selecting the real immutable owner from its typed tuple.
@inline function _append_validated_runtime_streams!(
    streams::Vector{S}, new_streams::Vector{Any},
) where {S}
    S === Any && return append!(streams, new_streams)
    return append!(streams, (stream::S for stream in new_streams))
end

function _model_execution_inputs_match(
    runtime_inputs::Tuple,
    compiled_inputs::Tuple,
    temporal_streams=nothing,
)
    length(runtime_inputs) == length(compiled_inputs) || return false
    additions = Tuple{Int,Vector{Any}}[]
    for index in eachindex(runtime_inputs)
        runtime_input = runtime_inputs[index]
        compiled_input = compiled_inputs[index]
        if runtime_input isa RuntimeTemporalInput
            runtime_input.compiled === compiled_input || return false
            binding = compiled_input.binding
            binding.multiplicity == :many || continue
            source_streams = runtime_input.source_streams
            if !(source_streams isa Vector)
                length(source_streams) == length(binding.source_ids) ||
                    return false
                continue
            end
            current_count = length(source_streams)
            source_count = length(binding.source_ids)
            current_count <= source_count || return false
            current_count == source_count && continue
            binding.policy isa PreviousTimeStep || return false
            isnothing(temporal_streams) && return false
            length(compiled_input.initial) == source_count || return false
            length(compiled_input.reference[]) == source_count || return false
            length(compiled_input.source_applications) == source_count ||
                return false
            new_streams = Any[]
            for source_index in (current_count + 1):source_count
                stream = _runtime_temporal_source_stream(
                    temporal_streams,
                    compiled_input,
                    source_index,
                )
                stream isa eltype(source_streams) || return false
                push!(new_streams, stream)
            end
            push!(additions, (index, new_streams))
        else
            runtime_input === compiled_input || return false
        end
    end
    for addition in additions
        _with_metadata_entry(runtime_inputs, first(addition)) do runtime_input
            runtime_input isa RuntimeTemporalInput ||
                error("A staged temporal stream extension lost its runtime owner.")
            admitted_streams = runtime_input.source_streams
            admitted_streams isa Vector ||
                error("A staged temporal stream extension lost its vector storage.")
            _append_validated_runtime_streams!(admitted_streams, last(addition))
            return nothing
        end
    end
    return true
end

function _model_execution_outputs_match(
    runtime_outputs::Tuple,
    status_view::CompiledModelStatusView,
    compiled::CompiledCompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    output_retention,
    temporal_streams=nothing,
)
    variables = output_retention isa OutputRetentionPlan ?
                get(
        output_retention.retained_outputs_by_application,
        application.id,
        (),
    ) : ()
    output_index = 0
    dependency_horizons = output_retention isa OutputRetentionPlan ?
                          output_retention.dependency_horizons :
                          nothing
    for variable in variables
        variable in _model_output_names(application) || continue
        output_index += 1
        output_index <= length(runtime_outputs) || return false
        output = runtime_outputs[output_index]
        output isa RuntimeOutputStream || return false
        _runtime_output_variable(output) == variable || return false
        expected_horizon = isnothing(dependency_horizons) ?
                           0.0 :
                           get(
            dependency_horizons,
            (application.id, variable),
            0.0,
        )
        output.dependency_horizon == expected_horizon || return false
        isnothing(temporal_streams) && continue
        key = _model_stream_key(application.id, object_id, variable)
        output.stream === get(temporal_streams, key, nothing) || return false
        output.reference === refvalue(status_view.status, variable) || return false
    end

    additions = Tuple{Int,Vector{Any}}[]
    if compiled.distributed_outputs isa CompiledDistributedOutputs
        groups = get(
            compiled.distributed_outputs.by_execution_target,
            (application.id, object_id),
            nothing,
        )
        if !isnothing(groups)
            isnothing(temporal_streams) && return false
            for binding in values(groups)
                for variable_ in binding.plan.variable_names
                    variable = Symbol(variable_)
                    variable in variables || continue
                    output_index += 1
                    output_index <= length(runtime_outputs) || return false
                    output = runtime_outputs[output_index]
                    output isa RuntimeDistributedOutputStream || return false
                    _runtime_output_variable(output) == variable || return false
                    output.binding === binding || return false
                    output.references ===
                    getproperty(binding.columns, variable) || return false
                    expected_horizon = isnothing(dependency_horizons) ?
                                       0.0 :
                                       get(
                        dependency_horizons,
                        (application.id, variable),
                        0.0,
                    )
                    output.dependency_horizon == expected_horizon || return false
                    destination_ids = binding.destination_ids
                    runtime_streams = output.streams
                    length(runtime_streams) <= length(destination_ids) ||
                        return false
                    for index in eachindex(runtime_streams)
                        key = _model_stream_key(
                            application.id,
                            destination_ids[index],
                            variable,
                        )
                        runtime_streams[index] ===
                        get(temporal_streams, key, nothing) || return false
                    end
                    length(runtime_streams) == length(destination_ids) &&
                        continue
                    runtime_streams isa Vector || return false
                    new_streams = Any[]
                    for index in (length(runtime_streams) + 1):length(destination_ids)
                        key = _model_stream_key(
                            application.id,
                            destination_ids[index],
                            variable,
                        )
                        stream = get(temporal_streams, key, nothing)
                        isnothing(stream) && return false
                        stream isa eltype(runtime_streams) || return false
                        push!(new_streams, stream)
                    end
                    push!(additions, (output_index, new_streams))
                end
            end
        end
    end
    output_index == length(runtime_outputs) || return false
    for addition in additions
        _with_metadata_entry(runtime_outputs, first(addition)) do output
            output isa RuntimeDistributedOutputStream ||
                error("A staged distributed stream extension lost its runtime owner.")
            admitted_streams = output.streams
            admitted_streams isa Vector ||
                error("A staged distributed stream extension lost its vector storage.")
            _append_validated_runtime_streams!(admitted_streams, last(addition))
            return nothing
        end
    end
    return true
end

function _model_execution_output_targets_match(
    targets,
    compiled,
    application,
    object_id,
    ::NoCompiledDistributedOutputs,
)
    return isempty(targets)
end

function _model_execution_output_targets_match(
    targets,
    compiled,
    application,
    object_id,
    distributed_outputs::CompiledDistributedOutputs,
)
    bindings = get(
        distributed_outputs.by_execution_target,
        (application.id, object_id),
        nothing,
    )
    isnothing(bindings) && return isempty(targets)
    count = 0
    ordered_bindings = values(bindings)
    for (index, binding) in enumerate(ordered_bindings)
        for name in binding.plan.variable_names
            hasproperty(targets, name) || return false
            target = getproperty(targets, name)
            target.binding === binding || return false
            count += 1
        end
        # A monotonic addition can extend existing columns and streams in place.
        # Rebuild only if it changes which destination declarations are aligned.
        current = getproperty(targets, first(binding.plan.variable_names))
        for previous_index in 1:(index - 1)
            previous = ordered_bindings[previous_index]
            previous_target = getproperty(targets, first(previous.plan.variable_names))
            was_aligned = current.alignment_id == previous_target.alignment_id
            now_aligned = binding.destination_ids == previous.destination_ids
            was_aligned == now_aligned || return false
        end
    end
    length(targets) == count || return false
    return true
end

function _model_execution_output_targets_match(
    targets,
    compiled,
    application,
    object_id,
)
    return _model_execution_output_targets_match(
        targets,
        compiled,
        application,
        object_id,
        compiled.distributed_outputs,
    )
end

function _manual_call_binding_has_changed_target(
    binding,
    compiled::CompiledCompositeModel,
)
    _compiled_call_mode(binding) === :manual || return false
    _compiled_call_membership_is_observed(binding) || return false
    for (application_id, object_id) in compiled.changed_execution_target_ids
        application_id in binding.callee_application_ids || continue
        first(
            _sorted_object_id_position(
                binding.callee_object_ids,
                object_id,
            ),
        ) || continue
        application = get(compiled.applications_by_id, application_id, nothing)
        isnothing(application) && continue
        first(
            _sorted_object_id_position(
                application.target_ids,
                object_id,
            ),
        ) || continue
        return true
    end
    return false
end

function _model_execution_target_change_reason(
    target::CompiledExecutionTarget,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    output_retention=nothing,
    temporal_streams=nothing,
)
    object_id = target.object_id
    key = (application.id, object_id)
    status_view = get(compiled.status_views_by_target, key, nothing)
    isnothing(status_view) && return :missing_status_view
    target.model === _application_model(application, object_id) ||
        return :model
    # Preserve the existing reference checks after admitting the target's view schema.
    V = typeof(target.status_view)
    status_view isa V || return :status_view
    status_view = status_view::V
    target.status_view.status === status_view.status || return :status_view
    target.status_view.canonical_status === status_view.canonical_status ||
        return :canonical_status
    target.bound_inputs === status_view.bound_inputs ||
        return :bound_inputs
    _model_execution_output_targets_match(
        target.output_targets,
        compiled,
        application,
        object_id,
    ) || return :output_targets
    _model_execution_inputs_match(
        target.input_bindings,
        status_view.temporal_inputs,
        temporal_streams,
    ) ||
        return :temporal_inputs
    _model_execution_outputs_match(
        target.output_bindings,
        status_view,
        compiled,
        application,
        object_id,
        output_retention,
        temporal_streams,
    ) || return :output_bindings
    target.environment_binding === _environment_binding_for(
        env_bindings,
        application.id,
        object_id,
    ) || return :environment_binding
    target.call_bindings ===
    get(compiled.call_bindings_by_target, key, ()) ||
        return :call_bindings
    target.call_bindings_signature ==
    _call_bindings_signature(target.call_bindings) ||
        return :call_bindings
    if any(binding -> _manual_call_binding_has_changed_target(binding,compiled),
        target.call_bindings)
        context = target.context
        # Delta markers describe changes entering this compiled owner. A child
        # already prepared against that exact owner must not replay the delta.
        # Reuse the same owner/binding/stamp proof as ordinary context cloning;
        # a stale child still reaches the existing rebuild below.
        current = context isa RunContext && _call_context_clone_is_current(
            context,compiled,env_bindings,application,object_id,target.bound_inputs,
            target.output_targets,target.call_bindings,temporal_streams,
            output_retention,context.constants)
        current || return :call_bindings
    end
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
    elseif reason === :bound_inputs
        :execution_target_rebuild_bound_inputs
    elseif reason === :output_targets
        :execution_target_rebuild_output_targets
    elseif reason === :output_bindings
        :execution_target_rebuild_output_bindings
    elseif reason === :call_bindings
        :execution_target_rebuild_call_bindings
    elseif reason === :environment_binding
        :execution_target_rebuild_environment_binding
    else
        :execution_target_rebuild_unknown
    end
    return _runtime_performance_count!(performance, counter)
end

function _model_execution_batch_accepts_target(
    batch::CompiledExecutionBatch,
    target::CompiledExecutionTarget,
    env_bindings,
    application,
)
    typeof(target) === eltype(batch.targets) || return false
    provider = _compiled_model_execution_environment_provider(
        env_bindings,
        application,
        target,
    )
    return isequal(provider, batch.environment_provider)
end

function _extend_execution_target_call_batches_by_prefix!(
    target::CompiledExecutionTarget,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams,
    output_retention,
    constants,
)
    context = target.context
    context isa RunContext || return false
    current_call_bindings = get(
        compiled.call_bindings_by_target,
        (context.application.id, target.object_id),
        (),
    )
    scope = _context_call_schema(context)
    current_call_bindings = _admitted_current_execution_call_bindings(scope,
        target, current_call_bindings)
    isnothing(current_call_bindings) && return false
    length(context.calls) == length(current_call_bindings) || return false
    _preflight_current_execution_calls(scope, context.calls, current_call_bindings,
        compiled, env_bindings) || return false
    staged = _execution_append_intent_buffer(scope)
    staged_bindings = _execution_binding_intent_buffer(scope)
    for call_index in eachindex(context.calls)
        extended = _with_current_execution_call(scope, context.calls,
            current_call_bindings, call_index) do call_targets, binding
            _compiled_call_name(call_targets.binding) == _compiled_call_name(binding) || return false
            _stage_execution_binding!(staged_bindings, scope, call_targets, binding) || return false
            _compiled_call_mode(binding) === :initializer && return true
            execution_batches = _cached_call_execution_batches(call_targets)
            isnothing(execution_batches) && return true
            schema = call_targets.batch_schema
            _execution_call_batches_match_applications(schema, execution_batches,
                binding.callee_application_ids) || return false
            for application_id in binding.callee_application_ids
                matched = _compiled_application_by_id(compiled, application_id) do application
                    application_schema = _call_batch_schema_for_application(schema, application)
                    batches = _execution_call_batches_for_application(schema, application_schema,
                        execution_batches, application_id)
                    isempty(batches) && return false
                    current_ids = [object_id for object_id in binding.callee_object_ids
                        if _call_binding_target_matches(binding, application, object_id)]
                    # Preserve the existing ordered-prefix algorithm. Only the
                    # count leaves each admitted concrete batch operation.
                    existing_count = 0
                    for raw_batch in batches
                        next_count = _execution_call_prefix_end(application_schema,
                            raw_batch, current_ids, existing_count,
                            compiled.changed_execution_target_ids, application.id)
                        isnothing(next_count) && return false
                        existing_count = next_count
                    end
                    existing_count == length(current_ids) && return true
                    admission = _call_cohort_admission(application_schema, OpenExecutionCohortSchema())
                    first_new_index = existing_count + 1
                    return _with_execution_batch(application_schema, last(batches)) do destination_batch
                        for index in first_new_index:lastindex(current_ids)
                            object_id = current_ids[index]
                            execution_target = _compiled_model_execution_target(
                                compiled, env_bindings, application, object_id,
                                temporal_streams, output_retention, constants;
                                owner=_execution_call_owner(binding), cohort_schema=admission)
                            accepted = _with_execution_cohort_target(admission, execution_target) do actual
                                _model_execution_batch_accepts_target(destination_batch,
                                    actual, env_bindings, application) || return false
                                return _stage_execution_append!(staged, scope, call_targets,
                                    binding, destination_batch.targets, actual)
                            end
                            accepted || return false
                        end
                        return true
                    end
                end
                matched || return false
            end
            return true
        end
        extended || return false
    end
    _commit_execution_call_extension!(scope, staged, staged_bindings,
        compiled, env_bindings) || return false
    target.call_bindings = current_call_bindings
    target.call_bindings_signature = _call_bindings_signature(current_call_bindings)
    target.call_context_cache.transient = nothing
    return true
end

function _pure_addition_changed_call_target_ids(
    binding,
    compiled::CompiledCompositeModel,
)
    application_ids = binding.callee_application_ids
    changed_ids = ObjectId[]
    affected_application_ids = Symbol[]
    for (application_id, object_id) in compiled.changed_execution_target_ids
        application_id in application_ids || continue
        first(
            _sorted_object_id_position(
                binding.callee_object_ids,
                object_id,
            ),
        ) || continue
        matches_application = _compiled_application_by_id(compiled, application_id) do application
            first(_sorted_object_id_position(application.target_ids, object_id))
        end
        matches_application || continue
        push!(changed_ids, object_id)
        application_id in affected_application_ids ||
            push!(affected_application_ids, application_id)
    end
    _sort_object_ids!(changed_ids)
    return changed_ids, affected_application_ids
end

function _extend_execution_target_call_batches_for_pure_addition!(
    target::CompiledExecutionTarget,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams,
    output_retention,
    constants,
    performance=nothing,
)
    compiled.status_view_refresh_is_pure_addition || return nothing
    context = target.context
    context isa RunContext || return nothing
    current_call_bindings = get(
        compiled.call_bindings_by_target,
        (context.application.id, target.object_id),
        (),
    )
    scope = _context_call_schema(context)
    current_call_bindings = _admitted_current_execution_call_bindings(scope,
        target, current_call_bindings)
    isnothing(current_call_bindings) && return nothing
    length(context.calls) == length(current_call_bindings) || return nothing
    _preflight_current_execution_calls(scope, context.calls, current_call_bindings,
        compiled, env_bindings) || return nothing
    staged = _execution_append_intent_buffer(scope)
    staged_bindings = _execution_binding_intent_buffer(scope)
    for call_index in eachindex(context.calls)
        extended = _with_current_execution_call(scope, context.calls,
            current_call_bindings, call_index) do call_targets, binding
            _compiled_call_name(call_targets.binding) == _compiled_call_name(binding) || return nothing
            _stage_execution_binding!(staged_bindings, scope, call_targets, binding) || return nothing
            _compiled_call_mode(binding) === :initializer && return true
            execution_batches = _cached_call_execution_batches(call_targets)
            isnothing(execution_batches) && return true
            schema = call_targets.batch_schema
            _execution_call_batches_match_applications(schema, execution_batches,
                binding.callee_application_ids) || return nothing
            changed_ids, affected_application_ids = _pure_addition_changed_call_target_ids(binding, compiled)
            isempty(changed_ids) && return true
            length(affected_application_ids) == 1 || return nothing
            length(binding.callee_application_ids) == 1 || return nothing
            application_id = only(affected_application_ids)
            return _compiled_application_by_id(compiled, application_id) do application
                application_schema = _call_batch_schema_for_application(schema, application)
                batches = _execution_call_batches_for_application(schema, application_schema,
                    execution_batches, application_id)
                isempty(batches) && return false
                admission = _call_cohort_admission(application_schema, OpenExecutionCohortSchema())
                return _with_execution_batch(application_schema, last(batches)) do destination_batch
                    last_old_id = last(destination_batch.targets).object_id
                    all(object_id -> _object_id_isless(last_old_id, object_id), changed_ids) || return false
                    found_boundary, boundary = _sorted_object_id_position(binding.callee_object_ids, last_old_id)
                    found_boundary || return false
                    for index in (boundary + 1):lastindex(binding.callee_object_ids)
                        object_id = binding.callee_object_ids[index]
                        first(_sorted_object_id_position(application.target_ids, object_id)) || continue
                        first(_sorted_object_id_position(changed_ids, object_id)) || return false
                    end
                    for object_id in changed_ids
                        execution_target = _compiled_model_execution_target(
                            compiled, env_bindings, application, object_id,
                            temporal_streams, output_retention, constants;
                            owner=_execution_call_owner(binding), cohort_schema=admission)
                        accepted = _with_execution_cohort_target(admission, execution_target) do actual
                            _model_execution_batch_accepts_target(destination_batch,
                                actual, env_bindings, application) || return false
                            return _stage_execution_append!(staged, scope, call_targets,
                                binding, destination_batch.targets, actual)
                        end
                        accepted || return false
                    end
                    return true
                end
            end
        end
        isnothing(extended) && return nothing
        extended || return false
    end
    _commit_execution_call_extension!(scope, staged, staged_bindings,
        compiled, env_bindings) || return false
    target.call_bindings = current_call_bindings
    target.call_bindings_signature = _call_bindings_signature(current_call_bindings)
    target.call_context_cache.transient = nothing
    _runtime_performance_count!(performance, :execution_target_call_delta_extensions)
    _runtime_performance_count!(performance, :execution_target_call_delta_targets_added, length(staged))
    return true
end

function _extend_execution_target_call_batches!(
    target::CompiledExecutionTarget,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams,
    output_retention,
    constants,
    performance=nothing,
)
    pure_addition_result =
        _extend_execution_target_call_batches_for_pure_addition!(
            target,
            compiled,
            env_bindings,
            temporal_streams,
            output_retention,
            constants,
            performance,
        )
    isnothing(pure_addition_result) || return pure_addition_result
    return _extend_execution_target_call_batches_by_prefix!(
        target,
        compiled,
        env_bindings,
        temporal_streams,
        output_retention,
        constants,
    )
end

function _same_execution_members(left, right)
    length(left) == length(right) || return false
    return all(index -> left[index] === right[index], eachindex(left))
end

function _refresh_model_execution_group!(
    previous_group,
    cohorts::ExecutionCohortStore,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledModelApplication,
    temporal_streams,
    output_retention,
    constants,
    performance,
    changed_object_ids,
)
    previous_membership = isnothing(previous_group) ? nothing : previous_group.membership
    target_schema = isnothing(previous_membership) ? OpenExecutionCohortSchema() : previous_membership.schema
    calls_extended = Ref(false)
    refreshed = refresh_cohort_membership!(
        cohorts, application.id, application.target_ids, changed_object_ids;
        previous=previous_membership,
    ) do object_id, previous_target
        reason = isnothing(previous_target) ? :new_target :
                 _model_execution_target_change_reason(
            previous_target, compiled, env_bindings, application,
            output_retention, temporal_streams,
        )
        isnothing(reason) && return previous_target
        if reason === :call_bindings && _extend_execution_target_call_batches!(
            previous_target, compiled, env_bindings, temporal_streams,
            output_retention, constants, performance,
        )
            calls_extended[] = true
            _runtime_performance_count!(performance, :execution_target_call_batches_extended)
            return previous_target
        end
        target = _new_model_execution_target(
            compiled, env_bindings, application, object_id,
            temporal_streams, output_retention, constants; target_schema,
        )
        _count_model_execution_target_rebuild!(performance, reason)
        return target
    end
    assembled = _model_execution_batches(
        env_bindings, application, refreshed.membership,
        output_retention, previous_group;
        batch_schema=_execution_group_batch_schema(previous_group),
    )
    reused_group = !isnothing(previous_group) &&
                   previous_group.application === application &&
                   _same_execution_members(previous_group.batches, assembled.batches)
    group_changed = refreshed.membership_changed ||
                    refreshed.targets_constructed > 0 || calls_extended[]
    group = if isempty(assembled.batches)
        if !isnothing(previous_group) && previous_group.application === application &&
           previous_group.batches isa AbstractVector
            empty!(previous_group.batches)
            previous_group.membership = refreshed.membership
            previous_group
        else
            nothing
        end
    elseif reused_group
        previous_group.membership = refreshed.membership
        previous_group
    else
        _retain_execution_group(previous_group, _compiled_application_execution_group(
            application, assembled.batches, refreshed.membership;
            batch_schema=_execution_group_batch_schema(previous_group),
        ))
    end
    if !isnothing(group) && group === previous_group && group_changed
        _runtime_performance_count!(performance, :execution_groups_updated_in_place)
    end
    return (
        group=group,
        targets_constructed=refreshed.targets_constructed,
        batches_constructed=assembled.batches_constructed,
        group_reused=reused_group && !group_changed,
    )
end

function _changed_execution_target_ids_by_application(changed_execution_target_ids,
    ::Type{I},
) where {I<:ObjectId}
    changed_by_application = Dict{Symbol,Vector{I}}()
    for (application_id, object_id) in changed_execution_target_ids
        object_ids = get!(changed_by_application, application_id) do
            I[]
        end
        push!(object_ids, object_id::I)
    end
    for object_ids in values(changed_by_application)
        _sort_object_ids!(object_ids)
    end
    return changed_by_application
end

# The ordinary open representation can learn a new group schema. A closed
# tuple must enter the worker with an already admitted application witness.
function _with_matching_previous_execution_group(f, group, application::A,
    ::Tuple,
) where {A<:CompiledModelApplication}
    group isa CompiledApplicationExecutionGroup{A} || return nothing
    group.application.id === application.id || return nothing
    group.application.slot == application.slot || return nothing
    return f(group)::NTuple{3,Int}
end

function _with_matching_previous_execution_group(f, group, application,
    ::AbstractVector,
)
    isnothing(group) && return nothing
    group.application.id === application.id || return nothing
    return f(group)::NTuple{3,Int}
end

_missing_previous_execution_group(f, ::AbstractVector, application) =
    f(nothing)::NTuple{3,Int}

function _missing_previous_execution_group(f, ::Tuple, application)
    throw(ArgumentError(
        "The prepared execution-group schema has no matching application " *
        "`$(application.id)` at slot $(application.slot). Prepare its group before execution.",
    ))
end

# Prefer the current authored position, then search the existing owners by id.
# Only scalar counts leave the concrete callback; there is one lookup loop for
# both representations. Incompatible closed application types never enter f.
function _with_previous_execution_group(f::F, slots, application::CompiledModelApplication,
    visited::BitVector,
) where {F}
    preferred_slot = application.slot
    for candidate in 0:length(slots)
        slot = iszero(candidate) ? preferred_slot : candidate
        (slot < 1 || slot > length(slots) ||
         (!iszero(candidate) && slot == preferred_slot)) && continue
        counts = _with_metadata_entry(slots, slot) do group
            _with_matching_previous_execution_group(f, group, application, slots)
        end
        if !isnothing(counts)
            visited[slot] = true
            return counts
        end
    end
    return _missing_previous_execution_group(f, slots, application)
end

# Validate each CURRENT entry before it reaches metadata readers. Literal
# tuple fields close the container without constructing Tuple(values) with a
# runtime arity, reordering application ids, or recreating any live group.
_execution_groups_in_schema(::AbstractVector, groups) = groups

@generated function _execution_groups_in_schema(::G, groups) where {G<:Tuple}
    count = fieldcount(G)
    values = [gensym(:group) for _ in 1:count]
    statements = Any[]
    for (index, (value, type)) in enumerate(zip(values, fieldtypes(G)))
        push!(statements, :($value = groups[$index]))
        push!(statements, :($value isa $type || throw(ArgumentError(
            "A refreshed execution group is outside the prepared tuple schema at position " *
            string($index) * ".",
        ))))
    end
    result = Expr(:tuple, [:( $(values[index])::$(fieldtype(G, index)) )
        for index in 1:count]...)
    return quote
        length(groups) == $count || throw(ArgumentError(
            "The refreshed execution-group count differs from its prepared tuple schema.",
        ))
        $(statements...)
        return $result
    end
end

# A known closed layout mismatch is an admission error. Validate metadata
# coverage and CURRENT schedule order before any membership/cohort worker runs.
# This does not promise rollback of earlier lifecycle or binding preparation.
_preflight_execution_group_layout!(previous, compiled, ::AbstractVector) = nothing

function _preflight_execution_group_layout!(previous, compiled, slots::Tuple)
    witnesses = CompiledApplicationExecutionGroup[]
    visited = falses(length(slots))
    for entry in compiled.scenario_plan.application_schedule.entries
        _with_metadata_entry(compiled.applications_by_id,entry.application_id) do application
            _with_previous_execution_group(slots,application,visited) do group
                push!(witnesses,group)
                return (0,0,0)
            end
            return nothing
        end
    end
    # The witnesses remain the actual old owners in the NEW scheduler order.
    # Never reorder them back to the prepared ids to make a cast succeed.
    groups = _execution_groups_in_schema(previous.groups,witnesses)
    current_slots = _execution_groups_by_application_slot(groups,
        length(compiled.scenario_plan.applications))
    _execution_groups_in_schema(slots,current_slots)
    return nothing
end

function _refresh_model_execution_plan(
    previous::CompiledExecutionPlan,
    compiled::CompiledCompositeModel,
    env_bindings::CompiledEnvironmentBindings,
    temporal_streams=nothing,
    output_retention=nothing,
    constants=nothing,
    performance=nothing,
    changed_application_ids=nothing,
    changed_execution_target_ids=compiled.changed_execution_target_ids,
)
    changed_by_application = isnothing(changed_application_ids) ? nothing :
                             _changed_execution_target_ids_by_application(
        changed_execution_target_ids,
        keytype(compiled.model.registry.objects),
    )
    previous_slots = previous.groups_by_application_slot
    _preflight_execution_group_layout!(previous,compiled,previous_slots)
    visited_slots = falses(length(previous_slots))
    groups = CompiledApplicationExecutionGroup[]
    batches = AbstractExecutionBatch[]
    sizehint!(groups, length(previous.groups))
    sizehint!(batches, length(previous.batches))
    targets_constructed = 0
    batches_constructed = 0
    groups_reused = 0
    # These are the compiler's existing dependency-ordered root entries;
    # call-only applications are already excluded by that same schedule.
    for entry in compiled.scenario_plan.application_schedule.entries
        counts = _with_metadata_entry(compiled.applications_by_id, entry.application_id) do application
            _with_previous_execution_group(previous_slots, application,
                visited_slots,
            ) do previous_group
                if !isnothing(previous_group) && !isnothing(changed_application_ids) &&
                   !(application.id in changed_application_ids)
                    push!(groups, previous_group)
                    append!(batches, previous_group.batches)
                    return (0, 0, 1)
                end
                changed_ids = isnothing(changed_by_application) ? nothing :
                              get(changed_by_application, application.id, ())
                refreshed = _refresh_model_execution_group!(
                    previous_group, previous.cohorts, compiled, env_bindings, application,
                    temporal_streams, output_retention, constants, performance, changed_ids,
                )
                if !isnothing(refreshed.group)
                    push!(groups, refreshed.group)
                    append!(batches, refreshed.group.batches)
                end
                return (refreshed.targets_constructed, refreshed.batches_constructed,
                    Int(refreshed.group_reused))
            end
        end
        targets_constructed += counts[1]
        batches_constructed += counts[2]
        groups_reused += counts[3]
    end
    # A removed application (or one now exclusively called) has no scheduled
    # membership. Visit each remaining old slot at its existing type boundary.
    for slot in eachindex(previous_slots)
        visited_slots[slot] && continue
        _with_metadata_entry(previous_slots, slot) do group
            isnothing(group) && return nothing
            for object_id in group.membership.object_ids
                remove_cohort_target!(previous.cohorts, group.application.id, object_id; schema=group.membership.schema)
            end
            return nothing
        end
    end
    groups_in_schema = _execution_groups_in_schema(previous.groups, groups)
    same_groups = _same_execution_members(previous.groups, groups_in_schema)
    same_batches = _same_execution_members(previous.batches, batches)
    application_count = length(compiled.scenario_plan.applications)
    groups_by_slot = same_groups &&
                     length(previous.groups_by_application_slot) == application_count ?
                     previous.groups_by_application_slot :
                     _execution_groups_by_application_slot(groups_in_schema, application_count)
    slots_in_schema = _execution_groups_in_schema(
        previous.groups_by_application_slot, groups_by_slot,
    )
    return (
        plan=CompiledExecutionPlan(
            previous.cohorts,
            previous.topology,
            same_groups ? previous.groups : groups_in_schema,
            same_batches ? previous.batches : batches,
            slots_in_schema,
            _refreshed_runtime_application_schedule(previous.schedule,
                compiled.scenario_plan.application_schedule),
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
            target_storage=:cohort,
            cohort_schema=eltype(batch.targets),
            target_type=eltype(batch.targets),
            model_type=fieldtype(eltype(batch.targets), :model),
            status_type=fieldtype(fieldtype(eltype(batch.targets), :status_view), :status),
            input_bindings_type=fieldtype(eltype(batch.targets), :input_bindings),
            call_bindings_type=fieldtype(eltype(batch.targets), :call_bindings),
            call_capability=isempty(first(batch.targets).call_bindings) ?
                            :no_calls :
                            :compiled_calls,
            output_variables=batch.output_publication.variables,
            output_publication=batch.output_publication.enabled ?
                               :direct_stream_bindings :
                               :none,
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
    model = deepcopy(model)
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
    return _compiled_application_by_id(compiled, binding.application_id) do consumer
        for source_application_id in binding.source_application_ids
            covered = _compiled_application_by_id(compiled, source_application_id) do source
                required = _model_temporal_retention_horizon(
                    binding, consumer, source, compiled.scenario_plan.timeline,
                )
                key = (source_application_id, binding.source_var)
                key in plan.temporal_dependencies &&
                    get(plan.dependency_horizons, key, -Inf) >= required
            end
            covered || return false
        end
        return true
    end
end

function _model_output_retention_covers_addition(
    plan::OutputRetentionPlan,
    compiled::CompiledCompositeModel,
)
    for key in compiled.changed_execution_target_ids
        view = get(compiled.status_views_by_target, key, nothing)
        isnothing(view) && continue
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

function _same_model_output_retention(
    previous::OutputRetentionPlan,
    current::OutputRetentionPlan,
)
    return previous.retain_all == current.retain_all &&
           previous.temporal_dependencies ==
           current.temporal_dependencies &&
           previous.requested_outputs == current.requested_outputs &&
           previous.dependency_horizons == current.dependency_horizons &&
           previous.retained_outputs_by_application ==
           current.retained_outputs_by_application
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

function _model_application_output_variables(
    compiled,
    application,
    ::NoCompiledDistributedOutputs,
)
    return _model_output_names(application)
end

function _model_application_output_variables(
    compiled,
    application,
    distributed_outputs::CompiledDistributedOutputs,
)
    variables = Symbol[Symbol(variable) for variable in _model_output_names(application)]
    for ((application_id, variable), destination_ids) in
        distributed_outputs.destination_ids_by_application_variable
        application_id == application.id || continue
        isempty(destination_ids) && continue
        variable in variables || push!(variables, variable)
    end
    # Plans with an initially empty destination set still define retainable
    # variables that may acquire destinations at a later lifecycle barrier.
    plans = compiled.scenario_plan.distributed_output_plans
    if plans isa CompiledDistributedOutputPlans
        for plan in _application_plans(plans.by_application, application.id)
            for variable_ in plan.variable_names
                variable = Symbol(variable_)
                variable in variables || push!(variables, variable)
            end
        end
    end
    return Tuple(variables)
end

_model_application_output_variables(compiled, application) =
    _model_application_output_variables(
        compiled,
        application,
        compiled.distributed_outputs,
    )

function compile_model_output_retention(
    compiled::CompiledCompositeModel,
    output_requests;
    retain_all::Bool=false,
    accepted_call_times=Dict{Symbol,Float64}(),
)
    temporal_dependencies = Set{Tuple{Symbol,Symbol}}()
    dependency_horizons = Dict{Tuple{Symbol,Symbol},Float64}()
    timeline = compiled.scenario_plan.timeline
    for binding in compiled.input_bindings
        binding.carrier_hint == :temporal_stream || continue
        _compiled_application_by_id(compiled, binding.application_id) do consumer
            for source_application_id in binding.source_application_ids
                _compiled_application_by_id(compiled, source_application_id) do source
                    required = _model_temporal_retention_horizon(
                        binding, consumer, source, timeline,
                    )
                    key = (source_application_id, binding.source_var)
                    push!(temporal_dependencies, key)
                    dependency_horizons[key] = max(
                        get(dependency_horizons, key, 0.0), required,
                    )
                end
            end
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
        if application.id in compiled.scenario_plan.manual_application_ids
            get!(accepted_call_times, application.id, -Inf)
        end
    end
    retained_outputs_by_application = Dict{Symbol,Vector{Symbol}}()
    retained_keys = if retain_all
        all_outputs = Set{Tuple{Symbol,Symbol}}()
        for retained_application_id in keys(compiled.applications_by_id)
            _compiled_application_by_id(compiled, retained_application_id) do application
                for variable in _model_application_output_variables(compiled, application)
                    push!(all_outputs, (application.id, variable))
                end
            end
        end
        all_outputs
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
        retained_outputs_by_application,
        accepted_call_times,
    )
end

function _explain_output_retention(compiled::CompiledCompositeModel, plan)
    keys_to_explain = if plan.retain_all
        all_outputs = Set{Tuple{Symbol,Symbol}}()
        for retained_application_id in keys(compiled.applications_by_id)
            _compiled_application_by_id(compiled, retained_application_id) do application
                for variable in _model_application_output_variables(compiled, application)
                    push!(all_outputs, (application.id, variable))
                end
            end
        end
        all_outputs
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
            current_output_object_count=length(
                _model_output_object_ids(
                    compiled,
                    _compiled_application_by_id(compiled, application_id),
                    variable,
                ),
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
    compiled = _diagnostic_bindings(model)
    output_requests, retain_all = _model_output_selection(outputs)
    plan = compile_model_output_retention(
        compiled,
        output_requests;
        retain_all=retain_all,
    )
    return _explain_output_retention(compiled, plan)
end

@noinline function _synchronize_call_targets_slow!(
    targets::CallTargets,
    context::RunContext,
)
    targets.time = context.time
    targets.publication_allowed = context.publication_allowed
    targets.environment = context.environment
    return targets
end

@inline _with_named_call(operation, ::Tuple{}, name::Symbol, context::RunContext, args...) =
    _missing_named_call(context, name)

# The declared call tuple supplies the finite branches. Keep the operation in
# the selected concrete branch without constructing Val from a runtime name.
@inline function _with_named_call(operation, calls::Tuple, name::Symbol, context::RunContext, args...)
    targets = first(calls)
    if _compiled_call_name(targets.binding) === name
        return operation(targets, context, name, args...)
    end
    return _with_named_call(operation, Base.tail(calls), name, context, args...)
end

@inline function _synchronized_named_call(targets, context::RunContext, name::Symbol)
    targets.time == context.time &&
        targets.publication_allowed == context.publication_allowed &&
        targets.environment === context.environment && return targets
    return _synchronize_call_targets_slow!(targets, context)
end

Base.@constprop :aggressive function _model_call_targets(context::RunContext, name::Symbol)
    return _with_named_call(_synchronized_named_call, context.calls, name, context)
end

@noinline function _initializer_requires_dedicated_api(context, name)
    throw(
        ArgumentError(
            "Call `$(name)` on application `$(context.application.id)` is an " *
            "initializer binding. Use `run_initializer!(context, :$(name), object)` " *
            "exactly once for the newly registered object.",
        ),
    )
end

@inline function _selected_call_targets(targets, context::RunContext, name::Symbol, requested_ids)
    if isnothing(requested_ids)
        _compiled_call_mode(targets.binding) === :manual ||
            _initializer_requires_dedicated_api(context, name)
        return _synchronized_named_call(targets, context, name)
    end
    return _current_topology_call_targets(
        _synchronized_named_call(targets, context, name), context, name, requested_ids,
    )
end

_call_target_matches(targets::CallTargets, application, object_id::ObjectId) =
    _call_binding_target_matches(targets.binding, application, object_id)

@inline function _with_call_execution_batch(f::F, targets::CallTargets, batches, index::Int) where {F}
    return _with_metadata_entry(batches, index) do batch
        _with_execution_batch(f, targets.batch_schema, batch)
    end
end

function Base.length(targets::CallTargets)
    count = 0
    batches = _materialize_call_execution_batches!(targets)
    for index in eachindex(batches)
        count += _with_call_execution_batch(targets, batches, index) do batch
            length(batch.targets)
        end
    end
    return count
end

Base.size(targets::CallTargets) = (length(targets),)

@inline function _materialize_call(
    targets::CallTargets,
    application,
    target::CompiledExecutionTarget,
)
    return _materialize_call(CallTarget, targets, application, target)
end

@inline function _materialize_call(
    ::Type{V},
    targets::CallTargets,
    application,
    target::CompiledExecutionTarget,
) where {V<:CallTarget}
    # A reusable buffer already matches the environment type. Recover it before
    # constructing a concrete view so Julia does not box fields at a dynamic
    # constructor call.
    environment = isconcretetype(V) ?
        (targets.environment::fieldtype(V, :environment)) : targets.environment
    context = target.context
    calls = if context isa RunContext
        if target.call_context_cache.in_use
            if _call_context_clone_is_current(
                context, targets.compiled, targets.environment_bindings,
                application, target.object_id, target.bound_inputs, target.output_targets,
                target.call_bindings,
                targets.temporal_streams, targets.output_retention, targets.constants,
            )
                _clone_runtime_call_targets(
                    context.calls, targets.compiled, targets.environment_bindings,
                    targets.temporal_streams, targets.output_retention, targets.time,
                    targets.constants, targets.publication_allowed, environment,
                )
            else
                _runtime_call_targets(
                    targets.compiled, targets.environment_bindings, target.call_bindings,
                    targets.temporal_streams, targets.output_retention, targets.time,
                    targets.constants, targets.publication_allowed, environment;
                    call_schema=_context_call_schema(context),
                )
            end
        else
            _prepare_runtime_call_targets!(
                context.calls,
                targets.compiled,
                targets.environment_bindings,
                targets.temporal_streams,
                targets.output_retention,
                targets.time,
                targets.constants,
                targets.publication_allowed,
                environment,
            )
            context.calls
        end
    else
        _runtime_call_targets(
            targets.compiled,
            targets.environment_bindings,
            target.call_bindings,
            targets.temporal_streams,
            targets.output_retention,
            targets.time,
            targets.constants,
            targets.publication_allowed,
            environment,
        )
    end
    return V(
        target,
        targets.compiled,
        targets.environment_bindings,
        application,
        target.object_id,
        calls,
        targets.temporal_streams,
        targets.output_retention,
        targets.time,
        targets.constants,
        targets.publication_allowed,
        environment,
    )
end

function Base.getindex(targets::CallTargets, requested::Int)
    batches = _materialize_call_execution_batches!(targets)
    remaining = requested
    for index in eachindex(batches)
        count, selected = let position=remaining
            _with_call_execution_batch(targets, batches, index) do batch
                batch_count = length(batch.targets)
                target = 1 <= position <= batch_count ?
                    _materialize_call(targets, batch.application, batch.targets[position]) : nothing
                return batch_count, target
            end
        end
        isnothing(selected) || return selected
        remaining -= count
    end
    throw(BoundsError(targets, (requested,)))
end

function Base.iterate(targets::CallTargets, state::Tuple{Int,Int}=(1, 1))
    batch_index, target_index = state
    batches = _materialize_call_execution_batches!(targets)
    while batch_index <= length(batches)
        selected = let batch_position=batch_index, target_position=target_index
            _with_call_execution_batch(targets, batches, batch_position) do batch
                target_position <= length(batch.targets) || return nothing
                target = batch.targets[target_position]
                return (_materialize_call(targets, batch.application, target),
                    (batch_position, target_position + 1))
            end
        end
        isnothing(selected) || return selected
        batch_index += 1
        target_index = 1
    end
    return nothing
end

# Array collection would allocate Vector{CallTarget} and repeatedly index the
# lazy collection. Iteration preserves concrete homogeneous snapshot types and
# widens normally when target models/statuses differ. Every view is still fresh.
function Base.collect(targets::CallTargets)
    isempty(targets) && return CallTarget[]
    return collect(target for target in targets)
end

@inline function _call_target_buffer_matches(entry, targets, batches, environment_type)
    return entry isa _CallTargetBuffer &&
           entry.batches === batches && entry.binding === targets.binding &&
           entry.compiled === targets.compiled &&
           entry.environment_bindings === targets.environment_bindings &&
           entry.environment_type === environment_type
end

@noinline function _new_call_target_buffer!(cache, targets, batches, environment_type)
    entry = _CallTargetBuffer(collect(targets), batches, targets.binding,
        targets.compiled, targets.environment_bindings, environment_type, false)
    # Keep the ordinary slot stable while nested calls use the second slot.
    # Deeper reentrancy gets independent temporary storage rather than
    # overwriting a vector that is still borrowed by an ancestor.
    if cache.first === nothing
        cache.first = entry
    elseif cache.first.in_use
        if cache.second === nothing || !cache.second.in_use
            cache.second = entry
        end
    else
        if cache.second === nothing || !cache.second.in_use
            cache.second = cache.first
        end
        cache.first = entry
    end
    return entry
end

function _refill_call_target_buffer!(values::Vector{V}, targets::CallTargets,
    batches::Union{Tuple,AbstractVector},
) where {V}
    count = 0
    for index in eachindex(batches)
        count += _with_call_execution_batch(targets, batches, index) do batch
            length(batch.targets)
        end
    end
    resize!(values, count)
    written = 0
    for index in eachindex(batches)
        next_count = let offset=written
            _with_call_execution_batch(targets, batches, index) do batch
                for (local_index, target) in enumerate(batch.targets)
                    # Keep the same concrete snapshot constructor for inline
                    # homogeneous buffers; heterogeneous vectors widen normally.
                    view = if isconcretetype(V)
                        _materialize_call(V, targets, batch.application, target)
                    else
                        _materialize_call(targets, batch.application, target)
                    end
                    @inbounds values[offset + local_index] = view
                end
                return length(batch.targets)
            end
        end
        written += next_count
    end
    return values
end

function _with_call_target_buffer(f::F, entry::_CallTargetBuffer, targets, batches) where {F}
    entry.in_use = true
    try
        values = _refill_call_target_buffer!(entry.values, targets, batches)
        return f(values)
    finally
        entry.in_use = false
    end
end

"""
    with_call_targets(f, context::RunContext, name::Symbol)
    with_call_targets(f, targets::CallTargets)

Call `f` with a borrowed vector of the current hard-call targets and return
its result. Homogeneous targets keep a concrete element type; mixed types
widen as needed. The engine reuses prepared storage while the target bindings
and environment type remain compatible. Each invocation
refreshes caller metadata and restores compiled target order; it shares live
status references and does not run a model or copy numerical state.

The vector may be reordered inside `f`, but must not escape the callback or be
retained for another invocation. Use `collect(values)` inside the callback for
an independent vector. Individual immutable `CallTarget` values may be retained;
they keep their captured time, environment and publication permission.

Nested invocations borrow independent storage, and exceptions release the
lease. This controls storage lifetime, not rollback or concurrent execution of
one mutable model/status. Ordinary `collect(targets)` continues to return fresh
storage. Use `call_targets(context, name; objects=...)` for targeted newborns.
"""
function with_call_targets(f::F, targets::CallTargets) where {F}
    batches = _materialize_call_execution_batches!(targets)
    environment_type = typeof(targets.environment)
    cache = targets.target_buffer_cache
    if cache === nothing
        cache = _CallTargetBufferCache(nothing, nothing)
        targets.target_buffer_cache = cache
    end
    entry = if _call_target_buffer_matches(cache.first, targets, batches, environment_type) &&
               !cache.first.in_use
        cache.first
    elseif _call_target_buffer_matches(cache.second, targets, batches, environment_type) &&
           !cache.second.in_use
        cache.second
    else
        _new_call_target_buffer!(cache, targets, batches, environment_type)
    end
    return _with_call_target_buffer(f, entry, targets, batches)
end

@inline Base.@constprop :aggressive function with_call_targets(
    f::F, context::RunContext, name::Symbol,
) where {F}
    return with_call_targets(f, call_targets(context, name))
end

@noinline function _single_call_snapshot_matches(
    snapshot::CallTarget,
    targets::CallTargets,
    application,
    target::CompiledExecutionTarget,
    context::RunContext,
)
    return getfield(snapshot, :execution_target) === target &&
           getfield(snapshot, :compiled) === targets.compiled &&
           getfield(snapshot, :environment_bindings) === targets.environment_bindings &&
           getfield(snapshot, :application) === application &&
           getfield(snapshot, :object_id) === target.object_id &&
           getfield(snapshot, :calls) === context.calls &&
           getfield(snapshot, :temporal_streams) === targets.temporal_streams &&
           getfield(snapshot, :output_retention) === targets.output_retention &&
           getfield(snapshot, :time) === targets.time &&
           getfield(snapshot, :constants) === targets.constants &&
           getfield(snapshot, :publication_allowed) === targets.publication_allowed &&
           getfield(snapshot, :environment) === targets.environment
end

@inline function _default_single_call_view_type(
    ::CallTargets{CS,EB,B,TS,OR,C},
    ::A,
    ::T,
    ::RC,
) where {CS,EB,B,TS,OR,C,A,T<:CompiledExecutionTarget,RC<:RunContext}
    CT = fieldtype(RC, :calls)
    E = fieldtype(RC, :environment)
    I = fieldtype(T, :object_id)
    return CallTarget{T,CS,EB,A,CT,TS,OR,C,E,I}
end

@noinline function _transient_single_call_target_slot(
    targets::CallTargets{CS,EB,B,TS,OR,C},
    application::A,
    target::T,
    context::RC,
    environment::E,
) where {CS,EB,B,TS,OR,C,A,T<:CompiledExecutionTarget,RC<:RunContext,E}
    # The collection stores override metadata behind Any. Cross that boundary
    # once so this specialization knows the actual environment type while
    # checking and constructing cached immutable views.
    CT = fieldtype(RC, :calls)
    I = fieldtype(T, :object_id)
    Slot = _TransientSingleCallSlot{_SingleCallTargetView{T,CS,EB,A,TS,OR,C,I}}
    View = CallTarget{T,CS,EB,A,CT,TS,OR,C,E,I}
    previous = targets.last_single_snapshot
    if previous isa Slot
        snapshot = previous.snapshot
        if snapshot isa View &&
           _single_call_snapshot_matches(snapshot, targets, application, target, context)
            return previous::Slot
        end
    end
    snapshot = View(
        target,
        targets.compiled,
        targets.environment_bindings,
        application,
        target.object_id,
        context.calls,
        targets.temporal_streams,
        targets.output_retention,
        targets.time,
        targets.constants,
        targets.publication_allowed,
        environment,
    )
    if previous isa Slot
        previous.snapshot = snapshot
        return previous::Slot
    end
    slot = Slot(snapshot)
    targets.last_single_snapshot = slot
    return slot
end

@inline function _single_call_target_snapshot(
    targets::CallTargets{CS,EB,B,TS,OR,C},
    application::A,
    target::T,
) where {CS,EB,B,TS,OR,C,A,T<:CompiledExecutionTarget}
    # The execution owner determines model/status types. Descendant tuple and
    # environment types may change, including during a leased lifecycle refresh.
    View = _SingleCallTargetView{T,CS,EB,A,TS,OR,C,fieldtype(T, :object_id)}
    context = target.context
    if context isa RunContext && !target.call_context_cache.in_use
        _prepare_runtime_call_targets!(
            context.calls,
            targets.compiled,
            targets.environment_bindings,
            targets.temporal_streams,
            targets.output_retention,
            targets.time,
            targets.constants,
            targets.publication_allowed,
            targets.environment,
        )
        previous = targets.last_single_snapshot
        ConcreteView = _default_single_call_view_type(
            targets, application, target, context,
        )
        # Exact default metadata permits a concrete type check instead of
        # existential subtyping without crossing a dynamic override boundary.
        if isconcretetype(ConcreteView) &&
           isconcretetype(CS) && isconcretetype(EB) &&
           isconcretetype(TS) && isconcretetype(OR) && isconcretetype(C) &&
           isconcretetype(fieldtype(typeof(context), :calls)) &&
           typeof(targets.environment) === fieldtype(ConcreteView, :environment)
            if previous isa ConcreteView &&
               _single_call_snapshot_matches(previous, targets, application, target, context)
                return previous::ConcreteView
            end
            snapshot = ConcreteView(
                target,
                targets.compiled,
                targets.environment_bindings,
                application,
                target.object_id,
                context.calls,
                targets.temporal_streams,
                targets.output_retention,
                targets.time,
                targets.constants,
                targets.publication_allowed,
                targets.environment,
            )
            targets.last_single_snapshot = snapshot
            return snapshot
        end
        if isconcretetype(CS) && isconcretetype(EB) &&
           isconcretetype(TS) && isconcretetype(OR) && isconcretetype(C) &&
           isconcretetype(fieldtype(typeof(context), :calls))
            # A concrete mutable slot preserves the cached box and the known
            # metadata types without an existential view check at this boundary.
            return _transient_single_call_target_slot(
                targets, application, target, context, targets.environment,
            ).snapshot
        end
        if previous isa View &&
           _single_call_snapshot_matches(previous, targets, application, target, context)
            return previous::View
        end
        snapshot = CallTarget(
            target,
            targets.compiled,
            targets.environment_bindings,
            application,
            target.object_id,
            context.calls,
            targets.temporal_streams,
            targets.output_retention,
            targets.time,
            targets.constants,
            targets.publication_allowed,
            targets.environment,
        )
        targets.last_single_snapshot = snapshot
        return snapshot::View
    end
    # Reentrant materialization owns fresh descendants and never changes the
    # outer cached snapshot. Nothing-context owners keep general construction.
    return _materialize_call(targets, application, target)::View
end

@noinline function _only_call_target_count_error(count::Int)
    if iszero(count)
        throw(ArgumentError("Collection is empty, must contain exactly 1 element"))
    end
    throw(ArgumentError("Collection has multiple elements, must contain exactly 1 element"))
end

@inline function _only_call_target(targets::CallTargets, batches::Tuple{B}) where {B}
    batch = first(batches)
    length(batch.targets) == 1 || _only_call_target_count_error(length(batch.targets))
    return _single_call_target_snapshot(targets, batch.application, batch.targets[1])
end

function _only_call_target(targets::CallTargets, batches::Union{Tuple,AbstractVector})
    count = 0
    selected_index = 0
    for index in eachindex(batches)
        next_count = _with_call_execution_batch(targets, batches, index) do batch
            length(batch.targets)
        end
        iszero(next_count) && continue
        count += next_count
        count == 1 || _only_call_target_count_error(count)
        selected_index = index
    end
    iszero(count) && _only_call_target_count_error(count)
    return _with_call_execution_batch(targets, batches, selected_index) do batch
        _single_call_target_snapshot(targets, batch.application, batch.targets[1])
    end
end

# Reuse only indistinguishable immutable snapshots; all numerical state is
# still live. General iteration/collection and borrowed-buffer paths stay fresh.
@inline function Base.only(targets::CallTargets{CS,EB,B,TS,OR,C}) where {CS,EB,B,TS,OR,C}
    return _only_call_target(targets,
        _materialize_call_execution_batches!(targets))::_CallTargetMetadata{CS,EB,TS,OR,C}
end

"""
    call_targets(context::RunContext, name::Symbol; objects=nothing)

Return a cached, non-executing vector-like view of the targets declared for
`name` with `ModelSpec(...; calls=...)`. The collection is empty for an unresolved
`OptionalOne`, has one element for `One`, and contains every resolved target
for `Many`.

When `objects` is provided, resolve the declared call against the current
object topology and restrict the result to those objects. This explicit form is
intended for models that create objects and immediately initialize selected
manual-call-only applications on them. Structural refresh still occurs at the
safe barrier after a pure-addition event. If the pending event also removes or
reparents objects, this accessor performs a full binding/environment refresh
before resolving the explicit targets. Use [`Initializer`](@ref) and
[`run_initializer!`](@ref) instead when the target application must remain in
the normal schedule. Each requested object may be an [`ObjectId`](@ref),
[`Object`](@ref), an MTG node, or the [`Status`](@ref) returned by
[`add_organ!`](@ref).

Use this accessor with [`run_call!(::CallTarget)`](@ref) when targets need
different sampled environments, selective execution, a controlled order, or separate
trial and accepted publication.
"""
Base.@constprop :aggressive function call_targets(
    context::RunContext,
    name::Symbol,
    ;
    objects=nothing,
)
    requested_ids = isnothing(objects) ? nothing :
        _call_target_object_ids(runtime_model(context), objects)
    return _with_named_call(_selected_call_targets, context.calls, name, context, requested_ids)
end

@inline function _single_call_model(targets::CallTargets, batches::Tuple{B}) where {B}
    # The caller has already checked singular membership. Index directly rather
    # than allocating the Vector iterator's (target, state) tuple on this path.
    return first(batches).targets[1].model
end

function _single_call_model(targets::CallTargets, batches::Union{Tuple,AbstractVector})
    # Singular membership was checked by call_model. Empty retained runs do not
    # choose a model; every real payload remains in its admitted batch branch.
    for index in eachindex(batches)
        model = _with_call_execution_batch(targets, batches, index) do batch
            isempty(batch.targets) && return nothing
            return batch.targets[1].model
        end
        isnothing(model) || return model
    end
    _only_call_target_count_error(0)
end

"""
    call_model(context::RunContext, name::Symbol)

Return the concrete model for a declared hard call that currently resolves to
exactly one execution target. This is the allocation-free singular access path
for a controller that needs to dispatch on or inspect its fixed dependency
model before executing it.

Use [`call_targets`](@ref) when status access, selective execution, or more than
one target is required. The returned model is the model stored in the compiled
execution target and remains valid until a lifecycle refresh barrier.
"""
@noinline function _call_model_target_count_error(name, targets)
    throw(
        ArgumentError(
            "Hard call `$(name)` must resolve to exactly one target to use " *
            "`call_model`; resolved $(length(targets)).",
        ),
    )
end

@noinline function _missing_named_call(context, name)
    available = Symbol[targets.binding.call for targets in context.calls]
    error(
        "Application `$(context.application.id)` on object ",
        "`$(context.object_id.value)` did not declare call `$(name)`. ",
        "Declared calls: $(available).",
    )
end

@inline function _selected_call_model(targets, context::RunContext, name::Symbol)
    targets = _synchronized_named_call(targets, context, name)
    _compiled_call_mode(targets.binding) === :manual ||
        _initializer_requires_dedicated_api(context, name)
    length(targets) == 1 || _call_model_target_count_error(name, targets)
    return _single_call_model(targets, _materialize_call_execution_batches!(targets))
end

@inline Base.@constprop :aggressive function call_model(context::RunContext, name::Symbol)
    return _with_named_call(_selected_call_model, context.calls, name, context)
end

function call_model(context, name::Symbol)
    throw(
        ArgumentError(
            "`call_model` requires the compiled RunContext passed to a model " *
            "kernel; got $(typeof(context)).",
        ),
    )
end

function _call_target_object_id(model::CompositeModel, target)
    return object_id(model, target)
end

function _call_target_object_ids(model::CompositeModel, objects)
    requested = objects isa Union{Tuple,AbstractVector,AbstractSet} ?
                objects : (objects,)
    ids = ObjectId[_call_target_object_id(model, object) for object in requested]
    unique!(ids)
    return _application_target_ids(model, ids)
end

struct _ApplicationsByObjectOverlay{B,O}
    base::B
    overlay::O
end

mutable struct _TargetedApplicationSet{A,B}
    applications::A
    applications_by_object::B
    outputs_prepared::Bool
end

mutable struct _TargetedTopologyRuntime{CS,MA} <:
               AbstractTargetedTopologyRuntime
    compiled::CS
    model_revision::Int
    application_sets::Dict{
        Tuple{Vararg{ObjectId}},
        Union{Nothing,_TargetedApplicationSet},
    }
    added_applications_by_object::Dict{
        ObjectId,
        Vector{CompiledModelApplication},
    }
    indexed_addition_count::Int
    manual_application_ids::MA
    application_positions::Dict{Symbol,Int}
    call_context_caches::Dict{Tuple{Symbol,ObjectId},CallContextCache}
end

@inline function Base.get(
    applications::_ApplicationsByObjectOverlay,
    object_id,
    default,
)
    overlay = get(applications.overlay, object_id, nothing)
    isnothing(overlay) || return overlay
    return get(applications.base, object_id, default)
end

function _targeted_topology_runtime!(
    context::RunContext,
    model::CompositeModel,
)
    delta = lifecycle_delta(model)
    cached = delta.targeted_topology_runtime
    if cached isa _TargetedTopologyRuntime &&
       cached.compiled === context.compiled &&
       cached.model_revision == model.revision
        return cached
    end
    compiled = context.compiled
    runtime = _TargetedTopologyRuntime(
        compiled,
        model.revision,
        Dict{
            Tuple{Vararg{ObjectId}},
            Union{Nothing,_TargetedApplicationSet},
        }(),
        Dict{ObjectId,Vector{CompiledModelApplication}}(),
        0,
        compiled.scenario_plan.manual_application_ids,
        Dict(
            application_id => index
            for (index, application_id) in pairs(compiled.application_order)
        ),
        Dict{Tuple{Symbol,ObjectId},CallContextCache}(),
    )
    delta.targeted_topology_runtime = runtime
    return runtime
end

function _new_object_applications(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    requested_ids,
)
    by_object = Dict{ObjectId,Vector{CompiledModelApplication}}()
    partial_applications = CompiledModelApplication[]
    new_targets = _new_application_targets(
        model,
        compiled,
        requested_ids,
    )
    for slot in sort!(Int[
        compiled.applications_by_id[application_id].slot
        for application_id in keys(new_targets)
    ])
        application = compiled.applications[slot]
        target_ids = new_targets[application.id]
        partial = _partial_model_application(application, target_ids)
        push!(partial_applications, partial)
        for object_id in target_ids
            applications = get!(by_object, object_id) do
                CompiledModelApplication[
                    application for application in get(
                        compiled.applications_by_object,
                        object_id,
                        (),
                    )
                ]
            end
            any(candidate -> candidate.id == application.id, applications) ||
                push!(applications, partial)
        end
    end
    return (partial_applications, by_object)
end

function _targeted_application_set!(
    runtime::_TargetedTopologyRuntime,
    model::CompositeModel,
    requested_ids,
)
    key = Tuple(requested_ids)
    application_set = get!(runtime.application_sets, key) do
        applications = _new_object_applications(
            model,
            runtime.compiled,
            requested_ids,
        )
        isnothing(applications) && return nothing
        output_applications, added_applications_by_object = applications
        merge!(
            runtime.added_applications_by_object,
            added_applications_by_object,
        )
        return _TargetedApplicationSet(
            Tuple(output_applications),
            _ApplicationsByObjectOverlay(
                runtime.compiled.applications_by_object,
                runtime.added_applications_by_object,
            ),
            false,
        )
    end
    isnothing(application_set) && return nothing

    # A fully initialized source can be registered without an explicit call.
    # Include its application membership before resolving newborn inputs. The
    # append-only delta cursor visits each addition once across a chain of calls;
    # targets prepared above already have membership and need no extra lookup.
    added = lifecycle_delta(model).added
    unindexed_ids = nothing
    for index in (runtime.indexed_addition_count + 1):length(added)
        object_id = added[index].id
        haskey(runtime.added_applications_by_object, object_id) && continue
        isnothing(unindexed_ids) && (unindexed_ids = ObjectId[])
        push!(unindexed_ids, object_id)
    end
    if !isnothing(unindexed_ids)
        applications = _new_object_applications(
            model,
            runtime.compiled,
            unindexed_ids,
        )
        isnothing(applications) && return nothing
        merge!(runtime.added_applications_by_object, last(applications))
    end
    runtime.indexed_addition_count = length(added)
    return application_set
end

function _targeted_callee_applications(
    binding::CompiledModelCallBinding,
    requested_ids,
    partial_applications,
)
    applications = CompiledModelApplication[]
    unresolved_ids = ObjectId[]
    for object_id in requested_ids
        matched = false
        for application in partial_applications
            object_id in application.target_ids || continue
            isnothing(binding.process) ||
                application.process == binding.process ||
                continue
            isnothing(binding.application) ||
                application.id == binding.application ||
                continue
            calls = model_calls(application.spec)
            calls isa NamedTuple && !isempty(keys(calls)) && return nothing
            any(candidate -> candidate.id == application.id, applications) ||
                push!(applications, application)
            matched = true
        end
        matched || push!(unresolved_ids, object_id)
    end
    isempty(unresolved_ids) || error(
        "Hard call `$(binding.call)` from application `$(binding.application_id)` does not ",
        "resolve requested object(s) `$(Tuple(id.value for id in unresolved_ids))`."
    )
    return Tuple(applications)
end

function _applications_use_only_global_environment(
    model::CompositeModel,
    applications,
)
    return all(applications) do application
        backend = _environment_backend_from_config(
            model,
            environment_config(application.spec),
        )
        return isnothing(backend) || backend isa GlobalConstant
    end
end

function _targeted_call_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    applications,
    applications_by_id,
)
    _applications_use_only_global_environment(model, applications) ||
        return nothing
    partial = _compile_environment_bindings_for_applications(
        model,
        applications,
        cached.application_plans_by_id;
        environment_schema=cached.environment_schema,
    )
    _validate_model_environment_inputs!(partial, applications_by_id,
        keytype(model.registry.objects);
        environment_schema=cached.environment_schema)
    by_target = _index_environment_bindings(partial, keytype(model.registry.objects))
    return _compiled_environment_bindings(
        model,
        compiled,
        cached.application_plans,
        cached.application_plans_by_id,
        partial,
        by_target,
        cached.sample_cache;
        environment_schema=cached.environment_schema,
    )
end

function _targeted_new_object_call_targets(
    context::RunContext,
    name::Symbol,
    requested_ids,
    cached_targets::CallTargets,
    ;
    initializer::Bool=false,
)
    model = runtime_model(context)
    binding = cached_targets.binding
    expected_mode = initializer ? :initializer : :manual
    _compiled_call_mode(binding) === expected_mode || error(
        initializer ?
        "Call `$(name)` is a manual hard call, not an `Initializer` binding." :
        "Call `$(name)` is an initializer binding; use `run_initializer!`.",
    )
    if initializer
        length(requested_ids) == 1 || error(
            "Initializer `$(name)` requires exactly one newly registered object; " *
            "got $(length(requested_ids)).",
        )
    end
    if !bindings_dirty(model)
        initializer && error(
            "Initializer `$(name)` can run only during the lifecycle event that " *
            "registered its target; the model has no pending structural addition.",
        )
        return nothing
    end
    delta = lifecycle_delta(model)
    if delta.structural_kind !== :addition
        if initializer
            error(
                "Initializer `$(name)` requires a pure object-addition lifecycle event; " *
                "the pending structural change is `$(delta.structural_kind)`.",
            )
        end
        return nothing
    end
    dirty_ids = delta.structural_dirty_ids
    if !all(object_id -> object_id in dirty_ids, requested_ids)
        initializer && error(
            "Initializer `$(name)` target is not part of the pending object addition.",
        )
        return nothing
    end
    if initializer
        object_id = only(requested_ids)
        # For a pure `:addition` delta, `structural_dirty_ids` is exactly the
        # set populated by `_record_added_objects!`. Other structural mutations
        # change `structural_kind` and were rejected above, so the O(1) dirty-id
        # membership check already performed is the canonical newborn proof.
        initialization_key = (only(binding.potential_callee_application_ids), object_id)
        initialization_key in delta.initialized_targets && error(
            "Application `$(first(initialization_key))` already initialized newly " *
            "registered object `$(object_id.value)` in this lifecycle event.",
        )
    end

    binding.multiplicity != :many && length(requested_ids) > 1 &&
        error(
            "Hard call `$(name)` from application `$(context.application.id)` ",
            "accepts at most one requested object.",
        )
    default_scope = _default_dependency_scope(model, context.object_id)
    unresolved_ids = ObjectId[
        object_id for object_id in requested_ids
        if !_selector_matches_object_id(
            model,
            binding.matcher,
            object_id;
            context=context.object_id,
            default_to_context=true,
            default_scope=default_scope,
        )
    ]
    isempty(unresolved_ids) || error(
        "Hard call `$(name)` from application `$(context.application.id)` does not ",
        "resolve requested object(s) `$(Tuple(id.value for id in unresolved_ids))`."
    )
    if !initializer && binding.multiplicity != :many
        # A targeted newborn does not relax the authored singular selector.
        # Resolve its complete live scope before compiling or preparing any
        # newborn status so an existing match plus the newborn fails atomically.
        _dependency_object_ids(
            model,
            binding.selector,
            binding.matcher,
            binding.consumer_id,
        )
    end

    compiled = context.compiled
    targeted_runtime = _targeted_topology_runtime!(context, model)
    application_set = _targeted_application_set!(
        targeted_runtime,
        model,
        requested_ids,
    )
    if isnothing(application_set)
        initializer && error(
            "Initializer `$(name)` could not compile its newly registered target " *
            "against the scheduled application selector.",
        )
        return nothing
    end
    output_applications = application_set.applications
    callee_applications = _targeted_callee_applications(
        binding,
        requested_ids,
        output_applications,
    )
    if isnothing(callee_applications)
        initializer && error(
            "Initializer `$(name)` target application declares nested hard calls, " *
            "which targeted newborn execution does not support.",
        )
        return nothing
    end
    if !initializer && binding.multiplicity != :many
        pair_count = sum(
            count(object_id -> object_id in requested_ids, application.target_ids)
            for application in callee_applications;
            init=0,
        )
        pair_count == 1 || error(
            "Hard call `$(name)` from application `$(context.application.id)` " *
            "expected exactly one callee application/object pair, got $(pair_count).",
        )
    end

    return _prepare_targeted_newborn_targets(
        context, name, targeted_runtime, application_set, callee_applications, initializer,
        cached_targets.batch_schema,
    )
end

# Application membership is assembled dynamically, but its finite schema is
# stable for newborns selected by the same application recipe. Keep that tuple
# concrete across the canonical status and binding preparation below.
function _prepare_targeted_newborn_targets(
    context::RunContext,
    name::Symbol,
    targeted_runtime::_TargetedTopologyRuntime,
    application_set::_TargetedApplicationSet,
    callee_applications::Tuple,
    initializer::Bool,
    batch_schema::ExecutionBatchSchema,
)
    model = runtime_model(context)
    compiled = context.compiled
    output_applications = application_set.applications
    applications_by_object = application_set.applications_by_object
    if !application_set.outputs_prepared
        _prepare_model_output_statuses_batched!(model, output_applications)
        application_set.outputs_prepared = true
    end
    input_bindings = CompiledModelInputBinding[]
    for application in callee_applications
        isempty(application.target_ids) && continue
        recipe = _application_plans(
            compiled.scenario_plan.input_recipes_by_application, application.id,
        )
        _compile_application_consumer_bindings!(
            input_bindings, model, application, recipe,
            targeted_runtime.manual_application_ids, applications_by_object,
            compiled.applications_by_id, compiled.distributed_outputs,
        )
    end
    final_input_references = _model_input_status_references(input_bindings)
    _prepare_model_input_statuses_batched!(
        model,
        callee_applications,
        input_bindings;
        final_references=final_input_references,
    )
    _validate_model_required_inputs!(
        model,
        callee_applications,
        input_bindings,
    )
    unsupported_temporal_inputs = Symbol[
        input_binding.input for input_binding in input_bindings
        if input_binding.carrier_hint == :temporal_stream &&
           !(input_binding.policy isa PreviousTimeStep)
    ]
    if !isempty(unsupported_temporal_inputs)
        initializer && error(
            "Initializer `$(name)` target requires unsupported temporal input(s) " *
            "`$(Tuple(unsupported_temporal_inputs))`; only `PreviousTimeStep` has " *
            "defined newborn initialization semantics.",
        )
        return nothing
    end

    targeted_input_bindings = _index_model_bindings(
        input_bindings, keytype(model.registry.objects),
    )

    environment_bindings = _targeted_call_environment_bindings(
        model,
        compiled,
        context.environment_bindings,
        callee_applications,
        compiled.applications_by_id,
    )
    if isnothing(environment_bindings)
        initializer && error(
            "Initializer `$(name)` target requires a non-global environment " *
            "binding, which targeted newborn execution does not support.",
        )
        return nothing
    end

    targets = _targeted_newborn_target_buffer(batch_schema, context)
    for partial_application in callee_applications
        _append_targeted_newborn_targets!(
            targets, context, targeted_runtime, partial_application,
            targeted_input_bindings, environment_bindings, batch_schema,
        )
    end
    if initializer
        length(targets) == 1 || error(
            "Initializer `$(name)` must resolve one scheduled application target " *
            "for one newborn object; resolved $(length(targets)).",
        )
    end
    return targets
end

function _append_targeted_newborn_targets!(
    targets,
    context::RunContext,
    targeted_runtime::_TargetedTopologyRuntime,
    partial_application::CompiledModelApplication,
    targeted_input_bindings,
    environment_bindings::CompiledEnvironmentBindings,
    batch_schema::ExecutionBatchSchema,
)
    compiled = context.compiled
    # Partial applications share the genuine authored application plan.
    _compiled_application_by_id(compiled,partial_application.id) do application
        application_schema = _call_batch_schema_for_application(batch_schema,application)
        admission = _call_cohort_admission(application_schema,OpenExecutionCohortSchema())
        for object_id in partial_application.target_ids
            key = (application.id,object_id)
            cache = get(targeted_runtime.call_context_caches,key,nothing)::Union{Nothing,CallContextCache}
            stamp = isnothing(cache) ? Ref(UInt64(0)) :
                (getfield(cache,:execution_stamp)::Base.RefValue{UInt64})
            status_view = _compile_model_status_view(runtime_model(context),partial_application,
                object_id,get(targeted_input_bindings,key,()),compiled.applications_by_id,
                targeted_runtime.application_positions,compiled.distributed_outputs;
                execution_stamp=stamp)::CompiledModelStatusView
            output_targets = _runtime_model_output_targets(compiled,application,object_id)
            environment_binding = _environment_binding_for(environment_bindings,application.id,object_id)
            call_bindings = () # targeted admission has rejected nested callees
            fields = (object_id=object_id,model=_application_model(application,object_id),
                output_targets=output_targets,call_bindings=call_bindings,
                environment_binding=environment_binding)
            owners = (compiled=compiled,environment_bindings=environment_bindings,
                temporal_streams=context.temporal_streams,
                output_retention=context.output_retention,constants=context.constants,
                environment=context.environment)
            _with_execution_target_type(admission,application,status_view,fields,owners) do target_type,actual_application,actual,owner,call_schema
                _append_targeted_newborn_target!(target_type,actual_application,actual,owner,
                    call_schema,targets,context,cache,stamp,targeted_runtime,key)
            end
        end
        return nothing
    end
    return targets
end

function _append_targeted_newborn_target!(::Val{Target}, actual_application, actual, owner,
    call_schema, targets, context, cache, stamp, targeted_runtime, key,
) where {Target}
    outputs = isnothing(Target) ?
        _runtime_model_output_streams(actual.status_view.status,actual_application,
            actual.object_id,owner.temporal_streams,owner.output_retention,true) :
        _prepared_runtime_outputs(fieldtype(Target,:output_bindings),
            actual.status_view,actual.output_targets,actual_application,
            actual.object_id,owner.compiled,owner.temporal_streams,
            owner.output_retention,true)
    # Narrow a retained cache before use; no new owner is published
    # until all real fields have passed the same target admission.
    prepared_cache = _admit_newborn_context_cache(Target,cache)
    if isnothing(prepared_cache)
        prepared_cache = _newborn_call_context_cache(context,actual_application,
            actual.object_id,actual.bound_inputs,actual.output_targets,
            actual.call_bindings,owner.environment_bindings,stamp;call_schema)
    end
    result = _targeted_newborn_call_target(context,actual_application,
        actual.object_id,actual.model,actual.status_view,outputs,
        actual.output_targets,actual.call_bindings,owner.environment_bindings,
        actual.environment_binding,prepared_cache)
    isnothing(Target) || result.execution_target isa Target ||
        throw(ArgumentError("A newborn execution target is outside its prepared schema."))
    # Admit the full caller view before publishing its cache. The
    # payload and partial environment owner retain their identities.
    push!(targets,result)
    targeted_runtime.call_context_caches[key] = prepared_cache
    return nothing
end

# Adopt a pre-barrier newborn's logical counter when the ordinary compiler
# installs its view. This is cold construction over an existing cache directory,
# never a kernel-time identity lookup or a second target store.
function _targeted_call_execution_stamp(model::CompositeModel, key)
    targeted = lifecycle_delta(model).targeted_topology_runtime
    if targeted isa _TargetedTopologyRuntime
        cache = get(targeted.call_context_caches, key, nothing)::Union{Nothing,CallContextCache}
        isnothing(cache) || return getfield(cache, :execution_stamp)::Base.RefValue{UInt64}
    end
    return Ref(UInt64(0))
end

# Build a real context only on the first preparation of this newborn owner.
# Repeated target retrieval never changes an active default shell or its leases.
# Call bindings come from resolution, not from the shape of a cached prototype.
function _newborn_call_context_cache(context::RunContext, application, object_id,
    bound_inputs, output_targets, call_bindings::Tuple, environment_bindings,
    stamp::Base.RefValue{UInt64};
    call_schema=OpenContextCallSchema(),
)
    prepared = _prepare_model_execution_context!(
        nothing, context.compiled, environment_bindings, application, object_id,
        bound_inputs, output_targets, call_bindings, context.temporal_streams,
        context.output_retention, context.time, context.constants,
        context.publication_allowed, context.environment;call_schema,
    )
    return CallContextCache(prepared, stamp)
end

# Status views, publication tuples and handles leave heterogeneous assembly at
# this boundary. Reuse one concrete payload constructor for each actual schema.
function _targeted_newborn_call_target(
    context::RunContext,
    application::CompiledModelApplication,
    object_id::ObjectId,
    model,
    status_view::CompiledModelStatusView,
    outputs::Tuple,
    output_targets::NamedTuple,
    call_bindings::Tuple,
    environment_bindings::CompiledEnvironmentBindings,
    environment_binding,
    cache::CallContextCache{RC},
) where {RC<:RunContext}
    # Keep the targeted runtime's cache and partial binding shell. In
    # particular, do not intern this owner into the post-barrier cohort store.
    execution_target = _compiled_execution_target(
        object_id, model, status_view, status_view.temporal_inputs,
        status_view.bound_inputs, output_targets, outputs, call_bindings,
        environment_binding, cache.default, cache,
    )
    return CallTarget(
        execution_target, context.compiled, environment_bindings, application,
        object_id, cache.default.calls, context.temporal_streams, context.output_retention,
        context.time, context.constants, context.publication_allowed, context.environment,
    )
end

function _current_topology_call_targets(
    cached_targets::CallTargets,
    context::RunContext,
    name::Symbol,
    requested_ids,
)
    model = runtime_model(context)
    targeted = _targeted_new_object_call_targets(
        context,
        name,
        requested_ids,
        cached_targets,
    )
    isnothing(targeted) || return targeted
    compiled = _refresh_runtime_bindings!(model, context.compiled)
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
    _compiled_call_mode(resolved_binding) === :manual ||
        _initializer_requires_dedicated_api(context, name)
    resolved_binding.multiplicity != :many && length(requested_ids) > 1 &&
        error(
            "Hard call `$(name)` from application `$(context.application.id)` ",
            "accepts at most one requested object.",
        )
    default_scope = _default_dependency_scope(model, context.object_id)
    unresolved_ids = ObjectId[]
    callee_application_ids = Symbol[]
    for object_id in requested_ids
        if !_selector_matches_object_id(
            model,
            resolved_binding.matcher,
            object_id;
            context=context.object_id,
            default_to_context=true,
            default_scope=default_scope,
        )
            push!(unresolved_ids, object_id)
            continue
        end
        matching_applications = _matching_callee_applications(
            compiled.applications_by_object,
            object_id,
            resolved_binding.process,
            resolved_binding.application,
        )
        if isempty(matching_applications)
            push!(unresolved_ids, object_id)
            continue
        end
        append!(callee_application_ids, matching_applications)
    end
    isempty(unresolved_ids) || error(
        "Hard call `$(name)` from application `$(context.application.id)` does not ",
        "resolve requested object(s) `$(Tuple(id.value for id in unresolved_ids))`."
    )
    unique!(callee_application_ids)
    selected_binding = CompiledModelCallBinding(
        resolved_binding.plan,
        resolved_binding.consumer_id,
        _application_target_ids(model, requested_ids),
        callee_application_ids,
    )
    if !isnothing(context.temporal_streams) &&
       context.output_retention isa OutputRetentionPlan &&
       !isempty(context.output_retention.retained_outputs_by_application)
        # This accessor can refresh topology inside a running controller,
        # before Simulation reaches its normal stream-initialization barrier.
        # Prepare the refreshed targets without publishing a sample, including
        # distributed destinations and other applications on newborn objects.
        if compiled !== context.compiled
            _initialize_model_output_streams!(
                context.temporal_streams,
                compiled,
                context.output_retention,
                0,
                compiled.changed_execution_target_ids,
            )
        end
        # A previous explicit call may already have consumed the structural
        # delta. Independently ensure the selected targets' streams exist;
        # this stays bounded by this call's selection on a clean topology.
        selected_target_keys = Tuple{Symbol,ObjectId}[]
        for application_id in callee_application_ids
            application = _compiled_application_by_id(compiled, application_id)
            for object_id in requested_ids
                _call_binding_target_matches(
                    selected_binding,
                    application,
                    object_id,
                ) || continue
                push!(selected_target_keys, (application_id, object_id))
            end
        end
        _initialize_model_output_streams!(
            context.temporal_streams,
            compiled,
            context.output_retention,
            0,
            selected_target_keys,
        )
    end
    # This synthetic binding is already the complete explicitly requested
    # selection. Mark only it observed so materialization never activates the
    # cached full `Many` binding or its lifecycle reverse index.
    _mark_compiled_call_membership_observed!(selected_binding)
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
        ;
        tracks_full_membership=false,
        batch_schema=cached_targets.batch_schema,
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
            "`ModelSpec(model; environment=Environment(...))`."
        )
    end
    return binding
end

function _validate_environment_commit(context::RunContext, state)
    declared = _model_environment_output_names(context.application)
    isempty(declared) && error(
        "Application `$(context.application.id)` cannot commit environment state because ",
        "its model declares no `environment_outputs_` variables.",
    )
    missing = Symbol[variable for variable in declared if !hasproperty(state, variable)]
    isempty(missing) || error(
        "Environment state committed by application `$(context.application.id)` is missing ",
        "declared `environment_outputs_` variable(s) `$(Tuple(missing))`.",
    )
    return nothing
end

"""
    commit_environment!(context::RunContext, state)

Commit an accepted environment `state` through the opaque handle compiled for
the currently running model application/object. The model must declare the
variables it commits with `environment_outputs_`.

Commits are ignored while the current model is executing as a non-publishing
hard call. Trial environment states should instead be passed to
`run_call!(context, name; environment=state)`.
"""
function commit_environment!(context::RunContext, state)
    context.publication_allowed || return nothing
    binding = _environment_binding_for_current_context(context)
    _validate_environment_commit(context, state)
    frame = _active_call_evaluation()
    if frame !== nothing
        push!(frame.events, CapturedEnvironmentCommit(
            binding.backend, binding.handle, deepcopy(state), context.time,
        ))
        return nothing
    end
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

# CallTargets store override metadata behind Any; changing the override does
# not change the concrete child-call tuple. Recover the context type without
# erasing the normal no-override execution path.
@inline _call_context_type(
    ::RunContext{CS,A,CT,BI,OT,TS,OR,C,OldE,I,EB}, ::E,
) where {CS,A,CT,BI,OT,TS,OR,C,OldE,I,EB,E} = RunContext{CS,A,CT,BI,OT,TS,OR,C,E,I,EB}
@inline _call_context_type(::Nothing, environment) = RunContext

# Metadata already proved current needs only invocation values synchronized.
# Keep this small boundary usable when a stale owner's new descendant tuple
# differs from its original default type, without reboxing all owner metadata.
@inline function _synchronize_current_call_context!(
    context::RunContext, time, publication_allowed::Bool, environment,
)
    context.time = float(time)
    context.publication_allowed = publication_allowed
    context.environment = environment
    return context
end

@inline function _call_context_bindings_match(calls::Tuple, bindings::Tuple)
    length(calls) == length(bindings) || return false
    isempty(calls) && return true
    first(calls).binding === first(bindings) || return false
    return _call_context_bindings_match(Base.tail(calls), Base.tail(bindings))
end

@inline function _call_context_matches(
    context::RunContext, compiled, environment_bindings, application, object_id,
    bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
    environment,
)
    return context.compiled === compiled &&
           context.environment_bindings === environment_bindings &&
           context.application === application && context.object_id == object_id &&
           context.bound_inputs === bound_inputs && context.output_targets === output_targets &&
           context.temporal_streams === temporal_streams &&
           context.output_retention === output_retention && context.constants === constants &&
           _call_context_bindings_match(context.calls, call_bindings) &&
           typeof(context.environment) === typeof(environment)
end
@inline _call_context_matches(::Nothing, args...) = false

@inline function _call_context_clone_is_current(
    context::RunContext, compiled, environment_bindings, application, object_id,
    bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
)
    # The context identity guard also protects an empty descendant template:
    # no per-child stamp exists to prove it still describes another generation.
    return _call_context_matches(
        context, compiled, environment_bindings, application, object_id,
        bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
        context.environment,
    ) && _call_context_preparation_is_current(
        context.calls, compiled, environment_bindings, temporal_streams,
        output_retention, constants,
    )
end

@inline function _prepare_cached_call_context!(
    cache::CallContextCache, reuse::Bool, compiled, environment_bindings,
    application, object_id, bound_inputs, output_targets, call_bindings::Tuple, temporal_streams,
    output_retention, time, constants, publication_allowed, environment,
)
    Context = _call_context_type(cache.default, environment)
    context = reuse ? cache.default : nothing
    if !(context isa Context && _call_context_matches(
        context, compiled, environment_bindings, application, object_id,
        bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
        environment,
    ) && _call_context_preparation_is_current(
        context.calls, compiled, environment_bindings, temporal_streams,
        output_retention, constants,
    ))
        context = reuse ? cache.transient : nothing
        if context isa RunContext && !(context isa Context) &&
           _call_context_matches(
               context, compiled, environment_bindings, application, object_id,
               bound_inputs, output_targets, call_bindings, temporal_streams, output_retention,
               constants, environment,
           ) && _call_context_clone_is_current(
               context, compiled, environment_bindings, application, object_id,
               bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
           )
            # A stale OptionalOne can have acquired a different descendant tuple
            # type. Reuse that current transient rather than forcing the old
            # default's Context type and rebuilding it on every invocation.
            return _synchronize_current_call_context!(
                context, time, publication_allowed, environment,
            )
        end
        if !(context isa Context && _call_context_matches(
            context, compiled, environment_bindings, application, object_id,
            bound_inputs, output_targets, call_bindings, temporal_streams, output_retention, constants,
            environment,
        ) && _call_context_preparation_is_current(
            context.calls, compiled, environment_bindings, temporal_streams,
            output_retention, constants,
        ))
            # A reentrant call needs its own descendants as well as its shell:
            # child CallTargets carry mutable time, environment and permission.
            context = _prepare_model_execution_context!(
                cache.default, compiled, environment_bindings, application, object_id,
                bound_inputs, output_targets, call_bindings, temporal_streams, output_retention,
                time, constants, publication_allowed, environment; fresh=true,
            )
            reuse && (cache.transient = context)
            return context
        end
    end
    return _prepare_model_execution_context!(
        context::Context, compiled, environment_bindings, application, object_id,
        bound_inputs, output_targets, call_bindings, temporal_streams, output_retention,
        time, constants, publication_allowed, environment,
    )
end

@inline function _record_call_execution!(cache)
    return _record_call_execution!(cache, _active_call_evaluation())
end

@inline function _record_call_execution!(cache, ::Nothing)
    cache.execution_stamp[] += UInt64(1)
    return nothing
end

@inline function _record_call_execution!(cache, frame::CallEvaluationFrame)
    stamp = cache.execution_stamp
    stamp[] += UInt64(1)
    ancestor = frame
    while ancestor !== nothing
        ancestor.executions[stamp] = stamp[]
        ancestor = ancestor.parent
    end
    return frame
end

@inline function _run_call_kernel!(model, status, environment, context, output_bindings)
    run!(model, status, environment, context.constants, context)
    if context.publication_allowed
        isempty(output_bindings) ||
            _model_publish_runtime_outputs!(output_bindings, context.time)
        _record_model_call_publication!(
            context.output_retention, context.application.id, context.time,
        )
    end
    return nothing
end

@inline function _run_evaluated_call_kernel!(
    model, status, environment, context, output_bindings, frame::CallEvaluationFrame,
)
    run!(model, status, environment, context.constants, context)
    if context.publication_allowed
        _publish_evaluated_call!(frame, output_bindings, context)
    end
    return nothing
end

@noinline function _run_owned_call_kernel!(
    owner::CompiledExecutionTarget,
    environment,
    context::RunContext,
    frame,
)
    # Sampling can erase the environment type on either hard-call path.
    # Cross that boundary with the mutable owner, then read its typed payload
    # here instead of boxing model/status/output tuples as dispatch arguments.
    if frame === nothing
        _run_call_kernel!(
            owner.model, owner.status_view.status, environment, context, owner.output_bindings,
        )
    else
        _run_evaluated_call_kernel!(
            owner.model, owner.status_view.status, environment, context, owner.output_bindings, frame,
        )
    end
    return nothing
end

@inline function _run_call!(
    target::CallTarget,
    publish::Bool,
    sampled_environment,
    environment,
)
    cache = target.context_cache
    frame = _record_call_execution!(cache)
    _materialize_model_inputs!(
        target.status,
        target.temporal_inputs,
        target.compiled,
        target.application,
        target.temporal_streams,
        target.time,
    )
    environment_value = sampled_environment isa UnspecifiedModelEnvironment ?
                        _model_environment_for_binding(
        target.environment_bindings,
        target.application,
        target.environment_binding,
        target.time,
        environment,
    ) : sampled_environment
    publication_allowed = publish && target.publication_allowed
    acquired = !cache.in_use
    acquired && (cache.in_use = true)
    try
        context = _prepare_cached_call_context!(
            cache, acquired, target.compiled, target.environment_bindings,
            target.application, target.object_id, target.bound_inputs,
            target.output_targets, target.execution_target.call_bindings, target.temporal_streams, target.output_retention,
            target.time, target.constants, publication_allowed, environment,
        )
        # The common context is concrete in this cache owner. Keep its sampled
        # row unboxed at the kernel call; stale/trial contexts retain the general
        # path when their descendant tuple or environment type differs.
        DefaultContext = typeof(cache.default)
        if context isa DefaultContext
            _run_owned_call_kernel!(
                target.execution_target, environment_value, context::DefaultContext, frame,
            )
        else
            _run_owned_call_kernel!(
                target.execution_target, environment_value, context, frame,
            )
        end
    finally
        acquired && (cache.in_use = false)
    end
    return nothing
end

"""
    run_call!(target::CallTarget; publish=false, environment, sampled_environment)

Run one manually selected model call. By default, the call mutates its target
status without publishing outputs or environment updates, which is suitable
for trial iterations. Pass `publish=true` once for the accepted state.

`environment=trial_state` samples this target through its own compiled provider
and handle, and supplies that backend state to its descendant calls. In
contrast, `sampled_environment=value` forwards an already sampled model-facing
value to this target only; descendants keep their inherited backend state.
These two overrides are mutually exclusive. With neither override, the target
uses its captured environment. An override does not change the target's
captured environment, timestamp or inherited publication permission.

The method returns the same `CallTarget`.

Publication permission is inherited through the call stack. A descendant
cannot publish outputs or environment writes while any ancestor is running as
a trial.

For fine-grained control, obtain a collection with [`call_targets`](@ref), then
select or iterate its targets:

```julia
targets = call_targets(context, :leaf_energy)
for (target, target_environment) in zip(targets, environments_by_leaf)
    run_call!(
        target;
        sampled_environment=target_environment,
        publish=false,
    )
end

accepted = accepted_environment(model, status)
commit_environment!(context, accepted)
for target in targets
    run_call!(target; publish=true)
end
```
"""
@inline function run_call!(
    target::CallTarget;
    publish::Bool=false,
    environment=_NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=_UNSPECIFIED_SCENE_ENVIRONMENT,
)
    if !(environment isa NoEnvironmentOverride) &&
       !(sampled_environment isa UnspecifiedModelEnvironment)
        throw(
            ArgumentError(
                "`environment` and `sampled_environment` are mutually exclusive hard-call overrides.",
            ),
        )
    end
    selected_environment = environment isa NoEnvironmentOverride ?
                           target.environment : environment
    _run_call!(
        target,
        publish,
        sampled_environment,
        selected_environment,
    )
    # Preserve the public view without returning it across the execution
    # boundary, where partially inferred immutable snapshots can be boxed.
    return target
end

@inline function _run_compiled_call_target!(
    targets::CallTargets,
    application::CompiledModelApplication,
    target::CompiledExecutionTarget,
    publish::Bool,
    sampled_environment,
    environment,
    frame,
)
    cache = target.call_context_cache
    _record_call_execution!(cache, frame)
    _materialize_model_inputs!(
        target.status_view.status,
        target.input_bindings,
        targets.compiled,
        application,
        targets.temporal_streams,
        targets.time,
    )
    environment_value = sampled_environment isa UnspecifiedModelEnvironment ?
                        _model_environment_for_binding(
        targets.environment_bindings,
        application,
        target.environment_binding,
        targets.time,
        environment,
    ) : sampled_environment
    publication_allowed = publish && targets.publication_allowed
    acquired = !cache.in_use
    acquired && (cache.in_use = true)
    try
        # The compiled bulk target already owns this typed default context.
        # Preserve its original preparation path, with the same lease as the
        # transient cache; materialized views still check captured metadata.
        context = if acquired && target.context isa RunContext &&
                     typeof(target.context.environment) === typeof(environment)
            _prepare_model_execution_context!(
                target.context, targets.compiled, targets.environment_bindings,
                application, target.object_id, target.bound_inputs, target.output_targets,
                target.call_bindings,
                targets.temporal_streams, targets.output_retention, targets.time,
                targets.constants, publication_allowed, environment,
            )
        else
            _prepare_cached_call_context!(
                cache, acquired, targets.compiled, targets.environment_bindings,
                application, target.object_id, target.bound_inputs, target.output_targets,
                target.call_bindings,
                targets.temporal_streams, targets.output_retention, targets.time,
                targets.constants, publication_allowed, environment,
            )
        end
        _run_owned_call_kernel!(target, environment_value, context, frame)
    finally
        acquired && (cache.in_use = false)
    end
    return nothing
end

@inline function _run_compiled_call_batch!(
    targets::CallTargets,
    batch::CompiledExecutionBatch,
    publish::Bool,
    sampled_environment,
    environment,
    frame,
)
    for target in batch.targets
        _run_compiled_call_target!(
            targets,
            batch.application,
            target,
            publish,
            sampled_environment,
            environment,
            frame,
        )
    end
    return nothing
end

@inline _run_compiled_call_batches!(
    targets::CallTargets,
    ::Tuple{},
    publish::Bool,
    sampled_environment,
    environment,
    frame,
) = nothing

@inline function _run_compiled_call_batches!(
    targets::CallTargets,
    batches::Tuple,
    publish::Bool,
    sampled_environment,
    environment,
    frame,
)
    _run_compiled_call_batch!(
        targets,
        first(batches),
        publish,
        sampled_environment,
        environment,
        frame,
    )
    _run_compiled_call_batches!(
        targets,
        Base.tail(batches),
        publish,
        sampled_environment,
        environment,
        frame,
    )
    return nothing
end

# Prepared Many keeps an ordered runtime vector. Both representations enter
# the same batch and target executor after their normal metadata admission.
@inline function _run_compiled_call_batches!(
    targets::CallTargets,
    batches::AbstractVector,
    publish::Bool,
    sampled_environment,
    environment,
    frame,
)
    for index in eachindex(batches)
        _with_call_execution_batch(targets, batches, index) do batch
            _run_compiled_call_batch!(
                targets, batch, publish, sampled_environment, environment, frame,
            )
        end
    end
    return nothing
end

function _run_call_targets!(
    targets::CallTargets,
    publish::Bool,
    sampled_environment,
    environment,
)
    # Read task-local evaluation state once for the complete homogeneous batch,
    # rather than repeating the lookup at every target and publication clock.
    frame = _active_call_evaluation()
    _run_compiled_call_batches!(
        targets,
        _materialize_call_execution_batches!(targets),
        publish,
        sampled_environment,
        environment,
        frame,
    )
    if publish && targets.publication_allowed
        # The declared call completed even when its Many selection was empty.
        # Per-target publications above still distinguish objects included in
        # the accepted call from objects created or removed around that call.
        for application_id in targets.binding.potential_callee_application_ids
            _record_evaluated_call_clock!(
                frame,
                targets.output_retention,
                application_id,
                targets.time,
            )
        end
    end
    return targets
end

function _run_call_targets!(
    targets,
    publish::Bool,
    sampled_environment,
    environment,
)
    for target in targets
        _with_call_target_entry(targets, target) do actual
            _run_call!(actual, publish, sampled_environment, environment)
        end
    end
    return targets
end

"""
    run_initializer!(context::RunContext, name::Symbol, object)

Run the application declared by `name=Initializer(...)` exactly once on one
object registered during the current lifecycle event. The target application
remains normally scheduled and retains canonical writer ownership. Its model
mutates the newborn's canonical local status, but the targeted initializer does
not publish an extra mid-step output sample or distributed/environment update.
Consequently, only direct non-temporal downstream consumers may observe its
newborn output in that step; downstream temporal consumers are rejected during
scenario compilation.

The initializer target must use the caller's cadence and global environment,
must not declare nested calls, distributed outputs, or stream-only outputs, and
must be the sole potential canonical writer of each initialized output. It may
use `PreviousTimeStep` as its only temporal input policy. The initialized
object's canonical [`Status`](@ref) is returned. Calling the same initializer
again for that application/object pair, or passing an existing or reparented
object, is an error. The application/object pair is reserved before model code
runs, so a failed attempt remains marked and cannot be retried in the same
lifecycle event after an unknown partial mutation.
"""
function run_initializer!(context::RunContext, name::Symbol, object)
    context.publication_allowed || error(
        "Initializer `$(name)` cannot run inside a non-publishing hard call. " *
        "Keep its creator application root-scheduled.",
    )
    requested_ids = _call_target_object_ids(runtime_model(context), object)
    return _with_named_call(_selected_run_initializer!, context.calls, name, context, requested_ids)
end

function _selected_run_initializer!(cached_targets, context::RunContext, name::Symbol, requested_ids)
    model = runtime_model(context)
    targets = _targeted_new_object_call_targets(
        context, name, requested_ids, _synchronized_named_call(cached_targets, context, name);
        initializer=true,
    )
    return _with_call_target_entry(targets, only(targets)) do target
        key = (target.application.id, target.object_id)
        # Reserve before model code; failure still poisons this lifecycle event.
        push!(lifecycle_delta(model).initialized_targets, key)
        _run_call!(target, false, _UNSPECIFIED_SCENE_ENVIRONMENT, context.environment)
        return model_status(model, target.object_id)
    end
end

function run_initializer!(context, name::Symbol, object)
    throw(
        ArgumentError(
            "Initializer `$(name)` requires the compiled RunContext passed to " *
            "a model kernel; got $(typeof(context)).",
        ),
    )
end

"""
    run_call!(context::RunContext, name::Symbol;
              environment, sampled_environment, publish=false)

Execute every target of the hard call declared as `name` and return its
[`CallTargets`](@ref) collection. The return shape is always vector-like:
`One` produces one element, `OptionalOne` zero or one, and `Many` zero or more.
Initializer bindings are rejected here; execute those with
[`run_initializer!`](@ref).

When `environment` is supplied, every target keeps its own opaque compiled
backend handle and samples that transient backend-specific state. The state is
inherited by nested hard calls. Omit it to sample the committed backend state.

When `sampled_environment` is supplied, that already sampled model-facing value
is forwarded directly to every target through the cached typed execution path.
It is not resampled and is not inherited as a backend state by nested calls.
`environment` and `sampled_environment` are mutually exclusive.

For finer-grained target selection, order, or direct per-target sampled environments,
use [`call_targets`](@ref) and [`run_call!(::CallTarget)`](@ref). Commit an
accepted mutable state with [`commit_environment!`](@ref) before publishing the
accepted descendants.
"""
function run_call!(
    context::RunContext,
    name::Symbol;
    environment=_NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=_UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false,
    objects=nothing,
)
    if !(environment isa NoEnvironmentOverride) &&
       !(sampled_environment isa UnspecifiedModelEnvironment)
        throw(
            ArgumentError(
                "`environment` and `sampled_environment` are mutually " *
                "exclusive hard-call overrides.",
            ),
        )
    end
    requested_ids = isnothing(objects) ? nothing :
        _call_target_object_ids(runtime_model(context), objects)
    return _with_named_call(_selected_run_call!, context.calls, name, context,
        requested_ids, publish, sampled_environment, environment)
end

@inline function _selected_run_call!(cached_targets, context::RunContext, name::Symbol,
    requested_ids, publish, sampled_environment, environment)
    targets = _selected_call_targets(cached_targets, context, name, requested_ids)
    selected_environment = environment isa NoEnvironmentOverride ?
                           context.environment : environment
    return _run_call_targets!(targets, publish, sampled_environment, selected_environment)
end

function run_call!(
    context,
    name::Symbol;
    environment=_NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=_UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false,
    objects=nothing,
)
    throw(
        ArgumentError(
            "Hard call `$(name)` requires the compiled RunContext passed to a model kernel; got $(typeof(context)).",
        ),
    )
end

function _model_output_selection(outputs)
    outputs === :all && return ((), true)
    outputs === :none && return ((), false)
    outputs isa Symbol && error(
        "Unsupported output selection `$(outputs)`. Use `:all`, `:none`, an `OutputRequest`, or a vector of requests.",
    )
    requests = _normalize_output_requests(outputs)
    isempty(requests) && return ((), false)
    return requests, false
end

function _runtime_performance_count_lifecycle_delta!(performance, delta)
    _runtime_performance_count!(performance, :lifecycle_barriers)
    _runtime_performance_count!(
        performance,
        :lifecycle_added_objects,
        length(delta.added),
    )
    _runtime_performance_count!(
        performance,
        :lifecycle_removed_objects,
        length(delta.removed),
    )
    _runtime_performance_count!(
        performance,
        :lifecycle_reparented_subtrees,
        length(delta.reparented),
    )
    _runtime_performance_count!(
        performance,
        :lifecycle_reparented_objects,
        sum(
            length(event.descendant_ids)
            for event in delta.reparented;
            init=0,
        ),
    )
    _runtime_performance_count!(
        performance,
        :lifecycle_moved_objects,
        length(delta.moved),
    )
    _runtime_performance_count!(
        performance,
        :lifecycle_environment_dirty_objects,
        delta.full_environment ? 0 : length(delta.environment_dirty_ids),
    )
    delta.full_environment && _runtime_performance_count!(
        performance,
        :lifecycle_full_environment_barriers,
    )
    return nothing
end

function _refresh_simulation_runtime!(simulation::Simulation)
    model = simulation.model
    unobserved_compiled_owner = simulation.compiled !== getfield(model, :binding_cache)
    if bindings_dirty(model) || unobserved_compiled_owner ||
       simulation.compiled.revision != model_revision(model)
        lifecycle = lifecycle_delta(model)
        _runtime_performance_count_lifecycle_delta!(
            simulation.performance,
            lifecycle,
        )
        dirty_object_count = lifecycle.structural_kind === :full ?
                             length(model.registry.objects) :
                             length(lifecycle.structural_dirty_ids)
        previous_status_views = isnothing(simulation.performance) ?
                                nothing :
                                copy(
            simulation.compiled.status_views_by_target,
        )
        previous_input_bindings = isnothing(simulation.performance) ?
                                  nothing :
                                  copy(
            simulation.compiled.input_bindings_by_target,
        )
        previous_call_bindings = isnothing(simulation.performance) ?
                                 nothing :
                                 copy(
            simulation.compiled.call_bindings_by_target,
        )
        previous_environment_bindings = isnothing(simulation.performance) ?
                                        nothing :
                                        copy(
            simulation.environment_bindings.by_target,
        )
        started_at = _runtime_performance_start(simulation.performance)
        simulation.compiled = _refresh_runtime_bindings!(
            model, simulation.compiled;
            performance=simulation.performance,
        )
        # A previously published owner can change membership beyond the
        # pending lifecycle delta, including at the same topology revision.
        # Ordinary observed growth retains incremental request checks.
        if unobserved_compiled_owner
            simulation.output_request_model_revision = -1
        end
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
        if !isnothing(simulation.performance)
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
            _runtime_performance_count!(
                simulation.performance,
                :input_binding_targets_replaced,
                _changed_compiled_binding_target_count(
                    previous_input_bindings,
                    simulation.compiled.input_bindings_by_target,
                ),
            )
            _runtime_performance_count!(
                simulation.performance,
                :input_binding_targets_removed,
                _removed_compiled_binding_target_count(
                    previous_input_bindings,
                    simulation.compiled.input_bindings_by_target,
                ),
            )
            _runtime_performance_count!(
                simulation.performance,
                :call_binding_targets_replaced,
                _changed_compiled_binding_target_count(
                    previous_call_bindings,
                    simulation.compiled.call_bindings_by_target,
                ),
            )
            _runtime_performance_count!(
                simulation.performance,
                :call_binding_targets_removed,
                _removed_compiled_binding_target_count(
                    previous_call_bindings,
                    simulation.compiled.call_bindings_by_target,
                ),
            )
        end
        pure_object_addition = !unobserved_compiled_owner &&
            simulation.compiled.status_view_refresh_is_pure_addition
        output_retention_reused = pure_object_addition &&
                                  _model_output_retention_covers_addition(
            simulation.output_retention,
            simulation.compiled,
        )
        if !output_retention_reused
            started_at = _runtime_performance_start(simulation.performance)
            refreshed_output_retention = compile_model_output_retention(
                simulation.compiled,
                simulation.output_requests;
                retain_all=simulation.output_retention.retain_all,
                accepted_call_times=simulation.output_retention.accepted_call_times,
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
            output_retention_reused = _same_model_output_retention(
                simulation.output_retention,
                refreshed_output_retention,
            )
            output_retention_reused ||
                (simulation.output_retention = refreshed_output_retention)
        end
        if output_retention_reused
            _runtime_performance_count!(
                simulation.performance,
                :output_retention_reuses,
            )
        end
        _initialize_model_output_streams!(
            simulation.temporal_streams,
            simulation.compiled,
            simulation.output_retention,
            0,
            output_retention_reused && !unobserved_compiled_owner ?
            simulation.compiled.changed_execution_target_ids : nothing,
        )
        started_at = _runtime_performance_start(simulation.performance)
        environment_owner = _current_environment_binding_owner(model, simulation.environment_bindings)
        environment_delta_covers_runtime = environment_owner === simulation.environment_bindings
        simulation.environment_bindings = _refresh_environment_bindings!(
            model,
            simulation.compiled,
            environment_owner;
            environment_schema=simulation.environment_bindings.environment_schema,
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
        if !isnothing(simulation.performance)
            _runtime_performance_count!(
                simulation.performance,
                :environment_bindings_replaced,
                _changed_environment_binding_count(
                    previous_environment_bindings,
                    simulation.environment_bindings.by_target,
                ),
            )
            _runtime_performance_count!(
                simulation.performance,
                :environment_bindings_removed,
                _removed_environment_binding_count(
                    previous_environment_bindings,
                    simulation.environment_bindings.by_target,
                ),
            )
        end
        changed_execution_application_ids = !unobserved_compiled_owner &&
                                            output_retention_reused && environment_delta_covers_runtime ?
                                            simulation.compiled.changed_execution_application_ids :
                                            nothing
        started_at = _runtime_performance_start(simulation.performance)
        execution_refresh = _refresh_model_execution_plan(
            simulation.execution_plan,
            simulation.compiled,
            simulation.environment_bindings,
            simulation.temporal_streams,
            simulation.output_retention,
            simulation.constants,
            simulation.performance,
            changed_execution_application_ids,
        )
        simulation.execution_plan = execution_refresh.plan
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_compile,
            started_at,
        )
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_and_model_bundle_compile,
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
           simulation.environment_bindings !== getfield(model, :environment_binding_cache) ||
           simulation.environment_bindings.environment_revision !=
           environment_revision(model)
        _runtime_performance_count_lifecycle_delta!(
            simulation.performance,
            lifecycle_delta(model),
        )
        environment_owner = _current_environment_binding_owner(model, simulation.environment_bindings)
        # A public refresh can consume the lifecycle delta before this
        # Simulation observes it. A later partial event only describes changes
        # since that newer cache, so it cannot bound this runtime's stale rows.
        environment_delta_covers_runtime = environment_owner === simulation.environment_bindings
        dirty_environment_object_ids =
            lifecycle_delta(model).full_environment || !environment_delta_covers_runtime ?
            nothing :
            copy(lifecycle_delta(model).environment_dirty_ids)
        changed_environment_target_ids = Set{Tuple{Symbol,ObjectId}}()
        changed_environment_application_ids = if isnothing(dirty_environment_object_ids)
            nothing
        else
            application_ids = Set{Symbol}()
            for dirty_object_id in dirty_environment_object_ids
                # The lifecycle set can contain heterogeneous IDs. Capture the
                # canonical index's identity schema inside this query instead
                # of an existential ObjectId in the application callback.
                let object_id = _index_object_id(
                    simulation.compiled.applications_by_object,
                    dirty_object_id,
                )
                    _foreach_object_application(simulation.compiled, object_id) do application
                        push!(application_ids, application.id)
                        push!(changed_environment_target_ids, (application.id, object_id))
                    end
                end
            end
            application_ids
        end
        previous_environment_bindings = isnothing(simulation.performance) ?
                                        nothing :
                                        copy(
            simulation.environment_bindings.by_target,
        )
        started_at = _runtime_performance_start(simulation.performance)
        simulation.environment_bindings = _refresh_environment_bindings!(
            model,
            simulation.compiled,
            environment_owner;
            environment_schema=simulation.environment_bindings.environment_schema,
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
        if !isnothing(simulation.performance)
            _runtime_performance_count!(
                simulation.performance,
                :environment_bindings_replaced,
                _changed_environment_binding_count(
                    previous_environment_bindings,
                    simulation.environment_bindings.by_target,
                ),
            )
            _runtime_performance_count!(
                simulation.performance,
                :environment_bindings_removed,
                _removed_environment_binding_count(
                    previous_environment_bindings,
                    simulation.environment_bindings.by_target,
                ),
            )
        end
        started_at = _runtime_performance_start(simulation.performance)
        execution_refresh = _refresh_model_execution_plan(
            simulation.execution_plan,
            simulation.compiled,
            simulation.environment_bindings,
            simulation.temporal_streams,
            simulation.output_retention,
            simulation.constants,
            simulation.performance,
            changed_environment_application_ids,
            changed_environment_target_ids,
        )
        simulation.execution_plan = execution_refresh.plan
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_compile,
            started_at,
        )
        _runtime_performance_finish!(
            simulation.performance,
            :execution_plan_and_model_bundle_compile,
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
    simulation.runtime_revision = model.runtime_revision
    return simulation
end

@inline function _simulation_runtime_dirty(
    simulation::Simulation,
    ::Nothing,
)
    return simulation.runtime_revision != simulation.model.runtime_revision
end

@inline function _simulation_runtime_dirty(
    simulation::Simulation,
    performance::RuntimePerformanceCounters,
)
    _runtime_performance_count!(performance, :runtime_dirty_checks)
    return simulation.runtime_revision != simulation.model.runtime_revision
end

function _mark_schedule_prefix_completed!(
    completed_applications::Set{Symbol},
    schedule_plan::CompiledApplicationSchedule,
    first_entry::Int,
    last_entry::Int,
)
    for entry_index in first_entry:last_entry
        push!(
            completed_applications,
            schedule_plan.entries[entry_index].application_id,
        )
    end
    return completed_applications
end

@inline function _run_model_execution_group!(
    group::CompiledApplicationExecutionGroup,
    simulation::Simulation,
    step::Integer,
    ::Nothing,
)
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
    end
    return nothing
end

@inline function _run_model_execution_group!(
    group::CompiledApplicationExecutionGroup,
    simulation::Simulation,
    step::Integer,
    performance::RuntimePerformanceCounters,
)
    _runtime_performance_count!(
        performance,
        :application_groups_considered,
    )
    for batch in group.batches
        _run_model_execution_batch!(
            batch,
            simulation.compiled,
            simulation.environment_bindings,
            step,
            simulation.constants,
            simulation.temporal_streams,
            simulation.output_retention,
            performance,
        )
        _runtime_performance_count!(
            performance,
            :execution_batches_visited,
        )
        _runtime_performance_count!(
            performance,
            :execution_targets_visited,
            length(batch.targets),
        )
    end
    _runtime_performance_count!(
        performance,
        :application_groups_visited,
    )
    return nothing
end

function _run_model_execution_step!(simulation::Simulation, step::Integer)
    simulation.compiled.execution_generation += UInt64(1)
    started_at = _runtime_performance_start(simulation.performance)
    empty!(simulation.environment_bindings.sample_cache)
    schedule_plan = simulation.compiled.scenario_plan.application_schedule
    due_entry_indices = _due_application_schedule_entries!(
        simulation.execution_plan.schedule,
        schedule_plan,
        Int(step),
    )
    _runtime_performance_count!(
        simulation.performance,
        :application_schedule_dispatches,
    )
    _runtime_performance_count!(
        simulation.performance,
        :application_schedule_entries_due,
        length(due_entry_indices),
    )
    _runtime_performance_count!(
        simulation.performance,
        :application_schedule_generic_checks,
        length(schedule_plan.generic_entry_indices),
    )
    completed_applications = nothing
    completed_schedule_entry = 0
    for entry_index in due_entry_indices
        schedule_entry = schedule_plan.entries[entry_index]
        _run_execution_slot!(simulation.execution_plan.groups_by_application_slot,
            schedule_entry.application_slot, simulation, step) || continue

        if simulation.execution_plan.topology isa FixedExecution
            _refresh_timeline!(simulation, simulation.execution_plan.topology)
            continue
        end

        if !isnothing(completed_applications)
            _mark_schedule_prefix_completed!(
                completed_applications,
                schedule_plan,
                completed_schedule_entry + 1,
                entry_index,
            )
            completed_schedule_entry = entry_index
        end
        _simulation_runtime_dirty(
            simulation,
            simulation.performance,
        ) || continue
        if isnothing(completed_applications)
            completed_applications = Set{Symbol}()
            _mark_schedule_prefix_completed!(
                completed_applications,
                schedule_plan,
                firstindex(schedule_plan.entries),
                entry_index,
            )
            completed_schedule_entry = entry_index
        end
        lifecycle = _pending_output_request_lifecycle_delta(simulation.model)
        _refresh_simulation_runtime!(simulation)
        _refresh_output_request_targets!(
            simulation,
            lifecycle,
            completed_applications,
        )
        empty!(simulation.environment_bindings.sample_cache)
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

function _pending_output_request_lifecycle_delta(model::CompositeModel)
    bindings_dirty(model) || return nothing
    return lifecycle_delta(model)
end

function _incremental_output_request_object_ids(delta)
    isnothing(delta) && return nothing
    delta.structural_kind == :addition || return nothing
    return ObjectId[snapshot.id for snapshot in delta.added]
end

function _continue_scene!(simulation::Simulation, steps::Integer)
    steps >= 0 || throw(ArgumentError("`steps` must be non-negative, got $(steps)."))
    if iszero(steps)
        _refresh_timeline!(simulation, simulation.execution_plan.topology)
        return simulation
    end
    final_step = Base.Checked.checked_add(simulation.current_step, Int(steps))
    start_step = Base.Checked.checked_add(simulation.current_step, 1)
    for step in start_step:final_step
        _refresh_timeline!(simulation, simulation.execution_plan.topology)
        _run_model_execution_step!(simulation, step)
        simulation.current_step = step
    end
    _refresh_timeline!(simulation, simulation.execution_plan.topology)
    return simulation
end

function _output_request_target(
    model,
    compiled,
    application,
    object_id,
    variable::Symbol,
    start_time,
)
    initial = _model_output_reference(
        compiled,
        application,
        object_id,
        variable,
    )[]
    return (
        scale=_model_object(model, object_id).scale,
        memberships=[
            OutputRequestMembership(
                float(start_time),
                nothing,
                deepcopy(initial),
            ),
        ],
    )
end

_output_request_target_is_active(target) =
    !isempty(target.memberships) &&
    isnothing(last(target.memberships).end_time)

function _output_request_published_at(simulation, application_id, object_id, variable, time)
    samples = get(simulation.temporal_streams, (application_id, object_id, variable), nothing)
    return !isnothing(samples) && !isempty(samples) && first(last(samples)) == time
end

function _initial_output_request_targets(
    model,
    compiled,
    output_requests,
    output_request_matchers,
)
    targets = Dict{Symbol,Tuple{Symbol,Dict{ObjectId,Any}}}()
    for request in output_requests
        application = _model_request_application(model, compiled, request)
        object_ids = _resolve_object_ids(
            model,
            request.selector,
            output_request_matchers[request.name];
            context=request.context,
        )
        owned_ids = Set(
            _model_output_object_ids(
                compiled,
                application,
                request.var,
            ),
        )
        filter!(id -> id in owned_ids, object_ids)
        targets[request.name] = (
            application.id,
            Dict(
                id => _output_request_target(
                    model,
                    compiled,
                    application,
                    id,
                    request.var,
                    0.0,
                )
                for id in object_ids
            ),
        )
    end
    return targets
end

function _refresh_output_request_targets!(
    simulation::Simulation,
    lifecycle=nothing,
    completed_applications=nothing,
)
    current_revision = model_revision(simulation.model)
    simulation.output_request_model_revision == current_revision &&
        return simulation
    if isempty(simulation.output_requests)
        simulation.output_request_model_revision = current_revision
        return simulation
    end
    started_at = _runtime_performance_start(simulation.performance)
    _runtime_performance_count!(
        simulation.performance,
        :output_request_target_refreshes,
    )
    added_object_ids = simulation.output_request_model_revision == -1 ?
                       nothing : _incremental_output_request_object_ids(lifecycle)
    for request in simulation.output_requests
        matcher = simulation.output_request_matchers[request.name]
        application_id, object_targets =
            simulation.output_request_targets[request.name]
        matched_ids = if isnothing(added_object_ids)
            _runtime_performance_count!(
                simulation.performance,
                :output_request_selector_resolutions,
            )
            _resolve_object_ids(
                simulation.model,
                _selector_as_many(request.selector),
                matcher;
                context=request.context,
            )
        else
            _runtime_performance_count!(
                simulation.performance,
                :output_request_incremental_object_checks,
                length(added_object_ids),
            )
            ObjectId[
                object_id for object_id in added_object_ids
                if _selector_matches_object_id(
                    simulation.model,
                    matcher,
                    object_id;
                    context=request.context,
                )
            ]
        end
        application = _compiled_application_by_id(
            simulation.compiled,
            application_id,
        )
        owned_ids = Set(
            _model_output_object_ids(
                simulation.compiled,
                application,
                request.var,
            ),
        )
        filter!(id -> id in owned_ids, matched_ids)
        active_ids = Set(
            object_id for (object_id, target) in object_targets
            if _output_request_target_is_active(target)
        )
        matched_id_set = Set(matched_ids)
        current_ids = isnothing(added_object_ids) ?
                      matched_id_set :
                      union(active_ids, matched_id_set)
        if request.selector isa Union{One,OptionalOne} && length(current_ids) > 1
            error(
                "Output request `$(request.name)` expected at most one current object for selector ",
                "`$(request.selector)`, got $([id.value for id in current_ids]).",
            )
        end
        publication_time = float(simulation.current_step + 1)
        manual_application = application_id in simulation.compiled.scenario_plan.manual_application_ids
        application_completed =
            (!isnothing(completed_applications) && application_id in completed_applications) ||
            get(simulation.output_retention.accepted_call_times, application_id, -Inf) == publication_time
        membership_end_time = application_completed ?
                              float(simulation.current_step + 1) :
                              float(simulation.current_step)
        if isnothing(added_object_ids)
            for object_id in setdiff(active_ids, matched_id_set)
                # A manual call may publish before removing an object, or may
                # run only after removal. Preserve the last accepted sample in
                # the former case without inventing a held sample in the latter.
                target_end_time = manual_application ?
                    (_output_request_published_at(simulation, application_id, object_id,
                        request.var, publication_time) ? publication_time :
                        float(simulation.current_step)) : membership_end_time
                last(object_targets[object_id].memberships).end_time =
                    target_end_time
            end
        end
        start_time = application_completed ?
                     float(simulation.current_step + 2) :
                     float(simulation.current_step + 1)
        for object_id in matched_ids
            # Same-step accepted newborn publications take precedence over an
            # already completed call. Newborns created after an accepted empty
            # call instead join the following publication interval.
            target_start_time = manual_application &&
                _output_request_published_at(simulation, application_id, object_id,
                    request.var, publication_time) ? publication_time : start_time
            if haskey(object_targets, object_id)
                target = object_targets[object_id]
                _output_request_target_is_active(target) && continue
                initial = _model_output_reference(
                    simulation.compiled,
                    application,
                    object_id,
                    request.var,
                )[]
                push!(
                    target.memberships,
                    OutputRequestMembership(
                        target_start_time,
                        nothing,
                        deepcopy(initial),
                    ),
                )
                continue
            end
            object_targets[object_id] = _output_request_target(
                simulation.model,
                simulation.compiled,
                application,
                object_id,
                request.var,
                target_start_time,
            )
        end
    end
    _runtime_performance_finish!(
        simulation.performance,
        :output_request_target_refresh,
        started_at,
    )
    simulation.output_request_model_revision = current_revision
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
    outputs=:none,
    performance::Bool=false,
)
    simulation = _prepare_simulation!(model; steps, constants, outputs, performance)
    return _continue_scene!(simulation, steps)
end

function _prepare_simulation!(
    model::CompositeModel;
    steps::Integer,
    constants,
    outputs,
    performance::Bool=false,
    environment_schema=_environment_schema(getfield(model, :environment_binding_cache)),
)
    performance_counters = performance ? RuntimePerformanceCounters() : nothing
    initial_composite_started_at =
        _runtime_performance_start(performance_counters)
    started_at = initial_composite_started_at
    # An existing simulation may have refreshed its environment while retaining
    # its schedule. Compare the current base step even after that refresh.
    preparation = _scenario_preparation(model)
    _validate_authored_scenario(preparation)
    prepared = preparation.resolved
    compiled = model.binding_cache
    if !isnothing(prepared) || !isnothing(compiled)
        previous = isnothing(prepared) ? compiled.scenario_plan : prepared.plan
        backend = environment_backend(model.environment)
        timeline = _timeline_context(backend)
        cadence_changed = previous.timeline.base_step_seconds != timeline.base_step_seconds
        if cadence_changed || (model.environment_bindings_dirty && model.lifecycle_delta.full_environment)
            _validate_environment_duration(backend)
        end
        if cadence_changed
            _prepare_scenario_plan(model, timeline; force=true, performance=performance_counters)
        end
    end
    compiled = refresh_bindings!(
        model;
        performance=performance_counters,
    )
    compiled.execution_generation += UInt64(1)
    _runtime_performance_finish!(
        performance_counters,
        :initial_binding_compile,
        started_at,
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_application_plans_compiled,
        length(compiled.scenario_plan.applications),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_application_schedule_entries_compiled,
        length(compiled.scenario_plan.application_schedule.entries),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_input_plans_compiled,
        length(compiled.scenario_plan.input_plans),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_call_plans_compiled,
        length(compiled.scenario_plan.call_plans),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_status_views_constructed,
        length(compiled.status_views_by_target),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_input_bindings_constructed,
        length(compiled.input_bindings),
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_call_bindings_constructed,
        length(compiled.call_bindings),
    )
    started_at = _runtime_performance_start(performance_counters)
    cached_environment = getfield(model, :environment_binding_cache)::Union{Nothing,CompiledEnvironmentBindings}
    env_bindings = _refresh_environment_bindings!(model, compiled, cached_environment; environment_schema)
    _runtime_performance_finish!(
        performance_counters,
        :initial_environment_compile,
        started_at,
    )
    _runtime_performance_count!(
        performance_counters,
        :initial_environment_bindings_constructed,
        length(env_bindings.bindings),
    )
    empty!(env_bindings.sample_cache)
    output_requests, retain_all = _model_output_selection(outputs)
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
    temporal_streams = RuntimeStorage(Dict{Tuple{Symbol,ObjectId,Symbol},Any}(), model.registry.objects)
    _initialize_model_output_streams!(
        temporal_streams,
        compiled,
        output_retention,
        steps,
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
    _runtime_performance_finish!(
        performance_counters,
        :initial_execution_plan_and_model_bundle_compile,
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
    output_request_matchers = Dict(
        request.name => _compile_selector_matcher(model, request.selector)
        for request in output_requests
    )
    output_request_targets = _initial_output_request_targets(
        model,
        compiled,
        output_requests,
        output_request_matchers,
    )
    _runtime_performance_finish!(
        performance_counters,
        :initial_output_target_compile,
        started_at,
    )
    _runtime_performance_finish!(
        performance_counters,
        :initial_composite_compile,
        initial_composite_started_at,
    )
    return Simulation(
        model,
        compiled,
        env_bindings,
        execution_plan,
        output_retention,
        temporal_streams,
        _model_output_datetimes(environment_backend(model.environment), env_bindings),
        output_requests,
        output_request_matchers,
        output_request_targets,
        model_revision(model),
        model.runtime_revision,
        0,
        constants,
        performance_counters,
    )
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

# Keep the calendar labels with the simulation, independently of later edits to
# the weather table. Model clocks and output requests share these base-step dates.
function _model_output_datetimes(backend, environment_bindings)
    backend isa GlobalConstant || return missing
    source = environment_source(backend)
    isnothing(source) && return missing
    # DataFrame forcing may already be prepared in a cached environment plan.
    # Use those same rows so the labels agree with the weather kernels receive.
    for plan in environment_bindings.application_plans
        plan.backend isa GlobalConstant || continue
        environment_source(plan.backend) === source || continue
        plan.prepared_source isa PreparedGlobalEnvironmentRows || continue
        return Union{Missing,Dates.DateTime}[
            _model_output_row_datetime(row) for row in plan.prepared_source.rows
        ]
    end
    if source isa TimeStepTable || DataFormat(source) == TableAlike()
        return Union{Missing,Dates.DateTime}[
            _model_output_row_datetime(row) for row in Tables.rows(source)
        ]
    end
    return _model_output_row_datetime(source)
end

function _model_output_row_datetime(row)
    hasproperty(row, :date) || return missing
    date = getproperty(row, :date)
    date isa Dates.DateTime && return date
    date isa Dates.Date && return Dates.DateTime(date)
    return missing
end

_model_output_datetime(date::Union{Missing,Dates.DateTime}, time) = date

function _model_output_datetime(dates::AbstractVector, time)
    # Samples use the global base-step index, not the producer's execution count.
    step = Int(time)
    return checkbounds(Bool, dates, step) ? dates[step] : missing
end

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
                    datetime=_model_output_datetime(sim.output_datetimes, time),
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
        isnothing(request.application) ||
            application.id == request.application ||
            application.name == request.application ||
            continue
        local_output = request.var in _model_output_names(application)
        local_match = local_output && (
            any(id -> id in requested_ids, application.target_ids) ||
            (!isnothing(declared_scale) &&
             _model_application_matches_scale(model, application, declared_scale))
        )
        distributed_match = _model_request_matches_distributed_output(
            compiled,
            application,
            request,
            requested_ids,
        )
        (local_match || distributed_match) || continue
        if isnothing(request.application) &&
           !distributed_match &&
           _publish_mode_for_output(application.spec, request.var) == :stream_only
            continue
        end
        push!(candidates, application)
    end
    if isempty(candidates)
        error(
            "No model output publisher found for selector `$(request.selector)` and variable `$(request.var)`",
            isnothing(request.application) ?
            "." :
            " from application `$(request.application)`.",
        )
    elseif length(candidates) > 1
        if isnothing(request.application)
            manual_application_ids = _manual_call_application_ids(compiled)
            root_candidates = filter(
                application -> !(application.id in manual_application_ids),
                candidates,
            )
            length(root_candidates) == 1 && return only(root_candidates)
        end
        error(
            "Ambiguous model output publishers for selector `$(request.selector)` and variable `$(request.var)`: ",
            join((application.id for application in candidates), ", "),
            ". Provide `application=` or make one publisher canonical.",
        )
    end
    return only(candidates)
end

_model_request_matches_distributed_output(
    compiled,
    application,
    request,
    requested_ids,
    ::NoCompiledDistributedOutputs,
) = false

function _model_request_matches_distributed_output(
    compiled,
    application,
    request,
    requested_ids,
    distributed_outputs::CompiledDistributedOutputs,
)
    destination_ids = get(
        distributed_outputs.destination_ids_by_application_variable,
        (application.id, request.var),
        (),
    )
    concrete_match = any(id -> id in requested_ids, destination_ids)
    isempty(requested_ids) || return concrete_match
    plans = compiled.scenario_plan.distributed_output_plans
    plans isa CompiledDistributedOutputPlans || return false
    return any(
        plan -> request.var in plan.variable_names &&
                _selector_labels_may_overlap(request.selector, plan.selector),
        _application_plans(plans.by_application, application.id),
    )
end

_model_request_matches_distributed_output(
    compiled,
    application,
    request,
    requested_ids,
) = _model_request_matches_distributed_output(
    compiled,
    application,
    request,
    requested_ids,
    compiled.distributed_outputs,
)

function _model_request_application(sim::Simulation, request)
    return _model_request_application(sim.model, sim.compiled, request)
end

function _selector_declared_scale(selector::AbstractObjectMultiplicity)
    selector_criteria = criteria(selector)
    return _criteria_get(selector_criteria, :scale, nothing)
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
            membership=membership,
            samples=vcat(
                [(membership.start_time, membership.initial)],
                [
                    sample for sample in get(
                        sim.temporal_streams,
                        (application.id, object_id, request.var),
                        Tuple{Float64,typeof(membership.initial)}[],
                    ) if membership.start_time <= first(sample) &&
                    (
                        isnothing(membership.end_time) ||
                        first(sample) <= membership.end_time
                    )
                ],
            ),
        )
        for (object_id, target) in requested_objects
        for membership in target.memberships
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
        for row in sort!(
            nonempty_source_rows;
            by=row -> (
                string(row.object_id.value),
                row.membership.start_time,
            ),
        )
            membership_end = isnothing(row.membership.end_time) ?
                             float(sim.current_step) :
                             row.membership.end_time
            row.membership.start_time <= float(time) <= membership_end ||
                continue
            last_sample_time = request.policy isa HoldLast ?
                               membership_end :
                               last(row.samples)[1]
            float(time) <= last_sample_time || continue
            push!(
                rows,
                (
                    timestep=time,
                    datetime=_model_output_datetime(sim.output_datetimes, time),
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
                        max(t_start, row.membership.start_time),
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

"""
    collect_outputs(simulation; sink=DataFrames.DataFrame)
    collect_outputs(simulation, name::Symbol; sink=DataFrames.DataFrame)
    collect_outputs(simulation, object_id, variable::Symbol; sink=DataFrames.DataFrame)

Materialize retained output streams, a named [`OutputRequest`](@ref), or one
object's variable. With output requests, the first form returns a dictionary
keyed by request name. Pass `sink=nothing` for rows of named tuples.

Each row includes `timestep`, `datetime`, `application_id`, `object_id`,
`variable`, and `value`. Requested outputs also include `scale` and `process`.
`timestep` is the integer global simulation base-step index. `datetime` is the
`date` of the corresponding meteorology row, saved when [`run!`](@ref) starts. This
mapping follows actual publication steps for models with different cadences,
and the requested sampling step for resampled outputs, including held values.
It does not describe an aggregation window's start or end.

Meteorology `Date` values become midnight `DateTime` values. Undated rows,
unsupported date types, steps without a corresponding row, and custom
environment backends return `missing`. A singleton environment repeats its
supplied date, just as it repeats its forcing; dates are not extrapolated.
"""
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
