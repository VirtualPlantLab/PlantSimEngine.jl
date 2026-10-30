"""
    RefVector(field::Symbol, sts...)
    RefVector(field::Symbol, sts::Vector{<:Status})
    RefVector(v::Vector{R}) where {T,R<:Ref{T}}

A vector of references to a field of a vector of structs.
This is used to efficiently pass the values between scales.
The reference type is retained, including references into a backing array.

# Arguments

- `field`: the field of the struct to reference
- `sts...`: the structs to reference
- `sts::Vector{<:Status}`: a vector of structs to reference

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

Let's take two Status structs:

```jldoctest mylabel
julia> status1 = Status(a = 1.0, b = 2.0, c = 3.0);
```

```jldoctest mylabel
julia> status2 = Status(a = 2.0, b = 3.0, c = 4.0);
```

We can make a RefVector of the field `a` of the structs `st1` and `st2`:

```jldoctest mylabel
julia> rv = PlantSimEngine.RefVector(:a, status1, status2)
2-element PlantSimEngine.RefVector{Float64, Base.RefValue{Float64}}:
 1.0
 2.0
```

Which is equivalent to:

```jldoctest mylabel
julia> rv = PlantSimEngine.RefVector(:a, [status1, status2])
2-element PlantSimEngine.RefVector{Float64, Base.RefValue{Float64}}:
 1.0
 2.0
```

We can access the values of the RefVector:

```jldoctest mylabel
julia> rv[1]
1.0
```

Updating the value in the RefVector will update the value in the original struct:

```jldoctest mylabel
julia> rv[1] = 10.0
10.0
```

```jldoctest mylabel
julia> status1.a
10.0
```

We can also make a RefVector from a vector of references:

```jldoctest mylabel
julia> vec = [Ref(1.0), Ref(2.0), Ref(3.0)]
3-element Vector{Base.RefValue{Float64}}:
 Base.RefValue{Float64}(1.0)
 Base.RefValue{Float64}(2.0)
 Base.RefValue{Float64}(3.0)
```

```jldoctest mylabel
julia> rv = PlantSimEngine.RefVector(vec)
3-element PlantSimEngine.RefVector{Float64, Base.RefValue{Float64}}:
 1.0
 2.0
 3.0
```

```jldoctest mylabel
julia> rv[1]
1.0
```
"""
struct RefVector{T,R<:Ref{T}} <: AbstractVector{T}
    v::Vector{R}

    RefVector{T,R}(v::Vector{R}) where {T,R<:Ref{T}} = new{T,R}(v)
end

RefVector(v::Vector{R}) where {T,R<:Ref{T}} = RefVector{T,R}(v)
RefVector{T}(v::Vector{R}) where {T,R<:Ref{T}} = RefVector{T,R}(v)

function Base.getindex(rv::RefVector, i::Int)
    return rv.v[i][]
end

function Base.setindex!(rv::RefVector, v, i::Int)
    rv.v[i][] = v
end

Base.size(rv::RefVector) = size(rv.v)
Base.length(rv::RefVector) = length(rv.v)
Base.eltype(::Type{<:RefVector{T}}) where {T} = T
Base.parent(v::RefVector) = v.v

_reference_backing_dataids(reference::Ref) = ()
_reference_backing_dataids(reference::Base.RefArray) =
    Base.dataids(getfield(reference, :x))

# Reference-vector storage alone does not identify the live cells of an
# array-backed status. Deduplicate backing segments so a million references
# into one column still describe just that column and the reference vector.
function _reference_vector_dataids(references)
    return _mixed_reference_vector_dataids(references)
end

function _mixed_reference_vector_dataids(references)
    ids = UInt[Base.dataids(references)...]
    seen = Set(ids)
    for reference in references
        for id in _reference_backing_dataids(reference)
            if !(id in seen)
                push!(seen, id)
                push!(ids, id)
            end
        end
    end
    return Tuple(ids)
end

_reference_vector_dataids(references::Vector{<:Base.RefValue}) =
    Base.dataids(references)

function _reference_vector_dataids(references::Vector{<:Base.RefArray})
    isempty(references) && return Base.dataids(references)
    backing = getfield(first(references), :x)
    for reference in references
        getfield(reference, :x) === backing ||
            return _mixed_reference_vector_dataids(references)
    end
    return (Base.dataids(references)..., Base.dataids(backing)...)
end

Base.dataids(v::RefVector) = _reference_vector_dataids(parent(v))

# Julia's broadcast alias protection requires a copy of the same array type.
# Copy reference storage only on that path; normal carriers keep live cells.
# Restore the selected values shallowly, preserving mutable value identities.
function _unalias_reference_vector(references)
    copied = deepcopy(references)
    for i in eachindex(references)
        copied[i][] = references[i][]
    end
    return copied
end

function _unalias_reference_vector(references::Vector{Base.RefValue{T}}) where {T}
    copied = similar(references)
    for i in eachindex(references)
        copied[i] = Ref{T}(references[i][])
    end
    return copied
end

function _unalias_reference_vector(
    references::Vector{Base.RefArray{T,Vector{T},Roots}},
) where {T,Roots}
    # A gathered view may touch only a few entries of a very large column.
    # Copy those entries into dense independent storage, retaining the exact
    # reference type and shallow value identities required by broadcast.
    values = Vector{T}(undef, length(references))
    copied = similar(references)
    for i in eachindex(references)
        reference = references[i]
        values[i] = reference[]
        copied[i] = Base.RefArray{T,Vector{T},Roots}(
            values, i, getfield(reference, :roots),
        )
    end
    return copied
end

Base.unaliascopy(v::RefVector) = RefVector(_unalias_reference_vector(parent(v)))

Base.resize!(v::RefVector, nl::Integer) = (resize!(parent(v), nl); v)
Base.push!(v::RefVector, x...) = (push!(parent(v), x...); v)
Base.pop!(v::RefVector) = pop!(parent(v))
Base.append!(v::RefVector, items) = (append!(parent(v), items); v)
Base.empty!(v::RefVector) = (empty!(parent(v)); v)

function Base.show(io::IO, rv::RefVector{T}) where {T}
    print(io, "RefVector{")
    print(io, T)
    print(io, "}[")
    for i in 1:length(rv.v)
        print(io, rv.v[i][])
        if i < length(rv.v)
            print(io, ", ")
        end
    end
    print(io, "]")
end

# A function to make a vector of values from a vector of a field from structs:
function RefVector(field::Symbol, sts...)
    return RefVector(typeof(refvalue(sts[1], field))[refvalue(st, field) for st in sts])
end

function RefVector(field::Symbol, sts::Vector{<:Status})
    return RefVector(typeof(refvalue(sts[1], field))[refvalue(st, field) for st in sts])
end

function RefVector{T}() where {T}
    return RefVector{T}(Base.RefValue{T}[])
end
