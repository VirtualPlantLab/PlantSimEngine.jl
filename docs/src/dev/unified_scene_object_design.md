# Unified Scene/Object Design

This page records the target breaking design for one scene/object
configuration and runtime API.

The central idea is:

> Structural groupings and scales are selections over objects in one scene.

The engine should expose one way to say "this model input comes from these
objects" and one way to say "this model must manually call these models". The
compiler can then choose whether the runtime carrier is a `Ref`, `RefVector`,
temporal stream, materialized value, or callable model handle.

The public API should be simple enough to remember as:

```julia
Scene
Object
ModelSpec

AppliesTo(...)
Inputs(...)
Calls(...)
Updates(...)
TimeStep(...)
Environment(...)
```

Everything else should either be a selector, a trait declared by the model
author, or an internal compiled carrier.

## Core Concepts

### Scene

A `Scene` is the whole simulation universe. It contains:

- simulated objects;
- model applications;
- environment providers;
- time/runtime state;
- caches for object selections and environment bindings.

Plants, soil, atmosphere, microclimate grids, organs, sensors, and artificial
objects all live in the same scene-level object graph.

### Object

An object is any simulated entity with identity. It may have:

- a unique object id;
- one or more labels, such as `scale=:Leaf`, `kind=:plant`,
  `species=:oil_palm`;
- parent/child links;
- geometry or position;
- status variables;
- model applications.

The engine must not prescribe a plant architecture. A plant can be described as
`Plant -> Internode -> Leaf`, `Plant -> Axis -> Segment -> Leaf`,
`Plant -> Metamer -> Organ`, or another topology. The engine only needs object
identity, labels, and relations.

Existing `MultiScaleTreeGraph.Node` topologies enter the same registry through
`objects_from_mtg(root; ...)` or `Scene(root; ...)`. The adapter traverses once
and accepts accessors for ids, labels, status, and geometry; the timestep
runtime does not query the MTG topology.

### Scale

A scale is a label on objects, not a separate runtime layer. Examples:

```julia
:Scene
:Plant
:Axis
:Internode
:Leaf
:Soil
:SoilLayer
:Voxel
```

### Scope

A scope is a named or inferred subset of objects. Examples:

```julia
SceneScope()
Self()
SelfPlant()
Ancestor(scale=:Plant)
Scope(:oil_palm)
Kind(:plant)
Species(:oil_palm)
```

`Self()` means only the current model application object. `Subtree()` means
that object and its descendants. Neither spelling changes meaning with scale.

`SelfPlant()` is the nearest containing plant scope. The more generic form is
`Ancestor(scale=:Plant)`. Use these when a model running below the plant scale
must access siblings or state inside the containing plant.

Reusable plant models should use scope-relative queries. If an allocation
model is applied to each `:Plant`, `Many(scale=:Leaf, within=Subtree())` means
"the leaves inside this plant", not all leaves in the scene. The same query
applied to an axis-scale model means "the leaves inside this axis".

Scene-level models widen the scope explicitly with `within=SceneScope()`.

Topology-relative selections use `Relation(...)`:

```julia
One(Relation(:parent))
Many(Relation(:children))
Many(Relation(:ancestors), Scale(:Plant))
Many(Relation(:descendants), Scale(:Leaf))
Many(Relation(:siblings))
```

Supported relations are `:self`, `:parent`, `:children`, `:ancestors`,
`:descendants`, and `:siblings`. They resolve relative to the current model
application object. An explicit `within=...` scope intersects the relation
result; inferred default scopes do not hide parents or siblings. Relation
results are normalized to stable object-id order before bindings are compiled.

### Object Template And Instance

An object template is a reusable model/parameter bundle, for example one oil
palm species model. An object instance is one concrete object in the scene.

The same template can be mounted several times:

```julia
oil_palm = ObjectTemplate(
    kind=:plant,
    species=:oil_palm,
    applications=oil_palm_applications,
    parameters=oil_palm_parameters,
)

scene = Scene(
    ObjectInstance(:palm_1, oil_palm; root=node1),
    ObjectInstance(:palm_2, oil_palm; root=node2),
    ObjectInstance(:palm_3, oil_palm; root=node3),
    ObjectInstance(:palm_4, oil_palm; root=node4),
)
```

Models and parameters can be overridden at instance or object level:

```julia
ObjectInstance(:palm_2, oil_palm; overrides=(
    stomatal_conductance = Tuzet(; g1=3.2),
))

Override(
    object=:leaf_12,
    process=:photosynthesis,
    model=Fvcb(; VcMaxRef=90.0),
)
```

Ownership is reference-based and explicit:

- a template retains the supplied model and parameter objects without copying;
- unchanged instances share those exact objects;
- an instance override replaces one complete model application with another
  user-owned model object;
- an object override replaces that application only for the selected object;
- PlantSimEngine does not mutate model fields or implicitly merge parameter
  dictionaries.

Overrides must preserve the model contract: process identity and declared
status/environment variable names cannot change. Parameter-only overrides of
the same concrete model type retain concrete runtime dispatch. Heterogeneous
alternative implementations are supported but may require dynamic dispatch for
the exceptional application.

### Model Kernel And Model Application

A model kernel is the reusable model implementation written by a modeler. It
defines a process, parameters, `inputs_`, `outputs_`, optional `dep` defaults,
optional environment traits, and `run!`.

A model application is the scenario-specific use of that kernel on selected
objects, at a selected rate, with selected value inputs, model calls, update
rules, output routing, and environment binding behavior.

The model kernel should not need to know:

- the species it will be used with;
- the scene it will be embedded in;
- the timestep chosen by the user;
- whether its inputs come from local state, another scale, another object, a
  temporal stream, units, automatic differentiation values, or uncertainty
  wrappers.

The scenario owns those decisions through `ModelSpec`.

Target shape:

```julia
ModelSpec(LeafEnergyBalance(); name=:leaf_energy) |>
    AppliesTo(Many(kind=:plant, scale=:Leaf)) |>
    Inputs(...) |>
    Calls(...) |>
    TimeStep(Hour(1))
```

Application names are optional but important when the same process appears more
than once in the same object set. Other declarations can target either
`process=:photosynthesis` or `name=:sunlit_photosynthesis` when a process alone
is ambiguous.

## Unified Model Configuration

`ModelSpec` is the single scenario wrapper. Released mapping-era configuration
is replaced by explicit value inputs and callable model calls.

### Applies To

Use `AppliesTo(...)` to declare the object set where a model application runs.
This should be first-class, not inferred from a container or mapping key.

```julia
ModelSpec(LeafState()) |>
    AppliesTo(Many(kind=:plant, scale=:Leaf))

ModelSpec(AllocationModel()) |>
    AppliesTo(Many(kind=:plant, scale=:Plant))

ModelSpec(SceneEB()) |>
    AppliesTo(One(scale=:Scene))
```

The same model kernel can be applied several times with different selectors,
parameters, timesteps, or input bindings. The compiler should normalize each
application to a stable application id.

### Dependency Defaults From Traits

Model authors should still declare `inputs_`, `outputs_`, and `dep`. In the
final design, `dep(model)` is the model-level place for default dependency
intent. Historical `ModelMapping` declarations are migration inputs to the
Scene/Object runtime, not a second supported path.

The rule is:

- `inputs_(model)` declares the variables the model needs;
- `outputs_(model)` declares the variables the model computes;
- `dep(model)` declares default value sources or manual model calls when the
  model author knows a sensible coupling pattern;
- `ModelSpec(...) |> Inputs(...)` and `ModelSpec(...) |> Calls(...)` override
  or specialize those defaults for a specific simulation.

For example, a plant allocation model can provide a plant-local default:

```julia
dep(::PlantAllocationModel) = (
    leaf_carbon = Input(Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon)),
)
```

An energy-balance model can declare that it usually calls a stomatal
conductance model manually:

```julia
dep(::LeafEnergyBalanceModel) = (
    stomatal_conductance = Call(process=:stomatal_conductance),
)
```

These trait defaults are not absolute wiring. They are model-author defaults
that make common cases work without repeating configuration, while scenario
authors keep final authority through `ModelSpec`.

Compiler order:

1. read `inputs_`, `outputs_`, and `dep`;
2. infer simple same-object value dependencies when unambiguous;
3. apply `dep(model)` defaults for value inputs and model calls;
4. apply `ModelSpec` overrides last.

This order is part of the public contract. It keeps modeler defaults useful
without making them final wiring. Missing or ambiguous inputs after this pass
are errors, not incidental fallback behavior.

### Value Inputs

Use `Inputs(...)` when a model needs values before its `run!` method executes:

```julia
ModelSpec(LAIModel(ground_area)) |>
    Inputs(:leaf_areas => Many(scale=:Leaf, within=SceneScope(), var=:leaf_area))
```

Reusable plant allocation:

```julia
ModelSpec(AllocationModel()) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Subtree(), var=:leaf_carbon))
```

The same declaration must compile to:

- direct `Ref`/`RefVector` wiring when producer and consumer live in the same
  object graph and rate;
- temporal stream reads when producer and consumer run at different rates;
- materialization when target status must be assigned before a
  model runs;
- source-status lookup for graph-backed object selections.

The important user rule is:

- `Inputs(...)` means "give this model values"; the runtime schedules or
  samples producers;
- the receiving model never manually calls the producer because of an
  `Inputs(...)` declaration.

### Carrier And Copy Semantics

The compiler chooses the carrier, but the semantics must be documented and
explainable:

| Situation | Preferred carrier | Copy behavior |
| --- | --- | --- |
| same-rate scalar input | shared `Ref` or local alias | no copy when possible |
| same-rate `Many(...)` input | `RefVector` or equivalent typed reference collection | no copy for live values |
| cross-rate input | temporal stream sample | value materialized for the consumer timestep |
| `Integrate` or `Aggregate` input | temporal window reduction | reduced value materialized |
| materialized target status input | compiler-generated assignment | assigned before consumer run |
| environment input | cached `EnvironmentBinding` sample | backend-defined value sample |

This table is a required part of the design because performance, units,
automatic differentiation, and error propagation depend on preserving user
value types and avoiding hidden copies.

PlantSimEngine should not force `Float64` internally. Status values,
parameters, meteo values, and outputs must be allowed to use units, dual
numbers, uncertainty wrappers, tracked arrays, or other numeric-like types.
Compiled carriers should be parametric and type stable whenever the object set
and value type are known at initialization.

### Multirate Inputs

Multirate must be supported by the same `Inputs(...)` declaration, not a
separate mapping language. The public time language should remain `Dates`
periods.

Example:

```julia
ModelSpec(PlantAllocation()) |>
    AppliesTo(Many(kind=:plant, scale=:Plant)) |>
    Inputs(:leaf_assimilation => Many(
        scale=:Leaf,
        within=Subtree(),
        var=:assimilation,
        policy=Integrate(),
        window=Day(1),
    )) |>
    TimeStep(Day(1))
```

Policy precedence should stay explicit:

1. input-level policy in `Inputs(...)`;
2. producer `output_policy(model)`;
3. default `HoldLast()`.

Cross-rate links must go through temporal state even when they point to objects
that could otherwise be reference-wired.

Same-timestep feedback cycles are broken explicitly on the receiving input:

```julia
ModelSpec(CarbonState()) |>
    Inputs(
        PreviousTimeStep(:carbon_biomass) => One(
            scale=:Plant,
            process=:carbon_allocation,
            var=:carbon_biomass,
        ),
    )
```

`PreviousTimeStep(:x)` removes the producer-to-consumer edge from the current
timestep graph and reads the latest source sample at or before the previous
scene timestep. Before a source sample exists, the initialized consumer status
value for `x` is used. This makes initialization part of the scenario contract
instead of silently inventing a zero value.

### Model Calls

Use `Calls(...)` when a model must manually run selected models, typically
inside an iterative solver. This is the required public API name and must be
implemented as part of the unified scene/object redesign, not left as a later
rename.

```julia
ModelSpec(SceneEB()) |>
    Calls(:leaf_energy => Many(
        kind=:plant,
        scale=:Leaf,
        process=:energy_balance,
    )) |>
    Calls(:soil => One(kind=:soil, application=:soil_water))
```

Inside `run!`, the scene model receives call handles and calls
`run_call!(call)` during trial iterations, then
`run_call!(call; publish=true)` for the accepted final solution. The default is
deliberately `publish=false`: trial calls mutate target status for convergence
checks but do not append temporal samples or write environment outputs.

The important user rule is:

- `Calls(...)` means "give this model callable model handles";
- the parent model owns the call stack and can iterate, reject, or accept trial
  calls;
- call outputs are published only according to the call publication contract.

`explain_calls(compiled)` exposes this as
`publication_policy=:explicit_accept`, with `default_publish=false` and
`accepted_publish=true`.

Binding and call explanations also report where each dependency declaration
came from:

- `origin=:inferred_same_object` for compiler-inferred value dependencies;
- `origin=:model_default` for `Input(...)` or `Call(...)` declarations coming
  from `dep(model)`;
- `origin=:model_spec` for scenario-level `Inputs(...)` or `Calls(...)`,
  including declarations that override a model default.

### Multiplicity

Selection multiplicity is explicit:

```julia
One(...)
Many(...)
OptionalOne(...)
```

`OptionalOne(...)` resolves to zero or one dependency. With zero matches, an
input keeps its `inputs_` default and a call returns an empty
`call_targets(...)` collection. Explanations retain these unresolved
optional bindings instead of hiding them.

The compiler validates that `One(...)` resolves to exactly one producer per
consumer scope. `Many(...)` returns a vector-like value or target collection.

### Address Normalization

All source and target declarations normalize to an internal address:

```julia
ObjectAddress(
    scope,
    kind,
    species,
    scale,
    name,
    process,
    var,
    relation,
    multiplicity,
)
```

Only the compiler works with this normalized address. Users should not need to
construct it manually.

## Object Lifecycle And Spatial Contracts

Growth, pruning, organ creation, reparenting, and moving organs must all update
the same compiled caches:

- object selections used by `AppliesTo`, `Inputs`, and `Calls`;
- `RefVector` or equivalent many-object carriers;
- temporal stream ownership;
- writer validation;
- environment bindings.

The public mutation API should make cache invalidation explicit and centralized:

```julia
register_object!(scene, object; parent)
remove_object!(scene, object)
reparent_object!(scene, object, new_parent)
move_object!(scene, object, geometry_or_position)
Advanced.refresh_bindings!(scene)
```

Spatial environment backends should depend on a small geometry contract, not on
a particular plant representation:

```julia
position(object_or_status)
geometry(object_or_status)
bounds(object_or_status)
```

Packages can provide richer geometry, octrees, voxel grids, or layers, but
PlantSimEngine should only require enough information to bind an object to an
environment provider.

## Duplicate Writers And Updates

Most variables should have one canonical writer per object and timestep. When a
variable is intentionally updated by several models, the scenario should say so
where the model applications are assembled:

```julia
ModelSpec(PruningModel()) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Updates(:leaf_biomass; after=:carbon_allocation)
```

`Updates(...)` should be rare and explicit. It is a scenario-level ordering
rule, because a model author cannot predict every model that will later update
the same variable.

## Environment And Microclimate

Meteorology should remain automatic unless a model or scenario needs special
behavior. Models declare environment variables:

```julia
meteo_inputs_(::LeafEnergyModel) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    Ri_PAR_f=0.0,
    CO2=0.0,
)
```

The runtime resolves those variables through the scene environment service.

Default resolution:

1. A global/table meteo backend gives every object the current meteo row.
2. A voxel, octree, layered, or grid backend samples the cell bound to the
   object.
3. If the object has no position, use the parent position.
4. If no spatial binding can be made, fall back to global meteo or error when
   the environment variable is required.

Users can override the binding contract:

```julia
EnvironmentResolver(
    bind=(scene, object) -> containing_cell(scene.microclimate, position(object)),
)
```

PlantSimEngine should define the protocol and caching hooks, not the voxel or
octree implementation. Specialized packages should provide concrete spatial
backends.

The environment backend protocol should be small and backend-oriented:

```julia
Advanced.bind_environment(scene, backend, object)
sample_environment(backend, binding, time, variables)
scatter_environment!(backend, binding, values)
refresh_environment!(backend, scene)
```

`meteo_inputs_(model)` declares what a model reads from the active environment
provider. `meteo_outputs_(model)` declares what a model can write back to a
mutable microclimate provider. Simple global meteorology remains the default
provider.

Scenario-level environment source remapping belongs on `Environment(...)`, for
example:

```julia
ModelSpec(LeafGasExchange(); name=:gas_exchange) |>
    AppliesTo(Many(scale=:Leaf)) |>
    Environment(provider=:global, sources=(CO2=:Ca,))
```

Here the model still reads `meteo.CO2` because that is its declared generic
contract, while the active environment backend samples the source variable
`:Ca`. Environment binding refresh validates source availability when the
backend can enumerate variables, and explanations report both
`required_inputs` and `source_inputs`.

Global tabular meteorology follows the model application's compiled
`TimeStep(...)`. PlantMeteo samples the table with the reducer and window from
`meteo_hint(...)` when the model runs more slowly than the weather base step.
An `Environment(; sources=...)` override replaces only the source variable; it
does not discard the model-author reducer. The prepared weather sampler is
compiled once, and one sampled row is reused by every object targeted by the
same application at that timestep.

Spatial or mutable backends retain control of their own temporal semantics.
PlantSimEngine supplies the compiled object/cell binding and current simulation
time; a specialized microclimate backend decides whether its local state is
instantaneous, interpolated, or internally integrated.

### Cached Environment Bindings

Spatial lookup must not happen for every model call. At initialization and when
objects are created, the runtime builds an environment binding cache:

```julia
EnvironmentBinding(
    object_id,
    provider=:microclimate_grid,
    cell_id,
    variables=(:T, :Rh, :Wind, :Ri_PAR_f),
)
```

Runtime sampling is:

```text
object -> cached binding -> environment cell -> current values
```

Invalidation events:

- object created;
- object removed;
- object moved;
- geometry changed;
- environment grid rebuilt or refined;
- model environment requirements changed.

Geometry APIs should provide ergonomic invalidation:

```julia
mark_environment_binding_dirty!(scene, object)
update_geometry!(object, geometry; invalidate_environment=true)
```

Before each timestep, dirty bindings are refreshed in batch.

## Compilation Strategy

The compiler should build one global dependency graph over object addresses.
The graph includes:

- value dependencies from `Inputs(...)`;
- callable dependencies from `Calls(...)`;
- model update edges from `Updates(...)`;
- temporal policy edges;
- environment reads and writes;
- object-scope selection caches.

The runtime representation is an implementation detail:

- same-rate local links can stay as aliases;
- cross-rate links use temporal state;
- many-object links use `RefVector` or node-value streams;
- call links use `ModelCall` or an equivalent callable runtime handle;
- environment links use cached `EnvironmentBinding`s.

The final execution plan should group contiguous targets with the same concrete
model, status, model-bundle, input-binding, and environment-binding types.
Dynamic dispatch may occur once at the application/batch boundary, but not for
every leaf in a homogeneous target set. Exceptional model overrides form
separate concrete batches while preserving stable object order. Lifecycle or
environment refreshes rebuild these batches before the next timestep.

The public explanation API must describe the normalized graph, not the internal
carrier choice.

## Agent-Facing Requirements

The final design must be understandable by agents through structured
explanation helpers:

```julia
explain_objects(scene)
explain_instances(scene)
explain_scopes(scene)
explain_bindings(sim)
explain_calls(sim)
explain_environment_bindings(sim)
explain_schedule(sim)
explain_writers(sim)
explain_execution_plan(sim)
explain_output_retention(sim)
```

These helpers should return stable structured data, not only pretty text. A
binding row should include at least:

- consumer application id;
- consumer object id;
- consumer variable;
- source selector;
- resolved producer application id or environment provider id;
- resolved producer object ids;
- process/name filters;
- temporal policy and window;
- carrier kind;
- copy/reference semantics;
- reason the binding was chosen;
- whether it came from inference, `dep(model)`, or `ModelSpec`.

Execution-plan rows should additionally expose the selected object ids,
concrete model/status/carrier types, batch size, and whether the inner loop is
homogeneous and specialized.

Output-retention rows should expose the retained application id, variable,
retention reasons, compiled retention horizon, and current target count so
agents can distinguish default retain-all behavior, requested output streams,
and bounded temporal-dependency streams.

Errors should report concrete object labels, scope selectors, process names,
variables, and suggested fixes.

## API Position

This is a breaking design. It preserves model kernels and the
`run!(model, models, status, meteo, constants, extra)` contract while replacing
the scenario configuration surface with `Scene`, `Object`, `ModelSpec`,
selectors, `Inputs(...)`, `Calls(...)`, `TimeStep(...)`, and
`Environment(...)`.
