module PlantSimEngineGraphEditor

import HTTP
import JSON
import PlantSimEngine

export GraphEditorSession, edit_graph, current_mapping, apply_edit!, undo!, redo!, close

mutable struct GraphEditorSession{M,G,S}
    mapping::M
    mtg::G
    history::Vector{M}
    future::Vector{M}
    server::S
    host::String
    port::Int
    url::String
end

current_mapping(session::GraphEditorSession) = session.mapping
Base.close(session::GraphEditorSession) = close(session.server)

"""
    edit_graph(mapping; mtg=nothing, host="127.0.0.1", port=8765)

Start a local graph editor session. The returned session owns the current
`ModelMapping`; call `current_mapping(session)` to recover the edited mapping.
"""
function edit_graph(mapping; mtg=nothing, host::AbstractString="127.0.0.1", port::Integer=8765)
    session_ref = Ref{Any}()
    handler = http -> _handle_http(session_ref[], http)
    server = HTTP.listen!(handler, host, port; listenany=true, verbose=false)
    actual_port = HTTP.port(server)
    session = GraphEditorSession(
        mapping,
        mtg,
        typeof(mapping)[],
        typeof(mapping)[],
        server,
        String(host),
        actual_port,
        "http://$(host):$(actual_port)",
    )
    session_ref[] = session
    return session
end

function apply_edit!(session::GraphEditorSession, edit::PlantSimEngine.AbstractGraphEdit)
    push!(session.history, session.mapping)
    empty!(session.future)
    session.mapping = PlantSimEngine.apply_graph_edit(session.mapping, edit)
    return session.mapping
end

function undo!(session::GraphEditorSession)
    isempty(session.history) && return session.mapping
    push!(session.future, session.mapping)
    session.mapping = pop!(session.history)
    return session.mapping
end

function redo!(session::GraphEditorSession)
    isempty(session.future) && return session.mapping
    push!(session.history, session.mapping)
    session.mapping = pop!(session.future)
    return session.mapping
end

function _handle_http(session::GraphEditorSession, http::HTTP.Stream)
    if HTTP.WebSockets.isupgrade(http.message)
        return HTTP.WebSockets.upgrade(http) do ws
            _handle_websocket(session, ws)
        end
    end

    req = http.message
    path = HTTP.URI(req.target).path
    response = if path == "/" || path == "/index.html"
        (200, ["Content-Type" => "text/html; charset=utf-8"], _editor_html(session))
    elseif path == "/state"
        (200, ["Content-Type" => "application/json"], _state_json(session))
    else
        (404, ["Content-Type" => "text/plain; charset=utf-8"], "Not found")
    end
    status, headers, body = response
    HTTP.setstatus(http, status)
    for header in headers
        HTTP.setheader(http, header)
    end
    HTTP.setheader(http, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(http)
    write(http, body)
    return nothing
end

function _handle_websocket(session::GraphEditorSession, ws)
    HTTP.WebSockets.send(ws, _state_json(session))
    try
        for message in ws
            command = JSON.parse(String(message))
            response = _handle_command!(session, command)
            HTTP.WebSockets.send(ws, JSON.json(response))
        end
    catch err
        HTTP.WebSockets.send(ws, JSON.json(_error_payload(err)))
    end
end

function _handle_command!(session::GraphEditorSession, command)
    action = get(command, "action", "")
    try
        if action == "undo"
            undo!(session)
        elseif action == "redo"
            redo!(session)
        elseif action == "edit"
            edit = _edit_from_command(command)
            apply_edit!(session, edit)
        else
            error("Unsupported graph editor command action `$action`.")
        end
        return _state_payload(session; ok=true)
    catch err
        return _state_payload(session; ok=false, diagnostics=[sprint(showerror, err)])
    end
end

function _edit_from_command(command)
    kind = get(command, "kind", "")
    kind == "mark_previous_timestep" && return PlantSimEngine.MarkPreviousTimeStep(
        Symbol(command["scale"]),
        Symbol(command["process"]),
        Symbol(command["variable"]),
    )
    kind == "unmark_previous_timestep" && return PlantSimEngine.UnmarkPreviousTimeStep(
        Symbol(command["scale"]),
        Symbol(command["process"]),
        Symbol(command["variable"]),
    )
    kind == "remove_model" && return PlantSimEngine.RemoveModel(
        Symbol(command["scale"]),
        Symbol(command["process"]),
    )
    kind == "set_mapped_variable" && return PlantSimEngine.SetMappedVariable(
        Symbol(command["scale"]),
        Symbol(command["process"]),
        Symbol(command["variable"]),
        Symbol(command["sourceScale"]),
        Symbol(command["sourceVariable"]),
        Symbol(get(command, "mode", "single")),
    )
    if kind in ("add_model", "replace_model")
        model_type = _resolve_model_type(command["modelType"])
        parameters = _parameters_from_command(get(command, "parameters", Dict()))
        if kind == "add_model"
            return PlantSimEngine.AddModel(Symbol(command["scale"]), model_type, parameters)
        end
        return PlantSimEngine.ReplaceModel(Symbol(command["scale"]), Symbol(command["process"]), model_type, parameters)
    end
    error("Unsupported graph edit kind `$kind`.")
end

function _resolve_model_type(label)
    for model_type in PlantSimEngine.available_models()
        string(model_type) == label && return model_type
        string(nameof(model_type)) == label && return model_type
    end
    error("No loaded PlantSimEngine model type matches `$label`. Load the package that defines it first.")
end

function _parameters_from_command(parameters)
    pairs = Pair{Symbol,Any}[]
    for (key, value) in parameters
        push!(pairs, Symbol(key) => _parse_parameter_value(value))
    end
    return (; pairs...)
end

function _parse_parameter_value(value)
    value isa AbstractDict || return value
    choice = Symbol(get(value, "type", "julia"))
    raw = get(value, "value", nothing)
    choice == :float && return Float64(raw)
    choice == :integer && return Int(raw)
    choice == :boolean && return Bool(raw)
    choice == :symbol && return Symbol(raw)
    choice == :string && return String(raw)
    choice == :nothing && return nothing
    choice == :julia && return Core.eval(Main, Meta.parse(String(raw)))
    return raw
end

function _state_payload(session::GraphEditorSession; ok::Bool=true, diagnostics::Vector{String}=String[])
    graph = JSON.parse(PlantSimEngine.graph_view_json(session.mapping))
    append!(graph["diagnostics"], diagnostics)
    return Dict(
        "ok" => ok,
        "graph" => graph,
        "models" => [PlantSimEngine.model_descriptor(T) for T in PlantSimEngine.available_models()],
        "canUndo" => !isempty(session.history),
        "canRedo" => !isempty(session.future),
        "url" => session.url,
    )
end

_state_json(session::GraphEditorSession) = JSON.json(_state_payload(session))
_error_payload(err) = Dict("ok" => false, "diagnostics" => [sprint(showerror, err)])

function _editor_html(session::GraphEditorSession)
    react_html = _react_editor_html(session)
    isnothing(react_html) || return react_html

    graph_json = PlantSimEngine.graph_view_json(session.mapping)
    config_json = JSON.json(Dict("websocketUrl" => "ws://$(session.host):$(session.port)/ws"))
    return """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PlantSimEngine Graph Editor</title>
<script type="application/json" id="pse-graph-data">$(graph_json)</script>
<script type="application/json" id="pse-editor-config">$(config_json)</script>
</head>
<body>
<main style="font:14px system-ui;padding:24px;max-width:960px;margin:auto">
<h1>PlantSimEngine Graph Editor</h1>
<p>This live session is running. The React editor can connect to <code>ws://$(session.host):$(session.port)/ws</code>.</p>
<p>Current graph state is available at <a href="/state">/state</a>.</p>
<pre id="graph" style="white-space:pre-wrap;background:#f6f7f8;padding:16px;border:1px solid #ddd;overflow:auto"></pre>
</main>
<script>
document.getElementById("graph").textContent = JSON.stringify(JSON.parse(document.getElementById("pse-graph-data").textContent), null, 2);
</script>
</body>
</html>
"""
end

function _react_editor_html(session::GraphEditorSession)
    assets_dir = _frontend_dist_dir()
    manifest_path = joinpath(assets_dir, ".vite", "manifest.json")
    isfile(manifest_path) || return nothing

    manifest = JSON.parse(read(manifest_path, String))
    entry = nothing
    for value in values(manifest)
        if get(value, "isEntry", false) == true
            entry = value
            break
        end
    end
    isnothing(entry) && (entry = get(manifest, "index.html", nothing))
    isnothing(entry) && return nothing

    js_file = get(entry, "file", nothing)
    isnothing(js_file) && return nothing
    css_files = get(entry, "css", Any[])
    js = read(joinpath(assets_dir, js_file), String)
    css = join([read(joinpath(assets_dir, css_file), String) for css_file in css_files], "\n")
    graph_json = PlantSimEngine.graph_view_json(session.mapping)
    config_json = replace(JSON.json(Dict("websocketUrl" => "ws://$(session.host):$(session.port)/ws")), "</" => "<\\/")

    return """
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>PlantSimEngine Graph Editor</title>
<script type="application/json" id="pse-graph-data">$(graph_json)</script>
<script type="application/json" id="pse-editor-config">$(config_json)</script>
<style>$(css)</style>
</head>
<body>
<div id="root"></div>
<script type="module">$(js)</script>
</body>
</html>
"""
end

_frontend_dist_dir() = normpath(joinpath(@__DIR__, "..", "..", "..", "frontend", "dist"))

end
