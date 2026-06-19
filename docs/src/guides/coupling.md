# Coupling Models

Use `Inputs` when a model reads a value produced by another application. A
unique same-object producer is inferred; cross-object sources should use an
explicit `One`, `OptionalOne`, or `Many` selector. Inspect the resolved
references with `explain_bindings`.

Use `Calls` only when a parent algorithm owns child execution or iteration.
Resolve targets through `call_target`/`call_targets` and execute them with
`run_call!`. Trial calls use `publish=false`; accepted state is published once.
Nested calls inherit publication suppression, so a descendant cannot publish
inside an unpublished ancestor trial. `explain_calls` and `explain_schedule`
show call-only targets and ordering.

`explain_initialization(scene)` classifies values as supplied, generated,
producer-bound, environment-bound, or unresolved before execution.

## Value coupling

A consumer on the same object needs no scenario syntax when exactly one
canonical producer exists. Make cross-object intent explicit:

```julia
ModelSpec(PlantBalance(); name=:balance) |>
    AppliesTo(Many(scale=:Plant)) |>
    Inputs(
        :assimilation => Many(
            scale=:Leaf,
            within=Subtree(),
            application=:photosynthesis,
            var=:carbon,
        ),
        :soil_water => One(
            scale=:Soil,
            within=SceneScope(),
            application=:soil,
            var=:water,
        ),
    )
```

`One` is a contract: zero or multiple matches are errors. Use `OptionalOne`
only when absence has a scientific meaning, and `Many` when aggregation is
part of the consumer model. `within=Subtree()` searches descendants of the
current target; `within=SelfPlant()` anchors repeated plant instances; and
`SceneScope()` is deliberately global.

## Manual calls

```julia
ModelSpec(Optimizer(); name=:optimizer) |>
    AppliesTo(Many(scale=:Plant)) |>
    Calls(:leaf_energy => Many(scale=:Leaf, within=Subtree()))
```

Inside `Optimizer`, iterate over `call_targets(extra, :leaf_energy)`. Run
candidate states with `run_call!(target; publish=false)` and the accepted state
with `publish=true`. A call-only target is excluded from root scheduling, and
an unpublished outer call suppresses publication by every nested descendant.

After compilation, inspect `explain_bindings(compiled)` for source identity
and carrier type, `explain_calls(compiled)` for call-only targets, and
`explain_schedule(compiled)` for root execution order. These rows are the
supported diagnostic surface; compiled fields are internal.
