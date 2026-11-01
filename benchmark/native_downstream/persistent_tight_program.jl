module PersistentTightProgram

using PlantSimEngine
const PSE=PlantSimEngine
const Selected=Main.DirectPlanConstruction
const Shared=Main.SharedCallProgram
const Tight=Main.TightCallProgram
const Lean=Main.LeanNativeCompiler
const Native=Main.NativePBDriver
const Direct=Main.DirectCallCompiler
export prepare_persistent_tight, lower_persistent_tight!, persistent_tight_report,
    persistent_regions

mutable struct PersistentRecord
    selected::Selected.SelectedRecord
    state_strategy::Symbol
    status_strategy::Symbol
    header_strategy::Symbol
    count_calls::Bool
    denied::Set{Symbol}
    reasons::Dict{Symbol,Symbol}
    declaration_proofs::Dict{Any,Bool}
    declaration_policy::Any
    refreshes::Int
    regions_reused::Int
    regions_readmitted::Int
    regions_rebuilt::Int
    ordinary_fallbacks::Int
    exposed_application_declines::Int
    internal_regions_captured::Int
    metadata_rebases::Int
end
function PersistentRecord(state,status,header,count_calls;declaration_policy=nothing)
    selected=Selected.SelectedRecord(count_calls ? Tight.TightCounters() : nothing,header)
    return PersistentRecord(selected,state,status,header,count_calls,Set{Symbol}(),
        Dict{Symbol,Symbol}(),Dict{Any,Bool}(),declaration_policy,0,0,0,0,0,0,0,0)
end
const _records=WeakKeyDict{Any,PersistentRecord}()

struct PersistentTargets <: AbstractVector{Any}
    batch::Any
end
Base.IndexStyle(::Type{PersistentTargets})=IndexLinear()
mutable struct PersistentBatch{B} <: PSE.AbstractExecutionBatch
    inner::B
    record::PersistentRecord
    exposed::Bool
    captured::Bool
    batch_executions::Int
    last_execution_ids::Vector{PSE.ObjectId}
    last_execution_model_revision::Int
end
struct PersistentOrdinaryBatch{B} <: PSE.AbstractExecutionBatch
    inner::B
    record::PersistentRecord
end
const AnyPersistentBatch=Union{PersistentBatch,PersistentOrdinaryBatch}
function Base.getproperty(batch::AnyPersistentBatch,name::Symbol)
    name===:targets && return PersistentTargets(batch)
    name in fieldnames(typeof(batch)) && return getfield(batch,name)
    return getproperty(getfield(batch,:inner),name)
end
Base.propertynames(batch::AnyPersistentBatch,private::Bool=false)=private ?
    (fieldnames(typeof(batch))...,:targets,:application,:environment_provider,:output_publication) :
    (:application,:environment_provider,:output_publication,:targets)
_raw_targets(batch::PersistentBatch)=getfield(batch,:inner).factory.targets
_raw_targets(batch::PersistentOrdinaryBatch)=getfield(batch,:inner).targets
Base.size(targets::PersistentTargets)=size(_raw_targets(targets.batch))
Base.length(targets::PersistentTargets)=length(_raw_targets(targets.batch))
PSE._model_execution_target_id(targets::PersistentTargets,index)=
    PSE._model_execution_target_id(_raw_targets(targets.batch),index)
function _deny!(batch,reason)
    record=batch.record;application=batch.application.id
    if !(application in record.denied)
        push!(record.denied,application)
        record.exposed_application_declines+=1
    end
    record.reasons[application]=reason
    batch isa PersistentBatch && (batch.exposed=true)
    return nothing
end
function Base.getindex(targets::PersistentTargets,index::Int)
    _deny!(targets.batch,:public_target_exposure)
    return _raw_targets(targets.batch)[index]
end
PSE._execution_batch_requires_full_refresh(::AnyPersistentBatch)=true

# Strict type/effect proof only: never evaluate a declaration to decide whether
# extra admission work is allowed. Conditional effects or mutable/global names
# stay ordinary. Proofs are world-sensitive and cache no model/status values.
function _pure_declaration!(record,f,T)
    record.declaration_policy===nothing ||
        return _pure_declaration!(record.declaration_policy,record,f,T)
    key=(f,T,Base.get_world_counter())
    return get!(record.declaration_proofs,key) do
        effects=Base.infer_effects(f,Tuple{T})
        always=getfield(parentmodule(typeof(effects)),:ALWAYS_TRUE)
        inferred=Base.promote_op(f,T)
        effects.consistent==always && effects.effect_free==always && effects.nothrow &&
            inferred isa DataType && inferred<:NamedTuple && isconcretetype(inferred)
    end
end
_pure_declaration!(policy,record,f,T)=
    throw(ArgumentError("Unknown persistent declaration proof policy $(typeof(policy))"))
function _safe_target(record,compiled,application,id,ancestors,checked)
    key=(application.id,id)
    key in ancestors && return false
    key in checked && return true
    model=PSE._application_model(application,id)
    Tight.tight_call_effects(typeof(model))===Tight._TIGHT_CAPABILITY || return false
    _pure_declaration!(record,PSE._local_output_schema,typeof(application.spec)) || return false
    all(f->_pure_declaration!(record,f,typeof(model)),
        (PSE.inputs_,PSE.outputs_,PSE.environment_outputs_)) || return false
    push!(ancestors,key)
    try
        for binding in get(compiled.call_bindings_by_target,key,())
            PSE._compiled_call_mode(binding)===:manual || return false
            binding.multiplicity===:many && return false
            length(binding.callee_application_ids)==length(binding.callee_object_ids)==1 || return false
            child=PSE._compiled_application_by_id(compiled,only(binding.callee_application_ids))
            child_id=only(binding.callee_object_ids)
            PSE._call_binding_target_matches(binding,child,child_id) || return false
            _safe_target(record,compiled,child,child_id,ancestors,checked) || return false
        end
    finally
        delete!(ancestors,key)
    end
    push!(checked,key)
    return true
end
function _safe_application(record,compiled,application)
    ancestors=Set{Tuple{Symbol,PSE.ObjectId}}()
    checked=Set{Tuple{Symbol,PSE.ObjectId}}()
    return all(id->_safe_target(record,compiled,application,id,ancestors,checked),application.target_ids)
end


# Invocation epochs are cold control metadata, separate from scientific fields.
# The strategy hooks the existing status/entry boundaries; numerical execution
# and the real noinline Tight._run_child! method remain unchanged.
const NODE_HEADER_FIELDS=(:compiled,:environment_bindings,:application,:object_id,
    :bound_inputs,:output_targets,:temporal_streams,:output_retention,:constants,:environment)
const EDGE_HEADER_FIELDS=(:compiled,:environment_bindings,:temporal_streams,
    :output_retention,:constants,:environment)
mutable struct ContextEpochHeader
    compiled::Any
    environment_bindings::Any
    application::Any
    object_id::Any
    bound_inputs::Any
    output_targets::Any
    temporal_streams::Any
    output_retention::Any
    constants::Any
    environment::Any
end
mutable struct EdgeEpochHeader
    compiled::Any
    environment_bindings::Any
    temporal_streams::Any
    output_retention::Any
    constants::Any
    environment::Any
end
struct EdgeEpochs
    times::Vector{Float64}
    publication::BitVector
    headers::Vector{EdgeEpochHeader}
end
mutable struct TrackedStatusStrategy{S,E}
    parent::S
    times::Vector{Float64}
    publication::BitVector
    synchronize_edges::BitVector
    headers::Vector{ContextEpochHeader}
    edges::E
    root::Bool
    current_row::Int
end
function _node_header(program,row,constants=program.rows.constants)
    rows=program.rows
    return ContextEpochHeader(rows.compiled,rows.environment,rows.application,rows.ids[row],
        rows.bound_inputs[row],NamedTuple(),rows.streams,rows.retention,constants,PSE._NO_ENVIRONMENT_OVERRIDE)
end
function _edge_header(program,constants=program.rows.constants)
    rows=program.rows
    return EdgeEpochHeader(rows.compiled,rows.environment,rows.streams,rows.retention,
        constants,PSE._NO_ENVIRONMENT_OVERRIDE)
end
function _update_node_header!(header,program,row,constants)
    rows=program.rows
    header.compiled=rows.compiled
    header.environment_bindings=rows.environment
    header.application=rows.application
    header.object_id=rows.ids[row]
    header.bound_inputs=rows.bound_inputs[row]
    header.output_targets=NamedTuple()
    header.temporal_streams=rows.streams
    header.output_retention=rows.retention
    header.constants=constants
    header.environment=PSE._NO_ENVIRONMENT_OVERRIDE
    return nothing
end
function _update_edge_header!(header,program,constants)
    rows=program.rows
    header.compiled=rows.compiled
    header.environment_bindings=rows.environment
    header.temporal_streams=rows.streams
    header.output_retention=rows.retention
    header.constants=constants
    header.environment=PSE._NO_ENVIRONMENT_OVERRIDE
    return nothing
end
const TrackedFrame=Tight.TightFrame{P,E,S} where {P,E,S<:TrackedStatusStrategy}
@inline function Tight._status(
    context::Tight.TightContext{F,C,Tight.ProjectedHeaders,K},model,
) where {F<:TrackedFrame,C,K}
    strategy=context.frame.status_strategy
    row=context.row
    strategy.current_row=row
    strategy.times[row]=context.time
    strategy.publication[row]=strategy.root
    if strategy.synchronize_edges[row]
        _update_node_header!(strategy.headers[row],context.frame.program,row,context.constants)
        for edge in values(strategy.edges)
            edge.times[row]=context.time
            edge.publication[row]=strategy.root
            _update_edge_header!(edge.headers[row],context.frame.program,context.constants)
        end
        strategy.synchronize_edges[row]=false
    end
    strategy.headers[row].environment=PSE._NO_ENVIRONMENT_OVERRIDE
    return Native._native_kernel_status(context.frame.program.views[row],model,strategy.parent)
end
@inline function Tight._entry(frame::Tight.TightFrame{P,E,S},name::Val{Name}) where
    {P,E,S<:TrackedStatusStrategy,Name}
    strategy=frame.status_strategy
    row=strategy.current_row
    if row>0 && hasproperty(strategy.edges,Name)
        edge=getproperty(strategy.edges,Name)
        edge.times[row]=strategy.times[row]
        edge.publication[row]=strategy.publication[row]
        edge.headers[row].environment=strategy.headers[row].environment
    end
    # Erase only S to select the original generated lookup while retaining its
    # concrete P/E and exact child return type. This does not invoke a kernel.
    return invoke(Tight._entry,Tuple{Tight.TightFrame{P,E},Val{Name}},frame,name)
end

# A seed is keyed by dynamic identities and a call-name path, never type params.
_epoch_key(program,row,root_id,path)=(root_id,path,program.rows.application.id,program.rows.ids[row])
function _find_owner(batches,application_id,id)
    batches===nothing && return nothing
    for batch in batches
        batch.application.id===application_id || continue
        for index in eachindex(batch.targets)
            PSE._model_execution_target_id(batch.targets,index)==id || continue
            return batch.targets[index]
        end
    end
    return nothing
end
function _seed_owner_epochs!(seeds,program,row,root_id,path,owner,compiled,environment)
    owner===nothing && return nothing
    context=owner.context
    context isa PSE.RunContext || return nothing
    edges=Dict{Symbol,Any}()
    for targets in context.calls
        edges[PSE._compiled_call_name(targets.binding)]=targets
    end
    seeds[_epoch_key(program,row,root_id,path)]=(time=float(context.time),
        publication=context.publication_allowed,
        synchronize=context.compiled!==compiled || context.environment_bindings!==environment,
        header=ContextEpochHeader((getfield(context,name) for name in NODE_HEADER_FIELDS)...),
        edges=Dict(name=>(time=float(targets.time),publication=targets.publication_allowed,
                header=EdgeEpochHeader((getfield(targets,field) for field in EDGE_HEADER_FIELDS)...))
            for (name,targets) in pairs(edges)))
    for (name,child) in pairs(program.children)
        targets=get(edges,name,nothing)
        targets===nothing && continue
        cached=PSE._cached_call_execution_batches(targets)
        child_owner=_find_owner(cached,child.rows.application.id,child.rows.ids[row])
        _seed_owner_epochs!(seeds,child,row,root_id,(path...,name),child_owner,compiled,environment)
    end
    return nothing
end
function _epoch_seeds(program,batches,compiled,environment)
    seeds=Dict{Any,Any}()
    batches===nothing && return seeds
    # Scheduled roots have one owner per application/id. Build this index once;
    # child owners remain in their own parent call-site cache and are not merged.
    roots=Dict{Tuple{Symbol,PSE.ObjectId},Any}()
    for batch in batches,index in eachindex(batch.targets)
        id=PSE._model_execution_target_id(batch.targets,index)
        roots[(batch.application.id,id)]=batch.targets[index]
    end
    for row in eachindex(program.rows.ids)
        id=program.rows.ids[row]
        owner=get(roots,(program.rows.application.id,id),nothing)
        _seed_owner_epochs!(seeds,program,row,id,(),owner,compiled,environment)
    end
    return seeds
end
function _tracked_frame(program,status_strategy,seeds;root=true,root_ids=program.rows.ids,path=(),previous=nothing)
    n=length(program.rows.ids)
    old=previous===nothing ? nothing : previous.status_strategy
    times=old===nothing ? zeros(n) : old.times
    publication=old===nothing ? trues(n) : old.publication
    synchronize=old===nothing ? falses(n) : old.synchronize_edges
    headers=old===nothing ? ContextEpochHeader[_node_header(program,row) for row in 1:n] : old.headers
    edge_values=Tuple(old===nothing ? EdgeEpochs(zeros(n),trues(n),
        EdgeEpochHeader[_edge_header(program) for _ in 1:n]) : getproperty(old.edges,name)
        for name in keys(program.children))
    edges=NamedTuple{keys(program.children)}(edge_values)
    for row in 1:n
        seed=get(seeds,_epoch_key(program,row,root_ids[row],path),nothing)
        times[row]=seed===nothing ? 0.0 : seed.time
        publication[row]=seed===nothing ? true : seed.publication
        synchronize[row]=seed===nothing ? false : seed.synchronize
        headers[row]=seed===nothing ? _node_header(program,row) : seed.header
        for (name,edge) in pairs(edges)
            value=seed===nothing ? nothing : get(seed.edges,name,nothing)
            edge.times[row]=value===nothing ? 0.0 : value.time
            edge.publication[row]=value===nothing ? true : value.publication
            edge.headers[row]=value===nothing ? _edge_header(program) : value.header
        end
    end
    children=Tuple(_tracked_frame(child,status_strategy,seeds;root=false,root_ids,
        path=(path...,name),previous=previous===nothing ? nothing : getproperty(previous.entries,name))
        for (name,child) in pairs(program.children))
    strategy=TrackedStatusStrategy(Val(status_strategy),times,publication,synchronize,headers,edges,root,0)
    return Tight.TightFrame(program,NamedTuple{keys(program.children)}(children),strategy)
end
function _restore_shared_epochs!(frame,tracked)
    strategy=tracked.status_strategy
    copyto!(frame.times,strategy.times)
    copyto!(frame.publication,strategy.publication)
    frame.context.time=maximum(strategy.times;init=0.0)
    frame.context.publication_allowed=strategy.root
    for (name,entry) in pairs(frame.context.calls.entries)
        edge=getproperty(strategy.edges,name)
        for row in eachindex(strategy.times)
            targets=Shared._targets_for_row!(entry,frame,row)
            targets.time=edge.times[row]
            targets.publication_allowed=edge.publication[row]
            for field in EDGE_HEADER_FIELDS
                setfield!(targets,field,getfield(edge.headers[row],field))
            end
        end
        _restore_shared_epochs!(entry.frame,getproperty(tracked.entries,name))
    end
    # A pending ordinary runtime transition belongs to the actual owner context,
    # not merely a boolean trace. Materialize cold owners now and restore their
    # old header identities, so later ordinary entry performs its normal sync.
    for row in eachindex(strategy.times)
        owner=Direct._ordinary_owner!(Shared.SharedOwnerRef(frame,row))
        context=owner.context
        for field in NODE_HEADER_FIELDS
            setfield!(context,field,getfield(strategy.headers[row],field))
        end
    end
    return nothing
end
Base.@nospecializeinfer @noinline function Selected._full_protocol!(
    batch::Selected.SelectedTightBatch{F},
) where {F<:TrackedFrame}
    @nospecialize batch
    first_materialization=batch.factory.shared_batch===nothing
    inner=invoke(Selected._full_protocol!,Tuple{Selected.SelectedTightBatch},batch)
    first_materialization && _restore_shared_epochs!(inner.frame,batch.frame)
    return inner
end
function _track_selected(inner,batches,record)
    program=inner.frame.program
    seeds=_epoch_seeds(program,batches,program.rows.compiled,program.rows.environment)
    frame=_tracked_frame(program,record.status_strategy,seeds)
    tracked=Selected.SelectedTightBatch(frame,inner.headers,inner.counts,inner.application,
        inner.environment_provider,inner.output_publication,inner.factory)
    inner.factory.targets=Selected.SelectedTargetView(tracked,program.rows.ids)
    return tracked
end

function _wrap(inner,record)
    inner isa Selected.SelectedTightBatch || return PersistentOrdinaryBatch(inner,record)
    return PersistentBatch(inner,record,false,false,0,PSE.ObjectId[],0)
end
function _selected(record,compiled,environment,application,streams,retention,constants;ordinary_batches=nothing)
    application.id in record.denied && return (reason=:permanent_public_or_failed_owner_boundary,batches=nothing)
    _safe_application(record,compiled,application) || return (reason=:metadata_or_kernel_capability_boundary,batches=nothing)
    chosen=Selected._lower_selected(compiled,environment,application,streams,retention,
        constants,record.state_strategy,record.status_strategy,record.header_strategy,record.selected)
    chosen.reason===:eligible || return chosen
    return (reason=chosen.reason,batches=PSE.AbstractExecutionBatch[
        _track_selected(inner,ordinary_batches,record) for inner in chosen.batches])
end

# Scientific execution remains the existing typed program, including the real
# noinline Tight._run_child! exception boundary. No run! or call API is replaced.
Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::PersistentBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    before=batch.record.selected.batch_entries
    try
        PSE._run_model_execution_batch!(batch.inner,compiled,environment,time,constants,streams,retention)
    catch
        if batch.record.selected.batch_entries>before
            batch.batch_executions+=batch.record.selected.batch_entries-before
            if batch.record.count_calls
                entered=batch.inner.factory.entered
                batch.last_execution_ids=copy(batch.inner.frame.program.rows.ids[1:entered])
                batch.last_execution_model_revision=compiled.revision
            end
        end
        _deny!(batch,:partial_failure_or_public_protocol_boundary)
        rethrow()
    end
    entered=batch.record.selected.batch_entries-before
    batch.batch_executions+=entered
    if entered>0 && batch.record.count_calls
        batch.last_execution_ids=copy(batch.inner.frame.program.rows.ids)
        batch.last_execution_model_revision=compiled.revision
    end
    return nothing
end
Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::PersistentOrdinaryBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    batch.record.ordinary_fallbacks+=1
    return PSE._run_model_execution_batch!(batch.inner,compiled,environment,time,constants,streams,retention)
end
PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,batch::AnyPersistentBatch,time::Real)=
    PSE._compiled_source_prepare_batch(simulation,batch.inner,time)
PSE._explain_execution_batch(batch::AnyPersistentBatch,index)=
    merge(PSE._explain_execution_batch(batch.inner,index),(persistent_wrapper=true,))

function PSE._capture_execution_batch_refresh_state!(batch::PersistentBatch,model)
    batch.captured && return nothing
    # Observe external materialization/failure BEFORE our internal retirement.
    if batch.exposed || !batch.inner.factory.active || batch.inner.factory.shared_batch!==nothing ||
       PSE._active_call_evaluation()!==nothing
        _deny!(batch,:preexisting_public_failed_or_evaluation_owner)
    end
    PSE._capture_execution_batch_refresh_state!(batch.inner,model)
    batch.captured=true
    batch.record.internal_regions_captured+=1
    return nothing
end
PSE._capture_execution_batch_refresh_state!(batch::PersistentOrdinaryBatch,model)=
    PSE._capture_execution_batch_refresh_state!(batch.inner,model)

# A successful ordinary refresh is the bookkeeping oracle. Only numerical
# columns whose complete graph still matches current validated metadata survive.
function _program_current(program,compiled,environment,streams,retention,constants)
    rows=program.rows
    application=get(compiled.applications_by_id,rows.application.id,nothing)
    application===rows.application || return false
    rows.retention===retention && typeof(rows.constants)===typeof(constants) || return false
    for row in eachindex(rows.ids)
        id=rows.ids[row];key=(application.id,id)
        first(PSE._sorted_object_id_position(application.target_ids,id)) || return false
        view=get(compiled.status_views_by_target,key,nothing)
        view===nothing && return false
        view.status===rows.statuses[row] && view.bound_inputs===rows.bound_inputs[row] || return false
        PSE._application_model(application,id)===Shared._model(program,row) || return false
        isempty(view.temporal_inputs) && isempty(view.private_outputs) || return false
        bindings=get(compiled.call_bindings_by_target,key,())
        bindings===rows.call_bindings[row] && PSE._call_bindings_signature(bindings)==rows.call_signatures[row] || return false
        PSE._environment_binding_for(environment,application.id,id)===rows.environment_bindings[row] || return false
        PSE._model_execution_outputs_match(program.outputs[row],compiled,application,id,retention,streams) || return false
    end
    return all(child->_program_current(child,compiled,environment,streams,retention,constants),values(program.children))
end
function _rebase(program,compiled,environment,streams,retention,constants)
    old=program.rows
    rows=Shared.SharedProgramRows(old.application,old.ids,old.statuses,old.bound_inputs,
        old.call_bindings,old.call_signatures,old.environment_bindings,
        compiled,environment,streams,retention,constants)
    children=NamedTuple{keys(program.children)}(Tuple(_rebase(child,compiled,environment,
        streams,retention,constants) for child in values(program.children)))
    return Shared.SharedProgramNode(program.models,program.views,program.outputs,children,rows)
end
function _rebased_inner(batch,compiled,environment,streams,retention,constants,ordinary_batches)
    old=batch.inner
    program=_rebase(old.frame.program,compiled,environment,streams,retention,constants)
    headers=old.headers isa Tight.ProjectedHeaders ? old.headers : Tight._union_headers(program,batch.record.status_strategy)
    headers===nothing && return nothing
    application=program.rows.application
    factory=Selected.FallbackFactory(program,batch.record.status_strategy,nothing,nothing,
        old.factory.last_time,nothing,0,true,batch.record.selected)
    seeds=_epoch_seeds(program,ordinary_batches,compiled,environment)
    frame=_tracked_frame(program,batch.record.status_strategy,seeds;previous=old.frame)
    inner=Selected.SelectedTightBatch(frame,headers,
        batch.record.selected.counts,application,
        Lean._provider(environment,application,first(program.rows.ids)),
        PSE._compiled_output_publication(retention,application),factory)
    factory.targets=Selected.SelectedTargetView(inner,program.rows.ids)
    return inner
end
function _ordinary_shadow(previous)
    groups=PSE.CompiledApplicationExecutionGroup[];batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        rows=PSE.AbstractExecutionBatch[]
        for batch in group.batches
            if batch isa PersistentBatch
                append!(rows,Shared._retired_batches(Selected._full_protocol!(batch.inner)))
            elseif batch isa PersistentOrdinaryBatch
                push!(rows,batch.inner)
            else
                push!(rows,batch)
            end
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,rows));append!(batches,rows)
    end
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(previous.groups_by_application_slot)),
        previous.schedule,previous.model_revision,previous.environment_revision,previous.shared_target_plans)
end

Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::AnyPersistentBatch,previous,compiled,environment,streams,retention,
    constants,performance,changed_applications,changed_targets,
)
    @nospecialize previous compiled environment streams retention constants performance changed_applications changed_targets
    all(batch->batch isa AnyPersistentBatch || batch isa PSE.CompiledExecutionBatch,previous.batches) || return nothing
    record=trigger.record;record.refreshes+=1
    old=Dict{Symbol,Vector{Any}}()
    for group in previous.groups
        old[group.application.id]=Any[batch for batch in group.batches if batch isa PersistentBatch]
    end
    shadow=_ordinary_shadow(previous)
    refreshed=PSE._refresh_model_execution_plan(shadow,compiled,environment,streams,retention,
        constants,performance,changed_applications,changed_targets)
    groups=PSE.CompiledApplicationExecutionGroup[];batches=PSE.AbstractExecutionBatch[]
    for group in refreshed.plan.groups
        application=group.application;id=application.id;prior=get(old,id,Any[])
        chosen=PSE.AbstractExecutionBatch[]
        can_reuse=!isempty(prior) && !(id in record.denied) &&
            !isnothing(changed_applications) && !(id in changed_applications) &&
            reduce(vcat,(batch.inner.frame.program.rows.ids for batch in prior);init=PSE.ObjectId[])==application.target_ids &&
            all(batch->_program_current(batch.inner.frame.program,compiled,environment,streams,retention,constants),prior)
        if can_reuse
            replacements=Any[_rebased_inner(batch,compiled,environment,streams,retention,constants,group.batches) for batch in prior]
            can_reuse=all(index->replacements[index]!==nothing &&
                typeof(replacements[index])===typeof(prior[index].inner),eachindex(prior))
            if can_reuse
                for (batch,inner) in zip(prior,replacements)
                    batch.inner=inner;batch.captured=false
                    push!(chosen,batch)
                    record.regions_reused+=1;record.metadata_rebases+=1
                end
            end
        end
        if !can_reuse
            lowered=_selected(record,compiled,environment,application,streams,retention,constants;ordinary_batches=group.batches)
            record.reasons[id]=lowered.reason
            if lowered.reason===:eligible
                for inner in lowered.batches
                    push!(chosen,_wrap(inner,record))
                    record.regions_readmitted+=1;record.regions_rebuilt+=1
                end
            else
                append!(chosen,(_wrap(batch,record) for batch in group.batches))
            end
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(application,chosen));append!(batches,chosen)
    end
    plan=PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,compiled),
        refreshed.plan.schedule,compiled.revision,environment.environment_revision,refreshed.plan.shared_target_plans)
    return (;plan,targets_constructed=refreshed.targets_constructed,
        batches_constructed=refreshed.batches_constructed,groups_reused=refreshed.groups_reused)
end

"""Install only after fresh ordinary run!(steps=0), before public owner inspection.

The deliberate prior ordinary plan cost remains in normal PSE preparation.
Additional lowering is a distinct measurable phase. No science executes here.
"""
Base.@nospecializeinfer @noinline function lower_persistent_tight!(simulation::PSE.Simulation;
    count_calls::Bool=false,state_strategy::Symbol=:references,status_strategy::Symbol=:refs,
    header_strategy::Symbol=:projected,declaration_policy=nothing)
    @nospecialize simulation
    PSE.current_step(simulation)==0 || throw(ArgumentError("Lower only a fresh zero-step timeline"))
    haskey(_records,simulation) && throw(ArgumentError("Persistent lowering already installed"))
    state_strategy===:references && status_strategy===:refs && header_strategy===:projected ||
        throw(ArgumentError("First persistent prototype requires ordinary references/projected headers"))
    simulation.model.status_storage===nothing || throw(ArgumentError("First persistent prototype requires ordinary canonical references"))
    record=PersistentRecord(state_strategy,status_strategy,header_strategy,count_calls;declaration_policy)
    if simulation.performance!==nothing
        # Profiled core group dispatch requires ordinary CompiledExecutionBatch.
        # Retain the complete ordinary plan and counters without sentinel layers.
        _records[simulation]=record
        return simulation
    end
    previous=simulation.execution_plan
    groups=PSE.CompiledApplicationExecutionGroup[];batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        chosen=_selected(record,simulation.compiled,simulation.environment_bindings,
            group.application,simulation.temporal_streams,simulation.output_retention,simulation.constants)
        record.reasons[group.application.id]=chosen.reason
        selected=chosen.reason===:eligible ? chosen.batches : group.batches
        wrapped=PSE.AbstractExecutionBatch[_wrap(batch,record) for batch in selected]
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,wrapped));append!(batches,wrapped)
    end
    simulation.execution_plan=PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,simulation.compiled),previous.schedule,
        previous.model_revision,previous.environment_revision,previous.shared_target_plans)
    _records[simulation]=record
    return simulation
end
Base.@nospecializeinfer @noinline function prepare_persistent_tight(model::PSE.CompositeModel;
    steps::Integer=0,outputs=:none,performance::Bool=false,count_calls::Bool=false,
    constants=PSE.PlantMeteo.Constants(),state_strategy::Symbol=:references,
    status_strategy::Symbol=:refs,header_strategy::Symbol=:projected,declaration_policy=nothing)
    @nospecialize model outputs constants
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    simulation=PSE.run!(model;steps=0,outputs,performance,constants)
    lower_persistent_tight!(simulation;count_calls,state_strategy,status_strategy,header_strategy,declaration_policy)
    steps==0 || PSE.continue!(simulation;steps)
    return simulation
end
function persistent_regions(simulation::PSE.Simulation)
    return [(application=batch.application.id,identity=batch,region=batch,
        row_ids=copy(batch.inner.frame.program.rows.ids),
        numerical_signature=(typeof(batch.inner.frame),typeof(batch.inner.headers),typeof(batch.inner.environment_provider)),
        active=batch.inner.factory.active,exposed=batch.exposed || batch.application.id in batch.record.denied,
        batch_executions=batch.batch_executions,last_execution_ids=copy(batch.last_execution_ids),
        last_execution_model_revision=batch.last_execution_model_revision)
        for batch in simulation.execution_plan.batches if batch isa PersistentBatch]
end
function persistent_tight_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation has no persistent typed program"))
    counts=record.selected.counts
    regions=persistent_regions(simulation)
    return (;batch_executions=record.selected.batch_entries,
        executed_numerical_roots=counts===nothing ? missing : counts.roots,
        executed_numerical_calls=counts===nothing ? missing : counts.calls,
        regions_reused=record.regions_reused,regions_readmitted=record.regions_readmitted,
        regions_rebuilt=record.regions_rebuilt,ordinary_fallbacks=record.ordinary_fallbacks,
        exposed_application_declines=record.exposed_application_declines,
        denied_applications=sort!(collect(record.denied)),refreshes=record.refreshes,
        internal_regions_captured=record.internal_regions_captured,metadata_rebases=record.metadata_rebases,
        live_regions=length(regions),live_active_regions=count(row->row.active,regions),
        actual_numerical_id_trace=record.count_calls,
        source_capability=Tight._TIGHT_CAPABILITY,numerical_executor=:original_Tight_noinline_child,
        canonical_storage=:ordinary_references,scientific_values_copied=false,
        retirement_policy=:pre_refresh_original_owner_capture_then_ordinary_bookkeeping,
        reuse_policy=:stable_wrapper_and_numerical_columns_with_fresh_metadata_headers,
        initial_lowering=:additional_to_ordinary_zero_step_preparation,
        performance_fallback=simulation.performance!==nothing,
        qualification=simulation.performance===nothing ? :persistent_candidate : :ordinary_profiled_executor,
        empty_plan_readmission=:requires_at_least_one_live_selected_or_ordinary_sentinel_batch,
        reasons=copy(record.reasons))
end

end # module
