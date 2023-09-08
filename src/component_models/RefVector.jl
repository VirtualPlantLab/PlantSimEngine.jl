"""
    RefVector(field::Symbol, sts...)
    RefVector(field::Symbol, sts::Vector{<:Status})
    RefVector(v::Vector{Base.RefValue{T}})

A vector of references to a field of a vector of structs.
This is used to efficiently pass the values between scales.

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
2-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
```

Which is equivalent to:

```jldoctest mylabel
julia> rv = PlantSimEngine.RefVector(:a, [status1, status2])
2-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
```

We can access the values of the RefVector:

```jldoctest mylabel
julia> rv[1]
1.0
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
3-element PlantSimEngine.RefVector{Float64}:
 1.0
 2.0
 3.0
```

```jldoctest mylabel
julia> rv[1]
```
"""
struct RefVector{T} <: AbstractVector{T}
    v::Vector{Base.RefValue{T}}
end

function Base.getindex(rv::RefVector, i::Int)
    return rv.v[i][]
end

function Base.setindex!(rv::RefVector, v, i::Int)
    rv.v[i][] = v
end

Base.size(rv::RefVector) = size(rv.v)
Base.length(rv::RefVector) = length(rv.v)
Base.eltype(::Type{RefVector{T}}) where {T} = T

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