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

    function Status(vars::NamedTuple{N,T}) where {N,T<:Tuple{Vararg{Ref}}}
        return new{N,T}(vars, Ref(nothing))
    end
end

Status(; kwargs...) = Status(NamedTuple{keys(kwargs)}(Ref.(values(values(kwargs)))))
function Status{names}(tuple::Tuple) where {names}
    Status(NamedTuple{names}(Ref.(tuple)))
end

function Status(nt::NamedTuple{names}) where {names}
    Status(NamedTuple{names}(Ref.(values(nt))))
end

_status_vars(status) = getfield(status, :vars)
_status_values(status) = getindex.(values(_status_vars(status)))
_status_namedtuple(status) = NamedTuple{keys(status)}(values(status))
_status_tuple(status) = values(status)
_status_iterate(status, iter=1) = iterate(NamedTuple(status), iter)
_status_firstindex(status) = 1
_status_lastindex(status) = lastindex(NamedTuple(status))
_status_indexed_iterate(status, i::Int, state=1) = Base.indexed_iterate(NamedTuple(status), i, state)

Base.keys(::Status{names}) where {names} = names
Base.values(st::Status) = _status_values(st)
_status_identity(status::Status) = getfield(status, :identity)
refvalues(mnt::Status) = values(getfield(mnt, :vars))
refvalue(mnt::Status, key::Symbol) = getfield(getfield(mnt, :vars), key)

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


# Returns a status with all vector variables replaced with their first value (ie a Status ready for simulation)
# also returns a tuple of symbols corresponding to the vector variables
function flatten_status(s::Status{T}) where {T}
    n_vars_several_values = findall(x -> length(x) > 1, s)
    if length(n_vars_several_values) == 0
        return s, n_vars_several_values
    else
        return Status{keys(s)}(first.(values(s))), n_vars_several_values
    end
end

"""
    set_variables_at_timestep!(status_timestep::Status, user_status::Status, variables_to_update, timestep)

Update `status_timestep` to the current values at the `timestep` for all `variables_to_update` in the status provided by the user (`user_status`).
The variables to update are given in `variables_to_update`, which is a vector of symbols.

`status_timestep` is a status representing a single time-step. `user_status` is the status provided that gives values for variables that are not computed by any model.
It may give constant values or vectors of values, in which case the `timestep` is used to select the value to use for the current time step.

"""
function set_variables_at_timestep!(status_timestep::Status, user_status::Status, variables_to_update, timestep)
    for vec in variables_to_update
        status_timestep[vec] = user_status[vec][timestep]
    end
end

# TODO do a bit more and return error if there is a length discrepancy that isn't accounted for by timestep differences
function get_status_vector_max_length(s::Status)
    max_len = 1
    for (var, value) in zip(keys(s), s)
        if length(value) > 1
            max_len = length(value)
        end
    end
    return max_len
end
