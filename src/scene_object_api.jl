abstract type AbstractObjectSelector end
abstract type AbstractObjectMultiplicity end

struct ObjectRefVector{R} <: AbstractVector{Any}
    refs::R
end

Base.size(v::ObjectRefVector) = size(v.refs)
Base.length(v::ObjectRefVector) = length(v.refs)
Base.getindex(v::ObjectRefVector, i::Int) = v.refs[i][]
Base.setindex!(v::ObjectRefVector, value, i::Int) = (v.refs[i][] = value)
Base.parent(v::ObjectRefVector) = v.refs

struct ObjectId{T}
    value::T
end
ObjectId(id::ObjectId) = id
ObjectId(id::AbstractString) = ObjectId(Symbol(id))

mutable struct Object
    id::ObjectId
    scale::Union{Nothing,Symbol}
    kind::Union{Nothing,Symbol}
    species::Union{Nothing,Symbol}
    name::Union{Nothing,Symbol}
    parent::Union{Nothing,ObjectId}
    children::Vector{ObjectId}
    geometry::Any
    status::Any
    applications::Any
end

"""
    ObjectTemplate(applications=(); kind=nothing, species=nothing, mapping=applications, parameters=NamedTuple())

Reusable model-application bundle for one kind of scene object, such as a plant
species. Each mounted `ObjectInstance` scopes unqualified `AppliesTo(...)`
selectors to its own object subtree. Model objects are shared between instances
unless an instance supplies an override.

`parameters` stores template-level metadata. Parameter-field merging is not
implicit: use an instance model override when model parameters differ.
"""
struct ObjectTemplate{A,P}
    kind::Union{Nothing,Symbol}
    species::Union{Nothing,Symbol}
    applications::A
    parameters::P
end

_as_tuple(value::Tuple) = value
_as_tuple(value::AbstractVector) = Tuple(value)
_as_tuple(value) = (value,)

function ObjectTemplate(
    applications=();
    kind=nothing,
    species=nothing,
    mapping=applications,
    parameters=NamedTuple(),
)
    normalized_applications = _as_tuple(mapping)
    return ObjectTemplate(
        _maybe_symbol(kind),
        _maybe_symbol(species),
        normalized_applications,
        parameters,
    )
end

"""
    Override(; object, model, process=nothing, application=nothing)

Replace one template model application on one exceptional object. Select the
template application by its process, explicit application name, or both.
The replacement must implement the same process and variable contract.
"""
struct Override{M<:AbstractModel}
    object::ObjectId
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    model::M
end

function Override(; object, model::AbstractModel, process=nothing, application=nothing)
    normalized_process = _maybe_symbol(process)
    normalized_application = _maybe_symbol(application)
    if isnothing(normalized_process) && isnothing(normalized_application)
        error("`Override(...)` requires `process=...`, `application=...`, or both.")
    end
    return Override(
        ObjectId(object),
        normalized_process,
        normalized_application,
        model,
    )
end

"""
    ObjectInstance(name, template; root, objects=(), overrides=NamedTuple(), object_overrides=())

Mount an `ObjectTemplate` on one concrete scene-object subtree.

`root` may be an `Object` owned by the instance or the id of an object supplied
separately to `Scene`. `objects` contains additional owned descendants.
`overrides` maps one template application name or process to a replacement
model implementing the same process. `object_overrides` contains `Override`
entries for exceptional organs.
"""
struct ObjectInstance{T,R,O,OV,OOV}
    name::Symbol
    template::T
    root::R
    objects::O
    overrides::OV
    object_overrides::OOV
end

function ObjectInstance(
    name,
    template::ObjectTemplate;
    root,
    objects=(),
    overrides=NamedTuple(),
    object_overrides=(),
)
    normalized_objects = _as_tuple(objects)
    normalized_object_overrides = _as_tuple(object_overrides)
    all(object -> object isa Object, normalized_objects) || error(
        "`ObjectInstance(...; objects=...)` must contain `Object` values."
    )
    overrides isa NamedTuple || error(
        "`ObjectInstance(...; overrides=...)` must be a NamedTuple keyed by application name or process."
    )
    all(override -> override isa Override, normalized_object_overrides) || error(
        "`ObjectInstance(...; object_overrides=...)` must contain `Override` values."
    )
    return ObjectInstance(
        Symbol(name),
        template,
        root,
        normalized_objects,
        overrides,
        normalized_object_overrides,
    )
end

struct ObjectModelOverrides{M,O} <: AbstractModel
    base::M
    overrides::O
end

process(model::ObjectModelOverrides) = process(model.base)
inputs_(model::ObjectModelOverrides) = inputs_(model.base)
outputs_(model::ObjectModelOverrides) = outputs_(model.base)
dep(model::ObjectModelOverrides, nsteps=1) = dep(model.base, nsteps)
timespec(model::ObjectModelOverrides) = timespec(model.base)
output_policy(model::ObjectModelOverrides) = output_policy(model.base)
meteo_inputs_(model::ObjectModelOverrides) = meteo_inputs_(model.base)
meteo_outputs_(model::ObjectModelOverrides) = meteo_outputs_(model.base)

function Object(
    id;
    scale=nothing,
    kind=nothing,
    species=nothing,
    name=nothing,
    parent=nothing,
    children=ObjectId[],
    geometry=nothing,
    status=nothing,
    applications=(),
)
    return Object(
        ObjectId(id),
        _maybe_symbol(scale),
        _maybe_symbol(kind),
        _maybe_symbol(species),
        _maybe_symbol(name),
        isnothing(parent) ? nothing : ObjectId(parent),
        ObjectId[ObjectId(child) for child in children],
        geometry,
        status,
        applications,
    )
end

mutable struct SceneRegistry
    objects::Dict{ObjectId,Any}
    by_scale::Dict{Symbol,Set{ObjectId}}
    by_kind::Dict{Symbol,Set{ObjectId}}
    by_species::Dict{Symbol,Set{ObjectId}}
    by_name::Dict{Symbol,ObjectId}
end

SceneRegistry() = SceneRegistry(
    Dict{ObjectId,Any}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,ObjectId}(),
)

mutable struct Scene{R,A,E,I}
    registry::R
    applications::A
    environment::E
    instances::I
    binding_cache::Any
    environment_binding_cache::Any
    bindings_dirty::Bool
    environment_bindings_dirty::Bool
    environment_dirty_objects::Union{Nothing,Set{ObjectId}}
    revision::Int
    environment_revision::Int
end

function _normalize_object_instances(instances)
    instances isa ObjectInstance && return (instances,)
    normalized = _as_tuple(instances)
    all(instance -> instance isa ObjectInstance, normalized) || error(
        "Scene instances must be `ObjectInstance` values."
    )
    return normalized
end

function _instance_root_id(instance::ObjectInstance)
    return instance.root isa Object ? instance.root.id : ObjectId(instance.root)
end

function _collect_scene_items(items, instances)
    objects = Object[]
    mounted_instances = ObjectInstance[]
    for item in items
        if item isa Object
            push!(objects, item)
        elseif item isa ObjectInstance
            push!(mounted_instances, item)
        else
            error("A `Scene` can contain only `Object` and `ObjectInstance` values, got `$(typeof(item))`.")
        end
    end
    append!(mounted_instances, _normalize_object_instances(instances))
    for instance in mounted_instances
        instance.root isa Object && push!(objects, instance.root)
        append!(objects, instance.objects)
    end
    ids = Set{ObjectId}()
    for object in objects
        object.id in ids && error("Scene contains object id `$(object.id.value)` more than once.")
        push!(ids, object.id)
    end
    return objects, mounted_instances
end

function _object_descendant_ids(objects_by_id, root_id::ObjectId)
    ids = ObjectId[root_id]
    frontier = ObjectId[root_id]
    while !isempty(frontier)
        parent_id = popfirst!(frontier)
        for object in values(objects_by_id)
            object.parent == parent_id || continue
            object.id in ids && continue
            push!(ids, object.id)
            push!(frontier, object.id)
        end
    end
    return ids
end

function _prepare_object_instances!(objects, instances)
    objects_by_id = Dict(object.id => object for object in objects)
    claimed_ids = Dict{ObjectId,Symbol}()
    instance_ids = Dict{Symbol,Vector{ObjectId}}()
    for instance in instances
        root_id = _instance_root_id(instance)
        haskey(objects_by_id, root_id) || error(
            "Object instance `$(instance.name)` refers to missing root object `$(root_id.value)`."
        )
        ids = _object_descendant_ids(objects_by_id, root_id)
        for id in ids
            if haskey(claimed_ids, id)
                error(
                    "Object `$(id.value)` belongs to both instances `$(claimed_ids[id])` and `$(instance.name)`."
                )
            end
            claimed_ids[id] = instance.name
            object = objects_by_id[id]
            isnothing(object.kind) && (object.kind = instance.template.kind)
            isnothing(object.species) && (object.species = instance.template.species)
        end
        root = objects_by_id[root_id]
        if !isnothing(root.name) && root.name != instance.name
            error(
                "Object instance `$(instance.name)` root `$(root_id.value)` already has the conflicting name `$(root.name)`."
            )
        end
        root.name = instance.name
        instance_ids[instance.name] = ids
    end
    length(instance_ids) == length(instances) || error("Object instance names must be unique within a scene.")
    return instance_ids
end

function _register_scene_objects!(scene::Scene, objects)
    pending = copy(objects)
    while !isempty(pending)
        registered = false
        for index in reverse(eachindex(pending))
            object = pending[index]
            if isnothing(object.parent) || haskey(scene.registry.objects, object.parent)
                register_object!(scene, object)
                deleteat!(pending, index)
                registered = true
            end
        end
        registered && continue
        unresolved = [(object.id.value, isnothing(object.parent) ? nothing : object.parent.value) for object in pending]
        error("Cannot register scene objects because parent objects are missing or cyclic: $(unresolved).")
    end
    return scene
end

"""
    Scene(items...; applications=(), instances=(), environment=nothing)

Create a scene from `Object` and `ObjectInstance` values. Global applications
and applications mounted from object instances are compiled through the same
scene/object dependency graph.
"""
function Scene(
    items::Union{Object,ObjectInstance}...;
    applications=(),
    instances=(),
    environment=nothing,
)
    objects, mounted_instances = _collect_scene_items(items, instances)
    instance_ids = _prepare_object_instances!(objects, mounted_instances)
    mounted_applications = _mount_object_instance_applications(mounted_instances, instance_ids)
    normalized_applications = _as_tuple(applications)
    all_applications = (normalized_applications..., mounted_applications...)
    scene = Scene(
        SceneRegistry(),
        all_applications,
        environment,
        mounted_instances,
        nothing,
        nothing,
        true,
        true,
        nothing,
        0,
        0,
    )
    return _register_scene_objects!(scene, objects)
end

function _mtg_attribute(node, key::Symbol, default=nothing)
    try
        return node[key]
    catch
        return default
    end
end

"""
    objects_from_mtg(root; id=node_id, scale=symbol, kind=..., species=...,
                     name=..., geometry=..., status=...)

Adapt one MTG subtree to scene `Object` values. The MTG is traversed once;
node ids and parent relations become stable scene-object identities and
relations. Accessors may attach labels, geometry, and existing status objects
without prescribing a plant architecture.
"""
function objects_from_mtg(
    root::MultiScaleTreeGraph.Node;
    id=node_id,
    scale=symbol,
    kind=node -> _mtg_attribute(node, :kind, nothing),
    species=node -> _mtg_attribute(node, :species, nothing),
    name=node -> _mtg_attribute(node, :name, nothing),
    geometry=node -> _mtg_attribute(node, :geometry, nothing),
    status=node -> _mtg_attribute(node, :plantsimengine_status, nothing),
)
    objects = Object[]
    MultiScaleTreeGraph.traverse!(root) do node
        node_parent = parent(node)
        parent_id = node === root || isnothing(node_parent) ? nothing : id(node_parent)
        push!(
            objects,
            Object(
                id(node);
                scale=scale(node),
                kind=kind(node),
                species=species(node),
                name=name(node),
                parent=parent_id,
                geometry=geometry(node),
                status=status(node),
            ),
        )
    end
    return objects
end

"""
    Scene(root::MultiScaleTreeGraph.Node; applications=(), instances=(),
          environment=nothing, kwargs...)

Build a unified scene directly from an MTG subtree. Extra keyword arguments
are forwarded to [`objects_from_mtg`](@ref).
"""
function Scene(
    root::MultiScaleTreeGraph.Node;
    applications=(),
    instances=(),
    environment=nothing,
    kwargs...,
)
    objects = objects_from_mtg(root; kwargs...)
    return Scene(
        objects...;
        applications=applications,
        instances=instances,
        environment=environment,
    )
end

function _mark_environment_bindings_dirty!(scene::Scene, object_id::Union{Nothing,ObjectId}=nothing)
    if isnothing(object_id) || isnothing(scene.environment_binding_cache)
        scene.environment_binding_cache = nothing
        scene.environment_dirty_objects = nothing
    elseif !isnothing(scene.environment_dirty_objects)
        push!(scene.environment_dirty_objects, object_id)
    end
    scene.environment_bindings_dirty = true
    scene.environment_revision += 1
    return scene
end

function _mark_bindings_dirty!(scene::Scene)
    scene.binding_cache = nothing
    scene.bindings_dirty = true
    scene.revision += 1
    return _mark_environment_bindings_dirty!(scene)
end

bindings_dirty(scene::Scene) = scene.bindings_dirty
environment_bindings_dirty(scene::Scene) = scene.environment_bindings_dirty
scene_revision(scene::Scene) = scene.revision
environment_revision(scene::Scene) = scene.environment_revision
compiled_bindings(scene::Scene) = scene.binding_cache
compiled_environment_bindings(scene::Scene) = scene.environment_binding_cache
mark_environment_binding_dirty!(scene::Scene) = _mark_environment_bindings_dirty!(scene)
function mark_environment_binding_dirty!(scene::Scene, id)
    object_id = ObjectId(id)
    _scene_object(scene, object_id)
    return _mark_environment_bindings_dirty!(scene, object_id)
end
function mark_environment_binding_dirty!(scene::Scene, object::Object)
    return mark_environment_binding_dirty!(scene, object.id)
end

function _push_index!(index::Dict{Symbol,Set{ObjectId}}, key, id::ObjectId)
    isnothing(key) && return nothing
    push!(get!(index, key, Set{ObjectId}()), id)
    return nothing
end

function _delete_index!(index::Dict{Symbol,Set{ObjectId}}, key, id::ObjectId)
    isnothing(key) && return nothing
    ids = get(index, key, nothing)
    isnothing(ids) && return nothing
    delete!(ids, id)
    isempty(ids) && delete!(index, key)
    return nothing
end

function _index_object!(registry::SceneRegistry, object::Object)
    _push_index!(registry.by_scale, object.scale, object.id)
    _push_index!(registry.by_kind, object.kind, object.id)
    _push_index!(registry.by_species, object.species, object.id)
    if !isnothing(object.name)
        existing = get(registry.by_name, object.name, nothing)
        if !isnothing(existing) && existing != object.id
            error(
                "Scene object name `$(object.name)` is already used by object `$(existing.value)`."
            )
        end
        registry.by_name[object.name] = object.id
    end
    return nothing
end

function _deindex_object!(registry::SceneRegistry, object::Object)
    _delete_index!(registry.by_scale, object.scale, object.id)
    _delete_index!(registry.by_kind, object.kind, object.id)
    _delete_index!(registry.by_species, object.species, object.id)
    if !isnothing(object.name) && get(registry.by_name, object.name, nothing) == object.id
        delete!(registry.by_name, object.name)
    end
    return nothing
end

function _scene_object(scene::Scene, id)
    oid = ObjectId(id)
    haskey(scene.registry.objects, oid) || error("No scene object with id `$(oid.value)`.")
    return scene.registry.objects[oid]
end

function _instance_for_object(scene::Scene, id)
    current_id = ObjectId(id)
    while haskey(scene.registry.objects, current_id)
        for instance in scene.instances
            _instance_root_id(instance) == current_id && return instance
        end
        parent = scene.registry.objects[current_id].parent
        isnothing(parent) && return nothing
        current_id = parent
    end
    return nothing
end

function _apply_instance_labels!(object::Object, instance)
    isnothing(instance) && return object
    isnothing(object.kind) && (object.kind = instance.template.kind)
    isnothing(object.species) && (object.species = instance.template.species)
    return object
end

function register_object!(scene::Scene, object::Object; parent=object.parent)
    registry = scene.registry
    haskey(registry.objects, object.id) && error("Scene already contains object id `$(object.id.value)`.")
    parent_id = isnothing(parent) ? nothing : ObjectId(parent)
    if !isnothing(parent_id) && !haskey(registry.objects, parent_id)
        error("No scene object with id `$(parent_id.value)`.")
    end
    if !isnothing(object.name)
        existing = get(registry.by_name, object.name, nothing)
        isnothing(existing) || error(
            "Scene object name `$(object.name)` is already used by object `$(existing.value)`."
        )
    end
    instance = isnothing(parent_id) ? nothing : _instance_for_object(scene, parent_id)
    _apply_instance_labels!(object, instance)
    object.parent = parent_id
    registry.objects[object.id] = object
    _index_object!(registry, object)
    if !isnothing(object.parent)
        parent_object = registry.objects[object.parent]
        object.id in parent_object.children || push!(parent_object.children, object.id)
    end
    _mark_bindings_dirty!(scene)
    return object
end

function _remove_child_link!(scene::Scene, parent_id, child_id::ObjectId)
    isnothing(parent_id) && return nothing
    parent_object = _scene_object(scene, parent_id)
    filter!(!=(child_id), parent_object.children)
    return nothing
end

function remove_object!(scene::Scene, id; recursive::Bool=true)
    object = _scene_object(scene, id)
    if !recursive && !isempty(object.children)
        error("Cannot remove object `$(object.id.value)` with children unless `recursive=true`.")
    end
    for child in copy(object.children)
        remove_object!(scene, child; recursive=true)
    end
    _remove_child_link!(scene, object.parent, object.id)
    _deindex_object!(scene.registry, object)
    delete!(scene.registry.objects, object.id)
    _mark_bindings_dirty!(scene)
    return object
end

function reparent_object!(scene::Scene, id, new_parent)
    object = _scene_object(scene, id)
    new_parent_id = isnothing(new_parent) ? nothing : ObjectId(new_parent)
    if !isnothing(new_parent_id)
        haskey(scene.registry.objects, new_parent_id) || error("No scene object with id `$(new_parent_id.value)`.")
    end
    _remove_child_link!(scene, object.parent, object.id)
    object.parent = new_parent_id
    if !isnothing(new_parent_id)
        parent_object = _scene_object(scene, new_parent_id)
        object.id in parent_object.children || push!(parent_object.children, object.id)
    end
    _mark_bindings_dirty!(scene)
    return object
end

function move_object!(scene::Scene, id, geometry_or_position)
    return update_geometry!(scene, id, geometry_or_position)
end

function update_geometry!(scene::Scene, id, geometry_or_position; invalidate_environment::Bool=true)
    object = _scene_object(scene, id)
    object.geometry = geometry_or_position
    if invalidate_environment
        _mark_environment_bindings_dirty!(scene, object.id)
        for descendant_id in _geometry_inheriting_descendants(scene, object.id)
            _mark_environment_bindings_dirty!(scene, descendant_id)
        end
    end
    return object
end

function update_geometry!(object::Object, geometry_or_position)
    object.geometry = geometry_or_position
    return object
end

geometry(object::Object) = object.geometry
geometry(status::Status) = hasproperty(status, :geometry) ? status.geometry : nothing
geometry(x) = hasproperty(x, :geometry) ? getproperty(x, :geometry) : nothing

function _geometry_position(g::NamedTuple)
    haskey(g, :position) && return getproperty(g, :position)
    if haskey(g, :x) && haskey(g, :y) && haskey(g, :z)
        return (x=g.x, y=g.y, z=g.z)
    elseif haskey(g, :x) && haskey(g, :y)
        return (x=g.x, y=g.y)
    end
    return nothing
end
_geometry_position(_) = nothing

position(object::Object) = _geometry_position(geometry(object))
position(status::Status) = _geometry_position(geometry(status))

_geometry_bounds(g::NamedTuple) = haskey(g, :bounds) ? getproperty(g, :bounds) : nothing
_geometry_bounds(_) = nothing
bounds(object::Object) = _geometry_bounds(geometry(object))
bounds(status::Status) = _geometry_bounds(geometry(status))

function _geometry_inheriting_descendants(scene::Scene, root_id::ObjectId)
    ids = ObjectId[]
    for child_id in _scene_object(scene, root_id).children
        child = _scene_object(scene, child_id)
        isnothing(geometry(child)) || continue
        push!(ids, child_id)
        append!(ids, _geometry_inheriting_descendants(scene, child_id))
    end
    return ids
end

function refresh_bindings!(scene::Scene, specs=scene.applications; force::Bool=false)
    uses_scene_applications = specs === scene.applications
    if !uses_scene_applications
        return compile_scene(scene, specs)
    end
    if force || scene.bindings_dirty || isnothing(scene.binding_cache)
        scene.binding_cache = compile_scene(scene, scene.applications)
        scene.bindings_dirty = false
    end
    return scene.binding_cache
end

function refresh_environment_bindings!(scene::Scene, compiled=refresh_bindings!(scene); force::Bool=false)
    if force || scene.environment_bindings_dirty || isnothing(scene.environment_binding_cache)
        if !force &&
           !isnothing(scene.environment_binding_cache) &&
           !isnothing(scene.environment_dirty_objects)
            scene.environment_binding_cache = _refresh_environment_bindings_for_objects(
                scene,
                compiled,
                scene.environment_binding_cache,
                scene.environment_dirty_objects,
            )
        else
            scene.environment_binding_cache = compile_environment_bindings(scene, compiled)
        end
        scene.environment_bindings_dirty = false
        scene.environment_dirty_objects = Set{ObjectId}()
    else
        reconciled = _reconcile_environment_binding_metadata(
            scene,
            compiled,
            scene.environment_binding_cache,
        )
        scene.environment_binding_cache = isnothing(reconciled) ?
                                          compile_environment_bindings(scene, compiled) :
                                          reconciled
    end
    return scene.environment_binding_cache
end

function object_ids(scene::Scene; scale=nothing, kind=nothing, species=nothing, name=nothing)
    registry = scene.registry
    sets = Set{ObjectId}[]
    isnothing(scale) || push!(sets, copy(get(registry.by_scale, Symbol(scale), Set{ObjectId}())))
    isnothing(kind) || push!(sets, copy(get(registry.by_kind, Symbol(kind), Set{ObjectId}())))
    isnothing(species) || push!(sets, copy(get(registry.by_species, Symbol(species), Set{ObjectId}())))
    if !isnothing(name)
        id = get(registry.by_name, Symbol(name), nothing)
        push!(sets, isnothing(id) ? Set{ObjectId}() : Set([id]))
    end
    isempty(sets) && return sort!(collect(keys(registry.objects)); by=id -> string(id.value))
    ids = reduce(intersect, sets)
    return sort!(collect(ids); by=id -> string(id.value))
end

scene_objects(scene::Scene; kwargs...) = [_scene_object(scene, id) for id in object_ids(scene; kwargs...)]

function _instance_object_ids(scene::Scene, instance::ObjectInstance)
    root_id = _instance_root_id(instance)
    haskey(scene.registry.objects, root_id) || return ObjectId[]
    return _sort_object_ids!(_descendant_ids(scene, root_id))
end

function _object_instance_name(scene::Scene, object_id::ObjectId)
    instance = _instance_for_object(scene, object_id)
    return isnothing(instance) ? nothing : instance.name
end

function explain_objects(scene::Scene)
    return [
        (
            id=object.id.value,
            scale=object.scale,
            kind=object.kind,
            species=object.species,
            name=object.name,
            instance=_object_instance_name(scene, object.id),
            parent=isnothing(object.parent) ? nothing : object.parent.value,
            children=[child.value for child in object.children],
            has_geometry=!isnothing(object.geometry),
            has_status=!isnothing(object.status),
            n_applications=length(object.applications),
        )
        for object in scene_objects(scene)
    ]
end

function _instance_application_ids(scene::Scene, instance::ObjectInstance)
    prefix = string(instance.name, "__")
    ids = Symbol[]
    for application in scene.applications
        name = application_name(as_model_spec(application))
        isnothing(name) && continue
        startswith(string(name), prefix) && push!(ids, name)
    end
    return sort!(ids; by=string)
end

function explain_instances(scene::Scene)
    return [
        (
            name=instance.name,
            root_id=_instance_root_id(instance).value,
            kind=instance.template.kind,
            species=instance.template.species,
            object_ids=[id.value for id in _instance_object_ids(scene, instance)],
            application_ids=_instance_application_ids(scene, instance),
            instance_overrides=sort!(Symbol[Symbol(name) for name in keys(instance.overrides)]; by=string),
            object_overrides=[
                (
                    object_id=override.object.value,
                    process=override.process,
                    application=override.application,
                    model_type=typeof(override.model),
                )
                for override in instance.object_overrides
            ],
            parameters_type=typeof(instance.template.parameters),
            parameters_shared_by_reference=true,
        )
        for instance in scene.instances
    ]
end

function _object_id_values(ids)
    return [id.value for id in _sort_object_ids!(collect(ids))]
end

function _label_scope_rows(scene::Scene, scope_type::Symbol, label::Symbol, index)
    return [
        (
            scope_type=scope_type,
            selector=label => key,
            context=nothing,
            root_id=nothing,
            scale=label == :scale ? key : nothing,
            kind=label == :kind ? key : nothing,
            species=label == :species ? key : nothing,
            name=nothing,
            object_ids=_object_id_values(ids),
            n_objects=length(ids),
        )
        for (key, ids) in sort!(collect(index); by=pair -> string(first(pair)))
    ]
end

function explain_scopes(scene::Scene)
    rows = NamedTuple[]
    all_ids = object_ids(scene)
    push!(
        rows,
        (
            scope_type=:scene,
            selector=SceneScope(),
            context=nothing,
            root_id=nothing,
            scale=nothing,
            kind=nothing,
            species=nothing,
            name=nothing,
            object_ids=[id.value for id in all_ids],
            n_objects=length(all_ids),
        ),
    )
    for object in scene_objects(scene)
        descendant_ids = _object_id_values(_descendant_ids(scene, object.id))
        push!(
            rows,
            (
                scope_type=:object_subtree,
                selector=Self(),
                context=object.id.value,
                root_id=object.id.value,
                scale=object.scale,
                kind=object.kind,
                species=object.species,
                name=object.name,
                object_ids=descendant_ids,
                n_objects=length(descendant_ids),
            ),
        )
        object_scope_name = object.id.value isa Symbol ? object.id.value : Symbol(string(object.id.value))
        scope_names = Symbol[object_scope_name]
        isnothing(object.name) || push!(scope_names, object.name)
        unique!(scope_names)
        for scope_name in scope_names
            push!(
                rows,
                (
                    scope_type=:named_scope,
                    selector=Scope(scope_name),
                    context=nothing,
                    root_id=object.id.value,
                    scale=object.scale,
                    kind=object.kind,
                    species=object.species,
                    name=scope_name,
                    object_ids=descendant_ids,
                    n_objects=length(descendant_ids),
                ),
            )
        end
    end
    append!(rows, _label_scope_rows(scene, :scale, :scale, scene.registry.by_scale))
    append!(rows, _label_scope_rows(scene, :kind, :kind, scene.registry.by_kind))
    append!(rows, _label_scope_rows(scene, :species, :species, scene.registry.by_species))
    return rows
end

struct SceneScope <: AbstractObjectSelector end
struct Self <: AbstractObjectSelector end
struct SelfPlant <: AbstractObjectSelector end

struct Ancestor <: AbstractObjectSelector
    scale::Union{Nothing,Symbol}
end
Ancestor(; scale=nothing) = Ancestor(_maybe_symbol(scale))

struct Scope <: AbstractObjectSelector
    name::Symbol
end
Scope(name::Union{Symbol,AbstractString}) = Scope(Symbol(name))

struct Kind <: AbstractObjectSelector
    kind::Symbol
end
Kind(kind::Union{Symbol,AbstractString}) = Kind(Symbol(kind))

struct Species <: AbstractObjectSelector
    species::Symbol
end
Species(species::Union{Symbol,AbstractString}) = Species(Symbol(species))

struct Scale <: AbstractObjectSelector
    scale::Symbol
end
Scale(scale::Union{Symbol,AbstractString}) = Scale(Symbol(scale))

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

const _OBJECT_ADDRESS_SYMBOL_FIELDS = (:kind, :domain, :species, :scale, :name, :process, :var, :relation, :application)

function _normalize_object_selector_value(key::Symbol, value)
    key in _OBJECT_ADDRESS_SYMBOL_FIELDS && return _maybe_symbol(value)
    return value
end

function _normalize_selector_kwargs(kwargs)
    return NamedTuple{keys(kwargs)}(
        Tuple(_normalize_object_selector_value(k, v) for (k, v) in pairs(kwargs))
    )
end

function _normalize_selector_criteria(args::Tuple; kwargs...)
    selectors = Tuple(args)
    all(selector -> selector isa AbstractObjectSelector, selectors) || error(
        "Object selector positional arguments must be selector objects such as `Kind(:plant)` or `Scale(:Leaf)`."
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

_rebuild_selector(::One, criteria) = One{typeof(criteria)}(criteria)
_rebuild_selector(::OptionalOne, criteria) = OptionalOne{typeof(criteria)}(criteria)
_rebuild_selector(::Many, criteria) = Many{typeof(criteria)}(criteria)

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

function _instance_override_matches(spec, key::Symbol)
    name = application_name(spec)
    return key == process(spec) || (!isnothing(name) && key == name)
end

function _instance_override_models(instance::ObjectInstance, specs)
    selected = Dict{Int,AbstractModel}()
    for (key, replacement) in pairs(instance.overrides)
        replacement isa AbstractModel || error(
            "Override `$(key)` for instance `$(instance.name)` must be an `AbstractModel`, got `$(typeof(replacement))`."
        )
        matches = findall(spec -> _instance_override_matches(spec, Symbol(key)), specs)
        isempty(matches) && error(
            "Override `$(key)` for instance `$(instance.name)` does not match a template application name or process."
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
        inputs=Tuple(Symbol.(keys(inputs_(model)))),
        outputs=Tuple(Symbol.(keys(outputs_(model)))),
        meteo_inputs=Tuple(Symbol.(keys(meteo_inputs_(model)))),
        meteo_outputs=Tuple(Symbol.(keys(meteo_outputs_(model)))),
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

function _object_override_matches(spec, override::Override)
    process_match = isnothing(override.process) || process(spec) == override.process
    name = application_name(spec)
    application_match = isnothing(override.application) ||
                        (!isnothing(name) && name == override.application)
    return process_match && application_match
end

function _object_override_models(instance::ObjectInstance, specs, instance_ids)
    entries = Dict{Int,Vector{Pair{ObjectId,AbstractModel}}}()
    valid_ids = Set(instance_ids)
    for override in instance.object_overrides
        override.object in valid_ids || error(
            "Object override for `$(override.object.value)` does not belong to instance `$(instance.name)`."
        )
        matches = findall(spec -> _object_override_matches(spec, override), specs)
        isempty(matches) && error(
            "Object override for `$(override.object.value)` in instance `$(instance.name)` ",
            "does not match a template application."
        )
        length(matches) == 1 || error(
            "Object override for `$(override.object.value)` in instance `$(instance.name)` ",
            "matches several template applications; add `application=...`."
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
            "Template application `$(base_name)` has no `AppliesTo(...)` selector."
        )
        mounted_target = _selector_with_scope(target, Scope(instance.name))
        prefix_application = selector -> _selector_with_application_prefix(
            selector,
            instance.name,
            base_names,
        )
        mounted_inputs = _map_selector_bindings(value_inputs(spec), prefix_application)
        mounted_calls = _map_selector_bindings(model_calls(spec), prefix_application)
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
            ModelSpec(
                spec;
                model=mounted_model,
                name=mounted_name,
                applies_to=mounted_target,
                inputs=mounted_inputs,
                calls=mounted_calls,
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

_sort_object_ids!(ids) = sort!(ids; by=id -> string(id.value))

function _object_id_from_context(context)
    isnothing(context) && return nothing
    context isa Object && return context.id
    return ObjectId(context)
end

function _descendant_ids(scene::Scene, root_id::ObjectId)
    ids = ObjectId[root_id]
    object = _scene_object(scene, root_id)
    for child_id in object.children
        append!(ids, _descendant_ids(scene, child_id))
    end
    return ids
end

function _ancestor_id(scene::Scene, current_id::ObjectId; scale=nothing, kind=nothing)
    id = current_id
    while true
        object = _scene_object(scene, id)
        scale_match = isnothing(scale) || object.scale == Symbol(scale)
        kind_match = isnothing(kind) || object.kind == Symbol(kind)
        scale_match && kind_match && return id
        isnothing(object.parent) && return nothing
        id = object.parent
    end
end

function _ancestor_ids(scene::Scene, current_id::ObjectId)
    ids = ObjectId[]
    parent_id = _scene_object(scene, current_id).parent
    while !isnothing(parent_id)
        push!(ids, parent_id)
        parent_id = _scene_object(scene, parent_id).parent
    end
    return ids
end

function _relation_object_ids(scene::Scene, relation::Symbol, context)
    current_id = _object_id_from_context(context)
    isnothing(current_id) && error(
        "`Relation(:$(relation))` selectors require a current object context."
    )
    object = _scene_object(scene, current_id)
    relation == :self && return ObjectId[current_id]
    relation == :parent && return isnothing(object.parent) ? ObjectId[] : ObjectId[object.parent]
    relation == :children && return copy(object.children)
    relation == :ancestors && return _ancestor_ids(scene, current_id)
    relation == :descendants && return _descendant_ids(scene, current_id)[2:end]
    if relation == :siblings
        isnothing(object.parent) && return ObjectId[]
        return ObjectId[
            sibling_id for sibling_id in _scene_object(scene, object.parent).children
            if sibling_id != current_id
        ]
    end
    error("Unsupported object relation `$(relation)`.")
end

function _selector_scope_from_positional(selectors)
    scopes = filter(
        selector -> selector isa Union{SceneScope,Self,SelfPlant,Ancestor,Scope},
        selectors,
    )
    isempty(scopes) && return nothing
    length(scopes) == 1 || error("Only one scope selector can be used in one object selector.")
    return only(scopes)
end

function _selector_value_from_positional(selectors, ::Type{Kind})
    values = [selector.kind for selector in selectors if selector isa Kind]
    isempty(values) && return nothing
    length(unique(values)) == 1 || error("Conflicting `Kind(...)` selector values: $(values).")
    return only(unique(values))
end

function _selector_value_from_positional(selectors, ::Type{Species})
    values = [selector.species for selector in selectors if selector isa Species]
    isempty(values) && return nothing
    length(unique(values)) == 1 || error("Conflicting `Species(...)` selector values: $(values).")
    return only(unique(values))
end

function _selector_value_from_positional(selectors, ::Type{Scale})
    values = [selector.scale for selector in selectors if selector isa Scale]
    isempty(values) && return nothing
    length(unique(values)) == 1 || error("Conflicting `Scale(...)` selector values: $(values).")
    return only(unique(values))
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

function _criteria_scope(criteria)
    positional = _selector_scope_from_positional(criteria.selectors)
    keyword = haskey(criteria, :within) ? criteria.within : nothing
    if !isnothing(positional) && !isnothing(keyword) && typeof(positional) != typeof(keyword)
        error("Conflicting scope selectors: `$(positional)` and `$(keyword)`.")
    end
    return isnothing(keyword) ? positional : keyword
end

function _scope_object_ids(scene::Scene, scope, context)
    if isnothing(scope) || scope isa SceneScope
        return ObjectId[keys(scene.registry.objects)...]
    end

    current_id = _object_id_from_context(context)
    if scope isa Self
        isnothing(current_id) && error("`Self()` selectors require a current object context.")
        return _descendant_ids(scene, current_id)
    elseif scope isa SelfPlant
        isnothing(current_id) && error("`SelfPlant()` selectors require a current object context.")
        plant_id = _ancestor_id(scene, current_id; scale=:Plant)
        isnothing(plant_id) && error("No `scale=:Plant` ancestor found for object `$(current_id.value)`.")
        return _descendant_ids(scene, plant_id)
    elseif scope isa Ancestor
        isnothing(current_id) && error("`Ancestor(...)` selectors require a current object context.")
        ancestor_id = _ancestor_id(scene, current_id; scale=scope.scale)
        if isnothing(ancestor_id)
            error("No matching ancestor found for object `$(current_id.value)` and selector `$(scope)`.")
        end
        return _descendant_ids(scene, ancestor_id)
    elseif scope isa Scope
        root_id = get(scene.registry.by_name, scope.name, nothing)
        if isnothing(root_id)
            candidate = ObjectId(scope.name)
            root_id = haskey(scene.registry.objects, candidate) ? candidate : nothing
        end
        if isnothing(root_id)
            available = sort!(unique(Symbol[
                keys(scene.registry.by_name)...,
                (id.value for id in keys(scene.registry.objects))...,
            ]); by=string)
            suggestions = _near_symbol_matches(scope.name, available)
            error(
                "No named scope or object `$(scope.name)` found in the scene registry. ",
                "available=$(available), suggestions=$(suggestions)."
            )
        end
        return _descendant_ids(scene, root_id)
    end

    error("Unsupported object scope selector `$(scope)` of type `$(typeof(scope))`.")
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

function _available_selector_labels(scene::Scene, candidate_ids)
    objects = (_scene_object(scene, id) for id in candidate_ids)
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
    scene::Scene,
    selector,
    candidate_ids,
    matched_ids;
    context=nothing,
    scale=nothing,
    kind=nothing,
    species=nothing,
    name=nothing,
)
    available = _available_selector_labels(scene, candidate_ids)
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
    isnothing(scale) || object.scale == scale || return false
    isnothing(kind) || object.kind == kind || return false
    isnothing(species) || object.species == species || return false
    isnothing(name) || object.name == name || return false
    return true
end

function resolve_object_ids(scene::Scene, selector::AbstractObjectMultiplicity; context=nothing)
    return _resolve_object_ids(scene, selector; context=context)
end

function _resolve_object_ids(
    scene::Scene,
    selector::AbstractObjectMultiplicity;
    context=nothing,
    default_to_context::Bool=false,
    default_scope=nothing,
)
    criteria_ = criteria(selector)
    relation = _criteria_value(criteria_, :relation, Relation)

    explicit_scope = _criteria_scope(criteria_)
    scope = if !isnothing(explicit_scope)
        explicit_scope
    elseif isnothing(relation)
        default_scope
    else
        nothing
    end
    scale = _criteria_value(criteria_, :scale, Scale)
    kind = _criteria_value(criteria_, :kind, Kind)
    species = _criteria_value(criteria_, :species, Species)
    name = haskey(criteria_, :name) ? criteria_.name : nothing

    if default_to_context &&
       isnothing(explicit_scope) &&
       isnothing(relation) &&
       isnothing(scale) &&
       isnothing(kind) &&
       isnothing(species) &&
       isnothing(name) &&
       !isnothing(context)
        return ObjectId[_object_id_from_context(context)]
    end

    candidate_ids = if isnothing(relation)
        _scope_object_ids(scene, scope, context)
    else
        related_ids = _relation_object_ids(scene, relation, context)
        if isnothing(explicit_scope)
            related_ids
        else
            scoped_ids = Set(_scope_object_ids(scene, explicit_scope, context))
            ObjectId[id for id in related_ids if id in scoped_ids]
        end
    end
    ids = ObjectId[
        id for id in candidate_ids
        if _matches_object_criteria(_scene_object(scene, id); scale=scale, kind=kind, species=species, name=name)
    ]
    _sort_object_ids!(ids)

    if selector isa One && length(ids) != 1
        _selector_resolution_error(
            scene,
            selector,
            candidate_ids,
            ids;
            context=context,
            scale=scale,
            kind=kind,
            species=species,
            name=name,
        )
    elseif selector isa OptionalOne && length(ids) > 1
        _selector_resolution_error(
            scene,
            selector,
            candidate_ids,
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

resolve_objects(scene::Scene, selector::AbstractObjectMultiplicity; context=nothing) =
    [_scene_object(scene, id) for id in resolve_object_ids(scene, selector; context=context)]

function _default_dependency_scope(scene::Scene, context::ObjectId)
    object = _scene_object(scene, context)
    (object.scale == :Scene || object.kind == :scene) && return SceneScope()
    return Self()
end

struct CompiledSceneApplication{S,AT,TS,CL,MO}
    id::Symbol
    spec::S
    process::Symbol
    name::Union{Nothing,Symbol}
    target_ids::Vector{ObjectId}
    applies_to::AT
    timestep::TS
    clock::CL
    model_overrides::MO
end

struct CompiledSceneInputBinding{SEL,P,W,C}
    application_id::Symbol
    consumer_id::ObjectId
    input::Symbol
    selector::SEL
    origin::Symbol
    source_ids::Vector{ObjectId}
    source_application_ids::Vector{Symbol}
    source_var::Symbol
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    multiplicity::Symbol
    policy::P
    window::W
    carrier_hint::Symbol
    carrier::C
end

struct CompiledSceneCallBinding{SEL}
    application_id::Symbol
    consumer_id::ObjectId
    call::Symbol
    selector::SEL
    origin::Symbol
    callee_object_ids::Vector{ObjectId}
    callee_application_ids::Vector{Symbol}
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    multiplicity::Symbol
end

struct CompiledEnvironmentBinding{B,C,S}
    application_id::Symbol
    object_id::ObjectId
    provider::Symbol
    backend::B
    cell::C
    required_inputs::Vector{Symbol}
    source_inputs::Vector{Symbol}
    produced_outputs::Vector{Symbol}
    support::S
    geometry_source_object_id::Union{Nothing,ObjectId}
    geometry_source::Symbol
    config::Any
end

struct CompiledEnvironmentBindings{SC,B,I,S,C}
    scene::SC
    bindings::B
    by_target::I
    samplers_by_application::S
    sample_cache::C
    scene_revision::Int
    environment_revision::Int
end

struct CompiledScene{SC,AP,AI,IB,CB,IBI,CBI,MBI,AO}
    scene::SC
    applications::AP
    applications_by_id::AI
    input_bindings::IB
    call_bindings::CB
    input_bindings_by_target::IBI
    call_bindings_by_target::CBI
    model_bundles_by_target::MBI
    application_order::AO
    revision::Int
end

function _index_scene_bindings(bindings, application_field::Symbol, object_field::Symbol)
    grouped = Dict{Tuple{Symbol,ObjectId},Vector{Any}}()
    for binding in bindings
        key = (
            getproperty(binding, application_field),
            getproperty(binding, object_field),
        )
        push!(get!(grouped, key, Any[]), binding)
    end
    return Dict(key => Tuple(values) for (key, values) in grouped)
end

function compile_scene(scene::Scene)
    return compile_scene(scene, scene.applications)
end

function compile_scene(scene::Scene, specs::Tuple)
    return _compile_scene(scene, specs)
end

function compile_scene(scene::Scene, specs::AbstractVector)
    return _compile_scene(scene, Tuple(specs))
end

function compile_scene(scene::Scene, specs...)
    return _compile_scene(scene, specs)
end

function _scene_timeline(scene::Scene)
    backend = environment_backend(scene.environment)
    try
        return _timeline_context(backend)
    catch
        return TimelineContext(3600.0)
    end
end

function _compile_scene(scene::Scene, raw_specs)
    timeline = _scene_timeline(scene)
    applications = _compile_scene_applications(scene, raw_specs, timeline)
    call_bindings = _compile_scene_call_bindings(scene, applications)
    _validate_scene_writers!(applications, call_bindings)
    _prepare_scene_output_statuses!(scene, applications)
    input_bindings = _compile_scene_input_bindings(scene, applications)
    _prepare_scene_bound_input_statuses!(scene, applications, input_bindings)
    _wire_scene_input_carriers!(scene, input_bindings)
    _validate_scene_required_inputs!(scene, applications, input_bindings)
    input_bindings_by_target = _index_scene_bindings(input_bindings, :application_id, :consumer_id)
    call_bindings_by_target = _index_scene_bindings(call_bindings, :application_id, :consumer_id)
    application_order = _compile_scene_application_order(applications, input_bindings, call_bindings)
    applications_by_id = Dict(application.id => application for application in applications)
    model_bundles_by_target = _compile_scene_model_bundles(
        applications,
        applications_by_id,
        call_bindings_by_target,
    )
    return CompiledScene(
        scene,
        applications,
        applications_by_id,
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        model_bundles_by_target,
        application_order,
        scene.revision,
    )
end

function _compile_scene_applications(scene::Scene, raw_specs, timeline)
    process_counts = Dict{Symbol,Int}()
    ids = Set{Symbol}()
    applications = CompiledSceneApplication[]
    for raw_spec in raw_specs
        spec = as_model_spec(raw_spec)
        selector = applies_to(spec)
        isnothing(selector) && error(
            "Model application for process `$(process(spec))` has no `AppliesTo(...)` selector."
        )
        selector isa AbstractObjectMultiplicity || error(
            "`AppliesTo(...)` for process `$(process(spec))` must be an object selector such as `Many(scale=:Leaf)`."
        )
        proc = process(spec)
        occurrence = get(process_counts, proc, 0) + 1
        process_counts[proc] = occurrence
        name = application_name(spec)
        app_id = isnothing(name) ? (occurrence == 1 ? proc : Symbol(string(proc), "_", occurrence)) : name
        app_id in ids && error("Duplicate compiled scene application id `$(app_id)`.")
        push!(ids, app_id)
        target_ids = resolve_object_ids(scene, selector)
        spec = _scene_spec_with_meteo_hints(
            scene,
            spec,
            _scene_application_hint_scale(scene, target_ids),
        )
        model_overrides = _compiled_object_model_overrides(spec, target_ids, app_id)
        push!(
            applications,
            CompiledSceneApplication(
                app_id,
                spec,
                proc,
                name,
                target_ids,
                selector,
                timestep(spec),
                _scene_application_clock(scene, spec, target_ids, timeline),
                model_overrides,
            ),
        )
    end
    return applications
end

function _scene_spec_with_meteo_hints(scene::Scene, spec, scale::Symbol)
    hint = _normalize_meteo_hint(scale, process(spec), meteo_hint(model_(spec)))

    current_bindings = meteo_bindings(spec)
    has_explicit_bindings = !(current_bindings isa NamedTuple && isempty(keys(current_bindings)))
    new_bindings = has_explicit_bindings || isnothing(hint.bindings) ? current_bindings : hint.bindings
    new_bindings = _scene_meteo_bindings_with_environment_sources(spec, new_bindings)

    current_window = meteo_window(spec)
    new_window = isnothing(current_window) && !isnothing(hint.window) ? hint.window : current_window

    (new_bindings === current_bindings && new_window === current_window) && return spec
    return ModelSpec(spec; meteo_bindings=new_bindings, meteo_window=new_window)
end

function _scene_meteo_bindings_with_environment_sources(spec, bindings)
    sources = _environment_source_overrides(spec)
    isempty(keys(sources)) && return bindings

    bindings = bindings isa NamedTuple ? bindings : NamedTuple()
    model_inputs = Set(Symbol.(keys(meteo_inputs_(spec))))
    unknown = Symbol[target for target in keys(sources) if !(Symbol(target) in model_inputs)]
    isempty(unknown) || error(
        "`Environment(; sources=...)` for process `$(process(spec))` contains ",
        "unknown model-facing meteo input(s) `$(Tuple(unknown))`. Declared ",
        "`meteo_inputs_` are `$(Tuple(sort!(collect(model_inputs); by=string)))`."
    )

    targets = Symbol[Symbol(target) for target in keys(bindings)]
    for target in keys(sources)
        target = Symbol(target)
        target in targets || push!(targets, target)
    end

    resolved = Pair{Symbol,Any}[]
    for target in targets
        rule = haskey(bindings, target) ?
               _normalize_meteo_binding_rule(target, bindings[target]) :
               (source=target, reducer=PlantMeteo.MeanWeighted())
        source = haskey(sources, target) ? Symbol(sources[target]) : rule.source
        push!(resolved, target => (source=source, reducer=rule.reducer))
    end
    return (; resolved...)
end

function _compiled_object_model_overrides(spec, target_ids, application_id::Symbol)
    model = model_(spec)
    model isa ObjectModelOverrides || return nothing
    target_set = Set(target_ids)
    unmatched = ObjectId[id for id in keys(model.overrides) if !(id in target_set)]
    isempty(unmatched) || error(
        "Object override(s) `$([id.value for id in unmatched])` for application ",
        "`$(application_id)` do not match its `AppliesTo(...)` target set."
    )
    return model.overrides
end

_application_default_model(application::CompiledSceneApplication) =
    model_(application.spec) isa ObjectModelOverrides ?
    model_(application.spec).base :
    model_(application.spec)

function _application_model(application::CompiledSceneApplication, object_id::ObjectId)
    isnothing(application.model_overrides) && return _application_default_model(application)
    return get(
        application.model_overrides,
        object_id,
        _application_default_model(application),
    )
end

function _scene_output_names(application::CompiledSceneApplication)
    return Symbol[Symbol(var) for var in keys(outputs_(application.spec))]
end

function _scene_canonical_output_names(application::CompiledSceneApplication)
    return Symbol[
        variable for variable in _scene_output_names(application)
        if _publish_mode_for_output(application.spec, variable) == :canonical
    ]
end

function _scene_writer_groups(applications, skipped_application_ids=Set{Symbol}())
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for (index, application) in pairs(applications)
        application.id in skipped_application_ids && continue
        for object_id in application.target_ids
            for variable in _scene_canonical_output_names(application)
                push!(get!(groups, (object_id, variable), Tuple{Int,Any}[]), (index, application))
            end
        end
    end
    return groups
end

function _application_match_labels(application::CompiledSceneApplication)
    labels = Set{Symbol}([application.id, application.process])
    isnothing(application.name) || push!(labels, application.name)
    return labels
end

function _update_variables(update)
    return Tuple(Symbol(variable) for variable in getproperty(update, :variables))
end

function _update_after(update)
    return Tuple(Symbol(label) for label in getproperty(update, :after))
end

function _matching_updates(spec, variable::Symbol)
    return [update for update in updates(spec) if variable in _update_variables(update)]
end

function _update_after_labels(spec, variable::Symbol)
    labels = Symbol[]
    for update in _matching_updates(spec, variable)
        append!(labels, _update_after(update))
    end
    unique!(labels)
    return labels
end

function _updates_after_previous_writer(spec, variable::Symbol, previous_applications)
    matching = _matching_updates(spec, variable)
    isempty(matching) && return false
    previous_labels = Set{Symbol}()
    for application in previous_applications
        union!(previous_labels, _application_match_labels(application))
    end
    for update in matching
        after = _update_after(update)
        isempty(after) && continue
        any(label -> label in previous_labels, after) && return true
    end
    return false
end

function _declares_update_without_previous_writer(spec, variable::Symbol, previous_applications)
    isempty(previous_applications) || return false
    for update in _matching_updates(spec, variable)
        isempty(_update_after(update)) || return true
    end
    return false
end

function _manual_call_application_ids(call_bindings)
    ids = Set{Symbol}()
    for binding in call_bindings
        union!(ids, binding.callee_application_ids)
    end
    return ids
end

function _validate_scene_writers!(applications, call_bindings=())
    manual_application_ids = _manual_call_application_ids(call_bindings)
    for ((object_id, variable), indexed_writers) in _scene_writer_groups(applications, manual_application_ids)
        length(indexed_writers) <= 1 && continue
        sort!(indexed_writers; by=first)
        previous = CompiledSceneApplication[]
        for (_, application) in indexed_writers
            if _declares_update_without_previous_writer(application.spec, variable, previous)
                error(
                    "Application `$(application.id)` declares `Updates($(variable))` for object ",
                    "`$(object_id.value)`, but no previous writer for `$(variable)` exists. ",
                    "Move it after the producer named in `after=...`."
                )
            end
            if !isempty(previous) && !_updates_after_previous_writer(application.spec, variable, previous)
                previous_labels = sort!(collect(reduce(union!, (_application_match_labels(app) for app in previous); init=Set{Symbol}())))
                error(
                    "Variable `$(variable)` on object `$(object_id.value)` is written by multiple ",
                    "applications. Application `$(application.id)` must declare ",
                    "`Updates(:$(variable); after=...)` matching one of the previous writers ",
                    "`$(previous_labels)`."
                )
            end
            push!(previous, application)
        end
    end
    return nothing
end

function _scene_application_hint_scale(scene::Scene, target_ids::Vector{ObjectId})
    isempty(target_ids) && return :Scene
    scales = unique!([_scene_object(scene, object_id).scale for object_id in target_ids])
    length(scales) == 1 && return only(scales)
    return :Mixed
end

function _scene_application_clock(scene::Scene, spec, target_ids::Vector{ObjectId}, timeline)
    model = model_(spec)
    source = _runtime_clock_source_for_spec(spec)
    source == :meteo_base_step || return _model_clock(spec, model, timeline)
    scale = _scene_application_hint_scale(scene, target_ids)
    clock, hint_reason = _resolve_meteo_hint_clock(scale, process(spec), model, timeline)
    isnothing(hint_reason) || error(hint_reason)
    return clock
end

function _criteria_get(criteria, key::Symbol, default=nothing)
    return haskey(criteria, key) ? getproperty(criteria, key) : default
end

function _selector_policy(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :policy, HoldLast())
end

_selector_has_policy(selector::AbstractObjectMultiplicity) =
    haskey(criteria(selector), :policy)

function _scene_policy_from_source_application(applications_by_id, application_id::Symbol, source_var::Symbol)
    application = get(applications_by_id, application_id, nothing)
    isnothing(application) && error(
        "No compiled scene application with id `$(application_id)` while resolving ",
        "default output policy for `$(source_var)`."
    )
    return _policy_for_output(_application_default_model(application), source_var)
end

function _scene_selector_policy(selector::AbstractObjectMultiplicity, applications_by_id, source_application_ids, source_var::Symbol)
    _selector_has_policy(selector) && return _selector_policy(selector)
    isempty(source_application_ids) && return HoldLast()
    length(source_application_ids) == 1 && return _scene_policy_from_source_application(
        applications_by_id,
        only(source_application_ids),
        source_var,
    )
    policies = [
        _scene_policy_from_source_application(applications_by_id, application_id, source_var)
        for application_id in source_application_ids
    ]
    first_policy = first(policies)
    all(policy -> policy == first_policy, policies) && return first_policy
    error(
        "Cannot infer default policy for scene input from `$(source_var)` because ",
        "selector resolves several source applications `$(source_application_ids)` with ",
        "different output policies. Add `policy=...` to `Inputs(...)`."
    )
end

function _selector_window(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :window, nothing)
end

function _selector_var(selector::AbstractObjectMultiplicity, fallback::Symbol)
    return _criteria_get(criteria(selector), :var, fallback)
end

function _selector_application(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :application, nothing)
end

function _dependency_object_ids(scene::Scene, selector::AbstractObjectMultiplicity, context::ObjectId)
    return _resolve_object_ids(
        scene,
        selector;
        context=context,
        default_to_context=true,
        default_scope=_default_dependency_scope(scene, context),
    )
end

function _carrier_hint(selector::AbstractObjectMultiplicity, policy, window)
    !isnothing(window) && return :temporal_stream
    policy isa HoldLast || return :temporal_stream
    selector isa Many && return :ref_vector
    return :shared_ref
end

function _status_ref_or_nothing(status, var::Symbol)
    status isa Status || return nothing
    var in propertynames(status) || return nothing
    return refvalue(status, var)
end

function _input_carrier(scene::Scene, selector::AbstractObjectMultiplicity, source_ids::Vector{ObjectId}, source_var::Symbol)
    refs = Base.RefValue[]
    for source_id in source_ids
        object = _scene_object(scene, source_id)
        source_ref = _status_ref_or_nothing(object.status, source_var)
        isnothing(source_ref) && return nothing
        push!(refs, source_ref)
    end
    if selector isa Many
        isempty(refs) && return RefVector{Any}()
        return _ref_vector_carrier(refs)
    end
    return isempty(refs) ? nothing : only(refs)
end

function _ref_vector_carrier(refs)
    T = typeof(refs[1][])
    typed_refs = Base.RefValue{T}[]
    for source_ref in refs
        source_ref isa Base.RefValue{T} || return ObjectRefVector(refs)
        push!(typed_refs, source_ref)
    end
    return RefVector(typed_refs)
end

function _status_with_reference(status::Status, variable::Symbol, reference::Base.RefValue)
    names = propertynames(status)
    if variable in names
        references = ntuple(
            index -> names[index] == variable ? reference : refvalue(status, names[index]),
            length(names),
        )
        return Status(NamedTuple{names}(references))
    end
    extended_names = (names..., variable)
    references = (ntuple(index -> refvalue(status, names[index]), length(names))..., reference)
    return Status(NamedTuple{extended_names}(references))
end

function _status_with_default(status::Status, variable::Symbol, value)
    variable in propertynames(status) && return status
    return _status_with_reference(status, variable, Ref(value))
end

function _ensure_scene_object_status!(scene::Scene, object_id::ObjectId)
    object = _scene_object(scene, object_id)
    isnothing(object.status) && (object.status = Status())
    object.status isa Status || error(
        "Scene object `$(object_id.value)` uses model applications but its status has type ",
        "`$(typeof(object.status))`. Use `Status(...)` or leave status as `nothing`."
    )
    return object.status
end

function _prepare_scene_output_statuses!(scene::Scene, applications)
    for application in applications
        defaults = merge(outputs_(application.spec), meteo_outputs_(application.spec))
        for object_id in application.target_ids
            status = _ensure_scene_object_status!(scene, object_id)
            for (variable, value) in pairs(defaults)
                status = _status_with_default(status, Symbol(variable), value)
            end
            _scene_object(scene, object_id).status = status
        end
    end
    return scene
end

function _prepare_scene_bound_input_statuses!(scene::Scene, applications, bindings)
    applications_by_id = Dict(application.id => application for application in applications)
    for binding in bindings
        status = _ensure_scene_object_status!(scene, binding.consumer_id)
        binding.input in propertynames(status) && continue
        application = applications_by_id[binding.application_id]
        defaults = inputs_(application.spec)
        binding.input in keys(defaults) || error(
            "Bound input `$(binding.input)` is not declared by application `$(binding.application_id)`."
        )
        _scene_object(scene, binding.consumer_id).status =
            _status_with_default(status, binding.input, getproperty(defaults, binding.input))
    end
    return scene
end

function _wire_scene_input_carriers!(scene::Scene, bindings)
    for binding in bindings
        binding.carrier_hint == :temporal_stream && continue
        isnothing(binding.carrier) && continue
        object = _scene_object(scene, binding.consumer_id)
        status = object.status
        status isa Status || continue
        reference = binding.carrier isa Base.RefValue ? binding.carrier : Ref(binding.carrier)
        object.status = _status_with_reference(status, binding.input, reference)
    end
    return scene
end

input_carrier(binding::CompiledSceneInputBinding) = binding.carrier
has_reference_carrier(binding::CompiledSceneInputBinding) = !isnothing(binding.carrier)
input_value(binding::CompiledSceneInputBinding) = _input_value(binding.carrier)
_input_value(::Nothing) = nothing
_input_value(carrier::Base.RefValue) = carrier[]
_input_value(carrier::RefVector) = carrier
_input_value(carrier::ObjectRefVector) = carrier

function _matching_input_source_applications(
    applications_by_object,
    source_ids,
    source_var::Symbol,
    process_filter,
    application_filter;
    allow_empty::Bool=false,
)
    matches = Symbol[]
    for source_id in source_ids
        for application in get(applications_by_object, source_id, Any[])
            source_var in _scene_output_names(application) || continue
            isnothing(process_filter) || application.process == process_filter || continue
            isnothing(application_filter) || application.id == application_filter || continue
            push!(matches, application.id)
        end
    end
    unique!(matches)
    if !allow_empty &&
       (!isnothing(process_filter) || !isnothing(application_filter)) &&
       isempty(matches)
        error(
            "Input selector for source variable `$(source_var)` requested",
            isnothing(process_filter) ? "" : " process `$(process_filter)`",
            isnothing(application_filter) ? "" : " application `$(application_filter)`",
            ", but no matching source application was found."
        )
    end
    return matches
end

function _compile_scene_input_bindings(scene::Scene, applications)
    bindings = CompiledSceneInputBinding[]
    by_object = _applications_by_object(applications)
    by_id = Dict(application.id => application for application in applications)
    for application in applications
        for consumer_id in application.target_ids
            declared_inputs = value_inputs(application.spec)
            declared_inputs isa NamedTuple || (declared_inputs = NamedTuple())
            for (input_name, selector) in pairs(declared_inputs)
                input_sym = Symbol(input_name)
                _validate_declared_scene_input_name!(application, input_sym)
                selector isa AbstractObjectMultiplicity || error(
                    "Input binding `$(input_sym)` on application `$(application.id)` must use an object selector."
                )
                _push_scene_input_binding!(
                    bindings,
                    scene,
                    application,
                    consumer_id,
                    input_sym,
                    selector,
                    get(input_origins(application.spec), input_sym, :model_spec),
                    by_object,
                    by_id,
                )
            end
            _append_inferred_scene_input_bindings!(bindings, scene, application, consumer_id, declared_inputs, by_object, by_id)
        end
    end
    return bindings
end

function _push_scene_input_binding!(
    bindings,
    scene::Scene,
    application::CompiledSceneApplication,
    consumer_id::ObjectId,
    input_sym::Symbol,
    selector::AbstractObjectMultiplicity,
    origin::Symbol,
    applications_by_object,
    applications_by_id,
    source_ids_override=nothing,
)
    source_ids = isnothing(source_ids_override) ? _dependency_object_ids(scene, selector, consumer_id) : source_ids_override
    window = _selector_window(selector)
    source_var = _selector_var(selector, input_sym)
    process_filter = _criteria_get(criteria(selector), :process, nothing)
    application_filter = _selector_application(selector)
    source_application_ids = _matching_input_source_applications(
        applications_by_object,
        source_ids,
        source_var,
        process_filter,
        application_filter,
        allow_empty=selector isa OptionalOne,
    )
    if selector isa OptionalOne &&
       (!isnothing(process_filter) || !isnothing(application_filter)) &&
       isempty(source_application_ids)
        source_ids = ObjectId[]
    end
    policy = _scene_selector_policy(selector, applications_by_id, source_application_ids, source_var)
    if policy isa PreviousTimeStep
        policy.variable == input_sym || error(
            "PreviousTimeStep marker for input `$(input_sym)` on application ",
            "`$(application.id)` names `$(policy.variable)`. Use ",
            "`PreviousTimeStep(:$(input_sym))`."
        )
    else
        _validate_policy_instance(
            _scene_object(scene, consumer_id).scale,
            application.process,
            input_sym,
            policy,
        )
    end
    carrier = _input_carrier(scene, selector, source_ids, source_var)
    carrier_hint =
        isempty(source_ids) && selector isa OptionalOne ?
        :optional_default :
        _carrier_hint(selector, policy, window)
    _validate_scene_input_source!(
        scene,
        application,
        consumer_id,
        input_sym,
        source_var,
        source_ids,
        carrier,
        carrier_hint,
    )
    push!(
        bindings,
        CompiledSceneInputBinding(
            application.id,
            consumer_id,
            input_sym,
            selector,
            origin,
            source_ids,
            source_application_ids,
            source_var,
            process_filter,
            application_filter,
            multiplicity(selector),
            policy,
            window,
            carrier_hint,
            carrier,
        ),
    )
    return bindings
end

function _scene_input_names(application::CompiledSceneApplication)
    return Symbol[Symbol(var) for var in keys(inputs_(application.spec))]
end

function _validate_scene_input_source!(
    scene::Scene,
    application::CompiledSceneApplication,
    consumer_id::ObjectId,
    input_sym::Symbol,
    source_var::Symbol,
    source_ids::Vector{ObjectId},
    carrier,
    carrier_hint::Symbol,
)
    carrier_hint == :temporal_stream && return nothing
    !isnothing(carrier) && return nothing
    status_source_ids = ObjectId[
        source_id for source_id in source_ids
        if _scene_object(scene, source_id).status isa Status
    ]
    isempty(status_source_ids) && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` for object ",
        "`$(consumer_id.value)` reads `$(source_var)` from objects ",
        "`$([id.value for id in status_source_ids])`, but no source `Status` reference is available."
    )
end

function _validate_declared_scene_input_name!(application::CompiledSceneApplication, input_sym::Symbol)
    input_names = Set(_scene_input_names(application))
    input_sym in input_names && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` is not declared by ",
        "`inputs_` for process `$(application.process)`. Declared model inputs are ",
        "`$(sort!(collect(input_names)))`."
    )
end

function _same_object_output_applications(applications_by_object, application::CompiledSceneApplication, object_id::ObjectId, variable::Symbol)
    matches = CompiledSceneApplication[]
    for candidate in get(applications_by_object, object_id, Any[])
        candidate.id == application.id && continue
        variable in _scene_canonical_output_names(candidate) || continue
        push!(matches, candidate)
    end
    return matches
end

function _append_inferred_scene_input_bindings!(
    bindings,
    scene::Scene,
    application::CompiledSceneApplication,
    consumer_id::ObjectId,
    declared_inputs,
    applications_by_object,
    applications_by_id,
)
    declared_names = declared_inputs isa NamedTuple ? Set(Symbol.(keys(declared_inputs))) : Set{Symbol}()
    for input_sym in _scene_input_names(application)
        input_sym in declared_names && continue
        matches = _same_object_output_applications(applications_by_object, application, consumer_id, input_sym)
        isempty(matches) && continue
        if length(matches) > 1
            error(
                "Input `$(input_sym)` on application `$(application.id)` for object `$(consumer_id.value)` ",
                "has ambiguous same-object producers: `$([match.id for match in matches])`. ",
                "Add `Inputs(:$(input_sym) => One(...))` to disambiguate."
            )
        end
        producer = only(matches)
        selector = One(within=Self(), process=producer.process, application=producer.id, var=input_sym)
        _push_scene_input_binding!(
            bindings,
            scene,
            application,
            consumer_id,
            input_sym,
            selector,
            :inferred_same_object,
            applications_by_object,
            applications_by_id,
            ObjectId[consumer_id],
        )
    end
    return bindings
end

function _bound_scene_inputs(input_bindings)
    bound = Set{Tuple{Symbol,ObjectId,Symbol}}()
    for binding in input_bindings
        push!(bound, (binding.application_id, binding.consumer_id, binding.input))
    end
    return bound
end

function _status_has_variable(scene::Scene, object_id::ObjectId, variable::Symbol)
    object = _scene_object(scene, object_id)
    object.status isa Status || return false
    return variable in propertynames(object.status)
end

function _validate_scene_required_inputs!(scene::Scene, applications, input_bindings)
    bound = _bound_scene_inputs(input_bindings)
    missing = NamedTuple[]
    for application in applications
        for object_id in application.target_ids
            for input in _scene_input_names(application)
                (application.id, object_id, input) in bound && continue
                _status_has_variable(scene, object_id, input) && continue
                push!(
                    missing,
                    (
                        application_id=application.id,
                        object_id=object_id.value,
                        input=input,
                        process=application.process,
                    ),
                )
            end
        end
    end
    isempty(missing) && return nothing
    details = join(
        [
            "`$(row.application_id)` on object `$(row.object_id)` requires `$(row.input)`"
            for row in missing
        ],
        "; ",
    )
    error(
        "Missing required scene/object input(s): ",
        details,
        ". Provide the variable on object `Status`, add an `Inputs(...)` binding, ",
        "or add an unambiguous same-object producer."
    )
end

function _applications_by_object(applications)
    by_object = Dict{ObjectId,Vector{Any}}()
    for application in applications
        for object_id in application.target_ids
            push!(get!(by_object, object_id, Any[]), application)
        end
    end
    return by_object
end

function _matching_callee_applications(applications, object_id::ObjectId, proc, application_name_filter)
    matches = Symbol[]
    for application in get(applications, object_id, Any[])
        isnothing(proc) || application.process == proc || continue
        isnothing(application_name_filter) || application.id == application_name_filter || continue
        push!(matches, application.id)
    end
    return matches
end

function _compile_scene_call_bindings(scene::Scene, applications)
    by_object = _applications_by_object(applications)
    bindings = CompiledSceneCallBinding[]
    for application in applications
        calls = model_calls(application.spec)
        calls isa NamedTuple || continue
        for consumer_id in application.target_ids
            for (call_name, selector) in pairs(calls)
                call_sym = Symbol(call_name)
                selector isa AbstractObjectMultiplicity || error(
                    "Call binding `$(call_sym)` on application `$(application.id)` must use an object selector."
                )
                callee_object_ids = _dependency_object_ids(scene, selector, consumer_id)
                proc = _criteria_get(criteria(selector), :process, nothing)
                app_name = _selector_application(selector)
                callee_application_ids = Symbol[]
                for object_id in callee_object_ids
                    append!(
                        callee_application_ids,
                        _matching_callee_applications(by_object, object_id, proc, app_name),
                    )
                end
                unique!(callee_application_ids)
                if isempty(callee_application_ids) && !(selector isa OptionalOne)
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` matched objects ",
                        "$([id.value for id in callee_object_ids]) but no model application",
                        isnothing(proc) ? "." : " with process `$(proc)`.",
                    )
                end
                if selector isa One && length(callee_application_ids) != 1
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` expected one callee application, ",
                        "got `$(callee_application_ids)`. Add `application=:name` to disambiguate."
                    )
                elseif selector isa OptionalOne && length(callee_application_ids) > 1
                    error(
                        "Call `$(call_sym)` on application `$(application.id)` expected zero or one callee application, ",
                        "got `$(callee_application_ids)`. Add `application=:name` to disambiguate."
                    )
                end
                push!(
                    bindings,
                    CompiledSceneCallBinding(
                        application.id,
                        consumer_id,
                        call_sym,
                        selector,
                        get(call_origins(application.spec), call_sym, :model_spec),
                        callee_object_ids,
                        callee_application_ids,
                        proc,
                        app_name,
                        multiplicity(selector),
                    ),
                )
            end
        end
    end
    return bindings
end

function _scene_call_owners(call_bindings)
    owners = Dict{Symbol,Set{Symbol}}()
    for binding in call_bindings
        for callee_id in binding.callee_application_ids
            push!(get!(owners, callee_id, Set{Symbol}()), binding.application_id)
        end
    end
    return owners
end

function _add_scene_application_edge!(children, parent::Symbol, child::Symbol)
    parent == child && return nothing
    push!(get!(children, parent, Set{Symbol}()), child)
    return nothing
end

function _scene_input_order_edges!(children, input_bindings, call_owners)
    for binding in input_bindings
        binding.policy isa PreviousTimeStep && continue
        for source_id in binding.source_application_ids
            owners = get(call_owners, source_id, nothing)
            if isnothing(owners)
                _add_scene_application_edge!(children, source_id, binding.application_id)
            else
                for owner_id in owners
                    _add_scene_application_edge!(children, owner_id, binding.application_id)
                end
            end
        end
    end
    return children
end

function _scene_update_order_edges!(children, applications)
    for indexed_writers in values(_scene_writer_groups(applications))
        length(indexed_writers) > 1 || continue
        sort!(indexed_writers; by=first)
        for index in 2:length(indexed_writers)
            previous_application = indexed_writers[index - 1][2]
            application = indexed_writers[index][2]
            _add_scene_application_edge!(children, previous_application.id, application.id)
        end
    end
    return children
end

function _stable_topological_application_order(applications, children)
    application_ids = Symbol[application.id for application in applications]
    positions = Dict(application_id => index for (index, application_id) in pairs(application_ids))
    indegree = Dict(application_id => 0 for application_id in application_ids)
    for child_ids in values(children)
        for child_id in child_ids
            indegree[child_id] = get(indegree, child_id, 0) + 1
        end
    end
    ready = Symbol[application_id for application_id in application_ids if indegree[application_id] == 0]
    order = Symbol[]
    while !isempty(ready)
        sort!(ready; by=application_id -> positions[application_id])
        application_id = popfirst!(ready)
        push!(order, application_id)
        child_ids = sort!(collect(get(children, application_id, Set{Symbol}())); by=child_id -> positions[child_id])
        for child_id in child_ids
            indegree[child_id] -= 1
            indegree[child_id] == 0 && push!(ready, child_id)
        end
    end
    if length(order) != length(application_ids)
        remaining = Symbol[application_id for application_id in application_ids if indegree[application_id] > 0]
        error(
            "Scene application dependency cycle detected among applications `$(remaining)`. ",
            "Break the same-timestep cycle with a temporal policy or revise `Inputs(...)`/`Updates(...)`."
        )
    end
    return order
end

function _compile_scene_application_order(applications, input_bindings, call_bindings)
    children = Dict{Symbol,Set{Symbol}}()
    call_owners = _scene_call_owners(call_bindings)
    _scene_input_order_edges!(children, input_bindings, call_owners)
    _scene_update_order_edges!(children, applications)
    return _stable_topological_application_order(applications, children)
end

function _ordered_scene_applications(compiled::CompiledScene)
    return [compiled.applications_by_id[application_id] for application_id in compiled.application_order]
end

function explain_scene_applications(compiled::CompiledScene)
    return [
        (
            application_id=application.id,
            process=application.process,
            name=application.name,
            target_ids=[id.value for id in application.target_ids],
            applies_to=application.applies_to,
            timestep=application.timestep,
            clock=application.clock,
            model_type=typeof(_application_default_model(application)),
            model_storage=isnothing(application.model_overrides) ? :shared_application : :per_object_override,
            model_dispatch=_application_model_dispatch(application),
            object_overrides=isnothing(application.model_overrides) ?
                             NamedTuple[] :
                             [
                                 (
                                     object_id=object_id.value,
                                     model_type=typeof(model),
                                 )
                                 for (object_id, model) in sort!(
                                     collect(application.model_overrides);
                                     by=pair -> string(first(pair).value),
                                 )
                             ],
        )
        for application in compiled.applications
    ]
end

function _application_model_dispatch(application::CompiledSceneApplication)
    isnothing(application.model_overrides) && return :concrete_shared
    override_type = valtype(typeof(application.model_overrides))
    default_type = typeof(_application_default_model(application))
    return isconcretetype(override_type) && default_type == override_type ?
           :concrete_per_object :
           :heterogeneous_per_object
end

function explain_schedule(compiled::CompiledScene)
    timeline = _scene_timeline(compiled.scene)
    manual_application_ids = _manual_call_application_ids(compiled)
    execution_positions = Dict(application_id => index for (index, application_id) in pairs(compiled.application_order))
    return [
        (
            application_id=application.id,
            process=application.process,
            execution_index=execution_positions[application.id],
            timestep=application.timestep,
            clock=application.clock,
            dt_steps=application.clock.dt,
            phase=application.clock.phase,
            dt_seconds=float(application.clock.dt) * timeline.base_step_seconds,
            target_ids=[id.value for id in application.target_ids],
            root_scheduled=!(application.id in manual_application_ids),
            manual_call_only=application.id in manual_application_ids,
        )
        for application in _ordered_scene_applications(compiled)
    ]
end

function _scene_binding_carrier_kind(binding::CompiledSceneInputBinding)
    binding.carrier_hint == :temporal_stream && return :temporal_stream
    binding.carrier_hint == :optional_default && return :optional_default
    carrier = binding.carrier
    isnothing(carrier) && return :unresolved
    carrier isa Base.RefValue && return :ref
    carrier isa RefVector && return :ref_vector
    carrier isa ObjectRefVector && return :object_ref_vector
    return :custom
end

function _scene_binding_copy_semantics(binding::CompiledSceneInputBinding)
    kind = _scene_binding_carrier_kind(binding)
    kind in (:ref, :ref_vector, :object_ref_vector) && return :live_references
    kind == :temporal_stream && return :materialized_temporal_value
    kind == :optional_default && return :consumer_default
    kind == :unresolved && return :not_materialized
    return :backend_defined
end

function explain_bindings(compiled::CompiledScene)
    return [
        (
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            input=binding.input,
            origin=binding.origin,
            source_ids=[id.value for id in binding.source_ids],
            source_application_ids=binding.source_application_ids,
            source_var=binding.source_var,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            policy=binding.policy,
            window=binding.window,
            carrier_hint=binding.carrier_hint,
            carrier_kind=_scene_binding_carrier_kind(binding),
            copy_semantics=_scene_binding_copy_semantics(binding),
            has_reference_carrier=has_reference_carrier(binding),
            carrier_type=isnothing(binding.carrier) ? nothing : typeof(binding.carrier),
            selector=binding.selector,
        )
        for binding in compiled.input_bindings
    ]
end

function explain_calls(compiled::CompiledScene)
    return [
        (
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            call=binding.call,
            origin=binding.origin,
            callee_object_ids=[id.value for id in binding.callee_object_ids],
            callee_application_ids=binding.callee_application_ids,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            publication_policy=:explicit_accept,
            default_publish=false,
            accepted_publish=true,
            resolved=!isempty(binding.callee_application_ids),
            selector=binding.selector,
        )
        for binding in compiled.call_bindings
    ]
end

function explain_model_bundles(compiled::CompiledScene)
    return [
        (
            application_id=application_id,
            object_id=object_id.value,
            processes=collect(keys(models)),
            model_types=[typeof(model) for model in values(models)],
        )
        for ((application_id, object_id), models) in sort!(
            collect(compiled.model_bundles_by_target);
            by=pair -> (string(first(pair)[1]), string(first(pair)[2].value)),
        )
    ]
end

function explain_writers(compiled::CompiledScene)
    groups = _scene_writer_groups(compiled.applications, _manual_call_application_ids(compiled))
    rows = NamedTuple[]
    for ((object_id, variable), indexed_writers) in groups
        sort!(indexed_writers; by=first)
        applications = [application for (_, application) in indexed_writers]
        push!(
            rows,
            (
                object_id=object_id.value,
                variable=variable,
                application_ids=[application.id for application in applications],
                processes=[application.process for application in applications],
                update_application_ids=[
                    application.id for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                update_after=[
                    application.id => _update_after_labels(application.spec, variable)
                    for application in applications
                    if !isempty(_matching_updates(application.spec, variable))
                ],
                duplicate=length(applications) > 1,
            ),
        )
    end
    sort!(rows; by=row -> (string(row.object_id), string(row.variable)))
    return rows
end

function _environment_config_payload(config)
    config isa EnvironmentConfig && return config.config
    return config
end

function _environment_backend_from_config(scene::Scene, config)
    payload = _environment_config_payload(config)
    isnothing(payload) && return environment_backend(scene.environment)
    payload isa NamedTuple && haskey(payload, :backend) && return environment_backend(payload.backend)
    payload isa AbstractEnvironmentBackend && return payload
    return environment_backend(scene.environment)
end

function _environment_provider_from_config(config, backend)
    payload = _environment_config_payload(config)
    payload isa NamedTuple && haskey(payload, :provider) && return Symbol(payload.provider)
    payload isa Symbol && return payload
    isnothing(backend) && return :none
    return :scene
end

function _object_environment_support(application::CompiledSceneApplication, object::Object)
    scale = isnothing(object.scale) ? :Default : object.scale
    return EnvironmentSupport(application.id, scale, application.process, object.status)
end

bind_environment(backend, object::Object, support, config=nothing) = :global

function _environment_binding_object(scene::Scene, object::Object)
    !isnothing(geometry(object)) && return object, object.id, :self
    ancestor_id = object.parent
    while !isnothing(ancestor_id)
        ancestor = _scene_object(scene, ancestor_id)
        if !isnothing(geometry(ancestor))
            proxy = Object(
                object.id;
                scale=object.scale,
                kind=object.kind,
                species=object.species,
                name=object.name,
                parent=object.parent,
                children=object.children,
                geometry=geometry(ancestor),
                status=object.status,
                applications=object.applications,
            )
            return proxy, ancestor.id, :ancestor
        end
        ancestor_id = ancestor.parent
    end
    return object, nothing, :global
end

function _scene_environment_entities(scene::Scene)
    return [
        (
            id=object.id.value,
            object=object,
            scale=object.scale,
            kind=object.kind,
            species=object.species,
            name=object.name,
            parent=isnothing(object.parent) ? nothing : object.parent.value,
            geometry=geometry(object),
            position=position(object),
            bounds=bounds(object),
            status=object.status,
        )
        for object in scene_objects(scene)
    ]
end

function _scene_environment_backends(scene::Scene, compiled::CompiledScene)
    backends = Any[]
    seen = Set{UInt}()
    for application in compiled.applications
        backend = _environment_backend_from_config(scene, environment_config(application.spec))
        isnothing(backend) && continue
        id = objectid(backend)
        id in seen && continue
        push!(seen, id)
        push!(backends, backend)
    end
    return backends
end

function _update_scene_environment_indices!(scene::Scene, compiled::CompiledScene)
    entities = _scene_environment_entities(scene)
    for backend in _scene_environment_backends(scene, compiled)
        update_index!(backend, entities)
    end
    return nothing
end

function _environment_variable_names(vars)
    return Symbol[Symbol(var) for var in keys(vars)]
end

function _environment_source_variable_names(model_spec)
    return Symbol[Symbol(source) for (_, source) in _environment_sampling_rules(model_spec)]
end

function _compile_environment_bindings_for_applications(scene::Scene, applications)
    bindings = CompiledEnvironmentBinding[]
    for application in applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(scene, config)
        provider = _environment_provider_from_config(config, backend)
        required_inputs = _environment_variable_names(meteo_inputs_(application.spec))
        source_inputs = _environment_source_variable_names(application.spec)
        produced_outputs = _environment_variable_names(meteo_outputs_(application.spec))
        for object_id in application.target_ids
            object = _scene_object(scene, object_id)
            support = _object_environment_support(application, object)
            binding_object, geometry_source_object_id, geometry_source =
                _environment_binding_object(scene, object)
            cell = bind_environment(
                backend,
                binding_object,
                support,
                _environment_config_payload(config),
            )
            push!(
                bindings,
                CompiledEnvironmentBinding(
                    application.id,
                    object_id,
                    provider,
                    backend,
                    cell,
                    required_inputs,
                    source_inputs,
                    produced_outputs,
                    support,
                    geometry_source_object_id,
                    geometry_source,
                    config,
                ),
            )
        end
    end
    return bindings
end

_compile_environment_bindings(scene::Scene, compiled::CompiledScene) =
    _compile_environment_bindings_for_applications(scene, compiled.applications)

function _validate_scene_environment_inputs!(bindings, applications_by_id)
    missing_rows = NamedTuple[]
    for binding in bindings
        available = environment_variables(binding.backend)
        isnothing(available) && continue
        application = applications_by_id[binding.application_id]
        for (target, source) in _environment_sampling_rules(application.spec)
            source in available && continue
            push!(
                missing_rows,
                (
                    application_id=binding.application_id,
                    object_id=binding.object_id.value,
                    process=application.process,
                    target=target,
                    source=source,
                    available=Tuple(sort!(collect(available); by=string)),
                ),
            )
        end
    end
    isempty(missing_rows) && return nothing
    details = join(
        [
            string(
                row.application_id,
                "/",
                row.object_id,
                " (",
                row.process,
                ") needs `",
                row.target,
                "` from source `",
                row.source,
                "`; available=",
                row.available,
            )
            for row in missing_rows
        ],
        "; ",
    )
    error("Scene environment is missing required meteo inputs: ", details)
end

function _scene_environment_samplers(bindings)
    samplers_by_application = Dict{Symbol,Any}()
    prepared_sources = Tuple{Any,Any}[]
    for binding in bindings
        haskey(samplers_by_application, binding.application_id) && continue
        binding.backend isa GlobalConstant || continue
        meteo = environment_meteo(binding.backend)
        source_index = findfirst(entry -> entry[1] === meteo, prepared_sources)
        sampler = if isnothing(source_index)
            prepared = _prepare_meteo_sampler(meteo)
            push!(prepared_sources, (meteo, prepared))
            prepared
        else
            prepared_sources[source_index][2]
        end
        samplers_by_application[binding.application_id] = sampler
    end
    return samplers_by_application
end

function _compiled_environment_bindings(
    scene::Scene,
    bindings,
    by_target,
    samplers_by_application=_scene_environment_samplers(bindings),
    sample_cache=Dict{Tuple{Symbol,Int},Any}(),
)
    return CompiledEnvironmentBindings(
        scene,
        bindings,
        by_target,
        samplers_by_application,
        sample_cache,
        scene.revision,
        scene.environment_revision,
    )
end

function compile_environment_bindings(scene::Scene, compiled::CompiledScene=refresh_bindings!(scene))
    _update_scene_environment_indices!(scene, compiled)
    bindings = _compile_environment_bindings(scene, compiled)
    _validate_scene_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = Dict(
        (binding.application_id, binding.object_id) => binding
        for binding in bindings
    )
    length(by_target) == length(bindings) || error(
        "Environment binding compilation produced duplicate `(application_id, object_id)` targets."
    )
    return _compiled_environment_bindings(scene, bindings, by_target)
end

function _same_environment_backend(a, b)
    a === b && return true
    if a isa GlobalConstant && b isa GlobalConstant
        return environment_meteo(a) === environment_meteo(b)
    end
    return false
end

function _same_environment_support(a, b)
    return a.domain == b.domain &&
           a.scale == b.scale &&
           a.process == b.process &&
           a.status === b.status
end

function _reconcile_environment_binding_metadata(
    scene::Scene,
    compiled::CompiledScene,
    cached::CompiledEnvironmentBindings,
)
    expected_count = sum(length(application.target_ids) for application in compiled.applications)
    expected_count == length(cached.bindings) || return nothing

    bindings = CompiledEnvironmentBinding[]
    changed = false
    for application in compiled.applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(scene, config)
        provider = _environment_provider_from_config(config, backend)
        required_inputs = _environment_variable_names(meteo_inputs_(application.spec))
        source_inputs = _environment_source_variable_names(application.spec)
        produced_outputs = _environment_variable_names(meteo_outputs_(application.spec))
        for object_id in application.target_ids
            key = (application.id, object_id)
            old = get(cached.by_target, key, nothing)
            isnothing(old) && return nothing
            object = _scene_object(scene, object_id)
            support = _object_environment_support(application, object)
            _, geometry_source_object_id, geometry_source =
                _environment_binding_object(scene, object)
            _same_environment_backend(old.backend, backend) || return nothing
            old.provider == provider || return nothing
            isequal(old.config, config) || return nothing
            old.geometry_source_object_id == geometry_source_object_id ||
                return nothing
            old.geometry_source == geometry_source || return nothing
            _same_environment_support(old.support, support) || return nothing

            if old.required_inputs == required_inputs &&
               old.source_inputs == source_inputs &&
               old.produced_outputs == produced_outputs
                push!(bindings, old)
            else
                changed = true
                push!(
                    bindings,
                    CompiledEnvironmentBinding(
                        application.id,
                        object_id,
                        provider,
                        backend,
                        old.cell,
                        required_inputs,
                        source_inputs,
                        produced_outputs,
                        support,
                        geometry_source_object_id,
                        geometry_source,
                        config,
                    ),
                )
            end
        end
    end
    changed || return cached
    _validate_scene_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = Dict(
        (binding.application_id, binding.object_id) => binding
        for binding in bindings
    )
    return _compiled_environment_bindings(scene, bindings, by_target)
end

function _refresh_environment_bindings_for_objects(
    scene::Scene,
    compiled::CompiledScene,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    _update_scene_environment_indices!(scene, compiled)
    dirty = Set(dirty_object_ids)
    replacements = Dict{Tuple{Symbol,ObjectId},CompiledEnvironmentBinding}()
    for application in compiled.applications
        selected_ids = ObjectId[id for id in application.target_ids if id in dirty]
        isempty(selected_ids) && continue
        partial_application = CompiledSceneApplication(
            application.id,
            application.spec,
            application.process,
            application.name,
            selected_ids,
            application.applies_to,
            application.timestep,
            application.clock,
            application.model_overrides,
        )
        for binding in _compile_environment_bindings_for_applications(scene, (partial_application,))
            replacements[(binding.application_id, binding.object_id)] = binding
        end
    end
    bindings = CompiledEnvironmentBinding[
        get(replacements, (binding.application_id, binding.object_id), binding)
        for binding in cached.bindings
    ]
    _validate_scene_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = Dict(
        (binding.application_id, binding.object_id) => binding for binding in bindings
    )
    return _compiled_environment_bindings(
        scene,
        bindings,
        by_target,
        cached.samplers_by_application,
        cached.sample_cache,
    )
end

function explain_environment_bindings(compiled::CompiledEnvironmentBindings)
    return [
        (
            application_id=binding.application_id,
            object_id=binding.object_id.value,
            provider=binding.provider,
            backend_type=isnothing(binding.backend) ? nothing : typeof(binding.backend),
            cell=binding.cell,
            required_inputs=binding.required_inputs,
            source_inputs=binding.source_inputs,
            produced_outputs=binding.produced_outputs,
            temporal_sampler=!isnothing(
                get(compiled.samplers_by_application, binding.application_id, nothing),
            ),
            geometry_source_object_id=isnothing(binding.geometry_source_object_id) ?
                                      nothing : binding.geometry_source_object_id.value,
            geometry_source=binding.geometry_source,
            support=binding.support,
            config=binding.config,
        )
        for binding in compiled.bindings
    ]
end

function explain_environment_bindings(scene::Scene)
    return explain_environment_bindings(refresh_environment_bindings!(scene))
end

struct SceneOutputRetentionPlan
    retain_all::Bool
    temporal_dependencies::Set{Tuple{Symbol,Symbol}}
    requested_outputs::Set{Tuple{Symbol,Symbol}}
    dependency_horizons::Dict{Tuple{Symbol,Symbol},Float64}
end

struct SceneRunContext{CS,EB,A,TS,OR,C}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::ObjectId
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
end

struct SceneCallTarget{CS,EB,A,S,TS,OR,C}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::ObjectId
    model
    status::S
    temporal_streams::TS
    output_retention::OR
    time::Float64
    constants::C
end

abstract type AbstractSceneExecutionBatch end

struct CompiledSceneExecutionTarget{M,S,MB,IB,EB}
    object_id::ObjectId
    model::M
    status::S
    models::MB
    input_bindings::IB
    environment_binding::EB
end

struct CompiledSceneExecutionBatch{A,T<:AbstractVector} <: AbstractSceneExecutionBatch
    application::A
    targets::T
end

struct CompiledSceneExecutionPlan{B}
    batches::B
    scene_revision::Int
    environment_revision::Int
end

struct SceneSimulation{S,CS,EB,EP,OR,TS,R}
    scene::S
    compiled::CS
    environment_bindings::EB
    execution_plan::EP
    output_retention::OR
    temporal_streams::TS
    output_requests::R
end

scene_outputs(sim::SceneSimulation) = sim.temporal_streams

function _compiled_application_by_id(compiled::CompiledScene, id::Symbol)
    application = get(compiled.applications_by_id, id, nothing)
    isnothing(application) && error("No compiled scene application with id `$(id)`.")
    return application
end

function _environment_binding_for(env_bindings::CompiledEnvironmentBindings, application_id::Symbol, object_id::ObjectId)
    return get(env_bindings.by_target, (application_id, object_id), nothing)
end

function _scene_object_status(scene::Scene, object_id::ObjectId)
    object = _scene_object(scene, object_id)
    object.status isa Status || error(
        "Scene object `$(object_id.value)` has no `Status`; scene runtime requires status-backed objects."
    )
    return object.status
end

function _set_status_if_present!(status::Status, variable::Symbol, value)
    variable in propertynames(status) || error(
        "Cannot materialize input `$(variable)` because consumer status has no such variable."
    )
    status[variable] = value
    return status
end

_scene_stream_key(application_id::Symbol, object_id::ObjectId, variable::Symbol) =
    (application_id, object_id, variable)

function _scene_retain_output(
    retention::SceneOutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
)
    retention.retain_all && return true
    key = (application_id, variable)
    return key in retention.temporal_dependencies ||
           key in retention.requested_outputs
end

_scene_retain_output(::Nothing, application_id::Symbol, variable::Symbol) = true

function _scene_prune_dependency_stream!(
    samples,
    retention::SceneOutputRetentionPlan,
    application_id::Symbol,
    variable::Symbol,
    time::Real,
)
    retention.retain_all && return samples
    key = (application_id, variable)
    key in retention.requested_outputs && return samples
    key in retention.temporal_dependencies || return samples
    horizon = get(retention.dependency_horizons, key, 0.0)
    if horizon <= 0.0
        length(samples) > 1 && deleteat!(samples, 1:(length(samples) - 1))
        return samples
    end
    cutoff = float(time) - horizon + 1.0
    filter!(sample -> sample[1] >= cutoff - 1.0e-8, samples)
    return samples
end

_scene_prune_dependency_stream!(samples, ::Nothing, application_id, variable, time) =
    samples

function _scene_publish_outputs!(
    streams,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    status,
    time::Real,
    retention=nothing,
)
    isnothing(streams) && return nothing
    for variable in keys(outputs_(application.spec))
        var = Symbol(variable)
        _scene_retain_output(retention, application.id, var) || continue
        hasproperty(status, var) || error(
            "Application `$(application.id)` declares output `$(var)`, but object ",
            "`$(object_id.value)` status has no such variable."
        )
        key = _scene_stream_key(application.id, object_id, var)
        value = getproperty(status, var)
        samples = get(streams, key, nothing)
        if isnothing(samples)
            samples = Tuple{Float64,typeof(value)}[]
            streams[key] = samples
        elseif !(value isa fieldtype(eltype(samples), 2))
            error(
                "Output `$(application.id).$(var)` on object `$(object_id.value)` changed ",
                "value type from `$(fieldtype(eltype(samples), 2))` to `$(typeof(value))`. ",
                "Scene temporal streams require a stable output type."
            )
        end
        filter!(sample -> !isapprox(sample[1], float(time); atol=1.0e-8, rtol=0.0), samples)
        push!(samples, (float(time), value))
        _scene_prune_dependency_stream!(
            samples,
            retention,
            application.id,
            var,
            time,
        )
    end
    return nothing
end

function _scene_latest_sample(samples, time::Real)
    latest = nothing
    latest_t = -Inf
    for (sample_t, value) in samples
        sample_t <= float(time) || continue
        sample_t >= latest_t || continue
        latest = value
        latest_t = sample_t
    end
    return latest
end

function _scene_linear_value(v_left, v_right, α)
    applicable(-, v_right, v_left) || return nothing
    delta = v_right - v_left
    increment = if applicable(*, α, delta)
        α * delta
    elseif applicable(*, delta, α)
        delta * α
    else
        return nothing
    end
    applicable(+, v_left, increment) || return nothing
    return v_left + increment
end

function _scene_interpolated_sample(samples, time::Real, policy::Interpolate)
    isempty(samples) && return nothing
    t = float(time)
    prev_idx = findlast(sample -> sample[1] <= t + 1.0e-8, samples)
    next_idx = findfirst(sample -> sample[1] >= t - 1.0e-8, samples)

    if !isnothing(prev_idx) && !isnothing(next_idx)
        t_prev, v_prev = samples[prev_idx]
        t_next, v_next = samples[next_idx]
        isapprox(t_prev, t_next; atol=1.0e-8, rtol=0.0) && return v_prev
        policy.mode == :hold && return v_prev
        α = (t - t_prev) / (t_next - t_prev)
        interpolated = _scene_linear_value(v_prev, v_next, α)
        return isnothing(interpolated) ? v_prev : interpolated
    end

    if !isnothing(prev_idx)
        t_last, v_last = samples[prev_idx]
        if policy.extrapolation == :linear && prev_idx >= 2
            t_prev, v_prev = samples[prev_idx - 1]
            if !isapprox(t_last, t_prev; atol=1.0e-8, rtol=0.0)
                α = (t - t_last) / (t_last - t_prev)
                extrapolated = _scene_linear_value(v_prev, v_last, one(α) + α)
                !isnothing(extrapolated) && return extrapolated
            end
        end
        return v_last
    end

    return first(samples)[2]
end

function _scene_window_samples(samples, t_start::Real, t_end::Real)
    return [value for (sample_t, value) in samples if float(t_start) <= sample_t <= float(t_end)]
end

function _scene_window_reduce(values, durations, policy)
    isempty(values) && return 0.0
    reducer = policy isa Integrate ? policy.reducer : (policy isa Aggregate ? policy.reducer : PlantMeteo.SumReducer())
    f = _normalize_policy_reducer(reducer)
    applicable(f, values, durations) && return f(values, durations)
    applicable(f, values) && return f(values)
    reducer isa PlantMeteo.SumReducer && return sum(values)
    reducer isa PlantMeteo.MeanReducer && return Statistics.mean(values)
    reducer isa PlantMeteo.MinReducer && return minimum(values)
    reducer isa PlantMeteo.MaxReducer && return maximum(values)
    reducer isa PlantMeteo.FirstReducer && return first(values)
    reducer isa PlantMeteo.LastReducer && return last(values)
    error(
        "Reducer `$(reducer)` is not callable on scene temporal input values for policy ",
        "`$(typeof(policy))`. Expected `(values)` or `(values, durations_seconds)`."
    )
end

function _scene_duration_steps(duration, timeline)
    if duration isa Dates.Period || duration isa Dates.CompoundPeriod || duration isa Real
        seconds = _duration_to_seconds(duration)
        isnothing(seconds) && return nothing
        steps = seconds / timeline.base_step_seconds
        steps >= 1.0 || error(
            "Input window `$(duration)` is shorter than the scene base step ",
            "($(timeline.base_step_seconds) seconds)."
        )
        return steps
    end
    return nothing
end

function _scene_input_window_steps(binding::CompiledSceneInputBinding, application::CompiledSceneApplication, timeline)
    explicit = _scene_duration_steps(binding.window, timeline)
    !isnothing(explicit) && return explicit
    binding.policy isa Union{Integrate,Aggregate} && return float(application.clock.dt)
    return 1.0
end

function _scene_temporal_source_value(
    streams,
    application_id::Symbol,
    source_id::ObjectId,
    source_var::Symbol,
    time::Real,
    policy,
    t_start::Real,
    timeline,
)
    samples = get(streams, _scene_stream_key(application_id, source_id, source_var), nothing)
    isnothing(samples) && return policy isa Union{Integrate,Aggregate} ? 0.0 : nothing
    if policy isa HoldLast
        return _scene_latest_sample(samples, time)
    elseif policy isa PreviousTimeStep
        return _scene_latest_sample(samples, float(time) - 1.0)
    elseif policy isa Union{Integrate,Aggregate}
        values = _scene_window_samples(samples, t_start, time)
        durations = fill(timeline.base_step_seconds, length(values))
        return _scene_window_reduce(values, durations, policy)
    elseif policy isa Interpolate
        return _scene_interpolated_sample(samples, time, policy)
    end
    error("Unsupported scene temporal input policy `$(typeof(policy))`.")
end

function _scene_temporal_source_application(compiled::CompiledScene, binding::CompiledSceneInputBinding, source_id::ObjectId)
    isempty(binding.source_application_ids) && error(
        "Temporal scene input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
        "has no resolved source application. Add `process=` or `application=` to `Inputs(...)`."
    )
    matches = Symbol[
        application_id for application_id in binding.source_application_ids
        if source_id in _compiled_application_by_id(compiled, application_id).target_ids
    ]
    if length(matches) == 1
        return only(matches)
    elseif isempty(matches)
        error(
            "Temporal scene input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
            "has no source application matching object `$(source_id.value)`."
        )
    end
    error(
        "Temporal scene input `$(binding.input)` from `$(source_id.value).$(binding.source_var)` ",
        "has ambiguous source applications `$(matches)`. Add `application=...` to `Inputs(...)`."
    )
end

function _scene_temporal_input_value(
    compiled::CompiledScene,
    binding::CompiledSceneInputBinding,
    application::CompiledSceneApplication,
    status::Status,
    streams,
    time::Real,
    timeline,
)
    window_steps = _scene_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    initial = status[binding.input]
    if binding.multiplicity == :many
        values = [
            _scene_temporal_source_value(
                streams,
                _scene_temporal_source_application(compiled, binding, source_id),
                source_id,
                binding.source_var,
                time,
                binding.policy,
                t_start,
                timeline,
            )
            for source_id in binding.source_ids
        ]
        if binding.policy isa PreviousTimeStep
            initial_values = initial isa AbstractVector ? initial : ()
            return [
                isnothing(value) && index <= length(initial_values) ? initial_values[index] : value
                for (index, value) in pairs(values)
            ]
        end
        return values
    end
    source_id = only(binding.source_ids)
    value = _scene_temporal_source_value(
        streams,
        _scene_temporal_source_application(compiled, binding, source_id),
        source_id,
        binding.source_var,
        time,
        binding.policy,
        t_start,
        timeline,
    )
    isnothing(value) && binding.policy isa PreviousTimeStep && return initial
    isnothing(value) && error(
        "No temporal scene value available for input `$(binding.input)` from ",
        "`$(source_id.value).$(binding.source_var)` at t=$(time)."
    )
    return value
end

function _scene_temporal_input_value(
    compiled::CompiledScene,
    binding::CompiledSceneInputBinding,
    application::CompiledSceneApplication,
    streams,
    time::Real,
    timeline,
)
    status = _scene_object_status(compiled.scene, binding.consumer_id)
    return _scene_temporal_input_value(
        compiled,
        binding,
        application,
        status,
        streams,
        time,
        timeline,
    )
end

function _scene_assign_input_value!(status::Status, variable::Symbol, value)
    variable in propertynames(status) || error(
        "Cannot materialize input `$(variable)` because consumer status has no such variable."
    )
    current = status[variable]
    if current isa RefVector && value isa AbstractVector
        length(current) != length(value) && resize!(current, length(value))
        for i in eachindex(value)
            current[i] = value[i]
        end
        return status
    end
    status[variable] = value
    return status
end

function _materialize_scene_inputs!(
    compiled::CompiledScene,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    streams=nothing,
    time::Real=1,
)
    status = _scene_object_status(compiled.scene, object_id)
    bindings = get(compiled.input_bindings_by_target, (application.id, object_id), ())
    timeline = nothing
    for binding in bindings
        if binding.carrier_hint == :temporal_stream
            isnothing(streams) && continue
            isnothing(timeline) && (timeline = _scene_timeline(compiled.scene))
            value = _scene_temporal_input_value(
                compiled,
                binding,
                application,
                status,
                streams,
                time,
                timeline,
            )
            _scene_assign_input_value!(status, binding.input, value)
        end
    end
    return status
end

function _materialize_scene_inputs!(
    status::Status,
    bindings::Tuple,
    compiled::CompiledScene,
    application::CompiledSceneApplication,
    streams=nothing,
    time::Real=1,
)
    timeline = nothing
    for binding in bindings
        if binding.carrier_hint == :temporal_stream
            isnothing(streams) && continue
            isnothing(timeline) && (timeline = _scene_timeline(compiled.scene))
            value = _scene_temporal_input_value(
                compiled,
                binding,
                application,
                status,
                streams,
                time,
                timeline,
            )
            _scene_assign_input_value!(status, binding.input, value)
        end
    end
    return status
end

function _scene_meteo_for_model(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    time::Real,
)
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _scene_meteo_for_binding(env_bindings, application, binding, time)
end

function _scene_meteo_for_binding(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    binding,
    time::Real,
)
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    if binding.backend isa GlobalConstant
        sampler = get(env_bindings.samplers_by_application, application.id, nothing)
        if !isnothing(sampler)
            step = Int(round(time))
            key = (application.id, step)
            haskey(env_bindings.sample_cache, key) &&
                return env_bindings.sample_cache[key]
            meteo = environment_meteo(binding.backend)
            raw_row = _meteo_row_at_step(meteo, step)
            sampled = _sample_meteo_for_model(
                sampler,
                raw_row,
                step,
                application.clock,
                application.spec,
            )
            env_bindings.sample_cache[key] = sampled
            return sampled
        end
    end
    return sample_environment(binding.backend, binding.support, time, application.spec)
end

function _scatter_scene_environment_outputs!(
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    status,
    time::Real,
)
    isempty(keys(meteo_outputs_(application.spec))) && return nothing
    binding = _environment_binding_for(env_bindings, application.id, object_id)
    return _scatter_scene_environment_outputs!(
        application,
        binding,
        status,
        time,
    )
end

function _scatter_scene_environment_outputs!(
    application::CompiledSceneApplication,
    binding,
    status,
    time::Real,
)
    isempty(keys(meteo_outputs_(application.spec))) && return nothing
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    return scatter_environment_outputs!(binding.backend, binding.support, time, application.spec, status)
end

function _push_scene_model_entry!(pairs, names::Set{Symbol}, name::Symbol, model)
    name in names && return nothing
    push!(pairs, name => model)
    push!(names, name)
    return nothing
end

function _append_scene_model_dependencies!(
    pairs,
    names::Set{Symbol},
    applications_by_id,
    call_bindings_by_target,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    seen::Set{Tuple{Symbol,ObjectId}},
)
    key = (application.id, object_id)
    key in seen && return nothing
    push!(seen, key)
    _push_scene_model_entry!(
        pairs,
        names,
        application.process,
        _application_model(application, object_id),
    )
    bindings = get(call_bindings_by_target, key, ())
    for binding in bindings
        for application_id in binding.callee_application_ids
            callee_application = get(applications_by_id, application_id, nothing)
            isnothing(callee_application) && error(
                "No compiled scene application with id `$(application_id)`."
            )
            matching_object_ids = ObjectId[
                callee_object_id for callee_object_id in binding.callee_object_ids
                if callee_object_id in callee_application.target_ids
            ]
            # Old-style hard-dependency kernels expect one model object per
            # process field. Multi-object scene calls are exposed through
            # `call_targets(extra, name)` instead.
            length(matching_object_ids) == 1 || continue
            _append_scene_model_dependencies!(
                pairs,
                names,
                applications_by_id,
                call_bindings_by_target,
                callee_application,
                only(matching_object_ids),
                seen,
            )
        end
    end
    return nothing
end

function _compile_scene_model_bundle(
    applications_by_id,
    call_bindings_by_target,
    application::CompiledSceneApplication,
    object_id::ObjectId,
)
    pairs = Pair{Symbol,Any}[]
    names = Set{Symbol}()
    seen = Set{Tuple{Symbol,ObjectId}}()
    _append_scene_model_dependencies!(
        pairs,
        names,
        applications_by_id,
        call_bindings_by_target,
        application,
        object_id,
        seen,
    )
    return NamedTuple{Tuple(first(pair) for pair in pairs)}(Tuple(last(pair) for pair in pairs))
end

function _compile_scene_model_bundles(applications, applications_by_id, call_bindings_by_target)
    bundles = Dict{Tuple{Symbol,ObjectId},Any}()
    for application in applications
        for object_id in application.target_ids
            bundles[(application.id, object_id)] = _compile_scene_model_bundle(
                applications_by_id,
                call_bindings_by_target,
                application,
                object_id,
            )
        end
    end
    return bundles
end

function _scene_models_for_application(
    compiled::CompiledScene,
    application::CompiledSceneApplication,
    object_id::ObjectId,
)
    key = (application.id, object_id)
    models = get(compiled.model_bundles_by_target, key, nothing)
    isnothing(models) && error(
        "No compiled model bundle for application `$(application.id)` on object `$(object_id.value)`."
    )
    return models
end

function _run_scene_application!(
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    object_id::ObjectId;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
    publish::Bool=true,
    meteo=nothing,
)
    status = _materialize_scene_inputs!(compiled, application, object_id, temporal_streams, time)
    meteo_value = isnothing(meteo) ? _scene_meteo_for_model(env_bindings, application, object_id, time) : meteo
    context = SceneRunContext(
        compiled,
        env_bindings,
        application,
        object_id,
        temporal_streams,
        output_retention,
        float(time),
        constants,
    )
    model = _application_model(application, object_id)
    models = _scene_models_for_application(compiled, application, object_id)
    run!(model, models, status, meteo_value, constants, context)
    if publish
        _scatter_scene_environment_outputs!(env_bindings, application, object_id, status, time)
        _scene_publish_outputs!(
            temporal_streams,
            application,
            object_id,
            status,
            time,
            output_retention,
        )
    end
    return status
end

function _run_scene_execution_target!(
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    target::CompiledSceneExecutionTarget;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
)
    status = _materialize_scene_inputs!(
        target.status,
        target.input_bindings,
        compiled,
        application,
        temporal_streams,
        time,
    )
    meteo = _scene_meteo_for_binding(
        env_bindings,
        application,
        target.environment_binding,
        time,
    )
    context = SceneRunContext(
        compiled,
        env_bindings,
        application,
        target.object_id,
        temporal_streams,
        output_retention,
        float(time),
        constants,
    )
    run!(target.model, target.models, status, meteo, constants, context)
    _scatter_scene_environment_outputs!(
        application,
        target.environment_binding,
        status,
        time,
    )
    _scene_publish_outputs!(
        temporal_streams,
        application,
        target.object_id,
        status,
        time,
        output_retention,
    )
    return status
end

function _run_scene_execution_batch!(
    batch::CompiledSceneExecutionBatch,
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    output_retention=nothing,
)
    _scene_application_should_run(batch.application, time) || return nothing
    for target in batch.targets
        _run_scene_execution_target!(
            compiled,
            env_bindings,
            batch.application,
            target;
            time=time,
            constants=constants,
            temporal_streams=temporal_streams,
            output_retention=output_retention,
        )
    end
    return nothing
end

_scene_application_should_run(application::CompiledSceneApplication, t::Real) =
    _should_run_at_time(application.clock, float(t))

function _manual_call_application_ids(compiled::CompiledScene)
    ids = Set{Symbol}()
    for binding in compiled.call_bindings
        union!(ids, binding.callee_application_ids)
    end
    return ids
end

function _compiled_scene_execution_target(
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    object_id::ObjectId,
)
    status = _scene_object_status(compiled.scene, object_id)
    model = _application_model(application, object_id)
    models = _scene_models_for_application(compiled, application, object_id)
    input_bindings = get(
        compiled.input_bindings_by_target,
        (application.id, object_id),
        (),
    )
    environment_binding = _environment_binding_for(
        env_bindings,
        application.id,
        object_id,
    )
    return CompiledSceneExecutionTarget(
        object_id,
        model,
        status,
        models,
        input_bindings,
        environment_binding,
    )
end

function _typed_scene_execution_targets(targets, first_index::Int, last_index::Int)
    target_type = typeof(targets[first_index])
    typed = Vector{target_type}(undef, last_index - first_index + 1)
    for (destination, source) in enumerate(first_index:last_index)
        typed[destination] = targets[source]
    end
    return typed
end

function _append_scene_execution_batches!(
    batches,
    application::CompiledSceneApplication,
    targets,
)
    isempty(targets) && return batches
    first_index = firstindex(targets)
    target_type = typeof(targets[first_index])
    for index in (first_index + 1):lastindex(targets)
        typeof(targets[index]) == target_type && continue
        push!(
            batches,
            CompiledSceneExecutionBatch(
                application,
                _typed_scene_execution_targets(targets, first_index, index - 1),
            ),
        )
        first_index = index
        target_type = typeof(targets[index])
    end
    push!(
        batches,
        CompiledSceneExecutionBatch(
            application,
            _typed_scene_execution_targets(targets, first_index, lastindex(targets)),
        ),
    )
    return batches
end

function compile_scene_execution_plan(
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings,
)
    manual_application_ids = _manual_call_application_ids(compiled)
    batches = AbstractSceneExecutionBatch[]
    for application in _ordered_scene_applications(compiled)
        application.id in manual_application_ids && continue
        targets = Any[
            _compiled_scene_execution_target(
                compiled,
                env_bindings,
                application,
                object_id,
            )
            for object_id in application.target_ids
        ]
        _append_scene_execution_batches!(batches, application, targets)
    end
    return CompiledSceneExecutionPlan(
        batches,
        compiled.revision,
        env_bindings.environment_revision,
    )
end

function explain_execution_plan(plan::CompiledSceneExecutionPlan)
    return [
        (
            batch_index=index,
            application_id=batch.application.id,
            process=batch.application.process,
            object_ids=[target.object_id.value for target in batch.targets],
            batch_size=length(batch.targets),
            target_type=eltype(batch.targets),
            model_type=fieldtype(eltype(batch.targets), :model),
            status_type=fieldtype(eltype(batch.targets), :status),
            model_bundle_type=fieldtype(eltype(batch.targets), :models),
            input_bindings_type=fieldtype(eltype(batch.targets), :input_bindings),
            environment_binding_type=fieldtype(
                eltype(batch.targets),
                :environment_binding,
            ),
            inner_loop_dispatch=:concrete_homogeneous_batch,
        )
        for (index, batch) in pairs(plan.batches)
    ]
end

function explain_execution_plan(sim::SceneSimulation)
    return explain_execution_plan(sim.execution_plan)
end

function explain_execution_plan(scene::Scene)
    compiled = refresh_bindings!(scene)
    environment_bindings = refresh_environment_bindings!(scene, compiled)
    return explain_execution_plan(
        compile_scene_execution_plan(compiled, environment_bindings),
    )
end

function compile_scene_output_retention(
    compiled::CompiledScene,
    output_requests;
    retain_all::Bool=false,
)
    temporal_dependencies = Set{Tuple{Symbol,Symbol}}()
    dependency_horizons = Dict{Tuple{Symbol,Symbol},Float64}()
    timeline = _scene_timeline(compiled.scene)
    for binding in compiled.input_bindings
        binding.carrier_hint == :temporal_stream || continue
        consumer = _compiled_application_by_id(compiled, binding.application_id)
        window_steps = _scene_input_window_steps(binding, consumer, timeline)
        for application_id in binding.source_application_ids
            source = _compiled_application_by_id(compiled, application_id)
            required = if binding.policy isa Union{Integrate,Aggregate}
                float(window_steps)
            elseif binding.policy isa Union{Interpolate,PreviousTimeStep}
                max(2.0, float(source.clock.dt) + 1.0)
            else
                0.0
            end
            key = (application_id, binding.source_var)
            push!(
                temporal_dependencies,
                key,
            )
            dependency_horizons[key] = max(
                get(dependency_horizons, key, 0.0),
                required,
            )
        end
    end

    requested_outputs = Set{Tuple{Symbol,Symbol}}()
    names = Set{Symbol}()
    for request in output_requests
        request.name in names && error(
            "Duplicate output request name `$(request.name)`. Request names must be unique."
        )
        push!(names, request.name)
        application = _scene_request_application(
            compiled.scene,
            compiled,
            request,
        )
        push!(requested_outputs, (application.id, request.var))
    end
    return SceneOutputRetentionPlan(
        retain_all,
        temporal_dependencies,
        requested_outputs,
        dependency_horizons,
    )
end

function explain_output_retention(sim::SceneSimulation)
    plan = sim.output_retention
    keys_to_explain = if plan.retain_all
        Set(
            (application.id, Symbol(variable))
            for application in sim.compiled.applications
            for variable in keys(outputs_(application.spec))
        )
    else
        union(plan.temporal_dependencies, plan.requested_outputs)
    end
    return [
        (
            application_id=application_id,
            variable=variable,
            reasons=plan.retain_all ?
                    (:default_all,) :
                    Tuple(
                        reason for (reason, keys) in (
                            :temporal_dependency => plan.temporal_dependencies,
                            :output_request => plan.requested_outputs,
                        )
                        if (application_id, variable) in keys
                    ),
            retention_steps=plan.retain_all ||
                            (application_id, variable) in plan.requested_outputs ?
                            nothing :
                            get(
                                plan.dependency_horizons,
                                (application_id, variable),
                                0.0,
                            ),
            current_target_count=length(
                _compiled_application_by_id(
                    sim.compiled,
                    application_id,
                ).target_ids,
            ),
        )
        for (application_id, variable) in sort!(
            collect(keys_to_explain);
            by=key -> (string(first(key)), string(last(key))),
        )
    ]
end

function _scene_call_targets(context::SceneRunContext, name::Symbol)
    targets = SceneCallTarget[]
    bindings = get(
        context.compiled.call_bindings_by_target,
        (context.application.id, context.object_id),
        (),
    )
    for binding in bindings
        binding.call == name || continue
        for application_id in binding.callee_application_ids
            callee_application = _compiled_application_by_id(context.compiled, application_id)
            for object_id in binding.callee_object_ids
                object_id in callee_application.target_ids || continue
                status = _scene_object_status(context.compiled.scene, object_id)
                push!(
                    targets,
                    SceneCallTarget(
                        context.compiled,
                        context.environment_bindings,
                        callee_application,
                        object_id,
                        _application_model(callee_application, object_id),
                        status,
                        context.temporal_streams,
                        context.output_retention,
                        context.time,
                        context.constants,
                    ),
                )
            end
        end
    end
    return targets
end

"""
    call_targets(context::SceneRunContext, name)
    call_target(context::SceneRunContext, name)

Return manually executable targets declared with `Calls(...)` for the current
scene/object model call. `call_target` requires exactly one matching target.
Execute returned targets with [`run_call!`](@ref).
"""
call_targets(context::SceneRunContext, name::Symbol) = _scene_call_targets(context, name)
call_targets(context::SceneRunContext, name::AbstractString) =
    call_targets(context, Symbol(name))
call_target(context::SceneRunContext, name::Symbol) = only(call_targets(context, name))
call_target(context::SceneRunContext, name::AbstractString) =
    call_target(context, Symbol(name))

dependency_targets(context::SceneRunContext, name::Symbol) = call_targets(context, name)
dependency_targets(context::SceneRunContext, name::AbstractString) =
    call_targets(context, name)
dependency_target(context::SceneRunContext, name::Symbol) = call_target(context, name)
dependency_target(context::SceneRunContext, name::AbstractString) =
    call_target(context, name)

"""
    run_call!(target::SceneCallTarget; publish=false, meteo=nothing)

Run a manually selected model call. By default, the call mutates its target
status without publishing outputs or environment updates, which is suitable
for trial iterations. Pass `publish=true` once for the accepted state.
"""
function run_call!(target::SceneCallTarget; publish::Bool=false, meteo=nothing)
    _run_scene_application!(
        target.compiled,
        target.environment_bindings,
        target.application,
        target.object_id;
        time=target.time,
        constants=target.constants,
        temporal_streams=target.temporal_streams,
        output_retention=target.output_retention,
        publish=publish,
        meteo=meteo,
    )
    return target
end

function run!(
    scene::Scene;
    steps::Integer=1,
    constants=nothing,
    tracked_outputs=nothing,
)
    compiled = refresh_bindings!(scene)
    env_bindings = refresh_environment_bindings!(scene, compiled)
    empty!(env_bindings.sample_cache)
    execution_plan = compile_scene_execution_plan(compiled, env_bindings)
    output_requests = _normalize_output_requests(tracked_outputs)
    output_retention = compile_scene_output_retention(
        compiled,
        output_requests;
        retain_all=isnothing(tracked_outputs),
    )
    temporal_streams = Dict{Tuple{Symbol,ObjectId,Symbol},Any}()
    for step in 1:steps
        if bindings_dirty(scene)
            compiled = refresh_bindings!(scene)
            env_bindings = refresh_environment_bindings!(scene, compiled)
            execution_plan = compile_scene_execution_plan(compiled, env_bindings)
            output_retention = compile_scene_output_retention(
                compiled,
                output_requests;
                retain_all=isnothing(tracked_outputs),
            )
        elseif environment_bindings_dirty(scene)
            env_bindings = refresh_environment_bindings!(scene, compiled)
            execution_plan = compile_scene_execution_plan(compiled, env_bindings)
        end
        for batch in execution_plan.batches
            _run_scene_execution_batch!(
                batch,
                compiled,
                env_bindings;
                time=step,
                constants=constants,
                temporal_streams=temporal_streams,
                output_retention=output_retention,
            )
        end
    end
    if bindings_dirty(scene)
        compiled = refresh_bindings!(scene)
        env_bindings = refresh_environment_bindings!(scene, compiled)
        execution_plan = compile_scene_execution_plan(compiled, env_bindings)
        output_retention = compile_scene_output_retention(
            compiled,
            output_requests;
            retain_all=isnothing(tracked_outputs),
        )
    elseif environment_bindings_dirty(scene)
        env_bindings = refresh_environment_bindings!(scene, compiled)
        execution_plan = compile_scene_execution_plan(compiled, env_bindings)
    end
    return SceneSimulation(
        scene,
        compiled,
        env_bindings,
        execution_plan,
        output_retention,
        temporal_streams,
        output_requests,
    )
end

function _scene_output_rows(sim::SceneSimulation, filter_object=nothing, filter_var=nothing)
    rows = NamedTuple[]
    for ((application_id, object_id, variable), samples) in sort!(
        collect(sim.temporal_streams);
        by=pair -> (string(first(pair)[1]), string(first(pair)[2].value), string(first(pair)[3])),
    )
        isnothing(filter_object) || object_id == ObjectId(filter_object) || continue
        isnothing(filter_var) || variable == Symbol(filter_var) || continue
        for (time, value) in samples
            push!(
                rows,
                (
                    timestep=Int(round(time)),
                    time=time,
                    application_id=application_id,
                    object_id=object_id.value,
                    variable=variable,
                    value=value,
                ),
            )
        end
    end
    sort!(rows; by=row -> (row.timestep, string(row.object_id), string(row.variable)))
    return rows
end

function _materialize_scene_output_rows(rows, sink)
    isnothing(sink) && return rows
    sink === DataFrames.DataFrame && return DataFrames.DataFrame(rows)
    return sink(rows)
end

function _scene_request_application(scene::Scene, compiled::CompiledScene, request)
    candidates = CompiledSceneApplication[]
    for application in compiled.applications
        request.var in keys(outputs_(application.spec)) || continue
        isnothing(request.process) || application.process == request.process || continue
        isnothing(request.application) ||
            application.id == request.application ||
            application.name == request.application ||
            continue
        _scene_application_matches_scale(scene, application, request.scale) || continue
        if isnothing(request.process) &&
           isnothing(request.application) &&
           _publish_mode_for_output(application.spec, request.var) == :stream_only
            continue
        end
        push!(candidates, application)
    end
    if isempty(candidates)
        error(
            "No scene output publisher found for `$(request.scale).$(request.var)`",
            isnothing(request.application) ?
            (isnothing(request.process) ? "." : " from process `$(request.process)`.") :
            " from application `$(request.application)`.",
        )
    elseif length(candidates) > 1
        error(
            "Ambiguous scene output publishers for `$(request.scale).$(request.var)`: ",
            join((application.id for application in candidates), ", "),
            ". Provide `application=` or make one publisher canonical.",
        )
    end
    return only(candidates)
end

function _scene_request_application(sim::SceneSimulation, request)
    return _scene_request_application(sim.scene, sim.compiled, request)
end

function _selector_declared_scale(selector::AbstractObjectMultiplicity)
    selector_criteria = criteria(selector)
    scale = _criteria_get(selector_criteria, :scale, nothing)
    !isnothing(scale) && return scale
    for positional_selector in _criteria_get(selector_criteria, :selectors, ())
        positional_selector isa Scale && return positional_selector.scale
    end
    return nothing
end

function _scene_application_matches_scale(
    scene::Scene,
    application::CompiledSceneApplication,
    scale::Symbol,
)
    declared_scale = _selector_declared_scale(application.applies_to)
    declared_scale == scale && return true
    for object_id in application.target_ids
        object = get(scene.registry.objects, object_id, nothing)
        !isnothing(object) && object.scale == scale && return true
    end
    return false
end

function _scene_stream_object_matches_scale(
    scene::Scene,
    application::CompiledSceneApplication,
    object_id::ObjectId,
    scale::Symbol,
)
    object = get(scene.registry.objects, object_id, nothing)
    !isnothing(object) && return object.scale == scale
    declared_scale = _selector_declared_scale(application.applies_to)
    return isnothing(declared_scale) || declared_scale == scale
end

function _scene_request_clock(request, timeline)
    isnothing(request.clock) && return ClockSpec(1.0, 0.0)
    clock = _clock_from_spec_timestep(request.clock, timeline)
    isnothing(clock) && error(
        "Unsupported clock specification `$(typeof(request.clock))` in ",
        "OutputRequest `$(request.name)`.",
    )
    return clock
end

function _scene_requested_value(samples, time, t_start, policy, timeline)
    if policy isa HoldLast
        value = _scene_latest_sample(samples, time)
        return isnothing(value) ? missing : value
    elseif policy isa Interpolate
        value = _scene_interpolated_sample(samples, time, policy)
        return isnothing(value) ? missing : value
    elseif policy isa Union{Integrate,Aggregate}
        values = _scene_window_samples(samples, t_start, time)
        isempty(values) && return missing
        durations = fill(timeline.base_step_seconds, length(values))
        return _scene_window_reduce(values, durations, policy)
    end
    error("Unsupported scene output request policy `$(typeof(policy))`.")
end

function _scene_requested_output_rows(
    sim::SceneSimulation,
    request,
)
    application = _scene_request_application(sim, request)
    timeline = _scene_timeline(sim.scene)
    clock = _scene_request_clock(request, timeline)
    source_rows = [
        (object_id=object_id, samples=samples)
        for ((application_id, object_id, variable), samples) in sim.temporal_streams
        if application_id == application.id &&
           variable == request.var &&
           _scene_stream_object_matches_scale(sim.scene, application, object_id, request.scale)
    ]
    isempty(source_rows) && return NamedTuple[]
    nonempty_source_rows = [row for row in source_rows if !isempty(row.samples)]
    isempty(nonempty_source_rows) && return NamedTuple[]
    max_time = maximum(last(row.samples)[1] for row in nonempty_source_rows)
    rows = NamedTuple[]
    for time in 1:Int(floor(max_time))
        _should_run_at_time(clock, float(time)) || continue
        t_start = float(time) - float(clock.dt) + 1.0
        for row in sort!(nonempty_source_rows; by=row -> string(row.object_id.value))
            first_sample_time = first(row.samples)[1]
            last_sample_time = last(row.samples)[1]
            first_sample_time <= float(time) <= last_sample_time || continue
            push!(
                rows,
                (
                    timestep=time,
                    time=float(time),
                    scale=request.scale,
                    process=application.process,
                    application_id=application.id,
                    variable=request.var,
                    object_id=row.object_id.value,
                    value=_scene_requested_value(
                        row.samples,
                        float(time),
                        t_start,
                        request.policy,
                        timeline,
                    ),
                ),
            )
        end
    end
    return rows
end

function _collect_scene_requested_outputs(sim::SceneSimulation, sink)
    outputs = Dict{Symbol,Any}()
    for request in sim.output_requests
        haskey(outputs, request.name) && error(
            "Duplicate output request name `$(request.name)`. Request names must be unique."
        )
        outputs[request.name] = _materialize_scene_output_rows(
            _scene_requested_output_rows(sim, request),
            sink,
        )
    end
    return outputs
end

function collect_outputs(sim::SceneSimulation; sink=DataFrames.DataFrame)
    isempty(sim.output_requests) || return _collect_scene_requested_outputs(sim, sink)
    return _materialize_scene_output_rows(_scene_output_rows(sim), sink)
end

function collect_outputs(sim::SceneSimulation, name::Symbol; sink=DataFrames.DataFrame)
    matches = [request for request in sim.output_requests if request.name == name]
    isempty(matches) && error(
        "No scene output request named `$(name)`. Available request names are ",
        isempty(sim.output_requests) ? "none." : join((request.name for request in sim.output_requests), ", "),
    )
    length(matches) == 1 || error(
        "Duplicate scene output request name `$(name)`. Request names must be unique."
    )
    request = only(matches)
    return _materialize_scene_output_rows(
        _scene_requested_output_rows(sim, request),
        sink,
    )
end

function collect_outputs(sim::SceneSimulation, object_id, variable::Symbol; sink=DataFrames.DataFrame)
    return _materialize_scene_output_rows(_scene_output_rows(sim, object_id, variable), sink)
end

function explain_outputs(sim::SceneSimulation)
    return [
        (
            application_id=application_id,
            object_id=object_id.value,
            variable=variable,
            nsamples=length(samples),
            first_time=isempty(samples) ? nothing : first(samples)[1],
            last_time=isempty(samples) ? nothing : last(samples)[1],
            value_type=isempty(samples) ? Union{} : typeof(last(samples)[2]),
        )
        for ((application_id, object_id, variable), samples) in sort!(
            collect(sim.temporal_streams);
            by=pair -> (string(first(pair)[1]), string(first(pair)[2].value), string(first(pair)[3])),
        )
    ]
end

struct ObjectAddress{SC,K,SP,S,N,P,V,R,M}
    scope::SC
    kind::K
    species::SP
    scale::S
    name::N
    process::P
    var::V
    relation::R
    multiplicity::M
end

function ObjectAddress(selector::AbstractObjectMultiplicity)
    c = criteria(selector)
    scope = _criteria_scope(c)
    kind = _criteria_value(c, :kind, Kind)
    species = _criteria_value(c, :species, Species)
    scale = _criteria_value(c, :scale, Scale)
    name = haskey(c, :name) ? c.name : nothing
    process = haskey(c, :process) ? c.process : nothing
    var = haskey(c, :var) ? c.var : nothing
    relation = _criteria_value(c, :relation, Relation)
    return ObjectAddress(scope, kind, species, scale, name, process, var, relation, multiplicity(selector))
end

object_address(selector::AbstractObjectMultiplicity) = ObjectAddress(selector)

struct Input{S}
    selector::S
end
Input(; kwargs...) = Input(One(; kwargs...))

struct Call{S}
    selector::S
end
Call(; kwargs...) = Call(One(; kwargs...))

struct EnvironmentConfig{C}
    config::C
end

_normalize_application_name(name) = isnothing(name) ? nothing : Symbol(name)

function _normalize_application_bindings(bindings::NamedTuple)
    return bindings
end

function _normalize_application_bindings(bindings::Tuple)
    pairs = Pair{Symbol,Any}[]
    for binding in bindings
        binding isa Pair || error(
            "Expected `var => selector` pairs in `Inputs(...)` or `Calls(...)`, got `$(typeof(binding))`."
        )
        key = first(binding)
        selector = last(binding)
        if key isa PreviousTimeStep
            selector isa AbstractObjectMultiplicity || error(
                "A `PreviousTimeStep(...)` input must map to `One(...)`, ",
                "`OptionalOne(...)`, or `Many(...)`."
            )
            push!(
                pairs,
                key.variable => _selector_with_previous_timestep(selector, key),
            )
        else
            key isa Union{Symbol,AbstractString} || error(
                "Binding names in `Inputs(...)` and `Calls(...)` must be symbols, ",
                "strings, or `PreviousTimeStep(:input)` markers."
            )
            push!(pairs, Symbol(key) => selector)
        end
    end
    return (; pairs...)
end

function _normalize_application_bindings(binding::Pair)
    return _normalize_application_bindings((binding,))
end

function _normalize_application_bindings(bindings)
    error(
        "Unsupported binding declaration `$(bindings)` of type `$(typeof(bindings))`. ",
        "Use pairs such as `:x => Many(...)` or keyword arguments."
    )
end

function _model_default_value_inputs(model)
    defaults = Pair{Symbol,Any}[]
    for (dep_name, selector) in pairs(dep(model))
        selector isa Input || continue
        push!(defaults, Symbol(dep_name) => selector.selector)
    end
    return (; defaults...)
end

function _model_default_model_calls(model)
    defaults = Pair{Symbol,Any}[]
    for (dep_name, selector) in pairs(dep(model))
        selector isa Call || continue
        push!(defaults, Symbol(dep_name) => selector.selector)
    end
    return (; defaults...)
end

function _merge_value_inputs(defaults::NamedTuple, explicit::NamedTuple)
    return (; pairs(defaults)..., pairs(explicit)...)
end

function _binding_origins(defaults::NamedTuple, explicit::NamedTuple)
    origins = Pair{Symbol,Symbol}[]
    for name in keys(defaults)
        push!(origins, Symbol(name) => :model_default)
    end
    for name in keys(explicit)
        push!(origins, Symbol(name) => :model_spec)
    end
    return (; origins...)
end

function _normalize_binding_origins(origins::NamedTuple, bindings::NamedTuple)
    normalized = Pair{Symbol,Symbol}[]
    for name in keys(bindings)
        origin = haskey(origins, name) ? Symbol(getproperty(origins, name)) : :model_spec
        origin in (:model_default, :model_spec) || error(
            "Unsupported binding origin `$(origin)` for `$(name)`."
        )
        push!(normalized, Symbol(name) => origin)
    end
    return (; normalized...)
end

function _legacy_multiscale_rhs_from_input_selector(selector::AbstractObjectMultiplicity)
    c = criteria(selector)
    haskey(c, :scale) || return nothing

    # The current MTG mapping layer only understands scale/variable mappings.
    # Keep richer object filters as unified metadata for the future compiler.
    unsupported = (:kind, :domain, :species, :name, :process, :relation)
    any(key -> haskey(c, key) && !isnothing(getproperty(c, key)), unsupported) && return nothing

    scale = c.scale
    src_var = haskey(c, :var) ? c.var : nothing
    if selector isa Many
        return isnothing(src_var) ? [scale] : [scale => src_var]
    elseif selector isa One || selector isa OptionalOne
        return isnothing(src_var) ? scale : (scale => src_var)
    end
    return nothing
end

function _legacy_multiscale_from_value_inputs(bindings::NamedTuple, model=nothing)
    mapped = Pair{Symbol,Any}[]
    model_input_names = isnothing(model) ? nothing : Set(keys(inputs_(model)))
    for (input_var, selector) in pairs(bindings)
        input_sym = Symbol(input_var)
        if !isnothing(model_input_names) && !(input_sym in model_input_names)
            continue
        end
        selector isa AbstractObjectMultiplicity || continue
        rhs = _legacy_multiscale_rhs_from_input_selector(selector)
        isnothing(rhs) && continue
        push!(mapped, input_sym => rhs)
    end
    return mapped
end

function _merge_legacy_multiscale(existing, derived::Vector{Pair{Symbol,Any}})
    isempty(derived) && return existing
    if isnothing(existing)
        return derived
    end
    derived_inputs = Set(first(item) for item in derived)
    merged = Pair{Any,Any}[]
    for item in collect(existing)
        mapped_input = first(item)
        mapped_input = mapped_input isa PreviousTimeStep ? mapped_input.variable : mapped_input
        mapped_input in derived_inputs && continue
        push!(merged, item)
    end
    append!(merged, derived)
    return merged
end
