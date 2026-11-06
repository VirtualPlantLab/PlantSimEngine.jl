abstract type AbstractExecutionCohort end

mutable struct ExecutionCohort{T,I<:ObjectId} <: AbstractExecutionCohort
    owner::Any
    application_id::Symbol
    rows::Vector{Union{Nothing,T}}
    indices::Dict{I,Int}

    ExecutionCohort{T,I}(owner, application_id::Symbol, rows::Vector{Union{Nothing,T}},
        indices::Dict{I,Int}) where {T,I<:ObjectId} =
        new{T,I}(owner, application_id, rows, indices)
end

struct ExecutionCohortLocation
    cohort::AbstractExecutionCohort
    row::Int
end

"""Persistent typed execution payloads, indexed independently of schedule order."""
mutable struct ExecutionCohortStore
    cohorts::Dict{Tuple{Any,Symbol,DataType},AbstractExecutionCohort}
    locations::Dict{Tuple{Any,Symbol,ObjectId},ExecutionCohortLocation}
end

ExecutionCohortStore() = ExecutionCohortStore(
    Dict{Tuple{Any,Symbol,DataType},AbstractExecutionCohort}(),
    Dict{Tuple{Any,Symbol,ObjectId},ExecutionCohortLocation}(),
)

"""An ordered membership view over one application's concrete payload family."""
struct ExecutionCohortRows{T,C<:ExecutionCohort{T}} <: AbstractVector{T}
    store::ExecutionCohortStore
    cohort::C
    indices::Vector{Int}
end

ExecutionCohortRows{T}(store::ExecutionCohortStore, cohort::C, indices::Vector{Int}) where {T,C<:ExecutionCohort{T}} =
    ExecutionCohortRows{T,C}(store, cohort, indices)

Base.IndexStyle(::Type{<:ExecutionCohortRows}) = IndexLinear()
Base.size(rows::ExecutionCohortRows) = size(rows.indices)
Base.length(rows::ExecutionCohortRows) = length(rows.indices)
Base.dataids(rows::ExecutionCohortRows) =
    (Base.dataids(rows.indices)..., Base.dataids(rows.cohort.rows)...)

Base.@propagate_inbounds function Base.getindex(rows::ExecutionCohortRows{T}, index::Int) where {T}
    @boundscheck checkbounds(rows.indices, index)
    slot = @inbounds rows.indices[index]
    target = @inbounds rows.cohort.rows[slot]
    isnothing(target) && throw(ArgumentError(
        "This execution target was removed or changed its payload schema.",
    ))
    return target::T
end

function _execution_cohort(store::ExecutionCohortStore, owner, application_id::Symbol, ::Type{T}) where {T}
    isconcretetype(T) && T !== Nothing || throw(ArgumentError(
        "An execution cohort requires a concrete target payload type.",
    ))
    I = fieldtype(T, :object_id)
    I <: ObjectId && isconcretetype(I) || throw(ArgumentError(
        "An execution cohort requires a concrete ObjectId field in its target payload.",
    ))
    cohort = get!(store.cohorts, (owner, application_id, T)) do
        ExecutionCohort{T,I}(owner, application_id, Union{Nothing,T}[], Dict{I,Int}())
    end
    return cohort::ExecutionCohort{T,I}
end

function _clear_execution_cohort_row!(cohort::ExecutionCohort, row::Int)
    cohort.rows[row] = nothing
    return nothing
end

function _store_execution_cohort_target!(
    store::ExecutionCohortStore, cohort::ExecutionCohort{T}, target::T,
) where {T}
    object_id = ObjectId(target.object_id)
    key = (cohort.owner, cohort.application_id, object_id)
    previous = get(store.locations, key, nothing)
    if !isnothing(previous) && previous.cohort !== cohort
        _clear_execution_cohort_row!(previous.cohort, previous.row)
    end
    slot = get(cohort.indices, object_id, 0)
    if iszero(slot)
        push!(cohort.rows, target)
        slot = length(cohort.rows)
        cohort.indices[object_id] = slot
    else
        cohort.rows[slot] = target
    end
    store.locations[key] = ExecutionCohortLocation(cohort, slot)
    return slot
end

"""
    cohort_rows!(store, application_id, targets::AbstractVector{T}; owner=nothing)

Intern concrete target payloads and return a view in the supplied order. A
schedule can contain several views of the same cohort, including separate
runs around another payload family. Their membership vectors are independent.
`owner` separates execution contexts and cache leases, such as root scheduling
and distinct hard-call bindings, while their targets can share canonical status
references.
"""
function cohort_rows!(
    store::ExecutionCohortStore, application_id::Symbol, targets::AbstractVector{T}; owner=nothing,
) where {T}
    cohort = _execution_cohort(store, owner, application_id, T)
    rows = ExecutionCohortRows{T}(store, cohort, Int[])
    sizehint!(rows, length(targets))
    append!(rows, targets)
    return rows
end

function Base.setindex!(rows::ExecutionCohortRows{T}, target::T, index::Int) where {T}
    checkbounds(rows.indices, index)
    rows.indices[index] = _store_execution_cohort_target!(rows.store, rows.cohort, target)
    return rows
end

function Base.push!(rows::ExecutionCohortRows{T}, target::T) where {T}
    push!(rows.indices, _store_execution_cohort_target!(rows.store, rows.cohort, target))
    return rows
end

function Base.insert!(rows::ExecutionCohortRows{T}, index::Integer, target::T) where {T}
    1 <= index <= length(rows) + 1 || throw(BoundsError(rows, index))
    slot = _store_execution_cohort_target!(rows.store, rows.cohort, target)
    insert!(rows.indices, index, slot)
    return rows
end

function Base.append!(rows::ExecutionCohortRows{T}, targets::AbstractVector{T}) where {T}
    rows === targets && return append!(rows, copy(rows))
    for target in targets
        push!(rows, target)
    end
    return rows
end

function Base.deleteat!(rows::ExecutionCohortRows, indices)
    # Membership changes do not remove a payload used by another view. Its
    # execution owner removes it explicitly after all affected views refresh.
    deleteat!(rows.indices, indices)
    return rows
end

function Base.empty!(rows::ExecutionCohortRows)
    empty!(rows.indices)
    return rows
end

function Base.sizehint!(rows::ExecutionCohortRows, size::Integer)
    sizehint!(rows.indices, size)
    return rows
end

Base.copy(rows::ExecutionCohortRows{T}) where {T} =
    ExecutionCohortRows{T}(rows.store, rows.cohort, copy(rows.indices))

"""Reset one view's ordered membership while retaining the store's stable slots."""
function reset_cohort_rows!(rows::ExecutionCohortRows{T}, targets::AbstractVector{T}) where {T}
    rows === targets && return rows
    indices = Int[
        _store_execution_cohort_target!(rows.store, rows.cohort, target)
        for target in targets
    ]
    empty!(rows.indices)
    append!(rows.indices, indices)
    return rows
end

cohort_location(store::ExecutionCohortStore, application_id::Symbol, object_id; owner=nothing) =
    get(store.locations, (owner, application_id, ObjectId(object_id)), nothing)

"""Remove an execution payload without renumbering any cohort's row slots."""
function remove_cohort_target!(store::ExecutionCohortStore, application_id::Symbol, object_id; owner=nothing)
    key = (owner, application_id, ObjectId(object_id))
    location = pop!(store.locations, key, nothing)
    isnothing(location) && return false
    _clear_execution_cohort_row!(location.cohort, location.row)
    return true
end
