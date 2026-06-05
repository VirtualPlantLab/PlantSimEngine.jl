# Code Cleanup Audit

This page records cleanup candidates found during the multi-domain experimental
branch audit. It is intentionally biased toward code health and release-note
planning rather than immediate implementation.

See also:

- `release_notes_handoff.md` for the consolidated release-note source.
- `unified_scene_object_design.md` for the planned breaking replacement of the
  current domain/route and multiscale-mapping split.
- `unified_scene_object_implementation_plan.md` for the implementation handoff
  of that future design.

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
| Done | `_resolve_input_windowed`, `_resolve_input_interpolate`, `_resolve_input_holdlast` | `src/time/runtime/input_resolution.jl` | Policy-specific wrappers now delegate to `_resolve_input_from_policy!`, with shared vector/scalar source lookup and policy-specific sampling dispatch. |
| Done | `_normalize_meteo_reducer`, `_resolve_window_reducer` | `src/time/runtime/meteo_sampling.jl`; `src/time/runtime/input_resolution.jl` | Merged through `_normalize_time_reducer(...; context=...)`. |
| Done | `validate_meteo_inputs(model_specs, meteo)` and `validate_meteo_inputs(model_specs, backend)` | `src/time/runtime/meteo_sampling.jl`; `src/time/runtime/environment_backends.jl` | Shared missing-row collection and diagnostic formatting through `_collect_missing_meteo_rows` and `_error_missing_meteo_inputs`. |
| Done | `_required_horizon_for_export_policy` and `_required_horizon_for_policy` | `src/time/runtime/output_export.jl`; `src/time/runtime/publishers.jl` | Export code now delegates to `_required_horizon_for_policy(policy, clock.dt, source_dt)`. |
| Done | `_normalize_meteo_window` and `_runtime_meteo_window` | `src/mtg/ModelSpec.jl`; `src/time/runtime/meteo_sampling.jl` | Runtime meteo-window normalization now calls `_normalize_meteo_window`. |
| Done | Domain environment helpers for single-status and graph domains | `src/domains/domain_simulation.jl` | Shared `EnvironmentSupport` construction, environment sampling, and scatter flow while keeping thin single-status and graph-domain entry points. |
| Done | `_should_visit_domain_node` and `_should_publish_domain_key` | `src/domains/domain_simulation.jl` | Extracted `_phase_allows_hard_parent` for the shared hard-domain phase rule. |
| Done | `Status` and `StatusView` Base interface methods | `src/component_models/Status.jl`; `src/component_models/StatusView.jl` | Shared small private helpers for values, tuple conversion, iteration, and indexed iteration while keeping storage-specific access and mutation methods separate. |
| Done | Tutorial helper functions repeated in toy multiscale examples | `examples/ToyMultiScalePlantTutorial/ToyPlantSimulation2.jl`; `examples/ToyMultiScalePlantTutorial/ToyPlantSimulation3.jl` | Extracted shared MTG navigation helpers to `examples/ToyMultiScalePlantTutorial/ToyPlantHelpers.jl` and included it with `@__DIR__` so tutorial scripts remain standalone. |
| Done | Test helper flows that run a graph simulation and compare outputs | `test/helper-functions.jl` | Shared `run_graphsim_for_comparison` for generated multiscale comparison and filtered-output comparison paths. |

## Backward Compatibility To Remove

This section is the release-note source list. Removing these items is breaking,
and some are still internal dependencies rather than shallow exported shims.

| Priority | Compatibility surface | Evidence | Migration note |
| --- | --- | --- | --- |
| Done | `ModelList` public API and legacy backing type | Formerly in `src/PlantSimEngine.jl`; `src/component_models/ModelList.jl`; `src/mtg/mapping/mapping.jl` | `ModelList` has been removed. Use `ModelMapping(model...; status=..., type_promotion=...)` for single-scale simulations. |
| Done | `run!(::ModelList, ...)` | Formerly in `src/run.jl` direct `ModelList` methods | `run!(::ModelList, ...)` has been removed. Wrap models in `ModelMapping` before running. |
| Done | Batch `run!` for collections of `ModelList` or single-scale mappings | Formerly in `src/run.jl` collection methods | Batch `run!([mapping1, mapping2], meteo)` and `run!(Dict(...), meteo)` are removed. Use an explicit loop or comprehension and call `run!` per mapping. |
| Done | `run!(mtg, mapping::AbstractDict, ...)` | Formerly in `src/run.jl` | Passing a raw `Dict` to multiscale `run!` is removed. Construct `ModelMapping(dict)` first, or use `ModelMapping(:Scale => models, ...)`. |
| Done | String scale names | `src/mtg/mapping/mapping.jl`; `src/mtg/MultiScaleModel.jl`; `src/mtg/model_spec_inference.jl`; `src/time/runtime/bindings.jl` | String scale names are removed. Use symbols everywhere, for example `:Leaf` instead of `"Leaf"`. |
| Done | `ModelMapping(Float64 => Float32)` as old type-promotion shorthand | Formerly in `src/mtg/mapping/mapping.jl` | `ModelMapping(Float64 => Float32)` is removed. Use `Dict(Float64 => Float32)` as the `type_promotion` value. |
| Done | Old output indexing helpers on multiscale output dictionaries | Formerly in `src/mtg/GraphSimulation.jl` | `outputs(out_dict, key)` and `outputs(out_dict, i)` are removed. Use `convert_outputs(out_dict, sink)` and index the converted table or dictionary explicitly. |

`ModelMapping{SingleScale}` now uses an internal single-scale backing container
instead of the removed public `ModelList` API.

## Non-Idiomatic Julia Patterns

| Priority | Pattern | Evidence | Recommended cleanup |
| --- | --- | --- | --- |
| Done | Source-side `@assert` used for user/data validation | Formerly in MTG initialization, mapping, output conversion, and save-result helpers | Converted to explicit `if` checks and `error` messages in this cleanup pass. Remaining `@assert` uses are limited to tests and documentation examples. |
| Done | `ModelSpec(model::AbstractModel)` checks `model isa MultiScaleModel`, which is effectively dead | `src/mtg/ModelSpec.jl` | Added an explicit `ModelSpec(::MultiScaleModel)` method and removed the dead branch from the `AbstractModel` constructor. |
| Done | `Symbol("")` sentinel for same-scale/no-op mappings | `src/mtg/MultiScaleModel.jl`; `src/mtg/mapping/mapping.jl`; `src/dependencies/dependency_graph.jl` | Replaced the magic sentinel with the typed `SameScale()` marker and reject `Symbol("")` in new mappings. |
| Done | Domain selector detection by type name | `src/dependencies/hard_dependencies.jl`; `src/domains/domain_simulation.jl` | Added `AbstractDomainDependencySelector`; `AllDomains` and `HardDomains` subtype it, and detection now uses the marker type instead of type-name reflection. |
| Done | Policy handling by large `isa` branch chains | `src/time/runtime/input_resolution.jl` | Input resolution now dispatches on policy type through `_resolved_policy_value_for_source` and `_resolve_input_for_policy!`, with shared source-resolution helpers. |
| Done | Scope selectors accept strings and hard-code built-in scale names | `src/time/runtime/scopes.jl`; `src/mtg/ModelSpec.jl` | Scope selectors now reject strings at construction and runtime callable results must return `ScopeId` or `Symbol`. Built-in selector symbols remain explicit and validated. |
| Done | Normalizer fallbacks return unknown values unchanged | `src/mtg/ModelSpec.jl` | Fallbacks for input bindings, meteo bindings, and output routing now fail at construction with explicit errors. String scope selectors now error instead of being converted. |
| Done | Broad `Any` and anonymous named tuples in runtime storage | `src/mtg/mapping/mapping.jl`; `src/mtg/GraphSimulation.jl`; `src/time/multirate.jl`; `src/time/runtime/output_export.jl` | Added semantic aliases for model-rate declarations and temporal streams, typed reverse multiscale mappings as `Symbol => Symbol`, and replaced anonymous export-plan named tuples with `OutputExportPlan`. Remaining `Any` storage is for user-provided values/statuses and open extension hooks. |
| Done | Awkward container signatures with broad `AbstractArray` / verbose `where` clauses | `src/dataframe.jl`; `src/checks/dimensions.jl` | Simplified collection signatures to `AbstractVector`/`AbstractDict` forms without unnecessary `where` wrappers. |

## Brittle Or Overloaded Code

| Priority | Location | Risk | Recommended cleanup |
| --- | --- | --- | --- |
| Done | `src/dependencies/soft_dependencies.jl` hard-dependency redirection | Nested hard-dependency redirection is duplicated, walks parents with a depth cap, and can match by process without enough scale context. | Extracted shared owner-resolution helpers for nested hard dependencies, with scale-aware matching, ambiguity checks, and finalized soft-node validation. |
| Done | `src/domains/domain_simulation.jl` runner | Scheduling, environment sampling/scattering, route materialization, output publication, graph runtime lifecycle, and post-scene run loops were mixed in one large file. | Split domain routes, route runtime, environment bridge, output publication, scheduler helpers, graph-domain runner lifecycle, and shared run-loop orchestration into focused `src/domains/*` modules while keeping public run entry points in `domain_simulation.jl`. |
| Done | `src/time/runtime/input_resolution.jl` fallback resolution | Same-node, ancestor, and candidate-scan fallback can silently change behavior when topology or scope changes. | Built a shared source-status resolver that centralizes same-node, ancestor, vector, and unique-candidate fallback with scalar ambiguity validation. |
| Done | `src/mtg/initialisation.jl` `RefVector` population | Vector input order depends on MTG traversal order and can drift after growth/removal. | Added `reindex_runtime_topology!` to sort statuses by MTG node id and rebuild downstream `RefVector`s from current statuses after initialization and topology mutations. |
| Done | `src/mtg/mapping/compute_mapping.jl` and `src/mtg/mapping/mapping.jl` mapping sentinels/invariants | Magic sentinel values make mapping control flow fragile. | Same-scale mappings now use `SameScale()` instead of `Symbol("")`; explicit validation rejects the old sentinel. |
| Done | Domain run order | Domain order is mostly declaration order with `kind == :scene` last. Route constraints are validated by producer position only. | Added a stable domain DAG scheduler with declaration-order tie-breaking, explicit scene-phase edges, route producer-target edges, and cycle diagnostics. |
| Done | `src/mtg/add_organ.jl` topology mutation | Add/remove/reparent updates local status and refs, but scope-derived temporal keys and environment indexes need centralized invalidation. | Add/remove/reparent now centralize runtime topology reindexing; reparent clears temporal state for the moved subtree before rebuilding status and `RefVector` indexes. |
| Done | `examples/maespa_domain_example.jl` scene model | The example mixes solver math, hard-domain target orchestration, publication, soil feedback, and carbon updates. | Split scene energy-balance solving, leaf publication/carbon update, and soil feedback into separate helpers; added tests for selector mismatch, convergence failure, publication counts, and soil feedback. |
| Done | `src/dependencies/is_graph_cyclic.jl` cycle keys | Cycle detection keys nodes by model value and scale, which can conflate reused model objects. | Traversal now uses dependency-node identity through `IdDict`; cycle reports are converted back to `(model => scale)` for existing diagnostics. |
| Done | `src/time/runtime/bindings.jl` and input binding inference | Producer candidates can lose renamed source-variable identity. | Added `ProducerVariable(input, source)` dependency metadata for renamed multiscale producers, and candidate inference now matches on the consumer input while returning the producer source variable. |

## Suggested Cleanup Order

All originally listed cleanup items are now marked done. Keep this page as the
release-note source list and add new rows only for newly discovered cleanup work.
