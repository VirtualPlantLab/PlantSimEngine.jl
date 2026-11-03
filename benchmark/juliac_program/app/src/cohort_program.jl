# A second compiled layout behind the same ModelSpec/prepare/instantiate grammar:
# category cohorts with different concrete schemas and original MTG topology.
import MultiScaleTreeGraph as MTG

struct ModelSeed{M,K,V,T}
    slot::Int
end
struct ExternalSeed{C,V} end
struct AliasPort{C,V,S} end
struct CohortPort{D,A}
    seed::D
    alias::A
end
struct CohortRecipe{K,P,X}
    ports::P
    external_type::Type{X}
end
struct CohortCall{S,MODE,SCOPE,MULT} end
_cohort_route_slot(::CohortCall{S}) where {S}=S
struct ApplicationRecipe{M,C,SLOT,CALLS,D,V,I,O,E}
    slot::Int
    name::Symbol
    calls::CALLS
    dependencies::D
    contracts::V
    inputs_type::Type{I}
    outputs_type::Type{O}
    environment_type::Type{E}
end
struct CohortProgram{C,A,O}
    cohorts::C
    applications::A
    order::O
    cadence_ms::Int64
end
mutable struct Cohort{K,P,D,S,N}
    recipe::P
    defaults::D
    ids::Vector{Int}
    rows::Vector{S}
    nodes::Vector{N}
    committed::Int
end
struct CohortApplication{R,M,C}
    recipe::R
    model::M
    cohort::C
end
mutable struct CohortState{P,C,A,N,V}
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
    # Each stream contains a concrete typed vector, owned by its application.
    publications::V
end

_seed(seed::ModelSeed{M,K,V,T},models,initial) where {M,K,V,T} =
    (getproperty(K === :input ? PSE.inputs_(models[seed.slot]::M) : PSE.outputs_(models[seed.slot]::M),V))::T
_seed(seed::ModelSeed{M,:input,V,T},models,initial) where {M,V,T} =
    (getproperty(PSE.inputs_(models[seed.slot]::M),V).value)::T
_seed(::ExternalSeed{C,V},models,initial) where {C,V} = getproperty(getproperty(initial,C),V)
_cohort_key(::CohortRecipe{K}) where {K} = K
_cohort_key(::Cohort{K}) where {K} = K
_app_cohort(::ApplicationRecipe{M,C}) where {M,C} = C
_app_slot(::ApplicationRecipe{M,C,SLOT}) where {M,C,SLOT} = SLOT

function _cohort_scope(selector)
    c = PSE.criteria(selector)
    all(k -> k in (:selectors,:within,:scale,:application,:process,:var),keys(c)) ||
        throw(ArgumentError("unsupported cohort selector criteria"))
    length(c.selectors) <= 1 || throw(ArgumentError("one scope per binding"))
    scope = get(c,:within,isempty(c.selectors) ? PSE.Self() : only(c.selectors))
    scope isa PSE.Self && return :self
    scope isa PSE.SelfPlant && return :plant
    scope isa PSE.SceneScope && return :scene
    throw(ArgumentError("only Self/SelfPlant/SceneScope cohort bindings are admitted"))
end
function _source_application(specs,selector,category=nothing)
    c = PSE.criteria(selector)
    matches = findall(eachindex(specs)) do i
        (!haskey(c,:application) || specs[i].name === c.application) &&
        (!haskey(c,:process) || PSE.process(specs[i]) === c.process) &&
        (isnothing(category) || PSE.criteria(specs[i].applies_to).scale === category)
    end
    length(matches) == 1 || throw(ArgumentError("binding must identify one application"))
    return only(matches)
end

function _prepare_cohorts(specs;initial)
    categories = keys(initial)
    isempty(categories) && throw(ArgumentError("provide typed external seeds per category"))
    cats = map(specs) do s
        s.applies_to isa Many || throw(ArgumentError("cohort targets must be Many"))
        c = PSE.criteria(s.applies_to)
        keys(c) == (:selectors,:scale) && isempty(c.selectors) || throw(ArgumentError("only scale cohorts are admitted"))
        c.scale in categories || throw(ArgumentError("missing category seed"))
        isempty(s.outputs_to) && isempty(s.output_routing) && isempty(s.updates) || throw(ArgumentError("unsupported writer routing"))
        isnothing(s.environment) && isempty(s.environment_bindings) && isnothing(s.environment_window) || throw(ArgumentError("global rows only"))
        isempty(PSE.environment_outputs_(s)) && isempty(PSE.dep(s)) || throw(ArgumentError("unsupported model protocol"))
        all(x->isbits(x) && !(x isa PSE.Distributed),values(PSE.outputs_(s))) || throw(ArgumentError("only scalar outputs"))
        PSE._is_default_clock(PSE.timespec(s.model)) || throw(ArgumentError("nondefault model clocks unsupported"))
        PSE._variable_contract_schema(s)
        c.scale
    end
    cadence = Dates.value(convert(Millisecond,first(specs).timestep))
    cadence > 0 && all(s -> Dates.value(convert(Millisecond,s.timestep)) == cadence,specs) || throw(ArgumentError("single fixed cadence required"))
    length(unique(map(s->s.name,specs))) == length(specs) || throw(ArgumentError("duplicate application names"))
    seeds = Dict(cat=>Dict{Symbol,Any}() for cat in categories)
    writers = Dict{Tuple{Symbol,Symbol},Int}()
    for (i,s) in enumerate(specs)
        for (var,d) in pairs(PSE.inputs_(s))
            if d isa PSE.Default
                isbits(d.value) || throw(ArgumentError("mutable defaults unsupported"))
                get!(seeds[cats[i]],var,ModelSeed{typeof(s.model),:input,var,typeof(d.value)}(i))
            elseif !(d isa PSE.Required)
                throw(ArgumentError("invalid input declaration"))
            end
        end
        for (var,value) in pairs(PSE.outputs_(s))
            key=(cats[i],var)
            haskey(writers,key) && throw(ArgumentError("duplicate writer"))
            writers[key]=i
            seeds[cats[i]][var]=ModelSeed{typeof(s.model),:output,var,typeof(value)}(i)
        end
    end
    for cat in categories, (var,value) in pairs(initial[cat])
        isbits(value) || throw(ArgumentError("external seeds must be scalar"))
        seeds[cat][var]=ExternalSeed{cat,var}()
    end
    input_producers=[Dict{Symbol,Int}() for _ in specs]
    aliases=Dict(cat=>Dict{Symbol,Any}() for cat in categories)
    edges=[Set{Int}() for _ in specs]
    manual=Set{Int}(); initializer_owners=Dict{Int,Int}()
    routes=map(Tuple(enumerate(specs))) do (i,s)
        map(values(s.calls)) do binding
            mode=binding isa PSE.Initializer ? :initializer : :manual
            selector=mode===:initializer ? binding.selector : binding
            selector isa Union{One,Many} || throw(ArgumentError("unsupported call multiplicity"))
            mode===:initializer && !(selector isa One) && throw(ArgumentError("initializer must select One"))
            scope=_cohort_scope(selector)
            target=_source_application(specs,selector,get(PSE.criteria(selector),:scale,nothing))
            if mode===:manual
                push!(manual,target)
            else
                haskey(initializer_owners,target) && throw(ArgumentError("shared initializer owner"))
                initializer_owners[target]=i
                isempty(specs[target].calls) || throw(ArgumentError("initializer cannot have calls"))
                push!(edges[i],target)
            end
            CohortCall{target,mode,scope,PSE.multiplicity(selector)}()
        end
    end
    any(i -> i in manual,keys(initializer_owners)) && throw(ArgumentError("initializer cannot be manual-only"))
    for (i,s) in enumerate(specs), (var,decl) in pairs(PSE.inputs_(s))
        if haskey(s.inputs,var)
            selector=s.inputs[var]
            selector isa One || throw(ArgumentError("only scalar One inputs in cohort layout"))
            scope=_cohort_scope(selector); c=PSE.criteria(selector)
            sourcecat=get(c,:scale,cats[i]); sourcevar=get(c,:var,var)
            if haskey(c,:application) || haskey(c,:process)
                producer=_source_application(specs,selector,sourcecat)
                _validate_program_variable_contract!((spec=s,id=s.name),var,(spec=specs[producer],id=specs[producer].name),sourcevar)
            else
                producer=get(writers,(sourcecat,sourcevar),0)
            end
            haskey(seeds[sourcecat],sourcevar) || throw(ArgumentError("unresolved source input"))
            seeds[cats[i]][var]=seeds[sourcecat][sourcevar]
            if sourcecat!==cats[i]
                scope in (:plant,:scene) || throw(ArgumentError("cross-cohort binding needs explicit scope"))
                (scope===:plant && sourcecat===:Plant || scope===:scene && sourcecat===:Scene) || throw(ArgumentError("only Plant/Scene cross-cohort inputs admitted"))
                alias=AliasPort{findfirst(==(sourcecat),categories),sourcevar,scope}()
                haskey(writers,(cats[i],var)) && throw(ArgumentError("input alias conflicts with local writer"))
                haskey(aliases[cats[i]],var) && typeof(aliases[cats[i]][var])!==typeof(alias) && throw(ArgumentError("conflicting input aliases"))
                aliases[cats[i]][var]=alias
            else
                var===sourcevar && scope===:self || throw(ArgumentError("same-cohort renaming/scope unsupported"))
            end
        else
            sourcecat=cats[i]; sourcevar=var; producer=get(writers,(sourcecat,var),0)
        end
        input_producers[i][var]=producer
        haskey(seeds[cats[i]],var) || throw(ArgumentError("unresolved required input"))
        value=_seed(seeds[cats[i]][var],map(s->s.model,specs),initial)
        value isa PSE._input_expected_type(decl) || throw(ArgumentError("incompatible input type"))
        if producer!=0
            _validate_program_variable_contract!((spec=s,id=s.name),var,(spec=specs[producer],id=specs[producer].name),sourcevar)
        end
        if !(i in manual) && producer!=0 && producer!=i
            producer in manual || push!(edges[i],producer)
        end
    end
    # Call cycles cannot become an empty root schedule. Initializer consumers
    # also run after the creator so newborn values are visible in this step.
    visiting=Set{Int}(); complete=Set{Int}()
    function visit(i)
        i in visiting && throw(ArgumentError("hard call cycle"))
        i in complete && return
        push!(visiting,i)
        for route in routes[i]
            visit(_cohort_route_slot(route))
        end
        delete!(visiting,i); push!(complete,i)
    end
    foreach(visit,eachindex(specs))
    for (i,s) in enumerate(specs), var in keys(PSE.inputs_(s))
        i in manual && continue
        producer=get(input_producers[i],var,0)
        if haskey(initializer_owners,producer)
            creator=initializer_owners[producer]
            i!=creator && i!=producer && push!(edges[i],creator)
        end
    end
    roots=[i for i in eachindex(specs) if !(i in manual)]
    all(i -> !(i in manual),values(initializer_owners)) || throw(ArgumentError("initializer creator must be scheduled"))
    order=Int[]
    while length(order)<length(roots)
        at=findfirst(i -> !(i in order) && all(in(order),edges[i]),roots)
        isnothing(at) && throw(ArgumentError("cohort schedule cycle"))
        push!(order,roots[at])
    end
    cohorts=map(categories) do cat
        names=Tuple(sort!(collect(keys(seeds[cat]));by=string))
        ports=NamedTuple{names}(map(v->CohortPort(seeds[cat][v],get(aliases[cat],v,nothing)),names))
        CohortRecipe{cat,typeof(ports),typeof(initial[cat])}(ports,typeof(initial[cat]))
    end
    apps=map(Tuple(enumerate(specs))) do (i,s)
        c=findfirst(==(cats[i]),categories)
        calls=NamedTuple{keys(s.calls)}(routes[i])
        ApplicationRecipe{typeof(s.model),c,i,typeof(calls),typeof(PSE.dep(s.model)),typeof(PSE.variable_contracts_(s)),typeof(PSE.inputs_(s)),typeof(PSE.outputs_(s)),typeof(PSE.environment_inputs_(s))}(
            i,s.name,calls,PSE.dep(s.model),PSE.variable_contracts_(s),typeof(PSE.inputs_(s)),typeof(PSE.outputs_(s)),typeof(PSE.environment_inputs_(s)))
    end
    return CohortProgram(cohorts,apps,map(Val,Tuple(order)),cadence)
end

function _make_cohort(recipe::CohortRecipe{K},models,initial,::Type{N}) where {K,N}
    typeof(initial[K]) === recipe.external_type || throw(ArgumentError("changed external schema"))
    defaults=map(port->_seed(port.seed,models,initial),recipe.ports)
    status=Status(defaults)
    return Cohort{K,typeof(recipe),typeof(defaults),typeof(status),N}(recipe,defaults,Int[],typeof(status)[],N[],0)
end
function _bind_cohort_app(recipe::ApplicationRecipe{M,C,SLOT,CALLS,D,V,I,O,E},models,cohorts) where {M,C,SLOT,CALLS,D,V,I,O,E}
    model=models[recipe.slot]::M
    isempty(PSE.environment_outputs_(model)) && PSE._is_default_clock(PSE.timespec(model)) || throw(ArgumentError("changed environment/clock protocol"))
    PSE.dep(model) isa D && isequal(PSE.dep(model)::D,recipe.dependencies) || throw(ArgumentError("changed dependency schema"))
    isequal(PSE.variable_contracts_(model),recipe.contracts) || throw(ArgumentError("changed contracts"))
    typeof(PSE.inputs_(model))===I && typeof(PSE.outputs_(model))===O && typeof(PSE.environment_inputs_(model))===E || throw(ArgumentError("changed ports"))
    return CohortApplication(recipe,model,cohorts[C])
end
function instantiate(program::CohortProgram,models::Tuple,root::N;initial,retain=false) where {N<:MTG.Node}
    length(models)==length(program.applications) || throw(ArgumentError("wrong model count"))
    cohorts=map(r->_make_cohort(r,models,initial,N),program.cohorts)
    apps=map(r->_bind_cohort_app(r,models,cohorts),program.applications)
    publications=map(a->Publication{Int,typeof(a.cohort.defaults)}[],apps)
    state=CohortState(program,cohorts,apps,Dict{Int,N}(),Dict{Int,Tuple{Int,Int}}(),IdDict{Base.RefValue{Nothing},Int}(),Set{Int}(),Set{Tuple{Int,Int}}(),0,0,Bool(retain),publications)
    _register_tree!(state,root)
    _commit_cohorts!(state.cohorts)
    return state
end
function _plant_node(node)
    current=node
    while MTG.symbol(current)!==:Plant && !isnothing(MTG.parent(current))
        current=MTG.parent(current)
    end
    return current
end
function _alias_ref(::Nothing,value,state,node)
    return Ref(value)
end
function _alias_ref(::AliasPort{C,V,S},value,state,node) where {C,V,S}
    cohort=state.cohorts[C]
    row= S===:scene ? (length(cohort.ids)==1 ? 1 : throw(ArgumentError("Scene must be unique"))) :
        (id=MTG.node_id(_plant_node(node)); findfirst(==(id),cohort.ids))
    isnothing(row) && throw(ArgumentError("missing source object"))
    reference=PSE.refvalue(cohort.rows[row],V)
    typeof(reference[])===typeof(value) || throw(ArgumentError("incompatible reference type"))
    return reference
end
function _new_status(cohort,state,node,initial)
    all(k->haskey(cohort.defaults,k),keys(initial)) || throw(ArgumentError("unknown initial variable"))
    values_=merge(cohort.defaults,initial)
    typeof(values_)===typeof(cohort.defaults) || throw(ArgumentError("changed initial type"))
    refs=NamedTuple{keys(cohort.defaults)}(map((port,value)->_alias_ref(port.alias,value,state,node),values(cohort.recipe.ports),values(values_)))
    return Status(refs)
end
function _insert_registry!(state,cohort,slot,node,status)
    id=MTG.node_id(node)
    haskey(state.nodes,id) && throw(ArgumentError("duplicate object ID"))
    push!(cohort.ids,id); push!(cohort.rows,status); push!(cohort.nodes,node)
    state.nodes[id]=node; state.locations[id]=(slot,length(cohort.ids))
    state.identities[PSE._status_identity(status)]=id
    return status
end
_insert!(state,cohort,slot,node,status)=_insert_registry!(state,cohort,slot,node,status)
function _register_tree!(state,node)
    isempty(MTG.node_attributes(node)) || throw(ArgumentError("native cohort input requires empty MTG attrs; supply typed status inputs explicitly"))
    _register_node!(state,state.cohorts,node,1)
    for child in MTG.children(node)
        _register_tree!(state,child)
    end
end
_register_node!(state,::Tuple{},node,slot)=throw(ArgumentError("unregistered node category"))
function _register_node!(state,cohorts::Tuple,node,slot)
    cohort=first(cohorts)
    if MTG.symbol(node)===_cohort_key(cohort)
        return _insert!(state,cohort,slot,node,_new_status(cohort,state,node,NamedTuple()))
    end
    return _register_node!(state,Base.tail(cohorts),node,slot+1)
end
_commit_cohorts!(::Tuple{})=nothing
function _commit_cohorts!(cohorts::Tuple)
    first(cohorts).committed=length(first(cohorts).ids)
    _commit_cohorts!(Base.tail(cohorts))
end

struct CohortContext{A,ST,S,E,C}
    application::A
    state::ST
    status::S
    row::Int
    environment::E
    constants::C
    step::Int
    suppress::Bool
end
struct CohortTarget{C}
    context::C
end
function Base.getproperty(target::CohortTarget,name::Symbol)
    c=getfield(target,:context)
    name===:context && return c
    name===:status && return c.status
    name===:object_id && return ObjectId(c.application.cohort.ids[c.row])
    throw(ArgumentError("unsupported target property"))
end
function _cohort_publish!(c)
    state=c.state; state.retain || return nothing
    app=c.application; stream=state.publications[_app_slot(app.recipe)]
    id=app.cohort.ids[c.row]
    sample=Publication(app.recipe.name,id,c.step,NamedTuple(c.status))
    old=findlast(p->p.object_id==id && p.step==c.step,stream)
    isnothing(old) ? push!(stream,sample) : (stream[old]=sample)
    return nothing
end
function _invoke_cohort!(c;publish=false)
    # Plain complete global rows only; no hidden ordinary environment sampler.
    for (var,decl) in pairs(PSE.environment_inputs_(c.application.model))
        haskey(c.environment,var) || throw(ArgumentError("missing environment field"))
    end
    PSE.run!(c.application.model,c.status,c.environment,c.constants,c)
    publish && !c.suppress && _cohort_publish!(c)
    return nothing
end
function _scope_matches(::CohortCall{SLOT,MODE,SCOPE},context,node) where {SLOT,MODE,SCOPE}
    SCOPE===:scene && return true
    origin=context.application.cohort.nodes[context.row]
    return SCOPE===:self ? MTG.node_id(origin)==MTG.node_id(node) :
        MTG.node_id(_plant_node(origin))==MTG.node_id(_plant_node(node))
end
_cohort_context_type(app,state,cohort::Cohort{K,P,D,S},environment,constants) where {K,P,D,S} =
    CohortContext{typeof(app),typeof(state),S,typeof(environment),typeof(constants)}
_application_status(app,row)=app.cohort.rows[row]
function _cohort_targets(c,route::CohortCall{SLOT,MODE,SCOPE,MULT},objects=nothing) where {SLOT,MODE,SCOPE,MULT}
    app=c.state.applications[SLOT]; cohort=app.cohort
    # Context's status type is the callee's, even for initially empty cohorts.
    T=_cohort_context_type(app,c.state,cohort,c.environment,c.constants)
    targets=CohortTarget{T}[]
    if MODE===:manual && MULT===:one && !isnothing(objects)
        count(n->_scope_matches(route,c,n),cohort.nodes)==1 || throw(ArgumentError("targeted One call cannot relax full scope cardinality"))
    end
    limit=isnothing(objects) ? cohort.committed : length(cohort.ids)
    for row in 1:limit
        id=cohort.ids[row]
        (isnothing(objects) || ObjectId(id)==ObjectId(objects)) || continue
        _scope_matches(route,c,cohort.nodes[row]) || continue
        child=CohortContext(app,c.state,_application_status(app,row),row,c.environment,c.constants,c.step,c.suppress)
        push!(targets,CohortTarget(child))
    end
    MULT===:one && isnothing(objects) && length(targets)!=1 && throw(ArgumentError("One call requires exactly one target"))
    !isnothing(objects) && length(targets)!=1 && throw(ArgumentError("requested object outside call scope"))
    return targets
end
Base.@constprop :aggressive function PSE.call_targets(c::CohortContext,name::Symbol)
    route=getproperty(c.application.recipe.calls,name)
    _manual_route(route)
    return _cohort_targets(c,route)
end
_manual_route(::CohortCall{S,:manual}) where {S}=nothing
_manual_route(route)=throw(ArgumentError("initializer requires run_initializer!"))
function PSE.run_call!(t::CohortTarget;publish=false,environment=t.context.environment)
    p=t.context
    c=CohortContext(p.application,p.state,p.status,p.row,environment,p.constants,p.step,p.suppress || !publish)
    _invoke_cohort!(c;publish)
    return t
end
Base.@constprop :aggressive function PSE.run_call!(c::CohortContext,name::Symbol;publish=false,objects=nothing)
    route=getproperty(c.application.recipe.calls,name); _manual_route(route)
    targets=_cohort_targets(c,route,objects)
    for target in targets
        PSE.run_call!(target;publish)
    end
    return targets
end
Base.@constprop :aggressive function PSE.run_initializer!(c::CohortContext,name::Symbol,object)
    route=getproperty(c.application.recipe.calls,name)
    return _initialize_cohort!(c,route,ObjectId(object).value)
end
function _initialize_cohort!(c,route::CohortCall{SLOT,:initializer},id) where {SLOT}
    state=c.state
    !c.suppress || throw(ArgumentError("initializer cannot run in a trial"))
    state.active_slot==c.application.recipe.slot && id in state.pending || throw(ArgumentError("initializer requires a newborn in the current application event"))
    key=(SLOT,id); key in state.initialized && throw(ArgumentError("newborn already initialized"))
    targets=_cohort_targets(c,route,ObjectId(id)); target=only(targets)
    push!(state.initialized,key) # reserve before kernel; failure does not allow replay
    PSE.run_call!(target;publish=false)
    return target.status
end
_initialize_cohort!(c,route,id)=throw(ArgumentError("binding is not an initializer"))
PSE.source_node(c::CohortContext,id)=c.state.nodes[ObjectId(id).value]
PSE.object_id(c::CohortContext,status::PSE.Status)=ObjectId(c.state.identities[PSE._status_identity(status)])
function PSE.add_organ!(parent::MTG.Node,c::CohortContext,link,symbol,scale::Integer;
                        index,id,attributes=NamedTuple(),initial_status=NamedTuple())
    c.state.active_slot==c.application.recipe.slot || throw(ArgumentError("no active lifecycle event"))
    haskey(c.state.nodes,MTG.node_id(parent)) && c.state.nodes[MTG.node_id(parent)]===parent || throw(ArgumentError("parent is not registered"))
    haskey(c.state.nodes,id) && throw(ArgumentError("duplicate object ID"))
    isempty(attributes) || throw(ArgumentError("only empty node attributes admitted; runtime state belongs to registry"))
    return _add_organ!(c.state,c.state.cohorts,parent,link,symbol,scale,index,id,initial_status,1)
end
function _new_mtg_node(parent::MTG.Node{M,NamedTuple{(),Tuple{}}},id,encoding) where {M<:MTG.AbstractNodeMTG}
    N=typeof(parent)
    node=N(id,nothing,N[],encoding,NamedTuple(),nothing)
    MTG.addchild!(parent,node)
    return node
end
_new_mtg_node(parent::MTG.Node,id,encoding)=MTG.Node(id,parent,encoding,NamedTuple())
_add_organ!(state,::Tuple{},parent,link,symbol,scale,index,id,initial,slot)=throw(ArgumentError("unknown organ category"))
function _add_organ!(state,cohorts::Tuple,parent,link,symbol,scale,index,id,initial,slot)
    cohort=first(cohorts)
    if symbol===_cohort_key(cohort)
        status=_new_status(cohort,state,parent,initial) # validate state before touching MTG
        node=_new_mtg_node(parent,id,MTG.NodeMTG(link,symbol,index,scale))
        _insert!(state,cohort,slot,node,status)
        push!(state.pending,id)
        return status
    end
    return _add_organ!(state,Base.tail(cohorts),parent,link,symbol,scale,index,id,initial,slot+1)
end
function _step_cohort_application!(state,app,environment,constants)
    state.active_slot==0 || throw(ArgumentError("unfinished lifecycle event; construct fresh state after failure"))
    state.active_slot=app.recipe.slot
    empty!(state.pending); empty!(state.initialized)
    for row in 1:app.cohort.committed
        c=CohortContext(app,state,app.cohort.rows[row],row,environment,constants,state.step+1,false)
        _invoke_cohort!(c;publish=true)
    end
    _commit_cohorts!(state.cohorts)
    empty!(state.pending); empty!(state.initialized); state.active_slot=0
    return nothing
end
# Static application slots are schema, never object/population counts.
_step_order!(state,::Tuple{},environment,constants)=nothing
function _step_order!(state,order::Tuple,environment,constants)
    _step_cohort_slot!(state,first(order),environment,constants)
    _step_order!(state,_schema_tail(order),environment,constants)
end
_step_cohort_slot!(state,::Val{I},environment,constants) where {I} =
    _step_cohort_application!(state,state.applications[I],environment,constants)
function step!(state::CohortState,environment;constants=nothing)
    state.active_slot==0 || throw(ArgumentError("cannot retry failed lifecycle step"))
    _step_order!(state,state.program.order,environment,constants)
    state.step+=1
    return state
end
