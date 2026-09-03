# Implement a basic model

**New concept:** the complete one-step model boundary: process identity,
parameters, ports, scientific contracts, and a readable five-argument kernel.
This page uses the tested canonical fixture shipped with the PlantSimEngine
skill, first directly and then through the ordinary runtime.

Before creating a type, follow [New process or new model?](@ref). The example
below is one hypothesis for the `biomass_production` process. Its coefficients
are pedagogical, not a calibrated crop model.

## Load the canonical fixture

The documentation and agent skill use the same executable source instead of
maintaining two copies:

```@example modeler_basic
using Dates, PlantSimEngine

asset = joinpath(
    pkgdir(PlantSimEngine),
    "skills",
    "plantsimengine",
    "assets",
    "minimal-model.jl",
)
include(asset)
using .MinimalModelExample

boundary = RadiationUseEfficiency(1.5f0)
description = Authoring.describe_model(boundary)
validation = Authoring.validate_model(boundary; strict=true)
(
    runtime_process=process(boundary),
    described_process=description.process,
    inputs=inputs(boundary),
    outputs=outputs(boundary),
    contracts=variable_contracts(boundary),
    description_provenance=description.provenance,
    field_provenance=description.field_provenance,
    structurally_valid=validation.valid,
)
```

The loaded declaration is deliberately short. `RadiationUseEfficiency{T}`
stores `rue`; its schemas declare `intercepted_par` and
`biomass_increment`, plus explicitly empty environment inputs and outputs. The
two ports receive complete contracts, and the complete kernel equation is
`status.biomass_increment = model.rue * status.intercepted_par` followed by
`return nothing`. This description is derived from the asset included above,
so the tutorial does not maintain a second untested copy of its source.

The model struct stores only the fixed radiation-use-efficiency parameter.
`Required(Real)` is a type requirement, not an initial value. The output
initial value follows the parameter's numeric type. The complete
`VariableContract` declarations state that intercepted radiation and biomass
increment are daily, plant-scale totals with explicit units.

The kernel reads as the scientific calculation from input to output. It does
not select objects, find producers, choose a cadence, or retain output rows;
those are scenario responsibilities.

## Test the kernel directly

Use a minimal `Status` before involving the compiler:

```@example modeler_basic
direct = direct_example(Float32)
(
    biomass_increment=direct.biomass_increment,
    value_type=typeof(direct.biomass_increment),
)
```

This test isolates the equation and proves that the fixture preserves
`Float32`. Model packages should also test edge cases and supported enriched
number types.

## Compose it on one object

The asset provides the smallest full scenario with the required input supplied
as initial status:

```@example modeler_basic
one_object = single_object_scenario(Float32)
(
    initialization=Diagnostics.explain_initialization(one_object),
    final=final_state(run!(one_object)),
)
```

`Diagnostics.explain_initialization` distinguishes supplied inputs, model
defaults, produced outputs, environment bindings, and unresolved requirements.
Inspect this report before running a larger scenario.

## Reuse the same kernel over several objects

Object selection remains outside the model. Change only the application
multiplicity and provide each object with initial radiation:

```@example modeler_basic
development = RadiationUseEfficiency(1.5f0)
several_objects = CompositeModel(
    Object(
        :plant_1;
        scale=:Plant,
        status=Status(intercepted_par=10.0f0),
    ),
    Object(
        :plant_2;
        scale=:Plant,
        status=Status(intercepted_par=6.0f0),
    );
    applications=(
        ModelSpec(
            development;
            name=:biomass_production,
            on=Many(scale=:Plant),
        ),
    ),
)

final_state(run!(several_objects), Many(scale=:Plant))
```

Do not loop over objects inside `RadiationUseEfficiency.run!`.
PlantSimEngine compiles homogeneous targets and invokes the one-target kernel
for each selected object.

## Continue the authoring path

- [Port an existing model](@ref) explains the readable-kernel convention.
- [Model repository layout and tests](@ref) shows where to place alternatives,
  documentation, and each test level.
- [Implement Cross-Object Values](@ref) adds `One`, `Many`, and `Subtree()`
  bindings.
- [Coupling models](@ref) explains when `OptionalOne` is valid and
  distinguishes value coupling, hard calls, and explicit physical adapters.
- [Model compatibility and replacement](@ref) checks whether another
  hypothesis is genuinely substitutable.

## Model-author recap

- **You implemented:** one immutable parameter type, declared ports, complete
  scientific contracts, and a continuous one-target kernel.
- **PlantSimEngine inferred:** initialization, target execution, and generic
  status construction.
- **The scenario author keeps explicit:** object identities, target
  multiplicity, initial radiation, cadence, and output retention.
- **New API names:** `AbstractModel`, `inputs_`, `outputs_`,
  `variable_contracts_`, `VariableContract`, `Required`, `Status`, and `run!`.
