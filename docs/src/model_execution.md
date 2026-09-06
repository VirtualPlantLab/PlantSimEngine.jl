# Model Execution

This reference explains how PlantSimEngine prepares and runs a simulation.
Start with [your first simulation](journeys/users/one_object.md) if you are
new to the package.

A **model application** says where to run a model and how to supply its
inputs. Use `ModelSpec` to describe one:

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

Put these applications and the objects they describe into a `CompositeModel`.

## Model Kernels And Applications

A **kernel** is the `run!` function that evaluates a model's equations.
The model also declares what those equations need and produce:

- `inputs_(model)` declares each status input as `Required(T)` or
  `Default(value)`;
- `outputs_(model)` declares variables the model computes and their initial
  output-state values;
- `environment_inputs_(model)` declares environment variables it reads;
- `environment_outputs_(model)` declares which environmental variables it
  may update, such as the temperature controlled by a canopy model;
- `commit_environment!(context, state)` commits accepted mutable environment
  state when the model intentionally controls microclimate;
- `dep(model)` may declare model-author defaults;
- `run!(model, status, environment, constants, context)` contains the model
equations.

`Required(T)` means you must supply the input on the object, or connect it
to another model's output. `Default(value)` supplies a starting value only
when that input is absent. A plain number is not a valid input declaration:
it would not say whether the model requires a value or can use a default.

The equations stay in the model. Use `ModelSpec` to configure their use in
this particular simulation:

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
source supplies its growing conditions. You can reuse the same model in
other simulations with different choices.

## Compilation Before Runtime

Before the first time step, PlantSimEngine prepares the simulation. This
preparation is called **compilation**. It:

1. finds the objects selected by each application's `on` rule;
2. finds where each input value will come from;
3. connects values updated at the same rate through shared references, which
   let one model read another object's current value without copying it;
4. prepares any output history and rules needed to exchange values between
   models that run at different time steps;
5. lists the models that each controller can call through `calls`;
6. finds the weather source, cell, or layer that supplies each object;
7. puts applications in order so their inputs are available when needed,
   including any order specified by `Updates`;
8. groups objects with matching model, status, and environment types so Julia
   can run them efficiently.

The time loop reuses this work instead of searching for every connection
again at each step.

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

These reports show which objects and models were selected, where their
inputs come from, when they run, and which growing conditions they receive.
Both people and coding agents can inspect the reports.

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

The generated code shows which models run on which objects, where their
inputs come from, and which equations and manual calls are used. It runs
through the normal PlantSimEngine machinery. Use this view to inspect
execution; use `scenario_source` when you want to edit the simulation setup.

## Soft Dependencies With Inputs

A **soft dependency** means that one model needs a value calculated by
another. The model supplying the value is called the **producer**; the model
reading it is the **consumer**. Connect them with `ModelSpec(...; inputs=...)`:

```julia
ModelSpec(SceneLAI(ground_area); name=:scene_lai, on=One(scale=:Scene), inputs=(:leaf_areas => Many(
            kind=:plant,
            scale=:Leaf,
            within=SceneScope(),
            application=:leaf_state,
            var=:leaf_area,
        ),))
```

When the models run at the same rate, the input refers to the source
object's current value. A plant model reading several leaf areas receives
a reference vector such as `RefVector`: a list that reads the current value
from each leaf. This shared storage is called a **reference carrier** in
the diagnostic reports. Where it supports writing, changing an entry also
changes the source object's value.

You can omit an input connection when exactly one other model on the same
object provides an output with the same name. PlantSimEngine connects it
automatically. If several models provide that output, choose one with
`application=...`. Use `var=...` when the source variable has a different name.

Use `PreviousTimeStep(:x) => selector` when a feedback calculation should
read the previous step's value of `x`. The receiving model then does not
need to wait for the current step's calculation of `x`.

## Hard Calls With Calls

A **hard dependency** means that one model decides when to run another.
Declare it with `ModelSpec(...; calls=...)`. For example, an energy-balance
model may need to run photosynthesis repeatedly while adjusting leaf
temperature.

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

`run_call!` uses `publish=false` by default. Each trial updates the called
objects' current values, but does not add results to their time histories or
save changes to the shared environment. Pass `environment=trial_state` to
try temporary growing conditions; each called model still gets the conditions
for its own location. Once the result is accepted, save the environment
with `commit_environment!` and run once with `publish=true` to record it.

Applications used only through `ModelSpec(...; calls=...)` run when their
controller calls them. They do not also run independently from the normal
schedule. `Diagnostics.explain_schedule(model)` marks them as manual-call-only.

## Duplicate Writers With Updates

Normally, only one model application may calculate a given output variable
on an object. If you want several models to update that variable, state
which should run first:

```julia
ModelSpec(CarbonAllocation(); name=:carbon_allocation, on=Many(scale=:Leaf))

ModelSpec(LeafPruning(); name=:leaf_pruning, on=Many(scale=:Leaf), updates=Updates(:leaf_biomass; after=:carbon_allocation))
```

This keeps ordinary duplicate outputs as errors while allowing cases such as
allocation followed by pruning. `Diagnostics.explain_writers(model)` reports writer
groups and the `Updates(...)` declarations that validate them.
For `after`, use the application ID shown by
`Diagnostics.explain_applications(model)`. A process name does not identify
a particular application when several models use that process.

## Multirate Execution

**Multirate** means that models run at different time steps. Set how often
a model runs with `ModelSpec(...; every=...)` and a duration such as `Hour(1)`:

The duration must be a positive integer multiple of the simulation base step.
Choose a finer common base step when needed; the scheduler does not insert
intermediate execution times. See [Give Models Different Cadences](@ref).

```julia
ModelSpec(HourlyLeafAssimilation(); name=:leaf_assim, on=Many(scale=:Leaf), every=Dates.Hour(1))

ModelSpec(DailyPlantAllocation(); name=:allocation, on=Many(scale=:Plant), inputs=(:leaf_assimilation => Many(
            scale=:Leaf,
            within=Subtree(),
            application=:leaf_assim,
            var=:A,
            policy=Integrate((values, durations_seconds) -> sum(values .* durations_seconds)),
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
- `Integrate()`: sum values over a window with `SumReducer()`, without
  duration weighting;
- `Aggregate()`: reduce values over a window, defaulting to `MeanReducer()`.

These rules combine numeric values but do not change the units or physical
meaning recorded in `VariableContract`. If you declare a rate on one side
and an amount on the other, use a conversion model with the appropriate
units and meaning declared for each side;
see [Coupling models](@ref).

`Integrate(...)` and `Aggregate(...)` accept reducer objects or callables that
take either `(values)` or `(values, durations_seconds)`.
For rates per second, use
`Integrate((values, durations_seconds) -> sum(values .* durations_seconds))`.
For real scalar rates, `Integrate(PlantMeteo.DurationSumReducer())` provides
the same operation; load `PlantMeteo` to use its named reducer.
For duration-aware reducers, each producer value is held until the next
producer execution and weighted by the portion of that interval overlapping
the consumer window. This includes the last value published before the window
when it remains active inside the window.

Time windows cover a duration relative to the current simulation time.
They do not automatically align with calendar days or select the previous
complete day, week, or month.

## Environment Sampling

`Environment(...)` chooses a provider and optional source-variable remapping:

```julia
ModelSpec(CO2Probe(); name=:co2_probe, on=Many(scale=:Leaf), environment=Environment(provider=:canopy, sources=(CO2=:Ca,)))
```

Before running, PlantSimEngine finds the environment source for each model
and object. An environment **backend** is the code that supplies those
conditions, from a weather table or a spatial representation such as soil
layers or canopy cells. All backends use the same model-facing functions:

- `environment_inputs_(model)` says what the model reads;
- `environment_outputs_(model)` says what the model may commit;
- `commit_environment!(context, accepted_environment)` commits accepted mutable
  meteorology from a controller model;
- `run_call!(context, name; environment=trial_state)` exposes non-committing
  trial state while preserving every target's compiled backend handle;
- `Environment(; sources=...)` maps model-facing names to backend names;
- geometry and position are used by spatial backends when available;
- object-to-environment links are cached and refreshed when objects move.

A backend first locates the data needed by an object and saves that location
in a **handle**. The model does not need to interpret this handle; the backend
uses it to retrieve values efficiently. Backend authors implement:

```julia
handle = EnvironmentAPI.bind_environment(backend, object, context, config)

EnvironmentAPI.sample(backend, handle, variable, time)               # committed state
EnvironmentAPI.sample(backend, handle, trial_state, variable, time)  # transient state
commit_environment!(backend, handle, accepted_state, time)
```

`EnvironmentAPI.EnvironmentContext` identifies the model application, object,
scale, and process when the backend prepares the handle. A spatial backend
uses `EnvironmentAPI.bind_environment` to locate the object's layer, cell, or
other data source and stores that location in the handle. Later requests for
environment values use this handle; they do not receive the object's full
status and geometry again. If a controller reads from one source and saves
updates to another, the handle must record both, for example
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

The returned `Simulation` keeps the current model values, the prepared
connections and schedule, and any saved output histories.

By default, model runs retain no user output streams. Pass `outputs=:all` to
retain every published stream, or pass `OutputRequest` values to retain only
selected outputs and required temporal dependency streams:

```julia
request = OutputRequest(
    Many(scale=:Leaf),
    :A;
    name=:leaf_assimilation_daily,
    application=:leaf_assimilation,
    policy=Integrate((values, durations_seconds) -> sum(values .* durations_seconds)),
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

Use `add_organ!` when the plant structure comes from an MTG. It creates the
node, prepares its starting values, adds the object to the simulation, and
marks its connections for updating. By default, it reuses the function you
provided to initialize values from MTG nodes.

Set `use_status_adapter=false` only if you supply all the new organ's
attributes and values yourself, and that initialization function has no
additional work to do. Use `register_object!` when you already have a fully
prepared `Object` to add.

Adding or removing objects can change which models run and where their
inputs come from, so PlantSimEngine updates the affected connections. Moving
an object or changing its shape updates its environment connection without
rebuilding unrelated model connections. The rules you supplied in the
simulation setup stay the same.

Use the functions above to change objects; assigning directly to their
structure, label, or geometry fields would leave PlantSimEngine's stored
connections out of date. The functions check each change before applying it.
For example, `reparent_object!` prevents an object from becoming its own
parent or a descendant of itself.

The root of an `ObjectInstance` must stay in place. You cannot remove or
reparent that root, or an ancestor whose descendants contain it. Rejected
operations leave the existing structure unchanged. You can still add,
remove, or reparent ordinary descendants of the instance root.

Inside a model's `run!` function, use `runtime_model(context)` to access the
simulation model when creating or changing objects. Creating an object does
not immediately run its models. After the application that made the change
finishes, PlantSimEngine updates the affected model selections, input and
environment connections, manual calls, output histories, and execution order.
It also checks that output variables still have valid sources. A new object can therefore run an application
that remains later in the same timestep. It does not retroactively run an
application that already completed unless its creator declares that application
as an [`Initializer`](@ref) and explicitly calls [`run_initializer!`](@ref) on
the newborn object. Already published streams remain available for removed
objects.
