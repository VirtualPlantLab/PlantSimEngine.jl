module PlantSimEngineGraphEditorExt

import HTTP
import JSON
import PlantSimEngine
import PlantSimEngine: edit_graph, current_scene, apply_edit!, undo!, redo!

mutable struct GraphEditorSession <: PlantSimEngine.AbstractSceneGraphEditorSession
    scene::PlantSimEngine.Scene
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

current_scene(session::GraphEditorSession) = session.scene

function Base.close(session::GraphEditorSession)
    try
        isopen(session.server) && close(session.server)
    catch
        close(session.server)
    end
    return nothing
end

function Base.show(io::IO, session::GraphEditorSession)
    print(io, "GraphEditorSession(url=$(repr(session.url)), applications=$(length(session.scene.applications)))")
end

function Base.show(io::IO, ::MIME"text/plain", session::GraphEditorSession)
    println(io, "PlantSimEngineGraphEditorExt.GraphEditorSession")
    println(io, "  Open in browser: $(session.url)")
    println(io, "  State JSON: $(_state_url(session))")
    println(io, "  Current scene: current_scene(session)")
    println(io, "  Quit session: close(session)")
    isnothing(session.autosave_path) || println(io, "  Recovery autosave: $(session.autosave_path)")
    isnothing(session.save_path) || println(io, "  Saving changes to: $(session.save_path)")
end

"""
    edit_graph([scene]; host="127.0.0.1", port=0, open_browser=true,
               autosave=true, allow_remote=false, allow_julia_eval=nothing)

Start a local Scene graph editor. Julia owns the current Scene and applies all
semantic edits received from the browser. Call `edit_graph()` to start from an
empty Scene and `close(session)` to stop the server.
"""
function edit_graph(
    scene::PlantSimEngine.Scene=PlantSimEngine.Scene();
    host::AbstractString="127.0.0.1",
    port::Integer=0,
    open_browser::Bool=true,
    autosave::Bool=true,
    autosave_path::Union{Nothing,AbstractString}=nothing,
    save_path::Union{Nothing,AbstractString}=nothing,
    allow_remote::Bool=false,
    allow_julia_eval::Union{Nothing,Bool}=nothing,
    recover_path::Union{Nothing,AbstractString}=nothing,
    recent_paths=String[],
)
    _is_loopback_host(host) || allow_remote || error(
        "Graph editor sessions are limited to localhost by default. Pass `allow_remote=true` only for a trusted network.",
    )
    effective_allow_julia_eval = isnothing(allow_julia_eval) ? !allow_remote : allow_julia_eval
    initial_scene = isnothing(recover_path) ? deepcopy(scene) : _load_scene_file(
        _normalized_path(recover_path);
        allow_julia_eval=effective_allow_julia_eval,
    )
    session_ref = Ref{Any}()
    handler = stream -> _handle_http(session_ref[], stream)
    server = HTTP.listen!(handler, host, port; listenany=true, verbose=false)
    actual_port = HTTP.port(server)
    token = _session_token(server)
    autosave_file = autosave ? _normalized_path(
        isnothing(autosave_path) ? _default_autosave_path() : autosave_path,
    ) : nothing
    session = GraphEditorSession(
        initial_scene,
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
        String[_normalized_path(path) for path in recent_paths],
    )
    session_ref[] = session
    isnothing(session.save_path) || _remember_path!(session, session.save_path)
    isnothing(recover_path) || _remember_path!(session, _normalized_path(recover_path))
    _persist_scene!(session)
    open_browser && _open_in_default_browser(session.url)
    return session
end

function apply_edit!(session::GraphEditorSession, edit::PlantSimEngine.AbstractSceneGraphEdit)
    candidate = PlantSimEngine.apply_scene_graph_edit(session.scene, edit)
    push!(session.history, session.scene)
    empty!(session.future)
    session.scene = candidate
    _persist_scene!(session)
    return session.scene
end

function undo!(session::GraphEditorSession)
    isempty(session.history) && return session.scene
    push!(session.future, session.scene)
    session.scene = pop!(session.history)
    _persist_scene!(session)
    return session.scene
end

function redo!(session::GraphEditorSession)
    isempty(session.future) && return session.scene
    push!(session.history, session.scene)
    session.scene = pop!(session.future)
    _persist_scene!(session)
    return session.scene
end

_session_token(server) = string(hash((time_ns(), getpid(), objectid(server))); base=16) *
                         string(hash((objectid(server), time_ns(), getpid())); base=16)

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
        elseif action == "save_scene_code"
            session.save_path = _normalized_path(String(command["path"]))
            _remember_path!(session, session.save_path)
            _persist_scene!(session)
        elseif action == "open_scene_code"
            path = _normalized_path(String(command["path"]))
            candidate = _load_scene_file(path; allow_julia_eval=session.allow_julia_eval)
            push!(session.history, session.scene)
            empty!(session.future)
            session.scene = candidate
            session.save_path = path
            _remember_path!(session, path)
            _persist_scene!(session)
        elseif action in ("open_add_application", "begin_add_application")
            # This command only focuses/prefills frontend state. The Scene is
            # changed by a subsequent add_application edit.
        else
            error("Unsupported graph editor command action `$(action)`.")
        end
        return _state_payload(session)
    catch err
        return _state_payload(session; ok=false, diagnostics=[sprint(showerror, err)])
    end
end

function _edit_from_command(session, command)
    kind = String(get(command, "kind", ""))
    application_id = Symbol(get(command, "applicationId", ""))
    kind == "remove_application" && return PlantSimEngine.RemoveSceneApplication(application_id)
    kind == "remove_template_application" && return PlantSimEngine.RemoveSceneTemplateApplication(
        command["instance"],
        application_id,
    )
    kind == "mark_previous_timestep" && return PlantSimEngine.MarkScenePreviousTimeStep(
        application_id,
        Symbol(command["input"]),
    )
    kind == "unmark_previous_timestep" && return PlantSimEngine.UnmarkScenePreviousTimeStep(
        application_id,
        Symbol(command["input"]),
    )
    kind == "break_cycle" && return PlantSimEngine.BreakSceneCycle(
        application_id,
        Symbol(command["input"]),
        Bool(get(command, "initializeMissing", false)),
        _parameter_value(session, get(command, "initialValue", nothing)),
    )
    kind == "set_application_targets" && return PlantSimEngine.SetSceneApplicationTargets(
        application_id,
        _selector_from_payload(command["selector"]),
    )
    kind == "set_input_binding" && return PlantSimEngine.SetSceneInputBinding(
        application_id,
        Symbol(command["input"]),
        _selector_from_payload(command["selector"]),
    )
    kind == "remove_input_binding" && return PlantSimEngine.RemoveSceneInputBinding(
        application_id,
        Symbol(command["input"]),
    )
    kind == "set_call_binding" && return PlantSimEngine.SetSceneCallBinding(
        application_id,
        Symbol(command["call"]),
        _selector_from_payload(command["selector"]),
    )
    kind == "remove_call_binding" && return PlantSimEngine.RemoveSceneCallBinding(
        application_id,
        Symbol(command["call"]),
    )
    kind == "set_timestep" && return PlantSimEngine.SetSceneApplicationTimeStep(
        application_id,
        _timestep_from_payload(get(command, "timestep", nothing)),
    )
    kind == "set_application_environment" && return PlantSimEngine.SetSceneApplicationEnvironment(
        application_id,
        _configuration_from_payload(session, get(command, "configuration", nothing)),
    )
    kind == "set_output_routing" && return PlantSimEngine.SetSceneOutputRouting(
        application_id,
        Symbol(command["output"]),
        Symbol(command["route"]),
    )
    kind == "set_update_ordering" && return PlantSimEngine.SetSceneUpdateOrdering(
        application_id,
        _updates_from_payload(get(command, "updates", Any[])),
    )
    kind == "set_object_status" && return PlantSimEngine.SetSceneObjectStatus(
        command["objectId"],
        Symbol(command["variable"]),
        _parameter_value(session, command["value"]),
    )
    kind == "set_object_statuses" && return PlantSimEngine.SetSceneObjectStatuses(
        command["objectIds"],
        Symbol(command["variable"]),
        _parameter_value(session, command["value"]),
    )
    kind == "remove_object_status" && return PlantSimEngine.RemoveSceneObjectStatus(
        command["objectId"],
        Symbol(command["variable"]),
    )
    kind in ("set_object_metadata", "update_object") && return PlantSimEngine.SetSceneObjectMetadata(
        PlantSimEngine.ObjectId(command["objectId"]),
        _metadata_from_payload(get(command, "configuration", Dict())),
    )
    kind == "add_object" && return PlantSimEngine.AddSceneObject(
        _object_from_command(session, command),
    )
    kind == "remove_object" && return PlantSimEngine.RemoveSceneObject(
        command["objectId"];
        recursive=Bool(get(command, "recursive", true)),
    )
    kind == "reparent_object" && return PlantSimEngine.ReparentSceneObject(
        command["objectId"],
        get(command, "parentId", nothing),
    )
    kind == "set_instance_override" && return PlantSimEngine.SetSceneInstanceOverride(
        command["instance"],
        application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    kind == "remove_instance_override" && return PlantSimEngine.RemoveSceneInstanceOverride(
        command["instance"],
        application_id,
    )
    kind == "set_object_override" && return PlantSimEngine.SetSceneObjectOverride(
        command["instance"],
        command["objectId"],
        application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    kind == "remove_object_override" && return PlantSimEngine.RemoveSceneObjectOverride(
        command["instance"],
        command["objectId"],
        application_id,
    )
    kind == "add_application" && return _add_application_edit(session, command)
    kind == "update_application" && return _update_application_edit(session, command)
    kind == "update_template_application" && return PlantSimEngine.UpdateSceneTemplateApplication(
        Symbol(command["instance"]),
        application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
        _selector_from_payload(command["selector"]),
        _timestep_from_payload(get(command, "timestep", nothing)),
    )
    kind == "replace_application_model" && return PlantSimEngine.ReplaceSceneApplicationModel(
        application_id,
        _construct_model(session, command["modelType"], get(command, "parameters", Dict())),
    )
    error("Unsupported Scene graph edit kind `$(kind)`.")
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

function _updates_from_payload(payload)
    payload isa AbstractVector || error("Update ordering must be an array.")
    return Tuple(
        PlantSimEngine.Updates(
            Symbol.(get(item, "variables", Any[]))...;
            after=Symbol.(get(item, "after", Any[])),
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
    application_id = Symbol(command["applicationId"])
    model = _construct_model(session, command["modelType"], get(command, "parameters", Dict()))
    return PlantSimEngine.UpdateSceneApplication(
        application_id,
        model,
        Symbol(get(command, "name", string(application_id))),
        _selector_from_payload(command["selector"]),
        _timestep_from_payload(get(command, "timestep", nothing)),
    )
end

function _add_application_edit(session, command)
    model = _construct_model(session, command["modelType"], get(command, "parameters", Dict()))
    name = Symbol(command["name"])
    selector = _selector_from_payload(command["selector"])
    timestep = _timestep_from_payload(get(command, "timestep", nothing))
    spec = PlantSimEngine.ModelSpec(
        model;
        name=name,
        applies_to=selector,
        timestep=timestep,
    )
    return PlantSimEngine.AddSceneApplication(spec)
end

function _resolve_model_type(label)
    text = String(label)
    for model_type in PlantSimEngine.available_models()
        text in (string(model_type), string(nameof(model_type))) && return model_type
    end
    error("No loaded model type matches `$(text)`. Load the defining package with `using PackageName` first.")
end

function _construct_model(session, label, parameters)
    model_type = _resolve_model_type(label)
    descriptor = PlantSimEngine.model_constructor_descriptor(model_type)
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
    type == "Kind" && return PlantSimEngine.Kind(payload["kind"])
    type == "Species" && return PlantSimEngine.Species(payload["species"])
    type == "Scale" && return PlantSimEngine.Scale(payload["scale"])
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

function _timestep_from_payload(payload)
    isnothing(payload) && return nothing
    payload isa AbstractDict || return payload
    mode = String(get(payload, "mode", "default"))
    mode == "default" && return nothing
    mode == "clock" && return PlantSimEngine.ClockSpec(
        parse(Float64, string(payload["dt"])),
        parse(Float64, string(get(payload, "phase", 0.0))),
    )
    error("Unsupported timestep mode `$(mode)`.")
end

function _state_payload(session; ok=true, diagnostics=String[])
    graph = JSON.parse(PlantSimEngine.scene_graph_view_json(session.scene))
    return Dict{String,Any}(
        "ok" => ok,
        "diagnostics" => diagnostics,
        "graph" => graph,
        "canUndo" => !isempty(session.history),
        "canRedo" => !isempty(session.future),
        "url" => session.url,
        "sceneCode" => _scene_to_julia(session.scene),
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
    return normalized
end

function _load_scene_file(path; allow_julia_eval::Bool)
    allow_julia_eval || error("Opening Julia Scene files is disabled for this editor session.")
    isfile(path) || error("Scene file `$(path)` does not exist.")
    module_name = Symbol("PlantSimEngineGraphRecovery_", string(time_ns(); base=16))
    workspace = Module(module_name)
    Core.eval(workspace, :(using PlantSimEngine))
    Base.include(workspace, path)
    isdefined(workspace, :scene) || error(
        "Scene file `$(path)` must assign its final Scene to `scene`.",
    )
    scene = getfield(workspace, :scene)
    scene isa PlantSimEngine.Scene || error(
        "Scene file `$(path)` assigned `scene` to `$(typeof(scene))`, expected `PlantSimEngine.Scene`.",
    )
    return scene
end

_state_json(session) = JSON.json(_state_payload(session))

function _editor_html(session)
    view = PlantSimEngine.scene_graph_view(session.scene)
    html = PlantSimEngine.scene_graph_view_html(view)
    config = replace(JSON.json(Dict("websocketUrl" => _websocket_url(session))), "</" => "<\\/")
    script = "<script type=\"application/json\" id=\"pse-editor-config\">$(config)</script>"
    return replace(html, "</head>" => "$(script)</head>")
end

function _scene_to_julia(scene)
    io = IOBuffer()
    diagnostics = String[]
    modules = _scene_code_modules(scene)
    for module_name in sort!(collect(modules))
        println(io, "using $(module_name)")
    end
    println(io)
    if !isnothing(scene.source_adapter)
        push!(diagnostics, "The Scene source_adapter is runtime-specific and is not reconstructed by generated code.")
    end
    for object in PlantSimEngine.scene_objects(scene)
        isnothing(object.applications) || object.applications == () || push!(
            diagnostics,
            "Object $(repr(object.id.value)) has object-local applications that are not represented separately.",
        )
    end
    for diagnostic in unique(diagnostics)
        println(io, "# WARNING: ", diagnostic)
    end
    isempty(diagnostics) || println(io)
    println(io, "objects = (")
    for object in PlantSimEngine.scene_objects(scene)
        println(io, "    ", _object_code(object), ",")
    end
    println(io, ")")

    templates = Any[]
    for instance in scene.instances
        any(template -> template === instance.template, templates) || push!(templates, instance.template)
    end
    for (index, template) in pairs(templates)
        println(io)
        println(io, "template_$(index) = ", _template_code(template))
    end

    if !isempty(scene.instances)
        println(io)
        println(io, "instances = (")
        for instance in scene.instances
            template_index = only(index for (index, template) in pairs(templates) if template === instance.template)
            println(io, "    ", _instance_code(instance, template_index), ",")
        end
        println(io, ")")
    else
        println(io)
        println(io, "instances = ()")
    end

    mounted_ids = Set{Symbol}()
    for instance in scene.instances
        union!(mounted_ids, PlantSimEngine._instance_application_ids(scene, instance))
    end
    global_applications = [
        application for application in scene.applications
        if PlantSimEngine._scene_edit_application_id(application) ∉ mounted_ids
    ]
    println(io, "applications = (")
    for application in global_applications
        println(io, "    ", _application_code(PlantSimEngine.as_model_spec(application)), ",")
    end
    println(io, ")")
    environment = isnothing(scene.environment) ? "nothing" : repr(scene.environment)
    print(io, "scene = Scene(objects...; applications=applications, instances=instances, environment=$(environment))")
    return String(take!(io))
end

function _scene_code_modules(scene)
    modules = Set{String}(["PlantSimEngine"])
    add_model = function (model)
        module_ = Base.moduleroot(parentmodule(typeof(model)))
        module_ in (Base, Core, Main) || push!(modules, string(nameof(module_)))
    end
    for application in scene.applications
        model = PlantSimEngine.model_(PlantSimEngine.as_model_spec(application))
        if model isa PlantSimEngine.ObjectModelOverrides
            add_model(model.base)
            foreach(add_model, values(model.overrides))
        else
            add_model(model)
        end
    end
    for instance in scene.instances
        for application in instance.template.applications
            add_model(PlantSimEngine.model_(PlantSimEngine.as_model_spec(application)))
        end
        foreach(add_model, values(instance.overrides))
        foreach(override -> add_model(override.model), instance.object_overrides)
    end
    return modules
end

function _object_code(object)
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
    return "Object($(repr(object.id.value)); $(join(keywords, ", ")))"
end

function _template_code(template)
    applications = join(
        ("        " * _application_code(PlantSimEngine.as_model_spec(application)) * "," for application in template.applications),
        "\n",
    )
    return "ObjectTemplate((\n$(applications)\n    ); kind=$(repr(template.kind)), species=$(repr(template.species)), parameters=$(repr(template.parameters)))"
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
    isnothing(override.process) || push!(options, "process=$(repr(override.process))")
    isnothing(override.application) || push!(options, "application=$(repr(override.application))")
    push!(options, "model=$(repr(override.model))")
    return "Override(; $(join(options, ", ")))"
end

function _application_code(spec)
    code = "ModelSpec($(repr(PlantSimEngine.model_(spec))); name=$(repr(PlantSimEngine.application_name(spec))))"
    selector = PlantSimEngine.applies_to(spec)
    isnothing(selector) || (code *= " |> AppliesTo($(repr(selector)))")
    isempty(keys(PlantSimEngine.value_inputs(spec))) ||
        (code *= " |> Inputs($(repr(PlantSimEngine.value_inputs(spec))))")
    isempty(keys(PlantSimEngine.model_calls(spec))) ||
        (code *= " |> Calls($(repr(PlantSimEngine.model_calls(spec))))")
    isnothing(spec.timestep) || (code *= " |> TimeStep($(repr(spec.timestep)))")
    return code
end

function _persist_scene!(session)
    code = _scene_to_julia(session.scene) * "\n"
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
        "scene.autosave.jl",
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
