module PlantSimEngineGraphEditorExt

import HTTP
import JSON
import Dates
import PlantSimEngine
import PlantSimEngine.GraphEditor: edit_graph, current_model, apply_edit!, undo!, redo!

mutable struct GraphEditorSession <: PlantSimEngine.GraphEditor.AbstractModelGraphEditorSession
    model::PlantSimEngine.CompositeModel
    templates::Dict{Symbol,Any}
    environments::Dict{Symbol,Any}
    history::Vector{Any}
    future::Vector{Any}
    server::Any
    host::String
    port::Int
    token::String
    url::String
    autosave_path::Union{Nothing,String}
    save_path::Union{Nothing,String}
    allow_julia_eval::Bool
    recent_paths::Vector{String}
end

current_model(session::GraphEditorSession) = session.model

function _normalize_named_catalog(catalog, label)
    entries = if catalog isa NamedTuple
        collect(pairs(catalog))
    elseif catalog isa AbstractDict
        collect(pairs(catalog))
    else
        error("$(label) catalog must be a NamedTuple or dictionary.")
    end
    normalized = Dict{Symbol,Any}()
    for (name_, value) in entries
        name_ isa Symbol || error("$(label) catalog names must be symbols, got `$(repr(name_))`.")
        name = name_
        Base.isidentifier(String(name)) || error(
            "$(label) catalog name `$(name)` must be a valid Julia identifier.",
        )
        haskey(normalized, name) && error("$(label) catalog contains duplicate name `$(name)`.")
        normalized[name] = value
    end
    return normalized
end

function _normalize_template_catalog(catalog)
    normalized = _normalize_named_catalog(catalog, "Template")
    for (name, template) in normalized
        template isa PlantSimEngine.CompositeModelTemplate || error(
            "Template catalog entry `$(name)` must be a CompositeModelTemplate.",
        )
    end
    return normalized
end

_normalize_environment_catalog(catalog) = _normalize_named_catalog(catalog, "Environment")

function Base.close(session::GraphEditorSession)
    try
        isopen(session.server) && close(session.server)
    catch
        close(session.server)
    end
    return nothing
end

function Base.show(io::IO, session::GraphEditorSession)
    print(io, "GraphEditorSession(url=$(repr(session.url)), applications=$(length(session.model.applications)))")
end

function Base.show(io::IO, ::MIME"text/plain", session::GraphEditorSession)
    println(io, "PlantSimEngineGraphEditorExt.GraphEditorSession")
    println(io, "  Open in browser: $(session.url)")
    println(io, "  State JSON: $(_state_url(session))")
    println(io, "  Current model: GraphEditor.current_model(session)")
    println(io, "  Quit session: close(session)")
    isnothing(session.autosave_path) || println(io, "  Recovery autosave: $(session.autosave_path)")
    isnothing(session.save_path) || println(io, "  Saving changes to: $(session.save_path)")
end

"""
    edit_graph([model]; templates=NamedTuple(), environments=NamedTuple(),
               host="127.0.0.1", port=0, open_browser=true,
               autosave=true, allow_remote=false, allow_julia_eval=nothing)

Start a local Model graph editor. Julia owns the current Composite model and applies all
semantic edits received from the browser. Call `edit_graph()` to start from an
empty Composite model and `close(session)` to stop the server. `templates` is a
named catalog of `CompositeModelTemplate` presets. `environments` is a named
catalog of server-side environment values; these values are referenced by name
and are never serialized to the browser.
"""
function edit_graph(
    model::PlantSimEngine.CompositeModel=PlantSimEngine.CompositeModel();
    host::AbstractString="127.0.0.1",
    port::Integer=0,
    open_browser::Bool=true,
    autosave::Bool=true,
    autosave_path::Union{Nothing,AbstractString}=nothing,
    save_path::Union{Nothing,AbstractString}=nothing,
    allow_remote::Bool=false,
    allow_julia_eval::Union{Nothing,Bool}=nothing,
    recover_path::Union{Nothing,AbstractString}=nothing,
    recent_paths=nothing,
    templates=NamedTuple(),
    environments=NamedTuple(),
)
    _is_loopback_host(host) || allow_remote || error(
        "Graph editor sessions are limited to localhost by default. Pass `allow_remote=true` only for a trusted network.",
    )
    effective_allow_julia_eval = isnothing(allow_julia_eval) ? !allow_remote : allow_julia_eval
    template_catalog = _normalize_template_catalog(templates)
    environment_catalog = _normalize_environment_catalog(environments)
    catalog_values = (
        values(template_catalog)...,
        values(environment_catalog)...,
    )
    initial_model = isnothing(recover_path) ? PlantSimEngine._model_graph_deepcopy(
        model,
        catalog_values,
    ) : _load_model_file(
        _normalized_path(recover_path);
        allow_julia_eval=effective_allow_julia_eval,
        environments=environment_catalog,
    )
    session_ref = Ref{Any}()
    handler = stream -> _handle_http(session_ref[], stream)
    server = HTTP.listen!(handler, host, port; listenany=true, verbose=false)
    actual_port = HTTP.port(server)
    token = _session_token()
    autosave_file = autosave ? _normalized_path(
        isnothing(autosave_path) ? _default_autosave_path() : autosave_path,
    ) : nothing
    remembered_paths = isnothing(recent_paths) ? _load_recent_paths() : String.(recent_paths)
    session = GraphEditorSession(
        initial_model,
        template_catalog,
        environment_catalog,
        Any[],
        Any[],
        server,
        String(host),
        actual_port,
        token,
        "http://$(host):$(actual_port)/?token=$(token)",
        autosave_file,
        isnothing(save_path) ? nothing : _normalized_path(save_path),
        effective_allow_julia_eval,
        String[_normalized_path(path) for path in remembered_paths],
    )
    session_ref[] = session
    isnothing(session.save_path) || _remember_path!(session, session.save_path)
    isnothing(recover_path) || _remember_path!(session, _normalized_path(recover_path))
    _persist_model!(session)
    open_browser && _open_in_default_browser(session.url)
    return session
end

function apply_edit!(session::GraphEditorSession, edit::PlantSimEngine.GraphEditor.AbstractModelGraphEdit)
    candidate = PlantSimEngine.GraphEditor.apply_model_graph_edit(
        session.model,
        edit;
        preserve=(values(session.templates)..., values(session.environments)...),
    )
    if edit isa Union{
        PlantSimEngine.GraphEditor.SetCompositeModelEnvironment,
        PlantSimEngine.GraphEditor.SetModelApplicationEnvironment,
    }
        report = PlantSimEngine.GraphEditor.compile_model_report(candidate)
        _, environment_plans_by_id =
            PlantSimEngine._compile_environment_application_plans(
                candidate,
                report.applications;
                prepare_runtime=false,
            )
        bindings = PlantSimEngine._compile_environment_bindings_for_applications(
            candidate,
            report.applications,
            environment_plans_by_id,
        )
        PlantSimEngine._validate_model_environment_inputs!(
            bindings,
            Dict(application.id => application for application in report.applications),
        )
    end
    push!(session.history, session.model)
    empty!(session.future)
    session.model = candidate
    _persist_model!(session)
    return session.model
end

function undo!(session::GraphEditorSession)
    isempty(session.history) && return session.model
    push!(session.future, session.model)
    session.model = pop!(session.history)
    _persist_model!(session)
    return session.model
end

function redo!(session::GraphEditorSession)
    isempty(session.future) && return session.model
    push!(session.history, session.model)
    session.model = pop!(session.future)
    _persist_model!(session)
    return session.model
end

_session_token() = PlantSimEngine._graph_editor_session_token()

function _is_loopback_host(host)
    return lowercase(strip(String(host))) in (
        "127.0.0.1",
        "localhost",
        "::1",
        "[::1]",
        "0:0:0:0:0:0:0:1",
    )
end

_base_url(session) = "http://$(session.host):$(session.port)"
_state_url(session) = "$(_base_url(session))/state?token=$(session.token)"
_websocket_url(session) = "ws://$(session.host):$(session.port)/ws?token=$(session.token)"

function _handle_http(session::GraphEditorSession, stream::HTTP.Stream)
    request = stream.message
    path = HTTP.URI(request.target).path

    if HTTP.WebSockets.isupgrade(request)
        _authorized_request(session, request) || return _write_response(stream, 403, "text/plain", "Forbidden session token.")
        _authorized_origin(session, request) || return _write_response(stream, 403, "text/plain", "Forbidden websocket origin.")
        return HTTP.WebSockets.upgrade(stream) do websocket
            _handle_websocket(session, websocket)
        end
    end

    if path == "/health"
        return _write_response(stream, 200, "application/json", JSON.json(Dict("ok" => true)))
    end
    _authorized_request(session, request) || return _write_response(stream, 403, "text/plain", "Forbidden session token.")
    if path == "/" || path == "/index.html"
        return _write_response(stream, 200, "text/html; charset=utf-8", _editor_html(session))
    elseif path == "/static"
        view = PlantSimEngine.GraphEditor.model_graph_view(
            session.model;
            templates=session.templates,
            environments=session.environments,
        )
        return _write_response(
            stream,
            200,
            "text/html; charset=utf-8",
            PlantSimEngine.GraphEditor.model_graph_view_html(view),
        )
    elseif path == "/state"
        return _write_response(stream, 200, "application/json", _state_json(session))
    end
    return _write_response(stream, 404, "text/plain", "Not found")
end

function _write_response(stream, status, content_type, body)
    HTTP.setstatus(stream, status)
    HTTP.setheader(stream, "Content-Type" => content_type)
    HTTP.setheader(stream, "Connection" => "close")
    HTTP.setheader(stream, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(stream)
    write(stream, body)
    return nothing
end

function _authorized_request(session, request)
    token = HTTP.header(request, "X-PlantSimEngine-Graph-Token", "")
    isempty(token) && (token = something(_query_parameter(request.target, "token"), ""))
    return token == session.token
end

function _query_parameter(target, requested_name)
    query = String(HTTP.URI(target).query)
    isempty(query) && return nothing
    for component in split(query, '&')
        pair = split(component, '='; limit=2)
        length(pair) == 2 || continue
        first(pair) == requested_name && return last(pair)
    end
    return nothing
end

function _authorized_origin(session, request)
    origin = HTTP.header(request, "Origin", "")
    return isempty(origin) || origin == _base_url(session)
end

function _handle_websocket(session, websocket)
    _send_websocket(websocket, _state_json(session)) || return nothing
    try
        for raw_message in websocket
            command = JSON.parse(String(raw_message))
            response = _handle_command!(session, command)
            _send_websocket(websocket, JSON.json(response)) || return nothing
        end
    catch err
        _is_close_error(err) || _send_websocket(
            websocket,
            JSON.json(Dict("ok" => false, "diagnostics" => [sprint(showerror, err)])),
        )
    end
    return nothing
end

function _send_websocket(websocket, payload)
    try
        HTTP.WebSockets.send(websocket, payload)
        return true
    catch err
        _is_close_error(err) && return false
        rethrow()
    end
end

_is_close_error(err) = err isa EOFError || err isa Base.IOError

function _handle_command!(session, command)
    action = String(get(command, "action", ""))
    try
        if action == "undo"
            undo!(session)
        elseif action == "redo"
            redo!(session)
        elseif action == "edit"
            apply_edit!(session, _edit_from_command(session, command))
        elseif action == "save_model_code"
            session.save_path = _normalized_path(String(command["path"]))
            _remember_path!(session, session.save_path)
            _persist_model!(session)
        elseif action == "open_model_code"
            path = _normalized_path(String(command["path"]))
            candidate = _load_model_file(
                path;
                allow_julia_eval=session.allow_julia_eval,
                environments=session.environments,
            )
            push!(session.history, session.model)
            empty!(session.future)
            session.model = candidate
            session.save_path = path
            _remember_path!(session, path)
            _persist_model!(session)
        elseif action == "preview_input_binding"
            return _preview_input_binding_payload(session, command)
        elseif action == "preview_application_targets"
            return _preview_application_targets_payload(session, command)
        elseif action == "preview_instance"
            return _preview_instance_payload(session, command)
        elseif action in ("open_add_application", "begin_add_application")
            # This command only focuses/prefills frontend state. The Composite model is
            # changed by a subsequent add_application edit.
        else
            error("Unsupported graph editor command action `$(action)`.")
        end
        return _state_payload(session)
    catch err
        return _state_payload(session; ok=false, diagnostics=[sprint(showerror, err)])
    end
end

function _preview_instance_payload(session, command)
    candidate = PlantSimEngine.GraphEditor.apply_model_graph_edit(
        session.model,
        _add_instance_edit(session, command),
    )
    name = Symbol(command["name"])
    instance = only(item for item in candidate.instances if item.name == name)
    report = PlantSimEngine.GraphEditor.compile_model_report(candidate)
    application_ids = PlantSimEngine._instance_application_ids(candidate, instance)
    payload = _state_payload(session)
    payload["instancePreview"] = Dict{String,Any}(
        "name" => string(name),
        "objectIds" => [
            PlantSimEngine._model_graph_json_value(id.value)
            for id in PlantSimEngine._instance_object_ids(candidate, instance)
        ],
        "applications" => [
            Dict(
                "applicationId" => string(application.id),
                "targetIds" => [
                    PlantSimEngine._model_graph_json_value(id.value)
                    for id in application.target_ids
                ],
            )
            for application in report.applications if application.id in application_ids
        ],
        "diagnostics" => [diagnostic.message for diagnostic in report.diagnostics],
    )
    return payload
end

function _preview_application_targets_payload(session, command)
    selector = _selector_from_payload(command["selector"])
    groups = Dict{String,Any}[]
    target_ids = if haskey(command, "applicationRef")
        application = _application_ref_from_command(command)
        if application.scope == :template
            _, selected = PlantSimEngine._model_edit_instance(
                session.model,
                something(application.instance),
            )
            ids = PlantSimEngine.ObjectId[]
            for instance in session.model.instances
                instance.template === selected.template || continue
                scoped = PlantSimEngine._selector_with_scope(
                    selector,
                    PlantSimEngine.Scope(instance.name),
                )
                selected_ids = PlantSimEngine.resolve_object_ids(session.model, scoped)
                append!(ids, selected_ids)
                push!(groups, Dict(
                    "instance" => string(instance.name),
                    "objectIds" => [id.value for id in selected_ids],
                ))
            end
            unique(ids)
        else
            PlantSimEngine.resolve_object_ids(session.model, selector)
        end
    else
        PlantSimEngine.resolve_object_ids(session.model, selector)
    end
    payload = _state_payload(session)
    payload["targetPreview"] = Dict{String,Any}(
        "objectIds" => [PlantSimEngine._model_graph_json_value(id.value) for id in target_ids],
        "count" => length(target_ids),
        "groups" => groups,
    )
    return payload
end

function _preview_input_binding_payload(session, command)
    application = _application_ref_from_command(command)
    application_ids = PlantSimEngine._model_edit_compiled_application_ids(
        session.model,
        application,
    )
    input = Symbol(command["input"])
    candidate = PlantSimEngine.GraphEditor.apply_model_graph_edit(
        session.model,
        PlantSimEngine.GraphEditor.SetModelInputBinding(
            application,
            input,
            _selector_for_application(session, application, command["selector"]),
        ),
    )
    report = PlantSimEngine.GraphEditor.compile_model_report(candidate)
    bindings = [
        binding for binding in report.input_bindings
        if binding.application_id in application_ids && binding.input == input
    ]
    payload = _state_payload(session)
    payload["selectorPreview"] = Dict{String,Any}(
        "applicationRef" => _application_ref_payload(application),
        "input" => string(input),
        "consumerObjectIds" => unique([
            PlantSimEngine._model_graph_json_value(binding.consumer_id.value)
            for binding in bindings
        ]),
        "sourceObjectIds" => unique([
            PlantSimEngine._model_graph_json_value(source_id.value)
            for binding in bindings for source_id in binding.source_ids
        ]),
        "sourceApplicationIds" => unique([
            string(source_id) for binding in bindings
            for source_id in binding.source_application_ids
        ]),
        "bindingCount" => length(bindings),
        "diagnostics" => [diagnostic.message for diagnostic in report.diagnostics],
    )
    return payload
end

function _application_ref_payload(application)
    return Dict{String,Any}(
        "scope" => string(application.scope),
        "applicationId" => string(application.application_id),
        "instance" => isnothing(application.instance) ? nothing : string(application.instance),
    )
end

function _application_ref_from_command(command)
    payload = get(command, "applicationRef", nothing)
    payload isa AbstractDict || error("Application commands require an `applicationRef` object.")
    scope = Symbol(get(payload, "scope", ""))
    application_id = Symbol(get(payload, "applicationId", ""))
    scope == :global && return PlantSimEngine.GraphEditor.GlobalApplicationRef(application_id)
    scope == :template && return PlantSimEngine.GraphEditor.TemplateApplicationRef(
        payload["instance"],
        application_id,
    )
    error("Unsupported application owner scope `$(scope)`.")
end

function _model_local_templates(session)
    templates = Any[]
    for instance in session.model.instances
        any(template -> template === instance.template, values(session.templates)) && continue
        any(template -> template === instance.template, templates) || push!(templates, instance.template)
    end
    return templates
end

function _template_from_id(session, template_id)
    text = String(template_id)
    if startswith(text, "catalog:")
        name = Symbol(chopprefix(text, "catalog:"))
        haskey(session.templates, name) || error("Unknown template catalog entry `$(name)`.")
        return session.templates[name]
    elseif startswith(text, "model:")
        index = parse(Int, chopprefix(text, "model:"))
        templates = _model_local_templates(session)
        checkbounds(Bool, templates, index) || error("Unknown model-local template `$(text)`.")
        return templates[index]
    end
    error("Unsupported template id `$(text)`.")
end

function _environment_from_id(session, environment_id)
    isnothing(environment_id) && return nothing
    text = String(environment_id)
    text == "none" && return nothing
    startswith(text, "environment:") || error("Unsupported environment id `$(text)`.")
    name = Symbol(chopprefix(text, "environment:"))
    haskey(session.environments, name) || error("Unknown environment catalog entry `$(name)`.")
    return session.environments[name]
end

function _edit_from_command(session, command)
    kind = String(get(command, "kind", ""))
    kind == "add_instance" && return _add_instance_edit(session, command)
    kind == "remove_instance" && return PlantSimEngine.GraphEditor.RemoveModelInstance(command["name"])
    kind == "set_model_environment" && return PlantSimEngine.GraphEditor.SetCompositeModelEnvironment(
        _environment_from_id(session, get(command, "environmentId", nothing)),
    )
    application = kind in (
        "remove_application", "mark_previous_timestep", "unmark_previous_timestep",
        "break_cycle", "set_application_targets", "set_input_binding",
        "remove_input_binding", "set_call_binding", "remove_call_binding",
        "set_application_cadence", "set_application_environment", "set_output_routing",
        "set_update_ordering", "set_instance_override", "remove_instance_override",
        "set_object_override", "remove_object_override", "update_application",
        "replace_application_model",
    ) ? _application_ref_from_command(command) : nothing
    kind == "remove_application" && return PlantSimEngine.GraphEditor.RemoveModelApplication(application)
    kind == "mark_previous_timestep" && return PlantSimEngine.GraphEditor.MarkModelPreviousTimeStep(
        application,
        Symbol(command["input"]),
    )
    kind == "unmark_previous_timestep" && return PlantSimEngine.GraphEditor.UnmarkModelPreviousTimeStep(
        application,
        Symbol(command["input"]),
    )
    kind == "break_cycle" && return PlantSimEngine.GraphEditor.BreakModelCycle(
        application,
        Symbol(command["input"]),
        Bool(get(command, "initializeMissing", false)),
        _parameter_value(session, get(command, "initialValue", nothing)),
    )
    kind == "set_application_targets" && return PlantSimEngine.GraphEditor.SetModelApplicationTargets(
        application,
        _selector_for_application(session, application, command["selector"]),
    )
    kind == "set_input_binding" && return PlantSimEngine.GraphEditor.SetModelInputBinding(
        application,
        Symbol(command["input"]),
        _selector_for_application(session, application, command["selector"]),
    )
    kind == "remove_input_binding" && return PlantSimEngine.GraphEditor.RemoveModelInputBinding(
        application,
        Symbol(command["input"]),
    )
    if kind == "set_call_binding"
        selector = _selector_for_application(
            session,
            application,
            command["selector"],
        )
        mode = Symbol(get(command, "mode", "manual"))
        mode in (:manual, :initializer) || error(
            "Call binding mode must be `manual` or `initializer`, got `$(mode)`.",
        )
        binding = mode === :initializer ?
                  PlantSimEngine.Initializer(selector) : selector
        return PlantSimEngine.GraphEditor.SetModelCallBinding(
            application,
            Symbol(command["call"]),
            binding,
        )
    end
    kind == "remove_call_binding" && return PlantSimEngine.GraphEditor.RemoveModelCallBinding(
        application,
        Symbol(command["call"]),
    )
    kind == "set_application_cadence" && return PlantSimEngine.GraphEditor.SetModelApplicationCadence(
        application,
        _period_from_payload(get(command, "cadence", nothing)),
    )
    kind == "set_application_environment" && return PlantSimEngine.GraphEditor.SetModelApplicationEnvironment(
        application,
        _application_environment_from_payload(session, get(command, "configuration", nothing)),
    )
    kind == "set_output_routing" && return PlantSimEngine.GraphEditor.SetModelOutputRouting(
        application,
        Symbol(command["output"]),
        Symbol(command["route"]),
    )
    kind == "set_update_ordering" && return PlantSimEngine.GraphEditor.SetModelUpdateOrdering(
        application,
        _updates_from_payload(application, get(command, "updates", Any[])),
    )
    kind == "set_object_status" && return PlantSimEngine.GraphEditor.SetModelObjectStatus(
        command["objectId"],
        Symbol(command["variable"]),
        _parameter_value(session, command["value"]),
    )
    kind == "set_object_statuses" && return PlantSimEngine.GraphEditor.SetModelObjectStatuses(
        command["objectIds"],
        Symbol(command["variable"]),
        _parameter_value(session, command["value"]),
    )
    kind == "remove_object_status" && return PlantSimEngine.GraphEditor.RemoveModelObjectStatus(
        command["objectId"],
        Symbol(command["variable"]),
    )
    kind in ("set_object_metadata", "update_object") && return PlantSimEngine.GraphEditor.SetModelObjectMetadata(
        PlantSimEngine.ObjectId(command["objectId"]),
        _metadata_from_payload(get(command, "configuration", Dict())),
    )
    kind == "add_object" && return PlantSimEngine.GraphEditor.AddModelObject(
        _object_from_command(session, command),
    )
    kind == "remove_object" && return PlantSimEngine.GraphEditor.RemoveModelObject(
        command["objectId"];
        recursive=Bool(get(command, "recursive", true)),
    )
    kind == "reparent_object" && return PlantSimEngine.ReparentModelObject(
        command["objectId"],
        get(command, "parentId", nothing),
    )
    kind == "set_instance_override" && return PlantSimEngine.GraphEditor.SetModelInstanceOverride(
        command["instance"],
        application.application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    kind == "remove_instance_override" && return PlantSimEngine.GraphEditor.RemoveModelInstanceOverride(
        command["instance"],
        application.application_id,
    )
    kind == "set_object_override" && return PlantSimEngine.GraphEditor.SetModelObjectOverride(
        command["instance"],
        command["objectId"],
        application.application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    kind == "remove_object_override" && return PlantSimEngine.GraphEditor.RemoveModelObjectOverride(
        command["instance"],
        command["objectId"],
        application.application_id,
    )
    kind == "add_application" && return _add_application_edit(session, command)
    kind == "update_application" && return _update_application_edit(session, command)
    kind == "replace_application_model" && return PlantSimEngine.GraphEditor.ReplaceModelApplicationModel(
        application,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    error("Unsupported Model graph edit kind `$(kind)`.")
end

function _add_instance_edit(session, command)
    root_payload = get(command, "rootObject", nothing)
    root = isnothing(root_payload) ? nothing : _object_from_command(session, root_payload)
    root_id = isnothing(root) ? command["rootId"] : root.id
    return PlantSimEngine.GraphEditor.AddModelInstance(
        command["name"],
        _template_from_id(session, command["templateId"]),
        root_id;
        root_object=root,
    )
end

function _selector_for_application(session, application, payload)
    selector = _selector_from_payload(payload)
    application.scope == :global && return selector
    _, instance = PlantSimEngine._model_edit_instance(
        session.model,
        something(application.instance),
    )
    return PlantSimEngine._model_edit_unmount_selector(selector, instance)
end

function _application_environment_from_payload(session, payload)
    isnothing(payload) && return nothing
    payload isa AbstractDict || error("Application environment configuration must be an object.")
    values = Pair{Symbol,Any}[]
    backend_id = get(payload, "backendId", "scene")
    backend_id in (nothing, "scene") || push!(values, :backend => _environment_from_id(session, backend_id))
    provider = get(payload, "provider", nothing)
    isnothing(provider) || isempty(strip(String(provider))) || push!(values, :provider => Symbol(provider))
    sources = get(payload, "sources", Dict())
    isempty(sources) || push!(values, :sources => (; (
        Symbol(key) => Symbol(value) for (key, value) in pairs(sources)
        if !isempty(strip(String(value)))
    )...))
    sink = get(payload, "sink", nothing)
    isnothing(sink) || isempty(strip(String(sink))) || push!(values, :sink => Symbol(sink))
    extra = _configuration_from_payload(session, get(payload, "extra", Dict()))
    append!(values, pairs(extra))
    return (; values...)
end

function _symbol_keyed_namedtuple(payload)
    payload isa AbstractDict || error("Expected an object-valued configuration payload.")
    return (; (Symbol(key) => value for (key, value) in payload)...)
end

function _metadata_from_payload(payload)
    payload isa AbstractDict || error("Expected an object metadata payload.")
    return (; (
        Symbol(key) => (value isa AbstractString && isempty(strip(value)) ? nothing : value)
        for (key, value) in payload
    )...)
end

function _configuration_from_payload(session, payload)
    isnothing(payload) && return nothing
    payload isa AbstractDict || return payload
    values = Pair{Symbol,Any}[]
    for (key, value) in payload
        parsed = if value isa AbstractDict && haskey(value, "type") && haskey(value, "value")
            _parameter_value(session, value)
        elseif value isa AbstractDict
            _configuration_from_payload(session, value)
        elseif value isa AbstractVector
            [_configuration_from_payload(session, item) for item in value]
        else
            value
        end
        push!(values, Symbol(key) => parsed)
    end
    return (; values...)
end

function _updates_from_payload(application, payload)
    payload isa AbstractVector || error("Update ordering must be an array.")
    prefix = application.scope == :template ? string(application.instance, "__") : ""
    return Tuple(
        PlantSimEngine.Updates(
            Symbol.(get(item, "variables", Any[]))...;
            after=Symbol[
                Symbol(
                    !isempty(prefix) && startswith(String(value), prefix) ?
                    chopprefix(String(value), prefix) : String(value),
                )
                for value in get(item, "after", Any[])
            ],
        )
        for item in payload
    )
end

function _object_from_command(session, command)
    configuration = get(command, "configuration", Dict())
    status_payload = get(command, "status", Dict())
    status = if isempty(status_payload)
        nothing
    else
        PlantSimEngine.Status((; (
            Symbol(name) => _parameter_value(session, value)
            for (name, value) in status_payload
        )...))
    end
    return PlantSimEngine.Object(
        command["objectId"];
        scale=get(configuration, "scale", nothing),
        kind=get(configuration, "kind", nothing),
        species=get(configuration, "species", nothing),
        name=get(configuration, "name", nothing),
        parent=get(configuration, "parent", nothing),
        status=status,
    )
end

function _update_application_edit(session, command)
    application = _application_ref_from_command(command)
    model = _construct_model(session, command["modelType"], get(command, "parameters", Dict()))
    return PlantSimEngine.GraphEditor.UpdateModelApplication(
        application,
        model,
        Symbol(get(command, "name", string(application.application_id))),
        _selector_for_application(session, application, command["selector"]),
        _period_from_payload(get(command, "cadence", nothing)),
    )
end

function _add_application_edit(session, command)
    model = _construct_model(session, command["modelType"], get(command, "parameters", Dict()))
    name = Symbol(command["name"])
    selector = _selector_from_payload(command["selector"])
    cadence = _period_from_payload(get(command, "cadence", nothing))
    spec = PlantSimEngine.ModelSpec(model;
        name=name,
        on=selector,
        every=cadence,)
    return PlantSimEngine.GraphEditor.AddModelApplication(spec)
end

function _resolve_model_type(label)
    text = String(label)
    for model_type in PlantSimEngine.GraphEditor.available_models()
        text in (string(model_type), string(nameof(model_type))) && return model_type
    end
    error("No loaded model type matches `$(text)`. Load the defining package with `using PackageName` first.")
end

function _construct_model(session, label, parameters)
    model_type = _resolve_model_type(label)
    descriptor = PlantSimEngine.GraphEditor.model_constructor_descriptor(model_type)
    fields = descriptor["fields"]
    isempty(fields) && return model_type()
    default_instance = try
        model_type()
    catch
        nothing
    end
    values = Any[]
    for field in fields
        name = field["name"]
        if haskey(parameters, name)
            push!(values, _parameter_value(session, parameters[name]))
        elseif !isnothing(default_instance)
            push!(values, getfield(default_instance, Symbol(name)))
        else
            error("Missing constructor parameter `$(name)` for model `$(model_type)`.")
        end
    end
    return model_type(values...)
end

function _parameter_value(session, payload)
    payload isa AbstractDict || return payload
    choice = Symbol(get(payload, "type", "julia"))
    raw = get(payload, "value", nothing)
    choice == :float && return parse(Float64, string(raw))
    choice == :integer && return parse(Int, string(raw))
    choice == :boolean && return parse(Bool, string(raw))
    choice == :symbol && return Symbol(raw)
    choice == :string && return String(raw)
    choice == :nothing && return nothing
    choice == :julia && session.allow_julia_eval || choice != :julia || error(
        "Raw Julia parameter values are disabled for this session.",
    )
    choice == :julia && return Core.eval(Main, Meta.parse(String(raw)))
    return raw
end

function _selector_from_payload(payload)
    payload isa AbstractDict || error("A selector payload must be an object.")
    multiplicity = Symbol(get(payload, "multiplicity", "many"))
    criteria = get(payload, "criteria", Dict())
    selectors = PlantSimEngine.AbstractObjectSelector[
        _selector_atom_from_payload(value)
        for value in get(criteria, "selectors", Any[])
    ]
    keyword_pairs = Pair{Symbol,Any}[]
    for (key, value) in criteria
        key == "selectors" && continue
        value === nothing && continue
        push!(keyword_pairs, Symbol(key) => _selector_value(Symbol(key), value))
    end
    keywords = (; keyword_pairs...)
    multiplicity == :one && return PlantSimEngine.One(selectors...; keywords...)
    multiplicity == :optional_one && return PlantSimEngine.OptionalOne(selectors...; keywords...)
    multiplicity == :many && return PlantSimEngine.Many(selectors...; keywords...)
    error("Unsupported selector multiplicity `$(multiplicity)`.")
end

function _selector_value(key, value)
    key in (:scale, :kind, :species, :name, :process, :var, :relation, :application) &&
        return value isa AbstractVector ? Symbol.(value) : Symbol(value)
    key == :within && return _selector_atom_from_payload(value)
    key == :policy && return _policy_from_payload(value)
    key == :window && return _period_from_payload(value)
    return value
end

function _selector_atom_from_payload(payload)
    payload isa AbstractDict || error("A structured object selector must be an object.")
    type = String(get(payload, "type", ""))
    type == "SceneScope" && return PlantSimEngine.SceneScope()
    type == "Self" && return PlantSimEngine.Self()
    type == "Subtree" && return PlantSimEngine.Subtree()
    type == "SelfPlant" && return PlantSimEngine.SelfPlant()
    type == "Ancestor" && return PlantSimEngine.Ancestor(; scale=get(payload, "scale", nothing))
    type == "Scope" && return PlantSimEngine.Scope(payload["name"])
    type == "Relation" && return PlantSimEngine.Relation(payload["relation"])
    error("Unsupported structured object selector type `$(type)`.")
end

function _policy_from_payload(payload)
    payload isa AbstractDict || error("A temporal policy must be a structured object.")
    type = String(get(payload, "type", ""))
    type == "PreviousTimeStep" && return PlantSimEngine.PreviousTimeStep(
        Symbol(payload["variable"]),
        Symbol(get(payload, "process", "unknown")),
    )
    type == "HoldLast" && return PlantSimEngine.HoldLast()
    type == "Interpolate" && return PlantSimEngine.Interpolate(
        ;
        mode=Symbol(get(payload, "mode", "linear")),
        extrapolation=Symbol(get(payload, "extrapolation", "linear")),
    )
    type == "Integrate" && return PlantSimEngine.Integrate()
    type == "Aggregate" && return PlantSimEngine.Aggregate()
    error("Unsupported temporal policy type `$(type)`.")
end

function _period_from_payload(payload)
    isnothing(payload) && return nothing
    payload isa AbstractDict || error("A cadence or window payload must be an object.")
    mode = String(get(payload, "mode", "default"))
    mode == "default" && return nothing
    mode == "period" || error("Unsupported cadence/window mode `$(mode)`.")
    value = parse(Int, string(payload["value"]))
    value > 0 || error("Cadence/window values must be positive.")
    unit = String(payload["unit"])
    constructors = Dict(
        "Second" => Dates.Second,
        "Minute" => Dates.Minute,
        "Hour" => Dates.Hour,
        "Day" => Dates.Day,
    )
    haskey(constructors, unit) || error(
        "Unsupported period unit `$(unit)`. Use Second, Minute, Hour, or Day.",
    )
    return constructors[unit](value)
end

function _state_payload(session; ok=true, diagnostics=String[])
    graph = JSON.parse(PlantSimEngine.GraphEditor.model_graph_view_json(
        session.model;
        templates=session.templates,
        environments=session.environments,
    ))
    return Dict{String,Any}(
        "ok" => ok,
        "diagnostics" => diagnostics,
        "graph" => graph,
        "canUndo" => !isempty(session.history),
        "canRedo" => !isempty(session.future),
        "url" => session.url,
        "modelCode" => _model_to_julia(session),
        "autosavePath" => session.autosave_path,
        "savePath" => session.save_path,
        "recentPaths" => session.recent_paths,
    )
end

function _remember_path!(session, path)
    normalized = _normalized_path(path)
    filter!(!=(normalized), session.recent_paths)
    pushfirst!(session.recent_paths, normalized)
    length(session.recent_paths) > 12 && resize!(session.recent_paths, 12)
    _persist_recent_paths!(session.recent_paths)
    return normalized
end

function _recent_paths_file()
    return joinpath(tempdir(), "PlantSimEngineGraphEditor", "recent-models.json")
end

function _load_recent_paths()
    path = _recent_paths_file()
    isfile(path) || return String[]
    try
        values = JSON.parse(read(path, String))
        values isa AbstractVector || return String[]
        return String[_normalized_path(value) for value in values if value isa AbstractString]
    catch
        return String[]
    end
end

function _persist_recent_paths!(paths)
    path = _recent_paths_file()
    mkpath(dirname(path))
    _atomic_write(path, JSON.json(collect(paths)))
    return path
end

function _load_model_file(path; allow_julia_eval::Bool, environments=Dict{Symbol,Any}())
    allow_julia_eval || error("Opening Julia Composite model files is disabled for this editor session.")
    isfile(path) || error("Composite model file `$(path)` does not exist.")
    source = read(path, String)
    required_match = match(
        r"(?m)^# Requires `editor_environments` with named values: ([^.]+)\.$",
        source,
    )
    if !isnothing(required_match)
        required = Set(Symbol(strip(name)) for name in split(required_match.captures[1], ','))
        missing = sort!(collect(setdiff(required, Set(keys(environments)))); by=string)
        isempty(missing) || error(
            "Composite model file `$(path)` requires environment catalog keys $(missing).",
        )
    end
    module_name = Symbol("PlantSimEngineGraphRecovery_", string(time_ns(); base=16))
    workspace = Module(module_name)
    Core.eval(workspace, :(using PlantSimEngine))
    environment_values = (; (
        name => value for (name, value) in sort!(collect(environments); by=first)
    )...)
    Core.eval(workspace, :(editor_environments = $environment_values))
    included = Base.include(workspace, path)
    model = isdefined(workspace, :model) ? getfield(workspace, :model) : included
    model isa PlantSimEngine.CompositeModel || error(
        "Composite model file `$(path)` must assign its final PlantSimEngine.CompositeModel to `model`.",
    )
    return model
end

_state_json(session) = JSON.json(_state_payload(session))

function _editor_html(session)
    view = PlantSimEngine.GraphEditor.model_graph_view(
        session.model;
        templates=session.templates,
        environments=session.environments,
    )
    html = PlantSimEngine.GraphEditor.model_graph_view_html(view)
    config = replace(JSON.json(Dict("websocketUrl" => _websocket_url(session))), "</" => "<\\/")
    script = "<script type=\"application/json\" id=\"pse-editor-config\">$(config)</script>"
    return replace(html, "</head>" => "$(script)</head>")
end

function _status_conversion_module_code(module_::Module)
    label = string(module_)
    all(Base.isidentifier, split(label, '.')) || return nothing
    return label
end

function _status_conversion_type_code(type_)
    type_ isa DataType || return nothing
    name = String(nameof(type_))
    Base.isidentifier(name) || return nothing
    occursin('#', name) && return nothing
    module_ = parentmodule(type_)
    module_code = _status_conversion_module_code(module_)
    isnothing(module_code) && return nothing
    isdefined(module_, Symbol(name)) || return nothing
    getfield(module_, Symbol(name)) === type_.name.wrapper || return nothing
    base = module_ in (Base, Core) ? name : "$(module_code).$(name)"
    isempty(type_.parameters) && return base
    parameter_codes = String[]
    for parameter in type_.parameters
        code = parameter isa Type ?
               _status_conversion_type_code(parameter) :
               _status_conversion_literal_code(parameter)
        isnothing(code) && return nothing
        push!(parameter_codes, code)
    end
    return "$(base){$(join(parameter_codes, ", "))}"
end

function _status_conversion_tuple_code(codes::Vector{String})
    isempty(codes) && return "()"
    length(codes) == 1 && return "($(only(codes)),)"
    return "($(join(codes, ", ")))"
end

function _status_conversion_array_code(value::Array)
    element_type = _status_conversion_type_code(eltype(value))
    isnothing(element_type) && return nothing
    elements = String[]
    for item in value
        code = _status_conversion_literal_code(item)
        isnothing(code) && return nothing
        push!(elements, code)
    end
    vector = "$(element_type)[$(join(elements, ", "))]"
    ndims(value) == 1 && return vector
    ndims(value) == 0 && return "reshape($(vector), ())"
    return "reshape($(vector), $(join(size(value), ", ")))"
end

function _status_conversion_literal_code(value)
    value === nothing && return "nothing"
    value === missing && return "missing"
    value isa Type && return _status_conversion_type_code(value)
    if value isa PlantSimEngine.ObjectId
        identifier = _status_conversion_literal_code(value.value)
        isnothing(identifier) && return nothing
        return "PlantSimEngine.ObjectId($(identifier))"
    end
    value isa Union{Bool,Integer,Float16,Float32,Float64,Char,AbstractString,Symbol} &&
        return repr(value)
    if value isa Pair
        first_code = _status_conversion_literal_code(first(value))
        last_code = _status_conversion_literal_code(last(value))
        (isnothing(first_code) || isnothing(last_code)) && return nothing
        return "$(first_code) => $(last_code)"
    end
    if value isa NamedTuple
        names_code = _status_conversion_literal_code(Tuple(keys(value)))
        values_code = _status_conversion_literal_code(Tuple(values(value)))
        (isnothing(names_code) || isnothing(values_code)) && return nothing
        return "NamedTuple{$(names_code)}($(values_code))"
    end
    if value isa Tuple
        codes = String[]
        for item in value
            code = _status_conversion_literal_code(item)
            isnothing(code) && return nothing
            push!(codes, code)
        end
        return _status_conversion_tuple_code(codes)
    end
    value isa Array && return _status_conversion_array_code(value)
    return nothing
end

function _status_transform_code(transform)
    isnothing(transform) && return "nothing"
    try
        Meta.parse(repr(transform))
    catch
        return nothing
    end

    transform_type = typeof(transform)
    type_name = String(nameof(transform_type))
    (Base.isidentifier(type_name) && !occursin('#', type_name)) || return nothing
    if transform isa Function
        name = nameof(transform)
        module_ = parentmodule(transform_type)
        module_code = _status_conversion_module_code(module_)
        isnothing(module_code) && return nothing
        isdefined(module_, name) || return nothing
        getfield(module_, name) === transform || return nothing
        return "$(module_code).$(name)"
    end

    type_code = _status_conversion_type_code(transform_type)
    isnothing(type_code) && return nothing
    fields = Any[getfield(transform, index) for index in 1:fieldcount(transform_type)]
    field_codes = String[]
    for field in fields
        code = _status_conversion_literal_code(field)
        isnothing(code) && return nothing
        push!(field_codes, code)
    end
    applicable(transform_type, fields...) || return nothing
    reconstructed = try
        transform_type(fields...)
    catch
        return nothing
    end
    typeof(reconstructed) === transform_type || return nothing
    all(
        isequal(getfield(reconstructed, index), getfield(transform, index))
        for index in 1:fieldcount(transform_type)
    ) || return nothing
    return "$(type_code)($(join(field_codes, ", ")))"
end

function _status_conversion_policy_code(model, diagnostics)
    policy = model.status_conversion
    isempty(policy.rules) && isnothing(policy.transform) && return nothing

    rule_codes = String[]
    mapping_safe = true
    for rule in policy.rules
        source = _status_conversion_type_code(first(rule))
        target = _status_conversion_type_code(last(rule))
        if isnothing(source) || isnothing(target)
            mapping_safe = false
            break
        end
        push!(rule_codes, "$(source) => $(target)")
    end
    if !mapping_safe
        empty!(rule_codes)
        push!(
            diagnostics,
            "The Composite model type_promotion rules are not reconstructed because at least one mapped type has no safe Julia representation. Existing effective Status values are preserved, but future status materialization will not apply the mapping.",
        )
    end
    sort!(rule_codes)

    transform_code = _status_transform_code(policy.transform)
    if isnothing(transform_code)
        transform_repr = replace(repr(policy.transform), '\n' => ' ')
        push!(
            diagnostics,
            "The Composite model status_transform `$(transform_repr)` is not reconstructed because its repr is not a safely reconstructible named function or functor. Existing effective Status values are preserved, but future defaults and registered objects use only reconstructible type_promotion rules.",
        )
        transform_code = "nothing"
    elseif !isnothing(policy.transform) &&
           Base.moduleroot(parentmodule(typeof(policy.transform))) === Main
        push!(
            diagnostics,
            "The Composite model status_transform type $(typeof(policy.transform)) is defined in Main. Define or include it before evaluating this generated Composite model script.",
        )
    end

    rules = _status_conversion_tuple_code(rule_codes)
    return "PlantSimEngine.StatusConversionPolicy($(rules), $(transform_code))"
end

function _status_conversion_record_code(record)
    record isa PlantSimEngine.StatusConversionRecord || return nothing
    arguments = String[]
    for field in fieldnames(typeof(record))
        code = _status_conversion_literal_code(getfield(record, field))
        isnothing(code) && return nothing
        push!(arguments, code)
    end
    return "PlantSimEngine.StatusConversionRecord($(join(arguments, ", ")))"
end

function _status_conversion_records_code(model, diagnostics)
    isempty(model.status_conversion_records) && return nothing
    entries = String[]
    for (key, record) in model.status_conversion_records
        key_code = _status_conversion_literal_code(key)
        record_code = _status_conversion_record_code(record)
        if isnothing(key_code) || isnothing(record_code)
            push!(
                diagnostics,
                "The Composite model status-conversion records contain a value with no safe Julia representation. Generated code omits those diagnostic records while preserving effective Status values and the reconstructible policy.",
            )
            return nothing
        end
        push!(entries, "$(key_code) => $(record_code)")
    end
    sort!(entries)
    return "Dict{Any,Any}($(join(entries, ", ")))"
end

function _model_to_julia(session::GraphEditorSession)
    model = session.model
    io = IOBuffer()
    diagnostics = String[]
    status_conversion = _status_conversion_policy_code(model, diagnostics)
    status_conversion_records = isnothing(status_conversion) ?
                                nothing :
                                _status_conversion_records_code(model, diagnostics)
    modules = _model_code_modules(model)
    for module_name in sort!(collect(modules))
        println(io, "using $(module_name)")
    end
    println(io, "using Dates")
    println(io)
    if !isnothing(model.source_adapter)
        push!(diagnostics, "The Composite model source_adapter is runtime-specific and is not reconstructed by generated code.")
    end
    for model in _model_code_models(model)
        Base.moduleroot(parentmodule(typeof(model))) === Main || continue
        push!(
            diagnostics,
            "Model $(typeof(model)) is defined in Main. Define or include that model before evaluating this generated Composite model script.",
        )
    end
    for diagnostic in unique(diagnostics)
        println(io, "# WARNING: ", diagnostic)
    end
    required_environments = _required_environment_names(session)
    if !isempty(required_environments)
        names = join(sort!(string.(collect(required_environments))), ", ")
        println(io, "# Requires `editor_environments` with named values: ", names, ".")
    end
    isempty(diagnostics) || println(io)
    println(io, "objects = (")
    for object in PlantSimEngine.model_objects(model)
        println(io, "    ", _object_code(session, object), ",")
    end
    println(io, ")")

    templates = Any[]
    for instance in model.instances
        any(template -> template === instance.template, templates) || push!(templates, instance.template)
    end
    for (index, template) in pairs(templates)
        println(io)
        println(io, "template_$(index) = ", _template_code(session, template))
    end

    if !isempty(model.instances)
        println(io)
        println(io, "instances = (")
        for instance in model.instances
            template_index = only(index for (index, template) in pairs(templates) if template === instance.template)
            println(io, "    ", _instance_code(instance, template_index), ",")
        end
        println(io, ")")
    else
        println(io)
        println(io, "instances = ()")
    end

    mounted_ids = Set{Symbol}()
    for instance in model.instances
        union!(mounted_ids, PlantSimEngine._instance_application_ids(model, instance))
    end
    global_applications = [
        application for application in model.applications
        if PlantSimEngine._model_edit_application_id(application) ∉ mounted_ids
    ]
    println(io, "applications = (")
    for application in global_applications
        println(io, "    ", _application_code(session, PlantSimEngine.as_model_spec(application)), ",")
    end
    println(io, ")")
    environment = _environment_value_code(session, model.environment)
    options = String[
        "applications=applications",
        "instances=instances",
        "environment=$(environment)",
    ]
    if !isnothing(status_conversion)
        push!(options, "_status_conversion=$(status_conversion)")
        push!(options, "_status_values_materialized=true")
        isnothing(status_conversion_records) ||
            push!(options, "_status_conversion_records=$(status_conversion_records)")
    end
    print(io, "model = CompositeModel(objects...; $(join(options, ", ")))")
    return String(take!(io))
end

function _required_environment_names(session)
    names = Set{Symbol}()
    add_value = function (value)
        for (name, environment) in session.environments
            environment === value && push!(names, name)
        end
    end
    add_value(session.model.environment)
    add_spec = function (raw_spec)
        spec = PlantSimEngine.as_model_spec(raw_spec)
        environment = PlantSimEngine.environment_config(spec)
        isnothing(environment) && return
        payload = environment isa PlantSimEngine.EnvironmentConfig ? environment.config : environment
        payload isa NamedTuple && haskey(payload, :backend) && add_value(payload.backend)
    end
    foreach(add_spec, session.model.applications)
    for object in PlantSimEngine.model_objects(session.model)
        isnothing(object.applications) || foreach(add_spec, object.applications)
    end
    for instance in session.model.instances
        foreach(add_spec, instance.template.applications)
    end
    return names
end

function _model_code_models(model)
    models = Any[]
    add_application = function (application)
        process_model = PlantSimEngine.model_(PlantSimEngine.as_model_spec(application))
        if process_model isa PlantSimEngine.ObjectModelOverrides
            push!(models, process_model.base)
            append!(models, values(process_model.overrides))
        else
            push!(models, process_model)
        end
    end
    foreach(add_application, model.applications)
    for object in PlantSimEngine.model_objects(model)
        isnothing(object.applications) && continue
        foreach(add_application, object.applications)
    end
    for instance in model.instances
        foreach(add_application, instance.template.applications)
        append!(models, values(instance.overrides))
        append!(models, (override.model for override in instance.object_overrides))
    end
    return models
end

function _model_code_modules(model)
    modules = Set{String}(["PlantSimEngine"])
    add_model = function (model)
        module_ = parentmodule(typeof(model))
        module_ in (Base, Core, Main) || push!(modules, string(module_))
    end
    foreach(add_model, _model_code_models(model))
    return modules
end

function _object_code(session, object)
    keywords = String[
        "scale=$(repr(object.scale))",
        "kind=$(repr(object.kind))",
        "species=$(repr(object.species))",
        "name=$(repr(object.name))",
        "parent=$(isnothing(object.parent) ? "nothing" : repr(object.parent.value))",
    ]
    if object.status isa PlantSimEngine.Status
        values = join(("$(name)=$(repr(object.status[name]))" for name in propertynames(object.status)), ", ")
        push!(keywords, "status=Status(; $(values))")
    end
    isnothing(object.geometry) || push!(keywords, "geometry=$(repr(object.geometry))")
    if !isnothing(object.applications) && object.applications != ()
        applications = join(
            (_application_code(session, PlantSimEngine.as_model_spec(application)) for application in object.applications),
            ", ",
        )
        push!(keywords, "applications=($(applications),)")
    end
    return "Object($(repr(object.id.value)); $(join(keywords, ", ")))"
end

function _template_code(session, template)
    applications = join(
        ("        " * _application_code(session, PlantSimEngine.as_model_spec(application)) * "," for application in template.applications),
        "\n",
    )
    return "CompositeModelTemplate((\n$(applications)\n    ); kind=$(repr(template.kind)), species=$(repr(template.species)), parameters=$(repr(template.parameters)))"
end

function _instance_code(instance, template_index)
    overrides = if isempty(keys(instance.overrides))
        "NamedTuple()"
    else
        entries = join(("$(key)=$(repr(model))" for (key, model) in pairs(instance.overrides)), ", ")
        "($(entries),)"
    end
    object_overrides = if isempty(instance.object_overrides)
        "()"
    else
        entries = join((_object_override_code(override) for override in instance.object_overrides), ", ")
        "($(entries),)"
    end
    return "ObjectInstance($(repr(instance.name)), template_$(template_index); root=$(repr(PlantSimEngine._instance_root_id(instance).value)), overrides=$(overrides), object_overrides=$(object_overrides))"
end

function _object_override_code(override)
    options = String["object=$(repr(override.object.value))"]
    isnothing(override.application) || push!(options, "application=$(repr(override.application))")
    push!(options, "model=$(repr(override.model))")
    return "Override(; $(join(options, ", ")))"
end

function _environment_value_code(session, value)
    isnothing(value) && return "nothing"
    for (name, environment) in session.environments
        environment === value && return "editor_environments.$(name)"
    end
    return repr(value)
end

function _environment_configuration_code(session, payload)
    payload isa NamedTuple || return repr(payload)
    entries = String[]
    for (name, value) in pairs(payload)
        code = Symbol(name) == :backend ? _environment_value_code(session, value) : repr(value)
        push!(entries, "$(name)=$(code)")
    end
    return isempty(entries) ? "NamedTuple()" : "($(join(entries, ", ")),)"
end

function _application_code(session, spec)
    options = String["name=$(repr(PlantSimEngine.application_name(spec)))"]
    selector = PlantSimEngine.applies_to(spec)
    isnothing(selector) || push!(options, "on=$(repr(selector))")
    isempty(keys(PlantSimEngine.value_inputs(spec))) ||
        push!(options, "inputs=$(repr(PlantSimEngine.value_inputs(spec)))")
    isempty(keys(PlantSimEngine.model_calls(spec))) ||
        push!(options, "calls=$(repr(PlantSimEngine.model_calls(spec)))")
    environment = PlantSimEngine.environment_config(spec)
    if !isnothing(environment)
        payload = environment isa PlantSimEngine.EnvironmentConfig ? environment.config : environment
        push!(options, "environment=Environment($(_environment_configuration_code(session, payload)))")
    end
    isnothing(spec.timestep) || push!(options, "every=$(repr(spec.timestep))")
    if !isempty(keys(PlantSimEngine.environment_bindings(spec)))
        push!(
            options,
            "environment_bindings=$(repr(PlantSimEngine.environment_bindings(spec)))",
        )
    end
    if !isnothing(PlantSimEngine.environment_window(spec))
        push!(
            options,
            "environment_window=$(repr(PlantSimEngine.environment_window(spec)))",
        )
    end
    isempty(keys(PlantSimEngine.output_routing(spec))) ||
        push!(options, "output_routing=$(repr(PlantSimEngine.output_routing(spec)))")
    update_codes = String[]
    for update in PlantSimEngine.updates(spec)
        variables = join(repr.(collect(update.variables)), ", ")
        push!(update_codes, "Updates($(variables); after=$(repr(update.after)))")
    end
    if length(update_codes) == 1
        push!(options, "updates=$(only(update_codes))")
    elseif !isempty(update_codes)
        push!(options, "updates=($(join(update_codes, ", ")),)")
    end
    return "ModelSpec($(repr(PlantSimEngine.model_(spec))); $(join(options, ", ")))"
end

function _persist_model!(session)
    code = _model_to_julia(session) * "\n"
    isnothing(session.autosave_path) || _atomic_write(session.autosave_path, code)
    isnothing(session.save_path) || _atomic_write(session.save_path, code)
    return nothing
end

function _atomic_write(path, content)
    path = _normalized_path(path)
    mkpath(dirname(path))
    temporary = tempname(dirname(path))
    try
        write(temporary, content)
        mv(temporary, path; force=true)
    finally
        isfile(temporary) && rm(temporary; force=true)
    end
    return path
end

_normalized_path(path) = isabspath(String(path)) ? normpath(String(path)) : normpath(joinpath(pwd(), String(path)))

function _default_autosave_path()
    return joinpath(
        tempdir(),
        "PlantSimEngineGraphEditor",
        string("session-", time_ns()),
        "model.autosave.jl",
    )
end

function _open_in_default_browser(url)
    try
        if Sys.isapple()
            run(`open $url`)
        elseif Sys.iswindows()
            run(`cmd /c start "" $url`)
        elseif !isnothing(Sys.which("xdg-open"))
            run(`xdg-open $url`)
        else
            @warn "Could not locate a default-browser command." url
            return false
        end
        return true
    catch err
        @warn "Could not open the graph editor automatically." url exception=(err, catch_backtrace())
        return false
    end
end

end
