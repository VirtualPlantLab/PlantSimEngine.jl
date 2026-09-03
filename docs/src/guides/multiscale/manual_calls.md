# Manual Calls Across Objects

Declare parent-owned execution with
`ModelSpec(model; calls=(:name => One(...),))` or a `Many(...)` selector. In
the kernel, execute every resolved target with `run_call!(context, :name)`.
The returned `CallTargets` collection is always vector-like, including for
`One` and `OptionalOne`.

Use the narrowest execution path that matches the algorithm:

- `run_call!(context, :name; sampled_environment=environment)` executes all
  targets directly through cached typed batches. Prefer it when the caller has
  already sampled one model-facing environment for every target.
- `call_model(context, :name)` returns the concrete model for a call that
  resolves to exactly one target. It is useful when dispatch or model
  parameters must be inspected before the bulk call.
- `call_targets(context, :name)` followed by `run_call!(target)` supports
  object selection, custom ordering, target status inspection, or a different
  sampled environment per target.

`environment=trial_state` has different semantics from
`sampled_environment=value`. The former is a transient backend state that each
target samples through its compiled environment handle. The latter is already
in the model-facing form and is forwarded without sampling.

A target used only by calls is absent from root scheduling. Trial calls default
to `publish=false`; publish only an accepted execution.

## Initialize a newly registered object

Use `Initializer`, not an ordinary manual `Call`, when the target application
must remain in the root schedule but a creator needs to run it once on a new
object after its normal slot already passed:

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

Initializer selectors follow the ordinary contextual-scope rules. A call from
a plant object defaults to `Self()`, so a creator targeting a new descendant
must state `within=Subtree()` explicitly. A scene creator may instead use
`within=SceneScope()` when the target is scene-wide.

The target application must use `on=Many(...)`, an explicit `application=`,
and exactly the caller's cadence and phase. It remains root-scheduled and owns
its canonical outputs. The compiler orders it before the creator and orders
the execution owners of same-step consumers after the creator. That owner is
the consumer itself for an ordinary scheduled application, the root hard-call
owner for a manual callee, or the consumer's creator when it is another
initializer target. If both calls belong to the same creator, its kernel must
invoke the initializers in dependency order; there is no meaningful self-edge
to impose that intra-kernel order. Targeted newborn
execution supports the global environment, canonical local outputs,
non-temporal inputs, and `PreviousTimeStep` inputs, including canonical input
sources written through another application's `outputs_to`. It rejects nested
calls, distributed or stream-only outputs on the initializer target itself,
other temporal policies, mixed manual ownership, multiple initializer owners,
and any overlapping local or distributed canonical writer for the target's
outputs. Each initialized output must have one canonical writer; `Updates`
ordering cannot make a later writer safe because targeted execution occurs
inside the creator's kernel.

Only direct, non-temporal downstream consumers may observe the initialized
output later in that same step. `run_initializer!` deliberately publishes no
mid-step stream sample, so the compiler rejects downstream `HoldLast` windows,
`Interpolate`, `Integrate`, `Aggregate`, and `PreviousTimeStep` bindings that
could consume an initializer target's newborn output. This is distinct from a
`PreviousTimeStep` input *used by the initializer itself*, whose newborn
fallback is supported. This first initializer contract does not admit a
temporal downstream binding at all. When later history is required, publish
the value from a distinct scheduled application and consume that application's
history on a later timestep.

An initializer binding stores only its statically validated application
identity. It does not collect pre-existing target objects or build cached
execution batches; `run_initializer!` resolves only the explicit newborn.

`run_initializer!` accepts exactly one object added by the current pure
addition event, mutates its canonical local status without adding a mid-step
output-history sample, and returns that canonical `Status`. A second call for
the same application/object pair is an error. The pair is reserved before the
model runs, so a failed initializer remains marked and cannot be retried after
an unknown partial mutation in the same lifecycle event. Existing, reparented,
foreign, or refresh-fallback targets are also errors. Use ordinary `Call` and
`run_call!` for trial execution or repeated controller-owned calls.

## Compiled plans and changing objects

The call declaration is compiled once with the scenario. Its call name,
applications, selector, multiplicity, ordering, and execution batches remain
fixed during the simulation. Ordinary calls therefore do not resolve selectors
or rebuild public target wrappers in their execution loop.

Objects may still be created, removed, or reparented during growth. At the
structural refresh barrier, PlantSimEngine updates only the affected resolved
target buffers. Later applications in the same timestep see the new targets;
applications that already ran are not repeated. The following ordinary
timestep returns to the cached execution path.

`call_targets(context, name; objects=newborn)` can build a targeted partial
view without crossing that barrier only while the pending lifecycle delta is a
pure addition. If the same event also removes or reparents an object, the
manual-call API performs the full binding and environment refresh before it
resolves the requested objects. This preserves current topology membership but
has the cost of a mid-kernel refresh and consumes the pending dirty state.
`run_initializer!` is stricter: it rejects such a mixed structural event.

Explicit target cadence must match the caller. A target without an explicit
cadence inherits the caller's invocation timing.
