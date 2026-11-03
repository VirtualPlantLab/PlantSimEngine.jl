# Full heterogeneous application views retain producer-specific temporal streams.
# Models and contracts are the original ModelSpec payloads; only the execution
# storage and dispatch plan differ from the ordinary CompositeModel runtime.
mutable struct FullApplication{R,M,C,S,B,H}
    const recipe::R
    const model::M
    const cohort::C
    const views::Vector{S}
    const bindings::Vector{B}
    const streams::H
end

# Only row membership is cached. Invocation contexts still sample the current
# environment, step, status view and publication policy on every call.
mutable struct FullRowOrder
    live::Vector{Int}
    committed::Vector{Int}
    live_count::Int
    committed_count::Int
end
FullRowOrder()=FullRowOrder(Int[],Int[],-1,-1)
mutable struct FullCallMembership
    live::Vector{Int}
    committed::Vector{Int}
    live_count::Int
    committed_count::Int
end
FullCallMembership()=FullCallMembership(Int[],Int[],-1,-1)

mutable struct FullState{P,C,A,N,I}
    program::P
    cohorts::C
    applications::A
    nodes::Dict{Int,N}
    locations::Dict{Int,Tuple{Int,Int}}
    identities::IdDict{Base.RefValue{Nothing},Int}
    pending::Set{Int}
    initialized::Set{Tuple{Int,Int}}
    step::Int
    active_slot::Int
    retain::Bool
    initial_objects::I
    ready::Bool
    reference_epochs::Vector{UInt}
    ordered_rows::Vector{FullRowOrder}
    call_memberships::Dict{Tuple{Int,Int},FullCallMembership}
end

include("full_program_bindings.jl")
include("full_program_history.jl")

_application_status(app::FullApplication,row)=app.views[row]
_cohort_context_type(app::FullApplication{R,M,C,S},state,cohort::Cohort,environment,constants) where {R,M,C,S} =
    CohortContext{typeof(app),typeof(state),S,typeof(environment),typeof(constants)}

Base.@noinline function _bind_full_app(recipe::FullApplicationRecipe{M,C,SLOT,INPUTS,OUTPUTS,CALLS,TO,D,V,I,O,E,B,S,H},models,cohorts) where {M,C,SLOT,INPUTS,OUTPUTS,CALLS,TO,D,V,I,O,E,B,S,H}
    model=models[SLOT]::M
    PSE.dep(model) isa D && isequal(PSE.dep(model)::D,recipe.dependencies) || throw(ArgumentError("changed dependency schema"))
    isequal(PSE.variable_contracts_(model),recipe.contracts) || throw(ArgumentError("changed variable contracts"))
    typeof(PSE.inputs_(model))===I && typeof(PSE.outputs_(model))===O && typeof(PSE.environment_inputs_(model))===E || throw(ArgumentError("changed model ports"))
    cohort=cohorts[C]
    streams=_make_full_streams(recipe,model)::H
    return FullApplication{typeof(recipe),M,typeof(cohort),S,B,H}(
        recipe,model,cohort,S[],B[],streams)
end

_private_parameter(value)=ismutabletype(typeof(value)) ? copy(value) : value
_private_parameter(value::Symbol)=value
@generated function _private_model(model::M) where {M}
    isbitstype(M) && return :(model)
    fields=[:(_private_parameter(getfield(model,$i))) for i in 1:fieldcount(M)]
    return :(M($(fields...)))
end
@generated function _private_full_models(recipes::R,models::Tuple) where {R<:Tuple}
    types=map(recipe->recipe.parameters[1],fieldtypes(R))
    calls=[:(_private_model(getfield(models,$i)::$(types[i]))) for i in eachindex(types)]
    return :($(Expr(:tuple,calls...))::$(Tuple{types...}))
end
# Application slots are finite schema. Construct their tuple explicitly so a
# large model graph does not widen through generic tuple-map inference. Organ
# counts, identities, parameter values and duration remain runtime data.
@generated function _bind_full_apps(recipes::R,models,cohorts::C) where {R<:Tuple,C<:Tuple}
    types=map(fieldtypes(R)) do recipe
        M,slot=recipe.parameters[1:2]
        B,S,H=recipe.parameters[end-2:end]
        FullApplication{recipe,M,fieldtype(C,slot),S,B,H}
    end
    calls=[:(_bind_full_app(getfield(recipes,$i),models,cohorts)) for i in eachindex(types)]
    return :($(Expr(:tuple,calls...))::$(Tuple{types...}))
end
Base.@noinline function instantiate(program::FullProgram,models::Tuple,root::N;initial,objects,retain=false) where {N<:MTG.Node}
    length(models)==length(program.applications) || throw(ArgumentError("wrong model count"))
    # One private model/RNG per application and simulation, shared by that
    # application's objects in their deterministic execution order.
    owned=_private_full_models(program.applications,models)
    cohorts=map(r->_make_cohort(r,owned,initial,N),program.cohorts)
    apps=_bind_full_apps(program.applications,owned,cohorts)
    state=FullState(program,cohorts,apps,Dict{Int,N}(),Dict{Int,Tuple{Int,Int}}(),
        IdDict{Base.RefValue{Nothing},Int}(),Set{Int}(),Set{Tuple{Int,Int}}(),0,0,Bool(retain),objects,false,
        zeros(UInt,length(cohorts)),[FullRowOrder() for _ in cohorts],
        Dict{Tuple{Int,Int},FullCallMembership}())
    _register_tree!(state,root)
    _commit_cohorts!(state.cohorts)
    _fill_full_views!(state,state.applications)
    state.ready=true
    return state
end

_full_copy(value)=_payload_copy(value)
_full_copy(value::PSE.RefVector{T}) where {T}=PSE.RefVector([Ref(_full_copy(v)) for v in value])
_full_initial_value(default::T,value) where {T}=_payload_copy(value)::T
_full_initial_value(default::PSE.RefVector{T},value::AbstractVector) where {T}=PSE.RefVector(Base.RefValue{T}[Ref{T}(v) for v in value])
Base.@constprop :aggressive function _full_imported_value(entries,id,::Val{V},default) where {V}
    for entry in entries
        if entry.object_id.value==id && haskey(entry.values,V)
            return getproperty(entry.values,V)
        end
    end
    return default
end
Base.@noinline function _full_new_status(cohort::Cohort{K,P,D,S},state,id,initial) where {K,P,D,S}
    names=keys(cohort.defaults)
    all(k->k in names,keys(initial)) || throw(ArgumentError("unknown newborn initial variable"))
    entries=getproperty(state.initial_objects,_cohort_key(cohort))
    # Tuple recursion supplies each port's concrete type, including mutable
    # defaults and reference-vector fields. No attributes carry scientific state.
    refs=_schema_pairs(cohort.defaults) do var,default
        value=haskey(initial,var) ? getproperty(initial,var) : _full_imported_value(entries,id,Val(var),default)
        Ref(_full_initial_value(default,value))
    end
    return Status(refs)::S
end
_new_status(cohort,state::FullState,node,initial)=_full_new_status(cohort,state,MTG.node_id(node),initial)

function _insert!(state::FullState,cohort,slot,node,status)
    result=_insert_registry!(state,cohort,slot,node,status)
    if state.ready
        _append_full_views!(state,state.applications,cohort,length(cohort.ids))
    end
    return result
end
_fill_full_views!(state,::Tuple{})=nothing
function _fill_full_views!(state,apps::Tuple)
    app=first(apps)
    for row in eachindex(app.cohort.ids)
        _append_full_view!(state,app,row)
    end
    _fill_full_views!(state,_schema_tail(apps))
end
_append_full_views!(state,::Tuple{},cohort::Cohort,row)=nothing
function _append_full_views!(state,apps::Tuple,cohort::Cohort{K},row) where {K}
    app=first(apps)
    _cohort_key(app.cohort)===K && _append_full_view!(state,app,row)
    _append_full_views!(state,_schema_tail(apps),cohort,row)
end
@generated function _make_full_bindings(routes::NamedTuple{K,T},stored::S,state,node) where {K,T,S<:Status}
    bindings=[:(_make_full_binding(getfield(routes,$index),state,node,
        getfield(getfield(stored,:vars),$(QuoteNode(K[index])))[])) for index in eachindex(K)]
    return Expr(:call,NamedTuple{K},Expr(:tuple,bindings...))
end
Base.@noinline function _append_full_view!(state,app::FullApplication{R,M,C,S,B,H},row) where {R,M,C,S,B,H}
    node=app.cohort.nodes[row]; stored=app.cohort.rows[row]
    bindings=_make_full_bindings(app.recipe.inputs,stored,state,node)::B
    canonical=_alias_full_canonical!(state,app.cohort,row,bindings)
    _expose_full_many!(canonical,bindings)
    push!(app.bindings,bindings)
    refs=merge(PSE._status_vars(canonical),_schema_map(binding->binding.reference,bindings))::fieldtype(S,1)
    view=Status(refs)::S
    push!(app.views,view)
    state.identities[PSE._status_identity(view)]=app.cohort.ids[row]
    return nothing
end
Base.@noinline function _refresh_full_view!(state,app::FullApplication{R,M,C,S,B,H},row,step) where {R,M,C,S,B,H}
    node=app.cohort.nodes[row]; bindings=app.bindings[row]::B; canonical=app.cohort.rows[row]
    _schema_map(bindings) do binding
        _refresh_full_binding!(binding,state,node,step)
    end
    canonical=_alias_full_canonical!(state,app.cohort,row,bindings)
    _expose_full_many!(canonical,bindings)
    refs=merge(PSE._status_vars(canonical),_schema_map(binding->binding.reference,bindings))::fieldtype(S,1)
    previous=app.views[row]
    refs===PSE._status_vars(previous) && return previous::S
    view=Status(refs)::S
    delete!(state.identities,PSE._status_identity(previous))
    app.views[row]=view
    state.identities[PSE._status_identity(view)]=app.cohort.ids[row]
    return view::S
end
@generated function _canonical_full_refs(refs::NamedTuple{K,T},bindings::NamedTuple{BK,BT}) where {K,T,BK,BT}
    fields=Any[]
    for (index,name) in enumerate(K)
        binding_index=findfirst(==(name),BK)
        binding_type=isnothing(binding_index) ? Nothing : fieldtype(BT,binding_index)
        if binding_type <: FullBinding && binding_type.parameters[2]===false && binding_type.parameters[3] in (:one,:optional_one)
            push!(fields,:(getfield(getfield(bindings,$binding_index),:reference)))
        else
            push!(fields,:(getfield(refs,$index)))
        end
    end
    return Expr(:call,NamedTuple{K},Expr(:tuple,fields...))
end
function _alias_full_canonical!(state,cohort::Cohort{K,P,D,S},row,bindings) where {K,P,D,S}
    previous=cohort.rows[row]
    refs=_canonical_full_refs(PSE._status_vars(previous),bindings)::fieldtype(S,1)
    refs===PSE._status_vars(previous) && return previous::S
    return _replace_full_status!(state,cohort,row,Status(refs)::S)
end

function _replace_full_status!(state,cohort::Cohort{K,P,D,S},row,status::S) where {K,P,D,S}
    previous=cohort.rows[row]
    if PSE._status_vars(previous)!==PSE._status_vars(status)
        slot=state.locations[cohort.ids[row]][1]
        state.reference_epochs[slot]+=UInt(1)
    end
    cohort.rows[row]=status
    state.identities[PSE._status_identity(status)]=cohort.ids[row]
    return status
end

function _full_ordered_rows(state,slot::Int,cohort;committed=true)
    order=state.ordered_rows[slot]
    if order.live_count!=length(cohort.ids)
        empty!(order.live)
        append!(order.live,sortperm(cohort.ids))
        order.live_count=length(cohort.ids)
    end
    if order.committed_count!=cohort.committed
        empty!(order.committed)
        for row in order.live
            row<=cohort.committed && push!(order.committed,row)
        end
        order.committed_count=cohort.committed
    end
    return committed ? order.committed : order.live
end
@generated function _expose_full_many!(canonical::Status,bindings::NamedTuple{K,BT}) where {K,BT}
    writes=Any[]
    for (index,name) in enumerate(K)
        binding_type=fieldtype(BT,index)
        if binding_type <: FullBinding && binding_type.parameters[2]===false && binding_type.parameters[3]===:many
            push!(writes,:(PSE.refvalue(canonical,$(QuoteNode(name)))[]=getfield(getfield(bindings,$index),:reference)[]))
        end
    end
    return Expr(:block,writes...,:(nothing))
end

Base.@noinline function _invoke_cohort!(c::CohortContext{<:FullApplication};publish=false)
    _validate_full_environment(c.application.model,c.environment)
    status=_refresh_full_view!(c.state,c.application,c.row,c.step)
    current=CohortContext(c.application,c.state,status,c.row,c.environment,c.constants,c.step,c.suppress)
    PSE.run!(current.application.model,current.status,current.environment,current.constants,current)
    publish && !current.suppress && _full_publish!(current)
    return nothing
end
function _validate_full_environment(model,environment)
    for (var,declaration) in pairs(PSE.environment_inputs_(model))
        haskey(environment,var) || throw(ArgumentError("missing global environment input"))
        expected=declaration isa Union{PSE.Required,PSE.Default} ? PSE._input_expected_type(declaration) : typeof(declaration)
        getproperty(environment,var) isa expected || throw(ArgumentError("incompatible global environment input"))
    end
end
Base.@noinline function _step_cohort_application!(state::FullState,app,environment,constants)
    state.active_slot==0 || throw(ArgumentError("unfinished lifecycle event"))
    state.active_slot=app.recipe.slot
    empty!(state.pending); empty!(state.initialized)
    # RNG-consuming models follow the ordinary object ID order, independently
    # of insertion and category storage order.
    for row in _full_ordered_rows(state,_app_cohort(app.recipe),app.cohort)
        c=CohortContext(app,state,app.views[row],row,environment,constants,state.step+1,false)
        _invoke_cohort!(c;publish=true)
    end
    _commit_cohorts!(state.cohorts)
    empty!(state.pending); empty!(state.initialized); state.active_slot=0
    return nothing
end
function step!(state::FullState,environment;constants=nothing)
    state.active_slot==0 || throw(ArgumentError("cannot retry failed lifecycle step"))
    _step_order!(state,state.program.order,environment,constants)
    state.step+=1
    return state
end

PSE.source_node(c::CohortContext{<:FullApplication})=c.application.cohort.nodes[c.row]
PSE.object_id(c::CohortContext{<:FullApplication})=ObjectId(c.application.cohort.ids[c.row])
PSE.model_status(c::CohortContext{<:FullApplication},node::MTG.Node)=_full_status(c.state,MTG.node_id(node))
function _full_status(state,id)
    slot,row=state.locations[id]
    return _full_status_at(state.cohorts,slot,row)
end
@generated function _full_status_at(cohorts::C,slot,row) where {C<:Tuple}
    types=[eltype(fieldtype(cohort,:rows)) for cohort in fieldtypes(C)]
    result_type=Union{types...}
    branch=:(throw(ArgumentError("unknown object cohort")))
    for index in reverse(eachindex(types))
        value=:(getfield(getfield(cohorts,$index),:rows)[row])
        branch=Expr(:if,:(slot==$index),value,branch)
    end
    return Expr(:(::),branch,result_type)
end
function _add_organ!(state::FullState,cohorts::Tuple,parent,link,symbol,scale,index,id,initial,slot)
    cohort=first(cohorts)
    if symbol===_cohort_key(cohort)
        status=_full_new_status(cohort,state,id,initial)
        node=_new_mtg_node(parent,id,MTG.NodeMTG(link,symbol,index,scale))
        _insert!(state,cohort,slot,node,status)
        push!(state.pending,id)
        return status
    end
    return _add_organ!(state,_schema_tail(cohorts),parent,link,symbol,scale,index,id,initial,slot+1)
end
_add_organ!(state::FullState,::Tuple{},parent,link,symbol,scale,index,id,initial,slot)=
    throw(ArgumentError("unknown organ cohort"))

function _full_call_membership(c,route::FullCallRoute{SLOT}) where {SLOT}
    cohort=c.state.applications[SLOT].cohort
    origin=c.application.cohort.nodes[c.row]
    key=(route.cache_key,c.application.cohort.ids[c.row])
    membership=get!(c.state.call_memberships,key) do
        FullCallMembership()
    end
    if membership.live_count!=length(cohort.ids)
        _full_validate_scope(route.matcher,origin)
        fixed,node=_full_point_node(route.matcher,origin)
        changed=false
        if fixed
            if membership.live_count<0 && !isnothing(node)
                location=get(c.state.locations,MTG.node_id(node),nothing)
                if !isnothing(location) && location[1]==_app_cohort(c.state.applications[SLOT].recipe) &&
                    _full_matches(route.matcher,origin,node)
                    push!(membership.live,location[2])
                end
            end
        else
            for row in (max(membership.live_count,0)+1):length(cohort.ids)
                if _full_matches(route.matcher,origin,cohort.nodes[row])
                    push!(membership.live,row)
                    changed=true
                end
            end
            changed && sort!(membership.live;by=row->cohort.ids[row])
        end
        membership.live_count=length(cohort.ids)
    end
    if membership.committed_count!=cohort.committed
        empty!(membership.committed)
        for row in membership.live
            row<=cohort.committed && push!(membership.committed,row)
        end
        membership.committed_count=cohort.committed
    end
    return membership
end

function _cohort_targets(c,route::FullCallRoute{SLOT,MODE,MULT},objects=nothing) where {SLOT,MODE,MULT}
    app=c.state.applications[SLOT]; cohort=app.cohort
    T=_cohort_context_type(app,c.state,cohort,c.environment,c.constants)
    targets=CohortTarget{T}[]
    origin=c.application.cohort.nodes[c.row]
    # Targeted initializers validate their one newborn directly. Their One
    # selects an application; it never requires scanning every live newborn.
    membership=MODE===:manual ? _full_call_membership(c,route) : nothing
    if MODE===:manual
        fullcount=length(membership.live)
        MULT===:one && !isnothing(objects) && fullcount!=1 && throw(ArgumentError("targeted One call cannot relax cardinality"))
        MULT===:optional_one && !isnothing(objects) && fullcount>1 && throw(ArgumentError("targeted OptionalOne call cannot relax cardinality"))
    end
    if !isnothing(objects)
        id=ObjectId(objects).value
        location=get(c.state.locations,id,nothing)
        isnothing(location) && throw(ArgumentError("object outside call scope"))
        slot,row=location
        slot==_app_cohort(app.recipe) && _full_matches(route.matcher,origin,cohort.nodes[row]) ||
            throw(ArgumentError("object outside call scope"))
        child=CohortContext(app,c.state,app.views[row],row,c.environment,c.constants,c.step,c.suppress)
        push!(targets,CohortTarget(child))
    else
        MODE===:manual || throw(ArgumentError("initializer requires an explicit newborn object"))
        for row in membership.committed
            child=CohortContext(app,c.state,app.views[row],row,c.environment,c.constants,c.step,c.suppress)
            push!(targets,CohortTarget(child))
        end
    end
    MULT===:one && isnothing(objects) && length(targets)!=1 && throw(ArgumentError("One call cardinality"))
    MULT===:optional_one && isnothing(objects) && length(targets)>1 && throw(ArgumentError("OptionalOne call cardinality"))
    !isnothing(objects) && length(targets)!=1 && throw(ArgumentError("object outside call scope"))
    return targets
end
_manual_route(::FullCallRoute{S,:manual}) where {S}=nothing
function _initialize_cohort!(c,route::FullCallRoute{SLOT,:initializer},id) where {SLOT}
    state=c.state
    !c.suppress || throw(ArgumentError("initializer cannot run in trial"))
    state.active_slot==c.application.recipe.slot && id in state.pending || throw(ArgumentError("initializer requires current newborn"))
    key=(SLOT,id); key in state.initialized && throw(ArgumentError("newborn already initialized"))
    target=only(_cohort_targets(c,route,ObjectId(id)))
    push!(state.initialized,key)
    PSE.run_call!(target;publish=false)
    return _full_status(state,id)
end
# Reproductive emission computes a finite set of call names at runtime. Tuple
# recursion dispatches their precompiled routes without constructing Val(name).
Base.@constprop :aggressive function PSE.call_targets(c::CohortContext{<:FullApplication},name::Symbol)
    return _full_named_targets(c,keys(c.application.recipe.calls),values(c.application.recipe.calls),name,nothing)
end
_full_named_targets(c,::Tuple{},::Tuple{},name,objects)=throw(ArgumentError("undeclared call"))
function _full_named_targets(c,names::Tuple,routes::Tuple,name,objects)
    if name===first(names)
        route=first(routes); _manual_route(route)
        return _cohort_targets(c,route,objects)
    end
    return _full_named_targets(c,_schema_tail(names),_schema_tail(routes),name,objects)
end
Base.@constprop :aggressive function PSE.run_call!(c::CohortContext{<:FullApplication},name::Symbol;publish=false,objects=nothing)
    return _full_named_run!(c,keys(c.application.recipe.calls),values(c.application.recipe.calls),name,objects,publish)
end
_full_named_run!(c,::Tuple{},::Tuple{},name,objects,publish)=throw(ArgumentError("undeclared call"))
function _full_named_run!(c,names::Tuple,routes::Tuple,name,objects,publish)
    if name===first(names)
        route=first(routes); _manual_route(route)
        targets=_cohort_targets(c,route,objects)
        for target in targets
            PSE.run_call!(target;publish)
        end
        return targets
    end
    return _full_named_run!(c,_schema_tail(names),_schema_tail(routes),name,objects,publish)
end
Base.@constprop :aggressive function PSE.run_initializer!(c::CohortContext{<:FullApplication},name::Symbol,object)
    return _full_named_initialize!(c,keys(c.application.recipe.calls),values(c.application.recipe.calls),name,ObjectId(object).value)
end
_full_named_initialize!(c,::Tuple{},::Tuple{},name,id)=throw(ArgumentError("undeclared initializer"))
function _full_named_initialize!(c,names::Tuple,routes::Tuple,name,id)
    name===first(names) && return _initialize_cohort!(c,first(routes),id)
    return _full_named_initialize!(c,_schema_tail(names),_schema_tail(routes),name,id)
end
