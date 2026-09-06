struct BoundManyObjectIds{T,I<:AbstractVector{T}} <: AbstractVector{T}
    ids::I
end

Base.IndexStyle(::Type{<:BoundManyObjectIds}) = IndexLinear()
Base.size(ids::BoundManyObjectIds) = size(ids.ids)
Base.length(ids::BoundManyObjectIds) = length(ids.ids)
Base.axes(ids::BoundManyObjectIds) = axes(ids.ids)
Base.eachindex(ids::BoundManyObjectIds) = eachindex(ids.ids)
Base.@propagate_inbounds Base.getindex(ids::BoundManyObjectIds, index::Int) =
    ids.ids[index]

"""
    BoundMany <: AbstractVector

Identity-aware, reference-backed view of a compiled `Many` input.

Use [`bound_input`](@ref) inside a model kernel to obtain this view. Ordinary
positional indexing, iteration, broadcasting, and mutation operate on the same
carrier already installed in the model status. [`object_ids`](@ref) returns the
aligned, read-only object identities without copying them. Wrap an identity in
[`ObjectId`](@ref) for unambiguous identity-based indexing; integer indexing
remains positional.

Both aligned carriers use the one-based indexing contract of PlantSimEngine's
compiled input storage.
"""
struct BoundMany{T,I,V} <: AbstractVector{T}
    ids::I
    values::V
end

function _new_bound_many(ids::I, values::V) where {
    I<:AbstractVector{<:ObjectId},
    V<:AbstractVector,
}
    length(ids) == length(values) || throw(
        DimensionMismatch(
            "Compiled Many identities and values must have the same length.",
        ),
    )
    axes(ids) == axes(values) || throw(
        DimensionMismatch(
            "Compiled Many identities and values must use the same axes.",
        ),
    )
    Base.require_one_based_indexing(ids, values)
    id_view = BoundManyObjectIds(ids)
    return BoundMany{eltype(V),typeof(id_view),V}(id_view, values)
end

function _validate_bound_many_ids(ids)
    for index in (firstindex(ids) + 1):lastindex(ids)
        previous = ids[index - 1]
        current = ids[index]
        previous == current && throw(
            ArgumentError(
                "BoundMany object identities must be unique; duplicate " *
                "`$(current)`.",
            ),
        )
        _object_id_isless(previous, current) || throw(
            ArgumentError(
                "BoundMany object identities must use compiled ObjectId order; " *
                "`$(previous)` must sort before `$(current)`.",
            ),
        )
    end
    return ids
end

function BoundMany(ids::I, values::V) where {
    I<:AbstractVector{<:ObjectId},
    V<:AbstractVector,
}
    _validate_bound_many_ids(ids)
    return _new_bound_many(ids, values)
end

_compiled_bound_many(ids, values) = _new_bound_many(ids, values)

Base.IndexStyle(::Type{<:BoundMany}) = IndexLinear()
Base.size(values::BoundMany) = size(values.values)
Base.length(values::BoundMany) = length(values.values)
Base.axes(values::BoundMany) = axes(values.values)
Base.eachindex(values::BoundMany) = eachindex(values.values)
Base.parent(values::BoundMany) = values.values
Base.@propagate_inbounds Base.getindex(values::BoundMany, index::Int) =
    values.values[index]
Base.@propagate_inbounds Base.setindex!(values::BoundMany, value, index::Int) =
    setindex!(values.values, value, index)

"""
    object_ids(values::BoundMany)

Return the live, read-only `ObjectId` view aligned with `values`. The view is
maintained by compiled lifecycle refresh and does not copy the identity vector.
"""
object_ids(values::BoundMany) = values.ids

@inline function _bound_many_object_position(
    values::BoundMany,
    object_id::ObjectId,
)
    found, position = _sorted_object_id_position(values.ids.ids, object_id)
    found || throw(KeyError(object_id))
    return position
end

@inline Base.getindex(values::BoundMany, object_id::ObjectId) =
    values.values[_bound_many_object_position(values, object_id)]

@inline Base.setindex!(
    values::BoundMany,
    value,
    object_id::ObjectId,
) = setindex!(
    values.values,
    value,
    _bound_many_object_position(values, object_id),
)

_compiled_bound_many_inputs(::Tuple{}, ::Status) = NamedTuple()

function _compiled_bound_many_inputs(bindings::Tuple, status::Status)
    any(binding -> binding.multiplicity == :many, bindings) ||
        return NamedTuple()
    names = Symbol[]
    values = Any[]
    for binding in bindings
        binding.multiplicity == :many || continue
        input = binding.input
        input in names && error(
            "Compiled application input `$(input)` has more than one Many binding.",
        )
        carrier = getproperty(status, input)
        carrier isa AbstractVector || error(
            "Compiled Many input `$(input)` has non-vector runtime value " *
            "`$(typeof(carrier))`.",
        )
        push!(names, input)
        push!(values, _compiled_bound_many(binding.source_ids, carrier))
    end
    return NamedTuple{Tuple(names)}(Tuple(values))
end

_rebind_compiled_bound_many_inputs(::NamedTuple{()}, ::Status) = NamedTuple()

function _rebind_compiled_bound_many_inputs(
    bound_inputs::NamedTuple,
    status::Status,
)
    names = propertynames(bound_inputs)
    values = ntuple(length(names)) do index
        name = names[index]
        current = getproperty(bound_inputs, name)
        _compiled_bound_many(current.ids.ids, getproperty(status, name))
    end
    return NamedTuple{names}(values)
end
