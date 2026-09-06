# Implement A Mutable Environment Controller

**New concept:** accepted mutable environment state. A controller declares
which variables it may commit, evaluates typed trial states, and commits one
accepted state explicitly.

Simulation users first encounter this workflow in
[Modify The Environment](@ref). Backend packages implement the separate
[Environment Backend Extensions](@ref) contract.

The examples below execute the shipped, tested
`ToyEnvironmentControllerModel`.

## Model 9: declare commit permission

`ToyEnvironmentControllerModel` declares its reader hard dependency and the
environment variable it may commit:

```@example modeler_mutable_environment
using PlantSimEngine, DataFrames
using PlantSimEngine.Examples

controller = ToyEnvironmentControllerModel(30.0, 22.0)
(
    dependency=PlantSimEngine.dep(controller),
    commit_schema=PlantSimEngine.environment_outputs_(controller),
)
```

Its tested kernel keeps trial, commit, and accepted publication separate. It
runs the reader against the trial environment with `publish=false`, calls
`commit_environment!` only for the accepted environment, then publishes one
accepted reader execution. The complete scenario below executes that source
instead of repeating it as an unchecked excerpt.

`environment_outputs_` is commit permission, not object-status output.
PlantSimEngine validates that the accepted state provides every declared
variable before invoking the backend through the controller's compiled handle.

## Compose the controller

The reader needs only a provider. The controller additionally receives
`sink=:cells`; the backend defines what that sink means:

```@example modeler_mutable_environment
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
            controller;
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
