# Implement A Mutable Environment Controller

Some coupled calculations also update their environment. A canopy controller,
for example, may evaluate a trial temperature before accepting the
environmental state that other processes should use.

This teaching example uses prescribed temperatures to explain that sequence.
It does not implement a physical canopy solver. Start with
[Modify The Environment](@ref) for the scenario perspective and
[Implement A Hard Dependency](@ref) for model calls.

## Declare the accepted values you can write

A controller declares both the model it calls and the environmental variables
it may commit. Here `environment_outputs_` names temperature `T`. These are
the actual declarations in `examples/ToySpatialEnvironment.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "PlantSimEngine.inputs_(::ToyEnvironmentControllerModel)",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

Object outputs record what the controller observed.
`environment_outputs_` separately declares what it may write to the
environment provider.

## Evaluate a trial, then commit an accepted state

The controller's implementation makes the sequence explicit:

```@eval
Main.DocsSources.section(
    "examples/ToySpatialEnvironment.jl",
    "function PlantSimEngine.run!(\n    model::ToyEnvironmentControllerModel,",
)
```

The first call evaluates the reader against a trial environment without
publishing an accepted sample. `commit_environment!` writes the accepted
environmental values; the final reader call publishes the accepted result.

In a scientific controller, the trial calculation and acceptance criterion
belong to your algorithm. Also account for state changed during a rejected
trial: suppressing publication is not a general rollback operation.

## Connect the controller to a provider

The example provider stores temperature in a named canopy cell. The reader
can sample it; the controller additionally receives `sink=:cells`, which
permits the supported write operation for this provider.

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

The provider starts at 20, the trial reads 30, and the accepted value is 22.
Use `Diagnostics.explain_environment_bindings(model)` to inspect the provider
and sink, and `Diagnostics.explain_outputs(simulation)` to inspect retained
samples.

The accepted state must provide every declared environmental output. If the
controller is itself inside an unpublished outer trial, its descendant
publications and environment writes are suppressed too.

A package providing a different spatial environment implements the separate
[Environment Backend Extensions](@ref) interface. A process-model author
normally uses that provider through `Environment` and the public call and
commit operations shown here.
