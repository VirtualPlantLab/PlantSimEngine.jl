# Design and run a calibration

Use this guide when the user asks to estimate parameters or to design a
calibration. Scale the protocol to the prediction goal, the model and the
evidence. For a well-posed fit with an agreed split and a small parameter set,
verify those choices and proceed. When the scope is open, use the audit to
decide what can be estimated before launching a search.

## Map processes to observations

- Define the prediction of interest and its scale, time horizon and domain of
  use. Specify what information will be available when making those predictions.
  Distinguish future years at a known site, transfer to new sites, transfer to
  new genotypes, and predictions conditional on measured inputs.
- Inspect the actual scenario, model definitions and run entry point. For each
  relevant process, trace the active parameters to the computed variables and
  their downstream consumers, including feedback, stress responses and stored
  state. Use the model's contracts and the engine's authoring and diagnostic
  tools where helpful. Identify observable outputs and how they are computed
  from simulation outputs. A parameter's name or presence in a configuration
  file is insufficient evidence that the scenario uses it.
- Build a compact map from process to parameter, observable, data support and
  likely confounders. Separate direct measurements, derived proxies and
  downstream outcomes. Revisit the process list after inspecting the data.
  For example, harvest mass can constrain net production. A stressed harvest
  alone cannot distinguish a low growth potential from a high potential with a
  strong stress response.

## Audit the data and choose the prediction test

Read the files and measurement protocol. Tabulate coverage by the units that
matter, such as site, year, treatment, plot, individual, species, genotype,
cohort and developmental stage. Count independent experimental units as well
as repeated measurements. Check sample selection, units, time intervals,
initial conditions, driver coverage, censoring, and the distinction between a
recorded zero and an unknown outcome. Identify where a match to the same
organ, individual or plot is possible. Record the effects of exclusions and
conversions. See [data alignment](data-calibration-evaluation.md#data-meaning-and-alignment).

Inspect existing splits and the intended use before proposing a new one.
Freeze the data roles before choosing fitted parameters, preprocessing or
model alternatives. Hold out the groups that reflect the intended transfer,
such as entire plot trajectories, seasons, sites or treatments. Keep
overlapping measurement windows and repeated observations of the same unit
together when their dependence would leak information across the split.
Evaluate within the range the split actually supports. A network within a
single region can support a regional transfer test without establishing
performance in other climates. See [block cross-validation](https://doi.org/10.1111/ecog.02881).

| Design or evidence | Calibration consequence |
| --- | --- |
| One site, several annual seasons | For prediction in a new season, hold out whole seasons where the series permits it. Use verified sowing and initial state for each season, and preserve rotations or soil carryover if the model represents them. Site transfer remains untested. |
| Perennial with repeated or irregular measurements | Preserve plant identity, cohorts, developmental history and state across years. For a future-period test, carry the simulated state through the split with the inputs available at prediction time. Treat unknown initial age, size, reserves or prior treatments explicitly. Starting a validation year from an observed state changes the prediction question. |
| Several species, varieties or progenies | Check whether genotypes share sites and treatments and whether there are independent replicates. Use shared values where defensible and estimate group-specific values where contrasts support them. Consider partial pooling when the model and design support it. A genotype observed at one site alone may be confounded with the site. Keep individual observations for scoring where available and aggregate model output at the same level as aggregate measurements. |
| Sparse observations, harvest only or a single usable season | Fit a small supported subset, such as one effective parameter conditional on justified fixed values. Use profiles or sensitivity ranges for unresolved quantities. If a defensible holdout is unavailable, report what the calibration or internal resampling establishes and which transfer remains untested. |
| Treatments or years with contrasting conditions | If the data support it, use low-stress conditions to constrain potential and comparable stress contrasts to constrain response. Check baseline conditions, treatment timing, competing stresses and developmental windows. Where these effects overlap, state the conditional interpretation or keep the confounded parameters fixed. |

Ask focused questions when missing information would change the calibration.
Typical questions concern the intended transfer, whether a missing harvest
means zero, which individuals were revisited, or whether a driver was known in
advance. Inspect available metadata first. Proceed with reversible assumptions
when they suffice and record them. A protocol-only request ends with the
proposed design and the unresolved decisions that affect it.

## Specify and screen an estimable parameter set

1. Record each parameter's process, units, scope (shared, group-specific or
   individual), starting value, bounds and provenance. Prefer relevant
   measurements and published evidence on the same scale and under comparable
   conditions. Distinguish physical limits from exploratory search ranges.
   An observed maximum under stress provides evidence about realized output,
   while a ceiling on potential needs separate justification.
2. Separate fixed independently measured values, initial states, externally
   supplied drivers, fitted parameters and competing model structures.
   Propose a small core of free parameters and additional candidates with a
   testable reason to include them. Record the observation or experimental
   contrast expected to distinguish each effect.
3. Before a large search, run the reference and perturb proposed parameters on a
   few representative training situations. Check whether each active parameter
   changes its intended output on the available support. Compare sensitivity
   to measurement resolution and stochastic variation. Check tradeoffs with
   simple profiles, pairwise perturbations or an equivalent diagnostic where
   needed. If several effects remain interchangeable, estimate a defensible
   combination, fix some parameters, or report the compatible range.

Freeze the planned blocks or joint fit, the observation masks, candidates,
objective and scoring weights, and the criteria for revisiting earlier
decisions. Use an error model where supported, or an explicit scale for each
variable and weights that reflect the intended unit of inference. Measure how
dense series, populous groups and poorly sampled targets influence the score.
When a total and its components carry the same information, designate a
primary objective and use the other quantities as diagnostics unless a joint
error model accounts for the dependence. Declare how failed runs and missing
predictions affect comparison on the fixed support.

## Choose optional forcing and a fitting sequence

- Use measured upstream values as forcing when their identity, timing, units
  and coverage support the intended comparison. Confirm the value received by
  the consumer and document the behavior at unmatched dates or objects. Choose
  a gap policy appropriate for the variable, including leaving a process free
  when the observations are too sparse. Use the
  [observation-provider and ownership guidance](data-calibration-evaluation.md#force-observations-into-a-scenario).
- Fit a free downstream response under measured inputs when that isolates the
  effect of interest. Evaluate conditional predictions on responses still
  generated by the model. When the intended prediction requires the coupled
  system, release the relevant forcing and check the free trajectory. If a
  retrospective forcing uses observations unavailable at prediction time,
  label the comparison as conditional and keep it separate from prospective
  evaluation.
- Where forcing is infeasible or irrelevant, fit the coupled model directly to
  aligned outputs. Start with the best-constrained processes or a small joint
  fit when feedback and the data warrant it. If using staged fitting, rerun the
  coupled reference after important blocks. Reopen earlier parameters when a
  measured output has degraded beyond a meaningful tolerance and the proposed
  change is supported by data. Recheck the affected outputs before accepting a
  revision. Document any changes to the plan and keep evaluation data reserved.
- For alternative formulations, estimate each model's free parameters under
  comparable data, objectives, constraints and tuning budgets. Freeze the
  resulting models before comparing their predictive performance. A comparison
  at one common parameter vector answers a separate sensitivity question
  about the effect of changing the formulation at that setting.

## Run, check and report

Use the package-specific method when available. PlantSimEngine's
`Evaluation.fit` is an extension point implemented by model packages. For
example, `PlantSimEngine.Evaluation.fit(Beer, data)` returns named fitted
parameters. See `docs/src/working_with_data/fitting.md` under the verified
package root. For an arbitrary coupled scenario, wrap scenario construction,
simulation and scoring in an objective suitable for the selected optimizer or
inference framework.

- Start each trial from a fresh scenario or a verified reset of state,
  topology, histories and random generators. Use `continue!` to advance a
  trajectory when history is intended. For stochastic models, compare
  candidates with paired seeds where appropriate and increase replicates when
  differences approach simulation noise. Identify the stochastic processes
  still active under forcing. Treat simulated replicates and biological
  replicates as different sources of variation.
- Check the baseline, a small search and a reproducible rerun of the selected
  parameters before scaling up. Choose a search consistent with the parameter
  dimension and response shape. Record seeds, starts, failures, convergence,
  boundary hits and poorly identified combinations. For costly runs, budget
  by trajectory and compare timing at equivalent output retention. Compile or
  parallelize when the workload merits it and check that the execution path
  reproduces the scientific outputs needed by the objective.
- For a long calibration, publish checkpoints at useful decisions. Include
  initial and current predictions on the training support, fitted and fixed
  values and residuals by the relevant groups and periods. Show individual
  measurements or their dispersion when available. Inspect components behind
  aggregate improvements to detect compensating errors.
- Deliver the observation and parameter maps, split, forcing choices,
  objective, run configuration, fitted values and diagnostic results in a
  reproducible form. Evaluate the frozen model on the intended prediction
  task following [empirical evaluation](data-calibration-evaluation.md#evaluate-predictions).
  Identify which results are calibration fit, conditional prediction or
  independent evaluation. State which parameters or domains remain weakly
  supported. Synthetic recovery can check the fitting implementation.

## References for protocol choices

- Wallach et al. (2024) give a staged soil–crop calibration protocol with
  documented observation groups and major and candidate parameters. Their
  demonstration uses artificial data and a particular selection criterion.
  Adapt the grouping and criterion to the study design. [Paper](https://doi.org/10.1016/j.envsoft.2024.106147)
- Wallach et al. (2021) compare calibration decisions in a multi-model crop
  exercise and give recommendations illustrated with phenology.
  [Paper](https://doi.org/10.1016/j.envsoft.2021.105206)
- CroptimizR documents a worked example of parameters shared across situations
  and parameters specific to varieties, and provides an example of staged
  optimization through a model wrapper. [Varietal example by Samuel Buis](https://sticsrpacks.github.io/CroptimizR/articles/Parameter_estimation_Specific_and_Varietal.html) · [Estimation interface](https://sticsrpacks.github.io/CroptimizR/reference/estim_param.html)
