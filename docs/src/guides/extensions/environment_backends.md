# Environment Backend Extensions

This page is for package authors who connect a meteorology, canopy-layer,
voxel, grid, or other spatial provider to PlantSimEngine. Simulation users
normally configure an existing backend with `Environment(...)` and do not need
this protocol.

## The boundary

An extension backend subtypes
`PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend` and extends
functions in `PlantSimEngine.EnvironmentAPI`. Keep the concrete backend and
handle types in the extension package. They do not belong in PlantSimEngine's
root namespace.

The required methods are:

- `base_step_seconds(backend)`: duration of one base step;
- `get_nsteps(backend)`: available number of steps;
- `bind_environment(backend, object, context, config)`: compile one opaque
  handle for an application/object pair;
- `sample(backend, handle, variable, time)`: read committed state.

Implement `environment_variables(backend)` when the variable names can be
enumerated cheaply. PlantSimEngine then validates model environment inputs
while compiling.

Mutable or structurally indexed backends add only the capabilities they need:

- `sample(backend, handle, trial_state, variable, time)` for transient trial
  states supplied to `run_call!`;
- `commit_environment!(backend, handle, accepted_state, time)` for accepted
  state;
- `update_index!(backend, entities)` when topology or geometry changes require
  rebuilding a spatial index.

[`ToySpatialEnvironment`](@ref) is the small, tested implementation used by
the user journeys.

## Compile routing into the handle

`bind_environment` receives the target `Object`, an
`EnvironmentAPI.EnvironmentContext`, and the payload configured with
`Environment(...)`. Resolve geometry, layer, voxel, provider, and commit sink
there. Return a concrete handle containing everything later sampling and
committing need.

PlantSimEngine caches that handle. The hot `sample` methods receive it directly,
so they should not search the object registry or repeat spatial routing.
`EnvironmentContext` contains application id, object id, scale, and process;
runtime status is deliberately absent.

A controller that reads one provider and writes another can encode both routes
in its handle. For example, the scenario may configure
`Environment(provider=:forcing, sink=:canopy)`, while the backend decides what
those names mean.

## Trial and commit semantics

Transient sampling and committing are separate backend operations:

1. a controller passes its typed trial state to
   `run_call!(context, name; environment=trial_state, publish=false)`;
2. PlantSimEngine invokes the transient `sample` overload through each target's
   already-compiled handle;
3. the controller accepts a state and calls
   `commit_environment!(context, accepted_state)`;
4. PlantSimEngine validates the caller's `environment_outputs_` declaration,
   then invokes the backend commit through the caller's handle;
5. the controller publishes accepted called-model outputs explicitly with
   `publish=true`.

The model-facing `commit_environment!(context, state)` is root API. The
backend-facing method belongs to `PlantSimEngine.EnvironmentAPI`; extension
packages should qualify it when adding methods.

## Refresh and diagnostics

PlantSimEngine calls `update_index!` once per distinct spatial backend before
binding or rebinding affected targets. Geometry changes invalidate the affected
handles; structural changes can also change the set of bound targets.

Use these public checks instead of reading compiler fields:

- `validate_environment_inputs(model)` checks declared variables;
- `Diagnostics.explain_environment_bindings(model)` reports each
  application/object handle and geometry source;
- `Diagnostics.explain_environment(simulation)` reports the active backend,
  variables, step count, and base-step duration.

Backend tests should cover at least two objects with distinct handles,
committed and transient sampling, rejected undeclared commits, and handle
refresh after movement or geometry changes.
