module SharedCallProgram

using PlantSimEngine
const PSE=PlantSimEngine
const Native=Main.NativePBDriver
const Direct=Main.DirectCallCompiler
const Lean=Main.LeanNativeCompiler
const GP=Main.CompiledRegionsExperiment.GP

export prepare_shared_calls, shared_call_report, shared_context_effects,
    compile_shared_call_plan

"""
    shared_context_effects(::Type) = :ordinary

`:synchronous_borrowed_context` is an audited source capability. In addition to
`NativePBDriver.native_call_effects(T) == :fixed_native_calls`, the kernel and
all its descendants borrow their context only during the synchronous call:
they never retain it, inspect its representation, launch work using it, or
change topology/models/bindings. Scientific references and true CallTargets
may escape. Public call APIs remain available through a permanent ordinary
fallback for that organ row. Unknown kernels use the ordinary executor.
"""
shared_context_effects(::Type)=:ordinary
for audit in Native.PB_NATIVE_CALL_AUDIT
    T=typeof(audit.model)
    @eval shared_context_effects(::Type{$T})=:synchronous_borrowed_context
end

mutable struct SharedRecord
    counters::Direct.DirectCounters
    program_nodes::Int
    shared_contexts::Int
    cohorts::Int
    row_leases::Int
    lazy_wrappers::Int
    initial_rich_targets::Int
    logical_views::Int
    reasons::Vector{NamedTuple}
end
SharedRecord()=SharedRecord(Direct.DirectCounters(),0,0,0,0,0,0,0,NamedTuple[])
const _records=WeakKeyDict{Any,SharedRecord}()

# Cold metadata is kept outside the concrete scientific model/view structure.
# Its arrays contain row values and identities, never recursively nested row
# execution contexts or child owners.
struct SharedProgramRows{EB}
    application::Any
    ids::Vector{PSE.ObjectId}
    statuses::Vector{Any}
    bound_inputs::Vector{Any}
    call_bindings::Vector{Any}
    call_signatures::Vector{Any}
    environment_bindings::EB
    compiled::Any
    environment::Any
    streams::Any
    retention::Any
    constants::Any
end

"""One immutable numerical instruction and its typed, aligned row columns."""
struct SharedProgramNode{M,V,O,C,R}
    models::M
    views::V
    outputs::O
    children::C
    rows::R
end

mutable struct SharedProgramState
    row::Int
    leases::Vector{Direct.DirectRowLease}
    record::SharedRecord
end

struct SharedCallEntry{F,B,T}
    frame::F
    bindings::B
    targets::Vector{Union{Nothing,T}}
    generations::Vector{Base.RefValue{UInt64}}
    expected_generations::Vector{UInt64}
end

struct SharedCallTable{P,E,S}
    program::P
    entries::E
    state::SharedProgramState
    frame_ref::Base.RefValue{Any}
    status_strategy::S
end

mutable struct SharedProgramFrame{C}
    context::C
    owners::Vector{Any}
    times::Vector{Float64}
    publication::BitVector
    in_use_row::Int
end

# An outward collection owns only this small locator until materialization.
# Direct's already-tested deferred target/snapshot/buffer protocol can then
# recover the exact ordinary owner belonging to this row, even while the shared
# numerical frame is currently executing another row.
struct SharedOwnerRef
    frame::Any
    row::Int
end
function Base.getproperty(reference::SharedOwnerRef,name::Symbol)
    name===:frame && return getfield(reference,:frame)
    name===:row && return getfield(reference,:row)
    frame,row=getfield(reference,:frame),getfield(reference,:row)
    program=frame.context.calls.program
    name===:application && return program.rows.application
    name===:object_id && return program.rows.ids[row]
    name===:lease && return frame.context.calls.state.leases[row]
    name===:original_context && return Direct._ordinary_owner!(reference).context
    throw(ArgumentError("Unknown shared owner field $(name)"))
end

@inline @generated function _entry(table::SharedCallTable{P,E},::Val{Name}) where {P,E,Name}
    index=findfirst(==(Name),fieldnames(E))
    return index===nothing ? :(nothing) : :(getfield(table.entries,$index))
end
@inline _model(program::SharedProgramNode,row)=GP._column_model_at(program.models,row)

Base.@nospecializeinfer @noinline function _typed_column(values)
    @nospecialize values
    T=typeof(first(values))
    all(value->typeof(value)===T,values) || throw(ArgumentError("heterogeneous_program_column"))
    return T[value for value in values]
end

Base.@nospecializeinfer @noinline function _blueprint(compiled,environment,application,
    id,streams,retention,constants,strategy,ancestors)
    @nospecialize compiled environment application streams retention constants
    key=(application.id,id)
    key in ancestors && throw(ArgumentError("recursive_call_graph"))
    model=PSE._application_model(application,id)
    Native.native_call_effects(typeof(model))===:fixed_native_calls ||
        throw(ArgumentError("unknown_model_capability"))
    shared_context_effects(typeof(model))===:synchronous_borrowed_context ||
        throw(ArgumentError("unknown_context_escape_capability"))
    view=PSE._model_status_view_for_application(compiled,application,id)
    isempty(view.temporal_inputs) || throw(ArgumentError("temporal_input_boundary"))
    isempty(view.private_outputs) || throw(ArgumentError("private_output_boundary"))
    isempty(PSE._distributed_output_schema(model)) || throw(ArgumentError("distributed_output_boundary"))
    isempty(PSE.environment_outputs_(model)) || throw(ArgumentError("environment_commit_boundary"))
    outputs=PSE._runtime_model_output_streams(view.status,application,id,streams,retention)
    all(output->output isa PSE.RuntimeOutputStream,outputs) ||
        throw(ArgumentError("distributed_publication_boundary"))
    provider=Lean._provider(environment,application,id)
    provider isa PSE.UnspecifiedModelEnvironment &&
        throw(ArgumentError("per_object_environment_boundary"))
    bindings=get(compiled.call_bindings_by_target,key,())
    names,children=Symbol[],Any[]
    push!(ancestors,key)
    try
        for binding in bindings
            PSE._compiled_call_mode(binding)===:manual || throw(ArgumentError("initializer_boundary"))
            binding.multiplicity===:many && throw(ArgumentError("tracked_many_call_boundary"))
            length(binding.callee_application_ids)==1 && length(binding.callee_object_ids)==1 ||
                throw(ArgumentError("singular_fixed_call_required"))
            child_application=PSE._compiled_application_by_id(compiled,only(binding.callee_application_ids))
            child_id=only(binding.callee_object_ids)
            PSE._call_binding_target_matches(binding,child_application,child_id) ||
                throw(ArgumentError("singular_fixed_call_required"))
            push!(names,PSE._compiled_call_name(binding))
            push!(children,_blueprint(compiled,environment,child_application,child_id,
                streams,retention,constants,strategy,ancestors))
        end
    finally
        delete!(ancestors,key)
    end
    ports=Symbol[unique((keys(PSE.inputs_(model))...,keys(PSE.outputs_(model))...))...]
    for child in children,name in child.ports
        name in ports || !hasproperty(view.status,name) || push!(ports,name)
    end
    ports=Tuple(ports)
    numerical=Direct._projected_view(view.status,ports,strategy)
    binding=PSE._environment_binding_for(environment,application.id,id)
    shape=(application.id,typeof(model),typeof(numerical),typeof(outputs),typeof(binding),
        Tuple(names),Tuple(child.shape for child in children))
    return (;application,id,model,numerical,outputs,status=view.status,
        bound_inputs=view.bound_inputs,bindings,signature=PSE._call_bindings_signature(bindings),binding,provider,
        ports,names=Tuple(names),children=Tuple(children),shape)
end

Base.@nospecializeinfer @noinline function _program(blueprints,compiled,environment,
    streams,retention,constants,record)
    @nospecialize blueprints compiled environment streams retention constants
    first_blueprint=first(blueprints)
    children=Tuple(_program(Any[blueprint.children[index] for blueprint in blueprints],
        compiled,environment,streams,retention,constants,record)
        for index in eachindex(first_blueprint.children))
    models=_typed_column(Any[blueprint.model for blueprint in blueprints])
    model_column=all(model->model===first(models),models) ?
        GP.SharedColumnModel(first(models)) : GP.PerRowColumnModels(models)
    rows=SharedProgramRows(first_blueprint.application,
        PSE.ObjectId[blueprint.id for blueprint in blueprints],
        Any[blueprint.status for blueprint in blueprints],
        Any[blueprint.bound_inputs for blueprint in blueprints],
        Any[blueprint.bindings for blueprint in blueprints],
        Any[blueprint.signature for blueprint in blueprints],
        _typed_column(Any[blueprint.binding for blueprint in blueprints]),
        compiled,environment,streams,retention,constants)
    record.program_nodes+=1
    return SharedProgramNode(model_column,
        _typed_column(Any[blueprint.numerical for blueprint in blueprints]),
        _typed_column(Any[blueprint.outputs for blueprint in blueprints]),
        NamedTuple{first_blueprint.names}(children),rows)
end

Base.@nospecializeinfer @noinline function _frame(program,state,status_strategy,constants)
    @nospecialize program constants
    entries=Any[]
    nrows=length(program.rows.ids)
    for (index,child) in enumerate(values(program.children))
        child_frame=_frame(child,state,status_strategy,constants)
        bindings=_typed_column(Any[row[index] for row in program.rows.call_bindings])
        B=eltype(bindings)
        T=PSE.CallTargets{Any,Any,B,Any,Any,typeof(constants),Direct.DirectDeferredBatches}
        targets=Vector{Union{Nothing,T}}(undef,nrows)
        fill!(targets,nothing)
        push!(entries,SharedCallEntry(child_frame,bindings,targets,
            Base.RefValue{UInt64}[getfield(binding,:membership_generation) for binding in bindings],
            UInt64[PSE._compiled_call_membership_generation(binding) for binding in bindings]))
    end
    holder=Ref{Any}(nothing)
    table=SharedCallTable(program,NamedTuple{keys(program.children)}(Tuple(entries)),
        state,holder,Val(status_strategy))
    rows=program.rows
    context=PSE.RunContext{Any,Any,typeof(table),Any,Any,Any,Any,typeof(constants),typeof(PSE._NO_ENVIRONMENT_OVERRIDE)}(
        rows.compiled,rows.environment,rows.application,first(rows.ids),table,
        first(rows.bound_inputs),NamedTuple(),rows.streams,rows.retention,0.0,
        constants,true,PSE._NO_ENVIRONMENT_OVERRIDE)
    frame=SharedProgramFrame(context,fill!(Vector{Any}(undef,nrows),nothing),
        zeros(nrows),trues(nrows),0)
    holder[]=frame
    state.record.shared_contexts+=1
    return frame
end

@inline function _targets_for_row!(entry::SharedCallEntry{F,B,T},frame,row) where {F,B,T}
    cached=@inbounds entry.targets[row]
    cached===nothing || return cached::T
    return _new_targets_for_row!(entry,frame,row)::T
end
Base.@nospecializeinfer @noinline function _new_targets_for_row!(entry::SharedCallEntry{F,B,T},frame,row) where {F,B,T}
    @nospecialize frame
    context=frame.context
    rows=context.calls.program.rows
    lease=context.calls.state.leases[row]
    deferred=Direct.DirectDeferredBatches(SharedOwnerRef(entry.frame,row),nothing,lease)
    targets=T(rows.compiled,rows.environment,entry.bindings[row],rows.streams,
        rows.retention,frame.times[row],context.constants,frame.publication[row],
        PSE._NO_ENVIRONMENT_OVERRIDE,deferred,nothing,nothing,nothing)
    entry.targets[row]=targets
    context.calls.state.record.lazy_wrappers+=1
    return targets
end

Base.@nospecializeinfer @noinline function Direct._ordinary_owner!(reference::SharedOwnerRef)
    frame,row=reference.frame,reference.row
    table=frame.context.calls
    lease=table.state.leases[row]
    Direct._disable!(lease)
    owner=frame.owners[row]
    owner===nothing || return owner
    program=table.program
    rows=program.rows
    calls=Direct.OrdinaryDeferredCallTable(Tuple(
        _targets_for_row!(entry,frame,row) for entry in values(table.entries)))
    constants=frame.context.constants
    context=PSE.RunContext{Any,Any,typeof(calls),Any,Any,Any,Any,typeof(constants),Any}(
        rows.compiled,rows.environment,rows.application,rows.ids[row],calls,
        rows.bound_inputs[row],NamedTuple(),rows.streams,rows.retention,
        frame.times[row],constants,frame.publication[row],PSE._NO_ENVIRONMENT_OVERRIDE)
    status=rows.statuses[row]
    model=_model(program,row)
    kernel=PSE._kernel_execution_status(rows.compiled,rows.application,model,status)
    bindings=rows.call_bindings[row]
    cache=PSE.CallContextCache(context)
    cache.in_use=frame.in_use_row==row
    cache.execution_revision=cache.in_use ? UInt64(1) : UInt64(0)
    owner=PSE.CompiledExecutionTarget(rows.ids[row],model,status,
        kernel===status ? nothing : kernel,status,(),rows.bound_inputs[row],NamedTuple(),
        program.outputs[row],bindings,rows.call_signatures[row],
        rows.environment_bindings[row],context,cache)
    frame.owners[row]=owner
    lease.counters.rich_targets+=1
    return owner
end

Base.@nospecializeinfer @noinline function _fallback_context!(context)
    @nospecialize context
    table=context.calls
    row=table.state.row
    row>0 || throw(ArgumentError("Borrowed shared context used outside its synchronous invocation"))
    original=Direct._ordinary_owner!(SharedOwnerRef(table.frame_ref[],row)).context
    for name in (:compiled,:environment_bindings,:application,:object_id,:bound_inputs,
        :output_targets,:temporal_streams,:output_retention,:time,:constants,
        :publication_allowed,:environment)
        setfield!(original,name,getfield(context,name))
    end
    return original
end
@noinline function _fallback_call!(context,name;
    environment,sampled_environment,publish,objects)
    context.calls.state.record.counters.fallback_calls+=1
    return PSE.run_call!(_fallback_context!(context),name;
        environment,sampled_environment,publish,objects)
end
@inline PSE._find_call_targets(table::SharedCallTable,name::Val,context::PSE.RunContext)=
    PSE._find_call_targets(_fallback_context!(context).calls,name,_fallback_context!(context))
@inline PSE._find_manual_call_targets(table::SharedCallTable,name::Val,context::PSE.RunContext)=
    PSE._find_manual_call_targets(_fallback_context!(context).calls,name,_fallback_context!(context))
Base.length(table::SharedCallTable)=length(table.entries)
Base.isempty(table::SharedCallTable)=isempty(table.entries)
Base.iterate(table::SharedCallTable,state...)=iterate(_fallback_context!(table.frame_ref[].context).calls,state...)

@inline function _prepare_frame!(frame,row,time,constants,publication_allowed)
    context=frame.context
    rows=context.calls.program.rows
    context.object_id=@inbounds rows.ids[row]
    context.bound_inputs=@inbounds rows.bound_inputs[row]
    context.time=float(time)
    context.constants=constants
    context.publication_allowed=publication_allowed
    frame.times[row]=float(time)
    frame.publication[row]=publication_allowed
    # Core context preparation does not touch unqueried child collections
    # when runtime identities are unchanged. The selected edge is synchronized
    # by run_call! or public lookup, preserving saved descendant snapshots.
    return context
end

# A real call frame is retained around each dependency for exception unwind
# safety. Do not force-inline nested scientific bodies through parent catches.
@noinline function _run_child!(frame::SharedProgramFrame,parent,publish,sampled)
    table=parent.calls
    row=table.state.row
    context=_prepare_frame!(frame,row,parent.time,parent.constants,
        publish && parent.publication_allowed)
    program=context.calls.program
    model=_model(program,row)
    view=@inbounds program.views[row]
    environment=sampled isa PSE.UnspecifiedModelEnvironment ?
        PSE._model_environment_for_binding(parent.environment_bindings,
            program.rows.application,program.rows.environment_bindings[row],parent.time) : sampled
    frame.in_use_row=row
    try
        counters=table.state.record.counters
        counters.calls+=1
        counters.fields+=Direct._direct_field_count(view)
        counters.native_fields+=Native._view_native_fields(view)
        status=Native._native_kernel_status(view,model,context.calls.status_strategy)
        PSE.run!(model,status,environment,parent.constants,context)
        if context.publication_allowed
            outputs=@inbounds program.outputs[row]
            isempty(outputs) || PSE._model_publish_runtime_outputs!(outputs,context.time)
            PSE._record_model_call_publication!(context.output_retention,
                program.rows.application.id,context.time)
        end
    finally
        frame.in_use_row=0
        owner=frame.owners[row]
        owner===nothing || (owner.call_context_cache.in_use=false)
    end
    return nothing
end

@inline function _run_entry!(entry::SharedCallEntry,context,name,environment,sampled,publish,objects)
    table=context.calls
    row=table.state.row
    row>0 || return _fallback_call!(context,name;environment,sampled_environment=sampled,publish,objects)
    lease=@inbounds table.state.leases[row]
    if !lease.disabled && lease.running && lease.task==objectid(current_task()) &&
       environment isa PSE.NoEnvironmentOverride &&
       context.environment isa PSE.NoEnvironmentOverride && objects===nothing &&
       PSE._active_call_evaluation()===nothing && entry.frame.in_use_row==0 &&
       entry.generations[row][]==entry.expected_generations[row]
        targets=_targets_for_row!(entry,table.frame_ref[],row)
        targets.time=context.time
        targets.constants=context.constants
        targets.publication_allowed=context.publication_allowed
        targets.environment=context.environment
        _run_child!(entry.frame,context,publish,sampled)
        if publish && context.publication_allowed
            for application in targets.binding.potential_callee_application_ids
                PSE._record_evaluated_call_clock!(nothing,context.output_retention,application,context.time)
            end
        end
        return targets
    end
    return _fallback_call!(context,name;environment,sampled_environment=sampled,publish,objects)
end
@inline _run_entry!(::Nothing,context,name,environment,sampled,publish,objects)=
    _fallback_call!(context,name;environment,sampled_environment=sampled,publish,objects)
@inline Base.@constprop :aggressive function PSE.run_call!(
    context::PSE.RunContext{CS,A,CT},name::Symbol;
    environment=PSE._NO_ENVIRONMENT_OVERRIDE,
    sampled_environment=PSE._UNSPECIFIED_SCENE_ENVIRONMENT,
    publish::Bool=false,objects=nothing,
) where {CS,A,CT<:SharedCallTable}
    !(environment isa PSE.NoEnvironmentOverride) &&
        !(sampled_environment isa PSE.UnspecifiedModelEnvironment) &&
        throw(ArgumentError("`environment` and `sampled_environment` are mutually exclusive hard-call overrides."))
    return _run_entry!(_entry(context.calls,Val(name)),context,name,environment,
        sampled_environment,publish,objects)
end
@inline function _call_model(entry::SharedCallEntry,context,name)
    context.calls.state.record.counters.lookups+=1
    return _model(entry.frame.context.calls.program,context.calls.state.row)
end
@noinline _call_model(::Nothing,context,name)=PSE._call_model(_fallback_context!(context),name)
@inline PSE._call_model(context::PSE.RunContext{CS,A,CT},name::Val) where {CS,A,CT<:SharedCallTable}=
    _call_model(_entry(context.calls,name),context,name)

struct SharedTargetView{F} <: AbstractVector{Any}
    frame::F
    ids::Vector{PSE.ObjectId}
end
Base.IndexStyle(::Type{<:SharedTargetView})=IndexLinear()
Base.size(targets::SharedTargetView)=size(targets.ids)
Base.length(targets::SharedTargetView)=length(targets.ids)
Base.getindex(targets::SharedTargetView,index::Int)=Direct._ordinary_owner!(SharedOwnerRef(targets.frame,index))
PSE._model_execution_target_id(targets::SharedTargetView,index)=targets.ids[index]

struct SharedProgramBatch{F,E} <: PSE.AbstractExecutionBatch
    frame::F
    targets::SharedTargetView{F}
    application::Any
    environment_provider::E
    output_publication::Any
    compiled::Any
    environment_bindings::Any
    streams::Any
    retention::Any
    constants::Any
    record::SharedRecord
end
PSE._execution_batch_requires_full_refresh(::SharedProgramBatch)=true

Base.@nospecializeinfer @noinline function _ordinary_root!(batch,row,time,constants,sampled,publish)
    @nospecialize batch constants sampled
    owner=Direct._ordinary_owner!(SharedOwnerRef(batch.frame,row))
    PSE._prepare_model_execution_context!(owner.context,batch.compiled,batch.environment_bindings,
        batch.application,owner.object_id,owner.bound_inputs,owner.output_targets,
        batch.streams,batch.retention,float(time),constants)
    PSE._run_model_execution_target!(batch.compiled,batch.environment_bindings,
        batch.application,owner,float(time),constants,batch.streams,batch.retention,sampled,publish)
    batch.record.counters.ordinary_roots+=1
    return nothing
end

@noinline function _numerical_rows!(batch::SharedProgramBatch,environment,constants,time)
    frame=batch.frame
    table=frame.context.calls
    program=table.program
    state=table.state
    publish=batch.output_publication.enabled
    for row in eachindex(program.rows.ids)
        lease=@inbounds state.leases[row]
        if lease.disabled
            _ordinary_root!(batch,row,time,constants,environment,publish)
            continue
        end
        state.row=row
        lease.running,lease.task=true,objectid(current_task())
        frame.in_use_row=row
        try
            context=_prepare_frame!(frame,row,time,constants,true)
            model=_model(program,row)
            view=@inbounds program.views[row]
            status=Native._native_kernel_status(view,model,table.status_strategy)
            counters=state.record.counters
            counters.roots+=1
            counters.fields+=Direct._direct_field_count(view)
            counters.native_fields+=Native._view_native_fields(view)
            Base.@inline PSE.run!(model,status,environment,constants,context)
            publish && PSE._model_publish_runtime_outputs!(program.outputs[row],time)
        finally
            frame.in_use_row=0
            owner=frame.owners[row]
            owner===nothing || (owner.call_context_cache.in_use=false)
            lease.running,lease.task=false,UInt(0)
            state.row=0
        end
    end
    return nothing
end
Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::SharedProgramBatch,compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants,streams,retention,
)
    @nospecialize compiled environment constants streams retention
    sampled=PSE._model_execution_batch_environment(batch.environment_provider,
        environment,batch.application,time)
    _numerical_rows!(batch,sampled,constants,time)
    return nothing
end
function PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,
    batch::SharedProgramBatch,time::Real)
    sampled=PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings,batch.application,time)
    return sampled,batch.output_publication.enabled
end
function PSE._explain_execution_batch(batch::SharedProgramBatch,index)
    program=batch.frame.context.calls.program
    return (batch_index=index,application_id=batch.application.id,
        process=batch.application.process,object_ids=[id.value for id in batch.targets.ids],
        batch_size=length(batch.targets.ids),target_type=typeof(batch.targets),
        model_type=typeof(_model(program,1)),status_type=eltype(program.views),
        input_bindings_type=Tuple{},call_bindings_type=typeof(first(program.rows.call_bindings)),
        call_capability=:shared_fixed_singular_program,
        output_variables=batch.output_publication.variables,
        output_publication=batch.output_publication.enabled ? :direct_stream_bindings : :none,
        environment_binding_type=typeof(batch.environment_provider),
        inner_loop_dispatch=:typed_shared_program_over_rows)
end

Base.@nospecializeinfer @noinline function _retire_row!(frame,row)
    @nospecialize frame
    owner=Direct._ordinary_owner!(SharedOwnerRef(frame,row))
    for entry in values(frame.context.calls.entries)
        _retire_row!(entry.frame,row)
        targets=_targets_for_row!(entry,frame,row)
        Direct._materialize!(targets.execution_batches)
    end
    return owner
end
function PSE._capture_execution_batch_refresh_state!(batch::SharedProgramBatch,model)
    for row in eachindex(batch.targets.ids)
        _retire_row!(batch.frame,row)
    end
    return nothing
end
Base.@nospecializeinfer @noinline function _retired_batches(batch::SharedProgramBatch)
    @nospecialize batch
    owners=Any[_retire_row!(batch.frame,row) for row in eachindex(batch.targets.ids)]
    batches=PSE.AbstractExecutionBatch[]
    isempty(owners) && return batches
    start=firstindex(owners)
    T=typeof(owners[start])
    for index in (start+1):lastindex(owners)
        typeof(owners[index])===T && continue
        push!(batches,PSE.CompiledExecutionBatch(batch.application,
            PSE._typed_model_execution_targets(owners,start,index-1),
            batch.environment_provider,batch.output_publication))
        start=index;T=typeof(owners[index])
    end
    push!(batches,PSE.CompiledExecutionBatch(batch.application,
        PSE._typed_model_execution_targets(owners,start,lastindex(owners)),
        batch.environment_provider,batch.output_publication))
    return batches
end
Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::SharedProgramBatch,previous,compiled,environment,streams,retention,
    constants,performance,changed_applications,changed_targets,
)
    @nospecialize previous compiled environment streams retention constants performance changed_applications changed_targets
    all(batch->batch isa PSE.CompiledExecutionBatch || batch isa SharedProgramBatch,
        previous.batches) || return nothing
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        selected=PSE.AbstractExecutionBatch[]
        for batch in group.batches
            batch isa SharedProgramBatch ? append!(selected,_retired_batches(batch)) : push!(selected,batch)
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,selected))
        append!(batches,selected)
    end
    shadow=PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(previous.groups_by_application_slot)),
        previous.schedule,previous.model_revision,previous.environment_revision,previous.shared_target_plans)
    return PSE._refresh_model_execution_plan(shadow,compiled,environment,streams,retention,
        constants,performance,changed_applications,changed_targets)
end

Base.@nospecializeinfer @noinline function _lower(compiled,environment,application,
    streams,retention,constants,strategy,status_strategy,record)
    @nospecialize compiled environment application streams retention constants
    isempty(application.target_ids) && return (reason=:empty_application,batches=nothing)
    blueprints=Any[]
    try
        for id in application.target_ids
            push!(blueprints,_blueprint(compiled,environment,application,id,streams,
                retention,constants,strategy,Set{Tuple{Symbol,PSE.ObjectId}}()))
        end
    catch exception
        exception isa ArgumentError || rethrow()
        return (reason=Symbol(exception.msg),batches=nothing)
    end
    ranges=UnitRange{Int}[]
    start=1
    for index in 2:length(blueprints)
        blueprints[index].shape==blueprints[index-1].shape && continue
        push!(ranges,start:index-1);start=index
    end
    push!(ranges,start:length(blueprints))
    batches=PSE.AbstractExecutionBatch[]
    publication=PSE._compiled_output_publication(retention,application)
    for selected in ranges
        subset=blueprints[selected]
        program=_program(subset,compiled,environment,streams,retention,constants,record)
        leases=Direct.DirectRowLease[Direct.DirectRowLease(record.counters) for _ in selected]
        state=SharedProgramState(0,leases,record)
        frame=_frame(program,state,status_strategy,constants)
        targets=SharedTargetView(frame,program.rows.ids)
        push!(batches,SharedProgramBatch(frame,targets,application,first(subset).provider,
            publication,compiled,environment,streams,retention,constants,record))
        record.cohorts+=1
        record.row_leases+=length(selected)
    end
    return (reason=:eligible,batches)
end

struct SharedPlanCompiler
    state_strategy::Symbol
    status_strategy::Symbol
    record::SharedRecord
end
Base.@nospecializeinfer @noinline function (compiler::SharedPlanCompiler)(compiled,
    environment,streams=nothing,retention=nothing,constants=nothing)
    @nospecialize compiled environment streams retention constants
    return compile_shared_call_plan(compiled,environment,streams,retention,constants;
        state_strategy=compiler.state_strategy,status_strategy=compiler.status_strategy,record=compiler.record)
end
Base.@nospecializeinfer @noinline function compile_shared_call_plan(compiled,environment,
    streams=nothing,retention=nothing,constants=nothing;
    state_strategy=:native,status_strategy=:direct,record=SharedRecord())
    @nospecialize compiled environment streams retention constants
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    record.logical_views=length(compiled.status_views_by_target)
    manual=PSE._manual_call_application_ids(compiled)
    shared=compiled.execution_policy.shared_plans ? IdDict{Any,Any}() : nothing
    for application in PSE._ordered_model_applications(compiled)
        application.id in manual && continue
        chosen=_lower(compiled,environment,application,streams,retention,constants,
            state_strategy,status_strategy,record)
        first_batch=length(batches)+1
        if chosen.reason===:eligible
            append!(batches,chosen.batches)
        else
            targets=Any[PSE._compiled_model_execution_target(compiled,environment,
                application,id,streams,retention,constants;shared_plan_cache=shared)
                for id in application.target_ids]
            record.initial_rich_targets+=length(targets)
            PSE._append_model_execution_batches!(batches,environment,application,targets,retention)
        end
        push!(record.reasons,(application=application.id,targets=length(application.target_ids),reason=chosen.reason))
        first_batch>length(batches) && continue
        selected=batches[first_batch:end]
        chosen.reason===:eligible && (selected=Lean._bounded_application_batches(selected))
        push!(groups,PSE.CompiledApplicationExecutionGroup(application,selected))
    end
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(compiled.scenario_plan.applications)),
        PSE._runtime_application_schedule(compiled.scenario_plan.application_schedule),
        compiled.revision,environment.environment_revision,shared)
end

Base.@nospecializeinfer @noinline function prepare_shared_calls(model::PSE.CompositeModel;
    steps::Integer=0,outputs=:none,performance::Bool=false,state_strategy::Symbol=:native,
    status_strategy::Symbol=:direct,constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    state_strategy in (:native,:references) || throw(ArgumentError("Unknown shared state strategy"))
    status_strategy in (:direct,:refs) || throw(ArgumentError("Unknown shared status strategy"))
    state_strategy===:native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native shared calls require native storage from allocation"))
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    record=SharedRecord()
    compiler=performance ? PSE.compile_model_execution_plan : SharedPlanCompiler(state_strategy,status_strategy,record)
    simulation=PSE.run!(model;steps=0,outputs,performance,constants,_execution_plan_compiler=compiler)
    _records[simulation]=record
    steps==0 || PSE.continue!(simulation;steps)
    return simulation
end

function shared_call_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation was not prepared by prepare_shared_calls"))
    c=record.counters
    return (executed_numerical_roots=c.roots,executed_numerical_calls=c.calls,
        executed_native_column_fields=c.native_fields,executed_numerical_fields=c.fields,
        typed_model_lookups=c.lookups,fallback_calls=c.fallback_calls,
        ordinary_root_executions=c.ordinary_roots,lazy_materializations=c.lazy_materializations,
        constructed_rich_targets=record.initial_rich_targets+c.rich_targets,
        immutable_program_nodes=record.program_nodes,shared_numerical_contexts=record.shared_contexts,
        program_cohorts=record.cohorts,row_lease_slots=record.row_leases,
        lazy_public_wrappers=record.lazy_wrappers,
        live_shared_batches=count(batch->batch isa SharedProgramBatch,simulation.execution_plan.batches),
        logical_status_views_retained=record.logical_views,
        scientific_kernels=:original,numerical_scalar_copies=false,
        context_capability=:audited_synchronous_borrow,
        refresh_policy=:retire_original_owner_tree_then_ordinary_refresh,
        reasons=copy(record.reasons))
end

end
