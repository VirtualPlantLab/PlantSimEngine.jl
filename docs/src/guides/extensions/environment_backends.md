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
   `evaluate_call!(context, name; environment=trial_state)`;
2. PlantSimEngine calls the trial version of `sample` using each target's
   stored handle, or its prepared complete-row method, so each target reads
   the trial at its own location.
3. The controller accepts a solution and calls
   `commit_environment!(context, accepted_state)`;
4. PlantSimEngine checks that `environment_outputs_` allows the controller to
   change those variables, then calls the backend's commit method using the
   controller's handle.
5. The controller calls `accept_call!(evaluation)` to publish the evaluated
   outputs without running those models again.

Model code calls `PlantSimEngine.commit_environment!(context, state)`. Your
backend extends the separate function
`PlantSimEngine.EnvironmentAPI.commit_environment!`; use that full name when
defining its method in an extension package.

`run_call!(...; publish=false)` and `run_call!(...; publish=true)` remain
available when a model should execute without capture, either unpublished or
published immediately. Evaluation/acceptance is useful when an iterative
controller already has the accepted calculation and needs to publish it once.

Commits requested inside an evaluation are deferred until acceptance. They
do not change the backend for subsequent default samples within that
evaluation. Pass the transient state explicitly when descendants need to read
it. A rejected evaluation still changes live model statuses; this protocol
does not roll back arbitrary scientific state or backend side effects.

## Sample a complete row with a prepared schema

The runtime prepares an `EnvironmentAPI.PreparedEnvironmentInputs` for each
application. It stores model-facing names and their aligned backend source
names, with no environmental values. `keys(prepared)` returns the model-facing
names and `values(prepared)` the source names. The default complete-row method
calls your scalar `sample` method for each source through the compiled handle.

For a backend with an efficient whole-row read, specialize:

```julia
EnvironmentAPI.sample_environment(backend, handle, time,
    prepared::EnvironmentAPI.PreparedEnvironmentInputs)
EnvironmentAPI.sample_environment(backend, handle, trial_state, time,
    prepared::EnvironmentAPI.PreparedEnvironmentInputs)
```

Return a row with the prepared model-facing names. Preserve the handle's
provider/location semantics and the target/source remapping. A complete-row
method may validate one shared air state once for that row instead of scanning
all air fields again for each requested variable. It must read current values
on every invocation: reusing a schema or the identity of a mutable trial does
not justify reusing an old value. This hook batches variables for one model
sample; it does not imply one sampling call for every object in the scene.

### One mutable air compartment shared by two leaves

This plumbing example reads temperature and humidity and counts evaluations.
The values are illustrative; no leaf-physiology hypothesis is being tested.
Both leaves use the same air compartment, so the handle needs no spatial
location. A voxel backend would keep a different location in each handle.

```@example prepared_shared_air
using Dates, PlantSimEngine
const EA = PlantSimEngine.EnvironmentAPI

mutable struct SharedAir{T} <: EA.AbstractEnvironmentBackend
    temperature_c::T
    relative_humidity::T
end
EA.base_step_seconds(::SharedAir) = 3600.0
EA.get_nsteps(::SharedAir) = 2
EA.environment_variables(::SharedAir) = Set((:temperature_c, :relative_humidity))
EA.bind_environment(::SharedAir, object::Object, context, config) = nothing
EA.sample(air::SharedAir, handle, variable::Symbol, time) = getproperty(air, variable)
EA.sample(::SharedAir, handle, state::NamedTuple, variable::Symbol, time) =
    getproperty(state, variable)

function air_row(state, prepared::EA.PreparedEnvironmentInputs)
    isfinite(state.temperature_c) || throw(ArgumentError("temperature must be finite"))
    0 <= state.relative_humidity <= 1 || throw(ArgumentError("humidity must be a fraction"))
    return NamedTuple{keys(prepared)}(map(name -> getproperty(state, name), values(prepared)))
end
EA.sample_environment(air::SharedAir, handle, time, prepared::EA.PreparedEnvironmentInputs) =
    air_row(air, prepared)
EA.sample_environment(::SharedAir, handle, state::NamedTuple, time,
    prepared::EA.PreparedEnvironmentInputs) = air_row(state, prepared)
function EA.commit_environment!(air::SharedAir, handle, state, time)
    air.temperature_c = state.temperature_c
    air.relative_humidity = state.relative_humidity
    return nothing
end

PlantSimEngine.@process "docs_shared_air_leaf" verbose=false
struct AirReader <: AbstractDocs_Shared_Air_LeafModel end
PlantSimEngine.environment_inputs_(::AirReader) = (T=0.0, Rh=0.0)
PlantSimEngine.outputs_(::AirReader) = (seen_temperature_c=0.0, seen_humidity=0.0, calls=0)
function PlantSimEngine.run!(::AirReader, status, environment, constants, context)
    status.seen_temperature_c = environment.T
    status.seen_humidity = environment.Rh
    status.calls += 1
    return nothing
end

PlantSimEngine.@process "docs_shared_air_controller" verbose=false
struct AirController <: AbstractDocs_Shared_Air_ControllerModel end
PlantSimEngine.outputs_(::AirController) = (accepted_temperature_c=0.0,)
PlantSimEngine.environment_outputs_(::AirController) = (temperature_c=0.0, relative_humidity=0.0)
PlantSimEngine.dep(::AirController) = (
    leaves=Call(Many(scale=:Leaf, within=Subtree(), process=:docs_shared_air_leaf)),)
function PlantSimEngine.run!(::AirController, status, environment, constants, context)
    trial = (temperature_c=22.0, relative_humidity=0.6)
    evaluated = evaluate_call!(context, :leaves; environment=trial)
    leaves = call_targets(evaluated)
    status.accepted_temperature_c = sum(leaf.status.seen_temperature_c for leaf in leaves) / length(leaves)
    commit_environment!(context, trial)
    accept_call!(evaluated)
    return nothing
end

air = SharedAir(18.0, 0.5)
leaf_spec = ModelSpec(AirReader(); name=:air_reader, on=Many(scale=:Leaf),
    environment=Environment(sources=(T=:temperature_c, Rh=:relative_humidity)))
scenario = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant),
    Object(:leaf_2; scale=:Leaf, parent=:plant);
    applications=(ModelSpec(AirController(); name=:air_controller, on=One(id=:plant)), leaf_spec),
    environment=air)
simulation = run!(scenario; outputs=:all)
leaf_calls = [final_state(simulation, id).calls for id in (:leaf_1, :leaf_2)]
@assert leaf_calls == [1, 1]
(accepted_temperature_c=air.temperature_c, leaf_calls=leaf_calls)
```

The controller evaluates both leaves at the trial air, commits that air, and
publishes their existing evaluations. Each leaf kernel runs once. The accepted
backend is shared, and the prepared schema does not retain its old values:

```@example prepared_shared_air
prepared = EA.PreparedEnvironmentInputs(leaf_spec)
air.temperature_c = 24.0
current_row = EA.sample_environment(air, nothing, 2.0, prepared)
@assert current_row.T == 24.0
current_row
```

For a custom backend, specialize `sample_environment` on the prepared schema
as above. A specialization accepting only a `ModelSpec` is not the runtime
batch hook: direct `ModelSpec` calls prepare a schema before dispatching to
the same prepared method.

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
