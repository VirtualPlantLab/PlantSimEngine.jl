# Graph visualization and editing

`PlantSimEngine` can export a dependency graph view from a [`ModelMapping`](@ref). The static viewer is available from the core package and does not require any web server dependency.

```julia
using PlantSimEngine
using PlantSimEngine.Examples

mapping = ModelMapping(
    ToyLAIModel(),
    Beer(0.5);
    status=(TT_cu=1.0:200.0,),
)

write_graph_view("dependency_graph.html", mapping)
```

The same serialization path is used by the interactive editor. The editor is implemented as a Julia package extension, so the HTTP/WebSocket stack is loaded only when [`HTTP.jl`](https://github.com/JuliaWeb/HTTP.jl) is available and loaded in the active session.

```julia
using PlantSimEngine
using PlantSimEngine.Examples
using HTTP

mapping = ModelMapping(
    ToyLAIModel(),
    Beer(0.5);
    status=(TT_cu=1.0:200.0,),
)

session = edit_graph(mapping)
session.url
session
```

To start from a blank graph and build a mapping from scratch, omit the mapping:

```julia
session = edit_graph()
```

By default, `edit_graph` opens `session.url` in the system default browser. Pass `open_browser=false` to keep the session headless, for example in scripts or tests:

```julia
session = edit_graph(mapping; open_browser=false)
```

The browser sends edit commands to Julia over a WebSocket. Julia remains the source of truth: it applies the edit, rebuilds the [`ModelMapping`](@ref), recompiles graph diagnostics, and sends the updated graph back to the browser.

To stop the HTTP/WebSocket session, run:

```julia
close(session)
```

Use [`current_mapping`](@ref) to recover the latest mapping from the session:

```julia
edited_mapping = current_mapping(session)
close(session)
```

The web editor also exposes a dedicated "Mapping code" panel. It shows the current [`ModelMapping`](@ref) as Julia code, and can write that code to a `.jl` file so it can be copied/pasted or reused in scripts. The generated file is intentionally plain Julia: it imports the packages needed by the selected models and defines a top-level `mapping` variable:

```julia
using PlantSimEngine
using PlantSimEngine.Examples

mapping = ModelMapping(
    # ...
)
```

After writing a file once, every successful edit, undo, redo, or recent-file load automatically rewrites that same file. The session also keeps a recovery autosave in the temporary directory. The top-left "Open" button can reopen a mapping script from a file path or from the recent mapping list. Use git or another version-control system for mapping scripts that matter for a simulation workflow.

The editor extension currently supports the same edit operations as the Julia API:

- add, remove, and replace a model at a scale;
- update an existing model's parameter values, scale, or rate from the inspector;
- keep the model default rate, or set a custom `ClockSpec(dt, phase)` when adding a model;
- set a mapped input variable, either from the inspector or by drawing a connection from an output port to an input port;
- map a scalar source value or a vector of values from one or several source scales;
- mark or unmark a variable as [`PreviousTimeStep`](@ref);
- undo and redo edits inside the live session.

If `HTTP` is not loaded, `edit_graph(mapping)` throws an error explaining that the interactive editor requires `using HTTP`. Static graph visualization through [`write_graph_view`](@ref), `graph_view`, and [`graph_view_json`](@ref) remains available without loading `HTTP`.
