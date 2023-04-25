"""
    StatusView(vars)

An equivalent of the `Status` struct, but with views instead of Refs. Allows to use the same syntax as Status, but initialised with values of 
other data structures present elsewhere, and that we want to update on mutation.

Like the `Status`, `StatusView` is used to store the values of the variables during a simulation, mainly as the structure to store the variables 
in the `TimeStepRow` of a `TimeStepTable` (see [`PlantMeteo.jl` docs](https://palmstudio.github.io/PlantMeteo.jl/stable/)) of a [`ModelList`](@ref).

# Examples

Making the reference data as an array:

```jldoctest st1
julia> ref_data = [13.747, 1.0, 0.03, 1500.0];
```

Making a view of the reference data:

```jldoctest st1
ref_data_view = NamedTuple{(:Rₛ, :sky_fraction, :d, :aPPFD)}(ntuple(i->view(ref_data, i), 4))
```

Making the StatusView:

```jldoctest st1
julia> st = PlantSimEngine.StatusView(ref_data_view);
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

Setting a StatusView variable is very easy:

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

The reference data is updated:

```jldoctest st1
julia> ref_data
4-element Array{Float64,1}:
 22.0
  1.0
  0.03
 1500.0
```
"""
struct StatusView{N,T<:Tuple{Vararg{<:SubArray}}}
    vars::NamedTuple{N,T}
end

function Base.getproperty(s::StatusView, name::Symbol)
    return getfield(s, :vars)[name][]
end

function Base.setproperty!(s::StatusView, name, value)
    getfield(s, :vars)[name][] = value
end

function Base.getindex(s::StatusView, name::Symbol)
    return getfield(s, :vars)[name][]
end

function Base.getindex(s::StatusView, i::Int)
    return getfield(s, :vars)[i][]
end

function Base.setindex!(s::StatusView, value, name)
    getfield(s, :vars)[name][] = value
end

Base.keys(::StatusView{names}) where {names} = names
Base.values(s::StatusView) = getindex.(values(getfield(s, :vars)))
Base.NamedTuple(mnt::StatusView) = NamedTuple{keys(mnt)}(values(mnt))
Base.Tuple(mnt::StatusView) = values(mnt)

function Base.show(io::IO, s::StatusView)
    length(s) == 0 && return
    print(io, "StatusView(")
    for (i, (k, v)) in enumerate(getfield(s, :vars))
        print(io, k, "=", v[])
        if i < length(getfield(s, :vars))
            print(io, ", ")
        end
    end
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", t::StatusView)
    st_panel = Term.Panel(
        Term.highlight(PlantMeteo.show_long_format_row(t)),
        title="StatusView",
        style="red",
        fit=false,
    )
    print(io, st_panel)
end

# function Base.show(io::IO, ::MIME"text/html", s::StatusView)
#     print(io, "StatusView(")
#     for (i, (k, v)) in enumerate(getfield(s, :vars))
#         print(io, k, "=", v[])
#         if i < length(getfield(s, :vars))
#             print(io, ", ")
#         end
#     end
#     print(io, ")")
# end


Base.propertynames(::StatusView{T,R}) where {T,R} = T
Base.length(mnt::StatusView) = length(getfield(mnt, :vars))
Base.eltype(::Type{StatusView{T}}) where {T} = T
Base.iterate(mnt::StatusView, iter=1) = iterate(NamedTuple(mnt), iter)
Base.firstindex(mnt::StatusView) = 1
Base.lastindex(mnt::StatusView) = lastindex(NamedTuple(mnt))

function Base.indexed_iterate(mnt::StatusView, i::Int, state=1)
    Base.indexed_iterate(NamedTuple(mnt), i, state)
end