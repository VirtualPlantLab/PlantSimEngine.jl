# Public API Refinement Completion Audit

This audit records the supported contract and the evidence used to stabilize it.
It complements the [decision record](public_api_refinement_decisions.md) and the
[public symbol inventory](../API/public_symbols.md).

## Contract evidence

| Requirement | Supported contract | Evidence |
|:--|:--|:--|
| Public boundary | Composition, model-author, diagnostic, and extension symbols are exported by default; compiler/cache representations live under `PlantSimEngine.Advanced`. | `test-model-api-stabilization.jl` checks the namespace boundary; Documenter's missing-doc check covers exported docstrings. |
| Application identity | Repeated process applications require explicit names. Inputs, calls, outputs, overrides, and `Updates(...; after=...)` use canonical application IDs. Singular process references are rejected; `Many(process=...)` remains an explicit discovery query. | Stabilization, binding-inference, hard-call, output, override, and update tests cover repeated applications and actionable errors. |
| Selector grammar | `Self()` is one object, `Subtree()` is that object plus descendants, `SelfPlant()` is the containing plant, and `SceneScope()` is the model. `One`, `OptionalOne`, and `Many` share the same criteria across targeting, coupling, lookup, and outputs. | Multi-plant selector tests, instance/template tests, lifecycle tests, and XPalm downstream tests. |
| Outputs | `outputs=:none` is the safe default; `:all` and selector-based `OutputRequest`s are explicit. Request names are unique, application identity is preserved, and removed-object history remains collectable. | Output-boundary, runtime-matrix, multirate, lifecycle-history, and allocation tests. |
| Execution ownership | `run!` starts a fresh simulation; `continue!` and `step!` advance its live handle without resetting time, streams, schedules, or environment position. | Split-run equivalence, multirate-boundary, environment-resume, and lifecycle-continuation tests. |
| Construction and initialization | `CompositeModel(models...; status=...)` lowers to ordinary objects and `ModelSpec`s. `Diagnostics.explain_initialization` reports application, object, origin, defaults, expected/provided types, and remedies without running kernels. | Concise/explicit lowering equivalence and initialization report tests. |
| Diagnostics | Supported explanation functions accept `CompositeModel` directly and compiled views where useful; simulation overloads avoid field inspection. Results are structured vectors that can be filtered with ordinary Julia predicates. | Structured explanation assertions throughout the model test matrix and documentation examples. |
| Lifecycle | Registration, MTG growth, removal, reparenting, movement, and geometry updates are the supported mutation paths. Cycle/self-parent failures are atomic; structural and geometry invalidation remain targeted. | Stabilization, unified integration, environment, and lifecycle-output tests. |
| Model-author API | The kernel is `run!(model, status, environment, constants, context)`. Model parameters come from `model`; `runtime_model`, call-target accessors, traits, and lifecycle helpers are the supported context surface. | `test-model-contract.jl`, hard-call tests, growing-plant tutorial, and downstream model suites. |
| Compatibility | `tracked_outputs`, singular scenario `process=` references, output-request `process=`, and process-only overrides are removed. Mapping runtimes are not restored. | Migration guide plus rejection tests. |

## Validation matrix

The release gate is:

1. complete PlantSimEngine package tests, including allocation gates and doctests;
2. a full Documenter build with missing-doc and executable-example checks;
3. full PlantBiophysics and XPalm downstream suites against this checkout;
4. benchmark smoke tests for native, multirate, PlantBiophysics, and XPalm paths;
5. `git diff --check` and searches for transitional spellings outside explicit
   migration/history documentation.

This matrix covers one/many objects, all selector multiplicities, soft inputs,
hard calls, duplicate writers, temporal policies, global/spatial environments,
templates, instances, overrides, lifecycle mutation, generic values, output
retention modes, fresh/continued execution, and homogeneous hot-loop allocation.

## Deliberate compatibility boundary

Compiled structs and cache controls are qualified advanced APIs and may evolve.
Direct mutation of `Object` or `CompositeModel` fields is unsupported. Historical
`ModelMapping`, executor, and status-vector runtimes are outside the compatibility
surface and must not be reintroduced.
