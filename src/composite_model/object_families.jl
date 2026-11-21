abstract type AbstractObjectFamily end

struct ObjectFamilyRow{I<:ObjectId,S}
    id::I
    status::S
end

mutable struct ObjectFamily{I<:ObjectId,S} <: AbstractObjectFamily
    rows::Vector{Union{Nothing,ObjectFamilyRow{I,S}}}

    ObjectFamily{I,S}(rows::Vector{Union{Nothing,ObjectFamilyRow{I,S}}}) where {I<:ObjectId,S} =
        new{I,S}(rows)
end

struct ObjectFamilyLocation
    family::Int
    row::Int
    object::Object
end

mutable struct OpenObjectFamilyCatalog
    families::Vector{AbstractObjectFamily}
    slots::Dict{Tuple{Type,Type},Int}
end

OpenObjectFamilyCatalog() = OpenObjectFamilyCatalog(
    AbstractObjectFamily[], Dict{Tuple{Type,Type},Int}(),
)

struct ClosedObjectFamilyCatalog{F<:Tuple,M}
    families::F
    status_manifest::M
end

# Open registration crosses the ordinary JIT function barrier. Closed
# registration keeps the operation inside the exact admitted Status branch,
# rather than first returning a large union from the Object's Any-valued field.
@inline _with_registered_status(f::OP, ::OpenObjectFamilyCatalog, status,
    args::Vararg{Any,N},
) where {OP,N} = f(status, args...)

@generated function _with_registered_status(f::OP, ::ClosedObjectFamilyCatalog{F},
    status, args::Vararg{Any,N},
) where {OP,F,N}
    schemas = unique(family.parameters[2] for family in fieldtypes(F))
    branches = [:(status isa $S && return f(status::$S, args...)) for S in schemas]
    return quote
        $(branches...)
        throw(ArgumentError("The status schema is outside the prepared object family catalog."))
    end
end

"""Canonical object identities and typed status families behind the object dictionary."""
mutable struct ObjectFamilyStore{I<:ObjectId,C} <: AbstractDict{I,Object}
    const catalog::C
    const locations::Dict{I,ObjectFamilyLocation}
    const status_owners::IdDict{Base.RefValue{Nothing},I}
    const changed_status_ids::Vector{ObjectId}
    const change_sink::_WeakStatusChangeSink
end

function ObjectFamilyStore(catalog, locations::Dict{I,ObjectFamilyLocation}, owners::IdDict{Base.RefValue{Nothing},I}) where {I<:ObjectId}
    ids = ObjectId[]
    return ObjectFamilyStore(catalog, locations, owners, ids, _WeakStatusChangeSink(WeakRef(ids)))
end

ObjectFamilyStore{I}() where {I<:ObjectId} = ObjectFamilyStore(
    OpenObjectFamilyCatalog(), Dict{I,ObjectFamilyLocation}(),
    IdDict{Base.RefValue{Nothing},I}(),
)
ObjectFamilyStore() = ObjectFamilyStore{ObjectId}()

Base.length(store::ObjectFamilyStore) = length(store.locations)
Base.haskey(store::ObjectFamilyStore, id) = haskey(store.locations, id)
_registry_object_ids(store::ObjectFamilyStore) = keys(store.locations)
Base.getindex(store::ObjectFamilyStore, id) = store.locations[id].object

function Base.get(store::ObjectFamilyStore, id, default)
    location = get(store.locations, id, nothing)
    return isnothing(location) ? default : location.object
end

function Base.iterate(store::ObjectFamilyStore, state...)
    item = iterate(store.locations, state...)
    isnothing(item) && return nothing
    (id, location), next = item
    return id => location.object, next
end

# A dictionary copy exposes the same mutable Object facades, as an ordinary
# shallow Dict copy does. It does not create a second writable family owner.
Base.copy(store::ObjectFamilyStore) = Dict(store)
Base.empty(::ObjectFamilyStore{I}) where {I} = ObjectFamilyStore{I}()

function _object_family_for_write!(catalog::OpenObjectFamilyCatalog, ::Type{I}, ::Type{S}) where {I,S}
    slot = get!(catalog.slots, (I, S)) do
        push!(catalog.families, ObjectFamily{I,S}(Union{Nothing,ObjectFamilyRow{I,S}}[]))
        length(catalog.families)
    end
    return slot, catalog.families[slot]::ObjectFamily{I,S}
end

@generated function _object_family_for_write!(catalog::ClosedObjectFamilyCatalog{F}, ::Type{I}, ::Type{S}) where {F,I,S}
    for (slot, family_type) in enumerate(fieldtypes(F))
        family_type === ObjectFamily{I,S} || continue
        return :($slot, getfield(catalog.families, $slot))
    end
    return :(throw(ArgumentError("The object identity/status schema is outside the prepared family catalog.")))
end

function _object_family_status_at(::OpenObjectFamilyCatalog, location::ObjectFamilyLocation)
    # The registered facade owns the existing boxed Status; family rows retain
    # its concrete reference payload. Canonical writes update both together.
    # Reuse that box across this open dispatch boundary instead of reboxing the
    # immutable Status. No scientific values or reference carriers are copied.
    return getfield(location.object, :status)
end

# A finite union retains the concrete Status families across a runtime slot.
# Object counts, IDs and row positions are deliberately absent from the type.
@generated function _object_family_status_at(catalog::ClosedObjectFamilyCatalog{F}, location::ObjectFamilyLocation) where {F}
    # Extract the family parameters directly; rows also admit tombstones.
    status_types = [family.parameters[2] for family in fieldtypes(F)]
    result_type = Union{status_types...}
    branch = :(throw(BoundsError(catalog.families, location.family)))
    for slot in reverse(1:fieldcount(F))
        check = quote
            family = getfield(catalog.families, $slot)
            isnothing(family.rows[location.row]) && throw(ArgumentError(
                "The object family row is no longer registered.",
            ))
        end
        branch = Expr(:if, :(location.family == $slot), check, branch)
    end
    return quote
        $branch
        # Reuse the official box; extracting the immutable header from a typed
        # family row would rebox it when the caller stores the result as Any.
        getfield(location.object, :status)::$result_type
    end
end

_object_family_status(store::ObjectFamilyStore, id) =
    _object_family_status_at(store.catalog, store.locations[id])

function _require_object_location(store::ObjectFamilyStore, id::ObjectId)
    location = get(store.locations, id, nothing)
    isnothing(location) && error("No model object with id `", _object_id_text(id), "`.")
    return location
end

_registered_object_status(store::ObjectFamilyStore, id::ObjectId) =
    _object_family_status_at(store.catalog, _require_object_location(store, id))

function _validate_object_family_status_owner!(store::ObjectFamilyStore, status, id)
    status isa Status || return nothing
    existing = get(store.status_owners, _status_identity(status), nothing)
    if !isnothing(existing) && existing != id
        throw(ArgumentError(
            "The same Status instance cannot be owned by model objects " *
            "`$(_object_id_text(existing))` and `$(_object_id_text(id))`. Give each Object its own Status instance.",
        ))
    end
    return nothing
end

function _forget_object_family_status!(store::ObjectFamilyStore, status, id)
    status isa Status || return nothing
    identity = _status_identity(status)
    get(store.status_owners, identity, nothing) == id && delete!(store.status_owners, identity)
    return nothing
end

function _clear_object_family_row!(catalog, location::ObjectFamilyLocation)
    catalog.families[location.family].rows[location.row] = nothing
    return nothing
end

function _store_object_family_row!(store::ObjectFamilyStore{K}, object::Object, id::I, status::S) where {K,I<:ObjectId,S}
    id isa K || throw(ArgumentError("The object identity type is outside the prepared family catalog."))
    previous = get(store.locations, id, nothing)
    if !isnothing(previous) && previous.object !== object
        throw(ArgumentError("Remove the registered Object before reusing its identity for another Object."))
    end
    _validate_object_family_status_owner!(store, status, id)
    slot, family = _object_family_for_write!(store.catalog, K, S)
    if !isnothing(previous)
        old = _object_family_status_at(store.catalog, previous)
        if old !== status
            _unwatch_status_references!(old, store.change_sink)
            _forget_object_family_status!(store, old, id)
            push!(store.changed_status_ids, id)
        end
    end
    entry = ObjectFamilyRow{K,S}(id, status)
    row = if !isnothing(previous) && previous.family == slot
        family.rows[previous.row] = entry
        previous.row
    else
        push!(family.rows, entry)
        isnothing(previous) || _clear_object_family_row!(store.catalog, previous)
        length(family.rows)
    end
    store.locations[id] = ObjectFamilyLocation(slot, row, object)
    if store.catalog isa ClosedObjectFamilyCatalog
        _watch_status_references!(status, store.change_sink, id)
    end
    status isa Status && (store.status_owners[_status_identity(status)] = id)
    return status
end

function Base.setindex!(store::ObjectFamilyStore{I}, object::Object, id) where {I<:ObjectId}
    isequal(object.id, id) || throw(ArgumentError("The dictionary key must match the Object identity."))
    object.id isa I || throw(ArgumentError("The object identity type is outside the prepared family catalog."))
    _with_registered_status(store.catalog, object.status) do status
        _store_object_family_row!(store, object, object.id::I, status)
    end
    return store
end

function Base.delete!(store::ObjectFamilyStore, id)
    location = get(store.locations, id, nothing)
    isnothing(location) && return store
    status = _object_family_status_at(store.catalog, location)
    _unwatch_status_references!(status, store.change_sink)
    _forget_object_family_status!(store, status, id)
    _clear_object_family_row!(store.catalog, location)
    delete!(store.locations, id)
    return store
end

function Base.empty!(store::ObjectFamilyStore)
    for location in values(store.locations)
        _unwatch_status_references!(_object_family_status_at(store.catalog, location), store.change_sink)
    end
    empty!(store.changed_status_ids)
    empty!(store.locations)
    empty!(store.status_owners)
    for family in store.catalog.families
        empty!(family.rows)
    end
    return store
end

"""Freeze the real ID domain of an already prepared private registry."""
function _closed_object_family_store(store::ObjectFamilyStore{K,<:ClosedObjectFamilyCatalog}) where {K}
    # Retain every known prepared family even after all its rows are removed.
    # Ordinary registries admit arbitrary ObjectId value types; explicit private
    # closure narrows only that ID domain, never discovers another Status layout.
    K !== ObjectId && return store
    I = isempty(store) ? K : Union{unique(typeof(id) for id in keys(store))...}
    return _copy_closed_object_family_store(store, I)
end

function _closed_object_family_store(store::ObjectFamilyStore{K,<:ClosedObjectFamilyCatalog},
    ::Type{I}) where {K,I}
    members = Base.uniontypes(I)
    !isempty(members) && all(T -> T <: ObjectId && isconcretetype(T), members) ||
        throw(ArgumentError("A declared closed identity domain requires concrete ObjectId types."))
    K === I && return store
    # Validate any narrower domain before copying a row: row admission installs
    # reference-change watchers on the existing canonical Status headers.
    (K <: I || all(id -> id isa I, keys(store))) ||
        throw(ArgumentError("The declared closed identity domain excludes an existing object."))
    return _copy_closed_object_family_store(store, I)
end

function _copy_closed_object_family_store(store::ObjectFamilyStore{K,<:ClosedObjectFamilyCatalog},
    ::Type{I}) where {K,I}
    manifest = store.catalog.status_manifest
    S = manifest.status_type
    families = (ObjectFamily{I,Nothing}(Union{Nothing,ObjectFamilyRow{I,Nothing}}[]),
        ObjectFamily{I,S}(Union{Nothing,ObjectFamilyRow{I,S}}[]))
    closed = ObjectFamilyStore(ClosedObjectFamilyCatalog(families, manifest),
        Dict{I,ObjectFamilyLocation}(), IdDict{Base.RefValue{Nothing},I}())
    for (id, object) in store
        status = _object_family_status(store, id)::Union{Nothing,S}
        _store_object_family_row!(closed, object, id, status)
    end
    return closed
end
