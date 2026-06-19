# Manual Calls Across Objects

Declare parent-owned execution with `Calls(:name => One(...))` or
`Calls(:name => Many(...))`. In the kernel, obtain the resolved target from the
`SceneRunContext` and invoke `run_call!`. A target used only by calls is absent
from root scheduling.

Explicit target cadence must match the caller. A target without an explicit
cadence inherits the caller's invocation timing. Structural mutations are
recompiled between timesteps, so new or removed objects affect calls on the
next timestep, never recursively inside the mutation-producing kernel call.

