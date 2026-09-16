# Modify The Environment

## Try a value before keeping it

Some models need to try several temperatures before choosing a solution.
For example, a model might adjust canopy air temperature until its heat
balance is close enough to zero. A **controller** is a model that manages
these repeated calculations.

This teaching example shows how to try one temperature, then keep a different
one. It does not solve a heat balance: the trial and final temperatures are
chosen in advance. **Committing** the final value means writing it back to
the environment so that later calculations can use it.

Start with one spatial cell. `ToyEnvironmentReaderModel` reads temperature
`T` from the environment. The controller declares `T` with
`environment_outputs_` to say that it may change this environment variable.
This declaration does not add `T` to the leaf's stored status.

```@example journey_mutable_environment
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

(
    reader_inputs=PlantSimEngine.environment_inputs_(
        ToyEnvironmentReaderModel(),
    ),
    controller_commit_permissions=PlantSimEngine.environment_outputs_(
        ToyEnvironmentControllerModel(30.0, 22.0),
    ),
)
```

The first function asks the reader to calculate a result using a trial
environment. You can inspect that result in the reader's status.
`publish=false` prevents it from being added to the output history, and this
call does not change the stored environment:

```@example journey_mutable_environment
function run_trial!(context, trial_environment)
    return only(run_call!(
        context,
        :reader;
        environment=trial_environment,
        publish=false,
    ))
end
```

After choosing a final value, save it in the environment with
`commit_environment!`. Then run the reader with `publish=true` to record
its accepted result:

```@example journey_mutable_environment
function commit_and_publish!(context, accepted_environment)
    commit_environment!(context, accepted_environment)
    return only(run_call!(
        context,
        :reader;
        environment=accepted_environment,
        publish=true,
    ))
end
```

`ToyEnvironmentControllerModel` performs these two operations in its `run!`
function. The `calls` setting below lets it run the reader. Only the controller
has `sink=:cells`, which tells the environment where to save the accepted
temperature:

```@example journey_mutable_environment
environment = ToySpatialEnvironment(
    Dict(:canopy => (T=20.0,));
    step_seconds=3600.0,
)

model = CompositeModel(
    Object(
        :leaf;
        scale=:Leaf,
        kind=:leaf,
        geometry=(cell=:canopy,),
    );
    applications=(
        ModelSpec(
            ToyEnvironmentReaderModel();
            name=:reader,
            on=One(scale=:Leaf),
            environment=Environment(backend=environment),
        ),
        ModelSpec(
            ToyEnvironmentControllerModel(30.0, 22.0);
            name=:controller,
            on=One(scale=:Leaf),
            calls=(
                :reader => One(
                    scale=:Leaf,
                    application=:reader,
                ),
            ),
            environment=Environment(
                backend=environment,
                sink=:cells,
            ),
        ),
    ),
)

simulation = run!(model; outputs=:all)
state = final_state(simulation)
(
    trial_seen=state.trial_temperature_seen,
    accepted_seen=state.accepted_temperature_seen,
    committed=environment.cells[:canopy].T,
)
```

The reader tried 30 °C, then used the accepted value of 22 °C. The environment
now stores 22 °C. The table below shows that the reader recorded only its
accepted result:

```@example journey_mutable_environment
select(
    DataFrame(Diagnostics.explain_outputs(simulation)),
    :application_id,
    :variable,
    :nsamples,
)
```

## Give each leaf its own local conditions

Now give one leaf a sunny cell and the other a shaded cell. `Many(scale=:Leaf)`
runs the same reader on both leaves, but each leaf reads its own cell's
temperature:

```@example journey_mutable_environment
spatial_environment = ToySpatialEnvironment(
    Dict(
        :sun => (T=26.0,),
        :shade => (T=18.0,),
    );
    step_seconds=3600.0,
)

spatial_model = CompositeModel(
    Object(
        :sun_leaf;
        scale=:Leaf,
        geometry=(cell=:sun,),
    ),
    Object(
        :shade_leaf;
        scale=:Leaf,
        geometry=(cell=:shade,),
    );
    applications=(
        ModelSpec(
            ToyEnvironmentReaderModel();
            name=:temperature,
            on=Many(scale=:Leaf),
            environment=Environment(backend=spatial_environment),
        ),
    ),
)

spatial_simulation = run!(spatial_model)
spatial_states = final_state(spatial_simulation, Many(scale=:Leaf))
Dict(id => state.temperature_seen for (id, state) in spatial_states)
```

The sun leaf reads 26 °C and the shade leaf reads 18 °C. A **handle** stores
the cell used by each leaf. You can check that the two handles are different:

```@example journey_mutable_environment
select(
    DataFrame(Diagnostics.explain_environment_bindings(spatial_model)),
    :object_id,
    :handle,
)
```

For a larger example that adjusts canopy air conditions and repeats leaf
calculations across several plants, see [MAESPA-Style Synthesis](@ref).
To connect your own source of environmental data, see
[Environment Backend Extensions](@ref).
