# Coupling more complex models

```@setup scene_advanced_coupling
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

Usually, coupling means that one model calculates a value and another reads
it. Sometimes a model must also decide when the other calculation runs. For
example, an energy-balance model may run photosynthesis and
stomatal-conductance models several times while trying to find the leaf
temperature that balances heat gains and losses.

That second case is called a **manual call** or **hard dependency**. Declare
it with `ModelSpec(...; calls=...)`.

## Soft inputs and manual calls

An ordinary input connection is also called a **soft dependency**. Set it
with `ModelSpec(...; inputs=...)`. PlantSimEngine connects inputs automatically
on the same object when exactly one model supplies the required variable.
Use `ModelSpec(...; calls=...)` when one model must run another from inside
its own `run!` function.

The example process models in `examples/dummy.jl` contain both patterns:

- `Process4Model` computes `var1` and `var2`;
- `Process1Model` reads `var1` and `var2` and computes `var3`;
- `Process2Model` manually calls process 1, then computes `var4` and `var5`;
- `Process3Model` manually calls process 2, then computes `var6`;
- `Process5Model`, `Process6Model`, and `Process7Model` read other models'
  results through ordinary inputs.

## Declaring manual calls in the scenario

The simulation setup chooses which models are called. The model's `run!`
function can then keep the same equations when those choices change.

A **model application** is a model configured with a name, selected objects,
and any input or timing settings. In the setup below, use `application=...`
to choose that name in a call or input connection.

This matters when you use the same process in several places. For example,
two soil-water models may represent different layers. Naming the application
lets you choose the intended layer.

When writing a reusable model, you will not know the names that future
simulations choose. Its `dep(model)` declaration can instead ask for the
scientific process it needs. The simulation then connects that request to
an application.

```@example scene_advanced_coupling
complex_scene = CompositeModel(
    Object(:scene; scale=:Scene, kind=:scene, status=Status(var0=2.0));
    applications=(
        ModelSpec(Process4Model(); name=:prepare_inputs, on=One(scale=:Scene), every=Day(1)),

        ModelSpec(Process1Model(2.0); name=:process1, on=One(scale=:Scene), every=Day(1)),

        ModelSpec(Process2Model(); name=:process2, on=One(scale=:Scene), calls=(:process1 => One(scale=:Scene, application=:process1)), every=Day(1)),

        ModelSpec(Process3Model(); name=:process3, on=One(scale=:Scene), calls=(:process2 => One(scale=:Scene, application=:process2)), every=Day(1)),

        ModelSpec(Process5Model(); name=:process5, on=One(scale=:Scene), every=Day(1)),

        ModelSpec(Process7Model(); name=:process7, on=One(scale=:Scene), every=Day(1)),

        ModelSpec(Process6Model(); name=:process6, on=One(scale=:Scene), every=Day(1)),
    ),
    environment=meteo_day,
)

select(
    DataFrame(Diagnostics.explain_calls(complex_scene)),
    :application_id,
    :call,
    :callee_application_ids,
    :callee_object_ids,
    :publication_policy,
)
```

The table shows which model each named call will run. Models used only
through these calls run when their caller asks them to; they do not also
run independently at each time step.

## Running the coupled model

PlantSimEngine still connects ordinary inputs from the models' `inputs_`
and `outputs_` declarations. It uses those connections and the manual calls
to determine which calculations run first. Inspect that order:

```@example scene_advanced_coupling
select(
    DataFrame(Diagnostics.explain_schedule(complex_scene)),
    :application_id,
    :manual_call_only,
    :execution_index,
    :clock,
)
```

Run one timestep:

```@example scene_advanced_coupling
complex_sim = run!(complex_scene; steps=1)
complex_status = final_state(complex_sim)
(
    var3=complex_status.var3,
    var5=complex_status.var5,
    var6=complex_status.var6,
    var8=complex_status.var8,
)
```

## Writing new hard-coupled models

Inside a model, run all models and objects selected by a named call with:

```julia
targets = run_call!(context, :leaf_energy; publish=true)
```

The result is a collection of **targets**, each representing a called model
on one object. To choose individual targets before running them, use
`call_targets`. This also lets you pass different environmental values to
each one:

```julia
targets = call_targets(context, :leaf_energy)
for (target, leaf_environment) in zip(targets, environments_by_leaf)
    run_call!(
        target;
        sampled_environment=leaf_environment,
        publish=false,
    )
end
```

If an environment provider supplies values for different positions, you can
give it a trial state for the whole call. PlantSimEngine then reads the
appropriate values for each target's location. The following outline shows
the order; your model must define how to calculate and accept a trial:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, status, environment,
                             constants, context)
    trial = trial_environment(model, status)
    run_call!(context, :leaf_energy; environment=trial, publish=false)

    accepted = accepted_environment(model, status)
    commit_environment!(context, accepted)
    run_call!(context, :leaf_energy; publish=true)

    return nothing
end
```

`run_call!` defaults to `publish=false`: trial results are not saved as
accepted samples for output history or time-based connections. Pass a trial
environment with the `environment` keyword. Once you accept a solution,
`commit_environment!` writes its environmental values, and a call with
`publish=true` saves the accepted result. Trial calculations can still change
the objects' current values, so your algorithm must handle any changes it
needs to discard.

The MAESPA-style example uses the same approach: a canopy energy-balance
model calls the leaf energy-balance models and the shared soil model while
it solves canopy microclimate. Use manual calls for calculations that need
this control. An ordinary input is enough when a model simply reads
another model's result.
