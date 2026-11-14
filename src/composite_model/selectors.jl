struct SceneScope <: AbstractObjectSelector end

"""
    Self()

Select the current object: the object on which the consuming model application
runs. `Self()` means a plant only when that object is itself the plant.
"""
struct Self <: AbstractObjectSelector end
struct Subtree <: AbstractObjectSelector end
struct SelfPlant <: AbstractObjectSelector end

struct Ancestor <: AbstractObjectSelector
    scale::Union{Nothing,Symbol}
end
Ancestor(; scale=nothing) = Ancestor(_maybe_symbol(scale))

"""
    Scope(root)

Select the subtree rooted at an object ID or at an `ObjectInstance` name.
A symbolic root first identifies an instance, then an object ID. Use
`Scope(ObjectId(id))` to select an object explicitly when the two identifiers
coincide. Object display names do not define scopes.
"""
struct Scope{R} <: AbstractObjectSelector
    root::R
end
Scope(root::AbstractString) = Scope(Symbol(root))

struct Relation <: AbstractObjectSelector
    relation::Symbol
    function Relation(relation::Symbol)
        relation in _OBJECT_RELATIONS || error(
            "Unsupported object relation `$(relation)`. Supported relations are $(_OBJECT_RELATIONS)."
        )
        return new(relation)
    end
end
const _OBJECT_RELATIONS = (:self, :parent, :children, :ancestors, :descendants, :siblings)
Relation(relation::AbstractString) = Relation(Symbol(relation))

_maybe_symbol(x) = isnothing(x) ? nothing : Symbol(x)

const _OBJECT_SELECTOR_KEYWORD_FIELDS = (
    :within,
    :kind,
    :species,
    :scale,
    :id,
    :relation,
    :process,
    :application,
    :var,
    :policy,
    :window,
    :from_status,
    :after,
)
const _OBJECT_LABEL_SYMBOL_FIELDS = (:kind, :species, :scale)
const _OBJECT_ROUTING_SYMBOL_FIELDS = (:process, :var, :application)
const _OBJECT_SELECTOR_POSITIONAL_TYPES =
    Union{SceneScope,Self,Subtree,SelfPlant,Ancestor,Scope,Relation}
const _OBJECT_SELECTOR_FIELDS = (:within, :kind, :species, :scale, :id, :relation)
const _APPLICATION_TARGET_SELECTOR_FIELDS = (:within, :kind, :species, :scale, :id)
const _INPUT_SELECTOR_FIELDS = (
    _OBJECT_SELECTOR_FIELDS...,
    :process,
    :application,
    :var,
    :policy,
    :window,
    :from_status,
    :after,
)
const _CALL_SELECTOR_FIELDS = (
    _OBJECT_SELECTOR_FIELDS...,
    :process,
    :application,
)

function _selector_context_fields(context::Symbol)
    context == :application_target && return _APPLICATION_TARGET_SELECTOR_FIELDS
    context in (:object_query, :output_request, :output_destination) &&
        return _OBJECT_SELECTOR_FIELDS
    context == :input && return _INPUT_SELECTOR_FIELDS
    context == :call && return _CALL_SELECTOR_FIELDS
    error("Unsupported selector validation context `$(context)`.")
end

function _selector_context_description(context::Symbol)
    context == :application_target && return "application-target"
    context == :object_query && return "object-query"
    context == :output_request && return "output-request"
    context == :output_destination && return "output-destination"
    context == :input && return "input-binding"
    context == :call && return "call-binding"
    return string(context)
end

function _maybe_symbol_collection(value)
    value isa Tuple && return Tuple(_maybe_symbol(item) for item in value)
    value isa AbstractVector && return Tuple(_maybe_symbol(item) for item in value)
    return _maybe_symbol(value)
end

function _normalize_object_id_criterion(value)
    isnothing(value) && return nothing
    value isa Union{Tuple,AbstractVector} && return Tuple(ObjectId(id) for id in value)
    return ObjectId(value)
end

Base.@constprop :aggressive function _normalize_object_selector_value(key::Symbol, value)
    key == :id && return _normalize_object_id_criterion(value)
    key == :within && begin
        value isa Union{SceneScope,Self,Subtree,SelfPlant,Ancestor,Scope} || error(
            "Selector keyword `within` must be a topology scope such as `Self()`, ",
            "`SelfPlant()`, `SceneScope()`, `Ancestor(...)`, or `Scope(...)`; ",
            "got `$(repr(value))`."
        )
        return value
    end
    key == :relation && return Relation(value).relation
    key == :after && begin
        values = value isa Union{Tuple,AbstractVector} ? value : (value,)
        isempty(values) && error("Selector keyword `after` cannot be empty.")
        return Tuple(Symbol(item) for item in values)
    end
    key == :from_status && begin
        value isa Bool || error(
            "Selector keyword `from_status` must be `true` or `false`, got `$(repr(value))`."
        )
        return value
    end
    key in _OBJECT_LABEL_SYMBOL_FIELDS && return _maybe_symbol_collection(value)
    key in _OBJECT_ROUTING_SYMBOL_FIELDS && return _maybe_symbol(value)
    return value
end

function _object_matches_selector_value(object_value, requested)
    isnothing(requested) && return true
    requested isa Tuple && return object_value in requested
    return object_value == requested
end

Base.@constprop :aggressive function _normalize_selector_kwargs(kwargs::NamedTuple{K}) where {K}
    if !all(key -> key in _OBJECT_SELECTOR_KEYWORD_FIELDS,K)
        unsupported = filter(key -> !(key in _OBJECT_SELECTOR_KEYWORD_FIELDS),K)
        error(
            "Unsupported object selector keyword(s) `$(unsupported)`. ",
            "Supported keywords are `$(_OBJECT_SELECTOR_KEYWORD_FIELDS)`."
        )
    end
    return NamedTuple{K}(
        map(_normalize_object_selector_value,K,values(kwargs))
    )
end

function _normalize_selector_criteria(args::Tuple; kwargs...)
    selectors = Tuple(args)
    all(selector -> selector isa _OBJECT_SELECTOR_POSITIONAL_TYPES, selectors) || error(
        "Object selector positional arguments are reserved for topology selectors such as ",
        "`Self()`, `Ancestor(...)`, `Scope(...)`, or `Relation(...)`. ",
        "Use keyword criteria such as `kind=:plant` and `scale=:Leaf` for labels."
    )
    normalized_kwargs = _normalize_selector_kwargs((; kwargs...))
    return (; selectors=selectors, normalized_kwargs...)
end

struct One{C<:NamedTuple} <: AbstractObjectMultiplicity
    criteria::C
end
struct OptionalOne{C<:NamedTuple} <: AbstractObjectMultiplicity
    criteria::C
end
struct Many{C<:NamedTuple} <: AbstractObjectMultiplicity
    criteria::C
end

One(args...; kwargs...) = One(_normalize_selector_criteria(args; kwargs...))
OptionalOne(args...; kwargs...) = OptionalOne(_normalize_selector_criteria(args; kwargs...))
Many(args...; kwargs...) = Many(_normalize_selector_criteria(args; kwargs...))

criteria(selector::AbstractObjectMultiplicity) = selector.criteria
multiplicity(::One) = :one
multiplicity(::OptionalOne) = :optional_one
multiplicity(::Many) = :many

"""A named topology scope resolved once while the scenario plan is compiled."""
struct CompiledNamedScope{R,I<:ObjectId}
    reference::R
    root_id::I
end

"""
Normalized selector criteria used by lifecycle membership checks without
reinterpreting the authored selector at every structural refresh.
"""
struct CompiledSelectorMatcher{S,R,SC,K,SP,I}
    scope::S
    relation::R
    scale::SC
    kind::K
    species::SP
    id::I
    defaults_to_context::Bool
end

function _selector_semantic_fields(selector::AbstractObjectMultiplicity)
    selector_criteria = criteria(selector)
    fields = Symbol[Symbol(key) for key in keys(selector_criteria) if Symbol(key) != :selectors]
    for atom in selector_criteria.selectors
        atom isa Relation ? push!(fields, :relation) : push!(fields, :within)
    end
    return unique!(fields)
end

function _validate_selector_context(
    selector::AbstractObjectMultiplicity,
    context::Symbol,
)
    allowed = _selector_context_fields(context)
    invalid = Symbol[]
    for field in _selector_semantic_fields(selector)
        accepted = false
        for allowed_field in allowed
            if field === allowed_field
                accepted = true
                break
            end
        end
        accepted || push!(invalid, field)
    end
    if !isempty(invalid)
        allowed_fields = Symbol[]
        for field in allowed
            push!(allowed_fields, field)
        end
        io = IOBuffer()
        ancestors = Any[]
        print(io, "Selector field(s) `")
        _print_selector_diagnostic(io, invalid, ancestors)
        print(io, "` are not valid in ", _selector_context_description(context),
            " selectors. Allowed fields are `")
        _print_selector_diagnostic(io, allowed_fields, ancestors)
        print(io, "`.")
        error(String(take!(io)))
    end
    if context == :application_target
        scope = _criteria_scope(criteria(selector))
        scope isa Union{Nothing,SceneScope,Scope} || error(
            "Application-target selectors have no current object, so `within=$(repr(scope))` ",
            "cannot be resolved. Use `SceneScope()` or a named `Scope(...)`; ",
            "use object-relative scopes in `inputs` and `calls`."
        )
    end
    return selector
end

function _validate_selector_context(selector, context::Symbol)
    error(
        "$(_selector_context_description(context)) selectors must use `One(...)`, ",
        "`OptionalOne(...)`, or `Many(...)`; got `$(typeof(selector))`."
    )
end

_rebuild_selector(::One, criteria) = One{typeof(criteria)}(criteria)
_rebuild_selector(::OptionalOne, criteria) = OptionalOne{typeof(criteria)}(criteria)
_rebuild_selector(::Many, criteria) = Many{typeof(criteria)}(criteria)
_selector_as_many(selector::AbstractObjectMultiplicity) =
    Many{typeof(criteria(selector))}(criteria(selector))

function _selector_with_scope(selector::AbstractObjectMultiplicity, scope)
    selector_criteria = criteria(selector)
    haskey(selector_criteria, :within) && return selector
    return _rebuild_selector(selector, merge(selector_criteria, (; within=scope)))
end

function _selector_with_application_prefix(
    selector::AbstractObjectMultiplicity,
    instance_name::Symbol,
    template_application_names::Set{Symbol},
)
    selector_criteria = criteria(selector)
    haskey(selector_criteria, :application) || return selector
    application = selector_criteria.application
    isnothing(application) && return selector
    application in template_application_names || return selector
    mounted_name = Symbol(instance_name, "__", application)
    return _rebuild_selector(selector, merge(selector_criteria, (; application=mounted_name)))
end

function _selector_with_previous_timestep(
    selector::AbstractObjectMultiplicity,
    previous::PreviousTimeStep,
)
    return _rebuild_selector(
        selector,
        merge(criteria(selector), (; policy=previous)),
    )
end

function _mounted_application_name(spec, index::Int)
    name = application_name(spec)
    return isnothing(name) ? process(spec) : name
end

function _instance_override_models(instance::ObjectInstance, specs)
    selected = Dict{Int,AbstractModel}()
    for (key, replacement) in pairs(instance.overrides)
        replacement isa AbstractModel || error(
            "Override `$(key)` for instance `$(instance.name)` must be an `AbstractModel`, got `$(typeof(replacement))`."
        )
        matches = findall(
            index ->
                Symbol(key) ==
                _mounted_application_name(specs[index], index),
            eachindex(specs),
        )
        isempty(matches) && error(
            "Override `$(key)` for instance `$(instance.name)` does not match a template application name."
        )
        length(matches) == 1 || error(
            "Override `$(key)` for instance `$(instance.name)` matches several template applications; use a unique application name."
        )
        index = only(matches)
        haskey(selected, index) && error(
            "Several overrides target template application `$(_mounted_application_name(specs[index], index))` in instance `$(instance.name)`."
        )
        _validate_model_override_contract!(
            model_(specs[index]),
            replacement;
            description="Override `$(key)` for instance `$(instance.name)`",
        )
        selected[index] = replacement
    end
    return selected
end

function _validate_model_override_contract!(base, replacement; description)
    base_contract = model_interface(base)
    replacement_contract = model_interface(replacement)
    isequal(base_contract, replacement_contract) && return (; base=base_contract, replacement=replacement_contract)
    error(
        "$(description) has an incompatible model contract. Expected ",
        "`$(base_contract)`, got `$(replacement_contract)`. Object and instance ",
        "overrides may change parameters or implementation, but not the full compiled " *
        "interface (port schemas, contracts, dependencies, or runtime traits)."
    )
end

function _configured_variant_ports(contract)
    input_defaults = _input_default_values(contract.inputs)
    output_defaults = _local_output_declarations(contract.outputs)
    return (
        input_types=_authored_port_types(_input_expected_type, contract.inputs),
        output_types=_authored_port_types(_output_value_type, contract.outputs),
        output_element_types=_authored_output_element_types(contract.outputs),
        input_names=keys(contract.inputs), output_names=keys(contract.outputs),
        input_default_names=keys(input_defaults), output_default_names=keys(output_defaults),
        defaults_types=_authored_port_types(identity,
            (inputs=typeof(input_defaults), outputs=typeof(output_defaults))),
    )
end

function _prepare_object_model_overrides(base, object_models; description)
    isempty(object_models) && throw(ArgumentError("Object overrides must not be empty."))
    entries = Any[]
    I = Union{map(typeof, collect(keys(object_models)))...}
    slots = Dict{I,Int}()
    for (object_id, replacement) in pairs(object_models)
        contracts = _validate_model_override_contract!(base, replacement; description)
        isempty(entries) && push!(entries, (model=base, ports=_configured_variant_ports(contracts.base)))
        slot = findfirst(entry -> entry.model === replacement, entries)
        if isnothing(slot)
            push!(entries, (model=replacement, ports=_configured_variant_ports(contracts.replacement)))
            slot = length(entries)
        end
        slots[object_id] = slot
    end
    return ObjectModelOverrides(ConfiguredModelVariants(Tuple(entries), slots))
end

function _object_override_models(instance::ObjectInstance, specs, instance_ids)
    entries = Dict{Int,Vector{Pair{ObjectId,AbstractModel}}}()
    valid_ids = Set(instance_ids)
    for override in instance.object_overrides
        override.object in valid_ids || error(
            "Object override for `$(override.object.value)` does not belong to instance `$(instance.name)`."
        )
        matches = findall(
            index ->
                override.application ==
                _mounted_application_name(specs[index], index),
            eachindex(specs),
        )
        isempty(matches) && error(
            "Object override for `$(override.object.value)` in instance `$(instance.name)` ",
            "does not match a template application."
        )
        length(matches) == 1 || error(
            "Object override for `$(override.object.value)` in instance `$(instance.name)` ",
            "matches several template applications."
        )
        index = only(matches)
        object_models = get!(entries, index, Pair{ObjectId,AbstractModel}[])
        any(entry -> first(entry) == override.object, object_models) && error(
            "Several object overrides target application `$(_mounted_application_name(specs[index], index))` ",
            "on object `$(override.object.value)` in instance `$(instance.name)`."
        )
        _validate_model_override_contract!(
            model_(specs[index]),
            override.model;
            description="Object override for `$(override.object.value)` in instance `$(instance.name)`",
        )
        push!(object_models, override.object => override.model)
    end
    selected = Dict{Int,Any}()
    for (index, object_models) in entries
        selected[index] = _typed_object_model_dict(object_models)
    end
    return selected
end

function _typed_object_model_dict(entries)
    isempty(entries) && return Dict{ObjectId,AbstractModel}()
    model_type = typeof(last(first(entries)))
    if all(entry -> typeof(last(entry)) == model_type, entries)
        models = Dict{ObjectId,model_type}()
        for (object_id, model) in entries
            models[object_id] = model
        end
        return models
    end
    return Dict{ObjectId,AbstractModel}(entries)
end

function _map_selector_bindings(bindings::NamedTuple, f)
    mapped = Pair{Symbol,Any}[]
    for (name, selector) in pairs(bindings)
        push!(mapped, Symbol(name) => (selector isa AbstractObjectMultiplicity ? f(selector) : selector))
    end
    return (; mapped...)
end

function _map_call_bindings(bindings::NamedTuple, f)
    mapped = Pair{Symbol,Any}[]
    for (name, binding) in pairs(bindings)
        selector = _call_binding_selector(binding)
        push!(
            mapped,
            Symbol(name) => _call_binding_with_selector(binding, f(selector)),
        )
    end
    return (; mapped...)
end

function _mount_updates(updates, instance_name::Symbol, base_names)
    return Tuple(
        Updates(
            update.variables...;
            after=Tuple(
                label in base_names ? Symbol(instance_name, "__", label) : label
                for label in update.after
            ),
        )
        for update in updates
    )
end

function _mount_object_instance_applications(instance::ObjectInstance, instance_ids)
    specs = Tuple(as_model_spec(application) for application in instance.template.applications)
    base_names = Set(_mounted_application_name(spec, index) for (index, spec) in pairs(specs))
    instance_overrides = _instance_override_models(instance, specs)
    object_overrides = _object_override_models(instance, specs, instance_ids)
    mounted = Any[]
    for (index, spec) in pairs(specs)
        base_name = _mounted_application_name(spec, index)
        mounted_name = Symbol(instance.name, "__", base_name)
        target = applies_to(spec)
        isnothing(target) && error(
            "Template application `$(base_name)` has no `ModelSpec(...; on=...)` selector."
        )
        mounted_target = _selector_with_scope(target, Scope(instance.name))
        prefix_application = selector -> _selector_with_application_prefix(
            selector,
            instance.name,
            base_names,
        )
        mounted_inputs = _map_selector_bindings(value_inputs(spec), prefix_application)
        mounted_calls = _map_call_bindings(model_calls(spec), prefix_application)
        mounted_updates = _mount_updates(updates(spec), instance.name, base_names)
        mounted_model = get(instance_overrides, index, model_(spec))
        if haskey(object_overrides, index)
            object_models = object_overrides[index]
            mounted_model = _prepare_object_model_overrides(mounted_model, object_models;
                description="Object override for template application `$(base_name)`")
        end
        push!(
            mounted,
            _replace_model_spec(
                spec;
                model=mounted_model,
                name=mounted_name,
                on=mounted_target,
                inputs=mounted_inputs,
                calls=mounted_calls,
                updates=mounted_updates,
            ),
        )
    end
    return Tuple(mounted)
end

function _mount_object_instance_applications(instances, instance_ids)
    mounted = Any[]
    for instance in instances
        append!(
            mounted,
            _mount_object_instance_applications(instance, instance_ids[instance.name]),
        )
    end
    return Tuple(mounted)
end

function _object_id_isless(left::ObjectId, right::ObjectId)
    left_value = left.value
    right_value = right.value
    # Keep each identity type in one ordered group. Mixing natural ordering
    # within a type with string ordering between types is not transitive, and
    # distinct identities such as `1` and `Symbol("1")` otherwise compare equal.
    if typeof(left_value) !== typeof(right_value)
        return isless(string(typeof(left_value)), string(typeof(right_value)))
    end
    if hasmethod(isless, Tuple{typeof(left_value),typeof(right_value)})
        return isless(left_value, right_value)
    end
    return isless(string(left_value), string(right_value))
end

_sort_object_ids!(ids) = sort!(ids; lt=_object_id_isless)

function _object_id_from_context(context)
    isnothing(context) && return nothing
    context isa Object && return context.id
    return ObjectId(context)
end

function _append_descendant_ids!(
    ids::Vector{ObjectId},
    model::CompositeModel,
    root_id::ObjectId,
)
    push!(ids, root_id)
    object = _model_object(model, root_id)
    for child_id in object.children
        _append_descendant_ids!(ids, model, child_id)
    end
    return ids
end

function _descendant_ids(model::CompositeModel, root_id::ObjectId)
    return _append_descendant_ids!(ObjectId[], model, root_id)
end

function _descendant_ids_up_to(
    model::CompositeModel,
    root_id::ObjectId,
    limit::Int,
)
    ids = ObjectId[]
    # Borrow child vectors and retain only a depth-sized cursor stack. Pushing
    # every child onto a worklist would allocate for a huge subtree even when
    # a sparse index gives this traversal a budget of only a few objects.
    cursors = Tuple{Vector{ObjectId},Int}[]
    current_id = root_id
    while true
        length(ids) >= limit && return nothing
        push!(ids, current_id)
        children = _model_object(model, current_id).children
        if !isempty(children)
            push!(cursors, (children, 2))
            current_id = first(children)
            continue
        end
        found_next = false
        while !isempty(cursors)
            siblings, next_index = pop!(cursors)
            next_index > length(siblings) && continue
            push!(cursors, (siblings, next_index + 1))
            current_id = siblings[next_index]
            found_next = true
            break
        end
        found_next || return ids
    end
end

function _ancestor_id(
    model::CompositeModel,
    current_id::ObjectId;
    scale=nothing,
    kind=nothing,
    include_self::Bool=true,
)
    return _ancestor_id(
        model,
        current_id,
        _maybe_symbol(scale),
        _maybe_symbol(kind),
        include_self,
    )
end

function _ancestor_id(
    model::CompositeModel,
    current_id::ObjectId,
    scale::Union{Nothing,Symbol},
    kind::Union{Nothing,Symbol},
    include_self::Bool,
)
    ancestors = _object_ancestor_ids(model.registry, current_id)
    final_index = lastindex(ancestors) - (include_self ? 0 : 1)
    final_index < firstindex(ancestors) && return nothing
    isnothing(scale) && isnothing(kind) &&
        return @inbounds ancestors[final_index]
    !isnothing(scale) && !haskey(model.registry.by_scale, scale) && return nothing
    !isnothing(kind) && !haskey(model.registry.by_kind, kind) && return nothing
    for index in final_index:-1:firstindex(ancestors)
        id = @inbounds ancestors[index]
        _ancestor_matches_indexed_labels(model, id, scale, kind) && return id
    end
    return nothing
end

# An ancestry path may contain several concrete ObjectId types. Keep each
# scalar index lookup inside that identity's dispatch boundary so immutable
# index and family-store headers do not escape across a dynamic call.
@noinline function _ancestor_matches_indexed_labels(
    model::CompositeModel, id::ObjectId,
    scale::Union{Nothing,Symbol}, kind::Union{Nothing,Symbol},
)
    _model_object(model, id)
    return (isnothing(scale) || id in model.registry.by_scale[scale]) &&
           (isnothing(kind) || id in model.registry.by_kind[kind])
end

function _ancestor_ids(model::CompositeModel, current_id::ObjectId)
    ids = ObjectId[]
    parent_id = _model_object(model, current_id).parent
    while !isnothing(parent_id)
        push!(ids, parent_id)
        parent_id = _model_object(model, parent_id).parent
    end
    return ids
end

function _relation_object_ids(model::CompositeModel, relation::Symbol, context)
    current_id = _object_id_from_context(context)
    isnothing(current_id) && error(
        "`Relation(:$(relation))` selectors require a current object context."
    )
    object = _model_object(model, current_id)
    relation == :self && return ObjectId[current_id]
    relation == :parent && return isnothing(object.parent) ? ObjectId[] : ObjectId[object.parent]
    relation == :children && return copy(object.children)
    relation == :ancestors && return _ancestor_ids(model, current_id)
    relation == :descendants && return _descendant_ids(model, current_id)[2:end]
    if relation == :siblings
        isnothing(object.parent) && return ObjectId[]
        return ObjectId[
            sibling_id for sibling_id in _model_object(model, object.parent).children
            if sibling_id != current_id
        ]
    end
    error("Unsupported object relation `$(relation)`.")
end

function _selector_scope_from_positional(selectors)
    scopes = filter(
        selector -> selector isa Union{SceneScope,Self,Subtree,SelfPlant,Ancestor,Scope},
        selectors,
    )
    isempty(scopes) && return nothing
    length(scopes) == 1 || error("Only one scope selector can be used in one object selector.")
    return only(scopes)
end

_first_positional_relation(::Tuple{}) = nothing
function _first_positional_relation(selectors::Tuple)
    selector = first(selectors)
    selector isa Relation && return selector
    return _first_positional_relation(Base.tail(selectors))
end

function _selector_value_from_positional(selectors, ::Type{Relation})
    relation = _first_positional_relation(selectors)
    isnothing(relation) && return nothing
    first_value = relation.relation
    for selector in selectors
        if selector isa Relation && selector.relation != first_value
            values = Symbol[]
            for candidate in selectors
                candidate isa Relation && push!(values, candidate.relation)
            end
            io = IOBuffer()
            print(io, "Conflicting `Relation(...)` selector values: ")
            _print_selector_diagnostic(io, values, Any[])
            print(io, '.')
            error(String(take!(io)))
        end
    end
    return first_value
end

function _criteria_value(criteria, key::Symbol, selector_type)
    positional = _selector_value_from_positional(criteria.selectors, selector_type)
    keyword = haskey(criteria, key) ? getproperty(criteria, key) : nothing
    if !isnothing(positional) && !isnothing(keyword) && positional != keyword
        io = IOBuffer()
        ancestors = Any[]
        print(io, "Conflicting selector values for `", String(key), "`: `")
        _print_selector_diagnostic(io, positional, ancestors)
        print(io, "` and `")
        _print_selector_diagnostic(io, keyword, ancestors)
        print(io, "`.")
        error(String(take!(io)))
    end
    return isnothing(keyword) ? positional : keyword
end

_criteria_value(criteria, key::Symbol) =
    haskey(criteria, key) ? getproperty(criteria, key) : nothing

function _criteria_scope(criteria)
    positional = _selector_scope_from_positional(criteria.selectors)
    keyword = haskey(criteria, :within) ? criteria.within : nothing
    if !isnothing(positional) && !isnothing(keyword) && positional != keyword
        error("Conflicting scope selectors: `$(positional)` and `$(keyword)`.")
    end
    return isnothing(keyword) ? positional : keyword
end

# Resolve the authored root identity independently from current membership.
# Preparation can retain a future scope without caching a missing-root failure.
function _named_scope_root_candidate(model::CompositeModel, scope::Scope)
    if scope.root isa Symbol
        for instance in model.instances
            instance.name == scope.root || continue
            return _instance_root_id(instance), instance.name
        end
    end
    return ObjectId(scope.root), nothing
end

function _named_scope_root_id(model::CompositeModel, scope::Scope)
    root_id, instance_name = _named_scope_root_candidate(model, scope)
    haskey(model.registry.objects, root_id) && return root_id
    isnothing(instance_name) || error(
        "Object instance `$(instance_name)` has no current root object `$(root_id.value)`.",
    )
    available_ids = [id.value for id in object_ids(model)]
    available_instances = sort!(Symbol[instance.name for instance in model.instances]; by=string)
    symbolic_ids = Symbol[id for id in available_ids if id isa Symbol]
    suggestions = root_id.value isa Symbol ?
                  _near_symbol_matches(root_id.value, unique!([available_instances; symbolic_ids])) : Symbol[]
    error(
        "No instance or object ID `$(root_id.value)` found in the model registry. ",
        "available_ids=$(available_ids), available_instances=$(available_instances), ",
        "suggestions=$(suggestions).",
    )
end

_compile_selector_scope(::CompositeModel, scope) = scope
_compile_selector_scope(model::CompositeModel, scope::Scope) =
    CompiledNamedScope(scope.root, _named_scope_root_id(model, scope))

_compile_selector_relation(::Nothing) = nothing
_compile_selector_relation(relation::Symbol) = Val(relation)

function _authored_selector_matcher(selector::AbstractObjectMultiplicity)
    criteria_ = criteria(selector)
    relation = _criteria_value(criteria_, :relation, Relation)
    scope = _criteria_scope(criteria_)
    scale = _criteria_value(criteria_, :scale)
    kind = _criteria_value(criteria_, :kind)
    species = _criteria_value(criteria_, :species)
    id = _criteria_value(criteria_, :id)
    defaults_to_context = isnothing(scope) &&
                          isnothing(relation) &&
                          isnothing(scale) &&
                          isnothing(kind) &&
                          isnothing(species) &&
                          isnothing(id)
    return CompiledSelectorMatcher(
        scope,
        _compile_selector_relation(relation),
        scale,
        kind,
        species,
        id,
        defaults_to_context,
    )
end

_selector_matcher_with_scope(matcher::CompiledSelectorMatcher, scope) =
    CompiledSelectorMatcher(scope, matcher.relation, matcher.scale, matcher.kind,
        matcher.species, matcher.id, matcher.defaults_to_context)

function _resolve_selector_matcher(model::CompositeModel, matcher::CompiledSelectorMatcher)
    return _selector_matcher_with_scope(matcher, _compile_selector_scope(model, matcher.scope))
end

_compile_selector_matcher(model::CompositeModel, selector::AbstractObjectMultiplicity) =
    _resolve_selector_matcher(model, _authored_selector_matcher(selector))

function _scope_object_ids(model::CompositeModel, scope, context)
    if isnothing(scope) || scope isa SceneScope
        return collect(keys(model.registry.objects))
    end

    current_id = _object_id_from_context(context)
    if scope isa Self
        isnothing(current_id) && error("`Self()` selectors require a current object context.")
        return [current_id]
    elseif scope isa Subtree
        isnothing(current_id) && error("`Subtree()` selectors require a current object context.")
        return _descendant_ids(model, current_id)
    elseif scope isa SelfPlant
        isnothing(current_id) && error("`SelfPlant()` selectors require a current object context.")
        plant_id = _ancestor_id(
            model,
            current_id,
            :Plant,
            nothing,
            true,
        )
        isnothing(plant_id) && error("No `scale=:Plant` ancestor found for object `$(current_id.value)`.")
        return _descendant_ids(model, plant_id)
    elseif scope isa Ancestor
        isnothing(current_id) && error("`Ancestor(...)` selectors require a current object context.")
        ancestor_id = _ancestor_id(
            model,
            current_id;
            scale=scope.scale,
            include_self=false,
        )
        if isnothing(ancestor_id)
            error("No matching ancestor found for object `$(current_id.value)` and selector `$(scope)`.")
        end
        return _descendant_ids(model, ancestor_id)
    elseif scope isa Scope
        return _descendant_ids(model, _named_scope_root_id(model, scope))
    elseif scope isa CompiledNamedScope
        return haskey(model.registry.objects, scope.root_id) ?
               _descendant_ids(model, scope.root_id) : ObjectId[]
    end

    error("Unsupported object scope selector `$(scope)` of type `$(typeof(scope))`.")
end

function _registry_selector_candidates(index, requested)
    isnothing(requested) && return nothing
    if !(requested isa Tuple)
        bucket = get(index, requested, ())
        return (ids=bucket, estimate=length(bucket))
    end
    requested_values = requested
    # Unlabelled objects have no index bucket. Another criterion may still
    # provide a complete candidate source; otherwise scan the registry.
    any(isnothing, requested_values) && return nothing
    buckets = map(value -> get(index, value, ()), requested_values)
    return (ids=Iterators.flatten(buckets), estimate=sum(length, buckets; init=0))
end

function _smallest_indexed_candidates(model::CompositeModel; scale=nothing, kind=nothing, species=nothing, id=nothing)
    smallest = nothing
    for candidates in (
        _registry_selector_candidates(model.registry.by_scale, scale),
        _registry_selector_candidates(model.registry.by_kind, kind),
        _registry_selector_candidates(model.registry.by_species, species),
    )
        isnothing(candidates) && continue
        if isnothing(smallest) || candidates.estimate < smallest.estimate
            smallest = candidates
        end
    end
    if !isnothing(id)
        requested_ids = id isa Tuple ? id : (id,)
        if isnothing(smallest) || length(requested_ids) < smallest.estimate
            smallest = (ids=requested_ids, estimate=length(requested_ids))
        end
    end
    return smallest
end

function _indexed_object_ids(model::CompositeModel; scale=nothing, kind=nothing, species=nothing, id=nothing)
    candidates = _smallest_indexed_candidates(model; scale, kind, species, id)
    if isnothing(candidates) && all(isnothing, (scale, kind, species, id))
        return nothing
    end
    candidate_ids = isnothing(candidates) ? keys(model.registry.objects) : candidates.ids
    return unique!(ObjectId[
        candidate for candidate in candidate_ids
        if haskey(model.registry.objects, candidate) &&
           _matches_object_criteria(_model_object(model, candidate); scale, kind, species, id)
    ])
end

# Resolve topology once, before choosing between a bounded local walk and a
# borrowed index bucket. The budget follows this query's global candidate count,
# rather than a fixed cutoff that penalizes many medium-sized plant subtrees.
function _selector_subtree_root(model::CompositeModel, scope, context)
    if scope isa Union{Subtree,SelfPlant,Ancestor}
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`$(scope)` selectors require a current object context.")
        _model_object(model, current_id)
        scope isa Subtree && return current_id
        root = _scope_anchor(model, scope, current_id)
        if isnothing(root)
            scope isa SelfPlant && error("No `scale=:Plant` ancestor found for object `$(current_id.value)`.")
            error("No matching ancestor found for object `$(current_id.value)` and selector `$(scope)`.")
        end
        return root
    elseif scope isa Scope
        return _named_scope_root_id(model, scope)
    elseif scope isa CompiledNamedScope
        return scope.root_id
    end
    return nothing
end

# A query owns its resolved root only until its current candidates are consumed.
# Existing compiled named scopes already carry this root; relations and nearest
# ancestor queries retain their original point predicates.
function _query_scope_matcher(matcher::CompiledSelectorMatcher, scope, root)
    (isnothing(matcher.relation) && !isnothing(root) &&
     !(scope isa CompiledNamedScope)) || return matcher
    return _selector_matcher_with_scope(matcher, CompiledNamedScope(scope, root))
end

function _query_scope_matcher(model::CompositeModel, matcher::CompiledSelectorMatcher,
    context, default_scope)
    isnothing(matcher.relation) || return matcher
    scope = isnothing(matcher.scope) ? default_scope : matcher.scope
    if scope isa Ancestor && !isnothing(matcher.scale) && matcher.scale == scope.scale
        return matcher
    end
    return _query_scope_matcher(matcher, scope, _selector_subtree_root(model, scope, context))
end

# On Julia 1.10, keep the target ID unboxed when the ancestor's ID type is unknown.
@inline function _object_is_in_subtree(model::CompositeModel, object_id::ObjectId, root_id::ObjectId)
    return root_id in _object_ancestor_ids(model.registry, object_id)
end

@inline _point_scope_contains(topology, ::Union{Nothing,SceneScope}, origin, object) = true

@inline _point_scope_contains(topology, ::Self, origin, object) =
    _relation_same_object(topology, origin, object)

@inline _point_scope_contains(topology, ::Subtree, origin, object) =
    _relation_in_subtree(topology, object, origin)

@inline _scope_ancestor(model::CompositeModel, origin, scale, include_self) =
    _ancestor_id(model, origin, scale, nothing, include_self)

@inline _scope_anchor(topology, ::SelfPlant, origin) =
    _scope_ancestor(topology, origin, :Plant, true)
@inline _scope_anchor(topology, scope::Ancestor, origin) =
    _scope_ancestor(topology, origin, scope.scale, false)

@inline function _required_scope_anchor(topology, scope, origin)
    root = _scope_anchor(topology, scope, origin)
    isnothing(root) && _missing_point_scope_anchor(topology, scope, origin)
    return root
end

_missing_point_scope_anchor(::CompositeModel, ::SelfPlant, id) =
    error("No `scale=:Plant` ancestor found for object `$(id.value)`.")
_missing_point_scope_anchor(::CompositeModel, scope::Ancestor, id) =
    error("No matching ancestor found for object `$(id.value)` and scale `$(scope.scale)`.")

@inline _point_scope_contains(topology, scope::Union{SelfPlant,Ancestor}, origin, object) =
    _relation_in_subtree(topology, object, _required_scope_anchor(topology, scope, origin))

@inline function _nearest_ancestor_matches(topology, scope::Ancestor, origin, object)
    ancestor = _scope_anchor(topology, scope, origin)
    return !isnothing(ancestor) && _relation_same_object(topology, ancestor, object)
end

function _scope_contains_object(model::CompositeModel, scope, context, object_id::ObjectId)
    scope isa Union{Nothing,SceneScope} &&
        return _point_scope_contains(model, scope, context, object_id)
    return if scope isa Self
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Self()` selectors require a current object context.")
        _point_scope_contains(model, scope, current_id, object_id)
    elseif scope isa Subtree
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Subtree()` selectors require a current object context.")
        _point_scope_contains(model, scope, current_id, object_id)
    elseif scope isa SelfPlant
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`SelfPlant()` selectors require a current object context.")
        _point_scope_contains(model, scope, current_id, object_id)
    elseif scope isa Ancestor
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Ancestor(...)` selectors require a current object context.")
        _point_scope_contains(model, scope, current_id, object_id)
    elseif scope isa Scope
        _object_is_in_subtree(
            model,
            object_id,
            _named_scope_root_id(model, scope),
        )
    elseif scope isa CompiledNamedScope
        haskey(model.registry.objects, scope.root_id) &&
            _object_is_in_subtree(model, object_id, scope.root_id)
    else
        error(
            "Unsupported object scope selector `$(scope)` of type `$(typeof(scope))`.",
        )
    end
end

# Share relation predicates across topology representations while keeping
# registry lookups and traversal specific to each representation.
@inline _relation_parent(model::CompositeModel, id) = _model_object(model, id).parent
@inline _relation_in_subtree(model::CompositeModel, id, root) =
    _object_is_in_subtree(model, id, root)
@inline _relation_same_object(::CompositeModel, left, right) = left == right

@inline _relation_contains_object(topology, ::Nothing, origin, object) = true

@inline _relation_contains_object(topology, ::Val{:self}, origin, object) =
    _relation_same_object(topology, origin, object)

@inline function _relation_contains_object(topology, ::Val{:parent}, origin, object)
    parent = _relation_parent(topology, origin)
    return !isnothing(parent) && _relation_same_object(topology, parent, object)
end

@inline function _relation_contains_object(topology, ::Val{:children}, origin, object)
    return _relation_contains_object(topology, Val(:parent), object, origin)
end

@inline function _relation_contains_object(topology, ::Val{:ancestors}, origin, object)
    return !_relation_same_object(topology, origin, object) &&
           _relation_in_subtree(topology, origin, object)
end

@inline function _relation_contains_object(topology, ::Val{:descendants}, origin, object)
    return _relation_contains_object(topology, Val(:ancestors), object, origin)
end

@inline function _relation_contains_object(topology, ::Val{:siblings}, origin, object)
    _relation_same_object(topology, origin, object) && return false
    origin_parent = _relation_parent(topology, origin)
    isnothing(origin_parent) && return false
    object_parent = _relation_parent(topology, object)
    return !isnothing(object_parent) &&
           _relation_same_object(topology, origin_parent, object_parent)
end

function _symbol_edit_distance(left::Symbol, right::Symbol)
    a = collect(string(left))
    b = collect(string(right))
    previous = collect(0:length(b))
    current = similar(previous)
    for i in eachindex(a)
        current[1] = i
        for j in eachindex(b)
            substitution = previous[j] + (a[i] == b[j] ? 0 : 1)
            current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, substitution)
        end
        previous, current = current, previous
    end
    return previous[end]
end

function _near_symbol_matches(requested, available)
    isnothing(requested) && return Symbol[]
    requested isa Tuple && return unique!(reduce(
        vcat, (_near_symbol_matches(value, available) for value in requested); init=Symbol[],
    ))
    requested_symbol = Symbol(requested)
    threshold = max(2, cld(length(string(requested_symbol)), 3))
    ranked = Tuple{Int,Symbol}[
        (_symbol_edit_distance(requested_symbol, candidate), candidate)
        for candidate in available
    ]
    filter!(pair -> first(pair) <= threshold, ranked)
    sort!(ranked; by=pair -> (first(pair), string(last(pair))))
    return Symbol[last(pair) for pair in Iterators.take(ranked, 3)]
end

function _available_selector_labels(model::CompositeModel, candidate_ids)
    objects = (_model_object(model, id) for id in candidate_ids)
    scales = Symbol[]
    kinds = Symbol[]
    species = Symbol[]
    ids = Vector{keytype(model.registry.objects)}()
    for object in objects
        isnothing(object.scale) || push!(scales, object.scale)
        isnothing(object.kind) || push!(kinds, object.kind)
        isnothing(object.species) || push!(species, object.species)
        push!(ids, object.id)
    end
    return (
        scales=sort!(unique!(scales); by=string),
        kinds=sort!(unique!(kinds); by=string),
        species=sort!(unique!(species); by=string),
        ids=[id.value for id in _sort_object_ids!(unique!(ids))],
    )
end

# Type display is fixed by the schema. Keeping its text constant avoids the
# generic Julia syntax printer in the compiled application's error paths.
@generated function _selector_diagnostic_type_name(::Type{T}) where {T}
    return QuoteNode(string(T))
end

function _print_selector_diagnostic(io, value::T, ancestors) where {T}
    # Ancestors are inspected only with ===; recursive values remain typed by
    # this method's argument, never recovered from the identity stack.
    tracked = ismutabletype(T)
    if tracked
        any(ancestor -> ancestor === value, ancestors) &&
            return print(io, "<circular reference>")
        push!(ancestors, value)
    end
    try
        _print_selector_diagnostic_value(io, value, ancestors)
    finally
        tracked && pop!(ancestors)
    end
    return nothing
end

function _selector_diagnostic_text(value)
    io = IOBuffer()
    _print_selector_diagnostic(io, value, Any[])
    return String(take!(io))
end

function _print_selector_diagnostic_value(io, value::AbstractString, ancestors)
    print(io, '"')
    escape_string(io, value, ('"',))
    print(io, '"')
    return nothing
end

function _print_selector_diagnostic_value(io, value::Symbol, ancestors)
    print(io, "Symbol(")
    _print_selector_diagnostic_value(io, String(value), ancestors)
    print(io, ')')
    return nothing
end

_print_selector_diagnostic_value(io, ::Nothing, ancestors) = print(io, "nothing")

# User numeric types use the record printer too; their custom show methods must
# not silently reintroduce the generic syntax printer.
_print_selector_diagnostic_value(io, value::Union{
    Bool,Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128,
    Float16,Float32,Float64,BigInt,BigFloat,
}, ancestors) =
    print(io, value)

function _print_selector_diagnostic_value(io, value::Char, ancestors)
    print(io, "Char(")
    _print_selector_diagnostic_value(io, string(value), ancestors)
    print(io, ')')
    return nothing
end

function _print_selector_diagnostic_value(io, value::ObjectId, ancestors)
    print(io, "ObjectId(")
    _print_selector_diagnostic(io, value.value, ancestors)
    print(io, ')')
    return nothing
end

function _print_selector_diagnostic_value(io, ::Type{T}, ancestors) where {T}
    print(io, _selector_diagnostic_type_name(T))
    return nothing
end

function _print_selector_diagnostic_items(io, items::Tuple, ancestors)
    isempty(items) && return nothing
    _print_selector_diagnostic(io, first(items), ancestors)
    if length(items) > 1
        print(io, ", ")
        _print_selector_diagnostic_items(io, Base.tail(items), ancestors)
    end
    return nothing
end

function _print_selector_diagnostic_items(io, items::AbstractVector, ancestors)
    for (index, item) in enumerate(items)
        index == 1 || print(io, ", ")
        _print_selector_diagnostic(io, item, ancestors)
    end
    return nothing
end

function _print_selector_diagnostic_value(io, items::Union{Tuple,AbstractVector}, ancestors)
    tuple = items isa Tuple
    print(io, tuple ? '(' : '[')
    _print_selector_diagnostic_items(io, items, ancestors)
    tuple && length(items) == 1 && print(io, ',')
    print(io, tuple ? ')' : ']')
    return nothing
end

function _print_selector_diagnostic_value(io, items::AbstractArray, ancestors)
    print(io, _selector_diagnostic_type_name(typeof(items)), "(size=")
    _print_selector_diagnostic(io, size(items), ancestors)
    print(io, ", values=[")
    for (index, item) in enumerate(items)
        index == 1 || print(io, ", ")
        _print_selector_diagnostic(io, item, ancestors)
    end
    print(io, "])")
    return nothing
end

function _print_selector_diagnostic_value(io, items::AbstractDict, ancestors)
    print(io, _selector_diagnostic_type_name(typeof(items)), '(')
    for (index, (key, value)) in enumerate(items)
        index == 1 || print(io, ", ")
        _print_selector_diagnostic(io, key, ancestors)
        print(io, " => ")
        _print_selector_diagnostic(io, value, ancestors)
    end
    print(io, ')')
    return nothing
end

function _print_selector_diagnostic_value(io, items::AbstractSet, ancestors)
    print(io, _selector_diagnostic_type_name(typeof(items)), '(')
    for (index, item) in enumerate(items)
        index == 1 || print(io, ", ")
        _print_selector_diagnostic(io, item, ancestors)
    end
    print(io, ')')
    return nothing
end

@generated function _print_selector_diagnostic_fields(io, value::T, ancestors) where {T}
    statements = Expr[]
    for (index, name) in enumerate(fieldnames(T))
        index == 1 || push!(statements, :(print(io, ", ")))
        push!(statements, quote
            print(io, $(String(name)), '=')
            if isdefined(value, $index)
                _print_selector_diagnostic(io, getfield(value, $index), ancestors)
            else
                print(io, "<undefined>")
            end
        end)
    end
    return quote
        $(statements...)
        return nothing
    end
end

function _print_selector_diagnostic_value(io, value::NamedTuple, ancestors)
    print(io, '(')
    _print_selector_diagnostic_fields(io, value, ancestors)
    print(io, ')')
    return nothing
end

function _print_selector_diagnostic_record(io, label, value::T, ancestors) where {T}
    print(io, label, '(')
    _print_selector_diagnostic_fields(io, value, ancestors)
    print(io, ')')
    return nothing
end

function _print_selector_diagnostic_value(io, selector::AbstractObjectMultiplicity, ancestors)
    label = selector isa One ? "One" : selector isa OptionalOne ? "OptionalOne" : "Many"
    print(io, label)
    _print_selector_diagnostic_value(io, criteria(selector), ancestors)
    return nothing
end

function _print_selector_diagnostic_value(io, scope::_OBJECT_SELECTOR_POSITIONAL_TYPES, ancestors)
    _print_selector_diagnostic_record(io, String(nameof(typeof(scope))), scope, ancestors)
    return nothing
end

function _print_selector_diagnostic_value(io, value::T, ancestors) where {T}
    if isprimitivetype(T)
        print(io, _selector_diagnostic_type_name(T), "(bytes=")
        _print_selector_diagnostic(io, reinterpret(NTuple{sizeof(T),UInt8}, value), ancestors)
        print(io, ')')
    else
        _print_selector_diagnostic_record(io, _selector_diagnostic_type_name(T), value, ancestors)
    end
    return nothing
end

function _selector_resolution_error(
    model::CompositeModel,
    selector,
    candidate_ids,
    matched_ids;
    context=nothing,
    scale=nothing,
    kind=nothing,
    species=nothing,
    id=nothing,
)
    available = _available_selector_labels(model, candidate_ids)
    suggestions = (
        scale=_near_symbol_matches(scale, available.scales),
        kind=_near_symbol_matches(kind, available.kinds),
        species=_near_symbol_matches(species, available.species),
    )
    expected = selector isa One ? "exactly one" : "zero or one"
    context_id = _object_id_from_context(context)
    io = IOBuffer()
    ancestors = Any[]
    print(io, "Expected ", expected, " object for selector `")
    _print_selector_diagnostic(io, selector, ancestors)
    print(io, "`, got ", length(matched_ids), ". context=")
    _print_selector_diagnostic(io, context_id, ancestors)
    print(io, ", matched_ids=")
    _print_selector_diagnostic(io, matched_ids, ancestors)
    print(io, ", requested=")
    _print_selector_diagnostic(io, (; scale, kind, species, id), ancestors)
    print(io, ", available=")
    _print_selector_diagnostic(io, available, ancestors)
    print(io, ", suggestions=")
    _print_selector_diagnostic(io, suggestions, ancestors)
    print(io, '.')
    error(String(take!(io)))
end

function _matches_object_criteria(object::Object; scale=nothing, kind=nothing, species=nothing, id=nothing)
    _object_matches_selector_value(object.scale, scale) || return false
    _object_matches_selector_value(object.kind, kind) || return false
    _object_matches_selector_value(object.species, species) || return false
    _object_matches_selector_value(object.id, id) || return false
    return true
end

_compiled_relation_symbol(::Val{RELATION}) where {RELATION} = RELATION

function _selector_matches_object_id(
    model::CompositeModel,
    matcher::CompiledSelectorMatcher,
    object_id::ObjectId;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
    relation_resolved::Bool=false,
)
    if default_to_context && matcher.defaults_to_context && !isnothing(context)
        return object_id == _object_id_from_context(context)
    end
    _selector_matches_object_labels(model, matcher, object_id) || return false
    return _selector_matches_object_topology(model, matcher, object_id;
        context, default_scope, relation_resolved)
end

@inline function _selector_matches_object_labels(model::CompositeModel,
    matcher::CompiledSelectorMatcher, object_id::ObjectId)
    return _matches_object_criteria(_model_object(model, object_id);
        scale=matcher.scale, kind=matcher.kind, species=matcher.species, id=matcher.id)
end

function _selector_matches_object_topology(model::CompositeModel,
    matcher::CompiledSelectorMatcher, object_id::ObjectId;
    context=nothing, default_scope=nothing, relation_resolved::Bool=false)
    scope = isnothing(matcher.scope) ? default_scope : matcher.scope
    if isnothing(matcher.relation)
        if scope isa Ancestor &&
           !isnothing(matcher.scale) &&
           matcher.scale == scope.scale
            current_id = _object_id_from_context(context)
            isnothing(current_id) && error(
                "`Ancestor(...)` selectors require a current object context.",
            )
            return _nearest_ancestor_matches(model, scope, current_id, object_id)
        end
        return _scope_contains_object(model, scope, context, object_id)
    end
    if !relation_resolved
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error(
            "`Relation(:$(_compiled_relation_symbol(matcher.relation)))` selectors require a current object context.",
        )
        _relation_contains_object(
            model,
            matcher.relation,
            current_id,
            object_id,
        ) || return false
    end
    return isnothing(matcher.scope) ||
           _scope_contains_object(model, matcher.scope, context, object_id)
end

function _selector_matches_object_id(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
    object_id::ObjectId;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
)
    return _selector_matches_object_id(
        model,
        _compile_selector_matcher(model, selector),
        object_id;
        context=context,
        default_to_context=default_to_context,
        default_scope=default_scope,
    )
end

function _selector_matches_any_object_id(
    model::CompositeModel,
    matcher::CompiledSelectorMatcher,
    object_ids,
    context,
    default_to_context::Bool,
    default_scope,
)
    for object_id in object_ids
        _selector_matches_object_id(
            model,
            matcher,
            object_id;
            context=context,
            default_to_context=default_to_context,
            default_scope=default_scope,
        ) && return true
    end
    return false
end

function resolve_object_ids(model::CompositeModel, selector::AbstractObjectMultiplicity; context=nothing)
    _validate_selector_context(selector, :object_query)
    return _resolve_object_ids(model, selector; context=context)
end

function _resolve_object_ids(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
)
    return _resolve_object_ids(
        model,
        selector,
        _compile_selector_matcher(model, selector);
        context=context,
        default_to_context=default_to_context,
        default_scope=default_scope,
    )
end

function _matching_selector_ids(
    model::CompositeModel,
    matcher::CompiledSelectorMatcher,
    candidates,
    context,
    default_to_context::Bool,
    default_scope,
    relation_resolved::Bool,
)
    # The adaptive candidate source may be a local vector, an index iterator,
    # or registry keys. Specialize this loop at that boundary, rather than
    # dispatching dynamically for every object in a heterogeneous query.
    I = keytype(model.registry.objects)
    ids = Vector{I}()
    for candidate in candidates
        candidate isa I || continue
        id = candidate::I
        haskey(model.registry.objects, id) || continue
        _selector_matches_object_id(
            model, matcher, id; context, default_to_context, default_scope, relation_resolved,
        ) && push!(ids, id)
    end
    return _sort_object_ids!(unique!(ids))
end

function _resolve_object_ids(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
    matcher::CompiledSelectorMatcher;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
)
    relation = isnothing(matcher.relation) ?
               nothing : _compiled_relation_symbol(matcher.relation)

    explicit_scope = matcher.scope
    scope = if !isnothing(explicit_scope)
        explicit_scope
    elseif isnothing(relation)
        default_scope
    else
        nothing
    end
    scale = matcher.scale
    kind = matcher.kind
    species = matcher.species
    requested_id = matcher.id

    if default_to_context &&
       matcher.defaults_to_context &&
       !isnothing(context)
        return ObjectId[_object_id_from_context(context)]
    end

    indexed = _smallest_indexed_candidates(
        model; scale, kind, species, id=requested_id,
    )
    nearest_ancestor = isnothing(relation) && scope isa Ancestor &&
                       !isnothing(scale) && scale == scope.scale
    subtree_root = if nearest_ancestor
        nothing
    elseif relation == :descendants
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error(
            "`Relation(:descendants)` selectors require a current object context.",
        )
        _model_object(model, current_id)
        current_id
    elseif isnothing(relation)
        _selector_subtree_root(model, scope, context)
    else
        nothing
    end
    local_ids = if !isnothing(subtree_root)
        if !haskey(model.registry.objects, subtree_root)
            ObjectId[]
        else
            budget = isnothing(indexed) ? length(model.registry.objects) :
                     min(indexed.estimate, length(model.registry.objects))
            _descendant_ids_up_to(model, subtree_root, budget)
        end
    else
        nothing
    end
    # Only the relation resolver guarantees membership. Borrowed index buckets
    # still need relation checks, and a completed descendant walk includes self.
    relation_resolved = false
    candidate_ids = if nearest_ancestor
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error(
            "`Ancestor(...)` selectors require a current object context.",
        )
        ancestor_id = _ancestor_id(model, current_id; scale=scope.scale, include_self=false)
        isnothing(ancestor_id) ? ObjectId[] : ObjectId[ancestor_id]
    elseif !isnothing(local_ids)
        local_ids
    elseif !isnothing(relation) && relation != :descendants
        relation_resolved = true
        _relation_object_ids(model, relation, context)
    elseif scope isa Self && isnothing(relation)
        self_ids = _scope_object_ids(model, scope, context)
        _model_object(model, only(self_ids))
        self_ids
    elseif !isnothing(indexed)
        indexed.ids
    elseif isnothing(relation)
        _scope_object_ids(model, scope, context)
    else
        relation_resolved = true
        _relation_object_ids(model, relation, context)
    end
    matching_matcher = _query_scope_matcher(matcher, scope, subtree_root)
    ids = _matching_selector_ids(
        model, matching_matcher, candidate_ids, context, default_to_context, default_scope, relation_resolved,
    )

    # Cardinality diagnostics may need all available labels in the topology
    # scope. Materialize them only on an error, never for empty Many queries.
    invalid_cardinality = (selector isa One && length(ids) != 1) ||
                          (selector isa OptionalOne && length(ids) > 1)
    diagnostic_candidate_ids = if invalid_cardinality &&
                                  (isempty(ids) || !isnothing(relation))
        if isnothing(relation)
            _scope_object_ids(model, scope, context)
        else
            related_ids = _relation_object_ids(model, relation, context)
            isnothing(explicit_scope) ? related_ids : ObjectId[
                id for id in related_ids
                if _scope_contains_object(model, explicit_scope, context, id)
            ]
        end
    else
        ids
    end

    if selector isa One && length(ids) != 1
        _selector_resolution_error(
            model,
            selector,
            diagnostic_candidate_ids,
            ids;
            context=context,
            scale=scale,
            kind=kind,
            species=species,
            id=requested_id,
        )
    elseif selector isa OptionalOne && length(ids) > 1
        _selector_resolution_error(
            model,
            selector,
            diagnostic_candidate_ids,
            ids;
            context=context,
            scale=scale,
            kind=kind,
            species=species,
            id=requested_id,
        )
    end
    return ids
end

resolve_objects(model::CompositeModel, selector::AbstractObjectMultiplicity; context=nothing) =
    [_model_object(model, id) for id in resolve_object_ids(model, selector; context=context)]

function _default_dependency_scope(model::CompositeModel, context::ObjectId)
    object = _model_object(model, context)
    (object.scale == :Scene || object.kind == :scene) && return SceneScope()
    return Self()
end
