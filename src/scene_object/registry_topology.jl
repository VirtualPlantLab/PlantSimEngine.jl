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
    ObjectTemplate(applications=(); kind=nothing, species=nothing, parameters=NamedTuple())

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
    parameters=NamedTuple(),
)
    normalized_applications = _as_tuple(applications)
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
    if !isnothing(normalized_process) && isnothing(normalized_application)
        Base.depwarn(
            "Process-only `Override` selection is deprecated; name the template application and use `application=`.",
            :Override,
        )
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
dep(model::ObjectModelOverrides) = dep(model.base)
timespec(model::ObjectModelOverrides) = timespec(model.base)
output_policy(model::ObjectModelOverrides) = output_policy(model.base)
timestep_hint(model::ObjectModelOverrides) = timestep_hint(model.base)
meteo_hint(model::ObjectModelOverrides) = meteo_hint(model.base)
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

struct MTGObjectAdapter{I,S,K,SP,N,G,ST}
    id::I
    scale::S
    kind::K
    species::SP
    name::N
    geometry::G
    status::ST
end

mutable struct Scene{R,A,E,I,SA}
    registry::R
    applications::A
    environment::E
    instances::I
    source_adapter::SA
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
    source_adapter=nothing,
)
    objects, mounted_instances = _collect_scene_items(items, instances)
    instance_ids = _prepare_object_instances!(objects, mounted_instances)
    mounted_applications = _mount_object_instance_applications(mounted_instances, instance_ids)
    normalized_applications = collect(Any, _as_tuple(applications))
    append!(normalized_applications, mounted_applications)
    scene = Scene(
        SceneRegistry(),
        normalized_applications,
        environment,
        mounted_instances,
        source_adapter,
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

"""
    Scene(model::AbstractModel, models::AbstractModel...;
          status=NamedTuple(), id=:scene, scale=:Scene, kind=:scene,
          name=id, environment=nothing)

Construct a concise one-object simulation. This is syntax lowering only: it
creates one ordinary [`Object`](@ref), one normal `ModelSpec` per model, and a
regular [`Scene`](@ref). The returned scene therefore uses the same compiler,
scheduler, diagnostics, lifecycle, and output system as explicitly assembled
scenes.

Use explicit `Object`, `ModelSpec`, and selector construction when applications
need names, different cadences, explicit coupling, or different target sets.
"""
function Scene(
    model::AbstractModel,
    models::AbstractModel...;
    status=NamedTuple(),
    id=:scene,
    scale=:Scene,
    kind=:scene,
    name=id,
    environment=nothing,
)
    object_name = isnothing(name) ? nothing : Symbol(string(name))
    object_status = if status isa Status || isnothing(status)
        status
    elseif status isa Union{NamedTuple,AbstractDict,Base.Pairs}
        Status((; (Symbol(key) => value for (key, value) in pairs(status))...))
    else
        error(
            "One-object `Scene(...; status=...)` requires a `Status`, `NamedTuple`, ",
            "`AbstractDict`, `Base.Pairs`, or `nothing`, got `$(typeof(status))`."
        )
    end
    selector = isnothing(object_name) ? One(scale=scale) : One(name=object_name)
    applications = map((model, models...)) do application_model
        ModelSpec(application_model) |> AppliesTo(selector)
    end
    return Scene(
        Object(
            id;
            scale=scale,
            kind=kind,
            name=object_name,
            status=object_status,
        );
        applications=applications,
        environment=environment,
    )
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
    adapter = MTGObjectAdapter(id, scale, kind, species, name, geometry, status)
    return _objects_from_mtg(root, adapter)
end

function _objects_from_mtg(root::MultiScaleTreeGraph.Node, adapter::MTGObjectAdapter)
    objects = Object[]
    MultiScaleTreeGraph.traverse!(root) do node
        node_parent = parent(node)
        parent_id = node === root || isnothing(node_parent) ? nothing : adapter.id(node_parent)
        push!(
            objects,
            Object(
                adapter.id(node);
                scale=adapter.scale(node),
                kind=adapter.kind(node),
                species=adapter.species(node),
                name=adapter.name(node),
                parent=parent_id,
                geometry=adapter.geometry(node),
                status=adapter.status(node),
            ),
        )
    end
    return objects
end

"""
    Scene(root::MultiScaleTreeGraph.Node; applications=(), instances=(),
          environment=nothing, id=node_id, scale=symbol, status=..., ...)

Build a unified scene directly from an MTG subtree. The MTG accessors are
retained and reused by [`add_organ!`](@ref) when the topology grows.
"""
function Scene(
    root::MultiScaleTreeGraph.Node;
    applications=(),
    instances=(),
    environment=nothing,
    id=node_id,
    scale=symbol,
    kind=node -> _mtg_attribute(node, :kind, nothing),
    species=node -> _mtg_attribute(node, :species, nothing),
    name=node -> _mtg_attribute(node, :name, nothing),
    geometry=node -> _mtg_attribute(node, :geometry, nothing),
    status=node -> _mtg_attribute(node, :plantsimengine_status, nothing),
)
    adapter = MTGObjectAdapter(id, scale, kind, species, name, geometry, status)
    objects = _objects_from_mtg(root, adapter)
    return Scene(
        objects...;
        applications=applications,
        instances=instances,
        environment=environment,
        source_adapter=adapter,
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

"""
    register_object!(scene, object; parent=object.parent)

Register a fully initialized [`Object`](@ref) in `scene`. Structural bindings
are marked dirty and become visible to execution after the next lifecycle
refresh boundary. Prefer [`add_organ!`](@ref) for MTG-backed growth.
"""
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

function _status_data!(data::Dict{Symbol,Any}, values)
    values === nothing && return data
    source = values isa Status ? NamedTuple(values) : values
    source isa Union{NamedTuple,AbstractDict,Base.Pairs} || error(
        "Initial organ status must be a `Status`, `NamedTuple`, `AbstractDict`, ",
        "`Base.Pairs`, or `nothing`, got `$(typeof(values))`."
    )
    for (key, value) in pairs(source)
        Symbol(key) == :plantsimengine_status && continue
        data[Symbol(key)] = value
    end
    return data
end

function _organ_status(adapter::MTGObjectAdapter, node, initial_status)
    adapted_status = adapter.status(node)
    data = Dict{Symbol,Any}()
    _status_data!(data, MultiScaleTreeGraph.node_attributes(node))
    _status_data!(data, adapted_status)
    data[:node] = node
    _status_data!(data, initial_status)
    data[:node] = node
    return Status((; data...))
end

"""
    add_organ!(parent, runtime, link, symbol, scale; index=0, id, attributes=(),
               initial_status=(), kind=nothing, species=nothing, name=nothing)

Create an MTG node and register its corresponding scene object as one operation.
`runtime` may be a [`Scene`](@ref), [`SceneRunContext`](@ref), or
[`SceneSimulation`](@ref). The scene reuses the MTG accessors and status
initializer supplied when it was constructed, then overlays `initial_status`.

This is the public growth API. [`register_object!`](@ref) remains the low-level
registry operation for callers that already own a fully initialized `Object`.
"""
function add_organ!(
    parent_node::MultiScaleTreeGraph.Node,
    runtime,
    link,
    organ_symbol,
    mtg_scale::Integer;
    index::Integer=0,
    id=MultiScaleTreeGraph.new_id(MultiScaleTreeGraph.get_root(parent_node)),
    attributes=NamedTuple(),
    initial_status=NamedTuple(),
    kind=nothing,
    species=nothing,
    name=nothing,
)
    scene = runtime_scene(runtime)
    adapter = scene.source_adapter
    adapter isa MTGObjectAdapter || error(
        "`add_organ!` requires a scene constructed from an MTG. Use ",
        "`register_object!` for scenes built directly from `Object` values."
    )
    parent_id = ObjectId(adapter.id(parent_node))
    _scene_object(scene, parent_id)
    root = MultiScaleTreeGraph.get_root(parent_node)
    isnothing(MultiScaleTreeGraph.get_node(root, Int(id))) || error(
        "MTG node id `$(id)` already exists."
    )

    node = MultiScaleTreeGraph.Node(
        Int(id),
        parent_node,
        MultiScaleTreeGraph.NodeMTG(
            Symbol(link),
            Symbol(organ_symbol),
            Int(index),
            Int(mtg_scale),
        ),
        attributes,
    )
    try
        status = _organ_status(adapter, node, initial_status)
        node[:plantsimengine_status] = status
        object = Object(
            adapter.id(node);
            scale=adapter.scale(node),
            kind=isnothing(kind) ? adapter.kind(node) : kind,
            species=isnothing(species) ? adapter.species(node) : species,
            name=isnothing(name) ? adapter.name(node) : name,
            parent=parent_id,
            geometry=adapter.geometry(node),
            status=status,
        )
        register_object!(scene, object)
        return status
    catch
        MultiScaleTreeGraph.delete_node!(node)
        rethrow()
    end
end

function _remove_child_link!(scene::Scene, parent_id, child_id::ObjectId)
    isnothing(parent_id) && return nothing
    parent_object = _scene_object(scene, parent_id)
    filter!(!=(child_id), parent_object.children)
    return nothing
end

function _instance_roots_in_subtree(scene::Scene, root_id::ObjectId)
    subtree_ids = Set(_descendant_ids(scene, root_id))
    roots = ObjectId[
        _instance_root_id(instance) for instance in scene.instances
        if _instance_root_id(instance) in subtree_ids
    ]
    return _sort_object_ids!(roots)
end

function _validate_mutable_object_subtree!(scene::Scene, object::Object, operation::Symbol)
    instance_roots = _instance_roots_in_subtree(scene, object.id)
    isempty(instance_roots) && return nothing
    error(
        "Cannot $(operation) object `$(object.id.value)` because its subtree contains ",
        "immutable ObjectInstance root(s) `$([id.value for id in instance_roots])`. ",
        "Mutate ordinary instance descendants instead.",
    )
end

function remove_object!(scene::Scene, id; recursive::Bool=true)
    object = _scene_object(scene, id)
    _validate_mutable_object_subtree!(scene, object, :remove)
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
    _validate_mutable_object_subtree!(scene, object, :reparent)
    new_parent_id = isnothing(new_parent) ? nothing : ObjectId(new_parent)
    if !isnothing(new_parent_id)
        haskey(scene.registry.objects, new_parent_id) || error("No scene object with id `$(new_parent_id.value)`.")
        new_parent_id == object.id && error(
            "Cannot reparent object `$(object.id.value)` to itself.",
        )
        new_parent_id in _descendant_ids(scene, object.id) && error(
            "Cannot reparent object `$(object.id.value)` below its descendant `$(new_parent_id.value)`.",
        )
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
        push!(
            rows,
            (
                scope_type=:object_self,
                selector=Self(),
                context=object.id.value,
                root_id=object.id.value,
                scale=object.scale,
                kind=object.kind,
                species=object.species,
                name=object.name,
                object_ids=[object.id.value],
                n_objects=1,
            ),
        )
        descendant_ids = _object_id_values(_descendant_ids(scene, object.id))
        push!(
            rows,
            (
                scope_type=:object_subtree,
                selector=Subtree(),
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
