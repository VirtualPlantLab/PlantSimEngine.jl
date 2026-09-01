---
name: plantsimengine
description: Create, couple, run, inspect, diagnose, and test PlantSimEngine.jl models and CompositeModel/Object scenarios. Use for model implementations in PlantSimEngine-dependent packages, scientific process alternatives, multiscale coupling, lifecycle behavior, environments, hard calls, multirate execution, or PlantSimEngine diagnostics.
---

# PlantSimEngine

Use the unified `CompositeModel`/`Object` API. Treat the Julia model code as the
readable scientific source and the compiler, contracts, and diagnostics as the
structured evidence. Do not recreate mapping-era APIs or add compatibility
wrappers unless the user explicitly requests compatibility work.

## Verify the loaded package first

For any Julia work, load the `kaimon-julia` skill and use a Kaimon session for
the exact target project. Before reading an API from memory, editing Julia, or
running an example, evaluate:

```julia
using PlantSimEngine, Pkg
(
    path = Base.pathof(PlantSimEngine),
    root = pkgdir(PlantSimEngine),
    version = Base.pkgversion(PlantSimEngine),
    active_project = Base.active_project(),
)
```

Use these values in the result you report. A loaded depot copy, another
checkout, a stale Codex skill, and the current worktree are different sources.
The package-owned skill is:

```julia
joinpath(pkgdir(PlantSimEngine), "skills", "plantsimengine")
```

Resolve package documentation and assets from `pkgdir(PlantSimEngine)`, not
from the current working directory. Never overwrite an installed skill copy
automatically. Compare it with the package copy and update it only after an
explicit user request.

When checking an installed copy, first resolve both directories, then use a
read-only recursive diff and report which one matches the loaded package
version. If the user explicitly asks to synchronize it, replace the installed
`plantsimengine` directory from the package-owned directory as one operation;
do not merge the two copies or maintain installed-only instructions.

## Route the task

Read only the references needed for the request:

- Creating or wrapping a model, choosing a process, declaring ports and
  contracts, implementing alternatives, or testing a kernel: read
  [references/model-authoring.md](references/model-authoring.md).
- Building a `CompositeModel`, selecting objects, coupling values, configuring
  time/environment, using hard calls, or adding an adapter: read
  [references/scenario-coupling.md](references/scenario-coupling.md).
- Creating or reorganizing a package of models: read
  [references/repository-layout.md](references/repository-layout.md).
- Adding/removing/reparenting objects, MTG organ creation, initializers,
  geometry changes, or distributed outputs: read
  [references/dynamic-models.md](references/dynamic-models.md).
- Inspecting a model, comparing alternatives, explaining compilation, or
  diagnosing a failure: read
  [references/diagnostics.md](references/diagnostics.md).

Executable examples live in `assets/`. Prefer adapting them over inventing a
new skeleton:

- [assets/minimal-model.jl](assets/minimal-model.jl): one generic model, direct
  kernel call, scientific contracts, and one-object composition;
- [assets/alternative-model.jl](assets/alternative-model.jl): two drop-in
  alternatives and one non-drop-in alternative of the same process;
- [assets/adapter-model.jl](assets/adapter-model.jl): explicit conversion of a
  physical basis in a cross-object scenario;
- [assets/coupling-patterns.jl](assets/coupling-patterns.jl): explicit `One`,
  unresolved `OptionalOne`, renamed values, and `Many` over `Subtree()`;
- [assets/runtime-patterns.jl](assets/runtime-patterns.jl): `HoldLast`,
  `PreviousTimeStep`, and parent-owned hard-call publication;
- [assets/lifecycle-output.jl](assets/lifecycle-output.jl): lifecycle
  registration with a one-shot initializer and identity-aware `outputs_to`;
- [assets/model-tests.jl](assets/model-tests.jl): executable tests for all
  examples.

Run `scripts/check-examples.jl` through the verified Kaimon session after
changing the skill or its assets.

Fresh-agent cases and their structured trace oracle live in
[evaluations/manifest.jl](evaluations/manifest.jl) and
[evaluations/harness.jl](evaluations/harness.jl); follow
[evaluations/README.md](evaluations/README.md). Static repository tests prove
that this matrix is complete and internally consistent, not that an agent
passed it. Run each case in a context-free agent task before claiming
behavioral evidence.

## Non-negotiable model rules

1. **The process carries the scientific meaning.** Implement a new concrete
   model for a new hypothesis of an existing process. Declare a new process
   only when the biological or physical question is genuinely different.
2. **Same process does not imply substitutability.** A direct replacement also
   requires compatible inputs, outputs, environment ports, variable contracts,
   dependencies, and relevant traits. Use `Authoring.compare_models` rather
   than assuming compatibility from `process(model)`.
3. **Make scientific conversions explicit.** A change of unit, basis,
   temporal meaning, aggregation, or extent belongs in a named adapter model,
   never in an unexplained binding or hidden factor.
4. **Keep `run!` readable from top to bottom.** The kernel should show the
   scientific calculation. Extract helpers for named equations, genuinely
   reused/tested units, or isolated optimization machinery—not mechanically
   for every line.
5. **Keep values generic.** Do not force `Float64`; preserve parameter, status,
   carrier, and output types. Return `nothing` from `run!`.
6. **Do not invent science.** If units, basis, defaults, hypotheses, parameter
   bounds, references, or validation criteria are unknown, leave the decision
   explicit and ask or report it as unresolved.
7. **Use public evidence.** Prefer `Authoring` and `Diagnostics`; do not inspect
   compiled fields or use `Advanced` unless the task is specifically compiler
   integration or cache behavior.

## Canonical authoring workflow

1. Verify package path, version, and active project.
2. Inspect the package and `Authoring.available_processes()` before declaring
   a process. Inspect candidate models with `Authoring.available_models(...)`
   and `Authoring.describe_model(...)`.
3. Make the process-versus-hypothesis decision explicit.
4. Create the concrete model type and declare its fixed parameters.
5. Declare `inputs_`, `outputs_`, `environment_inputs_`, and
   `environment_outputs_`.
6. Declare complete `variable_contracts_` beside the corresponding ports.
7. Add `dep`, hard calls, initializers, temporal/output traits, or environment
   hints only when they are intrinsic to the model.
8. Write a continuous, numerically generic `run!` that returns `nothing`.
9. Test the kernel directly with a minimal `Status` and environment.
10. Compose the model on one object, then add same-object and explicit
    cross-object bindings as required.
11. Validate with `Authoring.validate_model`,
    `Authoring.validate_scenario`, and public diagnostics for initialization,
    bindings, calls, writers, schedule, execution plan, and environment before
    a full simulation.
12. Implement a second hypothesis of the same process and use
    `Authoring.compare_models` to establish whether it is truly
    interchangeable; test another numeric type and every introduced coupling
    or lifecycle behavior.
13. Document the hypothesis, units, domain of validity, reference status,
    maturity, and scientific validation level. Use `model_metadata` and
    `parameter_metadata` for structured facts, and state explicitly when an
    example is pedagogical, non-calibrated, or has no scientific reference.

When an `Authoring` report marks information as inferred or best effort, do
not present it as exact instance evidence. When the loaded package predates a
documented API, stop using that API and report the version mismatch; do not
silently substitute historical syntax.

## Completion evidence

For a new model or coupling, do not claim completion without evidence for:

- process identity and declared ports;
- complete scientific contracts for every contracted connection;
- a direct kernel test;
- a compiled minimal scenario;
- intended bindings, calls, writers, schedule, and environment sources;
- generic numeric behavior where scientifically meaningful;
- targeted lifecycle or multirate behavior when used;
- the exact package path/version under which validation ran.

Keep structural correctness separate from scientific validation. Passing
PlantSimEngine tests proves the declared computational contract, not that an
equation, parameterization, or dataset is scientifically valid.
