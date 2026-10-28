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

Object IDs are unique, stable runtime identities. `Object(:leaf_1)` needs no
other labels. An optional `name="Sunlit leaf"` is display text; it need not be
unique and does not affect selection. The graph viewer shows the ID when the
name is omitted. Use `One(id=:leaf_1)` for an individual object, preserving
numeric or other typed IDs when present.

`scale`, `kind`, and `species` are optional group labels, not a prescribed
botanical ontology. Add them when a model selects those groups. Topology
alone does not determine execution order; compiled input, call, and writer
edges do.

`ModelSpec.name` identifies an application. Omit it when the process occurs
once, or give each separate application of the same process a distinct name.
`ObjectInstance.name` identifies an instance and prefixes its applications;
it does not rename the root object or change its ID.

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
- `Ancestor(...)` and `Relation(...)`: explicit topology relationships.
- `Scope(:instance_name)`: the instance's root and descendants.
- `Scope(ObjectId(root_id))`: a root selected by its typed object ID and its
  descendants. Object display names never define a scope.

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
Every duration-based application cadence must be a positive integer multiple
of the simulation base step. For hourly and 90-minute applications, use a
30-minute base step. Fixed subsecond periods are supported; calendar months
and adaptive application timesteps are not.

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
            policy=Integrate((values, durations_seconds) -> sum(values .* durations_seconds)),
            window=Dates.Day(1),
        ),
    ),
    every=Dates.Day(1),
)
```

Use:

- `HoldLast()` for the last available state;
- `Interpolate()` for a value defined between samples;
- `Integrate()` to sum interval amounts over a window;
- `Integrate((values, durations_seconds) -> sum(values .* durations_seconds))`
  to integrate rates per second; the default reducer does not weight by time;
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

For real scalar rates per second, the named reducer
`Integrate(PlantMeteo.DurationSumReducer())` is equivalent to the duration-aware
callable above (`using PlantMeteo`).

Temporal policies do not transform `VariableContract` metadata. The
`Integrate(reducer)` example above assumes uncontracted ports; a rate contract cannot
be bound directly to a total contract, even with `Integrate()`. For contracted
models, put the rate-to-amount calculation in a named adapter whose incoming
binding uses the producer's rate contract and whose output declares the
consumer's amount contract. Accumulate varying rates at the producer cadence
or use a correctly averaged rate. Do not remove contracts or label an amount
as a rate to make the connection compile.

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
The runtime reuses `EnvironmentAPI.PreparedEnvironmentInputs` schemas, which
contain names/remapping rather than values. A custom backend's
`sample_environment` specialization should accept that prepared schema and
read current committed/trial data on every invocation. This supports a shared
mutable air compartment as well as spatial handles; never cache mutable
environment values solely because the trial state's object identity matches.

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
    # Evaluate a candidate, inspect it, and accept it without replaying kernels.
    evaluated = evaluate_call!(context, :leaves)
    status.total = sum(target.status.flux for target in call_targets(evaluated))
    accept_call!(evaluated)
    return nothing
end
```

For an iterative solve, evaluate each candidate with `evaluate_call!`, inspect
its target statuses, and accept only the latest successful candidate. The
individual-target overload accepts a `CallTarget`; the named-call overload
also accepts `objects=...`. Both environment keywords retain their usual
meaning. Publish the state whose equations were evaluated, not a proposed
next iterate.

`run_call!` remains appropriate when capture is unnecessary: use
`publish=false` for an ordinary unpublished trial or `publish=true` to run and
publish together. It always returns a vector-like `CallTargets` collection.
Use the bulk form to execute every target, and individual calls for selective
ordering, per-target environment values or explicit status inspection.
Call-target-only applications are not run by the root scheduler.

Evaluation/acceptance constraints:

- Evaluation mutates live statuses. It captures
  publication-intended retained/dependency values and commits, not complete
  model state; it is not rollback for stateful scientific equations.
- Accept a token once on its originating task, in the same synchronous call
  tree, before any rerun of its targets, timestep advance or structural/model/
  binding change. Do not directly change its live inputs/status before accept.
- Earlier candidates require caller-owned scientific inputs/state and another
  evaluation. Mutable retained output values are captured at their original
  publication point, including private outputs. Applications declaring
  distributed outputs still cannot be manual-call-only targets; keep them
  root-scheduled and evaluate/accept their scalar children instead.
- Nested `publish=false` suppresses descendant publication; nested
  `publish=true` stages into the active evaluation. Accepting a child inside
  an outer evaluation merges its events; an unpublished ancestor still wins.
- Environment commits inside evaluation are deferred and do not overlay the
  backend for subsequent default samples. Pass transient states explicitly to
  descendants. A controller may commit accepted air, then accept its already
  evaluated leaves without rerunning them. Backend commit failures retain the
  backend's own exception semantics; acceptance is not arbitrary-side-effect
  atomicity.

## Evidence for the changed composition

`Authoring.validate_scenario(model)` checks declared scenario structure. Choose
the public reports that answer questions about the changed connections,
ownership, timing, or execution; these are available examples, not a required
bundle:

```julia
Diagnostics.explain_initialization(model)
Diagnostics.explain_applications(model)
Diagnostics.explain_bindings(model)
Diagnostics.explain_calls(model)
Diagnostics.explain_writers(model)
Diagnostics.explain_schedule(model)
Diagnostics.explain_execution_plan(model)
```

For a focused execution check, retain only the outputs needed by the task:

```julia
simulation = run!(model; steps=10, outputs=:none)
latest = final_state(simulation, One(scale=:Plant))
```

Use `outputs=:all` or `OutputRequest` only for streams needed by the task.
`collect_outputs` materializes rows and should not be the default internal
representation. Use `continue!` or `step!` to advance the same timeline.

For observed upstream values, parameter fitting, or scientific comparison,
see [data-calibration-evaluation.md](data-calibration-evaluation.md). These
tasks require data alignment and scientific evidence beyond compiled bindings.

## Example request

> Couple these component models into the requested scenario. Preserve units,
> physical bases, object identities, and time meaning. Make needed conversions
> explicit and show evidence that each changed input receives its intended
> source, with a focused execution check of the composition.
