# MAESPA-Style Synthesis

## New concept: synthesis without another runtime mechanism

This page is an integrated reference, not an onboarding example. It combines
the ideas developed independently in the earlier journeys into a small
MAESPA-style stand: two species, five leaves, hourly canopy and soil exchange,
daily allocation and LAI, iterative leaf calls, and accepted mutable canopy
air.

This is a non-calibrated teaching example inspired by MAESPA's process
structure. It is not a validated MAESPA implementation. Leaf illumination is
uniform with complete absorption, the canopy has one air layer, and the soil
water model uses prescribed withdrawals and bounds rather than a complete
soil hydraulic balance. The example tests coupling and carbon accounting;
its trajectories should not be used as empirical predictions.

If any individual mechanism is unfamiliar, follow its focused link in
[How the pieces compose](@ref) before reading the implementation.

## Run the reference case

The complete, tested source lives in
`examples/maespa_model_example.jl`. Supply 25 hourly forcing rows so the daily
scheduler runs at its initial boundary and again 24 base steps later:

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

The model contains one scene, one soil object, and two template instances with
different species parameters and leaf counts:

```@example journey_maespa_synthesis
(
    instances=DataFrame(Diagnostics.explain_instances(model)),
    plants=length(model_objects(model; scale=:Plant)),
    leaves=length(model_objects(model; scale=:Leaf)),
    species_A=length(model_objects(model; scale=:Leaf, species=:A)),
    species_B=length(model_objects(model; scale=:Leaf, species=:B)),
)
```

## Inspect the compiled architecture

The execution schedule makes the two cadences and parent-controlled
applications visible. Leaf energy balance and soil water are call-only under
the scene controller; allocation and LAI run daily:

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

The scene energy-balance application resolves all five leaves through one
`Many` hard call and the soil through one `One` hard call:

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

Each plant allocation application receives a live vector of only its own
descendant leaves. The scene receives stand-wide vectors and one scalar soil
potential:

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

The scene controller reads above-canopy `:forcing`, iterates leaf models
against typed trial canopy air with `publish=false`, commits the converged
state to `sink=:canopy`, and then publishes one accepted leaf execution. Leaf
applications read the committed `:canopy` provider. Those routes are compiled
into opaque handles:

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

`MaespaSingleLayerEnvironment` is intentionally a one-layer canopy backend.
Its handle still separates forcing, canopy, and commit-sink routes per
application/object. A voxel or multilayer backend can replace it without
changing the model-facing environment contract; the two-cell proof is in
[Modify The Environment](@ref), and backend implementation belongs in
[Environment Backend Extensions](@ref).

## Check the scientific handoffs

The example keeps the conversions visible:

| Quantity | Meaning and units |
|---|---|
| `Ri_SW_f`, `Ri_PAR_f` | Incoming radiation in W m⁻²; PAR is `PlantMeteo.Constants().PAR_fraction` of shortwave energy. |
| Leaf `aPPFD` | Absorbed photon flux in µmol photons m[leaf]⁻² s⁻¹: `Ri_PAR_f * constants.J_to_umol`, assuming uniform illumination and complete absorption. |
| Leaf `A` | Net CO₂ assimilation in µmol CO₂ m[leaf]⁻² s⁻¹. |
| Leaf `leaf_carbon` | Cumulative net assimilation in g elemental C: sum of `A * leaf_area * duration_seconds * 12e-6`. |
| Plant `daily_growth` | Net C since this plant's previous allocation, in g C per allocation interval; the initial scheduler call is a startup interval. |
| Plant carbon pools | Allocated g elemental C, not g dry matter; the unassigned allocation fraction remains in `reserve_pool`. |
| `scene_transpiration` | Accepted water loss in mm over the current hourly forcing interval. |

Every leaf receives the same above-canopy irradiance here. There is no
shading, scattering, or leaf-angle calculation; a radiation model would need
to replace that assumption for a realistic stand.

The final snapshots expose state independently of retained history:

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
allocated again on later days. Between allocation calls, a new signed carbon
increment can remain pending:

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
C recovers cumulative net assimilation. These are signed carbon accounts:
negative net assimilation reduces them. The example does not model initial
biomass, construction respiration, dry-matter conversion, or limits on
withdrawing reserves, so the pools are not predictions of organ mass.

Retained output counts confirm the cadence boundary: hourly scene and leaf
variables have 25 samples, while daily LAI and allocation variables have two:

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

| Construct in this synthesis | Role here | Focused journey |
|---|---|---|
| `CompositeModelTemplate` and two `ObjectInstance`s | Reuse one species-specific application set across several plants | [Instantiate Several Plants](@ref) |
| Scene, plant, internode, leaf, and soil objects | Represent one registry without prescribing plant architecture | [Build One Multiscale Plant](@ref) |
| Scalar and `Many` live-reference bindings | Couple soil-to-scene and leaf-to-plant/scene values | [Build One Multiscale Plant](@ref) |
| Hourly and daily applications with `HoldLast` | Keep canopy exchange and allocation on scientific cadences | [Give Models Different Cadences](@ref) |
| Forcing and canopy providers with compiled handles | Sample global forcing and committed canopy state through one contract | [Understand Environments](@ref) |
| Typed trials and explicit accepted commit | Iterate canopy air without publishing rejected states | [Modify The Environment](@ref) |
| Nested hard calls and accepted publication | Let scene energy balance control leaf and soil execution | [Control Advanced Execution](@ref) |
| `Simulation`, final state, and retained streams | Separate current canonical state from requested history | [Couple Models On One Object](@ref) |

This 25-hour reference keeps plant topology fixed because organogenesis is not
part of its scientific question. A growth model can add, reparent, or remove
organs through the same registry and refresh machinery; that independent
lifecycle is demonstrated in [Modify Plant Structure](@ref). Keeping it out of
this synthesis prevents canopy iteration, daily allocation, and topology
mutation from becoming one inseparable example.

## Reference invariants

The automated example test verifies the important handoffs rather than exact
floating-point trajectories:

- the stand contains two isolated instances and five correctly routed leaves;
- plant allocation vectors contain only descendant leaves;
- the scene call resolves every leaf and the shared soil application;
- hourly and daily output counts match their cadences;
- accepted canopy air is committed separately from above-canopy forcing;
- leaf fluxes are finite and aggregate consistently at scene scale;
- PAR energy is bounded by shortwave energy and converted to photon units;
- 73 accepted hourly samples span three daily intervals and an initial
  scheduler call, with no carbon added by rejected leaf iterations;
- each plant allocates every C increment once, preserves cumulative leaf C,
  and conserves the sum of its leaf, wood, reserve, and pending C accounts.

## Page recap

- **You added:** no new primitive; you assembled the earlier topology,
  cadence, hard-call, environment, and output mechanisms into one stand.
- **PlantSimEngine inferred:** application order, plant-local bindings,
  concrete call targets, environment handles, and the hourly/daily schedule.
- **You keep explicit:** species parameters, topology, scientific iteration,
  accepted state, output requests, and the invariants used to validate the
  result.
- **New API names:** none. Every API in this synthesis was introduced on a
  focused earlier journey.
