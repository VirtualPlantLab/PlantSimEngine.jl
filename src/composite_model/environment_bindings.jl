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
    backends,
    dirty_object_ids=nothing,
)
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

function _update_model_environment_indices!(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    dirty_object_ids=nothing,
)
    return _update_model_environment_indices!(
        model,
        _model_environment_backends(model, compiled),
        dirty_object_ids,
    )
end

function _update_model_environment_indices_for_objects!(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    application_ids = Set{Symbol}()
    for object_id in dirty_object_ids
        _foreach_object_application(compiled, object_id) do application
            push!(application_ids, application.id)
        end
        for target in get(cached.targets_by_object, object_id, ())
            push!(application_ids, target[1])
        end
    end
    backends = Any[]
    seen = Set{UInt}()
    for application_id in application_ids
        plan = cached.application_plans_by_id[application_id]
        backend = plan.backend
        isnothing(backend) && continue
        id = objectid(backend)
        id in seen && continue
        push!(seen, id)
        push!(backends, backend)
    end
    return _update_model_environment_indices!(
        model,
        backends,
        dirty_object_ids,
    )
end

function _environment_variable_names(vars)
    return Tuple(Symbol(var) for var in keys(vars))
end

function _environment_source_variable_names(sampling_rules)
    return Tuple(Symbol(source) for (_, source) in sampling_rules)
end

# Raw singleton sampling returns the source itself. Other sampling recipes
# retain Any until their result schema is known; preparation never samples a
# custom source merely to discover its return type.
function _global_environment_sample_schema(backend, source, sampler, uses_raw::Bool, prepare_runtime::Bool)
    R = prepare_runtime && isnothing(sampler) && uses_raw &&
        backend isa GlobalConstant &&
        DataFormat(environment_source(backend)) isa SingletonAlike ? typeof(source) : Any
    return GlobalEnvironmentSampleSchema{R}()
end

function _compile_environment_application_plans(
    model::CompositeModel,
    applications;
    previous_plans_by_id=nothing,
    prepare_runtime::Bool=true,
)
    plans = CompiledEnvironmentApplicationPlan[]
    plans_by_id = Dict{Symbol,CompiledEnvironmentApplicationPlan}()
    samplers_by_source = IdDict{Any,Any}()
    prepared_by_source = IdDict{Any,Any}()
    if !isnothing(previous_plans_by_id)
        for plan in values(previous_plans_by_id)
            plan.backend isa GlobalConstant || continue
            source = environment_source(plan.backend)
            samplers_by_source[source] = plan.sampler
            prepared_by_source[source] = plan.prepared_source
        end
    end
    for application in applications
        config = environment_config(application.spec)
        backend = _environment_backend_from_config(model, config)
        bindings, environment_sources = _environment_sampling_configuration(application.spec)
        required_inputs = _model_environment_input_names(application)
        sampling_rules = Tuple(_environment_sampling_rules(bindings, environment_sources, required_inputs))
        compiled_sampling_rules = Tuple(
            CompiledEnvironmentSamplingRule(target, source)
            for (target, source) in sampling_rules
        )
        source_inputs = _environment_source_variable_names(sampling_rules)
        produced_outputs = _model_environment_output_names(application)
        sampler = nothing
        prepared_source = nothing
        if prepare_runtime && backend isa GlobalConstant
            source = environment_source(backend)
            sampler = get!(samplers_by_source, source) do
                _prepare_environment_sampler(source)
            end
            prepared_source = get!(prepared_by_source, source) do
                _prepare_global_environment(source)
            end
        end
        has_bindings = !isempty(keys(bindings))
        has_source_overrides = !isempty(keys(environment_sources))
        uses_raw_global_source = backend isa GlobalConstant &&
                                 isnothing(sampler) &&
                                 !has_bindings && !has_source_overrides
        plan = CompiledEnvironmentApplicationPlan(
            application.id,
            backend,
            config,
            required_inputs,
            source_inputs,
            produced_outputs,
            sampling_rules,
            compiled_sampling_rules,
            sampler,
            prepared_source,
            uses_raw_global_source,
            _global_environment_sample_schema(
                backend, prepared_source, sampler, uses_raw_global_source, prepare_runtime,
            ),
        )
        push!(plans, plan)
        haskey(plans_by_id, application.id) && error(
            "Environment application-plan compilation produced duplicate application id `$(application.id)`.",
        )
        plans_by_id[application.id] = plan
    end
    return plans, plans_by_id
end

function _compile_environment_bindings_for_applications(
    model::CompositeModel,
    applications,
    plans_by_id,
)
    bindings = CompiledEnvironmentBinding[]
    for application in applications
        plan = plans_by_id[application.id]
        for object_id in application.target_ids
            object = _model_object(model, object_id)
            context = _object_environment_context(application, object)
            binding_object, geometry_source_object_id, geometry_source =
                _environment_binding_object(model, object)
            handle = bind_environment(
                plan.backend,
                binding_object,
                context,
                _environment_config_payload(plan.config),
            )
            push!(
                bindings,
                CompiledEnvironmentBinding(
                    plan,
                    object_id,
                    handle,
                    context,
                    geometry_source_object_id,
                    geometry_source,
                ),
            )
        end
    end
    return bindings
end

function _compile_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    plans_by_id,
)
    return _compile_environment_bindings_for_applications(
        model,
        compiled.applications,
        plans_by_id,
    )
end

function _validate_model_environment_inputs!(bindings, applications_by_id)
    missing_rows = NamedTuple[]
    for binding in bindings
        available = environment_variables(binding.backend)
        isnothing(available) && continue
        application = applications_by_id[binding.application_id]
        for (target, source) in binding.sampling_rules
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

struct PreparedGlobalEnvironmentRows{R}
    rows::R
end

@inline _environment_row_at_step(
    prepared::PreparedGlobalEnvironmentRows,
    step::Int,
) = @inbounds prepared.rows[step]

# Rule names are fixed in the compiled plan's tuple type. Materializing this
# zero-size schema is a compiler constant, not a scan or a sampled-value cache.
@generated function _prepared_environment_inputs(::R) where {R<:Tuple}
    targets = Tuple(rule.parameters[1] for rule in R.parameters)
    sources = Tuple(rule.parameters[2] for rule in R.parameters)
    return :(PreparedEnvironmentInputs{$(QuoteNode(targets)),$(QuoteNode(sources)),false}())
end

@inline function _sample_compiled_global_environment_row(row, rules::Tuple)
    return _sample_prepared_global_environment_row(row, _prepared_environment_inputs(rules))
end

# A `GlobalConstant` table is immutable simulation input. Materialize
# heterogeneous DataFrame rows once so model kernels receive concrete
# `NamedTuple` rows instead of type-erased `DataFrameRow` property values.
_prepare_global_environment(source::DataFrames.AbstractDataFrame) =
    PreparedGlobalEnvironmentRows(Tables.rowtable(source))
_prepare_global_environment(source) = source

function _compiled_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    application_plans,
    application_plans_by_id,
    bindings,
    by_target,
    sample_cache=Dict{Tuple{Symbol,Int},Any}(),
    positions_by_target=_index_environment_binding_positions(
        bindings, keytype(model.registry.objects),
    ),
    targets_by_object=_index_environment_targets_by_object(
        bindings, keytype(model.registry.objects),
    ),
)
    return CompiledEnvironmentBindings(
        model,
        application_plans,
        application_plans_by_id,
        bindings,
        by_target,
        positions_by_target,
        targets_by_object,
        sample_cache,
        model.revision,
        model.environment_revision,
        compiled.applications,
    )
end

# The binding vector may contain several concrete handle/plan families. These
# indexes need only the fixed metadata fields, never a sampled environment.
@inline function _environment_binding_target_key(binding::CompiledEnvironmentBinding,
    ::Type{I},
) where {I<:ObjectId}
    plan = getfield(binding, :plan)::CompiledEnvironmentApplicationPlan
    return (getfield(plan, :application_id), getfield(binding, :object_id)::I)
end

function _index_environment_binding_positions(bindings, ::Type{I}) where {I<:ObjectId}
    return Dict{Tuple{Symbol,I},Int}(
        _environment_binding_target_key(binding, I) => index
        for (index, binding) in pairs(bindings)
    )
end

function _index_environment_targets_by_object(bindings, ::Type{I}) where {I<:ObjectId}
    targets_by_object = Dict{I,Vector{Tuple{Symbol,I}}}()
    for binding in bindings
        target = _environment_binding_target_key(binding, I)
        push!(
            get!(targets_by_object, target[2]) do
                Tuple{Symbol,I}[]
            end,
            target,
        )
    end
    return targets_by_object
end

function _index_environment_bindings(bindings, ::Type{I}) where {I<:ObjectId}
    # Keep lifecycle indexing open to future binding families; reads validate the
    # CompiledEnvironmentBinding domain. Execution targets retain concrete
    # handles and sampling plans.
    by_target = Dict{Tuple{Symbol,I},Any}()
    sizehint!(by_target, length(bindings))
    for binding in bindings
        by_target[_environment_binding_target_key(binding, I)] = binding
    end
    length(by_target) == length(bindings) || error(
        "Environment binding compilation produced duplicate `(application_id, object_id)` targets.",
    )
    return by_target
end

function compile_environment_bindings(model::CompositeModel, compiled::CompiledCompositeModel=refresh_bindings!(model))
    _update_model_environment_indices!(model, compiled)
    application_plans, application_plans_by_id =
        _compile_environment_application_plans(model, compiled.applications)
    bindings = _compile_environment_bindings(
        model,
        compiled,
        application_plans_by_id,
    )
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = _index_environment_bindings(bindings, keytype(model.registry.objects))
    return _compiled_environment_bindings(
        model,
        compiled,
        application_plans,
        application_plans_by_id,
        bindings,
        by_target,
    )
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

function _same_environment_application_plan(a, b)
    return _same_environment_backend(a.backend, b.backend) &&
           isequal(a.config, b.config) &&
           a.required_inputs == b.required_inputs &&
           a.source_inputs == b.source_inputs &&
           a.produced_outputs == b.produced_outputs &&
           a.sampling_rules == b.sampling_rules &&
           typeof(a.compiled_sampling_rules) ===
           typeof(b.compiled_sampling_rules) &&
           a.sampler === b.sampler &&
           a.prepared_source === b.prepared_source &&
           a.uses_raw_global_source == b.uses_raw_global_source &&
           typeof(a.sample_schema) === typeof(b.sample_schema)
end

function _reconciled_environment_application_plans(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
)
    candidates, candidates_by_id = _compile_environment_application_plans(
        model,
        compiled.applications;
        previous_plans_by_id=cached.application_plans_by_id,
    )
    plans = CompiledEnvironmentApplicationPlan[]
    plans_by_id = Dict{Symbol,CompiledEnvironmentApplicationPlan}()
    for candidate in candidates
        old = get(cached.application_plans_by_id, candidate.application_id, nothing)
        if !isnothing(old)
            _same_environment_backend(old.backend, candidate.backend) ||
                return nothing
            isequal(old.config, candidate.config) || return nothing
        end
        plan = !isnothing(old) &&
               _same_environment_application_plan(old, candidate) ?
               old : candidates_by_id[candidate.application_id]
        push!(plans, plan)
        plans_by_id[plan.application_id] = plan
    end
    return plans, plans_by_id
end

function _reconcile_environment_binding_metadata(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
)
    expected_count = sum(length(application.target_ids) for application in compiled.applications)
    expected_count == length(cached.bindings) || return nothing
    reconciled_plans = _reconciled_environment_application_plans(
        model,
        compiled,
        cached,
    )
    isnothing(reconciled_plans) && return nothing
    application_plans, application_plans_by_id = reconciled_plans

    bindings = CompiledEnvironmentBinding[]
    changed = false
    for application in compiled.applications
        plan = application_plans_by_id[application.id]
        for object_id in application.target_ids
            key = (application.id, object_id)
            old = get(cached.by_target, key, nothing)::Union{Nothing,CompiledEnvironmentBinding}
            isnothing(old) && return nothing
            object = _model_object(model, object_id)
            context = _object_environment_context(application, object)
            _, geometry_source_object_id, geometry_source =
                _environment_binding_object(model, object)
            _same_environment_backend(old.backend, plan.backend) || return nothing
            isequal(old.config, plan.config) || return nothing
            old.geometry_source_object_id == geometry_source_object_id ||
                return nothing
            old.geometry_source == geometry_source || return nothing
            _same_environment_context(old.context, context) || return nothing

            if old.plan === plan
                push!(bindings, old)
            else
                changed = true
                push!(
                    bindings,
                    CompiledEnvironmentBinding(
                        plan,
                        object_id,
                        old.handle,
                        context,
                        geometry_source_object_id,
                        geometry_source,
                    ),
                )
            end
        end
    end
    changed || return _compiled_environment_bindings(
        model,
        compiled,
        cached.application_plans,
        cached.application_plans_by_id,
        cached.bindings,
        cached.by_target,
        cached.sample_cache,
        cached.positions_by_target,
        cached.targets_by_object,
    )
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id)
    by_target = _index_environment_bindings(bindings, keytype(model.registry.objects))
    return _compiled_environment_bindings(
        model,
        compiled,
        application_plans,
        application_plans_by_id,
        bindings,
        by_target,
        cached.sample_cache,
    )
end

function _refresh_environment_bindings_for_objects(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    dirty_ids = ObjectId[dirty_object_ids...]
    _sort_object_ids!(dirty_ids)
    _update_model_environment_indices_for_objects!(
        model,
        compiled,
        cached,
        dirty_ids,
    )
    stale_targets = Set{Tuple{Symbol,ObjectId}}()
    replacements = Dict{Tuple{Symbol,ObjectId},CompiledEnvironmentBinding}()
    for object_id in dirty_ids
        current_applications = _application_membership_slots(compiled, object_id)
        previous_targets = get(cached.targets_by_object, object_id, ())
        isempty(current_applications) && isempty(previous_targets) && continue
        current_application_ids = Set{Symbol}()
        for slot in current_applications
            _with_metadata_entry(current_applications.applications, slot) do application
                push!(current_application_ids, application.id)
            end
        end
        for target in previous_targets
            target[1] in current_application_ids ||
                push!(stale_targets, target)
        end
        haskey(model.registry.objects, object_id) || continue
        for slot in current_applications
            _with_metadata_entry(current_applications.applications, slot) do application
                partial_application = _partial_model_application(application, ObjectId[object_id])
                for binding in _compile_environment_bindings_for_applications(
                    model,
                    (partial_application,),
                    cached.application_plans_by_id,
                )
                    replacements[(
                        binding.application_id,
                        binding.object_id,
                    )] = binding
                end
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
        object_targets = cached.targets_by_object[target[2]]
        target_index = findfirst(==(target), object_targets)
        isnothing(target_index) || deleteat!(object_targets, target_index)
        isempty(object_targets) && delete!(cached.targets_by_object, target[2])
    end
    for (target, binding) in replacements
        position = get(cached.positions_by_target, target, nothing)
        if isnothing(position)
            push!(cached.bindings, binding)
            cached.positions_by_target[target] =
                lastindex(cached.bindings)
            push!(
                get!(cached.targets_by_object, binding.object_id) do
                    Tuple{Symbol,ObjectId}[]
                end,
                target,
            )
        else
            cached.bindings[position] = binding
        end
        cached.by_target[target] = binding
    end
    return _compiled_environment_bindings(
        model,
        compiled,
        cached.application_plans,
        cached.application_plans_by_id,
        cached.bindings,
        cached.by_target,
        cached.sample_cache,
        cached.positions_by_target,
        cached.targets_by_object,
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
            sampling_rules=binding.sampling_rules,
            temporal_sampler=!isnothing(binding.sampler),
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
    return explain_environment_bindings(refresh_environment_bindings!(deepcopy(model)))
end

function refresh_environment_bindings!(model::CompositeModel, compiled=refresh_bindings!(model); force::Bool=false)
    cached = getfield(model, :environment_binding_cache)::Union{Nothing,CompiledEnvironmentBindings}
    return _refresh_environment_bindings!(model, compiled, cached; force)
end

# Canonical model caches keep the same container schema: plan/binding Vectors,
# Symbol/target/object Dicts, the sample Dict, and SC == typeof(model). Backends,
# handles, remapping, and alternate compiled applications remain values inside
# those containers. Targeted partial shells are never installed in this cache.
# Use the prepared shell only as its type witness; the current model cache is
# authoritative and can have been replaced by a public refresh in the meantime.
@inline function _current_environment_binding_owner(model::CompositeModel,
    ::E,
) where {E<:CompiledEnvironmentBindings}
    return getfield(model, :environment_binding_cache)::Union{Nothing,E}
end

function _refresh_environment_bindings!(model::CompositeModel, compiled,
    cached::Union{Nothing,CompiledEnvironmentBindings}; force::Bool=false,
)
    if force || model.environment_bindings_dirty || isnothing(cached)
        delta = model.lifecycle_delta
        refreshed = if !force && !isnothing(cached) && !delta.full_environment
            # A public Advanced refresh may have prepared another application
            # set. Reconcile that current owner before using its plans for a
            # partial event in this compiled scene.
            partial_owner = cached.compiled_applications === compiled.applications ?
                            cached : _reconcile_environment_binding_metadata(model, compiled, cached)
            if isnothing(partial_owner)
                compile_environment_bindings(model, compiled)
            else
                _refresh_environment_bindings_for_objects(
                    model,
                    compiled,
                    partial_owner,
                    delta.environment_dirty_ids,
                )
            end
        else
            compile_environment_bindings(model, compiled)
        end
        model.environment_binding_cache = refreshed
        _record_runtime_owner_replacement!(model, cached, refreshed)
        model.environment_bindings_dirty = false
        _reset_lifecycle_delta_if_consumed!(model)
        return refreshed
    elseif cached.model_revision == compiled.revision &&
           cached.environment_revision == model.environment_revision &&
           cached.compiled_applications === compiled.applications
        return cached
    else
        reconciled = _reconcile_environment_binding_metadata(model, compiled, cached)
        refreshed = isnothing(reconciled) ?
                    compile_environment_bindings(model, compiled) : reconciled
        model.environment_binding_cache = refreshed
        _record_runtime_owner_replacement!(model, cached, refreshed)
        return refreshed
    end
end
