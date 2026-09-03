# Model Execution

This page describes how the native composite-model/object runtime executes model
applications. Use this path for new multi-object, multi-plant, soil,
microclimate, and multirate simulations.

The public configuration surface has one application constructor:

```julia
ModelSpec(
    model;
    name=:application,
    on=Many(scale=:Leaf),
    inputs=(...),
    calls=(...),
    every=Dates.Hour(1),
    environment=Environment(...),
    output_routing=(...),
    updates=Updates(...),
)
```

Scenarios start from `CompositeModel` and model applications.

## Model Kernels And Applications

A model kernel is still an ordinary PlantSimEngine model:

- `inputs_(model)` declares each status input as `Required(T)` or
  `Default(value)`;
- `outputs_(model)` declares variables the model computes and their initial
  output-state values;
- `environment_inputs_(model)` declares environment variables it reads;
- `commit_environment!(context, state)` commits accepted mutable environment
  state when the model intentionally controls microclimate;
- `dep(model)` may declare model-author defaults;
- `run!(model, status, environment, constants, context)` contains the model
equations.

`Required(T)` has no initialization value: object state or a producer
application must satisfy it. `Default(value)` is installed only when the target
does not already have the input. Plain input literals are rejected because
they are ambiguous.

The composite-model/object layer does not change that kernel contract. It adds a
scenario-specific application around the kernel:

```julia
ModelSpec(
    LeafEnergyBalance();
    name=:leaf_energy,
    on=Many(kind=:plant, scale=:Leaf),
    inputs=(...),
    calls=(...),
    every=Dates.Hour(1),
    environment=Environment(provider=:canopy),
)
```

`ModelSpec` decides where the model runs, where its inputs come from, which
models it may call manually, which timestep it uses, and which environment
provider is bound to it. The model implementation stays reusable.

## Compilation Before Runtime

Before the timestep loop, PlantSimEngine compiles the model into concrete
runtime carriers:

1. `ModelSpec(...; on=...)` selectors are resolved to stable object ids.
2. `ModelSpec(...; inputs=...)` selectors are resolved to source object/application ids.
3. Same-rate inputs are wired as shared `Ref`s, `RefVector`s, or
   heterogeneous object-reference vectors.
4. Temporal inputs are compiled as stream lookups with a policy such as
   `HoldLast`, `Interpolate`, `Integrate`, or `Aggregate`.
5. `ModelSpec(...; calls=...)` declarations are compiled to callable target lists.
6. `Environment(...)` is bound to backend cells, layers, voxels, or global
   weather providers.
7. The root application order is topologically sorted from value inputs and
   `Updates(...)` ordering.
8. Root execution batches are grouped by concrete model/status/environment
   types where possible.

Selectors are not resolved in the hot loop. Runtime execution uses the
compiled indexes and carriers.

Useful inspection helpers:

```julia
Diagnostics.explain_applications(model)
Diagnostics.explain_bindings(model)
Diagnostics.explain_calls(model)
Diagnostics.explain_environment_bindings(model)
Diagnostics.explain_schedule(model)
Diagnostics.explain_execution_plan(model)
Diagnostics.explain_writers(model)
```

These explanations are intended for both users and agents. They report the
compiled object ids, applications, carriers, clocks, environment bindings, and
manual-call targets that the runtime will use.

### Readable source views

PlantSimEngine exposes two deliberately different source views. Reconstruct an
editable scenario declaration with:

```julia
scenario_code = Authoring.scenario_source(
    model;
    environments=(weather=weather,),
)
```

The `environments` catalog names runtime values that generated code must refer
to rather than attempt to serialize. For code review or agent inspection,
generate an executable Julia view of the resolved plan instead:

```julia
source = Authoring.compiled_model_source(model)
Authoring.write_compiled_model_source("compiled_model.jl", model)
```

The generated source spells out application order, selected targets, input
provenance, hard calls, and the kernel bodies invoked through normal
PlantSimEngine status, environment, output, and lifecycle machinery. It is
optimized for explanation and review, not as an alternative scheduler. It
represents the resolved plan; `scenario_source` reconstructs the scenario that
an author can edit and compile again.

## Soft Dependencies With Inputs

Soft dependencies are value dependencies. A consumer model reads a variable
produced by another model through `ModelSpec(...; inputs=...)`.

```julia
ModelSpec(SceneLAI(ground_area); name=:scene_lai, on=One(scale=:Scene), inputs=(:leaf_areas => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:leaf_state,
            var=:leaf_area,
        ),))
```

For same-rate inputs, the runtime installs a reference carrier into the
consumer status during compilation. A model-scale model reading all leaf areas
therefore sees a `RefVector`-like object: reading pulls current values from
source leaf statuses, and writing through the carrier mutates source refs when
the carrier supports it.

If an input is not explicitly declared with `ModelSpec(...; inputs=...)`, the compiler can
infer simple same-object bindings when exactly one producer on the same object
outputs the same variable. Ambiguous producers are errors and should be
disambiguated with `application=...` and, when names differ, `var=...`.

Use `PreviousTimeStep(:x) => selector` when a feedback dependency should read
the previous sample instead of creating a same-timestep scheduling edge.

## Hard Calls With Calls

Hard dependencies are manual calls. Use `ModelSpec(...; calls=...)` when a parent model must
control the call stack, for example during an iterative energy-balance solve.

```julia
ModelSpec(SceneEnergyBalance(); name=:scene_energy, on=One(scale=:Scene), calls=(:leaf_energy => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:energy_balance,
        ),
        :soil => One(
            kind=:soil,
            scale=:Soil,
            within=SceneScope(),
            application=:soil_water,
        ),), every=Dates.Hour(1))
```

Inside `run!`, the parent can execute every resolved target directly. The
return value is always vector-like: `One` returns one element, `OptionalOne`
returns zero or one, and `Many` returns zero or more.

```julia
soil_targets = run_call!(context, :soil; publish=true)
soil_status = only(soil_targets).status
```

For finer-grained iterative control, retrieve targets without executing them
and decide when to publish the accepted state:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, status, environment,
                             constants, context)
    trial = trial_environment(model, status)
    run_call!(context, :leaf_energy; environment=trial, publish=false)

    accepted = accepted_environment(model, status)
    commit_environment!(context, accepted)
    run_call!(context, :leaf_energy; publish=true)

    return nothing
end
```

`run_call!` defaults to `publish=false`. Trial calls mutate target statuses but
do not publish temporal samples or commit mutable environment updates. Use
`environment=trial_state` when hard-called descendants should sample temporary
state through their compiled environment handles. Call `commit_environment!` and
`run_call!(...; publish=true)` once for the accepted state.

Applications selected only by `ModelSpec(...; calls=...)` are marked manual-call-only in
`Diagnostics.explain_schedule(model)` and are skipped by the root `run!(model)` loop.

## Duplicate Writers With Updates

By default, one application owns each `(object, output variable)` canonical
writer. If a scenario intentionally lets several models update the same
variable, later writers must declare that order explicitly:

```julia
ModelSpec(CarbonAllocation(); name=:carbon_allocation, on=Many(scale=:Leaf))

ModelSpec(LeafPruning(); name=:leaf_pruning, on=Many(scale=:Leaf), updates=Updates(:leaf_biomass; after=:carbon_allocation))
```

This keeps ordinary duplicate outputs as errors while allowing cases such as
allocation followed by pruning. `Diagnostics.explain_writers(model)` reports writer
groups and the `Updates(...)` declarations that validate them.
The `after` value is the canonical application identifier shown by
`Diagnostics.explain_applications(model)`, not the process name.

## Multirate Execution

Use `ModelSpec(...; every=...)` with `Dates.Period` values for model application clocks:

```julia
ModelSpec(HourlyLeafAssimilation(); name=:leaf_assim, on=Many(scale=:Leaf), every=Dates.Hour(1))

ModelSpec(DailyPlantAllocation(); name=:allocation, on=Many(scale=:Plant), inputs=(:leaf_assimilation => Many(
            scale=:Leaf,
            within=Subtree(),
            application=:leaf_assim,
            var=:A,
            policy=Integrate(),
            window=Dates.Day(1),
        ),), every=Dates.Day(1))
```

Clock precedence is:

1. explicit `ModelSpec(...; every=...)` on the `ModelSpec`;
2. non-default `timespec(model)` trait;
3. the model environment base step.

`timestep_hint(model)` is a compatibility constraint and explanation hint. It
does not silently choose a clock. If a model uses the environment base step and
that step violates `timestep_hint.required`, model compilation errors.

Temporal input policy precedence is:

1. explicit selector policy, such as `policy=Integrate()`;
2. producer `output_policy(model)` for that output;
3. `HoldLast()`.

Supported policies are:

- `HoldLast()`: use the latest producer sample;
- `Interpolate()`: interpolate or extrapolate from producer samples;
- `Integrate()`: reduce values over a window, defaulting to `SumReducer()`;
- `Aggregate()`: reduce values over a window, defaulting to `MeanReducer()`.

`Integrate(...)` and `Aggregate(...)` accept reducer objects or callables that
take either `(values)` or `(values, durations_seconds)`.
For duration-aware reducers, each producer value is held until the next
producer execution and weighted by the portion of that interval overlapping
the consumer window. This includes the last value published before the window
when it remains active inside the window.

Temporal windows are duration-based rolling windows. Calendar-aligned civil
days and "previous complete period" selection are not part of the public API;
there is no `CalendarWindow` compatibility type.

## Environment Sampling

`Environment(...)` chooses a provider and optional source-variable remapping:

```julia
ModelSpec(CO2Probe(); name=:co2_probe, on=Many(scale=:Leaf), environment=Environment(provider=:canopy, sources=(CO2=:Ca,)))
```

The compiler binds each application/object pair to the selected backend before
runtime. Constant weather, global tabular meteorology, grid, layer, voxel, or
octree-style microclimate backends all use the same contract:

- `environment_inputs_(model)` says what the model reads;
- `environment_outputs_(model)` says what the model may commit;
- `commit_environment!(context, accepted_environment)` commits accepted mutable
  meteorology from a controller model;
- `run_call!(context, name; environment=trial_state)` exposes non-committing
  trial state while preserving every target's compiled backend handle;
- `Environment(; sources=...)` maps model-facing names to backend names;
- geometry and position are used by spatial backends when available;
- object-to-environment links are cached and refreshed when objects move.

Backend authors implement an opaque-handle protocol:

```julia
handle = EnvironmentAPI.bind_environment(backend, object, context, config)

EnvironmentAPI.sample(backend, handle, variable, time)               # committed state
EnvironmentAPI.sample(backend, handle, trial_state, variable, time)  # transient state
commit_environment!(backend, handle, accepted_state, time)
```

`EnvironmentAPI.EnvironmentContext` identifies the application, object, scale, and process
while the handle is compiled. Runtime status and geometry are not passed to
sampling: a spatial backend resolves them once in `EnvironmentAPI.bind_environment` and stores
the resulting provider, layer, voxel, or other routing data in its concrete
handle. A controller that reads from one provider and commits to another should
encode both routes in the handle, for example
`Environment(provider=:forcing, sink=:canopy)`.

Model-level `environment_hint(...)` can provide default source bindings and
aggregation rules. Scenario-level `Environment(...)` keeps precedence for
source names, while explicit sampling policy on `ModelSpec(...; inputs=...)` controls
model-to-model temporal values.

## Running And Outputs

Run a model with:

```julia
sim = run!(model; steps=30)
```

The returned `Simulation` contains the mutated model, compiled bindings,
environment bindings, execution plan, and retained temporal output streams.

By default, model runs retain no user output streams. Pass `outputs=:all` to
retain every published stream, or pass `OutputRequest` values to retain only
selected outputs and required temporal dependency streams:

```julia
request = OutputRequest(
    Many(scale=:Leaf),
    :A;
    name=:leaf_assimilation_daily,
    application=:leaf_assimilation,
    policy=Integrate(),
    clock=Dates.Day(1),
)

sim = run!(model; steps=72, outputs=request)
collect_outputs(sim, :leaf_assimilation_daily; sink=nothing)
Diagnostics.explain_output_retention(sim)
```

When several applications publish the same process and variable, use
`application=:application_name` in the request. This selects the named
application directly and can also request an explicitly named
`:stream_only` publisher.

`outputs=:none` retains no user output streams. Histories required by temporal
dependencies are still maintained with bounded retention.

`run!(model; ...)` always starts a fresh result timeline. Continue an existing
simulation without resetting its step index, environment position, multirate
phase, or temporal histories with:

```julia
continue!(sim; steps=24)
step!(sim)
current_step(sim)
```

Temporal dependency streams that are not explicitly requested retain only the
history required by their input policy. `HoldLast` keeps the latest sample,
`Integrate` and `Aggregate` keep their input window, and `Interpolate` and
`PreviousTimeStep` keep sufficient recent source samples. Requested streams
retain complete histories for post-run export. `Diagnostics.explain_output_retention(sim)`
reports `retention_steps` for bounded dependency-only streams and `nothing`
for full-history streams.

## Lifecycle Changes

CompositeModel objects may be added, removed, reparented, moved, or have their geometry
updated between or during timesteps:

```julia
register_object!(model, Object(:new_leaf; scale=:Leaf); parent=:plant_1)
leaf_status = add_organ!(
    parent_node,
    model,
    :+,
    :Leaf,
    3;
    index=4,
    attributes=(area=0.01,),
    initial_status=(biomass=0.0,),
)
remove_object!(model, :old_leaf)
reparent_object!(model, :leaf_3, :plant_2)
move_object!(model, :leaf_4, new_geometry)
update_geometry!(model, :leaf_5, new_geometry)
```

Use `add_organ!` for an MTG-backed model. It creates the MTG node, initializes
and attaches its `Status`, registers the model object, and invalidates the
affected bindings. By default, status initialization reuses the model's MTG
policy. A framework that already supplies the complete creation attributes and
initial status may set `use_status_adapter=false`; doing so is an explicit
assertion that the configured status accessor contributes no additional fields
or side effects for that node. `register_object!` is the low-level operation
for callers that already own a complete `Object`.

Structural changes invalidate compiled object/model bindings. Movement and
geometry changes invalidate environment bindings without rebuilding structural
input carriers. Scenario-level application, dependency, selector, cadence,
environment-sampling, and output-retention plans remain immutable; only the
affected object targets and buffers are refreshed.

Do not mutate `Object` topology, labels, or geometry fields directly. Direct
field mutation bypasses registry indexes and cache invalidation and is
unsupported. Use the lifecycle functions above. They validate prerequisites
before mutating; in particular, `reparent_object!` rejects self-parenting and
descendant cycles without changing existing links. `ObjectInstance` roots are
immutable lifecycle anchors: removing or reparenting a root, or an ancestor
whose subtree contains one, is rejected atomically. Ordinary descendants may
still be added, removed, or reparented.

Inside a lifecycle-capable model kernel, use `runtime_model(context)` to obtain
the live model. Objects created during a kernel call do not recursively execute
inside that call. At the safe barrier after the mutating application,
PlantSimEngine refreshes affected structural targets, value carriers, hard-call
targets, writer validation, temporal storage, execution groups, output-request
matches, and environment handles. A new object can therefore run an application
that remains later in the same timestep. It does not retroactively run an
application that already completed unless its creator declares that application
as an [`Initializer`](@ref) and explicitly calls [`run_initializer!`](@ref) on
the newborn object. Already published streams remain available for removed
objects.
