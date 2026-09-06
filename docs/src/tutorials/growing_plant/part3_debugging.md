# Debugging Growth And Resource Ordering

Use this page when a new organ receives the wrong inputs, spends a resource
twice, or appears in outputs at an unexpected time. Begin with the runnable
[Modify Plant Structure](@ref) example and change one mechanism at a time.

## Follow one timestep

First establish whether the organ was created inside a kernel or between
`step!` calls. Inside a kernel, targets and bindings refresh after the creating
application. The newborn can run applications that remain later in that step;
applications that already completed do not run again. Between steps, the
refresh happens before the next step.

An `Initializer` allows a creator to calculate one newborn's initial state
explicitly. It does not create an extra retained publication during the step.
Registration changes the live registry immediately; the refresh barrier is
not a general transaction or an automatic rollback of model state.

## Inspect the boundary that failed

| Symptom | First check | What to verify |
|---|---|---|
| Missing or invalid newborn state | `Diagnostics.explain_initialization(model)` | Every required input has a meaningful initial value. |
| One plant consumes another plant's leaves | `Diagnostics.explain_bindings(model)` | The source uses the intended `Subtree()` or other explicit scope. |
| A stock has two producers | `Diagnostics.explain_writers(model)` | One owner updates it, or intentional writers declare `Updates(:stock; after=:producer)`. |
| Child models run unexpectedly | `Diagnostics.explain_calls(model)` | The correct applications are call targets and the parent invokes them once for each intended trial or acceptance. |
| Daily uptake is added hourly | `Diagnostics.explain_schedule(model)` | Stock-update cadence matches the non-overlapping integration intervals. |
| Newborn output begins too early or too late | `Diagnostics.explain_outputs(simulation)` and `collect_outputs(simulation)` | First publication agrees with the creation point and remaining schedule. |

For carbon or water, also write a balance independent of the execution graph:
initial stock plus accepted inputs equals final stock plus explicit losses
and transfers. Passing writer checks cannot establish this conservation law.
[Adding Roots And Water](@ref) shows a two-day accounting check.

## Keep trial and accepted state distinct

For a numerical cycle, choose the scientific meaning: lag one input with
`PreviousTimeStep`, put convergence under a parent-owned hard call, or
reformulate the equations. Incidental application order is not a solver.

Use `run_call!(context, name; publish=false)` for trial evaluations and publish
only the accepted result. This suppresses trial output publication; it does
not undo assignments to live status. The parent must prepare each trial's
state and keep irreversible stock updates out of rejected iterations. Commit
mutable environment changes only after accepting a solution.

The parent owns the iteration limit, tolerance, and failure policy. The
[MAESPA-Style Synthesis](@ref) demonstrates accepted canopy-air commits and
leaf calls; its carbon accumulation happens after the solver accepts a state.
