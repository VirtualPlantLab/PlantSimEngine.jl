# MAESPA-Style CompositeModel Example Handoff

The executable acceptance example is `examples/maespa_model_example.jl`, with
focused coverage in `test/test-maespa-model-example.jl`.

## CompositeModel Shape

- One `:Scene` object owns canopy microclimate and model-scale fluxes.
- One shared `:Soil` object owns soil water state.
- Species A and B are reusable `CompositeModelTemplate`s mounted as independent
  `ObjectInstance`s.
- Each plant instance contains one plant object, one internode object, and its
  own leaf objects.
- Species parameters differ while the model application structure is shared.

Leaf applications use the copied PlantBiophysics subsample models:

- `Monteith` for `:energy_balance`;
- `Fvcb` for `:photosynthesis`;
- `Tuzet` for `:stomatal_conductance`.

## Coupling

The model energy-balance application controls iterative canopy-air, leaf, and
soil calls. `Calls(...)` expresses execution ownership only: the scene model
decides when subprocesses run.

```julia
ModelSpec(scene_model; name=:scene_eb) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(
        :psi_soil =>
            One(kind=:soil, scale=:Soil, application=:soil_water, var=:psi_soil),
    ) |>
    Calls(
        :energy_balance =>
            Many(kind=:plant, scale=:Leaf, process=:energy_balance),
        :soil =>
            One(kind=:soil, scale=:Soil, application=:soil_water),
    ) |>
    Environment(provider=:forcing) |>
    TimeStep(Dates.Hour(1))
```

The scene receives above-canopy forcing from the `:forcing` provider. Trial leaf
calls run inside `with_environment!(extra, trial_meteo) do ... end`, so all
hard-called leaves sample the same trial canopy atmosphere without committing it
to the backend. After convergence, the scene commits the accepted canopy
atmosphere with `update_environment!(extra, accepted_meteo)` and publishes one
accepted leaf call against that committed environment.

Scene/soil values are wired declaratively with `Inputs(...)`, not by manually
writing another object's status. The soil model receives accepted scene fluxes
through live references:

```julia
ModelSpec(SoilWater(...); name=:soil_water) |>
    AppliesTo(One(kind=:soil, scale=:Soil)) |>
    Inputs(
        :transpiration =>
            One(
                scale=:Scene,
                within=SceneScope(),
                application=:scene_eb,
                var=:scene_transpiration,
            ),
        :infiltration =>
            One(
                scale=:Scene,
                within=SceneScope(),
                application=:scene_eb,
                var=:scene_infiltration,
            ),
    ) |>
    TimeStep(Dates.Hour(1))
```

This creates a parent-controlled feedback loop: the scene reads mapped
`psi_soil` when it starts its energy-balance solve, computes accepted scene
water fluxes, writes `scene_transpiration` and `scene_infiltration`, then calls
the soil model. The soil call sees those scene values through input carriers
and publishes the updated soil state. If the intended science is an explicit
lag rather than same-step parent control, use `PreviousTimeStep(:psi_soil)` on
the scene input.

CompositeModel LAI receives live references to every leaf area:

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

The scene energy-balance model uses the same mapping mechanism for leaf-scale
values needed during the hard-call solve. It maps leaf area, leaf carbon, trial
leaf inputs (`Ra_SW_f`, `aPPFD`, `Ψₗ`), and accepted leaf fluxes (`Rn`, `λE`,
`H`, `A`) into scene-level vector inputs. The scene model then writes or reads
those vectors, while the referenced leaf statuses remain the single source of
truth.

```julia
ModelSpec(scene_model; name=:scene_eb) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(
        :leaf_areas => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_area),
        :leaf_carbon => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:leaf_carbon),
        :leaf_Ra_SW_f => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:Ra_SW_f),
        :leaf_aPPFD => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:aPPFD),
        :Ψₗ => Many(kind=:plant, scale=:Leaf, within=SceneScope(), var=:Ψₗ),
        :leaf_rn => Many(kind=:plant, scale=:Leaf, within=SceneScope(), policy=HoldLast(), var=:Rn),
        :leaf_lambda_e => Many(kind=:plant, scale=:Leaf, within=SceneScope(), policy=HoldLast(), var=:λE),
        :leaf_h => Many(kind=:plant, scale=:Leaf, within=SceneScope(), policy=HoldLast(), var=:H),
        :leaf_a => Many(kind=:plant, scale=:Leaf, within=SceneScope(), policy=HoldLast(), var=:A),
    )
```

`HoldLast()` is intentional for the leaf flux vectors: it asks the compiler for
live references to the current held status values, so the parent scene solve can
iterate hard-call trial states without materializing temporal streams.

Allocation is plant-local because its leaf selector uses `within=Subtree()`:

```julia
ModelSpec(allocation; name=:allocation) |>
    AppliesTo(One(scale=:Plant)) |>
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)) |>
    TimeStep(Dates.Day(1))
```

## Meteorology

Input meteorology is above-canopy forcing wrapped in a
`MaespaSingleLayerEnvironment`. The backend stores two meteorological states:

- `forcing`: the above-canopy `Weather`/time series sampled by the scene;
- `canopy`: the mutable canopy `Atmosphere` sampled by every leaf.

The scene application uses `Environment(provider=:forcing)`. Leaf energy-balance
applications use `Environment(provider=:canopy)`. The one-layer backend does not
look at process names, geometry, or cells; all leaves intentionally sample the
same current canopy atmosphere.

`canopy_air_update(...)` is a plain helper, not a model application. It reads
canopy-scale leaf fluxes aggregated in the scene, computes the MAESPA-style
canopy air update, and returns a new `Atmosphere`. The accepted solution is
committed directly with:

```julia
update_environment!(extra, accepted_meteo)
```

CompositeModel status also stores diagnostics for the resulting below-canopy
microclimate:

- `canopy_tair`;
- `canopy_vpd`;
- `canopy_rh`;
- `canopy_htot`;
- `canopy_gcanop`.

Trial iterations use `with_environment!` so the trial atmosphere is visible
through the normal environment sampling path but is restored afterwards. The
accepted state is the only state committed to the mutable environment backend.

## Acceptance Checks

The focused test verifies:

- five leaves across two species and one shared soil object;
- instance membership and mounted application ids;
- model calls to all leaf energy-balance applications and the soil model;
- nested `Monteith -> Fvcb -> Tuzet` call bundles;
- live-reference LAI and plant-local allocation bindings;
- hourly energy balance and daily LAI/allocation schedules;
- exactly one accepted publication per manually called target and timestep;
- finite canopy microclimate, leaf energy, photosynthesis, soil feedback, and
  species-specific allocation after a 25-hour run.
