# MAESPA-Style Synthesis

Bring the earlier tutorials together in a small MAESPA-style stand with two
species and five leaves. Canopy and soil exchange run hourly; carbon
allocation and LAI run daily. Within each hour, a controller repeatedly runs
the leaf models to find a consistent canopy air temperature and humidity.
This is an advanced example; start with the individual tutorials if these
steps are unfamiliar.

This is an uncalibrated teaching example inspired by MAESPA's process
structure. It is not a validated MAESPA implementation. Leaf illumination is
uniform with complete absorption, the canopy has one air layer, and the soil
water model uses prescribed withdrawals and bounds rather than a complete
soil hydraulic balance. The example tests coupling and carbon accounting;
its results should not be used to predict a real stand's behaviour.

The table in [How the pieces compose](@ref) links each part of this example
to the tutorial that explains it.

## Run the reference case

The complete, tested source is in `examples/maespa_model_example.jl`. Run it
with 25 hourly weather records. The daily models run on the first step and
again 24 hours later, so this is long enough to see two calls:

```@example journey_maespa_synthesis
using PlantSimEngine, DataFrames

include(joinpath(
    pkgdir(PlantSimEngine),
    "examples",
    "maespa_model_example.jl",
))

result = run_maespa_example(; nhours=25, check=true)
simulation = result.simulation
model = result.model
nothing
```

The model contains one object for the whole scene, one soil object, and two
plants with the same model connections. Each plant has its own template,
species parameters, and number of leaves:

```@example journey_maespa_synthesis
(
    instances=DataFrame(Diagnostics.explain_instances(model)),
    plants=length(model_objects(model; scale=:Plant)),
    leaves=length(model_objects(model; scale=:Leaf)),
    species_A=length(model_objects(model; scale=:Leaf, species=:A)),
    species_B=length(model_objects(model; scale=:Leaf, species=:B)),
)
```

## Check when models run and where their inputs come from

Check when each calculation runs. The scene controller decides when to call
leaf energy balance and soil water; these models do not run independently.
Allocation and LAI run once per day. In the table, `root_scheduled` means a
model runs directly from the simulation schedule, `manual_call_only` means
another model calls it, and `dt_steps` gives the interval in hourly steps:

```@example journey_maespa_synthesis
schedule = DataFrame(Diagnostics.explain_schedule(result.compiled))
select(
    filter(
        row -> row.application_id in (
            :scene_eb,
            :soil_water,
            :lai_dynamic,
            :plant_A__energy_balance,
            :plant_A__allocation,
            :plant_B__allocation,
        ),
        schedule,
    ),
    :application_id,
    :root_scheduled,
    :manual_call_only,
    :dt_steps,
)
```

The scene energy-balance model calls all five leaf models with `Many` and the
single soil model with `One`. These are **hard calls**: the calling model
controls when the other models run. The table lists the models and objects
called from `:scene_eb`:

```@example journey_maespa_synthesis
calls = DataFrame(Diagnostics.explain_calls(result.compiled))
select(
    filter(row -> row.application_id == :scene_eb, calls),
    :call,
    :callee_application_ids,
    :callee_object_ids,
    :publication_policy,
)
```

Each plant's allocation model reads carbon values from its own leaves. The
scene model reads areas from all leaves and water potential from the soil.
Here `AllocA` and `AllocB` use the same fixed-fraction allocation equation
with different parameters. For two different allocation rules running on
two plants together, see [Instantiate Several Plants](several_plants.md).
Inspect `source_ids` below to check where each input comes from. The values
are shared by reference, meaning the reader sees the current source values
without copying them:

```@example journey_maespa_synthesis
bindings = DataFrame(Diagnostics.explain_bindings(result.compiled))
select(
    filter(
        row -> (
            row.application_id in (
                :plant_A__allocation,
                :plant_B__allocation,
            ) && row.input == :leaf_carbon
        ) || (
            row.application_id == :scene_eb &&
            row.input in (:leaf_areas, :psi_soil)
        ),
        bindings,
    ),
    :application_id,
    :input,
    :source_ids,
    :carrier_kind,
    :copy_semantics,
)
```

## Follow trial canopy air to its accepted state

The scene controller starts from the above-canopy weather, named `:forcing`.
It tries different canopy air conditions and runs the leaf models for each
trial with `publish=false`, so these intermediate results are not saved in
the output history. Once the calculation converges, it commits the accepted
air conditions with `sink=:canopy` and runs the leaves once more to publish
their accepted results.

The leaf models then read the accepted conditions from `:canopy`. The table
below shows which environmental variables each model reads or changes. Its
`handle` column contains an internal identifier used to retrieve those
conditions; you do not need to interpret that identifier:

```@example journey_maespa_synthesis
environment_bindings = DataFrame(
    Diagnostics.explain_environment_bindings(result.environment),
)
select(
    filter(
        row -> row.application_id in (
            :scene_eb,
            :plant_A__energy_balance,
            :plant_B__energy_balance,
        ),
        environment_bindings,
    ),
    :application_id,
    :object_id,
    :handle,
    :required_inputs,
    :produced_outputs,
)
```

`MaespaSingleLayerEnvironment` supplies one set of air conditions for the
whole canopy. It keeps the above-canopy weather separate from the canopy
conditions that the controller changes. You could replace it with an
environment that represents several layers or 3D cells, while keeping the
same variables available to the process models. See the two-cell example in
[Modify The Environment](@ref) and the implementation guide in
[Environment Backend Extensions](@ref).

## Check units and carbon accounting

Check the units and conversions as values pass between models:

| Quantity | Meaning and units |
|---|---|
| `Ri_SW_f`, `Ri_PAR_f` | Incoming radiation in W m⁻²; PAR is `PlantMeteo.Constants().PAR_fraction` of shortwave energy. |
| Leaf `aPPFD` | Absorbed photon flux in µmol photons m[leaf]⁻² s⁻¹: `Ri_PAR_f * constants.J_to_umol`, assuming uniform illumination and complete absorption. |
| Leaf `A` | Net CO₂ assimilation in µmol CO₂ m[leaf]⁻² s⁻¹. |
| Leaf `leaf_carbon` | Cumulative net assimilation in g elemental C: sum of `A * leaf_area * duration_seconds * 12e-6`. |
| Plant `daily_growth` | Net C since this plant's previous allocation, in g C per allocation interval. The first call covers only the start of the simulation, not a full day. |
| Plant carbon pools | Allocated g elemental C, not g dry matter; the unassigned allocation fraction remains in `reserve_pool`. |
| `scene_transpiration` | Accepted water loss in mm over the current hourly forcing interval. |

Every leaf receives the same above-canopy irradiance here. There is no
shading, scattering, or leaf-angle calculation; a radiation model would need
to replace that assumption for a realistic stand.

Use `final_state` to read the latest values, whether or not you saved their
history:

```@example journey_maespa_synthesis
scene = final_state(simulation, :model)
soil = final_state(simulation, :soil)
plants = final_state(simulation, Many(scale=:Plant))

(
    lai=scene.lai,
    canopy_temperature_C=scene.canopy_tair,
    hourly_transpiration_mm=scene.scene_transpiration,
    soil_water_potential_MPa=soil.psi_soil,
    allocation_interval_g_C=Dict(
        id => state.daily_growth
        for (id, state) in plants
    ),
)
```

Allocation reads cumulative leaf C without resetting it. Each plant stores
the cumulative amount it has already accounted for and allocates only the
difference at the next daily call. This prevents the same carbon being
allocated again on later days. Carbon gained or lost since the last
allocation remains pending until the next one:

```@example journey_maespa_synthesis
DataFrame([
    (
        plant=id,
        cumulative_net_C_g=sum(state.leaf_carbon),
        accounted_C_g=state.accounted_carbon,
        pools_C_g=state.leaf_pool + state.wood_pool + state.reserve_pool,
        pending_C_g=sum(state.leaf_carbon) - state.accounted_carbon,
    )
    for (id, state) in plants
])
```

At each allocation, the three pools sum to `accounted_carbon`. Adding pending
C recovers cumulative net assimilation. These accounts can increase or
decrease: negative net assimilation reduces them. The example does not model initial
biomass, construction respiration, dry-matter conversion, or limits on
withdrawing reserves, so the pools are not predictions of organ mass.

Count the saved values to check how often the models ran. Hourly scene and
leaf variables have 25 samples; daily LAI and allocation variables have two:

```@example journey_maespa_synthesis
output_summary = DataFrame(Diagnostics.explain_outputs(simulation))
select(
    filter(
        row -> (
            row.object_id == :model &&
            row.variable in (:scene_transpiration, :lai)
        ) || (
            row.object_id in (:plant_A, :plant_B) &&
            row.variable == :daily_growth
        ) || (
            row.object_id == :plant_A_leaf_1 &&
            row.variable == :λE
        ),
        output_summary,
    ),
    :application_id,
    :object_id,
    :variable,
    :nsamples,
)
```

## How the pieces compose

| Part of the example | What it does here | Tutorial |
|---|---|---|
| `CompositeModelTemplate` and two `ObjectInstance`s | Reuse the same models for plants with different species parameters | [Instantiate Several Plants](@ref) |
| Scene, plant, internode, leaf, and soil objects | Represent the chosen plant structure and shared soil | [Build One Multiscale Plant](@ref) |
| `One` and `Many` inputs | Read one soil value or a collection of leaf values | [Build One Multiscale Plant](@ref) |
| Hourly and daily models with `HoldLast` | Keep using the last daily value between daily calculations | [Give Models Different Cadences](@ref) |
| Above-canopy weather and canopy conditions | Supply each model with the environment it needs | [Understand Environments](@ref) |
| Trial air conditions and an accepted result | Find consistent canopy conditions, then save the accepted result | [Modify The Environment](@ref) |
| Hard calls | Let scene energy balance decide when leaf and soil models run | [Control Advanced Execution](@ref) |
| `Simulation`, `final_state`, and saved outputs | Read current values and analyse changes over time | [Couple Models On One Object](@ref) |

Plant structure stays fixed during this 25-hour example. To add or remove
organs with a growth model, follow [Modify Plant Structure](@ref).

## What the tests check

The automated tests check that the parts work together as intended:

- the stand contains two plants, with five leaves assigned to the right plant;
- each plant's allocation model reads only its own leaves;
- the scene controller calls every leaf and the shared soil model;
- hourly and daily output counts match their scheduled intervals;
- accepting new canopy conditions does not replace the above-canopy weather;
- leaf fluxes are finite and their totals agree with the scene results;
- PAR energy is bounded by shortwave energy and converted to photon units;
- a longer run with 73 hourly samples covers three daily intervals plus the
  initial call, with no carbon added by rejected trial calculations;
- each plant allocates every C increment once, preserves cumulative leaf C,
  and conserves the sum of its leaf, wood, reserve, and pending C accounts.
