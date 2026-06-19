# Runtime Contracts And Diagnostics

Use `explain_initialization`, `explain_bindings`, `explain_calls`,
`explain_schedule`, `explain_environment_bindings`, and
`explain_output_retention` as the supported inspection surface. Do not inspect
compiled internal fields.

Targets, carriers, calls, writer checks, and schedules refresh after structural
changes between timesteps. Movement and geometry changes invalidate affected
spatial environment bindings. Accepted streams are append-only.

