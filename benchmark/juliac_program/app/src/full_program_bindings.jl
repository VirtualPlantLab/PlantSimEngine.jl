# Concrete bindings for the full cohort runtime. Topology and ObjectIds remain
# runtime data; source application slots and payload schemas are static routes.
mutable struct FullBinding{R,TEMP,MULT,T,REF,STAMP}
    route::R
    reference::REF
    ids::Vector{ObjectId{Int}}
    initial::Dict{Int,T}
    # Reuse membership and Refs until a source cohort grows or a canonical
    # Ref changes for the bound port in that cohort.
    stamp::STAMP
    valid::Bool
    locations::Vector{NTuple{4,Int}} # object ID, cohort, row, producer slot
    references::Vector{Base.RefValue{T}}
    fallback::Union{Nothing,Base.RefValue{T}}
end

function _prototype_full_binding(route::FullInputRoute{S,V,TEMP,MULT,T},initial_value) where {S,V,TEMP,MULT,T}
    reference=MULT===:many ? Ref(PSE.RefVector(Base.RefValue{T}[])) : Ref(_payload_copy(initial_value)::T)
    stamp=map(_ -> (0,UInt(0),0),_full_binding_cohorts(route))
    return FullBinding{typeof(route),TEMP,MULT,T,typeof(reference),typeof(stamp)}(
        route,reference,ObjectId{Int}[],Dict{Int,T}(),stamp,false,
        NTuple{4,Int}[],Base.RefValue{T}[],MULT===:many ? nothing : reference)
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
struct FullMTGTopology end
PSE._relation_parent(::FullMTGTopology,node)=MTG.parent(node)
PSE._relation_in_subtree(::FullMTGTopology,node,root)=_full_in_subtree(node,root)
PSE._relation_same_object(::FullMTGTopology,left,right)=MTG.node_id(left)==MTG.node_id(right)

PSE._scope_ancestor(::FullMTGTopology,origin,scale,include_self)=
    _full_ancestor(origin,scale;include_self)
PSE._missing_point_scope_anchor(::FullMTGTopology,::PSE.SelfPlant,origin)=
    throw(ArgumentError("SelfPlant scope has no Plant ancestor"))
PSE._missing_point_scope_anchor(::FullMTGTopology,::PSE.Ancestor,origin)=
    throw(ArgumentError("Ancestor scope has no matching ancestor"))

function _full_nearest_ancestor(matcher)
    scope=matcher.scope
    return scope isa PSE.Ancestor && !isnothing(matcher.scale) &&
        matcher.scale===scope.scale && isnothing(matcher.relation)
end

function _full_validate_scope(matcher,origin)
    if isnothing(matcher.relation) && !_full_nearest_ancestor(matcher) &&
        matcher.scope isa Union{PSE.SelfPlant,PSE.Ancestor}
        PSE._required_scope_anchor(FullMTGTopology(),matcher.scope,origin)
    end
    return nothing
end

_full_relation(::Nothing)=nothing
_full_relation(::Val{R}) where {R}=R

function _full_matches(matcher,origin,node)
    scale=matcher.scale
    (isnothing(scale) || (scale isa Tuple ? MTG.symbol(node) in scale : MTG.symbol(node)===scale)) || return false
    topology=FullMTGTopology()
    if _full_nearest_ancestor(matcher)
        return PSE._nearest_ancestor_matches(topology,matcher.scope,origin,node)
    end
    PSE._relation_contains_object(topology,matcher.relation,origin,node) || return false
    return PSE._point_scope_contains(topology,matcher.scope,origin,node)
end

# A point selector's membership cannot change when unrelated objects are added.
function _full_is_point_selector(matcher)
    scope=matcher.scope
    relation=_full_relation(matcher.relation)
    return _full_nearest_ancestor(matcher) ||
        scope isa PSE.Self || relation===:self || relation===:parent
end
function _full_point_node(matcher,origin)
    scope=matcher.scope
    relation=_full_relation(matcher.relation)
    if _full_nearest_ancestor(matcher)
        return true,PSE._scope_anchor(FullMTGTopology(),scope,origin)
    elseif scope isa PSE.Self || relation===:self
        return true,origin
    elseif relation===:parent
        return true,MTG.parent(origin)
    end
    return false,nothing
end

_full_source_cohorts(sources)=Tuple(unique(first.(sources)))
@generated function _full_binding_cohorts(::FullInputRoute{S}) where {S}
    return QuoteNode(map(Val,_full_source_cohorts(S)))
end
_full_writer_slot(::Val{SLOT}) where {SLOT}=SLOT

_full_writer_covers(app,::FullOutputRoute{CS,V,false},node,committed) where {CS,V}=true
function _full_writer_covers(app,route::FullOutputRoute{CS,V,true},node,committed) where {CS,V}
    limit=committed ? app.cohort.committed : length(app.cohort.ids)
    for row in 1:limit
        _full_matches(route.matcher,app.cohort.nodes[row],node) && return true
    end
    return false
end

@inline function _full_candidate_covers(slot,state,node,::Val{V},committed) where {V}
    app=getfield(state.applications,_full_writer_slot(slot))
    return _full_writer_covers(app,getfield(app.recipe.outputs,V),node,committed)
end

@inline function _full_select_producer(candidates,state,node,variable,committed)
    writer=PSE._last_matching_writer(candidates) do slot
        _full_candidate_covers(slot,state,node,variable,committed)
    end
    return isnothing(writer) ? 0 : _full_writer_slot(writer)
end

@generated function _full_binding_producer(
    ::FullInputRoute{S,V,TEMP,MULT,T,M,FILTERED}, state,node,::Val{C},
) where {S,V,TEMP,MULT,T,M,FILTERED,C}
    slots=Tuple(slot for (cohort,slot) in S if cohort==C)
    !(TEMP || FILTERED) && return only(slots)
    candidates=map(Val,filter(!iszero,slots))
    isempty(candidates) && return 0
    return :(_full_select_producer($(QuoteNode(candidates)),state,node,Val($(QuoteNode(V))),$(MULT===:many)))
end

function _full_append_binding_row!(entries,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T,M,FILTERED},
                                   ::Val{C},row) where {S,V,TEMP,MULT,T,M,FILTERED,C}
    cohort=state.cohorts[C]
    node=cohort.nodes[row]
    _full_matches(route.matcher,origin,node) || return entries
    producer=_full_binding_producer(route,state,node,Val(C))
    FILTERED && MULT===:many && iszero(producer) && return entries
    isnothing(entries) && (entries=NTuple{4,Int}[])
    push!(entries,(cohort.ids[row],C,row,producer))
    return entries
end

function _full_append_binding_source!(entries,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T},
                                      ::Val{C}) where {S,V,TEMP,MULT,T,C}
    cohort=state.cohorts[C]
    limit=MULT===:many ? cohort.committed : length(cohort.ids)
    fixed,node=_full_point_node(route.matcher,origin)
    if fixed
        isnothing(node) && return nothing
        location=get(state.locations,MTG.node_id(node),nothing)
        isnothing(location) && return nothing
        location[1]==C && location[2]<=limit || return nothing
        _full_append_binding_row!(entries,state,origin,route,Val(C),location[2])
        return nothing
    end
    for row in 1:limit
        _full_append_binding_row!(entries,state,origin,route,Val(C),row)
    end
    return nothing
end
_full_append_binding_sources!(entries,state,origin,route,::Tuple{})=nothing
function _full_append_binding_sources!(entries,state,origin,route,sources::Tuple)
    _full_append_binding_source!(entries,state,origin,route,first(sources))
    _full_append_binding_sources!(entries,state,origin,route,_schema_tail(sources))
    return nothing
end
function _full_binding_entries(route::FullInputRoute{S,V,TEMP,MULT,T,M,FILTERED},state,origin) where {S,V,TEMP,MULT,T,M,FILTERED}
    _full_validate_scope(route.matcher,origin)
    entries=NTuple{4,Int}[]
    _full_append_binding_sources!(entries,state,origin,route,_full_binding_cohorts(route))
    if FILTERED && MULT!==:many
        MULT===:one && length(entries)!=1 && throw(ArgumentError("One input requires exactly one source object"))
        MULT===:optional_one && length(entries)>1 && throw(ArgumentError("OptionalOne input requires at most one source object"))
        filter!(location->!iszero(location[4]),entries)
    end
    sort!(entries;by=first)
    return entries
end

# Append-only topology makes selected rows stable unless a distributed writer
# origin joins. On ordinary destination growth inspect only the new suffix.
function _full_append_added_binding_source(added,state,origin,route::FullInputRoute{S,V,TEMP,MULT,T},
                                           ::Val{C},old_count) where {S,V,TEMP,MULT,T,C}
    cohort=state.cohorts[C]
    limit=MULT===:many ? cohort.committed : length(cohort.ids)
    old_count<=limit || throw(ArgumentError("binding reuse requires append-only source membership"))
    for row in (old_count+1):limit
        added=_full_append_binding_row!(added,state,origin,route,Val(C),row)
    end
    return added
end
@generated function _full_added_binding_entries(binding,route::FullInputRoute{S,V,TEMP,MULT,T},state,origin) where {S,V,TEMP,MULT,T}
    calls=[:(added=_full_append_added_binding_source(added,state,origin,route,
        Val($cohort),binding.stamp[$index][1])) for (index,cohort) in enumerate(_full_source_cohorts(S))]
    return quote
        added=nothing
        $(calls...)
        added
    end
end

_full_writer_origin_count(app,::FullOutputRoute{CS,V,false},committed) where {CS,V}=0
_full_writer_origin_count(app,::FullOutputRoute{CS,V,true},committed) where {CS,V}=
    committed ? app.cohort.committed : length(app.cohort.ids)

@inline function _full_writer_origin_count(state,::Val{SLOT},::Val{V},committed) where {SLOT,V}
    app=getfield(state.applications,SLOT)
    return _full_writer_origin_count(app,getfield(app.recipe.outputs,V),committed)
end

# Direct finite cohort/producer projections preserve concrete source and stream
# types under safe trimming; locations contain runtime rows/IDs, never Val IDs.
@generated function _full_binding_stamp(
    ::FullInputRoute{S,V,TEMP,MULT,T,M,FILTERED},state,
) where {S,V,TEMP,MULT,T,M,FILTERED}
    values_=map(_full_source_cohorts(S)) do C
        count=MULT===:many ? :(getfield(state.cohorts,$C).committed) : :(length(getfield(state.cohorts,$C).ids))
        origins=:(0)
        if TEMP || FILTERED
            for (cohort,slot) in S
                cohort==C && slot>0 || continue
                origins=:($origins+_full_writer_origin_count(state,Val($slot),Val($(QuoteNode(V))),$(MULT===:many)))
            end
        end
        :(($count,_full_reference_epoch(state,Val($C),Val($(QuoteNode(V)))),$origins))
    end
    return Expr(:tuple,values_...)
end

@inline function _full_writer_origins_changed(previous,current)
    for index in eachindex(previous)
        previous[index][3]!=current[index][3] && return true
    end
    return false
end

@generated function _full_cached_source_ref(route::FullInputRoute{S,V,TEMP,MULT,T},state,location) where {S,V,TEMP,MULT,T}
    branch=:(throw(ArgumentError("invalid cached source cohort")))
    for C in reverse(unique(first.(S)))
        value=:(PSE.refvalue(getfield(state.cohorts,$C).rows[location[3]],$(QuoteNode(V)))::Base.RefValue{$T})
        branch=Expr(:if,:(location[2]==$C),value,branch)
    end
    return branch
end
@generated function _full_cached_previous(route::FullInputRoute{S,V,true,MULT,T},state,location,step,initial) where {S,V,MULT,T}
    branch=quote
        iszero(location[4]) || throw(ArgumentError("invalid cached temporal producer"))
        _payload_copy(initial[location[1]])::$T
    end
    for (C,SLOT) in reverse(S)
        SLOT==0 && continue
        value=:(_full_previous(state,Val($SLOT),Val($(QuoteNode(V))),location[1],step,initial)::$T)
        branch=Expr(:if,:(location[2]==$C && location[4]==$SLOT),value,branch)
    end
    return branch
end

function _capture_full_temporal_initial!(binding,state,location)
    get!(binding.initial,location[1]) do
        source=_full_cached_source_ref(binding.route,state,location)
        _payload_copy(source[])
    end
    return nothing
end

function _capture_full_temporal_additions!(binding,state,origin)
    additions=_full_added_binding_entries(binding,binding.route,state,origin)
    isnothing(additions) && return nothing
    for location in additions
        _capture_full_temporal_initial!(binding,state,location)
    end
    return nothing
end

function _full_cached_references!(binding::FullBinding{R,TEMP,MULT,T},state,locations,step) where {R,TEMP,MULT,T}
    references=Base.RefValue{T}[]
    old=1
    for location in locations
        id=location[1]
        if TEMP
            _capture_full_temporal_initial!(binding,state,location)
            # _full_previous already returns an owned payload. The private
            # scratch Ref must refresh every invocation, even on a cache hit.
            value=_full_cached_previous(binding.route,state,location,step,binding.initial)
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

_full_filtered_scalar(::FullInputRoute{S,V,TEMP,MULT,T,M,FILTERED}) where {S,V,TEMP,MULT,T,M,FILTERED} =
    FILTERED && MULT!==:many

function _refresh_full_binding!(binding::FullBinding{R,TEMP,MULT,T},state,origin,step;initialize=false) where {R,TEMP,MULT,T}
    stamp=_full_binding_stamp(binding.route,state)
    reuse=binding.valid
    unchanged=reuse && stamp==binding.stamp
    # A fixed One/OptionalOne can keep its validated membership across unrelated
    # source growth/rebinding. Many must still observe committed membership.
    origins_changed=reuse && !unchanged && _full_writer_origins_changed(binding.stamp,stamp)
    fixed=binding.valid && !unchanged && !origins_changed && MULT!==:many && _full_is_point_selector(binding.route.matcher)
    if unchanged || fixed
        unchanged && !TEMP && return nothing
        binding.valid=false
        if TEMP
            for index in eachindex(binding.locations)
                location=binding.locations[index]
                binding.references[index][]=_full_cached_previous(binding.route,state,location,step,binding.initial)
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
    if reuse && !origins_changed && !_full_filtered_scalar(binding.route)
        added=_full_added_binding_entries(binding,binding.route,state,origin)
        if isnothing(added)
            changed=nothing
            for index in eachindex(binding.locations)
                location=binding.locations[index]
                if TEMP
                    binding.references[index][]=_full_cached_previous(binding.route,state,location,step,binding.initial)
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
_refresh_optional_temporal_default!(binding,reference)=nothing
function _refresh_optional_temporal_default!(binding::FullBinding{R,true,:optional_one,T},reference) where {R,T}
    binding.fallback=reference::Base.RefValue{T}
    isempty(binding.locations) && (binding.reference=reference)
    return nothing
end

function _make_full_binding(route,state,origin,reference)
    binding=_prototype_full_binding(route,reference[])
    _refresh_optional_temporal_default!(binding,reference)
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
        _full_matches(route.matcher,origin,cohort.nodes[row]) || continue
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
    _full_validate_scope(route.matcher,origin)
    T=typeof(state.cohorts[first(CS)].defaults[V])
    entries=Tuple{Int,Base.RefValue{T}}[]
    _full_append_output_cohorts!(entries,state,origin,route,map(Val,CS),T,committed)
    sort!(entries;by=first)
    ids=ObjectId{Int}[ObjectId(id) for (id,_) in entries]
    references=Base.RefValue{T}[reference for (_,reference) in entries]
    return ids,PSE.RefVector(references)
end
# One mutable cache per distributed variable and application origin. Replace
# its carrier on invalidation so an escaped old view keeps its membership.
mutable struct FullOutputColumnCache{T,S}
    stamp::Union{Nothing,S}
    ids::Vector{ObjectId{Int}}
    column::PSE.RefVector{T}
end

_full_output_cache_type(::Type{<:FullOutputRoute{CS,V,false}}, ::Type) where {CS,V} = Nothing
function _full_output_cache_type(::Type{<:FullOutputRoute{CS,V,true}}, ::Type{C}) where {CS,V,C}
    defaults = fieldtype(fieldtype(C, first(CS)), :defaults)
    T = fieldtype(defaults, V)
    S = NTuple{length(CS),Tuple{Int,UInt}}
    return FullOutputColumnCache{T,S}
end
function _full_output_caches_type(::Type{NamedTuple{K,R}}, ::Type{C}) where {K,R,C}
    return NamedTuple{K,Tuple{map(route -> _full_output_cache_type(route, C), fieldtypes(R))...}}
end
_new_full_output_cache(::Type{Nothing}) = nothing
_new_full_output_cache(::Type{FullOutputColumnCache{T,S}}) where {T,S} =
    FullOutputColumnCache{T,S}(nothing, ObjectId{Int}[], PSE.RefVector(Base.RefValue{T}[]))
@generated function _new_full_output_caches(::Type{NT}) where {NT<:NamedTuple}
    fields = [:( _new_full_output_cache($T)) for T in fieldtypes(NT)]
    return :(NT($(Expr(:tuple, fields...))))
end

@generated function _full_output_stamp(::FullOutputRoute{CS,V}, state) where {CS,V}
    return Expr(:tuple, [:((getfield(state.cohorts, $c).committed,
        _full_reference_epoch(state,Val($c),Val($(QuoteNode(V))))))
        for c in CS]...)
end
function _full_cached_output_column!(cache::FullOutputColumnCache{T,S}, route, state, origin) where {T,S}
    stamp = _full_output_stamp(route, state)::S
    if cache.stamp !== stamp
        ids, column = _full_output_column(route, state, origin)
        cache.ids = ids
        cache.column = column
        cache.stamp = stamp
    end
    return cache.ids, cache.column
end
_full_cached_output_column!(::Nothing, route, state, origin) =
    _full_output_column(route, state, origin)

# Output names are part of the admitted port schema. Emit direct literal field
# projections so native compilation never sees a runtime Symbol/getproperty
# callback over heterogeneous output routes or destination column types.
@generated function _full_output_targets(context,::Val{NAMES}) where {NAMES}
    NAMES isa Tuple && !isempty(NAMES) && all(name -> name isa Symbol, NAMES) ||
        return :(throw(ArgumentError("request at least one output variable as Symbols")))
    selections = Expr(:tuple, [
        :(_full_cached_output_column!(getfield(caches, $(QuoteNode(name))),
            getfield(context.application.recipe.outputs, $(QuoteNode(name))), context.state, origin))
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
        caches = context.application.output_columns[context.row]
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
