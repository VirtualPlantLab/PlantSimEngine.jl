# Roadmap

This page summarizes work that is still in progress or intentionally left for
future releases. It is not a guarantee of delivery order.

## Current focus areas

### Multi-rate MTG simulations

Model-level varying timesteps are available experimentally for MTG simulations
through mapping-declared multi-rate execution and `ModelSpec` transforms such as
`TimeStepModel`, `InputBindings`, `OutputRouting`, and `ScopeModel`.

Known gaps in the current implementation:

- no sub-step execution below the meteorological base-step duration;
- no dedicated event scheduler for irregular or non-fixed calendar execution;
- no threaded or distributed multi-rate MTG execution path yet.

### Multi-plant and multi-species simulations

PlantSimEngine can already express multi-scale simulations, but practical support
for scenes containing several plants or several species with overlapping model
sets is still limited. Future work in this area is expected to focus on more
flexible mapping and parameter declaration.

## API and ergonomics

- a more consistent mapping API and clearer multiscale dependency declaration;
- improved user-facing errors and diagnostics;
- better dependency graph visualization and traversal helpers;
- broader examples for fitting, type conversion, and error propagation;
- clearer weather-data validation when a simulation requires meteorological inputs.

## Testing and release engineering

- broader downstream coverage and better release gating;
- additional checks for memory usage and type stability;
- state-machine or invariant-style validation for runtime outputs;
- graph fuzzing for multiscale corner cases.

## Lower-priority ideas

- API support for iterative construction and validation of `ModelMapping`;
- optional code-generation or build steps for validated mappings;
- improved parallel execution strategies;
- reintroducing multi-object parallelism in single-scale runs if the execution
  model can stay predictable and testable.

The full list of open issues is available on
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues).
