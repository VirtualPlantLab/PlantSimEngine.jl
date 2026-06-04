# Domain simulations

Domain simulations let you reuse complete plant, soil, scene, or environment
model mappings without renaming their internal scales and processes.

This is useful when a scene contains several plant species. Each species can
keep its own `ModelMapping`, parameters, hard dependencies, multiscale mappings,
and rates. A `SimulationMapping` then assembles these domains and makes
cross-domain coupling explicit.

The example on this page is deliberately simple. The numbers are arbitrary and
chosen only to show domain coupling and multi-rate execution.

## A two-plant scene with shared soil

First we define a few small models. The plant domains compute absorbed radiation
and transpiration hourly. The soil domain computes water content and evaporation
hourly. The scene domain runs daily and consumes all plant transpiration plus
soil evaporation through explicit `AllDomains(...)` value dependencies. These
dependencies read already-published producer streams; they do not manually run
the producer models.

```@example domains
using PlantSimEngine
using PlantMeteo
using Dates

PlantSimEngine.@process "doc_domain_absorbed_radiation" verbose=false
PlantSimEngine.@process "doc_domain_plant_transpiration" verbose=false
PlantSimEngine.@process "doc_domain_soil_water" verbose=false
PlantSimEngine.@process "doc_domain_soil_evaporation" verbose=false
PlantSimEngine.@process "doc_domain_scene_evapotranspiration" verbose=false

struct DocDomainAbsorbedRadiationModel <: AbstractDoc_Domain_Absorbed_RadiationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DocDomainAbsorbedRadiationModel) = NamedTuple()
PlantSimEngine.outputs_(::DocDomainAbsorbedRadiationModel) = (absorbed_radiation=0.0,)
PlantSimEngine.meteo_inputs_(::DocDomainAbsorbedRadiationModel) = (Ri_PAR_f=0.0,)

function PlantSimEngine.run!(model::DocDomainAbsorbedRadiationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.absorbed_radiation = model.coefficient * meteo.Ri_PAR_f
    return nothing
end

struct DocDomainPlantTranspirationModel <: AbstractDoc_Domain_Plant_TranspirationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DocDomainPlantTranspirationModel) = (absorbed_radiation=0.0,)
PlantSimEngine.outputs_(::DocDomainPlantTranspirationModel) = (transpiration=0.0,)

function PlantSimEngine.run!(model::DocDomainPlantTranspirationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.transpiration = model.coefficient * status.absorbed_radiation
    return nothing
end

struct DocDomainSoilWaterModel <: AbstractDoc_Domain_Soil_WaterModel
    baseline::Float64
end

PlantSimEngine.inputs_(::DocDomainSoilWaterModel) = NamedTuple()
PlantSimEngine.outputs_(::DocDomainSoilWaterModel) = (soil_water_content=0.0,)
PlantSimEngine.meteo_inputs_(::DocDomainSoilWaterModel) = (T=0.0,)

function PlantSimEngine.run!(model::DocDomainSoilWaterModel, models, status, meteo, constants=nothing, extra=nothing)
    status.soil_water_content = model.baseline - 0.001 * meteo.T
    return nothing
end

struct DocDomainSoilEvaporationModel <: AbstractDoc_Domain_Soil_EvaporationModel
    coefficient::Float64
end

PlantSimEngine.inputs_(::DocDomainSoilEvaporationModel) = (soil_water_content=0.0,)
PlantSimEngine.outputs_(::DocDomainSoilEvaporationModel) = (evaporation=0.0,)
PlantSimEngine.meteo_inputs_(::DocDomainSoilEvaporationModel) = (T=0.0,)

function PlantSimEngine.run!(model::DocDomainSoilEvaporationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.evaporation = model.coefficient * status.soil_water_content * meteo.T
    return nothing
end

struct DocDomainSceneEvapotranspirationModel <: AbstractDoc_Domain_Scene_EvapotranspirationModel end

PlantSimEngine.inputs_(::DocDomainSceneEvapotranspirationModel) = NamedTuple()
PlantSimEngine.outputs_(::DocDomainSceneEvapotranspirationModel) = (evapotranspiration=0.0,)

PlantSimEngine.dep(::DocDomainSceneEvapotranspirationModel) = (
    plant_transpiration=AllDomains(kind=:plant, process=:doc_domain_plant_transpiration, var=:transpiration, policy=Integrate()),
    soil_evaporation=AllDomains(kind=:soil, process=:doc_domain_soil_evaporation, var=:evaporation, policy=Integrate()),
)

function PlantSimEngine.run!(::DocDomainSceneEvapotranspirationModel, models, status, meteo, constants=nothing, extra=nothing)
    plant_values = dependency_values(extra, :plant_transpiration)
    soil_values = dependency_values(extra, :soil_evaporation)
    status.evapotranspiration =
        sum(filter(x -> !isnothing(x), plant_values)) +
        sum(filter(x -> !isnothing(x), soil_values))
    return nothing
end
nothing
```

Now each domain can be built independently. The oil palm and maize mappings use
the same model types but different parameters. In a real application these
could be completely different plant models, with different processes and
different internal mappings.

```@example domains
oil_palm_mapping = ModelMapping(
    ModelSpec(DocDomainAbsorbedRadiationModel(0.5)) |> TimeStepModel(Hour(1)),
    ModelSpec(DocDomainPlantTranspirationModel(0.01)) |> TimeStepModel(Hour(1)),
    status=(absorbed_radiation=0.0, transpiration=0.0),
)

maize_mapping = ModelMapping(
    ModelSpec(DocDomainAbsorbedRadiationModel(0.3)) |> TimeStepModel(Hour(1)),
    ModelSpec(DocDomainPlantTranspirationModel(0.02)) |> TimeStepModel(Hour(1)),
    status=(absorbed_radiation=0.0, transpiration=0.0),
)

soil_mapping = ModelMapping(
    ModelSpec(DocDomainSoilWaterModel(0.35)) |> TimeStepModel(Hour(1)),
    ModelSpec(DocDomainSoilEvaporationModel(0.2)) |> TimeStepModel(Hour(1)),
    status=(soil_water_content=0.0, evaporation=0.0),
)

scene_mapping = ModelMapping(
    ModelSpec(DocDomainSceneEvapotranspirationModel()) |> TimeStepModel(Day(1)),
    status=(evapotranspiration=0.0,),
)

simulation_mapping = SimulationMapping(
    Domain(:oil_palm, oil_palm_mapping; kind=:plant),
    Domain(:maize, maize_mapping; kind=:plant),
    Domain(:soil, soil_mapping; kind=:soil),
    Domain(:scene, scene_mapping; kind=:scene),
)
nothing
```

The meteorology is hourly. The plant and soil models run hourly, while the
scene model runs every day and integrates the producer streams.

```@example domains
hourly_meteo = Weather([
    Atmosphere(T=20.0, Rh=0.65, Wind=1.0, Ri_PAR_f=100.0, duration=Hour(1))
    for _ in 1:25
])

sim = run!(simulation_mapping, hourly_meteo; check=true)
round(status(sim, :scene).evapotranspiration; digits=2)
```

The final value is the daily integral of the two plant transpiration streams and
the soil evaporation stream.

## Inspecting the compiled simulation

Domain simulations expose small structured explanation helpers. These are meant
for users and for agents that need to repair a mapping from concrete symbols.

```@example domains
sort([(row.domain, row.kind) for row in explain_domains(sim)])
```

```@example domains
sort([(row.domain, row.process, row.dt_seconds) for row in explain_schedule(sim)])
```

```@example domains
sort(
    [(row.dependency, string(row.producer), row.policy) for row in explain_domain_dependencies(sim)];
    by=string,
)
```

The model-level explanation also includes the weather variables declared with
`meteo_inputs_` and any mutable environment variables declared with
`meteo_outputs_`:

```@example domains
[(row.domain, row.process, collect(keys(row.meteo_inputs))) for row in explain_domain_models(sim) if !isempty(row.meteo_inputs)]
```

## Explicit routes

`AllDomains(...)` value dependencies are the most direct way for a scene model
to consume several domain outputs. Routes are another option when you want to
materialize values into the target status before the target model runs.

```julia
Route(
    from=AllDomains(kind=:plant, process=:plant_transpiration, var=:transpiration),
    to=DomainRouteTarget(:scene, var=:plant_transpirations, process=:scene_evapotranspiration),
    cardinality=ManyToOneVector(),
)
```

Use `ManyToOneVector()` when the target model needs one value per matching
producer, and `ManyToOneAggregate(f)` when it needs a scalar reduction. For an
MTG-backed target domain, `OneToManyBroadcast()` can broadcast one source value
into every status at the target scale before that domain runs.

When a route targets a single-status domain variable consumed by one target
model, the target status slot is created from that model's `inputs_` default if
the user did not initialize it explicitly. Variables that are only route
materialization slots and are not model inputs still need to be initialized in
the target status.

When graph-domain values are aggregated across time, PlantSimEngine aligns them
by MTG node id. Growth and pruning inside the aggregation window therefore do
not require every timestep to publish vectors with the same length.

## Hard-domain dependencies

Use `HardDomains(...)` when a model must manually run selected producer
models, for example to control an iterative energy-balance solver:

```julia
PlantSimEngine.dep(::SceneEnergyBalanceModel) = (
    leaf_energy=HardDomains(kind=:plant, scale=:Leaf, process=:leaf_energy_balance),
)

function PlantSimEngine.run!(::SceneEnergyBalanceModel, models, status, meteo, constants=nothing, extra=nothing)
    leaf_targets = dependency_targets(extra, :leaf_energy)
    for iteration in 1:10
        for target in leaf_targets
            run_target!(target)
        end
        converged(status) && break
    end
    return nothing
end
```

Each target represents one selected model on one status. For an MTG-backed
producer domain, this means one target per matching node status, such as one
target per leaf. `run_target!` mutates that status like a normal model call,
but it does not append to domain streams or outputs unless `publish=true` is
requested. Trial iterations should usually run with `publish=false`, then the
final accepted hard-dependency call can use `publish=true`.

For same-status hard dependencies, the same target API can replace direct model
calls:

```julia
function PlantSimEngine.run!(::PhyllochronModel, models, status, meteo, constants, extra)
    run_target!(models, status, :phytomer_emission; meteo=meteo, constants=constants, extra=extra)
    return nothing
end
```

## MTG-backed plant domains

The same `Domain` wrapper can be used around a scale-keyed `ModelMapping`.
When running on an MTG, the `selector` decides which subtree roots belong to
the domain:

```julia
oil_palm = Domain(:oil_palm, xpalm_mapping; kind=:plant, selector=node -> node[:species] == :oil_palm)
maize = Domain(:maize, maize_mapping; kind=:plant, selector=node -> node[:species] == :maize)
sim = run!(scene_mtg, SimulationMapping(oil_palm, maize, scene), meteo)
```

Status inspection keeps both the domain-local view and the global scale view:

```julia
status(sim, :oil_palm, :Leaf)  # only oil palm leaves
status(sim, :maize, :Leaf)     # only maize leaves
status(sim, :Leaf)             # all leaves across graph-backed domains
```

If a declared graph scale currently has no active statuses, for example after
pruning all leaves, these status queries return `Status[]`. The same empty scale
is reported by `explain_domain_statuses(sim)` with `nstatuses=0`.

Selectors can also match several non-overlapping roots, for example
`selector=:Plant` to run one mapping over every plant subtree. Selectors that
match overlapping roots are rejected because they would register the same organ
twice.

## Meteorology and microclimate

Plain meteorology passed to `run!(SimulationMapping, meteo)` is wrapped as a
`GlobalConstant` environment backend. This preserves the existing behavior:
every object sees the same weather row at a given timestep.
If a model declares `meteo_inputs_`, running without meteorology now fails
during validation with the missing environment variables, instead of failing
later inside the model code.

Spatial or mutable microclimate should live in a specialized backend, not in
PlantSimEngine itself. A backend subtypes `AbstractEnvironmentBackend` and
implements the sampling and update hooks:

```julia
PlantSimEngine.sample(backend, variable, support, time)
PlantSimEngine.scatter!(backend, variable, support, value, time)
PlantSimEngine.update_index!(backend, entities)
```

Models declare which environment variables they read and write:

```julia
PlantSimEngine.meteo_inputs_(::LeafEnergyBalanceModel) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    Ri_PAR_f=0.0,
    CO2=400.0,
)

PlantSimEngine.meteo_outputs_(::MicroclimateUpdateModel) = (T=0.0,)
```

`EnvironmentSupport(domain, scale, process, status)` is passed to the backend,
so an octree, voxel, layered-canopy, or CFD backend can decide how to sample the
environment for the current organ or plant. In graph-backed domains, `status`
is the current node status.

## Updating a variable

Duplicate canonical writers are still errors by default. If a model is meant to
update a variable already produced at the same scale, declare that scenario rule
on the updating `ModelSpec`:

```julia
ModelSpec(LeafPruningModel()) |>
    Updates(:leaf_biomass; after=:carbon_allocation)
```

Only variables with several writers need an `Updates(...)` declaration. The
declaration adds an ordering edge and downstream consumers infer the terminal
updater as the effective source.

## Growth and topology changes

MTG-backed domain models receive the underlying `GraphSimulation` as `extra`,
so existing growth models can keep using the MTG registration APIs:

```julia
add_organ!(parent_node, extra, "+", :Leaf, 2; check=true)
remove_organ!(leaf_node, extra)
remove_organ!(internode_node, extra; recursive=true)
reparent_organ!(leaf_node, new_parent_node, extra)
```

These helpers update statuses, multiscale `RefVector`s, temporal streams, and
domain outputs. `update_index!(backend, entities)` is called after each domain
step so spatial environment backends can refresh their entity index after
growth, pruning, or geometry changes.

## Current boundaries

Cross-domain dependencies are explicit. PlantSimEngine does not infer them from
matching variable names across domains.

The domain layer defines the environment backend protocol, but it does not
implement an octree, voxel grid, or energy-balance solver. Those belong in
domain packages that provide models or environment backends.

Scene domains run after plant and soil domains in the current acyclic runner.
Routes that feed an MTG-backed target domain therefore need their source domain
to run earlier in the same timestep.
