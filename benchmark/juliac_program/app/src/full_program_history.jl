# Included inside ReusableProgram after full_program_plan.jl. Histories belong to
# one simulation and one application/output column, never to the reusable plan.
struct FullSample{T}
    application::Symbol
    object_id::Int
    step::Int
    value::T
end

struct ColumnHistory{T}
    last::Dict{Int,FullSample{T}}
    prior::Dict{Int,FullSample{T}}
    retained::Vector{FullSample{T}}
    retained_index::Dict{Tuple{Int,Int},Int}
    temporal::Bool
end
ColumnHistory(::Type{T},temporal::Bool) where {T} = ColumnHistory{T}(
    Dict{Int,FullSample{T}}(), Dict{Int,FullSample{T}}(),
    FullSample{T}[], Dict{Tuple{Int,Int},Int}(), temporal,
)

# Reference-backed array ports publish ordinary owned arrays, matching PSE's
# value streams. Copy nested payloads as well so later Updates or broadcast
# through a live carrier cannot retroactively alter an earlier sample.
_full_history_snapshot(value) = _payload_copy(value)
function _full_history_snapshot(::Type{T}, value) where {T}
    snapshot = _full_history_snapshot(value)
    return (snapshot isa T ? snapshot : convert(T, snapshot))::T
end
_full_history_id(id::Int) = id
_full_history_id(id::ObjectId{Int}) = id.value

function _make_full_streams(recipe, model)
    declarations=PSE.outputs_(model)::recipe.outputs_type
    return _schema_pairs(declarations) do var,declaration
        value = _full_value(declaration)
        value isa PSE.Required && throw(ArgumentError("full output history needs an initial value"))
        ColumnHistory(typeof(_full_history_snapshot(value)),var in recipe.temporal_outputs)
    end
end

"""Return an owned value from before this base step.

The binding captures its fallback when a source first joins it. Look up that
fallback only if the producer has no preceding sample for this object.
"""
function _full_previous(
    state, ::Val{SLOT}, ::Val{VAR}, object_id::Int, step::Int, initial,
) where {SLOT,VAR}
    history = getproperty(state.applications[SLOT].streams, VAR)
    return _full_previous(history, object_id, step, initial)
end

function _full_previous(history::ColumnHistory{T}, id::Int, step::Int, initial) where {T}
    history.temporal || throw(ArgumentError("output column has no planned temporal consumer"))
    sample = get(history.last, id, nothing)
    if !isnothing(sample)
        if sample.step < step
            return _full_history_snapshot(T, sample.value)
        elseif sample.step == step
            previous = get(history.prior, id, nothing)
            if !isnothing(previous)
                previous.step < step || throw(ArgumentError("invalid previous output sample order"))
                return _full_history_snapshot(T, previous.value)
            end
        else
            throw(ArgumentError("cannot read previous output through an obsolete step context"))
        end
    end
    # A consumer created after a same-step producer ran can observe a
    # different fallback from the one another consumer captured earlier.
    return _full_history_snapshot(T, initial[id])
end

function _full_record!(history::ColumnHistory{T}, application::Symbol,
                       object_id, step::Int, value, retain::Bool) where {T}
    (history.temporal || retain) || return nothing
    id = _full_history_id(object_id)
    sample = FullSample{T}(application, id, step, _full_history_snapshot(T, value))
    if history.temporal
        last = get(history.last, id, nothing)
        if !isnothing(last)
            step >= last.step || throw(ArgumentError("cannot publish an obsolete output step"))
            if step > last.step
                history.prior[id] = last
            end
        end
        history.last[id] = sample
    end
    if retain
        key = (id, step)
        if haskey(history.retained_index, key)
            history.retained[history.retained_index[key]] = sample
        else
            push!(history.retained, sample)
            history.retained_index[key] = length(history.retained)
        end
    end
    return nothing
end

_full_publish_columns!(::Tuple{}, ::Tuple{}, context) = nothing
function _full_publish_columns!(routes::Tuple, histories::Tuple, context)
    _full_publish_column!(first(routes), first(histories), context)
    _full_publish_columns!(_schema_tail(routes), _schema_tail(histories), context)
    return nothing
end

function _full_publish_column!(::FullOutputRoute{COHORTS,VAR,false}, history, context) where {COHORTS,VAR}
    (history.temporal || context.state.retain) || return nothing
    application = context.application
    id = application.cohort.ids[context.row]
    _full_record!(history, application.recipe.name, id, context.step,
        context.status[VAR], context.state.retain)
    return nothing
end

function _full_publish_column!(route::FullOutputRoute{COHORTS,VAR,true}, history, context) where {COHORTS,VAR}
    (history.temporal || context.state.retain) || return nothing
    application = context.application
    origin = application.cohort.nodes[context.row]
    cache = getfield(application.output_columns[context.row], VAR)
    ids, column = _full_cached_output_column!(cache, route, context.state, origin)
    length(ids) == length(column) || throw(ArgumentError("unaligned distributed output history column"))
    for (id, value) in zip(ids, column)
        _full_record!(history, application.recipe.name, id, context.step,
            value, context.state.retain)
    end
    return nothing
end

"""Publish this original kernel's outputs immediately, before a later Updates writer.
Retention controls the materialized event rows. Last/prior samples are updated
only for columns consumed by PreviousTimeStep, including when retention is off.
"""
function _full_publish!(context)
    context.suppress && return nothing
    (!context.state.retain && isempty(context.application.recipe.temporal_outputs)) && return nothing
    _full_publish_columns!(values(context.application.recipe.outputs),
        values(context.application.streams), context)
    return nothing
end
