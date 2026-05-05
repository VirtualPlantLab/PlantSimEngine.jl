module PlantSimEngineGraphEditorExt

import HTTP
import JSON
import PlantSimEngine
import PlantSimEngine: edit_graph, current_mapping, apply_edit!, undo!, redo!

mutable struct GraphEditorSession{M,G,S} <: PlantSimEngine.AbstractGraphEditorSession
    mapping::M
    mtg::G
    history::Vector{M}
    future::Vector{M}
    server::S
    host::String
    port::Int
    url::String
    last_saved_path::Union{Nothing,String}
end

current_mapping(session::GraphEditorSession) = session.mapping
function Base.close(session::GraphEditorSession)
    isopen(session.server) || return nothing
    return HTTP.forceclose(session.server)
end

function Base.show(io::IO, session::GraphEditorSession)
    print(io, "GraphEditorSession(url=\"$(session.url)\", host=\"$(session.host)\", port=$(session.port))")
end

function Base.show(io::IO, ::MIME"text/plain", session::GraphEditorSession)
    println(io, "PlantSimEngineGraphEditorExt.GraphEditorSession")
    println(io, "  Open in browser: $(session.url)")
    println(io, "  Local state JSON: $(session.url)/state")
    println(io, "  Quit session: close(session)")
    println(io, "  Current mapping: current_mapping(session)")
    println(io, "  Save mapping code: use the \"Mapping code\" panel in the web editor")
end

current_mapping_code(session::GraphEditorSession) = _model_mapping_to_julia(session.mapping)

"""
    edit_graph(mapping; mtg=nothing, host="127.0.0.1", port=8765, open_browser=true)

Start a local graph editor session. The returned session owns the current
`ModelMapping`; call `current_mapping(session)` to recover the edited mapping.

Single-scale mappings are automatically normalized to multiscale form at the :Default scale.
By default, the session URL is opened with the system default browser. Pass
`open_browser=false` to disable this, for example in scripts or tests.

This method is provided by the `PlantSimEngineGraphEditorExt` package extension.
Load `HTTP` in the active session to make it available.
"""
function edit_graph(
    mapping::PlantSimEngine.ModelMapping;
    mtg=nothing,
    host::AbstractString="127.0.0.1",
    port::Integer=8765,
    open_browser::Bool=true,
)
    # Normalize single-scale to multiscale form for uniform handling downstream
    mapping = _normalize_to_multiscale(mapping)

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
        nothing,
    )
    session_ref[] = session
    open_browser && _open_in_default_browser(session.url)
    return session
end

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
        elseif action == "write_mapping_code"
            raw_path = get(command, "path", "")
            _write_mapping_code!(session, String(raw_path))
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
        timestep = _timestep_from_command(get(command, "timestep", nothing))
        if kind == "add_model"
            return PlantSimEngine.AddModel(Symbol(command["scale"]), model_type, parameters, timestep)
        end
        return PlantSimEngine.ReplaceModel(Symbol(command["scale"]), Symbol(command["process"]), model_type, parameters, timestep)
    end
    error("Unsupported graph edit kind `$kind`.")
end

function _timestep_from_command(timestep)
    isnothing(timestep) && return nothing
    timestep isa AbstractDict || error("Unsupported timestep payload `$(timestep)`.")
    mode = String(get(timestep, "mode", "default"))
    mode == "default" && return nothing
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
        "lastSavedPath" => session.last_saved_path,
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

_frontend_dist_dir() = normpath(joinpath(@__DIR__, "..", "frontend", "dist"))

function _write_mapping_code!(session::GraphEditorSession, raw_path::AbstractString)
    path = strip(String(raw_path))
    isempty(path) && error("The output path is empty. Provide a .jl file path.")
    full_path = isabspath(path) ? normpath(path) : normpath(joinpath(pwd(), path))
    mkpath(dirname(full_path))
    write(full_path, current_mapping_code(session) * "\n")
    session.last_saved_path = full_path
    return full_path
end

function _model_mapping_to_julia(mapping::PlantSimEngine.ModelMapping)
    io = IOBuffer()
    println(io, "mapping = ModelMapping(")
    for scale in keys(mapping)
        println(io, "    :$(scale) => (")
        for item in _scale_items(mapping[scale])
            println(io, "        $(_mapping_item_to_code(item)),")
        end
        println(io, "    ),")
    end
    print(io, ")")
    return String(take!(io))
end

_scale_items(entry) = entry isa Tuple ? entry : (entry,)

function _mapping_item_to_code(item)
    if item isa PlantSimEngine.ModelSpec || item isa PlantSimEngine.MultiScaleModel
        return _model_spec_to_code(PlantSimEngine.as_model_spec(item))
    end
    return repr(item)
end

function _model_spec_to_code(spec::PlantSimEngine.ModelSpec)
    code = "ModelSpec($(repr(PlantSimEngine.model_(spec))))"
    mapped_variables = PlantSimEngine.mapped_variables_(spec)
    isempty(mapped_variables) || (code *= " |> MultiScaleModel($(_mapped_variables_to_code(mapped_variables)))")
    isnothing(PlantSimEngine.timestep(spec)) || (code *= " |> TimeStepModel($(_timestep_to_code(PlantSimEngine.timestep(spec))))")
    return code
end

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
