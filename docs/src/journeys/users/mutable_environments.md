# Modify The Environment

A canopy energy-balance model may try several air temperatures before deciding
which temperature other models should use. A **controller** manages these
repeated calculations. **Committing** its solution means saving the accepted
conditions in the shared environment for later calculations.

This guide first shows how to configure and run an existing controller, then
explains its implementation. [Understand Environments](@ref) introduces
providers and local conditions; [Implement A Hard Dependency](@ref) explains
how one model calls another. Read those pages first if these ideas are new.

Here the controller starts at 20 °C and adds 1 °C until a reader returns a
value strictly above 22 °C. These arbitrary choices make the example easy to
follow. It is not a physical temperature model: a real solver would calculate
new estimates from its equations and stop when a convergence criterion is met.

The example uses three types from `PlantSimEngine.Examples`:

| Type | Role |
| --- | --- |
| `ToySpatialEnvironment` | Stores environmental values in named cells. It supplies temperatures and can save an accepted temperature. It is a data provider. |
| `ToyEnvironmentReaderModel` | Copies `environment.T` to `status.temperature_seen`. It does not calculate or change the temperature. |
| `ToyEnvironmentControllerModel` | Calls the reader repeatedly, checks its result, and commits the accepted temperature. |

## Create the provider and the two models

Use one weather observation to initialize a cell named `:canopy` at 20 °C.
A cell is just a named entry in the dictionary here; this example has no 3D
mesh. `step_seconds=3600.0` sets an hour-long time step, and this toy provider
supplies one step. The controller reads its starting temperature from this
cell; committing later changes the cell, leaving the original weather
observation unchanged.

```@example modeler_mutable_environment
using Test, PlantSimEngine, DataFrames
using PlantSimEngine.Examples

weather = (T=20.0,)
environment = ToySpatialEnvironment(
    Dict(:canopy => (T=weather.T,)); step_seconds=3600.0,
)
environment.cells[:canopy]
```

The reader has no parameters. The controller adds 1 °C after each unsuccessful
trial and stops when the reader returns a value strictly above 22 °C. It
allows at most ten trial calls in this scenario.

```@example modeler_mutable_environment
reader = ToyEnvironmentReaderModel()
controller = ToyEnvironmentControllerModel(;
    increment=1.0, threshold=22.0, max_iterations=10,
)
nothing # hide
```

## Connect the controller to a provider

Both models run on the same leaf. Its `geometry=(cell=:canopy,)` tells the
provider which cell to use. Both `Environment` configurations below refer to
the same `environment` object, so they share the stored cell values.

The controller also has `sink=:cells`. A **sink** is a destination for values
written back to the environment. In this toy provider, `:cells` means
"allow accepted values to be saved in the `cells` dictionary".

| Configuration | What it enables |
| --- | --- |
| `Environment(backend=environment)` | Read values from the cell associated with the leaf. This is all the reader needs. |
| `Environment(backend=environment, sink=:cells)` | Use the same provider and also allow `commit_environment!` to save accepted values in that cell. The controller needs this because it commits a temperature. |

The two settings answer different questions: `cell=:canopy` chooses **which
cell**, while `sink=:cells` enables **writing back to the provider**. The
name `:cells` is specific to `ToySpatialEnvironment`; other providers can
define different destinations. It is unrelated to the `sink` argument used
when collecting simulation outputs into a table.

```@example modeler_mutable_environment
model = CompositeModel(
    Object(:leaf; scale=:Leaf, geometry=(cell=:canopy,));
    applications=(
        ModelSpec(
            reader;
            name=:reader, on=One(scale=:Leaf),
            environment=Environment(backend=environment),
        ),
        ModelSpec(
            controller;
            name=:controller, on=One(scale=:Leaf),
            environment=Environment(backend=environment, sink=:cells),
        ),
    ),
)
nothing # hide
```

The controller's `environment_outputs_` declaration says **what it may write**
(`T`); its `sink` configuration says **where to write it**. Omitting
`sink=:cells` from the controller would make its `commit_environment!` call
fail with a "has no commit sink" error. The reader has neither an
`environment_outputs_` declaration nor a commit call, so it needs no sink.

The controller's `dep` declaration asks for a temperature reader on the same
object. It selects the reader's **process**, not its application name
`name=:reader`. The reader runs only when the controller calls it; it does
not also run independently. The implementation section below explains this
declaration and the loop.

## Run the controller and inspect the result

During this one-step simulation, the controller keeps trial results out of
the saved output history. **Publishing** records the reader's result once
the controller has accepted it:

| Action | Temperature seen by the reader | Temperature stored in `:canopy` |
| --- | --- | --- |
| Before the controller runs | The reader has not run yet. | 20 °C |
| Iteration 1: try the starting temperature. | 20 °C; continue. | 20 °C |
| Iteration 2: add 1 °C and try again. | 21 °C; continue. | 20 °C |
| Iteration 3: add 1 °C and try again. | 22 °C; still not above the threshold. | 20 °C |
| Iteration 4: add 1 °C and try again. | 23 °C; stop iterating. | 20 °C |
| Commit the solution `(T=23.0,)`. | No reader call in this operation. | 23 °C |
| Call the reader at the solution with `publish=true`. | 23 °C | 23 °C |

```@example modeler_mutable_environment
simulation = run!(model; outputs=:all)
state = final_state(simulation)
@test state.initial_temperature == 20.0 # hide
@test state.iterations == 4 # hide
@test state.accepted_temperature_seen == 23.0 # hide
@test state.temperature_seen == 23.0 # hide
@test environment.cells[:canopy].T == 23.0 # hide
@test weather.T == 20.0 # hide
@test only(row for row in Diagnostics.explain_outputs(simulation) # hide
           if row.application_id == :reader).nsamples == 1 # hide
(
    initial=state.initial_temperature,
    iterations=state.iterations,
    accepted=state.accepted_temperature_seen,
    committed_temperature=environment.cells[:canopy].T,
)
```

The reader ran four trial calculations and one final calculation, all within
one simulation time step. Its output history contains only the final 23 °C
result. The controller records the starting temperature and iteration count
so you can see how it reached that result.

Use the diagnostics below to inspect which cell each application uses and
how many output samples were saved. The reader has only one saved sample,
despite being called five times:

```@example modeler_mutable_environment
select(
    DataFrame(Diagnostics.explain_environment_bindings(model)),
    :application_id, :object_id, :handle,
)
```

```@example modeler_mutable_environment
select(
    DataFrame(Diagnostics.explain_outputs(simulation)),
    :application_id, :variable, :nsamples,
)
```

## How the controller works

If you only need to use an existing controller, the configuration above is
enough. The following details explain how to write one.

### Declare what the model reads, writes, and calls

The controller uses ordinary model declarations, plus a declaration of the
environment variables it may change:

| Declaration | Meaning in this example |
| --- | --- |
| `inputs_` | No values are read from another model's status. |
| `outputs_` | Store the initial temperature, iteration count, and accepted result on the leaf. |
| `environment_inputs_` | Read the starting temperature `T` from the provider. |
| `environment_outputs_` | Allow the controller to commit `T` to the provider. This does not add `T` to the leaf's status. |
| `dep` | Declare a call named `reader`, selecting one model of process `:toy_environment_reader` on the same object. |

`dep` supplies the model's default choice. A scenario can choose a particular
application with `ModelSpec(...; calls=...)`, as shown in
[Implement A Hard Dependency](@ref).

### Try values, then commit and publish

The controller starts from `environment.T`. At each iteration,
`run_call!(context, :reader; environment=(T=temperature,), publish=false)`
runs the reader with a temporary temperature. `run_call!` returns a collection
of called targets; `only(...)` retrieves the one target selected here.
The controller reads `trial_target.status.temperature_seen` to decide whether
to stop or add `model.increment` and try again.

Trial calls leave the stored environment unchanged and do not add samples to
output history. They **do change the reader's current status**: `publish=false`
does not restore rejected trial values. The reader simply overwrites its
temperature here. A scientific controller must also handle any accumulated
state that a rejected trial changes.

Once a result is above `model.threshold`, `commit_environment!` saves the
temperature in the provider. The final reader call uses that same temperature
with `publish=true` to save its output. Committing changes the environment;
publishing records model results. `max_iterations` limits the trials and
raises an error without committing if no result is accepted.

When accepting a solution, supply every variable declared in
`environment_outputs_`. If another controller calls this one as a trial with
`publish=false`, its nested calls cannot save accepted output samples or
change the shared environment.

The complete reader and controller definitions below are read directly from
`examples/ToySpatialEnvironment.jl` when the documentation builds. They include
the process declarations, parameters, and `run!` methods. You do not need to
copy them to run this example: `using PlantSimEngine.Examples` imports them.

```@example modeler_mutable_environment_source
Main.DocsSources.details("Show the reader and controller model code", "examples/ToySpatialEnvironment.jl", "PlantSimEngine.@process \"toy_environment_reader\"") # hide
```

### How the provider reads and commits values

The provider's `bind_environment` method remembers the leaf's cell and its
application's sink setting in a **handle**. Its `sample` methods read either
the stored cell or a temporary trial state. Its `commit_environment!` method
checks for `sink=:cells` and replaces the stored cell with the accepted state.
Here that cell contains only `T`.

```@example modeler_mutable_environment_source
Main.DocsSources.details("Show the environment provider code", "examples/ToySpatialEnvironment.jl", "\"\"\"\n    ToySpatialEnvironment", "PlantSimEngine.@process \"toy_environment_reader\"") # hide
```

A process model can normally use an existing provider. To implement your own,
see [Environment Backend Extensions](@ref).

## Next steps

[Understand Environments](@ref) shows how to give different objects their own
local conditions. [MAESPA-Style Synthesis](@ref) combines local leaf conditions
with a controller that adjusts canopy air conditions across several plants.
