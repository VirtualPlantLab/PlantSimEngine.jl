# Release Notes Handoff

This page is the persistent release-note source for the composite-model/object redesign
and cleanup branch. Keep it factual: mark what is implemented, what is removed,
and what is only planned.

## Implemented Breaking Cleanup

Source details live in `code_cleanup_audit.md`.

- Removed `ModelList`, `ModelMapping`, `GraphSimulation`, `MultiScaleModel`,
  and the separate mapping dependency/runtime stack. Use `CompositeModel`, `Object`,
  and model applications.
- Removed direct and batch mapping `run!` methods.
- Removed string scale names. Use symbols, for example `:Leaf`.
- Removed mapping-specific type-promotion configuration.
- Removed `ModelMapping` completely; it is not retained as a qualified
  compatibility API.
- Removed old multiscale output indexing helpers. Convert outputs explicitly
  before indexing.
- Replaced mapping-specific same-scale rename sentinels with
  `Inputs(:local => One(within=Self(), var=:source))`.
- Removed unused parallel-executor traits after deleting the executor runtime.
- Removed dead mapping-era wrappers and traits: `UninitializedVar`,
  `RefVariable`, `TreeAlike`, and `StatusView`.
- Removed the unreleased `CompositeModelTemplate(...; mapping=...)` alias and dead
  selector-to-mapping conversion helpers.
- Removed stale `PlantSimEngine.Examples` exports for the deleted
  `ToyInternodeEmergence` example.
- Replaced many source-side validation `@assert`s with explicit errors.
- Added `Updates(:var; after=:application)` for ordered duplicate writers.
- Added `runtime_model(runtime)` as the sanctioned live-model accessor for
  `RunContext` and `Simulation`; kernels no longer need to inspect
  `extra.compiled.model`.
- Added `explain_initialization(model)` with structured `:supplied`,
  `:generated`, `:producer_bound`, `:environment_bound`, and `:unresolved`
  dispositions.
- Added `CompositeModel(model, models...; status=...)` as a thin one-object constructor
  that lowers to the normal object and `ModelSpec` representation.
- Calendar-aligned windows remain unsupported. Temporal windows use
  duration-based `Dates.Period` semantics.

## Removed Unreleased Scenario Prototype

An experimental scenario runtime was developed and replaced on this branch
before release. Its source, tests, examples, and documentation were removed
rather than retained as compatibility code.

The removed API included `Domain`, `SimulationMapping`, `Route`,
`AllDomains`, and `HardDomains`, together with the domain scheduler, run loops,
route materialization, environment bridge, graph runner, and output publisher.
Because this API was never released, there is no compatibility layer or user
migration path for it.

The reusable behavior now lives in the composite-model/object runtime: object selectors,
compiled `Inputs(...)`, manual `Calls(...)`, `Dates`-based scheduling,
environment backends, dynamic object lifecycle handling, and structured
explanations.

Dynamic MTG growth now has one public high-level operation: `add_organ!`.
An MTG-backed `CompositeModel` retains the accessors and status initializer used during
initial adaptation. `add_organ!` reuses that policy for new nodes, merges
explicit initial values, attaches the resulting `Status`, registers the model
object, and invalidates runtime bindings. `register_object!` remains available
as the low-level registry operation. XPalm and PlantGeom were migrated away
from package-local wrappers that duplicated this lifecycle sequence.

## Implemented MAESPA-Style Example Changes

The current `examples/maespa_model_example.jl` is the main executable example
for multi-plant model coupling.

- Uses copied PlantBiophysics subsample models:
  `Monteith`, `Fvcb`, and `Tuzet`.
- Uses two plant instances with different parameters and shared scale names
  such as `:Plant` and `:Leaf`.
- Uses a shared soil model.
- Uses `SceneEB` with `ModelSpec(...) |> Calls(...)` to manually run leaf
  `:energy_balance` and soil `:soil_water` targets.
- Ports MAESPA-style canopy air temperature and VPD update through the
  `canopy_air_update(...)` helper and `gbcanms`.
- Treats input meteorology as above-canopy forcing, runs trial leaves with
  `run_call!(...; environment=trial_state)`, commits accepted canopy
  meteorology with `commit_environment!`, and writes
  below-canopy microclimate diagnostics to model status fields:
  `canopy_tair`, `canopy_vpd`, `canopy_rh`, `canopy_htot`, and
  `canopy_gcanop`.
- Adds `LAIModel` and declares plant leaf-area materialization with
  `ModelSpec(...) |> Inputs(...)`.
- Computes plant allocation daily from plant-local `leaf_carbon` vectors.
- Adds `run_call!` for manually executing compiled model call targets.
- Adds model-level `Input(...)` and `Call(...)` dependency defaults through
  `dep(model)`, with scenario-level `Inputs(...)` and `Calls(...)` overriding
  those defaults in `ModelSpec`.
- Adds initial registry-backed model selector resolution with
  `resolve_object_ids` and `resolve_objects` for global, self-relative,
  plant-relative, ancestor-relative, and named-scope object selections.
- Adds `explain_scopes(model)` for structured scope diagnostics. It reports
  the model scope, object subtree scopes, named `Scope(...)` entries, and
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
- Adds the first compiled composite-model/object view with `Advanced.compile_composite_model`,
  `Advanced.CompiledCompositeModel`, `Advanced.CompiledModelApplication`, `Advanced.CompiledModelInputBinding`,
  `Advanced.CompiledModelCallBinding`, `explain_applications`,
  `explain_bindings`, and `explain_calls`.
- The compiled model view resolves `AppliesTo(...)`, `Inputs(...)`, and
  `Calls(...)` to object ids ahead of runtime, and reports temporal policy,
  window, carrier hints, and callee application ids for agent-readable
  diagnostics.
- Unscoped composite-model/object dependency selectors now infer scope from the consumer:
  model consumers default to `SceneScope()`, while non-model consumers default
  to `Self()`. Cross-scope shared dependencies, such as leaf models reading
  soil state, should use `within=SceneScope()` explicitly.
- Adds status-backed compiled input carriers for the composite-model/object view:
  scalar shared refs, homogeneous `RefVector`s, and `Advanced.ObjectRefVector` fallback
  carriers. `input_carrier`, `input_value`, and `has_reference_carrier` expose
  them for tests, diagnostics, and future runtime execution.
- Same-rate model inputs are now wired into consumer `Status` references once
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
- Adds model binding cache helpers:
  `Advanced.refresh_bindings!`, `Advanced.bindings_dirty`, `Advanced.compiled_bindings`, and
  `Advanced.model_revision`. Object registration, removal, and reparenting invalidate
  cached compiled bindings before the next refresh.
- Adds composite-model/object environment binding cache helpers:
  `Advanced.refresh_environment_bindings!`, `Advanced.compile_environment_bindings`,
  `Advanced.CompiledEnvironmentBinding`, `Advanced.CompiledEnvironmentBindings`,
  `Advanced.environment_bindings_dirty`, `Advanced.compiled_environment_bindings`,
  `Advanced.environment_revision`, and `explain_environment_bindings`.
- Adds `geometry`, `position`, and `bounds` accessors for model objects/statuses.
  Environment binding refreshes call `update_index!(backend, entities)` before
  binding objects to backend cells/layers, so spatial backends can precompute
  model-wide lookup structures.
- Spatial environment binding now falls back to the nearest ancestor geometry
  for objects without their own geometry. Binding explanations expose the
  geometry provenance, and moving an ancestor refreshes only descendants that
  inherit its geometry.
- Environment binding refresh can now update changed `meteo_inputs_` metadata
  without repeating spatial indexing or cell lookup when the
  application/object/provider/geometry contract is otherwise unchanged.
- `Environment(; sources=(CO2=:Ca,))` now remaps model-facing environment
  variables to backend source variables. CompositeModel environment binding refresh
  validates missing source variables for enumerable backends such as
  `GlobalConstant`, and explanations expose both `required_inputs` and
  `source_inputs`.
- `validate_meteo_inputs(model)` and
  `validate_meteo_inputs(compiled_scene, meteo_or_backend)` now validate
  composite-model/object environment contracts directly. Missing-variable diagnostics use
  model application ids, and validation honors both scenario
  `Environment(; sources=...)` remaps and model-author `meteo_hint` defaults.
- Object movement now invalidates environment bindings without rebuilding the
  structural object/model binding cache.
- Adds public geometry lifecycle helpers:
  `update_geometry!(model, object, geometry; invalidate_environment=true)` and
  object-scoped `mark_environment_binding_dirty!(model, object)`. They
  currently invalidate the model environment binding cache and leave room for
  finer-grained dirty tracking later.
- Adds the first composite-model/object runtime with `run!(model; steps=...)`.
  It materializes compiled `Inputs(...)` carriers, samples bound environment
  inputs, and executes generic model kernels on object `Status` values.
- CompositeModel/object compiler now infers simple same-object value bindings from
  `inputs_`/`outputs_` when one producer is unambiguous. `explain_bindings`
  reports each binding origin, including `:model_default`, `:model_spec`, and
  `:inferred_same_object`.
- Compiled input bindings now validate `Inputs(...)` `process=`/`application=`
  filters when they are provided, and `explain_bindings` reports
  `source_application_ids`, `process`, and `application`.
- `Advanced.compile_composite_model` now errors for required `inputs_(model)` variables that are
  neither bound through `Inputs(...)`/inference nor present on the target object
  `Status`.
- `Advanced.compile_composite_model` now prepares model-owned status schemas automatically:
  model-targeted objects may omit `Status`, declared model/environment outputs
  are inserted from trait defaults, and bound consumer inputs are generated
  from `inputs_` defaults. External unbound inputs still require explicit
  initialization.
- `Advanced.compile_composite_model` now rejects `Inputs(...)` entries whose receiving variable is
  not declared by the model's `inputs_`, making binding typos explicit at
  compile time.
- `Advanced.compile_composite_model` now validates status-backed non-temporal `Inputs(...)`
  source availability, so bindings that select existing source objects but no
  source `Status` reference fail at compile time instead of becoming no-ops.
- CompositeModel/object runtime now publishes model outputs to model-local temporal
  streams and resolves temporal `Inputs(...)` with `HoldLast`, `Integrate`,
  and `Aggregate` policies before consumer execution.
- CompositeModel temporal `Inputs(...)` now use producer `output_policy(...)` traits as
  the default when the selector omits `policy=...` and resolves to a unique
  source application. Explicit selector policies override the trait.
- CompositeModel applications now infer model-author default environment source remaps
  from `meteo_hint(...).bindings` when the scenario does not provide explicit
  meteo bindings. Scenario `Environment(; sources=...)` remains the override.
- CompositeModel/object runtime exposes `run_call!(...; environment=trial_state)`
  for non-committing trial meteorology and `commit_environment!` for accepted
  mutable environment
  commits from model kernels.
- CompositeModel/object root applications now honor `TimeStep(...)` values backed by
  `Dates.Period` scheduling. `explain_schedule` reports normalized clocks and
  whether an application is root-scheduled or manual-call-only.
- CompositeModel/object root applications now also honor `timespec(...)` model traits
  when no explicit `TimeStep(...)` is provided. Scenario-level `TimeStep(...)`
  remains the override.
- CompositeModel/object root applications now validate `timestep_hint(...)` required
  bounds for clocks derived from the model base step. Hints remain
  compatibility constraints, not scheduling overrides.
- CompositeModel/object execution now uses a stable topological application order
  compiled from `Inputs(...)` producer edges and `Updates(...)` ordering.
  Dependencies on manual-call-only applications are redirected to their parent
  caller, same-timestep cycles fail during compilation, and
  `explain_schedule` reports `execution_index`.
- `Advanced.CompiledCompositeModel` now pre-indexes input and call bindings by application and
  object id. Runtime input materialization and hard-call lookup no longer scan
  all model bindings for every object/model invocation.
- `Advanced.CompiledCompositeModel` now pre-indexes applications by application id, removing
  application scans from hard-call target resolution and dictionary rebuilding
  from ordered execution setup.
- `Advanced.CompiledEnvironmentBindings` now pre-indexes environment bindings by
  application and object id, removing the model-wide binding scan from
  environment sampling and output scattering.
- Adds `RunContext` and `CallTarget`; composite-model/object models can use
  `run_call!(extra, :name)` plus `call_targets(extra, :name)` for fine-grained manual `Calls(...)`
  execution.
- Applications selected by `Calls(...)` are skipped by the root
  `run!(model)` loop and execute only through explicit `run_call!`, preserving
  parent-controlled hard-call execution.
- Adds composite-model/object duplicate-writer validation in `Advanced.compile_composite_model`. A variable
  may have only one canonical writer per object unless later writers declare
  `Updates(:var; after=...)`, where `after` can match a previous application
  id/name or process.
- Adds `explain_writers(compiled)` to report object-variable writer groups,
  duplicate writers, and the `Updates(...)` declarations that validate ordered
  updates.
- Adds the first reusable object-template path with `CompositeModelTemplate` and
  `ObjectInstance`. Templates bundle reusable `ModelSpec`s and default
  `kind`/`species` labels; instances mount them inside a named object subtree.
- `CompositeModel(...)` accepts mounted instances whose roots are either owned objects
  or references to separately supplied model objects.
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
- Adds `explain_instances(model)` and instance membership in
  `explain_objects(model)`. Instance rows expose roots, current object
  membership, mounted applications, overrides, template labels, and
  reference-based parameter ownership.
- Objects created below a mounted instance inherit missing template `kind` and
  `species` labels. Membership explanations use the current topology rather
  than a copied instance object list.
- CompositeModel hard calls now support trial microclimate through
  `run_call!(extra, name; environment=local_state)`, so hard-called
  descendants resample the temporary environment through their normal
  environment bindings.
- CompositeModel hard calls now default to `publish=false`. Trial calls mutate target
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
- CompositeModel runtime now builds a process-keyed `models` bundle from compiled
  `Calls(...)` edges before invoking a model kernel. Existing hard-dependency
  kernels such as `Monteith` and `Fvcb` can therefore keep using
  `models.photosynthesis` and `models.stomatal_conductance`.
- CompositeModel duplicate-writer validation now ignores manual-call-only applications
  when validating canonical root writers, so hard-dependency children are not
  treated as independent root writers for variables they update inside a parent
  call stack.
- Adds `build_maespa_scene(...)` and `run_maespa_example(...)`.
  This unified composite-model/object MAESPA path uses `CompositeModelTemplate`,
  `ObjectInstance`, `AppliesTo`, `Inputs`, `Calls`, and
  `TimeStep(Dates.Period)` with two plant species, one shared soil object,
  model LAI, and model energy balance.
- `test/test-maespa-model-example.jl` verifies the unified composite-model/object
  MAESPA path.
- `run!(model)` now returns a `Simulation` wrapper containing the mutated
  model, compiled object bindings, compiled environment bindings, and
  model-local temporal output streams.
- Adds model output inspection helpers:
  `outputs(sim::Simulation)`, `collect_outputs(sim)`, and
  `explain_outputs(sim)`. These expose object ids, variables, publishing
  application ids, sample counts, time bounds, and value types.
- `run!(model; tracked_outputs=...)` now accepts `OutputRequest` for
  composite-model/object runs. Requested outputs are collected from retained typed model
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
  model output streams, their reasons, and the compiled retention horizon for
  dependency-only streams.
- CompositeModel temporal streams are now keyed by application id, object id, and
  variable, so two applications can publish the same variable on the same
  object without overwriting each other's stream samples.
- CompositeModel output-export tests now cover requested-output `DataFrame`
  materialization, canonical publisher inference without `process=...`,
  rejection when only stream-only publishers exist, and ambiguity when an
  explicit process matches both a stream-only and a canonical publisher.
- `OutputRequest(...)` now accepts `application=...` for composite-model/object runs.
  This disambiguates repeated applications of the same process and permits
  explicit export of a named `:stream_only` publisher.
- CompositeModel temporal streams now retain a concrete value type per
  application/object/output stream. Type changes fail explicitly, while
  generic values such as `BigFloat` remain typed through publication,
  interpolation, and integration.
- CompositeModel temporal `Inputs(...)` now implement the complete `Interpolate(...)`
  policy used by the existing multirate runtime: linear interpolation when
  samples bracket the requested time, online linear extrapolation from the
  last two samples, and configurable hold behavior. Interpolation modes are
  validated during model compilation, and arithmetic preserves generic value
  types such as `BigFloat` instead of coercing model values to `Float64`.
- CompositeModel `Inputs(...)` accepts
  `PreviousTimeStep(:input) => One(...)` or `Many(...)` for explicit lagged
  dependencies. These bindings read the previous model timestep, use the
  consumer status initialization before history exists, and are excluded from
  same-timestep dependency edges so feedback loops can be compiled.
- CompositeModel `OutputRouting(; var=:stream_only)` is honored by canonical writer
  validation and same-object input inference. Stream-only outputs are excluded
  from canonical ownership, but remain available in output streams and explicit
  `Inputs(..., application=:name)` bindings.
- CompositeModel execution now refreshes dirty structural bindings between timesteps.
  Objects created, removed, or reparented by a model update application target
  sets, input carriers, call targets, writer validation, and scheduling before
  the next timestep.
- Geometry-only changes refresh environment bindings at the next timestep
  without rebuilding structural bindings. `Simulation` returns the final
  compiled structural and environment state, including changes made during the
  last timestep.
- Geometry-only environment invalidation is now object-scoped. Moving or
  explicitly marking one organ dirty preserves unaffected compiled environment
  bindings and rebinds only model applications targeting that object;
  structural model changes still trigger a full rebuild.
- Added runtime lifecycle coverage for organ creation, pruning, plant-local
  `RefVector` refresh, historical output retention for removed objects, and
  movement between mock microclimate cells.
- `Advanced.CompiledCompositeModel` now precompiles one process-keyed model bundle per
  application/object target. Generic hard-dependency kernels receive this
  cached bundle through the existing `models` argument, avoiding recursive
  `Calls(...)` traversal and temporary collection allocation in the timestep
  hot loop.
- Adds `explain_model_bundles(compiled)` for structured inspection of the
  process names and model types passed to each application/object kernel.
- CompositeModel root execution now uses compiled homogeneous target batches. Models,
  statuses, model bundles, input bindings, and environment bindings are
  prebound, so dynamic dispatch happens once per batch instead of once per
  object. Heterogeneous object overrides split into ordered concrete batches.
- Adds `explain_execution_plan(scene_or_simulation)` and a zero-allocation
  warmed 128-leaf inner-loop regression gate.
- Manual `Calls(...)` handles now use the public
  vector-like `run_call!(extra, name)` execute-all API, with
  `call_targets(extra, name)` followed by `run_call!(target)` for fine-grained control.
- Removed the unreleased intermediate authoring and runtime subsystem after
  composite-model/object feature parity was established.
- Adds `objects_from_mtg(root; ...)` and `CompositeModel(mtg; ...)` so existing MTG
  topology can be adapted once into the unified registry while preserving
  node-derived identity, parent relations, labels, geometry, and existing
  status objects.
- CompositeModel applications now sample global tabular meteorology at their compiled
  `Dates.Period` clock. PlantMeteo reducers and windows from `meteo_hint` are
  honored; `Environment(; sources=...)` overrides the source while preserving
  the reducer. Prepared samplers are shared, and one sampled row is cached per
  application/timestep for all selected objects.

## Compatibility Boundary

The composite-model/object runtime and its MAESPA acceptance path are implemented.
Historical mapping APIs and the unreleased intermediate prototype were
removed. The design, implementation history, and completion evidence are
documented in:

- `composite_model_design.md`
- `composite_model_implementation_plan.md`
- `composite_model_completion_audit.md`

The completed public migration is:

- replace historical tutorials with native composite-model/object tutorials where
  long-term coverage is still valuable;
- model mappings should be described as model applications:
  `ModelSpec(model; name=...) |> AppliesTo(...) |> Inputs(...) |> Calls(...)`;
- `MultiScaleModel(...)` -> `Inputs(...)`.
- `dep(model)` remains the model-level trait for default dependency intent:
  defaults can become `Input(...)` value bindings or `Call(...)` manual model
  calls, and scenario-level `ModelSpec` configuration overrides them.
- model target scales -> `AppliesTo(...)` object selectors.
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

Historical mapping examples, tests, and runtime files were removed after the
composite-model/object acceptance path reached feature parity. Migration information is
kept in this release-note handoff and the user-facing migration guide.

## Migration Documentation Added

- Added `docs/src/migration_composite_model.md` as the user-facing migration guide
  from historical mappings to the composite-model/object API.
- Updated documentation navigation, home-page guidance, multiscale warnings,
  and the canonical repository agent skill to direct new
  scenarios toward `CompositeModel`, `Object`, `AppliesTo`, `Inputs`, `Calls`,
  `Updates`, `TimeStep`, and `Environment`.
- Replaced the documentation home-page quickstart with executable
  composite-model/object examples. The page now introduces `CompositeModel`, `Object`,
  `ModelSpec`, `AppliesTo`, `Inputs`, `TimeStep`, inferred same-object
  bindings, multi-object `Many(...)` inputs, and manual `Calls(...)` syntax
  before linking to the migration guide.
- Replaced the repository README examples with composite-model/object-first examples.
  The README now introduces `CompositeModel`, `Object`, model applications,
  multi-object `Inputs(...)`, and `Calls(...)`.
- Added a native composite-model/object quickstart page to the main documentation
  navigation. It provides docs-tested examples for one-object model chaining,
  inferred bindings, requested output retention, multi-object `Inputs(...)`,
  reference carrier explanations, and manual `Calls(...)` syntax.
- Rewrote the model execution page as the current composite-model/object execution
  guide. It now covers compilation, reference carriers, temporal `Inputs(...)`,
  manual `Calls(...)`, `Updates(...)`, `TimeStep(...)`, environment binding,
  retained outputs, lifecycle invalidation, and migration translations for
  historical mapping constructs.
- Rewrote the detailed first simulation tutorial to use the composite-model/object API.
  It now introduces `CompositeModel`, `Object`, `ModelSpec`, `AppliesTo`, `TimeStep`,
  compiled applications, inferred same-object bindings, model outputs, and a
  migration note for historical examples.
- Rewrote the quick examples page to use native composite-model/object snippets for
  Beer light interception, degree-days/LAI/light coupling, biomass growth, and
  retained `OutputRequest` exports. Historical mapping usage is confined to
  migration records.
- Rewrote the standard model coupling, model switching, and coupling more
  complex models tutorials around the composite-model/object API. These pages now show
  inferred same-object value bindings, switching one `ModelSpec` application,
  execution-plan explanations, and `Calls(...)` manual-call wiring.
- Removed legacy mapping transforms and their runtime implementations:
  `MultiScaleModel`, `SameScale`, `TimeStepModel`, `InputBindings`,
  `MeteoBindings`, `MeteoWindow`, and `ScopeModel`.
- Added a curated unified composite-model/object map to the public API page.
