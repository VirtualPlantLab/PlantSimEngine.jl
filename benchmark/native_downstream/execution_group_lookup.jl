module ExecutionGroupLookup

using PlantSimEngine
const PSE = PlantSimEngine
for name in (:_previous_execution_groups_for_refresh, :_previous_execution_group)
    isdefined(PSE, name) || error("Execution group lookup requires the optional refresh hooks")
end
export enable_execution_group_lookup!, execution_group_lookup_report

mutable struct LookupCounters
    refresh_lookups_created::Int
    lookups::Int
    slot_hits::Int
    slot_misses::Int
    absent_slot_misses::Int
    out_of_range_misses::Int
    identity_misses::Int
    dictionaries_built::Int
    dictionary_lookups::Int
end
LookupCounters() = LookupCounters(ntuple(_ -> 0, fieldcount(LookupCounters))...)
const _enabled = WeakKeyDict{Any,LookupCounters}()

"""Select guarded slot lookup for subsequent execution-plan refreshes.

This policy changes only lookup of the previous group. It leaves the current
application, target construction, reuse checks, scheduling and refresh decisions
to the ordinary executor. It can be enabled on an existing model because no
logical compilation or scientific storage representation is changed.
"""
function enable_execution_group_lookup!(model::PSE.CompositeModel)
    get!(_enabled, model) do
        LookupCounters()
    end
    return model
end

mutable struct RefreshGroupLookup{G,I}
    previous_groups::G
    groups_by_slot::I
    fallback_by_id::Any
    counts::LookupCounters
end

# Keep the ordinary generator and its inferred Dict type exactly as in core.
_ordinary_groups(groups) = Dict(group.application.id => group for group in groups)

_try_epoch_lookup(previous, compiled, counts) = nothing

Base.@nospecializeinfer @noinline function PSE._previous_execution_groups_for_refresh(
    previous::PSE.CompiledExecutionPlan, compiled::PSE.CompiledCompositeModel,
)
    @nospecialize previous compiled
    counts = get(_enabled, compiled.model, nothing)
    counts === nothing && return _ordinary_groups(previous.groups)
    counts.refresh_lookups_created += 1
    epoch = _try_epoch_lookup(previous, compiled, counts)
    epoch === nothing || return epoch
    return RefreshGroupLookup(previous.groups, previous.groups_by_application_slot,
        nothing, counts)
end

Base.@nospecializeinfer @noinline function PSE._previous_execution_group(
    lookup::RefreshGroupLookup, application::PSE.CompiledModelApplication,
)
    @nospecialize application
    counts = lookup.counts
    counts.lookups += 1
    slot = application.slot
    if slot isa Int && firstindex(lookup.groups_by_slot) <= slot <= lastindex(lookup.groups_by_slot)
        group = lookup.groups_by_slot[slot]
        if group === nothing
            counts.absent_slot_misses += 1
        elseif group.application === application
            counts.slot_hits += 1
            return group
        else
            counts.identity_misses += 1
        end
    else
        counts.out_of_range_misses += 1
    end
    counts.slot_misses += 1
    if lookup.fallback_by_id === nothing
        lookup.fallback_by_id = _ordinary_groups(lookup.previous_groups)
        counts.dictionaries_built += 1
    end
    counts.dictionary_lookups += 1
    return get(lookup.fallback_by_id, application.id, nothing)
end

Base.@nospecializeinfer @noinline function execution_group_lookup_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    counts = get(_enabled, model, nothing)
    names = fieldnames(LookupCounters)
    counters = NamedTuple{names}(Tuple(counts === nothing ? 0 : getfield(counts, name) for name in names))
    return (enabled=counts !== nothing, counters,
        dictionary_builds_avoided=counters.refresh_lookups_created-counters.dictionaries_built,
        proof=:in_range_slot_and_exact_current_application_identity,
        fallback=:original_ID_dictionary_built_lazily_once_per_refresh,
        scope=:previous_group_selection_only,
        cached_memberships=false, cached_scientific_values=false,
        interpretation=:actual_slot_hits_and_original_dictionary_fallback_operations)
end

end # module
