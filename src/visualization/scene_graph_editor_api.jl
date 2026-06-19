abstract type AbstractSceneGraphEdit end

struct AddSceneApplication{S} <: AbstractSceneGraphEdit
    spec::S
end

struct RemoveSceneApplication <: AbstractSceneGraphEdit
    application_id::Symbol
end

struct RemoveSceneTemplateApplication <: AbstractSceneGraphEdit
    instance::Symbol
    application_id::Symbol
end

RemoveSceneTemplateApplication(instance, application_id) =
    RemoveSceneTemplateApplication(Symbol(instance), Symbol(application_id))

struct ReplaceSceneApplicationModel{M<:AbstractModel} <: AbstractSceneGraphEdit
    application_id::Symbol
    model::M
end

struct UpdateSceneApplication{M<:AbstractModel,S,T} <: AbstractSceneGraphEdit
    application_id::Symbol
    model::M
    name::Symbol
    selector::S
    timestep::T
end

struct UpdateSceneTemplateApplication{M<:AbstractModel,S,T} <: AbstractSceneGraphEdit
    instance::Symbol
    application_id::Symbol
    model::M
    selector::S
    timestep::T
end

struct RenameSceneApplication <: AbstractSceneGraphEdit
    application_id::Symbol
    name::Symbol
end

struct SetSceneApplicationTargets{S} <: AbstractSceneGraphEdit
    application_id::Symbol
    selector::S
end

struct SetSceneInputBinding{S} <: AbstractSceneGraphEdit
    application_id::Symbol
    input::Symbol
    selector::S
end

struct RemoveSceneInputBinding <: AbstractSceneGraphEdit
    application_id::Symbol
    input::Symbol
end

struct SetSceneCallBinding{S} <: AbstractSceneGraphEdit
    application_id::Symbol
    call::Symbol
    selector::S
end

struct RemoveSceneCallBinding <: AbstractSceneGraphEdit
    application_id::Symbol
    call::Symbol
end

struct SetSceneApplicationTimeStep{T} <: AbstractSceneGraphEdit
    application_id::Symbol
    timestep::T
end

struct SetSceneApplicationEnvironment{C} <: AbstractSceneGraphEdit
    application_id::Symbol
    configuration::C
end

struct SetSceneOutputRouting <: AbstractSceneGraphEdit
    application_id::Symbol
    output::Symbol
    route::Symbol
end

struct SetSceneUpdateOrdering{U} <: AbstractSceneGraphEdit
    application_id::Symbol
    updates::U
end

struct MarkScenePreviousTimeStep <: AbstractSceneGraphEdit
    application_id::Symbol
    input::Symbol
end

struct UnmarkScenePreviousTimeStep <: AbstractSceneGraphEdit
    application_id::Symbol
    input::Symbol
end

struct BreakSceneCycle{V} <: AbstractSceneGraphEdit
    application_id::Symbol
    input::Symbol
    initialize_missing::Bool
    initial_value::V
end

struct AddSceneObject <: AbstractSceneGraphEdit
    object::Object
end

struct RemoveSceneObject <: AbstractSceneGraphEdit
    object_id::ObjectId
    recursive::Bool
end

RemoveSceneObject(object_id; recursive::Bool=true) =
    RemoveSceneObject(ObjectId(object_id), recursive)

struct ReparentSceneObject <: AbstractSceneGraphEdit
    object_id::ObjectId
    parent_id::Union{Nothing,ObjectId}
end

ReparentSceneObject(object_id, parent_id) = ReparentSceneObject(
    ObjectId(object_id),
    isnothing(parent_id) ? nothing : ObjectId(parent_id),
)

struct SetSceneObjectStatus{V} <: AbstractSceneGraphEdit
    object_id::ObjectId
    variable::Symbol
    value::V
end

SetSceneObjectStatus(object_id, variable, value) =
    SetSceneObjectStatus(ObjectId(object_id), Symbol(variable), value)

struct SetSceneObjectStatuses{V} <: AbstractSceneGraphEdit
    object_ids::Vector{ObjectId}
    variable::Symbol
    value::V
end


SetSceneObjectStatuses(object_ids, variable, value) = SetSceneObjectStatuses(
    ObjectId[ObjectId(object_id) for object_id in object_ids],
    Symbol(variable),
    value,
)

struct RemoveSceneObjectStatus <: AbstractSceneGraphEdit
    object_id::ObjectId
    variable::Symbol
end

RemoveSceneObjectStatus(object_id, variable) =
    RemoveSceneObjectStatus(ObjectId(object_id), Symbol(variable))

struct SetSceneObjectMetadata{C} <: AbstractSceneGraphEdit
    object_id::ObjectId
    configuration::C
end

SetSceneObjectMetadata(object_id; kwargs...) =
    SetSceneObjectMetadata(ObjectId(object_id), (; kwargs...))

struct SetSceneInstanceOverride{M<:AbstractModel} <: AbstractSceneGraphEdit
    instance::Symbol
    application_id::Symbol
    model::M
end

SetSceneInstanceOverride(instance, application_id, model::AbstractModel) =
    SetSceneInstanceOverride(Symbol(instance), Symbol(application_id), model)

struct RemoveSceneInstanceOverride <: AbstractSceneGraphEdit
    instance::Symbol
    application_id::Symbol
end

RemoveSceneInstanceOverride(instance, application_id) =
    RemoveSceneInstanceOverride(Symbol(instance), Symbol(application_id))

struct SetSceneObjectOverride{M<:AbstractModel} <: AbstractSceneGraphEdit
    instance::Symbol
    object_id::ObjectId
    application_id::Symbol
    model::M
end

SetSceneObjectOverride(instance, object_id, application_id, model::AbstractModel) =
    SetSceneObjectOverride(Symbol(instance), ObjectId(object_id), Symbol(application_id), model)

struct RemoveSceneObjectOverride <: AbstractSceneGraphEdit
    instance::Symbol
    object_id::ObjectId
    application_id::Symbol
end

RemoveSceneObjectOverride(instance, object_id, application_id) =
    RemoveSceneObjectOverride(Symbol(instance), ObjectId(object_id), Symbol(application_id))

"""
    apply_scene_graph_edit(scene, edit)

Apply one declarative graph edit transactionally. The input scene is not
modified; a deep-copied, cache-invalidated Scene is returned. Configuration
that is temporarily incomplete or cyclic is retained so the editor can display
and repair it. Structural edit errors leave the original scene unchanged.
"""
function apply_scene_graph_edit(scene::Scene, edit::AbstractSceneGraphEdit)
    candidate = deepcopy(scene)
    candidate = _apply_scene_graph_edit!(candidate, edit)
    _mark_bindings_dirty!(candidate)
    return candidate
end

function _scene_edit_application_id(spec)
    normalized = as_model_spec(spec)
    name = application_name(normalized)
    return isnothing(name) ? process(normalized) : name
end

function _scene_edit_application_index(scene::Scene, application_id::Symbol)
    matches = Int[
        index for (index, spec) in pairs(scene.applications)
        if _scene_edit_application_id(spec) == application_id
    ]
    isempty(matches) && error("Scene has no application `$(application_id)`.")
    length(matches) == 1 || error(
        "Scene application id `$(application_id)` is ambiguous. Name repeated applications explicitly.",
    )
    return only(matches)
end

function _scene_edit_spec(scene::Scene, application_id::Symbol)
    return as_model_spec(scene.applications[_scene_edit_application_index(scene, application_id)])
end

function _replace_scene_edit_spec!(scene::Scene, application_id::Symbol, spec)
    index = _scene_edit_application_index(scene, application_id)
    scene.applications[index] = spec
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::AddSceneApplication)
    spec = as_model_spec(edit.spec)
    application_id = _scene_edit_application_id(spec)
    any(item -> _scene_edit_application_id(item) == application_id, scene.applications) && error(
        "Scene application `$(application_id)` already exists.",
    )
    push!(scene.applications, spec)
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneApplication)
    deleteat!(scene.applications, _scene_edit_application_index(scene, edit.application_id))
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneTemplateApplication)
    _, selected_instance = _scene_edit_instance(scene, edit.instance)
    base_name = _scene_edit_template_application_id(selected_instance, edit.application_id)
    template = selected_instance.template
    template_specs = Any[as_model_spec(item) for item in template.applications]
    indexes = Int[
        index for (index, spec) in pairs(template_specs)
        if _mounted_application_name(spec, index) == base_name
    ]
    index = only(indexes)
    deleteat!(template_specs, index)
    replacement_template = ObjectTemplate(
        Tuple(template_specs);
        kind=template.kind,
        species=template.species,
        parameters=template.parameters,
    )
    instances = Any[]
    for instance in scene.instances
        if instance.template === template
            overrides = _scene_edit_namedtuple_remove(instance.overrides, base_name)
            object_overrides = Tuple(
                override for override in instance.object_overrides
                if override.application != base_name
            )
            push!(instances, _scene_edit_normalize_instance(
                instance;
                template=replacement_template,
                overrides=overrides,
                object_overrides=object_overrides,
            ))
        else
            push!(instances, _scene_edit_normalize_instance(instance))
        end
    end
    return _scene_edit_rebuild_instances(scene, Tuple(instances))
end

function _apply_scene_graph_edit!(scene::Scene, edit::ReplaceSceneApplicationModel)
    spec = _scene_edit_spec(scene, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Replacement model for application `$(edit.application_id)`",
    )
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; model=edit.model),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::UpdateSceneApplication)
    spec = _scene_edit_spec(scene, edit.application_id)
    _validate_model_override_contract!(
        model_(spec),
        edit.model;
        description="Updated model for application `$(edit.application_id)`",
    )
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    if edit.name != edit.application_id
        any(item -> _scene_edit_application_id(item) == edit.name, scene.applications) && error(
            "Scene application `$(edit.name)` already exists.",
        )
    end
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(
            spec;
            model=edit.model,
            name=edit.name,
            applies_to=edit.selector,
            timestep=edit.timestep,
        ),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::RenameSceneApplication)
    any(item -> _scene_edit_application_id(item) == edit.name, scene.applications) && error(
        "Scene application `$(edit.name)` already exists.",
    )
    spec = _scene_edit_spec(scene, edit.application_id)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; name=edit.name),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneApplicationTargets)
    edit.selector isa AbstractObjectMultiplicity || error(
        "Application targets must use One(...), OptionalOne(...), or Many(...).",
    )
    spec = _scene_edit_spec(scene, edit.application_id)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; applies_to=edit.selector),
    )
end

function _scene_edit_namedtuple_set(values::NamedTuple, name::Symbol, value)
    pairs_ = Pair{Symbol,Any}[
        Symbol(key) => (Symbol(key) == name ? value : item)
        for (key, item) in pairs(values)
    ]
    name in Symbol.(keys(values)) || push!(pairs_, name => value)
    return (; pairs_...)
end

function _scene_edit_namedtuple_remove(values::NamedTuple, name::Symbol)
    return (; (
        Symbol(key) => item
        for (key, item) in pairs(values)
        if Symbol(key) != name
    )...)
end

function _scene_edit_origins_set(origins::NamedTuple, name::Symbol, origin::Symbol)
    return _scene_edit_namedtuple_set(origins, name, origin)
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneInputBinding)
    edit.selector isa AbstractObjectMultiplicity || error("An input binding requires an object selector.")
    spec = _scene_edit_spec(scene, edit.application_id)
    edit.input in Symbol.(keys(inputs_(spec))) || error(
        "Application `$(edit.application_id)` model has no input `$(edit.input)`.",
    )
    inputs = _scene_edit_namedtuple_set(spec.inputs, edit.input, edit.selector)
    origins = _scene_edit_origins_set(spec.input_origins, edit.input, :model_spec)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneInputBinding)
    spec = _scene_edit_spec(scene, edit.application_id)
    inputs = _scene_edit_namedtuple_remove(spec.inputs, edit.input)
    origins = _scene_edit_namedtuple_remove(spec.input_origins, edit.input)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; inputs=inputs, input_origins=origins),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneCallBinding)
    edit.selector isa AbstractObjectMultiplicity || error("A call binding requires an object selector.")
    spec = _scene_edit_spec(scene, edit.application_id)
    calls = _scene_edit_namedtuple_set(spec.calls, edit.call, edit.selector)
    origins = _scene_edit_origins_set(spec.call_origins, edit.call, :model_spec)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneCallBinding)
    spec = _scene_edit_spec(scene, edit.application_id)
    calls = _scene_edit_namedtuple_remove(spec.calls, edit.call)
    origins = _scene_edit_namedtuple_remove(spec.call_origins, edit.call)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; calls=calls, call_origins=origins),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneApplicationTimeStep)
    spec = _scene_edit_spec(scene, edit.application_id)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; timestep=edit.timestep),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneApplicationEnvironment)
    spec = _scene_edit_spec(scene, edit.application_id)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; environment=edit.configuration),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneOutputRouting)
    edit.route in (:canonical, :stream_only) || error(
        "Output route must be `:canonical` or `:stream_only`.",
    )
    spec = _scene_edit_spec(scene, edit.application_id)
    edit.output in Symbol.(keys(outputs_(spec))) || error(
        "Application `$(edit.application_id)` model has no output `$(edit.output)`.",
    )
    routing = _scene_edit_namedtuple_set(spec.output_routing, edit.output, edit.route)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; output_routing=routing),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneUpdateOrdering)
    spec = _scene_edit_spec(scene, edit.application_id)
    return _replace_scene_edit_spec!(
        scene,
        edit.application_id,
        ModelSpec(spec; updates=edit.updates),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::MarkScenePreviousTimeStep)
    spec = _scene_edit_spec(scene, edit.application_id)
    selector = if haskey(spec.inputs, edit.input)
        getproperty(spec.inputs, edit.input)
    else
        report = compile_scene_report(scene)
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
    return _apply_scene_graph_edit!(
        scene,
        SetSceneInputBinding(edit.application_id, edit.input, previous_selector),
    )
end

function _scene_selector_without_previous_timestep(selector::AbstractObjectMultiplicity)
    values = (; (
        Symbol(key) => value
        for (key, value) in pairs(criteria(selector))
        if Symbol(key) != :policy
    )...)
    return _rebuild_selector(selector, values)
end

function _apply_scene_graph_edit!(scene::Scene, edit::UnmarkScenePreviousTimeStep)
    spec = _scene_edit_spec(scene, edit.application_id)
    haskey(spec.inputs, edit.input) || error(
        "Application `$(edit.application_id)` has no input binding `$(edit.input)`.",
    )
    selector = getproperty(spec.inputs, edit.input)
    _selector_policy(selector) isa PreviousTimeStep || error(
        "Input `$(edit.input)` on application `$(edit.application_id)` is not marked PreviousTimeStep.",
    )
    return _apply_scene_graph_edit!(
        scene,
        SetSceneInputBinding(
            edit.application_id,
            edit.input,
            _scene_selector_without_previous_timestep(selector),
        ),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::BreakSceneCycle)
    _apply_scene_graph_edit!(
        scene,
        MarkScenePreviousTimeStep(edit.application_id, edit.input),
    )
    edit.initialize_missing || return scene
    report = compile_scene_report(scene)
    applications = [
        application for application in report.applications
        if application.id == edit.application_id
    ]
    isempty(applications) && error(
        "Application `$(edit.application_id)` could not be resolved after breaking its cycle.",
    )
    application = only(applications)
    for object_id in application.target_ids
        object = _scene_object(scene, object_id)
        supplied = object.status isa Status && edit.input in Symbol.(propertynames(object.status))
        supplied || _set_scene_object_status!(scene, object_id, edit.input, edit.initial_value)
    end
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::AddSceneObject)
    register_object!(scene, edit.object)
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneObject)
    remove_object!(scene, edit.object_id; recursive=edit.recursive)
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::ReparentSceneObject)
    reparent_object!(scene, edit.object_id, edit.parent_id)
    return scene
end

function _scene_edit_status_values(status)
    status isa Status || return Pair{Symbol,Any}[]
    return Pair{Symbol,Any}[
        Symbol(name) => status[name]
        for name in propertynames(status)
    ]
end

function _set_scene_object_status!(scene, object_id, variable, value)
    object = _scene_object(scene, object_id)
    values = _scene_edit_status_values(object.status)
    index = findfirst(pair -> first(pair) == variable, values)
    if isnothing(index)
        push!(values, variable => value)
    else
        values[index] = variable => value
    end
    object.status = Status((; values...))
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneObjectStatus)
    return _set_scene_object_status!(scene, edit.object_id, edit.variable, edit.value)
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneObjectStatuses)
    isempty(edit.object_ids) && error("SetSceneObjectStatuses requires at least one object id.")
    for object_id in edit.object_ids
        _set_scene_object_status!(scene, object_id, edit.variable, edit.value)
    end
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneObjectStatus)
    object = _scene_object(scene, edit.object_id)
    values = Pair{Symbol,Any}[
        pair for pair in _scene_edit_status_values(object.status)
        if first(pair) != edit.variable
    ]
    object.status = isempty(values) ? nothing : Status((; values...))
    return scene
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneObjectMetadata)
    object = _scene_object(scene, edit.object_id)
    allowed = Set((:scale, :kind, :species, :name, :geometry, :parent))
    unknown = setdiff(Set(Symbol.(keys(edit.configuration))), allowed)
    isempty(unknown) || error("Unsupported object metadata fields: $(sort!(collect(unknown); by=string)).")
    _deindex_object!(scene.registry, object)
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
    _index_object!(scene.registry, object)
    haskey(edit.configuration, :parent) && reparent_object!(scene, object.id, edit.configuration.parent)
    _mark_environment_bindings_dirty!(scene, object.id)
    return scene
end

function _scene_edit_instance(scene::Scene, name::Symbol)
    matches = findall(instance -> instance.name == name, scene.instances)
    isempty(matches) && error("Scene has no object instance `$(name)`.")
    length(matches) == 1 || error("Scene object instance name `$(name)` is ambiguous.")
    return only(matches), scene.instances[only(matches)]
end

function _scene_edit_template_application_id(instance::ObjectInstance, application_id::Symbol)
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

function _scene_edit_normalize_instance(
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

function _scene_edit_rebuild_instances(
    scene::Scene,
    instances;
    replace_mounted_ids=Set{Symbol}(),
)
    instances = Tuple(_scene_edit_normalize_instance(instance) for instance in instances)
    mounted_ids = Set{Symbol}()
    for instance in scene.instances
        union!(mounted_ids, _instance_application_ids(scene, instance))
    end
    global_applications = Any[
        application for application in scene.applications
        if _scene_edit_application_id(application) ∉ mounted_ids
    ]
    old_mounted = Dict(
        _scene_edit_application_id(application) => as_model_spec(application)
        for application in scene.applications
        if _scene_edit_application_id(application) in mounted_ids
    )
    rebuilt = Scene(
        (deepcopy(object) for object in scene_objects(scene))...;
        applications=global_applications,
        instances=instances,
        environment=scene.environment,
        source_adapter=scene.source_adapter,
    )
    for (index, application) in pairs(rebuilt.applications)
        application_id = _scene_edit_application_id(application)
        haskey(old_mounted, application_id) || continue
        application_id in replace_mounted_ids && continue
        old_spec = old_mounted[application_id]
        new_spec = as_model_spec(application)
        rebuilt.applications[index] = ModelSpec(old_spec; model=model_(new_spec))
    end
    return rebuilt
end


function _apply_scene_graph_edit!(scene::Scene, edit::UpdateSceneTemplateApplication)
    _, selected_instance = _scene_edit_instance(scene, edit.instance)
    base_name = _scene_edit_template_application_id(selected_instance, edit.application_id)
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
    template_specs[index] = ModelSpec(
        original;
        model=edit.model,
        applies_to=edit.selector,
        timestep=edit.timestep,
    )
    replacement_template = ObjectTemplate(
        Tuple(template_specs);
        kind=template.kind,
        species=template.species,
        parameters=template.parameters,
    )
    affected = Set{Symbol}()
    instances = Any[]
    for instance in scene.instances
        if instance.template === template
            push!(affected, Symbol(instance.name, "__", base_name))
            push!(instances, _scene_edit_normalize_instance(instance; template=replacement_template))
        else
            push!(instances, _scene_edit_normalize_instance(instance))
        end
    end
    return _scene_edit_rebuild_instances(
        scene,
        Tuple(instances);
        replace_mounted_ids=affected,
    )
end

function _scene_edit_replace_instance(scene::Scene, instance_name::Symbol, replacement)
    index, _ = _scene_edit_instance(scene, instance_name)
    instances = Any[scene.instances...]
    instances[index] = replacement
    return _scene_edit_rebuild_instances(scene, Tuple(instances))
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneInstanceOverride)
    _, instance = _scene_edit_instance(scene, edit.instance)
    application = _scene_edit_template_application_id(instance, edit.application_id)
    overrides = _scene_edit_namedtuple_set(instance.overrides, application, edit.model)
    return _scene_edit_replace_instance(
        scene,
        edit.instance,
        _scene_edit_normalize_instance(instance; overrides=overrides),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneInstanceOverride)
    _, instance = _scene_edit_instance(scene, edit.instance)
    application = _scene_edit_template_application_id(instance, edit.application_id)
    haskey(instance.overrides, application) || error(
        "Instance `$(edit.instance)` has no override for application `$(application)`.",
    )
    overrides = _scene_edit_namedtuple_remove(instance.overrides, application)
    return _scene_edit_replace_instance(
        scene,
        edit.instance,
        _scene_edit_normalize_instance(instance; overrides=overrides),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::SetSceneObjectOverride)
    _, instance = _scene_edit_instance(scene, edit.instance)
    application = _scene_edit_template_application_id(instance, edit.application_id)
    object_ids = Set(_instance_object_ids(scene, instance))
    edit.object_id in object_ids || error(
        "Object `$(edit.object_id.value)` does not belong to instance `$(edit.instance)`.",
    )
    overrides = Override[
        override for override in instance.object_overrides
        if !(override.object == edit.object_id && override.application == application)
    ]
    push!(overrides, Override(object=edit.object_id, application=application, model=edit.model))
    return _scene_edit_replace_instance(
        scene,
        edit.instance,
        _scene_edit_normalize_instance(instance; object_overrides=Tuple(overrides)),
    )
end

function _apply_scene_graph_edit!(scene::Scene, edit::RemoveSceneObjectOverride)
    _, instance = _scene_edit_instance(scene, edit.instance)
    application = _scene_edit_template_application_id(instance, edit.application_id)
    overrides = Override[
        override for override in instance.object_overrides
        if !(override.object == edit.object_id && override.application == application)
    ]
    length(overrides) < length(instance.object_overrides) || error(
        "Instance `$(edit.instance)` has no object override for `$(edit.object_id.value)` and application `$(application)`.",
    )
    return _scene_edit_replace_instance(
        scene,
        edit.instance,
        _scene_edit_normalize_instance(instance; object_overrides=Tuple(overrides)),
    )
end

abstract type AbstractSceneGraphEditorSession end

function _scene_graph_editor_missing_http()
    throw(ArgumentError(
        "Interactive Scene graph editing requires HTTP.jl. Load it with `using HTTP` before calling `edit_graph`.",
    ))
end

"""
    edit_graph([scene]; kwargs...)

Start the HTTP-backed interactive Scene editor. Call `edit_graph()` to begin
with an empty Scene. The implementation is provided by the HTTP package
extension.
"""
edit_graph(args...; kwargs...) = _scene_graph_editor_missing_http()

current_scene(::AbstractSceneGraphEditorSession) = _scene_graph_editor_missing_http()
apply_edit!(::AbstractSceneGraphEditorSession, ::AbstractSceneGraphEdit) =
    _scene_graph_editor_missing_http()
undo!(::AbstractSceneGraphEditorSession) = _scene_graph_editor_missing_http()
redo!(::AbstractSceneGraphEditorSession) = _scene_graph_editor_missing_http()
