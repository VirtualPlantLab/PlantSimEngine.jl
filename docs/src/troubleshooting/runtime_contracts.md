# Runtime Contracts And Diagnostics

Use `Diagnostics.explain_initialization`, `Diagnostics.explain_bindings`, `Diagnostics.explain_calls`,
`Diagnostics.explain_schedule`, `Diagnostics.explain_environment_bindings`, and
`Diagnostics.explain_output_retention` as the supported inspection surface. Do not inspect
compiled internal fields.

Targets, carriers, calls, writer checks, and schedules refresh after the
application that made a structural change. New objects join applications still
remaining in that timestep; they do not retroactively run earlier applications.
Movement and geometry changes invalidate affected spatial environment bindings.
Accepted streams are append-only.
