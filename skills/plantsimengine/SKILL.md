---
name: plantsimengine
description: Implement, couple, debug, force with observations, calibrate, and evaluate PlantSimEngine.jl models and CompositeModel/Object scenarios. Use for PlantSimEngine-dependent model packages and scientific process alternatives.
---

# PlantSimEngine

Assume a recent frontier coding and reasoning model with general Julia and
scientific programming competence. This skill supplies package-specific
constraints, references, and executable examples. Choose the approach that
fits the task; the references are resources, not a required sequence. Use the
unified `CompositeModel`/`Object` API.

## Package and execution context

For source-only work, identify the checkout inspected. Before executing or
interpreting runtime evidence, verify the loaded package and active project:

```julia
using PlantSimEngine
(path=Base.pathof(PlantSimEngine), root=pkgdir(PlantSimEngine),
 version=Base.pkgversion(PlantSimEngine), project=Base.active_project())
```

Resolve version-specific documentation, assets, and the package-owned skill
from `pkgdir(PlantSimEngine)`; the skill is at `skills/plantsimengine`.
A checkout, installed skill copy, and loaded depot package may differ. Report
relevant mismatches rather than combining incompatible APIs.

Use the Julia tools available in the host environment. Kaimon is optional for
this package skill; when the user or repository requires it, honor that
requirement. If execution is unavailable, report source checks as source checks.

## References by task

- Model from a paper: [paper-to-model.md](references/paper-to-model.md).
- Model boundary, process choice, contracts, kernel, or wrapper:
  [model-authoring.md](references/model-authoring.md).
- Component coupling, selectors, time, environment, adapters, or hard calls:
  [scenario-coupling.md](references/scenario-coupling.md).
- Debugging, model compatibility, or compiled/runtime explanations:
  [diagnostics.md](references/diagnostics.md).
- Observation forcing, parameter fitting, or empirical evaluation:
  [data-calibration-evaluation.md](references/data-calibration-evaluation.md).
- Topology, MTG growth, initializers, or distributed outputs:
  [dynamic-models.md](references/dynamic-models.md).
- Reusable model package organization:
  [repository-layout.md](references/repository-layout.md).

## Domain and API constraints

- The process identifies the scientific operation; concrete models represent
  its hypotheses. Reuse an existing process when appropriate. Shared process
  identity alone does not establish replacement compatibility.
- Declare ports and complete known `VariableContract`s. Unit, basis, temporal
  meaning, aggregation, or extent conversions belong in explicit adapters.
  Never invent metadata or remove contracts to make a connection compile.
- Preserve generic parameter/status types. Keep the scientific equations
  readable in `run!`, use public context APIs, and return `nothing`.
- Declare distributed outputs as `Distributed(Default(value))` or
  `Distributed(Required(T))`; use anonymous `OutputTo` entries and request
  target views by output-variable tuple. Ordinary outputs remain local.
- Preserve canonical writers, object identities, lifecycle refresh, and
  accepted-state publication. The task references explain these contracts.
- Prefer `Authoring` and `Diagnostics` for supported interface and runtime
  facts. Preserve exact, inferred, and missing-information distinctions.
- Keep source facts, scientific assumptions, calibration results, held-out
  evaluation, and structural tests distinct. Missing scientific information
  remains explicit; passing a test does not validate a hypothesis.

## Outcomes proportional to the task

| Task | Useful completion evidence |
| --- | --- |
| New model | Traceable equations and assumptions, declared boundary/contracts, a reference calculation or stated lack of one, and a minimal compiled composition. |
| Coupling change | Intended source/destination identities, compatible contracts or tested adapters, and behavior of the changed bindings. |
| Debugging | A reproducible failure or bounded diagnosis, evidence for its cause, and a focused check of the correction. |
| Observation forcing | Identified measured inputs, ownership and sampling policy, and evidence that intended observations reach consumers. |
| Calibration | Reproducible fitting data/objective/parameter choices, fitted values, diagnostics, and the declared limits of the fit. |
| Empirical evaluation | Frozen configuration, independent evaluation data where claimed, explicit prediction/observation alignment, and appropriate metrics and plots. |

Exercise numeric types, time policies, hard calls, lifecycle, or output
retention when the change affects them. Use narrow public reports that answer
the current question; all diagnostic reports need not run on every task.
Report what was actually executed, the runtime path/version when applicable,
and unresolved scientific or implementation limitations.

## Executable examples

Adapt these when they fit the task:

- [minimal-model.jl](assets/minimal-model.jl): model boundary, direct kernel,
  and one-object scenario.
- [alternative-model.jl](assets/alternative-model.jl): compatible and
  incompatible alternatives of one process.
- [adapter-model.jl](assets/adapter-model.jl) and
  [coupling-patterns.jl](assets/coupling-patterns.jl): conversion, `One`,
  `OptionalOne`, renamed inputs, and `Many`/`Subtree()`.
- [runtime-patterns.jl](assets/runtime-patterns.jl): `HoldLast`,
  `PreviousTimeStep`, and hard-call publication.
- [lifecycle-output.jl](assets/lifecycle-output.jl): newborn initialization
  and distributed outputs; [model-tests.jl](assets/model-tests.jl) checks assets.

After changing executable assets or their API contracts, run
`scripts/check-examples.jl` in the verified Julia environment when available.
For skill behavior evaluation, see [evaluations/README.md](evaluations/README.md).
Static checks and example tests are not evidence that an independent agent
successfully completed a task.
