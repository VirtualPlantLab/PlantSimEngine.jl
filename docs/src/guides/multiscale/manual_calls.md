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

Explicit target cadence must match the caller. A target without an explicit
cadence inherits the caller's invocation timing.
