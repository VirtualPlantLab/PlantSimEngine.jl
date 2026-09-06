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
models declare these meanings in their variable contracts.

## Check before changing a scenario

Compare the concrete model instances:

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

The first pair has a compatible complete interface. The water-limited model
belongs to the same process, but its extra `ftsw` input needs a value.

Three distinctions matter:

- **Same process:** the models answer the same scientific question.
- **Usable in this scenario:** the candidate supplies what consumers need and
  can obtain all its own inputs.
- **Direct override:** the complete process, inputs, outputs, contracts,
  dependencies, and relevant traits are compatible.

Use `Override` only for the third case. For broader changes, replace the
model in a `ModelSpec` and update the affected inputs or other configuration.

## Compare the two light responses

Keep the objects, forcing, and timing identical:

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
coefficients; interface compatibility does not imply equal results.

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

This is an explicitly supplied value. In a dynamic simulation, bind `ftsw`
to a soil model or forcing data using [Coupling models](@ref). Inspect
`Diagnostics.explain_initialization(water_scene)` to see how each required
input was supplied, then `Diagnostics.explain_bindings(water_scene)` for
connections to other model applications.

## Keep physical meaning and scientific validation visible

Two variables with the same name can still differ in units, area or mass
basis, temporal meaning, or aggregation. Add a named conversion model when
those meanings differ; see [explicit adapters](../guides/coupling.md).

`Authoring.compare_models` reports differences in declarations.
`Authoring.validate_scenario` checks the proposed composition. Neither proves
that an equation or its parameterization is valid for your study. Compare
assumptions, domain of validity, reference data, and outputs as well.

For detailed reports, inspect `requires_binding_changes` for connection
changes and `requires_reconfiguration` for all differences that prevent a
direct override, including cadence changes. The [Public API](@ref) describes
the complete report.
