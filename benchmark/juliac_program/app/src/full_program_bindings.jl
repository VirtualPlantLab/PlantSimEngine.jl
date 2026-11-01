# Concrete bindings for the full cohort runtime. Topology and ObjectIds remain
# runtime data; source application slots and payload schemas are static routes.
mutable struct FullBinding{R,TEMP,MULT,T,REF}
    route::R
    reference::REF
    ids::Vector{ObjectId{Int}}
    initial::Dict{Int,T}
end

function _prototype_full_binding(route::FullInputRoute{S,V,TEMP,MULT,T},initial_value) where {S,V,TEMP,MULT,T}
    reference=MULT===:many ? Ref(PSE.RefVector(Base.RefValue{T}[])) : Ref(deepcopy(initial_value)::T)
    return FullBinding{typeof(route),TEMP,MULT,T,typeof(reference)}(
        route,reference,ObjectId{Int}[],Dict{Int,T}())
end

function _full_selector_scope(criteria)
    haskey(criteria,:within) && return criteria.within
    for atom in criteria.selectors
        atom isa PSE.Relation || return atom
    end
    return nothing
end
function _full_selector_relation(criteria)
    haskey(criteria,:relation) && return criteria.relation
    for atom in criteria.selectors
        atom isa PSE.Relation && return atom.relation
    end
    return nothing
end
function _full_in_subtree(node,root)
    current=node
    while !isnothing(current)
        MTG.node_id(current)==MTG.node_id(root) && return true
        current=MTG.parent(current)
    end
    return false
end
function _full_ancestor(origin,scale;include_self=false)
    current=include_self ? origin : MTG.parent(origin)
    while !isnothing(current)
        (isnothing(scale) || MTG.symbol(current)===scale) && return current
        current=MTG.parent(current)
    end
    return nothing
end
_full_scope_matches(::Nothing,origin,node)=true
_full_scope_matches(::PSE.SceneScope,origin,node)=true
_full_scope_matches(::PSE.Self,origin,node)=MTG.node_id(origin)==MTG.node_id(node)
_full_scope_matches(::PSE.Subtree,origin,node)=_full_in_subtree(node,origin)
function _full_scope_matches(::PSE.SelfPlant,origin,node)
    root=_full_ancestor(origin,:Plant;include_self=true)
    return !isnothing(root) && _full_in_subtree(node,root)
end
function _full_scope_matches(scope::PSE.Ancestor,origin,node)
    root=_full_ancestor(origin,scope.scale)
    return !isnothing(root) && _full_in_subtree(node,root)
end
function _full_relation_matches(relation,origin,node)
    isnothing(relation) && return true
    same=MTG.node_id(origin)==MTG.node_id(node)
    relation===:self && return same
    originparent=MTG.parent(origin); nodeparent=MTG.parent(node)
    relation===:parent && return !isnothing(originparent) && MTG.node_id(originparent)==MTG.node_id(node)
    relation===:children && return !isnothing(nodeparent) && MTG.node_id(nodeparent)==MTG.node_id(origin)
    relation===:ancestors && return !same && _full_in_subtree(origin,node)
    relation===:descendants && return !same && _full_in_subtree(node,origin)
    relation===:siblings && return !same && !isnothing(originparent) && !isnothing(nodeparent) &&
        MTG.node_id(originparent)==MTG.node_id(nodeparent)
    throw(ArgumentError("unsupported full-layout relation"))
end
function _full_matches(selector,state,origin,node)
    criteria=PSE.criteria(selector)
    scale=get(criteria,:scale,nothing)
    (isnothing(scale) || (scale isa Tuple ? MTG.symbol(node) in scale : MTG.symbol(node)===scale)) || return false
    scope=_full_selector_scope(criteria)
    relation=_full_selector_relation(criteria)
    if scope isa PSE.Ancestor && scale===scope.scale && isnothing(relation)
        ancestor=_full_ancestor(origin,scope.scale)
        return !isnothing(ancestor) && MTG.node_id(node)==MTG.node_id(ancestor)
    end
    if isnothing(scope) && isnothing(relation) && isnothing(scale)
        return MTG.node_id(origin)==MTG.node_id(node)
    end
    _full_scope_matches(scope,origin,node) || return false
    return _full_relation_matches(relation,origin,node)
end

function _full_append_binding_source!(entries,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T},
                                      ::Val{SOURCE},step,initial) where {S,V,TEMP,MULT,T,SOURCE}
    C,SLOT=SOURCE
    cohort=state.cohorts[C]
    limit=MULT===:many ? cohort.committed : length(cohort.ids)
    for row in 1:limit
        node=cohort.nodes[row]
        _full_matches(route.selector,state,origin,node) || continue
        id=cohort.ids[row]
        source=PSE.refvalue(cohort.rows[row],V)::Base.RefValue{T}
        if TEMP
            SLOT==0 && throw(ArgumentError("temporal inputs require an output producer"))
            fallback=get!(initial,id) do
                deepcopy(source[])
            end
            value=_full_previous(state,Val(SLOT),Val(V),id,step,fallback)::T
            push!(entries,(id,Ref(deepcopy(value))))
        else
            push!(entries,(id,source))
        end
    end
    return nothing
end
_full_append_binding_sources!(entries,state,origin,route,::Tuple{},step,initial)=nothing
function _full_append_binding_sources!(entries,state,origin,route,sources::Tuple,step,initial)
    _full_append_binding_source!(entries,state,origin,route,first(sources),step,initial)
    _full_append_binding_sources!(entries,state,origin,route,_schema_tail(sources),step,initial)
    return nothing
end
function _full_binding_entries(route::FullInputRoute{S,V,TEMP,MULT,T},state,origin,step,initial) where {S,V,TEMP,MULT,T}
    entries=Tuple{Int,Base.RefValue{T}}[]
    _full_append_binding_sources!(entries,state,origin,route,map(Val,S),step,initial)
    sort!(entries;by=first)
    for index in 2:length(entries)
        entries[index-1][1]!=entries[index][1] || throw(ArgumentError("duplicate selected source object"))
    end
    return entries
end
function _refresh_full_binding!(binding::FullBinding{R,TEMP,MULT,T},state,origin,step;initialize=false) where {R,TEMP,MULT,T}
    entries=_full_binding_entries(binding.route,state,origin,step,binding.initial)
    empty!(binding.ids)
    for (id,reference) in entries
        push!(binding.ids,ObjectId(id))
    end
    if MULT===:many
        binding.reference[]=PSE.RefVector(Base.RefValue{T}[reference for (_,reference) in entries])
    elseif MULT===:one
        length(entries)==1 || throw(ArgumentError("One input requires exactly one source object"))
        binding.reference=only(entries)[2]
    elseif MULT===:optional_one
        length(entries)<=1 || throw(ArgumentError("OptionalOne input requires at most one source object"))
        isempty(entries) || (binding.reference=only(entries)[2])
    else
        throw(ArgumentError("unsupported full-layout multiplicity"))
    end
    return nothing
end
function _make_full_binding(route,state,origin,initial_value)
    binding=_prototype_full_binding(route,initial_value)
    _refresh_full_binding!(binding,state,origin,state.step+1;initialize=true)
    return binding
end
function _full_bound_input(binding::FullBinding{R,TEMP,:many}) where {R,TEMP}
    return PSE.BoundMany(binding.ids,binding.reference[])
end
_full_bound_input(binding)=throw(ArgumentError("bound_input requires a declared Many input"))
Base.@constprop :aggressive function PSE.bound_input(context::CohortContext{<:FullApplication},name::Symbol)
    return _full_bound_input(getproperty(context.application.bindings[context.row],name))
end

struct FullOutputTargets{C}
    columns::C
    ids::Vector{ObjectId{Int}}
end
PSE.object_ids(targets::FullOutputTargets)=PSE.BoundManyObjectIds(targets.ids)
Base.length(targets::FullOutputTargets)=length(targets.ids)
Base.isempty(targets::FullOutputTargets)=isempty(targets.ids)
Base.eachindex(targets::FullOutputTargets)=eachindex(targets.ids)

function _full_append_output_cohort!(entries,state,origin,route::FullOutputRoute{CS,V,D},
                                     ::Val{C},::Type{T},committed) where {CS,V,D,C,T}
    cohort=state.cohorts[C]
    limit=D && committed ? cohort.committed : length(cohort.ids)
    for row in 1:limit
        _full_matches(route.selector,state,origin,cohort.nodes[row]) || continue
        reference=PSE.refvalue(cohort.rows[row],V)::Base.RefValue{T}
        push!(entries,(cohort.ids[row],reference))
    end
    return nothing
end
_full_append_output_cohorts!(entries,state,origin,route,::Tuple{},T,committed)=nothing
function _full_append_output_cohorts!(entries,state,origin,route,cohorts::Tuple,T,committed)
    _full_append_output_cohort!(entries,state,origin,route,first(cohorts),T,committed)
    _full_append_output_cohorts!(entries,state,origin,route,_schema_tail(cohorts),T,committed)
    return nothing
end
function _full_output_column(route::FullOutputRoute{CS,V,D},state,origin;committed=true) where {CS,V,D}
    T=typeof(state.cohorts[first(CS)].defaults[V])
    entries=Tuple{Int,Base.RefValue{T}}[]
    _full_append_output_cohorts!(entries,state,origin,route,map(Val,CS),T,committed)
    sort!(entries;by=first)
    ids=ObjectId{Int}[ObjectId(id) for (id,_) in entries]
    references=Base.RefValue{T}[reference for (_,reference) in entries]
    return ids,PSE.RefVector(references)
end
function _full_output_targets(context,::Val{NAMES}) where {NAMES}
    isempty(NAMES) && throw(ArgumentError("request at least one output variable"))
    origin=context.application.cohort.nodes[context.row]
    selected=map(NAMES) do name
        route=getproperty(context.application.recipe.outputs,name)
        _full_output_column(route,context.state,origin)
    end
    ids=first(selected)[1]
    all(column->column[1]==ids,selected) || throw(ArgumentError("requested output columns have different destination objects"))
    columns=NamedTuple{NAMES}(map(last,selected))
    return FullOutputTargets(columns,ids)
end
Base.@constprop :aggressive function PSE.output_targets(context::CohortContext{<:FullApplication},names::Tuple{Vararg{Symbol}})
    return _full_output_targets(context,Val(names))
end
