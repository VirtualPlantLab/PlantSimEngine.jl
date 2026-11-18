"""
    ObjectId(value)

Stable identity of one [`Object`](@ref) in a [`CompositeModel`](@ref).
Strings are normalized to symbols; an existing `ObjectId` is returned
unchanged.
"""
struct ObjectId{T}
    value::T
end
ObjectId(id::ObjectId) = id
ObjectId(id::AbstractString) = ObjectId(Symbol(id))

function Base.show(io::IO, id::ObjectId)
    print(io, "ObjectId(")
    show(io, id.value)
    print(io, ')')
end
