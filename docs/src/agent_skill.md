# AI agent skill

PlantSimEngine includes an optional Codex/OpenAI-style skill for users who want an AI agent to help write simulations or implement models.

The skill file is stored in the repository at:

```text
skills/plantsimengine/SKILL.md
```

Users can download the `skills/plantsimengine` folder and tell their agent to use the `plantsimengine` skill when working with PlantSimEngine.jl. The skill gives agents the package-specific conventions they need for:

- composing existing models with `ModelMapping`;
- declaring spatial multiscale mappings with scale symbols and `MultiScaleModel`;
- configuring multirate simulations with `ModelSpec`, `TimeStepModel`, `InputBindings`, and temporal policies;
- implementing or wrapping models with `@process`, `inputs_`, `outputs_`, `run!`, hard dependencies, and model traits.

The canonical source is [`skills/plantsimengine/SKILL.md`](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/skills/plantsimengine/SKILL.md).

Agents should still inspect the local package code before making changes. The skill is a usage and modeling guide, not a replacement for the current API definitions in `src/`.
