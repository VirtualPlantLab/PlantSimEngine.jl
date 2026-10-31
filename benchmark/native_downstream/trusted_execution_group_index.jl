module TrustedExecutionGroupIndex

using PlantSimEngine
const PSE = PlantSimEngine
const Epoch = getfield(Main, :ExecutionGroupEpochLookup)
for name in (:_begin_execution_group_index, :_observe_execution_group_index!,
    :_finish_execution_group_index!, :_try_trusted_execution_group_lookup)
    isdefined(PSE, name) || error("Trusted index construction requires the canonical core hooks")
end
export enable_trusted_execution_group_index!, trusted_execution_group_index_report

mutable struct TrustedCounters
    construction_begins::Int
    groups_observed::Int
    indices_certified::Int
    indices_rejected::Int
    logical_stamps_built::Int
    application_refs_recorded::Int
    stamp_slots_checked::Int
    duplicate_slots_rejected::Int
    refresh_attempts::Int
    certificate_hits::Int
    certificate_misses::Int
    lookup_attempts::Int
    trusted_group_hits::Int
    trusted_empty_returns::Int
    fallback_queries::Int
    fallback_lookups_created::Int
    index_registry_evictions::Int
    epoch_registry_evictions::Int
end
TrustedCounters()=TrustedCounters(ntuple(_->0,fieldcount(TrustedCounters))...)
const _enabled=WeakKeyDict{Any,TrustedCounters}()

struct LogicalStamp
    key::WeakRef
    model::WeakRef
    applications::Vector{WeakRef}
end
struct IndexCertificate
    key::WeakRef
    groups::WeakRef
    stamp::LogicalStamp
    application_count::Int
    group_count::Int
end

# Mutable vector keys must use object identity, never content hashing. Values
# hold weak key references, so bounded eviction and objectid reuse are safe.
mutable struct IdentityFIFO{V}
    entries::Dict{UInt,V}
    fifo::Vector{UInt}
    cursor::Int
    capacity::Int
    mutex::ReentrantLock
end
IdentityFIFO{V}(capacity::Int) where {V}=IdentityFIFO(Dict{UInt,V}(),UInt[],1,capacity,ReentrantLock())
const _indices=IdentityFIFO{IndexCertificate}(256)
const _epochs=IdentityFIFO{LogicalStamp}(64)
function _get(cache,key)
    lock(cache.mutex) do
        value=get(cache.entries,objectid(key),nothing)
        return value!==nothing && value.key.value===key ? value : nothing
    end
end
function _put!(cache,key,value)
    lock(cache.mutex) do
        identity=objectid(key)
        evicted=false
        if !haskey(cache.entries,identity)
            if length(cache.fifo)<cache.capacity
                push!(cache.fifo,identity)
            else
                old=cache.fifo[cache.cursor]
                evicted=pop!(cache.entries,old,nothing)!==nothing
                cache.fifo[cache.cursor]=identity
                cache.cursor=mod1(cache.cursor+1,cache.capacity)
            end
        end
        cache.entries[identity]=value
        return evicted
    end
end

# Lifecycle refresh creates new scene shells but shares this mutable dictionary
# from the logical scenario plan. Full compilation creates a new dictionary.
@noinline function _logical_epoch(compiled::PSE.CompiledCompositeModel{SC,SP}) where {SC,SP}
    plan=getfield(compiled,:scenario_plan)
    candidates=getfield(plan,:application_target_candidates)
    return getfield(candidates,:application_target_templates)
end
@noinline function _application_count(compiled::PSE.CompiledCompositeModel{SC,SP,AP}) where {SC,SP,AP}
    return length(getfield(compiled,:applications))
end
@noinline function _application_at(compiled::PSE.CompiledCompositeModel{SC,SP,AP},slot::Int) where {SC,SP,AP}
    applications=getfield(compiled,:applications)
    return applications isa Tuple ? getfield(applications,slot) : applications[slot]
end
@noinline _slot(application::PSE.CompiledModelApplication{P}) where {P}=
    getfield(getfield(application,:plan),:slot)

function enable_trusted_execution_group_index!(model::PSE.CompositeModel)
    # Only a missed/untrusted certificate uses the established conservative
    # epoch/original-ID path; its work stays in that separate report namespace.
    Epoch.enable_execution_group_epoch_lookup!(model)
    get!(_enabled,model) do
        TrustedCounters()
    end
    return model
end

function _stamp!(compiled,counts)
    token=_logical_epoch(compiled)
    token isa Dict || return nothing
    old=_get(_epochs,token)
    count=_application_count(compiled)
    if old!==nothing && old.model.value===compiled.model && length(old.applications)==count
        return old
    end
    references=WeakRef[]
    sizehint!(references,count)
    for slot in 1:count
        counts.stamp_slots_checked+=1
        application=_application_at(compiled,slot)
        application isa PSE.CompiledModelApplication && _slot(application)==slot || return nothing
        push!(references,WeakRef(application))
        counts.application_refs_recorded+=1
    end
    stamp=LogicalStamp(WeakRef(token),WeakRef(compiled.model),references)
    counts.logical_stamps_built+=1
    _put!(_epochs,token,stamp) && (counts.epoch_registry_evictions+=1)
    return stamp
end

mutable struct ConstructionProof
    compiled::Any
    stamp::Union{Nothing,LogicalStamp}
    counts::TrustedCounters
    expected_groups::Int
    observed_groups::Int
    valid::Bool
end
Base.@nospecializeinfer @noinline function PSE._begin_execution_group_index(
    compiled::PSE.CompiledCompositeModel,groups,index,
)
    @nospecialize compiled groups index
    counts=get(_enabled,compiled.model,nothing)
    counts===nothing && return nothing
    counts.construction_begins+=1
    stamp=_stamp!(compiled,counts)
    valid=groups isa Vector && index isa Vector && stamp!==nothing &&
        length(index)==_application_count(compiled)
    return ConstructionProof(compiled,stamp,counts,length(groups),0,valid)
end
function PSE._observe_execution_group_index!(proof::ConstructionProof,index,group,slot)
    proof.counts.groups_observed+=1
    proof.observed_groups+=1
    proof.valid || return nothing
    if !(slot isa Int && 1<=slot<=length(index))
        proof.valid=false
        return nothing
    end
    if index[slot]!==nothing
        proof.counts.duplicate_slots_rejected+=1
        proof.valid=false
        return nothing
    end
    proof.valid=group isa PSE.CompiledApplicationExecutionGroup &&
        proof.stamp.applications[slot].value===group.application &&
        _application_at(proof.compiled,slot)===group.application
    return nothing
end
function PSE._finish_execution_group_index!(proof::ConstructionProof,index,groups,compiled)
    valid=proof.valid && compiled===proof.compiled &&
        proof.observed_groups==proof.expected_groups==length(groups) &&
        length(index)==length(proof.stamp.applications) &&
        proof.stamp.key.value===_logical_epoch(compiled) &&
        proof.stamp.model.value===compiled.model
    if valid
        certificate=IndexCertificate(WeakRef(index),WeakRef(groups),proof.stamp,
            length(index),length(groups))
        proof.counts.indices_certified+=1
        _put!(_indices,index,certificate) && (proof.counts.index_registry_evictions+=1)
    else
        proof.counts.indices_rejected+=1
    end
    return nothing
end

mutable struct TrustedLookup
    previous::Any
    compiled::Any
    certificate::Union{Nothing,IndexCertificate}
    counts::TrustedCounters
    fallback::Any
end
Base.@nospecializeinfer @noinline function PSE._try_trusted_execution_group_lookup(
    previous::PSE.CompiledExecutionPlan,compiled::PSE.CompiledCompositeModel,
)
    @nospecialize previous compiled
    counts=get(_enabled,compiled.model,nothing)
    counts===nothing && return nothing
    counts.refresh_attempts+=1
    certificate=_get(_indices,previous.groups_by_application_slot)
    valid=certificate!==nothing && certificate.groups.value===previous.groups &&
        certificate.stamp.model.value===compiled.model &&
        certificate.stamp.key.value===_logical_epoch(compiled) &&
        certificate.application_count==_application_count(compiled)==length(previous.groups_by_application_slot) &&
        certificate.group_count==length(previous.groups)
    if valid
        counts.certificate_hits+=1
    else
        counts.certificate_misses+=1
        certificate=nothing
    end
    return TrustedLookup(previous,compiled,certificate,counts,nothing)
end
function _fallback!(lookup,application)
    lookup.counts.fallback_queries+=1
    if lookup.fallback===nothing
        lookup.fallback=PSE._previous_execution_groups_for_refresh(lookup.previous,lookup.compiled)
        lookup.counts.fallback_lookups_created+=1
    end
    return PSE._previous_execution_group(lookup.fallback,application)
end
Base.@nospecializeinfer @noinline function PSE._previous_execution_group(
    lookup::TrustedLookup,application::PSE.CompiledModelApplication,
)
    @nospecialize application
    lookup.counts.lookup_attempts+=1
    certificate=lookup.certificate
    certificate===nothing && return _fallback!(lookup,application)
    slot=_slot(application)
    in_range=slot isa Int && 1<=slot<=certificate.application_count &&
        slot<=_application_count(lookup.compiled) && slot<=length(lookup.previous.groups_by_application_slot)
    canonical=in_range && certificate.stamp.applications[slot].value===application &&
        _application_at(lookup.compiled,slot)===application
    canonical || return _fallback!(lookup,application)
    group=lookup.previous.groups_by_application_slot[slot]
    if group===nothing
        lookup.counts.trusted_empty_returns+=1
        return nothing
    end
    group.application===application || return _fallback!(lookup,application)
    lookup.counts.trusted_group_hits+=1
    return group
end

Base.@nospecializeinfer @noinline function trusted_execution_group_index_report(value)
    @nospecialize value
    model=value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state=get(_enabled,model,nothing)
    names=fieldnames(TrustedCounters)
    counters=NamedTuple{names}(Tuple(state===nothing ? 0 : getfield(state,name) for name in names))
    return (enabled=state!==nothing,counters,
        registry_capacities=(indices=_indices.capacity,logical_stamps=_epochs.capacity),
        registry_entries=(indices=lock(()->length(_indices.entries),_indices.mutex),
            logical_stamps=lock(()->length(_epochs.entries),_epochs.mutex)),
        stamp_scope=:once_per_logical_token_while_retained_in_bounded_FIFO,
        refresh_work=:constant_time_identity_and_length_checks_no_scan_or_snapshot,
        construction_proof=:canonical_application_and_unique_slot_in_core_fill_loop,
        epoch_token=:mutable_application_target_template_cache_identity,
        descriptor_ownership=:weak_index_list_model_token_and_application_references,
        finalizers_used=false,cached_memberships=false,cached_scientific_values=false,
        fallback_epoch=Epoch.execution_group_epoch_lookup_report(value))
end

end # module
