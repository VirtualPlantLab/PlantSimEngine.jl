# Coupling Models

Use `inputs` when a model reads a value produced by another application. A
unique same-object producer is inferred; cross-object sources should use an
explicit `One`, `OptionalOne`, or `Many` selector. Inspect the resolved
references with `explain_bindings`.

Use `calls` only when a parent algorithm owns child execution or iteration.
Use `run_call!(context, :name)` to execute every resolved target. For selective
or iterative execution, retrieve the vector-like collection with
`call_targets(context, :name)` and execute individual targets. Trial calls use
`publish=false`; accepted state is published once.
Nested calls inherit publication suppression, so a descendant cannot publish
inside an unpublished ancestor trial. `explain_calls` and `explain_schedule`
show call-only targets and ordering.

`explain_initialization(model)` classifies values as supplied, generated,
producer-bound, defaulted, required, or environment-bound before execution.

## Value coupling

A consumer on the same object needs no scenario syntax when exactly one
canonical producer exists. Make cross-object intent explicit:

```julia
ModelSpec(PlantBalance(); name=:balance, on=Many(scale=:Plant), inputs=(:assimilation => Many(
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
        ),))
```

`One` is a contract: zero or multiple matches are errors. Use `OptionalOne`
only when absence has a scientific meaning, and `Many` when aggregation is
part of the consumer model. `within=Subtree()` searches descendants of the
current target; `within=SelfPlant()` anchors repeated plant instances; and
`SceneScope()` is deliberately global.

By default, an input selector also identifies applications that produce the
selected variable, and those producers are scheduled before the consumer. Use
`from_status=true` only when the input deliberately reads the objects' current
`Status` references independently of any producer:

```julia
ModelSpec(
    ReserveConsumer();
    inputs=(
        :organ_reserves => Many(
            scale=(:Leaf, :Internode),
            within=Subtree(),
            var=:reserve,
            from_status=true,
            after=:plant_allocation,
        ),
    ),
)
```

This is a same-step live-reference binding. It cannot be combined with
`process`, `application`, `policy`, or `window`. It does not infer a producer
edge; use `after=:application_id` when the state must be read or mutated after
a particular application. Otherwise, the scenario's application order is
preserved.

## Manual calls

```julia
ModelSpec(Optimizer(); name=:optimizer, on=Many(scale=:Plant), calls=(:leaf_energy => Many(scale=:Leaf, within=Subtree())))
```

Inside `Optimizer`, iterate over `call_targets(context, :leaf_energy)`. Run
candidate states with `run_call!(target; publish=false)` and the accepted state
with `publish=true`. A call-only target is excluded from root scheduling, and
an unpublished outer call suppresses publication by every nested descendant.

After compilation, inspect `explain_bindings(compiled)` for source identity
and carrier type, `explain_calls(compiled)` for call-only targets, and
`explain_schedule(compiled)` for root execution order. These rows are the
supported diagnostic surface; compiled fields are internal.
