# Manual Calls Across Objects

Declare parent-owned execution with `Calls(:name => One(...))` or
`Calls(:name => Many(...))`. In the kernel, execute every resolved target with
`run_call!(extra, :name)`. The returned `CallTargets` collection is always
vector-like, including for `One` and `OptionalOne`. Use
`call_targets(extra, :name)` followed by `run_call!(target)` for selective,
per-target, or iterative execution. A target used only by calls is absent from
root scheduling.

Explicit target cadence must match the caller. A target without an explicit
cadence inherits the caller's invocation timing. Structural mutations are
recompiled between timesteps, so new or removed objects affect calls on the
next timestep, never recursively inside the mutation-producing kernel call.
