# AI agent skill

PlantSimEngine includes an optional Codex/OpenAI-style skill for users who want an AI agent to help write simulations or implement models.

The skill file is stored in the repository at:

```text
skills/plantsimengine/SKILL.md
```

Users can download the `skills/plantsimengine` folder and tell their agent to
use the `plantsimengine` skill when working with PlantSimEngine.jl. The skill
gives agents the package-specific conventions they need for:

- building object graphs with `Scene`, `Object`, `ObjectTemplate`, and
  `ObjectInstance`;
- applying models with `ModelSpec` and `AppliesTo`;
- coupling values and manual model calls with `Inputs` and `Calls`;
- configuring multirate simulations with `TimeStep`, `Dates.Period` values,
  and temporal policies;
- binding global or spatial microclimate through `Environment`;
- reasoning about model-clock weather aggregation, `meteo_hint` reducers, and
  scenario source overrides;
- inspecting compiled scenarios with structured explanation helpers;
- inspecting homogeneous runtime batches with `explain_execution_plan`;
- collecting raw or requested scene outputs with `scene_outputs`,
  `OutputRequest`, `collect_outputs`, and `explain_output_retention`;
- implementing or wrapping models with `@process`, `inputs_`, `outputs_`,
  `run!`, hard dependencies, and model traits.

The superseded `ModelMapping` and `MultiScaleModel` runtimes have been removed.
Use [Migrating To The Scene/Object API](migration_scene_object.md) when
translating historical code.

The canonical source is [`skills/plantsimengine/SKILL.md`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/skills/plantsimengine/SKILL.md).

Agents should still inspect the local package code before making changes. The skill is a usage and modeling guide, not a replacement for the current API definitions in `src/`.
