# Implement A Hard Dependency

This page adds one model-author concept: declare a process-level hard
dependency only when the parent kernel must control another model's execution.
Value dependencies should stay in `inputs_`.

Simulation users wire and inspect advanced calls in
[Control Advanced Execution](@ref).

## Model 8: declare and execute the call

`ToySelectiveCallControllerModel` declares a reusable default by process,
scale, and relative scope. It cannot know future application names:

```julia
PlantSimEngine.dep(::ToySelectiveCallControllerModel) = (
    readers=Call(Many(
        scale=:Leaf,
        process=:toy_environment_reader,
        within=Subtree(),
    )),
)
```

Inside `run!`, the controller inspects the vector-like collection, restricts
the declared call by object id, runs trials without publication, and publishes
one accepted execution:

```julia
targets = call_targets(context, :readers)
selected = only(call_targets(
    context,
    :readers;
    objects=(ObjectId(model.selected_object),),
))

for temperature in model.trial_temperatures
    run_call!(
        selected;
        sampled_environment=(T=temperature,),
        publish=false,
    )
end
run_call!(
    selected;
    sampled_environment=(T=model.accepted_temperature,),
    publish=true,
)
```

The source excerpt is exercised by the example-model contract suite. Build a
scenario without a `calls` keyword to use that model default:

```@example modeler_hard_dependency
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
    Object(:plant; scale=:Plant),
    Object(
        :sun_leaf;
        scale=:Leaf,
        parent=:plant,
        geometry=(cell=:sun,),
    ),
    Object(
        :shade_leaf;
        scale=:Leaf,
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
        ),
    ),
)

DataFrame(Diagnostics.explain_calls(model))
```

```@example modeler_hard_dependency
simulation = run!(model; outputs=:all)
(
    controller=final_state(simulation, :plant),
    leaves=final_state(simulation, Many(scale=:Leaf)),
    publications=filter(
        row -> row.application_id == :reader,
        DataFrame(Diagnostics.explain_outputs(simulation)),
    ),
)
```

`origin=:model_default` identifies the `dep(model)` contract. A concrete
scenario can replace it with `ModelSpec(...; calls=...)` when application
identity or target selection differs.

## Model-author recap

- **You implemented:** a process-level `Call` requirement and explicit
  execution inside the parent kernel.
- **PlantSimEngine inferred:** call-only scheduling, resolved targets, nested
  context, and publication boundaries.
- **The scenario author keeps explicit:** application overrides and any
  architecture-specific target choice.
- **New API names:** `dep`, `Call`, `call_targets`, `CallTargets`,
  `run_call!`, `sampled_environment`, and `publish`.
