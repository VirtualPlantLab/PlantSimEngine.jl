# Unified CompositeModel/Object Implementation Plan

This plan is the persistent handoff for replacing the historical
multiscale-mapping system with one composite-model/object address system.

The implementation can be incremental internally, but the target API is
breaking. Do not preserve experimental intermediate APIs as user-facing
concepts in the final design.

The target public surface should be centered on a small set of concepts:

```julia
ModelSpec(
    model;
    name=:application,
    on=Many(scale=:Leaf),
    inputs=(...),
    calls=(...),
    every=Dates.Hour(1),
    environment=Environment(...),
    output_routing=(...),
    updates=Updates(...),
)
```

This is the API memory target for users, modelers, and agents. Additional
types should be selectors, model traits, or internal compiled carriers.

## Implementation Progress

- Started Phase 0 by adding typed application metadata, now constructed
  directly with `ModelSpec` keywords.
- Added `ModelSpec(model; name=...)` application names and getters:
  `application_name`, `applies_to`, `value_inputs`, `model_calls`, and
  `environment_config`.
- Added initial selector and address types:
  `SceneScope`, `Self`, `SelfPlant`, `Ancestor`, `Scope`, `Kind`, `Species`,
  `Scale`, `Relation`, `One`, `OptionalOne`, `Many`, and `ObjectAddress`.
- Added initial `CompositeModel`/`Object` registry types and lifecycle hooks:
  `register_object!`, `remove_object!`, `reparent_object!`, `move_object!`,
  and `Advanced.refresh_bindings!`.
- Added registry-backed selector resolution with `resolve_object_ids` and
  `resolve_objects` for `SceneScope()`, `Self()`, `SelfPlant()`,
  `Ancestor(...)`, `Scope(...)`, positional selectors such as
  `Kind(:plant)`/`Scale(:Leaf)`, and `One`/`OptionalOne`/`Many` cardinality
  checks.
- Added `explain_scopes(model)` for agent-readable scope diagnostics. It
  reports the global model scope, each object subtree, each named
  `Scope(...)`, and label groups by scale, kind, and species with concrete
  resolved object ids.
- Selector cardinality and named-scope failures now report the consumer
  context, matched object ids, requested criteria, available scales, kinds,
  species, and names inside the resolved scope, plus bounded edit-distance
  suggestions.
- `Relation(...)` selectors now resolve `:self`, `:parent`, `:children`,
  `:ancestors`, `:descendants`, and `:siblings` relative to the consuming
  object. Explicit scopes constrain relation results, default dependency scopes
  do not erase parent/sibling queries, and compiled `ModelSpec(...; inputs=...)` can use these
  relations without runtime selector resolution.
- `ObjectAddress(selector)` now normalizes positional `Kind`, `Species`,
  `Scale`, scope, and `Relation` selectors instead of recording only keyword
  criteria.
- Started the object-address compiler with `Advanced.compile_composite_model(model, specs)` and
  compiled model application/binding carriers. The compiler now resolves
  `ModelSpec(...; on=...)` target object ids, object-relative `ModelSpec(...; inputs=...)` source
  object ids, and object-relative `ModelSpec(...; calls=...)` callee object/application ids
  before runtime.
- Added `explain_applications`, `explain_bindings`, and `explain_calls`
  for the compiled model view. These explanations expose application ids,
  processes, target ids, input source ids, call callee ids, temporal policy,
  window, and carrier hints.
- Added status-backed compiled input carriers. When source objects already
  hold `Status` values, `ModelSpec(...; inputs=...)` bindings now precompile a scalar shared
  `Ref`, a homogeneous `RefVector`, or an `Advanced.ObjectRefVector` fallback for
  heterogeneous reference-preserving vectors. `input_carrier`, `input_value`,
  and `has_reference_carrier` expose these carriers, and `explain_bindings`
  reports carrier kind, copy/reference semantics, carrier type, and reference
  availability.
- Added conservative same-object input inference in the model compiler. When a
  model declares an `inputs_` variable that is not covered by explicit/default
  `ModelSpec(...; inputs=...)`, and exactly one other application on the same object outputs
  the same variable, `Advanced.compile_composite_model` creates an inferred reference binding.
  `explain_bindings` now reports binding `origin` values such as
  `:model_default`, `:model_spec`, and `:inferred_same_object`.
- Compiled input bindings now carry producer metadata. When an `ModelSpec(...; inputs=...)`
  selector uses `process=` or `application=`, `Advanced.compile_composite_model` validates that a
  matching source application exists for the selected source objects.
  `explain_bindings` reports `source_application_ids`, `process`, and
  `application` for agent-readable dependency diagnostics.
- Dependency selectors in `ModelSpec(...; inputs=...)` and `ModelSpec(...; calls=...)` now infer a default
  scope from the consumer object when no explicit `within=...` is provided:
  model objects default to `SceneScope()`, while non-model objects default to
  `Self()`. Shared model/soil dependencies from organs should therefore use
  `within=SceneScope()` explicitly.
- `Advanced.compile_composite_model` now validates `Required(T)` status inputs
  from `inputs_(model)`. Each required input must either have a compiled
  binding or already exist on the target object `Status`; otherwise
  compilation errors with the concrete application id, object id, and input
  variable.
- CompositeModel compilation creates an empty `Status` for model-targeted
  objects when status is omitted, inserts missing `outputs_` fields and
  `Default(value)` inputs from their initial values, and installs explicitly or
  implicitly bound input carriers. Unbound `Required(T)` inputs remain
  compilation errors.
- `Advanced.compile_composite_model` now rejects `ModelSpec(...; inputs=...)` declarations whose left-hand
  variable is not declared by the target model's `inputs_`. This catches
  misspelled or stale scenario bindings before they create silent unused
  metadata.
- `Advanced.compile_composite_model` now validates source availability for status-backed
  non-temporal `ModelSpec(...; inputs=...)` bindings. When selected source objects already
  have `Status` values, the requested source variable must resolve to
  references instead of silently compiling to an unused/no-op binding.
- Carrier compilation preserves source `Status` references and arbitrary value
  types; tests cover scalar refs, heterogeneous many-object vectors, and a
  homogeneous dual-like `BigFloat` value through `RefVector`, model arithmetic,
  source mutation, and typed output publication.
- Same-object renaming is supported directly by `ModelSpec(...; inputs=...)`, for example
  `inputs=(:renamed_signal => One(within=Self(), var=:signal),)`. The compiler
  aliases the source `Ref`, records the renamed source variable in
  `explain_bindings`, and schedules the producer before the consumer.
- Same-rate input carriers are installed directly into consumer `Status`
  reference cells during model compilation. Scalar bindings share the source
  `Ref`; many-object bindings store the compiled `RefVector` or
  `Advanced.ObjectRefVector` once. The timestep runtime performs no assignment for
  these bindings, and a focused `Many(...)` materialization gate verifies zero
  allocations after compilation.
- Reference wiring adds a missing bound input field to the consumer `Status`
  schema when needed, instead of requiring users to duplicate compiler-owned
  input placeholders.
- Added call ambiguity validation in the compiled model view: a call can select
  by process when unique, and must use `application=:name` when several model
  applications with the same process match the same object.
- Added a model binding cache with `Advanced.refresh_bindings!`, `Advanced.bindings_dirty`,
  `Advanced.compiled_bindings`, and `Advanced.model_revision`. Object creation, removal,
  and reparenting now invalidate the compiled binding cache and bump a model
  revision before the next refresh.
- Added an environment binding cache with `Advanced.refresh_environment_bindings!`,
  `Advanced.compile_environment_bindings`, `Advanced.CompiledEnvironmentBinding`,
  `Advanced.CompiledEnvironmentBindings`, `Advanced.environment_bindings_dirty`,
  `Advanced.compiled_environment_bindings`, `Advanced.environment_revision`, and
  `explain_environment_bindings`. The compiler resolves each
  application/object environment provider, backend, required
  `environment_inputs_`, support descriptor, and backend cell before runtime.
- Added the minimal model geometry contract: `geometry(object_or_status)`,
  `position(object_or_status)`, and `bounds(object_or_status)`. Environment
  binding refreshes now call `update_index!(backend, entities)` once per
  distinct backend before `Advanced.bind_environment`, giving spatial backends a current
  model-wide object/entity list for precomputed microclimate lookup.
- Automatic spatial binding now uses the nearest ancestor geometry when a
  target object has no geometry of its own. Existing backends still receive an
  `Object` carrying the target id/status, while its binding-time geometry comes
  from the ancestor. Explanations report `geometry_source=:self`, `:ancestor`,
  or `:global` and the source object id.
- Moving an object invalidates environment bindings for descendants that
  inherit its geometry, stopping at descendants with their own geometry. This
  preserves unaffected cached bindings.
- Environment refresh now reconciles model environment contracts against
  cached spatial bindings. If only `environment_inputs_` changes while application
  id, object, process, provider, backend, status, and geometry provenance remain
  unchanged, required metadata is updated while the cached cell is reused
  without `update_index!` or `Advanced.bind_environment`.
- `validate_environment_inputs(model)` and
  `validate_environment_inputs(compiled_scene, environment_or_backend)` now validate
  composite-model/object model application `environment_inputs_` against the active
  environment or an explicit replacement. Errors report model application ids,
  so duplicate process applications remain diagnosable.
- `Environment(; sources=(target=:source,))` now remaps model-facing
  environment variables to backend source variables. Environment binding
  refresh validates missing source variables when the backend can enumerate its
  variables, and `explain_environment_bindings` reports both `required_inputs`
  and `source_inputs`.
- CompositeModel applications now infer model-author default environment source remaps
  from `environment_hint(...).bindings` when the scenario does not provide explicit
  environment bindings. Scenario `Environment(; sources=...)` keeps precedence over
  the trait.
- Global tabular meteorology is now sampled at each model application's
  compiled clock. `environment_hint(...).bindings` reducers and windows are applied
  through PlantMeteo, while `Environment(; sources=...)` replaces only the
  source variable and preserves the selected reducer. Prepared weather
  samplers are shared by applications using the same weather table, and each
  application/timestep sample is cached once per run so all target objects
  reuse it.
- Object creation, removal, and reparenting invalidate both structural and
  environment bindings. Object movement invalidates only environment bindings,
  so moving a leaf or changing its geometry can refresh microclimate lookup
  without rebuilding object/model binding carriers.
- Added public geometry invalidation helpers:
  `update_geometry!(model, object, geometry; invalidate_environment=true)`
  and object-scoped `mark_environment_binding_dirty!(model, object)`.
  Geometry-only changes record the affected object ids and refresh only their
  compiled environment bindings; descendants inheriting moved ancestor
  geometry are invalidated as part of the same object-scoped refresh.
- Started composite-model/object execution with `run!(model; steps=...)`.
  The runtime refreshes compiled object bindings and environment bindings,
  materializes precompiled `ModelSpec(...; inputs=...)` carriers into consumer `Status`
  fields, samples the bound environment backend, and calls generic model
  kernels through the existing `run!` contract.
- CompositeModel/object execution now publishes model outputs to model-local temporal
  streams. Compiled `ModelSpec(...; inputs=...)` bindings marked as `:temporal_stream` can
  materialize `HoldLast`, `Interpolate`, `Integrate`, and `Aggregate` values
  before the consumer runs, using selector source ids, source variables,
  windows, and the model base timestep.
- CompositeModel temporal `ModelSpec(...; inputs=...)` now honor producer `output_policy(...)` traits
  when the selector omits `policy=...` and resolves to a unique source
  application. Explicit selector policies remain scenario-level overrides.
- CompositeModel `Interpolate(...)` matches the established multirate runtime:
  bracketed samples use linear interpolation, online consumers use linear
  extrapolation from the last two samples when requested, and insufficient or
  non-interpolable values fall back to hold-last. `mode=:hold` and
  `extrapolation=:hold` are supported, invalid modes fail during model
  compilation, and interpolation arithmetic preserves generic numeric value
  types without converting model values to `Float64`.
- Unified `ModelSpec(...; inputs=...)` now supports explicit lagged dependencies with
  `PreviousTimeStep(:input) => selector`. Lagged bindings use temporal streams,
  read source samples at or before `t - 1`, preserve the initialized consumer
  status value until history exists, and do not add a same-timestep scheduling
  edge. This allows feedback cycles to compile without changing generic model
  kernels.
- CompositeModel/object execution now exposes explicit mutable environment
  commits through `commit_environment!(context, accepted_state)` and
  non-committing trial sampling through
  `run_call!(context, name; environment=trial_state)`.
  Meteorological state stays in the environment backend instead of being staged
  through same-named status values.
- Added root application scheduling from `ModelSpec(...; every=...)` using `Dates.Period`
  values and the model environment base step. `explain_schedule` on a
  `Advanced.CompiledCompositeModel` now reports each application clock, phase, timestep in base
  steps, timestep duration in seconds, and whether the application is scheduled
  as a root application or is manual-call-only.
- CompositeModel application scheduling now also honors a model's `timespec(...)` trait
  when `ModelSpec(...; every=...)` is omitted. Scenario-level `ModelSpec(...; every=...)` keeps
  precedence over the model trait, matching the established multirate runtime.
- CompositeModel application scheduling now validates `timestep_hint(...)` required
  bounds for base-step-derived clocks. Hints remain compatibility constraints;
  they do not override explicit `ModelSpec(...; every=...)` or non-default `timespec(...)`.
- `Advanced.compile_composite_model` now computes a stable topological application order from
  resolved `ModelSpec(...; inputs=...)` producer edges and `Updates(...)` writer-order edges.
  Inputs produced by manual-call-only applications are redirected to the parent
  application that owns the `ModelSpec(...; calls=...)` call stack. `run!(model)` uses this
  precompiled order instead of user declaration order, cycles fail at compile
  time, and `explain_schedule` reports `execution_index`.
- `Advanced.CompiledCompositeModel` now pre-indexes input and call bindings by
  `(application_id, object_id)`. Per-object input materialization and
  `call_targets` lookup uses these indexes instead of scanning every
  binding in the model at each model call.
- `Advanced.CompiledCompositeModel` now also pre-indexes applications by application id.
  Hard-call target resolution and stable ordered-application materialization
  use this index instead of scanning or rebuilding lookup dictionaries.
- `Advanced.CompiledEnvironmentBindings` now pre-indexes environment bindings by
  `(application_id, object_id)`. Environment sampling and mutable environment
  output scattering use direct lookup instead of scanning all environment
  bindings for every model invocation.
- Added `RunContext` and `CallTarget`. Models can retrieve manual
  `ModelSpec(...; calls=...)` targets with `call_targets(context, :name)` and execute
  them with `run_call!`, preserving explicit call-stack control in the
  composite-model/object runtime. Manual calls execute immediately under the parent call
  stack; applications selected by `ModelSpec(...; calls=...)` are skipped by the root
  `run!(model)` loop and only execute through `run_call!`.
- Added composite-model/object duplicate-writer validation. During `Advanced.compile_composite_model`, each
  `(object, output variable)` now has one canonical writer unless later
  writers declare `Updates(:var; after=...)`. The `after` token can match a
  previous application id/name or process, so scenario authors can express
  cases such as pruning after carbon allocation without changing either model
  implementation.
- Added `explain_writers(compiled)`. It reports each object/variable writer
  group, duplicate-writer status, writer application ids/processes, and the
  `Updates(...)` declarations used to validate ordered updates.
- Extended `explain_model_specs` rows with application name, target selector,
  value inputs, manual calls, and environment metadata.
- Started Phase 3 by compiling simple `ModelSpec(...; inputs=...)` declarations to typed
  scale/variable carriers, for example
  `inputs=(:x => Many(scale=:Leaf, var=:y),)`.
- Added model-level `Input(...)` defaults from `dep(model)` into
  `ModelSpec` value inputs. Scenario-level `ModelSpec(...; inputs=(...))`
  overrides those defaults before the native binding is compiled.
- Removed the intermediate scenario bridge after the composite-model/object compiler
  gained native `ModelSpec(...; inputs=...)` support. Manual value-transfer carriers are not
  retained as user-authored API.
- Removed the intermediate dependency resolver after `ModelSpec(...; calls=...)` became
  native composite-model/object metadata. Manual model execution now goes through
  `CallTargets`, `call_targets`, and `run_call!`.
- Added model-level `Call(...)` defaults from `dep(model)` into
  `ModelSpec` manual-call metadata. Scenario-level
  `ModelSpec(...; calls=(...))` overrides those defaults, and
  `dep(::ModelSpec)` excludes raw `Call(...)` trait entries so default calls
  are normalized through the same bridge as explicit calls.
- Migrated the MAESPA example's model energy-balance hard calls to
  scenario-level `ModelSpec(scene_model; calls=(...))`.
- Migrated the MAESPA example's model LAI leaf-area transfer to consumer-side
  `ModelSpec(LAIModel(...); inputs=(...))`.
- Started Phase 5 with `CompositeModelTemplate` and `ObjectInstance`. A template stores
  reusable composite-model/object `ModelSpec`s plus default object labels, and an
  instance mounts those specs inside one named object subtree.
- `CompositeModel(...)` accepts `ObjectInstance` values directly or through its
  `instances` keyword. An instance root can be an owned `Object` or the id of
  an object supplied separately to the model.
- Mounted template applications receive stable instance-prefixed application
  names and an implicit `Scope(instance_name)` on unqualified
  `ModelSpec(...; on=...)` selectors. Their `ModelSpec(...; inputs=...)`, `ModelSpec(...; calls=...)`, scheduling,
  writer validation, and execution use the normal compiled composite-model/object path.
- Instance overrides can replace one template application by application name
  or process. Overrides must be unambiguous and preserve process identity.
  Instances without overrides retain the exact shared model object from the
  template.
- Template labels fill missing `kind` and `species` metadata throughout the
  mounted subtree, while the root receives the instance name used by
  `Scope(...)`. Tests cover four instances, plant-local aggregation, shared
  model storage, and one process-level model override.
- Added explicit exceptional-organ overrides with
  `Override(object=..., application=... or process=..., model=...)` through
  `ObjectInstance(...; object_overrides=...)`. The override must resolve to one
  template application, belong to the instance subtree, and preserve process,
  input, output, and environment-variable declarations.
- Object overrides remain one logical model application: the compiler stores
  the selected replacement model by target object id. Dependency bindings,
  writer ownership, application names, and manual calls therefore remain
  unchanged, and no selector resolution occurs in the runtime loop.
- Parameter/model ownership is explicit. Templates retain user-supplied model
  and `parameters` objects by reference; unchanged instances share them.
  Instance and object overrides retain their user-supplied replacement model
  by reference. PlantSimEngine does not copy models or mutate model fields to
  merge parameter overrides.
- Same-concrete-type object overrides use a concretely typed object-to-model
  table. Structured application explanations report shared/per-object storage,
  concrete versus heterogeneous dispatch, overridden object ids, and model
  types.
- `CompositeModel` retains mounted instance metadata and `explain_instances(model)`
  reports each instance root, current subtree object ids, mounted application
  ids, instance/object overrides, template labels, and parameter ownership.
  `explain_objects(model)` also reports instance membership.
- New objects registered below an instance automatically inherit missing
  template `kind` and `species` labels. Instance explanations derive membership
  from the current topology, so growth, pruning, and reparenting do not leave a
  separate stale membership list.
- CompositeModel hard calls can run under temporary local meteorology with
  `run_call!(context, name; environment=local_state)`. Descendants sample the
  temporary state through normal environment bindings, while `publish=false`
  suppresses output publication and environment commits. This supports
  iterative microclimate solvers such as the MAESPA model energy-balance loop.
- Model kernels read their own parameters from the `model` argument. Generic
  hard-dependency kernels such as `Monteith` and `Fvcb` discover declared call
  targets through `call_targets` and execute them through `run_call!`.
- CompositeModel duplicate-writer validation now ignores manual-call-only applications
  when validating canonical root writers. This keeps hard-dependency children
  from being treated as independent root writers when they intentionally update
  the same object status inside their parent call stack.
- Added a unified composite-model/object MAESPA example path:
  `build_maespa_scene(...)` and `run_maespa_example(...)`.
  It uses `CompositeModelTemplate`, `ObjectInstance`, `on`, `inputs`, `calls`,
  and `every=Dates.Period` with two plant species, one shared soil object,
  model LAI, and model energy balance.
- `test/test-maespa-model-example.jl` verifies the unified composite-model/object
  MAESPA path.
- `run!(model)` now returns a `Simulation` wrapper with the mutated
  `CompositeModel`, compiled model bindings, compiled environment bindings, and the
  model-local temporal output streams. This keeps existing status mutation
  behavior but makes model outputs inspectable after a run.
- Added `outputs(sim::Simulation)`, `collect_outputs(sim)`, and
  `explain_outputs(sim)` for composite-model/object runs. The explanation reports object
  ids, variables, publishing application ids, sample counts, time bounds, and
  value types.
- `run!(model; tracked_outputs=...)` now accepts `OutputRequest` and returns
  requested model outputs through `collect_outputs(sim)` or
  `collect_outputs(sim, :request_name)`. CompositeModel requests are materialized from
  retained typed temporal streams after the run. They support `HoldLast`,
  `Interpolate`, `Integrate`, and `Aggregate`, `Dates.Period` export clocks,
  canonical-publisher inference when unique, explicit `process=...`
  selection, and dynamic objects over each object's own published sample
  interval.
- CompositeModel output requests now compile a publisher-level retention plan. With
  `tracked_outputs=nothing`, the model runtime retains all output streams for
  historical inspection. With explicit `tracked_outputs`, including an empty
  request vector, it retains only requested publisher streams plus streams
  required by temporal `ModelSpec(...; inputs=...)`. Dependency-only streams are pruned after
  publication to the compiled policy horizon: latest-only for `HoldLast`, the
  input window for `Integrate`/`Aggregate`, and enough source history for
  `Interpolate`/`PreviousTimeStep`. Explicitly requested streams retain their
  complete histories for post-run export. Export is therefore not yet fully
  online, but unrequested temporal dependencies no longer grow for the full
  simulation.
- Added `explain_output_retention(sim)` to report which application/variable
  streams are retained and whether the reason is default retention, an output
  request, or a temporal dependency. Dependency-only rows also report their
  compiled `retention_steps`; unbounded requested/default rows report
  `nothing`.
- CompositeModel temporal streams are now keyed by application id, object id, and
  variable. Multiple applications can publish the same variable on the same
  object without overwriting each other's stream samples.
- CompositeModel output-export tests now cover requested-output `DataFrame`
  materialization, canonical publisher inference when `process=` is omitted,
  rejection when only stream-only publishers exist, and ambiguity when an
  explicit process matches both a stream-only and a canonical publisher.
- CompositeModel `OutputRequest(...)` now accepts `application=...` to select an
  explicit application id/name when the same process is mounted more than
  once. Explicit application selection can retain and export a
  `:stream_only` publisher.
- Each model temporal stream owns a concrete `Vector{Tuple{Float64,T}}`
  selected from its first published value rather than boxing all values as
  `Any`. Output type changes fail explicitly, and `Interpolate`/`Integrate`
  tests verify `BigFloat` histories and reduced values remain `BigFloat`.
- CompositeModel `output_routing=(var=:stream_only,)` now matches the unified graph
  semantics: stream-only outputs are excluded from canonical writer validation
  and same-object input inference, while remaining available in output streams
  and explicit `inputs=(... One(application=:name), ...)` selections.
- `run!(model; steps=...)` now refreshes dirty structural bindings at timestep
  boundaries. Objects created, removed, or reparented by a model during one
  timestep update `ModelSpec(...; on=...)` target sets, input carriers, call targets,
  writer validation, and scheduling before the next timestep.
- Geometry-only mutations refresh environment bindings at the next timestep
  without recompiling structural bindings. The returned `Simulation`
  always contains final compiled structural and environment bindings, including
  mutations performed on the last step.
- Environment dirty tracking is now object-scoped for geometry-only changes.
  `move_object!`, `update_geometry!`, and
  `mark_environment_binding_dirty!(model, object)` retain unaffected compiled
  bindings and re-run `Advanced.bind_environment` only for applications targeting the
  changed object. Structural changes and provider-wide invalidation still
  rebuild the complete environment cache.
- Runtime lifecycle tests cover a model-created leaf joining a leaf
  application and plant-local `RefVector`, a pruned leaf leaving both before
  the next step, and a moved leaf switching mock microclimate cells.
- Root model execution now compiles contiguous homogeneous target batches.
  Each target prebinds its concrete model, `Status`, input-binding tuple, and
  environment binding. Runtime dispatch occurs once
  at the batch function barrier; the inner object loop is specialized on a
  concrete target type.
- Exceptional object overrides with another concrete model implementation
  become separate batches without changing stable object execution order.
  Structural or environment binding refresh recompiles the execution plan
  before the next timestep.
- Added `explain_execution_plan(scene_or_simulation)`. It reports batch object
  ids, concrete model/status/carrier types, batch sizes, and inner-loop dispatch
  semantics. A focused 128-leaf gate verifies zero allocations inside a warmed
  homogeneous no-output batch.
- Added `objects_from_mtg(root; ...)` and `CompositeModel(root::MultiScaleTreeGraph.Node;
  ...)`. Existing MTG topology is traversed once into the unified registry,
  preserving stable node-derived ids, parent relations, labels, geometry, and
  existing `:plantsimengine_status` objects through configurable accessors.

The composite-model/object compiler is executable: selectors normalize to object
addresses, resolve before runtime, and compile into reference, temporal, call,
writer, and environment carriers. The historical mapping compiler has been
removed.

## Phase 0: Public Contract Freeze

Goal: decide the small public vocabulary before implementing internals.

Define:

- `ModelSpec(model; name=nothing)` as the model-application wrapper.
- `ModelSpec(...; on=selector)` as the target object-set declaration.
- `ModelSpec(...; inputs=...)` for value dependencies.
- `ModelSpec(...; calls=...)` for manual call-stack dependencies.
- `Updates(...)` for rare ordered duplicate writers.
- `every=period::Dates.Period` and related multirate policies.
- `Environment(...)` for optional environment resolver/backend overrides.

Rules:

- a model kernel remains generic and declares `inputs_`, `outputs_`, optional
  `dep`, optional `environment_inputs_`, and `run!`;
- a model application decides where the kernel runs, at what rate, and how its
  inputs, calls, updates, outputs, and environment are bound;
- application ids are stable and can be generated from explicit `name`,
  process, object selector, and occurrence index;
- if several applications provide the same process on the same object set,
  selectors must disambiguate by application name or another explicit filter.

Acceptance tests:

- a model can be applied twice to the same leaf objects with different names;
- a dependency selector can choose by process when unique and by name when not;
- structured explanations expose model kernel type, process, application name,
  and target object ids.

## Phase 1: CompositeModel Object Registry

Goal: introduce the internal object model without changing public behavior yet.

Implement:

- `ObjectId` as the stable identity key for every runtime object.
- `ModelObject` metadata with labels:
  `scale`, `kind`, `species`, optional `name`, parent id, child ids, and
  optional geometry/position handle.
- `Advanced.ObjectRegistry` storing objects, parent/child relations, and indexes by
  label.
- adapters from existing MTG state into the registry:
  each selected root and each MTG node gets an object id;
  single-status simulations get one object with `scale=:Default`.
- object lifecycle hooks for add/remove/reparent that mirror the existing MTG
  runtime reindexing.

Acceptance tests:

- the MAESPA example registers five leaf objects, two plant objects, one soil
  object, and one model object;
- `status(sim, :plant_A, :Leaf)` and `status(sim, :Leaf)` can be expressed as
  registry queries;
- add/remove/reparent updates object registry relations and status views.

## Phase 2: Selector And Scope Language

Goal: make "which objects?" explicit and reusable.

Implement selector types:

```julia
SceneScope()
Self()
SelfPlant()
Ancestor(scale=:Plant)
Scope(name)
Kind(kind)
Species(species)
Scale(scale)
Relation(...)
```

Implement multiplicity wrappers:

```julia
One(selector...)
OptionalOne(selector...)
Many(selector...)
```

Selectors must normalize to `ObjectAddress` objects with enough context to be
resolved relative to a consuming object.

Implement `ModelSpec(...; on=...)` using the same selector system. The target object
set of a model application must never be hidden inside a mapping key or
implicit scale table.

Definitions:

- `Self()` means only the current model application object.
- `Subtree()` means the current object and its descendants.
- `SelfPlant()` means the nearest containing plant scope.
- `Ancestor(scale=:Plant)` is the generic selector form for `SelfPlant()`.
- `SceneScope()` means the whole model.
- `Scope(name)` means a named scope or object collection.

Rules:

- unqualified selectors inside a reusable plant application bundle default to
  `within=Self()`;
- model-level selectors default to `within=SceneScope()`;
- `One(...)` errors unless exactly one object resolves per consumer;
- `Many(...)` preserves stable object-id order;
- object-id order replaces incidental traversal order as the semantic default.
- selectors are resolved during compilation or binding refresh, not inside the
  inner model loop.

Acceptance tests:

- plant allocation on four oil palms reads only leaves under each plant;
- model LAI reads leaves across all plant objects;
- a species-specific model model can read only `species=:oil_palm` leaves;
- a model application target set declared with `ModelSpec(...; on=...)` produces stable
  application/object pairs;
- selector errors report available labels and near matches.

## Phase 3: Unified Value Inputs

Goal: use `ModelSpec(...; inputs=...)` as the only user-facing value-dependency declaration.
Historical `MultiScaleModel(...)` mappings are migration sources only.

Target API:

```julia
ModelSpec(AllocationModel(); on=Many(kind=:plant, scale=:Plant), inputs=(:leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)))

ModelSpec(LAIModel(area); on=One(scale=:Scene), inputs=(:leaf_areas => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_area)))
```

Implement:

- `ModelSpec(...; inputs=...)` as `ModelSpec` configuration.
- `Input(...)` or an equivalent internal wrapper that lets `dep(model)`
  provide default value-input bindings.
- normalized input bindings from target variable to `ObjectAddress`.
- compiler pass that decides carrier:
  direct reference, `RefVector`, temporal stream, or materialization.
- status-default insertion for materialized target variables using the
  consumer model's `inputs_` default.
- temporal policies on value inputs:
  `HoldLast`, `Interpolate`, `Integrate`, `Aggregate`.
- `Dates.Period` windows on value inputs, for example `window=Day(1)`.
- copy/reference semantics reporting for every compiled input binding.

Rules:

- model authors still declare `inputs_`; scenario authors decide where those
  inputs come from;
- `dep(model)` may provide defaults for common value-input bindings in
  composite-model/object composition;
- scenario-level `ModelSpec(...; inputs=(...))` always wins over `dep(model)`
  defaults;
- same-rate local links should keep reference semantics where possible;
- cross-rate links always go through temporal state;
- duplicate source candidates are errors unless the selector disambiguates;
- materialization carriers, when needed, are internal compiler details
  and are not user-authored structs;
- same-rate scalar and many-object links should avoid copies when they can use
  aliases, shared refs, `RefVector`, or an equivalent typed carrier;
- PlantSimEngine must preserve arbitrary value types, including units,
  automatic differentiation numbers, uncertainty wrappers, and other
  numeric-like values.

Carrier expectations:

| Binding kind | Runtime carrier |
| --- | --- |
| same-rate scalar | shared `Ref` or local alias |
| same-rate many-object | `RefVector` or equivalent typed reference collection |
| cross-rate | temporal stream sample |
| integrate/aggregate | temporal window reduction |
| materialized cross-object input | generated pre-run status assignment |
| environment | cached environment binding sample |

Acceptance tests:

- the MAESPA model LAI cross-object input is declared with `ModelSpec(...; inputs=...)` and
  produces the same `lai` and `leaf_area`;
- historical plant allocation `MultiScaleModel([:leaf_carbon => [:Leaf => :leaf_carbon]])`
  becomes `ModelSpec(...; inputs=...)` and remains plant-local;
- a same-scale rename currently expressed with `SameScale()` works through
  `ModelSpec(...; inputs=...)`;
- multi-rate value inputs integrate object streams by object id.
- same-rate many-object bindings do not allocate per timestep in a benchmarked
  hot loop beyond unavoidable model work.
- unitful or dual-number status values survive `ModelSpec(...; inputs=...)` without forced
  conversion to `Float64`.

## Phase 4: Unified Model Calls

Goal: use `ModelSpec(...; calls=...)` as the only user-facing manual model-call declaration.
The same mechanism must also be usable from `dep(model)` so hard-dependency
traits become default call declarations.

Target API:

```julia
ModelSpec(
    SceneEB();
    on=One(scale=:Scene),
    calls=(
        :leaf_energy =>
            Many(kind=:plant, scale=:Leaf, process=:energy_balance),
        :soil => One(kind=:soil, application=:soil_water),
    ),
)
```

Implement:

- `ModelSpec(...; calls=...)` as `ModelSpec` configuration.
- `Call(...)` or an equivalent internal wrapper that lets `dep(model)` provide
  default manual-call dependencies.
- call resolution from `ObjectAddress` to concrete `ModelCall` handles, or an
  equivalent callable runtime object if the final internal type name differs.
- same-status hard dependency calls using the same public API.
- publication semantics:
  trial `run_call!(call)` mutates status only;
  final `run_call!(call; publish=true)` appends outputs and temporal
  streams.
- structured call explanations with parent application id, selected callee
  application ids, selected object ids, selector, and publication behavior.

Rules:

- calls are manual call-stack dependencies and are not independently
  scheduled under the parent;
- `dep(model)` call defaults are model-author defaults, not final wiring;
- scenario-level `ModelSpec(...; calls=(...))` overrides `dep(model)` defaults;
- hard target outputs still participate in dependency graph compilation through
  the owning parent when needed;
- call selection must be visible through explanation helpers.

Acceptance tests:

- MAESPA model energy balance uses `ModelSpec(...; calls=...)` and still controls iterative
  leaf energy calls;
- missing call selectors report `kind`, `scale`, `process`, and available
  matches;
- final accepted calls publish exactly once per timestep.
- an iterative model model can run selected leaf and soil calls several times
  with `publish=false` and publish only the accepted state.

Implemented:

- `run_call!(::CallTarget)` defaults to `publish=false`, matching the
  iterative manual-call contract.
- One-shot accepted calls use `publish=true` explicitly.
- An iterative hard-call regression executes two default non-publishing trials
  followed by one accepted call and verifies exactly one environment write and
  one temporal output sample for the accepted state.
- `explain_calls(compiled)` reports
  `publication_policy=:explicit_accept`, `default_publish=false`, and
  `accepted_publish=true` for every compiled call edge.
- `ModelSpec` now retains per-binding provenance for value inputs and manual
  calls. Bindings from `dep(model)` are reported as `:model_default`,
  scenario-level `ModelSpec(...; inputs=...)` and `ModelSpec(...; calls=...)` are reported as `:model_spec`,
  and compiler-created same-object value links are reported as
  `:inferred_same_object`. `explain_bindings`, `explain_calls`, and
  `explain_model_specs` expose these origins for agent-readable diagnostics.
- Zero-match `OptionalOne(...)` dependencies remain compiled and visible.
  Optional inputs retain the consumer `inputs_` default with
  `carrier_kind=:optional_default`; optional calls expose an empty target set
  and `resolved=false` instead of failing compilation.

## Phase 5: Object Templates, Instances, And Overrides

Goal: support several plants of the same species with shared default models and
selective per-instance differences.

Target API:

```julia
oil_palm = CompositeModelTemplate(
    kind=:plant,
    species=:oil_palm,
    mapping=oil_palm_mapping,
)

model = CompositeModel(
    ObjectInstance(:palm_1, oil_palm; root=node1),
    ObjectInstance(:palm_2, oil_palm; root=node2, overrides=(
        stomatal_conductance = Tuzet(; g1=3.2),
    )),
)
```

Implement:

- template-level model specs and parameters;
- instance-level model/parameter overrides by process;
- object-level overrides for exceptional organs;
- conflict validation when two overrides target the same process/object.
- shared parameter/model storage when template instances do not override
  anything, with explicit copy/ownership behavior when they do.

Rules:

- templates do not prescribe topology; they attach mappings to whatever object
  tree the instance provides;
- default `Self()` selectors resolve inside the current instance;
- model-wide models must opt into wider scope.

Acceptance tests:

- four oil palm instances share model objects/parameters when not overridden;
- one palm instance can override one process parameter;
- allocation remains per plant while model LAI sees all leaves.

MAESPA status:

- the unified composite-model/object MAESPA path uses `CompositeModelTemplate` and
  `ObjectInstance` for species A and B.

## Phase 5B: Object Lifecycle And Cache Invalidation

Goal: make growth, pruning, and moving organs update every compiled binding
through one mutation path.

Implement public lifecycle hooks:

```julia
register_object!(model, object; parent)
remove_object!(model, object)
reparent_object!(model, object, new_parent)
move_object!(model, object, geometry_or_position)
Advanced.refresh_bindings!(model)
```

Implement invalidation for:

- object selector caches;
- model application target sets;
- `RefVector` or equivalent many-object carriers;
- temporal stream ownership;
- writer validation;
- environment bindings.

Rules:

- topology and geometry changes do not silently leave stale carriers;
- object creation should bind the new object to model applications selected by
  `ModelSpec(...; on=...)` before the next timestep;
- moving an object should refresh environment bindings without rebuilding
  unrelated model bindings unless the move changes object relations or labels.

Acceptance tests:

- creating a new leaf adds it to plant-local allocation and model LAI before
  the next timestep;
- pruning/removing a leaf removes it from many-object carriers and temporal
  stream ownership;
- changing a leaf insertion angle can refresh only the affected environment
  binding when topology is unchanged.

## Phase 6: Environment Binding Cache

Goal: make environment and microclimate sampling automatic and fast.

Implement:

- `EnvironmentBinding` cache:
  object id, backend/provider id, cell/layer id, required variables.
- default environment resolver:
  global environment data for non-spatial backends;
  object position for spatial backends;
  parent position fallback;
  global fallback or validation error.
- dirty flags and batched refresh:
  `mark_environment_binding_dirty!`;
  `update_geometry!(...; invalidate_environment=true)`;
  automatic dirty marking on object creation, removal, reparenting, and
  environment grid rebuild.
- explanation helper:
  `explain_environment_bindings(sim)`.
- minimal geometry accessors or traits:
  `position`, `geometry`, and `bounds`.
- backend protocol:
  `Advanced.bind_environment`, opaque handles, committed/transient `sample`,
  `commit_environment!`, and `update_index!`.
- `Environment(...)` overrides for scenario-specific resolver/backend choices.
- `Environment(; sources=(CO2=:Ca,))` for scenario-specific environment source
  remapping without changing model kernels.

Runtime rule:

```text
object -> cached binding -> backend cell/layer -> current environment values
```

Spatial lookup must happen only during binding refresh, not inside every model
call.

Acceptance tests:

- global environment data gives the same values to all objects;
- missing global environment variables fail during environment binding refresh when
  the backend can enumerate variables;
- `Environment(; sources=...)` remaps backend variables to model-facing
  `environment_inputs_` names and is visible in explanations;
- a model running every two hours over hourly global meteorology receives a
  windowed weather sample rather than only the current raw row;
- model `environment_hint` reducers/windows are honored, and an
  `Environment(; sources=...)` override changes the source without discarding
  the reducer;
- all objects targeted by one application reuse one global weather sample per
  application/timestep;
- mock grid backend binds leaves to cells once at initialization;
- moving one leaf marks only that leaf binding dirty and refreshes it before
  the next timestep;
- model `environment_inputs_` changes update required variables without recomputing
  spatial links unless necessary.
- `commit_environment!(context, accepted_state)` commits mutable microclimate
  state back to the active backend.

## Phase 7: Compiler, Scheduler, And Explanation Cleanup

Goal: make the unified graph the source of truth.

Implement:

- one compiler that builds a global dependency graph over object addresses;
- materialization and multiscale reference wiring as internal carriers;
- object/scope dependency scheduling;
- writer validation through the same graph, including `Updates(...)`;
- model application scheduling from `ModelSpec(...; on=...)` target sets;
- multirate scheduling based on `Dates.Period` values in `ModelSpec(...; every=...)` and
  input windows;
- typed compiled bindings that avoid selector resolution in timestep hot loops;
- typed homogeneous execution batches that move dynamic dispatch outside the
  per-object inner loop while preserving ordered heterogeneous overrides;
- arbitrary value type preservation through status, input carriers, temporal
  storage, and environment samples;
- structured explanation:
  `explain_objects`, `explain_scopes`, `explain_bindings`,
  `explain_calls`, `explain_environment_bindings`, `explain_schedule`,
  `explain_writers`.

Acceptance tests:

- old `MultiScaleModel` examples rewritten with `ModelSpec(...; inputs=...)` produce matching
  outputs;
- historical cross-object examples rewritten with `ModelSpec(...; inputs=...)` produce
  matching outputs;
- MAESPA hard-call example rewritten with `ModelSpec(...; calls=...)` produces matching
  outputs;
- explanation helpers include enough concrete object ids, scales, processes,
  and variables for an AI agent to repair bad mappings.
- `explain_bindings(sim)` reports whether each dependency came from inference,
  `dep(model)`, or `ModelSpec`, and reports carrier/copy semantics.
- no selector resolution occurs inside the per-object, per-model timestep loop
  for static composite models.
- a warmed homogeneous execution batch performs no allocations beyond model,
  output-stream, or backend work requested by the application itself;
- multirate simulations use the same object-address graph as same-rate
  simulations.

## Phase 8: Breaking API Removal And Migration Docs

Goal: remove the old configuration surface once parity is proven.

Removed:

- `MultiScaleModel(...)` as public scenario configuration;
- superseded scenario containers and value-transfer authoring;
- superseded manual-dependency selectors.

Write migration notes:

- `MultiScaleModel([:x => [:Leaf => :y]])` -> `inputs=(:x => Many(scale=:Leaf, var=:y),)`;
- cross-object value declarations -> consumer `ModelSpec(...; inputs=...)`;
- manual dependency declarations -> `ModelSpec(...; calls=...)`;
- repeated species assemblies -> `CompositeModelTemplate` plus `ObjectInstance`;
- explicit environment wiring -> environment resolver/binding backend.
- `InputBindings(...)` -> source and temporal policy information inside
  `ModelSpec(...; inputs=...)`;
- `MeteoBindings(...)` and `MeteoWindow(...)` -> `Environment(...)` and
  environment sampling/window policy;
- `ModelSpec(...; output_routing=...)` -> model-application output policy;
- `PreviousTimeStep(...)` -> temporal policy/cycle-breaking marker in the
  unified graph;
- `ScopeModel(...)` -> `ModelSpec(...; on=...)` plus selector scope.

Regression tests must cover all migrated examples before removal.

Migration documentation progress:

- Added `docs/src/migration_composite_model.md` with direct translations for
  `MultiScaleModel`, repeated object assemblies,
  `TimeStepModel`, `InputBindings`, `MeteoBindings`, `ScopeModel`, and
  `SameScale`.
- Documentation navigation and the home page now identify the composite-model/object API
  as the target for new multiscale and multi-plant work.
- The documentation home page now uses executable composite-model/object examples as the
  primary quickstart. It shows `CompositeModel`, `Object`, `ModelSpec`, `on`,
  `inputs`, `every`, automatic same-object binding inference, multi-object
  `Many(...)` inputs, and manual `ModelSpec(...; calls=...)` syntax.
- The repository README now mirrors the composite-model/object entry point instead of
  teaching `ModelMapping` first. It includes smoke-tested `CompositeModel`/`Object`
  quickstart code, `ModelSpec(...; inputs=...)` multi-object coupling, conceptual
  `ModelSpec(...; calls=...)` syntax, and links to the migration guide.
- Added `docs/src/composite_model/quickstart.md` as the first native
  composite-model/object tutorial page and promoted it in the documentation navigation.
  The page contains docs-tested examples for one-object model chaining,
  inferred same-object bindings, `OutputRequest` retention, multi-object
  `ModelSpec(...; inputs=...)`, `RefVector` carrier explanations, and manual `ModelSpec(...; calls=...)`
  syntax.
- The repository agent skill teaches the unified public vocabulary.
- The public API page now starts with curated composite-model/object groups for scenario
  construction, selectors, coupling, lifecycle, environment, runtime, and
  structured explanations.

Current removal audit:

- The unreleased intermediate scenario and runtime subsystem has been deleted,
  including its carriers, dependency selectors, target helpers, tests,
  examples, and documentation.
- Public manual-call control now uses vector-like `CallTargets`,
  `run_call!(context, name)`, `call_targets`, and `run_call!(target)`.
- `RunContext` defines Symbol-named `run_call!` and `call_targets` directly.
- The legacy mapping transforms are removed:
  `MultiScaleModel`, `SameScale`, `TimeStepModel`, `InputBindings`,
  `MeteoBindings`, `MeteoWindow`, and `ScopeModel` are not retained as
  compatibility constructors.
- `ModelMapping` is removed. Retained documentation mentions it only as
  historical migration context.
- Historical MTG mapping and mapping-level multirate pages were removed from
  the active documentation navigation. A future documentation cleanup can
  replace
  these historical pages with equivalent composite-model/object tutorials rather than
  retaining them as migration reference.
- The model execution page has been rewritten as a composite-model/object-first guide.
  It now documents compilation, same-rate reference carriers, temporal
  `ModelSpec(...; inputs=...)`, manual `ModelSpec(...; calls=...)`, `Updates(...)`, `ModelSpec(...; every=...)`,
  environment binding, output retention, lifecycle cache invalidation, and
  compatibility translations from the historical mapping runtime.
- The detailed first simulation tutorial now starts from the composite-model/object API
  instead of `ModelMapping`. It introduces model kernels, object status,
  compiled applications, inferred same-object bindings, model outputs, and a
  short compatibility note for historical mapping examples.
- The quick examples page now uses copy-pasteable composite-model/object examples for
  Beer light interception, degree-days/LAI/light coupling, biomass growth, and
  retained `OutputRequest` exports. `ModelMapping` appears only in the
  compatibility note.
- The standard model coupling, model switching, and coupling more complex
  models step-by-step tutorials now teach `CompositeModel`, `Object`, `ModelSpec`,
  `on`, `every`, inferred soft `ModelSpec(...; inputs=...)`, and manual
  `ModelSpec(...; calls=...)` first. Historical `PlantSimEngine.ModelMapping(...)` appears
  only in compatibility notes on those pages.
- The home page has been replaced by native composite-model/object examples. The
  repository README has also been replaced by native composite-model/object examples,
  and a dedicated composite-model/object quickstart is now available in the main
  documentation navigation.
- CompositeModel/object tests cover scheduling, temporal policies, binding inference
  and overrides, environment contracts and aggregation, output routing and
  application-qualified export, and structured explanations. Legacy mapping
  regression tests were removed with the old runtime.
- CompositeModel/object tests now include public environment-contract validation parity for
  missing environment variables, explicit `Environment(; sources=...)`
  remapping, model-author `environment_hint` source defaults, and validation against
  an explicit replacement environment object/backend.
- Test code uses the canonical `ModelSpec(...; every=...)` spelling and composite-model/object
  modifiers. Legacy transform tests were removed with the old compatibility
  constructors.
- The unified MAESPA path is implemented and tested through `on`,
  `inputs`, `calls`, `call_targets`, and `run_call!`.

## Resolved API Decisions

- `SceneScope`, `Self`, `SelfPlant`, `Kind`, `Species`, and `Scale` are the
  public selector names.
- `ModelSpec(...; inputs=...)` is the only scenario-level value-binding
  construction form.
- `ModelSpec(...; every=...)` is the canonical timestep configuration.
- `Environment(...)` owns provider/resolver/source configuration. Temporal
  value windows belong to the consuming `ModelSpec(...; inputs=...)` selector.
- Object templates own reusable model applications and parameters, not plant
  topology construction. They consume explicit object trees or MTGs adapted
  through `objects_from_mtg`.
- The old multiscale and mapping-transform implementations have been removed.

## Completion Evidence

The requirement-by-requirement evidence and final verification commands are
recorded in `composite_model_completion_audit.md`.
