"""Mutable storage owned by one simulation, shared by scheduled and manual execution.

Stream values retain the existing dictionary interface. Execution cohorts share
that lifetime, rather than the model's reusable structural plan, so a fresh run
cannot replace another simulation's targets or call-context leases.
"""
struct RuntimeStorage{K,V,D<:AbstractDict{K,V}} <: AbstractDict{K,V}
    streams::D
    cohorts::ExecutionCohortStore
end

RuntimeStorage(streams::AbstractDict{K,V}) where {K,V} =
    RuntimeStorage{K,V,typeof(streams)}(streams, ExecutionCohortStore())

Base.length(storage::RuntimeStorage) = length(storage.streams)
Base.iterate(storage::RuntimeStorage, state...) = iterate(storage.streams, state...)
Base.getindex(storage::RuntimeStorage, key) = storage.streams[key]
Base.setindex!(storage::RuntimeStorage, value, key) = setindex!(storage.streams, value, key)
Base.haskey(storage::RuntimeStorage, key) = haskey(storage.streams, key)
Base.get(storage::RuntimeStorage, key, default) = get(storage.streams, key, default)
Base.get!(storage::RuntimeStorage, key, default) = get!(storage.streams, key, default)
Base.get!(default::Union{Function,Type}, storage::RuntimeStorage, key) =
    get!(default, storage.streams, key)
Base.delete!(storage::RuntimeStorage, key) = (delete!(storage.streams, key); storage)
Base.empty!(storage::RuntimeStorage) = (empty!(storage.streams); storage)
Base.empty(storage::RuntimeStorage) = RuntimeStorage(empty(storage.streams))
Base.copy(storage::RuntimeStorage) = RuntimeStorage(copy(storage.streams))
Base.keys(storage::RuntimeStorage) = keys(storage.streams)
Base.values(storage::RuntimeStorage) = values(storage.streams)
Base.pairs(storage::RuntimeStorage) = pairs(storage.streams)
Base.sizehint!(storage::RuntimeStorage, n::Integer) = (sizehint!(storage.streams, n); storage)

_execution_cohort_store(storage::RuntimeStorage) = storage.cohorts
_execution_cohort_store(::Nothing) = ExecutionCohortStore()

_insert_with_spare_capacity!(rows::ExecutionCohortRows, position::Integer, target) =
    insert!(rows, position, target)

# The caller identity and the callee identity schema are independent. The
# latter comes only from this already admitted application's target families.
@generated function _execution_retirement_key_type(::ClosedExecutionCohortSchema{T}) where {T}
    ids = unique(fieldtype(Target, :object_id) for Target in fieldtypes(T))
    Key = Tuple{Symbol,Union{ids...}}
    return :($Key)
end

@inline _with_execution_retirement_id(f, ::OpenExecutionCohortSchema, id) = f(id)
@generated function _with_execution_retirement_id(f, ::ClosedExecutionCohortSchema{T}, id) where {T}
    ids = unique(fieldtype(Target, :object_id) for Target in fieldtypes(T))
    branches = [:(id isa $I && return f(id::$I)) for I in ids]
    return quote
        $(branches...)
        throw(ArgumentError("The retired target identity is outside its prepared callee schema."))
    end
end

# Keep the ordinary representation and its equality behavior unchanged.
_call_retirement_current(::OpenExecutionCohortSchema, batches, batch_schema) =
    Set((batch.application.id, target.object_id) for batch in batches for target in batch.targets)
_call_retirement_obsolete(::OpenExecutionCohortSchema) = Tuple{Symbol,ObjectId}[]
_call_retirement_obsolete(schema::ClosedExecutionCohortSchema) = Vector{_execution_retirement_key_type(schema)}()

function _collect_call_retirement_current!(current, schema, batch)
    for raw_target in batch.targets
        _with_execution_cohort_target(schema, raw_target) do target
            # Selection of the concrete target precedes pair construction.
            push!(current, (batch.application.id, target.object_id))
        end
    end
    return nothing
end

function _call_retirement_current(schema::ClosedExecutionCohortSchema, batches, batch_schema)
    current = Set{_execution_retirement_key_type(schema)}()
    for batch in batches
        if isnothing(batch_schema)
            _collect_call_retirement_current!(current, schema, batch)
        else
            _with_execution_batch(batch_schema, batch) do actual
                _collect_call_retirement_current!(current, schema, actual)
            end
        end
    end
    return current
end

function _retire_call_cohort_targets!(storage::RuntimeStorage, binding, batches;
    schema=OpenExecutionCohortSchema(), batch_schema=nothing)
    store = storage.cohorts
    owner = _execution_call_owner(binding)
    current = _call_retirement_current(schema, batches, batch_schema)
    obsolete = _call_retirement_obsolete(schema)
    for (candidate_owner, application_id, object_id) in keys(store.locations)
        # Preserve the original argument order for arbitrary ordinary owners.
        matches = schema isa OpenExecutionCohortSchema ? isequal(owner, candidate_owner) :
            _execution_cohort_owner_matches(schema, candidate_owner, owner)
        matches || continue
        _with_execution_retirement_id(schema, object_id) do admitted_id
            key = (application_id, admitted_id)
            key in current || push!(obsolete, key)
        end
    end
    # Admit every existing payload/namespace before clearing the first row.
    for (application_id, object_id) in obsolete
        _with_execution_retirement_id(schema, object_id) do admitted_id
            location = cohort_location(store, application_id, admitted_id; owner)
            _with_execution_cohort_location(identity, schema, location, owner, application_id, admitted_id)
        end
    end
    for (application_id, object_id) in obsolete
        _with_execution_retirement_id(schema, object_id) do admitted_id
            remove_cohort_target!(store, application_id, admitted_id; owner, schema)
        end
    end
    return nothing
end

_retire_call_cohort_targets!(::Nothing, binding, batches;
    schema=OpenExecutionCohortSchema(), batch_schema=nothing) = nothing

_execution_call_owner(binding) = (
    binding.application_id,
    binding.consumer_id,
    _compiled_call_name(binding),
    _compiled_call_mode(binding),
)
