abstract type AbstractGraphEditorSession end

function _graph_editor_missing_http()
    throw(ArgumentError("Interactive graph editing requires HTTP.jl. Load it with `using HTTP` before calling `edit_graph`."))
end

"""
    edit_graph([mapping]; kwargs...)

Start an interactive graph editor session for a [`ModelMapping`](@ref), or
call `edit_graph()` with no mapping to start from a blank editor.

The HTTP-backed method is provided by the `PlantSimEngineGraphEditorExt`
package extension. Load `HTTP` in the active Julia session before calling this
function:

```julia
using PlantSimEngine
using HTTP

session = edit_graph(mapping)
blank_session = edit_graph()
```

Pass `open_browser=false` to keep the session headless.
"""
function edit_graph(args...; kwargs...)
    _graph_editor_missing_http()
end

"""
    current_mapping(session)

Return the current [`ModelMapping`](@ref) stored by an interactive graph editor
session.
"""
function current_mapping(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end

"""
    apply_edit!(session, edit)

Apply an [`AbstractGraphEdit`](@ref) to an interactive graph editor session and
return the rebuilt [`ModelMapping`](@ref).
"""
function apply_edit!(session::AbstractGraphEditorSession, edit::AbstractGraphEdit)
    _graph_editor_missing_http()
end

"""
    undo!(session)

Undo the latest edit in an interactive graph editor session and return the
current [`ModelMapping`](@ref).
"""
function undo!(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end

"""
    redo!(session)

Redo the latest undone edit in an interactive graph editor session and return
the current [`ModelMapping`](@ref).
"""
function redo!(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end
