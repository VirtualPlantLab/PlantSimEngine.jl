# Diagnosing Dependency Cycles

A **dependency cycle** occurs when two or more models each need a new result
from the others before they can run. For example, a leaf model needs water
from a root model, but the root model needs carbon from the leaf model.
Neither can go first, so PlantSimEngine reports the problem before running
the equations. The error names the applications, objects, and variables
involved.

Choose the solution that matches your equations. If the leaf should use the
root's water from the previous step, mark that input with
`PreviousTimeStep(:water)`. For a daily simulation, this means yesterday's
water. The leaf can then calculate today's carbon before the root calculates
today's water:

```julia
ModelSpec(
    LeafModel();
    inputs=(
        PreviousTimeStep(:water) =>
            One(scale=:Root, application=:root, var=:water),
    ),
)
```

At the start, the leaf's initial `water` value is used until a result from a
previous step is available.

If the two values must instead be solved together in the current step, use
a controller model that calls both models repeatedly. Try values with
`publish=false` and record each accepted result once with `publish=true`.
The controller must decide when the result is close enough and what to do if
the calculation does not converge. See
[Control Advanced Execution](../journeys/users/advanced_execution.md).

You may also need to rewrite the equations. Simply changing the order of
the `ModelSpec` declarations does not resolve a cycle.
