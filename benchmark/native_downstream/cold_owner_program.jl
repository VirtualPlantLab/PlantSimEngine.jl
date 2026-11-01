module ColdOwnerProgram

using PlantSimEngine
const PSE=PlantSimEngine
const PT=Main.PersistentTightProgram
const Selected=Main.DirectPlanConstruction
const Shared=Main.SharedCallProgram
const Tight=Main.TightCallProgram
const Lean=Main.LeanNativeCompiler
export prepare_cold_owner,lower_cold_owner!,cold_owner_report,cold_owner_regions

"""An opt-in owner-reuse policy; all scientific state stays in ordinary references.

The ordinary zero-step plan remains the authoritative cold owner tree. Numerical
columns are the existing Selected/Tight implementation. At a public or refresh
boundary, tracked metadata is copied onto those same owners, rather than
constructing a Shared full-protocol tree. This retains ordinary owner memory.
"""
mutable struct ColdOwnerRecord
    selected::Selected.SelectedRecord
    state_strategy::Symbol
    status_strategy::Symbol
    header_strategy::Symbol
    count_calls::Bool
    denied::Set{Symbol}
    reasons::Dict{Symbol,Symbol}
    declaration_proofs::Dict{Any,Bool}
    declaration_policy::Any
    ordinary_plan::Any
    refreshes::Int
    regions_reused::Int
    regions_readmitted::Int
    regions_rebuilt::Int
    ordinary_fallbacks::Int
    exposed_application_declines::Int
    internal_regions_captured::Int
    metadata_rebases::Int
    cold_syncs::Int
    node_headers_restored::Int
    edge_headers_restored::Int
    child_caches_materialized::Int
    root_owners_retained::Int
    root_owner_identity_checks::Int
end
function ColdOwnerRecord(previous,count_calls,proof_cache)
    return ColdOwnerRecord(Selected.SelectedRecord(count_calls ? Tight.TightCounters() : nothing,:projected),
        :references,:refs,:projected,count_calls,Set{Symbol}(),Dict{Symbol,Symbol}(),
        Dict{Any,Bool}(),proof_cache,previous,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
end
const _records=WeakKeyDict{Any,ColdOwnerRecord}()

struct ColdTargets <: AbstractVector{Any}
    batch::Any
end
Base.IndexStyle(::Type{ColdTargets})=IndexLinear()
mutable struct ColdBatch{B} <: PSE.AbstractExecutionBatch
    inner::B
    record::ColdOwnerRecord
    cold_batches::Vector{PSE.AbstractExecutionBatch}
    root_owners::Vector{Any}
    root_state::PSE.ExecutionBatchContextState
    synchronized::Bool
    exposed::Bool
    captured::Bool
    batch_executions::Int
    last_execution_ids::Vector{PSE.ObjectId}
    last_execution_model_revision::Int
end
struct ColdOrdinaryBatch{B} <: PSE.AbstractExecutionBatch
    inner::B
    record::ColdOwnerRecord
end
const AnyColdBatch=Union{ColdBatch,ColdOrdinaryBatch}
function Base.getproperty(batch::AnyColdBatch,name::Symbol)
    name===:targets && return ColdTargets(batch)
    name in fieldnames(typeof(batch)) && return getfield(batch,name)
    return getproperty(getfield(batch,:inner),name)
end
Base.propertynames(batch::AnyColdBatch,private::Bool=false)=private ?
    (fieldnames(typeof(batch))...,:targets,:application,:environment_provider,:output_publication) :
    (:application,:environment_provider,:output_publication,:targets)
Base.size(targets::ColdTargets)=(length(targets),)
Base.length(targets::ColdTargets)=targets.batch isa ColdBatch ?
    length(targets.batch.root_owners) : length(targets.batch.inner.targets)
PSE._model_execution_target_id(targets::ColdTargets,index)=targets.batch isa ColdBatch ?
    targets.batch.inner.frame.program.rows.ids[index] :
    PSE._model_execution_target_id(targets.batch.inner.targets,index)
function _deny!(batch,reason)
    record=batch.record;id=batch.application.id
    if !(id in record.denied)
        push!(record.denied,id);record.exposed_application_declines+=1
    end
    record.reasons[id]=reason
    batch isa ColdBatch && (batch.exposed=true)
    return nothing
end
function Base.getindex(targets::ColdTargets,index::Int)
    batch=targets.batch
    _deny!(batch,:public_target_exposure)
    if batch isa ColdBatch
        _sync_cold!(batch)
        return batch.root_owners[index]
    end
    return batch.inner.targets[index]
end
PSE._execution_batch_requires_full_refresh(::AnyColdBatch)=true

function _root_index(batches)
    roots=Dict{PSE.ObjectId,Any}();states=Dict{PSE.ObjectId,Any}()
    for batch in batches,index in eachindex(batch.targets)
        owner=batch.targets[index];id=PSE._model_execution_target_id(batch.targets,index)
        haskey(roots,id) && throw(ArgumentError("Duplicate ordinary root owner"))
        roots[id]=owner
        states[id]=batch isa PSE.CompiledExecutionBatch ? batch.context_state : nothing
    end
    return (;roots,states)
end
function _wrap_selected(inner,ordinary_batches,record;previous=nothing)
    index=_root_index(ordinary_batches)
    ids=inner.frame.program.rows.ids
    owners=Any[index.roots[id] for id in ids]
    root_state=PSE.ExecutionBatchContextState(nothing,nothing)
    states=Any[index.states[id] for id in ids]
    if !isempty(states) && all(state->state!==nothing,states) &&
        all(state->state.compiled===first(states).compiled &&
            state.environment_bindings===first(states).environment_bindings,states)
        root_state.compiled=first(states).compiled
        root_state.environment_bindings=first(states).environment_bindings
    end
    targets=PSE._typed_model_execution_targets(owners,firstindex(owners),lastindex(owners))
    cold=PSE.CompiledExecutionBatch(inner.application,targets,
        inner.environment_provider,inner.output_publication,root_state)
    record.root_owners_retained+=length(owners)
    for row in eachindex(ids)
        owners[row]===index.roots[ids[row]] || error("Cold owner identity changed")
        record.root_owner_identity_checks+=1
    end
    return ColdBatch(inner,record,PSE.AbstractExecutionBatch[cold],owners,root_state,
        false,false,false,0,PSE.ObjectId[],0)
end

# Root context synchronization is a batch operation in ordinary PSE, including
# rows a later scientific exception may leave unentered. Mirror only that cold
# metadata operation before calling the original numerical row loop.
function _synchronize_root_epochs!(batch,compiled,environment,time,constants)
    state=batch.root_state
    state.compiled===compiled && state.environment_bindings===environment && return nothing
    frame=batch.inner.frame;strategy=frame.status_strategy
    for row in eachindex(strategy.times)
        strategy.times[row]=float(time);strategy.publication[row]=true
        header=strategy.headers[row]
        if header.compiled!==compiled || header.environment_bindings!==environment
            PT._update_node_header!(header,frame.program,row,constants)
            for edge in values(strategy.edges)
                edge.times[row]=float(time);edge.publication[row]=true
                PT._update_edge_header!(edge.headers[row],frame.program,constants)
            end
            strategy.synchronize_edges[row]=false
        end
        header.environment=PSE._NO_ENVIRONMENT_OVERRIDE
    end
    state.compiled=compiled;state.environment_bindings=environment
    return nothing
end

function _restore_owner!(frame,row,owner,record)
    context=owner.context
    context isa PSE.RunContext || return nothing
    strategy=frame.status_strategy
    context.time=strategy.times[row]
    context.publication_allowed=strategy.publication[row]
    for field in PT.NODE_HEADER_FIELDS
        setfield!(context,field,getfield(strategy.headers[row],field))
    end
    record.node_headers_restored+=1
    isempty(frame.entries) && return nothing
    edges=Dict{Symbol,Any}(PSE._compiled_call_name(targets.binding)=>targets for targets in context.calls)
    for (name,child) in pairs(frame.entries)
        targets=get(edges,name,nothing)
        targets===nothing && error("Original cold owner lost its declared call site")
        edge=getproperty(strategy.edges,name)
        targets.time=edge.times[row];targets.publication_allowed=edge.publication[row]
        for field in PT.EDGE_HEADER_FIELDS
            setfield!(targets,field,getfield(edge.headers[row],field))
        end
        record.edge_headers_restored+=1
        cached=PSE._cached_call_execution_batches(targets)
        if cached===nothing
            cached=PSE._materialize_call_execution_batches!(targets)
            record.child_caches_materialized+=1
        end
        child_owner=PT._find_owner(cached,child.program.rows.application.id,child.program.rows.ids[row])
        child_owner===nothing && error("Original cold call site lost its owner")
        _restore_owner!(child,row,child_owner,record)
    end
    return nothing
end
function _sync_cold!(batch::ColdBatch)
    batch.synchronized && return nothing
    # Retire private entry before any cold metadata operation can throw, just
    # as the original full-protocol factory does before materialization.
    batch.inner.factory.active=false
    for row in eachindex(batch.root_owners)
        _restore_owner!(batch.inner.frame,row,batch.root_owners[row],batch.record)
    end
    batch.synchronized=true
    batch.record.cold_syncs+=1
    return nothing
end

function _selected(record,compiled,environment,application,streams,retention,constants,ordinary_batches)
    application.id in record.denied && return (reason=:permanent_public_or_failed_owner_boundary,batches=nothing)
    PT._safe_application(record,compiled,application) ||
        return (reason=:metadata_or_kernel_capability_boundary,batches=nothing)
    chosen=Selected._lower_selected(compiled,environment,application,streams,retention,
        constants,:references,:refs,:projected,record.selected)
    chosen.reason===:eligible || return chosen
    return (reason=:eligible,batches=PSE.AbstractExecutionBatch[
        _wrap_selected(PT._track_selected(inner,ordinary_batches,record),ordinary_batches,record)
        for inner in chosen.batches])
end

Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::ColdBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    if !Selected._selected_entry_current(batch.inner,compiled,environment)
        _deny!(batch,:full_protocol_boundary)
        _sync_cold!(batch)
        batch.record.ordinary_fallbacks+=1
        for cold in batch.cold_batches
            PSE._run_model_execution_batch!(cold,compiled,environment,time,constants,streams,retention)
        end
        return nothing
    end
    # Preserve the original environment-sampling and exception boundaries.
    sampled=PSE._model_execution_batch_environment(batch.environment_provider,
        environment,batch.application,time)
    _synchronize_root_epochs!(batch,compiled,environment,time,constants)
    batch.record.selected.batch_entries+=1
    before=batch.batch_executions
    try
        Selected._selected_numerical_rows!(batch.inner,sampled,constants,time)
    catch
        batch.batch_executions=before+1
        if batch.record.count_calls
            entered=batch.inner.factory.entered
            batch.last_execution_ids=copy(batch.inner.frame.program.rows.ids[1:entered])
            batch.last_execution_model_revision=compiled.revision
        end
        _deny!(batch,:partial_failure_or_public_protocol_boundary)
        rethrow()
    end
    batch.batch_executions=before+1
    if batch.record.count_calls
        batch.last_execution_ids=copy(batch.inner.frame.program.rows.ids)
        batch.last_execution_model_revision=compiled.revision
    end
    return nothing
end
Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::ColdOrdinaryBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    batch.record.ordinary_fallbacks+=1
    return PSE._run_model_execution_batch!(batch.inner,compiled,environment,time,constants,streams,retention)
end
PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,batch::AnyColdBatch,time::Real)=
    PSE._compiled_source_prepare_batch(simulation,batch.inner,time)
PSE._explain_execution_batch(batch::AnyColdBatch,index)=
    merge(PSE._explain_execution_batch(batch.inner,index),(cold_owner_wrapper=true,))
function PSE._capture_execution_batch_refresh_state!(batch::ColdBatch,model)
    batch.captured && return nothing
    if batch.exposed || !batch.inner.factory.active || PSE._active_call_evaluation()!==nothing
        _deny!(batch,:preexisting_public_failed_or_evaluation_owner)
    end
    _sync_cold!(batch)
    batch.captured=true
    batch.record.internal_regions_captured+=1
    return nothing
end
PSE._capture_execution_batch_refresh_state!(batch::ColdOrdinaryBatch,model)=
    PSE._capture_execution_batch_refresh_state!(batch.inner,model)

# These are the original ordinary groups and owners. Only the live schedule and
# bookkeeping revision shells are supplied by the currently installed plan.
function _ordinary_shadow(previous,record)
    for batch in previous.batches
        batch isa ColdBatch && _sync_cold!(batch)
    end
    ordinary=record.ordinary_plan
    return PSE.CompiledExecutionPlan(ordinary.groups,ordinary.batches,
        ordinary.groups_by_application_slot,previous.schedule,ordinary.model_revision,
        ordinary.environment_revision,ordinary.shared_target_plans)
end
function _rebased_batch(batch,compiled,environment,streams,retention,constants,ordinary_batches)
    inner=PT._rebased_inner(batch,compiled,environment,streams,retention,constants,ordinary_batches)
    inner===nothing && return nothing
    rebound=_wrap_selected(inner,ordinary_batches,batch.record)
    typeof(rebound)===typeof(batch) || return nothing
    # Preserve public wrapper identity and cumulative counters only after every
    # candidate has been validated by the caller.
    return rebound
end
function _commit_rebase!(batch,rebound)
    batch.inner=rebound.inner;batch.cold_batches=rebound.cold_batches
    batch.root_owners=rebound.root_owners;batch.root_state=rebound.root_state
    batch.synchronized=false;batch.captured=false
    return batch
end
Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::AnyColdBatch,previous,compiled,environment,streams,retention,
    constants,performance,changed_applications,changed_targets,
)
    @nospecialize previous compiled environment streams retention constants performance changed_applications changed_targets
    all(batch->batch isa AnyColdBatch || batch isa PSE.CompiledExecutionBatch,previous.batches) || return nothing
    record=trigger.record;record.refreshes+=1
    old=Dict(group.application.id=>Any[batch for batch in group.batches if batch isa ColdBatch]
        for group in previous.groups)
    refreshed=PSE._refresh_model_execution_plan(_ordinary_shadow(previous,record),compiled,
        environment,streams,retention,constants,performance,changed_applications,changed_targets)
    record.ordinary_plan=refreshed.plan
    groups=PSE.CompiledApplicationExecutionGroup[];batches=PSE.AbstractExecutionBatch[]
    for group in refreshed.plan.groups
        application=group.application;id=application.id;prior=get(old,id,Any[])
        chosen=PSE.AbstractExecutionBatch[]
        reuse=!isempty(prior) && !(id in record.denied) &&
            !isnothing(changed_applications) && !(id in changed_applications) &&
            reduce(vcat,(batch.inner.frame.program.rows.ids for batch in prior);init=PSE.ObjectId[])==application.target_ids &&
            all(batch->PT._program_current(batch.inner.frame.program,compiled,environment,streams,retention,constants),prior)
        if reuse
            replacements=Any[_rebased_batch(batch,compiled,environment,streams,retention,constants,group.batches) for batch in prior]
            reuse=all(value->value!==nothing,replacements)
            if reuse
                for (batch,rebound) in zip(prior,replacements)
                    push!(chosen,_commit_rebase!(batch,rebound))
                    record.regions_reused+=1;record.metadata_rebases+=1
                end
            end
        end
        if !reuse
            lowered=_selected(record,compiled,environment,application,streams,retention,constants,group.batches)
            record.reasons[id]=lowered.reason
            if lowered.reason===:eligible
                append!(chosen,lowered.batches)
                record.regions_readmitted+=length(lowered.batches)
                record.regions_rebuilt+=length(lowered.batches)
            else
                append!(chosen,(ColdOrdinaryBatch(batch,record) for batch in group.batches))
            end
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(application,chosen));append!(batches,chosen)
    end
    plan=PSE.CompiledExecutionPlan(groups,batches,PSE._execution_groups_by_application_slot(groups,compiled),
        refreshed.plan.schedule,compiled.revision,environment.environment_revision,refreshed.plan.shared_target_plans)
    return (;plan,targets_constructed=refreshed.targets_constructed,
        batches_constructed=refreshed.batches_constructed,groups_reused=refreshed.groups_reused)
end

Base.@nospecializeinfer @noinline function lower_cold_owner!(simulation::PSE.Simulation;
    proof_cache=nothing,count_calls::Bool=false,
    state_strategy::Symbol=:references,status_strategy::Symbol=:refs,header_strategy::Symbol=:projected)
    @nospecialize simulation
    PSE.current_step(simulation)==0 || throw(ArgumentError("Lower only a fresh zero-step timeline"))
    haskey(_records,simulation) && throw(ArgumentError("Cold-owner lowering already installed"))
    state_strategy===:references && status_strategy===:refs && header_strategy===:projected ||
        throw(ArgumentError("Cold-owner prototype requires ordinary references/projected headers"))
    simulation.model.status_storage===nothing || throw(ArgumentError("Cold-owner prototype requires ordinary canonical references"))
    previous=simulation.execution_plan
    record=ColdOwnerRecord(previous,count_calls,proof_cache)
    _records[simulation]=record
    simulation.performance===nothing || return simulation
    groups=PSE.CompiledApplicationExecutionGroup[];batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        chosen=_selected(record,simulation.compiled,simulation.environment_bindings,
            group.application,simulation.temporal_streams,simulation.output_retention,simulation.constants,group.batches)
        record.reasons[group.application.id]=chosen.reason
        wrapped=chosen.reason===:eligible ? chosen.batches :
            PSE.AbstractExecutionBatch[ColdOrdinaryBatch(batch,record) for batch in group.batches]
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,wrapped));append!(batches,wrapped)
    end
    simulation.execution_plan=PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,simulation.compiled),previous.schedule,
        previous.model_revision,previous.environment_revision,previous.shared_target_plans)
    return simulation
end
Base.@nospecializeinfer @noinline function prepare_cold_owner(model::PSE.CompositeModel;
    steps::Integer=0,outputs=:none,performance::Bool=false,count_calls::Bool=false,
    constants=PSE.PlantMeteo.Constants(),proof_cache=nothing,
    state_strategy::Symbol=:references,status_strategy::Symbol=:refs,header_strategy::Symbol=:projected)
    @nospecialize model
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    simulation=PSE.run!(model;steps=0,outputs,performance,constants)
    lower_cold_owner!(simulation;proof_cache,count_calls,state_strategy,status_strategy,header_strategy)
    steps==0 || PSE.continue!(simulation;steps)
    return simulation
end
function cold_owner_regions(simulation::PSE.Simulation)
    return [(application=batch.application.id,identity=batch,region=batch,
        row_ids=copy(batch.inner.frame.program.rows.ids),
        numerical_signature=(typeof(batch.inner.frame),typeof(batch.inner.headers),typeof(batch.inner.environment_provider)),
        active=batch.inner.factory.active,exposed=batch.exposed || batch.application.id in batch.record.denied,
        batch_executions=batch.batch_executions,last_execution_ids=copy(batch.last_execution_ids),
        last_execution_model_revision=batch.last_execution_model_revision,
        retained_root_owners=copy(batch.root_owners))
        for batch in simulation.execution_plan.batches if batch isa ColdBatch]
end
function cold_owner_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation has no cold-owner program"))
    counts=record.selected.counts;regions=cold_owner_regions(simulation)
    return (;batch_executions=record.selected.batch_entries,
        executed_numerical_roots=counts===nothing ? missing : counts.roots,
        executed_numerical_calls=counts===nothing ? missing : counts.calls,
        regions_reused=record.regions_reused,regions_readmitted=record.regions_readmitted,
        regions_rebuilt=record.regions_rebuilt,ordinary_fallbacks=record.ordinary_fallbacks,
        exposed_application_declines=record.exposed_application_declines,
        denied_applications=sort!(collect(record.denied)),refreshes=record.refreshes,
        internal_regions_captured=record.internal_regions_captured,metadata_rebases=record.metadata_rebases,
        live_regions=length(regions),live_active_regions=count(row->row.active,regions),
        actual_numerical_id_trace=record.count_calls,source_capability=Tight._TIGHT_CAPABILITY,
        numerical_executor=:original_Selected_rows_and_Tight_noinline_child,
        canonical_storage=:ordinary_references,scientific_values_copied=false,
        retirement_policy=:tracked_metadata_replayed_into_original_cold_owners,
        reuse_policy=:stable_wrapper_and_numerical_columns_with_original_owner_tree,
        initial_lowering=:additional_to_ordinary_zero_step_preparation,
        performance_fallback=simulation.performance!==nothing,
        qualification=simulation.performance===nothing ? :cold_owner_candidate : :ordinary_profiled_executor,
        empty_plan_readmission=:requires_at_least_one_live_selected_or_ordinary_sentinel_batch,
        cold_syncs=record.cold_syncs,node_headers_restored=record.node_headers_restored,
        edge_headers_restored=record.edge_headers_restored,
        child_caches_materialized=record.child_caches_materialized,
        root_owners_retained=record.root_owners_retained,
        live_retained_ordinary_root_owners=sum(length(batch.targets) for batch in record.ordinary_plan.batches;init=0),
        root_owner_identity_checks=record.root_owner_identity_checks,
        shared_fallback_materializations=record.selected.fallback_materializations,
        retains_ordinary_owner_tree=true,proof_cache_enabled=record.declaration_policy!==nothing,
        reasons=copy(record.reasons))
end

# Cold diagnostic, deliberately excluded from phase clocks. summarysize includes
# the reachable ordinary model graph, so report it alongside an ordinary control;
# it is not claimed as exclusive storage or process RSS.
function cold_owner_memory_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation has no cold-owner program"))
    return (;reachable_plan_bytes=Base.summarysize(simulation.execution_plan),
        reachable_retained_ordinary_plan_bytes=Base.summarysize(record.ordinary_plan),
        reachable_combined_plan_bytes=Base.summarysize((simulation.execution_plan,record.ordinary_plan)),
        interpretation=:inclusive_reachable_graph_bytes_not_exclusive_storage_or_RSS)
end

end # module
