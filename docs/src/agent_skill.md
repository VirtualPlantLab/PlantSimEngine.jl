# AI agent skill

PlantSimEngine includes an optional Codex/OpenAI-style skill for users who want an AI agent to help write simulations or implement models.

The skill file is stored in the repository at:

```text
skills/plantsimengine/SKILL.md
```

Use the copy shipped with the package version that Julia actually loaded:

```julia
using PlantSimEngine

package_root = pkgdir(PlantSimEngine)
skill_root = joinpath(package_root, "skills", "plantsimengine")
(Base.pathof(PlantSimEngine), Base.pkgversion(PlantSimEngine), skill_root)
```

Copy or link that complete `skills/plantsimengine` directory into the agent's
skill directory. Do not install a skill from a floating `main` branch for a
tagged or otherwise older package: its instructions may describe another API
generation. Updating the installed copy is an explicit user action.

The skill gives agents the package-specific conventions they need for:

- building object graphs with `CompositeModel`, `Object`, `CompositeModelTemplate`, and
  `ObjectInstance`;
- applying models with `ModelSpec` and `on`;
- coupling values and manual model calls with `inputs` and `calls`;
- using cached hard-call plans through bulk `run_call!`, singular `call_model`,
  and lifecycle-maintained object target buffers;
- configuring multirate simulations with `every`, `Dates.Period` values,
  and temporal policies;
- binding global or spatial microclimate through `Environment`;
- reasoning about model-clock weather aggregation, `environment_hint` reducers, and
  scenario source overrides;
- inspecting compiled scenarios with structured explanation helpers;
- reporting supplied, generated, bound, and unresolved variables with
  `Diagnostics.explain_initialization`;
- accessing the live model from lifecycle-capable kernels with
  `runtime_model(context)`;
- inspecting homogeneous runtime batches with `Diagnostics.explain_execution_plan`;
- collecting raw or requested model outputs with `outputs`,
  `OutputRequest`, `collect_outputs`, and `Diagnostics.explain_output_retention`;
- implementing or wrapping models with `@process`, `inputs_`, `outputs_`,
  `variable_contracts_`, `run!`, hard dependencies, and model traits;
- discovering, describing, comparing, and validating concrete models with
  `Authoring` before editing a scenario;
- validating incomplete scenarios through versioned, serializable authoring
  reports instead of inspecting compiler fields;
- checking `ModelDescription.field_provenance` so exact declarations are not
  confused with inferred, best-effort, or unavailable information.

The canonical source for a given package version is the local
`skills/plantsimengine/` directory below `pkgdir(PlantSimEngine)`. Its main
entry point is `SKILL.md`; its relative `references`, `assets`, and `scripts`
directories are part of the same versioned resource.

The main file is a short router. It loads focused references for model
authoring, scenario coupling, repository organization, dynamic models, or
diagnostics. Copyable fixtures live under `assets/`, including a complete
minimal model, compatible and incompatible alternatives, an explicit physical
adapter, and their tests. Run the canonical local check with:

```julia
include(joinpath(
    pkgdir(PlantSimEngine),
    "skills",
    "plantsimengine",
    "scripts",
    "check-examples.jl",
))
```

Agents should still inspect the local package code before making changes. The skill is a usage and modeling guide, not a replacement for the current API definitions in `src/`.
