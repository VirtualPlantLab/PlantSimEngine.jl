# Diagnosing Dependency Cycles

A same-step value cycle is rejected because no valid execution order exists.
Read the reported application, object, and variable edges. If the science uses
yesterday's value, put `PreviousTimeStep(:variable)` on that input. If the
science requires convergence in the current step, make one parent application
own child trials with `calls`. Otherwise reformulate the coupled equations.

Application declaration order is not a cycle-resolution mechanism.

For example, if application `:leaf` reads same-step `water` from `:root` while
`:root` reads same-step `carbon` from `:leaf`, compilation fails before either
kernel runs. If root water scientifically affects tomorrow's leaf carbon,
change only that edge:

```julia
ModelSpec(
    LeafModel();
    inputs=(
        PreviousTimeStep(:water) =>
            One(scale=:Root, application=:root, var=:water),
    ),
)
```

The receiving object's initial `water` value is used until the first accepted
historical sample exists. If both values must converge within the same step,
do not add a lag: make a parent model own `calls` to the two trial models,
iterate with `publish=false`, and publish each accepted state once.
