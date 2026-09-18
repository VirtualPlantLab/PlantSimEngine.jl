# Model catalog and related packages

Start with the scientific question you want to answer. The packages below
provide process models, whole-plant models, or tools for working with plant
structure and light. They cover different parts of a simulation and can help
you decide which models and data you need.

Once you have chosen a package, the second part of this page shows how to
find and inspect its PlantSimEngine models in Julia.

## Packages to explore

### PlantBiophysics.jl: leaf physiology

PlantBiophysics provides models of photosynthesis, stomatal conductance,
transpiration, and leaf energy balance. Use it to study how leaves respond
to their environment, for example how light, temperature, and humidity affect
carbon uptake and water loss. Its process models use PlantSimEngine for
coupling and execution.

[Documentation](https://vezy.github.io/PlantBiophysics.jl/dev/) ·
[Repository](https://github.com/VEZY/PlantBiophysics.jl)

### ArchimedLight.jl: light in a 3D scene

ArchimedLight computes radiation interception and scattering in scenes made
of 3D surfaces. Use it when the positions and shapes of organs matter for
shading and light absorption. These radiation calculations can supply the
light information needed by physiological models; ArchimedLight itself
focuses on light rather than photosynthesis or energy balance.

[Documentation](https://vezy.github.io/ArchimedLight.jl/dev/) ·
[Repository](https://github.com/VEZY/ArchimedLight.jl)

### PlantGeom.jl: plant structure and geometry

PlantGeom helps you read, build, and display plant structures and their 3D
geometry. It works with MultiScaleTreeGraph (MTG), which records organs and
their connections. Use `diagram` to view those connections, or `plantviz`
to display 3D meshes and colour them using simulated values. This is useful
for inspecting the plant on which your models run and presenting their results.

[Documentation](https://vezy.github.io/PlantGeom.jl/dev/) ·
[Repository](https://github.com/VEZY/PlantGeom.jl) ·
[Visualizing plant structure](../guides/multiscale/visualizing_structure.md)

### XPalm.jl: oil palm growth and yield

XPalm combines plant development, carbon assimilation and allocation, water
balance, and organ growth using PlantSimEngine. It provides an example of a
whole-plant model assembled from several processes. Its VPalm component can
add a 3D representation of the palm when the question requires plant
architecture.

[Documentation](https://palmstudio.github.io/XPalm.jl/dev/) ·
[Repository](https://github.com/PalmStudio/XPalm.jl)

### AMAPSim.jl: plant architecture and growth (prototype)

AMAPSim is a prototype for building and growing plant architectures. It
combines models of organ development and branching with PlantSimEngine,
records the plant structure in an MTG, and uses PlantGeom for 3D geometry.
It is under development, and its repository is currently private.

## Find models in your Julia session

PlantSimEngine can list models from packages already loaded in your Julia
session. It does not search all installed or available packages. These
functions find PlantSimEngine models; geometry and visualization tools are
documented by their own packages.

### Choose where to start

| You want to… | Start here |
|---|---|
| Learn the interface with small examples | `PlantSimEngine.Examples` and [one-object simulation](../journeys/users/one_object.md) |
| Write a new equation | [New process or new model?](@ref) |
| Compare two implementations | [Model compatibility and replacement](@ref) |

The `Toy...` models in these tutorials are teaching examples. Their presence
in a catalog does not establish scientific validation.

### List a process's models

After loading a package, list its process types with
`Authoring.available_processes()`. For a known process, request its models:

```@example loaded-model-catalog
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

Authoring.available_models(AbstractGrowthModel)
```

In your own session, load the relevant scientific package first. The table on
this website reflects the documentation build's session only.

### Inspect a model you might use

Construct a real model with explicit parameters. This avoids guessing the
defaults of a type that requires arguments.

```@example loaded-model-catalog
candidate = ToyRUEGrowthModel(0.2)
description = Authoring.describe_model(candidate)

(
    model=description.model_type,
    process=description.process,
    parameters=description.parameters,
    inputs=inputs(candidate),
    outputs=outputs(candidate),
)
```

Read the package documentation to understand the equations, parameter units,
assumptions, and conditions where the model has been tested. The report only
shows the information its author has supplied.

`variable_contracts(candidate)` shows the units and physical meaning recorded
for each variable. These declarations are called **variable contracts**. If
one side of a connection has a contract, the other side must have the same
one. Ask the model author to add missing declarations. If the quantities
differ, for example a value per plant and a value per ground area, use a
separate model to perform the conversion.

## Check whether a candidate fits your simulation

1. Confirm that its inputs can come from your data, environment, or other models.
2. Check that connected values have the same units, refer to the same area
   or object, and describe the same time period. Check whether each is a
   total, an average, or a rate.
3. Use `Authoring.compare_models(current, candidate)` when replacing a model.
4. Validate the assembled scenario with `Authoring.validate_scenario`, then
   check a small run against an expected result.

See [Coupling models](@ref) for connection choices and
[Model compatibility and replacement](@ref) for a complete comparison.

## Reference: models visible during this build

The following table is generated from the loaded modules. `complete=false`
means a type could not provide a complete description, for example because
it needs parameter values before it can be created. Create a model with those
parameters and inspect it before choosing it. The `provenance` column records
where the description came from: the author's declarations or information
found by examining the code. Detailed reports give this source for each field.

```@setup loaded-model-catalog
rows = NamedTuple[]
for process_type in Authoring.available_processes()
    for model_type in Authoring.available_models(process_type)
        model_description = Authoring.describe_model(model_type)
        push!(rows, (
            process=model_description.process,
            model=model_description.model_type,
            package=something(model_description.package, ""),
            complete=model_description.complete,
            provenance=model_description.provenance,
        ))
    end
end
catalog = DataFrame(rows)
sort!(catalog, [:package, :model])
```

```@example loaded-model-catalog
catalog
```

To reproduce this discovery yourself, loop over
`Authoring.available_processes()` and call
`Authoring.available_models(process_type)` for each process. Pass a concrete
model, such as `ToyRUEGrowthModel(0.2)`, to `Authoring.describe_model` for its
parameters, variables, physical meanings, and any problems found.
