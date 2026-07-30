```@meta
CurrentModule = PlantSimEngine
```

# Visualize And Edit A CompositeModel

The CompositeModel graph shows how model applications, objects, and compiled value
bindings fit together before a simulation runs. Use the static visualizer when
you want an inspectable HTML artifact, and the interactive editor when you want
browser actions to update a Julia [`CompositeModel`](@ref).

## A Small CompositeModel

This example applies three toy models to one plant object. The compiler infers
the same-object `TT_cu` and `LAI` bindings from the declared input and output
names.

```@example graph_viewer
using PlantSimEngine
using PlantSimEngine.Examples

model = CompositeModel(
    ToyDegreeDaysCumulModel(),
    ToyLAIModel(),
    Beer(0.6);
    status=(TT=12.0,),
    id=:plant,
    scale=:Plant,
    kind=:plant,
)

view = GraphEditor.model_graph_view(model)
view.metadata
```

The documentation build writes that graph as a self-contained HTML page and
embeds it below.

```@raw html
<iframe
  id="pse-model-graph-example"
  title="Interactive PlantSimEngine CompositeModel graph example"
  style="width: 100%; height: 720px; border: 1px solid #d8cdbc; border-radius: 6px;"
  loading="lazy">
</iframe>
<script>
  document.getElementById("pse-model-graph-example").src =
    `${documenterBaseURL}/assets/model_graph_example.html`;
</script>
```

The default **Applications** projection groups all concrete executions of one
application into one card. Use **Objects** to inspect topology and **Executions**
to inspect concrete `(application, object)` pairs. Search, diagnostics,
initialization, selectors, parameters, and resolved edge details remain
available in the static viewer. The topology projection includes model and
instance containers; selecting an instance or object subtree scopes the
application and execution projections until the filter is cleared.

## Write A Static Viewer

The static visualizer is part of PlantSimEngine core and does not load a web
server:

```julia
path = GraphEditor.write_model_graph_view("model-graph.html", model)
```

The output bundles the graph payload, JavaScript, and CSS in one HTML file. It
can be opened locally or embedded in Documenter documentation. A downstream
package can generate the file from `docs/make.jl` and place it under
`docs/src/assets`:

```julia
mkpath(joinpath(@__DIR__, "src", "assets"))
GraphEditor.write_model_graph_view(
    joinpath(@__DIR__, "src", "assets", "default_scene.html"),
    default_scene(),
)
```

Then embed it from a Markdown page with an HTML `iframe`. The graph is
read-only, but its projection controls, search, inspector, and diagnostics are
interactive in the browser.

## Start The Editor

The mutable editor is an optional package extension activated by HTTP.jl. Add
HTTP once to the environment that will launch the editor:

```julia
using Pkg
Pkg.add("HTTP")
```

Then start a session:

```julia
using PlantSimEngine
using HTTP

session = GraphEditor.edit_graph(model)
```

The default browser opens automatically. The returned session also prints its
URL and shutdown command. Julia remains authoritative: browser edits are sent
as semantic commands, applied transactionally to a candidate CompositeModel, compiled,
and returned as a fresh graph state.

Inspect the current result or stop the server with:

```julia
edited_scene = GraphEditor.current_model(session)
close(session)
```

Call `GraphEditor.edit_graph()` without a CompositeModel to start from an empty scenario. Use
`open_browser=false` on remote machines or when a test controls the browser.

## What Can Be Edited

The editor supports:

- model objects, metadata, status initialization, and parent topology;
- model applications, constructor parameters, target selectors, and cadence;
- explicit value bindings, hard calls, output routing, and update ordering;
- shared template applications plus instance-level and object-level overrides;
- dependency cycles through an explicit `PreviousTimeStep` break action;
- undo, redo, temporary recovery autosaves, and readable Julia CompositeModel scripts.

Application target and binding dialogs can ask Julia to preview the concrete
objects selected by a declaration. This is important for `Many`, relative
scopes such as `SelfPlant`, and composite models containing several plant instances.

## Models From Other Packages

The model browser reflects concrete `AbstractModel` subtypes currently loaded
in Julia. There is no separate registration API. Loading a model package before
starting the editor makes its models available automatically:

```julia
using PlantSimEngine
using PlantBiophysics
using HTTP

session = GraphEditor.edit_graph(model)
```

The `+` buttons next to ports use exact declared variable names only. For an
input named `LAI`, the editor lists loaded models whose `outputs_` contains
`LAI`. For an output named `LAI`, it lists models whose `inputs_` contains
`LAI`, as well as compatible applications already present in the CompositeModel. This is
a composition aid, not a scientific compatibility inference.

When the CompositeModel is saved as Julia code, required package imports are emitted for
the model types used by the CompositeModel.

## Invalid And Cyclic Composite Models

Simulation compilation remains strict, but graph compilation preserves as much
structure as possible and attaches diagnostics. This lets the editor display
incomplete selectors, missing initialization, ambiguous writers, and cycles.

Cycle edges are shown in red. The break workflow asks which consumer input
should read its previous accepted timestep value and asks for initial values
when the affected target objects do not already provide one. The action changes
the application input policy for every target selected by that application.

!!! warning
    `PreviousTimeStep` changes model semantics. It disconnects the selected
    input from current-step producers during one run step. Use it only when that
    lag and its initialization value are scientifically intentional.

## Saving And Recovery

The **Save** action writes readable Julia code whose final binding is
`model = CompositeModel(...)`. Once a path is selected, every successful edit rewrites
that file. The editor also keeps a temporary recovery file and lists recent
CompositeModel scripts in **Open**.

Generated code is best effort for arbitrary Julia values and external runtime
resources. Review the code and keep important scenario scripts under Git.
