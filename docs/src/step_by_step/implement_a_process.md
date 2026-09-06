# New process or new model?

A **process** names a biological or physical question. A **model** is one
hypothesis or formulation used to answer it. For example, two photosynthesis
equations can belong to the same process even if they need different inputs.

Before creating a model, check whether the process already exists. That lets
users find your implementation beside the alternatives they may want to compare.

## Find the existing family

Load the package that owns the models. This example uses the teaching models
distributed with PlantSimEngine:

```@example choose_process
using PlantSimEngine
using PlantSimEngine.Examples

growth_models = Authoring.available_models(AbstractGrowthModel)
growth_models
```

For a scientific application, load its model package first and inspect its
documentation. `Authoring.available_processes()` lists the process types
visible in the loaded modules. `Authoring.available_models(process_type)`
then lists that family's concrete model types.

Choose a candidate and inspect an actual parameterized instance:

```@example choose_process
candidate = ToyRUEGrowthModel(0.2)
(
    process=process(candidate),
    inputs=inputs(candidate),
    outputs=outputs(candidate),
)
```

[Loaded model catalog](@ref) explains discovery and inspection in more detail.
Discovery only sees packages loaded into Julia; also check the target
package's source and documentation before concluding that a process is absent.

## Decide what your new equation changes

| Your change | What to create |
|---|---|
| Another equation, parameterization, assumption, or resolution for the same question | A concrete model under the existing process |
| A distinct biological or physical question | A new process and its model |
| A conversion of units, basis, or aggregation between models | An explicit adapter model |

Give alternative hypotheses separate model types so users can select and test
them. Models in one process may have different inputs, outputs, or cadences.
Use [Model compatibility and replacement](@ref) before substituting one.

## Declare a genuinely new process

This declaration creates a process for a teaching example of root exudation:

```@example choose_process
PlantSimEngine.@process "docs_root_exudation" verbose=false

struct DocsLinearExudation{T} <: AbstractDocs_Root_ExudationModel
    fraction::T
end

process(DocsLinearExudation(0.1))
```

`@process` creates the abstract type that concrete models inherit from:

| Declaration | Generated abstract type |
|---|---|
| `@process "growth"` | `AbstractGrowthModel` |
| `@process "light_interception"` | `AbstractLight_InterceptionModel` |

When another package already declares the process, import its abstract type
and subtype it. Avoid declaring a second identity with the same meaning.

The type above is only the beginning. It still needs input and output
declarations, scientific contracts, an equation, and tests. Continue with
[Implement a basic model](@ref) to complete those steps.
