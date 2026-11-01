# Authoring-only full-model planner. No CompositeModel, Simulation or ordinary
# compiled plan is constructed here. Runtime consumes these typed recipes.
struct FullModelSeed{M,K,V,T}
    slot::Int
end
struct EmptyManySeed{T} end
struct FullCohortRecipe{K,P,X,D,S}
    ports::P
    external_type::Type{X}
    defaults_type::Type{D}
    status_type::Type{S}
end
_cohort_key(::FullCohortRecipe{K}) where {K}=K
function _seed(seed::FullModelSeed{M,K,V,T},models,initial) where {M,K,V,T}
    model=models[seed.slot]::M
    declaration=getproperty(K===:input ? PSE.inputs_(model) : PSE.outputs_(model),V)
    value=declaration isa PSE.Distributed ? declaration.declaration.value :
        declaration isa PSE.Default ? declaration.value : declaration
    return deepcopy(value::T)::T
end
_seed(::EmptyManySeed{T},models,initial) where {T}=PSE.RefVector(Base.RefValue{T}[])

"""A consumer-specific binding; SOURCES contains (cohort, application) pairs.
Application zero means explicit live canonical state, not an output stream.
TEMP=true reads the previous completed timestep of the specified application.
T is the scalar element type for Many, or the complete value type for One.
"""
struct FullInputRoute{SOURCES,VAR,TEMP,MULT,T,SEL}
    selector::SEL
end
struct FullOutputRoute{COHORTS,VAR,DISTRIBUTED,SEL}
    selector::SEL
end
struct FullCallRoute{SLOT,MODE,MULT,SEL}
    selector::SEL
end
struct FullApplicationRecipe{M,C,SLOT,INPUTS,OUTPUTS,CALLS,D,V,I,O,E,B,S,H}
    slot::Int
    name::Symbol
    inputs::INPUTS
    outputs::OUTPUTS
    calls::CALLS
    dependencies::D
    contracts::V
    inputs_type::Type{I}
    outputs_type::Type{O}
    environment_type::Type{E}
    binding_type::Type{B}
    status_type::Type{S}
    history_type::Type{H}
end
struct FullProgram{C,A,O}
    cohorts::C
    applications::A
    order::O
    cadence_ms::Int64
end
Base.show(io::IO,program::FullProgram)=print(io,"FullProgram(",length(program.applications),
    " applications, ",length(program.cohorts)," cohorts)")
Base.show(io::IO,recipe::FullApplicationRecipe)=print(io,"FullApplicationRecipe(",recipe.name,")")
Base.show(io::IO,recipe::FullCohortRecipe{K}) where {K}=print(io,"FullCohortRecipe(",K,")")
_app_slot(::FullApplicationRecipe{M,C,SLOT}) where {M,C,SLOT}=SLOT
_app_cohort(::FullApplicationRecipe{M,C}) where {M,C}=C
_cohort_route_slot(::FullCallRoute{SLOT}) where {SLOT}=SLOT

_full_value(declaration::PSE.Distributed)=_full_value(declaration.declaration)
_full_value(declaration::PSE.Default)=declaration.value
_full_value(declaration)=declaration
_full_previous(selector)=get(PSE.criteria(selector),:policy,nothing) isa PSE.PreviousTimeStep
_full_from_status(selector)=get(PSE.criteria(selector),:from_status,false)

function _full_selector_categories(selector,categories,fallback)
    criteria=PSE.criteria(selector)
    requested=get(criteria,:scale,fallback)
    requested=isnothing(requested) ? categories : requested isa Tuple ? requested : (requested,)
    all(cat->cat in categories,requested) || throw(ArgumentError("selector names an undeclared cohort"))
    return Tuple(requested)
end
function _full_validate_selector(selector)
    selector isa Union{One,OptionalOne,Many} || throw(ArgumentError("invalid input/call multiplicity"))
    c=PSE.criteria(selector)
    allowed=(:selectors,:within,:scale,:relation,:application,:process,:var,:policy,:window,:from_status,:after)
    all(k->k in allowed,keys(c)) || throw(ArgumentError("unsupported full-layout selector criterion"))
    relations=(:self,:parent,:children,:ancestors,:descendants,:siblings)
    relation=get(c,:relation,nothing)
    isnothing(relation) || relation in relations || throw(ArgumentError("unsupported full-layout relation"))
    for atom in c.selectors
        atom isa Union{PSE.Self,PSE.SelfPlant,PSE.SceneScope,PSE.Subtree,PSE.Ancestor,PSE.Relation} ||
            throw(ArgumentError("unsupported full-layout topology selector"))
        atom isa PSE.Relation && !(atom.relation in relations) && throw(ArgumentError("unsupported full-layout relation"))
    end
    scope=get(c,:within,nothing)
    isnothing(scope) || scope isa Union{PSE.Self,PSE.SelfPlant,PSE.SceneScope,PSE.Subtree,PSE.Ancestor} ||
        throw(ArgumentError("unsupported full-layout scope"))
    policy=get(c,:policy,nothing)
    isnothing(policy) || policy isa PSE.PreviousTimeStep || throw(ArgumentError("full layout currently supports only same-step and PreviousTimeStep inputs"))
    isnothing(get(c,:window,nothing)) || throw(ArgumentError("temporal windows are not admitted"))
    return selector
end

function _prepare_full(specs::Tuple;initial,base_step=Day(1))
    isempty(specs) && throw(ArgumentError("empty full program"))
    categories=keys(initial)
    isempty(categories) && throw(ArgumentError("full layout needs typed initial data per cohort"))
    models=map(s->s.model,specs)
    names=map(s->s.name,specs)
    all(n->n isa Symbol,names) && length(unique(names))==length(names) || throw(ArgumentError("name each application uniquely"))
    appcat=map(specs) do spec
        spec.applies_to isa Many || throw(ArgumentError("full application targets must be Many(scale=...)"))
        c=PSE.criteria(spec.applies_to)
        keys(c)==(:selectors,:scale) && isempty(c.selectors) && c.scale isa Symbol ||
            throw(ArgumentError("full application targets must be a single scale cohort"))
        c.scale in categories || throw(ArgumentError("missing application category"))
        isnothing(spec.environment) && isempty(spec.environment_bindings) && isnothing(spec.environment_window) ||
            throw(ArgumentError("full entry currently uses one global environment row"))
        isempty(PSE.environment_outputs_(spec)) && isempty(PSE.dep(spec)) || throw(ArgumentError("unsupported environment/legacy dependency protocol"))
        PSE._is_default_clock(PSE.timespec(spec.model)) || throw(ArgumentError("nondefault model clock unsupported"))
        isempty(spec.output_routing) || all(==(:canonical),values(spec.output_routing)) || throw(ArgumentError("stream-only outputs unsupported in full layout"))
        PSE._variable_contract_schema(spec)
        c.scale
    end
    cadence=Dates.value(convert(Millisecond,base_step))
    cadence>0 || throw(ArgumentError("base step must be positive"))
    for spec in specs
        isnothing(spec.timestep) || Dates.value(convert(Millisecond,spec.timestep))==cadence ||
            throw(ArgumentError("full entry currently uses a single daily cadence"))
    end
    catindex=Dict(cat=>i for (i,cat) in enumerate(categories))
    # Writer order is authored application order; Updates must explicitly justify
    # every duplicate writer, including distributed writes to other cohorts.
    owners=Dict{Tuple{Symbol,Symbol},Vector{Int}}()
    output_routes=Vector{Any}(undef,length(specs))
    seeds=Dict(cat=>Dict{Symbol,Any}() for cat in categories)
    first_output=Set{Tuple{Symbol,Symbol}}()
    for (i,spec) in enumerate(specs)
        for (var,declaration) in pairs(PSE.inputs_(spec))
            declaration isa Union{PSE.Required,PSE.Default} || throw(ArgumentError("invalid input schema"))
            if declaration isa PSE.Default
                value=declaration.value
                get!(seeds[appcat[i]],var,FullModelSeed{typeof(spec.model),:input,var,typeof(value)}(i))
            end
        end
        routes=Pair{Symbol,Any}[]
        resolved=PSE._resolved_output_destinations(spec)
        for (var,declaration) in pairs(PSE.outputs_(spec))
            distributed=declaration isa PSE.Distributed
            if distributed
                destination=only(filter(entry->var in keys(entry.vars),resolved))
                selector=destination.selector
                _full_validate_selector(selector)
                cats=_full_selector_categories(selector,categories,nothing)
            else
                selector=One(within=PSE.Self())
                cats=(appcat[i],)
            end
            value=_full_value(declaration)
            value isa PSE.Required && throw(ArgumentError("required distributed outputs need an explicit initial value"))
            for cat in cats
                key=(cat,var)
                push!(get!(owners,key,Int[]),i)
                if !(key in first_output)
                    seeds[cat][var]=FullModelSeed{typeof(spec.model),:output,var,typeof(value)}(i)
                    push!(first_output,key)
                end
            end
            route=FullOutputRoute{Tuple(catindex[cat] for cat in cats),var,distributed,typeof(selector)}(selector)
            push!(routes,var=>route)
        end
        output_routes[i]=(;routes...)
    end
    for cat in categories, (var,value) in pairs(initial[cat])
        seeds[cat][var]=ExternalSeed{cat,var}()
    end

    # Calls have static application slots, but their selected object rows remain
    # runtime data. Keep their original selectors for exact topology resolution.
    manual=Set{Int}(); callowners=Dict{Int,Vector{Int}}(); initializer_owners=Dict{Int,Int}()
    call_routes=map(Tuple(enumerate(specs))) do (i,spec)
        values_=map(values(spec.calls)) do declaration
            initializer=declaration isa PSE.Initializer
            selector=initializer ? declaration.selector : declaration
            _full_validate_selector(selector)
            initializer && !(selector isa One) && throw(ArgumentError("initializer requires One"))
            criteria=PSE.criteria(selector)
            initializer && !(get(criteria,:application,nothing) isa Symbol) &&
                throw(ArgumentError("initializer must name its target with application=..."))
            cats=_full_selector_categories(selector,categories,nothing)
            matches=[j for j in eachindex(specs) if appcat[j] in cats &&
                (!haskey(criteria,:application) || names[j]===criteria.application) &&
                (!haskey(criteria,:process) || PSE.process(specs[j])===criteria.process)]
            length(matches)==1 || throw(ArgumentError("call must identify one application"))
            target=only(matches)
            if initializer
                haskey(initializer_owners,target) && throw(ArgumentError("initializer target requires exactly one owner binding"))
                initializer_owners[target]=i
                isempty(specs[target].calls) && isempty(specs[target].outputs_to) || throw(ArgumentError("initializer cannot have calls or distributed outputs"))
            else
                isempty(specs[target].outputs_to) || throw(ArgumentError("manual-only applications cannot declare distributed outputs"))
                push!(manual,target)
                push!(get!(callowners,target,Int[]),i)
            end
            FullCallRoute{target,initializer ? :initializer : :manual,PSE.multiplicity(selector),typeof(selector)}(selector)
        end
        NamedTuple{keys(spec.calls)}(values_)
    end
    any(i->i in manual,keys(initializer_owners)) && throw(ArgumentError("initializer cannot also be manual-only"))
    any(i->i in manual,values(initializer_owners)) && throw(ArgumentError("initializer creator must be root-scheduled"))
    # Manual kernels mutate the caller's canonical statuses, but are not
    # canonical writers or inferred soft producers. Their defaults remain
    # available for fields which have no normally scheduled writer.
    declared_owners=Dict(key=>copy(writers) for (key,writers) in owners)
    label_matches(label,index)=label===names[index]
    for ((cat,var),writers) in owners
        filter!(i->!(i in manual),writers)
        if !isempty(writers) && !haskey(initial[cat],var)
            writer=first(writers)
            value=_full_value(PSE.outputs_(specs[writer])[var])
            seeds[cat][var]=FullModelSeed{typeof(specs[writer].model),:output,var,typeof(value)}(writer)
        end
        for k in 2:length(writers)
            i=writers[k]; previous=writers[k-1]
            any(update->var in update.variables && any(label->label_matches(label,previous),update.after),specs[i].updates) ||
                throw(ArgumentError("duplicate writer $(names[i]) for $cat.$var needs Updates after $(names[previous])"))
        end
    end
    for target in keys(initializer_owners), var in keys(PSE.outputs_(specs[target]))
        writers=get(declared_owners,(appcat[target],var),Int[])
        length(writers)==1 && only(writers)==target || throw(ArgumentError(
            "initializer $(names[target]) must be the sole canonical writer of $(appcat[target]).$var"))
    end
    function rootowners(i,path=Int[])
        i in path && throw(ArgumentError("hard-call cycle"))
        direct=get(callowners,i,Int[])
        isempty(direct) && return (i,)
        result=Int[]
        for owner in direct
            append!(result,rootowners(owner,[path;i]))
        end
        return Tuple(unique(result))
    end
    foreach(rootowners,manual)
    edges=[Set{Int}() for _ in specs]
    potential_sources=[Dict{Symbol,Tuple}() for _ in specs]
    temporals=[Dict{Symbol,Bool}() for _ in specs]
    input_routes=Vector{Any}(undef,length(specs))
    # Route construction uses the schema's complete canonical source types. A
    # second pass resolves inputs whose only seed is another input/default.
    unresolved=Tuple{Int,Symbol,Any}[]
    for (i,spec) in enumerate(specs), var in keys(PSE.inputs_(spec))
        push!(unresolved,(i,var,PSE.inputs_(spec)[var]))
    end
    route_pairs=[Pair{Symbol,Any}[] for _ in specs]
    while !isempty(unresolved)
        next=Tuple{Int,Symbol,Any}[]
        progressed=false
        for (i,var,declaration) in unresolved
            spec=specs[i]
            explicit=haskey(spec.inputs,var)
            selector=explicit ? spec.inputs[var] : One(within=PSE.Self(),var=var)
            _full_validate_selector(selector)
            criteria=PSE.criteria(selector)
            sourcevar=get(criteria,:var,var)
            from_status=_full_from_status(selector)
            temporal=_full_previous(selector)
            temporal && criteria.policy.variable!=var && throw(ArgumentError("PreviousTimeStep must name its input $var"))
            # Relation selectors such as parent/children restrict topology at
            # runtime, while category candidates derive from the explicit scale
            # or all cohorts (for an unlabelled parent/children selector).
            relation=get(criteria,:relation,nothing)
            has_relation=!isnothing(relation) || any(a->a isa PSE.Relation,criteria.selectors)
            scope=get(criteria,:within,isempty(criteria.selectors) ? nothing : first(criteria.selectors))
            cross_scope=scope isa Union{PSE.SelfPlant,PSE.SceneScope,PSE.Subtree,PSE.Ancestor}
            fallback=explicit && (has_relation || cross_scope) ? nothing : appcat[i]
            sourcecats=_full_selector_categories(selector,categories,fallback)
            potential=Int[]; sources=Tuple{Int,Int}[]; values_=Any[]
            for cat in sourcecats
                candidates=from_status || (!explicit && i in manual) ? Int[] :
                    get(explicit ? declared_owners : owners,(cat,sourcevar),Int[])
                candidates=[j for j in candidates if (explicit || j!=i) &&
                    (!haskey(criteria,:application) || names[j]===criteria.application) &&
                    (!haskey(criteria,:process) || PSE.process(specs[j])===criteria.process)]
                append!(potential,candidates)
                for candidate in candidates
                    PSE._validate_model_variable_contract!((spec=spec,id=names[i]),var,
                        (spec=specs[candidate],id=names[candidate]),sourcevar)
                end
                chosen=isempty(candidates) ? 0 : last(candidates)
                if chosen!=0
                    value=_full_value(PSE.outputs_(specs[chosen])[sourcevar])
                    push!(sources,(catindex[cat],chosen));push!(values_,value)
                elseif haskey(seeds[cat],sourcevar)
                    seed=seeds[cat][sourcevar]
                    push!(sources,(catindex[cat],0));push!(values_,_seed(seed,models,initial))
                end
            end
            if isempty(sources)
                if declaration isa PSE.Default && !explicit
                    push!(sources,(catindex[appcat[i]],0));push!(values_,declaration.value)
                else
                    push!(next,(i,var,declaration));continue
                end
            end
            T=typeof(first(values_))
            all(v->typeof(v)===T,values_) || throw(ArgumentError("heterogeneous scalar payload types in $var are not yet supported"))
            multiplicity=PSE.multiplicity(selector)
            if multiplicity===:many
                PSE._input_expected_type(declaration)<:AbstractVector || throw(ArgumentError("Many input $var must declare an AbstractVector"))
                # A Many port is always a reference carrier, even when the same
                # field is a local array output (LeafState.rank_leaves). Kernels
                # can update its selected source statuses through broadcasting.
                seeds[appcat[i]][var]=EmptyManySeed{T}()
            else
                first(values_) isa PSE._input_expected_type(declaration) || throw(ArgumentError("incompatible scalar input $var"))
                if !haskey(seeds[appcat[i]],var)
                    # Canonical filler uses the same producer seed; app-local
                    # views will supply the actual selected live/temporal Ref.
                    sourcecat=categories[first(sources)[1]]
                    chosen=first(sources)[2]
                    seeds[appcat[i]][var]=chosen==0 ? seeds[sourcecat][sourcevar] :
                        FullModelSeed{typeof(specs[chosen].model),:output,sourcevar,T}(chosen)
                end
            end
            route=FullInputRoute{Tuple(sources),sourcevar,temporal,multiplicity,T,typeof(selector)}(selector)
            push!(route_pairs[i],var=>route)
            potential_sources[i][var]=Tuple(unique(potential))
            temporals[i][var]=temporal
            progressed=true
        end
        isempty(next) && break
        progressed || throw(ArgumentError("unresolved full-layout inputs: $(Tuple((names[i],var) for (i,var,_) in next))"))
        unresolved=next
    end
    for target in keys(initializer_owners), consumer in eachindex(specs)
        consumer==target && continue
        for (var,producers) in potential_sources[consumer]
            get(temporals[consumer],var,false) && target in producers && throw(ArgumentError(
                "temporal input $(names[consumer]).$var cannot consume initialized output from $(names[target])"))
        end
    end
    # Restore declaration order even if a route waited for a forward seed.
    for (i,spec) in enumerate(specs)
        routes=Dict(route_pairs[i])
        input_routes[i]=NamedTuple{keys(PSE.inputs_(spec))}(map(var->routes[var],keys(PSE.inputs_(spec))))
    end
    # All potential writers create same-step edges, even though live bindings
    # select a final canonical writer. Manual callee outputs are attributed to
    # their root owner; input edges into a manual callee do not reorder its owner.
    for i in eachindex(specs), (var,producers) in potential_sources[i]
        get(temporals[i],var,false) && continue
        for producer in producers, owner in rootowners(producer)
            owner==i || push!(edges[i],owner)
        end
        selector=haskey(specs[i].inputs,var) ? specs[i].inputs[var] : nothing
        if !isnothing(selector)
            for label in get(PSE.criteria(selector),:after,())
                source=findfirst(==(label),names)
                isnothing(source) && throw(ArgumentError("unknown from_status ordering application"))
                source==i || push!(edges[i],source)
            end
        end
    end
    for (target,creator) in initializer_owners
        push!(edges[creator],target)
        for consumer in eachindex(specs), (var,producers) in potential_sources[consumer]
            get(temporals[consumer],var,false) && continue
            target in producers || continue
            executionowners=haskey(initializer_owners,consumer) ? (initializer_owners[consumer],) : rootowners(consumer)
            for owner in executionowners
                owner==creator || push!(edges[owner],creator)
            end
        end
    end
    # Updates edges are also meaningful for distributed writer overlap.
    for ((cat,var),writers) in owners, k in 2:length(writers)
        previous=writers[k-1]; current=writers[k]
        current in manual || previous in manual || push!(edges[current],previous)
    end
    roots=[i for i in eachindex(specs) if !(i in manual)]
    order=Int[]
    while length(order)<length(roots)
        index=findfirst(i->!(i in order) && all(j->j in manual || j in order,edges[i]),roots)
        isnothing(index) && throw(ArgumentError("full-layout same-step dependency cycle: $(Tuple(names[i] for i in roots if !(i in order)))"))
        push!(order,roots[index])
    end
    cohorts=map(categories) do cat
        fields=Tuple(sort!(collect(keys(seeds[cat]));by=string))
        ports=NamedTuple{fields}(map(var->CohortPort(seeds[cat][var],nothing),fields))
        defaults=map(port->_seed(port.seed,models,initial),ports)
        status=Status(defaults)
        X=typeof(initial[cat]); D=typeof(defaults); S=typeof(status)
        FullCohortRecipe{cat,typeof(ports),X,D,S}(ports,X,D,S)
    end
    applications=map(Tuple(enumerate(specs))) do (i,spec)
        inputs=input_routes[i]; outputs=output_routes[i]; calls=call_routes[i]
        M=typeof(spec.model); C=catindex[appcat[i]]; D=typeof(PSE.dep(spec.model)); V=typeof(PSE.variable_contracts_(spec))
        I=typeof(PSE.inputs_(spec)); O=typeof(PSE.outputs_(spec)); E=typeof(PSE.environment_inputs_(spec))
        defaults=map(port->_seed(port.seed,models,initial),cohorts[C].ports)
        bindings=NamedTuple{keys(inputs)}(map(keys(inputs),values(inputs)) do var,route
            _prototype_full_binding(route,getproperty(defaults,var))
        end)
        canonical=Status(defaults)
        view=Status(merge(PSE._status_vars(canonical),map(binding->binding.reference,bindings)))
        histories=map(PSE.outputs_(spec)) do declaration
            value=_full_value(declaration)
            ColumnHistory(typeof(_full_history_snapshot(value)))
        end
        B=typeof(bindings); S=typeof(view); H=typeof(histories)
        FullApplicationRecipe{M,C,i,typeof(inputs),typeof(outputs),typeof(calls),D,V,I,O,E,B,S,H}(
            i,names[i],inputs,outputs,calls,PSE.dep(spec.model),PSE.variable_contracts_(spec),I,O,E,B,S,H)
    end
    return FullProgram(cohorts,applications,map(Val,Tuple(order)),cadence)
end

function _make_cohort(recipe::FullCohortRecipe{K,P,X,D,S},models,initial,::Type{N}) where {K,P,X,D,S,N}
    typeof(getproperty(initial,K))===X || throw(ArgumentError("changed external schema"))
    defaults=map(port->_seed(port.seed,models,initial),recipe.ports)::D
    status=Status(defaults)::S
    return Cohort{K,typeof(recipe),D,S,N}(recipe,defaults,Int[],S[],N[],0)
end
