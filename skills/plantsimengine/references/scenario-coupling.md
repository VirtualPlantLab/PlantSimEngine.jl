# Composing and coupling scenarios

Read this reference when applying existing models, wiring values between
objects, configuring time or environment, or implementing hard dependencies.
Read `model-authoring.md` as well when a new model or adapter is required.

## Start with the smallest faithful object graph

For models that all run on one object and couple uniquely by variable name,
the thin constructor is sufficient:

```julia
model = CompositeModel(
    ModelA(),
    ModelB();
    status=(driver=1.0,),
    timestep=Dates.Hour(1),
)
```

Use explicit objects and applications as soon as target sets or policies
differ:

```julia
model = CompositeModel(
    Object(:scene; scale=:Scene, kind=:scene),
    Object(:plant; scale=:Plant, kind=:plant, parent=:scene),
    Object(:leaf_1; scale=:Leaf, kind=:leaf, parent=:plant),
    Object(:leaf_2; scale=:Leaf, kind=:leaf, parent=:plant);
    applications=(
        ModelSpec(LeafFlux(); name=:leaf_flux, on=Many(scale=:Leaf)),
        ModelSpec(PlantTotal(); name=:plant_total, on=One(scale=:Plant)),
    ),
    environment=(T=25.0, duration=Dates.Hour(1)),
)
```

`scale`, `kind`, `species`, and `name` are scenario labels, not a prescribed
botanical ontology. Object ids are stable runtime identities. Topology alone
does not determine execution order; compiled input, call, and writer edges do.

## Choose multiplicity and scope deliberately

- `One(...)`: exactly one source must resolve.
- `OptionalOne(...)`: zero or one; when absent, the consumer keeps its
  declared default.
- `Many(...)`: zero or more, delivered through the appropriate reference
  carrier.
- `Self()`: the consumer object only.
- `Subtree()`: the consumer and its descendants.
- `SelfPlant()`: the containing plant/root scope.
- `SceneScope()`: the complete scene.
- `Ancestor(...)`, `Scope(name)`, and `Relation(...)`: explicit topology or
  named-scope relationships.

`Self()` never means “this model” or “this plant” unless the current target
object is itself that object.

## Value coupling

Let the compiler infer a same-object connection only when producer and
consumer variable names match uniquely. Write cross-object, renamed, temporal,
or otherwise ambiguous bindings explicitly.

One renamed source:

```julia
ModelSpec(
    Consumer();
    name=:consumer,
    on=One(scale=:Plant),
    inputs=(
        local_driver=One(
            scale=:Scene,
            within=SceneScope(),
            application=:source,
            var=:source_driver,
        ),
    ),
)
```

Many descendant sources:

```julia
ModelSpec(
    PlantTotal();
    name=:plant_total,
    on=Many(scale=:Plant),
    inputs=(
        leaf_fluxes=Many(
            scale=:Leaf,
            within=Subtree(),
            application=:leaf_flux,
            var=:flux,
        ),
    ),
)
```

Use `application=...` when the same process is applied more than once. Use
`process=...` for intentional discovery across applications, not as a shortcut
when one producer identity is known.

Same-rate scalar and homogeneous many-value connections preserve references.
Do not copy values in a kernel merely to “couple” models. Check the actual
carrier and source with `Diagnostics.input_carrier`,
`Diagnostics.input_value`, and `Diagnostics.explain_bindings`.

## Contracts and adapters

The compiler accepts a contracted connection only when both sides declare the
same complete `VariableContract`. It does not infer that two units or bases are
convertible.

When contracts differ:

1. confirm the intended physical conversion;
2. implement a named adapter model whose input uses the producer contract and
   output uses the consumer contract;
3. expose conversion parameters such as area or molecular-mass factor in the
   adapter struct;
4. test the adapter equation directly and in a scenario.

See `../assets/adapter-model.jl` for a ground-area-to-plant example.

## Time and temporal policies

Configure an application cadence with `every=Dates.Period`. `timespec(model)`
may provide a model default; an explicit scenario cadence overrides it.

```julia
ModelSpec(
    DailyPlantTotal();
    name=:daily_total,
    on=Many(scale=:Plant),
    inputs=(
        leaf_fluxes=Many(
            scale=:Leaf,
            within=Subtree(),
            application=:hourly_leaf_flux,
            var=:flux,
            policy=Integrate(),
            window=Dates.Day(1),
        ),
    ),
    every=Dates.Day(1),
)
```

Use:

- `HoldLast()` for the last available state;
- `Interpolate()` for a value defined between samples;
- `Integrate()` for a rate accumulated over a window;
- `Aggregate(...)` for an explicit aggregation policy;
- `PreviousTimeStep(:x)` only for an intentional lag/cycle break with an
  explicit initial value and temporal meaning.

Example cycle break:

```julia
inputs=(
    PreviousTimeStep(:carbon_pool) => One(
        within=Self(),
        application=:carbon_balance,
        var=:carbon_pool,
    ),
)
```

Do not use a temporal policy until it is clear whether a variable is a state,
rate, interval total, or instantaneous value.

## Environment coupling

Models declare model-facing variables with `environment_inputs_` and accepted
commits with `environment_outputs_`. `Environment(...; sources=...)` performs
scenario-level source remapping. `environment_hint(model)` may provide a
model-author default reducer, window, or source hint.

Global meteorology and spatial backends expose the same model-facing contract.
Spatial handles are compiled and cached. Use lifecycle geometry helpers to
invalidate them; do not mutate cached geometry behind the runtime.

For transient hard-call trials, distinguish:

- `environment=trial_backend_state`: sample through each target's compiled
  environment handle;
- `sampled_environment=model_facing_value`: forward an already sampled value.

Commit only the accepted environmental state with `commit_environment!`.

## Hard calls

Use a hard call when a parent owns iteration, trial states, convergence, or
publication of a child model:

```julia
PlantSimEngine.dep(::Controller) = (
    leaves=Call(
        Many(scale=:Leaf, within=Subtree(), process=:energy_balance),
    ),
)

function PlantSimEngine.run!(model::Controller, status, environment, constants, context)
    # Trial calls do not publish outputs.
    run_call!(context, :leaves; publish=false)

    # Call once with the accepted state and publish it.
    accepted = run_call!(context, :leaves; publish=true)
    status.total = sum(target.status.flux for target in accepted)
    return nothing
end
```

`run_call!` always returns a vector-like `CallTargets` collection. Use the bulk
form to execute every target. Use `call_targets` and individual calls only for
selective ordering, per-target environment values, or explicit target status
inspection. Call-target-only applications are not run by the root scheduler.

## Validate before running the full scenario

Use `Authoring.validate_scenario(model)` and inspect:

```julia
Diagnostics.explain_initialization(model)
Diagnostics.explain_applications(model)
Diagnostics.explain_bindings(model)
Diagnostics.explain_calls(model)
Diagnostics.explain_writers(model)
Diagnostics.explain_schedule(model)
Diagnostics.explain_execution_plan(model)
```

Then run with explicit output retention:

```julia
simulation = run!(model; steps=10, outputs=:none)
latest = final_state(simulation, One(scale=:Plant))
```

Use `outputs=:all` or `OutputRequest` only for streams needed by the task.
`collect_outputs` materializes rows and should not be the default internal
representation. Use `continue!` or `step!` to advance the same timeline.
