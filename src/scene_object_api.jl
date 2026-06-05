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

mutable struct Scene{R,A,E}
    registry::R
    applications::A
    environment::E
    binding_cache::Any
    environment_binding_cache::Any
    bindings_dirty::Bool
    environment_bindings_dirty::Bool
    revision::Int
    environment_revision::Int
end

function Scene(objects::Object...; applications=(), environment=nothing)
    scene = Scene(SceneRegistry(), applications, environment, nothing, nothing, true, true, 0, 0)
    for object in objects
        register_object!(scene, object)
    end
    return scene
end

function _mark_environment_bindings_dirty!(scene::Scene)
    scene.environment_binding_cache = nothing
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
    isnothing(object.name) || (registry.by_name[object.name] = object.id)
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

function register_object!(scene::Scene, object::Object; parent=object.parent)
    registry = scene.registry
    haskey(registry.objects, object.id) && error("Scene already contains object id `$(object.id.value)`.")
    object.parent = isnothing(parent) ? nothing : ObjectId(parent)
    registry.objects[object.id] = object
    _index_object!(registry, object)
    if !isnothing(object.parent)
        parent_object = _scene_object(scene, object.parent)
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
    object = _scene_object(scene, id)
    object.geometry = geometry_or_position
    _mark_environment_bindings_dirty!(scene)
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
        scene.environment_binding_cache = compile_environment_bindings(scene, compiled)
        scene.environment_bindings_dirty = false
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

function explain_objects(scene::Scene)
    return [
        (
            id=object.id.value,
            scale=object.scale,
            kind=object.kind,
            species=object.species,
            name=object.name,
            parent=isnothing(object.parent) ? nothing : object.parent.value,
            children=[child.value for child in object.children],
            has_geometry=!isnothing(object.geometry),
            has_status=!isnothing(object.status),
            n_applications=length(object.applications),
        )
        for object in scene_objects(scene)
    ]
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
end
Relation(relation::Union{Symbol,AbstractString}) = Relation(Symbol(relation))

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
        isnothing(root_id) && error("No named scope or object `$(scope.name)` found in the scene registry.")
        return _descendant_ids(scene, root_id)
    end

    error("Unsupported object scope selector `$(scope)` of type `$(typeof(scope))`.")
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

function _resolve_object_ids(scene::Scene, selector::AbstractObjectMultiplicity; context=nothing, default_to_context::Bool=false)
    criteria_ = criteria(selector)
    relation = _criteria_value(criteria_, :relation, Relation)
    isnothing(relation) || error("`Relation(...)` selector resolution is not implemented yet.")

    scope = _criteria_scope(criteria_)
    scale = _criteria_value(criteria_, :scale, Scale)
    kind = _criteria_value(criteria_, :kind, Kind)
    species = _criteria_value(criteria_, :species, Species)
    name = haskey(criteria_, :name) ? criteria_.name : nothing

    if default_to_context &&
       isnothing(scope) &&
       isnothing(scale) &&
       isnothing(kind) &&
       isnothing(species) &&
       isnothing(name) &&
       !isnothing(context)
        return ObjectId[_object_id_from_context(context)]
    end

    candidate_ids = _scope_object_ids(scene, scope, context)
    ids = ObjectId[
        id for id in candidate_ids
        if _matches_object_criteria(_scene_object(scene, id); scale=scale, kind=kind, species=species, name=name)
    ]
    _sort_object_ids!(ids)

    if selector isa One && length(ids) != 1
        error("Expected exactly one object for selector `$(selector)`, got $(length(ids)).")
    elseif selector isa OptionalOne && length(ids) > 1
        error("Expected zero or one object for selector `$(selector)`, got $(length(ids)).")
    end
    return ids
end

resolve_objects(scene::Scene, selector::AbstractObjectMultiplicity; context=nothing) =
    [_scene_object(scene, id) for id in resolve_object_ids(scene, selector; context=context)]

struct CompiledSceneApplication{S,AT,TS,CL}
    id::Symbol
    spec::S
    process::Symbol
    name::Union{Nothing,Symbol}
    target_ids::Vector{ObjectId}
    applies_to::AT
    timestep::TS
    clock::CL
end

struct CompiledSceneInputBinding{SEL,P,W,C}
    application_id::Symbol
    consumer_id::ObjectId
    input::Symbol
    selector::SEL
    origin::Symbol
    source_ids::Vector{ObjectId}
    source_var::Symbol
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
    produced_outputs::Vector{Symbol}
    support::S
    config::Any
end

struct CompiledEnvironmentBindings{SC,B}
    scene::SC
    bindings::B
    scene_revision::Int
    environment_revision::Int
end

struct CompiledScene{SC,AP,IB,CB}
    scene::SC
    applications::AP
    input_bindings::IB
    call_bindings::CB
    revision::Int
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
    _validate_scene_writers!(applications)
    input_bindings = _compile_scene_input_bindings(scene, applications)
    call_bindings = _compile_scene_call_bindings(scene, applications)
    return CompiledScene(scene, applications, input_bindings, call_bindings, scene.revision)
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
                _scene_application_clock(spec, timeline),
            ),
        )
    end
    return applications
end

function _scene_output_names(application::CompiledSceneApplication)
    return Symbol[Symbol(var) for var in keys(outputs_(application.spec))]
end

function _scene_writer_groups(applications)
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for (index, application) in pairs(applications)
        for object_id in application.target_ids
            for variable in _scene_output_names(application)
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

function _validate_scene_writers!(applications)
    for ((object_id, variable), indexed_writers) in _scene_writer_groups(applications)
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

function _scene_application_clock(spec, timeline)
    clock = _clock_from_spec_timestep(timestep(spec), timeline)
    isnothing(clock) && return ClockSpec(1.0, 0.0)
    return clock
end

function _criteria_get(criteria, key::Symbol, default=nothing)
    return haskey(criteria, key) ? getproperty(criteria, key) : default
end

function _selector_policy(selector::AbstractObjectMultiplicity)
    return _criteria_get(criteria(selector), :policy, HoldLast())
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
    return _resolve_object_ids(scene, selector; context=context, default_to_context=true)
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

input_carrier(binding::CompiledSceneInputBinding) = binding.carrier
has_reference_carrier(binding::CompiledSceneInputBinding) = !isnothing(binding.carrier)
input_value(binding::CompiledSceneInputBinding) = _input_value(binding.carrier)
_input_value(::Nothing) = nothing
_input_value(carrier::Base.RefValue) = carrier[]
_input_value(carrier::RefVector) = carrier
_input_value(carrier::ObjectRefVector) = carrier

function _compile_scene_input_bindings(scene::Scene, applications)
    bindings = CompiledSceneInputBinding[]
    by_object = _applications_by_object(applications)
    for application in applications
        for consumer_id in application.target_ids
            declared_inputs = value_inputs(application.spec)
            declared_inputs isa NamedTuple || (declared_inputs = NamedTuple())
            for (input_name, selector) in pairs(declared_inputs)
                input_sym = Symbol(input_name)
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
                    :declared,
                )
            end
            _append_inferred_scene_input_bindings!(bindings, scene, application, consumer_id, declared_inputs, by_object)
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
    source_ids_override=nothing,
)
    source_ids = isnothing(source_ids_override) ? _dependency_object_ids(scene, selector, consumer_id) : source_ids_override
    policy = _selector_policy(selector)
    window = _selector_window(selector)
    source_var = _selector_var(selector, input_sym)
    carrier = _input_carrier(scene, selector, source_ids, source_var)
    push!(
        bindings,
        CompiledSceneInputBinding(
            application.id,
            consumer_id,
            input_sym,
            selector,
            origin,
            source_ids,
            source_var,
            multiplicity(selector),
            policy,
            window,
            _carrier_hint(selector, policy, window),
            carrier,
        ),
    )
    return bindings
end

function _scene_input_names(application::CompiledSceneApplication)
    return Symbol[Symbol(var) for var in keys(inputs_(application.spec))]
end

function _same_object_output_applications(applications_by_object, application::CompiledSceneApplication, object_id::ObjectId, variable::Symbol)
    matches = CompiledSceneApplication[]
    for candidate in get(applications_by_object, object_id, Any[])
        candidate.id == application.id && continue
        variable in _scene_output_names(candidate) || continue
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
            ObjectId[consumer_id],
        )
    end
    return bindings
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
                if isempty(callee_application_ids)
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
            model_type=typeof(model_(application.spec)),
        )
        for application in compiled.applications
    ]
end

function explain_schedule(compiled::CompiledScene)
    timeline = _scene_timeline(compiled.scene)
    manual_application_ids = _manual_call_application_ids(compiled)
    return [
        (
            application_id=application.id,
            process=application.process,
            timestep=application.timestep,
            clock=application.clock,
            dt_steps=application.clock.dt,
            phase=application.clock.phase,
            dt_seconds=float(application.clock.dt) * timeline.base_step_seconds,
            target_ids=[id.value for id in application.target_ids],
            root_scheduled=!(application.id in manual_application_ids),
            manual_call_only=application.id in manual_application_ids,
        )
        for application in compiled.applications
    ]
end

function explain_bindings(compiled::CompiledScene)
    return [
        (
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            input=binding.input,
            origin=binding.origin,
            source_ids=[id.value for id in binding.source_ids],
            source_var=binding.source_var,
            multiplicity=binding.multiplicity,
            policy=binding.policy,
            window=binding.window,
            carrier_hint=binding.carrier_hint,
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
            callee_object_ids=[id.value for id in binding.callee_object_ids],
            callee_application_ids=binding.callee_application_ids,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            selector=binding.selector,
        )
        for binding in compiled.call_bindings
    ]
end

function explain_writers(compiled::CompiledScene)
    groups = _scene_writer_groups(compiled.applications)
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

function _compile_environment_bindings(scene::Scene, compiled::CompiledScene)
    bindings = CompiledEnvironmentBinding[]
    for application in compiled.applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(scene, config)
        provider = _environment_provider_from_config(config, backend)
        required_inputs = _environment_variable_names(meteo_inputs_(application.spec))
        produced_outputs = _environment_variable_names(meteo_outputs_(application.spec))
        for object_id in application.target_ids
            object = _scene_object(scene, object_id)
            support = _object_environment_support(application, object)
            cell = bind_environment(backend, object, support, _environment_config_payload(config))
            push!(
                bindings,
                CompiledEnvironmentBinding(
                    application.id,
                    object_id,
                    provider,
                    backend,
                    cell,
                    required_inputs,
                    produced_outputs,
                    support,
                    config,
                ),
            )
        end
    end
    return bindings
end

function compile_environment_bindings(scene::Scene, compiled::CompiledScene=refresh_bindings!(scene))
    _update_scene_environment_indices!(scene, compiled)
    return CompiledEnvironmentBindings(
        scene,
        _compile_environment_bindings(scene, compiled),
        scene.revision,
        scene.environment_revision,
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
            produced_outputs=binding.produced_outputs,
            support=binding.support,
            config=binding.config,
        )
        for binding in compiled.bindings
    ]
end

function explain_environment_bindings(scene::Scene)
    return explain_environment_bindings(refresh_environment_bindings!(scene))
end

struct SceneRunContext{CS,EB,A,TS,C}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::ObjectId
    temporal_streams::TS
    time::Float64
    constants::C
end

struct SceneCallTarget{CS,EB,A,S,TS,C}
    compiled::CS
    environment_bindings::EB
    application::A
    object_id::ObjectId
    model
    status::S
    temporal_streams::TS
    time::Float64
    constants::C
end

function _compiled_application_by_id(compiled::CompiledScene, id::Symbol)
    for application in compiled.applications
        application.id == id && return application
    end
    error("No compiled scene application with id `$(id)`.")
end

function _environment_binding_for(env_bindings::CompiledEnvironmentBindings, application_id::Symbol, object_id::ObjectId)
    for binding in env_bindings.bindings
        binding.application_id == application_id && binding.object_id == object_id && return binding
    end
    return nothing
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

_scene_stream_key(object_id::ObjectId, variable::Symbol) = (object_id, variable)

function _scene_publish_outputs!(streams, application::CompiledSceneApplication, object_id::ObjectId, status, time::Real)
    isnothing(streams) && return nothing
    for variable in keys(outputs_(application.spec))
        var = Symbol(variable)
        hasproperty(status, var) || error(
            "Application `$(application.id)` declares output `$(var)`, but object ",
            "`$(object_id.value)` status has no such variable."
        )
        key = _scene_stream_key(object_id, var)
        samples = get!(streams, key, Tuple{Float64,Any}[])
        filter!(sample -> !isapprox(sample[1], float(time); atol=1.0e-8, rtol=0.0), samples)
        push!(samples, (float(time), getproperty(status, var)))
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

function _scene_window_samples(samples, t_start::Real, t_end::Real)
    return Any[value for (sample_t, value) in samples if float(t_start) <= sample_t <= float(t_end)]
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

function _scene_temporal_source_value(streams, source_id::ObjectId, source_var::Symbol, time::Real, policy, t_start::Real, timeline)
    samples = get(streams, _scene_stream_key(source_id, source_var), nothing)
    isnothing(samples) && return policy isa Union{Integrate,Aggregate} ? 0.0 : nothing
    if policy isa HoldLast
        return _scene_latest_sample(samples, time)
    elseif policy isa Union{Integrate,Aggregate}
        values = _scene_window_samples(samples, t_start, time)
        durations = fill(timeline.base_step_seconds, length(values))
        return _scene_window_reduce(values, durations, policy)
    elseif policy isa Interpolate
        return _scene_latest_sample(samples, time)
    end
    error("Unsupported scene temporal input policy `$(typeof(policy))`.")
end

function _scene_temporal_input_value(binding::CompiledSceneInputBinding, application::CompiledSceneApplication, streams, time::Real, timeline)
    window_steps = _scene_input_window_steps(binding, application, timeline)
    t_start = float(time) - float(window_steps) + 1.0
    if binding.multiplicity == :many
        return [
            _scene_temporal_source_value(streams, source_id, binding.source_var, time, binding.policy, t_start, timeline)
            for source_id in binding.source_ids
        ]
    end
    source_id = only(binding.source_ids)
    value = _scene_temporal_source_value(streams, source_id, binding.source_var, time, binding.policy, t_start, timeline)
    isnothing(value) && error(
        "No temporal scene value available for input `$(binding.input)` from ",
        "`$(source_id.value).$(binding.source_var)` at t=$(time)."
    )
    return value
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
    timeline = _scene_timeline(compiled.scene)
    for binding in compiled.input_bindings
        binding.application_id == application.id || continue
        binding.consumer_id == object_id || continue
        if binding.carrier_hint == :temporal_stream
            isnothing(streams) && continue
            value = _scene_temporal_input_value(binding, application, streams, time, timeline)
            _scene_assign_input_value!(status, binding.input, value)
        elseif has_reference_carrier(binding)
            _set_status_if_present!(status, binding.input, input_value(binding))
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
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
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
    isnothing(binding) && return nothing
    isnothing(binding.backend) && return nothing
    return scatter_environment_outputs!(binding.backend, binding.support, time, application.spec, status)
end

function _run_scene_application!(
    compiled::CompiledScene,
    env_bindings::CompiledEnvironmentBindings,
    application::CompiledSceneApplication,
    object_id::ObjectId;
    time::Real=1,
    constants=nothing,
    temporal_streams=nothing,
    publish::Bool=true,
)
    status = _materialize_scene_inputs!(compiled, application, object_id, temporal_streams, time)
    meteo = _scene_meteo_for_model(env_bindings, application, object_id, time)
    context = SceneRunContext(compiled, env_bindings, application, object_id, temporal_streams, float(time), constants)
    run!(application.spec, nothing, status, meteo, constants, context)
    if publish
        _scatter_scene_environment_outputs!(env_bindings, application, object_id, status, time)
        _scene_publish_outputs!(temporal_streams, application, object_id, status, time)
    end
    return status
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

function _scene_call_targets(context::SceneRunContext, name::Symbol)
    targets = SceneCallTarget[]
    for binding in context.compiled.call_bindings
        binding.application_id == context.application.id || continue
        binding.consumer_id == context.object_id || continue
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
                        model_(callee_application.spec),
                        status,
                        context.temporal_streams,
                        context.time,
                        context.constants,
                    ),
                )
            end
        end
    end
    return targets
end

dependency_targets(context::SceneRunContext, name::Symbol) = _scene_call_targets(context, name)
dependency_target(context::SceneRunContext, name::Symbol) = only(dependency_targets(context, name))

function run_call!(target::SceneCallTarget; publish::Bool=true)
    _run_scene_application!(
        target.compiled,
        target.environment_bindings,
        target.application,
        target.object_id;
        time=target.time,
        constants=target.constants,
        temporal_streams=target.temporal_streams,
        publish=publish,
    )
    return target
end

function run!(scene::Scene; steps::Integer=1, constants=nothing)
    compiled = refresh_bindings!(scene)
    env_bindings = refresh_environment_bindings!(scene, compiled)
    manual_application_ids = _manual_call_application_ids(compiled)
    temporal_streams = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Float64,Any}}}()
    for step in 1:steps
        for application in compiled.applications
            application.id in manual_application_ids && continue
            _scene_application_should_run(application, step) || continue
            for object_id in application.target_ids
                _run_scene_application!(
                    compiled,
                    env_bindings,
                    application,
                    object_id;
                    time=step,
                    constants=constants,
                    temporal_streams=temporal_streams,
                    publish=true,
                )
            end
        end
    end
    return scene
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
    scope = haskey(c, :within) ? c.within : nothing
    kind = haskey(c, :kind) ? c.kind : nothing
    species = haskey(c, :species) ? c.species : nothing
    scale = haskey(c, :scale) ? c.scale : nothing
    name = haskey(c, :name) ? c.name : nothing
    process = haskey(c, :process) ? c.process : nothing
    var = haskey(c, :var) ? c.var : nothing
    relation = haskey(c, :relation) ? c.relation : nothing
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
        first(binding) isa Union{Symbol,AbstractString} || error(
            "Binding names in `Inputs(...)` and `Calls(...)` must be symbols or strings."
        )
        push!(pairs, Symbol(first(binding)) => last(binding))
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
