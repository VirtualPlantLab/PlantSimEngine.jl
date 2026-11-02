module RegistryPrograms

import PlantSimEngine
const PSE=PlantSimEngine
export prepare, instantiate, step!, advance!, object_records, output_records
include("typed_seed_copy.jl")

# Authoring may use PSE's resolver, but none of its executable graph objects
# cross this boundary. The runtime below owns only scientific models and typed
# data carriers. Memberships and identities stay in vectors; the original
# scientific model parameter schemas are preserved.
struct RegistryTemporal{M,R,I,S}
    reference::R
    initial::I
    streams::S
end
struct RegistryOutput{D,S,R}
    streams::S
    references::R
    horizon::Float64
end
struct RegistryCallRoute{S,I}
    members::Vector{Tuple{Int,Int}}
    ids::Vector{I}
end
struct RegistryOutputTargets{C,I}
    columns::C
    ids::I
    permutation::Vector{Int}
end
PSE.object_ids(view::RegistryOutputTargets)=PSE.BoundManyObjectIds(view.ids)
Base.length(view::RegistryOutputTargets)=length(view.ids)

struct RegistryTarget{I,M,S,C,T,B,O,P,E,EO}
    application_id::Symbol
    object_id::I
    dt::Float64
    phase::Float64
    model::M
    status::S
    calls::C
    temporal::T
    bound_inputs::B
    output_targets::O
    publication::P
    environment::E
    environment_outputs::EO
end
struct RegistryGroup{T}
    targets::Vector{T}
end
struct RegistryObject{I,S,M}
    id::I
    status::S
    metadata::M
end
struct RegistryHistory{K,S}
    key::K
    samples::S
end
struct RegistrySeed{G,O,H,E,C,R,A}
    groups::G
    objects::O
    histories::H
    environment::E
    constants::C
    order::R
    applications::A
end
struct RegistryProgram{S,P,V}
    seed::S
    copy_plan::P
    payload_schema::V
end
mutable struct RegistryState{G,O,H,E,C,R,A,V}
    groups::G
    objects::O
    histories::H
    environment::E
    constants::C
    order::R
    applications::A
    payload_schema::V
    step::Int
end

struct NoOverride end
struct NoSample end
struct RegistryContext{S,T,E}
    state::S
    target::T
    override::E
    time::Float64
    publication_allowed::Bool
end
struct RegistryCallTarget{S,R,E,I}
    state::S
    route::R
    override::E
    object_id::I
    index::Int
    time::Float64
    publication_allowed::Bool
end
struct RegistryCallTargets{V,S,R,E} <: AbstractVector{V}
    state::S
    route::R
    override::E
    time::Float64
    publication_allowed::Bool
end
Base.IndexStyle(::Type{<:RegistryCallTargets})=IndexLinear()
Base.size(targets::RegistryCallTargets)=(length(targets.route.members),)
Base.length(targets::RegistryCallTargets)=length(targets.route.members)
function Base.getindex(targets::RegistryCallTargets{V},index::Int) where {V}
    @boundscheck checkbounds(targets.route.members,index)
    return V(targets.state,targets.route,targets.override,targets.route.ids[index],index,
        targets.time,targets.publication_allowed)
end

include("registry_program_display.jl")

@generated function _each_tuple(f,items::T) where {T<:Tuple}
    return Expr(:block,[:(f(getfield(items,$i))) for i in 1:fieldcount(T)]...,:(nothing))
end
include("object_program_maespa_environment.jl")

# These methods are exclusively host authoring. They resolve the original
# application graph once on a private copy, then discard its ordinary executor.
_typed_ids(ids)=isempty(ids) ? PSE.ObjectId{Symbol}[] : typeof(first(ids))[id for id in ids]
function _group_values(values)
    groups=Any[]
    types=DataType[]
    for value in values
        type=typeof(value)
        slot=findfirst(==(type),types)
        if isnothing(slot)
            push!(types,type); push!(groups,type[]); slot=length(groups)
        end
        push!(groups[slot],value)
    end
    return Tuple(groups)
end
_typed_temporal_initial(reference,initial,::Val{false})=initial
function _typed_temporal_initial(reference,initial,::Val{true})
    storage=reference[]
    T=eltype(storage)
    isconcretetype(T) || throw(ArgumentError("temporal Many values require a concrete admitted element schema"))
    length(initial)==length(storage) || throw(DimensionMismatch("temporal Many initial values and carrier lengths differ"))
    all(value->value isa T,initial) || throw(ArgumentError("temporal Many initial values differ from their admitted carrier schema"))
    # PSE's authoring buffer may use Vector{Any}; retain each original value
    # and its aliases while making the already-known carrier schema explicit.
    return T[value for value in initial]
end
function _lower_temporal(input::PSE.RuntimeTemporalInput)
    compiled=input.compiled
    compiled.binding.policy isa PSE.PreviousTimeStep || throw(ArgumentError(
        "fixed registry backend currently admits PreviousTimeStep temporal inputs"))
    many=compiled.binding.multiplicity===:many
    initial=_typed_temporal_initial(compiled.reference,compiled.initial,Val(many))
    return RegistryTemporal{many,typeof(compiled.reference),typeof(initial),typeof(input.source_streams)}(
        compiled.reference,initial,input.source_streams)
end
function _lower_output(output::PSE.RuntimeOutputStream)
    return RegistryOutput{false,typeof(output.stream),typeof(output.reference)}(
        output.stream,output.reference,output.dependency_horizon)
end
function _lower_output(output::PSE.RuntimeDistributedOutputStream)
    return RegistryOutput{true,typeof(output.streams),typeof(output.references)}(
        output.streams,output.references,output.dependency_horizon)
end
function _lower_output_target(view)
    ids=_typed_ids(view.binding.destination_ids)
    return RegistryOutputTargets(view.columns,ids,Vector{Int}(undef,length(ids)))
end
function _lower_many(view::PSE.BoundMany)
    return PSE.BoundMany(_typed_ids(PSE.object_ids(view)),parent(view))
end
function _call_members(raw)
    Base.@nospecialize raw
    names=Symbol[]; routes=Any[]
    for binding in raw.call_bindings
        binding.mode===:manual || throw(ArgumentError("fixed registry backend does not admit lifecycle initializers"))
        name=binding.call
        members=collect(PSE.call_targets(raw.context,name))
        push!(names,name)
        push!(routes,[(target.application.id,target.object_id) for target in members])
    end
    return NamedTuple{Tuple(names)}(Tuple(routes))
end
function _lower_calls(calls::NamedTuple,lookup)
    return NamedTuple{keys(calls)}(Tuple(begin
        locations=Tuple{Int,Int}[lookup[key] for key in members]
        slots=Tuple(sort!(unique(first.(locations))))
        ids=_typed_ids([last(key) for key in members])
        RegistryCallRoute{slots,eltype(ids)}(locations,ids)
    end for members in values(calls)))
end
function _target_projection(application,raw,atmosphere_type)
    Base.@nospecialize application raw
    environment=prepare_environment(raw.environment_binding;atmosphere_type)
    temporal=Tuple(_lower_temporal(input) for input in raw.input_bindings)
    inputs=NamedTuple{keys(raw.bound_inputs)}(Tuple(_lower_many(view) for view in values(raw.bound_inputs)))
    targets=NamedTuple{keys(raw.output_targets)}(Tuple(_lower_output_target(view) for view in values(raw.output_targets)))
    publication=Tuple(_lower_output(output) for output in raw.output_bindings)
    return (;temporal,inputs,targets,publication,environment,
        environment_outputs=keys(PSE.environment_outputs_(application.spec)),calls=_call_members(raw))
end
function _lower_target(application,raw,projection,lookup)
    Base.@nospecialize application raw projection
    return RegistryTarget(application.id,raw.object_id,float(application.clock.dt),float(application.clock.phase),
        raw.model,raw.status,_lower_calls(projection.calls,lookup),projection.temporal,
        projection.inputs,projection.targets,projection.publication,projection.environment,projection.environment_outputs)
end
function _partition(keys)
    labels=Dict{Any,Int}()
    return [get!(labels,key,length(labels)+1) for key in keys]
end
function _target_families(entries,index_by_target)
    # Initial colors contain only model/carrier/status/environment schemas and
    # declared port names. Neither identities nor instance application slots
    # participate. Refinement adds the finite callee-family neighborhood.
    classes=_partition([(typeof(raw.model),typeof(raw.status),typeof(raw.object_id),
        typeof(p.temporal),typeof(p.inputs),typeof(p.targets),typeof(p.publication),
        typeof(p.environment),p.environment_outputs,keys(p.calls)) for (_,raw,p) in entries])
    for _ in 1:length(entries)+1
        refined=_partition([(classes[index],Tuple(Tuple(sort!(unique(classes[index_by_target[key]]
            for key in members))) for members in values(p.calls))) for (index,(_,_,p)) in enumerate(entries)])
        refined==classes && return classes
        classes=refined
    end
    error("fixed registry call-family refinement did not converge")
end

Base.@nospecializeinfer function _assert_owned_graph!(seen,value)
    Base.@nospecialize value
    value isa Union{Nothing,Missing,Number,Symbol,AbstractString,Type,Module} && return nothing
    T=typeof(value)
    if value isa Union{PSE.CompositeModel,PSE.Simulation,PSE.RunContext,PSE.CallTarget} ||
       (parentmodule(T)===PSE && startswith(string(nameof(T)),"Compiled"))
        throw(ArgumentError("ordinary executable object escaped host lowering: $T"))
    end
    if ismutabletype(T)
        haskey(seen,value) && return nothing
        seen[value]=nothing
    end
    if value isa AbstractArray
        isbitstype(eltype(value)) && return nothing
        for item in value
            _assert_owned_graph!(seen,item)
        end
    elseif value isa AbstractDict
        for (key,item) in value
            _assert_owned_graph!(seen,key); _assert_owned_graph!(seen,item)
        end
    else
        for name in fieldnames(T)
            isdefined(value,name) && _assert_owned_graph!(seen,getfield(value,name))
        end
    end
    return nothing
end

Base.@nospecializeinfer function _authoring_targets(simulation)
    Base.@nospecialize simulation
    applications=simulation.compiled.applications
    existing=Dict{Any,Any}((group.application.id,target.object_id)=>target
        for group in simulation.execution_plan.groups for batch in group.batches for target in batch.targets)
    raws=Any[]
    for application in applications
        targets=Any[]
        for id in application.target_ids
            key=(application.id,id)
            target=get(existing,key,nothing)
            if isnothing(target)
                target=PSE._compiled_model_execution_target(simulation.compiled,
                    simulation.environment_bindings,application,id,simulation.temporal_streams,
                    simulation.output_retention,simulation.constants)
                existing[key]=target
            end
            push!(targets,target)
        end
        push!(raws,(application,targets))
    end
    return raws
end
Base.@nospecializeinfer function _lower_registry_seed(simulation,raws)
    Base.@nospecialize simulation raws
    private_model=simulation.model
    applications=simulation.compiled.applications
    atmosphere_type=_maespa_atmosphere_type(private_model,raws)
    any(pair->isempty(last(pair)),raws) && throw(ArgumentError("fixed registry backend requires nonempty application targets"))
    entries=[(application,raw,_target_projection(application,raw,atmosphere_type))
        for (application,targets) in raws for raw in targets]
    index_by_target=Dict((application.id,raw.object_id)=>index for (index,(application,raw,_)) in enumerate(entries))
    classes=_target_families(entries,index_by_target)
    family_rows=zeros(Int,maximum(classes))
    lookup=Dict{Any,Tuple{Int,Int}}()
    for (index,(application,raw,_)) in enumerate(entries)
        family=classes[index]; family_rows[family]+=1
        lookup[(application.id,raw.object_id)]=(family,family_rows[family])
    end
    families=[Any[] for _ in family_rows]
    for (index,(application,raw,projection)) in enumerate(entries)
        push!(families[classes[index]],_lower_target(application,raw,projection,lookup))
    end
    groups=Tuple(begin
        T=typeof(first(targets))
        all(target->typeof(target)===T,targets) || throw(ArgumentError("call-family refinement missed a heterogeneous target schema"))
        RegistryGroup(T[target for target in targets])
    end for targets in families)
    @info "Registry authoring: call families closed" families=length(groups) targets=length(entries)
    objects=_group_values([RegistryObject(object.id,object.status,
        (parent=object.parent,children=_typed_ids(object.children),scale=object.scale,kind=object.kind,
         species=object.species,geometry=PSE.geometry(object))) for object in PSE.model_objects(private_model)])
    histories=_group_values([RegistryHistory(key,stream) for (key,stream) in simulation.temporal_streams])
    order=Tuple{Int,Int}[lookup[(group.application.id,target.object_id)]
        for group in simulation.execution_plan.groups for batch in group.batches for target in batch.targets]
    application_rows=[(application.id,lookup[(application.id,first(application.target_ids))]...)
        for application in applications]
    # The entire graph already belongs to the private authoring model. Project
    # it without another copy: its shared refs/streams/backend retain their
    # aliases, and the owning ordinary model/executor have no backreferences in
    # this seed (checked below) and become unreachable when authoring returns.
    seed=RegistrySeed(groups,objects,histories,private_model.environment,simulation.constants,order,application_rows)
    _assert_owned_graph!(IdDict{Any,Nothing}(),seed)
    @info "Registry authoring: independent seed checked"
    return seed,atmosphere_type
end
Base.@nospecializeinfer function _prepare_copy_plan(seed,atmosphere_type)
    Base.@nospecialize seed
    copy_plan=TypedSeedCopies.prepare(seed;extra_types=(atmosphere_type,))
    payload_types=Tuple(unique(fieldtype(eltype(record.samples),2) for group in seed.histories for record in group))
    payload_schema=TypedSeedCopies.payload_schema(copy_plan,payload_types)
    @info "Registry authoring: typed copy schemas prepared"
    return RegistryProgram(seed,copy_plan,payload_schema)
end
"""Resolve on a private ordinary model at authoring time and lower its data.

The setup cost includes copying, ordinary resolution and this projection. The
returned program contains no ordinary model, Simulation, compiled execution
target, compiled binding, RunContext, schedule or executable fallback.
"""
function prepare(model::PSE.CompositeModel;outputs=:all,constants=PSE.Constants())
    isnothing(model.binding_cache) || throw(ArgumentError("prepare requires an uncompiled authored model"))
    private_model=deepcopy(model)
    simulation=PSE.run!(private_model;steps=0,outputs,constants)
    @info "Registry authoring: ordinary resolution complete" applications=length(simulation.compiled.applications)
    raws=_authoring_targets(simulation)
    seed,atmosphere_type=_lower_registry_seed(simulation,raws)
    program=_prepare_copy_plan(seed,atmosphere_type)
    isnothing(model.binding_cache) || error("host authoring unexpectedly mutated the input model")
    return program
end

"""Clone private numerical state through the prepared closed copy schema."""
function instantiate(program::RegistryProgram)
    seed=TypedSeedCopies.copy_seed(program.copy_plan)
    return RegistryState(seed.groups,seed.objects,seed.histories,seed.environment,seed.constants,seed.order,seed.applications,program.payload_schema,0)
end

function _materialize!(input::RegistryTemporal{false},time,schema)
    value=PSE._previous_time_step_sample(input.streams,time)
    input.reference[]=TypedSeedCopies.copy_payload(isnothing(value) ? input.initial : value,schema)
    return nothing
end
function _materialize!(input::RegistryTemporal{true},time,schema)
    storage=input.reference[]
    @inbounds for index in eachindex(input.streams)
        value=PSE._previous_time_step_sample(input.streams[index],time)
        storage[index]=TypedSeedCopies.copy_payload(isnothing(value) ? input.initial[index] : value,schema)
    end
    return nothing
end
function _publish_value!(stream,value,time,horizon,schema)
    expected=fieldtype(eltype(stream),2)
    value isa expected || throw(ArgumentError("published output changed its admitted value schema"))
    if !isempty(stream) && isapprox(last(stream)[1],time;atol=1.0e-8,rtol=0.0)
        pop!(stream)
    elseif !isempty(stream) && last(stream)[1]>time
        PSE._model_remove_sample_time!(stream,time)
    end
    push!(stream,(time,TypedSeedCopies.copy_payload(value,schema)))
    if stream isa PSE.TemporalDependencyBuffer
        cutoff=horizon<=0.0 ? time : time-horizon+1.0
        while length(stream)>2 && first(stream)[1]<cutoff-1.0e-8
            PSE._temporal_dependency_popfirst!(stream)
        end
    end
    return nothing
end
_publish!(output::RegistryOutput{false},time,schema)=_publish_value!(output.streams,output.references[],time,output.horizon,schema)
function _publish!(output::RegistryOutput{true},time,schema)
    @inbounds for index in eachindex(output.references)
        _publish_value!(output.streams[index],output.references[index],time,output.horizon,schema)
    end
    return nothing
end
_sample(binding,time,::NoOverride)=sample(binding,time)
_sample(binding,time,override)=sample(binding,time;override)
_execution_environment(target,time,override,::NoSample)=_sample(target.environment,time,override)
_execution_environment(target,time,override,environment)=environment
function _execute!(target,state,time,publish,override,sampled)
    _each_tuple(input->_materialize!(input,time,state.payload_schema),target.temporal)
    environment=_execution_environment(target,time,override,sampled)
    context=RegistryContext(state,target,override,time,publish)
    PSE.run!(target.model,target.status,environment,state.constants,context)
    publish && _each_tuple(output->_publish!(output,time,state.payload_schema),target.publication)
    return nothing
end

@generated function _run_member!(state,route::RegistryCallRoute{S},index,time,publish,override,sampled) where {S}
    branches=[:(if group==$slot
        _execute!(getfield(state.groups,$slot).targets[row],state,time,publish,override,sampled)
        return nothing
    end) for slot in S]
    return quote
        group,row=route.members[index]
        $(branches...)
        throw(ArgumentError("invalid fixed registry call membership"))
    end
end
@generated function _member_property(state,route::RegistryCallRoute{S},index,::Val{K}) where {S,K}
    K in (:status,:model) || return :(throw(ArgumentError("unknown call target property")))
    branches=[:(group==$slot && return getfield(getfield(state.groups,$slot).targets[row],$(QuoteNode(K)))) for slot in S]
    return quote
        group,row=route.members[index]
        $(branches...)
        throw(ArgumentError("invalid fixed registry call membership"))
    end
end
@inline Base.@constprop :aggressive function Base.getproperty(target::RegistryCallTarget,name::Symbol)
    name===:status && return _member_property(getfield(target,:state),getfield(target,:route),getfield(target,:index),Val(:status))
    name===:model && return _member_property(getfield(target,:state),getfield(target,:route),getfield(target,:index),Val(:model))
    return getfield(target,name)
end
@inline function _call_targets_for_route(context::RegistryContext{S,T,E},route::R) where {S,T,E,K,I,R<:RegistryCallRoute{K,I}}
    V=RegistryCallTarget{S,R,E,I}
    return RegistryCallTargets{V,S,R,E}(
        context.state,route,context.override,context.time,context.publication_allowed)
end
@generated function _call_targets_named(context::RegistryContext{S,T,E},name::Symbol) where {S,T,E}
    names=fieldnames(fieldtype(T,:calls))
    branches=[:(name===$(QuoteNode(key)) && return _call_targets_for_route(context,getfield(context.target.calls,$index)))
        for (index,key) in enumerate(names)]
    return Expr(:block,branches...,:(throw(ArgumentError("undeclared fixed registry hard call"))))
end
@inline Base.@constprop :aggressive function PSE.call_targets(context::RegistryContext,name::Symbol;objects=nothing)
    isnothing(objects) || throw(ArgumentError("fixed registry call membership cannot be changed"))
    return _call_targets_named(context,name)
end
@inline Base.@constprop :aggressive function PSE.call_model(context::RegistryContext,name::Symbol)
    targets=PSE.call_targets(context,name)
    length(targets)==1 || throw(ArgumentError("call_model requires exactly one target"))
    return _member_property(targets.state,targets.route,1,Val(:model))
end
function PSE.run_call!(target::RegistryCallTarget;publish::Bool=false,environment=NoOverride(),sampled_environment=NoSample())
    !(environment isa NoOverride) && !(sampled_environment isa NoSample) && throw(ArgumentError("conflicting call environment overrides"))
    override=environment isa NoOverride ? target.override : environment
    _run_member!(target.state,target.route,target.index,target.time,publish&&target.publication_allowed,override,sampled_environment)
    return target
end
function _run_call_route!(context,route,publish,environment,sampled_environment)
    targets=_call_targets_for_route(context,route)
    for target in targets
        PSE.run_call!(target;publish,environment,sampled_environment)
    end
    return targets
end
@generated function _run_call_named!(context::RegistryContext{S,T,E},name::Symbol,publish,environment,sampled_environment) where {S,T,E}
    names=fieldnames(fieldtype(T,:calls))
    branches=[:(name===$(QuoteNode(key)) && return _run_call_route!(context,getfield(context.target.calls,$index),
        publish,environment,sampled_environment)) for (index,key) in enumerate(names)]
    return Expr(:block,branches...,:(throw(ArgumentError("undeclared fixed registry hard call"))))
end
@inline Base.@constprop :aggressive function PSE.run_call!(context::RegistryContext,name::Symbol;publish::Bool=false,
        environment=NoOverride(),sampled_environment=NoSample(),objects=nothing)
    isnothing(objects) || throw(ArgumentError("fixed registry call membership cannot be changed"))
    return _run_call_named!(context,name,publish,environment,sampled_environment)
end
@inline Base.@constprop :aggressive PSE.bound_input(context::RegistryContext,name::Symbol)=getproperty(context.target.bound_inputs,name)
PSE.bound_input(context::RegistryContext,::Val{N}) where {N}=getfield(context.target.bound_inputs,N)
@inline Base.@constprop :aggressive PSE.output_targets(context::RegistryContext,names::Tuple)=PSE.output_targets(context,Val(names))
@generated function PSE.output_targets(context::RegistryContext,::Val{N}) where {N}
    N isa Tuple && !isempty(N) && all(n->n isa Symbol,N) && length(unique(N))==length(N) ||
        return :(throw(ArgumentError("distinct output names required")))
    columns=Expr(:tuple,[:(getfield(getfield(context.target.output_targets,$(QuoteNode(name))).columns,$(QuoteNode(name)))) for name in N]...)
    first_name=QuoteNode(first(N))
    checks=[:(getfield(context.target.output_targets,$(QuoteNode(name))).ids==first_view.ids ||
        throw(ArgumentError("unaligned output destination identities"))) for name in N]
    return quote
        first_view=getfield(context.target.output_targets,$first_name)
        $(checks...)
        RegistryOutputTargets(NamedTuple{$(QuoteNode(N))}($columns),first_view.ids,first_view.permutation)
    end
end
function PSE.commit_environment!(context::RegistryContext,accepted)
    context.publication_allowed || return nothing
    isempty(context.target.environment_outputs) && throw(ArgumentError("application does not declare environment outputs"))
    all(name->hasproperty(accepted,name),context.target.environment_outputs) || throw(ArgumentError("incomplete environment commit"))
    commit(context.target.environment,accepted,context.time)
    return nothing
end

function PSE.assign_outputs!(targets::RegistryOutputTargets,ids,columns::NamedTuple)
    keys(columns)==keys(targets.columns) || throw(ArgumentError("identified output columns must exactly cover the requested destinations"))
    length(ids)==length(targets.ids) || throw(ArgumentError("output identities do not exactly cover destinations"))
    for column in values(columns)
        length(column)==length(ids) || throw(DimensionMismatch("output column lengths differ"))
    end
    permutation=targets.permutation
    for (row,id) in enumerate(ids)
        destination=findfirst(==(PSE.ObjectId(id)),targets.ids)
        isnothing(destination) && throw(ArgumentError("unknown output destination identity"))
        for previous in 1:row-1
            permutation[previous]==destination && throw(ArgumentError("duplicate output destination identity"))
        end
        permutation[row]=destination
    end
    _assign_columns!(targets.columns,columns,permutation)
    return targets
end
function _identity_permutation(permutation)
    for index in eachindex(permutation)
        permutation[index]==index || return false
    end
    return true
end
@generated function _assign_columns!(destinations::NamedTuple{N},sources::NamedTuple{N},permutation) where {N}
    validations=[:(PSE._validate_output_column_values!(getfield(destinations,$i),getfield(sources,$i),permutation)) for i in 1:length(N)]
    alias_checks=[:(if PSE._output_columns_might_alias(getfield(destinations,$i),getfield(sources,$j))
        ($i==$j && PSE._output_columns_same_mapping(getfield(destinations,$i),getfield(sources,$j)) &&
            _identity_permutation(permutation)) ||
            throw(ArgumentError("output assignment has overlapping source and destination columns"))
    end) for i in 1:length(N) for j in 1:length(N)]
    assignments=[:(for row in eachindex(permutation)
        getfield(destinations,$i)[permutation[row]]=getfield(sources,$i)[row]
    end) for i in 1:length(N)]
    return Expr(:block,validations...,alias_checks...,assignments...,:(nothing))
end

@inline function _due(target,time)
    target.dt>0 || throw(ArgumentError("application cadence must be positive"))
    return target.dt<=1 || isapprox(mod(time-target.phase,target.dt),0;atol=1.0e-8,rtol=0)
end
@generated function _run_roots!(state::RegistryState{G,O,H,E,C,R,A,V},time) where {G,O,H,E,C,R,A,V}
    # Order is authoring metadata, but slots remain ordinary integer data.
    branches=[:(if slot==$i
        target=getfield(state.groups,$i).targets[row]
        if _due(target,time)
            _execute!(target,state,time,true,NoOverride(),NoSample())
        end
        continue
    end) for i in 1:fieldcount(G)]
    return quote
        for (slot,row) in state.order
            $(branches...)
        end
        nothing
    end
end
function step!(state::RegistryState)
    next_step=state.step+1
    _run_roots!(state,float(next_step))
    state.step=next_step
    return state
end
function advance!(state::RegistryState,steps::Integer=1)
    steps>=0 || throw(ArgumentError("steps must be nonnegative"))
    for _ in 1:steps
        step!(state)
    end
    return state
end
object_records(state::RegistryState)=Iterators.flatten(state.objects)
output_records(state::RegistryState)=Iterators.flatten(state.histories)

include("registry_program_output.jl")

end
