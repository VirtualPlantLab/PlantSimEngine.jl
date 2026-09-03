# Fresh-agent evaluation harness

Use each manifest case in a separate agent task with no prior PlantSimEngine
conversation. Preserve the declared workspace fixture and record a structured
trace with these fields:

```julia
(
    triggered_skills=(:kaimon_julia, :plantsimengine),
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
and transcript are the evidence that an agent selected the skill, read only the
routed references, and followed the workflow rather than merely reaching the
same runtime result.
