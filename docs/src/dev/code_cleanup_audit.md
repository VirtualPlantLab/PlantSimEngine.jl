# Code Cleanup Audit

This page records cleanup candidates found during the multi-domain experimental
branch audit. It is intentionally biased toward code health and release-note
planning rather than immediate implementation.

Priority meanings:

- P0: architectural compatibility removal or high-impact breaking cleanup.
- P1: should be handled before stabilizing the new API.
- P2: useful cleanup with moderate risk or blast radius.
- P3: lower-risk cleanup or follow-up once nearby code is touched.

## Functions With Mergeable Intent

These functions are not always wrong as separate Julia methods. The cleanup
target is duplicated control flow, not legitimate multiple dispatch.

| Priority | Functions | Evidence | Recommended cleanup |
| --- | --- | --- | --- |
| P1 | `_resolve_input_windowed`, `_resolve_input_interpolate`, `_resolve_input_holdlast` | `src/time/runtime/input_resolution.jl` around lines 201, 314, and 391 | Keep policy-specific dispatch, but extract the common source-status resolution flow. Policy methods should only decide how to sample a resolved source. |
| P1 | `_normalize_meteo_reducer`, `_resolve_window_reducer` | `src/time/runtime/meteo_sampling.jl` around line 45; `src/time/runtime/input_resolution.jl` around line 114 | Merge into one reducer normalizer with a context argument for error messages. |
| P1 | `validate_meteo_inputs(model_specs, meteo)` and `validate_meteo_inputs(model_specs, backend)` | `src/time/runtime/meteo_sampling.jl` around line 130; `src/time/runtime/environment_backends.jl` around line 115 | Keep dispatch entry points, but share missing-row collection and diagnostic formatting. |
| P2 | `_required_horizon_for_export_policy` and `_required_horizon_for_policy` | `src/time/runtime/output_export.jl` around line 171; `src/time/runtime/publishers.jl` around line 84 | Use a single `_required_horizon_for_policy(policy, consumer_dt, source_dt)` helper. Export code can pass `clock.dt`. |
| P2 | `_normalize_meteo_window` and `_runtime_meteo_window` | `src/mtg/ModelSpec.jl` around line 270; `src/time/runtime/meteo_sampling.jl` around line 13 | Make runtime normalization call the `ModelSpec` normalizer or move both to one shared helper. |
| P2 | Domain environment helpers for single-status and graph domains | `src/domains/domain_simulation.jl` around lines 1478, 1491, 1523, and 1542 | Share `EnvironmentSupport` construction and scatter flow. Keep thin entry points for single-status vs graph-domain differences. |
| P2 | `_should_visit_domain_node` and `_should_publish_domain_key` | `src/domains/domain_simulation.jl` around lines 1601 and 1633 | Extract the shared hard-domain phase rule into one helper. |
| P3 | `Status` and `StatusView` Base interface methods | `src/component_models/Status.jl` around line 70; `src/component_models/StatusView.jl` around line 99 | Do not merge storage-specific methods blindly. If touched, share small private helpers for tuple/key iteration. |
| P3 | Tutorial helper functions repeated in toy multiscale examples | `examples/ToyMultiScalePlantTutorial/ToyPlantSimulation2.jl`; `examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl` | Merge only if examples no longer need to stay standalone. |
| P3 | Test helper flows that run a graph simulation and compare outputs | `test/helper-functions.jl` around lines 49 and 374 | Share a private test runner/comparator if test maintenance becomes painful. |

## Backward Compatibility To Remove

This section is the release-note source list. Removing these items is breaking,
and some are still internal dependencies rather than shallow exported shims.

| Priority | Compatibility surface | Evidence | Migration note |
| --- | --- | --- | --- |
| P0 | `ModelList` public API and legacy backing type | `src/PlantSimEngine.jl`; `src/component_models/ModelList.jl`; `src/mtg/mapping/mapping.jl` | `ModelList` has been removed. Use `ModelMapping(model...; status=..., type_promotion=...)` for single-scale simulations. |
| P0 | `run!(::ModelList, ...)` | `src/run.jl` around lines 139, 284, and 338 | `run!(::ModelList, ...)` has been removed. Wrap models in `ModelMapping` before running. |
| P1 | Batch `run!` for collections of `ModelList` or single-scale mappings | `src/run.jl` around lines 238 and 434; `test/test-simulation.jl` | Batch `run!([mapping1, mapping2], meteo)` and `run!(Dict(...), meteo)` are removed. Use an explicit loop or comprehension and call `run!` per mapping. |
| P1 | `run!(mtg, mapping::AbstractDict, ...)` | `src/run.jl` around line 609 | Passing a raw `Dict` to multiscale `run!` is removed. Construct `ModelMapping(dict)` first, or use `ModelMapping(:Scale => models, ...)`. |
| P1 | String scale names | `src/mtg/mapping/mapping.jl`; `src/mtg/MultiScaleModel.jl`; `src/mtg/model_spec_inference.jl`; `src/time/runtime/bindings.jl` | String scale names are removed. Use symbols everywhere, for example `:Leaf` instead of `"Leaf"`. |
| P2 | `ModelMapping(Float64 => Float32)` as old type-promotion shorthand | `src/mtg/mapping/mapping.jl` around line 381 | `ModelMapping(Float64 => Float32)` is removed. Use `Dict(Float64 => Float32)` as the `type_promotion` value. |
| P2 | Old output indexing helpers on multiscale output dictionaries | `src/mtg/GraphSimulation.jl` around line 144 | `outputs(out_dict, key)` and `outputs(out_dict, i)` are removed. Use `convert_outputs(out_dict, sink)` and index the converted table or dictionary explicitly. |

Important: full `ModelList` removal is the largest cleanup. `ModelMapping{SingleScale}`
currently delegates to it internally, so complete removal requires a replacement
single-scale backing path in `ModelMapping`, `run!`, dependency/status helpers,
output preallocation, and the domain runtime.

## Non-Idiomatic Julia Patterns

| Priority | Pattern | Evidence | Recommended cleanup |
| --- | --- | --- | --- |
| Done | Source-side `@assert` used for user/data validation | Formerly in MTG initialization, mapping, output conversion, and save-result helpers | Converted to explicit `if` checks and `error` messages in this cleanup pass. Remaining `@assert` uses are limited to tests and documentation examples. |
| P2 | `ModelSpec(model::AbstractModel)` checks `model isa MultiScaleModel`, which is effectively dead | `src/mtg/ModelSpec.jl` around lines 79 and 93 | Add a dedicated `ModelSpec(model::MultiScaleModel; ...)` method or remove the dead branch. |
| P2 | `Symbol("")` sentinel for same-scale/no-op mappings | `src/mtg/MultiScaleModel.jl` around line 201; `src/mtg/mapping/mapping.jl` around line 635 | Replace with `nothing` or a typed singleton such as `SameScale()`. |
| P2 | Domain selector detection by type name | `src/dependencies/hard_dependencies.jl` around line 8 | Use dispatch or a trait instead of `nameof(typeof(x)) in (...)`. |
| P2 | Policy handling by large `isa` branch chains | `src/time/runtime/input_resolution.jl` around lines 207, 320, 397, and 544 | Dispatch on policy type and share source-resolution helpers. |
| P3 | Scope selectors accept strings and hard-code built-in scale names | `src/time/runtime/scopes.jl` around lines 31, 63, and 78 | Prefer explicit selector objects/traits, or validate symbols at construction. |
| P3 | Normalizer fallbacks return unknown values unchanged | `src/mtg/ModelSpec.jl` around lines 230, 238, and 302 | Fallback methods should throw `ArgumentError`; support shorthands with explicit methods. |
| P3 | Broad `Any` and anonymous named tuples in runtime storage | `src/mtg/mapping/mapping.jl`; `src/mtg/GraphSimulation.jl`; `src/time/multirate.jl`; `src/time/runtime/output_export.jl` | Introduce small structs or type aliases for mapping metadata, temporal streams, and export plans. |
| P4 | Awkward container signatures with broad `AbstractArray` / verbose `where` clauses | `src/dataframe.jl`; `src/checks/dimensions.jl` | Prefer simpler signatures such as `AbstractVector{<:ModelMapping}` unless N-dimensional arrays are intentional. |

## Brittle Or Overloaded Code

| Priority | Location | Risk | Recommended cleanup |
| --- | --- | --- | --- |
| P1 | `src/dependencies/soft_dependencies.jl` hard-dependency redirection | Nested hard-dependency redirection is duplicated, walks parents with a depth cap, and can match by process without enough scale context. | Extract an owner-resolution helper keyed by `(scale, process)` or stable node identity, and validate ownership once. |
| P1 | `src/domains/domain_simulation.jl` runner | Scheduling, routing, environment sampling/scattering, graph runtime lifecycle, output publication, and post-scene phases are all mixed in one large file. | Split into domain scheduler, route materializer, environment bridge, graph-domain runner, and output publisher modules. |
| P2 | `src/time/runtime/input_resolution.jl` fallback resolution | Same-node, ancestor, and candidate-scan fallback can silently change behavior when topology or scope changes. | Build a shared source-status resolver with explicit cardinality outcomes and scalar-ambiguity validation. |
| P2 | `src/mtg/initialisation.jl` `RefVector` population | Vector input order depends on MTG traversal order and can drift after growth/removal. | Make ordering explicit, for example by node id or user-provided policy, and normalize after topology mutations. |
| P2 | `src/mtg/mapping/compute_mapping.jl` and `src/mtg/mapping/mapping.jl` mapping sentinels/invariants | Magic sentinel values make mapping control flow fragile. | Replace sentinels with typed mapping variants. Explicit validation now replaces the former source-side assertions. |
| P2 | Domain run order | Domain order is mostly declaration order with `kind == :scene` last. Route constraints are validated by producer position only. | Compile domains/routes into a small DAG scheduler and detect cycles/phase constraints explicitly. |
| P2 | `src/mtg/add_organ.jl` topology mutation | Add/remove/reparent updates local status and refs, but scope-derived temporal keys and environment indexes need centralized invalidation. | Centralize topology mutations around a single reindex/invalidation step. |
| P2 | `examples/maespa_domain_example.jl` scene model | The example mixes solver math, hard-domain target orchestration, publication, soil feedback, and carbon updates. | Split solver math from domain side effects and add tests for selector mismatch, convergence failure, publication counts, and post-scene feedback. |
| P3 | `src/dependencies/is_graph_cyclic.jl` cycle keys | Cycle detection keys nodes by model value and scale, which can conflate reused model objects. | Key traversal by `(scale, process)` or stable dependency-node identity. |
| P3 | `src/time/runtime/bindings.jl` and input binding inference | Producer candidates can lose renamed source-variable identity. | Preserve source variable in dependency metadata and return `(scale, process, source_var)` candidates. |

## Suggested Cleanup Order

1. Remove shallow compatibility shims that do not affect internals: raw dict
   multiscale `run!`, string scale names, old output indexing helpers, and old
   type-promotion shorthand.
2. Remove dead constructor branches and other shallow non-idiomatic API checks.
3. Refactor low-risk duplicated helpers: horizon policy, reducer normalization,
   meteo-window normalization, and domain phase predicates.
4. Refactor input-resolution source lookup behind tests.
5. Replace `ModelList` as the single-scale backing path.
6. Split the domain runner into scheduler, routes, environment, graph-domain,
   and publication modules.
