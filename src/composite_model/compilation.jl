struct CompiledModelApplication{S,AT,TS,CL,MO}
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

struct CompiledModelInputBinding{SEL,P,W,C}
    application_id::Symbol
    consumer_id::ObjectId
    input::Symbol
    selector::SEL
    origin::Symbol
    source_ids::Vector{ObjectId}
    source_application_ids::Vector{Symbol}
    order_after_application_ids::Vector{Symbol}
    source_var::Symbol
    process::Union{Nothing,Symbol}
    application::Union{Nothing,Symbol}
    multiplicity::Symbol
    policy::P
    window::W
    carrier_hint::Symbol
    carrier::C
end

struct CompiledTemporalInput{B,S,I,R}
    binding::B
    source_applications::S
    initial::I
    reference::R
end

struct CompiledModelStatusView{S,C,T}
    status::S
    canonical_status::C
    temporal_inputs::T
end

struct CompiledModelCallBinding{NAME,SEL}
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

function CompiledModelCallBinding(
    application_id,
    consumer_id,
    call::Symbol,
    selector,
    origin,
    callee_object_ids,
    callee_application_ids,
    process,
    application,
    multiplicity,
)
    return CompiledModelCallBinding{call,typeof(selector)}(
        application_id,
        consumer_id,
        call,
        selector,
        origin,
        callee_object_ids,
        callee_application_ids,
        process,
        application,
        multiplicity,
    )
end

_compiled_call_name(::CompiledModelCallBinding{NAME}) where {NAME} = NAME

struct CompiledEnvironmentBinding{B,H,C}
    application_id::Symbol
    object_id::ObjectId
    backend::B
    handle::H
    required_inputs::Vector{Symbol}
    source_inputs::Vector{Symbol}
    produced_outputs::Vector{Symbol}
    context::C
    geometry_source_object_id::Union{Nothing,ObjectId}
    geometry_source::Symbol
    config::Any
end

struct CompiledEnvironmentBindings{SC,B,I,S,C}
    model::SC
    bindings::B
    by_target::I
    samplers_by_application::S
    sample_cache::C
    model_revision::Int
    environment_revision::Int
end

struct CompiledCompositeModel{SC,AP,AI,ABO,IB,CB,IBI,CBI,DBI,MBI,SVI,AO,TL}
    model::SC
    applications::AP
    applications_by_id::AI
    applications_by_object::ABO
    input_bindings::IB
    call_bindings::CB
    input_bindings_by_target::IBI
    call_bindings_by_target::CBI
    dynamic_input_binding_indices::DBI
    model_bundles_by_target::MBI
    status_views_by_target::SVI
    application_order::AO
    timeline::TL
    revision::Int
end

function _dynamic_binding_scale_keys(model::CompositeModel, binding)
    binding.origin == :inferred_same_object && return Symbol[]
    selector_criteria = criteria(binding.selector)
    explicit_scope = _criteria_scope(selector_criteria)
    default_scope = _default_dependency_scope(model, binding.consumer_id)
    scope = isnothing(explicit_scope) ? default_scope : explicit_scope
    scope isa Self && return Symbol[]
    scale = _criteria_value(selector_criteria, :scale, Scale)
    isnothing(scale) && return Union{Nothing,Symbol}[nothing]
    return Symbol[Symbol(value) for value in (scale isa Tuple ? scale : (scale,))]
end

function _index_dynamic_input_bindings(model::CompositeModel, bindings)
    index = Dict{Union{Nothing,Symbol},Vector{Int}}()
    for (binding_index, binding) in pairs(bindings)
        for scale in _dynamic_binding_scale_keys(model, binding)
            push!(get!(index, scale, Int[]), binding_index)
        end
    end
    return index
end

function _index_model_bindings(bindings, application_field::Symbol, object_field::Symbol)
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

"""
    compile_composite_model(model[, applications...])

Compile model applications, selectors, value bindings, hard calls, writer
ordering, and schedules into the single Composite Model/Object runtime representation.
Most callers can use [`run!`](@ref) directly, which compiles as needed.
"""
function compile_composite_model(model::CompositeModel)
    return compile_composite_model(model, model.applications)
end

function compile_composite_model(model::CompositeModel, specs::Tuple)
    return _compile_scene(model, specs)
end

function compile_composite_model(model::CompositeModel, specs::AbstractVector)
    return _compile_scene(model, Tuple(specs))
end

function compile_composite_model(model::CompositeModel, specs...)
    return _compile_scene(model, specs)
end

function _model_timeline(model::CompositeModel)
    backend = environment_backend(model.environment)
    _validate_meteo_duration(backend)
    return _timeline_context(backend)
end

function _compile_scene(model::CompositeModel, raw_specs; validate_required_inputs::Bool=true)
    timeline = _model_timeline(model)
    applications = _compile_model_applications(model, raw_specs, timeline)
    call_bindings = _compile_model_call_bindings(model, applications)
    _validate_model_call_cadences!(applications, call_bindings, timeline)
    _validate_model_writers!(applications, call_bindings)
    _prepare_model_output_statuses!(model, applications)
    input_bindings = _compile_model_input_bindings(
        model,
        applications,
        _manual_call_application_ids(call_bindings),
    )
    _share_many_input_bindings!(model, input_bindings)
    _prepare_model_bound_input_statuses!(model, applications, input_bindings)
    _wire_model_input_carriers!(model, input_bindings)
    validate_required_inputs &&
        _validate_model_required_inputs!(model, applications, input_bindings)
    # Lifecycle refresh may replace an initially empty `Many(...)` carrier
    # with a concrete carrier type. Keep the per-target index type-stable
    # across that replacement so an updated compiled scene can be stored in
    # an existing `Simulation`.
    input_bindings_by_target = Dict{Any,Any}(
        _index_model_bindings(
            input_bindings,
            :application_id,
            :consumer_id,
        ),
    )
    call_bindings_by_target = _index_model_bindings(call_bindings, :application_id, :consumer_id)
    application_order = _compile_model_application_order(applications, input_bindings, call_bindings)
    applications_by_id = Dict(application.id => application for application in applications)
    model_bundles_by_target = _compile_model_model_bundles(
        applications,
        applications_by_id,
        call_bindings_by_target,
    )
    status_views_by_target = _compile_model_status_views(
        model,
        applications,
        applications_by_id,
        input_bindings_by_target,
        application_order,
    )
    return CompiledCompositeModel(
        model,
        applications,
        applications_by_id,
        _applications_by_object(applications),
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        _index_dynamic_input_bindings(model, input_bindings),
        model_bundles_by_target,
        status_views_by_target,
        application_order,
        timeline,
        model.revision,
    )
end

function _new_application_targets(model::CompositeModel, applications, added_ids)
    targets = Dict{Symbol,Vector{ObjectId}}()
    for application in applications
        matched = ObjectId[
            object_id for object_id in added_ids
            if _selector_matches_object_id(model, application.applies_to, object_id)
        ]
        isempty(matched) && continue
        new_count = length(application.target_ids) + length(matched)
        if (application.applies_to isa One && new_count != 1) ||
           (application.applies_to isa OptionalOne && new_count > 1)
            return nothing
        end
        targets[application.id] = matched
    end
    return targets
end

function _compile_added_consumer_bindings!(
    bindings,
    model,
    application,
    consumer_id,
    manual_application_ids,
    applications_by_object,
    applications_by_id,
)
    declared_inputs = value_inputs(application.spec)
    declared_inputs isa NamedTuple || (declared_inputs = NamedTuple())
    for (input_name, selector) in pairs(declared_inputs)
        input_sym = Symbol(input_name)
        origin = get(input_origins(application.spec), input_sym, :model_spec)
        _validate_declared_model_input_name!(application, input_sym)
        _push_model_input_binding!(
            bindings,
            model,
            application,
            consumer_id,
            input_sym,
            selector,
            origin,
            applications_by_object,
            applications_by_id,
        )
    end
    application.id in manual_application_ids && return bindings
    _append_inferred_model_input_bindings!(
        bindings,
        model,
        application,
        consumer_id,
        declared_inputs,
        applications_by_object,
        applications_by_id,
    )
    return bindings
end

function _many_binding_scope_anchor(model::CompositeModel, binding::CompiledModelInputBinding)
    selector_criteria = criteria(binding.selector)
    !isnothing(_criteria_get(selector_criteria, :relation, nothing)) &&
        return (:consumer, binding.consumer_id)
    explicit_scope = _criteria_scope(selector_criteria)
    scope = isnothing(explicit_scope) ?
            _default_dependency_scope(model, binding.consumer_id) : explicit_scope
    if isnothing(scope) || scope isa SceneScope
        return (:scene,)
    elseif scope isa SelfPlant
        return (:plant, _ancestor_id(model, binding.consumer_id; scale=:Plant))
    elseif scope isa Scope
        return (:scope, scope.name)
    elseif scope isa Ancestor
        return (
            :ancestor,
            _ancestor_id(
                model,
                binding.consumer_id;
                scale=scope.scale,
                include_self=false,
            ),
        )
    end
    return (:consumer, binding.consumer_id)
end

function _many_binding_share_key(model::CompositeModel, binding::CompiledModelInputBinding)
    binding.multiplicity == :many || return nothing
    isnothing(binding.carrier) && return nothing
    return (
        binding.selector,
        _many_binding_scope_anchor(model, binding),
        binding.source_var,
        binding.process,
        binding.application,
        binding.carrier_hint,
        typeof(binding.carrier),
    )
end

function _binding_with_shared_many_sources(
    binding::CompiledModelInputBinding,
    canonical::CompiledModelInputBinding,
)
    return CompiledModelInputBinding(
        binding.application_id,
        binding.consumer_id,
        binding.input,
        binding.selector,
        binding.origin,
        canonical.source_ids,
        canonical.source_application_ids,
        binding.order_after_application_ids,
        binding.source_var,
        binding.process,
        binding.application,
        binding.multiplicity,
        binding.policy,
        binding.window,
        binding.carrier_hint,
        canonical.carrier,
    )
end

function _share_many_input_binding!(cache, model::CompositeModel, binding)
    key = _many_binding_share_key(model, binding)
    isnothing(key) && return binding
    canonical = get(cache, key, nothing)
    if isnothing(canonical)
        cache[key] = binding
        return binding
    end
    if canonical.source_ids != binding.source_ids ||
       canonical.source_application_ids != binding.source_application_ids
        cache[(key, binding.consumer_id)] = binding
        return binding
    end
    return _binding_with_shared_many_sources(binding, canonical)
end

function _share_many_input_bindings!(model::CompositeModel, bindings; cache=Dict{Any,Any}())
    for index in eachindex(bindings)
        bindings[index] = _share_many_input_binding!(cache, model, bindings[index])
    end
    return cache
end

function _many_input_binding_cache(model::CompositeModel, bindings)
    cache = Dict{Any,Any}()
    for binding in bindings
        key = _many_binding_share_key(model, binding)
        isnothing(key) || haskey(cache, key) || (cache[key] = binding)
    end
    return cache
end

function _append_added_many_sources!(
    model::CompositeModel,
    binding::CompiledModelInputBinding,
    added_ids,
    applications_by_object,
)
    binding.multiplicity == :many || return false
    default_scope = _default_dependency_scope(model, binding.consumer_id)
    new_source_ids = ObjectId[
        object_id for object_id in added_ids if
        _selector_matches_object_id(
            model,
            binding.selector,
            object_id;
            context=binding.consumer_id,
            default_to_context=true,
            default_scope=default_scope,
        ) && !(object_id in binding.source_ids)
    ]
    isempty(new_source_ids) && return true
    _sort_object_ids!(new_source_ids)

    # The growth path allocates monotonically increasing IDs. Appending preserves the
    # selector's stable order and, critically, keeps the carrier already installed in
    # the consumer status. Non-monotonic explicit IDs use the general rebuild path.
    if !isempty(binding.source_ids) &&
       !_object_id_isless(last(binding.source_ids), first(new_source_ids))
        return false
    end

    new_carrier = _input_carrier(model, binding.selector, new_source_ids, binding.source_var)
    isnothing(new_carrier) && return false
    existing_refs = parent(binding.carrier)
    new_refs = parent(new_carrier)
    eltype(new_refs) <: eltype(existing_refs) || return false
    append!(existing_refs, new_refs)
    append!(binding.source_ids, new_source_ids)

    new_application_ids = if _selector_from_status(binding.selector)
        Symbol[]
    else
        _matching_input_source_applications(
            applications_by_object,
            new_source_ids,
            binding.source_var,
            binding.process,
            binding.application;
            allow_empty=binding.selector isa OptionalOne,
        )
    end
    for application_id in new_application_ids
        application_id in binding.source_application_ids ||
            push!(binding.source_application_ids, application_id)
    end
    return true
end

function _preserve_temporal_input_state!(
    current::CompiledTemporalInput,
    previous::CompiledTemporalInput,
    previous_source_ids,
)
    if current.binding.multiplicity != :many ||
       previous.binding.multiplicity != :many
        current.reference[] = _private_temporal_value(previous.reference[])
        return CompiledTemporalInput(
            current.binding,
            current.source_applications,
            previous.initial,
            current.reference,
        )
    end

    current_initial = current.initial
    current_storage = current.reference[]
    previous_initial = previous.initial
    previous_storage = previous.reference[]
    previous_indices = Dict(
        object_id => index
        for (index, object_id) in pairs(previous_source_ids)
    )
    for (current_index, object_id) in pairs(current.binding.source_ids)
        previous_index = get(previous_indices, object_id, nothing)
        isnothing(previous_index) && continue
        current_initial[current_index] =
            _private_temporal_value(previous_initial[previous_index])
        current_storage[current_index] =
            _private_temporal_value(previous_storage[previous_index])
    end
    return CompiledTemporalInput(
        current.binding,
        current.source_applications,
        current_initial,
        current.reference,
    )
end

function _preserve_model_status_view_temporal_state!(
    current::CompiledModelStatusView,
    previous::CompiledModelStatusView,
    previous_temporal_sources,
    key,
)
    isempty(previous.temporal_inputs) && return current
    previous_by_input = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in previous.temporal_inputs
    )
    temporal_inputs = Tuple(begin
        previous_input = get(
            previous_by_input,
            temporal_input.binding.input,
            nothing,
        )
        if isnothing(previous_input)
            temporal_input
        else
            previous_source_ids = get(
                previous_temporal_sources,
                (key..., temporal_input.binding.input),
                previous_input.binding.source_ids,
            )
            _preserve_temporal_input_state!(
                temporal_input,
                previous_input,
                previous_source_ids,
            )
        end
    end for temporal_input in current.temporal_inputs)
    temporal_by_name = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in temporal_inputs
    )
    names = propertynames(current.canonical_status)
    references = ntuple(length(names)) do index
        name = names[index]
        temporal_input = get(temporal_by_name, name, nothing)
        isnothing(temporal_input) &&
            return refvalue(current.canonical_status, name)
        return temporal_input.reference
    end
    status = Status(NamedTuple{names}(references))
    return CompiledModelStatusView(
        status,
        current.canonical_status,
        temporal_inputs,
    )
end

function _extend_model_status_views(
    model::CompositeModel,
    compiled::CompiledCompositeModel,
    applications,
    applications_by_id,
    applications_by_object,
    input_bindings_by_target,
    application_order,
    new_targets,
    rewired_consumer_ids,
    affected_temporal_keys,
    previous_temporal_sources,
)
    views = copy(compiled.status_views_by_target)
    affected_keys = Set{Tuple{Symbol,ObjectId}}(affected_temporal_keys)
    for application in applications
        for object_id in get(new_targets, application.id, ObjectId[])
            push!(affected_keys, (application.id, object_id))
        end
    end
    for object_id in rewired_consumer_ids
        for application in get(applications_by_object, object_id, ())
            push!(affected_keys, (application.id, object_id))
        end
    end

    positions = Dict(
        application_id => index
        for (index, application_id) in pairs(application_order)
    )
    for key in affected_keys
        application_id, object_id = key
        application = applications_by_id[application_id]
        previous_view = get(compiled.status_views_by_target, key, nothing)
        if !isnothing(previous_view)
            for temporal_input in previous_view.temporal_inputs
                get!(
                    previous_temporal_sources,
                    (key..., temporal_input.binding.input),
                ) do
                    copy(temporal_input.binding.source_ids)
                end
            end
        end
        current_view = _compile_model_status_view(
            model,
            application,
            object_id,
            get(input_bindings_by_target, key, ()),
            applications_by_id,
            positions,
        )
        views[key] = isnothing(previous_view) ?
                     current_view :
                     _preserve_model_status_view_temporal_state!(
            current_view,
            previous_view,
            previous_temporal_sources,
            key,
        )
    end
    return views
end

function _extend_compiled_scene(model::CompositeModel, compiled::CompiledCompositeModel, added_objects)
    added_ids = ObjectId[id for id in added_objects if haskey(model.registry.objects, id)]
    isempty(added_ids) && return compile_composite_model(model, model.applications)
    new_targets = _new_application_targets(model, compiled.applications, added_ids)
    isnothing(new_targets) && return compile_composite_model(model, model.applications)

    for application in compiled.applications
        append!(application.target_ids, get(new_targets, application.id, ObjectId[]))
        _sort_object_ids!(application.target_ids)
    end
    applications = compiled.applications
    applications_by_id = Dict(application.id => application for application in applications)
    applications_by_object = compiled.applications_by_object
    for application in applications
        for object_id in get(new_targets, application.id, ObjectId[])
            push!(get!(applications_by_object, object_id, Any[]), application)
        end
    end

    has_calls = any(applications) do application
        calls = model_calls(application.spec)
        calls isa NamedTuple && !isempty(keys(calls))
    end
    timeline = _model_timeline(model)
    added_applications = CompiledModelApplication[]
    for application in applications
        target_ids = get(new_targets, application.id, ObjectId[])
        isempty(target_ids) && continue
        push!(
            added_applications,
            CompiledModelApplication(
                application.id,
                application.spec,
                application.process,
                application.name,
                target_ids,
                application.applies_to,
                application.timestep,
                application.clock,
                application.model_overrides,
            ),
        )
    end
    existing_calls_affected = false
    if has_calls
        existing_calls_affected = any(compiled.call_bindings) do binding
            _selector_matches_any_object_id(
                model,
                binding.selector,
                added_ids;
                context=binding.consumer_id,
                default_to_context=true,
                default_scope=_default_dependency_scope(model, binding.consumer_id),
            )
        end
    end
    new_call_bindings = has_calls ?
                        _compile_model_call_bindings(
        model,
        added_applications,
        applications,
        ;
        by_object=applications_by_object,
    ) : CompiledModelCallBinding[]
    call_bindings = if existing_calls_affected
        _compile_model_call_bindings(
            model,
            applications;
            by_object=applications_by_object,
        )
    else
        bindings = copy(compiled.call_bindings)
        append!(bindings, new_call_bindings)
        bindings
    end
    _validate_model_call_cadences!(applications, call_bindings, timeline)
    _validate_model_writers!(added_applications, call_bindings)
    _prepare_model_output_statuses!(model, added_applications)

    manual_application_ids = _manual_call_application_ids(call_bindings)
    input_bindings = copy(compiled.input_bindings)
    # A `Many(...)` binding that starts empty is compiled with an untyped
    # `RefVector{Any}` carrier. Once matching objects are registered, the
    # refreshed carrier becomes concrete (for example `RefVector{Float64}`).
    # Keep this incremental index value-widened so that lifecycle refresh can
    # replace an initially empty binding without rebuilding the whole scene.
    input_bindings_by_target = Dict{Any,Any}(compiled.input_bindings_by_target)
    changed_bindings = CompiledModelInputBinding[]
    rewired_consumer_ids = Set{ObjectId}()
    affected_temporal_keys = Set{Tuple{Symbol,ObjectId}}()
    previous_temporal_sources =
        Dict{Tuple{Symbol,ObjectId,Symbol},Vector{ObjectId}}()
    processed_many_sources = IdDict{Any,Nothing}()
    previous_shared_many_sources = IdDict{Any,Vector{ObjectId}}()
    candidate_binding_indices = Set(get(compiled.dynamic_input_binding_indices, nothing, Int[]))
    for object_id in added_ids
        object_scale = _model_object(model, object_id).scale
        isnothing(object_scale) || union!(
            candidate_binding_indices,
            get(compiled.dynamic_input_binding_indices, object_scale, Int[]),
        )
    end
    for index in candidate_binding_indices
        binding = input_bindings[index]
        if binding.multiplicity == :many && haskey(processed_many_sources, binding.source_ids)
            if binding.carrier_hint == :temporal_stream
                key = (binding.application_id, binding.consumer_id)
                push!(affected_temporal_keys, key)
                previous_temporal_sources[(
                    key...,
                    binding.input,
                )] = previous_shared_many_sources[binding.source_ids]
            end
            continue
        end
        previous_source_ids = binding.carrier_hint == :temporal_stream ?
                              copy(binding.source_ids) :
                              ObjectId[]
        binding.multiplicity == :many &&
            (previous_shared_many_sources[binding.source_ids] = copy(binding.source_ids))
        default_scope = _default_dependency_scope(model, binding.consumer_id)
        _selector_matches_any_object_id(
            model,
            binding.selector,
            added_ids;
            context=binding.consumer_id,
            default_to_context=true,
            default_scope=default_scope,
        ) || continue
        appended_sources = _append_added_many_sources!(
            model,
            binding,
            added_ids,
            applications_by_object,
        )
        if appended_sources
            if binding.carrier_hint == :temporal_stream &&
               previous_source_ids != binding.source_ids
                key = (binding.application_id, binding.consumer_id)
                push!(affected_temporal_keys, key)
                previous_temporal_sources[(
                    key...,
                    binding.input,
                )] = previous_source_ids
            end
            processed_many_sources[binding.source_ids] = nothing
            continue
        end
        application = applications_by_id[binding.application_id]
        replacement = CompiledModelInputBinding[]
        _push_model_input_binding!(
            replacement,
            model,
            application,
            binding.consumer_id,
            binding.input,
            binding.selector,
            binding.origin,
            applications_by_object,
            applications_by_id,
        )
        replacement_binding = only(replacement)
        input_bindings[index] = replacement_binding
        push!(changed_bindings, replacement_binding)
        push!(rewired_consumer_ids, binding.consumer_id)
        if binding.carrier_hint == :temporal_stream
            key = (binding.application_id, binding.consumer_id)
            push!(affected_temporal_keys, key)
            previous_temporal_sources[(
                key...,
                binding.input,
            )] = previous_source_ids
        end
        target = (binding.application_id, binding.consumer_id)
        input_bindings_by_target[target] = Tuple(
            existing === binding ? replacement_binding : existing
            for existing in get(input_bindings_by_target, target, ())
        )
    end
    previous_binding_count = length(input_bindings)
    many_binding_cache = _many_input_binding_cache(model, input_bindings)
    for application in applications
        for consumer_id in get(new_targets, application.id, ObjectId[])
            first_new_binding = length(input_bindings) + 1
            _compile_added_consumer_bindings!(
                input_bindings,
                model,
                application,
                consumer_id,
                manual_application_ids,
                applications_by_object,
                applications_by_id,
            )
            last_new_binding = length(input_bindings)
            if first_new_binding <= last_new_binding
                for binding_index in first_new_binding:last_new_binding
                    input_bindings[binding_index] = _share_many_input_binding!(
                        many_binding_cache,
                        model,
                        input_bindings[binding_index],
                    )
                end
                new_bindings = input_bindings[first_new_binding:last_new_binding]
                append!(changed_bindings, new_bindings)
                input_bindings_by_target[(application.id, consumer_id)] = Tuple(new_bindings)
            end
        end
    end
    dynamic_input_binding_indices = Dict{Union{Nothing,Symbol},Vector{Int}}(
        scale => copy(indices)
        for (scale, indices) in compiled.dynamic_input_binding_indices
    )
    for binding_index in (previous_binding_count + 1):length(input_bindings)
        binding = input_bindings[binding_index]
        for scale in _dynamic_binding_scale_keys(model, binding)
            push!(get!(dynamic_input_binding_indices, scale, Int[]), binding_index)
        end
    end

    _prepare_model_bound_input_statuses!(model, added_applications, changed_bindings)
    _wire_model_input_carriers!(model, changed_bindings)
    _validate_model_required_inputs!(model, added_applications, changed_bindings)
    call_bindings_by_target = if existing_calls_affected
        _index_model_bindings(call_bindings, :application_id, :consumer_id)
    elseif isempty(new_call_bindings)
        compiled.call_bindings_by_target
    else
        indexed = copy(compiled.call_bindings_by_target)
        merge!(
            indexed,
            _index_model_bindings(new_call_bindings, :application_id, :consumer_id),
        )
        indexed
    end
    # Newly resolved inputs can introduce ordering edges that did not exist
    # while a dynamic application's target set was empty. Recompute the
    # schedule before compiling status views and execution batches so new
    # targets observe the same dependency contract as initial targets.
    application_order =
        _compile_model_application_order(applications, input_bindings, call_bindings)
    if application_order != compiled.application_order
        for (key, view) in compiled.status_views_by_target
            isempty(view.temporal_inputs) && continue
            push!(affected_temporal_keys, key)
            for temporal_input in view.temporal_inputs
                get!(
                    previous_temporal_sources,
                    (key..., temporal_input.binding.input),
                ) do
                    copy(temporal_input.binding.source_ids)
                end
            end
        end
    end
    model_bundles_by_target = if existing_calls_affected
        _compile_model_model_bundles(
            applications,
            applications_by_id,
            call_bindings_by_target,
        )
    else
        bundles = copy(compiled.model_bundles_by_target)
        for application in added_applications
            for object_id in application.target_ids
                bundles[(application.id, object_id)] = _compile_model_model_bundle(
                    applications_by_id,
                    call_bindings_by_target,
                    application,
                    object_id,
                )
            end
        end
        bundles
    end
    status_views_by_target = _extend_model_status_views(
        model,
        compiled,
        applications,
        applications_by_id,
        applications_by_object,
        input_bindings_by_target,
        application_order,
        new_targets,
        rewired_consumer_ids,
        affected_temporal_keys,
        previous_temporal_sources,
    )
    return CompiledCompositeModel(
        model,
        applications,
        applications_by_id,
        applications_by_object,
        input_bindings,
        call_bindings,
        input_bindings_by_target,
        call_bindings_by_target,
        dynamic_input_binding_indices,
        model_bundles_by_target,
        status_views_by_target,
        application_order,
        timeline,
        model.revision,
    )
end

function _validate_model_call_cadences!(applications, call_bindings, timeline)
    applications_by_id = Dict(application.id => application for application in applications)
    for binding in call_bindings
        caller = applications_by_id[binding.application_id]
        for callee_id in binding.callee_application_ids
            callee = applications_by_id[callee_id]
            # A call-only target with no model/scenario cadence declaration
            # inherits the cadence of its parent call. An explicit target
            # cadence is a scientific contract and must match the caller.
            _runtime_clock_source_for_spec(callee.spec) == :meteo_base_step &&
                continue
            same_dt = isapprox(
                float(caller.clock.dt),
                float(callee.clock.dt);
                atol=1.0e-9,
                rtol=0.0,
            )
            same_phase = isapprox(
                float(caller.clock.phase),
                float(callee.clock.phase);
                atol=1.0e-9,
                rtol=0.0,
            )
            same_dt && same_phase && continue
            caller_seconds = float(caller.clock.dt) * timeline.base_step_seconds
            callee_seconds = float(callee.clock.dt) * timeline.base_step_seconds
            error(
                "Hard call `$(binding.call)` from application `$(caller.id)` to ",
                "application `$(callee.id)` has incompatible cadence: caller=",
                "$(caller_seconds) seconds (phase=$(caller.clock.phase)), target=",
                "$(callee_seconds) seconds (phase=$(callee.clock.phase)). ",
                "Use matching TimeStep declarations or omit TimeStep on the ",
                "manual-call-only target so it inherits the parent call cadence."
            )
        end
    end
    return nothing
end

"""
    explain_initialization(model::CompositeModel)

Return structured rows describing how every application variable is
initialized. `disposition` is one of:

- `:supplied`: present on the object's status before compilation;
- `:generated`: created from a model output declaration;
- `:producer_bound`: connected through an explicit or inferred `Inputs` binding;
- `:environment_bound`: provided by the selected environment backend;
- `:unresolved`: still requires user or scenario configuration.

Unlike [`compile_composite_model`](@ref), this report does not fail solely because a
required status or environment value is unresolved. Selector, writer, call,
and other invalid configuration errors remain errors.
"""
function explain_initialization(model::CompositeModel)
    supplied = Dict(
        object.id => Set{Symbol}(
            object.status isa Status ? Symbol.(propertynames(object.status)) : Symbol[]
        )
        for object in values(model.registry.objects)
    )
    compiled = _compile_scene(
        model,
        Tuple(model.applications);
        validate_required_inputs=false,
    )
    bindings = Dict(
        (binding.application_id, binding.consumer_id, binding.input) => binding
        for binding in compiled.input_bindings
    )

    environment_bindings = Dict(
        (binding.application_id, binding.object_id) => binding
        for binding in _compile_environment_bindings(model, compiled)
    )

    rows = NamedTuple[]
    for application in compiled.applications
        model_outputs = outputs_(application.spec)
        meteo_model_outputs = meteo_outputs_(application.spec)
        model_inputs = inputs_(application.spec)
        environment_inputs = meteo_inputs_(application.spec)
        generated = Set(Symbol.(keys(model_outputs)))
        for object_id in application.target_ids
            for variable in sort!(collect(generated); by=string)
                default_value = getproperty(model_outputs, variable)
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:output,
                    disposition=:generated,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=nothing,
                    origin=:model_output,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    detail=nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(meteo_model_outputs))); by=string)
                default_value = getproperty(meteo_model_outputs, variable)
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:environment_output,
                    disposition=:declared,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=nothing,
                    origin=:environment_commit,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    detail=nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(inputs_(application.spec)))); by=string)
                key = (application.id, object_id, variable)
                binding = get(bindings, key, nothing)
                disposition = if !isnothing(binding)
                    :producer_bound
                elseif variable in get(supplied, object_id, Set{Symbol}())
                    :supplied
                else
                    :unresolved
                end
                default_value = getproperty(model_inputs, variable)
                object = _model_object(model, object_id)
                provided_type = if disposition == :supplied
                    typeof(getproperty(object.status, variable))
                else
                    nothing
                end
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:input,
                    disposition=disposition,
                    source_application_ids=isnothing(binding) ? Symbol[] : copy(binding.source_application_ids),
                    source_object_ids=isnothing(binding) ? Any[] : [id.value for id in binding.source_ids],
                    source_variable=isnothing(binding) ? nothing : binding.source_var,
                    origin=isnothing(binding) ?
                           (disposition == :supplied ? :status : :missing) :
                           binding.origin,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=provided_type,
                    detail=disposition == :unresolved ?
                           "Provide `$(variable)` on object `$(object_id.value)` Status or add `Inputs(:$(variable) => ...)` to application `$(application.id)`." :
                           nothing,
                ))
            end
            for variable in sort!(Symbol.(collect(keys(meteo_inputs_(application.spec)))); by=string)
                environment_binding = get(
                    environment_bindings,
                    (application.id, object_id),
                    nothing,
                )
                source = get(
                    _environment_source_overrides(application.spec),
                    variable,
                    variable,
                )
                available = isnothing(environment_binding) ?
                            Set{Symbol}() :
                            environment_variables(environment_binding.backend)
                bound = isnothing(available) || Symbol(source) in available
                default_value = getproperty(environment_inputs, variable)
                push!(rows, (
                    application_id=application.id,
                    object_id=object_id.value,
                    variable=variable,
                    role=:environment_input,
                    disposition=bound ? :environment_bound : :unresolved,
                    source_application_ids=Symbol[],
                    source_object_ids=Any[],
                    source_variable=Symbol(source),
                    origin=:environment,
                    expected_type=typeof(default_value),
                    default_value=default_value,
                    provided_type=nothing,
                    detail=bound ? nothing :
                           "Environment source `$(source)` is not available for this application/object.",
                ))
            end
        end
    end
    sort!(rows; by=row -> (
        string(row.application_id),
        string(row.object_id),
        string(row.role),
        string(row.variable),
    ))
    return rows
end

function _compile_model_applications(model::CompositeModel, raw_specs, timeline)
    specs = [as_model_spec(raw_spec) for raw_spec in raw_specs]
    process_counts = Dict{Symbol,Int}()
    for spec in specs
        proc = process(spec)
        process_counts[proc] = get(process_counts, proc, 0) + 1
    end
    ids = Set{Symbol}()
    applications = CompiledModelApplication[]
    for spec in specs
        selector = applies_to(spec)
        isnothing(selector) && error(
            "Model application for process `$(process(spec))` has no `AppliesTo(...)` selector."
        )
        selector isa AbstractObjectMultiplicity || error(
            "`AppliesTo(...)` for process `$(process(spec))` must be an object selector such as `Many(scale=:Leaf)`."
        )
        proc = process(spec)
        name = application_name(spec)
        if isnothing(name) && process_counts[proc] > 1
            error(
                "Composite model contains $(process_counts[proc]) unnamed applications for process `$(proc)`. ",
                "Give every repeated application a unique name with `ModelSpec(model; name=:application_name)`.",
            )
        end
        app_id = isnothing(name) ? proc : name
        app_id in ids && error("Duplicate compiled model application id `$(app_id)`.")
        push!(ids, app_id)
        target_ids = resolve_object_ids(model, selector)
        spec = _model_spec_with_meteo_hints(
            model,
            spec,
            _model_application_hint_scale(model, target_ids),
        )
        model_overrides = _compiled_object_model_overrides(spec, target_ids, app_id)
        push!(
            applications,
            CompiledModelApplication(
                app_id,
                spec,
                proc,
                name,
                target_ids,
                selector,
                timestep(spec),
                _model_application_clock(model, spec, target_ids, timeline),
                model_overrides,
            ),
        )
    end
    return applications
end

function _model_spec_with_meteo_hints(model::CompositeModel, spec, scale::Symbol)
    hint = _normalize_meteo_hint(scale, process(spec), meteo_hint(model_(spec)))

    current_bindings = meteo_bindings(spec)
    has_explicit_bindings = !(current_bindings isa NamedTuple && isempty(keys(current_bindings)))
    new_bindings = has_explicit_bindings || isnothing(hint.bindings) ? current_bindings : hint.bindings
    new_bindings = _model_meteo_bindings_with_environment_sources(spec, new_bindings)

    current_window = meteo_window(spec)
    new_window = isnothing(current_window) && !isnothing(hint.window) ? hint.window : current_window

    (new_bindings === current_bindings && new_window === current_window) && return spec
    return ModelSpec(spec; meteo_bindings=new_bindings, meteo_window=new_window)
end

function _model_meteo_bindings_with_environment_sources(spec, bindings)
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

_application_default_model(application::CompiledModelApplication) =
    model_(application.spec) isa ObjectModelOverrides ?
    model_(application.spec).base :
    model_(application.spec)

function _application_model(application::CompiledModelApplication, object_id::ObjectId)
    isnothing(application.model_overrides) && return _application_default_model(application)
    return get(
        application.model_overrides,
        object_id,
        _application_default_model(application),
    )
end

function _model_output_names(application::CompiledModelApplication)
    return Symbol[Symbol(var) for var in keys(outputs_(application.spec))]
end

function _model_canonical_output_names(application::CompiledModelApplication)
    return Symbol[
        variable for variable in _model_output_names(application)
        if _publish_mode_for_output(application.spec, variable) == :canonical
    ]
end

function _model_writer_groups(applications, skipped_application_ids=Set{Symbol}())
    groups = Dict{Tuple{ObjectId,Symbol},Vector{Tuple{Int,Any}}}()
    for (index, application) in pairs(applications)
        application.id in skipped_application_ids && continue
        for object_id in application.target_ids
            for variable in _model_canonical_output_names(application)
                push!(get!(groups, (object_id, variable), Tuple{Int,Any}[]), (index, application))
            end
        end
    end
    return groups
end

function _application_match_labels(application::CompiledModelApplication)
    labels = Set{Symbol}([application.id])
    isnothing(application.name) || push!(labels, application.name)
    return labels
end

function _update_matches_application(label::Symbol, application::CompiledModelApplication)
    label == application.id && return true
    if label == application.process || (!isnothing(application.name) && label == application.name)
        Base.depwarn(
            "Matching `Updates(...; after=$(repr(label)))` by process or local name is deprecated. " *
            "Use the canonical application identifier `$(application.id)`.",
            :Updates,
        )
        return true
    end
    return false
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
    for update in matching
        after = _update_after(update)
        isempty(after) && continue
        any(
            label -> any(application -> _update_matches_application(label, application), previous_applications),
            after,
        ) && return true
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
        isnothing(binding.application) || push!(ids, binding.application)
    end
    return ids
end

function _validate_model_writers!(applications, call_bindings=())
    manual_application_ids = _manual_call_application_ids(call_bindings)
    for ((object_id, variable), indexed_writers) in _model_writer_groups(applications, manual_application_ids)
        length(indexed_writers) <= 1 && continue
        sort!(indexed_writers; by=first)
        previous = CompiledModelApplication[]
        for (_, application) in indexed_writers
            if _declares_update_without_previous_writer(application.spec, variable, previous)
                error(
                    "Application `$(application.id)` declares `Updates($(variable))` for object ",
                    "`$(object_id.value)`, but no previous writer for `$(variable)` exists. ",
                    "Move it after the producer named in `after=...`."
                )
            end
            if !isempty(previous) && isempty(_matching_updates(application.spec, variable))
                previous_labels = sort!(collect(reduce(union!, (_application_match_labels(app) for app in previous); init=Set{Symbol}())))
                error(
                    "Ambiguous canonical writers for variable `$(variable)` on object ",
                    "`$(object_id.value)`. ",
                    "applications. Application `$(application.id)` must declare ",
                    "`Updates(:$(variable); after=...)` matching one of the previous writers ",
                    "`$(previous_labels)`."
                )
            end
            if !isempty(previous) &&
               !_updates_after_previous_writer(
                   application.spec,
                   variable,
                   CompiledModelApplication[last(previous)],
               )
                previous_writer = last(previous)
                error(
                    "Application `$(application.id)` updates `$(variable)` on object ",
                    "`$(object_id.value)` without an ordering relation to the immediately ",
                    "previous writer `$(previous_writer.id)`. Add that application identifier ",
                    "to `Updates(:$(variable); after=...)`."
                )
            end
            push!(previous, application)
        end
    end
    return nothing
end

function _model_application_hint_scale(model::CompositeModel, target_ids::Vector{ObjectId})
    isempty(target_ids) && return :Scene
    scales = unique!([_model_object(model, object_id).scale for object_id in target_ids])
    length(scales) == 1 && return only(scales)
    return :Mixed
end

function _model_application_clock(model::CompositeModel, spec, target_ids::Vector{ObjectId}, timeline)
    process_model = model_(spec)
    source = _runtime_clock_source_for_spec(spec)
    source == :meteo_base_step || return _model_clock(spec, process_model, timeline)
    scale = _model_application_hint_scale(model, target_ids)
    clock, hint_reason =
        _resolve_meteo_hint_clock(scale, process(spec), process_model, timeline)
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

function _model_policy_from_source_application(applications_by_id, application_id::Symbol, source_var::Symbol)
    application = get(applications_by_id, application_id, nothing)
    isnothing(application) && error(
        "No compiled model application with id `$(application_id)` while resolving ",
        "default output policy for `$(source_var)`."
    )
    return _policy_for_output(_application_default_model(application), source_var)
end

function _model_selector_policy(selector::AbstractObjectMultiplicity, applications_by_id, source_application_ids, source_var::Symbol)
    if _selector_has_policy(selector)
        policy = _selector_policy(selector)
        policy isa PreviousTimeStep && return policy
        return _as_schedule_policy(
            policy;
            context="model input policy for `$(source_var)`",
        )
    end
    isempty(source_application_ids) && return HoldLast()
    length(source_application_ids) == 1 && return _model_policy_from_source_application(
        applications_by_id,
        only(source_application_ids),
        source_var,
    )
    policies = [
        _model_policy_from_source_application(applications_by_id, application_id, source_var)
        for application_id in source_application_ids
    ]
    first_policy = first(policies)
    all(policy -> policy == first_policy, policies) && return first_policy
    error(
        "Cannot infer default policy for model input from `$(source_var)` because ",
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

function _selector_from_status(selector::AbstractObjectMultiplicity)
    from_status = _criteria_get(criteria(selector), :from_status, false)
    from_status isa Bool || error(
        "Selector keyword `from_status` must be `true` or `false`, got `$(repr(from_status))`."
    )
    return from_status
end

function _selector_order_after(selector::AbstractObjectMultiplicity)
    after = _criteria_get(criteria(selector), :after, nothing)
    isnothing(after) && return Symbol[]
    values = after isa Union{Tuple,AbstractVector} ? after : (after,)
    applications = Symbol[Symbol(value) for value in values]
    isempty(applications) && error("Selector keyword `after` cannot be empty.")
    return unique!(applications)
end

function _validate_from_status_selector!(
    selector::AbstractObjectMultiplicity,
    process_filter,
    application_filter,
    applications_by_id,
    consumer_application_id,
)
    order_after = _selector_order_after(selector)
    if !_selector_from_status(selector)
        isempty(order_after) || error(
            "Selector keyword `after` is only supported with `from_status=true`. ",
            "Producer-bound inputs already derive their order from the selected application."
        )
        return order_after
    end
    isnothing(process_filter) || error(
        "`from_status=true` cannot be combined with `process=` because it deliberately ",
        "reads the selected objects' current Status without choosing a producer application."
    )
    isnothing(application_filter) || error(
        "`from_status=true` cannot be combined with `application=` because it deliberately ",
        "reads the selected objects' current Status without choosing a producer application."
    )
    _selector_has_policy(selector) && error(
        "`from_status=true` cannot be combined with a temporal `policy=`. Remove ",
        "`from_status=true` when reading a producer stream."
    )
    isnothing(_selector_window(selector)) || error(
        "`from_status=true` cannot be combined with `window=`. Status bindings are ",
        "same-step live references, not temporal streams."
    )
    for application_id in order_after
        application_id == consumer_application_id && error(
            "Status input on application `$(consumer_application_id)` cannot be ordered after itself."
        )
        haskey(applications_by_id, application_id) || error(
            "Status input on application `$(consumer_application_id)` requested ",
            "`after=$(repr(application_id))`, but no application with that id exists."
        )
    end
    return order_after
end

function _dependency_object_ids(model::CompositeModel, selector::AbstractObjectMultiplicity, context::ObjectId)
    return _resolve_object_ids(
        model,
        selector;
        context=context,
        default_to_context=true,
        default_scope=_default_dependency_scope(model, context),
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

function _input_carrier(model::CompositeModel, selector::AbstractObjectMultiplicity, source_ids::Vector{ObjectId}, source_var::Symbol)
    refs = Base.RefValue[]
    for source_id in source_ids
        object = _model_object(model, source_id)
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

function _ensure_model_object_status!(model::CompositeModel, object_id::ObjectId)
    object = _model_object(model, object_id)
    isnothing(object.status) && (object.status = Status())
    object.status isa Status || error(
        "Model object `$(object_id.value)` uses model applications but its status has type ",
        "`$(typeof(object.status))`. Use `Status(...)` or leave status as `nothing`."
    )
    return object.status
end

function _prepare_model_output_statuses!(model::CompositeModel, applications)
    for application in applications
        defaults = outputs_(application.spec)
        for object_id in application.target_ids
            status = _ensure_model_object_status!(model, object_id)
            for (variable, value) in pairs(defaults)
                status = _status_with_default(status, Symbol(variable), value)
            end
            _model_object(model, object_id).status = status
        end
    end
    return model
end

function _prepare_model_bound_input_statuses!(model::CompositeModel, applications, bindings)
    applications_by_id = Dict(application.id => application for application in applications)
    for binding in bindings
        status = _ensure_model_object_status!(model, binding.consumer_id)
        binding.input in propertynames(status) && continue
        application = applications_by_id[binding.application_id]
        defaults = inputs_(application.spec)
        binding.input in keys(defaults) || error(
            "Bound input `$(binding.input)` is not declared by application `$(binding.application_id)`."
        )
        _model_object(model, binding.consumer_id).status =
            _status_with_default(status, binding.input, getproperty(defaults, binding.input))
    end
    return model
end

function _wire_model_input_carriers!(model::CompositeModel, bindings)
    for binding in bindings
        binding.carrier_hint == :temporal_stream && continue
        isnothing(binding.carrier) && continue
        object = _model_object(model, binding.consumer_id)
        status = object.status
        status isa Status || continue
        reference = binding.carrier isa Base.RefValue ? binding.carrier : Ref(binding.carrier)
        object.status = _status_with_reference(status, binding.input, reference)
    end
    return model
end

function _private_temporal_value(value)
    value isa AbstractArray && return copy(value)
    return value
end

function _temporal_input_initial(binding::CompiledModelInputBinding, status::Status)
    initial = _input_value(binding.carrier)
    isnothing(initial) && (initial = status[binding.input])
    if binding.multiplicity == :many
        initial isa AbstractVector || error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` requires a vector-like initialized value; got ",
            "`$(typeof(initial))`.",
        )
        if length(initial) == length(binding.source_ids)
            return Any[_private_temporal_value(value) for value in initial]
        end
        binding.policy isa PreviousTimeStep && error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` resolved $(length(binding.source_ids)) source ",
            "objects but has $(length(initial)) initialized values.",
        )
        isempty(binding.source_ids) && return Any[]
        isempty(initial) && error(
            "Temporal `Many` input `$(binding.input)` on application ",
            "`$(binding.application_id)` needs an initialized element to preallocate ",
            "$(length(binding.source_ids)) temporal values.",
        )
        return Any[
            _private_temporal_value(first(initial))
            for _ in binding.source_ids
        ]
    end
    return _private_temporal_value(initial)
end

function _private_temporal_storage(binding::CompiledModelInputBinding, initial)
    binding.multiplicity == :many ||
        return _private_temporal_value(initial)
    isempty(initial) && return RefVector{Any}()
    references = Base.RefValue[Ref(_private_temporal_value(value)) for value in initial]
    return _ref_vector_carrier(references)
end

function _temporal_source_application(
    binding::CompiledModelInputBinding,
    source_id::ObjectId,
    applications_by_id,
    application_positions,
)
    isempty(binding.source_application_ids) && return nothing
    length(binding.source_application_ids) == 1 &&
        return only(binding.source_application_ids)
    matches = Symbol[
        application_id for application_id in binding.source_application_ids
        if source_id in applications_by_id[application_id].target_ids
    ]
    if length(matches) == 1
        return only(matches)
    elseif isempty(matches)
        binding.policy isa PreviousTimeStep && return nothing
        error(
            "Temporal model input `$(binding.input)` from ",
            "`$(source_id.value).$(binding.source_var)` has no source application ",
            "matching object `$(source_id.value)`.",
        )
    elseif binding.policy isa PreviousTimeStep
        return last(sort!(matches; by=application_id -> application_positions[application_id]))
    end
    error(
        "Temporal model input `$(binding.input)` from ",
        "`$(source_id.value).$(binding.source_var)` has ambiguous source ",
        "applications `$(matches)`. Add `application=...` to `Inputs(...)`.",
    )
end

function _validate_temporal_input_output_overlap!(
    application::CompiledModelApplication,
    temporal_bindings,
)
    output_names = Set(Symbol.(keys(outputs_(application.spec))))
    for binding in temporal_bindings
        binding.input in output_names || continue
        error(
            "Application `$(application.id)` declares `$(binding.input)` as both a ",
            "temporal input and an output. A temporal input uses application-local ",
            "storage while outputs publish through canonical status, so this overlap ",
            "is ambiguous. Use distinct names such as `previous_$(binding.input)` for ",
            "the lagged input and `$(binding.input)` for the current output, then map ",
            "the source explicitly.",
        )
    end
    return nothing
end

function _compile_model_status_view(
    model::CompositeModel,
    application::CompiledModelApplication,
    object_id::ObjectId,
    input_bindings,
    applications_by_id,
    application_positions,
)
    canonical_status = _ensure_model_object_status!(model, object_id)
    temporal_bindings = Tuple(
        binding for binding in input_bindings
        if binding.carrier_hint == :temporal_stream
    )
    _validate_temporal_input_output_overlap!(application, temporal_bindings)
    temporal_inputs = Tuple(begin
        initial = _temporal_input_initial(binding, canonical_status)
        CompiledTemporalInput(
            binding,
            Union{Nothing,Symbol}[
                _temporal_source_application(
                    binding,
                    source_id,
                    applications_by_id,
                    application_positions,
                )
                for source_id in binding.source_ids
            ],
            initial,
            Ref(_private_temporal_storage(binding, initial)),
        )
    end for binding in temporal_bindings)
    temporal_by_name = Dict(
        temporal_input.binding.input => temporal_input
        for temporal_input in temporal_inputs
    )
    names = propertynames(canonical_status)
    references = ntuple(length(names)) do index
        name = names[index]
        temporal_input = get(temporal_by_name, name, nothing)
        isnothing(temporal_input) && return refvalue(canonical_status, name)
        return temporal_input.reference
    end
    status = Status(NamedTuple{names}(references))
    return CompiledModelStatusView(status, canonical_status, temporal_inputs)
end

function _compile_model_status_views(
    model::CompositeModel,
    applications,
    applications_by_id,
    input_bindings_by_target,
    application_order,
)
    views = Dict{Tuple{Symbol,ObjectId},Any}()
    positions = Dict(
        application_id => index
        for (index, application_id) in pairs(application_order)
    )
    for application in applications
        for object_id in application.target_ids
            key = (application.id, object_id)
            views[key] = _compile_model_status_view(
                model,
                application,
                object_id,
                get(input_bindings_by_target, key, ()),
                applications_by_id,
                positions,
            )
        end
    end
    return views
end

input_carrier(binding::CompiledModelInputBinding) = binding.carrier
has_reference_carrier(binding::CompiledModelInputBinding) = !isnothing(binding.carrier)
input_value(binding::CompiledModelInputBinding) = _input_value(binding.carrier)
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
            source_var in _model_output_names(application) || continue
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

function _potential_input_source_applications(
    applications_by_id,
    source_var::Symbol,
    process_filter,
    application_filter,
)
    matches = Symbol[
        application.id
        for application in values(applications_by_id)
        if source_var in _model_output_names(application) &&
           (isnothing(process_filter) || application.process == process_filter) &&
           (isnothing(application_filter) || application.id == application_filter)
    ]
    sort!(matches)
    return matches
end

function _final_canonical_source_application(
    applications_by_object,
    source_ids,
    source_application_ids,
    source_var::Symbol,
)
    length(source_ids) == 1 || return source_application_ids
    matching_ids = Set(source_application_ids)
    canonical_ids = Symbol[
        application.id
        for application in get(applications_by_object, only(source_ids), Any[])
        if application.id in matching_ids &&
           _publish_mode_for_output(application.spec, source_var) == :canonical
    ]
    isempty(canonical_ids) && return source_application_ids
    return Symbol[last(canonical_ids)]
end

function _compile_model_input_bindings(
    model::CompositeModel,
    applications,
    manual_application_ids=Set{Symbol}(),
)
    bindings = CompiledModelInputBinding[]
    by_object = _applications_by_object(applications)
    by_id = Dict(application.id => application for application in applications)
    for application in applications
        for consumer_id in application.target_ids
            declared_inputs = value_inputs(application.spec)
            declared_inputs isa NamedTuple || (declared_inputs = NamedTuple())
            for (input_name, selector) in pairs(declared_inputs)
                input_sym = Symbol(input_name)
                origin = get(
                    input_origins(application.spec),
                    input_sym,
                    :model_spec,
                )
                _validate_declared_model_input_name!(application, input_sym)
                selector isa AbstractObjectMultiplicity || error(
                    "Input binding `$(input_sym)` on application `$(application.id)` must use an object selector."
                )
                if origin == :model_spec && !(selector isa Many) &&
                   !isnothing(_criteria_get(criteria(selector), :process, nothing)) &&
                   isnothing(_selector_application(selector))
                    Base.depwarn(
                        "`process=` in scenario `Inputs` is deprecated; name the producer application and use `application=`.",
                        :Inputs,
                    )
                end
                _push_model_input_binding!(
                    bindings,
                    model,
                    application,
                    consumer_id,
                    input_sym,
                    selector,
                    origin,
                    by_object,
                    by_id,
                )
            end
            application.id in manual_application_ids && continue
            _append_inferred_model_input_bindings!(
                bindings,
                model,
                application,
                consumer_id,
                declared_inputs,
                by_object,
                by_id,
            )
        end
    end
    return bindings
end

function _push_model_input_binding!(
    bindings,
    model::CompositeModel,
    application::CompiledModelApplication,
    consumer_id::ObjectId,
    input_sym::Symbol,
    selector::AbstractObjectMultiplicity,
    origin::Symbol,
    applications_by_object,
    applications_by_id,
    source_ids_override=nothing,
)
    source_ids = isnothing(source_ids_override) ? _dependency_object_ids(model, selector, consumer_id) : source_ids_override
    window = _selector_window(selector)
    source_var = _selector_var(selector, input_sym)
    process_filter = _criteria_get(criteria(selector), :process, nothing)
    application_filter = _selector_application(selector)
    order_after_application_ids = _validate_from_status_selector!(
        selector,
        process_filter,
        application_filter,
        applications_by_id,
        application.id,
    )
    source_application_ids = if _selector_from_status(selector)
        Symbol[]
    else
        _matching_input_source_applications(
            applications_by_object,
            source_ids,
            source_var,
            process_filter,
            application_filter,
            allow_empty=selector isa OptionalOne ||
                        (selector isa Many && isempty(source_ids)),
        )
    end
    if selector isa Many &&
       isempty(source_ids) &&
       (!isnothing(process_filter) || !isnothing(application_filter))
        source_application_ids = _potential_input_source_applications(
            applications_by_id,
            source_var,
            process_filter,
            application_filter,
        )
        isempty(source_application_ids) && error(
            "Input selector for source variable `$(source_var)` requested",
            isnothing(process_filter) ? "" : " process `$(process_filter)`",
            isnothing(application_filter) ? "" : " application `$(application_filter)`",
            ", but no matching source application was found.",
        )
    end
    if !(selector isa Many) &&
       isnothing(process_filter) &&
       isnothing(application_filter) &&
       length(source_application_ids) > 1
        source_application_ids = _final_canonical_source_application(
            applications_by_object,
            source_ids,
            source_application_ids,
            source_var,
        )
    end
    if !(selector isa Many) && length(source_application_ids) > 1
        error(
            "Input `$(input_sym)` on application `$(application.id)` matched several " *
            "source applications `$(source_application_ids)`. Add one of those canonical " *
            "identifiers as `application=...` to `Inputs(...)`.",
        )
    end
    if selector isa OptionalOne &&
       (!isnothing(process_filter) || !isnothing(application_filter)) &&
       isempty(source_application_ids)
        source_ids = ObjectId[]
    end
    policy = _model_selector_policy(selector, applications_by_id, source_application_ids, source_var)
    if policy isa PreviousTimeStep
        policy.variable == input_sym || error(
            "PreviousTimeStep marker for input `$(input_sym)` on application ",
            "`$(application.id)` names `$(policy.variable)`. Use ",
            "`PreviousTimeStep(:$(input_sym))`."
        )
    else
        _validate_policy_instance(
            _model_object(model, consumer_id).scale,
            application.process,
            input_sym,
            policy,
        )
    end
    carrier = _input_carrier(model, selector, source_ids, source_var)
    carrier_hint =
        isempty(source_ids) && selector isa OptionalOne ?
        :optional_default :
        _carrier_hint(selector, policy, window)
    _validate_model_input_source!(
        model,
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
        CompiledModelInputBinding(
            application.id,
            consumer_id,
            input_sym,
            selector,
            origin,
            source_ids,
            source_application_ids,
            order_after_application_ids,
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

function _model_input_names(application::CompiledModelApplication)
    return Symbol[Symbol(var) for var in keys(inputs_(application.spec))]
end

function _validate_model_input_source!(
    model::CompositeModel,
    application::CompiledModelApplication,
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
        if _model_object(model, source_id).status isa Status
    ]
    isempty(status_source_ids) && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` for object ",
        "`$(consumer_id.value)` reads `$(source_var)` from objects ",
        "`$([id.value for id in status_source_ids])`, but no source `Status` reference is available."
    )
end

function _validate_declared_model_input_name!(application::CompiledModelApplication, input_sym::Symbol)
    input_names = Set(_model_input_names(application))
    input_sym in input_names && return nothing
    error(
        "Input binding `$(input_sym)` on application `$(application.id)` is not declared by ",
        "`inputs_` for process `$(application.process)`. Declared model inputs are ",
        "`$(sort!(collect(input_names)))`."
    )
end

function _same_object_output_applications(applications_by_object, application::CompiledModelApplication, object_id::ObjectId, variable::Symbol)
    matches = CompiledModelApplication[]
    for candidate in get(applications_by_object, object_id, Any[])
        candidate.id == application.id && continue
        variable in _model_canonical_output_names(candidate) || continue
        push!(matches, candidate)
    end
    return matches
end

function _append_inferred_model_input_bindings!(
    bindings,
    model::CompositeModel,
    application::CompiledModelApplication,
    consumer_id::ObjectId,
    declared_inputs,
    applications_by_object,
    applications_by_id,
)
    declared_names = declared_inputs isa NamedTuple ? Set(Symbol.(keys(declared_inputs))) : Set{Symbol}()
    for input_sym in _model_input_names(application)
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
        _push_model_input_binding!(
            bindings,
            model,
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

function _bound_model_inputs(input_bindings)
    bound = Set{Tuple{Symbol,ObjectId,Symbol}}()
    for binding in input_bindings
        push!(bound, (binding.application_id, binding.consumer_id, binding.input))
    end
    return bound
end

function _status_has_variable(model::CompositeModel, object_id::ObjectId, variable::Symbol)
    object = _model_object(model, object_id)
    object.status isa Status || return false
    return variable in propertynames(object.status)
end

function _validate_model_required_inputs!(model::CompositeModel, applications, input_bindings)
    bound = _bound_model_inputs(input_bindings)
    missing = NamedTuple[]
    for application in applications
        for object_id in application.target_ids
            for input in _model_input_names(application)
                (application.id, object_id, input) in bound && continue
                _status_has_variable(model, object_id, input) && continue
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
        "Missing required composite-model/object input(s): ",
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

function _compile_model_call_bindings(
    model::CompositeModel,
    applications,
    lookup_applications=applications,
    ;
    by_object=nothing,
)
    isnothing(by_object) && (by_object = _applications_by_object(lookup_applications))
    bindings = CompiledModelCallBinding[]
    for application in applications
        calls = model_calls(application.spec)
        calls isa NamedTuple || continue
        for consumer_id in application.target_ids
            for (call_name, selector) in pairs(calls)
                call_sym = Symbol(call_name)
                origin = get(
                    call_origins(application.spec),
                    call_sym,
                    :model_spec,
                )
                selector isa AbstractObjectMultiplicity || error(
                    "Call binding `$(call_sym)` on application `$(application.id)` must use an object selector."
                )
                if origin == :model_spec && !(selector isa Many) &&
                   !isnothing(_criteria_get(criteria(selector), :process, nothing)) &&
                   isnothing(_selector_application(selector))
                    Base.depwarn(
                        "`process=` in scenario `Calls` is deprecated; name the callee application and use `application=`.",
                        :Calls,
                    )
                end
                callee_object_ids = _dependency_object_ids(model, selector, consumer_id)
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
                if isempty(callee_application_ids) && selector isa One
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
                    CompiledModelCallBinding(
                        application.id,
                        consumer_id,
                        call_sym,
                        selector,
                        origin,
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

function _model_call_owners(call_bindings)
    owners = Dict{Symbol,Set{Symbol}}()
    for binding in call_bindings
        for callee_id in binding.callee_application_ids
            push!(get!(owners, callee_id, Set{Symbol}()), binding.application_id)
        end
    end
    return owners
end

function _add_model_application_edge!(children, parent::Symbol, child::Symbol)
    parent == child && return nothing
    push!(get!(children, parent, Set{Symbol}()), child)
    return nothing
end

function _model_input_order_edges!(children, input_bindings, call_owners)
    for binding in input_bindings
        binding.policy isa PreviousTimeStep && continue
        ordering_sources = (
            binding.source_application_ids...,
            binding.order_after_application_ids...,
        )
        for source_id in ordering_sources
            owners = get(call_owners, source_id, nothing)
            if isnothing(owners)
                _add_model_application_edge!(children, source_id, binding.application_id)
            else
                for owner_id in owners
                    _add_model_application_edge!(children, owner_id, binding.application_id)
                end
            end
        end
    end
    return children
end

function _model_update_order_edges!(children, applications)
    for indexed_writers in values(_model_writer_groups(applications))
        length(indexed_writers) > 1 || continue
        sort!(indexed_writers; by=first)
        for index in 2:length(indexed_writers)
            previous_application = indexed_writers[index - 1][2]
            application = indexed_writers[index][2]
            _add_model_application_edge!(children, previous_application.id, application.id)
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
            "Composite model application dependency cycle detected among applications `$(remaining)`. ",
            "Break the same-timestep cycle with a temporal policy or revise `Inputs(...)`/`Updates(...)`."
        )
    end
    return order
end

function _compile_model_application_order(applications, input_bindings, call_bindings)
    children = Dict{Symbol,Set{Symbol}}()
    call_owners = _model_call_owners(call_bindings)
    _model_input_order_edges!(children, input_bindings, call_owners)
    _model_update_order_edges!(children, applications)
    return _stable_topological_application_order(applications, children)
end

function _ordered_model_applications(compiled::CompiledCompositeModel)
    return [compiled.applications_by_id[application_id] for application_id in compiled.application_order]
end

function explain_applications(compiled::CompiledCompositeModel)
    return [
        (
            application_id=application.id,
            process=application.process,
            name=application.name,
            target_ids=[id.value for id in application.target_ids],
            target_scales=sort!(unique!(Symbol[
                _model_object(compiled.model, id).scale
                for id in application.target_ids
                if !isnothing(_model_object(compiled.model, id).scale)
            ]); by=string),
            applies_to=application.applies_to,
            inputs=Tuple(Symbol.(keys(inputs_(application.spec)))),
            outputs=Tuple(Symbol.(keys(outputs_(application.spec)))),
            environment_inputs=Tuple(Symbol.(keys(meteo_inputs_(application.spec)))),
            environment_outputs=Tuple(Symbol.(keys(meteo_outputs_(application.spec)))),
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

explain_applications(model::CompositeModel) =
    explain_applications(refresh_bindings!(model))

function _application_model_dispatch(application::CompiledModelApplication)
    isnothing(application.model_overrides) && return :concrete_shared
    override_type = valtype(typeof(application.model_overrides))
    default_type = typeof(_application_default_model(application))
    return isconcretetype(override_type) && default_type == override_type ?
           :concrete_per_object :
           :heterogeneous_per_object
end

function explain_schedule(compiled::CompiledCompositeModel)
    timeline = compiled.timeline
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
        for application in _ordered_model_applications(compiled)
    ]
end

explain_schedule(model::CompositeModel) = explain_schedule(refresh_bindings!(model))

function _model_binding_carrier_kind(binding::CompiledModelInputBinding)
    binding.carrier_hint == :temporal_stream && return :temporal_stream
    binding.carrier_hint == :optional_default && return :optional_default
    carrier = binding.carrier
    isnothing(carrier) && return :unresolved
    carrier isa Base.RefValue && return :ref
    carrier isa RefVector && return :ref_vector
    carrier isa ObjectRefVector && return :object_ref_vector
    return :custom
end

function _model_binding_copy_semantics(binding::CompiledModelInputBinding)
    kind = _model_binding_carrier_kind(binding)
    kind in (:ref, :ref_vector, :object_ref_vector) && return :live_references
    kind == :temporal_stream && return :materialized_temporal_value
    kind == :optional_default && return :consumer_default
    kind == :unresolved && return :not_materialized
    return :backend_defined
end

function explain_bindings(compiled::CompiledCompositeModel)
    return [
        (
            application_id=binding.application_id,
            consumer_id=binding.consumer_id.value,
            input=binding.input,
            origin=binding.origin,
            source_ids=[id.value for id in binding.source_ids],
            source_application_ids=binding.source_application_ids,
            order_after_application_ids=binding.order_after_application_ids,
            source_var=binding.source_var,
            process=binding.process,
            application=binding.application,
            multiplicity=binding.multiplicity,
            policy=binding.policy,
            window=binding.window,
            carrier_hint=binding.carrier_hint,
            carrier_kind=_model_binding_carrier_kind(binding),
            copy_semantics=_model_binding_copy_semantics(binding),
            has_reference_carrier=has_reference_carrier(binding),
            carrier_type=isnothing(binding.carrier) ? nothing : typeof(binding.carrier),
            selector=binding.selector,
        )
        for binding in compiled.input_bindings
    ]
end

explain_bindings(model::CompositeModel) = explain_bindings(refresh_bindings!(model))

function explain_calls(compiled::CompiledCompositeModel)
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

explain_calls(model::CompositeModel) = explain_calls(refresh_bindings!(model))

function explain_model_bundles(compiled::CompiledCompositeModel)
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

explain_model_bundles(model::CompositeModel) =
    explain_model_bundles(refresh_bindings!(model))

function explain_writers(compiled::CompiledCompositeModel)
    groups = _model_writer_groups(compiled.applications, _manual_call_application_ids(compiled))
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

explain_writers(model::CompositeModel) = explain_writers(refresh_bindings!(model))
