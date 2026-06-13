# Release Notes Handoff

This page is the persistent release-note source for work done during the
multi-domain and cleanup branch. Keep it factual: mark what is implemented,
what is removed, and what is only planned.

## Implemented Breaking Cleanup

Source details live in `code_cleanup_audit.md`.

- Removed public `ModelList` usage. New simulations should use `Scene` and
  model applications. Retained mapping compatibility code can use
  `PlantSimEngine.ModelMapping(model...; status=...)`.
- Removed direct `run!(::ModelList, ...)`; retained mapping code must wrap
  models in `PlantSimEngine.ModelMapping`.
- Removed batch `run!` over collections/dictionaries of single-scale mappings;
  use explicit loops or comprehensions.
- Removed raw `Dict` multiscale `run!(mtg, dict, ...)`; construct
  `PlantSimEngine.ModelMapping(dict)` first.
- Removed string scale names. Use symbols, for example `:Leaf`.
- Removed `PlantSimEngine.ModelMapping(Float64 => Float32)` promotion shorthand. Use a
  `Dict(Float64 => Float32)` as the `type_promotion` value.
- Removed `ModelMapping` from exports. Historical mapping simulations remain
  available through the explicitly qualified
  `PlantSimEngine.ModelMapping(...)` compatibility API.
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
- Selector failures now include context, matched object ids, requested
  criteria, available labels, and near-match suggestions. Misspelled labels
  such as `scale=:Leef` therefore suggest `:Leaf` instead of returning only a
  cardinality count.
- `Relation(...)` now supports `:self`, `:parent`, `:children`, `:ancestors`,
  `:descendants`, and `:siblings` in `AppliesTo`, `Inputs`, and `Calls`
  selectors. Relation results are compiled to concrete object ids and may be
  constrained by an explicit scope.
- `ObjectAddress` explanations now preserve positional selector criteria such
  as `Scale(:Leaf)` and `Relation(:parent)`.
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
- Same-rate scene inputs are now wired into consumer `Status` references once
  during compilation. Scalar and `Many(...)` inputs remain live references,
  missing bound input fields are compiler-generated, and repeated non-temporal
  input materialization is allocation-free.
- Same-rate `Inputs(...)` carriers preserve arbitrary concrete value types.
  Regression coverage passes a dual-like `BigFloat` wrapper through a typed
  `RefVector`, model arithmetic, source mutation, and output publication
  without conversion to `Float64`.
- Same-object variable renaming now uses normal `Inputs(...)` syntax instead of
  `SameScale()`. Renamed inputs share the producer reference and contribute the
  expected producer-to-consumer scheduling edge.
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
- Spatial environment binding now falls back to the nearest ancestor geometry
  for objects without their own geometry. Binding explanations expose the
  geometry provenance, and moving an ancestor refreshes only descendants that
  inherit its geometry.
- Environment binding refresh can now update changed `meteo_inputs_` and
  `meteo_outputs_` metadata without repeating spatial indexing or cell lookup
  when the application/object/provider/geometry contract is otherwise
  unchanged.
- `Environment(; sources=(CO2=:Ca,))` now remaps model-facing environment
  variables to backend source variables. Scene environment binding refresh
  validates missing source variables for enumerable backends such as
  `GlobalConstant`, and explanations expose both `required_inputs` and
  `source_inputs`.
- `validate_meteo_inputs(scene)` and
  `validate_meteo_inputs(compiled_scene, meteo_or_backend)` now validate
  scene/object environment contracts directly. Missing-variable diagnostics use
  scene application ids, and validation honors both scenario
  `Environment(; sources=...)` remaps and model-author `meteo_hint` defaults.
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
  reports each binding origin, including `:model_default`, `:model_spec`, and
  `:inferred_same_object`.
- Compiled input bindings now validate `Inputs(...)` `process=`/`application=`
  filters when they are provided, and `explain_bindings` reports
  `source_application_ids`, `process`, and `application`.
- `compile_scene` now errors for required `inputs_(model)` variables that are
  neither bound through `Inputs(...)`/inference nor present on the target object
  `Status`.
- `compile_scene` now prepares model-owned status schemas automatically:
  model-targeted objects may omit `Status`, declared model/environment outputs
  are inserted from trait defaults, and bound consumer inputs are generated
  from `inputs_` defaults. External unbound inputs still require explicit
  initialization.
- `compile_scene` now rejects `Inputs(...)` entries whose receiving variable is
  not declared by the model's `inputs_`, making binding typos explicit at
  compile time.
- `compile_scene` now validates status-backed non-temporal `Inputs(...)`
  source availability, so bindings that select existing source objects but no
  source `Status` reference fail at compile time instead of becoming no-ops.
- Scene/object runtime now publishes model outputs to scene-local temporal
  streams and resolves temporal `Inputs(...)` with `HoldLast`, `Integrate`,
  and `Aggregate` policies before consumer execution.
- Scene temporal `Inputs(...)` now use producer `output_policy(...)` traits as
  the default when the selector omits `policy=...` and resolves to a unique
  source application. Explicit selector policies override the trait.
- Scene applications now infer model-author default environment source remaps
  from `meteo_hint(...).bindings` when the scenario does not provide explicit
  meteo bindings. Scenario `Environment(; sources=...)` remains the override.
- Scene/object runtime now scatters values declared by `meteo_outputs_(model)`
  back to the bound environment backend after each model call, using the
  existing `scatter_environment_outputs!` backend protocol.
- Scene/object root applications now honor `TimeStep(...)` values backed by
  `Dates.Period` scheduling. `explain_schedule` reports normalized clocks and
  whether an application is root-scheduled or manual-call-only.
- Scene/object root applications now also honor `timespec(...)` model traits
  when no explicit `TimeStep(...)` is provided. Scenario-level `TimeStep(...)`
  remains the override.
- Scene/object root applications now validate `timestep_hint(...)` required
  bounds for clocks derived from the scene base step. Hints remain
  compatibility constraints, not scheduling overrides.
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
  `call_target(s)(extra, :name)` plus `run_call!` for manual `Calls(...)`
  execution.
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
- Scene hard calls now accept explicit local meteorology:
  `run_call!(target; meteo=local_meteo, publish=false)`. This lets iterative
  parent models pass trial microclimate to manually called child models without
  resampling the scene environment.
- Scene hard calls now default to `publish=false`. Trial calls mutate target
  status without publishing temporal samples or environment writes; accepted
  states must use `run_call!(target; publish=true)`. Iterative-call tests verify
  that several trials followed by one accepted call publish exactly once.
- `explain_calls(compiled)` now exposes the manual-call publication contract
  through `publication_policy`, `default_publish`, and `accepted_publish`
  fields.
- `ModelSpec` now keeps provenance for `Inputs(...)` and `Calls(...)`.
  Declarations coming from `dep(model)` are `:model_default`, scenario-level
  declarations and overrides are `:model_spec`, and structured explanations
  expose these origins for release-note and migration diagnostics.
- Compiled `OptionalOne(...)` inputs and calls now accept zero matches.
  Optional inputs keep their declared model default, optional calls return an
  empty target collection, and both remain visible in structured explanations.
- Scene runtime now builds a process-keyed `models` bundle from compiled
  `Calls(...)` edges before invoking a model kernel. Existing hard-dependency
  kernels such as `Monteith` and `Fvcb` can therefore keep using
  `models.photosynthesis` and `models.stomatal_conductance`.
- Scene duplicate-writer validation now ignores manual-call-only applications
  when validating canonical root writers, so hard-dependency children are not
  treated as independent root writers for variables they update inside a parent
  call stack.
- Adds `build_maespa_unified_scene(...)` and `run_maespa_scene_example(...)`.
  This unified scene/object MAESPA path uses `ObjectTemplate`,
  `ObjectInstance`, `AppliesTo`, `Inputs`, `Calls`, and
  `TimeStep(Dates.Period)` with two plant species, one shared soil object,
  scene LAI, and scene energy balance.
- `test/test-maespa-domain-example.jl` now verifies the unified scene/object
  MAESPA path alongside the domain regression path.
- `run!(scene)` now returns a `SceneSimulation` wrapper containing the mutated
  scene, compiled object bindings, compiled environment bindings, and
  scene-local temporal output streams.
- Adds scene output inspection helpers:
  `scene_outputs(sim::SceneSimulation)`, `collect_outputs(sim)`, and
  `explain_outputs(sim)`. These expose object ids, variables, publishing
  application ids, sample counts, time bounds, and value types.
- `run!(scene; tracked_outputs=...)` now accepts `OutputRequest` for
  scene/object runs. Requested outputs are collected from retained typed scene
  streams after the run, can be read with `collect_outputs(sim)` or
  `collect_outputs(sim, :request_name)`, support the standard temporal
  policies and `Dates.Period` export clocks, and respect dynamic object
  lifetimes by exporting each object only across its own sample interval. This
  now prunes retained streams at publisher level: `tracked_outputs=nothing`
  keeps all streams, explicit requests keep requested application/variable
  streams plus streams required by temporal `Inputs(...)`, and
  `tracked_outputs=OutputRequest[]` keeps no streams unless temporal
  dependencies require them. Dependency-only streams now have bounded
  policy-specific histories: latest-only for `HoldLast`, the required window
  for `Integrate`/`Aggregate`, and sufficient recent source samples for
  `Interpolate`/`PreviousTimeStep`. Requested and default retain-all streams
  still preserve complete histories, and export remains post-run rather than
  fully online.
- Adds `explain_output_retention(sim)` for structured diagnostics of retained
  scene output streams, their reasons, and the compiled retention horizon for
  dependency-only streams.
- Scene temporal streams are now keyed by application id, object id, and
  variable, so two applications can publish the same variable on the same
  object without overwriting each other's stream samples.
- Scene output-export tests now cover requested-output `DataFrame`
  materialization, canonical publisher inference without `process=...`,
  rejection when only stream-only publishers exist, and ambiguity when an
  explicit process matches both a stream-only and a canonical publisher.
- `OutputRequest(...)` now accepts `application=...` for scene/object runs.
  This disambiguates repeated applications of the same process and permits
  explicit export of a named `:stream_only` publisher. Legacy
  `GraphSimulation` output export rejects this scene-specific selector.
- Scene temporal streams now retain a concrete value type per
  application/object/output stream. Type changes fail explicitly, while
  generic values such as `BigFloat` remain typed through publication,
  interpolation, and integration.
- Scene temporal `Inputs(...)` now implement the complete `Interpolate(...)`
  policy used by the existing multirate runtime: linear interpolation when
  samples bracket the requested time, online linear extrapolation from the
  last two samples, and configurable hold behavior. Interpolation modes are
  validated during scene compilation, and arithmetic preserves generic value
  types such as `BigFloat` instead of coercing model values to `Float64`.
- Scene `Inputs(...)` accepts
  `PreviousTimeStep(:input) => One(...)` or `Many(...)` for explicit lagged
  dependencies. These bindings read the previous scene timestep, use the
  consumer status initialization before history exists, and are excluded from
  same-timestep dependency edges so feedback loops can be compiled.
- Scene `OutputRouting(; var=:stream_only)` is honored by canonical writer
  validation and same-object input inference. Stream-only outputs are excluded
  from canonical ownership, but remain available in output streams and explicit
  `Inputs(..., application=:name)` bindings.
- Scene execution now refreshes dirty structural bindings between timesteps.
  Objects created, removed, or reparented by a model update application target
  sets, input carriers, call targets, writer validation, and scheduling before
  the next timestep.
- Geometry-only changes refresh environment bindings at the next timestep
  without rebuilding structural bindings. `SceneSimulation` returns the final
  compiled structural and environment state, including changes made during the
  last timestep.
- Geometry-only environment invalidation is now object-scoped. Moving or
  explicitly marking one organ dirty preserves unaffected compiled environment
  bindings and rebinds only model applications targeting that object;
  structural scene changes still trigger a full rebuild.
- Added runtime lifecycle coverage for organ creation, pruning, plant-local
  `RefVector` refresh, historical output retention for removed objects, and
  movement between mock microclimate cells.
- `CompiledScene` now precompiles one process-keyed model bundle per
  application/object target. Generic hard-dependency kernels receive this
  cached bundle through the existing `models` argument, avoiding recursive
  `Calls(...)` traversal and temporary collection allocation in the timestep
  hot loop.
- Adds `explain_model_bundles(compiled)` for structured inspection of the
  process names and model types passed to each application/object kernel.
- Scene root execution now uses compiled homogeneous target batches. Models,
  statuses, model bundles, input bindings, and environment bindings are
  prebound, so dynamic dispatch happens once per batch instead of once per
  object. Heterogeneous object overrides split into ordered concrete batches.
- Adds `explain_execution_plan(scene_or_simulation)` and a zero-allocation
  warmed 128-leaf inner-loop regression gate.
- Manual `Calls(...)` handles now use the public
  `call_target(extra, name)`/`call_targets(extra, name)` lookup API followed by
  `run_call!`. The older `dependency_target(s)` and `run_target!` spellings
  remain internal compatibility helpers.
- The legacy domain/route authoring surface is no longer exported:
  `Domain`, `SimulationMapping`, `DomainSimulation`, `AllDomains`,
  `HardDomains`, `Route`, route cardinalities, domain target helpers, and
  domain explanation helpers require qualified `PlantSimEngine.*` access for
  regression and migration work.
- Adds `objects_from_mtg(root; ...)` and `Scene(mtg; ...)` so existing MTG
  topology can be adapted once into the unified registry while preserving
  node-derived identity, parent relations, labels, geometry, and existing
  status objects.
- Scene applications now sample global tabular meteorology at their compiled
  `Dates.Period` clock. PlantMeteo reducers and windows from `meteo_hint` are
  honored; `Environment(; sources=...)` overrides the source while preserving
  the reducer. Prepared samplers are shared, and one sampled row is cached per
  application/timestep for all selected objects.

## Compatibility Boundary

The scene/object runtime and its MAESPA acceptance path are implemented. The
legacy configuration surface is retained only as an explicitly qualified
compatibility and regression layer. It is not exported or presented as the
primary API. The design, implementation history, and completion evidence are
documented in:

- `unified_scene_object_design.md`
- `unified_scene_object_implementation_plan.md`
- `unified_scene_object_completion_audit.md`

The completed public migration is:

- replace historical qualified compatibility tutorials with native
  scene/object tutorials where long-term coverage is still valuable;
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
  binding plus `Environment(...)` provider/source overrides.
- `OutputRouting(...)` -> model-application output policy.
- `ScopeModel(...)` -> `AppliesTo(...)` plus selector scopes.
- `PreviousTimeStep(...)` remains supported as a temporal/cycle-breaking
  marker in the unified object-address graph.
- explicit per-model meteo wiring -> automatic environment resolver plus
  cached environment bindings.

Historical examples and tests that remain are intentionally retained as a
separate qualified compatibility layer. Their continued existence does not
make them part of the public scene/object API.

## Migration Documentation Added

- Added `docs/src/migration_scene_object.md` as the user-facing migration guide
  from mappings, routes, and domains to the scene/object API.
- Updated documentation navigation, home-page guidance, legacy domain and
  multiscale warnings, and the canonical repository agent skill to direct new
  scenarios toward `Scene`, `Object`, `AppliesTo`, `Inputs`, `Calls`,
  `Updates`, `TimeStep`, and `Environment`.
- Replaced the documentation home-page quickstart with executable
  scene/object examples. The page now introduces `Scene`, `Object`,
  `ModelSpec`, `AppliesTo`, `Inputs`, `TimeStep`, inferred same-object
  bindings, multi-object `Many(...)` inputs, and manual `Calls(...)` syntax
  before linking to legacy mapping reference pages.
- Replaced the repository README examples with scene/object-first examples.
  The README now introduces `Scene`, `Object`, model applications,
  multi-object `Inputs(...)`, and `Calls(...)`, and treats `ModelMapping` /
  `MultiScaleModel` as compatibility APIs.
- Added a native scene/object quickstart page to the main documentation
  navigation. It provides docs-tested examples for one-object model chaining,
  inferred bindings, requested output retention, multi-object `Inputs(...)`,
  reference carrier explanations, and manual `Calls(...)` syntax.
- Rewrote the model execution page as the current scene/object execution
  guide. It now covers compilation, reference carriers, temporal `Inputs(...)`,
  manual `Calls(...)`, `Updates(...)`, `TimeStep(...)`, environment binding,
  retained outputs, lifecycle invalidation, and compatibility translations for
  old mapping/domain constructs.
- Rewrote the detailed first simulation tutorial to use the scene/object API.
  It now introduces `Scene`, `Object`, `ModelSpec`, `AppliesTo`, `TimeStep`,
  compiled applications, inferred same-object bindings, scene outputs, and a
  compatibility note for historical `ModelMapping` examples.
- Rewrote the quick examples page to use native scene/object snippets for
  Beer light interception, degree-days/LAI/light coupling, biomass growth, and
  retained `OutputRequest` exports. Historical `ModelMapping` usage is now
  confined to the compatibility note.
- Rewrote the standard model coupling, model switching, and coupling more
  complex models tutorials around the scene/object API. These pages now show
  inferred same-object value bindings, switching one `ModelSpec` application,
  execution-plan explanations, and `Calls(...)` manual-call wiring before
  mentioning `PlantSimEngine.ModelMapping(...)` as compatibility syntax.
- Removed legacy mapping transforms from exports:
  `MultiScaleModel`, `SameScale`, `TimeStepModel`, `InputBindings`,
  `MeteoBindings`, `MeteoWindow`, and `ScopeModel`. Historical executable
  examples use qualified compatibility names and are grouped under legacy
  documentation sections.
- Added a curated unified scene/object map to the public API page and labeled
  the remaining mapping-level multirate reference as legacy.
