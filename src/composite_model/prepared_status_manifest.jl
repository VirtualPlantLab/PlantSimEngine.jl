# One constructor-owned manifest. This stores names, exact reference classes,
# configured selector owners and raw-family correlations, never default values.
struct PreparedStatusManifest{S,A,P,D,R}
    status_type::Type{S}
    authored::A
    permissions::P
    destinations::D
    raw_families::R
end

# One typed view of the SAME authored specification and ports. Environment
# hint result types and call plans are irrelevant to status permissions.
struct PreparedStatusApplication{S,M,P}
    slot::Int
    id::Symbol
    spec::S
    target_matcher::M
    ports::P
end
_application_ports(application::PreparedStatusApplication) = application.ports

function _prepared_raw_status_families(model)
    catalog = model.registry.objects.catalog
    return catalog isa ClosedObjectFamilyCatalog && catalog.status_manifest isa PreparedStatusManifest ?
        catalog.status_manifest.raw_families : nothing
end

_prepared_status_variant_slot(application, object_id) = begin
    owner = _application_model_overrides(application)
    isnothing(owner) ? 1 : get(owner.object_slots, object_id, 1)
end

function _prepared_status_type_map(names, types)
    return _authored_port_types(identity, NamedTuple{Tuple(names)}(Tuple(types)))
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
function _prepared_status_declared_reference(policy, T, elements)
    configured = _configured_status_value_type(policy, T, elements)
    isnothing(configured) && return Union{}
    members = Base.uniontypes(configured)
    all(isconcretetype, members) || return Union{}
    return Union{map(T -> Base.RefValue{T}, members)...}
end

function _prepared_status_variant_permission(model, application, ports)
    names = Symbol[]; refs = Any[]
    output_names = Symbol[]; output_refs = Any[]
    for name in keys(ports.output_types)
        R = _prepared_status_declared_reference(model.status_conversion,
            getproperty(ports.output_types, name), get(ports.output_element_types, name, nothing))
        _prepared_status_add_type!(output_names, output_refs, name, R)
        name in _model_canonical_output_names(application) || continue
        _prepared_status_add_type!(names, refs, name, R)
    end
    for name in ports.input_names
        R = _prepared_status_declared_reference(model.status_conversion,
            getproperty(ports.input_types, name), get(ports.input_element_types, name, nothing))
        _prepared_status_add_type!(names, refs, name, R)
    end
    return (canonical=_prepared_status_type_map(names, refs),
        outputs=_prepared_status_type_map(output_names, output_refs))
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

function _prepared_status_application_permissions(model, recipes, program)
    return map(recipes) do application
        variants = Any[]
        _foreach_application_variant(application) do _, ports
            push!(variants, _prepared_status_variant_permission(model, application, ports))
        end
        plans = Tuple(plan for plan in program.input_records
            if plan isa CompiledModelInputPlan && plan.application_slot == application.slot)
        # Plan reference classes are common route evidence. Effective model
        # default classes above stay in their individual configured variant.
        alias_names = Symbol[]; alias_refs = Any[]
        for plan in plans
            _prepared_status_add_type!(alias_names, alias_refs,
                plan.input, _prepared_status_input_reference(plan))
        end
        aliases = _prepared_status_type_map(alias_names, alias_refs)
        (slot=application.slot, id=application.id, variants=Tuple(variants), aliases=aliases)
    end
end

function _prepared_status_raw_signature(model, object, recipes, destinations)
    selected = Tuple((application.slot, _prepared_status_variant_slot(application, object.id))
        for application in recipes
        if _prepared_status_application_matches(model, object, object.parent, application))
    routes = Any[]
    for plan in destinations
        application = only(a for a in recipes if a.slot == plan.application_slot)
        for (execution_id, producer) in model.registry.objects
            _prepared_status_application_matches(model, producer, producer.parent, application) || continue
            _prepared_status_destination_matches(model, object, object.parent,
                application, plan, execution_id) || continue
            push!(routes, (plan.slot, execution_id,
                _prepared_status_variant_slot(application, execution_id)))
        end
    end
    labels = _prepared_status_object_labels(model, object, object.parent)
    return (labels=(labels.scale, labels.kind, labels.species),
        selected=selected, destinations=Tuple(routes))
end

function _prepare_status_manifest(model, authored, program, raw_basis)
    recipes = Tuple(item for item in authored if item isa AuthoredApplicationRecipe)
    permissions = _prepared_status_application_permissions(model, recipes, program)
    outputs = _authored_distributed_output_plans(
        _graph_record_vector(AuthoredApplicationRecipe, recipes), program.output_records)
    destinations = outputs isa NoCompiledDistributedOutputPlans ? () : Tuple(outputs.plans)
    names = Symbol[]; refs = Any[]
    # Stable authoring order, captured once; physical absence never creates data.
    for application in recipes
        ports = _application_ports(application)
        for name in (keys(ports.output_types)..., ports.input_names...)
            name in names || (push!(names, name); push!(refs, Union{}))
        end
    end
    raw = if isnothing(raw_basis)
        observed = Any[]
        for object in values(model.registry.objects)
            source = object.status
            source isa Status || continue
            raw_names = propertynames(source)
            raw_refs = Tuple(typeof(refvalue(source, name)) for name in raw_names)
            signature = _prepared_status_raw_signature(model, object, recipes, destinations)
            entry = (signature=signature,
                schema=_prepared_status_type_map(raw_names, raw_refs))
            entry in observed || push!(observed, entry)
        end
        Tuple(observed)
    else
        # A force refresh must not promote materialized defaults or aliases to
        # new RAW permissions. Preserve the genuine constructor-owned evidence.
        raw_basis
    end
    for family in raw, (name, R) in pairs(family.schema)
        _prepared_status_add_type!(names, refs, name, R)
    end
    for permission in permissions
        for variant in permission.variants, (name, R) in pairs(variant.canonical)
            _prepared_status_add_type!(names, refs, name, R)
        end
        for (name, R) in pairs(permission.aliases)
            _prepared_status_add_type!(names, refs, name, R)
        end
    end
    # Distributed default types use the corresponding producer variant owner.
    # They enter the global storage bound even before any destination exists.
    for plan in destinations
        application = only(a for a in recipes if a.slot == plan.application_slot)
        _foreach_application_variant(application) do _, ports
            for name in plan.variable_names
                R = _prepared_status_declared_reference(model.status_conversion,
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
                "Prepare a concrete numeric configuration; arbitrary transforms and abstract Required declarations cannot supply a type witness."))
        end
    end
    for (application, permission) in zip(recipes, permissions)
        for (variant_slot, variant) in pairs(permission.variants)
            for name in _application_ports(application).input_names
                hasproperty(variant.canonical, name) && continue
                hasproperty(permission.aliases, name) && continue
                actual = any(raw) do family
                    any(entry -> entry == (application.slot, variant_slot),
                        family.signature.selected) && hasproperty(family.schema, name)
                end
                actual && continue
                throw(ArgumentError(
                    "Input field `$(name)` has no exact prospective, route or actual reference family " *
                    "for this application variant. Declare a concrete Required type, producer or configured initial-data family."))
            end
        end
    end
    # Bottom is useful while accumulating absent type evidence, but Julia
    # cannot encode it as a tuple field. Nothing is the physical absence marker;
    # no biological Ref is created for that slot.
    physical_refs = map(R -> R === Union{} ? Nothing : R, refs)
    S = _fixed_status_type(Tuple(names), Tuple{physical_refs...})
    applications = map(recipes) do application
        PreparedStatusApplication(application.slot, application.id, application.spec,
            application.target_matcher, application.ports)
    end
    return PreparedStatusManifest(S, applications, permissions, destinations, raw)
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

# Runtime admission is Boolean over the EXISTING typed metadata. It never
# assembles a runtime NamedTuple schema, a type, or a membership-sized tuple.
@generated function _prepared_status_reference_allowed(schema::NamedTuple{Names,T},
    name::Symbol, reference) where {Names,T}
    checks = Expr[]
    for index in eachindex(Names)
        R = fieldtype(T, index).parameters[1]
        push!(checks, :(name === $(QuoteNode(Names[index])) && reference isa $R && return true))
    end
    return quote
        $(checks...)
        return false
    end
end
_prepared_status_variant_reference_allowed(variant, name, reference) =
    _prepared_status_reference_allowed(variant.canonical, name, reference)
_prepared_status_output_reference_allowed(variant, name, reference) =
    _prepared_status_reference_allowed(variant.outputs, name, reference)

_prepared_status_application_reference_allowed(::Tuple{}, ::Tuple{}, model,
    object, parent_id, name, reference) = false
function _prepared_status_application_reference_allowed(applications::Tuple,
    permissions::Tuple, model, object, parent_id, name, reference)
    application, permission = first(applications), first(permissions)
    if _prepared_status_application_matches(model, object, parent_id, application)
        variant = _prepared_status_variant_slot(application, object.id)
        _with_metadata_entry(_prepared_status_variant_reference_allowed,
            permission.variants, variant, name, reference) && return true
        _prepared_status_reference_allowed(permission.aliases, name, reference) && return true
    end
    return _prepared_status_application_reference_allowed(Base.tail(applications),
        Base.tail(permissions), model, object, parent_id, name, reference)
end

_prepared_status_destination_reference_allowed(::Tuple{}, ::Tuple{}, plan,
    model, object, parent_id, name, reference) = false
function _prepared_status_destination_reference_allowed(applications::Tuple,
    permissions::Tuple, plan, model, object, parent_id, name, reference)
    application, permission = first(applications), first(permissions)
    if application.slot == plan.application_slot && name in plan.variable_names
        # Visit registered producer identities in place. No candidate vector or
        # synthetic producer is allocated by this admission path.
        has_producer = false
        for (execution_id, producer) in model.registry.objects
            _prepared_status_application_matches(model, producer, producer.parent, application) || continue
            has_producer = true
            _prepared_status_destination_matches(model, object, parent_id,
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
            topology = _prepared_status_topology(model, object, parent_id)
            if _selector_matches_object_id(topology, matcher, object.id,
                nothing, false, nothing, false)
                return _prepared_status_output_reference_allowed(
                    first(permission.variants), name, reference)
            end
        end
        return false
    end
    return _prepared_status_destination_reference_allowed(Base.tail(applications),
        Base.tail(permissions), plan, model, object, parent_id, name, reference)
end
_prepared_status_destinations_allow(::Tuple{}, manifest, model, object, parent_id, name, reference) = false
function _prepared_status_destinations_allow(plans::Tuple, manifest, model, object, parent_id, name, reference)
    _prepared_status_destination_reference_allowed(manifest.authored, manifest.permissions,
        first(plans), model, object, parent_id, name, reference) && return true
    return _prepared_status_destinations_allow(Base.tail(plans), manifest,
        model, object, parent_id, name, reference)
end
function _prepared_status_configured_reference_allowed(manifest, model, object, parent_id, name, reference)
    return _prepared_status_application_reference_allowed(manifest.authored, manifest.permissions,
        model, object, parent_id, name, reference) ||
        _prepared_status_destinations_allow(manifest.destinations, manifest,
            model, object, parent_id, name, reference)
end

function _prepared_status_raw_variant(raw, slot)
    for entry in raw.signature.selected
        first(entry) == slot && return last(entry)
    end
    return 0
end
_prepared_status_raw_membership_matches(::Tuple{}, raw, model, object, parent_id) = true
function _prepared_status_raw_membership_matches(applications::Tuple, raw, model, object, parent_id)
    application = first(applications)
    expected = _prepared_status_raw_variant(raw, application.slot)
    matches = _prepared_status_application_matches(model, object, parent_id, application)
    if matches
        expected == _prepared_status_variant_slot(application, object.id) || return false
    else
        iszero(expected) || return false
    end
    return _prepared_status_raw_membership_matches(Base.tail(applications), raw, model, object, parent_id)
end
function _prepared_status_raw_has_destination(raw, plan, execution_id, variant)
    for entry in raw.signature.destinations
        entry[1] == plan.slot && entry[2] == execution_id && entry[3] == variant && return true
    end
    return false
end
_prepared_status_raw_destination_count(::Tuple{}, plan, raw, model, object, parent_id) = 0
function _prepared_status_raw_destination_count(applications::Tuple, plan, raw, model, object, parent_id)
    application = first(applications)
    application.slot == plan.application_slot || return _prepared_status_raw_destination_count(
        Base.tail(applications), plan, raw, model, object, parent_id)
    count = 0
    for (execution_id, producer) in model.registry.objects
        _prepared_status_application_matches(model, producer, producer.parent, application) || continue
        _prepared_status_destination_matches(model, object, parent_id,
            application, plan, execution_id) || continue
        variant = _prepared_status_variant_slot(application, execution_id)
        _prepared_status_raw_has_destination(raw, plan, execution_id, variant) || return -1
        count += 1
    end
    return count
end
_prepared_status_raw_destination_total(::Tuple{}, manifest, raw, model, object, parent_id) = 0
function _prepared_status_raw_destination_total(plans::Tuple, manifest, raw, model, object, parent_id)
    count = _prepared_status_raw_destination_count(manifest.authored,
        first(plans), raw, model, object, parent_id)
    count < 0 && return -1
    rest = _prepared_status_raw_destination_total(Base.tail(plans), manifest, raw, model, object, parent_id)
    return rest < 0 ? -1 : count + rest
end
function _prepared_status_raw_matches(raw, manifest, model, object, parent_id)
    labels = _prepared_status_object_labels(model, object, parent_id)
    raw.signature.labels == (labels.scale, labels.kind, labels.species) || return false
    _prepared_status_raw_membership_matches(manifest.authored, raw, model, object, parent_id) || return false
    return _prepared_status_raw_destination_total(manifest.destinations, manifest,
        raw, model, object, parent_id) == length(raw.signature.destinations)
end
_prepared_status_raw_reference_allowed(::Nothing, name, reference) = false
_prepared_status_raw_reference_allowed(raw, name, reference) =
    _prepared_status_reference_allowed(raw.schema, name, reference)

# Each slot visit is emitted from the MANIFEST owner's target schema. Fixed storage has
# nullable exact Ref slots; no variable-length propertynames/ref tuple is built.
@generated function _prepared_status_source_allowed(manifest::PreparedStatusManifest{S},
    model, object, parent_id, source::Status, raw) where {S}
    names = _status_schema_names(S)
    checks = Expr[]
    for name in names
        push!(checks, quote
            reference = _initial_status_reference(source, $(QuoteNode(name)))
            if reference !== nothing
                present += 1
                (_prepared_status_configured_reference_allowed(manifest, model,
                    object, parent_id, $(QuoteNode(name)), reference) ||
                    _prepared_status_raw_reference_allowed(raw, $(QuoteNode(name)), reference)) || return false
            end
        end)
    end
    return quote
        $(Expr(:meta, :inline))
        present = 0
        $(checks...)
        return present == _initial_status_reference_count(source)
    end
end

_prepared_status_raw_source_allowed(::Tuple{}, manifest, model, object, source, parent_id) = false
function _prepared_status_raw_source_allowed(raws::Tuple, manifest, model, object, source, parent_id)
    raw = first(raws)
    if _prepared_status_raw_matches(raw, manifest, model, object, parent_id)
        Base.@inline _prepared_status_source_allowed(manifest, model, object, parent_id, source, raw) && return true
    end
    return _prepared_status_raw_source_allowed(Base.tail(raws), manifest, model, object, source, parent_id)
end

# Initial bootstrap supplies the SAME manifest explicitly before the catalog
# exists. Runtime delegates through its typed catalog; there is one gather/body.
function _validate_prepared_initial_status(manifest::PreparedStatusManifest,
    model, object, source_status, parent_id)
    isnothing(source_status) && return nothing
    source_status isa Status || throw(ArgumentError("Prepared initial data must be Status or nothing."))
    allowed = Base.@inline _prepared_status_source_allowed(manifest, model, object, parent_id, source_status, nothing)
    (allowed || _prepared_status_raw_source_allowed(manifest.raw_families, manifest,
            model, object, source_status, parent_id)) && return nothing
    throw(ArgumentError("Status reference classes are incompatible with this prepared object configuration/raw family."))
end
function _validate_prepared_initial_status(model, object, source_status, parent_id)
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
    manifest = _prepared_status_manifest(model)
    # A reparent/Scope change never revokes cells already owned by this object.
    # Only NEW edits need active permissions; old aliases grant no new rights.
    for (name, reference) in zip(recipe.edit_names, recipe.edit_references)
        _initial_status_reference(original, name) === reference && continue
        _prepared_status_configured_reference_allowed(manifest, model, object,
            object.parent, name, reference) || throw(ArgumentError(
                "A staged status reference is incompatible with the prepared object configuration."))
    end
    return nothing
end
