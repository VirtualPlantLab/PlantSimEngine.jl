module ExecutionGroupEpochLookup

using PlantSimEngine
const PSE = PlantSimEngine
const V1 = getfield(Main, :ExecutionGroupLookup)
isdefined(V1, :_try_epoch_lookup) || error("Load the epoch-ready v1 lookup factory")
export enable_execution_group_epoch_lookup!, execution_group_epoch_lookup_report

mutable struct EpochCounters
    epoch_attempts::Int
    epochs_validated::Int
    epochs_rejected::Int
    nonempty_epoch_hits::Int
    trusted_empty_returns::Int
    query_fallbacks::Int
    indexed_slots_checked::Int
    previous_groups_checked::Int
    application_references_snapshotted::Int
end
EpochCounters() = EpochCounters(ntuple(_ -> 0, fieldcount(EpochCounters))...)
const _enabled = WeakKeyDict{Any,EpochCounters}()

function enable_execution_group_epoch_lookup!(model::PSE.CompositeModel)
    V1.enable_execution_group_lookup!(model)
    get!(_enabled, model) do
        EpochCounters()
    end
    return model
end

struct EpochGroupLookup{L,A,S}
    fallback::L
    current_applications::A
    validated_applications::S
    counts::EpochCounters
end

# Read one scalar within its application's concrete method instance; never
# return or store an erased full plan/spec merely to obtain its slot.
@noinline _slot(application::PSE.CompiledModelApplication{P}) where {P} =
    getfield(getfield(application, :plan), :slot)

function _validated_epoch(previous, compiled, counts)
    groups = previous.groups
    index = previous.groups_by_application_slot
    current = compiled.applications
    groups isa Vector && index isa Vector && current isa Vector || return nothing
    length(index) == length(current) || return nothing
    # Snapshot references only. The queried application must still match both
    # this validated reference and the current canonical slot at lookup time.
    snapshot = copy(current)
    counts.application_references_snapshotted += length(snapshot)
    nonempty = 0
    for slot in eachindex(index)
        counts.indexed_slots_checked += 1
        group = index[slot]
        group === nothing && continue
        group isa PSE.CompiledApplicationExecutionGroup || return nothing
        group.application === snapshot[slot] || return nothing
        nonempty += 1
    end
    nonempty == length(groups) || return nothing
    # Verify list/index equality and uniqueness, rather than trusting a count
    # which could conceal a missing group plus an unrelated extra index entry.
    seen = falses(length(index))
    for group in groups
        counts.previous_groups_checked += 1
        group isa PSE.CompiledApplicationExecutionGroup || return nothing
        slot = _slot(group.application)
        slot isa Int && 1 <= slot <= length(index) || return nothing
        seen[slot] && return nothing
        index[slot] === group || return nothing
        seen[slot] = true
    end
    return snapshot
end

Base.@nospecializeinfer @noinline function V1._try_epoch_lookup(
    previous::PSE.CompiledExecutionPlan, compiled::PSE.CompiledCompositeModel,
    counts::V1.LookupCounters,
)
    @nospecialize previous compiled
    epoch_counts = get(_enabled, compiled.model, nothing)
    epoch_counts === nothing && return nothing
    epoch_counts.epoch_attempts += 1
    snapshot = _validated_epoch(previous, compiled, epoch_counts)
    if snapshot === nothing
        epoch_counts.epochs_rejected += 1
    else
        epoch_counts.epochs_validated += 1
    end
    fallback = V1.RefreshGroupLookup(previous.groups,
        previous.groups_by_application_slot, nothing, counts)
    return EpochGroupLookup(fallback, compiled.applications, snapshot, epoch_counts)
end

function _original_id_fallback!(lookup, application, in_range)
    fallback = lookup.fallback
    counts = fallback.counts
    counts.lookups += 1
    counts.slot_misses += 1
    if in_range
        counts.identity_misses += 1
    else
        counts.out_of_range_misses += 1
    end
    lookup.counts.query_fallbacks += 1
    if fallback.fallback_by_id === nothing
        fallback.fallback_by_id = V1._ordinary_groups(fallback.previous_groups)
        counts.dictionaries_built += 1
    end
    counts.dictionary_lookups += 1
    return get(fallback.fallback_by_id, application.id, nothing)
end

Base.@nospecializeinfer @noinline function PSE._previous_execution_group(
    lookup::EpochGroupLookup, application::PSE.CompiledModelApplication,
)
    @nospecialize application
    slot = _slot(application)
    if lookup.validated_applications === nothing
        in_range = slot isa Int && 1 <= slot <= length(lookup.fallback.groups_by_slot)
        return _original_id_fallback!(lookup, application, in_range)
    end
    in_range = slot isa Int && 1 <= slot <= length(lookup.validated_applications) &&
        slot <= length(lookup.current_applications) && slot <= length(lookup.fallback.groups_by_slot)
    canonical = in_range && lookup.current_applications[slot] === application &&
        lookup.validated_applications[slot] === application
    canonical || return _original_id_fallback!(lookup, application, in_range)
    group = lookup.fallback.groups_by_slot[slot]
    if group === nothing
        lookup.fallback.counts.lookups += 1
        lookup.counts.trusted_empty_returns += 1
        return nothing
    end
    # The same v1 identity proof has just succeeded, with no intervening query
    # or callback. Record its actual hit without repeating slot extraction.
    group.application === application || return _original_id_fallback!(lookup, application, true)
    lookup.counts.nonempty_epoch_hits += 1
    lookup.fallback.counts.lookups += 1
    lookup.fallback.counts.slot_hits += 1
    return group
end

Base.@nospecializeinfer @noinline function execution_group_epoch_lookup_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    names = fieldnames(EpochCounters)
    counters = NamedTuple{names}(Tuple(state === nothing ? 0 : getfield(state, name) for name in names))
    base = V1.execution_group_lookup_report(value)
    return (enabled=state !== nothing, counters, v1=base,
        lookup_accounting=(total=base.counters.lookups, nonempty_hits=base.counters.slot_hits,
            fallback_misses=base.counters.slot_misses, trusted_empty=counters.trusted_empty_returns),
        dictionary_builds_avoided=base.dictionary_builds_avoided,
        proof=:complete_unique_previous_group_index_and_current_application_identity,
        snapshot=:application_references_only_no_plan_spec_or_scientific_values_copied,
        fallback=:unchanged_v1_lookup_or_original_lazy_ID_map,
        cached_memberships=false, cached_scientific_values=false)
end

end # module
