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
Base.dataids(v::ObjectRefVector) = Base.dataids(parent(v))

"""
    ObjectId(value)

Stable identity of one [`Object`](@ref) in a [`CompositeModel`](@ref).
Strings are normalized to symbols; an existing `ObjectId` is returned
unchanged.
"""
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
    CompositeModelTemplate(applications=(); kind=nothing, species=nothing, parameters=NamedTuple())

Reusable model-application bundle for one kind of model object, such as a plant
species. Each mounted `ObjectInstance` scopes unqualified `ModelSpec(...; on=...)`
selectors to its own object subtree. Model objects are shared between instances
unless an instance supplies an override.

`parameters` stores template-level metadata. Parameter-field merging is not
implicit: use an instance model override when model parameters differ.
"""
struct CompositeModelTemplate{A,P}
    kind::Union{Nothing,Symbol}
    species::Union{Nothing,Symbol}
    applications::A
    parameters::P
end

_as_tuple(value::Tuple) = value
_as_tuple(value::AbstractVector) = Tuple(value)
_as_tuple(value) = (value,)

function CompositeModelTemplate(
    applications=();
    kind=nothing,
    species=nothing,
    parameters=NamedTuple(),
)
    normalized_applications = _as_tuple(applications)
    return CompositeModelTemplate(
        _maybe_symbol(kind),
        _maybe_symbol(species),
        normalized_applications,
        parameters,
    )
end

"""
    Override(; object, application, model)

Replace one template model application on one exceptional object. Select the
template application by its application name. The replacement must implement
the same process and variable contract.
"""
struct Override{M<:AbstractModel}
    object::ObjectId
    application::Symbol
    model::M
end

function Override(; object, application, model::AbstractModel)
    return Override(
        ObjectId(object),
        Symbol(application),
        model,
    )
end

"""
    ObjectInstance(name, template; root, objects=(), overrides=NamedTuple(), object_overrides=())

Mount a `CompositeModelTemplate` on one concrete object subtree.

`root` may be an `Object` owned by the instance or the id of an object supplied
separately to `CompositeModel`. `objects` contains additional owned descendants.
`overrides` maps one template application name to a replacement model
implementing the same process. `object_overrides` contains `Override` entries
for exceptional organs.
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
    template::CompositeModelTemplate;
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
        "`ObjectInstance(...; overrides=...)` must be a NamedTuple keyed by application name."
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
environment_hint(model::ObjectModelOverrides) = environment_hint(model.base)
environment_inputs_(model::ObjectModelOverrides) = environment_inputs_(model.base)
environment_outputs_(model::ObjectModelOverrides) = environment_outputs_(model.base)

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

mutable struct ObjectRegistry
    objects::Dict{ObjectId,Any}
    by_scale::Dict{Symbol,Set{ObjectId}}
    by_kind::Dict{Symbol,Set{ObjectId}}
    by_species::Dict{Symbol,Set{ObjectId}}
    by_name::Dict{Symbol,ObjectId}
    ancestor_ids_by_object::Dict{ObjectId,Vector{ObjectId}}
end

ObjectRegistry() = ObjectRegistry(
    Dict{ObjectId,Any}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,Set{ObjectId}}(),
    Dict{Symbol,ObjectId}(),
    Dict{ObjectId,Vector{ObjectId}}(),
)

struct MTGObjectAdapter{I,S,K,SP,N,G,ST}
    id::I
    scale::S
    kind::K
    species::SP
    name::N
    geometry::G
    status::ST
    max_node_id::Base.RefValue{Int}
end

"""Labels and topology captured for one object at a lifecycle event."""
struct LifecycleObjectSnapshot{G}
    id::ObjectId
    scale::Union{Nothing,Symbol}
    kind::Union{Nothing,Symbol}
    species::Union{Nothing,Symbol}
    name::Union{Nothing,Symbol}
    parent::Union{Nothing,ObjectId}
    children::Tuple
    ancestors::Tuple
    geometry::G
end

"""One subtree reparenting recorded before runtime buffers refresh."""
struct LifecycleReparentEvent
    root_id::ObjectId
    descendant_ids::Tuple
    old_parent::Union{Nothing,ObjectId}
    new_parent::Union{Nothing,ObjectId}
    old_ancestors_by_object::Dict{ObjectId,Tuple}
end

"""One geometry mutation and every environment handle it can affect."""
struct LifecycleMoveEvent{O,N}
    object_id::ObjectId
    affected_object_ids::Tuple
    old_geometry::O
    new_geometry::N
end

"""
Append-only object lifecycle events pending the next runtime refresh barrier.
The dirty-id sets are derived indices shared by every runtime consumer.
"""
mutable struct LifecycleDelta
    added::Vector{LifecycleObjectSnapshot}
    removed::Vector{LifecycleObjectSnapshot}
    reparented::Vector{LifecycleReparentEvent}
    moved::Vector{LifecycleMoveEvent}
    structural_dirty_ids::Set{ObjectId}
    environment_dirty_ids::Set{ObjectId}
    structural_kind::Symbol
    full_environment::Bool
    structural_generation::Int
    environment_generation::Int
end

function LifecycleDelta(;
    structural_kind::Symbol=:clean,
    full_environment::Bool=false,
)
    structural_kind in (:clean, :addition, :structural, :full) || error(
        "Unsupported lifecycle structural kind `$(structural_kind)`.",
    )
    return LifecycleDelta(
        LifecycleObjectSnapshot[],
        LifecycleObjectSnapshot[],
        LifecycleReparentEvent[],
        LifecycleMoveEvent[],
        Set{ObjectId}(),
        Set{ObjectId}(),
        structural_kind,
        full_environment,
        0,
        0,
    )
end

mutable struct CompositeModel{R,A,E,I,SA}
    registry::R
    applications::A
    environment::E
    instances::I
    source_adapter::SA
    binding_cache::Any
    environment_binding_cache::Any
    bindings_dirty::Bool
    environment_bindings_dirty::Bool
    lifecycle_delta::LifecycleDelta
    input_default_status_variables::Dict{ObjectId,Set{Symbol}}
    runtime_revision::Int
    revision::Int
    environment_revision::Int
end

function _normalize_object_instances(instances)
    instances isa ObjectInstance && return (instances,)
    normalized = _as_tuple(instances)
    all(instance -> instance isa ObjectInstance, normalized) || error(
        "CompositeModel instances must be `ObjectInstance` values."
    )
    return normalized
end

function _instance_root_id(instance::ObjectInstance)
    return instance.root isa Object ? instance.root.id : ObjectId(instance.root)
end

function _collect_model_items(items, instances)
    objects = Object[]
    mounted_instances = ObjectInstance[]
    for item in items
        if item isa Object
            push!(objects, item)
        elseif item isa ObjectInstance
            push!(mounted_instances, item)
        else
            error("A `CompositeModel` can contain only `Object` and `ObjectInstance` values, got `$(typeof(item))`.")
        end
    end
    append!(mounted_instances, _normalize_object_instances(instances))
    for instance in mounted_instances
        instance.root isa Object && push!(objects, instance.root)
        append!(objects, instance.objects)
    end
    ids = Set{ObjectId}()
    for object in objects
        object.id in ids && error("CompositeModel contains object id `$(object.id.value)` more than once.")
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
    length(instance_ids) == length(instances) || error("Object instance names must be unique within a model.")
    return instance_ids
end

function _register_objects!(model::CompositeModel, objects)
    pending = copy(objects)
    added = Object[]
    while !isempty(pending)
        registered = false
        for index in reverse(eachindex(pending))
            object = pending[index]
            if isnothing(object.parent) || haskey(model.registry.objects, object.parent)
                _register_object_without_lifecycle!(model, object)
                push!(added, object)
                deleteat!(pending, index)
                registered = true
            end
        end
        registered && continue
        unresolved = [(object.id.value, isnothing(object.parent) ? nothing : object.parent.value) for object in pending]
        error("Cannot register model objects because parent objects are missing or cyclic: $(unresolved).")
    end
    _record_added_objects!(model, added)
    return model
end

_register_model_objects!(model::CompositeModel, objects) =
    _register_objects!(model, objects)

"""
    CompositeModel(items...; applications=(), instances=(), environment=nothing)

Create a model from `Object` and `ObjectInstance` values. Global applications
and applications mounted from object instances are compiled through the same
composite-model/object dependency graph.
"""
function CompositeModel(
    items::Union{Object,ObjectInstance}...;
    applications=(),
    instances=(),
    environment=nothing,
    source_adapter=nothing,
)
    objects, mounted_instances = _collect_model_items(items, instances)
    instance_ids = _prepare_object_instances!(objects, mounted_instances)
    mounted_applications = _mount_object_instance_applications(mounted_instances, instance_ids)
    normalized_applications = collect(Any, _as_tuple(applications))
    append!(normalized_applications, mounted_applications)
    model = CompositeModel(
        ObjectRegistry(),
        normalized_applications,
        environment,
        mounted_instances,
        source_adapter,
        nothing,
        nothing,
        true,
        true,
        LifecycleDelta(;
            structural_kind=:full,
            full_environment=true,
        ),
        Dict{ObjectId,Set{Symbol}}(),
        0,
        0,
        0,
    )
    return _register_model_objects!(model, objects)
end

"""
    CompositeModel(template::CompositeModelTemplate;
                   root, objects=(), name=nothing, overrides=NamedTuple(),
                   object_overrides=(), applications=(), environment=nothing)

Build an executable composite model from a reusable template mounted on one
concrete object subtree. `root` may be the owned root `Object`, or its id when
the root is included in `objects`. When `name` is omitted, it is inferred from
the root object's name or id.

This constructor is syntax lowering for an [`ObjectInstance`](@ref) passed to
the regular [`CompositeModel`](@ref) constructor. Use explicit
`ObjectInstance` values when the same composite model contains several mounted
templates.
"""
function CompositeModel(
    template::CompositeModelTemplate;
    root,
    objects=(),
    name=nothing,
    overrides=NamedTuple(),
    object_overrides=(),
    applications=(),
    environment=nothing,
    source_adapter=nothing,
)
    inferred_name = if !isnothing(name)
        Symbol(name)
    elseif root isa Object && !isnothing(root.name)
        root.name
    elseif root isa Object
        Symbol(root.id.value)
    else
        Symbol(ObjectId(root).value)
    end
    instance = ObjectInstance(
        inferred_name,
        template;
        root=root,
        objects=objects,
        overrides=overrides,
        object_overrides=object_overrides,
    )
    return CompositeModel(
        instance;
        applications=applications,
        environment=environment,
        source_adapter=source_adapter,
    )
end

"""
    CompositeModel(model::AbstractModel, models::AbstractModel...;
          status=NamedTuple(), id=:scene, scale=:Scene, kind=nothing,
          name=id, environment=nothing, timestep=nothing)

Construct a concise one-object simulation. This is syntax lowering only: it
creates one ordinary [`Object`](@ref), one normal `ModelSpec` per model, and a
regular [`CompositeModel`](@ref). The returned model therefore uses the same compiler,
scheduler, diagnostics, lifecycle, and output system as explicitly assembled
composite models.

Use explicit `Object`, `ModelSpec`, and selector construction when applications
need names, different cadences, explicit coupling, or different target sets.
Use `timestep` to apply one common cadence to every supplied model.
"""
function CompositeModel(
    model::AbstractModel,
    models::AbstractModel...;
    status=NamedTuple(),
    id=:scene,
    scale=:Scene,
    kind=nothing,
    name=id,
    environment=nothing,
    timestep=nothing,
)
    object_name = isnothing(name) ? nothing : Symbol(string(name))
    object_status = if status isa Status || isnothing(status)
        status
    elseif status isa Union{NamedTuple,AbstractDict,Base.Pairs}
        Status((; (Symbol(key) => value for (key, value) in pairs(status))...))
    else
        error(
            "One-object `CompositeModel(...; status=...)` requires a `Status`, `NamedTuple`, ",
            "`AbstractDict`, `Base.Pairs`, or `nothing`, got `$(typeof(status))`."
        )
    end
    selector = isnothing(object_name) ? One(scale=scale) : One(name=object_name)
    applications = map((model, models...)) do application_model
        ModelSpec(application_model; on=selector, every=timestep)
    end
    return CompositeModel(
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

Adapt one MTG subtree to model `Object` values. The MTG is traversed once;
node ids and parent relations become stable model-object identities and
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
    adapter = MTGObjectAdapter(
        id,
        scale,
        kind,
        species,
        name,
        geometry,
        status,
        Ref(MultiScaleTreeGraph.max_id(root)),
    )
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
    CompositeModel(root::MultiScaleTreeGraph.Node; applications=(), instances=(),
          environment=nothing, id=node_id, scale=symbol, status=..., ...)

Build a unified model directly from an MTG subtree. The MTG accessors are
retained and reused by [`add_organ!`](@ref) when the topology grows.
"""
function CompositeModel(
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
    adapter = MTGObjectAdapter(
        id,
        scale,
        kind,
        species,
        name,
        geometry,
        status,
        Ref(MultiScaleTreeGraph.max_id(root)),
    )
    objects = _objects_from_mtg(root, adapter)
    return CompositeModel(
        objects...;
        applications=applications,
        instances=instances,
        environment=environment,
        source_adapter=adapter,
    )
end

_lifecycle_object_ids(::Nothing) = nothing
_lifecycle_object_ids(object_id::ObjectId) = (object_id,)
_lifecycle_object_ids(object_ids) = object_ids

function _mark_environment_bindings_dirty!(
    model::CompositeModel,
    object_ids=nothing,
)
    delta = model.lifecycle_delta
    ids = _lifecycle_object_ids(object_ids)
    if isnothing(ids) || isnothing(model.environment_binding_cache)
        model.environment_binding_cache = nothing
        delta.full_environment = true
    elseif !delta.full_environment
        union!(delta.environment_dirty_ids, ids)
    end
    if !model.environment_bindings_dirty
        model.environment_revision += 1
        model.runtime_revision += 1
    end
    model.environment_bindings_dirty = true
    delta.environment_generation = model.environment_revision
    return model
end

function _mark_bindings_dirty!(
    model::CompositeModel,
    object_ids=nothing;
    kind::Symbol=:full,
)
    kind in (:addition, :structural, :full) || error(
        "Unsupported binding dirty kind `$(kind)`.",
    )
    delta = model.lifecycle_delta
    ids = _lifecycle_object_ids(object_ids)
    if isnothing(ids)
        model.binding_cache = nothing
        delta.structural_kind = :full
    else
        union!(delta.structural_dirty_ids, ids)
        delta.structural_kind = if delta.structural_kind == :full
            :full
        elseif delta.structural_kind == :clean
            kind
        elseif delta.structural_kind == kind
            kind
        else
            :structural
        end
    end
    if !model.bindings_dirty
        model.revision += 1
    end
    model.bindings_dirty = true
    delta.structural_generation = model.revision
    return _mark_environment_bindings_dirty!(model, ids)
end

function _reset_lifecycle_delta_if_consumed!(model::CompositeModel)
    model.bindings_dirty && return model.lifecycle_delta
    model.environment_bindings_dirty && return model.lifecycle_delta
    consumed = model.lifecycle_delta
    model.lifecycle_delta = LifecycleDelta()
    return consumed
end

function _consume_structural_lifecycle_delta!(model::CompositeModel)
    consumed = model.lifecycle_delta
    if !model.environment_bindings_dirty
        model.lifecycle_delta = LifecycleDelta()
        return consumed
    end
    model.lifecycle_delta = LifecycleDelta(
        copy(consumed.added),
        copy(consumed.removed),
        copy(consumed.reparented),
        copy(consumed.moved),
        Set{ObjectId}(),
        copy(consumed.environment_dirty_ids),
        :clean,
        consumed.full_environment,
        consumed.structural_generation,
        consumed.environment_generation,
    )
    return consumed
end

bindings_dirty(model::CompositeModel) = model.bindings_dirty
environment_bindings_dirty(model::CompositeModel) = model.environment_bindings_dirty
lifecycle_delta(model::CompositeModel) = model.lifecycle_delta
model_revision(model::CompositeModel) = model.revision
environment_revision(model::CompositeModel) = model.environment_revision
compiled_bindings(model::CompositeModel) = model.bindings_dirty ? nothing : model.binding_cache
compiled_environment_bindings(model::CompositeModel) = model.environment_binding_cache
mark_environment_binding_dirty!(model::CompositeModel) = _mark_environment_bindings_dirty!(model)
function mark_environment_binding_dirty!(model::CompositeModel, id)
    object_id = ObjectId(id)
    _model_object(model, object_id)
    return _mark_environment_bindings_dirty!(model, object_id)
end
function mark_environment_binding_dirty!(model::CompositeModel, object::Object)
    return mark_environment_binding_dirty!(model, object.id)
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

function _index_object!(registry::ObjectRegistry, object::Object)
    _push_index!(registry.by_scale, object.scale, object.id)
    _push_index!(registry.by_kind, object.kind, object.id)
    _push_index!(registry.by_species, object.species, object.id)
    if !isnothing(object.name)
        existing = get(registry.by_name, object.name, nothing)
        if !isnothing(existing) && existing != object.id
            error(
                "CompositeModel object name `$(object.name)` is already used by object `$(existing.value)`."
            )
        end
        registry.by_name[object.name] = object.id
    end
    return nothing
end

function _deindex_object!(registry::ObjectRegistry, object::Object)
    _delete_index!(registry.by_scale, object.scale, object.id)
    _delete_index!(registry.by_kind, object.kind, object.id)
    _delete_index!(registry.by_species, object.species, object.id)
    if !isnothing(object.name) && get(registry.by_name, object.name, nothing) == object.id
        delete!(registry.by_name, object.name)
    end
    return nothing
end

function _model_object(model::CompositeModel, id)
    oid = ObjectId(id)
    haskey(model.registry.objects, oid) || error("No model object with id `$(oid.value)`.")
    return model.registry.objects[oid]
end

"""
    model_object(model::CompositeModel, id) -> Object

Return the single object registered under `id`. The identifier may be either
an [`ObjectId`](@ref) or the value used to construct one. An error is raised
when the registry contains no matching object.
"""
model_object(model::CompositeModel, id) = _model_object(model, id)

function _object_ancestor_ids(
    registry::ObjectRegistry,
    object_id::ObjectId,
)
    ancestors = get(registry.ancestor_ids_by_object, object_id, nothing)
    isnothing(ancestors) && error(
        "No cached topology path for model object `$(object_id.value)`.",
    )
    return ancestors
end

function _lifecycle_object_snapshot(model::CompositeModel, object::Object)
    ancestors = get(
        model.registry.ancestor_ids_by_object,
        object.id,
        ObjectId[],
    )
    return LifecycleObjectSnapshot(
        object.id,
        object.scale,
        object.kind,
        object.species,
        object.name,
        object.parent,
        Tuple(object.children),
        Tuple(ancestors),
        object.geometry,
    )
end

function _record_added_objects!(model::CompositeModel, objects)
    isempty(objects) && return model
    object_ids = Tuple(object.id for object in objects)
    for object in objects
        push!(
            model.lifecycle_delta.added,
            _lifecycle_object_snapshot(model, object),
        )
    end
    return _mark_bindings_dirty!(
        model,
        object_ids;
        kind=:addition,
    )
end

function _refresh_object_ancestor_ids!(
    model::CompositeModel,
    object_id::ObjectId,
    parent_ancestors::Vector{ObjectId},
)
    ancestors = copy(parent_ancestors)
    push!(ancestors, object_id)
    model.registry.ancestor_ids_by_object[object_id] = ancestors
    object = _model_object(model, object_id)
    for child_id in object.children
        _refresh_object_ancestor_ids!(
            model,
            child_id,
            ancestors,
        )
    end
    return nothing
end

function _instance_for_object(model::CompositeModel, id)
    current_id = ObjectId(id)
    while haskey(model.registry.objects, current_id)
        for instance in model.instances
            _instance_root_id(instance) == current_id && return instance
        end
        parent = model.registry.objects[current_id].parent
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

function _register_object_without_lifecycle!(
    model::CompositeModel,
    object::Object;
    parent=object.parent,
)
    registry = model.registry
    haskey(registry.objects, object.id) && error("CompositeModel already contains object id `$(object.id.value)`.")
    parent_id = isnothing(parent) ? nothing : ObjectId(parent)
    if !isnothing(parent_id) && !haskey(registry.objects, parent_id)
        error("No model object with id `$(parent_id.value)`.")
    end
    if !isnothing(object.name)
        existing = get(registry.by_name, object.name, nothing)
        isnothing(existing) || error(
            "CompositeModel object name `$(object.name)` is already used by object `$(existing.value)`."
        )
    end
    instance = isnothing(parent_id) ? nothing : _instance_for_object(model, parent_id)
    _apply_instance_labels!(object, instance)
    object.parent = parent_id
    registry.objects[object.id] = object
    _index_object!(registry, object)
    parent_ancestors = isnothing(parent_id) ?
                       ObjectId[] :
                       _object_ancestor_ids(registry, parent_id)
    ancestors = copy(parent_ancestors)
    push!(ancestors, object.id)
    registry.ancestor_ids_by_object[object.id] = ancestors
    if !isnothing(object.parent)
        parent_object = registry.objects[object.parent]
        object.id in parent_object.children || push!(parent_object.children, object.id)
    end
    return object
end

"""
    register_object!(model, object; parent=object.parent)

Register a fully initialized [`Object`](@ref) in `model`. Structural bindings
are marked dirty and become visible to execution after the next lifecycle
refresh boundary. Prefer [`add_organ!`](@ref) for MTG-backed growth.
"""
function register_object!(model::CompositeModel, object::Object; parent=object.parent)
    registered = _register_object_without_lifecycle!(
        model,
        object;
        parent=parent,
    )
    _record_added_objects!(model, (registered,))
    return registered
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

Create an MTG node and register its corresponding model object as one operation.
`runtime` may be a [`CompositeModel`](@ref), [`RunContext`](@ref), or
[`Simulation`](@ref). The model reuses the MTG accessors and status
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
    id=nothing,
    attributes=NamedTuple(),
    initial_status=NamedTuple(),
    kind=nothing,
    species=nothing,
    name=nothing,
)
    model = runtime_model(runtime)
    adapter = model.source_adapter
    adapter isa MTGObjectAdapter || error(
        "`add_organ!` requires a model constructed from an MTG. Use ",
        "`register_object!` for composite models built directly from `Object` values."
    )
    parent_id = ObjectId(adapter.id(parent_node))
    _model_object(model, parent_id)
    root = MultiScaleTreeGraph.get_root(parent_node)
    node_id = if isnothing(id)
        # `max_node_id` is initialized from the complete source MTG and is
        # updated for every explicit insertion, so the next automatic id is
        # unique without an O(n) tree lookup.
        adapter.max_node_id[] += 1
    else
        explicit_id = Int(id)
        adapter.max_node_id[] = max(adapter.max_node_id[], explicit_id)
        isnothing(MultiScaleTreeGraph.get_node(root, explicit_id)) || error(
            "MTG node id `$(explicit_id)` already exists."
        )
        explicit_id
    end

    node = MultiScaleTreeGraph.Node(
        node_id,
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
        register_object!(model, object)
        return status
    catch
        MultiScaleTreeGraph.delete_node!(node)
        rethrow()
    end
end

function _remove_child_link!(model::CompositeModel, parent_id, child_id::ObjectId)
    isnothing(parent_id) && return nothing
    parent_object = _model_object(model, parent_id)
    filter!(!=(child_id), parent_object.children)
    return nothing
end

function _instance_roots_in_subtree(
    model::CompositeModel,
    root_id::ObjectId,
    descendant_ids=_descendant_ids(model, root_id),
)
    subtree_ids = Set(descendant_ids)
    roots = ObjectId[
        _instance_root_id(instance) for instance in model.instances
        if _instance_root_id(instance) in subtree_ids
    ]
    return _sort_object_ids!(roots)
end

function _validate_mutable_object_subtree!(
    model::CompositeModel,
    object::Object,
    operation::Symbol,
    descendant_ids=_descendant_ids(model, object.id),
)
    instance_roots = _instance_roots_in_subtree(
        model,
        object.id,
        descendant_ids,
    )
    isempty(instance_roots) && return nothing
    error(
        "Cannot $(operation) object `$(object.id.value)` because its subtree contains ",
        "immutable ObjectInstance root(s) `$([id.value for id in instance_roots])`. ",
        "Mutate ordinary instance descendants instead.",
    )
end

function remove_object!(model::CompositeModel, id; recursive::Bool=true)
    object = _model_object(model, id)
    descendant_ids = _descendant_ids(model, object.id)
    _validate_mutable_object_subtree!(
        model,
        object,
        :remove,
        descendant_ids,
    )
    if !recursive && !isempty(object.children)
        error("Cannot remove object `$(object.id.value)` with children unless `recursive=true`.")
    end
    snapshots = LifecycleObjectSnapshot[
        _lifecycle_object_snapshot(model, _model_object(model, object_id))
        for object_id in descendant_ids
    ]
    _remove_child_link!(model, object.parent, object.id)
    for object_id in Iterators.reverse(descendant_ids)
        removed = _model_object(model, object_id)
        _deindex_object!(model.registry, removed)
        delete!(model.registry.objects, object_id)
        delete!(model.registry.ancestor_ids_by_object, object_id)
        delete!(model.input_default_status_variables, object_id)
    end
    append!(model.lifecycle_delta.removed, snapshots)
    _mark_bindings_dirty!(model, descendant_ids; kind=:structural)
    return object
end

function reparent_object!(model::CompositeModel, id, new_parent)
    object = _model_object(model, id)
    descendant_ids = _descendant_ids(model, object.id)
    _validate_mutable_object_subtree!(
        model,
        object,
        :reparent,
        descendant_ids,
    )
    new_parent_id = isnothing(new_parent) ? nothing : ObjectId(new_parent)
    if !isnothing(new_parent_id)
        haskey(model.registry.objects, new_parent_id) || error("No model object with id `$(new_parent_id.value)`.")
        new_parent_id == object.id && error(
            "Cannot reparent object `$(object.id.value)` to itself.",
        )
        new_parent_id in descendant_ids && error(
            "Cannot reparent object `$(object.id.value)` below its descendant `$(new_parent_id.value)`.",
        )
    end
    old_parent_id = object.parent
    old_ancestors_by_object = Dict{ObjectId,Tuple}(
        descendant_id => Tuple(
            _object_ancestor_ids(model.registry, descendant_id),
        )
        for descendant_id in descendant_ids
    )
    _remove_child_link!(model, old_parent_id, object.id)
    object.parent = new_parent_id
    if !isnothing(new_parent_id)
        parent_object = _model_object(model, new_parent_id)
        object.id in parent_object.children || push!(parent_object.children, object.id)
    end
    parent_ancestors = isnothing(new_parent_id) ?
                       ObjectId[] :
                       _object_ancestor_ids(model.registry, new_parent_id)
    _refresh_object_ancestor_ids!(
        model,
        object.id,
        parent_ancestors,
    )
    push!(
        model.lifecycle_delta.reparented,
        LifecycleReparentEvent(
            object.id,
            Tuple(descendant_ids),
            old_parent_id,
            new_parent_id,
            old_ancestors_by_object,
        ),
    )
    _mark_bindings_dirty!(model, descendant_ids; kind=:structural)
    return object
end

function move_object!(model::CompositeModel, id, geometry_or_position)
    return update_geometry!(model, id, geometry_or_position)
end

function update_geometry!(model::CompositeModel, id, geometry_or_position; invalidate_environment::Bool=true)
    object = _model_object(model, id)
    old_geometry = object.geometry
    affected_object_ids = ObjectId[object.id]
    invalidate_environment && append!(
        affected_object_ids,
        _geometry_inheriting_descendants(model, object.id),
    )
    object.geometry = geometry_or_position
    if invalidate_environment
        push!(
            model.lifecycle_delta.moved,
            LifecycleMoveEvent(
                object.id,
                Tuple(affected_object_ids),
                old_geometry,
                geometry_or_position,
            ),
        )
        _mark_environment_bindings_dirty!(model, affected_object_ids)
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

function _geometry_inheriting_descendants(model::CompositeModel, root_id::ObjectId)
    ids = ObjectId[]
    for child_id in _model_object(model, root_id).children
        child = _model_object(model, child_id)
        isnothing(geometry(child)) || continue
        push!(ids, child_id)
        append!(ids, _geometry_inheriting_descendants(model, child_id))
    end
    return ids
end

function refresh_bindings!(
    model::CompositeModel,
    specs=model.applications;
    force::Bool=false,
    performance=nothing,
)
    uses_model_applications = specs === model.applications
    if !uses_model_applications
        return compile_composite_model(
            model,
            specs;
            performance=performance,
        )
    end
    if force || model.bindings_dirty || isnothing(model.binding_cache)
        delta = model.lifecycle_delta
        dirty_object_ids = delta.structural_dirty_ids
        can_extend = !force &&
                     !isnothing(model.binding_cache) &&
                     !isempty(dirty_object_ids) &&
                     model.binding_cache.distributed_outputs isa
                     NoCompiledDistributedOutputs
        if can_extend && delta.structural_kind == :addition
            model.binding_cache = _extend_compiled_scene(
                model,
                model.binding_cache,
                dirty_object_ids,
                ;
                performance=performance,
            )
        elseif can_extend && delta.structural_kind == :structural
            delta = _prepare_structural_compiled_delta(
                model,
                model.binding_cache,
                dirty_object_ids,
                performance,
            )
            model.binding_cache = _extend_compiled_scene(
                model,
                delta.compiled,
                dirty_object_ids;
                forced_input_binding_keys=delta.forced_input_binding_keys,
                forced_call_target_keys=delta.forced_call_target_keys,
                previous_temporal_sources_seed=delta.previous_temporal_sources,
                changed_application_ids_seed=delta.changed_application_ids,
                changed_target_ids_seed=delta.changed_target_ids,
                pure_addition=false,
                structural_dirty_ids=dirty_object_ids,
                performance=performance,
            )
            _remove_stale_status_views!(
                model.binding_cache,
                delta.changed_target_ids,
            )
        else
            previous_binding_cache = model.binding_cache
            refreshed_binding_cache = compile_composite_model(
                model,
                model.applications;
                performance=performance,
            )
            if !force &&
               !isnothing(previous_binding_cache) &&
               previous_binding_cache.distributed_outputs isa
               CompiledDistributedOutputs
                _preserve_recompiled_model_status_views!(
                    refreshed_binding_cache,
                    previous_binding_cache,
                )
            end
            model.binding_cache = refreshed_binding_cache
        end
        model.bindings_dirty = false
        _consume_structural_lifecycle_delta!(model)
    end
    return model.binding_cache
end

function refresh_environment_bindings!(model::CompositeModel, compiled=refresh_bindings!(model); force::Bool=false)
    if force || model.environment_bindings_dirty || isnothing(model.environment_binding_cache)
        delta = model.lifecycle_delta
        if !force &&
           !isnothing(model.environment_binding_cache) &&
           !delta.full_environment
            model.environment_binding_cache = _refresh_environment_bindings_for_objects(
                model,
                compiled,
                model.environment_binding_cache,
                delta.environment_dirty_ids,
            )
        else
            model.environment_binding_cache = compile_environment_bindings(model, compiled)
        end
        model.environment_bindings_dirty = false
        _reset_lifecycle_delta_if_consumed!(model)
    elseif model.environment_binding_cache.model_revision == compiled.revision &&
           model.environment_binding_cache.environment_revision ==
           model.environment_revision &&
           model.environment_binding_cache.applications_identity ==
           objectid(compiled.applications)
        return model.environment_binding_cache
    else
        reconciled = _reconcile_environment_binding_metadata(
            model,
            compiled,
            model.environment_binding_cache,
        )
        model.environment_binding_cache = isnothing(reconciled) ?
                                          compile_environment_bindings(model, compiled) :
                                          reconciled
    end
    return model.environment_binding_cache
end

function object_ids(model::CompositeModel; scale=nothing, kind=nothing, species=nothing, name=nothing)
    registry = model.registry
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

model_objects(model::CompositeModel; kwargs...) = [_model_object(model, id) for id in object_ids(model; kwargs...)]

function _instance_object_ids(model::CompositeModel, instance::ObjectInstance)
    root_id = _instance_root_id(instance)
    haskey(model.registry.objects, root_id) || return ObjectId[]
    return _sort_object_ids!(_descendant_ids(model, root_id))
end

function _object_instance_name(model::CompositeModel, object_id::ObjectId)
    instance = _instance_for_object(model, object_id)
    return isnothing(instance) ? nothing : instance.name
end

function explain_objects(model::CompositeModel)
    return [
        (
            id=object.id.value,
            scale=object.scale,
            kind=object.kind,
            species=object.species,
            name=object.name,
            instance=_object_instance_name(model, object.id),
            parent=isnothing(object.parent) ? nothing : object.parent.value,
            children=[child.value for child in object.children],
            has_geometry=!isnothing(object.geometry),
            has_status=!isnothing(object.status),
            n_applications=length(object.applications),
        )
        for object in model_objects(model)
    ]
end

function _instance_application_ids(model::CompositeModel, instance::ObjectInstance)
    prefix = string(instance.name, "__")
    ids = Symbol[]
    for application in model.applications
        name = application_name(as_model_spec(application))
        isnothing(name) && continue
        startswith(string(name), prefix) && push!(ids, name)
    end
    return sort!(ids; by=string)
end

function explain_instances(model::CompositeModel)
    return [
        (
            name=instance.name,
            root_id=_instance_root_id(instance).value,
            kind=instance.template.kind,
            species=instance.template.species,
            object_ids=[id.value for id in _instance_object_ids(model, instance)],
            application_ids=_instance_application_ids(model, instance),
            instance_overrides=sort!(Symbol[Symbol(name) for name in keys(instance.overrides)]; by=string),
            object_overrides=[
                (
                    object_id=override.object.value,
                    application=override.application,
                    model_type=typeof(override.model),
                )
                for override in instance.object_overrides
            ],
            parameters_type=typeof(instance.template.parameters),
            parameters_shared_by_reference=true,
        )
        for instance in model.instances
    ]
end

function _object_id_values(ids)
    return [id.value for id in _sort_object_ids!(collect(ids))]
end

function _label_scope_rows(model::CompositeModel, scope_type::Symbol, label::Symbol, index)
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

function explain_scopes(model::CompositeModel)
    rows = NamedTuple[]
    all_ids = object_ids(model)
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
    for object in model_objects(model)
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
        descendant_ids = _object_id_values(_descendant_ids(model, object.id))
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
    append!(rows, _label_scope_rows(model, :scale, :scale, model.registry.by_scale))
    append!(rows, _label_scope_rows(model, :kind, :kind, model.registry.by_kind))
    append!(rows, _label_scope_rows(model, :species, :species, model.registry.by_species))
    return rows
end
