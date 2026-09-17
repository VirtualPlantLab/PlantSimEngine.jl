# Implement A Mutable Environment Controller

Some models also change their environment. A canopy energy-balance model,
for example, may try several temperatures before deciding which temperature
other models should use. A model that manages these trials is called a
**controller**.

This teaching example uses prescribed temperatures to explain that sequence.
It does not implement a physical canopy solver. A small **reader model** copies
the temperature it receives into its results. The **controller model** calls
that reader first with a trial temperature, then with an accepted temperature.
An **environment provider** stores the temperature that later calculations can
use. Start with
[Modify The Environment](@ref) for the scenario perspective and
[Implement A Hard Dependency](@ref) for model calls.

## Declare the accepted values you can write

A controller declares both the model it calls and the environmental variables
it may update. Here `environment_outputs_` names temperature `T`. These are
the actual declarations in `examples/ToySpatialEnvironment.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "PlantSimEngine.inputs_(::ToyEnvironmentControllerModel)",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

The variables in `outputs_` record the temperatures seen during the
calculation. The variable in `environment_outputs_` is the temperature the
controller may change in the shared environment.

The `dep` declaration gives the controller a call named `reader`. It looks for
one model of the `:toy_environment_reader` process on the same object. This
lets the controller call that model when it needs a calculation.

## Evaluate a trial, then commit an accepted state

The controller's implementation makes the sequence explicit:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

The first call gives the reader a trial temperature. Its result is not saved
as an accepted output sample. `commit_environment!` then stores the accepted
temperature in the shared environment. The final reader call saves the
result calculated at that temperature.

`run_call!` returns a collection of called models. Here there is exactly one,
so `only(...)` retrieves it, and `trial_target.status.temperature_seen` reads
its result. The controller copies this result into `trial_temperature_seen`
before the next call overwrites the reader's `temperature_seen`.

For a scientific controller, you must choose how to calculate trials and
when to accept a solution. You must also handle any values changed by a
rejected trial: `publish=false` does not restore them automatically.

## Connect the controller to a provider

The complete example uses three small types from `PlantSimEngine.Examples`:

| Type | What it does here |
| --- | --- |
| `ToySpatialEnvironment` | Stores environmental values in a dictionary of named cells. It supplies temperatures to the models and can store an accepted temperature. It is a data provider, not a process model. |
| `ToyEnvironmentReaderModel` | Reads `environment.T` and writes it to `status.temperature_seen`. It does not calculate or change the temperature. |
| `ToyEnvironmentControllerModel` | Calls the reader with a trial temperature, saves an accepted temperature in the provider, then calls the reader with that accepted temperature. |

### Create the provider and the two models

Start with one cell, named `:canopy`, at 20 °C. A cell is just a named entry
in the dictionary here; this example has no 3D mesh. `step_seconds=3600.0`
sets an hour-long time step, and this toy provider supplies one step.

```@example modeler_mutable_environment
using Test, PlantSimEngine
using PlantSimEngine.Examples

environment = ToySpatialEnvironment(
    Dict(:canopy => (T=20.0,)); step_seconds=3600.0,
)
environment.cells[:canopy]
```

The reader has no parameters. The controller's two parameters are the
temperature to try, 30 °C, and the temperature to accept, 22 °C. These are
just random values chosen for the demonstration.

```@example modeler_mutable_environment
reader = ToyEnvironmentReaderModel()
controller = ToyEnvironmentControllerModel(30.0, 22.0)
nothing # hide
```

You can inspect the complete definitions below. The documentation reads this
code directly from `examples/ToySpatialEnvironment.jl` during the build,
including the process declarations, model parameters and `run!` methods.
You do not need to copy these definitions to run the example: the import
above already makes them available.

```@example modeler_mutable_environment_source
Main.DocsSources.details("Show the reader and controller model code", "examples/ToySpatialEnvironment.jl", "PlantSimEngine.@process \"toy_environment_reader\"") # hide
```

### Choose where each model reads and writes

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

The controller finds the reader through its `dep` declaration, shown above.
That declaration selects the reader's **process**, not its application name
`name=:reader`. The reader runs when the controller calls it; it does not
also run independently at the start of the time step.

For readers who want to see how the provider implements these operations,
the complete provider code is below. `bind_environment` remembers the leaf's
cell and its application's sink setting in a handle. `sample` reads either
the stored cell or a temporary trial state. The provider's
`commit_environment!` checks for `sink=:cells` and replaces the stored cell
with the accepted state. Here that cell contains only `T`.

```@example modeler_mutable_environment_source
Main.DocsSources.details("Show the environment provider code", "examples/ToySpatialEnvironment.jl", "\"\"\"\n    ToySpatialEnvironment", "PlantSimEngine.@process \"toy_environment_reader\"") # hide
```

### Run the controller and inspect the result

During this one-step simulation, the controller performs the following
sequence:

| Action | Temperature seen by the reader | Temperature stored in `:canopy` |
| --- | --- | --- |
| Before the controller runs | The reader has not run yet. | 20 °C |
| Call the reader with the trial state `(T=30.0,)`. | 30 °C | Still 20 °C |
| Commit the accepted state `(T=22.0,)`. | No reader call in this operation. | 22 °C |
| Call the reader with the accepted state and `publish=true`. | 22 °C | 22 °C |

```@example modeler_mutable_environment
simulation = run!(model; outputs=:all)
state = final_state(simulation)
@test state.trial_temperature_seen == 30.0
@test state.accepted_temperature_seen == 22.0
@test state.temperature_seen == 22.0
@test environment.cells[:canopy].T == 22.0
(
    trial=state.trial_temperature_seen,
    accepted=state.accepted_temperature_seen,
    committed_temperature=environment.cells[:canopy].T,
)
```

The reader saves only its accepted result, 22 °C, in its output history.
The controller separately records the trial result, 30 °C, in
`trial_temperature_seen`, so it remains available for inspection. Keeping
that diagnostic result does not mean the provider accepted 30 °C.

Use `Diagnostics.explain_environment_bindings(model)` to check where models
read and write environmental data. `Diagnostics.explain_outputs(simulation)`
shows the saved results.

When accepting a solution, supply a value for every variable declared in
`environment_outputs_`. If another controller calls this one as a trial with
`publish=false`, none of its nested calls can save accepted output samples
or change the shared environment.

To add a new kind of spatial environment provider, see
[Environment Backend Extensions](@ref). When writing a process model, you
can normally use an existing provider through `Environment` and the call
and commit functions shown here.
