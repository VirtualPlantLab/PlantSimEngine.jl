abstract type AbstractGraphEditorSession end

function _graph_editor_missing_http()
    throw(ArgumentError("Interactive graph editing requires HTTP.jl. Load it with `using HTTP` before calling `edit_graph`."))
end

function edit_graph(args...; kwargs...)
    _graph_editor_missing_http()
end

function current_mapping(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end

function apply_edit!(session::AbstractGraphEditorSession, edit::AbstractGraphEdit)
    _graph_editor_missing_http()
end

function undo!(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end

function redo!(session::AbstractGraphEditorSession)
    _graph_editor_missing_http()
end
