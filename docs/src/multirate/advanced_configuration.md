# Advanced multi-rate configuration

This page collects the multi-rate features that were intentionally kept in the
background on the first two pages:

- [Introduction to multi-rate execution](introduction.md) explains the core
  scheduling rules;
- [Step-by-step multi-rate tutorial](multirate_tutorial.md) shows a complete
  hourly/daily/weekly MTG example with minimal configuration;
- this page covers the explicit configuration tools you reach for when defaults
  are no longer enough.

The goal here is not to build another full simulation from scratch. Instead, the
objective is to explain when and why you should add more explicit multi-rate
declarations to a mapping.

## 1. When the defaults are enough

PlantSimEngine tries to keep simple mappings concise:

- if a model does not declare `TimeStepModel(...)`, it follows the meteo
  cadence;
- if an input has a unique producer, `InputBindings(...)` can often be omitted;
- if a model consumes common `Atmosphere` variables at a coarser cadence,
  PlantMeteo default transforms can often replace explicit `MeteoBindings(...)`;
- if an exported variable has a unique canonical publisher, `OutputRequest(...)`
  can often omit `process=`.

The sections below focus on the cases where that implicit behavior becomes too
ambiguous or too limiting.

## 2. Explicit model-to-model bindings with `InputBindings(...)`

The tutorial pages rely on unique-producer inference plus `output_policy(...)`
declared on the source models. That is the simplest setup, but it stops being
enough as soon as several candidate producers exist or when you want to override
the default resampling rule.

Use explicit `InputBindings(...)` when:

- several models can produce the same input variable;
- the same process exists at several reachable scales;
- the source variable has a different name than the consumer input;
- the producer default policy is not the policy you want for this particular
  connection.

For example, a daily plant model may need to say explicitly that it consumes the
hourly leaf assimilation stream from the `:Leaf` scale and integrates it over
the day:

```julia
plant_daily_spec = ModelSpec(TutorialPlantDailyModel()) |>
    TimeStepModel(ClockSpec(24.0, 0.0)) |>
    InputBindings(;
        leaf_assim_h=(
            process=:tutorialleafhourly,
            scale=:Leaf,
            var=:leaf_assim_h,
            policy=Integrate(),
        ),
    )
```

This is more verbose than inference, but the resulting mapping is also more
explicit: anyone reading it can see exactly where the data comes from and how it
is reduced.

## 3. Explicit meteorological aggregation with `MeteoBindings(...)`

For common `Atmosphere` variables, PlantSimEngine delegates weather sampling to
PlantMeteo, and PlantMeteo already defines default transforms. In practice, this
means you often do not need `MeteoBindings(...)` for variables such as `T`,
`Rh`, or aliases like `Ri_SW_q`.

Add explicit `MeteoBindings(...)` when:

- you want a non-default reducer;
- the target variable should come from a differently named source variable;
- the variable is not covered by PlantMeteo defaults;
- you want the mapping itself to document the intended weather aggregation rule.

For example, this daily model makes the defaults explicit for temperature and
shortwave radiation energy:

```julia
plant_daily_spec = ModelSpec(TutorialPlantDailyModel()) |>
    TimeStepModel(ClockSpec(24.0, 0.0)) |>
    MeteoBindings(
        ;
        T=MeanWeighted(),
        Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
    )
```

And this variant shows a more genuinely custom rule:

```julia
plant_daily_spec = ModelSpec(TutorialPlantDailyModel()) |>
    TimeStepModel(ClockSpec(24.0, 0.0)) |>
    MeteoBindings(
        ;
        T=(source=:T, reducer=MaxReducer()),
        rad_peak=(source=:Ri_SW_f, reducer=MaxReducer()),
    )
```

The important point is that `MeteoBindings(...)` is not only about reducing
weather from fast to slow. It is also a way to state the semantics of that
reduction explicitly.

## 4. Calendar-aligned windows with `MeteoWindow(...)`

By default, coarser meteo sampling uses rolling windows that follow the model
clock. That is often sufficient, but some models are tied to civil periods such
as "the current day" or "the current week".

In those cases, use `MeteoWindow(...)` to replace the default trailing window
with a calendar-aligned one:

```julia
plant_daily_spec = ModelSpec(TutorialPlantDailyModel()) |>
    TimeStepModel(ClockSpec(24.0, 0.0)) |>
    MeteoWindow(
        CalendarWindow(
            :day;
            anchor=:current_period,
            week_start=1,
            completeness=:strict,
        ),
    )
```

This becomes important when a daily or weekly model should aggregate over civil
days or weeks rather than over "the last 24 hours" or "the last 168 hours".

## 5. Exporting streams with `OutputRequest(...)`

The second tutorial page uses `OutputRequest(...)` to materialize clean
hourly/daily/weekly tables from the simulation streams. The simple form works
well when the requested variable has a unique canonical publisher:

```julia
req_plant_daily = OutputRequest(:Plant, :plant_assim_d;
    name=:plant_assim_daily,
    clock=ClockSpec(24.0, 0.0),
)
```

More complex mappings often need more explicit requests. In particular, add
`process=` when several models can publish the same variable, and add `policy=`
when you need a specific export-time resampling behavior:

```julia
req_daily_energy = OutputRequest(:Leaf, :leaf_assim_h;
    name=:leaf_energy_daily,
    process=:tutorialleafhourly,
    policy=Integrate(),
    clock=ClockSpec(24.0, 0.0),
)

req_hourly_hold = OutputRequest(:Plant, :plant_assim_d;
    name=:plant_assim_hold_hourly,
    process=:tutorialplantdaily,
    policy=HoldLast(),
    clock=ClockSpec(1.0, 0.0),
)
```

So `OutputRequest(...)` is not just a way to rename a column. It is also a
declaration of which stream you want, at which cadence, and with which
resampling policy.

## 6. Inspect resolved configuration

When a mapping mixes inferred bindings, explicit bindings, custom meteo
aggregation, scopes, and export requests, it becomes difficult to reason about
the final resolved configuration by inspection alone.

That is where `explain_model_specs(...)` and `resolved_model_specs(...)` become
useful:

```julia
explain_model_specs(mapping)

resolved = resolved_model_specs(mapping)
resolved[:Plant]
```

These helpers let you confirm:

- the effective timestep of each model;
- the resolved input bindings;
- the resolved meteo bindings;
- the active meteo window.

In practice, this is often the fastest way to debug a multi-rate mapping before
running a larger simulation.

## 7. How to choose between the three pages

Use the pages in this order:

1. start with [Introduction to multi-rate execution](introduction.md) if you
   want to understand the scheduling rules;
2. continue with [Step-by-step multi-rate tutorial](multirate_tutorial.md) for
   a complete but compact MTG example;
3. come back to this page when you need explicit bindings, explicit meteo
   aggregation, custom export requests, scopes, or debugging helpers.
