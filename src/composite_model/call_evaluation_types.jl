abstract type AbstractCallPublicationEvent end

struct CapturedCallOutput{O,S,V} <: AbstractCallPublicationEvent
    output::O
    stream::S
    value::V
    time::Float64
end

struct CapturedCallClock{P} <: AbstractCallPublicationEvent
    plan::P
    application::Symbol
    time::Float64
end

struct CapturedEnvironmentCommit{B,H,S} <: AbstractCallPublicationEvent
    backend::B
    handle::H
    state::S
    time::Float64
end

mutable struct CallEvaluationFrame
    events::Vector{AbstractCallPublicationEvent}
    executions::Dict{Any,UInt64}
    generation::UInt64
    pending::Bool
    in_use::Bool
    task::Task
    compiled::Any
    model_revision::Int
    runtime_revision::Int
    environment_revision::Int
    lifecycle_delta::Any
    lifecycle_generation::UInt64
    binding_flags::Tuple{Bool,Bool}
    execution_generation::UInt64
    time::Float64
    parent::Union{Nothing,CallEvaluationFrame}
    parent_generation::UInt64
    publication_allowed::Bool
end

CallEvaluationFrame() = CallEvaluationFrame(
    # Cache keys are mutable objects with identity equality. Dict keeps its
    # storage when emptied and stores revision values without boxing.
    AbstractCallPublicationEvent[], Dict{Any,UInt64}(), UInt64(0), false,
    false, current_task(), nothing, 0, 0, 0, nothing, UInt64(0), (false, false), UInt64(0),
    0.0, nothing, UInt64(0), false,
)

"""
    CallEvaluation

Opaque, single-use result of [`evaluate_call!`](@ref). Inspect its targets with
[`call_targets`](@ref) and accept its captured publications with
[`accept_call!`](@ref). The token does not own a rollback copy of model status.
"""
struct CallEvaluation{T}
    frame::CallEvaluationFrame
    generation::UInt64
    targets::T
end

const _CALL_EVALUATION_TLS_KEY = :PlantSimEngine_call_evaluation

@inline function _active_call_evaluation()
    storage = current_task().storage
    return (storage === nothing ? nothing :
        get(storage::IdDict{Any,Any}, _CALL_EVALUATION_TLS_KEY, nothing))::Union{Nothing,CallEvaluationFrame}
end
