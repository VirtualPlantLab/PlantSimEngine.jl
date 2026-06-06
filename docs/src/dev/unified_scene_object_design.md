# Unified Scene/Object Design

This page records the target breaking design discussed after the multi-domain
prototype. It intentionally supersedes the user-facing distinction between
`MultiScaleModel(...)` mappings and `Route(...)` cross-domain materialization.

The central idea is:

> Domains and scales are not fundamentally different concepts. They are both
> selections over objects in one scene.

The engine should expose one way to say "this model input comes from these
objects" and one way to say "this model must manually call these models". The
compiler can then choose whether the runtime carrier is a `Ref`, `RefVector`,
temporal stream, route materialization, or callable model handle.

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

`Self()` means the current model application object or scope. It does not
always mean "the current plant". If a model runs on a `:Plant`, `Self()` means
that plant object or subtree. If a model runs on an `:Axis`, it means that axis.
If a model runs on a `:Leaf`, it means that leaf. If a model runs on the scene
object, it means the scene object/scope.

`SelfPlant()` is the nearest containing plant scope. The more generic form is
`Ancestor(scale=:Plant)`. Use these when a model running below the plant scale
must access siblings or state inside the containing plant.

Reusable plant models should default to scope-relative queries. If an
allocation model is applied to each `:Plant`, `Many(scale=:Leaf, within=Self())`
means "the leaves inside this plant", not all leaves in the scene. The same
query applied to an axis-scale model would mean "the leaves inside this axis".

Scene-level models widen the scope explicitly with `within=SceneScope()`.

### Object Template And Instance

An object template is a reusable model/parameter bundle, for example one oil
palm species model. An object instance is one concrete object in the scene.

The same template can be mounted several times:

```julia
oil_palm = ObjectTemplate(
    kind=:plant,
    species=:oil_palm,
    mapping=oil_palm_mapping,
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

`ModelSpec` should become the single scenario wrapper. `MultiScaleModel(...)`,
`AllDomains(...)`, `HardDomains(...)`, and user-written `Route(...)` should be
replaced by explicit value inputs and callable model calls.

### Applies To

Use `AppliesTo(...)` to declare the object set where a model application runs.
This should be first-class, not inferred from a domain or mapping key.

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
new design, `dep(model)` becomes the model-level place for default dependency
intent, for both the current `ModelMapping` use case and the future scene/object
runtime.

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
    leaf_carbon = Input(Many(scale=:Leaf, within=Self(), var=:leaf_carbon)),
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
    Inputs(:leaf_carbon => Many(scale=:Leaf, within=Self(), var=:leaf_carbon))
```

The same declaration must compile to:

- direct `Ref`/`RefVector` wiring when producer and consumer live in the same
  object graph and rate;
- temporal stream reads when producer and consumer run at different rates;
- current route materialization when target status must be assigned before a
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
| route-like target status input | compiler-generated materialization | assigned before consumer run |
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
        within=Self(),
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
    Calls(:soil => One(kind=:soil, process=:soil_water))
```

Inside `run!`, the scene model receives call handles and calls
`run_call!(call; publish=false)` during trial iterations, then
`publish=true` for the accepted final solution.

The important user rule is:

- `Calls(...)` means "give this model callable model handles";
- the parent model owns the call stack and can iterate, reject, or accept trial
  calls;
- call outputs are published only according to the call publication contract.

### Multiplicity

Selection multiplicity is explicit:

```julia
One(...)
Many(...)
OptionalOne(...)
```

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
refresh_bindings!(scene)
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
bind_environment(scene, backend, object)
sample_environment(backend, binding, time, variables)
scatter_environment!(backend, binding, values)
refresh_environment!(backend, scene)
```

`meteo_inputs_(model)` declares what a model reads from the active environment
provider. `meteo_outputs_(model)` declares what a model can write back to a
mutable microclimate provider. Simple global meteorology remains the default
provider.

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

Errors should report concrete object labels, scope selectors, process names,
variables, and suggested fixes.

## Compatibility Position

This is a breaking target design. It should preserve model kernels and the
`run!(model, models, status, meteo, constants, extra)` contract when possible,
but it may replace the scenario configuration surface:

- `MultiScaleModel(...)` becomes `Inputs(...)`;
- `Route(...)` becomes a compiler-generated carrier for `Inputs(...)`;
- `AllDomains(...)` becomes a selector used inside `Inputs(...)`;
- `HardDomains(...)` becomes `Calls(...)`;
- `Domain(...)` becomes an object scope/template/instance concept;
- `InputBindings(...)` becomes explicit policy and source information on
  `Inputs(...)`;
- `MeteoBindings(...)` becomes automatic environment binding plus optional
  `Environment(...)` overrides;
- `OutputRouting(...)` remains model-application output configuration or is
  folded into a clearer output policy modifier;
- `PreviousTimeStep(...)` remains a temporal policy/cycle-breaking marker in
  the unified graph.
