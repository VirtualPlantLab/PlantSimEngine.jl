module PlantSimEngineGraphEditorExt

import HTTP
import JSON
import PlantSimEngine
import PlantSimEngine: edit_graph, current_mapping, apply_edit!, undo!, redo!
import Random

mutable struct GraphEditorSession{M,G,S} <: PlantSimEngine.AbstractGraphEditorSession
    mapping::M
    mtg::G
    history::Vector{M}
    future::Vector{M}
    server::S
    host::String
    port::Int
    token::String
    url::String
    last_saved_path::Union{Nothing,String}
    save_target_path::Union{Nothing,String}
    autosave_path::Union{Nothing,String}
    last_autosaved_path::Union{Nothing,String}
    recent_file_path::String
    recent_mapping_paths::Vector{String}
end

current_mapping(session::GraphEditorSession) = session.mapping
function Base.close(session::GraphEditorSession)
    isopen(session.server) || return nothing
    return close(session.server)
end

function Base.show(io::IO, session::GraphEditorSession)
    print(io, "GraphEditorSession(url=\"$(session.url)\", host=\"$(session.host)\", port=$(session.port))")
end

function Base.show(io::IO, ::MIME"text/plain", session::GraphEditorSession)
    println(io, "PlantSimEngineGraphEditorExt.GraphEditorSession")
    println(io, "  Open in browser: $(session.url)")
    println(io, "  Local state JSON: $(_state_url(session))")
    println(io, "  Quit session: close(session)")
    println(io, "  Current mapping: current_mapping(session)")
    isnothing(session.save_target_path) || println(io, "  Auto-saving edits to: $(session.save_target_path)")
    isnothing(session.autosave_path) || println(io, "  Recovery autosave: $(session.autosave_path)")
    println(io, "  Save mapping code: use the \"Mapping code\" panel in the web editor")
end

current_mapping_code(session::GraphEditorSession) = _model_mapping_to_julia(session.mapping)

"""
    edit_graph([mapping]; mtg=nothing, host="127.0.0.1", port=8765, open_browser=true, autosave=true, allow_remote=false)

Start a local graph editor session. The returned session owns the current
`ModelMapping`; call `current_mapping(session)` to recover the edited mapping.
Call `edit_graph()` without a mapping to start from an empty scratch editor.

Single-scale mappings are automatically normalized to multiscale form at the :Default scale.
By default, the session URL is opened with the system default browser. Pass
`open_browser=false` to disable this, for example in scripts or tests.
The URL includes a session token and the server is restricted to localhost
unless `allow_remote=true` is passed explicitly.
When `autosave=true`, a recovery script is written to the temporary directory.
After saving through the web editor, every successful graph edit, undo, redo,
or recent-file load rewrites the saved Julia script.

This method is provided by the `PlantSimEngineGraphEditorExt` package extension.
Load `HTTP` in the active session to make it available.
"""
function edit_graph(
    mapping::PlantSimEngine.ModelMapping=_empty_editor_mapping();
    mtg=nothing,
    host::AbstractString="127.0.0.1",
    port::Integer=8765,
    open_browser::Bool=true,
    autosave::Bool=true,
    autosave_path::Union{Nothing,AbstractString}=nothing,
    recent_file_path::Union{Nothing,AbstractString}=nothing,
    allow_remote::Bool=false,
)
    if !_is_loopback_host(host) && !allow_remote
        error("Graph editor sessions are limited to localhost by default. Pass `allow_remote=true` only for a trusted network environment.")
    end

    # Normalize single-scale to multiscale form for uniform handling downstream
    mapping = _normalize_to_multiscale(mapping)

    session_ref = Ref{Any}()
    handler = http -> _handle_http(session_ref[], http)
    server = HTTP.listen!(handler, host, port; listenany=true, verbose=false)
    actual_port = HTTP.port(server)
    token = _session_token()
    session = GraphEditorSession(
        mapping,
        mtg,
        typeof(mapping)[],
        typeof(mapping)[],
        server,
        String(host),
        actual_port,
        token,
        "http://$(host):$(actual_port)/?token=$(token)",
        nothing,
        nothing,
        autosave ? _normalized_output_path(isnothing(autosave_path) ? _default_autosave_path() : autosave_path) : nothing,
        nothing,
        _normalized_output_path(isnothing(recent_file_path) ? _default_recent_file_path() : recent_file_path),
        _load_recent_mapping_paths(isnothing(recent_file_path) ? _default_recent_file_path() : recent_file_path),
    )
    session_ref[] = session
    _persist_session_mapping!(session; write_save_target=false)
    open_browser && _open_in_default_browser(session.url)
    return session
end

_session_token() = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))

function _is_loopback_host(host::AbstractString)
    value = lowercase(strip(String(host)))
    return value in ("127.0.0.1", "localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1")
end

_base_url(session::GraphEditorSession) = "http://$(session.host):$(session.port)"
_state_url(session::GraphEditorSession) = "$(_base_url(session))/state?token=$(session.token)"
_websocket_url(session::GraphEditorSession) = "ws://$(session.host):$(session.port)/ws?token=$(session.token)"

_empty_editor_mapping() =
    PlantSimEngine._build_model_mapping(PlantSimEngine.MultiScale, Dict{Symbol,Tuple}(); validated=false)

function _open_in_default_browser(url::AbstractString)
    try
        if Sys.isapple()
            run(`open $url`)
        elseif Sys.iswindows()
            run(`cmd /c start "" $url`)
        elseif !isnothing(Sys.which("xdg-open"))
            run(`xdg-open $url`)
        else
            @warn "Could not open graph editor automatically because no supported default-browser command was found." url
            return false
        end
        return true
    catch err
        @warn "Could not open graph editor automatically. Open the session URL manually." url exception = (err, catch_backtrace())
        return false
    end
end

function apply_edit!(session::GraphEditorSession, edit::PlantSimEngine.AbstractGraphEdit)
    updated_mapping = PlantSimEngine.apply_graph_edit(session.mapping, edit)
    push!(session.history, session.mapping)
    empty!(session.future)
    session.mapping = updated_mapping
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
    req = http.message
    path = HTTP.URI(req.target).path

    if HTTP.WebSockets.isupgrade(http.message)
        _authorized_request(session, req) || return _write_http_response(http, 403, ["Content-Type" => "text/plain; charset=utf-8"], "Forbidden graph editor session token.")
        _authorized_origin(session, req) || return _write_http_response(http, 403, ["Content-Type" => "text/plain; charset=utf-8"], "Forbidden graph editor websocket origin.")
        return HTTP.WebSockets.upgrade(http) do ws
            _handle_websocket(session, ws)
        end
    end

    response = if path == "/" || path == "/index.html" || path == "/state"
        _authorized_request(session, req) || return _write_http_response(http, 403, ["Content-Type" => "text/plain; charset=utf-8"], "Forbidden graph editor session token.")
        if path == "/state"
            (200, ["Content-Type" => "application/json"], _state_json(session))
        else
            (200, ["Content-Type" => "text/html; charset=utf-8"], _editor_html(session))
        end
    else
        (404, ["Content-Type" => "text/plain; charset=utf-8"], "Not found")
    end
    status, headers, body = response
    return _write_http_response(http, status, headers, body)
end

function _write_http_response(http::HTTP.Stream, status::Integer, headers, body::AbstractString)
    HTTP.setstatus(http, status)
    for header in headers
        HTTP.setheader(http, header)
    end
    HTTP.setheader(http, "Connection" => "close")
    HTTP.setheader(http, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(http)
    write(http, body)
    return nothing
end

function _authorized_request(session::GraphEditorSession, req)
    token = _request_token(req)
    return !isnothing(token) && token == session.token
end

function _request_token(req)
    header = HTTP.header(req, "X-PlantSimEngine-Graph-Token", "")
    isempty(header) || return String(header)
    return _query_param(String(req.target), "token")
end

function _query_param(target::AbstractString, name::AbstractString)
    query = String(HTTP.URI(target).query)
    isempty(query) && return nothing
    for part in split(query, '&')
        pair = split(part, '='; limit=2)
        length(pair) == 2 || continue
        first(pair) == name && return last(pair)
    end
    return nothing
end

function _authorized_origin(session::GraphEditorSession, req)
    origin = HTTP.header(req, "Origin", "")
    isempty(origin) && return true
    return String(origin) == _base_url(session)
end

"""
    _normalize_to_multiscale(mapping::PlantSimEngine.ModelMapping{PlantSimEngine.SingleScale})

Convert a single-scale ModelMapping to multiscale form at the :Default scale.
This ensures all downstream logic only deals with MultiScale mappings.
"""
function _normalize_to_multiscale(mapping::PlantSimEngine.ModelMapping{PlantSimEngine.SingleScale})
    entry = mapping[:Default]  # Returns tuple of (models..., status)
    return PlantSimEngine.ModelMapping(:Default => entry; check=true, type_promotion=PlantSimEngine.type_promotion(mapping))
end

function _normalize_to_multiscale(mapping::PlantSimEngine.ModelMapping{PlantSimEngine.MultiScale})
    # Already multiscale, return as is
    return mapping
end

function _handle_websocket(session::GraphEditorSession, ws)
    _websocket_send(ws, _state_json(session)) || return nothing
    try
        for message in ws
            command = JSON.parse(String(message))
            response = _handle_command!(session, command)
            _websocket_send(ws, JSON.json(response)) || return nothing
        end
    catch err
        _is_websocket_close_error(err) && return nothing
        _websocket_send(ws, JSON.json(_error_payload(err)))
    end
    return nothing
end

function _websocket_send(ws, payload::AbstractString)
    try
        HTTP.WebSockets.send(ws, payload)
        return true
    catch err
        _is_websocket_close_error(err) && return false
        rethrow()
    end
end

function _is_websocket_close_error(err)
    err isa EOFError && return true
    err isa Base.IOError && return true
    return false
end

function _handle_command!(session::GraphEditorSession, command)
    action = get(command, "action", "")
    try
        persist = false
        if action == "undo"
            undo!(session)
            persist = true
        elseif action == "redo"
            redo!(session)
            persist = true
        elseif action == "edit"
            edit = _edit_from_command(command)
            apply_edit!(session, edit)
            persist = true
        elseif action == "write_mapping_code"
            raw_path = get(command, "path", "")
            _write_mapping_code!(session, String(raw_path))
        elseif action == "open_mapping_code"
            raw_path = get(command, "path", "")
            _open_mapping_code!(session, String(raw_path))
            persist = true
        else
            error("Unsupported graph editor command action `$action`.")
        end
        diagnostics = persist ? _persist_session_mapping!(session) : String[]
        return _state_payload(session; ok=isempty(diagnostics), diagnostics=diagnostics)
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
    if kind == "update_model"
        model_type = _resolve_model_type(command["modelType"])
        parameters = _parameters_from_command(get(command, "parameters", Dict()))
        timestep = _timestep_from_command(get(command, "timestep", nothing); default_sentinel=true)
        return PlantSimEngine.UpdateModel(
            Symbol(command["scale"]),
            Symbol(command["process"]),
            Symbol(get(command, "targetScale", command["scale"])),
            model_type,
            parameters,
            timestep,
        )
    end
    kind == "set_mapped_variable" && return PlantSimEngine.SetMappedVariable(
        Symbol(command["scale"]),
        Symbol(command["process"]),
        Symbol(command["variable"]),
        Symbol(command["sourceScale"]),
        Symbol(command["sourceVariable"]),
        Symbol(get(command, "mode", "single")),
        Symbol.(get(command, "extraSourceScales", [])),
    )
    kind == "set_initialization" && return PlantSimEngine.SetStatusVariable(
        Symbol(command["scale"]),
        Symbol(command["variable"]),
        _parse_parameter_value(get(command, "value", Dict("type" => "julia", "value" => "nothing"))),
    )
    if kind in ("add_model", "replace_model")
        model_type = _resolve_model_type(command["modelType"])
        parameters = _parameters_from_command(get(command, "parameters", Dict()))
        timestep = _timestep_from_command(get(command, "timestep", nothing))
        if kind == "add_model"
            return PlantSimEngine.AddModel(Symbol(command["scale"]), model_type, parameters, timestep)
        end
        return PlantSimEngine.ReplaceModel(Symbol(command["scale"]), Symbol(command["process"]), model_type, parameters, timestep)
    end
    error("Unsupported graph edit kind `$kind`.")
end

function _timestep_from_command(timestep; default_sentinel::Bool=false)
    isnothing(timestep) && return nothing
    timestep isa AbstractDict || error("Unsupported timestep payload `$(timestep)`.")
    mode = String(get(timestep, "mode", "default"))
    mode == "default" && return (default_sentinel ? :default : nothing)
    mode == "clock" || error("Unsupported timestep mode `$mode`. Use `default` or `clock`.")
    dt = _parse_real(get(timestep, "dt", "1.0"))
    phase = _parse_real(get(timestep, "phase", "0.0"))
    return PlantSimEngine.ClockSpec(dt, phase)
end

_parse_real(value::Real) = Float64(value)
_parse_real(value) = parse(Float64, String(value))

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
    choice == :float && return parse(Float64, raw)
    choice == :integer && return parse(Int, raw)
    choice == :boolean && return parse(Bool, raw)
    choice == :symbol && return Symbol(raw)
    choice == :string && return String(raw)
    choice == :nothing && return nothing
    choice == :julia && return Core.eval(Main, Meta.parse(String(raw)))
    return raw
end

function _state_payload(session::GraphEditorSession; ok::Bool=true, diagnostics::Vector{String}=String[])
    graph = JSON.parse(PlantSimEngine.graph_view_json(session.mapping))
    isempty(get(graph, "scales", Any[])) && (graph["scales"] = ["Default"])
    append!(graph["diagnostics"], diagnostics)
    return Dict(
        "ok" => ok,
        "diagnostics" => diagnostics,
        "graph" => graph,
        "models" => [PlantSimEngine.model_descriptor(T) for T in PlantSimEngine.available_models()],
        "canUndo" => !isempty(session.history),
        "canRedo" => !isempty(session.future),
        "url" => session.url,
        "mappingCode" => current_mapping_code(session),
        "initializations" => _initialization_payload(session.mapping),
        "lastSavedPath" => session.last_saved_path,
        "saveTargetPath" => session.save_target_path,
        "autosavePath" => session.autosave_path,
        "lastAutosavedPath" => session.last_autosaved_path,
        "recentMappings" => session.recent_mapping_paths,
    )
end

_state_json(session::GraphEditorSession) = JSON.json(_state_payload(session))
_error_payload(err) = Dict("ok" => false, "diagnostics" => [sprint(showerror, err)])

function _editor_html(session::GraphEditorSession)
    react_html = _react_editor_html(session)
    isnothing(react_html) || return react_html

    graph_json = PlantSimEngine.graph_view_json(session.mapping)
    config_json = JSON.json(Dict("websocketUrl" => _websocket_url(session)))
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
<p>This live session is running. The React editor can connect to <code>$(_websocket_url(session))</code>.</p>
<p>Current graph state is available at <a href="$(_state_url(session))">/state</a>.</p>
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
    config_json = replace(JSON.json(Dict("websocketUrl" => _websocket_url(session))), "</" => "<\\/")

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

_frontend_dist_dir() = normpath(joinpath(@__DIR__, "..", "frontend", "dist"))

function _write_mapping_code!(session::GraphEditorSession, raw_path::AbstractString)
    path = strip(String(raw_path))
    isempty(path) && error("The output path is empty. Provide a .jl file path.")
    full_path = _normalized_output_path(path)
    _atomic_write(full_path, current_mapping_code(session) * "\n")
    session.last_saved_path = full_path
    session.save_target_path = full_path
    _remember_recent_mapping!(session, full_path)
    return full_path
end

function _open_mapping_code!(session::GraphEditorSession, raw_path::AbstractString)
    path = strip(String(raw_path))
    isempty(path) && error("The input path is empty. Provide a .jl file path.")
    full_path = _normalized_output_path(path)
    isfile(full_path) || error("No mapping code file exists at `$full_path`.")
    mapping = _mapping_from_julia_file(full_path)
    push!(session.history, session.mapping)
    empty!(session.future)
    session.mapping = _normalize_to_multiscale(mapping)
    session.save_target_path = full_path
    session.last_saved_path = full_path
    _remember_recent_mapping!(session, full_path)
    return session.mapping
end

function _mapping_from_julia_file(path::AbstractString)
    module_ = Module(gensym(:PlantSimEngineGraphEditorMapping))
    Core.eval(module_, :(using Base))
    Core.eval(module_, :(using PlantSimEngine))
    result = Core.eval(module_, Meta.parse("begin\n" * read(path, String) * "\nend"))
    mapping = isdefined(module_, :mapping) ? getfield(module_, :mapping) : result
    mapping isa PlantSimEngine.ModelMapping || (!isdefined(module_, :mapping) && error("Mapping code `$path` must define a top-level `mapping` variable."))
    mapping isa PlantSimEngine.ModelMapping || error("`mapping` in `$path` is a $(typeof(mapping)), not a PlantSimEngine.ModelMapping.")
    return mapping
end

function _persist_session_mapping!(session::GraphEditorSession; write_save_target::Bool=true)
    diagnostics = String[]
    if write_save_target && !isnothing(session.save_target_path)
        try
            _atomic_write(session.save_target_path, current_mapping_code(session) * "\n")
            session.last_saved_path = session.save_target_path
        catch err
            push!(diagnostics, "Could not auto-save mapping code to $(session.save_target_path): $(sprint(showerror, err))")
        end
    end
    if !isnothing(session.autosave_path)
        try
            _atomic_write(session.autosave_path, current_mapping_code(session) * "\n")
            session.last_autosaved_path = session.autosave_path
        catch err
            push!(diagnostics, "Could not write recovery autosave to $(session.autosave_path): $(sprint(showerror, err))")
        end
    end
    return diagnostics
end

function _atomic_write(path::AbstractString, content::AbstractString)
    full_path = _normalized_output_path(path)
    mkpath(dirname(full_path))
    tmp = tempname(dirname(full_path))
    try
        write(tmp, content)
        mv(tmp, full_path; force=true)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
    return full_path
end

function _normalized_output_path(path::AbstractString)
    stripped = strip(String(path))
    return isabspath(stripped) ? normpath(stripped) : normpath(joinpath(pwd(), stripped))
end

function _default_autosave_path()
    stamp = string(round(Int, time() * 1000))
    suffix = string(rand(UInt32); base=16)
    return joinpath(tempdir(), "PlantSimEngineGraphEditor", "session-$stamp-$suffix", "mapping.autosave.jl")
end

_default_recent_file_path() = joinpath(DEPOT_PATH[1], "config", "PlantSimEngine", "graph_editor_recent.json")

function _load_recent_mapping_paths(path::AbstractString)
    full_path = _normalized_output_path(path)
    isfile(full_path) || return String[]
    try
        payload = JSON.parse(read(full_path, String))
        values = payload isa AbstractDict ? get(payload, "paths", String[]) : payload
        return [String(item) for item in values if item isa AbstractString && isfile(String(item))]
    catch
        return String[]
    end
end

function _remember_recent_mapping!(session::GraphEditorSession, path::AbstractString)
    full_path = _normalized_output_path(path)
    filter!(item -> item != full_path, session.recent_mapping_paths)
    pushfirst!(session.recent_mapping_paths, full_path)
    length(session.recent_mapping_paths) > 10 && resize!(session.recent_mapping_paths, 10)
    _write_recent_mapping_paths(session)
    return session.recent_mapping_paths
end

function _write_recent_mapping_paths(session::GraphEditorSession)
    content = JSON.json(Dict("paths" => session.recent_mapping_paths))
    try
        _atomic_write(session.recent_file_path, content * "\n")
    catch err
        @warn "Could not update graph editor recent mappings." path = session.recent_file_path exception = (err, catch_backtrace())
    end
    return session.recent_file_path
end

function _initialization_payload(mapping::PlantSimEngine.ModelMapping)
    required_by_scale = _required_status_variables(mapping)
    payload = Any[]
    for scale in sort!(collect(keys(required_by_scale)); by=string)
        status = _scale_status(mapping, scale)
        for variable in sort!(collect(required_by_scale[scale]); by=string)
            value_payload = isnothing(status) || !(variable in keys(status)) ?
                            _status_value_payload(nothing; provided=false) :
                            _status_value_payload(status[variable]; provided=true)
            push!(
                payload,
                merge(
                    Dict(
                        "scale" => string(scale),
                        "name" => string(variable),
                    ),
                    value_payload
                )
            )
        end
    end
    return payload
end

function _scale_status(mapping::PlantSimEngine.ModelMapping, scale::Symbol)
    haskey(mapping, scale) || return nothing
    for item in _scale_items(mapping[scale])
        item isa PlantSimEngine.Status && return item
    end
    return nothing
end

function _status_value_payload(value; provided::Bool)
    choice, label = _status_value_choice(value, provided)
    return Dict(
        "value" => label,
        "type" => choice,
        "provided" => provided,
    )
end

_status_value_choice(::Nothing, provided::Bool) = provided ? ("nothing", "") : ("julia", "")
_status_value_choice(value::Bool, ::Bool) = ("boolean", string(value))
_status_value_choice(value::Integer, ::Bool) = ("integer", string(value))
_status_value_choice(value::AbstractFloat, ::Bool) = ("float", string(value))
_status_value_choice(value::Symbol, ::Bool) = ("symbol", string(value))
_status_value_choice(value::AbstractString, ::Bool) = ("string", String(value))
_status_value_choice(value, ::Bool) = ("julia", repr(value))

function _model_mapping_to_julia(mapping::PlantSimEngine.ModelMapping)
    io = IOBuffer()
    for statement in _using_statements(mapping)
        println(io, statement)
    end
    println(io)
    if isempty(keys(mapping))
        println(io, "# Add at least one model in the graph editor to generate a ModelMapping.")
        print(io, "# mapping = ModelMapping(...)")
        return String(take!(io))
    end
    required_status_variables = _required_status_variables(mapping)
    println(io, "mapping = ModelMapping(")
    for scale in keys(mapping)
        println(io, "    :$(scale) => (")
        items = _scale_items(mapping[scale])
        required = get(required_status_variables, scale, Set{Symbol}())
        for item in items
            code = _mapping_item_to_code(item, required)
            isnothing(code) && continue
            println(io, "        $(code),")
        end
        println(io, "    ),")
    end
    print(io, ")")
    return String(take!(io))
end

_scale_items(entry) = entry isa Tuple ? entry : (entry,)

function _using_statements(mapping::PlantSimEngine.ModelMapping)
    modules = Set{Module}([PlantSimEngine])
    for scale in keys(mapping)
        for item in _scale_items(mapping[scale])
            _collect_mapping_modules!(modules, item)
        end
    end
    return ["using $(_module_name(module_))" for module_ in sort!(collect(modules); by=_module_sort_key)]
end

function _collect_mapping_modules!(modules::Set{Module}, item)
    item isa PlantSimEngine.Status && return modules
    if item isa PlantSimEngine.ModelSpec || item isa PlantSimEngine.MultiScaleModel
        return _collect_spec_modules!(modules, PlantSimEngine.as_model_spec(item))
    end
    item isa PlantSimEngine.AbstractModel && return _collect_model_modules!(modules, item)
    return modules
end

function _collect_spec_modules!(modules::Set{Module}, spec::PlantSimEngine.ModelSpec)
    _collect_model_modules!(modules, PlantSimEngine.model_(spec))
    _collect_value_modules!(modules, PlantSimEngine.mapped_variables_(spec))
    _collect_value_modules!(modules, PlantSimEngine.timestep(spec))
    _collect_value_modules!(modules, spec.input_bindings)
    _collect_value_modules!(modules, spec.meteo_bindings)
    _collect_value_modules!(modules, spec.meteo_window)
    _collect_value_modules!(modules, spec.output_routing)
    _collect_value_modules!(modules, spec.scope)
    return modules
end

function _collect_model_modules!(modules::Set{Module}, model::PlantSimEngine.AbstractModel)
    module_ = parentmodule(typeof(model))
    module_ in (Base, Core, Main) || push!(modules, module_)
    return modules
end

function _collect_value_modules!(modules::Set{Module}, value)
    value === nothing && return modules
    if value isa Type
        module_ = parentmodule(value)
        module_ in (Base, Core, Main) || push!(modules, module_)
        return modules
    end
    module_ = parentmodule(typeof(value))
    module_ in (Base, Core, Main) || push!(modules, module_)
    if value isa Pair
        _collect_value_modules!(modules, first(value))
        _collect_value_modules!(modules, last(value))
    elseif value isa NamedTuple
        for item in values(value)
            _collect_value_modules!(modules, item)
        end
    elseif value isa Tuple || value isa AbstractArray
        for item in value
            _collect_value_modules!(modules, item)
        end
    end
    return modules
end

function _module_name(module_::Module)
    return join(string.(Base.fullname(module_)), ".")
end

function _module_sort_key(module_::Module)
    module_ === PlantSimEngine && return ""
    return _module_name(module_)
end

function _required_status_variables(mapping::PlantSimEngine.ModelMapping)
    stripped = Dict{Symbol,Any}()
    status_only_scales = Set{Symbol}()
    for scale in keys(mapping)
        items = [item for item in _scale_items(mapping[scale]) if !(item isa PlantSimEngine.Status)]
        if isempty(items)
            push!(status_only_scales, scale)
        else
            stripped[scale] = tuple(items...)
        end
    end

    required = isempty(stripped) ?
               Dict{Symbol,Vector{Symbol}}() :
               PlantSimEngine.to_initialize(PlantSimEngine.ModelMapping(stripped; check=true, type_promotion=PlantSimEngine.type_promotion(mapping)))

    required_by_scale = Dict{Symbol,Set{Symbol}}(
        scale => Set{Symbol}(variables)
        for (scale, variables) in pairs(required)
    )
    for scale in status_only_scales
        required_by_scale[scale] = Set{Symbol}()
        for item in _scale_items(mapping[scale])
            item isa PlantSimEngine.Status || continue
            union!(required_by_scale[scale], keys(item))
        end
    end
    return required_by_scale
end

function _mapping_item_to_code(item, required_status_variables=nothing)
    if item isa PlantSimEngine.Status
        return _status_to_code(item, required_status_variables)
    end
    if item isa PlantSimEngine.ModelSpec || item isa PlantSimEngine.MultiScaleModel
        return _model_spec_to_code(PlantSimEngine.as_model_spec(item))
    end
    return repr(item)
end

function _status_to_code(status::PlantSimEngine.Status, required_variables)
    isnothing(required_variables) && (required_variables = Set{Symbol}(keys(status)))
    kept = Pair{Symbol,Any}[
        name => status[name]
        for name in keys(status)
        if name in required_variables
    ]
    isempty(kept) && return nothing
    return "Status(" * join(("$(first(item)) = $(repr(last(item)))" for item in kept), ", ") * ")"
end

function _model_spec_to_code(spec::PlantSimEngine.ModelSpec)
    code = "ModelSpec($(repr(PlantSimEngine.model_(spec))))"
    mapped_variables = PlantSimEngine.mapped_variables_(spec)
    isempty(mapped_variables) || (code *= " |> MultiScaleModel($(_mapped_variables_to_code(mapped_variables)))")
    isnothing(PlantSimEngine.timestep(spec)) || (code *= " |> TimeStepModel($(_timestep_to_code(PlantSimEngine.timestep(spec))))")
    _is_empty_namedtuple(spec.input_bindings) || (code *= " |> InputBindings($(_julia_code(spec.input_bindings)))")
    _is_empty_namedtuple(spec.meteo_bindings) || (code *= " |> MeteoBindings($(_julia_code(spec.meteo_bindings)))")
    isnothing(spec.meteo_window) || (code *= " |> MeteoWindow($(_julia_code(spec.meteo_window)))")
    _is_empty_namedtuple(spec.output_routing) || (code *= " |> OutputRouting($(_julia_code(spec.output_routing)))")
    _is_default_scope(spec.scope) || (code *= " |> ScopeModel($(_julia_code(spec.scope)))")
    return code
end

_julia_code(value) = repr(value)
_is_empty_namedtuple(value) = value isa NamedTuple && isempty(keys(value))
_is_default_scope(scope) = scope == :global

function _timestep_to_code(timestep::PlantSimEngine.ClockSpec)
    return "ClockSpec($(repr(timestep.dt)), $(repr(timestep.phase)))"
end

_timestep_to_code(timestep) = repr(timestep)

function _mapped_variables_to_code(mapped_variables)
    isempty(mapped_variables) && return "[]"
    return "[" * join((_mapped_variable_to_code(i) for i in mapped_variables), ", ") * "]"
end

function _mapped_variable_to_code(mapping)
    lhs = first(mapping)
    rhs = last(mapping)
    lhs_code = _mapped_lhs_to_code(lhs)
    variable = _mapped_variable_symbol(lhs)
    rhs_code = _mapped_rhs_to_code(rhs, variable)
    return "$(lhs_code) => $(rhs_code)"
end

_mapped_variable_symbol(variable::Symbol) = variable
_mapped_variable_symbol(variable::PlantSimEngine.PreviousTimeStep) = variable.variable

_mapped_lhs_to_code(variable::Symbol) = string(":", variable)
_mapped_lhs_to_code(variable::PlantSimEngine.PreviousTimeStep) = "PreviousTimeStep(:$(variable.variable))"

function _mapped_rhs_to_code(rhs::Pair{Symbol,Symbol}, variable::Symbol)
    source_scale = first(rhs)
    source_variable = last(rhs)
    if source_scale == Symbol("")
        return "(Symbol(\"\") => :$(source_variable))"
    end
    if source_variable == variable
        return ":$(source_scale)"
    end
    return "(:$(source_scale) => :$(source_variable))"
end

function _mapped_rhs_to_code(rhs::AbstractVector{<:Pair{Symbol,Symbol}}, variable::Symbol)
    compact = all(last(i) == variable for i in rhs)
    if compact
        return "[" * join((":" * string(first(i)) for i in rhs), ", ") * "]"
    end
    return "[" * join(("(:$(first(i)) => :$(last(i)))" for i in rhs), ", ") * "]"
end

end
