function _environment_config_payload(config)
    config isa EnvironmentConfig && return config.config
    return config
end

function _environment_backend_from_config(model::CompositeModel, config)
    payload = _environment_config_payload(config)
    isnothing(payload) && return environment_backend(model.environment)
    payload isa NamedTuple && haskey(payload, :backend) && return environment_backend(payload.backend)
    payload isa AbstractEnvironmentBackend && return payload
    return environment_backend(model.environment)
end

function _object_environment_context(application::CompiledModelApplication, object::Object)
    scale = isnothing(object.scale) ? :Default : object.scale
    return EnvironmentContext(application.id, object.id, scale, application.process)
end

"""
    bind_environment(backend, object, context, config=nothing)

Compile and return an opaque backend-specific handle for one model target.
`context` contains immutable application/object metadata and `config` is the
payload declared with `Environment(...)`. Spatial backends should resolve the
object's geometry here and store the resulting cell, voxel, layer, provider, or
commit sink in a concrete handle. Runtime sampling and commits receive that
handle directly.
"""
bind_environment(backend, object::Object, context, config=nothing) = nothing

function _environment_binding_object(model::CompositeModel, object::Object)
    !isnothing(geometry(object)) && return object, object.id, :self
    ancestor_id = object.parent
    while !isnothing(ancestor_id)
        ancestor = _model_object(model, ancestor_id)
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

function _model_environment_entity(object::Object)
    return (
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
    )
end

function _model_environment_entities(model::CompositeModel, object_ids=nothing)
    objects = if isnothing(object_ids)
        model_objects(model)
    else
        (
            _model_object(model, object_id)
            for object_id in object_ids
            if haskey(model.registry.objects, object_id)
        )
    end
    return [_model_environment_entity(object) for object in objects]
end

function _model_environment_backends(model::CompositeModel, compiled::CompiledCompositeModel)
    backends = Any[]
    seen = Set{UInt}()
    for application in compiled.applications
        backend = _environment_backend_from_config(model, environment_config(application.spec))
        isnothing(backend) && continue
        id = objectid(backend)
        id in seen && continue
        push!(seen, id)
        push!(backends, backend)
    end
    return backends
end

function _update_model_environment_indices!(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    dirty_object_ids=nothing,
)
    backends = _model_environment_backends(model, compiled)
    filter!(backend -> !(backend isa GlobalConstant), backends)
    isempty(backends) && return nothing
    entities = _model_environment_entities(model, dirty_object_ids)
    removed_object_ids = isnothing(dirty_object_ids) ?
                         ObjectId[] :
                         ObjectId[
        object_id for object_id in dirty_object_ids
        if !haskey(model.registry.objects, object_id)
    ]
    for backend in backends
        update_index!(backend, entities, removed_object_ids)
    end
    return nothing
end

function _environment_variable_names(vars)
    return Symbol[Symbol(var) for var in keys(vars)]
end

function _environment_source_variable_names(model_spec)
    return Symbol[Symbol(source) for (_, source) in _environment_sampling_rules(model_spec)]
end

function _compile_environment_bindings_for_applications(model::CompositeModel, applications)
    bindings = CompiledEnvironmentBinding[]
    for application in applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(model, config)
        required_inputs = _environment_variable_names(environment_inputs_(application.spec))
        source_inputs = _environment_source_variable_names(application.spec)
        produced_outputs = _environment_variable_names(environment_outputs_(application.spec))
        for object_id in application.target_ids
            object = _model_object(model, object_id)
            context = _object_environment_context(application, object)
            binding_object, geometry_source_object_id, geometry_source =
                _environment_binding_object(model, object)
            handle = bind_environment(
                backend,
                binding_object,
                context,
                _environment_config_payload(config),
            )
            push!(
                bindings,
                CompiledEnvironmentBinding(
                    application.id,
                    object_id,
                    backend,
                    handle,
                    required_inputs,
                    source_inputs,
                    produced_outputs,
                    context,
                    geometry_source_object_id,
                    geometry_source,
                    config,
                ),
            )
        end
    end
    return bindings
end

_compile_environment_bindings(model::CompositeModel, compiled::CompiledCompositeModel) =
    _compile_environment_bindings_for_applications(model, compiled.applications)

function _validate_model_environment_inputs!(bindings, applications_by_id)
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
    error("Composite model environment is missing required source inputs: ", details)
end

function _model_environment_samplers(bindings)
    samplers_by_application = Dict{Symbol,Any}()
    prepared_sources = Tuple{Any,Any}[]
    for binding in bindings
        haskey(samplers_by_application, binding.application_id) && continue
        binding.backend isa GlobalConstant || continue
        source = environment_source(binding.backend)
        source_index = findfirst(entry -> entry[1] === source, prepared_sources)
        sampler = if isnothing(source_index)
            prepared = _prepare_environment_sampler(source)
            push!(prepared_sources, (source, prepared))
            prepared
        else
            prepared_sources[source_index][2]
        end
        samplers_by_application[binding.application_id] = sampler
    end
    return samplers_by_application
end

struct PreparedGlobalEnvironmentRows{R}
    rows::R
end

# A `GlobalConstant` table is immutable simulation input. Materialize
# heterogeneous DataFrame rows once so model kernels receive concrete
# `NamedTuple` rows instead of type-erased `DataFrameRow` property values.
_prepare_global_environment(source::DataFrames.AbstractDataFrame) =
    PreparedGlobalEnvironmentRows(Tables.rowtable(source))
_prepare_global_environment(source) = source

function _prepared_global_environment(bindings, cache=IdDict{Any,Any}())
    for binding in bindings
        binding.backend isa GlobalConstant || continue
        source = environment_source(binding.backend)
        haskey(cache, source) && continue
        cache[source] = _prepare_global_environment(source)
    end
    return cache
end

function _compiled_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    bindings,
    by_target,
    samplers_by_application=_model_environment_samplers(bindings),
    prepared_global_environment=_prepared_global_environment(bindings),
    sample_cache=Dict{Tuple{Symbol,Int},Any}(),
    positions_by_target=Dict(
        (binding.application_id, binding.object_id) => index
        for (index, binding) in pairs(bindings)
    ),
)
    return CompiledEnvironmentBindings(
        model,
        bindings,
        by_target,
        positions_by_target,
        samplers_by_application,
        prepared_global_environment,
        sample_cache,
        model.revision,
        model.environment_revision,
        objectid(compiled.applications),
    )
end

function _index_environment_bindings(bindings)
    by_target = Dict(
        (binding.application_id, binding.object_id) => binding
        for binding in bindings
    )
    length(by_target) == length(bindings) || error(
        "Environment binding compilation produced duplicate `(application_id, object_id)` targets.",
    )
    return by_target
end

function compile_environment_bindings(model::CompositeModel, compiled::CompiledCompositeModel=refresh_bindings!(model))
    _update_model_environment_indices!(model, compiled)
    bindings = _compile_environment_bindings(model, compiled)
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = _index_environment_bindings(bindings)
    return _compiled_environment_bindings(model, compiled, bindings, by_target)
end

function _same_environment_backend(a, b)
    a === b && return true
    if a isa GlobalConstant && b isa GlobalConstant
        return environment_source(a) === environment_source(b)
    end
    return false
end

function _same_environment_context(a, b)
    return a.application == b.application &&
           a.object_id == b.object_id &&
           a.scale == b.scale &&
           a.process == b.process
end

function _reconcile_environment_binding_metadata(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
)
    expected_count = sum(length(application.target_ids) for application in compiled.applications)
    expected_count == length(cached.bindings) || return nothing

    bindings = CompiledEnvironmentBinding[]
    changed = false
    for application in compiled.applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(model, config)
        required_inputs = _environment_variable_names(environment_inputs_(application.spec))
        source_inputs = _environment_source_variable_names(application.spec)
        produced_outputs = _environment_variable_names(environment_outputs_(application.spec))
        for object_id in application.target_ids
            key = (application.id, object_id)
            old = get(cached.by_target, key, nothing)
            isnothing(old) && return nothing
            object = _model_object(model, object_id)
            context = _object_environment_context(application, object)
            _, geometry_source_object_id, geometry_source =
                _environment_binding_object(model, object)
            _same_environment_backend(old.backend, backend) || return nothing
            isequal(old.config, config) || return nothing
            old.geometry_source_object_id == geometry_source_object_id ||
                return nothing
            old.geometry_source == geometry_source || return nothing
            _same_environment_context(old.context, context) || return nothing

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
                        backend,
                        old.handle,
                        required_inputs,
                        source_inputs,
                        produced_outputs,
                        context,
                        geometry_source_object_id,
                        geometry_source,
                        config,
                    ),
                )
            end
        end
    end
    changed || return cached
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = _index_environment_bindings(bindings)
    return _compiled_environment_bindings(model, compiled, bindings, by_target)
end

function _refresh_environment_bindings_for_objects(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    dirty_ids = ObjectId[dirty_object_ids...]
    _sort_object_ids!(dirty_ids)
    _update_model_environment_indices!(model, compiled, dirty_ids)
    stale_targets = Set{Tuple{Symbol,ObjectId}}()
    replacements = Dict{Tuple{Symbol,ObjectId},CompiledEnvironmentBinding}()
    for object_id in dirty_ids
        current_applications = get(
            compiled.applications_by_object,
            object_id,
            (),
        )
        current_application_ids = Set(
            application.id for application in current_applications
        )
        for application in compiled.applications
            target = (application.id, object_id)
            haskey(cached.by_target, target) || continue
            application.id in current_application_ids ||
                push!(stale_targets, target)
        end
        haskey(model.registry.objects, object_id) || continue
        for application in current_applications
            partial_application = CompiledModelApplication(
                application.id,
                application.spec,
                application.process,
                application.name,
                ObjectId[object_id],
                application.applies_to,
                application.timestep,
                application.clock,
                application.model_overrides,
            )
            for binding in _compile_environment_bindings_for_applications(
                model,
                (partial_application,),
            )
                replacements[(
                    binding.application_id,
                    binding.object_id,
                )] = binding
            end
        end
    end
    _validate_model_environment_inputs!(
        values(replacements),
        compiled.applications_by_id,
    )

    for target in stale_targets
        position = pop!(cached.positions_by_target, target)
        last_position = lastindex(cached.bindings)
        if position != last_position
            moved_binding = cached.bindings[last_position]
            cached.bindings[position] = moved_binding
            cached.positions_by_target[(
                moved_binding.application_id,
                moved_binding.object_id,
            )] = position
        end
        pop!(cached.bindings)
        delete!(cached.by_target, target)
    end
    for (target, binding) in replacements
        position = get(cached.positions_by_target, target, nothing)
        if isnothing(position)
            push!(cached.bindings, binding)
            cached.positions_by_target[target] =
                lastindex(cached.bindings)
        else
            cached.bindings[position] = binding
        end
        cached.by_target[target] = binding
    end
    return _compiled_environment_bindings(
        model,
        compiled,
        cached.bindings,
        cached.by_target,
        cached.samplers_by_application,
        cached.prepared_global_environment,
        cached.sample_cache,
        cached.positions_by_target,
    )
end

function explain_environment_bindings(compiled::CompiledEnvironmentBindings)
    rows = [
        (
            application_id=binding.application_id,
            object_id=binding.object_id.value,
            backend_type=isnothing(binding.backend) ? nothing : typeof(binding.backend),
            handle=binding.handle,
            required_inputs=binding.required_inputs,
            source_inputs=binding.source_inputs,
            produced_outputs=binding.produced_outputs,
            temporal_sampler=!isnothing(
                get(compiled.samplers_by_application, binding.application_id, nothing),
            ),
            geometry_source_object_id=isnothing(binding.geometry_source_object_id) ?
                                      nothing : binding.geometry_source_object_id.value,
            geometry_source=binding.geometry_source,
            context=binding.context,
            config=binding.config,
        )
        for binding in compiled.bindings
    ]
    sort!(
        rows;
        by=row -> (string(row.application_id), string(row.object_id)),
    )
    return rows
end

function explain_environment_bindings(model::CompositeModel)
    return explain_environment_bindings(refresh_environment_bindings!(model))
end
