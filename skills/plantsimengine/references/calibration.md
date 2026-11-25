# Design and run a calibration

Use this guide when the user asks to estimate parameters or to design a
calibration. Scale the protocol to the prediction goal, the model and the
evidence. For a well-posed fit with an agreed split and a small parameter set,
verify those choices and proceed. When the scope is open, use the audit to
decide what can be estimated before launching a search.

For an executed calibration, use the target PlantSimEngine.jl model in Julia
to generate predictions for the objective and validation. Reuse the study's
scenario when available. If only equations are supplied, implement the minimal
PlantSimEngine scenario that represents them and check a reference case before
fitting. A hand calculation or independent script can check that case. If the
engine cannot run, report the blocker and which steps were completed.

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

Check biological constraints across parameters as well as individual bounds.
For example, if leaf expansion starts and ends on the same thermal-time
scale, fitting an onset and a positive duration preserves their order.

Define what would justify freeing each additional candidate. For example,
first fit a water-stress threshold with a justified fixed slope. Then free
the slope and compare both fits on identical training observations. Inspect
whether intermediate deficits distinguish threshold from slope. Retain the
extra parameter when the contrast and improvement support it. An information
criterion is an option for comparable likelihoods on the same data.

Freeze the planned blocks or joint fit, the observation masks, candidates,
objective and scoring weights, and the criteria for revisiting earlier
decisions. Use an error model where supported, or an explicit scale for each
variable and weights that reflect the intended unit of inference. Measure how
dense series, populous groups and poorly sampled targets influence the score.
When a total and its components carry the same information, designate a
primary objective and use the other quantities as diagnostics unless a joint
error model accounts for the dependence. Declare how failed runs and missing
predictions affect comparison on the fixed support.

## Select training situations for each calibration block

For each block, record the parameter, the process and stage where it acts,
the observable, and the sites, plots, treatments or dates eligible for
scoring. Give the evidence for eligibility and counts of independent units.
Choose these subsets within the training split before comparing fits. A site
can contribute to different blocks in different periods. Run the preceding
trajectory when its water balance, reserves or developmental state carries
into the scoring window.

| Parameter block | Informative training contrast |
| --- | --- |
| Potential growth or expansion | Select sites or periods with evidence of adequate resources during the relevant stage, such as measured water status and adequate nitrogen. The highest observed yield alone cannot establish potential. If all situations are limited, use independent information or report the range compatible with the observed stress. |
| Water-stress response | Compare water-limited plots or periods against comparable well-watered ones spanning the response, with adequate nitrogen or measured differences that can be accounted for. Use the timing and intensity of water deficit during the sensitive stage. |
| Nitrogen-stress response | Use a nitrogen supply or plant nitrogen status gradient with comparable water availability. Where both stresses vary together, seek a factorial contrast or report which combined effect the data constrain. |

For competing mechanisms, spell out an observable on which their predictions
would differ and check its availability. For example, fruit number and mean
fruit mass per bunch can help distinguish two explanations for the same
harvest mass. With total mass alone, limit the inference to what it constrains.

Match each scored observation to the period when its contributing cohort was
exposed to the fitted process. An early harvest may come from organs already
past the sensitive stage at initialization. Use cohort or event records to
decide whether to start earlier, reconstruct initial cohorts, or score early
harvests separately. Document uncertainty when the exposure cannot be dated.

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
- Choose how to fill gaps from the variable, measurement protocol and
  intended use. For example, when LAI is measured weekly on the same plot
  and changes smoothly, propose linear interpolation between successive valid
  measurements to supply daily LAI directly to consumers. The LAI process
  can be omitted in this composition. Check for harvest, pruning or other
  abrupt changes before bridging an interval. Agree on the longest credible
  gap and how to handle dates outside the measured range. Mark interpolated
  inputs as such and score predictions against actual measurements. Using
  the next measurement makes this a retrospective reconstruction.
- If the choice is unclear after inspecting the dates, values and metadata,
  ask the user a concrete question grounded in the data. For example:
  “Most LAI measurements are a week apart, but this plot has a three-week
  gap. Was there a cut during that period? Is interpolation defensible there,
  or should the model supply LAI across that gap?” Use the answer to record
  a policy by variable and, when necessary, by interval.
- When simulated fallback is appropriate, keep the process running at every step.
  Compute its prediction, then let one correction model publish the value used
  by consumers: use a valid observation for that object and time when available,
  otherwise use the current prediction. A measured zero is a valid value.
  Keep the raw prediction and record which source was used. For a dynamic
  state, specify whether the correction updates the state for the next step
  or only the input seen by a consumer. Reconcile linked stocks or increments
  if a state correction affects their balance. Trace a gap, a correction and
  the step after it. Score the pre-correction prediction when assessing the
  corrected variable itself.
- For alternative formulations, estimate each model's free parameters under
  comparable data, objectives, constraints and tuning budgets. Freeze the
  resulting models before comparing their predictive performance. A comparison
  at one common parameter vector answers a separate sensitivity question
  about the effect of changing the formulation at that setting.

### Order the blocks and revisit them

Read the simulation schedule and bindings, including dependencies carried
between steps. Use that order to propose calibration blocks. For each block,
name the process, the first parameter to vary, the observation that constrains
it, and the parameters held fixed. Start with an upstream effect that the
training data can distinguish. Group strongly coupled parameters when the
observations can constrain them jointly.

For example, if developmental stage governs leaf expansion, first fit a
thermal-time requirement to observed stage dates with base temperature fixed
from independent evidence. Then hold that requirement fixed and fit a leaf
expansion parameter to repeated leaf-area measurements. Release any stage
forcing and rerun the coupled trajectory after the second block. If canopy
development feeds back through water stress to development rate, compare
stage-date residuals again and revisit the thermal-time parameter with the
updated canopy parameters. With a one-way dependency, verify that stage dates
are unchanged and carry the upstream fit forward.

When several upstream variables are forced, release each one separately from
the same forced reference, then release them together. Keep parameters, units
of observation, scoring dates, initial conditions and random seeds fixed.
Compare both the released trajectory and the downstream response. A loss
after releasing phenology directs the next check to stage timing and its
consumers. A loss only after releasing both phenology and leaf area warrants
checking their interaction before choosing which block to revisit.

After each pass, inspect all affected training targets on the same support.
Alongside each block's own fitting subset, rerun the coupled model on a fixed
training panel. Keep a table by fitting step, variable and relevant treatment
with bias, RMSE in measurement units and matched count. Keep observation
identities fixed within each comparison and flag missing predictions. If leaf
area improves while stage dates drift on dry plots, inspect those trajectories
and the water-stress feedback before reopening phenology.
Repeat the affected blocks or refine them jointly while changes exceed the
declared tolerances for scores and parameter movement. If blocks trade errors
or oscillate, check identifiability and report the tradeoff. Use the reserved
evaluation set once the coupled configuration is frozen.

### Prepare repeated evaluations before fitting

List the fixed compositions needed by the campaign, for example a downstream
fit with observation correction and a free coupled model for refinement.
For an admitted composition, prepare and build its JuliaC application before
the optimizer loop. See the checkout's
[compiled scenario guide](../../../docs/src/guides/compile_scenario.md) for
the qualified entry point and supported features. In this checkout the
documented path captures model parameters and environment rows at build time.
Time-varying observations and changing candidate parameters therefore require
a separately verified runtime input path before a bundle can serve that fit.

For every proposed bundle, try two distinct candidates and two driver series
through the same executable, including a missing observation if applicable.
Compare the resulting trajectories and objective against ordinary Julia runs
from the same initial state. If the composition or inputs exceed compiler
support, keep the ordinary Julia process warm across trials and reset each
trajectory. Measure build time, first evaluation in a fresh process, and
subsequent time per evaluation separately, with the same scoring and outputs.

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
- Trace one training observation through a trial: verify the candidate value
  reached the intended model instance, inspect its simulated output, then
  reproduce the observation match and its contribution to the objective.
  For threshold events, define how a simulated event date is extracted and
  how a missed event is scored before comparing candidates.
- Check the baseline, a small search and a reproducible rerun of the selected
  parameters before scaling up. Choose a search consistent with the parameter
  dimension and response shape. Record seeds, starts, failures, convergence,
  boundary hits and poorly identified combinations. For costly runs, budget
  by trajectory and compare timing at equivalent output retention. Compile or
  parallelize when the workload merits it and check that the execution path
  reproduces the scientific outputs needed by the objective.
- For a local search, compare starting and fitted values, final scores and
  stopping reasons across dispersed feasible starts. When scores are similar
  despite different parameters, compare trajectories under conditions that
  distinguish the mechanisms, such as intermediate water deficits. Report
  which predictions are stable and where another measurement could separate
  the fits. When final scores differ materially, check simulation failures,
  budget limits and sensitivity to initialization before interpreting the
  best fit biologically.
- For a long calibration, publish checkpoints at useful decisions. Include
  initial and current predictions on the training support, fitted and fixed
  values and residuals by the relevant groups and periods. Show individual
  measurements or their dispersion when available. Inspect components behind
  aggregate improvements to detect compensating errors.
- Deliver the observation and parameter maps, split, forcing choices,
  objective, run configuration, fitted values and diagnostic results in a
  reproducible form. Evaluate the frozen model on the intended prediction
  task following [empirical evaluation](data-calibration-evaluation.md#evaluate-predictions).
  Compare fitted and reference predictions on the same held-out units with
  the same scoring rules. Report deterioration for individual targets even
  when the aggregate improves. If that comparison prompts retuning, record
  those units as development data for the revised model.
  Identify which results are calibration fit, conditional prediction or
  independent evaluation. State which parameters or domains remain weakly
  supported. Synthetic recovery can check the fitting implementation.

## References for protocol choices

- CroptimizR illustrates [multi-start diagnostics](https://sticsrpacks.github.io/CroptimizR/articles/Parameter_estimation_simple_case.html),
  [candidate selection](https://sticsrpacks.github.io/CroptimizR/reference/estim_param.html)
  and [stepwise error diagnostics](https://sticsrpacks.github.io/CroptimizR/reference/plot_stats_evolution.html).

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
