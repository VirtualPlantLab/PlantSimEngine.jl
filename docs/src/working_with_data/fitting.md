# Parameter Fitting

Parameter fitting means finding parameter values that make a model agree
with observations. Independent evaluation asks how well those values predict
observations that were kept out of fitting. This page starts with a small fitting example,
then explains how to keep those two uses of data separate.

PlantSimEngine provides `Evaluation.fit` as a common
function name; each model package supplies the fitting method for its own
models. Pass the model type first and a table of observations second.
The table can be a DataFrame or another format supported by Tables.jl.

## Fit the example light model

For the `Beer` model, we can calculate the light-extinction coefficient `k`
from LAI, incoming light, and absorbed light:

```julia
J_to_umol = PlantMeteo.Constants().J_to_umol
incident_ppfd = J_to_umol .* data.Ri_PAR_f
f_abs = data.aPPFD ./ incident_ppfd
k = Statistics.mean(-log1p.(-f_abs) ./ data.LAI)
```

This snippet only shows how to rearrange Beer's equation to find `k`. The implementation in
`examples/Beer.jl` validates every observation and returns `(k=k,)`; do not use
the snippet alone as an unchecked fitting method.

A fitting method returns named parameter values, for example `(k=0.6,)`.

In this Beer example, `Ri_PAR_f` measures incoming light per unit ground area
and `aPPFD` measures light absorbed by the whole canopy per unit ground area.
`LAI` is leaf area per unit ground area. Do not use a PPFD expressed per unit
leaf area in this calculation. The fit rejects empty data, non-finite or
non-positive `LAI` and incident PAR, and absorbed fractions outside `[0, 1)`.

```@example fitting
using PlantSimEngine, PlantMeteo, Dates, DataFrames
using PlantSimEngine.Examples

meteo = Atmosphere(
    T=20.0,
    Wind=1.0,
    P=101.3,
    Rh=0.65,
    Ri_PAR_f=300.0,
    duration=Hour(1),
)

model = CompositeModel(
    Beer(0.6);
    status=(LAI=2.0,),
    id=:plant,
    scale=:Plant,
    environment=meteo,
)

simulation = run!(model)
plant = final_state(simulation, One(scale=:Plant))
data = DataFrame(
    aPPFD=[plant.aPPFD],
    LAI=[plant.LAI],
    Ri_PAR_f=[meteo.Ri_PAR_f[1]],
)

PlantSimEngine.Evaluation.fit(Beer, data)
```

This example recovers the parameter used to generate the synthetic
observation. It checks that the fit and simulation agree algebraically;
it provides no evidence of predictive performance on measured data.

The result contains parameters, rather than a modified simulation. Construct
the fitted component and run a new scenario. Using the variables from the
example above, the following illustrates that step:

```julia
parameters = PlantSimEngine.Evaluation.fit(Beer, data)
fitted_model = CompositeModel(
    Beer(parameters.k);
    status=(LAI=2.0,), id=:plant, scale=:Plant, environment=meteo,
)
fitted_simulation = run!(fitted_model; outputs=:all)
fitted_rows = collect_outputs(fitted_simulation; sink=DataFrame)
```

For real data, keep the same scenario construction, environmental inputs,
initial states, and observation-matching rules when comparing the original
and fitted parameterizations. A new `run!` starts a fresh timeline. For a
stateful model, reconstruct its initial state for each trial so one candidate's
final state does not become the next candidate's starting state.

## Prepare measurements and define the split

Record where the measurements came from and what each column means: units,
leaf or ground area basis, object identity, measurement time or interval,
protocol, and missing-value or quality flags. Identify the simulated quantity
that corresponds to each observation. For example, an hourly mean flux and a
daily accumulated amount require different comparisons even when both refer
to absorbed light. The [output guide](../guides/data/outputs_plotting.md)
shows how to match object identities and times before comparing values.

Choose the calibration and evaluation datasets before fitting. Preserve a
split specified by the experiment or project. Where you need to define a
split, its unit should match the intended prediction: a new plant, site,
treatment, or period. Closely related measurements from the same plant or
period may not provide an independent check when split between the two sets.
Record the membership and rationale so the comparison can be reproduced.

Use only calibration data to select parameters, model alternatives, bounds,
or other fitting choices. Freeze those choices before evaluating the held-out
data. If evaluation results lead you to change the model or fitting method,
report that iteration and obtain a new independent check before describing
the revised result as held-out performance.

[Use observed values](../guides/data/forcing_observations.md) when you want to
isolate a component: for example, supply measured LAI while fitting the light
model. State which quantities are measured inputs and which are predictions.
Agreement in absorbed light under measured LAI evaluates that conditional
light calculation; it does not evaluate the ability to predict LAI.

## Choose a fitting method for the scientific problem

`Evaluation.fit` is an extension point, rather than a general optimizer for
every `CompositeModel`. A model package can implement a closed-form fit,
an optimization loop, or another estimation method and return named
parameters with additional diagnostics. Check what the package's method
actually estimates and which data it requires.

For an optimization-based calibration, define an objective using predictions
matched to the calibration observations. Explain the residual scale and any
weights, especially when combining variables with different units or sampling
frequencies. Choose parameter bounds and transformations from the model's
meaning and evidence; the optimizer and stopping criteria should suit that
objective. Record starting values, fitted values, convergence information,
and a random seed when the method uses randomness.

The Beer example averages values obtained by inverting each observation.
That estimator need not be the same as minimizing squared errors in absorbed
light, particularly with noisy measurements. Choose the estimator according
to the measurement process and scientific question.

## Compare baseline and fitted predictions

Run both parameterizations on the calibration and evaluation scenarios.
Align predictions with observations before computing scores, and use the
same accepted observations for both parameterizations. Report missing or
excluded pairs and the number of retained pairs for each dataset.

Suppose `comparison` is your aligned DataFrame with columns `dataset`
(`:calibration` or `:evaluation`), `configuration` (`:baseline` or `:fitted`),
`object_id`, `datetime`, `observed`, and `simulated`. Each row is one valid,
finite observation-prediction pair, with consistent units and sampling.
The following keeps the four comparisons separate:

```julia
using Statistics

scores = [
    (
        dataset=first(pairs.dataset),
        configuration=first(pairs.configuration),
        n=nrow(pairs),
        rmse=PlantSimEngine.Evaluation.RMSE(pairs.observed, pairs.simulated),
        bias=Statistics.mean(pairs.simulated .- pairs.observed),
    )
    for pairs in groupby(comparison, [:dataset, :configuration])
]
comparison.residual = comparison.simulated .- comparison.observed
```

RMSE has the observed variable's units; the bias above is positive when
predictions are too high. `Evaluation.NRMSE` divides RMSE by the observed
range, and `Evaluation.EF` computes Nash–Sutcliffe efficiency. Their
denominators vanish for constant observations, so they cannot provide a
useful score for that case. Check the [evaluation API](../API/API_public.md)
for the available metrics and their definitions.

Inspect predictions alongside observations and residuals against time,
predicted values, and relevant treatments or objects. An overall score can
hide a systematic error for one site or condition. Report calibration
agreement and independent evaluation performance separately, with the
unchanged baseline as a reference.

A good fit does not establish that each parameter is identifiable: several
parameter combinations can produce similar predictions. Interpret fitted
values within the observed conditions and report uncertainty or sensitivity
when needed for the intended use. The [uncertainty guide](../guides/data/uncertainty_propagation.md)
shows how to propagate specified uncertainty; choosing illustrative parameter
distributions is not an estimate of calibration uncertainty.

For help carrying out this workflow, see the calibration and evaluation
prompts in [Work with an AI coding agent](../agent_skill.md). Provide the data
documentation, the intended prediction, and the dataset split; the shipped
skill supplies the package-specific guidance.
