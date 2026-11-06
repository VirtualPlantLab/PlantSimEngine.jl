"""Ordered schedule membership, separate from persistent execution payloads."""
struct ExecutionCohortMembership
    store::ExecutionCohortStore
    owner::Any
    application_id::Symbol
    object_ids::Vector{ObjectId}
    locations::Vector{ExecutionCohortLocation}
    runs::Vector{ExecutionCohortRows}
    run_starts::Vector{Int}
end

function _execution_cohort_target(cohort::ExecutionCohort{T}, row::Int) where {T}
    target = cohort.rows[row]
    isnothing(target) && throw(ArgumentError(
        "An execution membership refers to a removed or replaced payload schema.",
    ))
    return target::T
end

_execution_cohort_target(location::ExecutionCohortLocation) =
    _execution_cohort_target(location.cohort, location.row)

function _execution_cohort_rows(
    store::ExecutionCohortStore, cohort::ExecutionCohort{T}, indices::Vector{Int},
) where {T}
    return ExecutionCohortRows{T}(store, cohort, indices)
end

function _shift_execution_run_starts!(membership, first_run, delta)
    for index in first_run:lastindex(membership.run_starts)
        membership.run_starts[index] += delta
    end
    return nothing
end

function _insert_execution_membership_row!(membership, position, object_id, location)
    count = length(membership.object_ids)
    runs = membership.runs
    starts = membership.run_starts
    if isempty(runs) || position == count + 1
        if !isempty(runs) && last(runs).cohort === location.cohort
            push!(last(runs).indices, location.row)
        else
            push!(runs, _execution_cohort_rows(membership.store, location.cohort, Int[location.row]))
            push!(starts, position)
        end
    else
        run_index = searchsortedlast(starts, position)
        rows = runs[run_index]
        local_index = position - starts[run_index] + 1
        if rows.cohort === location.cohort
            insert!(rows.indices, local_index, location.row)
            _shift_execution_run_starts!(membership, run_index + 1, 1)
        elseif local_index == 1 && run_index > 1 &&
               runs[run_index - 1].cohort === location.cohort
            push!(runs[run_index - 1].indices, location.row)
            _shift_execution_run_starts!(membership, run_index, 1)
        elseif local_index == 1
            insert!(runs, run_index, _execution_cohort_rows(
                membership.store, location.cohort, Int[location.row],
            ))
            insert!(starts, run_index, position)
            _shift_execution_run_starts!(membership, run_index + 1, 1)
        else
            # A new family inside a run needs one additional view of its right
            # part. Other runs and all scientific payloads retain identity.
            right_indices = rows.indices[local_index:end]
            sizehint!(right_indices, length(right_indices) + max(16, length(right_indices) ÷ 4))
            right = _execution_cohort_rows(membership.store, rows.cohort, right_indices)
            resize!(rows.indices, local_index - 1)
            insert!(runs, run_index + 1, _execution_cohort_rows(
                membership.store, location.cohort, Int[location.row],
            ))
            insert!(starts, run_index + 1, position)
            insert!(runs, run_index + 2, right)
            insert!(starts, run_index + 2, position + 1)
            _shift_execution_run_starts!(membership, run_index + 3, 1)
        end
    end
    insert!(membership.object_ids, position, object_id)
    insert!(membership.locations, position, location)
    return nothing
end

function _delete_execution_membership_row!(membership, position)
    runs = membership.runs
    starts = membership.run_starts
    run_index = searchsortedlast(starts, position)
    rows = runs[run_index]
    deleteat!(rows.indices, position - starts[run_index] + 1)
    _shift_execution_run_starts!(membership, run_index + 1, -1)
    if isempty(rows.indices)
        deleteat!(runs, run_index)
        deleteat!(starts, run_index)
        if run_index > 1 && run_index <= length(runs) &&
           runs[run_index - 1].cohort === runs[run_index].cohort
            append!(runs[run_index - 1].indices, runs[run_index].indices)
            deleteat!(runs, run_index)
            deleteat!(starts, run_index)
        end
    end
    deleteat!(membership.object_ids, position)
    deleteat!(membership.locations, position)
    return nothing
end

function _check_execution_cohort_target(target, object_id)
    T = typeof(target)
    hasfield(T, :object_id) || throw(ArgumentError(
        "An execution target requires an object_id field.",
    ))
    I = fieldtype(T, :object_id)
    I <: ObjectId && isconcretetype(I) || throw(ArgumentError(
        "An execution target requires a concrete ObjectId field.",
    ))
    target.object_id == object_id || throw(ArgumentError(
        "An execution target's identity must match its membership identity.",
    ))
    return nothing
end

function _new_execution_cohort_membership(store, owner, application_id, count)
    ids = ObjectId[]
    locations = ExecutionCohortLocation[]
    # Reserve initial spare capacity once. Ordinary push!/insert! growth then
    # remains amortized; requesting exactly one spare slot on every refresh
    # would itself force repeated allocations proportional to live object count.
    capacity = count + max(16, count ÷ 4)
    sizehint!(ids, capacity)
    sizehint!(locations, capacity)
    return ExecutionCohortMembership(
        store, owner, application_id, ids, locations, ExecutionCohortRows[], Int[],
    )
end

"""
    refresh_cohort_membership!(build_target, store, application_id, current_ids,
                               changed_ids; previous=nothing, owner=nothing)

Refresh one execution owner's persistent ordered membership. `current_ids` and
`changed_ids` use the compiler's canonical, unique object order. A supplied
change set covers all added, removed, and semantically changed target identities.
A `nothing` change set validates every current target and discovers removals by
merging identities. Initial construction also validates every current target.

`build_target(object_id, previous_target)` returns the existing target when
reusable, including after a valid in-place call-cache update, or a newly compiled
target. All constructions finish before this helper changes payload storage or
membership; the callback itself keeps its existing mutation/failure contract.

Changed owners are looked up independently of batch count. Membership arrays
and typed runs are spliced in place. Appending a same-schema target touches no
surviving membership entries; insertion/removal shifts only affected metadata.
A new family inside a run splits that run, preserving global object/RNG order.
No retained target, status, context, or binding cache is cloned.
"""
function refresh_cohort_membership!(
    build_target,
    store::ExecutionCohortStore,
    application_id::Symbol,
    current_ids,
    changed_ids;
    previous::Union{Nothing,ExecutionCohortMembership}=nothing,
    owner=nothing,
)
    if !isnothing(previous)
        previous.store === store && previous.application_id === application_id &&
            isequal(previous.owner, owner) || throw(ArgumentError(
            "Previous execution membership belongs to a different store or execution owner.",
        ))
    end
    staged_targets = Tuple{ObjectId,Any}[]
    removed_ids = ObjectId[]
    checked_ids = isnothing(previous) || isnothing(changed_ids) ? current_ids : changed_ids
    for object_id in checked_ids
        location = cohort_location(store, application_id, object_id; owner)
        is_current = isnothing(previous) || isnothing(changed_ids) ||
                     first(_sorted_object_id_position(current_ids, object_id))
        if !is_current
            push!(removed_ids, object_id)
            continue
        end
        previous_target = isnothing(location) ? nothing : _execution_cohort_target(location)
        target = build_target(object_id, previous_target)
        _check_execution_cohort_target(target, object_id)
        target === previous_target || push!(staged_targets, (object_id, target))
    end
    if !isnothing(previous) && isnothing(changed_ids)
        current_index = firstindex(current_ids)
        for object_id in previous.object_ids
            while current_index <= lastindex(current_ids) &&
                  _object_id_isless(current_ids[current_index], object_id)
                current_index += 1
            end
            if current_index > lastindex(current_ids) || current_ids[current_index] != object_id
                push!(removed_ids, object_id)
            end
        end
    end

    membership = isnothing(previous) ?
                 _new_execution_cohort_membership(store, owner, application_id, length(current_ids)) :
                 previous
    membership_changed = isnothing(previous)
    targets_removed = 0
    # Every fallible target construction has completed before the first splice.
    for object_id in removed_ids
        found, position = _sorted_object_id_position(membership.object_ids, object_id)
        if found
            _delete_execution_membership_row!(membership, position)
            targets_removed += 1
            membership_changed = true
        end
        remove_cohort_target!(store, application_id, object_id; owner)
    end
    for (object_id, target) in staged_targets
        cohort = _execution_cohort(store, owner, application_id, typeof(target))
        _store_execution_cohort_target!(store, cohort, target)
        isnothing(previous) && continue
        location = cohort_location(store, application_id, object_id; owner)
        found, position = if isempty(membership.object_ids) ||
                             _object_id_isless(last(membership.object_ids), object_id)
            (false, length(membership.object_ids) + 1)
        else
            _sorted_object_id_position(membership.object_ids, object_id)
        end
        if !found
            _insert_execution_membership_row!(membership, position, object_id, location)
            membership_changed = true
        elseif membership.locations[position].cohort !== location.cohort
            _delete_execution_membership_row!(membership, position)
            _insert_execution_membership_row!(membership, position, object_id, location)
            membership_changed = true
        else
            membership.locations[position] = location
        end
    end
    if isnothing(previous)
        for object_id in current_ids
            location = cohort_location(store, application_id, object_id; owner)
            _insert_execution_membership_row!(
                membership, length(membership.object_ids) + 1, object_id, location,
            )
        end
        for rows in membership.runs
            count = length(rows)
            sizehint!(rows.indices, count + max(16, count ÷ 4))
            family_count = length(rows.cohort.rows)
            sizehint!(rows.cohort.rows, family_count + max(16, family_count ÷ 4))
        end
    end
    return (
        membership=membership,
        targets_constructed=length(staged_targets),
        targets_reused=length(current_ids) - length(staged_targets),
        targets_removed=targets_removed,
        membership_changed=membership_changed,
    )
end
