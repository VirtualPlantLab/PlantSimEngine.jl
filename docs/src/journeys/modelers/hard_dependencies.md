# Implement A Hard Dependency

Use a **hard dependency** when one model must decide when or how often another
model runs. For example, an energy-balance calculation may evaluate gas
exchange at several trial temperatures before accepting a solution.

When a model only needs another model's result, use an ordinary input instead.
[Coupling models](@ref) explains the difference, and
[Control Advanced Execution](@ref) covers scenario configuration.

## Declare the model you need to call

The teaching model below acts as a **controller**: it chooses when to run
another model. It selects one leaf, tries two prescribed temperatures, and
finally accepts a third. This shows how to run trials; it does not solve an
energy-balance equation.

Its declaration asks for temperature-reading models on the current plant's leaves.
These definitions are extracted from `examples/ToyAdvancedControl.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "PlantSimEngine.dep(::ToySelectiveCallControllerModel)",
    "function PlantSimEngine.outputs_",
)
```

`Call` declares which models the controller needs. The controller chooses
when to run them. Asking for a process on the current plant's leaves lets
you reuse it without knowing the names a future simulation will give those
model applications.

## Run trials and accept one result

Here is the actual controller calculation:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "function PlantSimEngine.run!(\n    model::ToySelectiveCallControllerModel,",
    "\"\"\"\n    ToyStockWriterModel",
)
```

`call_targets` lists the models and objects that match the `Call` declaration.
Each match is called a **target**. Here the controller chooses the target for
one leaf. Each trial uses `publish=false`, so its result is not saved as an
accepted output sample. The final call uses `publish=true` to save the
accepted result for output history and time-based connections.

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
