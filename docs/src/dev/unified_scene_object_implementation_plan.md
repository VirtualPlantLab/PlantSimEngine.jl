# Unified Scene/Object Implementation Plan

This plan is the persistent handoff for replacing the current domain/route and
multiscale-mapping split with one scene/object address system.

The implementation can be incremental internally, but the target API is
breaking. Do not try to preserve `MultiScaleModel(...)`, `Route(...)`,
`AllDomains(...)`, or `HardDomains(...)` as primary user-facing concepts in the
final design.

The target public surface should be centered on a small set of concepts:

```julia
Scene
Object
ModelSpec

AppliesTo(...)
Inputs(...)
Calls(...)
Updates(...)
TimeStep(...)
Environment(...)
```

This is the API memory target for users, modelers, and agents. Additional
types should be selectors, model traits, or internal compiled carriers.

## Current State To Preserve Until Replacement

The current experimental branch already implements useful behavior:

- `Domain`, `SimulationMapping`, and `DomainSimulation`;
- single-status and MTG-backed domains;
- graph-domain selectors for several plant instances/species;
- `Route(...)` materialization into scene status;
- `AllDomains(...)` stream/value dependencies;
- `HardDomains(...)` targets and `run_target!`;
- multi-rate domain scheduling with `Dates`;
- environment backend protocol and constant meteo backend;
- dynamic MTG add/remove/reparent support;
- `Updates(...)` for ordered duplicate writers;
- structured domain explanation helpers.

Those features are the behavioral test bed for the new design. The new API
should reproduce the same capabilities through unified object selections.

## Implementation Progress

- Started Phase 0 by adding the public API vocabulary as real typed metadata:
  `AppliesTo(...)`, `Inputs(...)`, `Calls(...)`, `TimeStep(...)`, and
  `Environment(...)` can now be applied to `ModelSpec`.
- Added `ModelSpec(model; name=...)` application names and getters:
  `application_name`, `applies_to`, `value_inputs`, `model_calls`, and
  `environment_config`.
- Added initial selector and address types:
  `SceneScope`, `Self`, `SelfPlant`, `Ancestor`, `Scope`, `Kind`, `Species`,
  `Scale`, `Relation`, `One`, `OptionalOne`, `Many`, and `ObjectAddress`.
- Added initial `Scene`/`Object` registry types and lifecycle hooks:
  `register_object!`, `remove_object!`, `reparent_object!`, `move_object!`,
  and `refresh_bindings!`.
- Added registry-backed selector resolution with `resolve_object_ids` and
  `resolve_objects` for `SceneScope()`, `Self()`, `SelfPlant()`,
  `Ancestor(...)`, `Scope(...)`, positional selectors such as
  `Kind(:plant)`/`Scale(:Leaf)`, and `One`/`OptionalOne`/`Many` cardinality
  checks.
- Added `explain_scopes(scene)` for agent-readable scope diagnostics. It
  reports the global scene scope, each object subtree, each named
  `Scope(...)`, and label groups by scale, kind, and species with concrete
  resolved object ids.
- Started the object-address compiler with `compile_scene(scene, specs)` and
  compiled scene application/binding carriers. The compiler now resolves
  `AppliesTo(...)` target object ids, object-relative `Inputs(...)` source
  object ids, and object-relative `Calls(...)` callee object/application ids
  before runtime.
- Added `explain_scene_applications`, `explain_bindings`, and `explain_calls`
  for the compiled scene view. These explanations expose application ids,
  processes, target ids, input source ids, call callee ids, temporal policy,
  window, and carrier hints.
- Added status-backed compiled input carriers. When source objects already
  hold `Status` values, `Inputs(...)` bindings now precompile a scalar shared
  `Ref`, a homogeneous `RefVector`, or an `ObjectRefVector` fallback for
  heterogeneous reference-preserving vectors. `input_carrier`, `input_value`,
  and `has_reference_carrier` expose these carriers, and `explain_bindings`
  reports carrier kind, copy/reference semantics, carrier type, and reference
  availability.
- Added conservative same-object input inference in the scene compiler. When a
  model declares an `inputs_` variable that is not covered by explicit/default
  `Inputs(...)`, and exactly one other application on the same object outputs
  the same variable, `compile_scene` creates an inferred reference binding.
  `explain_bindings` now reports binding `origin` values such as
  `:declared` and `:inferred_same_object`.
- Compiled input bindings now carry producer metadata. When an `Inputs(...)`
  selector uses `process=` or `application=`, `compile_scene` validates that a
  matching source application exists for the selected source objects.
  `explain_bindings` reports `source_application_ids`, `process`, and
  `application` for agent-readable dependency diagnostics.
- Dependency selectors in `Inputs(...)` and `Calls(...)` now infer a default
  scope from the consumer object when no explicit `within=...` is provided:
  scene objects default to `SceneScope()`, while non-scene objects default to
  `Self()`. Shared scene/soil dependencies from organs should therefore use
  `within=SceneScope()` explicitly.
- `compile_scene` now validates required status inputs from `inputs_(model)`.
  Each required input must either have a compiled binding or already exist on
  the target object `Status`; otherwise compilation errors with the concrete
  application id, object id, and input variable.
- `compile_scene` now rejects `Inputs(...)` declarations whose left-hand
  variable is not declared by the target model's `inputs_`. This catches
  misspelled or stale scenario bindings before they create silent unused
  metadata.
- `compile_scene` now validates source availability for status-backed
  non-temporal `Inputs(...)` bindings. When selected source objects already
  have `Status` values, the requested source variable must resolve to
  references instead of silently compiling to an unused/no-op binding.
- Carrier compilation preserves source `Status` references and arbitrary value
  types; tests cover both scalar refs and many-object vectors with a custom
  non-`Float64` value type.
- Added call ambiguity validation in the compiled scene view: a call can select
  by process when unique, and must use `application=:name` when several model
  applications with the same process match the same object.
- Added a scene binding cache with `refresh_bindings!`, `bindings_dirty`,
  `compiled_bindings`, and `scene_revision`. Object creation, removal,
  and reparenting now invalidate the compiled binding cache and bump a scene
  revision before the next refresh.
- Added an environment binding cache with `refresh_environment_bindings!`,
  `compile_environment_bindings`, `CompiledEnvironmentBinding`,
  `CompiledEnvironmentBindings`, `environment_bindings_dirty`,
  `compiled_environment_bindings`, `environment_revision`, and
  `explain_environment_bindings`. The compiler resolves each
  application/object environment provider, backend, required
  `meteo_inputs_`, produced `meteo_outputs_`, support descriptor, and backend
  cell before runtime.
- Added the minimal scene geometry contract: `geometry(object_or_status)`,
  `position(object_or_status)`, and `bounds(object_or_status)`. Environment
  binding refreshes now call `update_index!(backend, entities)` once per
  distinct backend before `bind_environment`, giving spatial backends a current
  scene-wide object/entity list for precomputed microclimate lookup.
- Object creation, removal, and reparenting invalidate both structural and
  environment bindings. Object movement invalidates only environment bindings,
  so moving a leaf or changing its geometry can refresh microclimate lookup
  without rebuilding object/model binding carriers.
- Added public geometry invalidation helpers:
  `update_geometry!(scene, object, geometry; invalidate_environment=true)`
  and object-scoped `mark_environment_binding_dirty!(scene, object)`.
  These currently route to the scene environment binding cache invalidation;
  finer-grained per-object dirty tracking can be added behind the same API.
- Started scene/object execution with `run!(scene; steps=...)`.
  The runtime refreshes compiled object bindings and environment bindings,
  materializes precompiled `Inputs(...)` carriers into consumer `Status`
  fields, samples the bound environment backend, and calls generic model
  kernels through the existing `run!` contract.
- Scene/object execution now publishes model outputs to scene-local temporal
  streams. Compiled `Inputs(...)` bindings marked as `:temporal_stream` can
  materialize `HoldLast`, `Integrate`, and `Aggregate` values before the
  consumer runs, using selector source ids, source variables, windows, and the
  scene base timestep.
- Scene/object execution now scatters mutable environment outputs declared by
  `meteo_outputs_(model)` back to the bound backend after each model call.
  This reuses `scatter_environment_outputs!`, so environment writers keep the
  existing generic model contract: compute a same-named status value, and let
  the runtime push it to the active microclimate backend.
- Added root application scheduling from `TimeStep(...)` using `Dates.Period`
  values and the scene environment base step. `explain_schedule` on a
  `CompiledScene` now reports each application clock, phase, timestep in base
  steps, timestep duration in seconds, and whether the application is scheduled
  as a root application or is manual-call-only.
- Added `SceneRunContext` and `SceneCallTarget`. Models can retrieve manual
  `Calls(...)` targets with `dependency_target(s)(extra, :name)` and execute
  them with `run_call!`, preserving explicit call-stack control in the
  scene/object runtime. Manual calls execute immediately under the parent call
  stack; applications selected by `Calls(...)` are skipped by the root
  `run!(scene)` loop and only execute through `run_call!`.
- Added scene/object duplicate-writer validation. During `compile_scene`, each
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
- Started Phase 3 by bridging simple `Inputs(...)` declarations into the
  existing MTG multiscale mapping carrier when the selector is representable as
  a pure scale/variable mapping, for example
  `Inputs(:x => Many(scale=:Leaf, var=:y))`.
- Added model-level `Input(...)` defaults from `dep(model)` into
  `ModelSpec` value inputs. Scenario-level `ModelSpec(...) |> Inputs(...)`
  overrides those defaults and also replaces the corresponding internal legacy
  mapping carrier for the same input.
- Extended the Phase 3 bridge for domain simulations by generating internal
  `Route(...)` carriers from supported consumer-side `Inputs(...)`
  declarations, for example
  `Inputs(:leaf_areas => Many(kind=:plant, scale=:Leaf, process=:leaf_state, var=:leaf_area))`.
- Started Phase 4 by bridging `Calls(...)` declarations into the current
  hard-domain dependency resolver when selectors can be represented by
  `kind`, `domain`, `scale`, and `process`. Added `run_call!` as the unified
  spelling over the current `ModelTarget` execution path.
- Added model-level `Call(...)` defaults from `dep(model)` into
  `ModelSpec` manual-call metadata. Scenario-level
  `ModelSpec(...) |> Calls(...)` overrides those defaults, and
  `dep(::ModelSpec)` excludes raw `Call(...)` trait entries so default calls
  are normalized through the same bridge as explicit calls.
- Migrated the MAESPA example's scene energy-balance hard calls from
  model-level `HardDomains(...)` to scenario-level
  `ModelSpec(scene_model) |> Calls(...)`.
- Migrated the MAESPA example's scene LAI leaf-area route from user-written
  `Route(...)` to consumer-side `ModelSpec(LAIModel(...)) |> Inputs(...)`.

This progress is still a bridge over the existing compiler, not the final
object-address compiler. Supported `Inputs(...)` and `Calls(...)` selectors are
translated to current carriers where possible. Unsupported object-relative
selectors remain structured metadata until the object-address compiler lands.

## Phase 0: Public Contract Freeze

Goal: decide the small public vocabulary before implementing internals.

Define:

- `ModelSpec(model; name=nothing)` as the model-application wrapper.
- `AppliesTo(selector)` as the target object-set declaration.
- `Inputs(...)` for value dependencies.
- `Calls(...)` for manual call-stack dependencies.
- `Updates(...)` for rare ordered duplicate writers.
- `TimeStep(period::Dates.Period)` and related multirate policies.
- `Environment(...)` for optional environment resolver/backend overrides.

Rules:

- a model kernel remains generic and declares `inputs_`, `outputs_`, optional
  `dep`, optional `meteo_inputs_`/`meteo_outputs_`, and `run!`;
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

## Phase 1: Scene Object Registry

Goal: introduce the internal object model without changing public behavior yet.

Implement:

- `ObjectId` as the stable identity key for every runtime object.
- `SceneObject` metadata with labels:
  `scale`, `kind`, `species`, optional `name`, parent id, child ids, and
  optional geometry/position handle.
- `SceneRegistry` storing objects, parent/child relations, and indexes by
  label.
- adapters from the current MTG/domain state into the registry:
  each selected domain root and each MTG node gets an object id;
  single-status domains get one object with `scale=:Default`.
- object lifecycle hooks for add/remove/reparent that mirror the existing MTG
  runtime reindexing.

Acceptance tests:

- the MAESPA example registers five leaf objects, two plant objects, one soil
  object, and one scene object;
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

Implement `AppliesTo(...)` using the same selector system. The target object
set of a model application must never be hidden inside a domain key, mapping
key, or implicit scale table.

Definitions:

- `Self()` means the current model application object or scope. It is the
  current plant only when the model is applied at `scale=:Plant`.
- `SelfPlant()` means the nearest containing plant scope.
- `Ancestor(scale=:Plant)` is the generic selector form for `SelfPlant()`.
- `SceneScope()` means the whole scene.
- `Scope(name)` means a named scope or object collection.

Rules:

- unqualified selectors inside a reusable plant mapping default to
  `within=Self()`;
- scene-level selectors default to `within=SceneScope()`;
- `One(...)` errors unless exactly one object resolves per consumer;
- `Many(...)` preserves stable object-id order;
- object-id order replaces incidental traversal order as the semantic default.
- selectors are resolved during compilation or binding refresh, not inside the
  inner model loop.

Acceptance tests:

- plant allocation on four oil palms reads only leaves under each plant;
- scene LAI reads leaves across all plant objects;
- a species-specific scene model can read only `species=:oil_palm` leaves;
- a model application target set declared with `AppliesTo(...)` produces stable
  application/object pairs;
- selector errors report available labels and near matches.

## Phase 3: Unified Value Inputs

Goal: replace `MultiScaleModel(...)` and user-written `Route(...)` with
`Inputs(...)`, while using the existing `dep` trait as the model-level source
of default dependency intent.

Target API:

```julia
ModelSpec(AllocationModel()) |>
    AppliesTo(Many(kind=:plant, scale=:Plant)) |>
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Self(), var=:leaf_carbon))

ModelSpec(LAIModel(area)) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(:leaf_areas => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_area))
```

Implement:

- `Inputs(...)` as `ModelSpec` configuration.
- `Input(...)` or an equivalent internal wrapper that lets `dep(model)`
  provide default value-input bindings.
- normalized input bindings from target variable to `ObjectAddress`.
- compiler pass that decides carrier:
  direct reference, `RefVector`, temporal stream, or route-like
  materialization.
- status-default insertion for materialized target variables using the
  consumer model's `inputs_` default.
- temporal policies on value inputs:
  `HoldLast`, `Interpolate`, `Integrate`, `Aggregate`.
- `Dates.Period` windows on value inputs, for example `window=Day(1)`.
- copy/reference semantics reporting for every compiled input binding.

Rules:

- model authors still declare `inputs_`; scenario authors decide where those
  inputs come from;
- `dep(model)` may provide defaults for common value-input bindings, for both
  current `ModelMapping`-style composition and future scene/object composition;
- scenario-level `ModelSpec(...) |> Inputs(...)` always wins over `dep(model)`
  defaults;
- same-rate local links should keep reference semantics where possible;
- cross-rate links always go through temporal state;
- duplicate source candidates are errors unless the selector disambiguates;
- route structs may remain internally but should not be required in examples.
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
| materialized route | generated pre-run status assignment |
| environment | cached environment binding sample |

Acceptance tests:

- the MAESPA scene LAI route becomes an `Inputs(...)` declaration and produces
  the same `lai` and `leaf_area`;
- current plant allocation `MultiScaleModel([:leaf_carbon => [:Leaf => :leaf_carbon]])`
  becomes `Inputs(...)` and remains plant-local;
- a same-scale rename currently expressed with `SameScale()` works through
  `Inputs(...)`;
- multi-rate value inputs integrate graph-domain node streams by object id.
- same-rate many-object bindings do not allocate per timestep in a benchmarked
  hot loop beyond unavoidable model work.
- unitful or dual-number status values survive `Inputs(...)` without forced
  conversion to `Float64`.

## Phase 4: Unified Model Calls

Goal: replace `HardDomains(...)` with `Calls(...)`. `Calls(...)` is the
required public API for manually controlled model execution and must be
implemented in this phase, not deferred to a future rename. The same mechanism
must also be usable from `dep(model)` so current hard-dependency traits become
default call declarations.

Target API:

```julia
ModelSpec(SceneEB()) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(:leaf_energy => Many(kind=:plant, scale=:Leaf, process=:energy_balance)) |>
    Calls(:soil => One(kind=:soil, process=:soil_water))
```

Implement:

- `Calls(...)` as `ModelSpec` configuration.
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
- scenario-level `ModelSpec(...) |> Calls(...)` overrides `dep(model)` defaults;
- hard target outputs still participate in dependency graph compilation through
  the owning parent when needed;
- call selection must be visible through explanation helpers.

Acceptance tests:

- MAESPA scene energy balance uses `Calls(...)` and still controls iterative
  leaf energy calls;
- missing call selectors report `kind`, `scale`, `process`, and available
  matches;
- final accepted calls publish exactly once per timestep.
- an iterative scene model can run selected leaf and soil calls several times
  with `publish=false` and publish only the accepted state.

## Phase 5: Object Templates, Instances, And Overrides

Goal: support several plants of the same species with shared default models and
selective per-instance differences.

Target API:

```julia
oil_palm = ObjectTemplate(
    kind=:plant,
    species=:oil_palm,
    mapping=oil_palm_mapping,
)

scene = Scene(
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
- scene-wide models must opt into wider scope.

Acceptance tests:

- four oil palm instances share model objects/parameters when not overridden;
- one palm instance can override one process parameter;
- allocation remains per plant while scene LAI sees all leaves.

## Phase 5B: Object Lifecycle And Cache Invalidation

Goal: make growth, pruning, and moving organs update every compiled binding
through one mutation path.

Implement public lifecycle hooks:

```julia
register_object!(scene, object; parent)
remove_object!(scene, object)
reparent_object!(scene, object, new_parent)
move_object!(scene, object, geometry_or_position)
refresh_bindings!(scene)
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
  `AppliesTo(...)` before the next timestep;
- moving an object should refresh environment bindings without rebuilding
  unrelated model bindings unless the move changes object relations or labels.

Acceptance tests:

- creating a new leaf adds it to plant-local allocation and scene LAI before
  the next timestep;
- pruning/removing a leaf removes it from many-object carriers and temporal
  stream ownership;
- changing a leaf insertion angle can refresh only the affected environment
  binding when topology is unchanged.

## Phase 6: Environment Binding Cache

Goal: make meteo/microclimate automatic and fast.

Implement:

- `EnvironmentBinding` cache:
  object id, backend/provider id, cell/layer id, required variables.
- default environment resolver:
  global meteo for non-spatial backends;
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
  `bind_environment`, `sample_environment`, `scatter_environment!`, and
  `refresh_environment!`.
- `Environment(...)` overrides for scenario-specific resolver/backend choices.

Runtime rule:

```text
object -> cached binding -> backend cell/layer -> current meteo values
```

Spatial lookup must happen only during binding refresh, not inside every model
call.

Acceptance tests:

- global meteo gives the same values to all objects;
- mock grid backend binds leaves to cells once at initialization;
- moving one leaf marks only that leaf binding dirty and refreshes it before
  the next timestep;
- model `meteo_inputs_` changes update required variables without recomputing
  spatial links unless necessary.
- `meteo_outputs_` can write mutable microclimate variables back to the active
  backend through `scatter_environment!`.

## Phase 7: Compiler, Scheduler, And Explanation Cleanup

Goal: make the unified graph the source of truth.

Implement:

- one compiler that builds a global dependency graph over object addresses;
- route/materialization and multiscale reference wiring as internal carriers;
- domain DAG scheduling replaced by object/scope dependency scheduling;
- writer validation through the same graph, including `Updates(...)`;
- model application scheduling from `AppliesTo(...)` target sets;
- multirate scheduling based on `Dates.Period` values in `TimeStep(...)` and
  input windows;
- typed compiled bindings that avoid selector resolution in timestep hot loops;
- arbitrary value type preservation through status, input carriers, temporal
  storage, and environment samples;
- structured explanation:
  `explain_objects`, `explain_scopes`, `explain_bindings`,
  `explain_calls`, `explain_environment_bindings`, `explain_schedule`,
  `explain_writers`.

Acceptance tests:

- old `MultiScaleModel` examples rewritten with `Inputs(...)` produce matching
  outputs;
- old `Route(...)` examples rewritten with `Inputs(...)` produce matching
  outputs;
- MAESPA hard-call example rewritten with `Calls(...)` produces matching
  outputs;
- explanation helpers include enough concrete object ids, scales, processes,
  and variables for an AI agent to repair bad mappings.
- `explain_bindings(sim)` reports whether each dependency came from inference,
  `dep(model)`, or `ModelSpec`, and reports carrier/copy semantics.
- no selector resolution occurs inside the per-object, per-model timestep loop
  for static scenes.
- multirate simulations use the same object-address graph as same-rate
  simulations.

## Phase 8: Breaking API Removal And Migration Docs

Goal: remove the old configuration surface once parity is proven.

Remove or demote:

- `MultiScaleModel(...)` as public scenario configuration;
- public `Route(...)` authoring for normal value inputs;
- `AllDomains(...)` and `HardDomains(...)` as primary user API;
- `Domain(...)` as a user-facing container when object templates/instances are
  available.

Write migration notes:

- `MultiScaleModel([:x => [:Leaf => :y]])` -> `Inputs(:x => Many(scale=:Leaf, var=:y))`;
- `Route(from=AllDomains(...), to=...)` -> consumer `Inputs(...)`;
- `HardDomains(...)` -> `Calls(...)`;
- repeated species domains -> `ObjectTemplate` plus `ObjectInstance`;
- explicit meteo routes -> environment resolver/binding backend.
- `InputBindings(...)` -> source and temporal policy information inside
  `Inputs(...)`;
- `MeteoBindings(...)` and `MeteoWindow(...)` -> `Environment(...)` and
  environment sampling/window policy;
- `OutputRouting(...)` -> model-application output policy;
- `PreviousTimeStep(...)` -> temporal policy/cycle-breaking marker in the
  unified graph;
- `ScopeModel(...)` -> `AppliesTo(...)` plus selector scope.

Regression tests must cover all migrated examples before removal.

## Open Decisions

- Final names for `SceneScope`, `Self`, `SelfPlant`, `Kind`, `Species`, and
  `Scale`.
- Whether `Inputs(...)` should be a pipeable `ModelSpec` modifier only, or also
  accepted as a keyword in `ModelSpec`.
- Whether `TimeStep(...)` is the final name, or whether the existing
  `TimeStepModel(...)` should be kept as an alias during the transition.
- Whether `Environment(...)` owns only backend/resolver choices or also
  per-model meteo window policies.
- Whether object templates should own topology construction helpers or only
  consume prebuilt MTGs/object trees.
- How much of the old API remains as compatibility wrappers after the breaking
  release.
