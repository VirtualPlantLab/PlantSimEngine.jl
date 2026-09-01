# Organizing a package of PlantSimEngine models

Read this reference when creating a model package, adding a process family, or
splitting an oversized scenario definition. The exact hierarchy may follow a
domain (radiation, carbon, water) or a botanical scale (plant, leaf, root); the
invariants below matter more than the folder names.

## Recommended shape

```text
src/
├── MyModels.jl
├── plant/
│   ├── PlantModels.jl
│   └── carbon_gain/
│       ├── process.jl
│       ├── LinearRUE.jl
│       └── SaturatingRUE.jl
├── leaf/
│   ├── LeafModels.jl
│   └── photosynthesis/
│       ├── process.jl
│       └── FvCB.jl
└── scenarios/
    ├── leaf_applications.jl
    ├── plant_applications.jl
    └── default_scenario.jl

test/
├── runtests.jl
├── models/
│   ├── test-LinearRUE.jl
│   └── test-SaturatingRUE.jl
├── coupling/
│   └── test-carbon-gain.jl
└── scenarios/
    └── test-default-scenario.jl

docs/src/models/
├── carbon-gain.md
└── photosynthesis.md
```

Use flatter nesting for a small package. Do not create empty architectural
layers merely to match the diagram.

This convention distills patterns already visible in model packages such as
PlantBiophysics, where one process directory contains several formulations,
and XPalm, where process declarations and alternatives such as RUE or Q10
models are grouped by domain and scale. Treat those repositories as design and
downstream-validation references, not as moving tutorial dependencies. Keep
the invariants above; do not copy historical filenames or incomplete models
without reviewing them.

## Ownership invariants

- One process declaration represents one scientific meaning.
- Put each public concrete hypothesis/model in its own file.
- Keep alternatives for a process next to one another so their parameters,
  ports, contracts, assumptions, and validation status are easy to compare.
- Reuse a process type owned by a dependency instead of redeclaring it.
- Include process declarations before concrete models and make public exports
  explicit in the package module.
- Give each process one documentation page that compares the available model
  hypotheses rather than only listing generated signatures.
- Keep experimental, obsolete, or incomplete models outside the public
  `src/` include path unless the package has an explicit and machine-readable
  maturity convention.

## Keep scenario assembly readable

A large scenario is application configuration, not one model. Split it into
named builders by domain or scale:

```julia
leaf_applications(parameters) = (
    ModelSpec(...),
    ModelSpec(...),
)

plant_applications(parameters) = (
    ModelSpec(...),
)

function default_applications(parameters)
    return (
        leaf_applications(parameters)...,
        plant_applications(parameters)...,
    )
end
```

Keep selectors and application names close to the applications they configure.
Centralize only shared parameter parsing and the final assembly. Avoid one
thousand-line function containing every object, binding, model, and parameter
lookup.

Validate structured input parameters before constructing applications. Avoid
deep dictionaries whose misspelled string keys are detected only during a
simulation.

## Kernel readability convention

The main `run!` method should remain a short scientific narrative:

1. derive or read environmental drivers;
2. compute named intermediate physical or biological quantities;
3. compute final fluxes/states;
4. assign outputs;
5. return `nothing`.

Extract a helper when at least one is true:

- it represents a named equation that benefits from its own docstring;
- it is used by several concrete models;
- it has an independent unit or property test;
- it hides numerical optimization, root finding, or another mechanism that
  would obscure the scientific flow.

Do not extract a helper merely because an expression spans several lines. Do
not put a replaceable subprocess in a private helper: implement it as a model
of its own process so scenarios can couple and replace it explicitly.

## Documentation expected for each model

Record, without inventing missing information:

- process and hypothesis;
- equation or algorithm in readable form;
- parameter meanings, units, defaults, and valid ranges;
- input, output, and environment contracts;
- temporal and spatial scale;
- source/reference and any deviations from it;
- domain of validity and known limitations;
- validation level and datasets used;
- compatible alternatives and whether they are drop-in replacements.

Generate port/contract tables from `Authoring.describe_model(instance)` where
possible. Keep scientific explanation and citations in prose; do not expect
reflection to infer them.

## Test placement and scope

- `test/models/`: schemas, contracts, direct kernels, generic numeric types,
  edge cases, and named helper equations.
- `test/coupling/`: same-object inference, cross-object selectors, adapters,
  hard calls, and compatibility between alternatives.
- `test/scenarios/`: object topology, schedules, lifecycle, output retention,
  and representative full compositions.
- Separate scientific/empirical evaluation from structural package tests when
  datasets or long runtimes make that distinction useful.

A passing direct kernel test does not prove composition; a passing scenario
test does not prove scientific validity. Report those evidence levels
separately.

## Checklist when adding an implementation

1. Confirm the owner and meaning of the process.
2. Add one model file beside the existing alternatives.
3. Add includes and exports deliberately.
4. Declare ports, environment, and `VariableContract`s.
5. Write a continuous, generic `run!`.
6. Add a focused direct test and a relevant coupling test.
7. Compare the new model with existing alternatives using
   `Authoring.compare_models`.
8. Update the process documentation page with hypothesis, parameters,
   validity, reference, and validation level.
9. Validate one minimal scenario before changing a full production scenario.
