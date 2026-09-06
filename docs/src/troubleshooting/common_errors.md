# Common Errors

Start with the application, object, and variable named in the error. They tell
you which part of the configuration needs attention. Many connection errors
are detected before any equation runs.

| Symptom | What it means | First action |
|:--|:--|:--|
| A required input is missing | Neither initial status nor another application supplies it | Supply a measured/initial value or connect a producer |
| A selector finds too few or too many objects | The matches do not satisfy `One`, `OptionalOne`, or `Many` | Check object labels and the search scope |
| More than one source matches | The source application is ambiguous | Name the intended `application` and, if needed, `var` |
| Several models write the same variable | Canonical status has competing writers | Decide which model owns the value; use `Updates` only for intentional ordered updates |
| Variable contracts differ | Units, physical basis, or another declared meaning differ | Check the equations and add an explicit conversion model if appropriate |
| A cadence is rejected | The period does not fit the base step, or an implicit cadence violates a model's hint | [Choose compatible time steps](../guides/time/advanced_time_environment.md) |
| There is a dependency cycle | No valid same-step execution order exists | Decide whether the science requires a lag or an iterative solution |

## Example: the light model needs LAI

`Beer` reads LAI from status. With no producer, you must supply it:

```@example missing_lai
using PlantSimEngine
using PlantSimEngine.Examples

model = CompositeModel(Beer(0.6);
    status=(LAI=2.0,), environment=(Ri_PAR_f=100.0,))
simulation = run!(model)
final_state(simulation).aPPFD
```

Alternatively, add a model that calculates LAI and supply that model's inputs.
An arbitrary zero may remove a missing-input error while changing the
scientific question. Use a value with a clear meaning.

## Check the objects a selector actually sees

Inspect `Diagnostics.explain_objects(model)` to see labels and parent links.
For a plant application, `Many(scale=:Leaf, within=Subtree())` searches that
plant and its descendants. For a leaf application, the same selector starts
at that leaf. Use `SelfPlant()` when the search should cover its whole plant.

Choose `Many` when the receiving model accepts a collection. Choosing it only
to silence an error can pass a vector to an equation that expects one value.

## Errors while writing a model

Declare each status input with `Required(T)` or `Default(value)`, for example
`inputs_(::MyModel) = (LAI=Required(Real),)` with the function qualified as
`PlantSimEngine.inputs_`. A plain literal in `inputs_` is not a declaration of
required state. Define the equation as `PlantSimEngine.run!(...)` so Julia
extends the package function.

For the complete sequence, see [Write and test a first model](../journeys/modelers/basic_model.md).
For further investigation, see [Inspect a simulation](runtime_contracts.md)
and [Dependency cycles](dependency_cycles.md).
