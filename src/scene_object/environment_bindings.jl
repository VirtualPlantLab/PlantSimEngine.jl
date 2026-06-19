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
    return a.application == b.application &&
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

