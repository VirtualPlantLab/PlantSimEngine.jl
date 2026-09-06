# Implement A Mutable Environment Controller

Some models also change their environment. A canopy energy-balance model,
for example, may try several temperatures before deciding which temperature
other models should use. A model that manages these trials is called a
**controller**.

This teaching example uses prescribed temperatures to explain that sequence.
It does not implement a physical canopy solver. Start with
[Modify The Environment](@ref) for the scenario perspective and
[Implement A Hard Dependency](@ref) for model calls.

## Declare the accepted values you can write

A controller declares both the model it calls and the environmental variables
it may update. Here `environment_outputs_` names temperature `T`. These are
the actual declarations in `examples/ToySpatialEnvironment.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "PlantSimEngine.inputs_(::ToyEnvironmentControllerModel)",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

The variables in `outputs_` record the temperatures seen during the
calculation. The variable in `environment_outputs_` is the temperature the
controller may change in the shared environment.

## Evaluate a trial, then commit an accepted state

The controller's implementation makes the sequence explicit:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

The first call gives the reader a trial temperature. Its result is not saved
as an accepted output sample. `commit_environment!` then stores the accepted
temperature in the shared environment. The final reader call saves the
result calculated at that temperature.

For a scientific controller, you must choose how to calculate trials and
when to accept a solution. You must also handle any values changed by a
rejected trial: `publish=false` does not restore them automatically.

## Connect the controller to a provider

An **environment provider** supplies data such as temperature to the models.
This example stores temperature in a named canopy cell. The reader can read
that temperature. The controller also gets `sink=:cells`, which allows it to
write accepted temperatures into the provider's cells.

```@example modeler_mutable_environment
using Test, PlantSimEngine
using PlantSimEngine.Examples

environment = ToySpatialEnvironment(
    Dict(:canopy => (T=20.0,)); step_seconds=3600.0,
)
controller = ToyEnvironmentControllerModel(30.0, 22.0)
model = CompositeModel(
    Object(:leaf; scale=:Leaf, geometry=(cell=:canopy,));
    applications=(
        ModelSpec(
            ToyEnvironmentReaderModel();
            name=:reader, on=One(scale=:Leaf),
            environment=Environment(backend=environment),
        ),
        ModelSpec(
            controller;
            name=:controller, on=One(scale=:Leaf),
            environment=Environment(backend=environment, sink=:cells),
        ),
    ),
)

simulation = run!(model; outputs=:all)
state = final_state(simulation)
@test state.trial_temperature_seen == 30.0
@test state.accepted_temperature_seen == 22.0
@test environment.cells[:canopy].T == 22.0
(
    trial=state.trial_temperature_seen,
    accepted=state.accepted_temperature_seen,
    committed_temperature=environment.cells[:canopy].T,
)
```

The temperature starts at 20, the trial uses 30, and the accepted value is 22.
Use `Diagnostics.explain_environment_bindings(model)` to check where models
read and write environmental data. `Diagnostics.explain_outputs(simulation)`
shows the saved results.

When accepting a solution, supply a value for every variable declared in
`environment_outputs_`. If another controller calls this one as a trial with
`publish=false`, none of its nested calls can save accepted output samples
or change the shared environment.

To add a new kind of spatial environment provider, see
[Environment Backend Extensions](@ref). When writing a process model, you
can normally use an existing provider through `Environment` and the call
and commit functions shown here.
