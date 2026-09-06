```@meta
CurrentModule = PlantSimEngine
```

# Visualize And Edit A CompositeModel

The graph shows which models run on which objects and how values pass between
them. For example, you can follow LAI from the model that calculates it to the
light model that uses it. Use the viewer to explore and share a graph, or the
editor to change your [`CompositeModel`](@ref) from the browser.

## A Small CompositeModel

This example applies three teaching models to one plant object. The
thermal-time model supplies `TT_cu` to the LAI model, which supplies `LAI` to
the light model. PlantSimEngine connects them using their matching input and
output names.

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
  src="../assets/model_graph_example.html"
  title="Interactive PlantSimEngine CompositeModel graph example"
  style="width: 100%; height: 720px; border: 1px solid #d8cdbc; border-radius: 6px;"
  loading="lazy">
</iframe>
```

Use the three views to explore the simulation:

- **Applications** shows one card for each configured use of a model, even
  when it runs on many leaves or plants.
- **Objects** shows the plant structure and groups of objects.
- **Executions** shows each model application on each object separately.

Select a card or connection to inspect its parameters, inputs, starting
values, and any problems found. Selecting a plant or a branch of the structure
filters the other views to those objects. Clear the filter to see the whole
simulation again. These controls also work in a saved, read-only viewer.

## Write A Static Viewer

The static visualizer is part of PlantSimEngine core and does not load a web
server:

```julia
path = GraphEditor.write_model_graph_view("model-graph.html", model)
```

The output includes the graph data and viewer code in one HTML file. It
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
read-only, but its views, search, details panel, and error reports are
interactive in the browser.

## Start The Editor

The editor needs the optional HTTP.jl package to communicate with Julia. Add
HTTP once to the project where you will use the editor:

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
URL and shutdown command. When you make an edit, the browser sends it to
Julia. Julia checks the proposed change before accepting it and sends the
updated graph back to the browser.

Inspect the current result or stop the server with:

```julia
edited_scene = GraphEditor.current_model(session)
close(session)
```

Call `GraphEditor.edit_graph()` without a CompositeModel to start from an empty scenario. Use
`open_browser=false` on remote machines or when a test controls the browser.

## Templates And Several Plants

A template is a reusable set of connected models. Applying the same template
to two plants gives each plant its own set of calculations. By default, the
models look for inputs within their own plant, so a model in `plant_a` does
not accidentally read values from `plant_b`.

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

Use **Add instance** to apply a template to an existing root object and its
descendants, provided they are not already part of another instance. You can
also create a new root and apply the template in one operation. Preview the
objects and model applications before accepting. Removing the template from
an instance removes its applications but keeps the objects.

Catalog templates are presets. The first edit to a mounted preset creates a
replacement within this simulation, shared by all instances that currently use it. The original
preset remains available when adding another instance. Template application names
cannot be changed; they identify the applications within the template.

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

The editor can replace a model for a whole plant instance or for an individual
object. Julia checks that the replacement describes the same process and has
compatible inputs, outputs, and other requirements.

## Environment Catalogs And Routing

Give the editor names for the environment sources it can use. The browser
shows these names; the weather data and other environment objects stay in Julia:

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

You can choose a new environment for the whole simulation or for one model
application. The settings include the source to read (`provider`), any
variable-name translations, and the destination for accepted updates (`sink`).
Other options depend on the environment source. The editor shows the model's
defaults from `environment_hint(model)` and its current environment
connections. Julia checks a proposed change before accepting it.

Model time steps and time windows use `Dates.Second`, `Dates.Minute`,
`Dates.Hour`, or `Dates.Day`. To select objects across the whole scene,
`SceneScope()` must be selected deliberately. Omitting the scope keeps a template
application local to each mounted instance.

## What Can Be Edited

The editor supports:

- objects, their labels and starting values, and their place in the structure;
- models, their parameters, which objects they run on, and their time steps;
- input connections, calls between models, saved outputs, and update order;
- templates, plant instances, and model replacements;
- environment sources and destinations for the scene or individual models;
- feedback loops, by choosing an input that should read the previous step;
- undo, redo, recovery files, and saving the simulation setup as Julia code.

When selecting objects or connecting inputs, preview the matching objects
before applying the change. This helps check selections such as `Many` and
`SelfPlant`, especially when the simulation contains several plants.

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

The `+` buttons next to inputs and outputs search by exact variable name. For an
input named `LAI`, the editor lists loaded models whose `outputs_` contains
`LAI`. For an output named `LAI`, it lists models whose `inputs_` contains
`LAI`, as well as compatible applications already present in the CompositeModel. This is
a way to find possible connections. You still need to check the units and
physical meaning of the values.

When the CompositeModel is saved as Julia code, required package imports are emitted for
the model types used by the CompositeModel.

## Invalid And Cyclic Composite Models

The editor can display an incomplete simulation and show its problems, even
when it cannot run yet. These include missing starting values, selections
that do not identify the intended objects, several models trying to set the
same output, and circular dependencies.

Connections in a circular dependency are shown in red. To break a loop, choose
which input should read the previous step's value. The editor also asks for
starting values if the objects do not have them. This change applies to every
object selected by that model application.

!!! warning
    `PreviousTimeStep` changes the calculation: the model reads an older value
    instead of the value calculated at the current step. Use it only when this
    delay and the starting value make sense for your scientific model.

## Saving And Recovery

The **Save** action writes readable Julia code ending with
`model = CompositeModel(...)`. Once a path is selected, every successful edit rewrites
that file. The editor also keeps a temporary recovery file and lists recent
CompositeModel scripts in **Open**.

The same core generator is available without starting the HTTP editor:

```julia
source = Authoring.scenario_source(
    model;
    environments=(weather=weather, canopy=canopy_backend),
)
```

Use this code to edit or share the simulation setup.
`Authoring.compiled_model_source(model)` provides a more detailed view of how
PlantSimEngine will run the calculations.

Some Julia values and external resources cannot be recreated automatically
from a saved script. Templates and instances are written into the script. Named environment values are
referenced through a `scenario_environments` named tuple, and the generated header
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
