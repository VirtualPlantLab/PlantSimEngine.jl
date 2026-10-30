mutable struct _NativeStatusCohortRows
    rows::Dict{ObjectId,Int}
    next_row::Int
end

"""
    NativeColumnStorage()

Opt-in allocator for scalar canonical status fields. Pass it as
`CompositeModel(...; status_storage=storage)` and supply initial values as a
`NamedTuple` or dictionary. Concrete isbits values are owned by append-only
typed columns from their first allocation. Supplied `Status` objects and
all-`Ref` NamedTuple schemas keep their existing reference cells. A `Ref`
among ordinary scientific values remains a reference-valued payload.

Columns are grouped by the source status schema, variable, and effective value
type. Allocation never depends on object scale names, model package names, or
an object's current position in a selector. Removing an object does not move
other rows, so previously borrowed references remain valid after growth.
Mutable and non-isbits values use ordinary reference storage.
"""
mutable struct NativeColumnStorage
    pools::Dict{Any,Any}
    cohorts::Dict{ObjectId,Any}
    cohort_rows::Dict{Any,_NativeStatusCohortRows}
    native_allocations::Int
    fallback_allocations::Int
    preserved_references::Int
    owner::Any
end

NativeColumnStorage() = NativeColumnStorage(
    Dict{Any,Any}(), Dict{ObjectId,Any}(), Dict{Any,_NativeStatusCohortRows}(),
    0, 0, 0, nothing,
)

mutable struct _NativeStatusColumn{T}
    values::Vector{T}
end

_native_status_scalar(value) = isconcretetype(typeof(value)) && isbitstype(typeof(value))

function _native_status_pairs(source)
    source isa Status && return pairs(_status_vars(source))
    source isa Union{NamedTuple,AbstractDict,Base.Pairs} || throw(ArgumentError(
        "Initial status must be a Status, NamedTuple, dictionary, Pairs, or nothing.",
    ))
    return pairs(source)
end

function _native_status_values(source)
    names = Symbol[]
    entries = Any[]
    for (key, value) in _native_status_pairs(source)
        key isa Union{Symbol,AbstractString} || throw(ArgumentError(
            "Status keys must be symbols or strings; got $(typeof(key)).",
        ))
        name = Symbol(key)
        name in names && throw(ArgumentError(
            "Initial status repeats normalized variable $(name).",
        ))
        push!(names, name)
        push!(entries, value)
    end
    return Tuple(names), Tuple(entries)
end

function _register_status_storage_cohort!(model, object_id::ObjectId, source)
    storage = model.status_storage
    storage isa NativeColumnStorage || return nothing
    if isnothing(storage.owner)
        storage.owner = model
    elseif storage.owner !== model
        throw(ArgumentError("A NativeColumnStorage allocator belongs to one CompositeModel; construct a fresh allocator for another model."))
    end
    haskey(storage.cohorts, object_id) && return storage.cohorts[object_id]
    supported = source isa Union{Status,NamedTuple,AbstractDict,Base.Pairs}
    names, values_ = supported ? _native_status_values(source) : ((), ())
    value_types = map(typeof, values_)
    cohort = (names, value_types)
    storage.cohorts[object_id] = cohort
    rows = get!(storage.cohort_rows, cohort) do
        _NativeStatusCohortRows(Dict{ObjectId,Int}(), 0)
    end
    _reserve_native_status_row!(rows, object_id)
    return cohort
end

function _reserve_native_status_row!(cohort::_NativeStatusCohortRows, object_id::ObjectId)
    return get!(cohort.rows, object_id) do
        cohort.next_row += 1
    end
end

function _retire_status_storage_object!(model, object_id::ObjectId)
    storage = model.status_storage
    storage isa NativeColumnStorage || return nothing
    cohort = pop!(storage.cohorts, object_id, nothing)
    if !isnothing(cohort)
        delete!(storage.cohort_rows[cohort].rows, object_id)
    end
    # Do not compact arrays or decrement next_row. An escaped removed Status
    # still owns its original cells even if its ObjectId is registered again.
    return nothing
end

_allocate_status_reference(::Nothing, object_id, variable::Symbol, value) =
    Ref(value)

function _allocate_status_reference(
    storage::NativeColumnStorage, object_id::ObjectId, variable::Symbol, value,
)
    if !_native_status_scalar(value)
        storage.fallback_allocations += 1
        return Ref(value)
    end
    cohort = get(storage.cohorts, object_id, ((), ()))
    rows = get!(storage.cohort_rows, cohort) do
        _NativeStatusCohortRows(Dict{ObjectId,Int}(), 0)
    end
    row = _reserve_native_status_row!(rows, object_id)
    T = typeof(value)
    column = get!(storage.pools, (cohort, variable, T)) do
        _NativeStatusColumn(T[])
    end
    reference = _allocate_native_status_value!(column, object_id, row, value)
    storage.native_allocations += 1
    return reference
end

function _allocate_native_status_value!(
    column::_NativeStatusColumn{T}, object_id::ObjectId, row::Int, value::T,
) where {T}
    # Reserve one physical row for an object across *all* its fields. Initial
    # registration and compiler defaults need not visit objects in the same
    # order. Unassigned holes contain no exposed reference and are never read.
    length(column.values) < row && resize!(column.values, row)
    column.values[row] = value
    return Ref(column.values, row)
end

_allocate_status_reference(model::CompositeModel, object_id::ObjectId, variable::Symbol, value) =
    _allocate_status_reference(model.status_storage, object_id, variable, value)

function _materialize_initial_status(model, object_id::ObjectId, source)
    _register_status_storage_cohort!(model, object_id, source)
    isnothing(source) && return nothing
    source isa Status && return _convert_registered_status(model, object_id, source)
    source isa Union{NamedTuple,AbstractDict,Base.Pairs} || return source
    names, values_ = _native_status_values(source)
    # Match Status(NamedTuple) exactly. An all-Ref schema lends reference
    # carriers; a Ref among ordinary values is itself a scientific payload.
    if all(value -> value isa Ref, values_)
        storage = model.status_storage
        storage isa NativeColumnStorage &&
            (storage.preserved_references += length(values_))
        return _convert_registered_status(model, object_id,
            Status(NamedTuple{names}(values_)))
    end
    references = ntuple(length(names)) do index
        variable = names[index]
        value = values_[index]
        initial = if _no_status_conversion(model.status_conversion)
            value
        else
            converted, _, _ = _materialize_status_value(
                model, variable, value;
                object_id, origin=:supplied_status,
            )
            converted
        end
        return _allocate_status_reference(model, object_id, variable, initial)
    end
    return Status(NamedTuple{names}(references))
end

"""
    native_storage_report(storage::NativeColumnStorage)
    native_storage_report(model::CompositeModel)

Describe canonical allocation. The model overload additionally counts fields
whose *current* canonical reference still points into this allocator's columns;
allocated fields may have become inputs bound to a different source. This is
storage evidence, not proof that an execution backend used direct columns.
"""
function native_storage_report(storage::NativeColumnStorage)
    return (
        strategy=:canonical_columns_from_allocation,
        pools=length(storage.pools), cohorts=length(storage.cohort_rows),
        registered_objects=length(storage.cohorts),
        native_allocations=storage.native_allocations,
        fallback_allocations=storage.fallback_allocations,
        preserved_references=storage.preserved_references,
        native_bytes=sum(sizeof(column.values) for column in values(storage.pools); init=0),
        canonical_references_replaced=false,
        canonical_scalar_copy_retained=false,
        removal_policy=:append_only_stable_rows,
    )
end

function native_storage_report(model::CompositeModel)
    storage = model.status_storage
    storage isa NativeColumnStorage || return (
        strategy=:reference_cells, active_native_fields=0, active_native_objects=0,
    )
    owned_arrays = IdDict(column.values => true for column in values(storage.pools))
    active_fields = 0
    active_objects = 0
    for object in values(model.registry.objects)
        object.status isa Status || continue
        object_native = false
        for reference in refvalues(object.status)
            reference isa Base.RefArray || continue
            haskey(owned_arrays, getfield(reference, :x)) || continue
            active_fields += 1
            object_native = true
        end
        active_objects += object_native
    end
    return (; native_storage_report(storage)...,
        active_native_fields=active_fields, active_native_objects=active_objects)
end
