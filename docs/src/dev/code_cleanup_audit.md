# Code Cleanup Audit

## Status

The compatibility cleanup is implemented on the `multi-plants` branch.

The package now has one scenario compiler and runtime: the composite-model/object API.
The following superseded implementations were removed rather than deprecated:

- `ModelList` and `SingleScaleModelSet`;
- `ModelMapping` and `MultiScaleModel`;
- `DependencyGraph`, `HardDependencyNode`, and `SoftDependencyNode`;
- `GraphSimulation` and the MTG mapping runner;
- mapping-specific multirate input resolution and output export;
- the unreleased domain prototype that preceded the composite-model/object API,
  including `Domain`, `SimulationMapping`, `Route`, `AllDomains`,
  `HardDomains`, and its separate scheduler, runtime, environment bridge, and
  output publisher;
- mapping-only initialization, dataframe, dimension, and topology helpers;
- unused parallel-executor traits after removal of the executor runtime;
- dead `UninitializedVar`, `RefVariable`, `TreeAlike`, and `StatusView` types;
- the unreleased `CompositeModelTemplate(...; mapping=...)` alias and legacy
  selector-to-mapping conversion helpers;
- compatibility tests, tutorials, and executable examples.

Migration details are retained in
[`migration_composite_model.md`](../migration_composite_model.md) and
[`release_notes_handoff.md`](release_notes_handoff.md).

## Current Ownership

| Concern | Owner |
| --- | --- |
| Object registry, selectors, compilation, execution, lifecycle | `src/composite_model_api.jl` |
| Model application configuration | `src/ModelSpec.jl` |
| Status and reference vectors | `src/component_models/Status.jl`, `src/component_models/RefVector.jl` |
| Dates-based clocks and policies | `src/time/multirate.jl`, `src/time/runtime/clocks.jl` |
| Weather sampling | `src/time/runtime/meteo_sampling.jl` |
| Environment backends | `src/time/runtime/environment_backends.jl` |
| Output request definition | `src/time/runtime/output_export.jl` |

## Remaining Review Rules

Future cleanup should reject:

- a second scenario/runtime abstraction parallel to `CompositeModel`;
- compatibility wrappers for unreleased APIs;
- package-specific behavior in PlantSimEngine;
- model kernels that know their scenario object, timestep, or coupling unless
  the scientific algorithm requires a hard call;
- dynamic per-object dispatch or copying in hot loops when compiled typed
  batches and reference carriers are available;
- undocumented public names or agent instructions that describe removed APIs.

## Verification

Current cleanup evidence:

- the `src` tree contains only the composite-model/object runtime and supporting status,
  time, environment, fitting, trait, and example files;
- empty directories left by removed subsystems were deleted;
- `git diff --check` passes;
- PlantSimEngine precompiles and loads from a clean Kaimon session;
- `test/test-unified-model-object-api.jl` passes 576 tests;
- the complete package environment passes 885 tests, including Aqua and
  doctests;
- `test/test-fitting.jl` passes;
- the documentation build passes, including executable examples and
  cross-reference checks;
- repository search finds no superseded scenario-runtime definitions or
  references in source, tests, examples, README, public docs, or the packaged
  agent skill;
- remaining `ModelMapping` and `MultiScaleModel` references outside
  development notes are migration text that explicitly points historical code
  to the composite-model/object API.
- repository search finds no `Domain`, `SimulationMapping`, `Route`,
  `AllDomains`, or `HardDomains` implementations, exports, tests, examples, or
  public documentation. The only remaining references are development/release
  notes that record their removal from this unreleased branch;
- ignored `.DS_Store` files were removed from the working tree outside `.git`.
- `ModelSpec` pipe-helper boilerplate was consolidated behind shared internal
  helpers while keeping the public `AppliesTo`, `Inputs`, `Calls`, `TimeStep`,
  `Environment`, `Updates`, and `OutputRouting` grammar unchanged.
- the duplicate `Advanced.TimeStepTable` export was removed from the PlantMeteo
  re-export block; `Advanced.TimeStepTable` remains exported once from the core status
  export list.
- stale `PlantSimEngine.Examples` exports for the deleted
  `ToyInternodeEmergence` example were removed.

Downstream verification:

- PlantBiophysics passes 117/117 tests against this working tree.
- XPalm's uncommitted CompositeModel/Object migration executes 74/75 assertions. The
  remaining assertion retains the removed runtime's first-step LAI value,
  while the explicit current dependency order produces zero from the initial
  zero-biomass leaf before plant/model aggregation. PlantSimEngine intentionally
  contains no package-specific compatibility workaround for that stale fixture.
