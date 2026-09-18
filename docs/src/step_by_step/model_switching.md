# Model compatibility and replacement

Suppose daily carbon gain increases with intercepted light. We want to compare
a linear response with a saturating response, then add a soil-water limitation.
All three models answer the same scientific question, but the last needs an
extra input.

## Load one family of alternatives

Let's load the teaching models that implement three alternative equations for
the same process. Each model has a different name, but they all inherit from the same abstract type, `AbstractCarbon_GainModel`.

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
nothing # hide
```

The models can be summarized as follows:

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

- **Same process:** the models describe the same scientific process.
- **Usable in this scenario:** the new model can get all its inputs and
  provide the results needed by the models connected to it.
- **Direct override:** you can replace the model without changing its
  connections or other settings. PlantSimEngine checks the process, variables
  and their physical meaning, calls to other models, and timing requirements.

Two models defined for the same process may not be directly interchangeable. If a new model needs an extra input, you can still use it, but you must supply that input yourself or connect it to another model. If a new model has different timing requirements, you may need to change the scenario's timestep or the application's `every` setting. If it needs to call different models, you may need to add those models to the scenario's `applications` or update the application's `calls` setting. The `on` setting selects the objects where a model runs.

PlantSimEngine connects matching inputs and outputs automatically when there is one possible source on the same object. For connections between objects, or when several sources are possible, declare the source with `inputs` in `ModelSpec`. Any additional required input must come from a model or a value you supply.

You can use `Override` for the third case (direct replacement with no other changes). For broader changes, replace the model in a `ModelSpec` and update the affected inputs or other configuration.

## Comparing two light responses

Let's define a composite model with a plant object and one of the light-response models. The plant object has a `Status` that records the daily absorbed PAR and the daily carbon gain. The model reads the absorbed PAR and writes the carbon gain.

We'll keep the plants, input data, and timing identical:

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
@test linear_gain == 2.0 # hide
@test saturating_gain ≈ 100 / 15 # hide
(linear=linear_gain, saturating=saturating_gain)
```

At 10 mol of absorbed photons the
linear equation produces 2 g carbon and the saturating equation about
6.67 g carbon. These different outcomes reflect the chosen model for that process.

## Using water-limited conditions

We can also use the third model that accounts for water limitation. To do this, we need to supply the soil-water fraction (`ftsw`) alongside
the light input (`absorbed_par`):

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

Here we supplied the soil-water fraction ourselves to the `Status` of the plant (through our `values` argument). To let it change during
a simulation, we could add a soil model that would simulate it (see [Coupling models](@ref)).

You can inspect the output of `Diagnostics.explain_initialization(water_scene)` to see how each required
input was supplied, then `Diagnostics.explain_bindings(water_scene)` for connections to other models.

!!! note
    You can try to remove the `ftsw` input from the `Status` of the plant and run the simulation again. PlantSimEngine will raise an error because the water-limited model needs that input to run.

## Keep physical meaning and scientific validation visible

Two variables with the same name may use different units or describe
different quantities. Check whether each value is per plant or per unit
area, and whether it is a rate, a mean, or a total. If a conversion is needed,
write it as a small model; see [explicit adapters](../guides/coupling.md). PlantSimEngine does not perform unit conversions automatically. When models declare `VariableContract`s, it compares their unit and meaning labels for an exact match; it does not check the physical dimensions of the values.

`Authoring.compare_models` reports differences in declarations.
`Authoring.validate_scenario` checks whether the models can work together in
your setup. Neither proves that an equation or its parameters are valid for
your study. Also compare assumptions, the conditions in which the models
have been tested, reference data, and simulation results.

For detailed reports, inspect `requires_binding_changes` for connection
changes and `requires_reconfiguration` for all differences that prevent a
direct override, including changes to how often a model runs. The [Public API](@ref) describes
the complete report.
