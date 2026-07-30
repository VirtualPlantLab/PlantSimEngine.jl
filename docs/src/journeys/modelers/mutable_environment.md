# Implement A Mutable Environment Controller

**New concept:** accepted mutable environment state. A controller declares
which variables it may commit, evaluates typed trial states, and commits one
accepted state explicitly.

Simulation users first encounter this workflow in
[Modify The Environment](@ref). Backend packages implement the separate
[Environment Backend Extensions](@ref) contract.

The plain Julia blocks below are excerpts from the shipped, tested
`ToyEnvironmentControllerModel`.

## Model 9: declare commit permission

`ToyEnvironmentControllerModel` declares its reader hard dependency and the
environment variable it may commit:

```julia
PlantSimEngine.dep(::ToyEnvironmentControllerModel) = (
    reader=Call(One(process=:toy_environment_reader)),
)
PlantSimEngine.environment_outputs_(
    model::ToyEnvironmentControllerModel,
) = (T=zero(model.accepted_temperature),)
```

Its tested kernel keeps trial, commit, and accepted publication separate:

```julia
trial_environment = (T=model.trial_temperature,)
trial_target = only(run_call!(
    context,
    :reader;
    environment=trial_environment,
    publish=false,
))

accepted_environment = (T=model.accepted_temperature,)
commit_environment!(context, accepted_environment)
accepted_target = only(run_call!(
    context,
    :reader;
    environment=accepted_environment,
    publish=true,
))
```

`environment_outputs_` is commit permission, not object-status output.
PlantSimEngine validates that the accepted state provides every declared
variable before invoking the backend through the controller's compiled handle.

## Compose the controller

The reader needs only a provider. The controller additionally receives
`sink=:cells`; the backend defines what that sink means:

```@example modeler_mutable_environment
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

environment = ToySpatialEnvironment(
    Dict(:canopy => (T=20.0,));
    step_seconds=3600.0,
)
model = CompositeModel(
    Object(
        :leaf;
        scale=:Leaf,
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
            environment=Environment(
                backend=environment,
                sink=:cells,
            ),
        ),
    ),
)

(
    call=DataFrame(Diagnostics.explain_calls(model)),
    environment=DataFrame(
        Diagnostics.explain_environment_bindings(model),
    ),
)
```

```@example modeler_mutable_environment
simulation = run!(model; outputs=:all)
(
    final=final_state(simulation),
    committed=environment.cells[:canopy],
    publications=filter(
        row -> row.application_id == :reader,
        DataFrame(Diagnostics.explain_outputs(simulation)),
    ),
)
```

The rejected `T=30` trial mutates only the reader's trial status. The accepted
`T=22` state is committed once and produces the reader's only retained sample.
If the controller itself runs as an unpublished ancestor call, PlantSimEngine
also suppresses its descendant publications and environment writes.

## Model-author recap

- **You implemented:** declared commit variables, typed trial construction,
  acceptance logic, explicit commit, and one accepted publication.
- **PlantSimEngine inferred:** permission validation, backend/handle routing,
  nested trial suppression, and retained output history.
- **The scenario author keeps explicit:** provider, commit sink, concrete
  backend, and any hard-call override.
- **New API names:** `environment_outputs_`, `commit_environment!`,
  `Environment`, `environment`, and `publish`.
