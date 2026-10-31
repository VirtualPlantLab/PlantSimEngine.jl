module TightCallProgram

using PlantSimEngine
const PSE=PlantSimEngine
const Native=Main.NativePBDriver
const Shared=Main.SharedCallProgram
const Direct=Main.DirectCallCompiler
const Lean=Main.LeanNativeCompiler

export prepare_tight_calls, tight_call_report, tight_call_effects, compile_tight_call_plan

"""
    tight_call_effects(::Type) = :full_protocol

The opt-in value
`:discarded_call_results_publishfalse_no_public_calls_no_context_escape`
is a source audit, additional to the full shared executor's capability. Every
hard call is synchronous, unpublished, and its result is discarded. The only
context operations are unpublished `run_call!` and typed `call_model`; contexts
and call results never escape. Topology, bindings and model parameters remain
fixed during the invocation. Scientific state/references may change or escape,
and numerical kernels may throw.

Eligible kernels receive a PRIVATE immutable TightContext, not a RunContext.
Its unpublished-call intrinsic returns `nothing`, which the capability makes
unobservable. It does not pretend to return a CallTargets collection. Unknown,
retained-result, evaluation, publication and public-context kernels keep the
full Shared/ordinary protocol and all its genuine collections.
"""
tight_call_effects(::Type)=:full_protocol
const _TIGHT_CAPABILITY=:discarded_call_results_publishfalse_no_public_calls_no_context_escape
for audit in Native.PB_NATIVE_CALL_AUDIT
    T=typeof(audit.model)
    @eval tight_call_effects(::Type{$T})=:discarded_call_results_publishfalse_no_public_calls_no_context_escape
end

mutable struct TightCounters
    roots::Int
    calls::Int
    lookups::Int
    fields::Int
    native_fields::Int
end
TightCounters()=TightCounters(0,0,0,0,0)
@inline _count_root!(::Nothing,view)=nothing
@inline _count_child!(::Nothing,view)=nothing
@inline _count_lookup!(::Nothing)=nothing
@inline function _count_root!(counts::TightCounters,view)
    counts.roots+=1
    counts.fields+=Direct._direct_field_count(view)
    counts.native_fields+=Native._view_native_fields(view)
    return nothing
end
@inline function _count_child!(counts::TightCounters,view)
    counts.calls+=1
    counts.fields+=Direct._direct_field_count(view)
    counts.native_fields+=Native._view_native_fields(view)
    return nothing
end
@inline _count_lookup!(counts::TightCounters)=(counts.lookups+=1;nothing)

struct ProjectedHeaders end
mutable struct TightFrame{P,E,S}
    const program::P
    const entries::E
    const status_strategy::S
end
struct TightContext{F,C,H,K}
    frame::F
    row::Int
    time::Float64
    constants::C
    shared_header::H
    counts::K
end
@inline @generated function _entry(frame::TightFrame{P,E},::Val{Name}) where {P,E,Name}
    index=findfirst(==(Name),fieldnames(E))
    return index===nothing ? :(nothing) : :(getfield(frame.entries,$index))
end
@inline _model(frame::TightFrame,row)=Shared._model(frame.program,row)
@inline _status(context::TightContext{F,C,ProjectedHeaders},model) where {F,C}=
    Native._native_kernel_status(context.frame.program.views[context.row],model,context.frame.status_strategy)
@inline _status(context::TightContext,model)=context.shared_header

Base.@nospecializeinfer @noinline function _frame(program,status_strategy)
    @nospecialize program
    children=Tuple(_frame(child,status_strategy) for child in values(program.children))
    return TightFrame(program,NamedTuple{keys(program.children)}(children),Val(status_strategy))
end
function _eligible(program)
    for row in eachindex(program.rows.ids)
        tight_call_effects(typeof(Shared._model(program,row)))===_TIGHT_CAPABILITY || return false
    end
    return all(_eligible,values(program.children))
end

_ports(view::Native.NativeStatusView)=keys(view.columns)
_ports(view::Native.NativeReferenceView)=keys(getfield(view.status,:vars))
function _same_canonical(program,row,root_id,root_status,union_names)
    program.rows.ids[row]==root_id || return false
    program.rows.statuses[row]===root_status || return false
    PSE._status_identity(program.rows.statuses[row])===PSE._status_identity(root_status) || return false
    for name in _ports(program.views[row])
        name in union_names || return false
        PSE.refvalue(program.rows.statuses[row],name)===PSE.refvalue(root_status,name) || return false
    end
    return all(child->_same_canonical(child,row,root_id,root_status,union_names),values(program.children))
end
function _all_direct_status(program,row)
    Native.direct_status_compatible(typeof(Shared._model(program,row))) || return false
    return all(child->_all_direct_status(child,row),values(program.children))
end
Base.@nospecializeinfer @noinline function _union_headers(program,status_strategy)
    @nospecialize program
    headers=Any[]
    for row in eachindex(program.rows.ids)
        view=program.views[row]
        names=_ports(view)
        _same_canonical(program,row,program.rows.ids[row],program.rows.statuses[row],names) || return nothing
        header=status_strategy===:direct && view isa Native.NativeStatusView && _all_direct_status(program,row) ?
            Native.NativeDirectStatus(view) : Native._native_status(view)
        push!(headers,header)
    end
    return Shared._typed_column(headers)
end
@inline _header(::ProjectedHeaders,row)=ProjectedHeaders()
@inline _header(headers::AbstractVector,row)=@inbounds headers[row]

# Keep a real numerical frame around every child, including nested exceptions
# caught and retried by the original parent scientific kernel.
@noinline function _run_child!(frame::TightFrame,parent,sampled)
    context=TightContext(frame,parent.row,parent.time,parent.constants,parent.shared_header,parent.counts)
    model=_model(frame,parent.row)
    view=@inbounds frame.program.views[parent.row]
    environment=sampled isa PSE.UnspecifiedModelEnvironment ?
        PSE._model_environment_for_binding(frame.program.rows.environment,
            frame.program.rows.application,frame.program.rows.environment_bindings[parent.row],parent.time) : sampled
    _count_child!(parent.counts,view)
    PSE.run!(model,_status(context,model),environment,parent.constants,context)
    return nothing
end
@noinline _run_child!(::Nothing,parent,sampled)=
    throw(ArgumentError("Private tight call does not name a declared singular child"))
@inline Base.@constprop :aggressive function PSE.run_call!(context::TightContext,name::Symbol;
    sampled_environment=PSE._UNSPECIFIED_SCENE_ENVIRONMENT,publish::Bool=false,
    environment=PSE._NO_ENVIRONMENT_OVERRIDE,objects=nothing,
)
    publish && throw(ArgumentError("Tight source capability forbids publishing child calls"))
    environment isa PSE.NoEnvironmentOverride ||
        throw(ArgumentError("Tight source capability forbids backend environment overrides"))
    objects===nothing || throw(ArgumentError("Tight source capability forbids selected public calls"))
    return _run_child!(_entry(context.frame,Val(name)),context,sampled_environment)
end
@inline function _call_model(frame::TightFrame,context)
    _count_lookup!(context.counts)
    return _model(frame,context.row)
end
@noinline _call_model(::Nothing,context)=throw(ArgumentError("Unknown private tight model lookup"))
@inline Base.@constprop :aggressive PSE.call_model(context::TightContext,name::Symbol)=
    _call_model(_entry(context.frame,Val(name)),context)

mutable struct TightRecord
    shared::Shared.SharedRecord
    counts::Union{Nothing,TightCounters}
    tight_batches::Int
    tight_rows::Int
    batch_executions::Int
    fallback_batches::Int
    header_strategy::Symbol
    reasons::Vector{NamedTuple}
end
TightRecord(shared,counts,header_strategy)=TightRecord(shared,counts,0,0,0,0,header_strategy,NamedTuple[])
const _records=WeakKeyDict{Any,TightRecord}()

struct TightBatch{B,F,H,K} <: PSE.AbstractExecutionBatch
    inner::B
    frame::F
    headers::H
    counts::K
    last_time::Base.RefValue{Float64}
    active::Base.RefValue{Bool}
    record::TightRecord
end
function Base.getproperty(batch::TightBatch,name::Symbol)
    name in (:inner,:frame,:headers,:counts,:last_time,:active,:record) && return getfield(batch,name)
    # Access to real execution owners is a cold boundary. No collection or
    # context can have escaped the tight scientific path, so synthesize its
    # previously unobservable cache metadata before handing control to Shared.
    name===:targets && _synchronize_retirement_metadata!(batch)
    return getproperty(getfield(batch,:inner),name)
end
Base.propertynames(batch::TightBatch,private::Bool=false)=private ?
    (propertynames(batch.inner)...,:inner,:frame,:headers,:counts,:last_time,:active,:record) : propertynames(batch.inner)
PSE._execution_batch_requires_full_refresh(::TightBatch)=true

function _seed_frame_time!(frame,time,isroot)
    fill!(frame.times,time)
    fill!(frame.publication,isroot)
    frame.context.time=time
    frame.context.publication_allowed=isroot
    for entry in values(frame.context.calls.entries)
        _seed_frame_time!(entry.frame,time,false)
    end
    return nothing
end
function _synchronize_retirement_metadata!(batch::TightBatch)
    batch.active[] || return nothing
    _seed_frame_time!(batch.inner.frame,batch.last_time[],true)
    return nothing
end
function PSE._capture_execution_batch_refresh_state!(batch::TightBatch,model)
    _synchronize_retirement_metadata!(batch)
    PSE._capture_execution_batch_refresh_state!(batch.inner,model)
    batch.active[]=false
    return nothing
end

@inline function _entry_proof(batch::TightBatch,compiled,environment)
    inner=batch.inner
    return batch.active[] && compiled===inner.compiled && environment===inner.environment_bindings &&
        PSE._active_call_evaluation()===nothing &&
        inner.frame.context.calls.state.row==0 &&
        all(lease->!lease.disabled && !lease.running,inner.frame.context.calls.state.leases)
end
function _seed_partial_frame_time!(frame,entered,time,previous_time,isroot)
    for row in eachindex(frame.times)
        frame.times[row]=row<=entered ? float(time) : previous_time
        frame.publication[row]=isroot
    end
    frame.context.time=float(time)
    frame.context.publication_allowed=isroot
    for entry in values(frame.context.calls.entries)
        _seed_partial_frame_time!(entry.frame,entered,time,previous_time,false)
    end
    return nothing
end
@noinline function _retire_partial_failure!(batch,entered,time)
    # A failed root has entered its current-time context; later rows have not.
    # No tight context or child collection escaped, so cold descendant owners
    # can inherit each root's epoch until a normal public lookup prepares them.
    _seed_partial_frame_time!(batch.inner.frame,entered,time,batch.last_time[],true)
    batch.last_time[]=float(time)
    batch.active[]=false
    return nothing
end
@noinline function _numerical_rows!(batch::TightBatch,environment,constants,time)
    program=batch.frame.program
    publish=batch.inner.output_publication.enabled
    entered=0
    try
        for row in eachindex(program.rows.ids)
            entered=row
            context=TightContext(batch.frame,row,float(time),constants,_header(batch.headers,row),batch.counts)
            model=_model(batch.frame,row)
            view=@inbounds program.views[row]
            _count_root!(batch.counts,view)
            Base.@inline PSE.run!(model,_status(context,model),environment,constants,context)
            publish && PSE._model_publish_runtime_outputs!(program.outputs[row],time)
        end
    catch
        _retire_partial_failure!(batch,entered,time)
        rethrow()
    end
    return nothing
end
Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::TightBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    if !_entry_proof(batch,compiled,environment)
        batch.record.fallback_batches+=1
        _synchronize_retirement_metadata!(batch)
        batch.active[]=false
        batch.last_time[]=float(time)
        return PSE._run_model_execution_batch!(batch.inner,compiled,environment,time,constants,streams,retention)
    end
    sampled=PSE._model_execution_batch_environment(batch.inner.environment_provider,
        environment,batch.inner.application,time)
    batch.record.batch_executions+=1
    _numerical_rows!(batch,sampled,constants,time)
    batch.last_time[]=float(time)
    return nothing
end
function PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,batch::TightBatch,time::Real)
    return PSE._compiled_source_prepare_batch(simulation,batch.inner,time)
end
function PSE._explain_execution_batch(batch::TightBatch,index)
    return merge(PSE._explain_execution_batch(batch.inner,index),(
        call_capability=_TIGHT_CAPABILITY,inner_loop_dispatch=:private_unpublished_typed_calls))
end

Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::TightBatch,previous,compiled,environment,streams,retention,
    constants,performance,changed_applications,changed_targets,
)
    @nospecialize previous compiled environment streams retention constants performance changed_applications changed_targets
    all(batch->batch isa PSE.CompiledExecutionBatch || batch isa Shared.SharedProgramBatch || batch isa TightBatch,
        previous.batches) || return nothing
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        selected=PSE.AbstractExecutionBatch[]
        for batch in group.batches
            if batch isa TightBatch
                _synchronize_retirement_metadata!(batch)
                push!(selected,batch.inner)
            else
                push!(selected,batch)
            end
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,selected))
        append!(batches,selected)
    end
    shadow=PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(previous.groups_by_application_slot)),
        previous.schedule,previous.model_revision,previous.environment_revision,previous.shared_target_plans)
    return PSE._try_refresh_execution_batch_plan(trigger.inner,shadow,compiled,environment,
        streams,retention,constants,performance,changed_applications,changed_targets)
end

struct TightPlanCompiler
    state_strategy::Symbol
    status_strategy::Symbol
    header_strategy::Symbol
    record::TightRecord
end
Base.@nospecializeinfer @noinline function (compiler::TightPlanCompiler)(compiled,
    environment,streams=nothing,retention=nothing,constants=nothing)
    @nospecialize compiled environment streams retention constants
    return compile_tight_call_plan(compiled,environment,streams,retention,constants;
        state_strategy=compiler.state_strategy,status_strategy=compiler.status_strategy,
        header_strategy=compiler.header_strategy,record=compiler.record)
end
Base.@nospecializeinfer @noinline function compile_tight_call_plan(compiled,environment,
    streams=nothing,retention=nothing,constants=nothing;
    state_strategy=:native,status_strategy=:direct,header_strategy=:projected,
    record=TightRecord(Shared.SharedRecord(),nothing,header_strategy))
    @nospecialize compiled environment streams retention constants
    previous=Shared.compile_shared_call_plan(compiled,environment,streams,retention,constants;
        state_strategy,status_strategy,record=record.shared)
    replacements=IdDict{Any,Any}()
    for batch in previous.batches
        batch isa Shared.SharedProgramBatch || continue
        program=batch.frame.context.calls.program
        if !_eligible(program)
            push!(record.reasons,(application=batch.application.id,reason=:full_call_protocol_required))
            continue
        end
        headers=header_strategy===:projected ? ProjectedHeaders() : _union_headers(program,status_strategy)
        if headers===nothing
            push!(record.reasons,(application=batch.application.id,reason=:union_header_requires_identical_canonical_status))
            continue
        end
        replacements[batch]=TightBatch(batch,_frame(program,status_strategy),headers,record.counts,Ref(0.0),Ref(true),record)
        record.tight_batches+=1
        record.tight_rows+=length(program.rows.ids)
        push!(record.reasons,(application=batch.application.id,reason=:eligible))
    end
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        selected=PSE.AbstractExecutionBatch[get(replacements,batch,batch) for batch in group.batches]
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,Lean._bounded_application_batches(selected)))
        append!(batches,selected)
    end
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(previous.groups_by_application_slot)),
        previous.schedule,previous.model_revision,previous.environment_revision,previous.shared_target_plans)
end

Base.@nospecializeinfer @noinline function prepare_tight_calls(model::PSE.CompositeModel;
    steps::Integer=0,outputs=:none,performance::Bool=false,state_strategy::Symbol=:native,
    status_strategy::Symbol=:direct,header_strategy::Symbol=:projected,count_calls::Bool=false,
    constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    state_strategy in (:native,:references) || throw(ArgumentError("Unknown tight state strategy"))
    status_strategy in (:direct,:refs) || throw(ArgumentError("Unknown tight status strategy"))
    header_strategy in (:projected,:same_object_union) || throw(ArgumentError("Unknown tight header strategy"))
    state_strategy===:native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native tight calls require native storage from allocation"))
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    record=TightRecord(Shared.SharedRecord(),count_calls ? TightCounters() : nothing,header_strategy)
    compiler=performance ? PSE.compile_model_execution_plan :
        TightPlanCompiler(state_strategy,status_strategy,header_strategy,record)
    simulation=PSE.run!(model;steps=0,outputs,performance,constants,_execution_plan_compiler=compiler)
    _records[simulation]=record
    steps==0 || PSE.continue!(simulation;steps)
    return simulation
end
function tight_call_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation was not prepared by prepare_tight_calls"))
    counts=record.counts
    shared=record.shared
    return (count_calls=counts!==nothing,
        executed_numerical_roots=counts===nothing ? missing : counts.roots,
        executed_numerical_calls=counts===nothing ? missing : counts.calls,
        typed_model_lookups=counts===nothing ? missing : counts.lookups,
        executed_numerical_fields=counts===nothing ? missing : counts.fields,
        executed_native_column_fields=counts===nothing ? missing : counts.native_fields,
        tight_batches_prepared=record.tight_batches,tight_rows_prepared=record.tight_rows,
        tight_batch_executions=record.batch_executions,fallback_batch_executions=record.fallback_batches,
        live_tight_batches=count(batch->batch isa TightBatch,simulation.execution_plan.batches),
        full_shared_numerical_roots=shared.counters.roots,
        full_shared_numerical_calls=shared.counters.calls,
        lazy_public_wrappers=shared.lazy_wrappers,
        constructed_rich_targets=shared.initial_rich_targets+shared.counters.rich_targets,
        header_strategy=record.header_strategy,
        source_capability=_TIGHT_CAPABILITY,private_call_return=:unobservable_nothing,
        scientific_kernels=:original,numerical_scalar_copies=false,
        counters=counts===nothing ? :compiled_out : :actual_work_companion,
        counted_fields=:projected_instruction_ports,
        preparation=:shared_program_plus_shared_fallback_frames_plus_tight_frames,
        refresh_policy=:shared_original_owner_retirement_then_ordinary_refresh,
        shared_reasons=copy(shared.reasons),reasons=copy(record.reasons))
end

end
