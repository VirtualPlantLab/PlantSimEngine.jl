# Readable model source compilation on top of the `multi-plants` API

Temporary implementation plan for updating `compile-models` with `multi-plants`
and implementing readable model source generation for the new `CompositeModel`
API.

The implementation currently on `compile-models` is a proof of concept. Its
code structure, internal types, generated function shape, modes, and public
names are not compatibility requirements. It may be rewritten or deleted
completely. What must be preserved is the product idea and user-facing contract
described below.

This file is a working checklist. Remove it once the implementation, validation,
and permanent documentation are complete.

## Objective

Make `compile-models` contain the current `multi-plants` implementation and add
a source-generation layer for that API. Given a model composed with the new
PlantSimEngine API, the feature must generate a new Julia script that makes the
otherwise implicit model orchestration explicit and understandable.

The generated script is the product. A user reading it should be able to see:

1. which model applications run;
2. in which order they run and why;
3. which objects or scales they apply to;
4. where each model input comes from;
5. how manually called models are nested relative to their callers; and
6. where cadence, environment, temporal, and output behavior affects execution.

The script must also be executable so its correctness can be checked against
the normal `Simulation` path, but execution speed is secondary to clarity. An
optional optimized output mode may be added later; it is not part of the core
contract.

The new work must build on the `CompositeModel` compiler. It must not restore
the removed `ModelList`, `ModelMapping`, `GraphSimulation`, or legacy dependency
graph runtimes.

## Live starting point (2026-08-17)

- Current branch: `compile-models` at `23899a9040f47e5da2ea9bf74ec440dd2e1fef83`.
- Source branch: `multi-plants` at `676be76887d63cd3f5e4e0f79d02766168abf3b0`.
- Merge base: `8e601d59ef50186898acd86b1f43762dbb537859`.
- Divergence from the merge base: 8 commits on `compile-models` and 237 commits
  on `multi-plants`.
- The current compiler implementation is mainly:
  - `src/compiled_model.jl` (986 lines);
  - `test/test-compiled-model.jl` (410 lines);
  - the include/export additions in `src/PlantSimEngine.jl`;
  - the test include in `test/runtests.jl`.
- A read-only merge preview reports textual conflicts in only:
  - `.gitignore`;
  - `src/PlantSimEngine.jl`;
  - `test/runtests.jl`.
- Generated benchmark, documentation, and frontend artifacts are currently
  untracked. They are user data and must be preserved. Do not delete or
  overwrite them as merge cleanup.

## Architectural boundary

`multi-plants` already performs runtime compilation:

1. `compile_composite_model` builds immutable application, input, call,
   schedule, and selector plans plus object-dependent bindings.
2. Environment compilation resolves environment plans and target bindings.
3. `compile_model_execution_plan` builds execution groups, batches, and concrete
   execution targets.
4. `run!`, `step!`, and `continue!` execute those plans and refresh affected
   targets at lifecycle barriers.

The feature requested here is different: it translates the resolved scenario
into readable Julia source. The new compiler artifacts should be used as the
semantic authority for order, targets, bindings, calls, cadence, and lifecycle.
The generated script must then express those decisions explicitly. Merely
emitting a wrapper that iterates opaque execution plans or calls
`_run_model_execution_batch!` would preserve execution but fail the readability
contract.

The port may reuse small source-extraction or AST-rewriting ideas from the proof
of concept, but it must not be designed around preserving that implementation.

## Non-negotiable user-facing contract

- A user can pass a scenario expressed with the new `CompositeModel` API and
  receive Julia source as a `String` or write it to a `.jl` file.
- The emitted file is valid, loadable Julia and includes a clear entry point.
- The default output is designed to be read by a human. Readability is not a
  debug side effect or a pretty-printer for internal structs.
- The source is deterministic for the same scenario so it can be reviewed,
  diffed, taught from, and kept as an explanatory artifact.
- The top-level execution order is visible directly in the generated code.
- Model bodies are shown in the generated file, either inline at their call site
  or as clearly named generated helper functions whose call sites make the
  application and manual-call graph obvious.
- Generated names use application, process, scale, and object concepts rather
  than anonymous slots wherever possible.
- Comments identify original model types, source methods, declared
  inputs/outputs, resolved input provenance, and target selection.
- Reading the file must not require understanding
  `CompiledApplicationExecutionGroup`, `CompiledExecutionBatch`, or other
  PlantSimEngine internals to discover how the scientific models call one
  another.
- Unsupported source constructs fail with a precise explanation. The readable
  mode must not silently replace an unrepresentable relationship with an opaque
  runtime call.

## Implementation freedom and semantic boundaries

- `CompositeModel`, `Object`, `ModelSpec`, `Simulation`, selectors, explicit
  input declarations, calls, environments, and output requests are the only
  scenario API targeted by the new compiler.
- The authored scenario and the normal compiled execution plan remain the
  source of truth. Generated code is an executable explanation of that resolved
  scenario, not a second authored API or an independent semantic compiler.
- Immutable application/call/schedule plans remain separate from mutable
  object-dependent targets. Generated code must not freeze object membership in
  a way that silently bypasses lifecycle invalidation.
- Ordinary input/output coupling remains reference-backed. Temporal inputs,
  `Many` carriers, output publication, environment state, and hard-call context
  must retain their current semantics.
- `PreviousTimeStep` remains a temporal dependency with no same-step scheduler
  edge.
- A generated function must reject an incompatible model or simulation with a
  clear error rather than execute against a different scenario accidentally.
- No proof-of-concept type, function, mode, AST strategy, test fixture, or file
  layout needs to survive. Reuse it only where that is simpler and demonstrably
  useful.
- Implement one excellent readable mode first. A `:fast` mode is optional and
  must not complicate or weaken the readable representation.
- Do not duplicate the optimized runtime with a permanent parallel hard-call or
  scheduling compiler. Existing runtime helpers may implement low-level
  mechanics, but they must be wrapped with explicit generated structure and
  comments so they do not hide model ordering, input provenance, or the call
  graph.

## Naming decision to settle before public export

The new API already uses `compile_composite_model` for runtime compilation.
Before exporting the source generator, choose names that make the distinction
explicit. Preferred direction:

- `compile_model_source(...) -> String` for source generation;
- `write_compiled_model(path, ...)` for persistence;
- keep `compile_composite_model(...) -> CompiledCompositeModel` unchanged.

Retaining `compile_model` as an alias is possible, but only if it cannot be
confused with `compile_composite_model` and does not create a compatibility
promise for the removed API.

## Phase 0: Preserve evidence and establish baselines

- [ ] Record `git status`, branch heads, merge base, and divergence again just
  before integration.
- [ ] Inventory the untracked benchmark results, generated HTML, and frontend
  test artifacts. Preserve them in place or move them to an explicit safe
  location only if the merge would overwrite a path.
- [ ] Through Kaimon, optionally run the current focused compiler tests and save
  one representative generated file as a UX reference. This is evidence of the
  original idea only; neither the tests nor the generated text constrain the new
  implementation.
- [ ] Through Kaimon, run or confirm an appropriate `multi-plants` baseline
  before attributing any later failure to this port.
- [ ] Record which aspects of that example make the hidden application order and
  manual calls easier to understand.

Commit checkpoint: no code commit is required for evidence-only work.

## Phase 1: Integrate `multi-plants` into `compile-models`

- [ ] Merge `multi-plants` into `compile-models` so both branch histories remain
  visible.
- [ ] Resolve `.gitignore` by preserving the new branch's rules and any still
  relevant generated-artifact exclusions from `compile-models`.
- [ ] Resolve `src/PlantSimEngine.jl` with the `multi-plants` module layout as
  authoritative.
- [ ] Resolve `test/runtests.jl` with the `multi-plants` test organization as
  authoritative.
- [ ] Keep the old `src/compiled_model.jl` and
  `test/test-compiled-model.jl` only long enough to extract useful examples or
  small implementation ideas. Delete or replace them freely; do not carry
  legacy structure forward for compatibility.
- [ ] Confirm that the integrated tree loads and that the focused new-API tests
  pass before changing compiler behavior.

Commit checkpoint: merge and conflict resolution only, with the package in a
loadable state.

## Phase 2: Define the new source-compilation contract

- [ ] Make `CompositeModel` the primary authored input. Supporting an existing
  `Simulation` may be useful for resolved output/lifecycle state, but it is an
  additional entry point rather than the conceptual API.
- [ ] Define how output selection participates in compilation. A `Simulation`
  contains output retention, temporal streams, and requests that are not fully
  represented by `CompiledCompositeModel` alone.
- [ ] Define the generated function signature. It should make fresh execution
  versus continuation explicit and should not duplicate the semantics of
  `run!`, `step!`, and `continue!` accidentally.
- [ ] Define a consistent, human-oriented file structure, preferably:
  - a header describing the source scenario and compatibility signature;
  - clearly named generated kernel/helper functions with source locations;
  - explicit application and object sections;
  - visible input preparation and provenance;
  - visible manual-call nesting; and
  - one clear top-level simulation function.
- [ ] Produce a small hand-reviewed target example before implementing the full
  generator. It should demonstrate what a reader will see for two dependent
  models and one manually called model.
- [ ] Define readability acceptance criteria. A reviewer looking only at the
  generated file must be able to reconstruct application order, target scope,
  input provenance, and the manual-call graph without opening PlantSimEngine
  internals.
- [ ] Define the compatibility signature. At minimum consider application
  plans, application order, concrete model types, object identities and target
  membership, input/call binding shapes, schedule, environment binding shape,
  output selection, and relevant model/runtime revisions.
- [ ] Define supported lifecycle behavior:
  - reject structural changes after source generation;
  - regenerate automatically at a lifecycle barrier; or
  - reuse stable generated application code while refreshing concrete targets.
- [ ] Prefer the third option if it can reuse the current lifecycle delta and
  execution-group refresh machinery without adding a second invalidation path.
- [ ] Specify unsupported source shapes and failure messages before writing the
  AST rewriter.

Commit checkpoint: tests for the public contract and compatibility failures may
land with a minimal implementation skeleton.

## Phase 3: Implement source extraction and readable rewriting

- [ ] Implement the generator cleanly in a name and location consistent with the
  new API, for example `src/composite_model/source_compilation.jl`. Copy proof-of-
  concept code only when it remains the clearest solution.
- [ ] Port method discovery and source extraction for the five-argument kernel
  contract:

  ```julia
  run!(model, status, environment, constants, context)
  ```

- [ ] Retain robust handling of typed arguments, default arguments, `where`
  clauses, nested blocks, final returns, module imports, and source metadata.
- [ ] Replace legacy `(scale, process)` lookup with compiled application and
  concrete execution-target lookup.
- [ ] Replace legacy soft-node traversal with the stable application schedule
  and execution groups already compiled by `multi-plants`.
- [ ] Rewrite current-model references from each concrete
  `CompiledExecutionTarget`, including per-object model overrides.
- [ ] Adapt readable-mode locals and comments to application id, object id,
  scale, model type, source method, declared inputs/outputs, and target count.
- [ ] Emit stable, descriptive helper and local names. Avoid slot numbers and
  opaque generated symbols in the user-facing source unless a comment explains
  them.
- [ ] Format the source intentionally rather than relying only on raw `Expr`
  printing if raw printing makes nested applications difficult to read.
- [ ] Reject ambiguous method dispatch and unsupported AST/call shapes with the
  application and object context included in the error.

Commit checkpoint: one-object, one-application source generation and execution
parity.

## Phase 4: Generate execution from new compiler artifacts

- [ ] Generate root application execution explicitly in compiled schedule order.
- [ ] Do not make the readable entry point loop over opaque application slots,
  execution groups, or batches. Translate those resolved artifacts into named
  code sections and ordinary Julia loops.
- [ ] Reuse `CompiledApplicationExecutionGroup` and `CompiledExecutionBatch`
  as generation-time information so heterogeneous model overrides and
  environment providers remain correct; they need not appear in emitted source.
- [ ] Preserve input materialization for inferred and explicit bindings,
  `One`/`OptionalOne`/`Many`, cross-object sources, temporal policies, and
  `from_status` bindings.
- [ ] Preserve application-specific status views and canonical status writes.
- [ ] Preserve global, object-local, spatial, cached, and mutable environment
  behavior.
- [ ] Preserve direct output publication, temporal streams, canonical versus
  stream-only routing, and requested output retention.
- [ ] Keep cadence dispatch correct for always, periodic, and generic schedule
  entries.
- [ ] Ensure a generated multi-step execution path has the same fresh versus
  continuing timeline semantics as the normal runtime.
- [ ] Whenever a low-level runtime helper remains necessary, precede it with a
  plain-language comment and keep the surrounding application, input, and call
  structure visible.

Commit checkpoint: static multi-object and multi-plant scenarios, including
multirate and output retention, are numerically equivalent to normal execution.

## Phase 5: Inline manual calls safely

- [ ] Detect the new hard-call forms (`call_model`, `run_call!`, and any
  supported aliases) through the compiled call plans and `RunContext`, not by
  reconstructing dependencies from model source.
- [ ] Inline only calls whose target application and target multiplicity can be
  resolved from the compiled call plan.
- [ ] Preserve `One`, `OptionalOne`, and `Many` call semantics, environment
  overrides, publication control, constants, and nested call context.
- [ ] Detect recursive call expansion and report the full application/call
  chain.
- [ ] Show manual calls inline or through clearly named generated helper
  functions so the caller/callee relationship is obvious from the script.
- [ ] When a call shape cannot be represented safely and readably, fail
  explicitly according to the contract from Phase 2. Do not silently hide it
  behind the normal hard-call runtime in the default readable output.
- [ ] Verify that no unsupported hard-call expression remains silently in the
  generated body.

Commit checkpoint: same-object, cross-object, cross-scale, nested, and
environment-overridden hard-call parity.

## Phase 6: Lifecycle and invalidation

- [ ] Exercise generated execution across `add_organ!`, `register_object!`,
  object removal, object movement, and environment-binding refreshes.
- [ ] Reuse `_extend_compiled_scene`, structural compiled deltas, and execution
  group refreshes for target changes.
- [ ] Ensure newly created objects receive compiled defaults or prior temporal
  state according to the normal runtime contract.
- [ ] Ensure `Many` carriers, status views, hard-call targets, temporal buffers,
  output retention, and output request membership are refreshed together.
- [ ] Add a deterministic stale-code guard for any structural or configuration
  change that cannot be handled incrementally.
- [ ] Verify that normal steady-state steps return to the fixed generated plan
  after a lifecycle barrier.

Commit checkpoint: dynamic-organ and mutable-environment parity without a
second lifecycle/invalidation architecture.

## Phase 7: Tests

- [ ] Replace legacy compiler fixtures with `CompositeModel` fixtures.
- [ ] Test readability and execution parity as separate requirements.
- [ ] Keep a small, representative generated script as a reviewed fixture or
  snapshot. Formatting is part of the product for this artifact, so intentional
  layout changes should receive explicit review.
- [ ] Use structural assertions for broad coverage so incidental formatting
  changes do not require updating many brittle tests.
- [ ] Assert that the readable script contains descriptive application sections,
  model source, resolved input provenance, visible execution order, and visible
  manual-call relationships.
- [ ] Assert that the readable entry point does not reduce orchestration to
  opaque calls such as `_run_model_execution_batch!`.
- [ ] Test the default readable mode first. Test an optimized mode only if one is
  deliberately added after the readable implementation is complete.
- [ ] Cover:
  - [ ] one object and one application;
  - [ ] application dependency order;
  - [ ] several objects and several plants;
  - [ ] selectors and per-object model overrides;
  - [ ] explicit, inferred, renamed, and cross-object inputs;
  - [ ] `One`, `OptionalOne`, and `Many` carriers;
  - [ ] `PreviousTimeStep`, aggregation, integration, and interpolation;
  - [ ] heterogeneous cadence;
  - [ ] hard calls, nested calls, and call environment overrides;
  - [ ] canonical and stream-only outputs;
  - [ ] output requests and `outputs=:none`;
  - [ ] global and spatial environments;
  - [ ] lifecycle additions and structural refresh;
  - [ ] incompatible-model and stale-generated-code errors;
  - [ ] unsupported source and call shapes.
- [ ] Compare final state, retained outputs, requested outputs, temporal state,
  and relevant environment state against normal `run!`/`step!` execution.
- [ ] Have at least one human review the representative generated script without
  relying on the original scenario definition, and record any parts that still
  obscure the model call graph.
- [ ] Treat performance and allocation measurements as optional follow-up work.
  They must not drive the generated source back toward opaque runtime dispatch.

## Phase 8: Public API and documentation

- [ ] Export only the agreed source-generation entry points from the appropriate
  namespace.
- [ ] Document the distinction between runtime compilation and generated source.
- [ ] Lead the documentation with the actual purpose: turning an implicitly
  composed model into explicit Julia code that users can inspect to understand
  execution order, coupling, and manual calls.
- [ ] Document supported scenario features, compatibility guards, lifecycle
  behavior, and unsupported Julia source shapes.
- [ ] Add a small progressive example using the canonical API, beginning with a
  normal `CompositeModel` run and then generating, reviewing, loading, and
  executing source.
- [ ] Walk through the generated example in execution order and explain how the
  original model list became explicit code.
- [ ] Explain when readable source is useful and when the normal compiled
  runtime should be preferred.
- [ ] Do not add compatibility documentation for removed mapping-era APIs.

Commit checkpoint: public API, docstrings, guide, and changelog.

## Phase 9: Validation

All Julia commands must run through Kaimon.

- [ ] Load the package in a fresh or confirmed PlantSimEngine Kaimon session.
- [ ] Run the focused source-compiler tests.
- [ ] Run the relevant compiler/runtime suites for:
  - [ ] API stabilization;
  - [ ] unified model/object behavior;
  - [ ] bindings and configuration errors;
  - [ ] hard calls;
  - [ ] multirate and temporal reducers;
  - [ ] previous-timestep views;
  - [ ] outputs and lifecycle behavior;
  - [ ] environments.
- [ ] Run the complete PlantSimEngine test suite.
- [ ] Run documentation tests/build if public documentation changed.
- [ ] Run the established downstream PlantBiophysics and XPalm gates if the
  generated path or shared runtime helpers changed.
- [ ] Run `git diff --check` and review the final diff for generated artifacts,
  temporary diagnostics, and accidental legacy API restoration.
- [ ] Record Julia versions and distinguish fresh results from historical or
  repository-recorded evidence.

## Completion criteria

- [ ] `compile-models` contains `multi-plants` with its current API and runtime
  behavior intact.
- [ ] Source generation accepts the agreed new-API inputs and emits loadable
  Julia code.
- [ ] A user can read the generated file and identify all model applications,
  their execution order and targets, their resolved input sources, and their
  manual caller/callee relationships without inspecting PlantSimEngine's
  internal compiled plan types.
- [ ] The generated file contains the relevant model code, not only calls into an
  opaque generic executor.
- [ ] Generated execution matches normal execution for the static, multirate,
  environment, hard-call, output, and lifecycle cases in scope.
- [ ] Compatibility and unsupported-shape errors are deterministic and useful.
- [ ] No removed mapping-era runtime or compatibility alias has been restored.
- [ ] No duplicate scheduler, selector compiler, binding compiler, or lifecycle
  invalidation path has been introduced.
- [ ] No proof-of-concept implementation detail remains solely for backward
  compatibility.
- [ ] Focused, full-package, documentation, and applicable downstream checks are
  green with recorded evidence.
- [ ] Temporary comparison artifacts and this plan are removed after permanent
  documentation and implementation history are sufficient.
