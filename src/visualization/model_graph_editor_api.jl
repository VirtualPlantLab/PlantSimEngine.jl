abstract type AbstractModelGraphEdit end

struct AddModelApplication{S} <: AbstractModelGraphEdit
    spec::S
end

struct RemoveModelApplication <: AbstractModelGraphEdit
    application_id::Symbol
end

struct RemoveModelTemplateApplication <: AbstractModelGraphEdit
    instance::Symbol
    application_id::Symbol
end

RemoveModelTemplateApplication(
    instance::Union{Symbol,AbstractString},
    application_id::Union{Symbol,AbstractString},
) =
    RemoveModelTemplateApplication(Symbol(instance), Symbol(application_id))

struct ReplaceModelApplicationModel{M<:AbstractModel} <: AbstractModelGraphEdit
    application_id::Symbol
    model::M
end

struct UpdateModelApplication{M<:AbstractModel,S,T} <: AbstractModelGraphEdit
    application_id::Symbol
    model::M
    name::Symbol
    selector::S
    timestep::T
end

struct UpdateModelTemplateApplication{M<:AbstractModel,S,T} <: AbstractModelGraphEdit
    instance::Symbol
    application_id::Symbol
    model::M
    selector::S
    timestep::T
end

struct RenameModelApplication <: AbstractModelGraphEdit
    application_id::Symbol
    name::Symbol
end

struct SetModelApplicationTargets{S} <: AbstractModelGraphEdit
    application_id::Symbol
    selector::S
end

struct SetModelInputBinding{S} <: AbstractModelGraphEdit
    application_id::Symbol
    input::Symbol
    selector::S
end

struct RemoveModelInputBinding <: AbstractModelGraphEdit
    application_id::Symbol
    input::Symbol
end

struct SetModelCallBinding{S} <: AbstractModelGraphEdit
    application_id::Symbol
    call::Symbol
    selector::S
end

struct RemoveModelCallBinding <: AbstractModelGraphEdit
    application_id::Symbol
    call::Symbol
end

struct SetModelApplicationTimeStep{T} <: AbstractModelGraphEdit
    application_id::Symbol
    timestep::T
end

struct SetModelApplicationEnvironment{C} <: AbstractModelGraphEdit
    application_id::Symbol
    configuration::C
end

struct SetModelOutputRouting <: AbstractModelGraphEdit
    application_id::Symbol
    output::Symbol
    route::Symbol
end

struct SetModelUpdateOrdering{U} <: AbstractModelGraphEdit
    application_id::Symbol
    updates::U
end

struct MarkModelPreviousTimeStep <: AbstractModelGraphEdit
    application_id::Symbol
    input::Symbol
end

struct UnmarkModelPreviousTimeStep <: AbstractModelGraphEdit
    application_id::Symbol
    input::Symbol
end

struct BreakModelCycle{V} <: AbstractModelGraphEdit
    application_id::Symbol
    input::Symbol
    initialize_missing::Bool
    initial_value::V
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
    apply_model_graph_edit(model, edit)

Apply one declarative graph edit transactionally. The input model is not
modified; a deep-copied, cache-invalidated CompositeModel is returned. Configuration
that is temporarily incomplete or cyclic is retained so the editor can display
and repair it. Structural edit errors leave the original model unchanged.
"""
function apply_model_graph_edit(model::CompositeModel, edit::AbstractModelGraphEdit)
    candidate = deepcopy(model)
    candidate = _apply_model_graph_edit!(candidate, edit)
    _mark_bindings_dirty!(candidate)
    return candidate
end

function _model_edit_application_id(spec)
    normalized = as_model_spec(spec)
    name = application_name(normalized)
    return isnothing(name) ? process(normalized) : name
end

function _model_edit_application_index(model::CompositeModel, application_id::Symbol)
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

function _model_edit_spec(model::CompositeModel, application_id::Symbol)
    return as_model_spec(model.applications[_model_edit_application_index(model, application_id)])
end

function _replace_model_edit_spec!(model::CompositeModel, application_id::Symbol, spec)
    index = _model_edit_application_index(model, application_id)
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
    deleteat!(model.applications, _model_edit_application_index(model, edit.application_id))
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelTemplateApplication)
    _, selected_instance = _model_edit_instance(model, edit.instance)
    base_name = _model_edit_template_application_id(selected_instance, edit.application_id)
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
    spec = _model_edit_spec(model, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Replacement model for application `$(edit.application_id)`",
    )
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; model=edit.model),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::UpdateModelApplication)
    spec = _model_edit_spec(model, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Updated model for application `$(edit.application_id)`",
    )
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    if edit.name != edit.application_id
        any(item -> _model_edit_application_id(item) == edit.name, model.applications) && error(
            "CompositeModel application `$(edit.name)` already exists.",
        )
    end
    _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(
            spec;
            model=edit.model,
            name=edit.name,
            on=edit.selector,
            every=edit.timestep,
        ),
    )
    edit.name == edit.application_id || _rewrite_model_application_references!(
        model,
        edit.application_id,
        edit.name,
    )
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RenameModelApplication)
    any(item -> _model_edit_application_id(item) == edit.name, model.applications) && error(
        "CompositeModel application `$(edit.name)` already exists.",
    )
    spec = _model_edit_spec(model, edit.application_id)
    _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; name=edit.name),
    )
    _rewrite_model_application_references!(model, edit.application_id, edit.name)
    return model
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

function _rewrite_model_application_references!(model::CompositeModel, old_id::Symbol, new_id::Symbol)
    for (index, raw_spec) in pairs(model.applications)
        spec = as_model_spec(raw_spec)
        inputs = (; (
            Symbol(name) => _rewrite_model_selector_application(selector, old_id, new_id)
            for (name, selector) in pairs(spec.inputs)
        )...)
        calls = (; (
            Symbol(name) => _rewrite_model_selector_application(selector, old_id, new_id)
            for (name, selector) in pairs(spec.calls)
        )...)
        target = _rewrite_model_selector_application(spec.applies_to, old_id, new_id)
        updates_ = Tuple(
            Updates(
                _update_variables(update)...;
                after=Tuple(item == old_id ? new_id : item for item in _update_after(update)),
            )
            for update in spec.updates
        )
        model.applications[index] = _replace_model_spec(
            spec;
            inputs=inputs,
            calls=calls,
            on=target,
            updates=updates_,
        )
    end
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationTargets)
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    spec = _model_edit_spec(model, edit.application_id)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
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
    spec = _model_edit_spec(model, edit.application_id)
    edit.input in Symbol.(keys(_input_schema(spec))) || error(
        "Application `$(edit.application_id)` model has no input `$(edit.input)`.",
    )
    inputs = _model_edit_namedtuple_set(spec.inputs, edit.input, edit.selector)
    origins = _model_edit_origins_set(spec.input_origins, edit.input, :model_spec)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelInputBinding)
    spec = _model_edit_spec(model, edit.application_id)
    inputs = _model_edit_namedtuple_remove(spec.inputs, edit.input)
    origins = _model_edit_namedtuple_remove(spec.input_origins, edit.input)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelCallBinding)
    edit.selector isa AbstractObjectMultiplicity || error("A call binding requires an object selector.")
    spec = _model_edit_spec(model, edit.application_id)
    calls = _model_edit_namedtuple_set(spec.calls, edit.call, edit.selector)
    origins = _model_edit_origins_set(spec.call_origins, edit.call, :model_spec)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelCallBinding)
    spec = _model_edit_spec(model, edit.application_id)
    calls = _model_edit_namedtuple_remove(spec.calls, edit.call)
    origins = _model_edit_namedtuple_remove(spec.call_origins, edit.call)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationTimeStep)
    spec = _model_edit_spec(model, edit.application_id)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; every=edit.timestep),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelApplicationEnvironment)
    spec = _model_edit_spec(model, edit.application_id)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; environment=Environment(edit.configuration)),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelOutputRouting)
    edit.route in (:canonical, :stream_only) || error(
        "Output route must be `:canonical` or `:stream_only`.",
    )
    spec = _model_edit_spec(model, edit.application_id)
    edit.output in Symbol.(keys(outputs_(spec))) || error(
        "Application `$(edit.application_id)` model has no output `$(edit.output)`.",
    )
    routing = _model_edit_namedtuple_set(spec.output_routing, edit.output, edit.route)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; output_routing=routing),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::SetModelUpdateOrdering)
    spec = _model_edit_spec(model, edit.application_id)
    return _replace_model_edit_spec!(
        model,
        edit.application_id,
        _replace_model_spec(spec; updates=edit.updates),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::MarkModelPreviousTimeStep)
    spec = _model_edit_spec(model, edit.application_id)
    selector = if haskey(spec.inputs, edit.input)
        getproperty(spec.inputs, edit.input)
    else
        report = compile_model_report(model)
        selectors = Any[
            binding.selector for binding in report.input_bindings
            if binding.application_id == edit.application_id && binding.input == edit.input
        ]
        isempty(selectors) && error(
            "Application `$(edit.application_id)` has no resolved selector for input `$(edit.input)`. Add an input binding first.",
        )
        first(selectors)
    end
    selector isa AbstractObjectMultiplicity || error(
        "Input `$(edit.input)` on application `$(edit.application_id)` does not use an object selector.",
    )
    previous_selector = _selector_with_previous_timestep(
        selector,
        PreviousTimeStep(edit.input),
    )
    return _apply_model_graph_edit!(
        model,
        SetModelInputBinding(edit.application_id, edit.input, previous_selector),
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
    spec = _model_edit_spec(model, edit.application_id)
    haskey(spec.inputs, edit.input) || error(
        "Application `$(edit.application_id)` has no input binding `$(edit.input)`.",
    )
    selector = getproperty(spec.inputs, edit.input)
    _selector_policy(selector) isa PreviousTimeStep || error(
        "Input `$(edit.input)` on application `$(edit.application_id)` is not marked PreviousTimeStep.",
    )
    return _apply_model_graph_edit!(
        model,
        SetModelInputBinding(
            edit.application_id,
            edit.input,
            _model_selector_without_previous_timestep(selector),
        ),
    )
end

function _apply_model_graph_edit!(model::CompositeModel, edit::BreakModelCycle)
    _apply_model_graph_edit!(
        model,
        MarkModelPreviousTimeStep(edit.application_id, edit.input),
    )
    edit.initialize_missing || return model
    report = compile_model_report(model)
    applications = [
        application for application in report.applications
        if application.id == edit.application_id
    ]
    isempty(applications) && error(
        "Application `$(edit.application_id)` could not be resolved after breaking its cycle.",
    )
    application = only(applications)
    for object_id in application.target_ids
        object = _model_object(model, object_id)
        supplied = object.status isa Status && edit.input in Symbol.(propertynames(object.status))
        supplied || _set_model_object_status!(model, object_id, edit.input, edit.initial_value)
    end
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::AddModelObject)
    register_object!(model, edit.object)
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::RemoveModelObject)
    remove_object!(model, edit.object_id; recursive=edit.recursive)
    return model
end

function _apply_model_graph_edit!(model::CompositeModel, edit::ReparentModelObject)
    reparent_object!(model, edit.object_id, edit.parent_id)
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
    haskey(edit.configuration, :parent) && reparent_object!(model, object.id, edit.configuration.parent)
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


function _apply_model_graph_edit!(model::CompositeModel, edit::UpdateModelTemplateApplication)
    _, selected_instance = _model_edit_instance(model, edit.instance)
    base_name = _model_edit_template_application_id(selected_instance, edit.application_id)
    template = selected_instance.template
    template_specs = Any[as_model_spec(item) for item in template.applications]
    matches = Int[
        index for (index, spec) in pairs(template_specs)
        if _mounted_application_name(spec, index) == base_name
    ]
    isempty(matches) && error("Template application `$(base_name)` was not found.")
    index = only(matches)
    original = template_specs[index]
    _validate_model_override_contract!(
        model_(original),
        edit.model;
        description="Updated shared template application `$(base_name)`",
    )
    edit.selector isa AbstractObjectMultiplicity || error(
        "Template application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    template_specs[index] = _replace_model_spec(
        original;
        model=edit.model,
        on=edit.selector,
        every=edit.timestep,
    )
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
