# MAESPA-Style Domain Example Handoff

The example in `examples/maespa_domain_example.jl` is the executable test bed
for the current hard-domain and scene microclimate prototype. It is also a good
migration target for the future unified scene/object design.

## Current Example Shape

- Two MTG-backed plant domains share scale names such as `:Plant` and `:Leaf`.
- Each plant domain uses copied PlantBiophysics subsample models:
  `Monteith` for `:energy_balance`, `Fvcb` for `:photosynthesis`, and `Tuzet`
  for `:stomatal_conductance`.
- `LeafState` owns `leaf_area` and `leaf_carbon`, because those are plant
  bookkeeping variables and not PlantBiophysics model outputs.
- `LAIModel` runs in the scene domain and now receives leaf areas through
  `ModelSpec(...) |> Inputs(...)`, which is bridged internally to the current
  route materialization runtime.
- `SceneEB` runs hourly and now uses `ModelSpec(...) |> Calls(...)` to
  manually run leaf `:energy_balance` targets and the shared soil
  `:soil_water` target.
- Plant allocation runs daily through the normal plant-local dependency graph.

## Manual Call Expectations

- `Calls(:energy_balance => Many(kind=:plant, scale=:Leaf, process=:energy_balance))`
  selects one target per matching leaf status through the current hard-domain
  bridge.
- `Calls(:soil => One(kind=:soil, process=:soil_water))` selects the shared
  soil model through the current hard-domain bridge.
- `dependency_targets(extra, :energy_balance)` returns executable leaf targets.
- `run_call!(target; publish=false)` is used during trial iterations.
- `run_call!(target; publish=true)` is used for the accepted final solution
  so outputs are appended once to domain streams and `DomainSimulation.outputs`.
- Trial target runs mutate target status. Irreversible accumulators such as
  `leaf_carbon` are updated only after the accepted solution.

## MAESPA-Style Canopy Microclimate

Input meteorology is treated as above-canopy forcing:

- `meteo.T` is above-canopy air temperature.
- `meteo.VPD` is above-canopy VPD.
- `meteo.Wind`, `meteo.P`, and radiation variables are above-canopy drivers.

Scene status stores below-canopy microclimate:

- `canopy_tair`
- `canopy_vpd`
- `canopy_rh`
- `canopy_htot`
- `canopy_gcanop`

The helper `tvpdcanopcalc(...)` ports the MAESPA-style canopy T/VPD update, and
`gbcanms(...)` ports the canopy aerodynamic conductance shape. The example uses
PlantMeteo kPa conventions and clipping equivalent to MAESPA's Pa clipping.

`SceneEB` computes total leaf fluxes per ground area and uses those values for
the canopy microclimate update. Total leaf area is routed to `LAIModel`, which
computes `leaf_area` and `lai` in the scene domain.

## Verification Expectations

The focused test `test/test-maespa-domain-example.jl` should verify:

- Species A has two leaves and species B has three leaves.
- `:energy_balance` hard-domain outputs are published once per leaf per hour.
- Soil `psi_soil` is updated through the scene hard target.
- `canopy_tair` and `canopy_vpd` remain finite and within MAESPA clipping
  bounds relative to the above-canopy meteo.
- `canopy_rh` remains between 0 and 1.
- `LAIModel` sees every leaf area through the route and computes scene LAI.
- Daily allocation differs between the two plant species because their
  allocation parameters differ.

## Future Migration Target

The MAESPA example has already moved away from explicit user-level
`Route(...)` and `HardDomains(...)`: leaf area materialization is declared with
`Inputs(...)`, and manual energy-balance calls are declared with `Calls(...)`.

Expected migration:

```julia
ModelSpec(LAIModel(ground_area)) |>
    AppliesTo(One(scale=:Scene)) |>
    Inputs(:leaf_areas => Many(kind=:plant, scale=:Leaf, process=:leaf_state, var=:leaf_area))

ModelSpec(SceneEB()) |>
    AppliesTo(One(scale=:Scene)) |>
    Calls(:leaf_energy => Many(kind=:plant, scale=:Leaf, process=:energy_balance)) |>
    Calls(:soil => One(kind=:soil, process=:soil_water))
```

Plant-local allocation should similarly move from `MultiScaleModel(...)` to a
scope-relative input:

```julia
ModelSpec(AllocA(...)) |>
    AppliesTo(Many(kind=:plant, scale=:Plant)) |>
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Self(), var=:leaf_carbon))
```

If this plant-local dependency is the normal behavior of the allocation model,
the model can provide it as a default trait instead:

```julia
dep(::AllocA) = (
    leaf_carbon = Input(Many(scale=:Leaf, within=Self(), var=:leaf_carbon)),
)
```

The same applies to manual calls. A leaf energy-balance model can use `dep` to
declare its usual stomatal-conductance call, while the scene `ModelSpec` can
still override or specialize the call selection with `Calls(...)` when the
model is assembled into a MAESPA-style scene.

Here `Self()` means the current model application object or scope. Because
`AllocA` runs at the plant scale, this selects leaves inside the current plant.
For a model running below the plant scale, use `SelfPlant()` or
`Ancestor(scale=:Plant)` when the intended scope is the containing plant.

The migration target should treat `SceneEB`, `LAIModel`, and plant allocation
as model applications. `AppliesTo(...)` declares where each application runs;
`Inputs(...)` provides values scheduled by the runtime; `Calls(...)` provides
manual call handles for the iterative scene energy-balance solver. This keeps
the MAESPA example aligned with the unified design and avoids recreating a
separate domain-specific path.
