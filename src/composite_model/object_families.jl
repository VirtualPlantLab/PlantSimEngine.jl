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
    slots::Dict{Tuple{DataType,DataType},Int}
end

OpenObjectFamilyCatalog() = OpenObjectFamilyCatalog(
    AbstractObjectFamily[], Dict{Tuple{DataType,DataType},Int}(),
)

struct ClosedObjectFamilyCatalog{F<:Tuple}
    families::F
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
struct ObjectFamilyStore{I<:ObjectId,C} <: AbstractDict{I,Object}
    catalog::C
    locations::Dict{I,ObjectFamilyLocation}
    status_owners::IdDict{Base.RefValue{Nothing},I}
    layout_cache::Dict{Tuple{Tuple,Tuple},Any}
end

ObjectFamilyStore{I}() where {I<:ObjectId} = ObjectFamilyStore(
    OpenObjectFamilyCatalog(), Dict{I,ObjectFamilyLocation}(),
    IdDict{Base.RefValue{Nothing},I}(),
    Dict{Tuple{Tuple,Tuple},Any}(),
)
ObjectFamilyStore() = ObjectFamilyStore{ObjectId}()

Base.length(store::ObjectFamilyStore) = length(store.locations)
Base.haskey(store::ObjectFamilyStore, id) = haskey(store.locations, id)
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

@inline function _object_family_status_at(family::ObjectFamily{I,S}, row::Int) where {I,S}
    entry = family.rows[row]
    isnothing(entry) && throw(ArgumentError("The object family row is no longer registered."))
    return entry.status::S
end

# A finite union retains the concrete Status families across a runtime slot.
# Object counts, IDs and row positions are deliberately absent from the type.
@generated function _object_family_status_at(catalog::ClosedObjectFamilyCatalog{F}, location::ObjectFamilyLocation) where {F}
    # Extract the family parameters directly; rows also admit tombstones.
    status_types = [family.parameters[2] for family in fieldtypes(F)]
    result_type = Union{status_types...}
    branch = :(throw(BoundsError(catalog.families, location.family)))
    for slot in reverse(1:fieldcount(F))
        value = :(_object_family_status_at(getfield(catalog.families, $slot), location.row))
        branch = Expr(:if, :(location.family == $slot), value, branch)
    end
    return Expr(:(::), branch, result_type)
end

_object_family_status(store::ObjectFamilyStore, id) =
    _object_family_status_at(store.catalog, store.locations[id])

function _validate_object_family_status_owner!(store::ObjectFamilyStore, status, id)
    status isa Status || return nothing
    existing = get(store.status_owners, _status_identity(status), nothing)
    if !isnothing(existing) && existing != id
        throw(ArgumentError(
            "The same Status instance cannot be owned by model objects " *
            "`$(existing.value)` and `$(id.value)`. Give each Object its own Status instance.",
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
    slot, family = _object_family_for_write!(store.catalog, I, S)
    if !isnothing(previous)
        _forget_object_family_status!(store, _object_family_status_at(store.catalog, previous), id)
    end
    entry = ObjectFamilyRow(id, status)
    row = if !isnothing(previous) && previous.family == slot
        family.rows[previous.row] = entry
        previous.row
    else
        push!(family.rows, entry)
        isnothing(previous) || _clear_object_family_row!(store.catalog, previous)
        length(family.rows)
    end
    store.locations[id] = ObjectFamilyLocation(slot, row, object)
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
    _forget_object_family_status!(store, _object_family_status_at(store.catalog, location), id)
    _clear_object_family_row!(store.catalog, location)
    delete!(store.locations, id)
    return store
end

function Base.empty!(store::ObjectFamilyStore)
    empty!(store.locations)
    empty!(store.status_owners)
    empty!(store.layout_cache)
    for family in store.catalog.families
        empty!(family.rows)
    end
    return store
end

"""Close active families of a private model before execution; replace its old store."""
function _closed_object_family_store(store::ObjectFamilyStore)
    # Preparation may have replaced an object's status several times. Empty
    # historical schemas are not promises about future newborn construction.
    slots = sort!(unique([location.family for location in values(store.locations)]))
    families = Tuple(store.catalog.families[slot] for slot in slots)
    id_types = unique([typeof(family).parameters[1] for family in families])
    isempty(id_types) && throw(ArgumentError("A closed object family store requires an identity schema."))
    I = Union{id_types...}
    closed_slots = Dict(slot => index for (index, slot) in enumerate(slots))
    locations = Dict{I,ObjectFamilyLocation}(
        id => ObjectFamilyLocation(closed_slots[location.family], location.row, location.object)
        for (id, location) in store.locations
    )
    return ObjectFamilyStore(
        ClosedObjectFamilyCatalog(families), locations,
        IdDict{Base.RefValue{Nothing},I}(store.status_owners),
        copy(store.layout_cache),
    )
end
