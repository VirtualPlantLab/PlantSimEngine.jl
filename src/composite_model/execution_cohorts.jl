abstract type AbstractExecutionCohort end

mutable struct ExecutionCohort{T,I<:ObjectId,O} <: AbstractExecutionCohort
    owner::O
    application_id::Symbol
    rows::Vector{Union{Nothing,T}}
    indices::Dict{I,Int}

    ExecutionCohort{T,I,O}(owner::O, application_id::Symbol, rows::Vector{Union{Nothing,T}},
        indices::Dict{I,Int}) where {T,I<:ObjectId,O} =
        new{T,I,O}(owner, application_id, rows, indices)
end

struct ExecutionCohortLocation{C<:AbstractExecutionCohort}
    cohort::C
    row::Int
end

"""Persistent payload storage with identity/owner types independent of target types.

A closed registry admits the finite identity and canonical namespace types.
The ordinary store keeps arbitrary owners and identity types; per-application
schemas still own every concrete target/row witness.
"""
mutable struct ExecutionCohortStore{I<:ObjectId,O}
    cohorts::Dict{Tuple{O,Symbol,DataType},AbstractExecutionCohort}
    locations::Dict{Tuple{O,Symbol,I},ExecutionCohortLocation}
end

ExecutionCohortStore{I,O}() where {I<:ObjectId,O} = ExecutionCohortStore{I,O}(
    Dict{Tuple{O,Symbol,DataType},AbstractExecutionCohort}(),
    Dict{Tuple{O,Symbol,I},ExecutionCohortLocation}(),
)
ExecutionCohortStore() = ExecutionCohortStore{ObjectId,Any}()
ExecutionCohortStore(::ObjectFamilyStore{I,<:OpenObjectFamilyCatalog}) where {I} =
    ExecutionCohortStore()
ExecutionCohortStore(::ObjectFamilyStore{I,<:ClosedObjectFamilyCatalog}) where {I} =
    ExecutionCohortStore{I,Union{Nothing,Tuple{Symbol,I,Symbol,Symbol}}}()

_execution_store_owner_type(::Type{ExecutionCohortStore{I,O}}) where {I,O} = O
_execution_store_owner(::ExecutionCohortStore{I,O}, owner) where {I,O} = owner::O
_execution_store_object_id(::ExecutionCohortStore{I}, object_id) where {I} = ObjectId(object_id)::I

"""An ordered membership view over one application's concrete payload family."""
struct ExecutionCohortRows{T,C<:ExecutionCohort{T},S<:ExecutionCohortStore} <: AbstractVector{T}
    store::S
    cohort::C
    indices::Vector{Int}
end

ExecutionCohortRows{T}(store::S, cohort::C, indices::Vector{Int}) where {T,C<:ExecutionCohort{T},S<:ExecutionCohortStore} =
    ExecutionCohortRows{T,C,S}(store, cohort, indices)

# The finite witness belongs to one application/owner boundary, never to the
# runtime store. In particular Target -> RunContext -> RuntimeStorage does not
# acquire a recursive catalogue of Target types.
abstract type ExecutionCohortSchema end
struct OpenExecutionCohortSchema <: ExecutionCohortSchema end
struct ClosedExecutionCohortSchema{T<:Tuple} <: ExecutionCohortSchema end

function _closed_execution_cohort_schema(::Type{T}) where {T<:Tuple}
    isconcretetype(T) || throw(ArgumentError("A closed cohort schema needs a finite tuple of concrete target types."))
    iszero(fieldcount(T)) && throw(ArgumentError("An empty cohort needs an explicit future target type witness."))
    for Target in fieldtypes(T)
        isconcretetype(Target) && hasfield(Target, :object_id) ||
            throw(ArgumentError("A closed cohort schema requires concrete execution target types."))
        I = fieldtype(Target, :object_id)
        isconcretetype(I) && I <: ObjectId ||
            throw(ArgumentError("A closed cohort schema requires concrete object identity types."))
    end
    return ClosedExecutionCohortSchema{T}()
end

_execution_cohort_schema(::Nothing) = OpenExecutionCohortSchema()
_execution_cohort_schema(::AbstractVector) = OpenExecutionCohortSchema()

# Pure type-only recipe shared by current batches and an explicit future B.
# Generated wrappers keep each finite operation inside its concrete branch;
# the recipe never reads scientific values or invokes model declarations.
function _execution_cohort_schema_expression(B, require_witness)
    invalid = require_witness ?
        :(throw(ArgumentError("A closed cohort needs explicit concrete canonical batch witnesses."))) :
        :(OpenExecutionCohortSchema())
    isconcretetype(B) || return invalid
    targets = Any[]
    for Batch in fieldtypes(B)
        isconcretetype(Batch) && hasfield(Batch, :targets) || return invalid
        Rows = fieldtype(Batch, :targets)
        Rows <: ExecutionCohortRows || return invalid
        Target = eltype(Rows)
        Target in targets || push!(targets, Target)
    end
    isempty(targets) && return invalid
    T = Tuple{targets...}
    return :(_closed_execution_cohort_schema($T))
end

@generated function _execution_cohort_schema(batches::B) where {B<:Tuple}
    return _execution_cohort_schema_expression(B, false)
end

@generated function _execution_cohort_schema(::Type{B}) where {B<:Tuple}
    return _execution_cohort_schema_expression(B, true)
end

# Ordinary stores may use arbitrary owner values. Closed execution first
# admits the stored owner to the concrete expected type, before comparison.
@inline _execution_cohort_owner_matches(::OpenExecutionCohortSchema, stored, expected) = isequal(stored, expected)
@inline function _execution_cohort_owner_matches(::ClosedExecutionCohortSchema, stored, expected::O) where {O}
    return stored isa O && isequal(stored::O, expected)
end

function _check_execution_cohort_location(location, owner, application_id, object_id,
    schema=OpenExecutionCohortSchema())
    cohort = location.cohort
    _execution_cohort_owner_matches(schema, cohort.owner, owner) && cohort.application_id === application_id &&
        get(cohort.indices, object_id, 0) == location.row || throw(ArgumentError(
        "The execution location belongs to another owner, application or object.",
    ))
    return nothing
end

@inline _with_execution_cohort_location(f, schema::ExecutionCohortSchema, store::ExecutionCohortStore, ::Nothing, owner, application_id, object_id) = f(nothing)
@inline function _with_execution_cohort_location(f, ::OpenExecutionCohortSchema, store::ExecutionCohortStore, location::ExecutionCohortLocation, owner, application_id, object_id)
    _check_execution_cohort_location(location, owner, application_id, object_id)
    return f(location)
end

# Select the actual cohort before invoking the operation. An assertion after a
# dynamic read/clear would leave the abstract operation reachable by JuliaC.
@generated function _with_execution_cohort_location(f, schema::ClosedExecutionCohortSchema{T}, store::S, location::ExecutionCohortLocation, owner, application_id, object_id) where {T,S<:ExecutionCohortStore}
    branches = Expr[]
    O = _execution_store_owner_type(S)
    for Target in fieldtypes(T)
        I = fieldtype(Target, :object_id)
        L = ExecutionCohortLocation{ExecutionCohort{Target,I,O}}
        push!(branches, quote
            if location isa $L
                _check_execution_cohort_location(location, owner, application_id, object_id, schema)
                return f(location)
            end
        end)
    end
    return quote
        $(branches...)
        throw(ArgumentError("The existing execution payload is outside its prepared application schema."))
    end
end

@inline _with_execution_cohort_target(f, ::OpenExecutionCohortSchema, target) = f(target)
@generated function _with_execution_cohort_target(f, ::ClosedExecutionCohortSchema{T}, target) where {T}
    branches = [:(target isa $Target && return f(target)) for Target in fieldtypes(T)]
    return quote
        $(branches...)
        throw(ArgumentError("The new execution payload is outside its prepared application schema."))
    end
end

_execution_cohort_types(::OpenExecutionCohortSchema, ::ExecutionCohortStore) =
    (identity=ObjectId, target=Any, location=ExecutionCohortLocation, rows=ExecutionCohortRows)
@generated function _execution_cohort_types(::ClosedExecutionCohortSchema{T}, ::S) where {T,S<:ExecutionCohortStore}
    targets = collect(fieldtypes(T))
    O = _execution_store_owner_type(S)
    ids = unique([fieldtype(Target, :object_id) for Target in targets])
    locations = [ExecutionCohortLocation{ExecutionCohort{Target,fieldtype(Target,:object_id),O}} for Target in targets]
    rows = [ExecutionCohortRows{Target,ExecutionCohort{Target,fieldtype(Target,:object_id),O},S} for Target in targets]
    I, U, L, R = Union{ids...}, Union{targets...}, Union{locations...}, Union{rows...}
    return :((identity=$I, target=$U, location=$L, rows=$R))
end

@inline _with_execution_cohort_rows(f, ::OpenExecutionCohortSchema, store::ExecutionCohortStore, rows::ExecutionCohortRows) = f(rows)
@generated function _with_execution_cohort_rows(f, ::ClosedExecutionCohortSchema{T}, store::S, rows::ExecutionCohortRows) where {T,S<:ExecutionCohortStore}
    branches = Expr[]
    O = _execution_store_owner_type(S)
    for Target in fieldtypes(T)
        R = ExecutionCohortRows{Target,ExecutionCohort{Target,fieldtype(Target,:object_id),O},S}
        push!(branches, :(rows isa $R && return f(rows)))
    end
    return quote
        $(branches...)
        throw(ArgumentError("The execution run is outside its prepared application schema."))
    end
end

Base.IndexStyle(::Type{<:ExecutionCohortRows}) = IndexLinear()
Base.size(rows::ExecutionCohortRows) = size(rows.indices)
Base.length(rows::ExecutionCohortRows) = length(rows.indices)
Base.dataids(rows::ExecutionCohortRows) =
    (Base.dataids(rows.indices)..., Base.dataids(rows.cohort.rows)...)

Base.@propagate_inbounds function Base.getindex(rows::ExecutionCohortRows{T}, index::Int) where {T}
    @boundscheck checkbounds(rows.indices, index)
    slot = @inbounds rows.indices[index]
    target = @inbounds rows.cohort.rows[slot]
    isnothing(target) && throw(ArgumentError(
        "This execution target was removed or changed its payload schema.",
    ))
    return target::T
end

function _execution_cohort(store::ExecutionCohortStore{StoreI,O}, owner, application_id::Symbol, ::Type{T}) where {T,StoreI,O}
    isconcretetype(T) && T !== Nothing || throw(ArgumentError(
        "An execution cohort requires a concrete target payload type.",
    ))
    I = fieldtype(T, :object_id)
    I <: ObjectId && isconcretetype(I) || throw(ArgumentError(
        "An execution cohort requires a concrete ObjectId field in its target payload.",
    ))
    I <: StoreI || throw(ArgumentError("The execution target identity is outside the store schema."))
    owner = _execution_store_owner(store, owner)
    cohort = get!(store.cohorts, (owner, application_id, T)) do
        ExecutionCohort{T,I,O}(owner, application_id, Union{Nothing,T}[], Dict{I,Int}())
    end
    return cohort::ExecutionCohort{T,I,O}
end

function _clear_execution_cohort_row!(cohort::ExecutionCohort, row::Int)
    cohort.rows[row] = nothing
    return nothing
end

function _store_execution_cohort_target!(store::ExecutionCohortStore, cohort::ExecutionCohort{T}, target::T) where {T}
    object_id = _execution_store_object_id(store, target.object_id)
    owner = _execution_store_owner(store, cohort.owner)
    previous = cohort_location(store, cohort.application_id, object_id; owner)
    return _with_execution_cohort_location(OpenExecutionCohortSchema(), store, previous,
        owner, cohort.application_id, object_id) do location
        _store_execution_cohort_target!(store, cohort, target, location)
    end
end

function _store_execution_cohort_target!(
    store::ExecutionCohortStore, cohort::ExecutionCohort{T}, target::T, previous,
) where {T}
    object_id = _execution_store_object_id(store, target.object_id)
    owner = _execution_store_owner(store, cohort.owner)
    if !isnothing(previous)
        _check_execution_cohort_location(previous, owner, cohort.application_id, object_id)
        previous.cohort === cohort || _clear_execution_cohort_row!(previous.cohort, previous.row)
    end
    slot = get(cohort.indices, object_id, 0)
    if iszero(slot)
        push!(cohort.rows, target)
        slot = length(cohort.rows)
        cohort.indices[object_id] = slot
    else
        cohort.rows[slot] = target
    end
    store.locations[(owner, cohort.application_id, object_id)] = ExecutionCohortLocation(cohort, slot)
    return slot
end

# Appending a prepared homogeneous call batch cannot replace another family.
# Prove that before writing either payloads or membership. General replacement
# is handled by refresh_cohort_membership!, with the whole application witness.
function _check_execution_cohort_append(rows::ExecutionCohortRows{T}, target::T) where {T}
    location = cohort_location(rows.store, rows.cohort.application_id, target.object_id; owner=rows.cohort.owner)
    isnothing(location) && return nothing
    location.cohort === rows.cohort || throw(ArgumentError(
        "Appending an execution batch cannot replace another payload family; reconcile its application membership first.",
    ))
    return nothing
end
_check_execution_cohort_append(rows::AbstractVector, target) = nothing
function _append_execution_cohort_target!(rows::ExecutionCohortRows{T}, target::T) where {T}
    _check_execution_cohort_append(rows, target)
    # The old row is absent or in this exact concrete cohort; no erased cohort
    # clear remains reachable from the admitted pure-addition operation.
    object_id = target.object_id
    slot = get(rows.cohort.indices, object_id, 0)
    previous = iszero(slot) ? nothing : ExecutionCohortLocation(rows.cohort, slot)
    push!(rows.indices, _store_execution_cohort_target!(rows.store, rows.cohort, target, previous))
    return rows
end
_append_execution_cohort_target!(rows::AbstractVector, target) = push!(rows, target)

"""
    cohort_rows!(store, application_id, targets::AbstractVector{T}; owner=nothing)

Intern concrete target payloads and return a view in the supplied order. A
schedule can contain several views of the same cohort, including separate
runs around another payload family. Their membership vectors are independent.
`owner` separates execution contexts and cache leases, such as root scheduling
and distinct hard-call bindings, while their targets can share canonical status
references.
"""
function cohort_rows!(
    store::ExecutionCohortStore, application_id::Symbol, targets::AbstractVector{T}; owner=nothing,
) where {T}
    cohort = _execution_cohort(store, owner, application_id, T)
    rows = ExecutionCohortRows{T}(store, cohort, Int[])
    sizehint!(rows, length(targets))
    append!(rows, targets)
    return rows
end

function Base.setindex!(rows::ExecutionCohortRows{T}, target::T, index::Int) where {T}
    checkbounds(rows.indices, index)
    rows.indices[index] = _store_execution_cohort_target!(rows.store, rows.cohort, target)
    return rows
end

function Base.push!(rows::ExecutionCohortRows{T}, target::T) where {T}
    push!(rows.indices, _store_execution_cohort_target!(rows.store, rows.cohort, target))
    return rows
end

function Base.insert!(rows::ExecutionCohortRows{T}, index::Integer, target::T) where {T}
    1 <= index <= length(rows) + 1 || throw(BoundsError(rows, index))
    slot = _store_execution_cohort_target!(rows.store, rows.cohort, target)
    insert!(rows.indices, index, slot)
    return rows
end

function Base.append!(rows::ExecutionCohortRows{T}, targets::AbstractVector{T}) where {T}
    rows === targets && return append!(rows, copy(rows))
    for target in targets
        push!(rows, target)
    end
    return rows
end

function Base.deleteat!(rows::ExecutionCohortRows, indices)
    # Membership changes do not remove a payload used by another view. Its
    # execution owner removes it explicitly after all affected views refresh.
    deleteat!(rows.indices, indices)
    return rows
end

function Base.empty!(rows::ExecutionCohortRows)
    empty!(rows.indices)
    return rows
end

function Base.sizehint!(rows::ExecutionCohortRows, size::Integer)
    sizehint!(rows.indices, size)
    return rows
end

Base.copy(rows::ExecutionCohortRows{T}) where {T} =
    ExecutionCohortRows{T}(rows.store, rows.cohort, copy(rows.indices))

"""Reset one view's ordered membership while retaining the store's stable slots."""
function reset_cohort_rows!(rows::ExecutionCohortRows{T}, targets::AbstractVector{T}) where {T}
    rows === targets && return rows
    indices = Int[
        _store_execution_cohort_target!(rows.store, rows.cohort, target)
        for target in targets
    ]
    empty!(rows.indices)
    append!(rows.indices, indices)
    return rows
end

function cohort_location(store::ExecutionCohortStore, application_id::Symbol, object_id; owner=nothing)
    id = _execution_store_object_id(store, object_id)
    admitted_owner = _execution_store_owner(store, owner)
    return get(store.locations, (admitted_owner, application_id, id), nothing)
end

"""Remove an execution payload without renumbering any cohort's row slots."""
function remove_cohort_target!(store::ExecutionCohortStore, application_id::Symbol, object_id; owner=nothing, schema=OpenExecutionCohortSchema())
    object_id = _execution_store_object_id(store, object_id)
    owner = _execution_store_owner(store, owner)
    key = (owner, application_id, object_id)
    location = get(store.locations, key, nothing)
    isnothing(location) && return false
    return _with_execution_cohort_location(schema, store, location, owner, application_id, object_id) do admitted
        _clear_execution_cohort_row!(admitted.cohort, admitted.row)
        delete!(store.locations, key)
        return true
    end
end
