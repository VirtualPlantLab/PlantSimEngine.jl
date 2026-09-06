# Model repository layout and tests

Organize a model package so a colleague can find the equation, its alternative
hypotheses, and the evidence used to test it. A small package can start with
one model file and one test file, then grow as needed.

## Group alternatives by scientific process

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

Use `process.jl` only when this package owns the process declaration.
Otherwise import the abstract process type from its owner. Keep one readable
file per hypothesis and make includes and exports explicit in `MyModels.jl`.

A process page should compare the alternatives: equations, assumptions,
required data, units, parameters, validity domain, references, and validation
status. Label teaching models and unfinished experiments clearly.

## Test from the equation outward

Each level answers a different question:

| Check | Question it answers |
|---|---|
| Direct equation test | Does the implementation reproduce a known calculation? |
| Declaration check | Are required inputs, outputs, and physical meanings explicit? |
| Small composition | Can the model obtain its inputs and run on the intended object? |
| Coupled scenario | Does it interact correctly with the other models used in this study? |

Start with the canonical biomass example from
[Implement a basic model](@ref):

```@example repository-tests
using Dates, Test, PlantSimEngine
include(joinpath(
    pkgdir(PlantSimEngine), "skills", "plantsimengine",
    "assets", "minimal-model.jl",
))
using .MinimalModelExample

model = RadiationUseEfficiency(1.5f0)
status = Status(intercepted_par=10.0f0, biomass_increment=0.0f0)
PlantSimEngine.run!(model, status, NamedTuple(), nothing, nothing)
@test status.biomass_increment == 15.0f0
@test status.biomass_increment isa Float32
@test Authoring.validate_model(model; strict=true).valid

scenario = CompositeModel(
    model; status=(intercepted_par=10.0f0,), timestep=Day(1),
)
@test final_state(run!(scenario)).biomass_increment == 15.0f0
```

These small checks isolate the equation from input routing and scheduling.
For a scientific model, add edge cases and a trusted reference calculation
or dataset. Agreement with the reference needs a numerical tolerance
appropriate to the calculation.

## Add checks for the features you use

A model with cross-object inputs needs tests that the intended objects supply
them. A model with several cadences needs checks at their update boundaries.
A growing scenario needs checks before and after organs are added or removed.
An iterative controller needs tests of both rejected trials and accepted
publication.

Use `Diagnostics` to inspect the relevant connections and schedules, then
assert the scientific relationship you intend to preserve. For example,
check that a plant total uses its own leaves and excludes a neighbouring
plant's leaves.

Exercise the numerical types your model supports. Measure performance where
large organ counts or repeated calls matter; keep such benchmarks separate
from equation checks. See [Numerical Reliability](@ref) and the
[benchmarking guidance](../../developers.md).

## Review a new hypothesis

Before sharing a model, check that:

- it belongs to the intended process;
- its inputs, outputs, units, bases, and timing are documented;
- its equation and fixed parameters are easy to find;
- each object's changing state stays separate;
- direct tests and the relevant coupled tests pass;
- scientific validation and remaining uncertainty are stated.

When a scenario becomes long, group its application definitions into named
functions by domain, such as leaf, plant, and soil processes. Keep those
functions as ordinary collections of `ModelSpec` values so the scenario
remains inspectable.
