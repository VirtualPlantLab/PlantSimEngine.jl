# Release Notes Handoff

This page is the persistent release-note source for work done during the
multi-domain and cleanup branch. Keep it factual: mark what is implemented,
what is removed, and what is only planned.

## Implemented Breaking Cleanup

Source details live in `code_cleanup_audit.md`.

- Removed public `ModelList` usage. Use `ModelMapping(model...; status=...)`
  for single-scale simulations.
- Removed direct `run!(::ModelList, ...)`; wrap models in `ModelMapping`.
- Removed batch `run!` over collections/dictionaries of single-scale mappings;
  use explicit loops or comprehensions.
- Removed raw `Dict` multiscale `run!(mtg, dict, ...)`; construct
  `ModelMapping(dict)` first.
- Removed string scale names. Use symbols, for example `:Leaf`.
- Removed `ModelMapping(Float64 => Float32)` promotion shorthand. Use a
  `Dict(Float64 => Float32)` as the `type_promotion` value.
- Removed old multiscale output indexing helpers. Convert outputs explicitly
  before indexing.
- Replaced the `Symbol("")` same-scale sentinel with `SameScale()`.
- Replaced many source-side validation `@assert`s with explicit errors.
- Added `Updates(:var; after=:process)` for ordered duplicate writers.

## Implemented Multi-Domain / Scene Prototype Features

These features exist in the current prototype, but may be replaced by the
unified scene/object API in a future breaking pass.

- `Domain`, `SimulationMapping`, `DomainSimulation`, and `DomainModelKey`.
- Single-status and MTG-backed domains.
- Domain selectors that can select one or more MTG subtree roots.
- Domain-local and global status views:
  `status(sim, :plant_A, :Leaf)` and `status(sim, :Leaf)`.
- Multi-rate domain execution using `Dates` periods.
- `AllDomains(...)` stream/value dependencies.
- `Route(...)` materialization with `ManyToOneVector`,
  `ManyToOneAggregate`, and limited `OneToManyBroadcast` graph support.
- `HardDomains(...)`, `dependency_targets`, `ModelTarget`, and
  `run_target!` for manually controlled hard-domain calls.
- Environment backend protocol:
  `AbstractEnvironmentBackend`, `GlobalConstant`, `EnvironmentSupport`,
  `sample_environment`, `scatter!`, `update_index!`, `get_nsteps`, and
  `base_step_seconds`.
- `meteo_inputs_` and `meteo_outputs_` declarations and validation.
- Dynamic MTG add/remove/reparent runtime reindexing.
- Domain explanation helpers:
  `explain_domains`, `explain_domain_models`, `explain_domain_statuses`,
  `explain_schedule`, `explain_domain_dependencies`, and `explain_routes`.

## Implemented MAESPA-Style Example Changes

The current `examples/maespa_domain_example.jl` is the main executable example
for multi-plant scene coupling.

- Uses copied PlantBiophysics subsample models:
  `Monteith`, `Fvcb`, and `Tuzet`.
- Uses two MTG-backed plant domains with different parameters and shared scale
  names such as `:Plant` and `:Leaf`.
- Uses a shared soil model.
- Uses `SceneEB` with `ModelSpec(...) |> Calls(...)` to manually run leaf
  `:energy_balance` and soil `:soil_water` targets through the current
  hard-domain bridge.
- Ports MAESPA-style canopy air temperature and VPD update through
  `tvpdcanopcalc` and `gbcanms`.
- Treats input meteorology as above-canopy forcing and writes below-canopy
  microclimate to scene status fields:
  `canopy_tair`, `canopy_vpd`, `canopy_rh`, `canopy_htot`, and
  `canopy_gcanop`.
- Adds `LAIModel` and declares plant leaf-area materialization with
  `ModelSpec(...) |> Inputs(...)`, bridged internally to the current route
  runtime.
- Computes plant allocation daily from plant-local `leaf_carbon` vectors.
- Adds `run_call!` as the unified scene/object spelling for manually executing
  current `ModelTarget` call handles.
- Adds model-level `Input(...)` and `Call(...)` dependency defaults through
  `dep(model)`, with scenario-level `Inputs(...)` and `Calls(...)` overriding
  those defaults in `ModelSpec`.
- Adds initial registry-backed scene selector resolution with
  `resolve_object_ids` and `resolve_objects` for global, self-relative,
  plant-relative, ancestor-relative, and named-scope object selections.
- Adds `explain_scopes(scene)` for structured scope diagnostics. It reports
  the scene scope, object subtree scopes, named `Scope(...)` entries, and
  scale/kind/species label groups with concrete object ids.
- Adds the first compiled scene/object view with `compile_scene`,
  `CompiledScene`, `CompiledSceneApplication`, `CompiledSceneInputBinding`,
  `CompiledSceneCallBinding`, `explain_scene_applications`,
  `explain_bindings`, and `explain_calls`.
- The compiled scene view resolves `AppliesTo(...)`, `Inputs(...)`, and
  `Calls(...)` to object ids ahead of runtime, and reports temporal policy,
  window, carrier hints, and callee application ids for agent-readable
  diagnostics.
- Unscoped scene/object dependency selectors now infer scope from the consumer:
  scene consumers default to `SceneScope()`, while non-scene consumers default
  to `Self()`. Cross-scope shared dependencies, such as leaf models reading
  soil state, should use `within=SceneScope()` explicitly.
- Adds status-backed compiled input carriers for the scene/object view:
  scalar shared refs, homogeneous `RefVector`s, and `ObjectRefVector` fallback
  carriers. `input_carrier`, `input_value`, and `has_reference_carrier` expose
  them for tests, diagnostics, and future runtime execution.
- `explain_bindings` now reports stable carrier kind and copy/reference
  semantics, making reference-wired inputs and materialized temporal values
  explicit for users and agents.
- Adds scene binding cache helpers:
  `refresh_bindings!`, `bindings_dirty`, `compiled_bindings`, and
  `scene_revision`. Object registration, removal, and reparenting invalidate
  cached compiled bindings before the next refresh.
- Adds scene/object environment binding cache helpers:
  `refresh_environment_bindings!`, `compile_environment_bindings`,
  `CompiledEnvironmentBinding`, `CompiledEnvironmentBindings`,
  `environment_bindings_dirty`, `compiled_environment_bindings`,
  `environment_revision`, and `explain_environment_bindings`.
- Adds `geometry`, `position`, and `bounds` accessors for scene objects/statuses.
  Environment binding refreshes call `update_index!(backend, entities)` before
  binding objects to backend cells/layers, so spatial backends can precompute
  scene-wide lookup structures.
- Object movement now invalidates environment bindings without rebuilding the
  structural object/model binding cache.
- Adds public geometry lifecycle helpers:
  `update_geometry!(scene, object, geometry; invalidate_environment=true)` and
  object-scoped `mark_environment_binding_dirty!(scene, object)`. They
  currently invalidate the scene environment binding cache and leave room for
  finer-grained dirty tracking later.
- Adds the first scene/object runtime with `run!(scene; steps=...)`.
  It materializes compiled `Inputs(...)` carriers, samples bound environment
  inputs, and executes generic model kernels on object `Status` values.
- Scene/object compiler now infers simple same-object value bindings from
  `inputs_`/`outputs_` when one producer is unambiguous. `explain_bindings`
  reports each binding origin, including `:declared` and
  `:inferred_same_object`.
- Compiled input bindings now validate `Inputs(...)` `process=`/`application=`
  filters when they are provided, and `explain_bindings` reports
  `source_application_ids`, `process`, and `application`.
- `compile_scene` now errors for required `inputs_(model)` variables that are
  neither bound through `Inputs(...)`/inference nor present on the target object
  `Status`.
- `compile_scene` now rejects `Inputs(...)` entries whose receiving variable is
  not declared by the model's `inputs_`, making binding typos explicit at
  compile time.
- `compile_scene` now validates status-backed non-temporal `Inputs(...)`
  source availability, so bindings that select existing source objects but no
  source `Status` reference fail at compile time instead of becoming no-ops.
- Scene/object runtime now publishes model outputs to scene-local temporal
  streams and resolves temporal `Inputs(...)` with `HoldLast`, `Integrate`,
  and `Aggregate` policies before consumer execution.
- Scene/object runtime now scatters values declared by `meteo_outputs_(model)`
  back to the bound environment backend after each model call, using the
  existing `scatter_environment_outputs!` backend protocol.
- Scene/object root applications now honor `TimeStep(...)` values backed by
  `Dates.Period` scheduling. `explain_schedule` reports normalized clocks and
  whether an application is root-scheduled or manual-call-only.
- Scene/object execution now uses a stable topological application order
  compiled from `Inputs(...)` producer edges and `Updates(...)` ordering.
  Dependencies on manual-call-only applications are redirected to their parent
  caller, same-timestep cycles fail during compilation, and
  `explain_schedule` reports `execution_index`.
- `CompiledScene` now pre-indexes input and call bindings by application and
  object id. Runtime input materialization and hard-call lookup no longer scan
  all scene bindings for every object/model invocation.
- `CompiledScene` now pre-indexes applications by application id, removing
  application scans from hard-call target resolution and dictionary rebuilding
  from ordered execution setup.
- `CompiledEnvironmentBindings` now pre-indexes environment bindings by
  application and object id, removing the scene-wide binding scan from
  environment sampling and output scattering.
- Adds `SceneRunContext` and `SceneCallTarget`; scene/object models can use
  `dependency_target(s)(extra, :name)` plus `run_call!` for manual
  `Calls(...)` execution.
- Applications selected by `Calls(...)` are skipped by the root
  `run!(scene)` loop and execute only through explicit `run_call!`, preserving
  parent-controlled hard-call execution.
- Adds scene/object duplicate-writer validation in `compile_scene`. A variable
  may have only one canonical writer per object unless later writers declare
  `Updates(:var; after=...)`, where `after` can match a previous application
  id/name or process.
- Adds `explain_writers(compiled)` to report object-variable writer groups,
  duplicate writers, and the `Updates(...)` declarations that validate ordered
  updates.
- Adds the first reusable object-template path with `ObjectTemplate` and
  `ObjectInstance`. Templates bundle reusable `ModelSpec`s and default
  `kind`/`species` labels; instances mount them inside a named object subtree.
- `Scene(...)` accepts mounted instances whose roots are either owned objects
  or references to separately supplied scene objects.
- Template applications are scoped to their instance and receive stable
  instance-prefixed application ids. Unmodified instances share the template's
  model objects, while instance overrides can replace one application by name
  or process when the replacement implements the same process.
- Adds `Override(...)` and `ObjectInstance(...; object_overrides=...)` for
  exceptional organs. Overrides are resolved during compilation to concrete
  object ids without splitting the logical application or changing its
  dependency bindings.
- Template models, template parameter metadata, and replacement models are
  retained by reference. The runtime does not copy models or mutate fields to
  apply parameter overrides.
- Override validation requires the same process and declared status/environment
  variable names. Application explanations report model storage, dispatch
  mode, overridden object ids, and replacement model types.
- Adds `explain_instances(scene)` and instance membership in
  `explain_objects(scene)`. Instance rows expose roots, current object
  membership, mounted applications, overrides, template labels, and
  reference-based parameter ownership.
- Objects created below a mounted instance inherit missing template `kind` and
  `species` labels. Membership explanations use the current topology rather
  than a copied instance object list.

## Planned Future Breaking Redesign

The target design is documented in:

- `unified_scene_object_design.md`
- `unified_scene_object_implementation_plan.md`

Expected future migration:

- model mappings should be described as model applications:
  `ModelSpec(model; name=...) |> AppliesTo(...) |> Inputs(...) |> Calls(...)`;
- `MultiScaleModel(...)` -> `Inputs(...)`.
- `Route(...)` for normal value coupling -> consumer-side `Inputs(...)`.
- `AllDomains(...)` selectors -> object selectors inside `Inputs(...)`.
- `HardDomains(...)` -> `Calls(...)`.
- `dep(model)` remains the model-level trait for default dependency intent:
  defaults can become `Input(...)` value bindings or `Call(...)` manual model
  calls, and scenario-level `ModelSpec` configuration overrides them.
- `Domain(...)` as user-facing assembly -> scene object templates and
  instances.
- model target scales/domains -> `AppliesTo(...)` object selectors.
- `InputBindings(...)` -> source, policy, and window information on
  `Inputs(...)`.
- `MeteoBindings(...)` and `MeteoWindow(...)` -> automatic environment
  binding plus optional `Environment(...)` overrides.
- `OutputRouting(...)` -> model-application output policy.
- `ScopeModel(...)` -> `AppliesTo(...)` plus selector scopes.
- `PreviousTimeStep(...)` remains supported as a temporal/cycle-breaking
  marker in the unified object-address graph.
- explicit per-model meteo wiring -> automatic environment resolver plus
  cached environment bindings.

Important: the future redesign is not implemented yet. Do not describe it as
released behavior until the old examples have been migrated and tests pass.
