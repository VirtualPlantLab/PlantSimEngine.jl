# Model repository layout and tests

A model package should make process ownership, alternative hypotheses, and
validation levels visible from the directory tree. The exact hierarchy may
follow domains or plant scales, but keep one file per concrete model and group
alternatives under their shared process.

## Recommended layout

```text
src/
├── MyModels.jl
└── processes/
    ├── photosynthesis/
    │   ├── process.jl
    │   ├── Farquhar.jl
    │   └── EmpiricalAssimilation.jl
    └── growth/
        ├── process.jl
        └── CarbonLimitedGrowth.jl

test/
├── runtests.jl
├── models/
├── coupling/
└── scenarios/

docs/src/models/
├── photosynthesis.md
└── growth.md
```

Use `process.jl` only when this package owns the process declaration. If a
dependency already declares the process, import and subtype its abstract model
type rather than declaring a second identity.

This convention retains the useful pattern from
`PlantBiophysics/src/processes/<process>/`, where alternatives such as FvCB and
constantA live beside their shared process. XPalm similarly makes process
identity and alternatives visible through files such as `0-process.jl`,
`rue.jl`/`rue_ftsw.jl`, and `Q10.jl`/`Q10_BP.jl`. Keep the invariant—one shared
process identity and one readable file per hypothesis—but prefer the explicit
name `process.jl` over the historical ordering prefix `0-process.jl`. These
packages are design references, not moving dependencies of this tutorial or
its tests.

Keep includes and exports explicit in the package module. A process page should
compare the available implementations side by side: assumptions, ports,
`VariableContract`s, parameters, domain of validity, references, and scientific
validation status. Put incomplete experiments outside the public `src/`
include path, or mark their maturity unambiguously.

Large scenario assemblies deserve named fragments by domain or scale, for
example `leaf_applications(parameters)`, `plant_applications(parameters)`,
and `soil_applications(parameters)`. These functions return ordinary
`ModelSpec` collections; they do not introduce another scenario runtime.

## Test pyramid

Test failures are easiest to interpret when each level adds one responsibility:

1. **Schema and contracts:** inspect `inputs_`, `outputs_`,
   `environment_inputs_`, `environment_outputs_`, and `variable_contracts_`.
2. **Direct kernel:** call `run!` on a minimal `Status` and sampled environment.
3. **One-object composition:** check defaults, inferred same-object bindings,
   and scheduling.
4. **Explicit coupling:** test renamed, cross-object, `Many`, temporal, and
   hard-call inputs used by the model.
5. **Diagnostics:** assert the intended application, source, carrier, call,
   writer, and schedule rows.
6. **Scenario regression:** compare a small scientifically interpretable
   scenario with a trusted result.
7. **Generic numerics and performance:** exercise supported numeric types and
   allocation-sensitive organ loops.

The first two levels should remain small enough to run after every model edit:

```@example repository-tests
using Test
using PlantSimEngine
using PlantSimEngine.Examples

model = ToyDevelopmentModel(0.5f0)
@test keys(PlantSimEngine.inputs_(model)) == (:TT, :stress)
@test keys(PlantSimEngine.outputs_(model)) == (:growth,)
@test isempty(PlantSimEngine.environment_inputs_(model))
@test isempty(PlantSimEngine.environment_outputs_(model))

status = Status(TT=8.0f0, stress=0.75f0, growth=0.0f0)
PlantSimEngine.run!(model, status, nothing, nothing, nothing)
@test status.growth == 3.0f0
@test status.growth isa Float32

composite = CompositeModel(model; status=(TT=8.0f0,))
simulation = run!(composite)
@test final_state(simulation).growth == 4.0f0
```

A green full-scenario test does not replace the kernel test: it usually cannot
show whether an error came from the equation, a contract, object selection, or
the scenario data. Likewise, a direct kernel test does not prove that
cross-object bindings or lifecycle behavior compile correctly.

## Review checklist for a new hypothesis

- The concrete type subtypes the intended existing process.
- Parameters are immutable and generic where the mathematics permits.
- Every status and environment read is declared.
- Every written status field is declared as an output.
- Connected scientific variables have complete, matching contracts.
- The main `run!` reads as a continuous scientific calculation.
- Alternative models do not hide behind a mode flag.
- Direct, composition, coupling, and generic-numeric tests cover the model's
  actual responsibilities.
- Documentation states what is measured, tested, proposed, or still
  scientifically unvalidated.
