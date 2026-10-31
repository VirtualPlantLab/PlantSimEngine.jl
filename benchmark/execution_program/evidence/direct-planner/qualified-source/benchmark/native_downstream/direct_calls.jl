module DirectCallCompiler

using PlantSimEngine
const PSE = PlantSimEngine
const Native = Main.NativePBDriver
const CR = Main.CompiledRegionsExperiment
if !isdefined(Main, :LeanNativeCompiler)
    Base.include(Main, joinpath(@__DIR__, "lean_compiler.jl"))
end
const Lean = Main.LeanNativeCompiler

export prepare_direct_calls, direct_call_report, compile_direct_call_plan

mutable struct DirectCounters
    roots::Int
    calls::Int
    native_fields::Int
    fields::Int
    lookups::Int
    fallback_calls::Int
    ordinary_roots::Int
    lazy_materializations::Int
    rich_targets::Int
end
DirectCounters() = DirectCounters(0,0,0,0,0,0,0,0,0)

# Coverage counts the typed projected interface, not the canonical backing's
# unrelated fields. Reading Status.keys here would traverse an Any backing in
# the reference control and add dynamic dispatch to every numerical invocation.
_direct_field_count(view::Native.NativeReferenceView)=length(getfield(view.status,:vars))
_direct_field_count(view)=Native._view_fields(view)

mutable struct DirectRecord
    counters::DirectCounters
    skipped_rich_targets::Int
    initial_rich_targets::Int
    logical_views::Int
    batches::Int
    shapes::Dict{Any,Any}
    reasons::Vector{NamedTuple}
end
DirectRecord() = DirectRecord(DirectCounters(),0,0,0,0,Dict{Any,Any}(),NamedTuple[])
const _records = WeakKeyDict{Any,DirectRecord}()

mutable struct DirectRowLease
    disabled::Bool
    running::Bool
    task::UInt
    counters::DirectCounters
end
DirectRowLease(counters) = DirectRowLease(false,false,UInt(0),counters)

_disable!(lease::DirectRowLease) = (lease.disabled = true; nothing)

# A real CallTargets wrapper owns this deferred container. Nothing constructs
# a rich target/cache graph until a public target/evaluation path requests it.
mutable struct DirectDeferredBatches <: AbstractVector{PSE.AbstractExecutionBatch}
    node::Any
    batches::Any
    lease::DirectRowLease
end
Base.IndexStyle(::Type{DirectDeferredBatches}) = IndexLinear()

struct DirectGraphShape
    model_type::Any
    call_names::Tuple
    child_types::Tuple
    ports::Tuple
end

mutable struct DirectNode{M,V,C,O}
    model::M
    view::V
    context::C
    outputs::O
    original_context::Any
    application::Any
    object_id::PSE.ObjectId
    environment_binding::Any
    status::Any
    bound_inputs::Any
    call_bindings::Any
    owner::Any
    in_use::Bool
    lease::DirectRowLease
    graph_shape::Any
end
struct DirectEntry{N,T}
    node::N
    targets::T
    generation::Base.RefValue{UInt64}
    expected_generation::UInt64
end
struct DirectCallTable{E,S}
    entries::E
    original_calls::Any
    fallback_context::Any
    lease::DirectRowLease
    status_strategy::S
end
Base.length(table::DirectCallTable) = length(table.original_calls)
Base.isempty(table::DirectCallTable) = isempty(table.original_calls)
Base.iterate(table::DirectCallTable, state...) = iterate(table.original_calls, state...)

@inline @generated function _entry(table::DirectCallTable{E}, ::Val{Name}) where {E,Name}
    index=findfirst(==(Name),fieldnames(E))
    return index === nothing ? :(nothing) : :(getfield(table.entries,$index))
end

# Marker for the original public-call shell. It keeps the real cached tuple
# while distinguishing deferred owner caches from core eager-context caches.
struct OrdinaryDeferredCallTable{C}
    calls::C
end
Base.length(table::OrdinaryDeferredCallTable)=length(table.calls)
Base.isempty(table::OrdinaryDeferredCallTable)=isempty(table.calls)
Base.iterate(table::OrdinaryDeferredCallTable,state...)=iterate(table.calls,state...)
PSE._find_call_targets(table::OrdinaryDeferredCallTable,name::Val,context::PSE.RunContext)=
    PSE._find_call_targets(table.calls,name,context)
PSE._find_manual_call_targets(table::OrdinaryDeferredCallTable,name::Val,context::PSE.RunContext)=
    PSE._find_manual_call_targets(table.calls,name,context)
PSE._prepare_runtime_call_targets!(table::OrdinaryDeferredCallTable,args...)=
    PSE._prepare_runtime_call_targets!(table.calls,args...)

# The ordinary generic factory changes its context environment type on an
# override. A deferred call tuple cannot be reconstructed by that eager
# factory. Reuse this original wide-environment shell directly, preserving the
# exact cache tree. Reentrant calls deliberately use an independent ordinary
# shell/descendant graph, as the core implementation does.
function PSE._prepare_cached_call_context!(cache::PSE.CallContextCache{C},reuse::Bool,
    compiled,environment_bindings,application,object_id,bound_inputs,output_targets,
    temporal_streams,output_retention,time,constants,publication_allowed,environment,
) where {CT<:OrdinaryDeferredCallTable,C<:PSE.RunContext{Any,Any,CT}}
    if !reuse
        return PSE._prepare_model_execution_context!(nothing,compiled,environment_bindings,
            application,object_id,bound_inputs,output_targets,temporal_streams,
            output_retention,time,constants,publication_allowed,environment)
    end
    context=cache.default
    context.compiled=compiled
    context.environment_bindings=environment_bindings
    context.application=application
    context.object_id=object_id
    context.bound_inputs=bound_inputs
    context.output_targets=output_targets
    context.temporal_streams=temporal_streams
    context.output_retention=output_retention
    context.time=float(time)
    context.constants=constants
    context.publication_allowed=publication_allowed
    context.environment=environment
    PSE._prepare_runtime_call_targets!(context.calls,compiled,environment_bindings,
        temporal_streams,output_retention,time,constants,publication_allowed,environment)
    return context
end

Base.@nospecializeinfer @noinline function _ordinary_context!(node)
    @nospecialize node
    node.original_context === nothing || return node.original_context
    context=node.context
    calls=OrdinaryDeferredCallTable(context.calls.original_calls)
    constants=context.constants
    node.original_context=PSE.RunContext{Any,Any,typeof(calls),Any,Any,Any,Any,typeof(constants),Any}(
        context.compiled,context.environment_bindings,node.application,node.object_id,
        calls,node.bound_inputs,NamedTuple(),context.temporal_streams,context.output_retention,
        context.time,constants,context.publication_allowed,context.environment)
    return node.original_context
end

Base.@nospecializeinfer @noinline function _ordinary_owner!(node)
    @nospecialize node
    _disable!(node.lease)
    node.owner === nothing || return node.owner
    original=_ordinary_context!(node)
    # Match the latest private invocation before an owner becomes observable.
    # Once materialized, ordinary execution owns this shell and its exact cache.
    for name in (:compiled,:environment_bindings,:application,:object_id,:bound_inputs,
        :output_targets,:temporal_streams,:output_retention,:time,:constants,
        :publication_allowed,:environment)
        setfield!(original,name,getfield(node.context,name))
    end
    kernel_status=PSE._kernel_execution_status(original.compiled,node.application,
        node.model,node.status)
    cache=PSE.CallContextCache(original)
    # An owner first observed inside its private kernel already has an outer
    # lease. Public views must see that lease and use the core reentrant path.
    cache.in_use=node.in_use
    cache.execution_revision=node.in_use ? UInt64(1) : UInt64(0)
    node.owner=PSE.CompiledExecutionTarget(node.object_id,node.model,node.status,
        kernel_status === node.status ? nothing : kernel_status,node.status,(),
        node.bound_inputs,NamedTuple(),node.outputs,node.call_bindings,
        PSE._call_bindings_signature(node.call_bindings),node.environment_binding,
        original,cache)
    node.lease.counters.rich_targets+=1
    return node.owner
end

Base.@nospecializeinfer @noinline function _materialize!(deferred::DirectDeferredBatches)
    _disable!(deferred.lease)
    deferred.batches === nothing || return deferred.batches
    node=deferred.node
    owner=_ordinary_owner!(node)
    original=node.original_context
    targets=[owner]
    provider=PSE._compiled_model_execution_environment_provider(
        original.environment_bindings,node.application,owner)
    publication=PSE._compiled_output_publication(original.output_retention,node.application)
    deferred.batches=(PSE.CompiledExecutionBatch(node.application,targets,provider,publication),)
    deferred.lease.counters.lazy_materializations+=1
    return deferred.batches
end
Base.size(deferred::DirectDeferredBatches)=size(_materialize!(deferred))
Base.length(deferred::DirectDeferredBatches)=length(_materialize!(deferred))
Base.getindex(deferred::DirectDeferredBatches,index::Int)=_materialize!(deferred)[index]
Base.iterate(deferred::DirectDeferredBatches,state...)=iterate(_materialize!(deferred),state...)

# Core callers receive the genuine ordinary tuple once they cross the public
# view boundary, including run_call!(CallTarget), evaluation and buffer APIs.
function PSE._materialize_call_execution_batches!(
    targets::PSE.CallTargets{CS,EB,B,TS,OR,C,BT},
) where {CS,EB,B,TS,OR,C,BT<:DirectDeferredBatches}
    return _materialize!(targets.execution_batches)
end
function PSE._cached_call_execution_batches(
    targets::PSE.CallTargets{CS,EB,B,TS,OR,C,BT},
) where {CS,EB,B,TS,OR,C,BT<:DirectDeferredBatches}
    return targets.execution_batches.batches
end

# The core singular-view assertion derives CS/EB/stream parameters from the
# container. This container intentionally erases those parameters, whereas a
# public snapshot may recover their actual types. Reuse by metadata identity,
# without asserting the erased existential layout over a concrete snapshot.
function PSE._single_call_target_snapshot(
    targets::PSE.CallTargets{CS,EB,B,TS,OR,C,BT},application,target::PSE.CompiledExecutionTarget,
) where {CS,EB,B,TS,OR,C,BT<:DirectDeferredBatches}
    context=target.context
    if context isa PSE.RunContext && !target.call_context_cache.in_use
        PSE._prepare_runtime_call_targets!(context.calls,targets.compiled,
            targets.environment_bindings,targets.temporal_streams,targets.output_retention,
            targets.time,targets.constants,targets.publication_allowed,targets.environment)
        previous=targets.last_single_snapshot
        if previous isa PSE.CallTarget &&
           PSE._single_call_snapshot_matches(previous,targets,application,target,context)
            return previous
        end
        snapshot=PSE._materialize_call(targets,application,target)
        targets.last_single_snapshot=snapshot
        return snapshot
    end
    return PSE._materialize_call(targets,application,target)
end

# Reentrant snapshots use fresh ordinary descendants; non-reentrant snapshots
# use the original deferred marker. Their concrete snapshot types differ, so
# a public buffer can be reused only in the matching normal context mode.
function PSE._call_target_buffer_matches(entry,
    targets::PSE.CallTargets{CS,EB,B,TS,OR,C,BT},batches,environment_type,
) where {CS,EB,B,TS,OR,C,BT<:DirectDeferredBatches}
    invoke(PSE._call_target_buffer_matches,Tuple{Any,Any,Any,Any},
        entry,targets,batches,environment_type) || return false
    owner=only(only(batches).targets)
    owner.call_context_cache.in_use && return false
    V=eltype(entry.values)
    return isconcretetype(V) && fieldtype(V,:calls)===typeof(owner.context.calls)
end

@inline function PSE._find_call_targets(table::DirectCallTable,name::Val,context::PSE.RunContext)
    _disable!(table.lease)
    return PSE._find_call_targets(table.original_calls,name,context)
end
@inline function PSE._find_manual_call_targets(table::DirectCallTable,name::Val,context::PSE.RunContext)
    _disable!(table.lease)
    return PSE._find_manual_call_targets(table.original_calls,name,context)
end
PSE._prepare_runtime_call_targets!(table::DirectCallTable,args...)=
    PSE._prepare_runtime_call_targets!(table.original_calls,args...)

function _fallback_context!(context)
    node=context.calls.fallback_context[]
    original=_ordinary_context!(node)
    for name in (:compiled,:environment_bindings,:application,:object_id,:bound_inputs,
        :output_targets,:temporal_streams,:output_retention,:time,:constants,
        :publication_allowed,:environment)
        setfield!(original,name,getfield(context,name))
    end
    return original
end

@noinline function _fallback_call!(context,name;
    environment,sampled_environment,publish,objects)
    lease=context.calls.lease
    _disable!(lease)
    lease.counters.fallback_calls+=1
    return PSE.run_call!(_fallback_context!(context),name;
        environment,sampled_environment,publish,objects)
end

# Keep one real numerical call frame per dependency. Forcing every scientific
# body through nested try/finally regions into an ancestor catch/retry produced
# a native fault on Julia 1.13.1; this boundary preserves normal unwinding.
@noinline function _run_child!(node::DirectNode,parent,publish,sampled)
    child=node.context
    child.time=parent.time
    child.constants=parent.constants
    child.publication_allowed=publish && parent.publication_allowed
    child.environment=parent.environment
    environment=sampled isa PSE.UnspecifiedModelEnvironment ?
        PSE._model_environment_for_binding(parent.environment_bindings,node.application,
            node.environment_binding,parent.time,parent.environment) : sampled
    node.in_use=true
    try
        status=Native._native_kernel_status(node.view,node.model,parent.calls.status_strategy)
        counters=parent.calls.lease.counters
        counters.calls+=1
        counters.fields+=_direct_field_count(node.view)
        counters.native_fields+=Native._view_native_fields(node.view)
        PSE.run!(node.model,status,environment,parent.constants,child)
        if child.publication_allowed
            isempty(node.outputs) || PSE._model_publish_runtime_outputs!(node.outputs,child.time)
            PSE._record_model_call_publication!(child.output_retention,node.application.id,child.time)
        end
    finally
        node.in_use=false
        node.owner===nothing || (node.owner.call_context_cache.in_use=false)
    end
    return nothing
end

@inline function _run_entry!(entry::DirectEntry,context,name,environment,sampled,publish,objects)
    lease=context.calls.lease
    if !lease.disabled && lease.running && lease.task==objectid(current_task()) &&
       environment isa PSE.NoEnvironmentOverride &&
       context.environment isa PSE.NoEnvironmentOverride && objects === nothing &&
       PSE._active_call_evaluation() === nothing && !entry.node.in_use &&
       entry.generation[]==entry.expected_generation
        targets=entry.targets
        targets.time=context.time
        targets.constants=context.constants
        targets.publication_allowed=context.publication_allowed
        targets.environment=context.environment
        _run_child!(entry.node,context,publish,sampled)
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
) where {CS,A,CT<:DirectCallTable}
    !(environment isa PSE.NoEnvironmentOverride) &&
        !(sampled_environment isa PSE.UnspecifiedModelEnvironment) &&
        throw(ArgumentError("`environment` and `sampled_environment` are mutually exclusive hard-call overrides."))
    return _run_entry!(_entry(context.calls,Val(name)),context,name,environment,
        sampled_environment,publish,objects)
end
@inline function _call_model(entry::DirectEntry,context,name)
    # The capability forbids model/binding mutation during this invocation.
    # A public target request can disable later fast executions, but cannot
    # change this resolved scientific model before the refresh barrier.
    context.calls.lease.counters.lookups+=1
    return entry.node.model
end
@noinline _call_model(::Nothing,context,name)=PSE._call_model(_fallback_context!(context),name)
@inline PSE._call_model(context::PSE.RunContext{CS,A,CT},name::Val) where {CS,A,CT<:DirectCallTable}=
    _call_model(_entry(context.calls,name),context,name)

Base.@nospecializeinfer @noinline function _deferred_targets(compiled,environment,
    binding,streams,retention,constants,node,lease)
    @nospecialize compiled environment binding streams retention constants node
    deferred=DirectDeferredBatches(node,nothing,lease)
    return PSE.CallTargets{Any,Any,typeof(binding),Any,Any,typeof(constants),DirectDeferredBatches}(
        compiled,environment,binding,streams,retention,0.0,constants,true,
        PSE._NO_ENVIRONMENT_OVERRIDE,deferred,nothing,nothing,nothing)
end

# Project only the kernel's declared ports into its typed numerical interface.
# The canonical backing still provides whole-status reflection, identity and
# exact escaped references, including unrelated non-numerical metadata.
Base.@nospecializeinfer @noinline function _projected_view(status,names::Tuple,strategy)
    @nospecialize status names
    refs=Any[PSE.refvalue(status,name) for name in names]
    if strategy === :references
        local_status=PSE.Status(NamedTuple{names}(Tuple(refs)),PSE._status_identity(status),status)
        return Native.NativeReferenceView(local_status)
    end
    columns=Any[]
    indices=Int[]
    for reference in refs
        reference isa Base.RefArray || throw(ArgumentError("non_native_declared_port"))
        source=getfield(reference,:x)
        source isa Vector && isconcretetype(eltype(source)) && isbitstype(eltype(source)) ||
            throw(ArgumentError("non_scalar_declared_port"))
        push!(columns,source)
        push!(indices,getfield(reference,:i))
    end
    return Native.NativeStatusView(NamedTuple{names}(Tuple(columns)),Tuple(indices),
        PSE._status_identity(status),status)
end

Base.@nospecializeinfer @noinline function _build_node(compiled,environment,application,
    id,streams,retention,constants,strategy,status_strategy,lease,ancestors,record)
    @nospecialize compiled environment application streams retention constants
    key=(application.id,id)
    key in ancestors && throw(ArgumentError("recursive_call_graph"))
    model=PSE._application_model(application,id)
    Native.native_call_effects(typeof(model)) === :fixed_native_calls ||
        throw(ArgumentError("unknown_model_capability"))
    view=PSE._model_status_view_for_application(compiled,application,id)
    isempty(view.temporal_inputs) || throw(ArgumentError("temporal_input_boundary"))
    isempty(view.private_outputs) || throw(ArgumentError("private_output_boundary"))
    isempty(PSE._distributed_output_schema(model)) || throw(ArgumentError("distributed_output_boundary"))
    isempty(PSE.environment_outputs_(model)) || throw(ArgumentError("environment_commit_boundary"))
    outputs=PSE._runtime_model_output_streams(view.status,application,id,streams,retention)
    all(output->output isa PSE.RuntimeOutputStream,outputs) ||
        throw(ArgumentError("distributed_publication_boundary"))
    bindings=get(compiled.call_bindings_by_target,key,())
    names,entries,calls=Symbol[],Any[],Any[]
    push!(ancestors,key)
    try
        for binding in bindings
            PSE._compiled_call_mode(binding) === :manual || throw(ArgumentError("initializer_boundary"))
            # A singular fixed call is a selector contract, not today's target
            # count. Many collections must track future membership, including
            # collections retained after the root plan has been refreshed.
            binding.multiplicity === :many &&
                throw(ArgumentError("tracked_many_call_boundary"))
            length(binding.callee_application_ids)==1 && length(binding.callee_object_ids)==1 ||
                throw(ArgumentError("singular_fixed_call_required"))
            child_application=PSE._compiled_application_by_id(compiled,only(binding.callee_application_ids))
            child_id=only(binding.callee_object_ids)
            PSE._call_binding_target_matches(binding,child_application,child_id) ||
                throw(ArgumentError("singular_fixed_call_required"))
            child=_build_node(compiled,environment,child_application,child_id,streams,
                retention,constants,strategy,status_strategy,lease,ancestors,record)
            targets=_deferred_targets(compiled,environment,binding,streams,retention,constants,child,lease)
            push!(names,PSE._compiled_call_name(binding))
            push!(entries,DirectEntry(child,targets,getfield(binding,:membership_generation),
                PSE._compiled_call_membership_generation(binding)))
            push!(calls,targets)
        end
    finally
        delete!(ancestors,key)
    end
    own_ports=Tuple(unique((keys(PSE.inputs_(model))...,keys(PSE.outputs_(model))...)))
    graph_ports=Symbol[own_ports...]
    for entry in entries, name in entry.node.graph_shape.ports
        name in graph_ports || !hasproperty(view.status,name) || push!(graph_ports,name)
    end
    ports=Tuple(graph_ports)
    columns=_projected_view(view.status,ports,strategy)
    ordinary_calls=Tuple(calls)
    # The public wrapper tuple is allocated once, but no ordinary RunContext
    # shell is needed until the public view/evaluation boundary is crossed.
    owner_ref=Ref{Any}(nothing)
    table=DirectCallTable(NamedTuple{Tuple(names)}(Tuple(entries)),ordinary_calls,
        owner_ref,lease,Val(status_strategy))
    context=PSE.RunContext{Any,Any,typeof(table),Any,Any,Any,Any,typeof(constants),typeof(PSE._NO_ENVIRONMENT_OVERRIDE)}(
        compiled,environment,application,id,table,view.bound_inputs,NamedTuple(),
        streams,retention,0.0,constants,true,PSE._NO_ENVIRONMENT_OVERRIDE)
    binding=PSE._environment_binding_for(environment,application.id,id)
    node=DirectNode(model,columns,context,outputs,nothing,application,id,binding,
        view.status,view.bound_inputs,bindings,nothing,false,lease,nothing)
    owner_ref[]=node
    # The descriptor is shared by all equal graph signatures, independently of
    # organ count. IDs, model values, contexts and mutable leases stay per row.
    child_types=Tuple(typeof(entry.node.model) for entry in entries)
    shape=(typeof(model),Tuple(names),child_types,ports)
    node.graph_shape=get!(record.shapes,shape) do
        DirectGraphShape(typeof(model),Tuple(names),child_types,ports)
    end
    return node
end

struct DirectTargetView <: AbstractVector{Any}
    rows::AbstractVector
    ids::Vector{PSE.ObjectId}
end
Base.IndexStyle(::Type{DirectTargetView})=IndexLinear()
Base.size(targets::DirectTargetView)=size(targets.ids)
Base.length(targets::DirectTargetView)=length(targets.ids)
Base.getindex(targets::DirectTargetView,index::Int)=_ordinary_owner!(targets.rows[index])
PSE._model_execution_target_id(targets::DirectTargetView,index)=targets.ids[index]

mutable struct DirectRootBatch{R,E} <: PSE.AbstractExecutionBatch
    rows::R
    application::Any
    targets::DirectTargetView
    environment_provider::E
    output_publication::Any
    compiled::Any
    environment_bindings::Any
    streams::Any
    retention::Any
    constants::Any
    record::DirectRecord
end
PSE._execution_batch_requires_full_refresh(::DirectRootBatch)=true

# Retire the private representation before the logical refresh consumes its
# old bindings. Public collections already handed to a kernel must keep their
# original owners and call-cache tree when ordinary PSE would reuse that tree.
# Creating owners after semantic refresh could record a new binding signature
# over an old deferred child and incorrectly authorize reuse of stale targets.
Base.@nospecializeinfer @noinline function _retire_node!(node)
    @nospecialize node
    owner=_ordinary_owner!(node)
    for entry in values(node.context.calls.entries)
        _retire_node!(entry.node)
        _materialize!(entry.targets.execution_batches)
    end
    return owner
end

function PSE._capture_execution_batch_refresh_state!(batch::DirectRootBatch,model)
    for node in batch.rows
        _retire_node!(node)
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _retired_execution_batches(batch::DirectRootBatch)
    @nospecialize batch
    owners=Any[_retire_node!(node) for node in batch.rows]
    batches=PSE.AbstractExecutionBatch[]
    isempty(owners) && return batches
    first_index=firstindex(owners)
    owner_type=typeof(owners[first_index])
    for index in (first_index+1):lastindex(owners)
        typeof(owners[index])===owner_type && continue
        push!(batches,PSE.CompiledExecutionBatch(batch.application,
            PSE._typed_model_execution_targets(owners,first_index,index-1),
            batch.environment_provider,batch.output_publication))
        first_index=index
        owner_type=typeof(owners[index])
    end
    push!(batches,PSE.CompiledExecutionBatch(batch.application,
        PSE._typed_model_execution_targets(owners,first_index,lastindex(owners)),
        batch.environment_provider,batch.output_publication))
    return batches
end

Base.@nospecializeinfer @noinline function _ordinary_shadow_execution_plan(previous)
    @nospecialize previous
    # Another prototype may have its own lifecycle ownership. Do not convert
    # only part of a mixed alternative plan and bypass that owner's protocol.
    all(batch->batch isa PSE.CompiledExecutionBatch || batch isa DirectRootBatch,
        previous.batches) || return nothing
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    for group in previous.groups
        selected=PSE.AbstractExecutionBatch[]
        for batch in group.batches
            if batch isa DirectRootBatch
                append!(selected,_retired_execution_batches(batch))
            else
                push!(selected,batch)
            end
        end
        push!(groups,PSE.CompiledApplicationExecutionGroup(group.application,selected))
        append!(batches,selected)
    end
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,
            length(previous.groups_by_application_slot)),
        previous.schedule,previous.model_revision,previous.environment_revision,
        previous.shared_target_plans)
end

Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::DirectRootBatch,previous,compiled,environment_bindings,streams,
    retention,constants,performance,changed_application_ids,changed_targets,
)
    @nospecialize previous compiled environment_bindings streams retention constants performance changed_application_ids changed_targets
    shadow=_ordinary_shadow_execution_plan(previous)
    shadow===nothing && return nothing
    # Every shadow batch is ordinary, so this delegates all model, schema,
    # topology, environment and binding validity decisions to the core refresh
    # without revisiting this alternative-plan callback.
    return PSE._refresh_model_execution_plan(shadow,compiled,environment_bindings,
        streams,retention,constants,performance,changed_application_ids,changed_targets)
end

Base.@nospecializeinfer @noinline function _ordinary_root!(node,compiled,environment,
    time,constants,streams,retention,sampled,publish)
    @nospecialize node compiled environment constants streams retention sampled
    owner=_ordinary_owner!(node)
    PSE._prepare_model_execution_context!(owner.context,compiled,environment,
        node.application,node.object_id,owner.bound_inputs,owner.output_targets,
        streams,retention,float(time),constants)
    PSE._run_model_execution_target!(compiled,environment,node.application,owner,
        float(time),constants,streams,retention,sampled,publish)
    node.lease.counters.ordinary_roots+=1
    return nothing
end

@noinline function _numerical_rows!(batch::DirectRootBatch,environment,constants,time)
    for node in batch.rows
        if node.lease.disabled
            _ordinary_root!(node,batch.compiled,batch.environment_bindings,time,
                constants,batch.streams,batch.retention,environment,
                batch.output_publication.enabled)
            continue
        end
        lease=node.lease
        lease.running,lease.task=true,objectid(current_task())
        node.in_use=true
        try
            context=node.context
            context.time=float(time)
            context.constants=constants
            context.publication_allowed=true
            context.environment=PSE._NO_ENVIRONMENT_OVERRIDE
            status=Native._native_kernel_status(node.view,node.model,context.calls.status_strategy)
            lease.counters.roots+=1
            lease.counters.fields+=_direct_field_count(node.view)
            lease.counters.native_fields+=Native._view_native_fields(node.view)
            Base.@inline PSE.run!(node.model,status,environment,constants,context)
            batch.output_publication.enabled &&
                PSE._model_publish_runtime_outputs!(node.outputs,time)
        finally
            node.in_use=false
            node.owner===nothing || (node.owner.call_context_cache.in_use=false)
            lease.running,lease.task=false,UInt(0)
        end
    end
    return nothing
end

Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::DirectRootBatch{R,E},compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings,time::Real,constants::C,
    streams,retention,
) where {R,E,C}
    @nospecialize compiled environment streams retention
    sampled=PSE._model_execution_batch_environment(batch.environment_provider,
        environment,batch.application,time)
    _numerical_rows!(batch,sampled,constants,time)
    return nothing
end

function PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,
    batch::DirectRootBatch,time::Real)
    sampled=PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings,batch.application,time)
    return sampled,batch.output_publication.enabled
end
function PSE._explain_execution_batch(batch::DirectRootBatch,index)
    first_node=first(batch.rows)
    return (batch_index=index,application_id=batch.application.id,
        process=batch.application.process,object_ids=[id.value for id in batch.targets.ids],
        batch_size=length(batch.rows),target_type=DirectTargetView,
        model_type=typeof(first_node.model),status_type=typeof(first_node.view),
        input_bindings_type=Tuple{},call_bindings_type=typeof(first_node.call_bindings),
        call_capability=:direct_fixed_calls,output_variables=batch.output_publication.variables,
        output_publication=batch.output_publication.enabled ? :direct_stream_bindings : :none,
        environment_binding_type=typeof(batch.environment_provider),
        inner_loop_dispatch=:typed_direct_call_graph)
end

_node_count(node)=1+sum(entry->_node_count(entry.node),values(node.context.calls.entries);init=0)
Base.@nospecializeinfer @noinline function _lower_application(compiled,environment,application,
    streams,retention,constants,strategy,status_strategy,record)
    @nospecialize compiled environment application streams retention constants
    isempty(application.target_ids) && return (reason=:empty_application,batches=nothing)
    provider=Lean._provider(environment,application,first(application.target_ids))
    provider isa PSE.UnspecifiedModelEnvironment && return (reason=:per_object_environment_boundary,batches=nothing)
    rows=Any[]
    try
        for id in application.target_ids
            lease=DirectRowLease(record.counters)
            push!(rows,_build_node(compiled,environment,application,id,streams,retention,
                constants,strategy,status_strategy,lease,Set{Tuple{Symbol,PSE.ObjectId}}(),record))
        end
    catch exception
        exception isa ArgumentError || rethrow()
        return (reason=Symbol(exception.msg),batches=nothing)
    end
    ranges=UnitRange{Int}[]
    start=1
    for i in 2:length(rows)
        typeof(rows[i]) === typeof(rows[i-1]) && continue
        push!(ranges,start:i-1);start=i
    end
    push!(ranges,start:length(rows))
    batches=PSE.AbstractExecutionBatch[]
    publication=PSE._compiled_output_publication(retention,application)
    for selected in ranges
        Row=typeof(rows[first(selected)])
        typed=Row[rows[i] for i in selected]
        ids=PSE.ObjectId[node.object_id for node in typed]
        push!(batches,DirectRootBatch(typed,application,DirectTargetView(typed,ids),provider,
            publication,compiled,environment,streams,retention,constants,record))
        record.skipped_rich_targets+=sum(_node_count,typed)
        record.batches+=1
    end
    return (reason=:eligible,batches)
end

struct DirectPlanCompiler
    strategy::Symbol
    status_strategy::Symbol
    record::DirectRecord
end
Base.@nospecializeinfer @noinline function (compiler::DirectPlanCompiler)(compiled,
    environment,streams=nothing,retention=nothing,constants=nothing)
    @nospecialize compiled environment streams retention constants
    return compile_direct_call_plan(compiled,environment,streams,retention,constants;
        state_strategy=compiler.strategy,status_strategy=compiler.status_strategy,record=compiler.record)
end

Base.@nospecializeinfer @noinline function compile_direct_call_plan(compiled,environment,
    streams=nothing,retention=nothing,constants=nothing;
    state_strategy=:native,status_strategy=:direct,record=DirectRecord())
    @nospecialize compiled environment streams retention constants
    record.logical_views=length(compiled.status_views_by_target)
    groups=PSE.CompiledApplicationExecutionGroup[]
    batches=PSE.AbstractExecutionBatch[]
    manual=PSE._manual_call_application_ids(compiled)
    shared=compiled.execution_policy.shared_plans ? IdDict{Any,Any}() : nothing
    for application in PSE._ordered_model_applications(compiled)
        application.id in manual && continue
        chosen=_lower_application(compiled,environment,application,streams,retention,
            constants,state_strategy,status_strategy,record)
        first_batch=length(batches)+1
        if chosen.reason === :eligible
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
        app_batches=batches[first_batch:end]
        chosen.reason === :eligible && (app_batches=Lean._bounded_application_batches(app_batches))
        push!(groups,PSE.CompiledApplicationExecutionGroup(application,app_batches))
    end
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,length(compiled.scenario_plan.applications)),
        PSE._runtime_application_schedule(compiled.scenario_plan.application_schedule),
        compiled.revision,environment.environment_revision,shared)
end

Base.@nospecializeinfer @noinline function prepare_direct_calls(model::PSE.CompositeModel;
    steps::Integer=0,outputs=:none,performance::Bool=false,state_strategy::Symbol=:native,
    status_strategy::Symbol=:direct,constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    state_strategy in (:native,:references) || throw(ArgumentError("Unknown direct state strategy"))
    status_strategy in (:refs,:direct) || throw(ArgumentError("Unknown direct status strategy"))
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    state_strategy === :native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native direct calls require native storage from allocation"))
    record=DirectRecord()
    compiler=performance ? PSE.compile_model_execution_plan :
        DirectPlanCompiler(state_strategy,status_strategy,record)
    simulation=PSE.run!(model;steps=0,outputs,performance,constants,
        _execution_plan_compiler=compiler)
    _records[simulation]=record
    steps==0 || PSE.continue!(simulation;steps)
    return simulation
end

function direct_call_report(simulation::PSE.Simulation)
    record=get(_records,simulation,nothing)
    record===nothing && throw(ArgumentError("Simulation was not prepared by prepare_direct_calls"))
    c=record.counters
    live=count(batch->batch isa DirectRootBatch,simulation.execution_plan.batches)
    return (executed_numerical_roots=c.roots,executed_numerical_calls=c.calls,
        executed_native_column_fields=c.native_fields,executed_numerical_fields=c.fields,
        typed_model_lookups=c.lookups,fallback_calls=c.fallback_calls,
        ordinary_root_executions=c.ordinary_roots,lazy_materializations=c.lazy_materializations,
        skipped_rich_targets=record.skipped_rich_targets,
        constructed_rich_targets=record.initial_rich_targets+c.rich_targets,
        logical_status_views_retained=record.logical_views,direct_batches_prepared=record.batches,
        live_direct_batches=live,shared_graph_shapes=length(record.shapes),
        numerical_scalar_copies=false,scientific_kernels=:original,
        initial_execution_plan=:direct_from_logical_bindings,
        ordinary_context_preparation=:lazy_on_public_fallback_or_materialization,
        public_target_materialization=:permanent_row_fallback_with_shared_ordinary_cache_tree,
        refresh_policy=:retire_original_owner_tree_then_ordinary_refresh,reasons=copy(record.reasons))
end

end
