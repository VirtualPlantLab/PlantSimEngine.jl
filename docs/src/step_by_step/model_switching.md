# Model compatibility and replacement

Suppose daily carbon gain increases with intercepted light. We want to compare
a linear response with a saturating response, then add a soil-water limitation.
All three models answer the same scientific question, but the last needs an
extra input.

This example uses teaching models with arbitrary coefficients. They demonstrate
replacement and input checks; their outputs are not predictions for a crop.

## Load one family of alternatives

```@example scene_model_switching
using Dates, Test, PlantSimEngine

include(joinpath(
    pkgdir(PlantSimEngine), "skills", "plantsimengine",
    "assets", "alternative-model.jl",
))
using .AlternativeModelExample

linear = LinearCarbonGain(0.2)
saturating = SaturatingCarbonGain(10.0, 5.0)
water_limited = WaterLimitedCarbonGain(0.2)
```

| Model | Equation | Required inputs |
|---|---|---|
| Linear | efficiency × absorbed PAR | Absorbed PAR |
| Saturating | maximum × absorbed PAR / (half-saturation + absorbed PAR) | Absorbed PAR |
| Water-limited | efficiency × absorbed PAR × bounded soil-water fraction | Absorbed PAR and soil-water fraction |

Absorbed PAR is a daily total in mol photons per plant; carbon gain is a daily
total in g carbon per plant. The soil-water fraction is dimensionless. The
models record these units and meanings in `VariableContract` declarations.

## Check before changing a scenario

Compare the models with their chosen parameters:

```@example scene_model_switching
compatible = Authoring.compare_models(linear, saturating)
needs_water = Authoring.compare_models(linear, water_limited)

@test compatible.override_compatible
@test needs_water.requires_binding_changes
(
    saturating_can_replace_directly=compatible.override_compatible,
    water_limited_needs_new_inputs=needs_water.requires_binding_changes,
)
```

The linear and saturating models can replace each other directly: they read
and write the same kinds of values and have compatible settings. The
water-limited model answers the same question, but it also needs `ftsw`, the
fraction of transpirable soil water.

Three distinctions matter:

- **Same process:** the models answer the same scientific question.
- **Usable in this scenario:** the new model can get all its inputs and
  provide the results needed by the models connected to it.
- **Direct override:** you can replace the model without changing its
  connections or other settings. PlantSimEngine checks the process, variables
  and their physical meaning, calls to other models, and timing requirements.

Use `Override` only for the third case. For broader changes, replace the
model in a `ModelSpec` and update the affected inputs or other configuration.

## Compare the two light responses

Keep the plants, input data, and timing identical:

```@example scene_model_switching
function carbon_scenario(gain_model; values=(absorbed_par=10.0,))
    CompositeModel(
        Object(:plant; scale=:Plant, status=Status(; values...));
        applications=(
            ModelSpec(gain_model; name=:carbon_gain, on=One(scale=:Plant)),
        ),
        environment=(duration=Day(1),),
    )
end

linear_scene = carbon_scenario(linear)
saturating_scene = carbon_scenario(saturating)

linear_gain = final_state(run!(linear_scene)).carbon_gain
saturating_gain = final_state(run!(saturating_scene)).carbon_gain
@test linear_gain == 2.0
@test saturating_gain ≈ 100 / 15
(linear=linear_gain, saturating=saturating_gain)
```

Only the selected hypothesis changed. At 10 mol of absorbed photons the
linear equation produces 2 g carbon and the saturating equation about
6.67 g carbon. These different outcomes reflect the chosen teaching
coefficients. Models that can replace each other do not have to give the
same result: comparing those results is the purpose of the experiment.

## Supply the additional water input

For a controlled comparison, supply a soil-water fraction of 0.5 alongside
the same light input:

```@example scene_model_switching
water_scene = carbon_scenario(
    water_limited;
    values=(absorbed_par=10.0, ftsw=0.5),
)
validation = Authoring.validate_scenario(water_scene)
@test validation.valid

water_gain = final_state(run!(water_scene)).carbon_gain
@test water_gain == 1.0
(linear=linear_gain, water_limited=water_gain)
```

Here we supplied the soil-water fraction ourselves. To let it change during
a simulation, read it from a soil model or dataset using [Coupling models](@ref). Inspect
`Diagnostics.explain_initialization(water_scene)` to see how each required
input was supplied, then `Diagnostics.explain_bindings(water_scene)` for
connections to other models.

## Keep physical meaning and scientific validation visible

Two variables with the same name may use different units or describe
different quantities. Check whether each value is per plant or per unit
area, and whether it is a rate, a mean, or a total. If a conversion is needed,
write it as a small model; see [explicit adapters](../guides/coupling.md).

`Authoring.compare_models` reports differences in declarations.
`Authoring.validate_scenario` checks whether the models can work together in
your setup. Neither proves that an equation or its parameters are valid for
your study. Also compare assumptions, the conditions in which the models
have been tested, reference data, and simulation results.

For detailed reports, inspect `requires_binding_changes` for connection
changes and `requires_reconfiguration` for all differences that prevent a
direct override, including changes to how often a model runs. The [Public API](@ref) describes
the complete report.
