"""
    Status(vars)

Status type used to store the values of the variables during simulation. It is mainly used
as the structure to store the variables in the `TimeStepRow` of a `TimeStepTable` (see 
[`PlantMeteo.jl` docs](https://palmstudio.github.io/PlantMeteo.jl/stable/)) of a [`ModelList`](@ref).

Most of the code is taken from MasonProtter/MutableNamedTuples.jl, so `Status` is a MutableNamedTuples with a few modifications,
so in essence, it is a stuct that stores a `NamedTuple` of the references to the values of the variables, which makes it mutable.

# Examples

A leaf with one value for all variables will make a status with one time step:

```jldoctest st1
julia> st = PlantSimEngine.Status(Rₛ=13.747, sky_fraction=1.0, d=0.03, PPFD=1500.0);
```

All these indexing methods are valid:

```jldoctest st1
julia> st[:Rₛ]
13.747
```

```jldoctest st1
julia> st.Rₛ
13.747
```

```jldoctest st1
julia> st[1]
13.747
```

Setting a Status variable is very easy:

```jldoctest st1
julia> st[:Rₛ] = 20.0
20.0
```

```jldoctest st1
julia> st.Rₛ = 21.0
21.0
```
    
```jldoctest st1
julia> st[1] = 22.0
22.0
```
"""
struct Status{N,T<:Tuple{Vararg{<:Ref}}}
    vars::NamedTuple{N,T}
end

Status(; kwargs...) = Status(NamedTuple{keys(kwargs)}(Ref.(values(values(kwargs)))))
function Status{names}(tuple::Tuple) where {names}
    Status(NamedTuple{names}(Ref.(tuple)))
end

function Status(nt::NamedTuple{names}) where {names}
    Status(NamedTuple{names}(Ref.(values(nt))))
end

Base.keys(::Status{names}) where {names} = names
Base.values(st::Status) = getindex.(values(getfield(st, :vars)))
refvalues(mnt::Status) = values(getfield(mnt, :vars))
Base.NamedTuple(mnt::Status) = NamedTuple{keys(mnt)}(values(mnt))
Base.Tuple(mnt::Status) = values(mnt)

function Base.show(io::IO, ::MIME"text/plain", t::Status)
    st_panel = Term.Panel(
        Term.highlight(PlantMeteo.show_long_format_row(t)),
        title="Status",
        style="red",
        fit=false,
    )
    print(io, st_panel)
end

# Short form printing (e.g. inside another object)
function Base.show(io::IO, t::Status)
    length(t) == 0 && return
    print(io, "Status", NamedTuple(t))
end

Base.getproperty(mnt::Status, s::Symbol) = getproperty(getfield(mnt, :vars), s)[]
Base.getindex(mnt::Status, i::Int) = getfield(NamedTuple(mnt), i)
Base.getindex(mnt::Status, i::Symbol) = getfield(NamedTuple(mnt), i)

function Base.setproperty!(mnt::Status, s::Symbol, x)
    nt = getfield(mnt, :vars)
    getfield(nt, s)[] = x
end

function Base.setproperty!(mnt::Status, i::Int, x)
    nt = getfield(mnt, :vars)
    getindex(nt, i)[] = x
end

function Base.setindex!(mnt::Status, x, i::Symbol)
    Base.setproperty!(mnt, i, x)
end

function Base.setindex!(mnt::Status, x, i::Int)
    setproperty!(mnt, i, x)
end

Base.propertynames(::Status{T,R}) where {T,R} = T
Base.length(mnt::Status) = length(getfield(mnt, :vars))
Base.eltype(::Type{Status{T}}) where {T} = T

Base.iterate(mnt::Status, iter=1) = iterate(NamedTuple(mnt), iter)

Base.firstindex(mnt::Status) = 1
Base.lastindex(mnt::Status) = lastindex(NamedTuple(mnt))

function Base.indexed_iterate(mnt::Status, i::Int, state=1)
    Base.indexed_iterate(NamedTuple(mnt), i, state)
end