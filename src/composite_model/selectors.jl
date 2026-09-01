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

struct Scope <: AbstractObjectSelector
    name::Symbol
end
Scope(name::Union{Symbol,AbstractString}) = Scope(Symbol(name))

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
    :name,
    :relation,
    :process,
    :application,
    :var,
    :policy,
    :window,
    :from_status,
    :after,
)
const _OBJECT_LABEL_SYMBOL_FIELDS = (:kind, :species, :scale, :name)
const _OBJECT_ROUTING_SYMBOL_FIELDS = (:process, :var, :application)
const _OBJECT_SELECTOR_POSITIONAL_TYPES =
    Union{SceneScope,Self,Subtree,SelfPlant,Ancestor,Scope,Relation}
const _OBJECT_SELECTOR_FIELDS = (:within, :kind, :species, :scale, :name, :relation)
const _APPLICATION_TARGET_SELECTOR_FIELDS = (:within, :kind, :species, :scale, :name)
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

function _normalize_object_selector_value(key::Symbol, value)
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

function _normalize_selector_kwargs(kwargs)
    unsupported = Symbol[key for key in keys(kwargs) if !(key in _OBJECT_SELECTOR_KEYWORD_FIELDS)]
    isempty(unsupported) || error(
        "Unsupported object selector keyword(s) `$(Tuple(unsupported))`. ",
        "Supported keywords are `$(_OBJECT_SELECTOR_KEYWORD_FIELDS)`."
    )
    return NamedTuple{keys(kwargs)}(
        Tuple(_normalize_object_selector_value(k, v) for (k, v) in pairs(kwargs))
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
struct CompiledNamedScope{I<:ObjectId}
    name::Symbol
    root_id::I
end

"""
Normalized selector criteria used by lifecycle membership checks without
reinterpreting the authored selector at every structural refresh.
"""
struct CompiledSelectorMatcher{S,R,SC,K,SP,N}
    scope::S
    relation::R
    scale::SC
    kind::K
    species::SP
    name::N
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
    invalid = Symbol[field for field in _selector_semantic_fields(selector) if !(field in allowed)]
    isempty(invalid) || error(
        "Selector field(s) `$(Tuple(invalid))` are not valid in ",
        "$(_selector_context_description(context)) selectors. ",
        "Allowed fields are `$(allowed)`."
    )
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

function _model_contract(model)
    return (
        process=process(model),
        inputs=Tuple(Symbol.(keys(_input_schema(model)))),
        outputs=Tuple(Symbol.(keys(outputs_(model)))),
        environment_inputs=Tuple(Symbol.(keys(environment_inputs_(model)))),
        environment_outputs=Tuple(Symbol.(keys(environment_outputs_(model)))),
        variable_contracts=variable_contracts(model),
    )
end

function _validate_model_override_contract!(base, replacement; description)
    base_contract = _model_contract(base)
    replacement_contract = _model_contract(replacement)
    base_contract == replacement_contract && return nothing
    error(
        "$(description) has an incompatible model contract. Expected ",
        "`$(base_contract)`, got `$(replacement_contract)`. Object and instance ",
        "overrides may change parameters or implementation, but not process or declared variables."
    )
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
            for replacement in values(object_models)
                _validate_model_override_contract!(
                    mounted_model,
                    replacement;
                    description="Object override for template application `$(base_name)`",
                )
            end
            mounted_model = ObjectModelOverrides(mounted_model, object_models)
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
    if typeof(left_value) === typeof(right_value) &&
       hasmethod(isless, Tuple{typeof(left_value),typeof(right_value)})
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

# Object-relative selectors created with a newborn organ commonly cover only a
# handful of objects. Probe at most 32 objects before falling back to the
# registry-index heuristic so that those tiny scopes avoid copying a scene-wide
# label index without making large plant subtrees pay for a full extra walk.
const _SCOPE_FIRST_DESCENDANT_LIMIT = 32

function _append_descendant_ids_up_to!(
    ids::Vector{ObjectId},
    model::CompositeModel,
    root_id::ObjectId,
    limit::Int,
)
    length(ids) >= limit && return false
    push!(ids, root_id)
    object = _model_object(model, root_id)
    for child_id in object.children
        _append_descendant_ids_up_to!(ids, model, child_id, limit) ||
            return false
    end
    return true
end

function _descendant_ids_up_to(
    model::CompositeModel,
    root_id::ObjectId,
    limit::Int,
)
    ids = ObjectId[]
    complete = _append_descendant_ids_up_to!(ids, model, root_id, limit)
    return complete ? ids : nothing
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
    isnothing(kind) && return _ancestor_id_by_index(
        ancestors,
        final_index,
        model.registry.by_scale,
        scale,
    )
    isnothing(scale) && return _ancestor_id_by_index(
        ancestors,
        final_index,
        model.registry.by_kind,
        kind,
    )
    haskey(model.registry.by_scale, scale) || return nothing
    haskey(model.registry.by_kind, kind) || return nothing
    scale_ids = model.registry.by_scale[scale]
    kind_ids = model.registry.by_kind[kind]
    for index in final_index:-1:firstindex(ancestors)
        id = @inbounds ancestors[index]
        id in scale_ids && id in kind_ids && return id
    end
    return nothing
end

function _ancestor_id_by_index(
    ancestors::Vector{ObjectId},
    final_index::Int,
    object_index::Dict{Symbol,Set{ObjectId}},
    label::Symbol,
)
    haskey(object_index, label) || return nothing
    matching_ids = object_index[label]
    for index in final_index:-1:firstindex(ancestors)
        id = @inbounds ancestors[index]
        id in matching_ids && return id
    end
    return nothing
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

@inline function _object_is_in_nearest_ancestor_scope(
    model::CompositeModel,
    object_id::ObjectId,
    current_id::ObjectId,
    scale::Union{Nothing,Symbol},
    include_self::Bool,
)
    current_ancestors = _object_ancestor_ids(model.registry, current_id)
    final_index = lastindex(current_ancestors) - (include_self ? 0 : 1)
    final_index < firstindex(current_ancestors) && error(
        "No matching ancestor found for object `$(current_id.value)` and scale `$(scale)`.",
    )
    object_ancestors = _object_ancestor_ids(model.registry, object_id)
    if isnothing(scale)
        ancestor_id = @inbounds current_ancestors[final_index]
        return ancestor_id in object_ancestors
    end
    for index in final_index:-1:firstindex(current_ancestors)
        ancestor_id = @inbounds current_ancestors[index]
        _model_object(model, ancestor_id).scale == scale || continue
        return ancestor_id in object_ancestors
    end
    scale === :Plant && include_self && error(
        "No `scale=:Plant` ancestor found for object `$(current_id.value)`.",
    )
    error(
        "No matching ancestor found for object `$(current_id.value)` and scale `$(scale)`.",
    )
end

@inline function _object_is_nearest_ancestor(
    model::CompositeModel,
    object_id::ObjectId,
    current_id::ObjectId,
    scale::Symbol,
)
    current_ancestors = _object_ancestor_ids(model.registry, current_id)
    final_index = lastindex(current_ancestors) - 1
    final_index < firstindex(current_ancestors) && return false
    for index in final_index:-1:firstindex(current_ancestors)
        ancestor_id = @inbounds current_ancestors[index]
        _model_object(model, ancestor_id).scale == scale || continue
        return object_id == ancestor_id
    end
    return false
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

function _selector_value_from_positional(selectors, ::Type{Relation})
    values = [selector.relation for selector in selectors if selector isa Relation]
    isempty(values) && return nothing
    length(unique(values)) == 1 || error("Conflicting `Relation(...)` selector values: $(values).")
    return only(unique(values))
end

function _criteria_value(criteria, key::Symbol, selector_type)
    positional = _selector_value_from_positional(criteria.selectors, selector_type)
    keyword = haskey(criteria, key) ? getproperty(criteria, key) : nothing
    if !isnothing(positional) && !isnothing(keyword) && positional != keyword
        error("Conflicting selector values for `$(key)`: `$(positional)` and `$(keyword)`.")
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

function _named_scope_root_id(model::CompositeModel, scope::Scope)
    root_id = get(model.registry.by_name, scope.name, nothing)
    if isnothing(root_id)
        candidate = ObjectId(scope.name)
        root_id = haskey(model.registry.objects, candidate) ? candidate : nothing
    end
    if isnothing(root_id)
        available = sort!(unique(Symbol[
            keys(model.registry.by_name)...,
            (id.value for id in keys(model.registry.objects))...,
        ]); by=string)
        suggestions = _near_symbol_matches(scope.name, available)
        error(
            "No named scope or object `$(scope.name)` found in the model registry. ",
            "available=$(available), suggestions=$(suggestions).",
        )
    end
    return root_id
end

_compile_selector_scope(::CompositeModel, scope) = scope
_compile_selector_scope(model::CompositeModel, scope::Scope) =
    CompiledNamedScope(scope.name, _named_scope_root_id(model, scope))

_compile_selector_relation(::Nothing) = nothing
_compile_selector_relation(relation::Symbol) = Val(relation)

function _compile_selector_matcher(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
)
    criteria_ = criteria(selector)
    relation = _criteria_value(criteria_, :relation, Relation)
    scope = _compile_selector_scope(model, _criteria_scope(criteria_))
    scale = _criteria_value(criteria_, :scale)
    kind = _criteria_value(criteria_, :kind)
    species = _criteria_value(criteria_, :species)
    name = haskey(criteria_, :name) ? criteria_.name : nothing
    defaults_to_context = isnothing(scope) &&
                          isnothing(relation) &&
                          isnothing(scale) &&
                          isnothing(kind) &&
                          isnothing(species) &&
                          isnothing(name)
    return CompiledSelectorMatcher(
        scope,
        _compile_selector_relation(relation),
        scale,
        kind,
        species,
        name,
        defaults_to_context,
    )
end

function _scope_object_ids(model::CompositeModel, scope, context)
    if isnothing(scope) || scope isa SceneScope
        return ObjectId[keys(model.registry.objects)...]
    end

    current_id = _object_id_from_context(context)
    if scope isa Self
        isnothing(current_id) && error("`Self()` selectors require a current object context.")
        return ObjectId[current_id]
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

function _registry_selector_ids(index, requested)
    isnothing(requested) && return nothing
    requested_values = requested isa Tuple ? requested : (requested,)
    ids = Set{ObjectId}()
    for value in requested_values
        union!(ids, get(index, Symbol(value), Set{ObjectId}()))
    end
    return ids
end

function _indexed_object_ids(model::CompositeModel; scale=nothing, kind=nothing, species=nothing, name=nothing)
    candidate_sets = Set{ObjectId}[]
    for ids in (
        _registry_selector_ids(model.registry.by_scale, scale),
        _registry_selector_ids(model.registry.by_kind, kind),
        _registry_selector_ids(model.registry.by_species, species),
    )
        isnothing(ids) || push!(candidate_sets, ids)
    end
    if !isnothing(name)
        names = name isa Tuple ? name : (name,)
        push!(
            candidate_sets,
            Set{ObjectId}(
                id for candidate_name in names
                for id in (get(model.registry.by_name, Symbol(candidate_name), nothing),)
                if !isnothing(id)
            ),
        )
    end
    isempty(candidate_sets) && return nothing
    sort!(candidate_sets; by=length)
    ids = copy(first(candidate_sets))
    for candidates in Iterators.drop(candidate_sets, 1)
        intersect!(ids, candidates)
    end
    return ObjectId[ids...]
end

function _object_is_in_subtree(model::CompositeModel, object_id::ObjectId, root_id::ObjectId)
    return root_id in _object_ancestor_ids(model.registry, object_id)
end

function _scope_contains_object(model::CompositeModel, scope, context, object_id::ObjectId)
    (isnothing(scope) || scope isa SceneScope) && return true
    return if scope isa Self
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Self()` selectors require a current object context.")
        object_id == current_id
    elseif scope isa Subtree
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Subtree()` selectors require a current object context.")
        _object_is_in_subtree(model, object_id, current_id)
    elseif scope isa SelfPlant
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`SelfPlant()` selectors require a current object context.")
        _object_is_in_nearest_ancestor_scope(
            model,
            object_id,
            current_id,
            :Plant,
            true,
        )
    elseif scope isa Ancestor
        current_id = _object_id_from_context(context)
        isnothing(current_id) && error("`Ancestor(...)` selectors require a current object context.")
        _object_is_in_nearest_ancestor_scope(
            model,
            object_id,
            current_id,
            scope.scale,
            false,
        )
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

@inline _relation_contains_object(
    ::CompositeModel,
    ::Nothing,
    context_id::ObjectId,
    object_id::ObjectId,
) = true

@inline _relation_contains_object(
    ::CompositeModel,
    ::Val{:self},
    context_id::ObjectId,
    object_id::ObjectId,
) = object_id == context_id

@inline function _relation_contains_object(
    model::CompositeModel,
    ::Val{:parent},
    context_id::ObjectId,
    object_id::ObjectId,
)
    return _model_object(model, context_id).parent == object_id
end

@inline function _relation_contains_object(
    model::CompositeModel,
    ::Val{:children},
    context_id::ObjectId,
    object_id::ObjectId,
)
    return _model_object(model, object_id).parent == context_id
end

@inline function _relation_contains_object(
    model::CompositeModel,
    ::Val{:ancestors},
    context_id::ObjectId,
    object_id::ObjectId,
)
    return object_id != context_id &&
           object_id in _object_ancestor_ids(model.registry, context_id)
end

@inline function _relation_contains_object(
    model::CompositeModel,
    ::Val{:descendants},
    context_id::ObjectId,
    object_id::ObjectId,
)
    return object_id != context_id &&
           context_id in _object_ancestor_ids(model.registry, object_id)
end

@inline function _relation_contains_object(
    model::CompositeModel,
    ::Val{:siblings},
    context_id::ObjectId,
    object_id::ObjectId,
)
    object_id == context_id && return false
    context_parent = _model_object(model, context_id).parent
    return !isnothing(context_parent) &&
           _model_object(model, object_id).parent == context_parent
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
    names = Symbol[]
    for object in objects
        isnothing(object.scale) || push!(scales, object.scale)
        isnothing(object.kind) || push!(kinds, object.kind)
        isnothing(object.species) || push!(species, object.species)
        isnothing(object.name) || push!(names, object.name)
    end
    return (
        scales=sort!(unique!(scales); by=string),
        kinds=sort!(unique!(kinds); by=string),
        species=sort!(unique!(species); by=string),
        names=sort!(unique!(names); by=string),
    )
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
    name=nothing,
)
    available = _available_selector_labels(model, candidate_ids)
    suggestions = (
        scale=_near_symbol_matches(scale, available.scales),
        kind=_near_symbol_matches(kind, available.kinds),
        species=_near_symbol_matches(species, available.species),
        name=_near_symbol_matches(name, available.names),
    )
    expected = selector isa One ? "exactly one" : "zero or one"
    context_id = _object_id_from_context(context)
    error(
        "Expected $(expected) object for selector `$(selector)`, got $(length(matched_ids)). ",
        "context=$(isnothing(context_id) ? nothing : context_id.value), ",
        "matched_ids=$([id.value for id in matched_ids]), ",
        "requested=(scale=$(scale), kind=$(kind), species=$(species), name=$(name)), ",
        "available=$(available), suggestions=$(suggestions)."
    )
end

function _matches_object_criteria(object::Object; scale=nothing, kind=nothing, species=nothing, name=nothing)
    _object_matches_selector_value(object.scale, scale) || return false
    _object_matches_selector_value(object.kind, kind) || return false
    _object_matches_selector_value(object.species, species) || return false
    _object_matches_selector_value(object.name, name) || return false
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
)
    if default_to_context && matcher.defaults_to_context && !isnothing(context)
        return object_id == _object_id_from_context(context)
    end
    object = _model_object(model, object_id)
    _matches_object_criteria(
        object;
        scale=matcher.scale,
        kind=matcher.kind,
        species=matcher.species,
        name=matcher.name,
    ) || return false
    scope = isnothing(matcher.scope) ? default_scope : matcher.scope
    if isnothing(matcher.relation)
        if scope isa Ancestor &&
           !isnothing(matcher.scale) &&
           matcher.scale == scope.scale
            current_id = _object_id_from_context(context)
            isnothing(current_id) && error(
                "`Ancestor(...)` selectors require a current object context.",
            )
            return _object_is_nearest_ancestor(
                model,
                object_id,
                current_id,
                scope.scale,
            )
        end
        return _scope_contains_object(model, scope, context, object_id)
    end
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
    object_ids;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
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

function _selector_matches_any_object_id(
    model::CompositeModel,
    selector::AbstractObjectMultiplicity,
    object_ids;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
)
    return _selector_matches_any_object_id(
        model,
        _compile_selector_matcher(model, selector),
        object_ids;
        context=context,
        default_to_context=default_to_context,
        default_scope=default_scope,
    )
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
    name = matcher.name

    if default_to_context &&
       matcher.defaults_to_context &&
       !isnothing(context)
        return ObjectId[_object_id_from_context(context)]
    end

    has_indexed_criteria = !isnothing(scale) ||
                           !isnothing(kind) ||
                           !isnothing(species) ||
                           !isnothing(name)
    scope_candidate_ids = if isnothing(relation) && has_indexed_criteria
        if scope isa Self
            _scope_object_ids(model, scope, context)
        elseif scope isa Subtree
            current_id = _object_id_from_context(context)
            isnothing(current_id) && error(
                "`Subtree()` selectors require a current object context.",
            )
            _descendant_ids_up_to(
                model,
                current_id,
                _SCOPE_FIRST_DESCENDANT_LIMIT,
            )
        else
            nothing
        end
    else
        nothing
    end
    indexed_ids = if isnothing(scope_candidate_ids)
        _indexed_object_ids(
            model;
            scale=scale,
            kind=kind,
            species=species,
            name=name,
        )
    else
        nothing
    end
    candidate_ids = if !isnothing(scope_candidate_ids)
        scope_candidate_ids
    elseif isnothing(relation)
        if scope isa Ancestor && !isnothing(scale) && scale == scope.scale
            current_id = _object_id_from_context(context)
            isnothing(current_id) && error(
                "`Ancestor(...)` selectors require a current object context."
            )
            ancestor_id = _ancestor_id(
                model,
                current_id;
                scale=scope.scale,
                include_self=false,
            )
            isnothing(ancestor_id) ? ObjectId[] : ObjectId[ancestor_id]
        elseif isnothing(indexed_ids)
            _scope_object_ids(model, scope, context)
        elseif isnothing(scope) || scope isa SceneScope
            indexed_ids
        elseif length(indexed_ids) * 4 <= length(model.registry.objects)
            ObjectId[
                id for id in indexed_ids
                if _scope_contains_object(model, scope, context, id)
            ]
        else
            scoped_ids = Set(_scope_object_ids(model, scope, context))
            ObjectId[id for id in indexed_ids if id in scoped_ids]
        end
    else
        related_ids = _relation_object_ids(model, relation, context)
        if isnothing(explicit_scope)
            related_ids
        else
            scoped_ids = Set(_scope_object_ids(model, explicit_scope, context))
            ObjectId[id for id in related_ids if id in scoped_ids]
        end
    end
    ids = ObjectId[
        id for id in candidate_ids
        if _matches_object_criteria(
            _model_object(model, id);
            scale=scale,
            kind=kind,
            species=species,
            name=name,
        )
    ]
    _sort_object_ids!(ids)

    diagnostic_candidate_ids = if !isnothing(scope_candidate_ids)
        # Indexed candidates already satisfy the requested labels. Preserve
        # that diagnostic contract for ambiguous singular matches, while an
        # empty match still reports every label available inside the scope.
        isempty(ids) ? scope_candidate_ids : ids
    elseif isempty(ids) && !isnothing(indexed_ids)
        if isnothing(relation)
            _scope_object_ids(model, scope, context)
        else
            related_ids = _relation_object_ids(model, relation, context)
            if isnothing(explicit_scope)
                related_ids
            else
                scoped_ids = Set(_scope_object_ids(model, explicit_scope, context))
                ObjectId[id for id in related_ids if id in scoped_ids]
            end
        end
    else
        candidate_ids
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
            name=name,
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
            name=name,
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
