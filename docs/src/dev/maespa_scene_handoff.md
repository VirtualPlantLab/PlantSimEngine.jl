# MAESPA-Style Scene Example Handoff

The executable acceptance example is `examples/maespa_scene_example.jl`, with
focused coverage in `test/test-maespa-scene-example.jl`.

## Scene Shape

- One `:Scene` object owns canopy microclimate and scene-scale fluxes.
- One shared `:Soil` object owns soil water state.
- Species A and B are reusable `ObjectTemplate`s mounted as independent
  `ObjectInstance`s.
- Each plant instance contains one plant object, one internode object, and its
  own leaf objects.
- Species parameters differ while the model application structure is shared.

Leaf applications use the copied PlantBiophysics subsample models:

- `Monteith` for `:energy_balance`;
- `Fvcb` for `:photosynthesis`;
- `Tuzet` for `:stomatal_conductance`.

## Coupling

The scene energy-balance application controls iterative leaf and soil calls:

```julia
ModelSpec(scene_model; name=:scene_eb) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(
        :energy_balance =>
            Many(kind=:plant, scale=:Leaf, process=:energy_balance),
        :soil =>
            One(kind=:soil, scale=:Soil, process=:soil_water),
    ) |>
    TimeStep(Dates.Hour(1))
```

Trial leaf calls use `run_call!(target)` and do not publish. The accepted
solution uses `run_call!(target; publish=true)`, so temporal outputs and
environment writes are emitted exactly once.

Scene LAI receives live references to every leaf area:

```julia
ModelSpec(LAIModel(ground_area); name=:lai_dynamic) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(
        :leaf_areas => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            process=:leaf_state,
            var=:leaf_area,
        ),
    ) |>
    TimeStep(Dates.Day(1))
```

Allocation is plant-local because its leaf selector uses `within=Subtree()`:

```julia
ModelSpec(allocation; name=:allocation) |>
    AppliesTo(One(scale=:Plant)) |>
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)) |>
    TimeStep(Dates.Day(1))
```

## Meteorology

Input meteorology is above-canopy forcing. Scene status stores the resulting
below-canopy microclimate:

- `canopy_tair`;
- `canopy_vpd`;
- `canopy_rh`;
- `canopy_htot`;
- `canopy_gcanop`.

`tvpdcanopcalc(...)` and `gbcanms(...)` implement the MAESPA-style canopy
temperature, humidity, and aerodynamic-conductance update.

## Acceptance Checks

The focused test verifies:

- five leaves across two species and one shared soil object;
- instance membership and mounted application ids;
- scene calls to all leaf energy-balance applications and the soil model;
- nested `Monteith -> Fvcb -> Tuzet` call bundles;
- live-reference LAI and plant-local allocation bindings;
- hourly energy balance and daily LAI/allocation schedules;
- exactly one accepted publication per manually called target and timestep;
- finite canopy microclimate, leaf energy, photosynthesis, soil feedback, and
  species-specific allocation after a 25-hour run.
