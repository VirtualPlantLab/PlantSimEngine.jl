# Environment Backend Extensions

An **environment backend** connects a source of weather or spatial data to
PlantSimEngine. It may provide weather records, canopy layers, a grid, or
voxels (three-dimensional cells). This page explains how to write one. To use
an existing backend in a simulation, start with
[Understand Environments](../../journeys/users/environments.md).

## Define a backend

Define your backend as a subtype of
`PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend` and extend
functions in `PlantSimEngine.EnvironmentAPI`. Define its types in your
extension package, including the **handle** type. A handle stores the location
or data needed to read the environment for one model on one object. For
example, it might contain the canopy layer used by a leaf. PlantSimEngine
keeps this handle so it does not need to find that layer on every step.

The required methods are:

- `base_step_seconds(backend)`: duration of one base step;
- `get_nsteps(backend)`: available number of steps;
- `bind_environment(backend, object, context, config)`: create the handle for
  one model application on one object;
- `sample(backend, handle, variable, time)`: read a value from the stored,
  accepted environment state.

Implement `environment_variables(backend)` if you can list the available
variable names without an expensive calculation. PlantSimEngine can then
check that the required names exist when it prepares the simulation.

Add these methods if your backend needs to support trials, saved changes,
or changes to the plant structure:

- `sample(backend, handle, trial_state, variable, time)`: read from a trial
  environment supplied to `run_call!`, without changing the stored environment;
- `commit_environment!(backend, handle, accepted_state, time)`: save accepted
  environment values;
- `update_index!(backend, changed_entities, removed_object_ids)`: update how
  objects are found in space after a structure or geometry change. The first
  call supplies all objects; later calls supply only the changes.

[`ToySpatialEnvironment`](@ref) is the small, tested implementation used by
the user journeys.

## Find each object's data once

`bind_environment` receives the `Object` that will use the environment, an
`EnvironmentAPI.EnvironmentContext`, and the settings from `Environment(...)`.
Use them to find where this object reads its values and, if needed, where it
saves changes. For example, find the leaf's voxel or canopy layer here. Return
a concrete handle containing everything needed for later reads and writes.

PlantSimEngine stores that handle and passes it directly to `sample` each time.
To keep repeated reads fast, avoid searching all objects or recalculating
their locations in `sample`.
`EnvironmentContext` contains application id, object id, scale, and process;
it does not include the object's current status values.

A controller that reads one data source and writes to another can store both
locations in its handle. For example, the scenario may configure
`Environment(provider=:forcing, sink=:canopy)`, while the backend decides what
those names mean.

## Try values, then save accepted changes

Trying a value and saving it are separate operations:

1. A controller passes a trial environment to
   `run_call!(context, name; environment=trial_state, publish=false)`;
2. PlantSimEngine calls the trial version of `sample` using each target's
   stored handle, so each target reads the trial at its own location.
3. The controller accepts a solution and calls
   `commit_environment!(context, accepted_state)`;
4. PlantSimEngine checks that `environment_outputs_` allows the controller to
   change those variables, then calls the backend's commit method using the
   controller's handle.
5. The controller runs the called models with `publish=true` to record their
   accepted outputs.

Model code calls `PlantSimEngine.commit_environment!(context, state)`. Your
backend extends the separate function
`PlantSimEngine.EnvironmentAPI.commit_environment!`; use that full name when
defining its method in an extension package.

## Update locations and check the results

Before creating or updating affected handles, PlantSimEngine calls
`update_index!` once for each spatial backend. Moving an object or changing
its geometry requires an updated handle. Adding, removing, or reparenting
objects can also change which objects a model runs on.

Use these functions to inspect your backend:

- `validate_environment_inputs(model)` checks that required variables exist;
- `Diagnostics.explain_environment_bindings(model)` reports each
  application/object handle and geometry source;
- `Diagnostics.explain_environment(simulation)` reports the active backend,
  variables, step count, and base-step duration.

Test at least two objects that need different local values. Check that your
backend reads both stored and trial values correctly, rejects writes to
undeclared variables, and updates handles when objects move or their geometry
changes.
