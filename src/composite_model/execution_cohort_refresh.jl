"""Ordered schedule membership, separate from persistent execution payloads."""
struct ExecutionCohortMembership{S<:ExecutionCohortSchema,I<:ObjectId,L<:ExecutionCohortLocation,R<:ExecutionCohortRows,D<:ExecutionCohortStore,O}
    store::D
    owner::O
    application_id::Symbol
    schema::S
    object_ids::Vector{I}
    locations::Vector{L}
    runs::Vector{R}
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

function _shift_execution_run_starts!(starts::Vector{Int}, first_run, delta)
    for index in first_run:lastindex(starts)
        starts[index] += delta
    end
    return nothing
end

function _split_execution_run_indices!(indices::Vector{Int}, local_index)
    right = indices[local_index:end]
    sizehint!(right, length(right) + max(16, length(right) ÷ 4))
    resize!(indices, local_index - 1)
    return right
end

function _execution_membership_location_has_cohort(membership, position, cohort)
    object_id = membership.object_ids[position]
    return _with_execution_cohort_location(membership.schema, membership.store, membership.locations[position],
        membership.owner, membership.application_id, object_id) do location
        location.cohort === cohort
    end
end

function _execution_membership_run_has_cohort(membership, index, cohort)
    return _with_execution_membership_run(membership, index) do rows
        rows.cohort === cohort
    end
end

function _insert_execution_membership_row!(membership, position, object_id, location)
    count = length(membership.object_ids)
    runs = membership.runs
    starts = membership.run_starts
    if isempty(runs) || position == count + 1
        if !isempty(runs) && _execution_membership_run_has_cohort(membership, length(runs), location.cohort)
            _with_execution_membership_run(membership, length(runs)) do rows
                push!(rows.indices, location.row)
            end
        else
            push!(runs, _execution_cohort_rows(membership.store, location.cohort, Int[location.row]))
            push!(starts, position)
        end
    else
        run_index = searchsortedlast(starts, position)
        indices, same_cohort = _with_execution_membership_run(membership, run_index) do rows
            (rows.indices, rows.cohort === location.cohort)
        end
        local_index = position - starts[run_index] + 1
        if same_cohort
            insert!(indices, local_index, location.row)
            _shift_execution_run_starts!(starts, run_index + 1, 1)
        elseif local_index == 1 && run_index > 1 &&
               _execution_membership_run_has_cohort(membership, run_index - 1, location.cohort)
            _with_execution_membership_run(membership, run_index - 1) do previous_rows
                push!(previous_rows.indices, location.row)
            end
            _shift_execution_run_starts!(starts, run_index, 1)
        elseif local_index == 1
            insert!(runs, run_index, _execution_cohort_rows(membership.store, location.cohort, Int[location.row]))
            insert!(starts, run_index, position)
            _shift_execution_run_starts!(starts, run_index + 1, 1)
        else
            # Split only membership indices; payloads and scientific references
            # stay in their original cohorts.
            right_indices = _split_execution_run_indices!(indices, local_index)
            store = membership.store
            insert!(runs, run_index + 1, _execution_cohort_rows(store, location.cohort, Int[location.row]))
            insert!(starts, run_index + 1, position)
            _with_execution_membership_run(membership, run_index) do rows
                insert!(runs, run_index + 2, _execution_cohort_rows(store, rows.cohort, right_indices))
            end
            insert!(starts, run_index + 2, position + 1)
            _shift_execution_run_starts!(starts, run_index + 3, 1)
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
    run_empty = _with_execution_membership_run(membership, run_index) do rows
        deleteat!(rows.indices, position - starts[run_index] + 1)
        isempty(rows.indices)
    end
    _shift_execution_run_starts!(starts, run_index + 1, -1)
    if run_empty
        deleteat!(runs, run_index)
        deleteat!(starts, run_index)
        if run_index > 1 && run_index <= length(runs)
            merged = _with_execution_membership_run(membership, run_index - 1) do left
                _with_execution_membership_run(membership, run_index) do right
                    left.cohort === right.cohort || return false
                    append!(left.indices, right.indices)
                    return true
                end
            end
            if merged
                deleteat!(runs, run_index)
                deleteat!(starts, run_index)
            end
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

function _new_execution_cohort_membership(store, owner, application_id, count, schema=OpenExecutionCohortSchema())
    owner = _execution_store_owner(store, owner)
    types = _execution_cohort_types(schema, store)
    ids = Vector{types.identity}()
    locations = Vector{types.location}()
    capacity = count + max(16, count ÷ 4)
    sizehint!(ids, capacity)
    sizehint!(locations, capacity)
    return ExecutionCohortMembership(
        store, owner, application_id, schema, ids, locations, Vector{types.rows}(), Int[],
    )
end

# Host-only schema closure, before a plan's container types are fixed. Metadata
# vectors become finite unions; all cohort payloads, references and run views
# retain identity. No models, defaults, samplers or callbacks are invoked.
function _close_execution_cohort_membership(previous::ExecutionCohortMembership, schema::ClosedExecutionCohortSchema)
    types = _execution_cohort_types(schema, previous.store)
    for (object_id, location) in zip(previous.object_ids, previous.locations)
        object_id isa types.identity || throw(ArgumentError("An object identity is outside the prepared cohort schema."))
        _with_execution_cohort_location(identity, schema, previous.store, location, previous.owner, previous.application_id, object_id)
    end
    for rows in previous.runs
        _with_execution_cohort_rows(schema, previous.store, rows) do admitted
            _check_execution_cohort_rows_owner(admitted, previous.store, previous.owner, previous.application_id, schema)
        end
    end
    typeof(previous.schema) === typeof(schema) && return previous
    membership = _new_execution_cohort_membership(previous.store, previous.owner,
        previous.application_id, length(previous.object_ids), schema)
    append!(membership.object_ids, previous.object_ids)
    append!(membership.locations, previous.locations)
    # Close once with the same spare-capacity policy as initial preparation.
    # Exact-length copies would force an O(n) resize on the first real birth.
    run_count = length(previous.runs)
    run_capacity = run_count + max(16, run_count ÷ 4)
    sizehint!(membership.runs, run_capacity)
    sizehint!(membership.run_starts, run_capacity)
    append!(membership.runs, previous.runs)
    append!(membership.run_starts, previous.run_starts)
    return membership
end

function _check_execution_cohort_rows_owner(rows, store, owner, application_id, schema)
    rows.store === store && _execution_cohort_owner_matches(schema, rows.cohort.owner, owner) &&
        rows.cohort.application_id === application_id || throw(ArgumentError(
        "The execution run belongs to another store, owner or application.",
    ))
    return nothing
end

@inline function _with_execution_membership_run(f, membership, index)
    return _with_execution_cohort_rows(membership.schema, membership.store, membership.runs[index]) do rows
        _check_execution_cohort_rows_owner(rows, membership.store, membership.owner, membership.application_id, membership.schema)
        f(rows)
    end
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
    schema=isnothing(previous) ? OpenExecutionCohortSchema() : previous.schema,
)
    owner = _execution_store_owner(store, owner)
    if !isnothing(previous)
        previous.store === store && previous.application_id === application_id &&
            isequal(previous.owner, owner) || throw(ArgumentError(
            "Previous execution membership belongs to a different store or execution owner.",
        ))
        typeof(schema) === typeof(previous.schema) || throw(ArgumentError(
            "Close the application membership before entering its prepared refresh boundary.",
        ))
    end
    types = _execution_cohort_types(schema, store)
    staged_targets = Vector{Tuple{types.identity,types.target}}()
    removed_ids = Vector{types.identity}()
    checked_ids = isnothing(previous) || isnothing(changed_ids) ? current_ids : changed_ids
    for object_id in checked_ids
        object_id isa types.identity || throw(ArgumentError("An object identity is outside the prepared cohort schema."))
        location = cohort_location(store, application_id, object_id; owner)
        is_current = isnothing(previous) || isnothing(changed_ids) ||
                     first(_sorted_object_id_position(current_ids, object_id))
        _with_execution_cohort_location(schema, store, location, owner, application_id, object_id) do admitted
            if !is_current
                push!(removed_ids, object_id)
                return nothing
            end
            previous_target = isnothing(admitted) ? nothing : _execution_cohort_target(admitted)
            target = build_target(object_id, previous_target)
            _with_execution_cohort_target(schema, target) do accepted
                _check_execution_cohort_target(accepted, object_id)
                accepted === previous_target || push!(staged_targets, (object_id, accepted))
                return nothing
            end
            return nothing
        end
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

    # Discovering removals may bypass checked_ids. Validate every old location
    # and every run before the first clear/splice, including a fully empty result.
    for object_id in removed_ids
        location = cohort_location(store, application_id, object_id; owner)
        _with_execution_cohort_location(identity, schema, store, location, owner, application_id, object_id)
    end
    membership = isnothing(previous) ?
                 _new_execution_cohort_membership(store, owner, application_id, length(current_ids), schema) :
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
        remove_cohort_target!(store, application_id, object_id; owner, schema)
    end
    for (object_id, target) in staged_targets
        changed = _with_execution_cohort_target(schema, target) do accepted
            cohort = _execution_cohort(store, owner, application_id, typeof(accepted))
            old_location = cohort_location(store, application_id, object_id; owner)
            return _with_execution_cohort_location(schema, store, old_location, owner, application_id, object_id) do admitted
                slot = _store_execution_cohort_target!(store, cohort, accepted, admitted)
                isnothing(previous) && return false
                location = ExecutionCohortLocation(cohort, slot)
                found, position = if isempty(membership.object_ids) ||
                                     _object_id_isless(last(membership.object_ids), object_id)
                    (false, length(membership.object_ids) + 1)
                else
                    _sorted_object_id_position(membership.object_ids, object_id)
                end
                if !found
                    _insert_execution_membership_row!(membership, position, object_id, location)
                    return true
                elseif !_execution_membership_location_has_cohort(membership, position, location.cohort)
                    _delete_execution_membership_row!(membership, position)
                    _insert_execution_membership_row!(membership, position, object_id, location)
                    return true
                else
                    membership.locations[position] = location
                    return false
                end
            end
        end
        membership_changed |= changed
    end
    if isnothing(previous)
        for object_id in current_ids
            location = cohort_location(store, application_id, object_id; owner)
            _with_execution_cohort_location(schema, store, location, owner, application_id, object_id) do admitted
                _insert_execution_membership_row!(
                    membership, length(membership.object_ids) + 1, object_id, admitted,
                )
            end
        end
        for index in eachindex(membership.runs)
            _with_execution_membership_run(membership, index) do rows
                count = length(rows)
                sizehint!(rows.indices, count + max(16, count ÷ 4))
                family_count = length(rows.cohort.rows)
                sizehint!(rows.cohort.rows, family_count + max(16, family_count ÷ 4))
            end
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
