# Model Traits

A **trait** is a function that tells PlantSimEngine something about a model:
which values it needs, which values it calculates, or how often it should run.
This page lists the declarations a model author can provide. For a complete
example, start with [writing a first model](journeys/modelers/basic_model.md).

Use `ModelSpec` for choices that belong to a particular simulation, such as
which leaves use the model and where their inputs come from.

## Variables

Implement `inputs_(model)` with an explicit declaration for every status input:

```julia
PlantSimEngine.inputs_(::MyModel) = (
    leaf_area=Required(Float64),
    efficiency=Default(0.8),
)
PlantSimEngine.outputs_(::MyModel) = (assimilation=0.0,)
```

`Required(T)` means the object must already have this value, or another
model must provide it. `T` describes the kind of value expected, such as
`Float64` for a floating-point number. It does not supply a starting value.
Choose a type that fits the calculation; it need not always be `Float64`.

`Default(value)` supplies a starting value when neither the user nor another
model provides one. Each object gets its own copy. For example, changing a
default array on one leaf does not change the array on another leaf.

The values in `outputs_` are the outputs' starting values. In this example,
`assimilation` starts at `0.0` before the model first runs.

PlantSimEngine uses these declarations to prepare each object's values,
connect models, and find missing inputs. Writing a plain number in `inputs_`
is rejected: it would not say whether the model needs a supplied value or
can use a default.

Use `init_variables(model)` to inspect only values PlantSimEngine can
initialize by itself: `Default` input values and output initial values.
Required inputs are intentionally omitted.

Before running a scenario, `Diagnostics.explain_initialization(model)` classifies inputs as
`:required`, `:defaulted`, `:supplied`, or `:producer_bound`. A
`:required` row identifies an input you must supply before the simulation
can be prepared.

## Scientific meaning and dimensions

Names and Julia types are not enough to distinguish, for example, daily PAR
per ground area from daily PAR per plant. Add a `VariableContract` when a
value will pass between models. A **variable contract** records its unit
and physical meaning:

```julia
const PLANT_DAILY_PAR = VariableContract(
    unit=:mol_photon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

PlantSimEngine.variable_contracts_(::PlantLight) = (
    absorbed_par=PLANT_DAILY_PAR,
)
PlantSimEngine.variable_contracts_(::PlantGrowth) = (
    absorbed_par=PLANT_DAILY_PAR,
)
```

You choose the labels, such as `:plant` and `:day`. The model supplying the
value and the model reading it must declare the same complete contract. If
one declares a contract and the other does not, PlantSimEngine reports an
error before running. Renaming a variable with `var=...` does not convert
its units or meaning. Use a separate model for a conversion, such as
multiplying a quantity per unit area by plant area.

`VariableContract` describes the values without changing how they are
stored. Your equations still receive numbers or arrays, including compatible
types that carry units, uncertainty, or derivatives.

Use `variable_contracts(model)` to inspect the validated declarations. Contract
keys must occur in one of the model's declared status or environment traits, or
in the compiled application's distributed `outputs_to` declaration.

| Value or operation | Declaration | Where it comes from or goes |
|---|---|---|
| Object input | `inputs_` | A value on the object or an output from another model |
| Environment input | `environment_inputs_` | Weather data or local growing conditions |
| Constant | the `constants` argument | Values supplied for the simulation, such as physical constants |
| Manual model call | `dep` plus `ModelSpec(...; calls=...)` | Another model that this model decides when to run |
| Output on the current object | `outputs_` | The object on which this model runs |
| Outputs on other objects | `ModelSpec(...; outputs_to=...)` | Selected objects, such as leaves receiving a scene light calculation |

## Manual Dependencies

Use `dep(model)` to suggest default input connections with `Input`, or models
to call with `Call`. A `Call` declaration is needed when the model directly
runs another process from inside its own `run!` function:

```julia
PlantSimEngine.dep(::EnergyBalance) = (
    photosynthesis=Call(One(process=:photosynthesis)),
)
```

The scenario may override that default selector with
`ModelSpec(...; calls=...)`. The calling model runs all selected photosynthesis models with
`run_call!(context, :photosynthesis)`, which returns a collection even when
there is only one model. Use `call_targets` to inspect that collection first
and `run_call!(target)` to run individual entries. This lets you try values
and record only the accepted result with `publish=true`.

## Timing

`timespec(model)` declares a model clock in simulation steps. The default is
`ClockSpec(1.0, 0.0)`.

```julia
PlantSimEngine.timespec(::Type{<:DailyGrowth}) = ClockSpec(24.0, 1.0)
```

Here, `24.0` means every 24 simulation steps and `1.0` sets the first
execution at step 1: the model runs at steps 1, 25, 49, and so on. This is
daily execution only when the simulation uses hourly steps.

Use `ModelSpec(...; every=Dates.Day(1))` when the cadence should be expressed
in hours or days relative to the simulation's weather time step. A
`Dates.Period` is not a `ClockSpec` constructor argument.

`output_policy(model)` says how another model should read an output when
the two models run at different time steps. For example, it can request a
sum or a mean over a time window:

```julia
PlantSimEngine.output_policy(::Type{<:MyModel}) = (
    assimilation=Integrate(),
    leaf_temperature=Aggregate(MeanReducer()),
)
```

Unspecified outputs use `HoldLast()`. A scenario can select another clock with
`ModelSpec(...; every=...)` and another input policy in `ModelSpec(...; inputs=...)`.

`timestep_hint(model)` can declare required or preferred timestep constraints.
`environment_hint(model)` can provide default environment sampling configuration.

## Environment Variables

Use `environment_inputs_(model)` for variables sampled from the active environment
backend:

```julia
PlantSimEngine.environment_inputs_(::LeafEnergyBalance) = (
    T=0.0,
    Rh=0.0,
    Wind=0.0,
    Ri_PAR_f=0.0,
    CO2=400.0,
)
```

If a controller changes growing conditions, declare the variables it may
update with `environment_outputs_`. For example, a canopy controller that
adjusts temperature declares:

```julia
PlantSimEngine.environment_outputs_(::CanopyController) = (T=0.0,)
```

Once its calculation is accepted, the controller saves the new conditions
with `commit_environment!`. This operation requires the output declaration:

```julia
commit_environment!(context, accepted_environment)
```

To try temporary growing conditions, pass them through `environment`. Each
called model still receives the conditions for its own location:

```julia
run_call!(context, :leaf_energy; environment=trial_environment, publish=false)
```

You can also record canopy temperature or vapor-pressure deficit in
`outputs_`. Changing these outputs alone does not update the environment
that other models read; use `commit_environment!` for that.

## Precedence

Scenario configuration has precedence over model defaults:

1. `ModelSpec(...; inputs=...)` policy, then producer `output_policy`, then `HoldLast()`.
2. `ModelSpec(...; every=...)`, then `timespec(model)`, then the environment base step.
3. `Environment(...)`, then `environment_hint(model)`, then backend defaults.
