# Modify The Environment

## New concept: trial state versus accepted state

The previous environment journey sampled read-only global and spatial values.
Now a controller evaluates one typed trial state, accepts a different state,
and commits it explicitly.

Start with one cell. `ToyEnvironmentReaderModel` declares `T` as an environment
input. The controller declares `T` as an environment output: this is permission
to commit that variable, not an ordinary object-status output.

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

The controller's kernel uses the current typed trial-state path. A trial call
changes the callee status for inspection but does not publish output history or
commit backend state:

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

Accepted state is explicit and separate:

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

`ToyEnvironmentControllerModel` applies those two operations in its kernel.
Configure the reader as its one hard-call target and give only the controller a
commit sink:

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

The trial was `30`, but the accepted and committed temperature is `22`.
Only the accepted reader call published:

```@example journey_mutable_environment
select(
    DataFrame(Diagnostics.explain_outputs(simulation)),
    :application_id,
    :variable,
    :nsamples,
)
```

## Preserve distinct handles under `Many`

Extend the same backend to two spatial cells. One `Many` application samples
both, while each target retains its own compiled handle:

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

```@example journey_mutable_environment
select(
    DataFrame(Diagnostics.explain_environment_bindings(spatial_model)),
    :object_id,
    :handle,
)
```

This ordinary user page does not require the backend implementation protocol.
Framework builders can follow [Environment Backend Extensions](@ref); the
complete MAESPA-style synthesis later combines mutable microclimate, several
plants, and iterative leaf calls.

## Page recap

- **You added:** one typed trial, one explicit accepted commit, one accepted
  publication, and then two spatial cells.
- **PlantSimEngine inferred:** the reader call target, publication boundary,
  commit permission check, and distinct `Many` handles.
- **You keep explicit:** trial and acceptance logic, `publish`, the committed
  variables, controller sink, and backend state type.
- **New API names:** `environment_outputs_`, `run_call!`,
  `commit_environment!`, `publish`, and `calls`.
