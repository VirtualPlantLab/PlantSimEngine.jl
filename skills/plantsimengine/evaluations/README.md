# Fresh-agent evaluation harness

Use each manifest case in a separate agent task with no prior PlantSimEngine
conversation. Preserve the declared workspace fixture and record a structured
trace with these fields. Use the Julia execution tools required by the host
and repository; the package evaluation does not require an external skill or
connector:

```julia
(
    triggered_skills=(:plantsimengine,),
    read_references=("references/model-authoring.md",),
    actions=(:verify_loaded_package, :inspect_available_processes),
)
```

Load `harness.jl`, then call `assess_trace(case_id, trace)`. A passing score
requires all declared skills, routed references, and actions, and rejects every
forbidden item. Record the agent transcript, package path, package root,
version, active project, files changed, and Julia test result beside the score.

Every manifest case resolves `workspace_fixture` to a versioned file or package
under `assets/` or `evaluations/fixtures/`. Call `run_oracle(case_id)` before
dispatching the agent. The five trigger/error cases validate their concrete
workspace preconditions. The ten model-authoring cases execute model,
composition, diagnostic, publication, lifecycle, numeric, or package-layout
oracles against the loaded PlantSimEngine package.

These executable oracles establish the starting state and expected technical
outcome; they still do not replace fresh-agent behavioral runs. The trace score
and transcript record skill selection, reference routing, and the declared
actions. `assess_trace` scores those behaviors, not overall scientific or task
success. An equally correct implementation can use a different route.

When comparing skill versions, assess the produced model/scenario, scientific
fidelity, executable results, and truthful evidence separately from the trace
score. Use the same task inputs and model configuration, and record cost or
runtime where relevant. Add guidance for demonstrated failures rather than
requiring every task to follow the manifest's action list.

The current cases cover technical authoring, coupling, and runtime contracts.
They do not establish success at extracting a model from a paper, forcing real
observations, calibration, or independent empirical evaluation.
