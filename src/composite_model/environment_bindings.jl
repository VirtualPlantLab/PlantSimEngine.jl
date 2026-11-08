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

function _object_environment_context(application_id::Symbol, application_process::Symbol,
    object::Object, object_id::ObjectId,
)
    scale = isnothing(object.scale) ? :Default : object.scale
    return EnvironmentContext(application_id, object_id, scale, application_process)
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
    if !isnothing(geometry(object))
        object_id = _index_object_id(model.registry.objects, object.id)
        return object, object_id, :self
    end
    ancestor_id = object.parent
    while !isnothing(ancestor_id)
        ancestor_id = _index_object_id(model.registry.objects, ancestor_id)
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
            return proxy, ancestor_id, :ancestor
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
    # Backend index metadata may mix identity and geometry value types.
    entities = NamedTuple[]
    for object in objects
        push!(entities, _model_environment_entity(object))
    end
    return entities
end

function _model_environment_backends(model::CompositeModel,
    applications::CompiledMetadataTable{T},
) where {T}
    slots = Int[]
    seen = Set{UInt}()
    # Preserve actual discovery values, independently of the later plan pass.
    # The entry count is already encoded in the fixed application metadata.
    backends = ntuple(Val(fieldcount(T))) do slot
        _with_metadata_entry(applications, slot) do application
            backend = _environment_backend_from_config(model, environment_config(application.spec))
            if !isnothing(backend)
                id = objectid(backend)
                if !(id in seen)
                    push!(seen, id)
                    push!(slots, slot)
                end
            end
            return backend
        end
    end
    return CompiledMetadataTable(NamedTuple{fieldnames(T)}(backends)), slots
end

function _update_model_environment_indices!(
    with_backend,
    model::CompositeModel,
    entries,
    dirty_object_ids,
)
    filter!(entries) do entry
        with_backend(entry) do backend
            !(backend isa GlobalConstant)
        end
    end
    isempty(entries) && return nothing
    entities = _model_environment_entities(model, dirty_object_ids)
    removed_object_ids = isnothing(dirty_object_ids) ?
                         ObjectId[] :
                         ObjectId[
        object_id for object_id in dirty_object_ids
        if !haskey(model.registry.objects, object_id)
    ]
    for entry in entries
        with_backend(entry) do backend
            update_index!(backend, entities, removed_object_ids)
        end
    end
    return nothing
end

function _update_model_environment_indices!(model::CompositeModel, backends, dirty_object_ids=nothing)
    return _update_model_environment_indices!(model, backends, dirty_object_ids) do consume, backend
        consume(backend)
    end
end

function _update_model_environment_indices!(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    dirty_object_ids=nothing,
)
    backends, slots = _model_environment_backends(model, compiled.applications_by_id)
    return _update_model_environment_indices!(model, slots, dirty_object_ids) do consume, slot
        _with_metadata_entry(consume, backends, slot)
    end
end

function _update_model_environment_indices_for_objects!(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    application_ids = Set{Symbol}()
    for dirty_id in dirty_object_ids
        object_id = _index_object_id(cached.targets_by_object, dirty_id)
        _foreach_object_application(compiled, object_id) do application
            push!(application_ids, application.id)
        end
        for target in get(cached.targets_by_object, object_id, ())
            push!(application_ids, target[1])
        end
    end
    plans = CompiledEnvironmentApplicationPlan[]
    seen = Set{UInt}()
    for application_id in application_ids
        plan = cached.application_plans_by_id[application_id]
        _with_environment_plan(cached.application_plan_schema, plan) do admitted_plan
            backend = admitted_plan.backend
            isnothing(backend) && return nothing
            id = objectid(backend)
            id in seen && return nothing
            push!(seen, id)
            push!(plans, admitted_plan)
        end
    end
    # Plans are immutable snapshots. Index callbacks may replace the owner's
    # dictionary entries, so consume these selected plans without rereading it.
    return _update_model_environment_indices!(model, plans, dirty_object_ids) do consume, plan
        _with_environment_plan(cached.application_plan_schema, plan) do admitted_plan
            consume(admitted_plan.backend)
        end
    end
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
    if prepare_runtime && isnothing(sampler) && uses_raw &&
       backend isa GlobalConstant &&
       DataFormat(environment_source(backend)) isa SingletonAlike
        return GlobalEnvironmentSampleSchema{typeof(source)}()
    end
    return GlobalEnvironmentSampleSchema{Any}()
end

function _compile_environment_application_plans(
    model::CompositeModel,
    applications,
    applications_by_id;
    previous_plans_by_id=nothing,
    prepare_runtime::Bool=true,
    plan_schema=nothing,
)
    plans = CompiledEnvironmentApplicationPlan[]
    plans_by_id = Dict{Symbol,CompiledEnvironmentApplicationPlan}()
    plans_by_source = IdDict{Any,CompiledEnvironmentApplicationPlan}()
    if !isnothing(previous_plans_by_id)
        for plan in values(previous_plans_by_id)
            plan.backend isa GlobalConstant || continue
            source = environment_source(plan.backend)
            plans_by_source[source] = plan
        end
    end
    for candidate in applications
        _with_metadata_entry(applications_by_id, candidate.id) do application
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
            function build_plan(sampler, prepared_source)
                has_bindings = !isempty(keys(bindings))
                has_source_overrides = !isempty(keys(environment_sources))
                uses_raw_global_source = backend isa GlobalConstant &&
                                         isnothing(sampler) &&
                                         !has_bindings && !has_source_overrides
                return CompiledEnvironmentApplicationPlan(
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
            end
            plan = if prepare_runtime && backend isa GlobalConstant
                source = environment_source(backend)
                cached_plan = get(plans_by_source, source, nothing)
                if isnothing(cached_plan)
                    sampler = _prepare_environment_sampler(source)
                    prepared_source = _prepare_global_environment(source)
                    prepared_plan = build_plan(sampler, prepared_source)
                    plans_by_source[source] = prepared_plan
                    prepared_plan
                else
                    _with_environment_plan(plan_schema, cached_plan) do admitted_plan
                        build_plan(admitted_plan.sampler, admitted_plan.prepared_source)
                    end
                end
            else
                build_plan(nothing, nothing)
            end
            _with_environment_plan(identity, plan_schema, plan)
            push!(plans, plan)
            haskey(plans_by_id, application.id) && error(
                "Environment application-plan compilation produced duplicate application id `$(application.id)`.",
            )
            plans_by_id[application.id] = plan
        end
    end
    return plans, plans_by_id
end

# Open owners retain the same type when their live configuration changes.
_environment_plan_schema(::Nothing) = nothing
_environment_plan_schema(owner::CompiledEnvironmentBindings) = owner.application_plan_schema

# The default preparation inherits its owner. Collection explicitly stays open;
# a fixed native schema is supplied before the first compilation of its plans.
_preparation_environment_plan_schema(::Nothing, cached) = _environment_plan_schema(cached)
_preparation_environment_plan_schema(::Val{:collect}, cached) = nothing
_preparation_environment_plan_schema(schema::CompiledMetadataTable, cached) = schema

@inline _with_environment_plan(f, ::Nothing, plan) = f(plan)
@generated function _with_environment_plan(f::F, schema::CompiledMetadataTable{T},
    plan::CompiledEnvironmentApplicationPlan,
) where {F,T}
    branches = Expr[]
    for Witness in fieldtypes(T)
        Witness <: Val || error("Environment-plan metadata must contain type witnesses only.")
        P = only(Witness.parameters)
        P isa DataType && isconcretetype(P) && P <: CompiledEnvironmentApplicationPlan ||
            error("Environment-plan metadata needs actual concrete normalized plan types.")
        push!(branches, :(plan isa $P && return f(plan::$P)))
    end
    return quote
        $(branches...)
        throw(ArgumentError(string("The normalized environment plan for application `",
            getfield(plan, :application_id),
            "` is outside its prepared family schema. Prepare a new compilation schema for this configuration.")))
    end
end

# Host-only reconstruction from TYPES already observed in collection worlds.
# Their union must cover the initial and future normalized plan families.
function _environment_plan_schema_from_types(observed_types)
    plan_types = unique(observed_types)
    all(P -> P isa DataType && isconcretetype(P) && P <: CompiledEnvironmentApplicationPlan,
        plan_types) || throw(ArgumentError("Supply actual observed normalized plan types."))
    witnesses = Tuple(Val(P) for P in plan_types)
    names = ntuple(index -> Symbol(:environment_plan_, index), length(witnesses))
    return CompiledMetadataTable(NamedTuple{names}(witnesses))
end

function _retype_environment_plan_owner(compiled, owner, schema)
    for plan in owner.application_plans
        _with_environment_plan(identity, schema, plan)
    end
    return _compiled_environment_bindings(owner.model, compiled,
        owner.application_plans, owner.application_plans_by_id,
        owner.bindings, owner.by_target, owner.sample_cache,
        owner.positions_by_target, owner.targets_by_object; plan_schema=schema)
end

function _compile_environment_bindings_for_applications(
    model::CompositeModel,
    applications,
    plans_by_id;
    plan_schema=nothing,
)
    bindings = CompiledEnvironmentBinding[]
    for application in applications
        application_id = application.id
        application_process = application.process
        target_ids = application.target_ids
        _with_environment_plan(plan_schema, plans_by_id[application_id]) do plan
            for object_id in target_ids
                object = _model_object(model, object_id)
                context = _object_environment_context(application_id, application_process, object, object_id)
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
    end
    return bindings
end

function _compile_environment_bindings(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    plans_by_id;
    plan_schema=nothing,
)
    return _compile_environment_bindings_for_applications(
        model,
        compiled.applications,
        plans_by_id;
        plan_schema,
    )
end

function _validate_model_environment_inputs!(bindings, applications_by_id,
    ::Type{I}; plan_schema=nothing,
) where {I<:ObjectId}
    missing_details = String[]
    for binding in bindings
        plan = getfield(binding, :plan)::CompiledEnvironmentApplicationPlan
        object_id = getfield(binding, :object_id)::I
        _with_environment_plan(plan_schema, plan) do plan
            application_id = getfield(plan, :application_id)
            no_inputs = _with_metadata_entry(applications_by_id, application_id) do application
                isempty(_model_environment_input_names(application))
            end
            no_inputs && return nothing
            available = environment_variables(plan.backend)
            isnothing(available) && return nothing
            application = applications_by_id[application_id]
            for (target, source) in plan.sampling_rules
                source in available && continue
                push!(missing_details, string(
                    application_id,
                    "/",
                    object_id.value,
                    " (",
                    application.process,
                    ") needs `",
                    target,
                    "` from source `",
                    source,
                    "`; available=",
                    Tuple(sort!(collect(available); by=string)),
                ))
            end
        end
    end
    isempty(missing_details) && return nothing
    details = join(missing_details, "; ")
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
    );
    plan_schema=nothing,
)
    return CompiledEnvironmentBindings(
        model,
        application_plans,
        application_plans_by_id,
        plan_schema,
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
    cached = getfield(model, :environment_binding_cache)::Union{Nothing,CompiledEnvironmentBindings}
    return _compile_environment_binding_owner(model, compiled, _environment_plan_schema(cached))
end

function _compile_environment_binding_owner(model::CompositeModel,
    compiled::CompiledCompositeModel, plan_schema,
)
    _update_model_environment_indices!(model, compiled)
    application_plans, application_plans_by_id =
        _compile_environment_application_plans(model, compiled.applications,
            compiled.applications_by_id; plan_schema)
    bindings = _compile_environment_bindings(
        model,
        compiled,
        application_plans_by_id;
        plan_schema,
    )
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id,
        keytype(model.registry.objects); plan_schema)
    by_target = _index_environment_bindings(bindings, keytype(model.registry.objects))
    return _compiled_environment_bindings(
        model,
        compiled,
        application_plans,
        application_plans_by_id,
        bindings,
        by_target;
        plan_schema,
    )
end

function _same_environment_backend(a, b)
    a === b && return true
    if a isa GlobalConstant && b isa GlobalConstant
        return environment_source(a) === environment_source(b)
    end
    return false
end

function _same_environment_context(a, b, ::Type{I}) where {I<:ObjectId}
    previous = a::EnvironmentContext
    current = b::EnvironmentContext
    return previous.application == current.application &&
           (previous.object_id::I) == (current.object_id::I) &&
           previous.scale == current.scale &&
           previous.process == current.process
end

function _same_environment_plan_configuration(
    a::CompiledEnvironmentApplicationPlan, b::CompiledEnvironmentApplicationPlan,
)
    return _same_environment_backend(a.backend, b.backend) &&
           isequal(a.config, b.config)
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
        compiled.applications,
        compiled.applications_by_id;
        previous_plans_by_id=cached.application_plans_by_id,
        plan_schema=cached.application_plan_schema,
    )
    plans = CompiledEnvironmentApplicationPlan[]
    plans_by_id = Dict{Symbol,CompiledEnvironmentApplicationPlan}()
    plan_schema = cached.application_plan_schema
    for candidate in candidates
        application_id = candidate.application_id
        old = get(cached.application_plans_by_id, application_id, nothing)
        plan = if isnothing(old)
            _with_environment_plan(identity, plan_schema, candidates_by_id[application_id])
        else
            _with_environment_plan(plan_schema, old) do admitted_old
                _with_environment_plan(plan_schema, candidates_by_id[application_id]) do admitted_candidate
                    _same_environment_plan_configuration(admitted_old, admitted_candidate) ||
                        return nothing
                    return _same_environment_application_plan(admitted_old, admitted_candidate) ?
                           admitted_old : _with_environment_plan(identity, plan_schema, candidates_by_id[application_id])
                end
            end
        end
        isnothing(plan) && return nothing
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
    plan_schema = cached.application_plan_schema
    for application in compiled.applications
        application_id = application.id
        plan = application_plans_by_id[application_id]
        for object_id in application.target_ids
            key = (application_id, object_id)
            old = get(cached.by_target, key, nothing)::Union{Nothing,CompiledEnvironmentBinding}
            isnothing(old) && return nothing
            object = _model_object(model, object_id)
            context = _object_environment_context(application.id, application.process, object, object_id)
            _, geometry_source_object_id, geometry_source =
                _environment_binding_object(model, object)
            old_plan = getfield(old, :plan)::CompiledEnvironmentApplicationPlan
            same_configuration = _with_environment_plan(plan_schema, old_plan) do admitted_old
                _with_environment_plan(plan_schema, application_plans_by_id[application_id]) do admitted_current
                    _same_environment_plan_configuration(admitted_old, admitted_current)
                end
            end
            same_configuration || return nothing
            old.geometry_source_object_id == geometry_source_object_id ||
                return nothing
            old.geometry_source == geometry_source || return nothing
            _same_environment_context(old.context, context, keytype(cached.targets_by_object)) || return nothing

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
        cached.targets_by_object;
        plan_schema=cached.application_plan_schema,
    )
    _validate_model_environment_inputs!(bindings, compiled.applications_by_id,
        keytype(model.registry.objects);
        plan_schema=cached.application_plan_schema)
    by_target = _index_environment_bindings(bindings, keytype(model.registry.objects))
    return _compiled_environment_bindings(
        model,
        compiled,
        application_plans,
        application_plans_by_id,
        bindings,
        by_target,
        cached.sample_cache;
        plan_schema=cached.application_plan_schema,
    )
end

function _refresh_environment_bindings_for_objects(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    cached::CompiledEnvironmentBindings,
    dirty_object_ids,
)
    I = keytype(cached.targets_by_object)
    dirty_ids = I[]
    if Base.IteratorSize(typeof(dirty_object_ids)) isa Union{Base.HasLength,Base.HasShape}
        sizehint!(dirty_ids, length(dirty_object_ids))
    end
    for dirty_id in dirty_object_ids
        push!(dirty_ids, _index_object_id(cached.targets_by_object, dirty_id))
    end
    _sort_object_ids!(dirty_ids)
    _update_model_environment_indices_for_objects!(
        model,
        compiled,
        cached,
        dirty_ids,
    )
    K = keytype(cached.by_target)
    stale_targets = Set{K}()
    replacements = Dict{K,Any}()
    empty_targets = K[]
    for dirty_id in dirty_ids
        object_id = _index_object_id(cached.targets_by_object, dirty_id)
        current_applications = _application_membership_slots(compiled, object_id)
        previous_targets = get(cached.targets_by_object, object_id, empty_targets)
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
                partial_application = _partial_model_application(application, I[object_id])
                for binding in _compile_environment_bindings_for_applications(
                    model,
                    (partial_application,),
                    cached.application_plans_by_id;
                    plan_schema=cached.application_plan_schema,
                )
                    replacements[_environment_binding_target_key(binding, I)] = binding
                end
            end
        end
    end
    _validate_model_environment_inputs!(
        (binding::CompiledEnvironmentBinding for binding in values(replacements)),
        compiled.applications_by_id,
        keytype(model.registry.objects);
        plan_schema=cached.application_plan_schema,
    )

    for target in stale_targets
        position = pop!(cached.positions_by_target, target)
        last_position = lastindex(cached.bindings)
        if position != last_position
            moved_binding = cached.bindings[last_position]
            cached.bindings[position] = moved_binding
            cached.positions_by_target[_environment_binding_target_key(moved_binding, I)] = position
        end
        pop!(cached.bindings)
        delete!(cached.by_target, target)
        object_targets = cached.targets_by_object[target[2]]
        target_index = findfirst(==(target), object_targets)
        isnothing(target_index) || deleteat!(object_targets, target_index)
        isempty(object_targets) && delete!(cached.targets_by_object, target[2])
    end
    for (target, value) in replacements
        binding = value::CompiledEnvironmentBinding
        position = get(cached.positions_by_target, target, nothing)
        if isnothing(position)
            push!(cached.bindings, binding)
            cached.positions_by_target[target] =
                lastindex(cached.bindings)
            push!(
                get!(cached.targets_by_object, target[2]) do
                    K[]
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
        cached.targets_by_object;
        plan_schema=cached.application_plan_schema,
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

# Open canonical model caches keep the same container schema: plan/binding Vectors,
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
    plan_schema=_environment_plan_schema(cached),
)
    policy_changed = !isnothing(cached) && cached.application_plan_schema !== plan_schema
    if policy_changed && !force && !model.environment_bindings_dirty &&
       cached.model_revision == compiled.revision &&
       cached.environment_revision == model.environment_revision &&
       cached.compiled_applications === compiled.applications
        # Only the policy changes: validate current normalized values and retain
        # every existing handle/container, without replaying provider code.
        refreshed = _retype_environment_plan_owner(compiled, cached, plan_schema)
        model.environment_binding_cache = refreshed
        _record_runtime_owner_replacement!(model, cached, refreshed)
        return refreshed
    end
    if force || model.environment_bindings_dirty || isnothing(cached) || policy_changed
        delta = model.lifecycle_delta
        refreshed = if !force && !policy_changed && !isnothing(cached) && !delta.full_environment
            # A public Advanced refresh may have prepared another application
            # set. Reconcile that current owner before using its plans for a
            # partial event in this compiled scene.
            partial_owner = cached.compiled_applications === compiled.applications ?
                            cached : _reconcile_environment_binding_metadata(model, compiled, cached)
            if isnothing(partial_owner)
                _compile_environment_binding_owner(model, compiled, plan_schema)
            else
                _refresh_environment_bindings_for_objects(
                    model,
                    compiled,
                    partial_owner,
                    delta.environment_dirty_ids,
                )
            end
        else
            _compile_environment_binding_owner(model, compiled, plan_schema)
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
                    _compile_environment_binding_owner(model, compiled, plan_schema) : reconciled
        model.environment_binding_cache = refreshed
        _record_runtime_owner_replacement!(model, cached, refreshed)
        return refreshed
    end
end
