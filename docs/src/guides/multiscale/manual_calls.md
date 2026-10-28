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

Use `collect(call_targets(context, :name))` when the calculation needs a
sortable vector. Collection preserves a concrete element type when all targets
have the same type and widens for mixed target types. Empty results use
`Vector{CallTarget}`. To append other target types later, request
`collect(CallTarget, call_targets(context, :name))` explicitly. The vector
contains fresh views sharing the original live status references.

For repeated calculations over the same selection, borrow reusable typed
storage with `with_call_targets`:

```julia
with_call_targets(context, :leaf_energy) do targets
    sort!(targets; by=target -> target.status.leaf_index)
    for target in targets
        run_call!(target; publish=true)
    end
end
```

The engine prepares storage on first use and reuses it on later invocations.
It refills each target with the current time, environment and publication
permission before entering the callback. Changes to membership, models,
bindings or environment type can require new storage. Numerical status values
still use their original shared references.

The vector is borrowed until the callback returns. Sort or inspect it inside
that scope; do not retain or return the vector or an array view of it. A nested
borrow receives separate storage, and exceptions release the lease. Ordinary
`collect` still creates an independent vector when the caller needs ownership.
The callback's result is returned by `with_call_targets`.

Both the collection form and `run_call!(target; ...)` accept the two
environment keywords, which serve different purposes.
`environment=trial_state` supplies a trial version of the environment, from
which PlantSimEngine retrieves the conditions at each selected object through
its own provider and spatial handle. Descendant calls inherit that trial
backend state and sample it through their own bindings.
`sampled_environment=value` supplies the environmental variables directly in
the form the immediate model reads, so no further sampling occurs for that
model. Its descendants keep the inherited backend state; they do not inherit
this already sampled value. The keywords are mutually exclusive.

An individual call returns the same `CallTarget`. An explicit override changes
neither its captured environment nor its timestamp or inherited publication
permission. A later call without an override uses the captured environment.
Obtain targets locally for the current calculation; do not keep them in model
parameters or reuse them across structural lifecycle barriers.

A model used only through these calls does not also run independently from
the simulation schedule. Calls default to `publish=false`, so trial results
are not saved in the output history. Use `publish=true` when executing and
publishing a calculation together. For an iterative solver that has already
evaluated its accepted candidate, use `evaluate_call!` and `accept_call!` to
publish that candidate without running its equations again.

## Accept an evaluated candidate without running it again

`evaluate_call!(context, :name; ...)` runs the selected models and returns a
`CallEvaluation`. Inspect their results through `call_targets(evaluation)`.
Once the solver accepts that candidate, `accept_call!(evaluation)` publishes
its captured outputs and environment commits without another model execution.
To evaluate one individual `CallTarget`, use `evaluate_call!(target; ...)` and
accept the returned token in the same way.

This small example counts actual kernel executions. The counter is an
instrumentation example, not a physiological model: rejected trials still
increment its live count.

```@example manual_evaluation
using Dates, PlantSimEngine

PlantSimEngine.@process "docs_evaluation_counter" verbose=false
struct EvaluationCounter <: AbstractDocs_Evaluation_CounterModel end
PlantSimEngine.outputs_(::EvaluationCounter) = (calls=0,)
function PlantSimEngine.run!(::EvaluationCounter, status, environment, constants, context)
    status.calls += 1
    return nothing
end

PlantSimEngine.@process "docs_evaluation_controller" verbose=false
struct EvaluationController <: AbstractDocs_Evaluation_ControllerModel end
PlantSimEngine.outputs_(::EvaluationController) = (accepted_calls=0,)
function PlantSimEngine.run!(::EvaluationController, status, environment, constants, context)
    evaluate_call!(context, :counter) # First candidate, left unpublished.
    accepted = evaluate_call!(context, :counter)
    counter = only(call_targets(accepted))
    accept_call!(accepted)
    status.accepted_calls = counter.status.calls
    return nothing
end

scenario = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:counter; scale=:Counter, parent=:plant);
    applications=(
        ModelSpec(EvaluationController(); name=:controller, on=One(id=:plant),
            calls=(counter=One(id=:counter, within=Subtree(), application=:counter),)),
        ModelSpec(EvaluationCounter(); name=:counter, on=One(id=:counter)),
    ), environment=(duration=Hour(1),))

simulation = run!(scenario; outputs=:all)
@assert final_state(simulation, :counter).calls == 2
@assert final_state(simulation, :plant).accepted_calls == 2
collect(outputs(simulation)[(:counter, ObjectId(:counter), :calls)])
```

There are two evaluations and one retained sample. Acceptance adds no third
execution. The same pattern applies to a leaf energy solver or a canopy-air
iteration: accept the state whose fluxes were actually evaluated, rather than
an unevaluated proposal for the next iteration.

Evaluation uses the same `environment` and `sampled_environment` keywords as
`run_call!`. The context form also accepts `objects=...` to evaluate a selected
subset. `One`, `OptionalOne` and `Many` keep their target identities and
multiplicity; `call_targets(evaluation)` is always a collection.

### Nested calls and live state

During an evaluation, nested calls requesting `publish=true` stage their
outputs and environment commits. A nested `publish=false` suppresses its
whole descendant call tree. Accepting a child evaluation within an outer
evaluation stages the child's events into the outer one. Nothing is published
until that outer evaluation is accepted with publication permission.

Retained mutable output values are captured when publication is requested, so
a later writer cannot change an earlier writer's sample. This also applies to
private `stream_only` outputs. Evaluation does not copy or roll back the
complete status of the called models: trial equations still change their live
values.
Within an evaluation, temporal inputs can read staged publications from that
evaluation and its ancestors through private read views. These values remain
invisible to ordinary output history until acceptance. Read views allocate
only when staged outputs affect a temporal input; they are not copies of the
whole scene.
Models with state that advances once per physical timestep need their own
scientific trial/accepted-state design.

The existing restriction on distributed outputs still applies: applications
using `outputs_to` must remain root-scheduled and cannot be manual-call-only
targets. Such a scheduled model can evaluate and accept its scalar child
calculations before writing their results through `OutputTargets`.

Accept a token once, on the same task and within its originating synchronous
call tree. Accept only the latest evaluation before rerunning its targets,
advancing the simulation, or changing models, topology, geometry or bindings.
Do not directly mutate its live inputs or statuses between evaluation and
acceptance. To revisit an earlier candidate, save its scientific inputs/state
and evaluate it again; keeping an old token is not a rollback mechanism.

### Shared trial environments

Use `environment=trial_state` when several leaves read one trial air state.
Each leaf keeps its own compiled environment handle; a shared-air backend can
read the same air compartment for every leaf, while a spatial backend can
read different cells. A backend can specialize prepared batch sampling to
read a complete model-facing row; see
[Environment Backend Extensions](../extensions/environment_backends.md).

A controller may commit its accepted air and then accept the evaluated leaves:

```julia
evaluated = evaluate_call!(context, :leaves; environment=evaluated_air)
# Inspect call_targets(evaluated) and decide whether this evaluated air is accepted.
commit_environment!(context, evaluated_air)
accept_call!(evaluated)
```

Commit requests made *inside* an evaluation are deferred. They do not create a
speculative backend overlay for later default sampling. Pass the appropriate
transient state explicitly to descendants that need it. Acceptance is not an
atomic transaction across arbitrary backend side effects; a custom backend
owns the exception semantics of its commit method.

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
