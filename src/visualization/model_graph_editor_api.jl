abstract type AbstractModelGraphEdit end

"""
    ModelApplicationRef(scope, application_id; instance=nothing)
    GlobalApplicationRef(application_id)
    TemplateApplicationRef(instance, application_id)

Identify the declaration that owns an editable model application. Global
applications are owned directly by the `CompositeModel`; template applications
are owned by the shared `CompositeModelTemplate` mounted by `instance`.

Compiled mounted ids such as `plant_a__leaf_area` are deliberately not accepted
as declaration identities. The graph DTO carries both the compiled id and this
owner reference.
"""
struct ModelApplicationRef
    scope::Symbol
    application_id::Symbol
    instance::Union{Nothing,Symbol}

    function ModelApplicationRef(scope, application_id; instance=nothing)
        normalized_scope = Symbol(scope)
        normalized_scope in (:global, :template) || error(
            "Application scope must be `:global` or `:template`, got `$(normalized_scope)`.",
        )
        normalized_instance = isnothing(instance) ? nothing : Symbol(instance)
        normalized_scope == :global && !isnothing(normalized_instance) && error(
            "A global application reference cannot name a template instance.",
        )
        normalized_scope == :template && isnothing(normalized_instance) && error(
            "A template application reference requires a representative instance.",
        )
        return new(normalized_scope, Symbol(application_id), normalized_instance)
    end
end

GlobalApplicationRef(application_id) =
    ModelApplicationRef(:global, application_id)
TemplateApplicationRef(instance, application_id) =
    ModelApplicationRef(:template, application_id; instance=instance)

struct AddModelApplication{S} <: AbstractModelGraphEdit
    spec::S
end

struct RemoveModelApplication <: AbstractModelGraphEdit
    application::ModelApplicationRef
end

struct ReplaceModelApplicationModel{M<:AbstractModel} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    model::M
end

struct UpdateModelApplication{M<:AbstractModel,S,T} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    model::M
    name::Symbol
    selector::S
    cadence::T
end

struct RenameModelApplication <: AbstractModelGraphEdit
    application::ModelApplicationRef
    name::Symbol
end

struct SetModelApplicationTargets{S} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    selector::S
end

struct SetModelInputBinding{S} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    input::Symbol
    selector::S
end

struct RemoveModelInputBinding <: AbstractModelGraphEdit
    application::ModelApplicationRef
    input::Symbol
end

struct SetModelCallBinding{S} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    call::Symbol
    selector::S
end

struct RemoveModelCallBinding <: AbstractModelGraphEdit
    application::ModelApplicationRef
    call::Symbol
end

struct SetModelApplicationCadence{T} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    cadence::T
end

struct SetModelApplicationEnvironment{C} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    configuration::C
end

struct SetModelOutputRouting <: AbstractModelGraphEdit
    application::ModelApplicationRef
    output::Symbol
    route::Symbol
end

struct SetModelUpdateOrdering{U} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    updates::U
end

struct MarkModelPreviousTimeStep <: AbstractModelGraphEdit
    application::ModelApplicationRef
    input::Symbol
end

struct UnmarkModelPreviousTimeStep <: AbstractModelGraphEdit
    application::ModelApplicationRef
    input::Symbol
end

struct BreakModelCycle{V} <: AbstractModelGraphEdit
    application::ModelApplicationRef
    input::Symbol
    initialize_missing::Bool
    initial_value::V
end

struct AddModelInstance{T<:CompositeModelTemplate,O} <: AbstractModelGraphEdit
    name::Symbol
    template::T
    root_id::ObjectId
    root_object::O
end

function AddModelInstance(name, template::CompositeModelTemplate, root_id; root_object=nothing)
    return AddModelInstance(
        Symbol(name),
        template,
        ObjectId(root_id),
        root_object,
    )
end

struct RemoveModelInstance <: AbstractModelGraphEdit
    name::Symbol
end

RemoveModelInstance(name::Union{Symbol,AbstractString}) = RemoveModelInstance(Symbol(name))

struct SetCompositeModelEnvironment{E} <: AbstractModelGraphEdit
    environment::E
end

struct AddModelObject <: AbstractModelGraphEdit
    object::Object
end

struct RemoveModelObject <: AbstractModelGraphEdit
    object_id::ObjectId
    recursive::Bool
end

RemoveModelObject(object_id; recursive::Bool=true) =
    RemoveModelObject(ObjectId(object_id), recursive)

struct ReparentModelObject <: AbstractModelGraphEdit
    object_id::ObjectId
    parent_id::Union{Nothing,ObjectId}
end

ReparentModelObject(
    object_id::Union{ObjectId,Symbol,AbstractString,Integer},
    parent_id::Union{Nothing,ObjectId,Symbol,AbstractString,Integer},
) = ReparentModelObject(
    ObjectId(object_id),
    isnothing(parent_id) ? nothing : ObjectId(parent_id),
)

struct SetModelObjectStatus{V} <: AbstractModelGraphEdit
    object_id::ObjectId
    variable::Symbol
    value::V
end

SetModelObjectStatus(object_id, variable, value) =
    SetModelObjectStatus(ObjectId(object_id), Symbol(variable), value)

struct SetModelObjectStatuses{V} <: AbstractModelGraphEdit
    object_ids::Vector{ObjectId}
    variable::Symbol
    value::V
end


SetModelObjectStatuses(object_ids, variable, value) = SetModelObjectStatuses(
    ObjectId[ObjectId(object_id) for object_id in object_ids],
    Symbol(variable),
    value,
)

struct RemoveModelObjectStatus <: AbstractModelGraphEdit
    object_id::ObjectId
    variable::Symbol
end

RemoveModelObjectStatus(
    object_id::Union{ObjectId,Symbol,AbstractString,Integer},
    variable::Union{Symbol,AbstractString},
) =
    RemoveModelObjectStatus(ObjectId(object_id), Symbol(variable))

struct SetModelObjectMetadata{C} <: AbstractModelGraphEdit
    object_id::ObjectId
    configuration::C
end

SetModelObjectMetadata(object_id; kwargs...) =
    SetModelObjectMetadata(ObjectId(object_id), (; kwargs...))

struct SetModelInstanceOverride{M<:AbstractModel} <: AbstractModelGraphEdit
    instance::Symbol
    application_id::Symbol
    model::M
end

SetModelInstanceOverride(instance, application_id, model::AbstractModel) =
    SetModelInstanceOverride(Symbol(instance), Symbol(application_id), model)

struct RemoveModelInstanceOverride <: AbstractModelGraphEdit
    instance::Symbol
    application_id::Symbol
end

RemoveModelInstanceOverride(
    instance::Union{Symbol,AbstractString},
    application_id::Union{Symbol,AbstractString},
) =
    RemoveModelInstanceOverride(Symbol(instance), Symbol(application_id))

struct SetModelObjectOverride{M<:AbstractModel} <: AbstractModelGraphEdit
    instance::Symbol
    object_id::ObjectId
    application_id::Symbol
    model::M
end

SetModelObjectOverride(instance, object_id, application_id, model::AbstractModel) =
    SetModelObjectOverride(Symbol(instance), ObjectId(object_id), Symbol(application_id), model)

struct RemoveModelObjectOverride <: AbstractModelGraphEdit
    instance::Symbol
    object_id::ObjectId
    application_id::Symbol
end

RemoveModelObjectOverride(
    instance::Union{Symbol,AbstractString},
    object_id::Union{ObjectId,Symbol,AbstractString,Integer},
    application_id::Union{Symbol,AbstractString},
) =
    RemoveModelObjectOverride(Symbol(instance), ObjectId(object_id), Symbol(application_id))

"""
    apply_model_graph_edit(model, edit; preserve=())

Apply one declarative graph edit transactionally. The input model is not
modified; a deep-copied, cache-invalidated CompositeModel is returned. Configuration
that is temporarily incomplete or cyclic is retained so the editor can display
and repair it. Structural edit errors leave the original model unchanged. Values
listed in `preserve` retain their identity inside the copy; editor sessions use
this for server-side template and environment catalogs.
"""
function _model_graph_deepcopy(model::CompositeModel, preserve=())
    stack = IdDict{Any,Any}()
    for value in preserve
        stack[value] = value
    end
    return Base.deepcopy_internal(model, stack)
end

function apply_model_graph_edit(
    model::CompositeModel,
    edit::AbstractModelGraphEdit;
    preserve=(),
)
    candidate = _model_graph_deepcopy(model, preserve)
    candidate = _apply_model_graph_edit!(candidate, edit)
    _mark_bindings_dirty!(candidate)
    return candidate
end

function _model_edit_application_id(spec)
    normalized = as_model_spec(spec)
    name = application_name(normalized)
    return isnothing(name) ? process(normalized) : name
end

function _model_edit_global_application_ids(model::CompositeModel)
    mounted_ids = Set{Symbol}()
    for instance in model.instances
        union!(mounted_ids, _instance_application_ids(model, instance))
    end
    return Set(
        _model_edit_application_id(spec) for spec in model.applications
        if _model_edit_application_id(spec) ∉ mounted_ids
    )
end

function _model_edit_application_index(model::CompositeModel, application::ModelApplicationRef)
    application.scope == :global || error(
        "Application `$(application.application_id)` is owned by a template.",
    )
    application_id = application.application_id
    application_id in _model_edit_global_application_ids(model) || error(
        "CompositeModel has no global application `$(application_id)`.",
    )
    matches = Int[
        index for (index, spec) in pairs(model.applications)
        if _model_edit_application_id(spec) == application_id
    ]
    isempty(matches) && error("CompositeModel has no application `$(application_id)`.")
    length(matches) == 1 || error(
        "CompositeModel application id `$(application_id)` is ambiguous. Name repeated applications explicitly.",
    )
    return only(matches)
end

function _model_edit_spec(model::CompositeModel, application::ModelApplicationRef)
    if application.scope == :template
        _, instance = _model_edit_instance(model, something(application.instance))
        return _model_edit_template_application_spec(instance, application.application_id)[2]
    end
    return as_model_spec(model.applications[_model_edit_application_index(model, application)])
end

function _replace_model_edit_spec!(model::CompositeModel, application::ModelApplicationRef, spec)
    application.scope == :template && return _model_edit_replace_template_spec(
        model,
        application,
        spec,
    )
    index = _model_edit_application_index(model, application)
    model.applications[index] = spec
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::AddModelApplication)
    spec = as_model_spec(edit.spec)
    application_id = _model_edit_application_id(spec)
    any(item -> _model_edit_application_id(item) == application_id, model.applications) && error(
        "CompositeModel application `$(application_id)` already exists.",
    )
    push!(model.applications, spec)
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelApplication)
    edit.application.scope == :template && return _model_edit_remove_template_application(
        model,
        edit.application,
    )
    deleteat!(model.applications, _model_edit_application_index(model, edit.application))
    return model
end

function _model_edit_remove_template_application(
    model::CompositeModel,
    application::ModelApplicationRef,
)
    _, selected_instance = _model_edit_instance(model, something(application.instance))
    base_name = _model_edit_template_application_id(selected_instance, application.application_id)
    template = selected_instance.template
    template_specs = Any[as_model_spec(item) for item in template.applications]
    indexes = Int[
        index for (index, spec) in pairs(template_specs)
        if _mounted_application_name(spec, index) == base_name
    ]
    index = only(indexes)
    deleteat!(template_specs, index)
    replacement_template = CompositeModelTemplate(
        Tuple(template_specs);
        kind=template.kind,
        species=template.species,
        parameters=template.parameters,
    )
    instances = Any[]
    for instance in model.instances
        if instance.template === template
            overrides = _model_edit_namedtuple_remove(instance.overrides, base_name)
            object_overrides = Tuple(
                override for override in instance.object_overrides
                if override.application != base_name
            )
            push!(instances, _model_edit_normalize_instance(
                instance;
                template=replacement_template,
                overrides=overrides,
                object_overrides=object_overrides,
            ))
        else
            push!(instances, _model_edit_normalize_instance(instance))
        end
    end
    return _model_edit_rebuild_instances(model, Tuple(instances))
end

function _apply_model_graph_edit!(model::CompositeModel, edit::ReplaceModelApplicationModel)
    spec = _model_edit_spec(model, edit.application)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Replacement model for application `$(edit.application.application_id)`",
    )
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; model=edit.model),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::UpdateModelApplication)
    application_id = edit.application.application_id
    spec = _model_edit_spec(model, edit.application)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Updated model for application `$(application_id)`",
    )
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    edit.application.scope == :template && edit.name != application_id && error(
        "Template application names are fixed in the graph editor.",
    )
    if edit.application.scope == :global && edit.name != application_id
        any(item -> _model_edit_application_id(item) == edit.name, model.applications) && error(
            "CompositeModel application `$(edit.name)` already exists.",
        )
    end
    model = _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(
            spec;
            model=edit.model,
            name=edit.name,
            on=edit.selector,
            every=edit.cadence,
        ),
    )
    return edit.name == application_id ? model : _rewrite_model_application_references!(
        model,
        application_id,
        edit.name,
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RenameModelApplication)
    edit.application.scope == :global || error(
        "Template application names are fixed in the graph editor.",
    )
    any(item -> _model_edit_application_id(item) == edit.name, model.applications) && error(
        "CompositeModel application `$(edit.name)` already exists.",
    )
    spec = _model_edit_spec(model, edit.application)
    _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; name=edit.name),
    )
    return _rewrite_model_application_references!(
        model,
        edit.application.application_id,
        edit.name,
    )
end

function _rewrite_model_selector_application(selector, old_id::Symbol, new_id::Symbol)
    selector isa AbstractObjectMultiplicity || return selector
    rewritten = (; (
        Symbol(key) => (
            Symbol(key) == :application && value == old_id ? new_id : value
        )
        for (key, value) in pairs(criteria(selector))
    )...)
    return _rebuild_selector(selector, rewritten)
end

function _model_edit_spec_references_application(spec, application_id::Symbol)
    normalized = as_model_spec(spec)
    selectors = (
        applies_to(normalized),
        values(value_inputs(normalized))...,
        values(model_calls(normalized))...,
    )
    selector_reference = any(selectors) do selector
        selector isa AbstractObjectMultiplicity || return false
        haskey(criteria(selector), :application) || return false
        return criteria(selector).application == application_id
    end
    update_reference = any(
        application_id in _update_after(update) for update in updates(normalized)
    )
    return selector_reference || update_reference
end

function _rewrite_model_spec_application_references(spec, old_id::Symbol, new_id::Symbol)
    normalized = as_model_spec(spec)
    inputs = (; (
        Symbol(name) => _rewrite_model_selector_application(selector, old_id, new_id)
        for (name, selector) in pairs(value_inputs(normalized))
    )...)
    calls = (; (
        Symbol(name) => _rewrite_model_selector_application(selector, old_id, new_id)
        for (name, selector) in pairs(model_calls(normalized))
    )...)
    target = _rewrite_model_selector_application(applies_to(normalized), old_id, new_id)
    updates_ = Tuple(
        Updates(
            _update_variables(update)...;
            after=Tuple(item == old_id ? new_id : item for item in _update_after(update)),
        )
        for update in updates(normalized)
    )
    return _replace_model_spec(
        normalized;
        inputs=inputs,
        calls=calls,
        on=target,
        updates=updates_,
    )
end

function _rewrite_model_application_references!(model::CompositeModel, old_id::Symbol, new_id::Symbol)
    for (index, raw_spec) in pairs(model.applications)
        _model_edit_spec_references_application(raw_spec, old_id) || continue
        model.applications[index] = _rewrite_model_spec_application_references(
            raw_spec,
            old_id,
            new_id,
        )
    end
    replacements = IdDict{Any,Any}()
    for instance in model.instances
        template = instance.template
        haskey(replacements, template) && continue
        any(
            spec -> _model_edit_spec_references_application(spec, old_id),
            template.applications,
        ) || continue
        replacements[template] = CompositeModelTemplate(
            Tuple(
                _rewrite_model_spec_application_references(spec, old_id, new_id)
                for spec in template.applications
            );
            kind=template.kind,
            species=template.species,
            parameters=template.parameters,
        )
    end
    isempty(replacements) && return model
    instances = Tuple(
        _model_edit_normalize_instance(
            instance;
            template=get(replacements, instance.template, instance.template),
        )
        for instance in model.instances
    )
    return _model_edit_rebuild_instances(model, instances)
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationTargets)
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    spec = _model_edit_spec(model, edit.application)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; on=edit.selector),
    )
end

function _model_edit_namedtuple_set(values::NamedTuple, name::Symbol, value)
    pairs_ = Pair{Symbol,Any}[
        Symbol(key) => (Symbol(key) == name ? value : item)
        for (key, item) in pairs(values)
    ]
    name in Symbol.(keys(values)) || push!(pairs_, name => value)
    return (; pairs_...)
end

function _model_edit_namedtuple_remove(values::NamedTuple, name::Symbol)
    return (; (
        Symbol(key) => item
        for (key, item) in pairs(values)
        if Symbol(key) != name
    )...)
end

function _model_edit_origins_set(origins::NamedTuple, name::Symbol, origin::Symbol)
    return _model_edit_namedtuple_set(origins, name, origin)
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelInputBinding)
    edit.selector isa AbstractObjectMultiplicity || error("An input binding requires an object selector.")
    spec = _model_edit_spec(model, edit.application)
    edit.input in Symbol.(keys(_input_schema(spec))) || error(
        "Application `$(edit.application.application_id)` model has no input `$(edit.input)`.",
    )
    inputs = _model_edit_namedtuple_set(spec.inputs, edit.input, edit.selector)
    origins = _model_edit_origins_set(spec.input_origins, edit.input, :model_spec)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelInputBinding)
    spec = _model_edit_spec(model, edit.application)
    inputs = _model_edit_namedtuple_remove(spec.inputs, edit.input)
    origins = _model_edit_namedtuple_remove(spec.input_origins, edit.input)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelCallBinding)
    edit.selector isa AbstractObjectMultiplicity || error("A call binding requires an object selector.")
    spec = _model_edit_spec(model, edit.application)
    calls = _model_edit_namedtuple_set(spec.calls, edit.call, edit.selector)
    origins = _model_edit_origins_set(spec.call_origins, edit.call, :model_spec)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelCallBinding)
    spec = _model_edit_spec(model, edit.application)
    calls = _model_edit_namedtuple_remove(spec.calls, edit.call)
    origins = _model_edit_namedtuple_remove(spec.call_origins, edit.call)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationCadence)
    spec = _model_edit_spec(model, edit.application)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; every=edit.cadence),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationEnvironment)
    spec = _model_edit_spec(model, edit.application)
    configuration = isnothing(edit.configuration) ? nothing : Environment(edit.configuration)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; environment=configuration),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelOutputRouting)
    edit.route in (:canonical, :stream_only) || error(
        "Output route must be `:canonical` or `:stream_only`.",
    )
    spec = _model_edit_spec(model, edit.application)
    edit.output in Symbol.(keys(outputs_(spec))) || error(
        "Application `$(edit.application.application_id)` model has no output `$(edit.output)`.",
    )
    routing = _model_edit_namedtuple_set(spec.output_routing, edit.output, edit.route)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; output_routing=routing),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelUpdateOrdering)
    spec = _model_edit_spec(model, edit.application)
    return _replace_model_edit_spec!(
        model,
        edit.application,
        _replace_model_spec(spec; updates=edit.updates),
    )
end

function _model_edit_compiled_application_ids(
    model::CompositeModel,
    application::ModelApplicationRef,
)
    application.scope == :global && return Set((application.application_id,))
    _, selected_instance = _model_edit_instance(model, something(application.instance))
    base_name = _model_edit_template_application_id(
        selected_instance,
        application.application_id,
    )
    template = selected_instance.template
    return Set(
        Symbol(instance.name, "__", base_name) for instance in model.instances
        if instance.template === template
    )
end

function _model_edit_unmount_selector(
    selector::AbstractObjectMultiplicity,
    instance::ObjectInstance,
)
    selector_criteria = pairs(criteria(selector))
    prefix = string(instance.name, "__")
    values = Pair{Symbol,Any}[]
    for (key_, value_) in selector_criteria
        key = Symbol(key_)
        value = value_
        key == :within && value isa Scope && value.name == instance.name && continue
        if key == :application && startswith(string(value), prefix)
            value = Symbol(chopprefix(string(value), prefix))
        end
        push!(values, key => value)
    end
    return _rebuild_selector(selector, (; values...))
end

function _apply_model_graph_edit!(model::CompositeModel, edit::MarkModelPreviousTimeStep)
    spec = _model_edit_spec(model, edit.application)
    selector = if haskey(spec.inputs, edit.input)
        getproperty(spec.inputs, edit.input)
    else
        report = compile_model_report(model)
        compiled_ids = _model_edit_compiled_application_ids(model, edit.application)
        selectors = Any[
            binding.selector for binding in report.input_bindings
            if binding.application_id in compiled_ids && binding.input == edit.input
        ]
        isempty(selectors) && error(
            "Application `$(edit.application.application_id)` has no resolved selector for input `$(edit.input)`. Add an input binding first.",
        )
        if edit.application.scope == :template
            _, instance = _model_edit_instance(model, something(edit.application.instance))
            _model_edit_unmount_selector(first(selectors), instance)
        else
            first(selectors)
        end
    end
    selector isa AbstractObjectMultiplicity || error(
        "Input `$(edit.input)` on application `$(edit.application.application_id)` does not use an object selector.",
    )
    previous_selector = _selector_with_previous_timestep(
        selector,
        PreviousTimeStep(edit.input),
    )
    return _apply_model_graph_edit!(
        model,
        SetModelInputBinding(edit.application, edit.input, previous_selector),
    )
end

function _model_selector_without_previous_timestep(selector::AbstractObjectMultiplicity)
    values = (; (
        Symbol(key) => value
        for (key, value) in pairs(criteria(selector))
        if Symbol(key) != :policy
    )...)
    return _rebuild_selector(selector, values)
end

function _apply_model_graph_edit!(model::CompositeModel, edit::UnmarkModelPreviousTimeStep)
    spec = _model_edit_spec(model, edit.application)
    haskey(spec.inputs, edit.input) || error(
        "Application `$(edit.application.application_id)` has no input binding `$(edit.input)`.",
    )
    selector = getproperty(spec.inputs, edit.input)
    _selector_policy(selector) isa PreviousTimeStep || error(
        "Input `$(edit.input)` on application `$(edit.application.application_id)` is not marked PreviousTimeStep.",
    )
    return _apply_model_graph_edit!(
        model,
        SetModelInputBinding(
            edit.application,
            edit.input,
            _model_selector_without_previous_timestep(selector),
        ),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::BreakModelCycle)
    _apply_model_graph_edit!(
        model,
        MarkModelPreviousTimeStep(edit.application, edit.input),
    )
    edit.initialize_missing || return model
    report = compile_model_report(model)
    compiled_ids = _model_edit_compiled_application_ids(model, edit.application)
    applications = [
        application for application in report.applications
        if application.id in compiled_ids
    ]
    isempty(applications) && error(
        "Application `$(edit.application.application_id)` could not be resolved after breaking its cycle.",
    )
    for application in applications
        for object_id in application.target_ids
            object = _model_object(model, object_id)
            supplied = object.status isa Status && edit.input in Symbol.(propertynames(object.status))
            supplied || _set_model_object_status!(model, object_id, edit.input, edit.initial_value)
        end
    end
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::AddModelObject)
    register_object!(model, edit.object)
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelObject)
    removed_ids = edit.recursive ? Set(_descendant_ids(model, edit.object_id)) : Set((edit.object_id,))
    mounted_roots = Dict(_instance_root_id(instance) => instance.name for instance in model.instances)
    protected = intersect(removed_ids, Set(keys(mounted_roots)))
    isempty(protected) || error(
        "Unmount object instance `$(mounted_roots[first(protected)])` before removing its root object.",
    )
    remove_object!(model, edit.object_id; recursive=edit.recursive)
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::ReparentModelObject)
    before = _object_instance_name(model, edit.object_id)
    reparent_object!(model, edit.object_id, edit.parent_id)
    after = _object_instance_name(model, edit.object_id)
    before != after && (!isnothing(before) || !isnothing(after)) && error(
        "Object reparenting cannot cross an instance ownership boundary (`$(before)` to `$(after)`).",
    )
    return model
end

function _model_edit_status_values(status)
    status isa Status || return Pair{Symbol,Any}[]
    return Pair{Symbol,Any}[
        Symbol(name) => status[name]
        for name in propertynames(status)
    ]
end

function _set_model_object_status!(model, object_id, variable, value)
    object = _model_object(model, object_id)
    values = _model_edit_status_values(object.status)
    index = findfirst(pair -> first(pair) == variable, values)
    if isnothing(index)
        push!(values, variable => value)
    else
        values[index] = variable => value
    end
    object.status = Status((; values...))
    delete!(
        get!(
            model.input_default_status_variables,
            object_id,
            Set{Symbol}(),
        ),
        variable,
    )
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelObjectStatus)
    return _set_model_object_status!(model, edit.object_id, edit.variable, edit.value)
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelObjectStatuses)
    isempty(edit.object_ids) && error("SetModelObjectStatuses requires at least one object id.")
    for object_id in edit.object_ids
        _set_model_object_status!(model, object_id, edit.variable, edit.value)
    end
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelObjectStatus)
    object = _model_object(model, edit.object_id)
    values = Pair{Symbol,Any}[
        pair for pair in _model_edit_status_values(object.status)
        if first(pair) != edit.variable
    ]
    object.status = isempty(values) ? nothing : Status((; values...))
    delete!(
        get!(
            model.input_default_status_variables,
            edit.object_id,
            Set{Symbol}(),
        ),
        edit.variable,
    )
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelObjectMetadata)
    object = _model_object(model, edit.object_id)
    allowed = Set((:scale, :kind, :species, :name, :geometry, :parent))
    unknown = setdiff(Set(Symbol.(keys(edit.configuration))), allowed)
    isempty(unknown) || error("Unsupported object metadata fields: $(sort!(collect(unknown); by=string)).")
    if haskey(edit.configuration, :name)
        instance = findfirst(
            item -> _instance_root_id(item) == object.id,
            model.instances,
        )
        if !isnothing(instance)
            required_name = model.instances[instance].name
            edit.configuration.name == required_name || error(
                "Instance root `$(object.id.value)` must keep the instance name `$(required_name)`.",
            )
        end
    end
    _deindex_object!(model.registry, object)
    for (key_, value) in pairs(edit.configuration)
        key = Symbol(key_)
        if key == :parent
            continue
        elseif key == :geometry
            object.geometry = value
        else
            setfield!(object, key, isnothing(value) ? nothing : Symbol(value))
        end
    end
    _index_object!(model.registry, object)
    if haskey(edit.configuration, :parent)
        before = _object_instance_name(model, object.id)
        reparent_object!(model, object.id, edit.configuration.parent)
        after = _object_instance_name(model, object.id)
        before != after && (!isnothing(before) || !isnothing(after)) && error(
            "Object reparenting cannot cross an instance ownership boundary (`$(before)` to `$(after)`).",
        )
    end
    _mark_environment_bindings_dirty!(model, object.id)
    return model
end

function _model_edit_instance(model::CompositeModel, name::Symbol)
    matches = findall(instance -> instance.name == name, model.instances)
    isempty(matches) && error("CompositeModel has no object instance `$(name)`.")
    length(matches) == 1 || error("CompositeModel object instance name `$(name)` is ambiguous.")
    return only(matches), model.instances[only(matches)]
end

function _model_edit_template_application_id(instance::ObjectInstance, application_id::Symbol)
    prefix = string(instance.name, "__")
    candidate = startswith(string(application_id), prefix) ?
                Symbol(chopprefix(string(application_id), prefix)) : application_id
    specs = Tuple(as_model_spec(item) for item in instance.template.applications)
    matches = Symbol[
        _mounted_application_name(spec, index)
        for (index, spec) in pairs(specs)
        if candidate in (_mounted_application_name(spec, index), process(spec))
    ]
    isempty(matches) && error(
        "Instance `$(instance.name)` template has no application matching `$(application_id)`.",
    )
    length(matches) == 1 || error(
        "Instance `$(instance.name)` application `$(application_id)` is ambiguous; use its template application name.",
    )
    return only(matches)
end

function _model_edit_template_application_spec(instance::ObjectInstance, application_id::Symbol)
    base_name = _model_edit_template_application_id(instance, application_id)
    specs = Tuple(as_model_spec(item) for item in instance.template.applications)
    matches = [
        spec for (index, spec) in pairs(specs)
        if _mounted_application_name(spec, index) == base_name
    ]
    return base_name, only(matches)
end

function _model_edit_normalize_instance(
    instance::ObjectInstance;
    template=instance.template,
    overrides=instance.overrides,
    object_overrides=instance.object_overrides,
)
    return ObjectInstance(
        instance.name,
        template;
        root=_instance_root_id(instance),
        overrides=overrides,
        object_overrides=object_overrides,
    )
end

function _model_edit_rebuild_instances(
    model::CompositeModel,
    instances;
    replace_mounted_ids=Set{Symbol}(),
)
    instances = Tuple(_model_edit_normalize_instance(instance) for instance in instances)
    mounted_ids = Set{Symbol}()
    for instance in model.instances
        union!(mounted_ids, _instance_application_ids(model, instance))
    end
    global_applications = Any[
        application for application in model.applications
        if _model_edit_application_id(application) ∉ mounted_ids
    ]
    old_mounted = Dict(
        _model_edit_application_id(application) => as_model_spec(application)
        for application in model.applications
        if _model_edit_application_id(application) in mounted_ids
    )
    rebuilt = CompositeModel(
        (deepcopy(object) for object in model_objects(model))...;
        applications=global_applications,
        instances=instances,
        environment=model.environment,
        source_adapter=model.source_adapter,
    )
    for (index, application) in pairs(rebuilt.applications)
        application_id = _model_edit_application_id(application)
        haskey(old_mounted, application_id) || continue
        application_id in replace_mounted_ids && continue
        old_spec = old_mounted[application_id]
        new_spec = as_model_spec(application)
        rebuilt.applications[index] = _replace_model_spec(old_spec; model=model_(new_spec))
    end
    return rebuilt
end


function _model_edit_replace_template_spec(
    model::CompositeModel,
    application::ModelApplicationRef,
    replacement_spec,
)
    _, selected_instance = _model_edit_instance(model, something(application.instance))
    base_name = _model_edit_template_application_id(
        selected_instance,
        application.application_id,
    )
    template = selected_instance.template
    template_specs = Any[as_model_spec(item) for item in template.applications]
    matches = Int[
        index for (index, spec) in pairs(template_specs)
        if _mounted_application_name(spec, index) == base_name
    ]
    isempty(matches) && error("Template application `$(base_name)` was not found.")
    index = only(matches)
    replacement_name = _mounted_application_name(as_model_spec(replacement_spec), index)
    replacement_name == base_name || error(
        "Template application names are fixed in the graph editor.",
    )
    template_specs[index] = replacement_spec
    replacement_template = CompositeModelTemplate(
        Tuple(template_specs);
        kind=template.kind,
        species=template.species,
        parameters=template.parameters,
    )
    affected = Set{Symbol}()
    instances = Any[]
    for instance in model.instances
        if instance.template === template
            push!(affected, Symbol(instance.name, "__", base_name))
            push!(instances, _model_edit_normalize_instance(instance; template=replacement_template))
        else
            push!(instances, _model_edit_normalize_instance(instance))
        end
    end
    return _model_edit_rebuild_instances(
        model,
        Tuple(instances);
        replace_mounted_ids=affected,
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::AddModelInstance)
    any(instance -> instance.name == edit.name, model.instances) && error(
        "CompositeModel already has an object instance `$(edit.name)`.",
    )
    if !isnothing(edit.root_object)
        edit.root_object isa Object || error("A new instance root must be an Object.")
        edit.root_object.id == edit.root_id || error(
            "The new root object id must match the requested instance root id.",
        )
        haskey(model.registry.objects, edit.root_id) && error(
            "CompositeModel already has object `$(edit.root_id.value)`.",
        )
        register_object!(model, edit.root_object)
    end
    haskey(model.registry.objects, edit.root_id) || error(
        "Object instance `$(edit.name)` refers to missing root `$(edit.root_id.value)`.",
    )
    root = _model_object(model, edit.root_id)
    !isnothing(root.name) && root.name != edit.name && error(
        "Instance name `$(edit.name)` conflicts with root name `$(root.name)`.",
    )
    instance = ObjectInstance(edit.name, edit.template; root=edit.root_id)
    return _model_edit_rebuild_instances(model, (model.instances..., instance))
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelInstance)
    index, _ = _model_edit_instance(model, edit.name)
    instances = Any[model.instances...]
    deleteat!(instances, index)
    return _model_edit_rebuild_instances(model, Tuple(instances))
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetCompositeModelEnvironment)
    mounted_ids = Set{Symbol}()
    for instance in model.instances
        union!(mounted_ids, _instance_application_ids(model, instance))
    end
    global_applications = Tuple(
        application for application in model.applications
        if _model_edit_application_id(application) ∉ mounted_ids
    )
    return CompositeModel(
        (deepcopy(object) for object in model_objects(model))...;
        applications=global_applications,
        instances=Tuple(_model_edit_normalize_instance(instance) for instance in model.instances),
        environment=edit.environment,
        source_adapter=model.source_adapter,
    )
end

function _model_edit_replace_instance(model::CompositeModel, instance_name::Symbol, replacement)
    index, _ = _model_edit_instance(model, instance_name)
    instances = Any[model.instances...]
    instances[index] = replacement
    return _model_edit_rebuild_instances(model, Tuple(instances))
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelInstanceOverride)
    _, instance = _model_edit_instance(model, edit.instance)
    application, spec = _model_edit_template_application_spec(instance, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Instance override for `$(edit.instance)` application `$(application)`",
    )
    overrides = _model_edit_namedtuple_set(instance.overrides, application, edit.model)
    return _model_edit_replace_instance(
        model,
        edit.instance,
        _model_edit_normalize_instance(instance; overrides=overrides),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelInstanceOverride)
    _, instance = _model_edit_instance(model, edit.instance)
    application = _model_edit_template_application_id(instance, edit.application_id)
    haskey(instance.overrides, application) || error(
        "Instance `$(edit.instance)` has no override for application `$(application)`.",
    )
    overrides = _model_edit_namedtuple_remove(instance.overrides, application)
    return _model_edit_replace_instance(
        model,
        edit.instance,
        _model_edit_normalize_instance(instance; overrides=overrides),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelObjectOverride)
    _, instance = _model_edit_instance(model, edit.instance)
    application, spec = _model_edit_template_application_spec(instance, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Object override for `$(edit.object_id.value)` application `$(application)`",
    )
    object_ids = Set(_instance_object_ids(model, instance))
    edit.object_id in object_ids || error(
        "Object `$(edit.object_id.value)` does not belong to instance `$(edit.instance)`.",
    )
    overrides = Override[
        override for override in instance.object_overrides
        if !(override.object == edit.object_id && override.application == application)
    ]
    push!(overrides, Override(object=edit.object_id, application=application, model=edit.model))
    return _model_edit_replace_instance(
        model,
        edit.instance,
        _model_edit_normalize_instance(instance; object_overrides=Tuple(overrides)),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelObjectOverride)
    _, instance = _model_edit_instance(model, edit.instance)
    application = _model_edit_template_application_id(instance, edit.application_id)
    overrides = Override[
        override for override in instance.object_overrides
        if !(override.object == edit.object_id && override.application == application)
    ]
    length(overrides) < length(instance.object_overrides) || error(
        "Instance `$(edit.instance)` has no object override for `$(edit.object_id.value)` and application `$(application)`.",
    )
    return _model_edit_replace_instance(
        model,
        edit.instance,
        _model_edit_normalize_instance(instance; object_overrides=Tuple(overrides)),
    )
end

abstract type AbstractModelGraphEditorSession end

function _model_graph_editor_missing_http()
    throw(ArgumentError(
        "Interactive CompositeModel graph editing requires HTTP.jl. Load it with `using HTTP` before calling `edit_graph`.",
    ))
end

"""
    edit_graph([model]; kwargs...)

Start the HTTP-backed interactive CompositeModel editor. Call `edit_graph()` to begin
with an empty CompositeModel. The implementation is provided by the HTTP package
extension.
"""
edit_graph(args...; kwargs...) = _model_graph_editor_missing_http()

current_model(::AbstractModelGraphEditorSession) = _model_graph_editor_missing_http()
apply_edit!(::AbstractModelGraphEditorSession, ::AbstractModelGraphEdit) =
    _model_graph_editor_missing_http()
undo!(::AbstractModelGraphEditorSession) = _model_graph_editor_missing_http()
redo!(::AbstractModelGraphEditorSession) = _model_graph_editor_missing_http()
