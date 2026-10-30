"""
    Status(vars)

Status type used to store the values of the variables during simulation. It is mainly used
as the structure to store the variables in the `TimeStepRow` of a `TimeStepTable` (see 
[`PlantMeteo.jl` docs](https://palmstudio.github.io/PlantMeteo.jl/stable/)).

Most of the code is taken from MasonProtter/MutableNamedTuples.jl, so `Status` is a MutableNamedTuples with a few modifications,
so in essence, it is a stuct that stores a `NamedTuple` of the references to the values of the variables, which makes it mutable.

# Examples

A leaf with one value for all variables will make a status with one time step:

```jldoctest st1
julia> using PlantSimEngine
```

```jldoctest st1
julia> st = PlantSimEngine.Status(Ra_SW_f=13.747, sky_fraction=1.0, d=0.03, aPPFD=1500.0);
```

All these indexing methods are valid:

```jldoctest st1
julia> st[:Ra_SW_f]
13.747
```

```jldoctest st1
julia> st.Ra_SW_f
13.747
```

```jldoctest st1
julia> st[1]
13.747
```

Setting a Status variable is very easy:

```jldoctest st1
julia> st[:Ra_SW_f] = 20.0
20.0
```

```jldoctest st1
julia> st.Ra_SW_f = 21.0
21.0
```
    
```jldoctest st1
julia> st[1] = 22.0
22.0
```
"""
struct Status{N,T<:Tuple{Vararg{Ref}}}
    vars::NamedTuple{N,T}
    # `Status()` has no Ref-valued variable from which Julia could derive object
    # identity. Keep an opaque token so every runtime status, including an empty
    # one created before compilation adds variables, has a distinct identity.
    identity::Base.RefValue{Nothing}
    # A kernel-local view keeps only its declared reference fields in `vars`.
    # The erased backing preserves whole-status access and undeclared fields
    # without making unrelated canonical fields part of the kernel's type.
    # Ordinary registry statuses have no backing.
    backing::Any

    function Status(vars::NamedTuple{N,T}) where {N,T<:Tuple{Vararg{Ref}}}
        return new{N,T}(vars, Ref(nothing), nothing)
    end

    function Status(
        vars::NamedTuple{N,T}, identity::Base.RefValue{Nothing}, backing::Status,
    ) where {N,T<:Tuple{Vararg{Ref}}}
        return new{N,T}(vars, identity, backing)
    end
end

Status(; kwargs...) = Status(NamedTuple{keys(kwargs)}(Ref.(values(values(kwargs)))))
function Status{names}(tuple::Tuple) where {names}
    Status(NamedTuple{names}(Ref.(tuple)))
end

function Status(nt::NamedTuple{names}) where {names}
    Status(NamedTuple{names}(Ref.(values(nt))))
end

function _status_vars(status::Status)
    backing = getfield(status, :backing)
    return isnothing(backing) ? getfield(status, :vars) : _status_vars(backing)
end
_status_values(status) = getindex.(values(_status_vars(status)))
_status_namedtuple(status) = NamedTuple{keys(status)}(values(status))
_status_tuple(status) = values(status)
_status_iterate(status, iter=1) = iterate(NamedTuple(status), iter)
_status_firstindex(status) = 1
_status_lastindex(status) = lastindex(NamedTuple(status))
_status_indexed_iterate(status, i::Int, state=1) = Base.indexed_iterate(NamedTuple(status), i, state)

function Base.keys(status::Status{names}) where {names}
    backing = getfield(status, :backing)
    return isnothing(backing) ? names : keys(backing)
end
Base.values(st::Status) = _status_values(st)
_status_identity(status::Status) = getfield(status, :identity)
refvalues(mnt::Status) = values(_status_vars(mnt))
Base.@constprop :aggressive @inline function refvalue(mnt::Status, key::Symbol)
    vars = getfield(mnt, :vars)
    backing = getfield(mnt, :backing)
    return hasproperty(vars, key) || isnothing(backing) ? getfield(vars, key) :
           refvalue(backing, key)
end

Base.NamedTuple(mnt::Status) = _status_namedtuple(mnt)
Base.Tuple(mnt::Status) = _status_tuple(mnt)

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

Base.@constprop :aggressive @inline Base.getproperty(mnt::Status, s::Symbol) = refvalue(mnt, s)[]
Base.@constprop :aggressive @inline function Base.getindex(mnt::Status, i::Int)
    backing = getfield(mnt, :backing)
    return isnothing(backing) ? getfield(getfield(mnt, :vars), i)[] : backing[i]
end
Base.@constprop :aggressive @inline Base.getindex(mnt::Status, i::Symbol) = getproperty(mnt, i)

Base.@constprop :aggressive @inline function Base.setproperty!(mnt::Status, s::Symbol, x)
    refvalue(mnt, s)[] = x
end

Base.@constprop :aggressive @inline function Base.setproperty!(mnt::Status, i::Int, x)
    backing = getfield(mnt, :backing)
    if isnothing(backing)
        getindex(getfield(mnt, :vars), i)[] = x
    else
        backing[i] = x
    end
end

Base.@constprop :aggressive @inline function Base.setindex!(mnt::Status, x, i::Symbol)
    Base.setproperty!(mnt, i, x)
end

Base.@constprop :aggressive @inline function Base.setindex!(mnt::Status, x, i::Int)
    setproperty!(mnt, i, x)
end

Base.propertynames(mnt::Status) = keys(mnt)
Base.length(mnt::Status) = length(keys(mnt))
Base.eltype(::Type{Status{N,T}}) where {N,T} = eltype.(eltype(T))
function Base.eltype(status::Status)
    backing = getfield(status, :backing)
    return isnothing(backing) ? eltype(typeof(status)) : eltype(backing)
end

Base.iterate(mnt::Status, iter=1) = _status_iterate(mnt, iter)

Base.firstindex(mnt::Status) = _status_firstindex(mnt)
Base.lastindex(mnt::Status) = _status_lastindex(mnt)

function Base.indexed_iterate(mnt::Status, i::Int, state=1)
    _status_indexed_iterate(mnt, i, state)
end

function Base.:(==)(s1::Status, s2::Status)
    return (length(s1) == length(s2)) &&
           (propertynames(s1) == propertynames(s2)) &&
           (values(s1) == values(s2))
end
