# Debugging Growth And Resource Ordering

Use this page when a new organ receives the wrong inputs, spends a resource
twice, or appears in outputs at an unexpected time. Begin with the runnable
[Modify Plant Structure](@ref) example and change one mechanism at a time.

## Follow one timestep

First check whether a model created the organ during `run!`, or whether you
added it between `step!` calls. During a step, PlantSimEngine updates the list
of objects and their input connections after the creating application
finishes. The new organ can then run models scheduled later in that step;
models that already ran are not repeated. If you add the organ between steps,
these connections are updated before the next step.

An `Initializer` lets a model calculate a new organ's initial values without
adding an extra saved result during the step. Adding an organ changes the
object registry immediately. The later update to input connections does not
automatically undo those changes, or changes to other model values, if a
calculation fails.

## Find the cause of the unexpected result

| Symptom | First check | What to verify |
|---|---|---|
| A new organ has missing or invalid values | `Diagnostics.explain_initialization(model)` | Every required input has a meaningful initial value. |
| One plant reads values from another plant's leaves | `Diagnostics.explain_bindings(model)` | `Subtree()` or another selector limits the search to the intended plant. |
| Two models change the same stock | `Diagnostics.explain_writers(model)` | Only one model sets the value, or `Updates(:stock; after=:producer)` specifies the intended order. |
| A called model runs unexpectedly | `Diagnostics.explain_calls(model)` | The controller selects the intended models and calls them only for the intended trials and accepted calculations. |
| A day's uptake is added every hour | `Diagnostics.explain_schedule(model)` | The stock is updated only once for each amount of water taken up. |
| A new organ's results start too early or too late | `Diagnostics.explain_outputs(simulation)` and `collect_outputs(simulation)` | The first result matches when the organ was created and which models could still run in that step. |

For carbon or water, also check the balance directly: initial stock plus
accepted inputs equals final stock plus losses and transfers. PlantSimEngine
can check which models change a stock, but that check does not prove that your
equations conserve the resource.
[Adding Roots And Water](@ref) shows a two-day accounting check.

## Keep trial and accepted state distinct

If two models each need the other's result, decide what the equations require.
Use `PreviousTimeStep` if one input should come from the preceding step. If
both must be solved together in the current step, use a controller to repeat
the calculations until the solution is acceptable. You may also need to
rewrite the equations. Changing the order of the `ModelSpec` declarations
does not solve this problem.

Use `run_call!(context, name; publish=false)` for trials and `publish=true`
only for the accepted result. `publish=false` keeps the trial out of the
output history, but it does not undo changes to status values. The controller
must prepare the values for each new trial and avoid permanently spending
carbon or water on rejected trials. Save environment changes with
`commit_environment!` only after accepting a solution.

The controller must set the maximum number of trials, how close the solution
must be, and what to do if no acceptable solution is found. The
[MAESPA-Style Synthesis](@ref) shows repeated leaf calculations followed by
an accepted canopy air update. It adds carbon only after accepting a solution.
