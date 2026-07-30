# Control Advanced Execution

## New concept: parent-controlled execution and explicit publication

Most coupling should remain a value dependency through `inputs`. Use a hard
call only when a parent algorithm must decide whether, when, or how often
another model runs—for example, while iterating toward an accepted leaf
temperature.

## Declare parent-controlled targets

Start with one plant and two leaves. The reader application is selected by the
controller's `calls` declaration, so it is call-only rather than independently
scheduled:

```@example journey_advanced_execution
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

environment = ToySpatialEnvironment(
    Dict(
        :sun => (T=26.0,),
        :shade => (T=18.0,),
    );
    step_seconds=3600.0,
)

model = CompositeModel(
    Object(:plant; scale=:Plant, kind=:plant),
    Object(
        :sun_leaf;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        geometry=(cell=:sun,),
    ),
    Object(
        :shade_leaf;
        scale=:Leaf,
        kind=:leaf,
        parent=:plant,
        geometry=(cell=:shade,),
    );
    applications=(
        ModelSpec(
            ToyEnvironmentReaderModel();
            name=:reader,
            on=Many(scale=:Leaf),
            environment=Environment(backend=environment),
        ),
        ModelSpec(
            ToySelectiveCallControllerModel(
                (28.0, 31.0),
                22.0;
                selected_object=:sun_leaf,
            );
            name=:controller,
            on=One(scale=:Plant),
            calls=(
                :readers => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:reader,
                ),
            ),
        ),
    ),
)

select(
    DataFrame(Diagnostics.explain_calls(model)),
    :application_id,
    :call,
    :callee_application_ids,
    :callee_object_ids,
    :publication_policy,
)
```

`run_call!(context, :readers)` executes every resolved target and returns a
vector-like `CallTargets` collection. `One` still returns a collection of one;
`OptionalOne` returns zero or one; `Many` returns zero or more.

## Inspect, select, iterate, then publish once

`ToySelectiveCallControllerModel` needs different treatment per target, so its
kernel first calls `call_targets(context, :readers)` without executing
anything. It records the total, restricts the same declared call to
`:sun_leaf`, runs two temperature trials, and accepts one result:

```@example journey_advanced_execution
function run_selected_trials!(
    target,
    trial_temperatures,
    accepted_temperature,
)
    for temperature in trial_temperatures
        run_call!(
            target;
            sampled_environment=(T=temperature,),
            publish=false,
        )
    end
    run_call!(
        target;
        sampled_environment=(T=accepted_temperature,),
        publish=true,
    )
end
```

`publish=false` is the default. Trials may update the called model's current
status for convergence checks, but they neither append output samples nor
commit mutable environment state. Publish exactly the accepted execution.

```@example journey_advanced_execution
simulation = run!(model; outputs=:all)
(
    controller=final_state(simulation, :plant),
    leaves=final_state(simulation, Many(scale=:Leaf)),
)
```

The controller resolved two targets but selected only `:sun_leaf`. Object
selection uses `call_targets(context, name; objects=(ObjectId(:sun_leaf),))`;
it does not depend on iteration order. Two trials
left no history; its accepted call published once, while `:shade_leaf` was
never executed:

```@example journey_advanced_execution
filter(
    row -> row.application_id == :reader,
    DataFrame(Diagnostics.explain_outputs(simulation)),
)
```

Use `run_call!(context, name; environment=trial_state)` when every target
should sample the same provider-aware trial state through its own compiled
handle. Use `call_targets` and `run_call!(target; sampled_environment=...)`
for selection, custom order, or distinct already-sampled environments.

## Order intentional duplicate writers

One canonical variable normally has one writer. Two applications that both
claim `stock` therefore fail compilation unless their relationship is
intentional and ordered. `Updates` makes that ownership explicit:

```@example journey_advanced_execution
writer_model = CompositeModel(
    Object(:reserve; scale=:Organ);
    applications=(
        ModelSpec(
            ToyStockWriterModel(4);
            name=:initial_stock,
            on=One(scale=:Organ),
        ),
        ModelSpec(
            ToyStockWriterModel(8);
            name=:adjusted_stock,
            on=One(scale=:Organ),
            updates=Updates(:stock; after=:initial_stock),
        ),
        ModelSpec(
            ToyStockWriterModel(99);
            name=:alternative_stock,
            on=One(scale=:Organ),
            output_routing=(stock=:stream_only,),
        ),
    ),
)

select(
    DataFrame(Diagnostics.explain_writers(writer_model)),
    :object_id,
    :variable,
    :application_ids,
    :update_application_ids,
    :update_after,
)
```

`initial_stock` owns the first canonical write and `adjusted_stock` explicitly
updates it afterward. The alternative value is useful as a retained comparison
but must not replace canonical status, so `output_routing` marks it
`:stream_only`.

```@example journey_advanced_execution
writer_simulation = run!(writer_model; outputs=:all)
(
    canonical_stock=final_state(writer_simulation).stock,
    published=collect_outputs(
        writer_simulation,
        :reserve,
        :stock;
        sink=nothing,
    ),
)
```

The canonical result is `8`; the three application-specific streams retain
`4`, `8`, and `99`. A stream-only output is not a fallback writer and is not
selected by an application-free `OutputRequest`; request its application
explicitly when retaining only selected outputs.

## Page recap

- **You added:** one declared hard call, selective trials, one accepted
  publication, explicit update ordering, and one stream-only alternative.
- **PlantSimEngine inferred:** the call-only schedule, concrete targets,
  canonical writer ownership, and update edge.
- **You keep explicit:** when each target runs, `publish`, per-target forcing,
  intentional duplicate writers, and non-canonical streams.
- **New API names:** `calls`, `call_targets`, `run_call!`, `CallTargets`,
  `Updates`, `output_routing`, and `:stream_only`.
