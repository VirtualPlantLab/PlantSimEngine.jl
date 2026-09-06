# Manual Calls Across Objects

Some calculations need to control when another model runs. For example, a
plant model may need to run its leaf models several times while solving an
energy balance. Declare the models it can call with
`ModelSpec(model; calls=(:name => One(...),))`, using `Many(...)` to select
several objects. Inside its `run!` function, call
`run_call!(context, :name)` to run all the selected models. The returned
`CallTargets` is a collection, even when `One` or `OptionalOne` selects a
single object.

Choose how to make the call according to what your calculation needs:

- `run_call!(context, :name; sampled_environment=environment)` executes all
  selected models with the same environmental values. Use it when you have
  already prepared the values each model needs. PlantSimEngine groups these
  calls for efficient execution.
- `call_model(context, :name)` returns the model when the call selects exactly
  one target. Use it to inspect the model's type or parameters before running
  the calculation.
- `call_targets(context, :name)` followed by `run_call!(target)` supports
  running selected objects individually. Use it to choose their order,
  inspect their values, or supply different environmental values to each one.

The two environment keywords serve different purposes.
`environment=trial_state` supplies a trial version of the environment, from
which PlantSimEngine retrieves the conditions at each selected object.
`sampled_environment=value` supplies the environmental variables directly in
the form the model reads, so no further sampling occurs.

A model used only through these calls does not also run independently from
the simulation schedule. Calls default to `publish=false`, so trial results
are not saved in the output history. Use `publish=true` for the accepted
calculation.

## Initialize a newly registered object

Suppose a leaf model has already run for this timestep and a growth model
then creates a new leaf. The growth model can use `Initializer` to run that
leaf model once on the new leaf. The leaf model still runs normally from the
simulation schedule on other timesteps. Declare the initializer in the
growth model's `calls`, then pass the new object to `run_initializer!`:

```julia
creator = ModelSpec(
    GrowthModel();
    name=:growth,
    on=One(scale=:Plant),
    calls=(
        leaf_state=Initializer(
            One(
                scale=:Leaf,
                within=Subtree(),
                application=:leaf_state,
            ),
        ),
    ),
)

function PlantSimEngine.run!(::GrowthModel, status, environment, constants, context)
    leaf = register_object!(
        runtime_model(context),
        Object(:new_leaf; scale=:Leaf, parent=object_id(context)),
    )
    initialized_status = run_initializer!(context, :leaf_state, leaf)
    return nothing
end
```

By default, a call from a plant searches `Self()`, the plant object itself.
Set `within=Subtree()` to find a new leaf below it. A model that creates
objects anywhere in the scene can instead use `within=SceneScope()`.

### Scheduling and supported inputs

Name the target application explicitly with `application=`. That application
must select objects with `on=Many(...)` and run at exactly the same interval
and phase as the creator. The phase is the offset at which the repeating
schedule starts.

PlantSimEngine schedules the target application before the creator. For
models that need its new output in the same step, it schedules the relevant
calculation after the creator:

| How the reading model runs | What must run after the creator |
|---|---|
| Directly from the simulation schedule | The reading model itself |
| Through hard calls | The scheduled controller at the top of its call chain |
| As another initializer target | That target's creator |

If one creator calls two initializers and the second needs the first's
output, the creator must call them in that order inside its `run!` function.
PlantSimEngine cannot reorder statements inside your function.

An initializer supports the global environment and writes the new object's
own status values. These are its **canonical outputs**: the current values
other models normally read, as opposed to saved output history. It may read
current inputs or use `PreviousTimeStep`, including inputs supplied to the
object by another application's `outputs_to`.

The following restrictions apply to the target application:

- It cannot make nested calls, write to other objects through `outputs_to`,
  or produce outputs marked `stream_only`.
- Its input time policies are limited to `PreviousTimeStep`; it cannot use
  `HoldLast`, `Interpolate`, `Integrate`, or `Aggregate`.
- It cannot also be owned by an ordinary manual call or by a second creator.
- No other application may write its canonical outputs, either locally or
  through `outputs_to`. `Updates` does not relax this restriction: the
  initializer runs inside its creator, outside the target's normal slot.

### Reading initialized values

Other models can read the new values directly later in the same timestep.
They cannot read them through a time policy: `run_initializer!` does not add
a sample to the output history partway through a step. PlantSimEngine
therefore rejects downstream `HoldLast`, `Interpolate`, `Integrate`,
`Aggregate`, and `PreviousTimeStep` connections to an initializer's output.
This restriction applies to those connections altogether, not just to the
first step.

There is a distinction between an initializer **reading** a
`PreviousTimeStep` input, which is supported with a fallback for the new
object, and another model trying to read the initializer's **output** through
`PreviousTimeStep`, which is not supported. If you need output history, have
a separate scheduled application publish the value and read that
application's history on a later timestep.

### Initialize each new object once

`run_initializer!` runs only on the new object you pass to it. The declaration
identifies and checks the application in advance; it does not build a
collection of existing objects to run.

The call changes the new object's `Status` and returns it, without saving an
extra history sample. It accepts exactly one object created during the
current addition event, and that event must contain only additions. Existing
objects, reparented objects, objects from another simulation, or objects that
require a full structural refresh first are rejected.

You may initialize a given application/object pair only once. PlantSimEngine
marks the pair before running the model, so if the model fails after changing
some values, you cannot retry it in the same event. Use ordinary `Call` and
`run_call!` when you need trial calculations or repeated calls.

## Compiled plans and changing objects

When preparing the simulation, PlantSimEngine checks each call declaration
and prepares how it will execute. The call name, selected applications,
selector rules, `One`/`Many` requirement, execution order, and model groups
stay fixed. Ordinary calls reuse this preparation instead of searching for
objects again every time they run.

The objects themselves may still be added, removed, or reparented during
growth. After the model making a structural change finishes, PlantSimEngine
updates the affected object lists. Applications later in the same timestep
use the updated lists; applications that already ran are not repeated. On
the next timestep, calls reuse the updated preparation.

To call a newly created object before that update,
`call_targets(context, name; objects=newborn)` can select it directly if the
pending changes only add objects. If the same event also removes or
reparents an object, this call first updates all affected model connections
and environment lookups. This ensures that selection uses the current plant
structure, but the extra work takes place inside your model's `run!`
function, and those pending changes are then marked as processed.
`run_initializer!` is stricter: it rejects events that mix additions with
removal or reparenting.

If the called model declares its own execution interval, it must match the
caller's. Otherwise it follows the caller's timing.
