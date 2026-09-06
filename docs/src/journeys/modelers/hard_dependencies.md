# Implement A Hard Dependency

Use a **hard dependency** when one model must decide when or how often another
model runs. For example, an energy-balance calculation may evaluate gas
exchange at several trial temperatures before accepting a solution.

When a model only needs another model's result, use an ordinary input instead.
[Coupling models](@ref) explains the difference, and
[Control Advanced Execution](@ref) covers scenario configuration.

## Declare the model you need to call

The teaching controller below selects one leaf, tries two prescribed
temperatures, and finally accepts a third. It demonstrates the call mechanism;
it does not solve an energy-balance equation.

Its declaration selects leaf readers by process within the current plant.
These definitions are extracted from `examples/ToyAdvancedControl.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "PlantSimEngine.dep(::ToySelectiveCallControllerModel)",
    "function PlantSimEngine.outputs_",
)
```

`Call` declares the requirement. The controller will execute it explicitly.
Process and relative scope allow reuse without knowing a future scenario's
application names.

## Run trials and accept one result

Here is the actual controller calculation:

```@eval
Main.DocsSources.section(
    "examples/ToyAdvancedControl.jl",
    "function PlantSimEngine.run!(\n    model::ToySelectiveCallControllerModel,",
    "\"\"\"\n    ToyStockWriterModel",
)
```

`call_targets` finds the declared targets; the object filter chooses the leaf
for this example. Each trial uses `publish=false`, so it does not create an
accepted output sample. The final call uses `publish=true`.

An actual iterative model must define its own trial calculation, convergence
criterion, and treatment of state. Publication suppression does not undo
arbitrary changes made by a trial.

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

The controller's default `dep` declaration supplies the call. A scenario can
override its selection with `ModelSpec(...; calls=...)`. Inspect
`Diagnostics.explain_calls(model)` to check the resolved targets.

## Choose the simplest call operation

| Your algorithm needs… | Use |
|---|---|
| To execute every declared target | `run_call!(context, :readers)` |
| To inspect one resolved model's parameters or type | `call_model(context, :reader)` |
| To select objects, inspect target state, or use distinct trial values | `call_targets(context, :readers)`, then call the selected target |

`call_model` requires exactly one resolved target. The bulk `run_call!`
path can take `sampled_environment=value` when every target uses the same
already-sampled environment.

Supported structural changes refresh the selected objects. Keep ordinary
calls through these public operations so your controller continues to use
the current targets.
