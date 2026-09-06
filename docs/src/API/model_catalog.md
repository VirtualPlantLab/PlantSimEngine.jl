# Loaded model catalog

Start with the scientific process you need, then choose a model and inspect
its requirements. PlantSimEngine can list models from packages already loaded
in your Julia session. It does not search all installed or available packages.

## Choose where to start

| You want to… | Start here |
|---|---|
| Learn the interface with small examples | `PlantSimEngine.Examples` and [one-object simulation](../journeys/users/one_object.md) |
| Work on leaf gas exchange or energy balance | [PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl) and its model documentation |
| Write a new equation | [New process or new model?](@ref) |
| Compare two implementations | [Model compatibility and replacement](@ref) |

The `Toy...` models in these tutorials are teaching examples. Their presence
in a catalog does not establish scientific validation.

## List a process's models

After loading a package, list its process types with
`Authoring.available_processes()`. For a known process, request its models:

```@example loaded-model-catalog
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

Authoring.available_models(AbstractGrowthModel)
```

In your own session, load the relevant scientific package first. The table on
this website reflects the documentation build's session only.

## Inspect a model you might use

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
