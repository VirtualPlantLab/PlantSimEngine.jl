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
julia> using PlantSimEngine
```

```jldoctest st1
julia> st = PlantSimEngine.Status(Rₛ=13.747, sky_fraction=1.0, d=0.03, aPPFD=1500.0);
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
struct Status{N,T<:Tuple{Vararg{Ref}}}
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
refvalue(mnt::Status, key::Symbol) = getfield(getfield(mnt, :vars), key)

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
Base.getindex(mnt::Status, i::Int) = getfield(getfield(mnt, :vars), i)[]
Base.getindex(mnt::Status, i::Symbol) = getproperty(mnt, i)

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
Base.eltype(::Type{Status{N,T}}) where {N,T} = eltype.(eltype(T))

Base.iterate(mnt::Status, iter=1) = iterate(NamedTuple(mnt), iter)

Base.firstindex(mnt::Status) = 1
Base.lastindex(mnt::Status) = lastindex(NamedTuple(mnt))

function Base.indexed_iterate(mnt::Status, i::Int, state=1)
    Base.indexed_iterate(NamedTuple(mnt), i, state)
end


"""
    propagate_values!(status1::Dict, status2::Dict, vars_not_propagated::Set)

Propagates the values of all variables in `status1` to `status2`, except for vars in `vars_not_propagated`.

# Arguments

- `status1::Dict`: A dictionary containing the current values of variables.
- `status2::Dict`: A dictionary to which the values of variables will be propagated.
- `vars_not_propagated::Set`: A set of variables whose values should not be propagated.

# Examples

```jldoctest st1
julia> status1 = Status(var1 = 15.0, var2 = 0.3);
```

```jldoctest st1
julia> status2 = Status(var1 = 16.0, var2 = -Inf);
```

```jldoctest st1
julia> vars_not_propagated = (:var1,);

```jldoctest st1
julia> PlantSimEngine.propagate_values!(status1, status2, vars_not_propagated);
```

```jldoctest st1
julia> status2.var2 == status1.var2
true
```

```jldoctest st1
julia> status2.var1 == status1.var1
false
```
"""
function propagate_values!(status1, status2, vars_not_propagated)
    for var in setdiff(keys(status1), vars_not_propagated)
        status2[var] = status1[var]
    end
end
