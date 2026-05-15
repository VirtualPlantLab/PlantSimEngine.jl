# Graph visualization and editing

`PlantSimEngine` can display the dependency graph created from a [`ModelMapping`](@ref). Use it when you want to check which model computes which variable, inspect missing initial values, explain a model pipeline in documentation, or interactively build and revise a mapping.

There are two entry points:

- [`write_graph_view`](@ref) writes a standalone HTML viewer. This is available from `PlantSimEngine` itself and does not start a server.
- [`edit_graph`](@ref) starts a local browser editor. This is loaded by a Julia package extension when `HTTP.jl` is available and loaded in the session.

## Static graph viewer

The static viewer is the right tool for documentation, reports, or any read-only inspection. It contains the graph, search, the inspector, scale filters, relationship filters, and overview/detail modes, but it does not modify the [`ModelMapping`](@ref).

```@setup graph_viewer
using PlantSimEngine
using PlantSimEngine.Examples
```

Here is a small pedagogical mapping with three models:

```@example graph_viewer
mapping = ModelMapping(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5),
)
nothing # hide
```

The thermal time model computes `TT_cu`, the LAI model consumes `TT_cu` and computes `LAI`, and the Beer model consumes `LAI` and computes `aPPFD`. The generated viewer below is the same HTML file you would get by calling [`write_graph_view`](@ref):

```@raw html
<iframe
  src="../../www/simple_dependency_graph.html"
  style="width: 100%; height: 720px; border: 1px solid #d8cfc2; border-radius: 8px; background: #f7f0e7;"
  title="PlantSimEngine dependency graph example"
></iframe>
```

To write the viewer yourself:

```julia
using PlantSimEngine
using PlantSimEngine.Examples

mapping = ModelMapping(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.5),
)

write_graph_view("dependency_graph.html", mapping)
```

The returned file path is absolute, so you can print it, open it in a browser, or embed it in another documentation site.

## Interactive editor

The interactive editor uses the same graph JSON as the static viewer, but it keeps a WebSocket connection open to Julia. Julia remains the source of truth: the browser sends edit commands, Julia applies them to the [`ModelMapping`](@ref), recompiles graph diagnostics, and sends the updated graph back to the browser.

The editor is implemented as a package extension. Static graph files do not need `HTTP`, but the live editor does. In a project that only depends on `PlantSimEngine`, install `HTTP` first:

```julia
using Pkg
Pkg.add("HTTP")
```

Then load `HTTP` before calling [`edit_graph`](@ref):

```julia
using PlantSimEngine
using PlantSimEngine.Examples
using HTTP

mapping = ModelMapping(
    ToyLAIModel(),
    Beer(0.5);
    status=(TT_cu=1.0,),
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

The URL contains a session token and the server listens on `127.0.0.1` by default. Treat that URL as a local capability: anyone who can reach it can edit the live mapping. If you intentionally bind to another host, pass `allow_remote=true` only on a trusted network. Raw `julia` parameter values are disabled by default for remote sessions; pass `allow_julia_eval=true` only if you explicitly accept that risk.

To stop the HTTP/WebSocket session, run:

```julia
close(session)
```

Use [`current_mapping`](@ref) to recover the latest mapping from the session:

```julia
edited_mapping = current_mapping(session)
close(session)
```

!!! note
    If `HTTP` is not loaded, `edit_graph(mapping)` throws an error explaining that the interactive editor requires `using HTTP`. Static graph visualization through [`write_graph_view`](@ref), `graph_view`, and [`graph_view_json`](@ref) remains available without loading `HTTP`.

## What you can edit

The editor supports the same mapping operations as the Julia graph-edit API:

- add a model by choosing a scale, a model type, parameter values, and a rate;
- update an existing model's parameter values, scale, or rate from the inspector;
- remove a model from the inspector or from the selected model node;
- add new scales while configuring a model;
- set a mapped input variable from the inspector;
- draw a connection from an output port to an input port to create a mapping;
- map a scalar source value or a vector of values from one or several source scales;
- mark or unmark a variable as [`PreviousTimeStep`](@ref);
- use undo and redo inside the live session.

The `+` buttons beside variables are suggestions from the current model library:

- on an input, `+` lists models that can compute that variable as an output;
- on an output, `+` lists models that can consume that variable as an input.

Clicking a suggested model opens the add-model panel with that model preselected, so you can set its scale, parameters, and rate before adding it.

## Cycles

The simulation dependency graph must be acyclic when it runs. The viewer can still compile a non-throwing graph view for cyclic or incomplete mappings, so the editor can show the problem instead of failing immediately.

When a cycle is detected:

- cycle edges are drawn in red;
- the cycle call-to-action asks you to choose a break point in the graph;
- clicking the scissors button on a highlighted input wraps that input in [`PreviousTimeStep`](@ref).

This means the consumer model uses the variable value from the previous timestep, so that current-step dependency is removed and the graph can run again.

## Mapping code and saving

The web editor also exposes a dedicated "Mapping code" panel. It shows the current [`ModelMapping`](@ref) as Julia code, and can write that code to a `.jl` file so it can be copied/pasted or reused in scripts. The generated file is intentionally plain Julia: it imports the packages needed by the selected models and defines a top-level `mapping` variable:

```julia
using PlantSimEngine
using PlantSimEngine.Examples

mapping = ModelMapping(
    # ...
)
```

After writing a file once, every successful edit, undo, redo, or recent-file load automatically rewrites that same file. The session also keeps a recovery autosave in the temporary directory. The top-left "Open" button can reopen a mapping script from a file path or from the recent mapping list. Use git or another version-control system for mapping scripts that matter for a simulation workflow.

The `Status(...)` entries in generated code are rebuilt from the current mapping. Variables computed by models are omitted, even if they were present in the original status, and only variables still required for initialization are kept.

Because the generated script only defines `mapping`, users can include it directly from a simulation script:

```julia
include("mapping.generated.jl")
run!(mapping, meteo)
```

## Models from external packages

The editor does not use a separate model registry. It discovers models from the Julia session by traversing the loaded subtype tree under [`AbstractModel`](@ref).

This means packages become available when you load them:

```julia
using PlantSimEngine
using PlantSimEngine.Examples
using PlantBiophysics
using HTTP

session = edit_graph()
```

After `using PlantBiophysics`, the editor can list the process and model types that `PlantBiophysics` loaded into the session, provided those models follow the normal PlantSimEngine contract:

- process abstract types are subtypes of [`AbstractModel`](@ref);
- concrete model structs are subtypes of those process types;
- models define `inputs_` and `outputs_`;
- model parameters are stored in struct fields, with an optional zero-argument constructor for default values.

Constructor fields become parameter rows in the add-model and edit-model panels. For parametric models, fields that share the same type parameter also share the same type dropdown. The available parameter type choices are `float`, `integer`, `boolean`, `symbol`, `string`, `nothing`, and `julia`. Julia validates the final constructor call; if construction fails, the diagnostic is returned to the editor.

You can inspect the currently visible library from Julia:

```@example graph_viewer
available_models(:light_interception)
```

If a package is not loaded with `using PackageName`, its model types are not present in the Julia session and the editor cannot list them.

## Embedding a graph in package documentation

For package documentation built with Documenter, generate the HTML file before `makedocs` and place it somewhere under `docs/src`, for example `docs/src/www/model_graph.html`:

```julia
# docs/make.jl
using Documenter
using PlantSimEngine
using YourPackage

mapping = YourPackage.default_mapping()
write_graph_view(joinpath(@__DIR__, "src", "www", "model_graph.html"), mapping)

makedocs(;
    # ...
)
```

Then embed it from a markdown page:

```html
<iframe
  src="../../www/model_graph.html"
  style="width: 100%; height: 720px; border: 1px solid #d8cfc2; border-radius: 8px;"
  title="Model dependency graph"
></iframe>
```

Use the right relative path for the page where the iframe lives and remember that Documenter deploys pretty URLs by default. A page in `docs/src/multiscale/page.md` usually needs `../../www/model_graph.html`; a page at the root of `docs/src/` usually needs `www/model_graph.html`.

!!! tip
    This is the same pattern used to show large package mappings, such as the XPalm dependency graph, directly inside package documentation. The viewer is static, so it works on GitHub Pages without a Julia server.
