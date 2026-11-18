# One constructor-owned manifest. This stores names, exact reference classes,
# configured selector owners and raw-family correlations, never default values.
# These lists refer to the authored owners and their existing permissions.
# Cardinalities are data: adding organs never specializes the execution model.
struct PreparedBirthRecipe{S,A,F,D,R}
    status_type::Type{S}
    applications::A
    sources::F
    destinations::D
    raw_families::R
end

mutable struct PreparedStatusManifest{S,A,P,D,R,B}
    const status_type::Type{S}
    const authored::A
    const permissions::P
    const destinations::D
    const raw_families::R
    const birth_recipes::Dict{Union{Nothing,Symbol},B}
    const all_routes::B
end

# RAW membership, labels and reference classes are constructor evidence DATA.
# Their cardinality must not change the model/context type when S is unchanged.
struct PreparedRawStatusFamily{I<:ObjectId}
    labels::NTuple{3,Union{Nothing,Symbol}}
    selected::Vector{Tuple{Int,Int}}
    destinations::Vector{Tuple{Int,I,Int}}
    sources::Vector{Tuple{Int,I,Int}}
    names::Vector{Symbol}
    reference_types::Vector{DataType}
end

function _same_prepared_raw_family(left::PreparedRawStatusFamily,
    right::PreparedRawStatusFamily)
    return left.labels === right.labels && left.selected == right.selected &&
        left.destinations == right.destinations && left.sources == right.sources &&
        left.names == right.names && left.reference_types == right.reference_types
end

# Runtime status admission needs only applicability and the effective variant
# slot. Full specifications/ports stay in ScenarioPreparation; environment names
# must not change an otherwise identical canonical registry schema.
struct PreparedStatusSource{M}
    slot::Int
    input::Symbol
    source_var::Symbol
    matcher::M
    references::Vector{Pair{Symbol,DataType}}
end

struct PreparedStatusDestination{M}
    slot::Int
    application_slot::Int
    variable_names::Vector{Symbol}
    matcher::M
end

struct PreparedStatusVariant
    canonical::Vector{Pair{Symbol,DataType}}
    outputs::Vector{Pair{Symbol,DataType}}
    source_inputs::Vector{Pair{Symbol,DataType}}
end

struct PreparedStatusApplication{M,O}
    slot::Int
    id::Symbol
    target_matcher::M
    object_slots::O
end

struct PreparedStatusPermission{R}
    variants::Vector{PreparedStatusVariant}
    aliases::Vector{Pair{Symbol,DataType}}
    sources::Vector{R}
end
@inline _prepared_status_object_slots(application::PreparedStatusApplication) =
    application.object_slots
function _prepared_status_object_slots(application)
    owner = _application_model_overrides(application)
    return isnothing(owner) ? nothing : owner.object_slots
end

function _prepared_raw_status_families(model)
    catalog = model.registry.objects.catalog
    return catalog isa ClosedObjectFamilyCatalog && catalog.status_manifest isa PreparedStatusManifest ?
        catalog.status_manifest.raw_families : nothing
end

_prepared_status_variant_slot(application, object_id) = begin
    slots = _prepared_status_object_slots(application)
    isnothing(slots) ? 1 : get(slots, object_id, 1)
end

# These permissions are data consulted at admission. The fixed Status schema
# still owns the field layout and its exact reference types.
function _prepared_status_reference_classes(names, types)
    return Pair{Symbol,DataType}[name => R for (name, family) in zip(names, types)
        for R in Base.uniontypes(family) if R !== Union{}]
end

function _prepared_status_add_type!(names, types, name::Symbol, R)
    R === Union{} && return nothing
    all(T -> T <: Ref && isconcretetype(T), Base.uniontypes(R)) ||
        throw(ArgumentError("A prepared status field needs exact reference classes."))
    index = findfirst(isequal(name), names)
    if isnothing(index)
        push!(names, name); push!(types, R)
    else
        types[index] = Union{types[index],R}
    end
    return nothing
end

# Choose the declared numerical storage family without evaluating callbacks.
# This does not predict an arbitrary transform: its actual result is materialized
# once by the existing worker, then admitted before any canonical publication.
function _prepared_status_declared_reference(policy, name::Symbol, T, elements)
    configured = _configured_status_value_type(policy, name, T, elements)
    isnothing(configured) && return Union{}
    members = Base.uniontypes(configured)
    all(isconcretetype, members) || return Union{}
    return Union{map(T -> Base.RefValue{T}, members)...}
end

function _prepared_status_variant_permission(model, application, ports, plans)
    names = Symbol[]; refs = Any[]
    output_names = Symbol[]; output_refs = Any[]
    for name in keys(ports.output_types)
        R = _prepared_status_declared_reference(model.status_conversion, name,
            getproperty(ports.output_types, name), get(ports.output_element_types, name, nothing))
        _prepared_status_add_type!(output_names, output_refs, name, R)
        name in _model_canonical_output_names(application) || continue
        _prepared_status_add_type!(names, refs, name, R)
    end
    for name in ports.input_names
        R = _prepared_status_declared_reference(model.status_conversion, name,
            getproperty(ports.input_types, name), get(ports.input_element_types, name, nothing))
        _prepared_status_add_type!(names, refs, name, R)
    end
    source_names = Symbol[]; source_refs = Any[]
    for plan in plans
        _input_route_from_status(plan.route) || continue
        configured = _configured_status_value_type(model.status_conversion, plan.input,
            getproperty(ports.input_types, plan.input),
            get(ports.input_element_types, plan.input, nothing))
        T = plan.selector isa Many ?
            (!isnothing(configured) && configured <: AbstractVector ? eltype(configured) : Union{}) :
            (isnothing(configured) ? Union{} : configured)
        T === Union{} && continue
        # Real/Any are value bounds, not requests to replace Ref32/Ref64 by
        # invariant Ref{Real}/Ref{Any}. Keep only already prepared real classes.
        classes = Tuple(R for slot in fieldtypes(plan.reference_types)
            for R in Base.uniontypes(slot) if R <: Ref &&
                isconcretetype(R) && eltype(R) <: T)
        isempty(classes) && continue
        _prepared_status_add_type!(source_names, source_refs, plan.input, Union{classes...})
    end
    return PreparedStatusVariant(_prepared_status_reference_classes(names, refs),
        _prepared_status_reference_classes(output_names, output_refs),
        _prepared_status_reference_classes(source_names, source_refs))
end

# Project the SAME prepared source-reference family used by the runtime carrier
# constructor. A seed Vector value is not a RefVector carrier.
function _prepared_status_input_reference(plan)
    refs = fieldtypes(plan.reference_types)
    isempty(refs) && return Union{}
    if !(plan.selector isa Many)
        return Union{refs...}
    end
    return Base.RefValue{_many_input_carrier_type(plan.reference_types)}
end

# Matcher and override values keep their authored types and identities. The type
# of the collection depends on the supported matcher families, never on the
# number of applications, the input name, or the number of routes.
_prepared_status_field_type(values) = foldl((T, value) -> Union{T,typeof(value)},
    values; init=Union{})

function _prepared_status_applications(model, recipes, program)
    inputs = [plan for plan in program.input_records if plan isa CompiledModelInputPlan]
    M = _prepared_status_field_type(application.target_matcher for application in recipes)
    O = _prepared_status_field_type(_prepared_status_object_slots(application) for application in recipes)
    R = PreparedStatusSource{_prepared_status_field_type(plan.matcher for plan in inputs if
        _input_route_from_status(plan.route))}
    A = PreparedStatusApplication{M,O}
    applications = A[]
    permissions = PreparedStatusPermission{R}[]
    for application in recipes
        application_slot = application.slot
        plans = filter(plan -> plan.application_slot == application_slot, inputs)
        variants = PreparedStatusVariant[]
        _foreach_application_variant(application) do _, ports
            push!(variants, _prepared_status_variant_permission(model, application, ports, plans))
        end
        # Plan reference classes are common route evidence. Effective model
        # default classes above stay in their individual configured variant.
        alias_names = Symbol[]; alias_refs = Any[]
        for plan in plans
            _prepared_status_add_type!(alias_names, alias_refs,
                plan.input, _prepared_status_input_reference(plan))
        end
        aliases = _prepared_status_reference_classes(alias_names, alias_refs)
        sources = R[R(plan.slot, plan.input, plan.source_var, plan.matcher,
            _prepared_status_reference_classes((plan.source_var,),
                (Union{fieldtypes(plan.reference_types)...},)))
            for plan in plans if _input_route_from_status(plan.route)]
        push!(applications, A(application.slot, application.id, application.target_matcher,
            _prepared_status_object_slots(application)))
        push!(permissions, PreparedStatusPermission(variants, aliases, sources))
    end
    return applications, permissions
end

function _prepared_status_destinations(plans)
    M = _prepared_status_field_type(plan.matcher for plan in plans)
    return PreparedStatusDestination{M}[PreparedStatusDestination{M}(
        plan.slot, plan.application_slot, collect(Symbol, plan.variable_names), plan.matcher)
        for plan in plans]
end

function _prepared_birth_recipes(S, applications, permissions, destinations, raw, model)
    owners = collect(zip(applications, permissions))
    by_slot = Dict(first(owner).slot => owner for owner in owners)
    Source = eltype(fieldtype(eltype(permissions), :sources))
    sources = Tuple{eltype(applications),eltype(permissions),Source}[
        (app, permission, source) for (app, permission) in owners for source in permission.sources]
    routes = Tuple{eltype(applications),eltype(permissions),eltype(destinations)}[
        (by_slot[plan.application_slot]..., plan) for plan in destinations]
    all_routes = PreparedBirthRecipe(S, owners, sources, routes, raw)
    scales = Set{Union{Symbol,Nothing}}(keys(model.registry.by_scale))
    push!(scales, nothing)
    for matcher in Iterators.flatten(((app.target_matcher for app in applications),
        (source.matcher for (_, _, source) in sources), (plan.matcher for plan in destinations)))
        requested = matcher.scale
        requested isa Tuple ? union!(scales, requested) : push!(scales, requested)
    end
    recipes = Dict{Union{Nothing,Symbol},typeof(all_routes)}()
    for scale in scales
        matches(matcher) = _object_matches_selector_value(scale, matcher.scale)
        recipes[scale] = PreparedBirthRecipe(S,
            filter(owner -> matches(first(owner).target_matcher), owners),
            filter(row -> matches(last(row).matcher), sources),
            filter(row -> matches(last(row).matcher), routes),
            filter(family -> first(family.labels) === scale, raw))
    end
    return recipes, all_routes
end

function _prepared_status_raw_signature(model, object, applications, permissions, destinations)
    I = keytype(model.registry.objects)
    selected = Tuple{Int,Int}[(application.slot, _prepared_status_variant_slot(application, object.id))
        for application in applications
        if _prepared_status_application_matches(model, object, object.parent, application)]
    routes = Tuple{Int,I,Int}[]
    for plan in destinations
        application = only(a for a in applications if a.slot == plan.application_slot)
        for (execution_id, producer) in model.registry.objects
            _prepared_status_application_matches(model, producer, producer.parent, application) || continue
            _prepared_status_route_matches(model, object, object.parent,
                application, plan, execution_id) || continue
            push!(routes, (plan.slot, execution_id,
                _prepared_status_variant_slot(application, execution_id)))
        end
    end
    sources = Tuple{Int,I,Int}[]
    for (application, permission) in zip(applications, permissions), source in permission.sources
        for (consumer_id, consumer) in model.registry.objects
            _prepared_status_application_matches(model, consumer, consumer.parent, application) || continue
            _prepared_status_route_matches(model, object, object.parent,
                application, source, consumer_id) || continue
            push!(sources, (source.slot, consumer_id,
                _prepared_status_variant_slot(application, consumer_id)))
        end
    end
    labels = _prepared_status_object_labels(model, object, object.parent)
    return (labels=(labels.scale, labels.kind, labels.species),
        selected=selected, destinations=routes, sources=sources)
end

# Materialized source exports preserve the original supplied-data conversion
# records. Their original TYPES still describe the numerical configuration even
# when an unreconstructible callback was intentionally omitted from the export.
function _prepared_status_raw_configured_references(model, object, names, references)
    configured = copy(references)
    for (index, name) in enumerate(names)
        key = _status_conversion_record_key(name;
            object_id=object.id, origin=:supplied_status)
        record = get(model.status_conversion_records, key, nothing)
        record isa StatusConversionRecord || continue
        isequal(record.object_id, object.id) && record.variable === name || continue
        isnothing(record.application_id) || continue
        record.origin === :supplied_status || continue
        # Diagnostic metadata from a superseded class is not evidence for the
        # actual constructor-owned RAW family being prepared here.
        record.effective_type === eltype(references[index]) || continue
        R = _prepared_status_declared_reference(model.status_conversion,
            name, record.original_type, nothing)
        isconcretetype(R) && R <: Ref || continue
        # An unchanged VALUE type cannot justify changing the observed Ref
        # implementation (RefArray/custom Ref is not RefValue).
        eltype(R) === record.effective_type && continue
        configured[index] = R
    end
    return configured
end

function _prepare_status_manifest(model, authored, program, raw_basis)
    # Host traversal uses scalar records; freeze exact owner tuples only once
    # the namespace and all RAW permissions have been prepared.
    recipes = _graph_record_vector(AuthoredApplicationRecipe,
        (item for item in authored if item isa AuthoredApplicationRecipe))
    applications, permissions = _prepared_status_applications(model, recipes, program)
    outputs = _authored_distributed_output_plans(
        _graph_record_vector(AuthoredApplicationRecipe, recipes), program.output_records)
    destinations = _prepared_status_destinations(outputs isa NoCompiledDistributedOutputPlans ? () : outputs.plans)
    names = Symbol[]; refs = Any[]
    # Stable authoring order, captured once; physical absence never creates data.
    for application in recipes
        ports = _application_ports(application)
        for name in (keys(ports.output_types)..., ports.input_names...)
            name in names || (push!(names, name); push!(refs, Union{}))
        end
    end
    raw = if isnothing(raw_basis)
        I = keytype(model.registry.objects)
        observed = PreparedRawStatusFamily{I}[]
        for object in values(model.registry.objects)
            source = object.status
            source isa Status || continue
            raw_names = Symbol[name for name in propertynames(source)]
            raw_refs = DataType[typeof(refvalue(source, name)) for name in raw_names]
            signature = _prepared_status_raw_signature(model, object, applications, permissions, destinations)
            entry = PreparedRawStatusFamily{I}(signature.labels, signature.selected,
                signature.destinations, signature.sources, raw_names, raw_refs)
            any(previous -> _same_prepared_raw_family(previous, entry), observed) ||
                push!(observed, entry)
            configured_refs = _prepared_status_raw_configured_references(
                model, object, raw_names, raw_refs)
            if configured_refs != raw_refs
                configured = PreparedRawStatusFamily{I}(signature.labels,
                    signature.selected, signature.destinations, signature.sources,
                    raw_names, configured_refs)
                any(previous -> _same_prepared_raw_family(previous, configured), observed) ||
                    push!(observed, configured)
            end
        end
        observed
    else
        # A force refresh must not promote materialized defaults or aliases to
        # new RAW permissions. Preserve the genuine constructor-owned evidence.
        raw_basis
    end
    for family in raw, (name, R) in zip(family.names, family.reference_types)
        _prepared_status_add_type!(names, refs, name, R)
    end
    for permission in permissions
        for variant in permission.variants, (name, R) in variant.canonical
            _prepared_status_add_type!(names, refs, name, R)
        end
        for (name, R) in permission.aliases
            _prepared_status_add_type!(names, refs, name, R)
        end
        for source in permission.sources, variant in permission.variants
            input = source.input
            for (name, R) in variant.source_inputs
                name === input && _prepared_status_add_type!(names, refs, source.source_var, R)
            end
        end
    end
    # Distributed default types use the corresponding producer variant owner.
    # They enter the global storage bound even before any destination exists.
    for plan in destinations
        application = only(a for a in recipes if a.slot == plan.application_slot)
        _foreach_application_variant(application) do _, ports
            for name in plan.variable_names
                R = _prepared_status_declared_reference(model.status_conversion, name,
                    getproperty(ports.output_types, name), get(ports.output_element_types, name, nothing))
                _prepared_status_add_type!(names, refs, name, R)
            end
        end
    end
    for application in recipes
        ports = _application_ports(application)
        for name in keys(ports.output_types)
            _publish_mode_for_output(application.spec, name) === :canonical || continue
            index = findfirst(isequal(name), names)
            refs[index] === Union{} && throw(ArgumentError(
                "Canonical field `$(name)` has no exact prospective or actual reference family. " *
                "Prepare a concrete numeric configuration and a finite `status_transform` return family (including value-type parameters such as a particle count). Abstract Required declarations need actual or route type evidence."))
        end
    end
    # This check needs a storage TYPE, not a new right to introduce data. A
    # Required reader can share a canonical field linked by another applicable
    # application on the same object. Its own permission stays unchanged: it
    # cannot use the global slot union to supply an unauthorized RAW reference.
    for application in recipes
        for name in _application_ports(application).input_names
            index = findfirst(isequal(name), names)
            refs[index] !== Union{} && continue
            throw(ArgumentError(
                "Input field `$(name)` has no exact prospective, route or actual reference family " *
                "in the prepared Status namespace. Declare a concrete Required type, producer or configured initial-data family."))
        end
    end
    # Bottom is useful while accumulating absent type evidence, but Julia
    # cannot encode it as a tuple field. Nothing is the physical absence marker;
    # no biological Ref is created for that slot.
    physical_refs = map(R -> R === Union{} ? Nothing : R, refs)
    S = _fixed_status_type(Tuple(names), Tuple{physical_refs...})
    recipes_by_scale, all_routes = _prepared_birth_recipes(S, applications, permissions, destinations, raw, model)
    return PreparedStatusManifest(S, applications, permissions, destinations, raw, recipes_by_scale, all_routes)
end

# The catalog references the SAME prepared manifest; runtime never finds a
# DataType through CompositeModel.scenario_plan_cache::Any.
_prepared_status_manifest(model) = _prepared_status_manifest(model.registry.objects.catalog)
_prepared_status_manifest(catalog::ClosedObjectFamilyCatalog) = catalog.status_manifest

@inline function _with_prepared_canonical_status_type(f::F, model::CompositeModel,
    args::Vararg{Any,N}) where {F,N}
    return _with_prepared_canonical_status_type(f, model.registry.objects.catalog, args...)
end
@generated function _with_prepared_canonical_status_type(f::OP,
    catalog::ClosedObjectFamilyCatalog{F}, args::Vararg{Any,N}) where {OP,F,N}
    schemas = unique(S for family in fieldtypes(F) for S in (family.parameters[2],)
        if S <: Status && fieldtype(S, :vars) <: _FixedStatusStorage)
    length(schemas) == 1 || return :(throw(ArgumentError("The catalog needs exactly one prepared canonical Status type.")))
    S = only(schemas)
    return quote
        $(Expr(:meta, :inline))
        return f($S, args...)
    end
end

# All recorded classes are concrete. Comparing the class keeps custom Refs
# and abstract-valued Refs distinct without reading their contents.
function _prepared_status_reference_allowed(classes, name::Symbol, reference)
    for (field, R) in classes
        field === name && R === typeof(reference) && return true
    end
    return false
end
_prepared_status_variant_reference_allowed(variant, name, reference) =
    _prepared_status_reference_allowed(variant.canonical, name, reference)
_prepared_status_output_reference_allowed(variant, name, reference) =
    _prepared_status_reference_allowed(variant.outputs, name, reference)

function _prepared_status_application_reference_allowed(recipe, model, object, parent_id, name, reference)
    for (application, permission) in recipe.applications
        _prepared_status_application_matches(model, object, parent_id, application) || continue
        variant = _prepared_status_variant_slot(application, object.id)
        _prepared_status_variant_reference_allowed(permission.variants[variant], name, reference) && return true
        _prepared_status_reference_allowed(permission.aliases, name, reference) && return true
    end
    return false
end

# Registered producers and consumers already belong to the registry's scale
# index. A pending object's inherited labels and route still use the full matcher.
_prepared_status_context_ids(objects::AbstractDict) = keys(objects)
function _prepared_status_context_ids(model, application, route, object, parent_id)
    registry = model.registry
    scope = route.matcher.scope
    # A subtree source can only be read or written by an ancestor. For an
    # object awaiting registration the parent's path is already indexed.
    if scope isa Subtree || scope isa Self
        id = _index_object_id(registry.objects, object.id)
        existing = get(registry.objects, id, nothing)
        registered = !isnothing(existing)
        if scope isa Self
            return registered ? (id,) : ()
        end
        anchor = registered ? id : parent_id
        isnothing(anchor) && return ()
        if !registered || (existing === object && isequal(object.parent, parent_id))
            path = get(registry.ancestor_ids_by_object, anchor, nothing)
            isnothing(path) || return path
        end
    end
    scale = application.target_matcher.scale
    scale isa Symbol && return get(model.registry.by_scale, scale, ())
    return _prepared_status_context_ids(model.registry.objects)
end

# One exact application/permission pair enters the producer/route worker.
Base.@constprop :none Base.@noinline function _prepared_status_destination_entry_allowed(
    application, permission, plan, model, object, parent_id, name, reference,
)
    # Visit registered producer identities in place. No candidate vector or
    # synthetic producer is allocated by this admission path.
    has_producer = false
    for candidate_id in _prepared_status_context_ids(model, application, plan, object, parent_id)
        execution_id = _index_object_id(model.registry.objects, candidate_id)
        _prepared_status_application_matches_id(model, model,
            application.target_matcher, execution_id) || continue
        has_producer = true
        _prepared_status_route_matches(model, object, parent_id,
            application, plan, execution_id) || continue
        variant = _prepared_status_variant_slot(application, execution_id)
        _with_metadata_entry(_prepared_status_output_reference_allowed,
            permission.variants, variant, name, reference) && return true
    end
    # Explicit SceneScope without a relation is independent of a producer
    # context. With zero real producers, its base declaration already gives
    # a prospective permission; no RAW family or override is substituted.
    matcher = plan.matcher
    if !has_producer && matcher.scope isa SceneScope && isnothing(matcher.relation)
        id = _index_object_id(model.registry.objects, object.id)
        topology = _prepared_status_topology(model, object, id, parent_id)
        if _selector_matches_object_id(topology, matcher, id,
            nothing, false, nothing, false)
            return _prepared_status_output_reference_allowed(
                first(permission.variants), name, reference)
        end
    end
    return false
end

function _prepared_status_destinations_allow(recipe, model, object, parent_id, name, reference)
    for (application, permission, plan) in recipe.destinations
        name in plan.variable_names || continue
        _prepared_status_destination_entry_allowed(application, permission, plan, model, object,
            parent_id, name, reference) && return true
    end
    return false
end

function _prepared_status_source_input_admission(variant, input, reference)
    declared = false
    for (name, R) in variant.source_inputs
        name === input || continue
        declared = true
        R === typeof(reference) && return (true, true)
    end
    return (declared, !declared)
end

# Return whether a declaration contributes a right, all declarations agree,
# and every applicable route reference family admits the actual class.
# Observed extra RT classes support existing references/reparenting; they do not
# create new initial-data permissions in a different configured source context.
function _prepared_status_source_route_admission(source, application, permission,
    model, object, parent_id, name, reference)
    declared, allowed = false, true
    if source.source_var === name
        has_consumer = false
        for candidate_id in _prepared_status_context_ids(model, application, source, object, parent_id)
            consumer_id = _index_object_id(model.registry.objects, candidate_id)
            _prepared_status_application_matches_id(model, model,
                application.target_matcher, consumer_id) || continue
            has_consumer = true
            _prepared_status_route_matches(model, object, parent_id,
                application, source, consumer_id) || continue
            _prepared_status_reference_allowed(source.references, name, reference) ||
                return (false, false, false)
            has_type, matches = _with_metadata_entry(_prepared_status_source_input_admission,
                permission.variants, _prepared_status_variant_slot(application, consumer_id),
                source.input, reference)
            declared |= has_type
            allowed &= matches
        end
        pending_id = _prepared_status_pending_consumer_id(model, object, parent_id, application)
        if !isnothing(pending_id)
            has_consumer = true
            if _prepared_status_route_matches(model, object, parent_id,
                application, source, pending_id)
                _prepared_status_reference_allowed(source.references, name, reference) ||
                    return (false, false, false)
                has_type, matches = _with_metadata_entry(_prepared_status_source_input_admission,
                    permission.variants, _prepared_status_variant_slot(application, pending_id),
                    source.input, reference)
                declared |= has_type
                allowed &= matches
            end
        end
        matcher = source.matcher
        if !has_consumer && matcher.scope isa SceneScope && isnothing(matcher.relation)
            id = _index_object_id(model.registry.objects, object.id)
            topology = _prepared_status_topology(model, object, id, parent_id)
            if _selector_matches_object_id(topology, matcher, id,
                nothing, false, nothing, false)
                _prepared_status_reference_allowed(source.references, name, reference) ||
                    return (false, false, false)
                declared, allowed = _prepared_status_source_input_admission(
                    first(permission.variants), source.input, reference)
            end
        end
    end
    return (declared, allowed, true)
end

function _prepared_status_sources_admission(recipe, model, object, parent_id, name, reference)
    declared, allowed = false, true
    for (application, permission, source) in recipe.sources
        has_type, matches, compatible = _prepared_status_source_route_admission(source,
            application, permission, model, object, parent_id, name, reference)
        compatible || return (false, false, false)
        declared |= has_type
        allowed &= matches
    end
    return (declared, allowed, true)
end

# Keep erased cells behind the prepared physical bounds before crossing the
# permission worker's function boundary. The worker shares its typed body across
# field names; no caller needs to inline an application scan for every slot.
@generated function _prepared_status_configured_reference_admission(
    recipe::PreparedBirthRecipe{S}, model, object, parent_id, name, reference,
) where {S}
    references = unique(R for slot in fieldtypes(_status_schema_references(S))
        for R in Base.uniontypes(slot) if R <: Ref)
    branches = [quote
        if reference isa $R
            return _prepared_status_reference_admission(
                recipe, model, object, parent_id, name, reference::$R)
        end
    end for R in references]
    return quote
        $(Expr(:meta, :inline))
        $(branches...)
        return (false, false)
    end
end

Base.@constprop :none Base.@noinline function _prepared_status_reference_admission(
    recipe, model, object, parent_id, name, reference::R,
) where {R<:Ref}
    declared, source_allowed, compatible = _prepared_status_sources_admission(
        recipe, model, object, parent_id,
        name, reference::R)
    compatible || return (false, false)
    allowed = (declared && source_allowed) ||
        _prepared_status_application_reference_allowed(recipe,
            model, object, parent_id, name, reference::R) ||
        _prepared_status_destinations_allow(recipe,
            model, object, parent_id, name, reference::R)
    return (allowed, true)
end

function _prepared_status_raw_variant(raw, slot)
    for entry in raw.selected
        first(entry) == slot && return last(entry)
    end
    return 0
end
function _prepared_status_raw_membership_matches(recipe, raw, model, object, parent_id)
    for (application, _) in recipe.applications
        expected = _prepared_status_raw_variant(raw, application.slot)
        matches = _prepared_status_application_matches(model, object, parent_id, application)
        if matches
            expected == _prepared_status_variant_slot(application, object.id) || return false
        elseif !iszero(expected)
            return false
        end
    end
    return true
end

function _prepared_status_raw_has_context(contexts, plan, origin_id, variant)
    for entry in contexts
        # ObjectId uses identity equality; this also avoids dispatch through
        # an abstract identity payload in the nominal evidence vector.
        entry[1] == plan.slot && entry[2] === origin_id && entry[3] == variant && return true
    end
    return false
end
function _prepared_status_raw_destination_count(application, plan, raw, model, object, parent_id)
    count = 0
    for candidate_id in _prepared_status_context_ids(model, application, plan, object, parent_id)
        execution_id = _index_object_id(model.registry.objects, candidate_id)
        _prepared_status_application_matches_id(model, model,
            application.target_matcher, execution_id) || continue
        _prepared_status_route_matches(model, object, parent_id,
            application, plan, execution_id) || continue
        variant = _prepared_status_variant_slot(application, execution_id)
        _prepared_status_raw_has_context(raw.destinations, plan, execution_id, variant) || return -1
        count += 1
    end
    return count
end
function _prepared_status_raw_destination_total(recipe, raw, model, object, parent_id)
    total = 0
    for (application, _, plan) in recipe.destinations
        count = _prepared_status_raw_destination_count(application, plan, raw, model, object, parent_id)
        count < 0 && return -1
        total += count
    end
    return total
end

function _prepared_status_raw_source_count(source, application, raw, model, object, parent_id)
    count = 0
    for candidate_id in _prepared_status_context_ids(model, application, source, object, parent_id)
        consumer_id = _index_object_id(model.registry.objects, candidate_id)
        _prepared_status_application_matches_id(model, model,
            application.target_matcher, consumer_id) || continue
        _prepared_status_route_matches(model, object, parent_id,
            application, source, consumer_id) || continue
        variant = _prepared_status_variant_slot(application, consumer_id)
        _prepared_status_raw_has_context(raw.sources, source,
            consumer_id, variant) || return -1
        count += 1
    end
    pending_id = _prepared_status_pending_consumer_id(model, object, parent_id, application)
    if !isnothing(pending_id) && _prepared_status_route_matches(model, object, parent_id,
        application, source, pending_id)
        variant = _prepared_status_variant_slot(application, pending_id)
        _prepared_status_raw_has_context(raw.sources, source, pending_id, variant) || return -1
        count += 1
    end
    return count
end

function _prepared_status_raw_source_total(recipe, raw, model, object, parent_id)
    total = 0
    for (application, permission, source) in recipe.sources
        count = _prepared_status_raw_source_count(source, application, raw, model, object, parent_id)
        count < 0 && return -1
        total += count
    end
    return total
end

function _prepared_status_raw_matches(raw, recipe, model, object, parent_id)
    labels = _prepared_status_object_labels(model, object, parent_id)
    raw.labels === (labels.scale, labels.kind, labels.species) || return false
    _prepared_status_raw_membership_matches(recipe, raw, model, object, parent_id) || return false
    _prepared_status_raw_destination_total(recipe,
        raw, model, object, parent_id) == length(raw.destinations) || return false
    return _prepared_status_raw_source_total(recipe,
        raw, model, object, parent_id) == length(raw.sources)
end
_prepared_status_raw_reference_allowed(::Nothing, name, reference) = false
function _prepared_status_raw_reference_allowed(raw::PreparedRawStatusFamily,
    name::Symbol, reference)
    index = findfirst(isequal(name), raw.names)
    isnothing(index) && return false
    return typeof(reference) === raw.reference_types[index]
end

# Visit the prepared namespace in order without building a per-field method body.
# The existing finite classifier admits each exact Ref before the shared worker.
function _prepared_status_source_allowed(recipe::PreparedBirthRecipe{S},
    model, object, parent_id, source::Status, raw) where {S}
    present = 0
    for name in _status_schema_names(S)
        reference = _initial_status_reference(source, name)
        if reference !== nothing
            present += 1
            allowed, compatible = _prepared_status_configured_reference_admission(recipe, model,
                object, parent_id, name, reference)
            compatible && (allowed ||
                _prepared_status_raw_reference_allowed(raw, name, reference)) || return false
        end
    end
    return present == _initial_status_reference_count(source)
end

_object_birth_recipe(manifest, object) = get(manifest.birth_recipes, object.scale, manifest.all_routes)

# Initial bootstrap supplies the same manifest explicitly before the catalog
# exists. Runtime delegates through its typed catalog; there is one gather/body.
@inline function _validate_prepared_initial_status(manifest::PreparedStatusManifest,
    model, object, source_status, parent_id)
    isnothing(source_status) && return nothing
    source_status isa Status || throw(ArgumentError("Prepared initial data must be Status or nothing."))
    recipe = _object_birth_recipe(manifest, object)
    allowed = Base.@inline _prepared_status_source_allowed(recipe, model, object, parent_id, source_status, nothing)
    allowed && return nothing
    for raw in recipe.raw_families
        _prepared_status_raw_matches(raw, recipe, model, object, parent_id) || continue
        Base.@inline _prepared_status_source_allowed(recipe, model, object, parent_id, source_status, raw) && return nothing
    end
    throw(ArgumentError("Status reference classes are incompatible with this prepared object configuration/raw family."))
end
@inline function _validate_prepared_initial_status(model, object, source_status, parent_id)
    return _validate_prepared_initial_status(_prepared_status_manifest(model),
        model, object, source_status, parent_id)
end

function _validate_prepared_status_recipe(model, object_id, recipe)
    store = model.registry.objects
    object = store[object_id]
    original = recipe.original
    if recipe.fresh
        _initial_status_reference_count(original) == 0 &&
            isnothing(object.status) ||
            throw(ArgumentError("Fresh prepared status must start with an empty unregistered header."))
    else
        object.status === original &&
            get(store.status_owners, _status_identity(original), nothing) == object_id ||
            throw(ArgumentError("A prepared recipe must retain this object's exact registered header."))
        source_identity = get(model.status_source_identities, object_id, nothing)
        (isnothing(source_identity) ||
            get(model.status_source_owners, source_identity, nothing) == object_id) ||
            throw(ArgumentError("Prepared status source ownership changed."))
    end
    birth_recipe = _object_birth_recipe(_prepared_status_manifest(model), object)
    raw_parent = object.parent
    parent_id = isnothing(raw_parent) ? nothing : _index_object_id(store, raw_parent)
    # A reparent/Scope change never revokes cells already owned by this object.
    # Only NEW edits need active permissions; old aliases grant no new rights.
    for (name, reference) in zip(recipe.edit_names, recipe.edit_references)
        _initial_status_reference(original, name) === reference && continue
        allowed, compatible = _prepared_status_configured_reference_admission(birth_recipe,
            model, object, parent_id, name, reference)
        allowed && compatible || throw(ArgumentError(
            "A staged status reference is incompatible with the prepared object configuration."))
    end
    return nothing
end
