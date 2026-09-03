# New process or new model?

A process names a biological or physical question. A concrete model is one
hypothesis, formulation, or scale at which that process is computed. Make this
choice before writing the model type: it determines whether users can discover
your implementation beside existing alternatives.

## Prefer an existing process

Start by loading the packages that may own the process and inspect what they
declare:

```@example choose_process
using PlantSimEngine

Authoring.available_processes()
```

`Authoring.available_processes()` can only see loaded Julia modules. Search the source of
the target package as well before deciding that a process is missing. The
[Loaded model catalog](@ref) shows the same discovery result grouped into a
generated table with provenance and completeness.

Reuse an existing abstract process type when the new implementation answers
the same scientific question. Examples include two photosynthesis
formulations, a simple and a water-stress-aware radiation-use-efficiency model,
or the same process represented at different scales. Give each hypothesis its
own concrete model instead of adding a `method=:a_or_b` switch to one large
kernel.

Models in the same process form a scientific family, but they are not
necessarily interchangeable. They may require different inputs, produce
different outputs, use different clocks, or declare different
`VariableContract`s. See [Model compatibility and replacement](@ref) before
using one as an `Override` or replacing it without revisiting scenario
bindings.

## Declare a process only for a new meaning

Create a process when no existing process has the same biological or physical
meaning:

```@example choose_process
PlantSimEngine.@process "docs_root_exudation" verbose=false

abstract = AbstractDocs_Root_ExudationModel
abstract <: AbstractModel
```

The generated abstract type is formed by prefixing `Abstract`, preserving word
boundaries from the process name, and appending `Model`. For example:

| Declaration | Generated abstract type |
|---|---|
| `@process "growth"` | `AbstractGrowthModel` |
| `@process "light_interception"` | `AbstractLight_InterceptionModel` |

Concrete implementations subtype the generated abstract type:

```@example choose_process
struct DocsLinearExudation{T} <: AbstractDocs_Root_ExudationModel
    fraction::T
end

process(DocsLinearExudation(0.1))
```

The macro generates process identity and the abstract type; it does not choose
ports, units, parameters, defaults, equations, or scientific validation for
you. Continue with [Implement a basic model](@ref), which is the canonical
model-authoring path.

## A practical decision test

Ask these questions in order:

1. Is the quantity being simulated and its scientific meaning already
   represented by a loaded process?
2. Would users reasonably compare this implementation with the existing
   implementations as alternative hypotheses?
3. Is the difference only an equation, assumption, parameterization, scale, or
   resolution of that same question?

If the answers point to the same question, add a model to the existing
process. Create a new process only when the meaning itself changes. If the new
model changes units or basis while connecting two existing meanings, implement
an explicit adapter model instead; see [Coupling models](@ref).

## Without the macro

`@process` is a small convenience. The equivalent manual declaration is:

```@example choose_process
abstract type AbstractDocsManualRootExudationModel <:
              PlantSimEngine.AbstractModel end
PlantSimEngine.process_(
    ::Type{AbstractDocsManualRootExudationModel},
) = :docs_manual_root_exudation

struct DocsManualRootExudation <: AbstractDocsManualRootExudationModel end

manual_process = process(DocsManualRootExudation())
@assert manual_process == :docs_manual_root_exudation
manual_process
```

Prefer the macro for ordinary package code so process naming stays consistent.
