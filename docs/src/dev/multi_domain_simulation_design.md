# Multi-Domain Simulation Design

This page is the working design for extending PlantSimEngine from one plant or
one MTG mapping to reusable plant, soil, scene, and environment domains.

The goal is incremental: keep existing `ModelMapping`, `ModelSpec`,
`MultiScaleModel`, hard dependencies, and multi-rate machinery, then add one
composition layer above them.

## Goals

- Reuse complete plant models, such as XPalm, as independent species or variety
  domains.
- Assemble several plant domains with shared soil, scene, and microclimate
  domains.
- Keep plant-local mappings readable and reusable.
- Make cross-domain coupling explicit.
- Support multi-rate execution from the start using `Dates.FixedPeriod`
  timesteps.
- Preserve fast reference-based coupling inside existing mappings.
- Make compiled simulations inspectable by humans and agents.
- Allow exceptional same-scale duplicate writers through scenario-level
  `Updates(...)` declarations.
- Let meteorology be either constant/table-driven or provided by an external
  microclimate backend.

## Non-Goals For The First Implementation

- Do not infer cross-domain dependencies from matching variable names.
- Do not implement octree or voxel microclimate in PlantSimEngine.
- Do not solve arbitrary dynamic-topology MTG registration in the first slice;
  organ addition, terminal-organ removal, recursive subtree removal, and
  same-simulation reparenting are covered.
- Do not rewrite model kernels or force model authors to adopt a new `run!`
  signature.

## Domain

A `Domain` wraps an existing mapping and gives it an identity:

```julia
oil_palm = Domain(:oil_palm, kind=:plant, mapping=xpalm)
maize = Domain(:maize, kind=:plant, mapping=maize)
soil = Domain(:soil, kind=:soil, mapping=soil_mapping)
scene = Domain(:scene, kind=:scene, mapping=scene_mapping)
microclimate = Domain(:microclimate, kind=:environment, mapping=microclimate_mapping)
```

Model identity inside the compiled simulation is:

```julia
(domain, scale, process)
```

not only:

```julia
(scale, process)
```

This avoids renaming `:Leaf` into species-specific scale names. XPalm can keep
using `:Plant`, `:Leaf`, `:Internode`, and so on.

For MTG runs, domains will also need selectors:

```julia
Domain(
    :oil_palm,
    kind=:plant,
    mapping=xpalm,
    selector=node -> node[:species] == :oil_palm,
)
```

The selector decides which MTG nodes belong to the domain-local view.

## SimulationMapping

`SimulationMapping` assembles domains:

```julia
simulation_mapping = SimulationMapping(oil_palm, maize, soil, scene)
```

It should preserve both domain-local and global scale views:

```julia
status(sim, :oil_palm, :Leaf)  # oil palm leaves
status(sim, :maize, :Leaf)     # maize leaves
status(sim, :Leaf)             # all leaves across plant domains
status(sim, :soil, :Soil)      # shared soil statuses
```

When one domain selector matches several subtree roots, the domain-local status
view is flattened across those roots:

```julia
forest = Domain(:forest, kind=:plant, mapping=leaf_mapping, selector=:Plant)
status(sim, :forest, :Leaf) # leaves from every selected Plant subtree
```

The initial `run!(mapping::SimulationMapping, meteo)` path supports
single-status domains. The `run!(mtg, mapping::SimulationMapping, meteo)` path
also supports MTG-backed domains when a domain selector resolves to one or more
subtree roots. That path reuses the existing `GraphSimulation` engine for each
selected root, advances domains one base timestep at a time, then publishes
aggregated graph outputs into the domain stream layer so single-status scene
domains can consume them during the same timestep. It is still acyclic by
domain order: domains whose `kind` is not `:scene` run first, then `:scene`
domains run.
Routes into graph domains are supported when their source domain has already
run in the current timestep. Runtime status counts are inspectable with
`explain_domain_statuses(sim)`.

## Cross-Domain Routes

Local variable inference remains inside one domain. Cross-domain exchange is
explicit:

```julia
Route(
    from = AllDomains(kind=:plant, scale=:Leaf, var=:Tleaf),
    to = DomainRouteTarget(:scene, scale=:Scene, var=:leaf_temperatures),
    policy = Integrate(),
)
```

Route cardinality should be explicit where needed:

```julia
ManyToOneVector()
ManyToOneAggregate(sum)
OneToManyBroadcast()
SpatialSample()
SpatialScatterAdd()
```

This prevents ambiguous behavior when several plant domains publish the same
scale, process, or variable.

In the single-status runner, routes are executable for target
`scale=:Default`:

```julia
Route(
    from = AllDomains(
        kind=:plant,
        process=:plant_transpiration,
        var=:transpiration,
    ),
    to = DomainRouteTarget(
        :scene,
        var=:plant_transpirations,
        process=:scene_evapotranspiration,
    ),
    cardinality = ManyToOneVector(),
)
```

The target variable must already exist in the target domain status. If the
target process is omitted, PlantSimEngine tries to infer a unique model at the
target domain/scale that consumes the routed variable; otherwise the route clock
is hourly/base-step. `ManyToOneVector()` materializes one value per producer.
`ManyToOneAggregate(f)` reduces producer values with `f`. Spatial and broadcast
cardinalities are defined as public route types but are reserved for the
MTG/spatial runner.

In the current single-status runner, initialize routed vector targets with a
typed placeholder such as `[0.0]` rather than an empty vector. The route
overwrites the value before the target model runs, but the underlying
single-scale `ModelMapping` still treats an empty vector status value as
not initialized.

The MTG runner also supports one graph-target route form:
`OneToManyBroadcast()` into an MTG-backed domain. The route writes the resolved
source value into every status at the target scale before that graph domain
runs for the current timestep. On the first timestep, the runner also seeds the
selected MTG nodes with the routed attribute before `GraphSimulation`
initialization so existing graph initialization checks still apply. This is
useful for same-timestep coupling from an earlier domain, such as a shared soil
signal broadcast to leaves. Scene-to-plant feedback remains out of scope for
this acyclic order because scene domains run after plant domains.

## Domain-Aware Value Dependencies

Scene and environment models often need to consume outputs from all plant
domains. Stream/value dependencies use `AllDomains(...)` and should be explicit:

```julia
PlantSimEngine.dep(::SceneEvapotranspirationModel) = (
    plant_transpiration = AllDomains(
        kind=:plant,
        process=:plant_transpiration,
        var=:transpiration,
        policy=Integrate(),
    ),
    soil_evaporation = AllDomains(
        kind=:soil,
        process=:soil_evaporation,
        var=:evaporation,
        policy=Integrate(),
    ),
)
```

The runtime resolves this to concrete `(domain, scale, process)` producers.
Scene models consume resolved values, not manually index a single
`extra.models[:Leaf]`.

Unmatched `AllDomains(...)` selectors are reported with the consumer
`domain/scale/process`, the selector fields, available producer outputs, and
near matches when only `var` is wrong. This is part of the agent-facing API:
errors should contain enough concrete symbols for a user or AI system to repair
the mapping without reverse-engineering the compiled graph.

In the first executable slice, scene models can read producer values with:

```julia
plant_values = dependency_values(extra, :plant_transpiration, :transpiration)
soil_values = dependency_values(extra, :soil_evaporation, :evaporation)
```

When the selector declares `var`, model code can use the shorter form:

```julia
plant_values = dependency_values(extra, :plant_transpiration)
```

For MTG-backed producer domains, each resolved `(domain, scale, process)`
producer can represent several node statuses. The default
`dependency_values(...)` result therefore contains one value per producer, with
graph-domain producers unwrapped as vectors of node values. Scene models that
want one flat list across all selected domains can request:

```julia
leaf_values = dependency_values(extra, :leaf_fluxes; flatten=true)
```

When graph-domain producer values are reduced over a multi-rate window, the
runtime carries MTG node ids alongside the values and aggregates by node id.
This makes growth and pruning inside the window well-defined: a newly appeared
organ contributes from the timestep where it exists, and a removed organ keeps
its already-published contribution without requiring all value vectors in the
window to have the same length.

If a selected producer is nested as a hard dependency inside a domain model, its
outputs are published when the owning parent model runs. This keeps the model
visible to scene-level `AllDomains(...)` dependencies without making the hard
dependency independently scheduled.

## Hard Cross-Domain Dependencies

Some coupled models need true call-stack control. Energy balance is the typical
case: a scene-scale solver may need to run leaf-scale energy, stomatal
conductance, and photosynthesis models repeatedly until leaf temperatures
converge. That is not an `AllDomains(...)` value dependency.

Hard cross-domain dependencies use `HardDomains(...)`:

```julia
PlantSimEngine.dep(::SceneEnergyBalanceModel) = (
    leaf_energy = HardDomains(
        kind=:plant,
        scale=:Leaf,
        process=:leaf_energy_balance,
    ),
)
```

Inside `run!`, the parent requests targets and runs them manually:

```julia
function PlantSimEngine.run!(::SceneEnergyBalanceModel, models, status, meteo, constants=nothing, extra=nothing)
    leaf_targets = dependency_targets(extra, :leaf_energy)
    for iteration in 1:max_iterations
        for target in leaf_targets
            run_target!(target)
        end
        converged(status) && break
    end
    return nothing
end
```

Each target selects one model on one runtime status. In single-status
domains, a producer usually gives one target. In MTG-backed domains, a producer
at `scale=:Leaf` gives one target per matching leaf status. The call mutates the
status, just like a normal hard dependency call. By default it does not publish
to domain streams or outputs, which keeps trial iterations from becoming
canonical temporal outputs. The final accepted hard-dependency call can opt into
`publish=true`.

Hard dependencies remain manual calls owned by the parent model. A hard
dependency child cannot have an independent `ModelSpec` timestep; if the child
needs its own clock, it should be coupled as a soft dependency instead.

## Multi-Rate Semantics

User-facing time configuration should continue to use `Dates`:

```julia
ModelSpec(model) |> TimeStepModel(Dates.Hour(1))
ModelSpec(model) |> TimeStepModel(Dates.Day(1))
```

For the first implementation, use `Dates.FixedPeriod` only. `Dates.Month` and
`Dates.Year` are calendar-dependent and should error unless a calendar-aware
runtime is added.

Cross-domain dependencies and routes carry a temporal policy:

```julia
HoldLast()
Interpolate()
Integrate()
Aggregate()
```

The domain key must be part of temporal state keys from the beginning to avoid
collisions between species, soil, and environment streams.

## Variable Updates

Duplicate writers remain errors by default. Exceptional updates are declared by
the scenario author, not the model author:

```julia
ModelSpec(LeafPruning()) |>
    Updates(:leaf_biomass; after=:carbon_allocation)
```

Rules:

- one canonical producer is allowed;
- additional same-scale writers must declare `Updates(...)`;
- `after` adds an ordering edge;
- if several update writers target the same variable, they must also be ordered
  relative to each other;
- if both models run at the same `DateTime`, the updater runs after the
  producer;
- if only the updater runs, it updates the latest available state;
- downstream consumers read the updated value.
- in multi-rate input binding inference, an ordered update chain is treated as
  one effective source by selecting the unique terminal updater for the updated
  variable.

Only variables with duplicate writers need annotation.

## Meteorology And Microclimate

Models should declare meteorological fields explicitly:

```julia
meteo_inputs_(::LeafEnergyBalanceModel) = (
    T = -Inf,
    Rh = -Inf,
    Wind = -Inf,
    Ri_PAR_f = -Inf,
    CO2 = -Inf,
)

meteo_outputs_(::MicroclimateModel) = (
    T = -Inf,
    Rh = -Inf,
    Wind = -Inf,
    Ri_PAR_f = -Inf,
    CO2 = -Inf,
)
```

`inputs_` and `outputs_` remain object status variables. `meteo_inputs_` and
`meteo_outputs_` describe weather/environment variables; `meteo_inputs` and
`meteo_outputs` are the public key accessors.

PlantSimEngine should define the microclimate backend interface, not the octree
or voxel implementation:

```julia
abstract type AbstractEnvironmentBackend end

get_nsteps(backend)
base_step_seconds(backend)
sample(backend, variable, support, time)
sample_environment(backend, support, time, variables)
scatter!(backend, variable, support, value, time)
update_index!(backend, entities)
```

`GlobalConstant(meteo)` is the simple backend and preserves current behavior:
all models see the same meteo object or meteo row at a given timestep. Plain
meteo passed to `run!(SimulationMapping, meteo)` is wrapped automatically.

Backends receive an `EnvironmentSupport(domain, scale, process, status)` so
they can decide whether a sampled value is global, plant-local, organ-local, or
spatially resolved. The same protocol is used for single-status domains and
MTG-backed domains; in graph domains, `status` is the current node status, so
the backend can inspect node geometry, scale, domain, or any status variable.
Octree, voxel, layered-canopy, and CFD backends should live in specialized
packages.

After each domain step, the domain runtime calls:

```julia
update_index!(backend, entities)
```

where `entities` is a small collection of `(domain, kind, scale, statuses,
state)` rows. Spatial backends can use this hook to refresh their entity index
after geometry changes, growth, pruning, or status updates. `GlobalConstant`
ignores the hook.

When a model declares `meteo_outputs_`, the domain runtime scatters those values
to the backend after the model runs:

```julia
meteo_outputs_(::MicroclimateUpdateModel) = (T = -Inf,)
outputs_(::MicroclimateUpdateModel) = (T = -Inf,)
```

The same variable must currently be available on the model status, usually by
declaring it in `outputs_`. This keeps the existing `run!` signature unchanged
while giving backends a clear `scatter!` hook. In MTG-backed domains, the
scatter hook is called once per node status after the model runs. `GlobalConstant`
is immutable and errors if a model tries to scatter into it.

## Growth And Dynamic Entities

Dynamic organ creation must go through a central registration API. When a new
organ is added, the runtime must update:

- domain-local status views;
- global scale views;
- cross-domain routes;
- outputs;
- temporal buffers;
- environment spatial indexes.

This should not be scattered through model code. In MTG-backed domains, models
should keep using the existing:

```julia
add_organ!(parent_node, graph_simulation, link, symbol, scale; kwargs...)
```

from their `run!` implementation. The domain runner passes the underlying
`GraphSimulation` as `extra`, so existing growth models can register new organs
without knowing they are part of a `SimulationMapping`.

For the current domain runner:

- `add_organ!` initializes the new node status and updates multiscale
  `RefVector` wiring through the existing MTG initialization helpers.
- `remove_organ!` supports terminal MTG nodes by default and internal-node
  subtree deletion with `recursive=true`. It removes node statuses, detaches
  references from downstream `RefVector`s, clears node-scoped temporal cache and
  stream entries, and deletes the MTG nodes.
- `reparent_organ!` moves an already simulated node under another already
  simulated parent in the same `GraphSimulation`, validating that both nodes are
  registered and that the move does not create a cycle. Statuses and
  `RefVector`s continue to reference the same node objects, so no status
  rewiring is needed for this case.
- `status(sim, domain, scale)` and `status(sim, scale)` read the live
  `GraphSimulation` status vectors, so newly added organs are visible after
  registration. If a declared graph scale currently has no active statuses,
  these helpers return `Status[]` rather than throwing a dictionary lookup
  error, and `explain_domain_statuses(sim)` reports the scale with
  `nstatuses=0`.
- graph-domain output publication runs after each graph-domain timestep and
  includes newly registered statuses while skipping removed terminal organs.
- `update_index!(backend, entities)` is called after each domain step so
  external microclimate backends can refresh their spatial/entity index.

The current tests cover a new graph-domain leaf publishing an hourly stream
that is consumed by a daily model with `Integrate()`, online
`OutputRequest(...)` exports from dynamically created leaves, several leaves
created in the same timestep, custom callable scopes returning `ScopeId`,
terminal leaf removal in direct and multirate graph-domain coupling, repeated
terminal create/remove cycles, recursive internal-node subtree deletion, and
same-simulation topology reparenting.

## Agent-Friendly Requirements

The compiled simulation must be explainable as structured data:

```julia
explain_domains(sim)
explain_routes(sim)
explain_schedule(sim)
explain_writers(sim)
explain_domain_dependencies(sim)
```

Errors should include the conflicting domains/scales/processes and a suggested
fix. For example, duplicate writers should suggest `Updates(:var; after=...)`.
