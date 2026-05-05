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
```

Open `session.url` in a browser to use the live editor. The browser sends edit commands to Julia over a WebSocket. Julia remains the source of truth: it applies the edit, rebuilds the [`ModelMapping`](@ref), recompiles graph diagnostics, and sends the updated graph back to the browser.

Use [`current_mapping`](@ref) to recover the latest mapping from the session:

```julia
edited_mapping = current_mapping(session)
close(session)
```

The editor extension currently supports the same edit operations as the Julia API:

- add, remove, and replace a model at a scale;
- set a mapped input variable;
- mark or unmark a variable as [`PreviousTimeStep`](@ref);
- undo and redo edits inside the live session.

If `HTTP` is not loaded, `edit_graph(mapping)` throws an error explaining that the interactive editor requires `using HTTP`. Static graph visualization through [`write_graph_view`](@ref), `graph_view`, and [`graph_view_json`](@ref) remains available without loading `HTTP`.
