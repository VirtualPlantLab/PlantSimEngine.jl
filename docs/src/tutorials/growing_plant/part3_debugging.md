# Debugging Growth And Resource Ordering

If an organ appears to spend resources before it exists, inspect activation
timing and the compiled schedule. If two models intentionally update one stock,
declare `Updates(:stock; after=:producer)`. If a parent must test several child
states before accepting one, use `calls` and publish only the accepted call.

For cycles, choose a scientific meaning: lag one edge with
`PreviousTimeStep`, put convergence under a parent-owned hard call, or
reformulate the equations. Do not resolve a cycle by incidental application
ordering.

Use this debugging order:

1. `Diagnostics.explain_initialization(model)` for missing state or environment values.
2. `Diagnostics.explain_bindings(model)` for source scope and multiplicity.
3. `Diagnostics.explain_writers(model)` for competing canonical outputs.
4. `Diagnostics.explain_calls(model)` for call-only targets and target cardinality.
5. `Diagnostics.explain_schedule(model)` for cadence and root ordering.
6. `Diagnostics.explain_outputs(simulation)` after execution for publication history.

A trial call must not mutate accepted output history or scatter mutable
environment outputs. Nested trials inherit the outer publication decision.
Convergence and failure policy belongs to the parent model: it decides the
iteration limit, tolerance, fallback, and whether any state is accepted.

Structural mutation is also transactional at the timestep boundary. A new
organ is registered immediately in the model registry but does not recursively
run during the kernel that created it. Before the next timestep, compilation
refreshes targets, carriers, calls, writer validation, schedules, and requested
outputs. Geometry-only movement refreshes only affected spatial bindings where
possible.
