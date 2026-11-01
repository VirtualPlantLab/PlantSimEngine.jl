# Included inside ReusableProgram after full_program_plan.jl. Histories belong to
# one simulation and one application/output column, never to the reusable plan.
struct FullSample{T}
    application::Symbol
    object_id::Int
    step::Int
    value::T
end

struct ColumnHistory{T}
    initial::Dict{Int,T}
    last::Dict{Int,FullSample{T}}
    prior::Dict{Int,FullSample{T}}
    retained::Vector{FullSample{T}}
    retained_index::Dict{Tuple{Int,Int},Int}
end
ColumnHistory(::Type{T}) where {T} = ColumnHistory{T}(
    Dict{Int,T}(), Dict{Int,FullSample{T}}(), Dict{Int,FullSample{T}}(),
    FullSample{T}[], Dict{Tuple{Int,Int},Int}(),
)

# Reference-backed array ports publish ordinary owned arrays, matching PSE's
# value streams. Copy nested payloads as well so later Updates or broadcast
# through a live carrier cannot retroactively alter an earlier sample.
_full_history_snapshot(value::AbstractArray) = deepcopy(collect(value))
_full_history_snapshot(value) = deepcopy(value)
function _full_history_snapshot(::Type{T}, value) where {T}
    snapshot = _full_history_snapshot(value)
    return (snapshot isa T ? snapshot : convert(T, snapshot))::T
end
_full_history_id(id::Int) = id
_full_history_id(id::ObjectId{Int}) = id.value

function _make_full_streams(recipe, model)
    declarations=PSE.outputs_(model)::recipe.outputs_type
    return map(declarations) do declaration
        value = _full_value(declaration)
        value isa PSE.Required && throw(ArgumentError("full output history needs an initial value"))
        ColumnHistory(typeof(_full_history_snapshot(value)))
    end
end

"""Capture an object's actual birth value before any producer kernel mutates it.
Call at registration/binding, including each distributed destination. The first
value wins; repeated binding refreshes cannot replace birth history.
"""
function _full_history_initial!(history::ColumnHistory{T}, object_id, fallback) where {T}
    id = _full_history_id(object_id)
    if !haskey(history.initial, id)
        history.initial[id] = _full_history_snapshot(T, fallback)
    end
    return nothing
end

"""Return an owned value from strictly before this base step.
The caller passes the canonical birth value as fallback and should seed it at
registration via _full_history_initial!, before the first scientific write.
"""
function _full_previous(
    state, ::Val{SLOT}, ::Val{VAR}, object_id, step::Int, fallback,
) where {SLOT,VAR}
    history = getproperty(state.applications[SLOT].streams, VAR)
    return _full_previous(history, object_id, step, fallback)
end

function _full_previous(history::ColumnHistory{T}, object_id, step::Int, fallback) where {T}
    id = _full_history_id(object_id)
    _full_history_initial!(history, id, fallback)
    if haskey(history.last, id)
        sample = history.last[id]
        if sample.step < step
            return _full_history_snapshot(T, sample.value)
        elseif sample.step == step
            if haskey(history.prior, id)
                previous = history.prior[id]
                previous.step < step || throw(ArgumentError("invalid previous output sample order"))
                return _full_history_snapshot(T, previous.value)
            end
        else
            throw(ArgumentError("cannot read previous output through an obsolete step context"))
        end
    end
    # PSE's fallback belongs to the consumer binding. A consumer created after
    # a same-step producer has run may have a different initial value from the
    # source's birth value, while still having no preceding output sample.
    return _full_history_snapshot(T, fallback)
end

function _full_record!(history::ColumnHistory{T}, application::Symbol,
                       object_id, step::Int, value, retain::Bool) where {T}
    id = _full_history_id(object_id)
    sample = FullSample{T}(application, id, step, _full_history_snapshot(T, value))
    if haskey(history.last, id)
        last = history.last[id]
        step >= last.step || throw(ArgumentError("cannot publish an obsolete output step"))
        if step > last.step
            history.prior[id] = last
        end
    end
    history.last[id] = sample
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
    application = context.application
    id = application.cohort.ids[context.row]
    _full_record!(history, application.recipe.name, id, context.step,
        context.status[VAR], context.state.retain)
    return nothing
end

function _full_publish_column!(route::FullOutputRoute{COHORTS,VAR,true}, history, context) where {COHORTS,VAR}
    application = context.application
    origin = application.cohort.nodes[context.row]
    ids, column = _full_output_column(route, context.state, origin)
    length(ids) == length(column) || throw(ArgumentError("unaligned distributed output history column"))
    for (id, value) in zip(ids, column)
        _full_record!(history, application.recipe.name, id, context.step,
            value, context.state.retain)
    end
    return nothing
end

"""Publish this original kernel's outputs immediately, before a later Updates writer.
Retention controls only the materialized event rows; last/prior temporal samples
are updated even when the simulation retains no user-facing output streams.
"""
function _full_publish!(context)
    context.suppress && return nothing
    _full_publish_columns!(values(context.application.recipe.outputs),
        values(context.application.streams), context)
    return nothing
end
