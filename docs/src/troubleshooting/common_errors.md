# Common Errors

Start with the model application, object, and variable named in the error.
An application is a model configured to run on selected objects. These names
tell you where to look: for example, a light calculation on a particular
canopy may be missing LAI. PlantSimEngine catches many such problems before
running any equation.

| Symptom | What it means | First action |
|:--|:--|:--|
| A required input is missing | You have not supplied a starting value or a model that calculates it | Supply the value or connect a model that provides it |
| A selector finds too few or too many objects | For example, `One` expects one match but finds two | Check the object labels and where the selector searches |
| More than one source matches | Several models could supply the input | Name the intended `application` and, if needed, `var` |
| Several models set the same variable | PlantSimEngine cannot decide which value to keep | Choose one model, or use `Updates` if one model is meant to change another's result |
| Variable contracts differ | The connected variables declare different units or physical meanings | Check what each equation expects; add a conversion model where appropriate |
| A cadence is rejected | The chosen interval does not fit the base step or is not supported by the model | [Choose compatible time steps](../guides/time/advanced_time_environment.md) |
| There is a dependency cycle | Two or more models each wait for a result from the others | Decide whether one input should come from the previous step or the equations must be solved together |

## Example: the light model needs LAI

`Beer` needs the canopy's LAI to calculate absorbed light. If no other model
calculates LAI, supply its value yourself:

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

Declare each status input with `Required(T)` if it must be supplied, or
`Default(value)` if the model provides a fallback value. For example, use
`inputs_(::MyModel) = (LAI=Required(Real),)` with the function qualified as
`PlantSimEngine.inputs_`. Writing a number directly in `inputs_` does not
declare a required input. Define the equation as `PlantSimEngine.run!(...)`
so that Julia adds your model's method to the package function.

For the complete sequence, see [Write and test a first model](../journeys/modelers/basic_model.md).
For further investigation, see [Inspect a simulation](runtime_contracts.md)
and [Dependency cycles](dependency_cycles.md).
