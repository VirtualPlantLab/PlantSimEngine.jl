# Manual Calls Across Objects

Declare parent-owned execution with `Calls(:name => One(...))` or
`Calls(:name => Many(...))`. In the kernel, execute every resolved target with
`run_call!(context, :name)`. The returned `CallTargets` collection is always
vector-like, including for `One` and `OptionalOne`. Use
`call_targets(context, :name)` followed by `run_call!(target)` for selective,
per-target, or iterative execution. A target used only by calls is absent from
root scheduling.

Explicit target cadence must match the caller. A target without an explicit
cadence inherits the caller's invocation timing. Structural mutations are
recompiled after the application that made the change. New or removed objects
therefore affect later applications in the current timestep, but never
recursively affect the mutation-producing kernel call itself.
