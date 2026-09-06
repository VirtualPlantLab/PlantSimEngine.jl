# Implement a basic model

This teaching example describes daily biomass production as:

**biomass increment = radiation-use efficiency × intercepted radiation**

For an efficiency of 1.5 g dry matter per mol of photons and 10 mol of
intercepted photons per plant, the result is 15 g dry matter per plant.
These values illustrate the interface; they are not a calibrated crop model.

We will give that equation a name, declare its variables and units, test it,
and run it on two plants. Before adding your own model, use
[New process or new model?](@ref) to choose its process.

## Name the process and its model

A **process** identifies the scientific calculation. A **model** implements
one hypothesis for it. This example declares a biomass-production process:

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "PlantSimEngine.@process", "const INTERCEPTED_PAR_CONTRACT",
)
```

The model stores one fixed parameter, `rue`. The `{T}` allows its numerical
type to follow the supplied parameter.

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "struct RadiationUseEfficiency", "PlantSimEngine.inputs_",
)
```

## Declare the values the equation uses

| Value | Role | Meaning |
|---|---|---|
| `rue` | Fixed parameter | g dry matter per mol intercepted photons |
| `intercepted_par` | Input | Daily intercepted photons, mol per plant |
| `biomass_increment` | Output | Daily biomass production, g dry matter per plant |

`Required(Real)` says the simulation must supply a real-valued input.
`zero(model.rue)` initializes the output with the parameter's numerical type.
This model reads no environmental variables directly.

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "PlantSimEngine.inputs_(::RadiationUseEfficiency)",
    "PlantSimEngine.variable_contracts_",
)
```

A `VariableContract` states the physical meaning of a value at a connection
between models. Here both quantities are daily totals for one plant:

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "const INTERCEPTED_PAR_CONTRACT", "\"\"\"",
)
```

Attach those descriptions to the corresponding variables:

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "PlantSimEngine.variable_contracts_(::RadiationUseEfficiency)",
    "PlantSimEngine.Authoring.model_metadata",
)
```

Matching contracts help check connections. Converting between physical bases
or units requires an explicit [adapter model](../../guides/coupling.md).

## Write the equation

The `run!` function reads the parameter from `model`, reads the input from
`status`, and writes its result back to `status`:

```@eval
Main.DocsSources.section(
    "skills/plantsimengine/assets/minimal-model.jl",
    "function PlantSimEngine.run!(", "\"\"\"Run the kernel directly",
)
```

The remaining arguments carry environmental forcing, constants, and execution
context. This simple equation does not need them. Object selection and
simulation timing belong in the scenario.

## Test one calculation

These displayed definitions come from the package's executable
`skills/plantsimengine/assets/minimal-model.jl` example. To load the complete
example in your session:

```@example modeler_basic
using Dates, Test, PlantSimEngine
asset = joinpath(pkgdir(PlantSimEngine), "skills", "plantsimengine", "assets", "minimal-model.jl")
include(asset)
using .MinimalModelExample

model = RadiationUseEfficiency(1.5f0)
status = Status(intercepted_par=10.0f0, biomass_increment=0.0f0)
PlantSimEngine.run!(model, status, NamedTuple(), nothing, nothing)

@test status.biomass_increment == 15.0f0
@test status.biomass_increment isa Float32
status.biomass_increment
```

The `f0` notation chooses `Float32`. The tests check the equation and that
the implementation preserves this numerical type. Also check the declarations:

```@example modeler_basic
validation = Authoring.validate_model(model; strict=true)
@test validation.valid
validation.valid
```

That check validates the interface. Scientific validation needs appropriate
observations or reference results.

## Run the model on two plants

Each plant has its own intercepted radiation. The same model applies to both:

```@example modeler_basic
plants = CompositeModel(
    Object(:plant_1; scale=:Plant, status=Status(intercepted_par=10.0f0)),
    Object(:plant_2; scale=:Plant, status=Status(intercepted_par=6.0f0));
    applications=(
        ModelSpec(model; name=:biomass_production, on=Many(scale=:Plant)),
    ),
    environment=(duration=Day(1),),
)

simulation = run!(plants)
result_1 = final_state(simulation, :plant_1).biomass_increment
result_2 = final_state(simulation, :plant_2).biomass_increment
@test (result_1, result_2) == (15.0f0, 9.0f0)
(plant_1=result_1, plant_2=result_2)
```

PlantSimEngine calls the equation for each selected plant. Its state remains
separate, and the model contains no loop over plants.

## Continue with your own model

- [Port an existing model](@ref): separate a calculation from its original script.
- [Model repository layout and tests](@ref): organize a package and its checks.
- [Implement Cross-Object Values](@ref): read another object's result or sum several.
- [Model compatibility and replacement](@ref): compare another hypothesis.
- [Loaded model catalog](@ref): discover and inspect models already loaded.
