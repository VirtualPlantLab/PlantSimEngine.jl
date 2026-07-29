# Temporary Goal: Finalize the PlantSimEngine API and Progressive Documentation

> This is a temporary implementation goal, not user documentation.
>
> Use it as the working contract for the next PlantSimEngine API and
> documentation pass. Delete it after every completion criterion has been
> verified and the durable decisions have been moved into the normal
> documentation, changelog, tests, and downstream packages.

## Objective

Make PlantSimEngine answer one problem clearly:

> A model developer implements a scientific process once. A simulation user
> composes such models over objects, scales, plants, timesteps, and
> environments without rewriting their kernels.

The final API must be as small and unsurprising as possible for:

1. **model developers**, who implement reusable process models; and
2. **simulation users**, who select models, couple them, construct one or many
   plants, and run simulations.

The documentation must teach this progressively. It must begin with a few
existing models coupled on the same object and run over several timesteps.
Each later journey introduces one substantial concept at a time.

## Status Legend

- `[x]` is an established baseline already implemented on the current branch.
- `[ ]` is required work or verification before this goal is complete.

## Non-Negotiable Constraints

- [ ] Preserve the sole `CompositeModel`/`Object` compiler and runtime. Do not
      recreate the removed ModelMapping runtime.
- [ ] Prefer clean breaking changes. Do not add deprecated aliases,
      compatibility wrappers, old keyword support, or dual APIs unless the
      user explicitly requests them.
- [ ] Preserve generic numeric and status types, reference carriers, compiled
      execution batches, deterministic diagnostics, and allocation-sensitive
      paths.
- [ ] Treat runtime performance as part of the public contract. The richer
      `CompositeModel` semantics must compile into simple hot loops; selector
      resolution, dependency compilation, status-view construction, and
      execution-plan construction must not become ordinary per-step work.
- [ ] Make structural mutation proportional to the changed objects and affected
      applications, not to the total number of objects and execution targets
      already present in the simulation.
- [ ] Keep the common path short. Advanced features must not add arguments,
      types, or terminology to the first-time workflow.
- [ ] Reuse the models in `PlantSimEngine.Examples` whenever they can teach the
      intended concept. Do not redefine a tutorial-only model when an existing
      model can be brought up to the current contract.
- [ ] Treat PlantBiophysics and XPalm as required downstream acceptance suites,
      not optional follow-up cleanup.
- [ ] Preserve unrelated and concurrent working-tree changes. Inspect
      `git status` in all three repositories before editing.
- [ ] Use Kaimon for every Julia process and Julia test run.

## Current Branch Baseline That Must Not Regress

### Composite runtime

- [x] One `CompositeModel` owns an `ObjectRegistry`, applications, instances,
      overrides, and an environment.
- [x] Objects have stable identities, labels, parents, geometry, scale, kind,
      and `Status`.
- [x] Templates and instances reuse the same logical model definitions across
      multiple plants.
- [x] Same-object value coupling can be inferred when unique.
- [x] Cross-object coupling uses explicit `One`, `OptionalOne`, or `Many`
      selectors and scope.
- [x] Hard dependencies are parent controlled through `Calls`,
      `call_targets`, and `run_call!`.
- [x] Runtime mutation refreshes affected selectors, carriers, schedules, and
      environment bindings between timesteps.
- [x] Output streams are keyed by application, object, and variable.

### Environment API implemented by “Review multi-plants changes”

The following is the current environment semantic baseline. Preserve it even
if the public vocabulary is renamed later in this goal.

- [x] `EnvironmentContext(application, object_id, scale, process)` contains
      immutable target metadata and is used while compiling a backend binding.
      It does not expose runtime status or geometry to sampling.
- [x] `bind_environment(backend, object, context, config)` returns an opaque
      backend handle.
- [x] Committed sampling uses:

      ```julia
      sample(backend, handle, variable, time)
      ```

- [x] Transient sampling uses:

      ```julia
      sample(backend, handle, state, variable, time)
      ```

- [x] A provider-aware trial state is propagated to every resolved target,
      including `Many`, with:

      ```julia
      run_call!(context, name; environment=trial_state, publish=false)
      ```

      Each target still samples through its own compiled handle. A multi-voxel
      trial therefore does not require a model-level loop over leaves.

- [x] Accepted mutable state is explicit:

      ```julia
      commit_environment!(context, accepted_state)
      ```

- [x] Environment outputs are declarations of what a model is allowed to
      commit. They are not inserted into ordinary object `Status`.
- [x] Fine-grained execution can supply an already sampled row to one selected
      `CallTarget`. This is an advanced escape hatch, separate from the
      provider-aware `Many` path.
- [x] `with_environment!`, `update_environment!`, `EnvironmentSupport`, the
      override stack, context-level `meteo=`, automatic scatter, and
      status-based environment routing have been removed.
- [x] The MAESPA example uses explicit forcing and canopy routes and validates
      trial versus accepted environment states.

The other task reported these Kaimon results for this baseline:

- MAESPA focused suite: 172 passed;
- unified model/object API: 592 passed;
- complete PlantSimEngine suite: 1,324 passed;
- `git diff --check`: passed.

These results must be rerun after the API and documentation work below. Do not
present them as validation of later edits.

### Working-tree snapshot at goal start

- [x] PlantSimEngine is on `codex/pse-downstream-regression` at `7e38354f`.
      The only initial untracked path is this goal document, created for the
      current work.
- [x] XPalm is on `codex/xpalm-release-regression` at `0018162`. Its
      pre-existing `CHANGELOG.md` modification is concurrent user work and must
      not be overwritten or included in unrelated commits.
- [x] PlantBiophysics is on `codex/plantbiophysics-downstream-regression` at
      `1085356`. Its pre-existing logo source, SVG removal, PNG addition, and
      documentation-assets test edits are concurrent user work and must not be
      overwritten or included in unrelated commits.
- [x] Recheck all three worktrees before every cross-repository milestone; this
      snapshot records starting ownership but does not make later changes safe
      to assume.

## Target Public API

### 1. Model-developer kernel

The current six-argument kernel exposes a redundant process-keyed `models`
bundle and calls the actual context `extra`.

- [ ] Replace the canonical model kernel with:

      ```julia
      PlantSimEngine.run!(
          model,
          status,
          environment,
          constants,
          context,
      )
      ```

- [ ] Use `model.parameter` for the current model's parameters.
- [ ] Remove the `models` bundle from the model-developer contract.
- [ ] Expose hard-call models and targets only through focused context
      functions such as `call_targets`, `run_call!`, and a small read-only model
      accessor if one is genuinely needed.
- [ ] Use `context`, not `extra`, throughout source, examples, documentation,
      errors, and downstream packages.
- [ ] Keep the model kernel responsible for one timestep and one target.
      PlantSimEngine owns the timeline, scheduling, target iteration, and
      publication.
- [ ] Migrate all PlantSimEngine examples and tests.
- [ ] Migrate all PlantBiophysics and XPalm model kernels.
- [ ] Do not retain the six-argument method as compatibility.

### 2. One environment vocabulary

The new environment semantics are sound, but the model-facing vocabulary is
still divided between `Environment`, `meteo_inputs_`, `meteo_outputs_`, and a
kernel argument named `meteo`.

- [ ] Rename the model traits consistently:

      ```julia
      environment_inputs_(model)
      environment_outputs_(model)
      ```

- [ ] Rename related helpers, explanations, graph fields, diagnostics, and
      error messages consistently.
- [ ] Call the sampled model-facing kernel argument `environment`.
- [ ] Keep `environment=` on context-level `run_call!` for a typed transient
      backend state.
- [ ] Rename the per-target bypass keyword to an unambiguous name such as
      `sampled_environment=`; it supplies an already sampled row and bypasses
      provider sampling for exactly one target.
- [ ] Keep PlantMeteo as a provider/adapter, not as the name of PlantSimEngine's
      general environment abstraction.
- [ ] Do not reintroduce the removed override-stack or scatter APIs.

### 3. Required inputs versus true defaults

Input literals are currently described as defaults even when an unresolved
input still causes compilation to fail.

- [ ] Make required and defaulted inputs explicit. The target contract is:

      ```julia
      inputs_(::MyModel) = (
          required_value=Required(Float64),
          optional_value=Default(1.0),
      )
      ```

- [ ] Keep output literals as initial output-state values unless a more explicit
      output schema is justified.
- [ ] Ensure required/default declarations preserve generic types and do not
      force `Float64`.
- [ ] Remove undocumented `-Inf`-as-required conventions from canonical
      examples.
- [ ] Make initialization explanations report whether a value is required,
      defaulted, user supplied, or bound from another application.
- [ ] Add compile-error tests for missing required inputs and tests proving that
      true defaults require no user initialization.

### 4. Scenario configuration

`ModelSpec` currently has both a direct constructor and a pipe DSL. There
should be one normal spelling.

- [ ] Choose one canonical `ModelSpec` construction form and remove the other.
- [ ] Prefer a concise direct keyword form along these lines:

      ```julia
      ModelSpec(
          model;
          name=:application,
          on=Many(scale=:Leaf, within=SelfPlant()),
          inputs=(...),
          calls=(...),
          every=Hour(1),
          environment=Environment(...),
      )
      ```

- [ ] Preserve `Updates` and output-routing semantics, but place them in the
      same canonical configuration form.
- [ ] Remove the pipe helpers if direct keywords are selected; do not document
      both as equal alternatives.
- [ ] Migrate XPalm's scenario compiler as a primary design test.

### 5. Selectors

- [ ] Keep `One`, `OptionalOne`, and `Many`.
- [ ] Keep meaningful topology scopes: `Self`, `Subtree`, `SelfPlant`,
      `SceneScope`, `Ancestor`, `Scope`, and `Relation`.
- [ ] Prefer keyword criteria such as `scale=:Leaf` over duplicate wrapper
      spellings such as `Scale(:Leaf)`.
- [ ] Validate selector fields by context. For example, an application-target
      selector must not silently accept value-routing-only fields.
- [ ] Document `Self()` literally as the current object. It never means the
      current plant unless that object is the plant.
- [ ] Ensure structured selector diagnostics include every semantically
      relevant normalized field.

### 6. Public namespace

- [ ] Reduce the default exported API to the ordinary model-developer and
      simulation-user workflow.
- [ ] Move structured `explain_*` and carrier inspection tools under
      `PlantSimEngine.Diagnostics`.
- [ ] Move graph DTOs, graph edits, and editor sessions under
      `PlantSimEngine.GraphEditor`.
- [ ] Move backend extension protocol symbols under
      `PlantSimEngine.EnvironmentAPI`.
- [ ] Move fitting metrics and generic evaluation functions under
      `PlantSimEngine.Evaluation`.
- [ ] Avoid re-exporting the complete PlantMeteo reducer vocabulary when users
      can access it from PlantMeteo directly.
- [ ] Generate or test the public symbol inventory so it cannot drift from
      actual exports.

### 7. Simulation results

- [ ] Keep the memory-safe `outputs=:none` default unless measurements justify
      changing it.
- [ ] Add a concise `show(::Simulation)` that reports elapsed steps, object and
      application counts, retained stream count, and an actionable hint when
      no streams were retained.
- [ ] Add a sanctioned `final_state` or equivalent accessor for common final
      values, so tutorials do not require
      `only(model_objects(...)).status`.
- [ ] Use `outputs=:all` or explicit `OutputRequest`s in tutorials that collect
      or plot output streams.
- [ ] Introduce basic collection in the first journey; defer retention,
      resampling, and routing policies until later.

## Performance Restoration Contract

Runtime performance is a core package feature and a release-blocking part of
this goal. The new object, selector, lifecycle, hard-call, temporal, and output
semantics must be compiled into efficient execution. Restoring speed must not
remove those semantics or revive the old runtime.

### Measured regression baseline

The current full-cycle XPalm regression is directly comparable with the
committed XPalm v0.6.1 fixture:

- [x] Both measurements use Julia 1.12.1, 4,160 daily steps, the same
      meteorology file and SHA-256, `XPalm.default_parameters()`, and the same
      end-to-end regression helper.
- [x] XPalm v0.6.1 with PlantSimEngine v0.14.1 completed in
      `7.501459958` seconds.
- [x] The current `CompositeModel` runtime completed in `439.521899917`
      seconds; two earlier repetitions took approximately 505 and 512 seconds.
- [x] The best current result is therefore `58.59×` slower: approximately
      `105.654 ms` instead of `1.803 ms` per simulated day.
- [x] The reference run finishes with 344 phytomers.
- [x] Reproduce the current timing again from a healthy Kaimon session before
      changing runtime code, recording warm-up policy, source revisions,
      machine information, wall time, allocations, and output mode.
- [x] Capture a sampling and allocation profile before optimization. The code
      paths below are confirmed work amplification, but their exact shares of
      elapsed time have not yet been measured because the profiling Kaimon
      session failed to start.

Use XPalm v0.6.1 with PlantSimEngine v0.14.1 as the exact historical performance
reference. A v0.5.1 comparison may be retained as additional historical
evidence, but it must not replace the reproducible v0.6.1 fixture.

Current restoration checkpoints on the same staged XPalm fixture:

- [x] At `195a346b`, the 1,000-day run took `4.118958` seconds and allocated
      `3.145 GB` with `outputs=:none`; the reference-output run took
      `4.089205` seconds and allocated `3.161 GB`.
- [x] At `c1b8cc2f`, the 1,000-day run takes `3.989951` seconds and allocates
      `2.702 GB` with `outputs=:none`; the reference-output run takes
      `4.285781` seconds and allocates `2.719 GB`.
- [x] Reference-output collection is measured separately at `0.597552`
      seconds and `67.4 MB`.
- [x] At `4bf7575e`, the exact 4,160-day `outputs=:none` fixture took
      `110.872` seconds and allocated `48.889 GB`.
- [x] The lifecycle hard-call delta committed as `bb619c4e` reduced that
      fixture to `52.918` seconds and `29.360 GB`.
- [x] With the persistent dependency graph and delta execution-plan refresh,
      the current worktree takes `48.935` seconds and allocates `23.590 GB`.
- [ ] The current full-cycle result is still not an acceptance result:
      `phytomer_count=344` and `ftsw=0.7991179101191208` agree with the
      historical fixture, but `lai=4.897520126027398` does not equal the
      historical `5.0587602356164405`, and the runtime remains above the
      `<=15` second release gate.

### Performance invariants

- [x] The steady-state scheduler performs one linear traversal of compiled
      application groups and targets per timestep.
- [x] A timestep with no structural or environment changes performs no selector
      resolution, dependency-graph compilation, status-view construction,
      execution-plan construction, or output-retention compilation.
- [x] Adding objects extends or replaces only affected compiled structures.
      Unaffected targets retain their status views, temporal storage, reference
      carriers, call bindings, environment handles, and execution batches.
- [ ] Lifecycle extension cost scales with the number of added, removed,
      reparented, or moved objects and the applications affected by that delta.
- [x] Temporal dependency state is distinct from user-retained output history.
- [x] Dynamic dispatch remains at compiled batch boundaries, not inside the
      per-object kernel loop.
- [x] Homogeneous steady-state batches preserve the existing zero-allocation
      target-loop guarantee.
- [x] Performance improvements preserve deterministic application order,
      lifecycle visibility, `PreviousTimeStep` semantics, hard-call
      publication, output retention, removed-object history, overrides, and
      generic numeric types.

### 1. Add performance observability before redesign

- [ ] Add opt-in runtime counters and coarse timers for:
  - initial composite compilation;
  - selector and input/call binding compilation;
  - application-order compilation;
  - status-view construction;
  - model-bundle construction;
  - environment-binding compilation and refresh;
  - execution-plan construction and extension;
  - output-retention compilation;
  - temporal input materialization and publication;
  - scientific kernel execution;
  - output collection.
- [x] Count lifecycle refreshes, dirty objects, affected applications, status
      views constructed, execution targets constructed, bindings replaced, and
      batches rebuilt.
- [x] Keep instrumentation disabled or effectively free in ordinary runs.
- [x] Use `Profile`, allocation measurements, and BenchmarkTools through
      Kaimon. Do not infer percentage contributions from static inspection
      alone.
- [x] Profile a controlled matrix that separates:
  - scene construction from simulation;
  - steady-state execution from structural growth;
  - `outputs=:none` from requested regression outputs;
  - temporal dependencies from user-retained histories;
  - simulation from `collect_outputs`;
  - a short prefix from the complete 4,160-step cycle.

### 2. Make lifecycle compilation genuinely incremental

The current extension path appends new application targets but then rebuilds
all status views. Simulation refresh subsequently recompiles output retention
and the complete execution plan. A hard call restricted to newly created
objects forces this refresh immediately so those objects can be initialized.

XPalm creates one phytomer, one internode, and one leaf per emission. The three
growing scales are targeted by 27 applications. With 343 emissions after the
initial phytomer, rebuilding every existing view causes at least
`1,602,153` growing-scale status-view constructions, excluding static and
reproductive objects.

- [x] Preserve `status_views_by_target` for unaffected keys.
- [x] Compile status views only for new targets and for existing targets whose
      dynamic input bindings genuinely changed.
- [x] Preserve private temporal storage and reference identity for unaffected
      status views.
- [x] Extend `input_bindings_by_target`, `call_bindings_by_target`, and
      `model_bundles_by_target` only for affected consumers and callees.
- [x] When a dynamic hard-call selector starts matching a new object, update
      only that binding and the callers whose compiled bundle actually changes.
      Do not rebuild every call binding or model bundle.
- [x] Cache the application dependency graph or its edge set. Recompute
      application order only when a lifecycle delta introduces or removes an
      ordering edge.
- [x] Extend the execution plan by appending a new target to a compatible typed
      batch or rebuilding only the affected application's groups.
- [x] Update output retention only when a new temporal dependency or requested
      output target changes retention.
- [x] Continue using the existing incremental environment-binding refresh for
      affected objects; do not rebuild unrelated spatial handles.
- [x] Preserve the application-boundary lifecycle transaction so several
      objects created by one kernel are refreshed together.
- [x] Ensure `run_call!(...; objects=new_objects)` can initialize new objects
      without triggering a whole-scene rebuild.
- [x] Add lifecycle tests covering creation, removal, reparenting, overrides,
      new dynamic `Many` matches, hard-call initialization, and temporal state
      preservation.

### 3. Replace repeated scheduler scanning with application groups

The current step loop allocates a `Set{Symbol}` and repeatedly calls
`findfirst` from the beginning of the batch vector to locate the next
application. XPalm currently defines 62 applications, and one application can
contain several typed batches.

- [x] Compile an `ApplicationExecutionGroup` or equivalent representation that
      owns one application and its typed batches.
- [x] Execute the ordinary clean-runtime path as one linear loop over groups
      and one linear loop over each group's targets.
- [x] Do not allocate a completed-application set on an ordinary timestep.
- [x] Put lifecycle resumption behind a separate slow path.
- [x] After a mid-step refresh, skip already completed application identities
      without repeatedly rescanning all earlier batches.
- [x] Preserve correct behavior if a lifecycle change introduces a new
      dependency edge and changes the remaining order.
- [x] Benchmark and allocation-test one clean timestep with one batch per
      application and with several heterogeneous batches per application.

### 4. Compile temporal policies into typed state

XPalm currently declares 17 `PreviousTimeStep` dependencies. Internal temporal
dependencies are published through a global
`Dict{Tuple{Symbol,ObjectId,Symbol},Any}` of sample vectors. Dependency-only
streams then use `deleteat!` or `filter!` during publication.

- [x] Compile `PreviousTimeStep` to a typed previous/current double buffer or
      equivalent fixed-size state.
- [x] Rotate previous-step state at a defined timestep boundary so the result
      is independent of same-step producer/consumer execution order.
- [x] Share compiled source cells with all compatible consumers instead of
      repeating dictionary lookup by application, object, and variable.
- [x] Implement `Integrate`, `Aggregate`, and other finite-window policies with
      typed ring buffers or another bounded representation.
- [x] Keep append-only historical streams only for outputs the user explicitly
      retains or requests.
- [x] Preserve initial-value, missing-source, multirate cadence, publication,
      continuation, and removed-object history semantics.
- [x] Add allocation and scaling tests for thousands of objects using
      `PreviousTimeStep` without retained user output.

### 5. Restore the no-hard-call fast path per batch

XPalm has only two `Calls(...)` declarations, but the presence of any compiled
call binding currently sends every scheduled target through the call-capable
execution path.

- [x] Record call capability per compiled target or homogeneous batch.
- [x] Run targets with no call bindings through the no-call kernel even when
      unrelated applications in the scene declare hard calls.
- [x] Group call-capable targets by concrete call tuple or another type-stable
      representation.
- [x] Avoid a per-target lookup in `call_bindings_by_target` when call bindings
      are already known during compilation.
- [x] Preserve nested calls, selective targets, transient environments,
      `publish=false`, accepted publication, and lifecycle-created call targets.
- [ ] Benchmark a large scene with zero, sparse, and dense hard-call usage.

### 6. Separate and preallocate retained outputs

- [x] Benchmark `run!` and `collect_outputs` independently while retaining an
      end-to-end benchmark comparable to the historical XPalm fixture.
- [x] Preallocate regular-cadence requested output columns from the known step
      count where possible.
- [x] Extend output storage incrementally when lifecycle changes introduce a
      newly requested object.
- [ ] Avoid using the generic temporal-dependency stream representation for
      ordinary requested outputs when a typed columnar representation is
      available.
- [x] Preserve streams keyed by application, object, and variable and preserve
      resampling and removed-object history.
- [ ] Compare `outputs=:none`, a small explicit request, the XPalm regression
      request, and `outputs=:all`.

### Performance benchmark and regression matrix

- [x] Turn the existing BenchmarkTools suite into an executable, saved,
      comparable suite instead of leaving `tune!`, `run`, and result saving
      commented out.
- [ ] Record source revisions, Julia version, manifest hash, fixture hash,
      machine identity, warm-up policy, median time, minimum time, memory, and
      allocations with every persisted result.
- [ ] Add benchmarks for:
  1. initial XPalm scene compilation;
  2. a clean steady-state step;
  3. 100 and 1,000 clean steps;
  4. one lifecycle event on small and large existing scenes;
  5. a lifecycle event followed by immediate hard-call initialization;
  6. a temporal-policy-heavy scene with no requested output;
  7. the 4,160-step XPalm run with `outputs=:none`;
  8. the same run with reference outputs;
  9. output collection alone;
  10. the complete end-to-end reference helper.
- [x] Keep a short deterministic PR gate for steady-state allocations,
      lifecycle scaling, and a simulation prefix.
- [ ] Run and persist the complete XPalm performance suite on a stable runner
      nightly, before releases, or on explicit performance workflows.
- [ ] Compare noisy wall-clock measurements with generous regression
      tolerances, but keep allocation and work-count regressions strict.
- [x] Fail correctness before considering performance: every benchmark fixture
      must verify final state or selected checkpoints.

### Performance acceptance targets

- [ ] First restoration milestone: complete the exact XPalm full-cycle
      reference in at most 15 seconds on the baseline machine after warm-up.
- [ ] Final target: complete it in at most 10 seconds, or document and obtain
      explicit approval for any remaining measured cost required by the new
      semantics.
- [x] Demonstrate that a clean steady-state step allocates no memory in the
      homogeneous target loops and stays within an explicitly recorded total
      scheduler allocation budget.
- [x] Demonstrate that adding one equivalent organ to a large scene constructs
      only the new and affected compiled targets. The benchmark and work
      counters must show delta scaling rather than whole-scene scaling.
- [ ] Demonstrate that sparse hard-call declarations do not slow unrelated
      applications onto the call-capable path.
- [x] Demonstrate bounded temporal dependency memory when outputs are not
      retained.
- [ ] Persist the repaired baseline so later API, lifecycle, temporal, and
      output changes cannot silently recreate a large regression.

## Progressive Documentation Contract

### Teaching rules

- [ ] Every page states the one new concept it introduces.
- [ ] Every page starts from a working previous state or a minimal standalone
      example.
- [ ] Each page shows the smallest meaningful diff from the previous journey.
- [ ] Do not introduce a selector, scope, backend protocol, temporal policy,
      hard call, lifecycle operation, or output-routing policy before it is
      needed.
- [ ] Use one small diagram only when it makes object ownership, coupling, or
      execution order clearer than prose.
- [ ] Include one relevant explanation/diagnostic at each stage rather than
      presenting every diagnostic at once.
- [ ] End each page with:
  - what the user added;
  - what PlantSimEngine inferred;
  - what remains explicit;
  - the small set of new API names.
- [ ] Keep migration and maintainer design documents outside the first-time
      navigation.
- [ ] Run every code block as a doctest or an included tested example.

### Simulation-user journey

#### Journey 0: Mental model

- [ ] Explain process, model, application, object, status, environment, and
      simulation in one short page.
- [ ] State that PlantSimEngine is a composition/runtime framework, not a
      scientific plant-model library or prescribed plant architecture.
- [ ] Avoid executable configuration details on this page.

#### Journey 1: Couple models on one object and run many timesteps

This is the first executable journey and must demonstrate immediately that a
composite simulation naturally runs over time.

- [ ] Couple at least two existing models on one object and one scale.
- [ ] Prefer the existing chain:
  - `ToyDegreeDaysCumulModel`;
  - `ToyLAIModel`;
  - optionally `Beer` as the third model when the extra output improves the
    story.
- [ ] Run for several timesteps, not one:

      ```julia
      simulation = run!(model; steps=30, outputs=:all)
      results = collect_outputs(simulation)
      ```

- [ ] Show a short table or plot in which cumulative thermal time and LAI
      visibly evolve.
- [ ] Explain automatic same-object coupling by matching model outputs to
      inputs.
- [ ] Show the final state and the retained timeline.
- [ ] Optionally show one additional `step!` or `continue!` call after the main
      run, without turning continuation into a separate advanced subject.
- [ ] Use a simple weather fixture if needed, but treat it only as supplied
      forcing data here. Do not teach providers, handles, spatial binding, or
      mutable environments yet.
- [ ] Do not use explicit `ModelSpec`, selectors, templates, hard calls,
      multiple cadences, or lifecycle mutation.

#### Journey 2: Run the coupling on several same-scale objects

- [ ] Reuse the first model chain on two or more objects at the same scale.
- [ ] Introduce stable object identity and one `Many` target selection.
- [ ] Show that every object has independent status and output streams.
- [ ] Do not introduce parent/child scales or templates yet.

#### Journey 3: Build one multiscale plant

- [ ] Add one plant and several organs.
- [ ] Introduce parent/child topology, cross-object inputs, and plant-local
      aggregation one at a time.
- [ ] Prefer existing models designed for this purpose:
  - `ToyLeafSurfaceModel`;
  - `ToyPlantLeafSurfaceModel`;
  - `ToyLAIfromLeafAreaModel`;
  - `ToyLightPartitioningModel`;
  - `ToyMaintenanceRespirationModel`;
  - `ToyPlantRmModel`.
- [ ] Introduce `Subtree()` and `SelfPlant()` with a diagram showing their
      exact scopes.
- [ ] Introduce vector/reference carriers only after a scalar cross-object
      example works.

#### Journey 4: Instantiate several plants

- [ ] Convert the previous plant into a `CompositeModelTemplate`.
- [ ] Instantiate it at least twice with independent initial values.
- [ ] Prove that plant-local selectors do not mix organs between plants.
- [ ] Introduce `SceneScope()` only when adding a deliberately shared scene or
      soil source.
- [ ] Demonstrate one override only after the two identical instances work.

#### Journey 5: Understand environments

- [ ] Return to the forcing used in Journey 1 and now explain the environment
      contract explicitly.
- [ ] Show model environment declarations, `Environment(...)`, source
      remapping, and global sampling.
- [ ] Correct every reused example model so it declares every environment
      variable it reads.
- [ ] Run canonical examples against a strict backend that exposes only
      declared variables.
- [ ] Introduce spatial handles only after the global provider is understood.

#### Journey 6: Give models different cadences

Repeated execution of the whole composite was already introduced in Journey 1.
This journey introduces a different concept: applications with different
cadences.

- [ ] Reuse the same thermal-time, LAI, light, and growth models where
      scientifically coherent.
- [ ] Introduce one daily application into an otherwise hourly simulation.
- [ ] Start with `HoldLast`.
- [ ] Introduce `Integrate` or `Aggregate` in a separate subsection with a
      physical-units explanation.
- [ ] Explain `PreviousTimeStep` only when breaking a real same-step cycle.
- [ ] Do not combine multirate, growth, and mutable environment changes in the
      first multirate example.

#### Journey 7: Modify plant structure

- [ ] Grow one plant by adding one organ.
- [ ] Explain that structural changes become visible after the current
      timestep and bindings refresh between timesteps.
- [ ] Add removal and reparenting only after creation works.
- [ ] Reuse existing carbon demand/allocation/biomass models when practical:
  - `ToyCDemandModel`;
  - `ToyCAllocationModel`;
  - `ToyCBiomassModel`;
  - `ToyAssimModel`.
- [ ] Verify conservation, parentage, refreshed application targets, and
      retained history.

#### Journey 8: Modify the environment

- [ ] Begin with a single-layer mutable environment.
- [ ] Show the current typed trial-state path:

      ```julia
      run_call!(
          context,
          :energy_balance;
          environment=trial_environment,
          publish=false,
      )
      ```

- [ ] Show an explicit accepted commit:

      ```julia
      commit_environment!(context, accepted_environment)
      ```

- [ ] Explain environment output declarations as commit permissions.
- [ ] Then extend to a spatial/voxel environment, proving that `Many` preserves
      each target's opaque compiled handle.
- [ ] Do not expose backend implementation protocol in the ordinary user page;
      place backend authoring in an extension guide.

#### Journey 9: Advanced execution control

- [ ] Teach hard calls, target inspection, selective target calls, iterative
      publication, duplicate writers, `Updates`, and output routing.
- [ ] Make `publish=false` trial semantics and accepted publication explicit.
- [ ] Keep these APIs out of all earlier examples unless scientifically
      necessary.

#### Journey 10: Complete realistic example

- [ ] Use the MAESPA-style example as the integrated reference.
- [ ] Include multiple plants, multiple scales, multiple cadences, dynamic
      structure where relevant, and mutable/spatial environments.
- [ ] Present it as a synthesis and reference, not as onboarding.
- [ ] Link every advanced construct back to the earlier page that introduced
      it independently.

### Model-developer journey

- [ ] **Model 1:** implement a parameterized model with required inputs,
      defaults, outputs, and the final one-step kernel.
- [ ] **Model 2:** couple it automatically with another model on one object.
- [ ] **Model 3:** prove the same kernel runs over several objects without an
      object loop inside the model.
- [ ] **Model 4:** consume a scalar cross-object value.
- [ ] **Model 5:** consume or produce a vector-like multiscale value.
- [ ] **Model 6:** declare sampled environment inputs.
- [ ] **Model 7:** declare cadence and output temporal semantics.
- [ ] **Model 8:** declare and execute a hard dependency.
- [ ] **Model 9:** produce and explicitly commit accepted mutable environment
      state.
- [ ] Cross-link each model-developer page to the corresponding simulation-user
      journey, without forcing ordinary users through implementation details.

## Existing Model Reuse Inventory

Inspect and update these models before inventing new tutorial types:

| Existing model or helper | Preferred teaching use |
|---|---|
| `ToyDegreeDaysCumulModel` | Repeated timesteps, accumulated state, first coupling |
| `ToyLAIModel` | Automatic same-object input/output coupling |
| `Beer` | Third model in a simple chain; later, environment inputs |
| `ToyRUEGrowthModel` | Stateful biomass accumulation and later growth |
| `ToyAssimGrowthModel` | Model switching or comparison with a decomposed chain |
| `ToyLeafSurfaceModel` | One kernel over many leaf objects |
| `ToyPlantLeafSurfaceModel` | Plant-local aggregation |
| `ToyLAIfromLeafAreaModel` | Cross-scale aggregation toward scene/plant LAI |
| `ToyLightPartitioningModel` | Larger-scale value partitioned to organs |
| `ToyMaintenanceRespirationModel` | Organ-level process |
| `ToyPlantRmModel` | Plant-level aggregation from organs |
| `ToyAssimModel` | Organ assimilation in a decomposed carbon chain |
| `ToyCDemandModel` | Organ demand |
| `ToyCAllocationModel` | Vector-of-organ allocation |
| `ToyCBiomassModel` | Accepted allocation applied to organ biomass |
| `ToySoilWaterModel` | Shared soil/environment-related examples |
| `import_mtg_example()` | MTG import after the explicit object API is understood |
| `maespa_model_example.jl` | Final mutable/spatial environment synthesis |

Before using any of them:

- [ ] Ensure its input, output, environment, and timing declarations match what
      its kernel actually reads and writes.
- [ ] Ensure it uses the final model kernel and accesses its own parameters
      through the `model` argument.
- [ ] Ensure its docstring uses current `CompositeModel`/`Object` terminology.
- [ ] Ensure its numeric fields remain generic where scientifically possible.
- [ ] Add direct contract tests and at least one composition test.

## Documentation Navigation Target

- [ ] **Start here**
  1. Why PlantSimEngine;
  2. mental model;
  3. first same-scale coupled simulation over many timesteps;
  4. several same-scale objects.
- [ ] **Structure and composition**
  1. one multiscale plant;
  2. several plants;
  3. templates and overrides;
  4. MTG import.
- [ ] **Environment and time**
  1. read an environment;
  2. spatial environments;
  3. different model cadences;
  4. temporal policies.
- [ ] **Dynamic and advanced simulations**
  1. structural growth;
  2. mutable environments;
  3. hard calls and iterative execution;
  4. complete MAESPA-style example.
- [ ] **Implement models**
  1. basic contract;
  2. composition;
  3. multiple objects;
  4. multiscale values;
  5. environment-aware models;
  6. hard dependencies.
- [ ] **Reference**
  1. ordinary public API;
  2. diagnostics;
  3. backend extension API;
  4. graph editor;
  5. evaluation.
- [ ] **Migration**
  - keep migration from the removed mapping runtime separate from onboarding.
- [ ] **Maintainers**
  - move design notes, implementation plans, completion audits, and handoff
    documents out of the normal user journey.

## Downstream Migration Contract

### PlantBiophysics: model-developer acceptance suite

PlantBiophysics validates the model-author side of the API.

- [ ] Preserve its current `multi-plant` branch work.
- [ ] Migrate every model kernel to the final signature.
- [ ] Migrate model parameters away from the redundant `models` bundle.
- [ ] Migrate environment input/output declarations and kernel argument names.
- [ ] Migrate hard-call code and the fine-grained sampled-environment escape
      hatch.
- [ ] Migrate required/default input declarations.
- [ ] Migrate evaluation functions if they move under
      `PlantSimEngine.Evaluation`.
- [ ] Update all PlantBiophysics simulations, fitting code, tests, and docs.
- [ ] Run its package tests and documentation build through a Kaimon session
      started for the PlantBiophysics checkout.

### XPalm: simulation-user and framework-builder acceptance suite

XPalm validates the scenario-construction side of the API.

- [ ] Preserve its current `multi-plant` branch work and existing commits.
- [ ] Migrate every model kernel and environment declaration.
- [ ] Migrate its scenario compiler to the single canonical `ModelSpec` syntax.
- [ ] Migrate selectors and scopes without weakening plant-local isolation.
- [ ] Verify templates, multiple plants, scene and soil sharing, lifecycle
      changes, updates, output requests, and collection.
- [ ] Update XPalm docs and extension/notebook examples.
- [ ] Run its package tests and documentation build through a Kaimon session
      started for the XPalm checkout.

### Cross-repository completion rule

No breaking PlantSimEngine milestone is complete until:

1. PlantSimEngine examples, tests, and docs use the new contract;
2. PlantBiophysics uses and tests it;
3. XPalm uses and tests it;
4. no compatibility method remains solely to keep either downstream package
   temporarily green.

## Required Validation

### Static checks

- [ ] `git diff --check` passes in every modified repository.
- [ ] No stale removed environment API names remain:

      ```text
      with_environment!
      update_environment!
      EnvironmentSupport
      scatter_environment_outputs!
      ```

- [ ] No stale six-argument model kernel remains.
- [ ] No stale old environment trait names remain after the vocabulary rename.
- [ ] No deprecated mapping-runtime terminology remains in current user docs.
- [ ] README, tutorials, API inventory, generated graph labels, docstrings, and
      error messages use the same vocabulary.

### PlantSimEngine behavior

- [ ] One object and several objects.
- [ ] Same-object and cross-object inputs.
- [ ] `One`, `OptionalOne`, and `Many`.
- [ ] One scale, several scales, and several plant instances.
- [ ] Hard calls, nested hard calls, trials, accepted publication, and accepted
      environment commits.
- [ ] Duplicate writers and explicit update ordering.
- [ ] Repeated timesteps and different application cadences.
- [ ] `PreviousTimeStep`, `HoldLast`, `Interpolate`, `Integrate`, and
      `Aggregate`.
- [ ] Global, spatial, transient, and mutable environments.
- [ ] Distinct target handles under one `Many` trial environment.
- [ ] Object creation, removal, reparenting, movement, and geometry updates.
- [ ] Templates, instances, and overrides.
- [ ] Output retention, collection, continuation, and removed-object history.
- [ ] Generic numeric types and allocation-sensitive execution.

### Test and documentation gates

- [ ] Run focused PlantSimEngine model-contract tests.
- [ ] Run focused environment backend tests.
- [ ] Run focused steady-state allocation and scheduler tests.
- [ ] Run focused incremental lifecycle work-count and scaling tests.
- [ ] Run focused temporal-buffer and sparse-hard-call performance tests.
- [ ] Run the unified model/object API suite.
- [ ] Run the MAESPA focused suite.
- [ ] Run the full PlantSimEngine suite.
- [ ] Run the short deterministic performance-regression gate.
- [ ] Run and persist the complete XPalm performance matrix on the baseline
      machine.
- [ ] Build PlantSimEngine documentation and execute all doctests.
- [ ] Run the full PlantBiophysics suite and documentation.
- [ ] Run the full XPalm suite and documentation.
- [ ] Record exact passing counts and commands from the final source state.

## Suggested Implementation Order

1. [x] Snapshot all three dirty worktrees and identify ownership of overlapping
       changes.
2. [ ] Reproduce and profile the current XPalm performance baseline through a
       healthy Kaimon session; add the runtime counters and benchmark matrix.
3. [ ] Make lifecycle extension delta-based and verify that new-organ hard
       calls no longer rebuild the whole scene.
4. [ ] Replace repeated scheduler scanning with linear application groups.
5. [ ] Compile temporal policies into bounded typed state.
6. [ ] Restore per-batch no-hard-call specialization and separate/preallocate
       requested outputs.
7. [ ] Reach and persist the first XPalm restoration milestone before layering
       further breaking API work onto the runtime.
8. [ ] Finalize the model kernel, environment vocabulary, and required/default
       declarations.
9. [ ] Migrate PlantSimEngine models and focused contract tests.
10. [ ] Finalize `ModelSpec`, selectors, namespaces, and result ergonomics.
11. [ ] Migrate XPalm early enough that it influences scenario API decisions
        and continuously rerun its correctness and performance suites.
12. [ ] Migrate PlantBiophysics early enough that it influences model API
       decisions.
13. [ ] Rebuild the progressive simulation-user journey using existing models.
14. [ ] Rebuild the parallel model-developer journey.
15. [ ] Move migration and maintainer material out of onboarding.
16. [ ] Run the complete three-repository correctness and performance
        validation matrix.
17. [ ] Make coherent milestone commits whenever possible.
18. [ ] Delete this temporary goal after durable documentation and final
        validation evidence replace it.

## Definition of Done

This goal is complete only when a new user can:

1. open the first executable page;
2. understand a two- or three-model same-scale coupling;
3. run it over many timesteps with a short `run!` call;
4. inspect its evolving outputs;
5. progress to several objects, multiscale, multiplant, environment, and
   multirate concepts without encountering multiple new abstractions at once;
6. reach the MAESPA-style example after every major concept has already been
   introduced independently;

and when a model developer can implement the final kernel and declarations
without understanding the compiler, registry, backend handles, graph editor,
or output-retention internals.

The same final API must compile, run, and pass tests in PlantSimEngine,
PlantBiophysics, and XPalm without compatibility layers.

It must also execute the exact 4,160-step XPalm reference cycle in at most
10 seconds on the recorded baseline machine, unless a remaining cost required
by the new semantics has been measured, documented, and explicitly approved.
Steady-state execution must remain a simple compiled hot loop, structural
updates must scale with the changed objects rather than the whole scene, and
the persisted performance suite must protect those properties from regression.
