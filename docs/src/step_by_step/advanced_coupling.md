# Coupling more complex models

```@setup scene_advanced_coupling
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo_day = read_weather(
    joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv");
    duration=Dates.Day,
)
```

Most model coupling is a value dependency: one model writes an output, another
model reads it as an input. Some models need tighter control. For example, an
energy-balance model may call photosynthesis and stomatal-conductance models
several times while it iterates leaf temperature.

That second case is a manual call dependency. In the composite-model/object API it is
declared with `Calls(...)`.

## Soft inputs and manual calls

Use `Inputs(...)` or inferred same-object bindings when a model only needs a
value. Use `Calls(...)` when the parent model must directly run another model
inside its own `run!` method.

The example process models in `examples/dummy.jl` contain both patterns:

- `Process4Model` computes `var1` and `var2`;
- `Process1Model` consumes `var1` and `var2` and computes `var3`;
- `Process2Model` manually calls process 1, then computes `var4` and `var5`;
- `Process3Model` manually calls process 2, then computes `var6`;
- `Process5Model`, `Process6Model`, and `Process7Model` use regular soft
  value dependencies.

## Declaring manual calls in the scenario

`Calls(...)` is scenario-level wiring. The model kernel remains generic; the
scenario decides which concrete application is called.

Use `application=...` in scenario-level `Calls(...)` and `Inputs(...)` when you
know which mounted model application should provide the value or be called. Use
process identities in model-level contracts such as `dep(model)`, where the
model author only declares that a compatible process is required and cannot know
the names chosen by future scenarios.

This split avoids ambiguity when several applications implement the same
process. For example, two soil-water applications can share the same process but
represent different layers, parameter sets, objects, or time steps. A scenario
selector should name the application that has the intended role.

```@example scene_advanced_coupling
complex_scene = CompositeModel(
    Object(:scene; scale=:Scene, kind=:scene, status=Status(var0=2.0));
    applications=(
        ModelSpec(Process4Model(); name=:prepare_inputs) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),

        ModelSpec(Process1Model(2.0); name=:process1) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),

        ModelSpec(Process2Model(); name=:process2) |>
            AppliesTo(One(scale=:Scene)) |>
            Calls(:process1 => One(scale=:Scene, application=:process1)) |>
            TimeStep(Day(1)),

        ModelSpec(Process3Model(); name=:process3) |>
            AppliesTo(One(scale=:Scene)) |>
            Calls(:process2 => One(scale=:Scene, application=:process2)) |>
            TimeStep(Day(1)),

        ModelSpec(Process5Model(); name=:process5) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),

        ModelSpec(Process7Model(); name=:process7) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),

        ModelSpec(Process6Model(); name=:process6) |>
            AppliesTo(One(scale=:Scene)) |>
            TimeStep(Day(1)),
    ),
    environment=meteo_day,
)

select(
    DataFrame(explain_calls(complex_scene)),
    :application_id,
    :call,
    :callee_application_ids,
    :callee_object_ids,
    :publication_policy,
)
```

Applications selected by `Calls(...)` are not scheduled as independent root
applications under their caller. They run only when the parent calls them.
This gives the parent full call-stack control.

## Running the coupled model

The regular soft dependencies are still inferred from `inputs_` and
`outputs_`. The scheduler combines those soft edges with the call ownership
rules:

```@example scene_advanced_coupling
select(
    DataFrame(explain_schedule(complex_scene)),
    :application_id,
    :manual_call_only,
    :execution_index,
    :clock,
)
```

Run one timestep:

```@example scene_advanced_coupling
complex_sim = run!(complex_scene; steps=1)
complex_status = only(model_objects(complex_scene; scale=:Scene)).status
(
    var3=complex_status.var3,
    var5=complex_status.var5,
    var6=complex_status.var6,
    var8=complex_status.var8,
)
```

## Writing new hard-coupled models

For new composite-model/object models, execute all targets directly when they
share meteorology and publication policy:

```julia
targets = run_call!(extra, :leaf_energy; meteo=meteo, publish=true)
```

The result is always vector-like. Retrieve targets without executing them when
an iterative algorithm needs finer control:

```julia
function PlantSimEngine.run!(model::SceneEnergyBalance, models, status, meteo,
                             constants, extra)
    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=trial_meteo(model, status))
    end

    for target in call_targets(extra, :leaf_energy)
        run_call!(target; meteo=accepted_meteo(model, status), publish=true)
    end

    return nothing
end
```

`run_call!` defaults to `publish=false`, which is useful for trial iterations.
Use `publish=true` for the accepted state so temporal streams and mutable
environment outputs are published once.

The MAESPA-style example uses the same mechanism: a model energy-balance model
calls all selected leaf energy-balance models and the shared soil model while
it solves canopy microclimate.

Scenario wiring uses `Calls(...)`. Model authors should keep kernels generic
and only require manual calls when the model really needs call-stack control.
