# Concrete bindings for the full cohort runtime. Topology and ObjectIds remain
# runtime data; source application slots and payload schemas are static routes.
mutable struct FullBinding{R,TEMP,MULT,T,REF,STAMP}
    route::R
    reference::REF
    ids::Vector{ObjectId{Int}}
    initial::Dict{Int,T}
    # Membership/Refs are reusable until a source cohort grows or replaces a
    # canonical Ref. Epoch invalidation is deliberately cohort-wide for now.
    stamp::STAMP
    valid::Bool
    locations::Vector{NTuple{4,Int}} # object ID, cohort, row, producer slot
    references::Vector{Base.RefValue{T}}
    fallback::Union{Nothing,Base.RefValue{T}}
end

function _prototype_full_binding(route::FullInputRoute{S,V,TEMP,MULT,T},initial_value) where {S,V,TEMP,MULT,T}
    reference=MULT===:many ? Ref(PSE.RefVector(Base.RefValue{T}[])) : Ref(_payload_copy(initial_value)::T)
    stamp=map(_ -> (0,UInt(0)),S)
    return FullBinding{typeof(route),TEMP,MULT,T,typeof(reference),typeof(stamp)}(
        route,reference,ObjectId{Int}[],Dict{Int,T}(),stamp,false,
        NTuple{4,Int}[],Base.RefValue{T}[],MULT===:many ? nothing : reference)
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

# These selectors identify at most one fixed node under the admitted append-
# only topology. A missing parent/ancestor or a mismatched category stays empty;
# unrelated cohort growth cannot change it. General scopes/relations still scan.
function _full_is_point_selector(selector)
    criteria=PSE.criteria(selector)
    scope=_full_selector_scope(criteria)
    relation=_full_selector_relation(criteria)
    scale=get(criteria,:scale,nothing)
    return (scope isa PSE.Ancestor && scale===scope.scale && isnothing(relation)) ||
        scope isa PSE.Self || relation===:self || relation===:parent ||
        (isnothing(scope) && isnothing(relation) && isnothing(scale))
end
function _full_point_node(selector,origin)
    criteria=PSE.criteria(selector)
    scope=_full_selector_scope(criteria)
    relation=_full_selector_relation(criteria)
    scale=get(criteria,:scale,nothing)
    if scope isa PSE.Ancestor && scale===scope.scale && isnothing(relation)
        return true,_full_ancestor(origin,scope.scale)
    elseif scope isa PSE.Self
        return true,origin
    elseif relation===:self
        return true,origin
    elseif relation===:parent
        return true,MTG.parent(origin)
    elseif isnothing(scope) && isnothing(relation) && isnothing(scale)
        return true,origin
    end
    return false,nothing
end

function _full_append_binding_source!(entries,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T},
                                      ::Val{SOURCE}) where {S,V,TEMP,MULT,T,SOURCE}
    C,SLOT=SOURCE
    cohort=state.cohorts[C]
    limit=MULT===:many ? cohort.committed : length(cohort.ids)
    fixed,node=_full_point_node(route.selector,origin)
    if fixed
        isnothing(node) && return nothing
        location=get(state.locations,MTG.node_id(node),nothing)
        isnothing(location) && return nothing
        location[1]==C && location[2]<=limit || return nothing
        _full_matches(route.selector,state,origin,node) || return nothing
        push!(entries,(MTG.node_id(node),C,location[2],SLOT))
        return nothing
    end
    for row in 1:limit
        node=cohort.nodes[row]
        _full_matches(route.selector,state,origin,node) || continue
        id=cohort.ids[row]
        push!(entries,(id,C,row,SLOT))
    end
    return nothing
end
_full_append_binding_sources!(entries,state,origin,route,::Tuple{})=nothing
function _full_append_binding_sources!(entries,state,origin,route,sources::Tuple)
    _full_append_binding_source!(entries,state,origin,route,first(sources))
    _full_append_binding_sources!(entries,state,origin,route,_schema_tail(sources))
    return nothing
end
function _full_binding_entries(route::FullInputRoute{S,V,TEMP,MULT,T},state,origin) where {S,V,TEMP,MULT,T}
    entries=NTuple{4,Int}[]
    _full_append_binding_sources!(entries,state,origin,route,map(Val,S))
    sort!(entries;by=first)
    for index in 2:length(entries)
        entries[index-1][1]!=entries[index][1] || throw(ArgumentError("duplicate selected source object"))
    end
    return entries
end

# Append-only topology makes every previously selected row stable. On a dirty
# source stamp inspect only its newly visible suffix; allocate an additions
# buffer only if that suffix contains a match for this consumer.
function _full_append_added_binding_source(added,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T},
                                           ::Val{SOURCE},old_count) where {S,V,TEMP,MULT,T,SOURCE}
    C,SLOT=SOURCE
    cohort=state.cohorts[C]
    limit=MULT===:many ? cohort.committed : length(cohort.ids)
    old_count<=limit || throw(ArgumentError("binding reuse requires append-only source membership"))
    for row in (old_count+1):limit
        _full_matches(route.selector,state,origin,cohort.nodes[row]) || continue
        isnothing(added) && (added=NTuple{4,Int}[])
        push!(added,(cohort.ids[row],C,row,SLOT))
    end
    return added
end
@generated function _full_added_binding_entries(binding,route::FullInputRoute{S,V,TEMP,MULT,T},state,origin) where {S,V,TEMP,MULT,T}
    calls=[:(added=_full_append_added_binding_source(added,state,origin,route,
        Val($(QuoteNode(source))),binding.stamp[$index][1])) for (index,source) in enumerate(S)]
    return quote
        added=nothing
        $(calls...)
        added
    end
end

# Direct finite cohort/producer projections preserve concrete source and stream
# types under safe trimming; locations contain runtime rows/IDs, never Val IDs.
@generated function _full_binding_stamp(route::FullInputRoute{S,V,TEMP,MULT},state) where {S,V,TEMP,MULT}
    values_=map(S) do source
        C=source[1]
        count=MULT===:many ? :(getfield(state.cohorts,$C).committed) : :(length(getfield(state.cohorts,$C).ids))
        :(($count,state.reference_epochs[$C]))
    end
    return Expr(:tuple,values_...)
end
@generated function _full_cached_source_ref(route::FullInputRoute{S,V,TEMP,MULT,T},state,location) where {S,V,TEMP,MULT,T}
    branch=:(throw(ArgumentError("invalid cached source cohort")))
    for C in reverse(unique(first.(S)))
        value=:(PSE.refvalue(getfield(state.cohorts,$C).rows[location[3]],$(QuoteNode(V)))::Base.RefValue{$T})
        branch=Expr(:if,:(location[2]==$C),value,branch)
    end
    return branch
end
@generated function _full_cached_previous(route::FullInputRoute{S,V,true,MULT,T},state,location,step,fallback) where {S,V,MULT,T}
    branch=:(throw(ArgumentError("invalid cached temporal producer")))
    for (C,SLOT) in reverse(S)
        value=SLOT==0 ? :(throw(ArgumentError("temporal inputs require an output producer"))) :
            :(_full_previous(state,Val($SLOT),Val($(QuoteNode(V))),location[1],step,fallback)::$T)
        branch=Expr(:if,:(location[2]==$C && location[4]==$SLOT),value,branch)
    end
    return branch
end

function _full_cached_references!(binding::FullBinding{R,TEMP,MULT,T},state,locations,step) where {R,TEMP,MULT,T}
    references=Base.RefValue{T}[]
    old=1
    for location in locations
        id=location[1]
        if TEMP
            source=_full_cached_source_ref(binding.route,state,location)
            fallback=get!(binding.initial,id) do
                _payload_copy(source[])
            end
            # _full_previous already returns an owned payload. The private
            # scratch Ref must refresh every invocation, even on a cache hit.
            value=_full_cached_previous(binding.route,state,location,step,fallback)
            while old<=length(binding.locations) && binding.locations[old][1]<id
                old+=1
            end
            if old<=length(binding.locations) && binding.locations[old][1]==id
                reference=binding.references[old]
                reference[]=value
            else
                reference=Ref(value)
            end
            push!(references,reference)
        else
            push!(references,_full_cached_source_ref(binding.route,state,location))
        end
    end
    return references
end

function _refresh_full_binding!(binding::FullBinding{R,TEMP,MULT,T},state,origin,step;initialize=false) where {R,TEMP,MULT,T}
    stamp=_full_binding_stamp(binding.route,state)
    reuse=binding.valid
    unchanged=reuse && stamp==binding.stamp
    # A fixed One/OptionalOne can keep its validated membership across unrelated
    # source growth/rebinding. Many must still observe committed membership.
    fixed=binding.valid && !unchanged && MULT!==:many && _full_is_point_selector(binding.route.selector)
    if unchanged || fixed
        unchanged && !TEMP && return nothing
        binding.valid=false
        if TEMP
            for index in eachindex(binding.locations)
                location=binding.locations[index]
                binding.references[index][]=_full_cached_previous(binding.route,state,location,step,binding.initial[location[1]])
            end
        elseif isempty(binding.locations)
            binding.reference=binding.fallback::Base.RefValue{T}
        else
            reference=_full_cached_source_ref(binding.route,state,only(binding.locations))
            if binding.reference!==reference
                binding.references[1]=reference
                binding.reference=reference
            end
        end
        binding.stamp=stamp
        binding.valid=true
        return nothing
    end
    binding.valid=false
    # A dirty cohort epoch need not change this consumer. Compare canonical
    # Refs only at its cached locations, not at every row of the source cohort.
    # A selected live Ref replacement copies the reference vector/carrier;
    # unchanged selected Refs preserve every vector without allocating.
    if reuse
        added=_full_added_binding_entries(binding,binding.route,state,origin)
        if isnothing(added)
            changed=nothing
            for index in eachindex(binding.locations)
                location=binding.locations[index]
                if TEMP
                    binding.references[index][]=_full_cached_previous(binding.route,state,location,step,binding.initial[location[1]])
                else
                    reference=_full_cached_source_ref(binding.route,state,location)
                    if binding.references[index]!==reference
                        isnothing(changed) && (changed=copy(binding.references))
                        changed[index]=reference
                    end
                end
            end
            if !TEMP && !isnothing(changed)
                if MULT===:many
                    binding.reference[]=PSE.RefVector(changed)
                else
                    binding.reference=only(changed)
                end
                binding.references=changed
            elseif MULT!==:many
                binding.reference=isempty(binding.references) ? (binding.fallback::Base.RefValue{T}) : only(binding.references)
            end
            binding.stamp=stamp
            binding.valid=true
            return nothing
        end
        locations=vcat(binding.locations,added)
        sort!(locations;by=first)
        for index in 2:length(locations)
            locations[index-1][1]!=locations[index][1] || throw(ArgumentError("duplicate selected source object"))
        end
    else
        locations=_full_binding_entries(binding.route,state,origin)
    end
    # Validate membership before publishing a new carrier or a valid stamp.
    MULT===:one && length(locations)!=1 && throw(ArgumentError("One input requires exactly one source object"))
    MULT===:optional_one && length(locations)>1 && throw(ArgumentError("OptionalOne input requires at most one source object"))
    references=_full_cached_references!(binding,state,locations,step)
    ids=ObjectId{Int}[ObjectId(location[1]) for location in locations]
    if MULT===:many
        binding.reference[]=PSE.RefVector(references)
    elseif MULT===:one
        binding.reference=only(references)
    elseif MULT===:optional_one
        binding.reference=isempty(references) ? (binding.fallback::Base.RefValue{T}) : only(references)
    else
        throw(ArgumentError("unsupported full-layout multiplicity"))
    end
    binding.ids=ids
    binding.locations=locations
    binding.references=references
    binding.stamp=stamp
    binding.valid=true
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
# Output names are part of the admitted port schema. Emit direct literal field
# projections so native compilation never sees a runtime Symbol/getproperty
# callback over heterogeneous output routes or destination column types.
@generated function _full_output_targets(context,::Val{NAMES}) where {NAMES}
    NAMES isa Tuple && !isempty(NAMES) && all(name -> name isa Symbol, NAMES) ||
        return :(throw(ArgumentError("request at least one output variable as Symbols")))
    selections = Expr(:tuple, [
        :(_full_output_column(getfield(context.application.recipe.outputs, $(QuoteNode(name))),
            context.state, origin))
        for name in NAMES
    ]...)
    checks = [
        :(getfield(getfield(selected, $i), 1) == ids ||
            throw(ArgumentError("requested output columns have different destination objects")))
        for i in 2:length(NAMES)
    ]
    columns = Expr(:tuple, [:(getfield(getfield(selected, $i), 2)) for i in eachindex(NAMES)]...)
    return quote
        origin = context.application.cohort.nodes[context.row]
        selected = $selections
        ids = getfield(getfield(selected, 1), 1)
        $(checks...)
        columns = NamedTuple{$(QuoteNode(NAMES))}($columns)
        return FullOutputTargets{typeof(columns)}(columns, ids)
    end
end

Base.@constprop :aggressive function PSE.output_targets(context::CohortContext{<:FullApplication},names::Tuple{Vararg{Symbol}})
    return _full_output_targets(context,Val(names))
end
