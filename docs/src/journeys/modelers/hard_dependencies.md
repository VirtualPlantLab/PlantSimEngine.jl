# Implement A Hard Dependency

Sometimes a model needs to decide when, or how often, another model runs.
For example, an energy-balance calculation may evaluate gas exchange at
several trial temperatures before accepting a solution. PlantSimEngine calls
this a **hard dependency**, or a **manual call**. The model managing these
calls is a **controller**.

When a model only needs another model's result, use an ordinary input instead.
[Coupling models](@ref) helps choose between the two. This page first runs a
small controller, then explains its implementation. If you are new to writing
models, start with [Implement a basic model](@ref). [Understand Environments](@ref)
introduces the local cells and object locations used here.

## Choose which models the controller can call

The example has one plant with two leaves. A controller on the plant starts
from the weather temperature, calls one leaf's temperature reader, and adds
1 °C until the reader reports a value strictly above 22 °C. It then saves
that accepted result.

This is deliberately a **toy iteration**, not a physical temperature model.
A real energy-balance solver would calculate each new temperature from its
equations and stop when its convergence criterion is met. The fixed increment
makes this example reproducible.

| Component | Role in this example |
| --- | --- |
| `ToySelectiveCallControllerModel` | Chooses one leaf by ID, tries temperatures, and decides when to save a result. |
| `ToyEnvironmentReaderModel` | Reads `environment.T` and copies it to `status.temperature_seen`. It stands in for the calculation a real solver would call. |
| `ToySpatialEnvironment` | Supplies each leaf's usual temperature from a named cell. It is a data provider, not a process model. |

The global weather supplies the controller's starting temperature, 20 °C.
The reader normally gets 26 °C in the sun cell and 18 °C in the shade cell.
During a trial, the controller supplies a temporary temperature directly to
the reader; we will look at that code below.

`calls` gives the controller a call named `readers`. `Many` selects the
`:reader` application on all leaves below the plant. Both leaves are
available to the controller, which will choose `:sun_leaf` at runtime.
Because the readers are used only through these calls, the simulation does
not also run them independently.

```@example modeler_hard_dependency
using Test, Dates, DataFrames, PlantSimEngine
using PlantSimEngine.Examples

controller = ToySelectiveCallControllerModel(
    increment=1.0, threshold=22.0, max_iterations=100,
    selected_object=:sun_leaf,
)
weather = (T=20.0, duration=Dates.Hour(1))
environment = ToySpatialEnvironment(
    Dict(:sun => (T=26.0,), :shade => (T=18.0,));
    step_seconds=3600.0,
)
model = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:sun_leaf; scale=:Leaf, parent=:plant, geometry=(cell=:sun,)),
    Object(:shade_leaf; scale=:Leaf, parent=:plant, geometry=(cell=:shade,));
    applications=(
        ModelSpec(
            ToyEnvironmentReaderModel();
            name=:reader, on=Many(scale=:Leaf),
            environment=Environment(backend=environment),
        ),
        ModelSpec(
            controller;
            name=:controller, on=One(scale=:Plant),
            calls=(
                :readers => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:reader,
                ),
            ),
        ),
    ),
    environment=weather,
)
nothing # hide
```

A **target** is one selected model application on one object. Here there are
two targets: the reader on the sun leaf and the reader on the shade leaf.
Check that selection before running the simulation:

```@example modeler_hard_dependency
select(
    DataFrame(Diagnostics.explain_calls(model)),
    :application_id,
    :call,
    :callee_application_ids,
    :callee_object_ids,
    :publication_policy,
)
```

## Run the controller and inspect the result

```@example modeler_hard_dependency
simulation = run!(model; outputs=:all)
accepted = final_state(simulation, :plant)
@test accepted.target_count == 2 # hide
@test accepted.initial_temperature == 20.0 # hide
@test accepted.iterations == 4 # hide
@test accepted.accepted_temperature_seen == 23.0 # hide
@test final_state(simulation, :sun_leaf).temperature_seen == 23.0 # hide
@test final_state(simulation, :shade_leaf).temperature_seen == 0.0 # hide
@test environment.cells[:sun].T == 26.0 # hide
@test environment.cells[:shade].T == 18.0 # hide
(
    initial=accepted.initial_temperature,
    iterations=accepted.iterations,
    accepted=accepted.accepted_temperature_seen,
)
```

Starting from 20 °C, the controller evaluated 20, 21, 22, then 23 °C.
The first three values did not exceed 22 °C; the fourth did. These four trial
calculations were not recorded. The controller then repeated the accepted
calculation at 23 °C to save one result. The shade leaf's reader did not run:

```@example modeler_hard_dependency
reader_outputs = filter(
    row -> row.application_id == :reader,
    DataFrame(Diagnostics.explain_outputs(simulation)),
)
@test Dict(row.object_id => row.nsamples for row in eachrow(reader_outputs)) == # hide
      Dict(:sun_leaf => 1, :shade_leaf => 0) # hide
select(reader_outputs, :object_id, :variable, :nsamples)
```

Passing a trial temperature and publishing a result do not change the stored
spatial temperatures: the cells still contain 26 and 18 °C. To save accepted
conditions back to the environment with `commit_environment!`, continue with
[Modify The Environment](@ref).

## Declare defaults for a reusable controller

The scenario above chooses the reader application explicitly. When writing a
controller, you can also declare which process it needs by default, without
knowing the application names that future simulations will use.

This controller's `dep` method provides a call named `readers`. It asks for
models of the `:toy_environment_reader` process on leaves below the current
object. The definition below is read from `examples/ToyAdvancedControl.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "PlantSimEngine.dep(::ToySelectiveCallControllerModel)",
    "function PlantSimEngine.outputs_",
)
```

`scale=:Leaf` chooses leaves, `process=:toy_environment_reader` chooses the
process, and `within=Subtree()` limits the search to the current object and
its descendants. Applied to a plant, the controller therefore finds that
plant's leaves. PlantSimEngine prepares this selection before execution;
the controller chooses which of those targets to call during its calculation.

You can omit `calls` from the scenario's controller `ModelSpec` to use this
default. Supplying `calls` replaces that choice for the named call. In our
example, both choices select the same two readers. This separates the
process the controller needs from the model application a scenario chooses.

## Write the loop inside the controller

The controller declares temperature as an environment input, so its kernel
can read the starting weather through `environment.T`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "PlantSimEngine.environment_inputs_(model::ToySelectiveCallControllerModel)",
    "PlantSimEngine.dep(::ToySelectiveCallControllerModel)",
)
```

`call_targets(context, :readers)` lists the available targets without running
them. The controller counts both leaves, then selects `:sun_leaf` by ID, so
changing their order would not change the selection. At each iteration,
`run_call!` passes a trial temperature directly to that reader through
`sampled_environment` and updates its current status.

The controller inspects `selected.status.temperature_seen`: above the
threshold, it publishes the same calculation and returns; otherwise, it adds
the increment and tries again. `max_iterations` stops the loop with an error
if no result is accepted. Here is the actual implementation:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "function PlantSimEngine.run!(\n    model::ToySelectiveCallControllerModel,",
    "\"\"\"\n    ToyStockWriterModel",
)
```

`publish=false` is the default. It lets the controller inspect each trial
without adding it to output history or time-based connections. It still
changes the target's current values, including values visible through direct
references: it does not undo a rejected trial. Here the reader simply
overwrites its temperature, so repeating the accepted call is harmless.
A real solver must handle any accumulated state explicitly.

## Choose the simplest call operation

| Your algorithm needs… | Use |
|---|---|
| To run all selected models and objects | `run_call!(context, :readers)` |
| To read one called model's parameters or type | `call_model(context, name)` for a call selecting one target |
| To choose objects, read their current values, or give them different trial values | `call_targets(context, :readers)`, then `run_call!(target)` |

`run_call!` returns a `CallTargets` collection, even when `One` selects one
target. `OptionalOne` returns zero or one target; `Many` returns zero or more.
`call_model` requires exactly one match and returns the model itself without
running it. Its `name` is the name of a declared call, not an application
name. The `:readers` call in our example selects two targets, so use
`call_targets` to choose a leaf instead.

There are two ways to supply trial conditions:

- `environment=trial_state` gives the provider a temporary environment from
  which each target reads its own local values. Use it when a trial canopy
  temperature field gives different temperatures to different leaves.
- `sampled_environment=value` passes values you have already chosen, such as
  `(T=22.0,)`, directly to the called model, without asking the provider to
  sample them. This is what our controller uses.

With `run_call!(context, name; ...)`, either form runs all selected targets
together. Use `call_targets` followed by `run_call!(target; ...)` when you need
to choose individual targets, change their order, or inspect their status.

When objects are added, removed, or moved to a different parent through the
PlantSimEngine functions, the selection is updated. Use these call functions
so your controller uses the updated selection. [Manual Calls Across Objects](@ref)
covers calls during growth and initializing newly created objects.
