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

Read the model's equations, assumptions, units, parameter meanings, domain of
validity, and validation evidence in its package documentation. The report can
expose declared metadata, but cannot supply missing scientific evidence.

`variable_contracts(candidate)` returns the declared physical meanings of its
variables. When a candidate has no contracts, that information remains
missing. Before using a model in a contracted connection, its author must
provide the matching declarations or an explicit physical adapter.

## Check whether a candidate fits your simulation

1. Confirm that its inputs can come from your data, environment, or other models.
2. Compare units, basis, timing, and aggregation at every connection.
3. Use `Authoring.compare_models(current, candidate)` when replacing a model.
4. Validate the assembled scenario with `Authoring.validate_scenario`, then
   check a small run against an expected result.

See [Coupling models](@ref) for connection choices and
[Model compatibility and replacement](@ref) for a complete comparison.

## Reference: models visible during this build

The following table is generated from the loaded modules. `complete=false`
means a type could not provide a complete description, for example because
it needs constructor arguments. Inspect a concrete instance before making
a choice. `provenance` distinguishes declared information from best-effort
inspection; detailed reports also record provenance field by field.

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
instance to `Authoring.describe_model` for its parameters, variables,
contracts, metadata, and diagnostic messages.
