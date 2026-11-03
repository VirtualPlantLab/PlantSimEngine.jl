# Authoring-only projection from the canonical PSE scenario plan. The typed
# runtime consumes only the resulting recipes.
# Copy only the admitted scientific payload, keeping scalar/vector element types
# visible to the native compiler. Unknown payload families preserve the original
# deep-copy semantics; current XPalm Float/Int/Bool/Symbol/ObjectId/vector paths
# do not enter that generic fallback.
_payload_copy(value) = deepcopy(value)
_payload_copy(value::Number) = copy(value)
_payload_copy(value::Symbol) = value
_payload_copy(value::PSE.ObjectId) = value
_payload_copy(value::AbstractArray) = map(_payload_copy, collect(value))

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
    return _payload_copy(value::T)::T
end
_seed(::EmptyManySeed{T},models,initial) where {T}=PSE.RefVector(Base.RefValue{T}[])

"""A consumer-specific binding; SOURCES contains (cohort, application) pairs.
Application zero means explicit live canonical state, not an output stream.
TEMP=true reads the previous completed timestep of the specified application.
T is the scalar element type for Many, or the complete value type for One.
"""
struct FullInputRoute{SOURCES,VAR,TEMP,MULT,T,M}
    matcher::M
end
struct FullOutputRoute{COHORTS,VAR,DISTRIBUTED,M}
    matcher::M
end
struct FullCallRoute{SLOT,MODE,MULT,M}
    matcher::M
    cache_key::Int
end
struct FullApplicationRecipe{M,C,SLOT,INPUTS,OUTPUTS,CALLS,TO,D,V,I,O,E,B,S,H}
    slot::Int
    name::Symbol
    inputs::INPUTS
    outputs::OUTPUTS
    calls::CALLS
    temporal_outputs::TO
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
function _full_temporal_outputs!(needed,::FullInputRoute{SOURCES,VAR,TEMP}) where {SOURCES,VAR,TEMP}
    TEMP || return nothing
    for (_,slot) in SOURCES
        slot>0 || throw(ArgumentError("temporal inputs require an output producer"))
        push!(needed[slot],VAR)
    end
    return nothing
end

function _full_selector_categories(matcher,categories,fallback)
    requested=isnothing(matcher.scale) ? fallback : matcher.scale
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

const FULL_SELF_MATCHER = PSE.CompiledSelectorMatcher(
    PSE.Self(), nothing, nothing, nothing, nothing, nothing, false)

function _full_matcher(matcher, origin_category)
    # Dependency resolution defaults to Self except at Scene. A relation
    # without an explicit scope does not acquire that implicit scope.
    scope=matcher.scope
    if matcher.defaults_to_context
        scope=PSE.Self()
    elseif isnothing(scope) && isnothing(matcher.relation)
        scope=origin_category===:Scene ? PSE.SceneScope() : PSE.Self()
    end
    return PSE.CompiledSelectorMatcher(
        scope,matcher.relation,matcher.scale,matcher.kind,matcher.species,matcher.id,false)
end

function prepare(model::PSE.CompositeModel; initial)
    isempty(model.instances) || throw(ArgumentError("full programs require direct applications"))
    specs = Tuple(model.applications)
    timeline = PSE._model_timeline(model)
    timeline.base_step_seconds == 86_400 || throw(ArgumentError("full programs require a daily timeline"))
    applications = PSE._compile_model_applications(model, specs, timeline)
    all(application -> application.clock.dt == 1.0, applications) ||
        throw(ArgumentError("full programs require one execution per daily step for every application"))
    for application in applications, id in application.target_ids
        object=PSE._model_object(model,id)
        object.kind===:scene && object.scale!==:Scene &&
            throw(ArgumentError("full dependency scopes require scene objects to have scale=:Scene"))
    end
    scenario = PSE._compile_resolved_scenario_plan(model, applications, timeline)
    return _prepare_full(specs, scenario, applications; initial)
end

function _prepare_full(specs::Tuple, scenario, compiled_applications; initial)
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
    cadence=Dates.value(convert(Millisecond,Day(1)))
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
    destination_plans=scenario.distributed_output_plans
    for (i,spec) in enumerate(specs)
        for (var,declaration) in pairs(PSE.inputs_(spec))
            declaration isa Union{PSE.Required,PSE.Default} || throw(ArgumentError("invalid input schema"))
            if declaration isa PSE.Default
                value=declaration.value
                get!(seeds[appcat[i]],var,FullModelSeed{typeof(spec.model),:input,var,typeof(value)}(i))
            end
        end
        routes=Pair{Symbol,Any}[]
        destinations=destination_plans isa PSE.NoCompiledDistributedOutputPlans ?
            () : destination_plans.by_application[names[i]]
        for (var,declaration) in pairs(PSE.outputs_(spec))
            distributed=declaration isa PSE.Distributed
            if distributed
                destination=only(filter(plan->haskey(plan.declarations,var),destinations))
                selector=destination.selector
                _full_validate_selector(selector)
                matcher=_full_matcher(destination.matcher,appcat[i])
                cats=_full_selector_categories(matcher,categories,nothing)
            else
                matcher=FULL_SELF_MATCHER
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
            route=FullOutputRoute{Tuple(catindex[cat] for cat in cats),var,distributed,typeof(matcher)}(matcher)
            push!(routes,var=>route)
        end
        output_routes[i]=(;routes...)
    end
    for cat in categories, (var,value) in pairs(initial[cat])
        seeds[cat][var]=ExternalSeed{cat,var}()
    end

    # The canonical plan identifies the application and mode. The typed
    # runtime still resolves object rows from the selector as topology grows.
    manual=Set(scenario.applications_by_id[id].slot for id in scenario.manual_application_ids)
    for target in manual
        isempty(specs[target].outputs_to) ||
            throw(ArgumentError("manual-only applications cannot declare distributed outputs"))
    end
    initializer_targets=Int[]
    call_routes=map(names) do name
        plans=scenario.call_plans_by_application[name]
        routes=map(plans) do plan
            selector=plan.selector
            _full_validate_selector(selector)
            matcher=_full_matcher(plan.matcher,appcat[plan.application_slot])
            ids=plan.potential_callee_application_ids
            length(ids)==1 || throw(ArgumentError("full calls must identify one application"))
            target=scenario.applications_by_id[only(ids)].slot
            mode=PSE._compiled_call_mode(plan)
            mode===:initializer && push!(initializer_targets,target)
            FullCallRoute{target,mode,plan.multiplicity,typeof(matcher)}(matcher,plan.slot)
        end
        NamedTuple{map(PSE._compiled_call_name,plans)}(routes)
    end
    # Manual kernels mutate the caller's canonical statuses, but are not
    # canonical writers or inferred soft producers. Their defaults remain
    # available for fields which have no normally scheduled writer.
    declared_owners=Dict(key=>copy(writers) for (key,writers) in owners)
    for ((cat,var),writers) in owners
        filter!(i->!(i in manual),writers)
        if !isempty(writers) && !haskey(initial[cat],var)
            writer=first(writers)
            value=_full_value(PSE.outputs_(specs[writer])[var])
            seeds[cat][var]=FullModelSeed{typeof(specs[writer].model),:output,var,typeof(value)}(writer)
        end
        for k in 2:length(writers)
            i=writers[k]; previous=writers[k-1]
            PSE._updates_after_previous_writer(specs[i],var,(compiled_applications[previous],)) ||
                throw(ArgumentError("duplicate writer $(names[i]) for $cat.$var needs Updates after $(names[previous])"))
        end
    end
    explicit_plans=map(names) do name
        Dict(plan.input=>plan for plan in scenario.input_plans_by_application[name]
            if plan.origin!==:inferred_same_object)
    end
    inferred_sources=map(names) do name
        sources=Dict{Symbol,Set{Symbol}}()
        for plan in scenario.input_plans_by_application[name]
            plan.origin===:inferred_same_object || continue
            union!(get!(Set{Symbol},sources,plan.input),plan.potential_source_application_ids)
        end
        sources
    end
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
            plan=get(explicit_plans[i],var,nothing)
            explicit=!isnothing(plan)
            explicit && _full_validate_selector(plan.selector)
            matcher=explicit ? _full_matcher(plan.matcher,appcat[i]) : FULL_SELF_MATCHER
            sourcevar=explicit ? plan.source_var : var
            temporal=explicit && plan.breaks_same_step_cycle
            filtered=explicit && (!isnothing(plan.application) || !isnothing(plan.process))
            cross_scope=matcher.scope isa Union{PSE.SelfPlant,PSE.SceneScope,PSE.Subtree,PSE.Ancestor}
            fallback=explicit && (!isnothing(matcher.relation) || cross_scope) ? nothing : appcat[i]
            sourcecats=_full_selector_categories(matcher,categories,fallback)
            producer_ids=explicit ? plan.potential_source_application_ids :
                get(inferred_sources[i],var,())
            # Canonical candidates include applications whose target objects
            # do not exist yet. The typed route needs the subset that writes
            # the destination cohort, with manual writers eligible only for
            # explicit inputs.
            potential=Int[]; sources=Tuple{Int,Int}[]; values_=Any[]
            for cat in sourcecats
                writers=explicit ? declared_owners : owners
                candidates=!explicit && i in manual ? Int[] :
                    [j for j in get(writers,(cat,sourcevar),Int[]) if names[j] in producer_ids]
                append!(potential,candidates)
                chosen=isempty(candidates) ? 0 : last(candidates)
                if chosen!=0
                    value=_full_value(PSE.outputs_(specs[chosen])[sourcevar])
                    push!(sources,(catindex[cat],chosen));push!(values_,value)
                elseif !filtered && haskey(seeds[cat],sourcevar)
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
            multiplicity=explicit ? plan.multiplicity : :one
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
            route=FullInputRoute{Tuple(sources),sourcevar,temporal,multiplicity,T,typeof(matcher)}(matcher)
            push!(route_pairs[i],var=>route)
            potential_sources[i][var]=Tuple(unique(potential))
            temporals[i][var]=temporal
            progressed=true
        end
        isempty(next) && break
        progressed || throw(ArgumentError("unresolved full-layout inputs: $(Tuple((names[i],var) for (i,var,_) in next))"))
        unresolved=next
    end
    for target in initializer_targets, consumer in eachindex(specs)
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
    temporal_needed=[Set{Symbol}() for _ in specs]
    for routes in input_routes, route in values(routes)
        _full_temporal_outputs!(temporal_needed,route)
    end
    temporal_outputs=map(eachindex(specs)) do i
        Tuple(var for var in keys(output_routes[i]) if var in temporal_needed[i])
    end
    # Keep entries for applications with no initial targets. Growth can add
    # their first rows without changing the order of root applications.
    order=map(Tuple(scenario.application_schedule.entries)) do entry
        names[entry.application_slot] === entry.application_id ||
            throw(ArgumentError("resolved application does not match its authored slot"))
        Val(entry.application_slot)
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
        declarations=PSE.outputs_(spec)
        histories=NamedTuple{keys(declarations)}(map(keys(declarations),values(declarations)) do var,declaration
            value=_full_value(declaration)
            ColumnHistory(typeof(_full_history_snapshot(value)),var in temporal_needed[i])
        end)
        B=typeof(bindings); S=typeof(view); H=typeof(histories)
        FullApplicationRecipe{M,C,i,typeof(inputs),typeof(outputs),typeof(calls),typeof(temporal_outputs[i]),D,V,I,O,E,B,S,H}(
            i,names[i],inputs,outputs,calls,temporal_outputs[i],PSE.dep(spec.model),PSE.variable_contracts_(spec),I,O,E,B,S,H)
    end
    return FullProgram(cohorts,applications,order,cadence)
end

function _make_cohort(recipe::FullCohortRecipe{K,P,X,D,S},models,initial,::Type{N}) where {K,P,X,D,S,N}
    typeof(getproperty(initial,K))===X || throw(ArgumentError("changed external schema"))
    defaults=_schema_map(port->_seed(port.seed,models,initial),recipe.ports)::D
    status=Status(defaults)::S
    return Cohort{K,typeof(recipe),D,S,N}(recipe,defaults,Int[],S[],N[],0)
end
