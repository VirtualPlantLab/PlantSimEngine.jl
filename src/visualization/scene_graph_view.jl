"""
    SceneGraphDiagnostic

Structured diagnostic emitted while compiling a scene for visualization. A
graph report keeps diagnostics attached to stable application, object, and
variable identities so an editor can present actionable controls.
"""
struct SceneGraphDiagnostic
    code::Symbol
    severity::Symbol
    message::String
    phase::Symbol
    application_ids::Vector{Symbol}
    object_ids::Vector{Any}
    variable::Union{Nothing,Symbol}
    suggestions::Vector{String}
end

"""
    SceneCompilationReport

Best-effort result of compiling a `Scene` for inspection. Unlike
[`compile_scene`](@ref), this representation preserves successful earlier
phases when a later phase reports an invalid selector, binding, writer, or
cycle.
"""
struct SceneCompilationReport
    scene::Scene
    initial_status_variables::Dict{ObjectId,Set{Symbol}}
    applications::Any
    input_bindings::Any
    call_bindings::Any
    application_order::Vector{Symbol}
    dependency_children::Dict{Symbol,Set{Symbol}}
    cycles::Vector{Vector{Symbol}}
    diagnostics::Vector{SceneGraphDiagnostic}
    compiled::Any
end

"""
    SceneGraphView

JSON-oriented, renderer-independent representation of a Scene/Object graph.
Applications are the default visual unit; `executions` optionally expands them
into concrete `(application, object)` targets.
"""
struct SceneGraphView
    level::Symbol
    metadata::Dict{String,Any}
    objects::Vector{Dict{String,Any}}
    instances::Vector{Dict{String,Any}}
    applications::Vector{Dict{String,Any}}
    executions::Vector{Dict{String,Any}}
    edges::Vector{Dict{String,Any}}
    model_library::Vector{Dict{String,Any}}
    initialization::Vector{Dict{String,Any}}
    diagnostics::Vector{Dict{String,Any}}
    cycles::Vector{Dict{String,Any}}
    available_actions::Vector{String}
end

function _scene_graph_diagnostic(
    err,
    phase::Symbol;
    code=Symbol(phase, :_error),
    severity=:error,
    application_ids=Symbol[],
    object_ids=Any[],
    variable=nothing,
    suggestions=String[],
)
    return SceneGraphDiagnostic(
        Symbol(code),
        Symbol(severity),
        sprint(showerror, err),
        phase,
        Symbol[Symbol(id) for id in application_ids],
        Any[object_ids...],
        isnothing(variable) ? nothing : Symbol(variable),
        String[String(item) for item in suggestions],
    )
end

function _scene_graph_phase!(operation, diagnostics, phase::Symbol, fallback)
    try
        return operation()
    catch err
        push!(diagnostics, _scene_graph_diagnostic(err, phase))
        return fallback
    end
end

function _scene_graph_dependency_children(applications, input_bindings, call_bindings)
    children = Dict{Symbol,Set{Symbol}}()
    call_owners = _scene_call_owners(call_bindings)
    _scene_input_order_edges!(children, input_bindings, call_owners)
    _scene_update_order_edges!(children, applications)
    return children
end

function _scene_graph_cycle_components(applications, children)
    application_ids = Symbol[application.id for application in applications]
    index = Ref(0)
    indexes = Dict{Symbol,Int}()
    lowlinks = Dict{Symbol,Int}()
    stack = Symbol[]
    on_stack = Set{Symbol}()
    components = Vector{Vector{Symbol}}()

    function visit(application_id::Symbol)
        index[] += 1
        indexes[application_id] = index[]
        lowlinks[application_id] = index[]
        push!(stack, application_id)
        push!(on_stack, application_id)

        for child in sort!(collect(get(children, application_id, Set{Symbol}())); by=string)
            if !haskey(indexes, child)
                visit(child)
                lowlinks[application_id] = min(lowlinks[application_id], lowlinks[child])
            elseif child in on_stack
                lowlinks[application_id] = min(lowlinks[application_id], indexes[child])
            end
        end

        lowlinks[application_id] == indexes[application_id] || return
        component = Symbol[]
        while !isempty(stack)
            member = pop!(stack)
            delete!(on_stack, member)
            push!(component, member)
            member == application_id && break
        end
        if length(component) > 1 || application_id in get(children, application_id, Set{Symbol}())
            sort!(component; by=string)
            push!(components, component)
        end
    end

    for application_id in application_ids
        haskey(indexes, application_id) || visit(application_id)
    end
    sort!(components; by=component -> join(string.(component), ":"))
    return components
end

function _scene_graph_compiled(
    scene,
    applications,
    input_bindings,
    call_bindings,
    application_order,
    diagnostics,
)
    isempty(diagnostics) || return nothing
    applications_by_id = Dict(application.id => application for application in applications)
    input_by_target = _index_scene_bindings(input_bindings, :application_id, :consumer_id)
    call_by_target = _index_scene_bindings(call_bindings, :application_id, :consumer_id)
    model_bundles = _compile_scene_model_bundles(
        applications,
        applications_by_id,
        call_by_target,
    )
    return CompiledScene(
        scene,
        applications,
        applications_by_id,
        _applications_by_object(applications),
        input_bindings,
        call_bindings,
        input_by_target,
        call_by_target,
        _index_dynamic_input_bindings(scene, input_bindings),
        model_bundles,
        application_order,
        _scene_timeline(scene),
        scene.revision,
    )
end

function _scene_graph_fallback_application(scene, raw_spec, timeline)
    spec = as_model_spec(raw_spec)
    selector = applies_to(spec)
    selector isa AbstractObjectMultiplicity || error(
        "Model application for process `$(process(spec))` has no valid `AppliesTo(...)` selector.",
    )
    application_id = something(application_name(spec), process(spec))
    target_ids = resolve_object_ids(scene, selector)
    return CompiledSceneApplication(
        application_id,
        spec,
        process(spec),
        application_name(spec),
        target_ids,
        selector,
        timestep(spec),
        _scene_application_clock(scene, spec, target_ids, timeline),
        _compiled_object_model_overrides(spec, target_ids, application_id),
    )
end

function _scene_graph_compile_applications(scene, timeline, diagnostics)
    applications = _scene_graph_phase!(diagnostics, :applications, CompiledSceneApplication[]) do
        _compile_scene_applications(scene, Tuple(scene.applications), timeline)
    end
    isempty(applications) || return applications
    isempty(scene.applications) && return applications

    recovered = CompiledSceneApplication[]
    recovered_ids = Set{Symbol}()
    for raw_spec in scene.applications
        try
            application = _scene_graph_fallback_application(scene, raw_spec, timeline)
            application.id in recovered_ids && error(
                "Duplicate recovered scene application id `$(application.id)`.",
            )
            push!(recovered_ids, application.id)
            push!(recovered, application)
        catch err
            spec = as_model_spec(raw_spec)
            application_id = something(application_name(spec), process(spec))
            push!(diagnostics, _scene_graph_diagnostic(
                err,
                :application_recovery;
                application_ids=[application_id],
                suggestions=["Fix the application selector or authored configuration."],
            ))
        end
    end
    return recovered
end

"""
    compile_scene_report(scene; strict=false)

Compile a Scene for visualization while retaining partial graph information
and structured diagnostics. With `strict=true`, call the simulation compiler
and propagate its errors unchanged.
"""
function compile_scene_report(scene::Scene; strict::Bool=false)
    # Compilation wires reference carriers and prepares generated status fields.
    # A viewer must not mutate the user's editable or pre-run Scene merely by
    # inspecting it, so all diagnostic compilation happens on a structural copy.
    initial_status_variables = Dict(
        object.id => Set{Symbol}(
            object.status isa Status ? Symbol.(propertynames(object.status)) : Symbol[],
        )
        for object in values(scene.registry.objects)
    )
    scene = deepcopy(scene)
    if strict
        compiled = compile_scene(scene)
        children = _scene_graph_dependency_children(
            compiled.applications,
            compiled.input_bindings,
            compiled.call_bindings,
        )
        return SceneCompilationReport(
            scene,
            initial_status_variables,
            compiled.applications,
            compiled.input_bindings,
            compiled.call_bindings,
            Symbol[compiled.application_order...],
            children,
            Vector{Vector{Symbol}}(),
            SceneGraphDiagnostic[],
            compiled,
        )
    end

    diagnostics = SceneGraphDiagnostic[]
    timeline = _scene_graph_phase!(diagnostics, :timeline, nothing) do
        _scene_timeline(scene)
    end
    isnothing(timeline) && return SceneCompilationReport(
        scene,
        initial_status_variables,
        CompiledSceneApplication[],
        CompiledSceneInputBinding[],
        CompiledSceneCallBinding[],
        Symbol[],
        Dict{Symbol,Set{Symbol}}(),
        Vector{Vector{Symbol}}(),
        diagnostics,
        nothing,
    )

    applications = _scene_graph_compile_applications(scene, timeline, diagnostics)
    isempty(applications) && !isempty(scene.applications) && return SceneCompilationReport(
        scene,
        initial_status_variables,
        applications,
        CompiledSceneInputBinding[],
        CompiledSceneCallBinding[],
        Symbol[],
        Dict{Symbol,Set{Symbol}}(),
        Vector{Vector{Symbol}}(),
        diagnostics,
        nothing,
    )

    call_bindings = _scene_graph_phase!(diagnostics, :calls, CompiledSceneCallBinding[]) do
        _compile_scene_call_bindings(scene, applications)
    end
    _scene_graph_phase!(diagnostics, :call_cadence, nothing) do
        _validate_scene_call_cadences!(applications, call_bindings, timeline)
    end
    _scene_graph_phase!(diagnostics, :writers, nothing) do
        _validate_scene_writers!(applications, call_bindings)
    end
    _scene_graph_phase!(diagnostics, :output_status, nothing) do
        _prepare_scene_output_statuses!(scene, applications)
    end

    input_bindings = _scene_graph_phase!(diagnostics, :inputs, CompiledSceneInputBinding[]) do
        _compile_scene_input_bindings(
            scene,
            applications,
            _manual_call_application_ids(call_bindings),
        )
    end
    _scene_graph_phase!(diagnostics, :input_status, nothing) do
        _prepare_scene_bound_input_statuses!(scene, applications, input_bindings)
        _wire_scene_input_carriers!(scene, input_bindings)
    end

    children = Dict{Symbol,Set{Symbol}}()
    _scene_graph_phase!(diagnostics, :dependency_inputs, nothing) do
        call_owners = _scene_call_owners(call_bindings)
        _scene_input_order_edges!(children, input_bindings, call_owners)
    end
    _scene_graph_phase!(diagnostics, :update_order, nothing) do
        _scene_update_order_edges!(children, applications)
    end
    cycles = _scene_graph_cycle_components(applications, children)
    application_order = Symbol[]
    if isempty(cycles)
        application_order = _scene_graph_phase!(diagnostics, :schedule, Symbol[]) do
            _stable_topological_application_order(applications, children)
        end
    else
        for cycle in cycles
            message = "Scene application dependency cycle detected among applications `$(cycle)`."
            push!(diagnostics, SceneGraphDiagnostic(
                :application_cycle,
                :error,
                message,
                :schedule,
                copy(cycle),
                Any[],
                nothing,
                [
                    "Mark an eligible input as PreviousTimeStep to use its previous accepted value.",
                    "Revise Inputs(...) or Updates(...) to remove the same-step dependency.",
                ],
            ))
        end
    end

    compiled = try
        _scene_graph_compiled(
            scene,
            applications,
            input_bindings,
            call_bindings,
            application_order,
            diagnostics,
        )
    catch err
        push!(diagnostics, _scene_graph_diagnostic(err, :model_bundles))
        nothing
    end

    return SceneCompilationReport(
        scene,
        initial_status_variables,
        applications,
        input_bindings,
        call_bindings,
        application_order,
        children,
        cycles,
        diagnostics,
        compiled,
    )
end

_scene_graph_object_id(value) = value isa ObjectId ? value.value : value
_scene_graph_application_node_id(id) = string("application:", id)
_scene_graph_object_node_id(id) = string("object:", _scene_graph_object_id(id))
_scene_graph_instance_node_id(name) = string("instance:", name)
_scene_graph_execution_node_id(application_id, object_id) =
    string("execution:", application_id, ":", _scene_graph_object_id(object_id))
_scene_graph_port_id(application_id, role, variable) =
    string(_scene_graph_application_node_id(application_id), ":", role, ":", variable)

function _scene_graph_json_value(value)
    value === nothing && return nothing
    value === missing && return nothing
    value isa Bool && return value
    if value isa Real
        return isfinite(value) ? value : string(value)
    end
    value isa AbstractString && return String(value)
    value isa Symbol && return string(value)
    value isa ObjectId && return _scene_graph_json_value(value.value)
    value isa Type && return string(value)
    value isa Module && return string(value)
    value isa Pair && return Dict(
        "first" => _scene_graph_json_value(first(value)),
        "second" => _scene_graph_json_value(last(value)),
    )
    if value isa NamedTuple
        return Dict(string(key) => _scene_graph_json_value(item) for (key, item) in pairs(value))
    end
    if value isa AbstractDict
        return Dict(string(key) => _scene_graph_json_value(item) for (key, item) in pairs(value))
    end
    if value isa Tuple || value isa AbstractArray || value isa AbstractSet
        return [_scene_graph_json_value(item) for item in value]
    end
    value isa AbstractObjectMultiplicity && return _scene_graph_selector_dict(value)
    return string(value)
end

function _scene_graph_selector_atom(selector::AbstractObjectSelector)
    descriptor = Dict{String,Any}("type" => string(nameof(typeof(selector))))
    selector isa Ancestor && (descriptor["scale"] = _scene_graph_json_value(selector.scale))
    selector isa Scope && (descriptor["name"] = string(selector.name))
    selector isa Kind && (descriptor["kind"] = string(selector.kind))
    selector isa Species && (descriptor["species"] = string(selector.species))
    selector isa Scale && (descriptor["scale"] = string(selector.scale))
    selector isa Relation && (descriptor["relation"] = string(selector.relation))
    return descriptor
end

function _scene_graph_policy_dict(policy)
    descriptor = Dict{String,Any}(
        "type" => string(nameof(typeof(policy))),
        "julia" => repr(policy),
    )
    policy isa PreviousTimeStep && (descriptor["variable"] = string(policy.variable))
    policy isa PreviousTimeStep && (descriptor["process"] = string(policy.process))
    policy isa Interpolate && (descriptor["mode"] = string(policy.mode))
    policy isa Interpolate && (descriptor["extrapolation"] = string(policy.extrapolation))
    policy isa Union{Integrate,Aggregate} && (descriptor["reducer"] = repr(policy.reducer))
    return descriptor
end

function _scene_graph_selector_criteria(selector::AbstractObjectMultiplicity)
    result = Dict{String,Any}()
    for (key_, value) in pairs(criteria(selector))
        key = Symbol(key_)
        result[string(key)] = if key == :selectors
            [_scene_graph_selector_atom(item) for item in value]
        elseif key == :within && value isa AbstractObjectSelector
            _scene_graph_selector_atom(value)
        elseif key == :policy
            _scene_graph_policy_dict(value)
        else
            _scene_graph_json_value(value)
        end
    end
    return result
end

function _scene_graph_selector_dict(selector::AbstractObjectMultiplicity)
    return Dict{String,Any}(
        "type" => string(nameof(typeof(selector))),
        "multiplicity" => string(multiplicity(selector)),
        "criteria" => _scene_graph_selector_criteria(selector),
        "julia" => repr(selector),
    )
end

function _scene_graph_model_parameters(model)
    parameters = Dict{String,Any}()
    for field in fieldnames(Base.unwrap_unionall(typeof(model)))
        value = getfield(model, field)
        parameters[string(field)] = Dict{String,Any}(
            "value" => _scene_graph_json_value(value),
            "julia" => repr(value),
            "type" => string(_parameter_choice_from_type(typeof(value))),
            "juliaType" => string(typeof(value)),
        )
    end
    return parameters
end

function _scene_graph_port(application, role::Symbol, variable, default)
    name = Symbol(variable)
    return Dict{String,Any}(
        "id" => _scene_graph_port_id(application.id, role, name),
        "name" => string(name),
        "role" => string(role),
        "default" => _scene_graph_json_value(default),
        "defaultJulia" => repr(default),
        "expectedType" => string(typeof(default)),
    )
end

function _scene_graph_application_dict(scene, application)
    model = _application_default_model(application)
    spec = application.spec
    inputs = inputs_(application.spec)
    outputs = outputs_(application.spec)
    environment_inputs = meteo_inputs_(application.spec)
    environment_outputs = meteo_outputs_(application.spec)
    target_objects = [_scene_object(scene, id) for id in application.target_ids]
    environment = environment_config(spec)
    environment_payload = environment isa EnvironmentConfig ? environment.config : environment
    return Dict{String,Any}(
        "id" => _scene_graph_application_node_id(application.id),
        "applicationId" => string(application.id),
        "name" => isnothing(application.name) ? nothing : string(application.name),
        "process" => string(application.process),
        "modelType" => string(typeof(model)),
        "modelName" => string(nameof(typeof(model))),
        "module" => string(parentmodule(typeof(model))),
        "package" => _model_package_name(parentmodule(typeof(model))),
        "modelParameters" => _scene_graph_model_parameters(model),
        "selector" => _scene_graph_selector_dict(application.applies_to),
        "targetIds" => [_scene_graph_json_value(id.value) for id in application.target_ids],
        "targetCount" => length(application.target_ids),
        "targetScales" => sort!(unique!(String[string(object.scale) for object in target_objects if !isnothing(object.scale)])),
        "targetKinds" => sort!(unique!(String[string(object.kind) for object in target_objects if !isnothing(object.kind)])),
        "targetSpecies" => sort!(unique!(String[string(object.species) for object in target_objects if !isnothing(object.species)])),
        "targetInstances" => sort!(unique!(String[
            string(instance) for id in application.target_ids
            for instance in (_object_instance_name(scene, id),)
            if !isnothing(instance)
        ])),
        "timestep" => _scene_graph_json_value(application.timestep),
        "clock" => _scene_graph_json_value(application.clock),
        "inputs" => [_scene_graph_port(application, :input, name, value) for (name, value) in pairs(inputs)],
        "outputs" => [_scene_graph_port(application, :output, name, value) for (name, value) in pairs(outputs)],
        "environmentInputs" => [_scene_graph_port(application, :environment_input, name, value) for (name, value) in pairs(environment_inputs)],
        "environmentOutputs" => [_scene_graph_port(application, :environment_output, name, value) for (name, value) in pairs(environment_outputs)],
        "inputBindings" => Dict(
            string(name) => _scene_graph_selector_dict(selector)
            for (name, selector) in pairs(value_inputs(spec))
        ),
        "callBindings" => Dict(
            string(name) => _scene_graph_selector_dict(selector)
            for (name, selector) in pairs(model_calls(spec))
        ),
        "environment" => _scene_graph_json_value(environment_payload),
        "meteoBindings" => _scene_graph_json_value(meteo_bindings(spec)),
        "meteoWindow" => _scene_graph_json_value(meteo_window(spec)),
        "outputRouting" => _scene_graph_json_value(output_routing(spec)),
        "updates" => [
            Dict(
                "variables" => collect(string.(_update_variables(update))),
                "after" => collect(string.(_update_after(update))),
            )
            for update in updates(spec)
        ],
        "modelStorage" => isnothing(application.model_overrides) ? "shared_application" : "per_object_override",
        "objectOverrides" => isnothing(application.model_overrides) ? Any[] : [
            Dict(
                "objectId" => _scene_graph_json_value(object_id.value),
                "modelType" => string(typeof(override)),
                "parameters" => _scene_graph_model_parameters(override),
            )
            for (object_id, override) in application.model_overrides
        ],
    )
end

function _scene_graph_object_dict(row)
    id = row.id
    return Dict{String,Any}(
        "id" => _scene_graph_object_node_id(id),
        "objectId" => _scene_graph_json_value(id),
        "scale" => _scene_graph_json_value(row.scale),
        "kind" => _scene_graph_json_value(row.kind),
        "species" => _scene_graph_json_value(row.species),
        "name" => _scene_graph_json_value(row.name),
        "instance" => _scene_graph_json_value(row.instance),
        "parent" => isnothing(row.parent) ? nothing : _scene_graph_object_node_id(row.parent),
        "children" => [_scene_graph_object_node_id(child) for child in row.children],
        "hasGeometry" => row.has_geometry,
        "hasStatus" => row.has_status,
    )
end

function _scene_graph_instance_dict(row)
    return Dict{String,Any}(
        "id" => _scene_graph_instance_node_id(row.name),
        "name" => string(row.name),
        "rootId" => _scene_graph_json_value(row.root_id),
        "kind" => _scene_graph_json_value(row.kind),
        "species" => _scene_graph_json_value(row.species),
        "objectIds" => [_scene_graph_json_value(id) for id in row.object_ids],
        "applicationIds" => string.(row.application_ids),
        "instanceOverrides" => string.(row.instance_overrides),
        "objectOverrides" => _scene_graph_json_value(row.object_overrides),
        "parametersType" => string(row.parameters_type),
    )
end

function _scene_graph_execution_dict(application, object_id)
    model = _application_model(application, object_id)
    return Dict{String,Any}(
        "id" => _scene_graph_execution_node_id(application.id, object_id),
        "applicationId" => string(application.id),
        "applicationNodeId" => _scene_graph_application_node_id(application.id),
        "objectId" => _scene_graph_json_value(object_id.value),
        "objectNodeId" => _scene_graph_object_node_id(object_id),
        "modelType" => string(typeof(model)),
        "modelParameters" => _scene_graph_model_parameters(model),
        "overridden" => typeof(model) != typeof(_application_default_model(application)) || model != _application_default_model(application),
    )
end

function _scene_graph_application_for_object(applications_by_id, application_id, object_id)
    application = get(applications_by_id, application_id, nothing)
    isnothing(application) && return false
    return object_id in application.target_ids
end

function _scene_graph_binding_edges(report, level)
    edges = Dict{String,Dict{String,Any}}()
    applications_by_id = Dict(application.id => application for application in report.applications)
    cycle_memberships = Dict{Symbol,Int}()
    for (index, component) in pairs(report.cycles)
        for application_id in component
            cycle_memberships[application_id] = index
        end
    end

    for binding in report.input_bindings
        previous = binding.policy isa PreviousTimeStep
        for source_application_id in binding.source_application_ids
            source_ids = ObjectId[
                source_id for source_id in binding.source_ids
                if _scene_graph_application_for_object(
                    applications_by_id,
                    source_application_id,
                    source_id,
                )
            ]
            isempty(source_ids) && (source_ids = copy(binding.source_ids))
            if level == :resolved
                for source_id in source_ids
                    edge_id = string(
                        "binding:", source_application_id, ":", source_id.value,
                        ":", binding.source_var, ":", binding.application_id,
                        ":", binding.consumer_id.value, ":", binding.input,
                    )
                    edges[edge_id] = Dict{String,Any}(
                        "id" => edge_id,
                        "source" => _scene_graph_execution_node_id(source_application_id, source_id),
                        "target" => _scene_graph_execution_node_id(binding.application_id, binding.consumer_id),
                        "sourcePort" => _scene_graph_port_id(source_application_id, :output, binding.source_var),
                        "targetPort" => _scene_graph_port_id(binding.application_id, :input, binding.input),
                        "sourceVariable" => string(binding.source_var),
                        "targetVariable" => string(binding.input),
                        "sourceApplicationId" => string(source_application_id),
                        "targetApplicationId" => string(binding.application_id),
                        "sourceObjectIds" => [_scene_graph_json_value(source_id.value)],
                        "targetObjectIds" => [_scene_graph_json_value(binding.consumer_id.value)],
                        "kind" => previous ? "previous_timestep" : string(binding.origin == :inferred ? :inferred_same_object : :value_binding),
                        "projection" => "resolved",
                        "origin" => string(binding.origin),
                        "multiplicity" => string(binding.multiplicity),
                        "policy" => string(typeof(binding.policy)),
                        "selector" => _scene_graph_selector_dict(binding.selector),
                        "cycle" => !previous && get(cycle_memberships, source_application_id, 0) == get(cycle_memberships, binding.application_id, -1),
                    )
                end
            else
                edge_id = string(
                    "binding:", source_application_id, ":", binding.source_var,
                    ":", binding.application_id, ":", binding.input,
                )
                edge = get!(edges, edge_id) do
                    Dict{String,Any}(
                        "id" => edge_id,
                        "source" => _scene_graph_application_node_id(source_application_id),
                        "target" => _scene_graph_application_node_id(binding.application_id),
                        "sourcePort" => _scene_graph_port_id(source_application_id, :output, binding.source_var),
                        "targetPort" => _scene_graph_port_id(binding.application_id, :input, binding.input),
                        "sourceVariable" => string(binding.source_var),
                        "targetVariable" => string(binding.input),
                        "sourceApplicationId" => string(source_application_id),
                        "targetApplicationId" => string(binding.application_id),
                        "sourceObjectIds" => Any[],
                        "targetObjectIds" => Any[],
                        "kind" => previous ? "previous_timestep" : string(binding.origin == :inferred ? :inferred_same_object : :value_binding),
                        "projection" => "applications",
                        "origin" => string(binding.origin),
                        "multiplicity" => string(binding.multiplicity),
                        "policy" => string(typeof(binding.policy)),
                        "selector" => _scene_graph_selector_dict(binding.selector),
                        "cycle" => !previous && get(cycle_memberships, source_application_id, 0) == get(cycle_memberships, binding.application_id, -1),
                    )
                end
                append!(edge["sourceObjectIds"], [_scene_graph_json_value(id.value) for id in source_ids])
                push!(edge["targetObjectIds"], _scene_graph_json_value(binding.consumer_id.value))
                unique!(edge["sourceObjectIds"])
                unique!(edge["targetObjectIds"])
            end
        end
    end
    return collect(values(edges))
end

function _scene_graph_call_edges(report, level)
    edges = Dict{String,Dict{String,Any}}()
    for binding in report.call_bindings
        for callee_application_id in binding.callee_application_ids
            if level == :resolved
                for callee_object_id in binding.callee_object_ids
                    edge_id = string(
                        "call:", binding.application_id, ":", binding.consumer_id.value,
                        ":", binding.call, ":", callee_application_id, ":", callee_object_id.value,
                    )
                    edges[edge_id] = Dict{String,Any}(
                        "id" => edge_id,
                        "source" => _scene_graph_execution_node_id(binding.application_id, binding.consumer_id),
                        "target" => _scene_graph_execution_node_id(callee_application_id, callee_object_id),
                        "sourcePort" => nothing,
                        "targetPort" => nothing,
                        "kind" => "manual_call",
                        "projection" => "resolved",
                        "call" => string(binding.call),
                        "origin" => string(binding.origin),
                        "multiplicity" => string(binding.multiplicity),
                        "selector" => _scene_graph_selector_dict(binding.selector),
                        "cycle" => false,
                    )
                end
            else
                edge_id = string("call:", binding.application_id, ":", binding.call, ":", callee_application_id)
                edges[edge_id] = Dict{String,Any}(
                    "id" => edge_id,
                    "source" => _scene_graph_application_node_id(binding.application_id),
                    "target" => _scene_graph_application_node_id(callee_application_id),
                    "sourcePort" => nothing,
                    "targetPort" => nothing,
                    "kind" => "manual_call",
                    "projection" => "applications",
                    "call" => string(binding.call),
                    "origin" => string(binding.origin),
                    "multiplicity" => string(binding.multiplicity),
                    "selector" => _scene_graph_selector_dict(binding.selector),
                    "cycle" => false,
                )
            end
        end
    end
    return collect(values(edges))
end

function _scene_graph_update_edges(report)
    application_ids = Set(application.id for application in report.applications)
    edges = Dict{String,Any}[]
    for application in report.applications
        for update in updates(application.spec)
            variables = _update_variables(update)
            for predecessor in _update_after(update)
                predecessor in application_ids || continue
                edge_id = string(
                    "update:", predecessor, ":", application.id, ":",
                    join(string.(variables), ","),
                )
                push!(edges, Dict{String,Any}(
                    "id" => edge_id,
                    "source" => _scene_graph_application_node_id(predecessor),
                    "target" => _scene_graph_application_node_id(application.id),
                    "sourceApplicationId" => string(predecessor),
                    "targetApplicationId" => string(application.id),
                    "variables" => collect(string.(variables)),
                    "kind" => "update_order",
                    "projection" => "applications",
                    "cycle" => false,
                ))
            end
        end
    end
    return edges
end

function _scene_graph_environment_edges(report, level)
    environment_bindings = try
        _compile_environment_bindings_for_applications(report.scene, report.applications)
    catch
        Any[]
    end
    if isempty(environment_bindings)
        for application in report.applications
            required_inputs = Symbol.(keys(meteo_inputs_(application.spec)))
            produced_outputs = Symbol.(keys(meteo_outputs_(application.spec)))
            isempty(required_inputs) && isempty(produced_outputs) && continue
            source_inputs = _environment_source_variable_names(application.spec)
            config = environment_config(application.spec)
            provider = try
                _environment_provider_from_config(
                    config,
                    _environment_backend_from_config(report.scene, config),
                )
            catch
                :scene
            end
            for object_id in application.target_ids
                push!(environment_bindings, (
                    application_id=application.id,
                    object_id=object_id,
                    provider=provider,
                    required_inputs=required_inputs,
                    source_inputs=source_inputs,
                    produced_outputs=produced_outputs,
                ))
            end
        end
    end
    edges = Dict{String,Dict{String,Any}}()
    for binding in environment_bindings
        provider_id = string("environment:", binding.provider)
        target_id = level == :resolved ?
                    _scene_graph_execution_node_id(binding.application_id, binding.object_id) :
                    _scene_graph_application_node_id(binding.application_id)
        object_suffix = level == :resolved ? string(":", binding.object_id.value) : ""
        for (target_variable, source_variable) in zip(binding.required_inputs, binding.source_inputs)
            edge_id = string(
                "environment-input:", binding.provider, ":", source_variable, ":",
                binding.application_id, ":", target_variable, object_suffix,
            )
            edge = get!(edges, edge_id) do
                Dict{String,Any}(
                    "id" => edge_id,
                    "source" => provider_id,
                    "target" => target_id,
                    "sourcePort" => string(provider_id, ":output:", source_variable),
                    "targetPort" => _scene_graph_port_id(
                        binding.application_id,
                        :environment_input,
                        target_variable,
                    ),
                    "sourceVariable" => string(source_variable),
                    "targetVariable" => string(target_variable),
                    "targetApplicationId" => string(binding.application_id),
                    "sourceObjectIds" => Any[],
                    "targetObjectIds" => Any[],
                    "provider" => string(binding.provider),
                    "kind" => "environment_binding",
                    "projection" => string(level),
                    "cycle" => false,
                )
            end
            push!(edge["targetObjectIds"], _scene_graph_json_value(binding.object_id.value))
            unique!(edge["targetObjectIds"])
        end
        for variable in binding.produced_outputs
            edge_id = string(
                "environment-output:", binding.application_id, ":", variable, ":",
                binding.provider, object_suffix,
            )
            edge = get!(edges, edge_id) do
                Dict{String,Any}(
                    "id" => edge_id,
                    "source" => target_id,
                    "target" => provider_id,
                    "sourcePort" => _scene_graph_port_id(
                        binding.application_id,
                        :environment_output,
                        variable,
                    ),
                    "targetPort" => string(provider_id, ":input:", variable),
                    "sourceVariable" => string(variable),
                    "targetVariable" => string(variable),
                    "sourceApplicationId" => string(binding.application_id),
                    "sourceObjectIds" => Any[],
                    "targetObjectIds" => Any[],
                    "provider" => string(binding.provider),
                    "kind" => "environment_binding",
                    "projection" => string(level),
                    "cycle" => false,
                )
            end
            push!(edge["sourceObjectIds"], _scene_graph_json_value(binding.object_id.value))
            unique!(edge["sourceObjectIds"])
        end
    end
    return collect(values(edges))
end

function _scene_graph_structure_edges(scene, applications)
    edges = Dict{String,Any}[]
    for object in values(scene.registry.objects)
        if !isnothing(object.parent)
            push!(edges, Dict{String,Any}(
                "id" => string("topology:", object.parent.value, ":", object.id.value),
                "source" => _scene_graph_object_node_id(object.parent),
                "target" => _scene_graph_object_node_id(object.id),
                "kind" => "object_topology",
                "projection" => "topology",
                "cycle" => false,
            ))
        end
    end
    for application in applications
        for object_id in application.target_ids
            push!(edges, Dict{String,Any}(
                "id" => string("target:", application.id, ":", object_id.value),
                "source" => _scene_graph_application_node_id(application.id),
                "target" => _scene_graph_object_node_id(object_id),
                "kind" => "application_target",
                "projection" => "targets",
                "cycle" => false,
            ))
        end
    end
    return edges
end

function _scene_graph_diagnostic_dict(diagnostic::SceneGraphDiagnostic)
    return Dict{String,Any}(
        "code" => string(diagnostic.code),
        "severity" => string(diagnostic.severity),
        "message" => diagnostic.message,
        "phase" => string(diagnostic.phase),
        "applicationIds" => string.(diagnostic.application_ids),
        "objectIds" => _scene_graph_json_value(diagnostic.object_ids),
        "variable" => isnothing(diagnostic.variable) ? nothing : string(diagnostic.variable),
        "suggestions" => diagnostic.suggestions,
    )
end

function _scene_graph_initialization(report)
    supplied = report.initial_status_variables
    bindings = Dict(
        (binding.application_id, binding.consumer_id, binding.input) => binding
        for binding in report.input_bindings
    )
    environment_variables_ = try
        environment_variables(environment_backend(report.scene.environment))
    catch
        Set{Symbol}()
    end
    isnothing(environment_variables_) && (environment_variables_ = nothing)

    rows = Dict{String,Any}[]
    for application in report.applications
        model_inputs = inputs_(application.spec)
        model_outputs = outputs_(application.spec)
        model_environment_inputs = meteo_inputs_(application.spec)
        model_environment_outputs = meteo_outputs_(application.spec)
        source_overrides = _environment_source_overrides(application.spec)
        for object_id in application.target_ids
            object = _scene_object(report.scene, object_id)
            for (variable, default) in pairs(model_outputs)
                push!(rows, _scene_graph_initialization_row(
                    application.id,
                    object_id,
                    variable,
                    :output,
                    :generated,
                    default,
                ))
            end
            for (variable, default) in pairs(model_environment_outputs)
                push!(rows, _scene_graph_initialization_row(
                    application.id,
                    object_id,
                    variable,
                    :environment_output,
                    :generated,
                    default,
                ))
            end
            for (variable_, default) in pairs(model_inputs)
                variable = Symbol(variable_)
                binding = get(bindings, (application.id, object_id, variable), nothing)
                status_supplied = variable in get(supplied, object_id, Set{Symbol}())
                disposition = if !isnothing(binding) && binding.policy isa PreviousTimeStep
                    status_supplied ? :supplied : :unresolved
                elseif !isnothing(binding)
                    :producer_bound
                elseif status_supplied
                    :supplied
                else
                    :unresolved
                end
                value = disposition == :supplied ? object.status[variable] : default
                row = _scene_graph_initialization_row(
                    application.id,
                    object_id,
                    variable,
                    :input,
                    disposition,
                    value;
                    binding=binding,
                )
                push!(rows, row)
            end
            for (variable_, default) in pairs(model_environment_inputs)
                variable = Symbol(variable_)
                source = Symbol(get(source_overrides, variable, variable))
                bound = isnothing(environment_variables_) || source in environment_variables_
                row = _scene_graph_initialization_row(
                    application.id,
                    object_id,
                    variable,
                    :environment_input,
                    bound ? :environment_bound : :unresolved,
                    default,
                )
                row["sourceVariable"] = string(source)
                push!(rows, row)
            end
        end
    end
    sort!(rows; by=row -> (
        row["applicationId"],
        string(row["objectId"]),
        row["role"],
        row["variable"],
    ))
    return rows
end

function _scene_graph_initialization_row(
    application_id,
    object_id,
    variable,
    role,
    disposition,
    value;
    binding=nothing,
)
    return Dict{String,Any}(
        "applicationId" => string(application_id),
        "objectId" => _scene_graph_json_value(object_id.value),
        "variable" => string(variable),
        "role" => string(role),
        "disposition" => string(disposition),
        "value" => _scene_graph_json_value(value),
        "valueJulia" => repr(value),
        "expectedType" => string(typeof(value)),
        "sourceApplicationIds" => isnothing(binding) ? String[] : string.(binding.source_application_ids),
        "sourceObjectIds" => isnothing(binding) ? Any[] : [_scene_graph_json_value(id.value) for id in binding.source_ids],
        "sourceVariable" => isnothing(binding) ? nothing : string(binding.source_var),
        "origin" => isnothing(binding) ? string(disposition == :supplied ? :status : :missing) : string(binding.origin),
        "previousTimeStep" => !isnothing(binding) && binding.policy isa PreviousTimeStep,
    )
end

function _scene_graph_cycle_dict(report, component, index)
    members = Set(component)
    dependency_edges = Dict{String,Any}[]
    for source in component
        for target in get(report.dependency_children, source, Set{Symbol}())
            target in members || continue
            push!(dependency_edges, Dict{String,Any}(
                "sourceApplicationId" => string(source),
                "targetApplicationId" => string(target),
            ))
        end
    end
    break_candidates = Dict{String,Any}[]
    for binding in report.input_bindings
        binding.policy isa PreviousTimeStep && continue
        binding.application_id in members || continue
        any(source -> source in members, binding.source_application_ids) || continue
        push!(break_candidates, Dict{String,Any}(
            "applicationId" => string(binding.application_id),
            "objectId" => _scene_graph_json_value(binding.consumer_id.value),
            "input" => string(binding.input),
            "sourceApplicationIds" => string.(binding.source_application_ids),
            "sourceObjectIds" => [_scene_graph_json_value(id.value) for id in binding.source_ids],
            "sourceVariable" => string(binding.source_var),
            "selector" => _scene_graph_selector_dict(binding.selector),
        ))
    end
    return Dict{String,Any}(
        "id" => string("cycle:", index),
        "applicationIds" => string.(component),
        "edges" => dependency_edges,
        "breakCandidates" => break_candidates,
    )
end

function _scene_graph_model_library()
    return [model_descriptor(type) for type in available_models()]
end

function _normalize_scene_graph_level(level)
    normalized = Symbol(level)
    normalized in (:applications, :topology, :resolved) || error(
        "Unsupported scene graph level `$(level)`. Use `:applications`, `:topology`, or `:resolved`.",
    )
    return normalized
end

"""
    compile_scene_graph(scene; level=:applications, strict=false)
    compile_scene_graph(compiled::CompiledScene; level=:applications)

Build a renderer-independent graph view from a Scene or an existing compiled
scene.
"""
function compile_scene_graph(scene::Scene; level=:applications, strict::Bool=false)
    return _scene_graph_view(compile_scene_report(scene; strict=strict), level)
end

function compile_scene_graph(compiled::CompiledScene; level=:applications)
    children = _scene_graph_dependency_children(
        compiled.applications,
        compiled.input_bindings,
        compiled.call_bindings,
    )
    report = SceneCompilationReport(
        compiled.scene,
        Dict(
            object.id => Set{Symbol}(
                object.status isa Status ? Symbol.(propertynames(object.status)) : Symbol[],
            )
            for object in values(compiled.scene.registry.objects)
        ),
        compiled.applications,
        compiled.input_bindings,
        compiled.call_bindings,
        Symbol[compiled.application_order...],
        children,
        _scene_graph_cycle_components(compiled.applications, children),
        SceneGraphDiagnostic[],
        compiled,
    )
    return _scene_graph_view(report, level)
end

function _scene_graph_view(report::SceneCompilationReport, level)
    level = _normalize_scene_graph_level(level)
    objects = [_scene_graph_object_dict(row) for row in explain_objects(report.scene)]
    instances = [_scene_graph_instance_dict(row) for row in explain_instances(report.scene)]
    applications = [_scene_graph_application_dict(report.scene, application) for application in report.applications]
    executions = [
        _scene_graph_execution_dict(application, object_id)
        for application in report.applications
        for object_id in application.target_ids
    ]
    edges = vcat(
        _scene_graph_binding_edges(report, :applications),
        _scene_graph_binding_edges(report, :resolved),
        _scene_graph_call_edges(report, :applications),
        _scene_graph_call_edges(report, :resolved),
        _scene_graph_update_edges(report),
        _scene_graph_environment_edges(report, :applications),
        _scene_graph_environment_edges(report, :resolved),
        _scene_graph_structure_edges(report.scene, report.applications),
    )
    sort!(edges; by=edge -> edge["id"])
    initialization = _scene_graph_initialization(report)
    diagnostics = [_scene_graph_diagnostic_dict(diagnostic) for diagnostic in report.diagnostics]
    cycles = [
        _scene_graph_cycle_dict(report, component, index)
        for (index, component) in pairs(report.cycles)
    ]
    unresolved = count(row -> row["disposition"] == "unresolved", initialization)
    metadata = Dict{String,Any}(
        "title" => "PlantSimEngine Scene Graph",
        "sceneRevision" => report.scene.revision,
        "objectCount" => length(objects),
        "instanceCount" => length(instances),
        "applicationCount" => length(applications),
        "executionCount" => sum(application["targetCount"] for application in applications; init=0),
        "bindingCount" => length(report.input_bindings),
        "callCount" => length(report.call_bindings),
        "unresolvedInitializationCount" => unresolved,
        "cyclic" => !isempty(cycles),
        "strictlyCompiled" => !isnothing(report.compiled),
    )
    return SceneGraphView(
        level,
        metadata,
        objects,
        instances,
        applications,
        executions,
        edges,
        _scene_graph_model_library(),
        initialization,
        diagnostics,
        cycles,
        [
            "inspect",
            "filter",
            "expand_executions",
            "add_application",
            "connect_binding",
            "break_cycle",
        ],
    )
end

scene_graph_view(scene_or_compiled; kwargs...) = compile_scene_graph(scene_or_compiled; kwargs...)

function _scene_graph_view_dict(view::SceneGraphView)
    return Dict{String,Any}(
        "schemaVersion" => 1,
        "level" => string(view.level),
        "metadata" => view.metadata,
        "objects" => view.objects,
        "instances" => view.instances,
        "applications" => view.applications,
        "executions" => view.executions,
        "edges" => view.edges,
        "modelLibrary" => view.model_library,
        "initialization" => view.initialization,
        "diagnostics" => view.diagnostics,
        "cycles" => view.cycles,
        "availableActions" => view.available_actions,
    )
end

scene_graph_view_json(view::SceneGraphView) =
    replace(JSON.json(_scene_graph_view_dict(view)), "</" => "<\\/")

scene_graph_view_json(scene_or_compiled; kwargs...) =
    scene_graph_view_json(scene_graph_view(scene_or_compiled; kwargs...))

function _scene_graph_assets_dir()
    return normpath(joinpath(dirname(dirname(dirname(@__FILE__))), "frontend", "dist"))
end

function _scene_graph_vite_entry(assets_dir)
    manifest_path = joinpath(assets_dir, ".vite", "manifest.json")
    isfile(manifest_path) || return nothing
    manifest = JSON.parse(read(manifest_path, String))
    for entry in values(manifest)
        get(entry, "isEntry", false) == true && return entry
    end
    return get(manifest, "index.html", nothing)
end

function _scene_graph_react_html(view::SceneGraphView)
    assets_dir = _scene_graph_assets_dir()
    entry = _scene_graph_vite_entry(assets_dir)
    isnothing(entry) && return nothing
    js_file = get(entry, "file", nothing)
    isnothing(js_file) && return nothing
    css_files = get(entry, "css", Any[])
    js = read(joinpath(assets_dir, js_file), String)
    css = join([read(joinpath(assets_dir, css_file), String) for css_file in css_files], "\n")
    return _scene_graph_html_document(view, css, js)
end

function _scene_graph_html_document(view, css, js)
    json = scene_graph_view_json(view)
    html = raw"""
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>PlantSimEngine Scene Graph</title>
<script type="application/json" id="pse-scene-graph-data">__PSE_SCENE_GRAPH_JSON__</script>
<style>__PSE_SCENE_GRAPH_CSS__</style>
</head>
<body>
<div id="root"></div>
<script type="module">__PSE_SCENE_GRAPH_JS__</script>
</body>
</html>
"""
    return replace(
        html,
        "__PSE_SCENE_GRAPH_JSON__" => json,
        "__PSE_SCENE_GRAPH_CSS__" => css,
        "__PSE_SCENE_GRAPH_JS__" => js,
    )
end

function _scene_graph_standalone_html(view::SceneGraphView)
    css = raw"""
:root{font-family:Inter,ui-sans-serif,system-ui,sans-serif;color:#2d2722;background:#f4efe6}*{box-sizing:border-box}body{margin:0}.shell{height:100vh;display:grid;grid-template-rows:auto 1fr}.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:14px 18px;background:#fffaf2;border-bottom:1px solid #dccfbd}.brand{font-weight:800;font-size:19px;margin-right:auto}.toolbar button,.toolbar input{border:1px solid #cdbfaa;background:#fffaf2;border-radius:6px;padding:8px 10px;color:inherit}.toolbar button.active{border-color:#1f7a5a;color:#155b43;background:#e9f4ed}.content{display:grid;grid-template-columns:1fr 300px;min-height:0}.canvas{position:relative;overflow:auto;padding:24px}.grid{position:relative;display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:18px;z-index:2}.card{position:relative;background:#fffaf2;border:1px solid #ddcfbc;border-radius:7px;box-shadow:0 5px 18px #4a3e3020;padding:14px;min-height:150px;cursor:pointer}.card.cycle{border:2px solid #c94c3d}.card h3{margin:0 0 3px;font-size:16px}.muted{color:#776d64;font-size:12px}.badges{display:flex;gap:5px;flex-wrap:wrap;margin:10px 0}.badge{border:1px solid #d6c8b5;border-radius:999px;padding:2px 7px;font-size:11px}.ports{display:grid;grid-template-columns:1fr 1fr;gap:12px}.ports strong{font-size:10px;color:#776d64;text-transform:uppercase}.port{font-family:ui-monospace,monospace;font-size:11px;padding:3px 0}.inspector{overflow:auto;border-left:1px solid #dccfbd;background:#fffaf2;padding:18px}.inspector pre{white-space:pre-wrap;font-size:11px}.diagnostic{border-left:3px solid #c94c3d;padding:8px;margin:8px 0;background:#fff1eb}.empty{padding:60px;text-align:center;color:#776d64}@media(max-width:760px){.content{grid-template-columns:1fr}.inspector{display:none}.toolbar input{width:100%}}
"""
    js = raw"""
const data=JSON.parse(document.getElementById('pse-scene-graph-data').textContent);const root=document.getElementById('root');let mode=data.level||'applications';let query='';let selected=null;const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function cards(){if(mode==='topology')return data.objects.map(o=>({...o,title:o.name||String(o.objectId),subtitle:[o.kind,o.scale,o.instance].filter(Boolean).join(' · '),inputs:[],outputs:[]}));if(mode==='resolved')return data.executions.map(e=>({...e,title:e.applicationId+' @ '+e.objectId,subtitle:e.modelType,inputs:[],outputs:[]}));return data.applications.map(a=>({...a,title:a.name||a.applicationId,subtitle:a.modelType}));}function render(){const items=cards().filter(item=>JSON.stringify(item).toLowerCase().includes(query.toLowerCase()));root.innerHTML=`<div class="shell"><div class="toolbar"><div class="brand">PlantSimEngine Scene Graph</div><button data-mode="applications" class="${mode==='applications'?'active':''}">Applications</button><button data-mode="topology" class="${mode==='topology'?'active':''}">Objects</button><button data-mode="resolved" class="${mode==='resolved'?'active':''}">Executions</button><input id="search" placeholder="Search model, object, or variable" value="${esc(query)}"></div><div class="content"><main class="canvas">${items.length?`<div class="grid">${items.map(item=>{const appId=item.applicationId;const cyclic=data.cycles.some(c=>c.applicationIds.includes(appId));return `<article class="card ${cyclic?'cycle':''}" data-id="${esc(item.id)}"><h3>${esc(item.title)}</h3><div class="muted">${esc(item.subtitle)}</div>${item.targetCount!==undefined?`<div class="badges"><span class="badge">${item.targetCount} targets</span>${(item.targetScales||[]).map(v=>`<span class="badge">${esc(v)}</span>`).join('')}</div><div class="ports"><div><strong>Inputs</strong>${(item.inputs||[]).map(p=>`<div class="port">${esc(p.name)}</div>`).join('')}</div><div><strong>Outputs</strong>${(item.outputs||[]).map(p=>`<div class="port">${esc(p.name)}</div>`).join('')}</div></div>`:''}</article>`}).join('')}</div>`:'<div class="empty">No matching graph items.</div>'}</main><aside class="inspector"><h3>Inspector</h3>${selected?`<pre>${esc(JSON.stringify(selected,null,2))}</pre>`:'<p class="muted">Select an application or object.</p>'}<h3>Diagnostics</h3>${data.diagnostics.map(d=>`<div class="diagnostic"><strong>${esc(d.code)}</strong><div>${esc(d.message)}</div></div>`).join('')||'<p class="muted">No diagnostics.</p>'}</aside></div></div>`;root.querySelectorAll('[data-mode]').forEach(button=>button.onclick=()=>{mode=button.dataset.mode;selected=null;render()});root.querySelector('#search').oninput=event=>{query=event.target.value;render()};root.querySelectorAll('.card').forEach(card=>card.onclick=()=>{selected=cards().find(item=>item.id===card.dataset.id);render()});}render();
"""
    return _scene_graph_html_document(view, css, js)
end

function scene_graph_view_html(view::SceneGraphView; renderer::Symbol=:react)
    renderer == :standalone && return _scene_graph_standalone_html(view)
    renderer == :react || error("Unsupported renderer `$(renderer)`. Use `:react` or `:standalone`.")
    html = _scene_graph_react_html(view)
    return isnothing(html) ? _scene_graph_standalone_html(view) : html
end

scene_graph_view_html(scene_or_compiled; kwargs...) =
    scene_graph_view_html(scene_graph_view(scene_or_compiled); kwargs...)

"""
    write_scene_graph_view(path, scene_or_view; level=:applications,
                           strict=false, renderer=:react)

Write a self-contained static Scene graph viewer. The default renderer uses
the bundled frontend when available and otherwise falls back to the standalone
viewer.
"""
function write_scene_graph_view(
    path::AbstractString,
    scene_or_view;
    level=:applications,
    strict::Bool=false,
    renderer::Symbol=:react,
)
    view = scene_or_view isa SceneGraphView ?
           scene_or_view :
           scene_graph_view(scene_or_view; level=level, strict=strict)
    full_path = abspath(path)
    mkpath(dirname(full_path))
    write(full_path, scene_graph_view_html(view; renderer=renderer))
    return full_path
end
