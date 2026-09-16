# Implement A Hard Dependency

Use a **hard dependency** when one model must decide when or how often another
model runs. For example, an energy-balance calculation may evaluate gas
exchange at several trial temperatures before accepting a solution.

When a model only needs another model's result, use an ordinary input instead.
[Coupling models](@ref) explains the difference, and
[Control Advanced Execution](@ref) covers scenario configuration.

## Declare the model you need to call

The example model below acts as a **controller**: it chooses when to run
another model. It selects one leaf, tries two prescribed temperatures, and
finally accepts a third. This model is calling a **hard dependency** because
it controls the execution of another model. Each selected model and object pair is a **target**, and the controller's
`dep` function declaration describes what kind of models it needs (i.e. the kind of process it should simulate).

This example model declaration asks for temperature-reading models on the current plant's leaves. Its definition
is extracted from `examples/ToyAdvancedControl.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "PlantSimEngine.dep(::ToySelectiveCallControllerModel)",
    "function PlantSimEngine.outputs_",
)
```

What we are doing here is declaring a dependency on a process that reads temperature. The `dep` function returns a named tuple whose `readers` entry is a `Call` describing the models the controller needs. The `scale=:Leaf` argument says it wants models applied to leaves, the `process=:toy_environment_reader` defines
the kind of process it needs, and the `within=Subtree()` argument says it wants models on leaves anywhere below the current object onto which the `ToySelectiveCallControllerModel` is applied (e.g. all leaves from a plant if the controller is applied to a plant). The `Call` declaration identifies targets by their process and location, without naming a particular application or object. PlantSimEngine resolves these targets when it prepares the scenario. The controller then chooses which of those targets to call at runtime.

This approach may seem complex at first, but it allows the controller to be used in many different scenarios with different models and objects. The controller does not need to know the details of the models it calls, it just needs to know that they implement the required process. This is a key feature of PlantSimEngine's design: it allows for flexible model composition and reuse.

## Run trials and accept one result

Now let's define our controller model implementation. It is implemented like any other model, except that it calls other models during its calculation. This model runs a temperature model twice with trial temperatures (in a for loop), and then runs it a third time with an accepted temperature.

The model uses `call_targets` to get the list of models and objects that match its `dep` declaration. Each match is called a **target**. The model then counts the number of targets, and selects one target based on its object ID. This target is then used to run the temperature model with different trial temperatures used as environment inputs using `run_call!`. The controller decides which result to accept. It uses `publish=false` for trial calls and `publish=true` for the accepted call, so only the accepted result is published to output history and time-based connections. Trial calls still change the target's current values; `publish=false` does not hide those changes from direct references. The model implementation is extracted from `examples/ToyAdvancedControl.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "function PlantSimEngine.run!(\n    model::ToySelectiveCallControllerModel,",
    "\"\"\"\n    ToyStockWriterModel",
)
```

For a real solver, you must decide how to calculate each trial and when a
solution is close enough. You must also handle any values changed by a
rejected trial: `publish=false` does not restore them automatically.

## Compose a small scenario

```@example modeler_hard_dependency
using Test, PlantSimEngine
using PlantSimEngine.Examples

controller = ToySelectiveCallControllerModel(
    (28.0, 31.0), 22.0; selected_object=:sun_leaf,
)
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
        ModelSpec(controller; name=:controller, on=One(scale=:Plant)),
    ),
)
simulation = run!(model; outputs=:all)
accepted = final_state(simulation, :plant)
@test accepted.trial_temperature_seen == 31.0
@test accepted.accepted_temperature_seen == 22.0
(
    last_trial=accepted.trial_temperature_seen,
    accepted=accepted.accepted_temperature_seen,
)
```

The controller's `dep` declaration describes the models it calls by default.
To choose different models or objects in a simulation, set
`ModelSpec(...; calls=...)`. Use `Diagnostics.explain_calls(model)` to check
which models and objects were selected.

## Choose the simplest call operation

| Your algorithm needs… | Use |
|---|---|
| To run all selected models and objects | `run_call!(context, :readers)` |
| To read one called model's parameters or type | `call_model(context, :reader)` |
| To choose objects, read their current values, or give them different trial values | `call_targets(context, :readers)`, then call the selected target |

`call_model` requires exactly one match. If you have already prepared the
environmental values that all selected objects should use, pass them as
`sampled_environment=value` to `run_call!`.

When objects are added, removed, or moved to a different parent through the
PlantSimEngine functions, the selection is updated. Use the call functions
above so your controller uses that updated selection.
