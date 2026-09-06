# New process or new model?

A **process** names a biological or physical question. A **model** is one
hypothesis or formulation used to answer it. For example, two photosynthesis
equations can belong to the same process even if they need different inputs.

Before creating a model, check whether the process already exists. That lets
users find your implementation beside the alternatives they may want to compare.

## Find the existing family

Load the package that provides the models. This example uses the teaching models
distributed with PlantSimEngine:

```@example choose_process
using PlantSimEngine
using PlantSimEngine.Examples

growth_models = Authoring.available_models(AbstractGrowthModel)
growth_models
```

For a scientific application, load its model package first and inspect its
documentation. `Authoring.available_processes()` lists the process types
available in the packages you have loaded. `Authoring.available_models(process_type)`
then lists the model types that implement that process.

Choose a model, give it a parameter value, and inspect its inputs and outputs:

```@example choose_process
candidate = ToyRUEGrowthModel(0.2)
(
    process=process(candidate),
    inputs=inputs(candidate),
    outputs=outputs(candidate),
)
```

[Loaded model catalog](@ref) explains discovery and inspection in more detail.
These functions only find packages loaded into Julia. Also check the package
you plan to use before concluding that a process is missing.

## Decide what your new equation changes

| Your change | What to create |
|---|---|
| Another equation, assumption, or level of detail for the same question | A model under the existing process |
| A distinct biological or physical question | A new process and its model |
| A conversion such as radiation per square metre to radiation per plant | A small conversion model, called an adapter |

Give alternative equations separate model types so users can select and test
them. To compare parameter values in the same equation, create instances of
that model with different parameters. Models in one process may need
different inputs, produce different outputs, or run at different frequencies.
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
and use it after `<:` in your model definition. This puts your model in the
same family as the existing alternatives.

The type above is only the beginning. It still needs input and output
declarations, descriptions of the variables' units and meaning, an equation,
and tests. Continue with
[Implement a basic model](@ref) to complete those steps.
