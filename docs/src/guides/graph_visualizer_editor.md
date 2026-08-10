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
available in the static viewer. The topology projection includes model,
template, and instance containers; selecting an instance or object subtree scopes the
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

## Templates And Several Plants

A template is a reusable set of already coupled applications. Mounting the same
template twice creates two instance-local application sets. Unqualified selectors
remain inside their own plant, so a model in `plant_a` does not accidentally read
values from `plant_b`.

```julia
using Dates

plant_template = CompositeModelTemplate((
    ModelSpec(
        ToyDegreeDaysCumulModel();
        name=:degree_days,
        on=Many(scale=:Plant),
        every=Hour(1),
    ),
    ModelSpec(
        ToyLAIModel();
        name=:leaf_area,
        on=Many(scale=:Plant),
    ),
); kind=:plant, species=:oil_palm)

plant_a = ObjectInstance(
    :plant_a,
    plant_template;
    root=Object(:plant_a; name=:plant_a, scale=:Plant),
)
plant_b = ObjectInstance(
    :plant_b,
    plant_template;
    root=Object(:plant_b; name=:plant_b, scale=:Plant),
)

model = CompositeModel(plant_a, plant_b)
session = GraphEditor.edit_graph(
    model;
    templates=(oil_palm=plant_template,),
)
```

The **Add instance** wizard can mount a catalog template on an existing unclaimed
root and its descendants, or create a minimal root and mount the template in one
transaction. Preview the claimed subtree and resolved application targets before
committing. Unmounting removes the applications but keeps the object subtree.

Catalog templates are presets. The first edit to a mounted preset creates a
model-local replacement shared by all instances that currently use it. The original
preset remains available when adding another instance. Template application names
are fixed because they are part of the template contract.

## Overrides

Use an override when one plant or organ needs a different parameterization without
changing the shared template:

```julia
plant_b = ObjectInstance(
    :plant_b,
    plant_template;
    root=Object(:plant_b; name=:plant_b, scale=:Plant),
    overrides=(
        degree_days=ToyDegreeDaysCumulModel(T_base=12.0),
    ),
)
```

The editor offers the same operation at instance or object scope. Julia checks that
the replacement implements the same process and variable contract.

## Environment Catalogs And Routing

Environment values remain in Julia. Give the editor a named catalog rather than
serializing backends to the browser:

```julia
session = GraphEditor.edit_graph(
    model;
    templates=(oil_palm=plant_template,),
    environments=(
        weather=weather,
        canopy=canopy_backend,
    ),
)
```

The scene environment can be replaced from this catalog. Each application can use
the scene backend or a catalog backend and can configure `provider`, model-facing
input-to-source mappings, `sink`, and backend-specific typed options. The editor
shows `environment_hint(model)` and the effective compiled bindings read-only, then
asks Julia to validate the candidate routing before it is committed.

Application cadence and temporal windows use `Dates.Second`, `Dates.Minute`,
`Dates.Hour`, or `Dates.Day`. Whole-scene targeting is also explicit:
`SceneScope()` must be selected deliberately. Omitting the scope keeps a template
application local to each mounted instance.

## What Can Be Edited

The editor supports:

- model objects, metadata, status initialization, and parent topology;
- model applications, constructor parameters, target selectors, and cadence;
- explicit value bindings, hard calls, output routing, and update ordering;
- template catalogs, transactional instance mounting, shared template edits, and overrides;
- named scene and application environment backends, providers, sources, and sinks;
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
resources. Templates and instances are written inline. Named environment values are
referenced through an `editor_environments` named tuple, and the generated header
lists the keys that must be supplied when reopening the file:

```julia
session = GraphEditor.edit_graph(
    ;
    recover_path="model.jl",
    environments=(weather=weather, canopy=canopy_backend),
)
```

Missing environment keys fail while the file is opened. Review the generated code
and keep important scenario scripts under Git.
