# A registered canonical header can be shared by multiple models. Each
# registry records edits under its own ID, even when the other model ran first.
struct _WeakStatusChangeSink
    ids::WeakRef
end

# Construct a registered GC weak reference when copying an entire model. The
# registry owns the copied vector, and the shared deepcopy memo preserves that
# relationship regardless of whether the header or registry is copied first.
function Base.deepcopy_internal(sink::_WeakStatusChangeSink, memo::IdDict)
    haskey(memo, sink.ids) && return _WeakStatusChangeSink(memo[sink.ids]::WeakRef)
    ids = sink.ids.value::Union{Nothing,Vector{ObjectId}}
    weak = WeakRef(ids)
    memo[sink.ids] = weak
    weak.value = Base.deepcopy_internal(ids, memo)
    return _WeakStatusChangeSink(weak)
end

struct _StatusReferenceWatch
    sink::_WeakStatusChangeSink
    id::ObjectId
end

_watch_ids(watch::_StatusReferenceWatch) = watch.sink.ids.value::Union{Nothing,Vector{ObjectId}}

# N is the prepared namespace; the backing determines currently visible fields.
mutable struct _FixedStatusStorage{N,R<:Tuple,T<:NamedTuple}
    refs::T
    reference_epoch::UInt
    watchers::Union{Nothing,_StatusReferenceWatch,Vector{_StatusReferenceWatch}}
    function _FixedStatusStorage{N,R,T}(refs, epoch) where {N,R,T}
        return new{N,R,T}(refs, epoch, nothing)
    end
end

# A kernel carries its declared reference cells inline. The wider directory of
# visible cells and the epoch at which it was captured travel as one handle.
mutable struct _ProjectedStatusSnapshot{T<:NamedTuple}
    const refs::T
    const reference_epoch::UInt
end

struct _ProjectedStatusStorage{N,R<:Tuple,H<:NamedTuple,T<:NamedTuple}
    hot::H
    snapshot::_ProjectedStatusSnapshot{T}
end

@inline _status_reference_slots(storage::_FixedStatusStorage) = storage.refs
@inline _status_reference_slots(storage::_ProjectedStatusStorage) = storage.snapshot.refs

"""
    Status(vars)

Named values stored through mutable references. A standalone `Status` contains
its supplied fields. [`CompositeModel`](@ref) prepares the official registry
container and its allowed field types; use [`model_status`](@ref) to retrieve it.
Unchanged values share their references with the supplied status, while numeric
conversion can create new references. Fields without a real reference remain
absent. Positional access follows the order chosen at preparation.

The standalone reference container is adapted from
MasonProtter/MutableNamedTuples.jl.

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
struct Status{N,T}
    vars::T
    identity::Base.RefValue{Nothing}
    function Status(vars::NamedTuple{N,R}) where {N,R<:Tuple{Vararg{Ref}}}
        return new{N,typeof(vars)}(vars, Ref(nothing))
    end
    function Status(vars::_FixedStatusStorage{N}) where {N}
        return new{N,typeof(vars)}(vars, Ref(nothing))
    end
    function Status(vars::_ProjectedStatusStorage{N}) where {N}
        return new{N,typeof(vars)}(vars, Ref(nothing))
    end
end

# The physical namespace has one finite reference union per slot. This is a
# storage bound; configuration admission is checked separately before activation.
# Nothing marks a namespace slot with no canonical Ref family. Ref{Nothing}
# remains a real present cell whose biological value is nothing.
function _fixed_status_type(names::Tuple, references::Type{<:Tuple})
    length(names) == fieldcount(references) && all(n -> n isa Symbol, names) &&
        length(unique(names)) == length(names) || throw(ArgumentError("Invalid prepared status namespace."))
    valid = all(fieldtypes(references)) do R
        R === Nothing || all(T -> T <: Ref && isconcretetype(T), Base.uniontypes(R))
    end
    valid || throw(ArgumentError("Each prepared status slot needs a finite exact reference family."))
    Slots = NamedTuple{names,Tuple{map(R -> Union{Nothing,R}, fieldtypes(references))...}}
    return Status{names,_FixedStatusStorage{names,references,Slots}}
end
@generated function _fixed_status(::Type{S}) where {N,R,T,S<:Status{N,_FixedStatusStorage{N,R,T}}}
    empty = Expr(:tuple, fill(nothing, length(N))...)
    return :(Status(_FixedStatusStorage{$(QuoteNode(N)),$R,$T}($T($empty), UInt(0))))
end
_fixed_status(names::Val{N}, references::Type{<:Tuple}) where {N} =
    _fixed_status(_fixed_status_type(N, references))

_status_storage_names(storage::NamedTuple) = keys(storage)
_status_storage_names(storage::Union{_FixedStatusStorage{N},_ProjectedStatusStorage{N}}) where {N} =
    filter(name -> getfield(_status_reference_slots(storage), name) !== nothing, N)
_status_storage_reference_types(::Type{NamedTuple{N,R}}) where {N,R} = R
_status_storage_reference_types(::Type{<:_FixedStatusStorage{N,R}}) where {N,R} = R
_status_storage_reference_types(::Type{<:_ProjectedStatusStorage{N,R}}) where {N,R} = R
@inline _status_reference(storage::NamedTuple, key) = getfield(storage, key)
@inline function _status_reference(storage::_FixedStatusStorage, key::Symbol)
    reference = getfield(storage.refs, key)
    reference === nothing && throw(KeyError(key))
    return reference
end
@inline function _status_reference(storage::_ProjectedStatusStorage{N,R,H}, key::Symbol) where {N,R,H}
    hasfield(H, key) && return getfield(storage.hot, key)
    reference = getfield(_status_reference_slots(storage), key)
    reference === nothing && throw(KeyError(key))
    return reference
end
@inline _status_reference(storage::Union{_FixedStatusStorage,_ProjectedStatusStorage}, key::Int) =
    _status_reference(storage, _status_storage_names(storage)[key])

# Reference/presence edits invalidate projections; ref[] = value does not.
_status_reference_epoch(storage::NamedTuple) = UInt(0)
_status_reference_epoch(storage::_FixedStatusStorage) = storage.reference_epoch
_status_reference_epoch(storage::_ProjectedStatusStorage) = storage.snapshot.reference_epoch
_status_reference_epoch(status::Status) = _status_reference_epoch(_status_vars(status))
function _watch_status_references!(status::Status{N,<:_FixedStatusStorage}, sink, id) where {N}
    storage = _status_vars(status)
    watched = storage.watchers
    current = _StatusReferenceWatch(sink, id)
    if isnothing(watched) || (watched isa _StatusReferenceWatch && isnothing(_watch_ids(watched)))
        storage.watchers = current
    elseif watched isa _StatusReferenceWatch
        watched.sink.ids === sink.ids || (storage.watchers = [watched, current])
    else
        filter!(watch -> !isnothing(_watch_ids(watch)), watched)
        any(watch -> watch.sink.ids === sink.ids, watched) || push!(watched, current)
        length(watched) == 1 && (storage.watchers = only(watched))
    end
    return nothing
end
_watch_status_references!(status, sink, id) = nothing

function _unwatch_status_references!(status::Status{N,<:_FixedStatusStorage}, sink) where {N}
    storage = _status_vars(status)
    watched = storage.watchers
    if watched isa _StatusReferenceWatch
        watched.sink.ids === sink.ids && (storage.watchers = nothing)
    elseif watched isa Vector
        filter!(watch -> watch.sink.ids !== sink.ids && !isnothing(_watch_ids(watch)), watched)
        length(watched) <= 1 && (storage.watchers = isempty(watched) ? nothing : only(watched))
    end
    return nothing
end
_unwatch_status_references!(status, sink) = nothing

function _record_status_reference_change!(watch::_StatusReferenceWatch)
    ids = _watch_ids(watch)
    isnothing(ids) && return false
    push!(ids, watch.id)
    return true
end

function _advance_status_reference_epoch!(storage::_FixedStatusStorage)
    storage.reference_epoch += UInt(1)
    watched = storage.watchers
    if watched isa _StatusReferenceWatch
        _record_status_reference_change!(watched) || (storage.watchers = nothing)
    elseif watched isa Vector
        filter!(_record_status_reference_change!, watched)
        length(watched) <= 1 && (storage.watchers = isempty(watched) ? nothing : only(watched))
    end
    return nothing
end

function _set_status_reference!(status::Status{N,<:_FixedStatusStorage}, name::Symbol, reference::Ref) where {N}
    storage = _status_vars(status)
    index = findfirst(isequal(name), N)
    index === nothing && throw(KeyError(name))
    R = fieldtype(_status_storage_reference_types(typeof(storage)), index)
    reference isa R || throw(ArgumentError("Reference is outside its prepared slot type."))
    old = getfield(storage.refs, index)
    old === reference && return reference
    storage.refs = typeof(storage.refs)(Base.setindex(values(storage.refs), reference, index))
    _advance_status_reference_epoch!(storage)
    return reference
end
function _drop_status_reference!(status::Status{N,<:_FixedStatusStorage}, name::Symbol) where {N}
    storage = _status_vars(status)
    old = getfield(storage.refs, name)
    old === nothing && return nothing
    index = findfirst(isequal(name), N)
    storage.refs = typeof(storage.refs)(Base.setindex(values(storage.refs), nothing, index))
    _advance_status_reference_epoch!(storage)
    return old
end
Status(; kwargs...) = Status(NamedTuple{keys(kwargs)}(Ref.(values(values(kwargs)))))
function Status{names}(tuple::Tuple) where {names}
    Status(NamedTuple{names}(Ref.(tuple)))
end

function Status(nt::NamedTuple{names}) where {names}
    Status(NamedTuple{names}(Ref.(values(nt))))
end

_status_vars(status) = getfield(status, :vars)
# A standalone status owns a dense, statically named tuple of references.
_map_status_slots(::typeof(identity), slots::NamedTuple) = slots
@generated function _map_status_slots(f::F, slots::NamedTuple{names}) where {F,names}
    fields = Expr(:tuple, [:(f(getfield(slots, $i))) for i in eachindex(names)]...)
    return :(NamedTuple{$(QuoteNode(names))}($fields))
end

# A prepared namespace may be wide and sparsely populated. Compile the operation
# for each distinct reference type and read the occupied positions in field order.
@generated function _status_cell_families(::Type{S}) where {S<:NamedTuple}
    types = unique(T for slot in fieldtypes(S) for T in Base.uniontypes(slot) if T !== Nothing)
    return :(Tuple{$(types...)})
end

# Box the directory once so the compiler can call the same traversal for status
# layouts with hundreds of different names and the same reference types.
struct _StatusReferenceDirectory
    slots::NamedTuple
end

@generated function _append_status_cell!(
    items::Vector{Any}, f::F, directory::_StatusReferenceDirectory, index::Int, ::Type{R},
) where {F,R<:Tuple}
    branches = [:(if reference isa $T
        push!(items, f(reference::$T))
        return true
    end) for T in fieldtypes(R)]
    return quote
        reference = getfield(directory.slots, index)
        isnothing(reference) && return false
        $(branches...)
        throw(ArgumentError("Invalid prepared status reference."))
    end
end

function _map_present_status_fields(
    f::F, ::Type{T}, directory::_StatusReferenceDirectory, namespace::NTuple{N,Symbol}, ::Type{R},
) where {F,T,N,R<:Tuple}
    names = Symbol[]
    items = Any[]
    for index in eachindex(namespace)
        present = _append_status_cell!(items, f, directory, index, R)
        present && T === NamedTuple && push!(names, namespace[index])
    end
    data = Tuple(items)
    return T === Tuple ? data : NamedTuple{Tuple(names)}(data)
end

function _map_status_fields(f::F, ::Type{T}, status::Status) where {F,T}
    storage = _status_vars(status)
    if storage isa NamedTuple
        fields = _map_status_slots(f, storage)
        return T === Tuple ? Tuple(fields) : fields
    end
    slots = _status_reference_slots(storage)
    return _map_present_status_fields(f, T, _StatusReferenceDirectory(slots), keys(slots),
        _status_cell_families(typeof(slots)))
end

_status_namedtuple(status) = _map_status_fields(getindex, NamedTuple, status)
_status_values(status) = _map_status_fields(getindex, Tuple, status)
_status_tuple(status) = values(status)
_status_iterate(status, iter=1) = iterate(values(status), iter)
_status_firstindex(status) = 1
_status_lastindex(status) = length(status)
_status_indexed_iterate(status, i::Int, state=1) = Base.indexed_iterate(values(status), i, state)

Base.keys(status::Status) = _status_storage_names(_status_vars(status))
Base.values(st::Status) = _status_values(st)
_status_identity(status::Status) = getfield(status, :identity)
refvalues(mnt::Status) = _map_status_fields(identity, Tuple, mnt)
Base.@constprop :aggressive @inline refvalue(mnt::Status, key::Symbol) = _status_reference(_status_vars(mnt), key)

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
Base.@constprop :aggressive @inline Base.getindex(mnt::Status, i::Int) = _status_reference(_status_vars(mnt), i)[]
Base.@constprop :aggressive @inline Base.getindex(mnt::Status, i::Symbol) = getproperty(mnt, i)

Base.@constprop :aggressive @inline function Base.setproperty!(mnt::Status, s::Symbol, x)
    refvalue(mnt, s)[] = x
end

Base.@constprop :aggressive @inline function Base.setproperty!(mnt::Status, i::Int, x)
    _status_reference(_status_vars(mnt), i)[] = x
end

Base.@constprop :aggressive @inline function Base.setindex!(mnt::Status, x, i::Symbol)
    Base.setproperty!(mnt, i, x)
end

Base.@constprop :aggressive @inline function Base.setindex!(mnt::Status, x, i::Int)
    setproperty!(mnt, i, x)
end

Base.propertynames(status::Status) = keys(status)
Base.length(mnt::Status) = length(keys(mnt))
Base.eltype(::Type{Status{N,T}}) where {N,T} = eltype.(eltype(_status_storage_reference_types(T)))

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

# A shallow copy owns its header/presence, shares biological cells, and is unregistered.
_copy_status_storage(storage::Union{NamedTuple,_ProjectedStatusStorage}) = storage
_copy_status_storage(storage::_FixedStatusStorage{N,R,T}) where {N,R,T} =
    _FixedStatusStorage{N,R,T}(storage.refs, storage.reference_epoch)
Base.copy(status::Status) = Status(_copy_status_storage(_status_vars(status)))
# Keep Base's single-IdDict deepcopy: it preserves internal aliases/cycles and
# copies refs, owner metadata and the identity token together; no elementwise map.

@inline function _status_reference_slots(source::Status)
    storage = _status_vars(source)
    storage isa NamedTuple && return storage
    storage isa Union{_FixedStatusStorage,_ProjectedStatusStorage} || throw(ArgumentError("Unknown Status backing."))
    return _status_reference_slots(storage)
end
@inline _initial_status_reference_count(source::Status) =
    _initial_status_reference_count(_status_reference_slots(source))
# A newborn may supply any admitted layout. Box its directory once at this
# boundary so scanning a wide, mutable Status does not copy it for each field.
Base.@noinline Base.@nospecializeinfer function _initial_status_reference_count(@nospecialize(references::NamedTuple))
    count = 0
    for index in 1:nfields(references)
        getfield(references, index) === nothing || (count += 1)
    end
    return count
end
@inline _initial_status_reference(source::Status, name::Symbol) =
    _initial_status_reference(_status_reference_slots(source), name)
@inline function _initial_status_reference(references::NamedTuple, name::Symbol)
    slot = Base.fieldindex(typeof(references), name, false)
    return iszero(slot) ? nothing : getfield(references, slot)
end

# S is admitted by the prepared owner BEFORE this generated operation. No source
# NamedTuple subtype, field-count permutation or initializer value becomes proof.
@generated function _new_prepared_status(::Type{S}, source) where {N,R,T,S<:Status{N,_FixedStatusStorage{N,R,T}}}
    cells = [gensym(:cell) for _ in N]
    reads = [:($(cells[i]) = _initial_status_reference(source, $(QuoteNode(name)))) for (i,name) in enumerate(N)]
    checks = [:( $(cells[i]) isa $(fieldtype(T,i)) || throw(ArgumentError("Initial reference is outside its prepared slot family.")) ) for i in eachindex(N)]
    count = foldl((a,b)->:($a + $b), [:(Int($(cell) !== nothing)) for cell in cells]; init=:(0))
    refs = Expr(:tuple, [:( $(cells[i])::$(fieldtype(T,i)) ) for i in eachindex(N)]...)
    return quote
        $(Expr(:meta, :inline))
        source isa S && return source
        source === nothing && return _fixed_status(S)
        source isa Status || throw(ArgumentError("Initial status must be a Status or nothing."))
        $(reads...)
        $(checks...)
        $count == _initial_status_reference_count(source) || throw(ArgumentError("Initial status contains a name outside its prepared namespace."))
        return Status(_FixedStatusStorage{$(QuoteNode(N)),$R,$T}($T($refs), UInt(0)))
    end
end

@inline function _validate_status_reference(status::Status{N,<:_FixedStatusStorage}, name::Symbol, reference::Ref) where {N}
    index = findfirst(isequal(name), N)
    index === nothing && throw(KeyError(name))
    R = fieldtype(_status_storage_reference_types(typeof(_status_vars(status))), index)
    reference isa R || throw(ArgumentError("Reference is outside its prepared canonical slot family."))
    return nothing
end

_dense_status_type(names::Tuple, references::Type{<:Tuple}) = Status{names,NamedTuple{names,references}}
function _projected_status_type(::Type{C}, hot_names::Tuple, hot_references::Type{<:Tuple}) where {C<:Status}
    names = _status_schema_names(C)
    all(n -> n in names, hot_names) || throw(ArgumentError("A kernel port is outside the prepared namespace."))
    canonical = _status_schema_references(C)
    refs = map(eachindex(names)) do index
        hot_index = findfirst(isequal(names[index]), hot_names)
        isnothing(hot_index) ? fieldtype(canonical,index) : fieldtype(hot_references,hot_index)
    end
    R = Tuple{refs...}
    Slots = NamedTuple{names,Tuple{map(T -> Union{Nothing,T}, refs)...}}
    Hot = NamedTuple{hot_names,hot_references}
    return Status{names,_ProjectedStatusStorage{names,R,Hot,Slots}}
end

@inline _status_storage_hasproperty(storage::NamedTuple, name::Symbol) =
    hasfield(typeof(storage), name)
@generated function _status_storage_hasproperty(
    storage::Union{_FixedStatusStorage{N},_ProjectedStatusStorage{N}},
    name::Symbol,
) where {N}
    branches = [:(name === $(QuoteNode(field)) &&
        return getfield(_status_reference_slots(storage), $index) !== nothing)
        for (index, field) in enumerate(N)]
    return quote
        $(Expr(:meta, :inline))
        $(branches...)
        return false
    end
end
Base.@constprop :aggressive @inline Base.hasproperty(status::Status, name::Symbol) =
    _status_storage_hasproperty(_status_vars(status), name)
