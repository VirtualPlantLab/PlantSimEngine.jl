# Control Advanced Execution

## Let one model control another's calculations

Use `inputs` when a model simply needs a value calculated by another model.
Sometimes a model also needs to control when the other model runs, or repeat
its calculation several times. For example, a heat-balance solver might try
several leaf temperatures before accepting a result. PlantSimEngine calls
this a **hard call**. You declare it with `calls` and run it with `run_call!`.

## Choose which models the controller can call

Start with one plant and two leaves. A controller on the plant can call a
temperature reader on either leaf. In this example, the readers run only when
the controller calls them; the simulation does not also run them separately.
The `Diagnostics.explain_calls` table shows which leaves the controller can
call:

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

`run_call!(context, :readers)` runs the reader for every selected leaf and
returns a `CallTargets` collection that you can loop over. Even `One` returns
a collection, containing one target. `OptionalOne` returns zero or one target;
`Many` returns zero or more.

## Try several values and save the accepted result

The controller in this example wants to run only the sun leaf's reader.
`call_targets(context, :readers)` lists the available targets without running
them. The controller counts both leaves, selects `:sun_leaf`, tries two
temperatures, then records one accepted result. The repeated calls follow
this pattern:

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

`publish=false` is the default. Each trial updates the called model's status,
so the controller can inspect it and decide whether to continue. The trial
does not add a result to the output history or save changes to the environment.
Use `publish=true` for the accepted calculation.

```@example journey_advanced_execution
simulation = run!(model; outputs=:all)
(
    controller=final_state(simulation, :plant),
    leaves=final_state(simulation, Many(scale=:Leaf)),
)
```

The controller found two leaves but ran only `:sun_leaf`. It selects that leaf
by ID with `call_targets(context, name; objects=(ObjectId(:sun_leaf),))`,
so changing the order of the leaves would not change the selection. The two
trials were not recorded. The accepted calculation recorded one result, and
the reader on `:shade_leaf` did not run:

```@example journey_advanced_execution
filter(
    row -> row.application_id == :reader,
    DataFrame(Diagnostics.explain_outputs(simulation)),
)
```

There are two ways to supply trial conditions:

- `run_call!(context, name; environment=trial_state)` lets each target read
  its own local values from the trial environment. Use this when, for example,
  a trial canopy temperature field gives different values to different leaves.
- `run_call!(context, name; sampled_environment=value)` passes values you have
  already chosen, such as `(T=22.0,)`, directly to all targets.

Both forms run all selected targets together. Use `call_targets` followed by
`run_call!(target; sampled_environment=...)` when you need to choose individual
targets, change their order, inspect their status, or give each one different
values. For a call with one target, `call_model(context, name)` gives access to
the model itself, for example to read a parameter. It preserves the concrete
model type and does not allocate memory.

## Let two models update the same value

Normally, only one model may set a given variable on an object. If two models
both set `stock`, PlantSimEngine needs to know which value to keep. If the
second model is meant to change the first model's result, use `Updates` to
specify their order. Without that instruction, this configuration is rejected
before either model runs:

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

`initial_stock` sets `stock` first, then `adjusted_stock` changes it. The third
model calculates an alternative value that we want to keep for comparison.
`output_routing=(stock=:stream_only,)` records that alternative in its own
output history without replacing the object's `stock` value.

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

The object's final `stock` is `8`. The three models' output histories keep
their respective values: `4`, `8`, and `99`. The `:stream_only` setting never
lets the alternative replace the stored `stock`, even if no other model sets
it. If you use `OutputRequest` to save selected results, name
`:alternative_stock` explicitly to retain its output; requesting `stock`
without an application name does not select this alternative.
