# Observation forcing, calibration, and empirical evaluation

These tasks answer different questions. Observation forcing supplies measured
drivers or state values to a simulation. Calibration estimates parameters.
Evaluation assesses predictions against observations under a declared scope.
Use only the sections relevant to the request; forcing is not parameter
fitting or data assimilation, and calibration agreement is not independent
evaluation.

## Data meaning and alignment

Identify source/protocol, column meanings and units, object/site/treatment
identities, timestamps, sampling intervals, missing values, and uncertainty
where available. Preserve raw observations and make transformations explicit.
The prediction/observation comparison must use the same physical basis,
spatial extent, and temporal support. For example, a daily integrated flux
cannot be compared directly with an instantaneous sample or a rate per second.

Use stable object identities and explicit time alignment; row order and display
names are not sufficient identifiers. Decide how to handle missing values,
duplicate records, gaps, and interval boundaries according to the measurement
protocol and task. Record exclusions and conversions so retained sample counts
and their scientific interpretation can be checked.

## Force observations into a scenario

For a fixed measured input, supply status and omit the model that would
predict/write that variable. An initial status value alone does not keep it
fixed when a scheduled producer overwrites it.

For a changing observation sequence, use an explicit observation-provider
model that reads the measured driver from the environment and writes the
required status output. The package's
`docs/src/guides/data/forcing_observations.md` and companion `observed_lai.jl`
demonstrate `ObservedLAI()` supplying `LAI` to `Beer` on the same object.
Resolve these paths from the verified package root rather than an installed
skill directory. This provider copies values; it performs no fitting, unit
conversion, interpolation, or uncertainty-based state correction.

For other objects or variable names, bind the consumer explicitly. Match port
contracts and establish canonical writer ownership. Retain any alternative
prediction under a distinct output or stream when the comparison needs it;
do not let two producers silently compete for the measured field.

Sparse measurements require a scientific sampling policy. Hold-last,
interpolation, or aggregation can mean different things for a state, rate,
or interval total. Document the choice and its initialization/gap behavior;
temporal policies do not change `VariableContract` metadata. See
[scenario-coupling.md](scenario-coupling.md) for supported policies and adapters.

Useful evidence is a small trace showing observation identity/time/value,
the provider output, and the value received by the intended consumer.
Distinguish a subsystem evaluated with measured upstream inputs from the full
model evaluated with predicted inputs. Forcing an observed target into the
model and comparing that copied target to itself is not predictive validation.

## Calibrate parameters

PlantSimEngine provides `Evaluation.fit` as an extension point. Model packages
implement fitting methods; it is not a generic optimizer for arbitrary
`CompositeModel`s. The documented example is
`PlantSimEngine.Evaluation.fit(Beer, data)`, returning named parameter values
such as `(k=k,)`. See `docs/src/working_with_data/fitting.md` under the verified
package root.

For a model without a fitting method, use an appropriate optimizer or inference
framework around a reproducible simulation/objective. Choose it according to
the formulation and task rather than assuming the package supplies a fitting,
likelihood, assimilation, or uncertainty API. Distinguish estimated parameters
from fixed values, imposed inputs, and initial conditions; changing the model
structure is a separate scientific choice.

Make the fitting scope explicit: dataset split, estimated parameters and their
units/bounds, objective or likelihood, weighting, observation alignment, and
failure handling. Bounds need a scientific or documented numerical basis.
Check sensitivity or identifiability when the data may not constrain the
requested parameters. A returned optimum alone does not establish uniqueness
or parameter uncertainty.

Each objective evaluation must start from the intended initial state. Use a
fresh scenario or verified reset; `continue!` advances an existing simulation
and would carry state between trials. Keep stochastic seeds and replicate
policy reproducible where used. Apply fitted values by constructing the model
with those values and verify the resulting simulation, not only the optimizer
return value.

Report the data/objective/configuration, fitted values, convergence and
boundary diagnostics, and calibration residuals or plots. Recovering a known
parameter from synthetic data is a useful implementation check, not evidence
that the model is calibrated for a real population or environment.

## Evaluate predictions

Preserve an existing calibration/evaluation split unless the user changes it.
Choose a new split to reflect the intended generalization, such as unseen
dates, individuals, sites, years, or treatments; correlated observations may
need group/block separation. Record the split before fitting or model choice.
Keep evaluation targets out of parameter estimation, data-driven
preprocessing, model selection, and repeated tuning. If evaluation results
drive a revision, identify that reuse and reserve new evidence for subsequent
independent evaluation.

Freeze fitted parameters, model structure, forcing policy, and initialization
for the evaluation run. Preserve declared boundaries such as warm-up periods,
validity domains, and earlier holdouts. Show separately which quantities were
measured/imposed, estimated, and predicted. State whether results test a
component with measured inputs, a coupled system, or transfer to a new scope.

Use explicit output retention and align collected predictions with
observations by identity and time/support. Summarize errors in relevant units
and include sample counts, exclusions, residual structure, and useful plots.
Bias and RMSE/MAE often describe different failures; choose metrics for the
scientific question and avoid percentage metrics near zero without a clear
rationale. An aggregate score can hide site, treatment, or temporal failures.

If uncertainty is requested, distinguish observation uncertainty, fitted
parameter uncertainty, stochastic variability, and structural uncertainty.
A descriptive min-max band is not a confidence or prediction interval.
With no independent observations, report calibration fit or reference/structural
checks; do not relabel them as held-out evaluation.

## Example requests

> Supply these measured values to the requested component. Preserve their
> units, identities, and temporal meaning; explain the writer and sampling
> policy and verify the values actually received by the component.

> Calibrate these parameters using the declared training data and bounds.
> Make the objective and simulation reproducible, report what the data
> constrain, then evaluate the frozen model on the existing holdout. Keep
> imposed inputs, fitted quantities, and predictions distinct.
