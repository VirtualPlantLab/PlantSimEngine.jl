# Tuple types are covariant: a tuple containing different organ ID types
# can have several concrete types. A fixed record lets JuliaC specialize the
# hash table while callers keep their original tuple keys and iteration order.
struct _StoredObjectKey{A,B,C,L}
    first::A
    second::B
    third::C
end

_stored_object_key_type(::Type{Tuple{A,B}}) where {A,B} =
    _StoredObjectKey{A,B,Nothing,2}
_stored_object_key_type(::Type{Tuple{A,B,C}}) where {A,B,C} =
    _StoredObjectKey{A,B,C,3}

function _stored_object_key(::Type{N}, key::Tuple{Any,Any}) where {N<:_StoredObjectKey}
    return N(key[1], key[2], nothing)
end

function _stored_object_key(::Type{N}, key::Tuple{Any,Any,Any}) where {N<:_StoredObjectKey}
    return N(key...)
end

_stored_object_key_arity(::_StoredObjectKey{A,B,C,L}) where {A,B,C,L} = L

function _raw_object_key(key::_StoredObjectKey)
    return _stored_object_key_arity(key) == 2 ? (key.first, key.second) :
           (key.first, key.second, key.third)
end

function Base.hash(key::_StoredObjectKey, seed::UInt)
    tail = hash((), seed)
    if _stored_object_key_arity(key) == 3
        tail = hash(key.third, tail)
    end
    return hash(key.first, hash(key.second, tail))
end

Base.isequal(left::_StoredObjectKey, right::_StoredObjectKey) =
    _stored_object_key_arity(left) == _stored_object_key_arity(right) &&
    isequal(left.first, right.first) && isequal(left.second, right.second) &&
    isequal(left.third, right.third)

@inline function _object_key_for_insertion(::Type{K}, key) where {K}
    key isa K && return key
    converted = convert(K, key)::K
    isequal(converted, key) || _invalid_object_index_key(K, key)
    return converted
end

@static if isdefined(Base, :KeyTypeError)
    _invalid_object_index_key(::Type{K}, key) where {K} = throw(Base.KeyTypeError(K, key))
else
    _invalid_object_index_key(::Type{K}, key) where {K} =
        throw(ArgumentError("$(Base.limitrepr(key)) is not a valid key for type $K"))
end

struct _ObjectKeyIndex{K,V,N} <: AbstractDict{K,V}
    data::Dict{N,V}
end

function _object_key_index(::Type{K}, ::Type{V}) where {K<:Tuple,V}
    any(type -> type isa Union, fieldtypes(K)) || return Dict{K,V}()
    N = _stored_object_key_type(K)
    return _ObjectKeyIndex{K,V,N}(Dict{N,V}())
end

Base.length(index::_ObjectKeyIndex) = length(index.data)

function Base.iterate(index::_ObjectKeyIndex{K,V}, state...) where {K,V}
    row = iterate(index.data, state...)
    isnothing(row) && return nothing
    ((stored, value), next) = row
    return Pair{K,V}(_raw_object_key(stored), value), next
end

function Base.getindex(index::_ObjectKeyIndex{K,V,N}, key) where {K,V,N}
    key isa K || throw(KeyError(key))
    stored = _stored_object_key(N, key)
    return get(index.data, stored) do
        throw(KeyError(_raw_object_key(stored)))
    end
end

function Base.setindex!(index::_ObjectKeyIndex{K,V,N}, @nospecialize(value), key) where {K,V,N}
    checked = Base.@inline _object_key_for_insertion(K, key)
    index.data[_stored_object_key(N, checked)] = value
    return index
end

Base.get(index::_ObjectKeyIndex{K,V,N}, key, default) where {K,V,N} =
    key isa K ? get(index.data, _stored_object_key(N, key), default) : default
Base.haskey(index::_ObjectKeyIndex{K,V,N}, key) where {K,V,N} =
    key isa K && haskey(index.data, _stored_object_key(N, key))

function Base.get!(make::Union{Function,Type}, index::_ObjectKeyIndex{K,V,N}, key) where {K,V,N}
    checked = Base.@inline _object_key_for_insertion(K, key)
    return get!(make, index.data, _stored_object_key(N, checked))
end

function Base.get!(index::_ObjectKeyIndex{K,V,N}, key, default) where {K,V,N}
    checked = Base.@inline _object_key_for_insertion(K, key)
    return get!(index.data, _stored_object_key(N, checked), default)
end

@inline function Base.pop!(index::_ObjectKeyIndex{K,V,N}, key) where {K,V,N}
    key isa K || throw(KeyError(key))
    stored = _stored_object_key(N, key)
    haskey(index.data, stored) || throw(KeyError(key))
    return pop!(index.data, stored)
end

Base.pop!(index::_ObjectKeyIndex{K,V,N}, key, default) where {K,V,N} =
    key isa K ? pop!(index.data, _stored_object_key(N, key), default) : default

function Base.delete!(index::_ObjectKeyIndex{K,V,N}, key) where {K,V,N}
    key isa K && delete!(index.data, _stored_object_key(N, key))
    return index
end

Base.empty(index::_ObjectKeyIndex{K,V}) where {K,V} = _object_key_index(K, V)
Base.empty!(index::_ObjectKeyIndex) = (empty!(index.data); index)
Base.copy(index::_ObjectKeyIndex) = typeof(index)(copy(index.data))
function Base.sizehint!(index::_ObjectKeyIndex, n::Integer; kwargs...)
    sizehint!(index.data, n; kwargs...)
    return index
end

struct _ObjectKeySet{K,N} <: AbstractSet{K}
    data::Set{N}
end

function _object_key_set(::Type{K}) where {K<:Tuple}
    any(type -> type isa Union, fieldtypes(K)) || return Set{K}()
    N = _stored_object_key_type(K)
    return _ObjectKeySet{K,N}(Set{N}())
end

function Base.push!(set::_ObjectKeySet{K,N}, key) where {K,N}
    checked = Base.@inline _object_key_for_insertion(K, key)
    push!(set.data, _stored_object_key(N, checked))
    return set
end

Base.in(key, set::_ObjectKeySet{K,N}) where {K,N} =
    key isa K && _stored_object_key(N, key) in set.data
Base.length(set::_ObjectKeySet) = length(set.data)

function Base.iterate(set::_ObjectKeySet, state...)
    row = iterate(set.data, state...)
    isnothing(row) && return nothing
    return _raw_object_key(row[1]), row[2]
end

function Base.delete!(set::_ObjectKeySet{K,N}, key) where {K,N}
    key isa K && delete!(set.data, _stored_object_key(N, key))
    return set
end

Base.empty(set::_ObjectKeySet{K}) where {K} = _object_key_set(K)
Base.empty!(set::_ObjectKeySet) = (empty!(set.data); set)
Base.copy(set::_ObjectKeySet) = typeof(set)(copy(set.data))
function Base.sizehint!(set::_ObjectKeySet, n::Integer; kwargs...)
    sizehint!(set.data, n; kwargs...)
    return set
end

function _object_key_set(::Type{K}, raw) where {K<:Tuple}
    result = _object_key_set(K)
    for key in raw
        push!(result, key)
    end
    return result
end
