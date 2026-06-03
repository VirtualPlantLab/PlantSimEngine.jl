# Multi-Domain Simulation Implementation Plan

This page tracks the implementation plan for the multi-domain work. The design
reference is `multi_domain_simulation_design.md`.

## Milestone 1: Executable Single-Status Domain Slice

Done when:

- `Domain`, `SimulationMapping`, `DomainSimulation`, `DomainModelKey`, and
  `AllDomains` exist.
- Domains can wrap existing single-scale `ModelMapping`s.
- A `SimulationMapping` can run plant and soil domains hourly and a scene
  domain daily with `Dates.Hour(1)` and `Dates.Day(1)`.
- Single-status domains can contain models with different `ModelSpec`
  timesteps. Implemented.
- Scene models can consume resolved cross-domain producer streams with
  `dependency_values`.
- `AllDomains(...; var=:x)` can declare the consumed output variable, allowing
  `dependency_values(extra, :dependency_name)` and earlier validation of
  producer matches. Implemented for the single-status domain runner.
- Scene models can consume a model nested as a hard dependency inside a domain;
  the nested model output is published when its owning parent runs.
  Implemented for the single-status domain runner.
- `explain_domains`, `explain_schedule`, and
  `explain_domain_dependencies` return structured rows.
- A test example covers two plant domains, one soil domain, and one scene
  evapotranspiration model.

Likely files:

- `src/domains/domain_simulation.jl`
- `src/PlantSimEngine.jl`
- `test/test-domain-simulation.jl`
- `test/runtests.jl`

## Milestone 2: Agent-Friendly Inspection And Validation

Current status: implemented for the current domain runner surface.
`explain_domain_models(...)` returns expanded rows, the initial runner
validates unsupported cases early, mixed rates inside single-status domains are
scheduled independently, and explicit `Route(...)` materialization is
implemented for single-status domains with `ManyToOneVector()` and
`ManyToOneAggregate(...)`.

Done when:

- `explain_domain_models(simulation_mapping)` returns expanded domain model
  rows. Implemented.
- Errors include domain, scale, process, variable, and suggested fixes.
  Implemented for unmatched `AllDomains(...)` dependencies and routes, route
  targets, duplicate domains, and unsupported domain/route shapes.
- Duplicate domain names error early. Implemented.
- Mixed timesteps inside one initial domain are scheduled independently.
  Implemented for single-status domains.
- `AllDomains(...)` selectors report unmatched dependencies with context.
  Implemented.
- `Route(...)` materializes cross-domain producer streams into target domain
  status variables. Implemented for single-status domains.
- `explain_domain_dependencies(simulation)` reports resolved producers,
  temporal policy, and the declared dependency variable. Implemented.
- `explain_routes(simulation)` reports resolved route producers, target
  variables, cardinality, temporal policy, and effective route clocks.
  Implemented.

Likely tests:

- duplicate domain name;
- unmatched `AllDomains`;
- scene domain with multiple scene processes;
- domain with mixed model rates in the initial runner.
- scene dependency targeting a hard-dependency child inside a plant domain.
- vector and aggregate cross-domain routes.

## Milestone 3: `Updates(...)` In `ModelSpec`

Current status: implemented for same-scale dependency graphs, single-scale
runs, and MTG-backed domain runs. Downstream input binding inference treats an
unambiguous ordered update chain as one effective producer by selecting the
terminal updater.

Done when:

- `Updates(:var; after=:process)` exists as a scenario-level annotation.
  Implemented.
- Duplicate writers remain errors unless additional writers declare updates.
  Implemented for canonical same-scale writers.
- `after` creates an ordering edge.
  Implemented for executable soft dependency nodes.
- Downstream consumers read the terminal updated value when the update order is
  unambiguous. Implemented for MTG-backed domains.
- Errors suggest the exact `Updates(:var; after=...)` fix.
  Implemented for duplicate writers and invalid update declarations.
- Only variables with duplicate writers need annotation.
  Implemented.

Likely files:

- `src/mtg/ModelSpec.jl`
- dependency graph construction files
- model spec validation files
- tests for duplicate writers and ordered updates

## Milestone 4: Meteo Traits

Current status: trait surface and runtime field validation are implemented.
Environment backend coupling is implemented for the single-status domain
runner through the protocol described in Milestone 6.

Done when:

- `meteo_inputs(model)` and `meteo_outputs(model)` default to empty keys from
  `NamedTuple()`. Implemented.
- Existing meteo validation can check required fields when traits are present.
  Implemented for constant/table meteo field presence, including
  `MeteoBindings(source=...)` remapping and public
  `validate_meteo_inputs(mapping, meteo)` checks.
- `explain_model_specs` or a new explanation helper reports meteo needs.
  Implemented in `explain_model_specs` and `explain_domain_models`.
- Trait declarations support simple NamedTuple defaults first.
  Implemented.

Likely files:

- `src/processes/models_inputs_outputs.jl`
- `src/time/runtime/meteo_sampling.jl`
- documentation for model authors

## Milestone 5: MTG-Backed Domains

Current status: timestep-interleaved MTG-backed domain execution is implemented
for domain selectors that resolve to one or more subtree roots. The runner
advances non-scene domains, including graph domains backed by the existing
`GraphSimulation`, then advances single-status scene domains in the same base
timestep. Graph-domain outputs are aggregated per domain and published into
per-scale streams for `Route(...)` and `AllDomains(...)` consumers.

Done when:

- `Domain(..., selector=...)` partitions MTG nodes into domain-local views.
  Implemented for one or more selected subtree roots per graph domain.
- Domain-local statuses and global scale statuses are both available.
  Domain-local statuses are available through `status(sim, domain, scale)`.
  Global cross-domain views are available through `status(sim, scale)` when no domain
  has the same name, and runtime counts are reported by
  `explain_domain_statuses(sim)`.
- Cross-domain routes can consume all statuses from selected domains.
  Implemented for graph-domain sources routed into single-status
  domains. Also implemented for `OneToManyBroadcast()` routes into graph
  domains when the source domain runs earlier in the current timestep.
- Existing single-domain MTG behavior still works.
  Reused by the domain runner through `GraphSimulation`.

Likely files:

- `src/mtg/initialisation.jl`
- `src/mtg/GraphSimulation.jl`
- new domain graph simulation code
- tests with two plant species sharing `:Leaf` scale names

## Milestone 6: Environment Provider Interface

Current status: protocol and constant backend are implemented for the domain
runner. Custom backends are supported by single-status domains and MTG-backed
domains. Spatial backends remain external-package work.

Done when:

- PlantSimEngine defines the backend protocol for sampling and scattering
  meteo/environment variables. Implemented with `AbstractEnvironmentBackend`,
  `EnvironmentSupport`, `sample`, `sample_environment`, `scatter!`,
  `update_index!`, `get_nsteps`, and `base_step_seconds`.
- A constant meteo backend supports current behavior. Implemented with
  `GlobalConstant`, and plain meteo passed to `run!(SimulationMapping, meteo)`
  is wrapped automatically.
- External packages can implement spatial backends without PlantSimEngine
  knowing whether they use voxels, octrees, layers, or another structure.
  Implemented for the protocol surface; full spatial examples remain future.
- Environment bindings are visible to explanation helpers. Implemented with
  `explain_environment(simulation)` plus `meteo_inputs_` in
  `explain_domain_models`.
- Domain models declaring `meteo_outputs_` scatter same-named status values into
  mutable backends after `run!`. Implemented for the single-status domain
  runner and MTG-backed domain runner; `GlobalConstant` errors because it is
  immutable.
- Domain steps call `update_index!(backend, entities)` after model execution so
  mutable/spatial backends can refresh their entity indexes. Implemented for
  single-status domains and MTG-backed domains; `GlobalConstant` is a no-op.

Likely API:

```julia
sample(backend, variable, support, time)
scatter!(backend, variable, support, value, time)
update_index!(backend, entities)
```

## Milestone 7: Growth Registration

Current status: implemented for MTG-backed domains that use the existing
`add_organ!` API inside model `run!` methods, and for terminal or recursive
subtree removal with `remove_organ!`, and for same-simulation topology
reparenting with `reparent_organ!`. Domain status views and graph-domain stream
publication observe the live `GraphSimulation` status vectors, dynamic producer
streams are extended lazily, removed organs are detached from downstream
`RefVector`s and temporal caches, reparented organs keep their existing status
and reference identity, and environment backends receive `update_index!` calls
after each domain step.

Done when:

- new organs are added through one runtime API. Implemented by reusing
  `add_organ!` from graph-domain models.
- domain-local and global status views are updated. Implemented because
  `DomainSimulation` reads the live graph-domain status vectors.
- graph-domain output publication includes newly registered statuses.
  Implemented in the timestep-interleaved domain runner.
- environment indexes can be updated by the backend. Implemented through
  `update_index!(backend, entities)` after each domain step.
- organs can be removed through one runtime API. Implemented with
  `remove_organ!`, which removes the node status, detaches downstream
  `RefVector` references, removes node-scoped temporal cache and stream entries,
  and deletes the MTG node. Terminal deletion is the default; internal-node
  subtree deletion is available with `recursive=true`.
- already simulated organs can be reparented through one runtime API.
  Implemented with `reparent_organ!` for moves inside the same active
  `GraphSimulation`.
- output and temporal buffers are resized or lazily extended for all covered
  dynamic multi-rate cases. Regular graph outputs use the existing
  `save_results!` resizing path. Dynamic producer streams are covered for an
  hourly producer added during the run and consumed by a daily model with
  `Integrate()`. Online `OutputRequest(...)` exports are covered for a
  dynamically created leaf using plant scope, several leaves created in the
  same timestep, and custom callable scopes returning `ScopeId`. Terminal
  removal is covered for direct `RefVector` coupling, multirate temporal
  streams, repeated terminal create/remove cycles, and recursive internal-node
  subtree deletion. Same-simulation reparenting is covered for topology
  mutation while preserving status and reference identity.

## Executable Examples

The first executable domain example in `docs/src/domain_simulation.md` uses:

- two plant domains with different parameters and several hourly models each;
- one soil domain with several hourly models;
- one scene domain with a daily evapotranspiration model;
- explicit `AllDomains(...)` dependencies from the scene model to plant
  transpiration and soil evaporation;
- `Dates.Hour(1)` for plant/soil domains and `Dates.Day(1)` for the scene
  model.

The MAESPA-style example in `examples/maespa_domain_example.jl` exercises the
hard-dependency path:

- two MTG-backed plant domains with different models and parameters;
- one shared soil domain;
- one scene energy-balance model using `HardDomains(...)`;
- manual calls through `dependency_targets(...)` and `run_target!(...)`;
- trial iterations with `publish=false`, followed by final accepted calls with
  `publish=true`;
- hourly scene/plant/soil energy-balance models and daily plant allocation
  models.
