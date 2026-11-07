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

function _retire_call_cohort_targets!(storage::RuntimeStorage, binding, batches; schema=OpenExecutionCohortSchema())
    store = storage.cohorts
    owner = _execution_call_owner(binding)
    current = Set((batch.application.id, target.object_id)
        for batch in batches for target in batch.targets)
    obsolete = Tuple{Symbol,ObjectId}[]
    for (candidate_owner, application_id, object_id) in keys(store.locations)
        isequal(owner, candidate_owner) || continue
        (application_id, object_id) in current || push!(obsolete, (application_id, object_id))
    end
    for (application_id, object_id) in obsolete
        location = cohort_location(store, application_id, object_id; owner)
        _with_execution_cohort_location(identity, schema, location, owner, application_id, object_id)
    end
    for (application_id, object_id) in obsolete
        remove_cohort_target!(store, application_id, object_id; owner, schema)
    end
    return nothing
end

_retire_call_cohort_targets!(::Nothing, binding, batches; schema=OpenExecutionCohortSchema()) = nothing

_execution_call_owner(binding) = (
    binding.application_id,
    binding.consumer_id,
    _compiled_call_name(binding),
    _compiled_call_mode(binding),
)
