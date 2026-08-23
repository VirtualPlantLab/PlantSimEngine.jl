"""Mutable row-mapping cache owned by one simulation execution target."""
mutable struct OutputAssignmentCache
    id_column::Any
    permutation::Vector{Int}
    seen::Vector{UInt64}
    epoch::UInt64
    membership_generation::UInt64
    exact_order::Bool
    valid::Bool
end

"""
    OutputTargets

Identity-aware, columnar destination view for one named `OutputTo` group.
Obtain it inside a model kernel with [`output_targets`](@ref), inspect its
stable identities with [`object_ids`](@ref), and assign identified result
tables with [`assign_outputs!`](@ref).

Destination carriers are exposed explicitly as
`targets.columns.<variable>`.

The view is valid for the current model invocation and lifecycle generation.
Do not retain it across a lifecycle barrier.
"""
struct OutputTargets{B,C}
    binding::B
    assignment_cache::C
end

function OutputTargets(binding::CompiledModelOutputDestinationBinding)
    count = length(binding.destination_ids)
    return OutputTargets(
        binding,
        OutputAssignmentCache(
            nothing,
            Vector{Int}(undef, count),
            fill(UInt64(0), count),
            UInt64(0),
            binding.membership_generation,
            false,
            false,
        ),
    )
end

@inline function Base.getproperty(targets::OutputTargets, name::Symbol)
    name === :columns || return getfield(targets, name)
    binding = getfield(targets, :binding)
    return getfield(binding, :columns)
end

Base.propertynames(::OutputTargets, private::Bool=false) =
    private ? (:columns, :binding, :assignment_cache) : (:columns,)

object_ids(targets::OutputTargets) =
    BoundManyObjectIds(getfield(getfield(targets, :binding), :destination_ids))
Base.length(targets::OutputTargets) =
    length(getfield(getfield(targets, :binding), :destination_ids))
Base.isempty(targets::OutputTargets) = iszero(length(targets))
Base.eachindex(targets::OutputTargets) = eachindex(object_ids(targets))

function _reset_output_assignment_cache!(targets::OutputTargets)
    binding = getfield(targets, :binding)
    cache = getfield(targets, :assignment_cache)
    generation = binding.membership_generation
    cache.membership_generation == generation &&
        length(cache.permutation) == length(binding.destination_ids) &&
        return cache
    count = length(binding.destination_ids)
    resize!(cache.permutation, count)
    resize!(cache.seen, count)
    fill!(cache.seen, UInt64(0))
    cache.id_column = nothing
    cache.epoch = UInt64(0)
    cache.membership_generation = generation
    cache.exact_order = false
    cache.valid = false
    return cache
end

function _output_target_context(targets::OutputTargets)
    binding = getfield(targets, :binding)
    return "application `$(binding.application_id)`, output group `$(binding.group)`"
end

function _output_table_columns(
    destination_columns::NamedTuple{names},
    table_columns,
) where {names}
    return NamedTuple{names}(
        map(name -> Tables.getcolumn(table_columns, name), names),
    )
end

@inline _first_missing_output_column(::Tuple{}, available) = nothing

@inline function _first_missing_output_column(names::Tuple, available)
    name = first(names)
    name in available || return name
    return _first_missing_output_column(Base.tail(names), available)
end

@inline function _validate_declared_output_columns(
    targets::OutputTargets,
    available,
)
    missing = _first_missing_output_column(
        propertynames(targets.columns),
        available,
    )
    isnothing(missing) || throw(
        ArgumentError(
            "Identified output table for $(_output_target_context(targets)) " *
            "is missing declared output column `$(missing)`.",
        ),
    )
    return nothing
end

function _validate_output_table_columns(
    targets::OutputTargets,
    table_columns,
    id::Symbol,
)
    available = Tables.columnnames(table_columns)
    id in available || throw(
        ArgumentError(
            "Identified output table for $(_output_target_context(targets)) " *
            "is missing ID column `$(id)`. Available columns: `$(Tuple(available))`.",
        ),
    )
    _validate_declared_output_columns(targets, available)
    return nothing
end

function _validate_output_column_lengths(
    targets::OutputTargets,
    ids,
    columns::NamedTuple,
)
    row_count = length(ids)
    for (name, column) in pairs(columns)
        length(column) == row_count || throw(
            DimensionMismatch(
                "Output column `$(name)` for $(_output_target_context(targets)) " *
                "has $(length(column)) rows, but the ID column has $(row_count).",
            ),
        )
    end
    return row_count
end

function _output_coverage_error(
    targets::OutputTargets,
    ids,
)
    binding = getfield(targets, :binding)
    target_ids = binding.destination_ids
    row_ids = ObjectId[ObjectId(id) for id in ids]
    counts = Dict{ObjectId,Int}()
    sizehint!(counts, length(row_ids))
    for object_id in row_ids
        counts[object_id] = get(counts, object_id, 0) + 1
    end
    duplicate_ids = ObjectId[
        object_id for (object_id, count) in counts
        if count > 1
    ]
    unknown_ids = ObjectId[
        object_id for object_id in keys(counts)
        if !haskey(binding.destination_index, object_id)
    ]
    missing_ids = ObjectId[
        object_id for object_id in target_ids
        if !haskey(counts, object_id)
    ]
    _sort_object_ids!(duplicate_ids)
    _sort_object_ids!(unknown_ids)
    _sort_object_ids!(missing_ids)

    details = String[]
    if length(row_ids) > length(target_ids)
        extra_ids = isempty(unknown_ids) ? duplicate_ids : unknown_ids
        push!(
            details,
            "extra result ID(s) `$([id.value for id in extra_ids])`",
        )
    elseif !isempty(unknown_ids)
        push!(
            details,
            "unknown result ID(s) `$([id.value for id in unknown_ids])`",
        )
    end
    isempty(duplicate_ids) || push!(
        details,
        "duplicate result ID(s) `$([id.value for id in duplicate_ids])`",
    )
    isempty(missing_ids) || push!(
        details,
        "missing destination ID(s) `$([id.value for id in missing_ids])`",
    )
    isempty(details) && push!(
        details,
        "$(length(row_ids)) result rows for $(length(target_ids)) destinations",
    )
    throw(
        ArgumentError(
            "Exact output coverage failed for $(_output_target_context(targets)): " *
            join(details, "; ") * ".",
        ),
    )
end

function _compile_output_assignment_permutation!(
    targets::OutputTargets,
    ids,
)
    binding = getfield(targets, :binding)
    cache = _reset_output_assignment_cache!(targets)
    length(ids) == length(binding.destination_ids) ||
        _output_coverage_error(targets, ids)

    epoch = cache.epoch + UInt64(1)
    if iszero(epoch)
        fill!(cache.seen, UInt64(0))
        epoch = UInt64(1)
    end
    # Mapping compilation mutates the reusable buffers. Invalidate the old
    # mapping before the first mutation and advance the epoch immediately so a
    # failed validation cannot expose a partially overwritten permutation or
    # make the following retry observe stale `seen` marks.
    cache.id_column = nothing
    cache.epoch = epoch
    cache.exact_order = false
    cache.valid = false
    exact_order = true
    @inbounds for (row, raw_id) in enumerate(ids)
        object_id = ObjectId(raw_id)
        destination = get(binding.destination_index, object_id, 0)
        iszero(destination) && _output_coverage_error(targets, ids)
        cache.seen[destination] == epoch &&
            _output_coverage_error(targets, ids)
        cache.seen[destination] = epoch
        cache.permutation[row] = destination
        exact_order &= destination == row
    end
    cache.id_column = ids
    cache.membership_generation = binding.membership_generation
    cache.exact_order = exact_order
    cache.valid = true
    return cache
end

function _output_assignment_cache!(targets::OutputTargets, ids)
    cache = _reset_output_assignment_cache!(targets)
    if cache.valid && cache.id_column === ids
        length(ids) == length(cache.permutation) ||
            _output_coverage_error(targets, ids)
        return cache
    end
    return _compile_output_assignment_permutation!(targets, ids)
end

@inline function _validate_output_column_values!(
    destination::RefVector{T},
    source,
    permutation,
) where {T}
    eltype(source) <: T && return nothing
    @inbounds for (row, source_index) in enumerate(eachindex(source))
        convert(T, source[source_index])
    end
    return nothing
end

@inline function _validate_output_column_values!(
    destination::ObjectRefVector,
    source,
    permutation,
)
    references = parent(destination)
    @inbounds for (row, source_index) in enumerate(eachindex(source))
        reference = references[permutation[row]]
        _validate_output_reference_value(reference, source[source_index])
    end
    return nothing
end

@inline _validate_output_reference_value(::Base.RefValue{T}, ::T) where {T} =
    nothing

@inline function _validate_output_reference_value(
    reference::Base.RefValue{T},
    value,
) where {T}
    convert(T, value)
    return nothing
end

@inline function _validate_output_column_values!(
    destination,
    source,
    permutation,
)
    @inbounds for (row, source_index) in enumerate(eachindex(source))
        convert(eltype(destination), source[source_index])
    end
    return nothing
end

@inline _validate_output_columns!(::Tuple{}, ::Tuple{}, permutation) = nothing

@inline function _validate_output_columns!(
    destinations::Tuple,
    sources::Tuple,
    permutation,
)
    _validate_output_column_values!(
        first(destinations),
        first(sources),
        permutation,
    )
    _validate_output_columns!(
        Base.tail(destinations),
        Base.tail(sources),
        permutation,
    )
    return nothing
end

_output_columns_same_mapping(destination, source) = destination === source
_output_columns_same_mapping(destination::RefVector, source::RefVector) =
    parent(destination) === parent(source)
_output_columns_same_mapping(
    destination::ObjectRefVector,
    source::ObjectRefVector,
) =
    parent(destination) === parent(source)
_output_columns_same_mapping(
    destination::RefVector,
    source::ObjectRefVector,
) =
    parent(destination) === parent(source)
_output_columns_same_mapping(
    destination::ObjectRefVector,
    source::RefVector,
) =
    parent(destination) === parent(source)

_output_columns_might_alias(destination, source) = destination === source
_output_columns_might_alias(
    destination::AbstractArray,
    source::AbstractArray,
) = Base.mightalias(destination, source)
_output_columns_might_alias(destination::RefVector, source::RefVector) =
    parent(destination) === parent(source) ||
    Base.mightalias(destination, source)
_output_columns_might_alias(
    destination::ObjectRefVector,
    source::ObjectRefVector,
) =
    parent(destination) === parent(source) ||
    Base.mightalias(destination, source)
_output_columns_might_alias(
    destination::RefVector,
    source::ObjectRefVector,
) =
    parent(destination) === parent(source) ||
    Base.mightalias(destination, source)
_output_columns_might_alias(
    destination::ObjectRefVector,
    source::RefVector,
) =
    parent(destination) === parent(source) ||
    Base.mightalias(destination, source)

@noinline function _throw_output_source_alias_error(targets)
    throw(ArgumentError(
        "Assignment for $(_output_target_context(targets)) cannot use " *
        "a differently ordered or partially overlapping output " *
        "destination column as its result source.",
    ))
end

@inline function _validate_output_alias_pair(
    destination,
    source,
    targets,
    exact_order::Bool,
    ::Val{same_position},
) where {same_position}
    aliases = _output_columns_might_alias(destination, source)
    safe_alias = exact_order && same_position &&
                 _output_columns_same_mapping(destination, source)
    aliases && !safe_alias && _throw_output_source_alias_error(targets)
    return nothing
end

@generated function _validate_output_aliasing_columns(
    destinations::Destinations,
    sources::Sources,
    targets,
    exact_order::Bool,
) where {Destinations<:Tuple,Sources<:Tuple}
    validations = Any[]
    for source_index in 1:fieldcount(Sources)
        for destination_index in 1:fieldcount(Destinations)
            same_position = destination_index == source_index
            push!(validations, :(
                _validate_output_alias_pair(
                    getfield(destinations, $destination_index),
                    getfield(sources, $source_index),
                    targets,
                    exact_order,
                    Val($same_position),
                )
            ))
        end
    end
    push!(validations, :(nothing))
    return Expr(:block, validations...)
end

function _validate_output_aliasing(
    targets::OutputTargets,
    sources::NamedTuple,
    cache::OutputAssignmentCache,
)
    destinations = values(targets.columns)
    return _validate_output_aliasing_columns(
        destinations,
        values(sources),
        targets,
        cache.exact_order,
    )
end

@inline _assign_exact_output_columns!(::Tuple{}, ::Tuple{}) = nothing

@inline function _assign_exact_output_columns!(
    destinations::Tuple,
    sources::Tuple,
)
    destination = first(destinations)
    source = first(sources)
    @inbounds for (row, source_index) in enumerate(eachindex(source))
        destination[row] = source[source_index]
    end
    _assign_exact_output_columns!(
        Base.tail(destinations),
        Base.tail(sources),
    )
    return nothing
end

@inline _assign_permuted_output_columns!(::Tuple{}, ::Tuple{}, permutation) =
    nothing

@inline function _assign_permuted_output_columns!(
    destinations::Tuple,
    sources::Tuple,
    permutation,
)
    destination = first(destinations)
    source = first(sources)
    @inbounds for (row, source_index) in enumerate(eachindex(source))
        destination[permutation[row]] = source[source_index]
    end
    _assign_permuted_output_columns!(
        Base.tail(destinations),
        Base.tail(sources),
        permutation,
    )
    return nothing
end

"""
    assign_outputs!(targets::OutputTargets, table; id=:object_id)

Assign every declared output column from an identified Tables.jl-compatible
table. Destination coverage is exact: unknown, duplicate, extra, and missing
IDs are rejected before any status is changed. Additional table metadata
columns are ignored, while every output declared by the target group is
required.

Result columns must not alias output destination storage, except for a direct
self-assignment in exact destination order. Custom array types that wrap shared
storage must implement Julia's `Base.dataids`/`Base.mightalias` contract so
aliasing can be rejected before any status is changed.

The row permutation is cached by identity of the ID column. Reusing that
column promises that its IDs and order remain unchanged; replace the ID column
object when either changes.
"""
function assign_outputs!(
    targets::OutputTargets,
    table;
    id::Symbol=:object_id,
)
    table_columns = Tables.columns(table)
    _validate_output_table_columns(targets, table_columns, id)
    ids = Tables.getcolumn(table_columns, id)
    columns = _output_table_columns(targets.columns, table_columns)
    return assign_outputs!(targets, ids, columns)
end

"""
    assign_outputs!(targets::OutputTargets, ids, columns::NamedTuple)

Lower-level identified-column assignment. `columns` must contain every output
declared by `targets`; its extra fields are ignored. This overload avoids a
Tables.jl adapter on the stable columnar path.
"""
function assign_outputs!(
    targets::OutputTargets,
    ids::AbstractVector,
    columns::NamedTuple,
)
    _validate_declared_output_columns(targets, propertynames(columns))
    declared_columns = _output_table_columns(targets.columns, columns)
    _validate_output_column_lengths(targets, ids, declared_columns)
    cache = _output_assignment_cache!(targets, ids)
    destinations = values(targets.columns)
    sources = values(declared_columns)
    _validate_output_columns!(destinations, sources, cache.permutation)
    _validate_output_aliasing(targets, declared_columns, cache)
    if cache.exact_order
        _assign_exact_output_columns!(destinations, sources)
    else
        _assign_permuted_output_columns!(
            destinations,
            sources,
            cache.permutation,
        )
    end
    return targets
end
