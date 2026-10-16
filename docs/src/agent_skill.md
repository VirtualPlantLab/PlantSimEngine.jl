# AI agent skill

An **AI coding agent** can read and edit code and run tests with the tools you
make available. The examples on this page assume a recent frontier coding or
reasoning model with access to your project, source documents, data, and Julia
execution tools. Choose a model suitable for the complexity of your scientific
task; a chat session without those tools cannot execute or validate the code.

PlantSimEngine ships an optional **skill**: a folder of instructions,
references, and executable examples that an agent can read as needed. It covers
model authoring, coupling, debugging, observations, calibration, and evaluation.

You choose the scientific question, assumptions, references, and validation
evidence. The agent can help turn those choices into code and check that the
declared models connect as intended.

## Set up the skill for your package version

Find the skill shipped with the PlantSimEngine version you actually use:

```julia
using PlantSimEngine

package_root = pkgdir(PlantSimEngine)
skill_root = joinpath(package_root, "skills", "plantsimengine")
(Base.pathof(PlantSimEngine), Base.pkgversion(PlantSimEngine), skill_root)
```

Copy or link that complete directory into your coding agent's skill directory,
following its installation instructions. Keep its `SKILL.md`, `references`,
`assets`, `scripts`, and `evaluations` together. Update the skill when you update
PlantSimEngine so its instructions describe the API you actually use.

The skill uses the Julia tools available in your agent's environment. It does
not require a particular editor or connector. We recommend installing
[Kaimon](https://github.com/kahliburke/Kaimon.jl#quick-start) as an optional way
to give your agent a live Julia session for execution, inspection, and debugging.
Its Quick Start explains installation and connecting your coding agent.

## Describe the result and provide the evidence

Start with the scientific goal, relevant files, constraints, and the result you
want to inspect. Let the agent choose how to investigate and implement it.
Detailed instructions help when a scientific protocol requires them or an
observed mistake needs correcting; a long sequence of generic reasoning or
verification instructions is rarely a useful starting point.

Current [OpenAI guidance on skills and prompts](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)
and [Anthropic's skill authoring guidance](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
recommend focused instructions and references loaded as needed. Check their
effect on your own tasks; scientific requirements still need to be explicit.

Tell the agent to use the skill shipped with your loaded PlantSimEngine package.
The following prompts are starting points to adapt, with square brackets
marking information from your study.

### Implement a model from a paper

Provide the paper and relevant supplements, the formulation you want, and any
reference implementation or known results. State the intended object scale
and time interval.

> Implement [formulation] from [paper and supplements] as a reusable
> PlantSimEngine model for [scale and interval]. Keep equations and parameter
> sources traceable to their pages, equation numbers, or tables. Identify
> unresolved scientific choices without inventing values. Deliver readable
> model code, a minimal scenario, and checks against [reference results],
> with the assumptions and remaining limitations.

See [Implement a model from a paper](guides/modelers/from_paper.md),
[Implement a basic model](journeys/modelers/basic_model.md), and
[Port an existing model](@ref). The skill's `references/paper-to-model.md`
supplies the corresponding scientific guidance.

### Couple component models

Provide the model packages, objects and topology, weather or spatial sources,
units, and the outputs of interest. Mention any known conversions or timing
requirements.

> Couple [component models] for [objects and topology] using [input data]
> at [cadences]. Explain the selected sources, units, physical bases, and time
> meanings of the connections. Keep conversions explicit and flag missing
> inputs or incompatible interfaces. Deliver the scenario and evidence that
> it connects the intended objects and preserves [expected relationship].

See [Coupling models](@ref), [Model catalog and related packages](@ref), and
[Model compatibility and replacement](@ref). The skill includes
`references/scenario-coupling.md` and runnable coupling examples.

### Debug an unexpected result

Provide a runnable scenario, its inputs, the error or unexpected output, and
what you expected and why. Include the relevant observation or reference
result, rather than only a plot showing disagreement.

> Investigate [error or discrepancy] in [scenario] with [inputs]. The expected
> result is [result and evidence]. Find where the discrepancy first appears
> and distinguish configuration, numerical, and scientific causes. Show the
> evidence for your diagnosis and a verified correction where supported;
> leave unsupported hypotheses explicit. Keep parameter tuning separate.

See [Inspect a simulation](troubleshooting/runtime_contracts.md),
[Common Errors](@ref), and
[Debugging Growth And Resource Ordering](@ref). The skill's
`references/diagnostics.md` maps symptoms to the public inspection tools.

### Force a model with observations

Identify which measured variable should replace a predicted input, its units,
object identity, timestamps, sampling interval, and missing-data rules. State
which downstream results should still be predicted.

> Use measured [variable] from [dataset] to drive [consumer models] instead
> of predicting that input. Respect [units, object IDs, and sampling policy]
> and document any time alignment or conversions. Show the values supplied
> at model updates and the downstream predictions. Keep the imposed values
> distinct from results used to assess model performance.

See [Use Observed Values In A Simulation](@ref). Supplying observations may
require removing the model that ordinarily predicts the same input; choosing
two writers is a different experiment.

### Calibrate selected parameters

Provide the calibration data and its protocol, target variable, parameter
names and bounds, objective, and the data reserved for evaluation. Make clear
whether other parameters and initial conditions are fixed.

> Calibrate [parameters within bounds] against [target observations] using
> [calibration subset and objective]. Keep [fixed parameters and initial
> conditions] fixed and reserve [evaluation subset]. Report the parameter
> estimates, fitting diagnostics, objective value, and limitations. Save
> the configuration and data identifiers needed to reproduce the fit.

See [Parameter Fitting](@ref). PlantSimEngine's `Evaluation.fit` is an extension
point; the model package or study supplies its fitting method and optimizer.

### Evaluate on independent observations

Provide frozen parameter sets, the evaluation subset, the prediction target,
matching rules, and meaningful metrics. Keep any model selection or tuning
data separate from the independent evaluation data.

> Evaluate [frozen baseline and calibrated models] on [independent dataset]
> for [target, scale, and interval] without retuning. Match predictions to
> observations using [matching rules]. Report [metrics], residual patterns,
> and differences by [site or treatment], with sample counts and exclusions.
> Explain which conclusions the evaluation supports and where uncertainty
> or missing coverage limits them.

See [Collecting And Plotting Outputs](@ref) and [Parameter Fitting](@ref).
The skill's `references/data-calibration-evaluation.md` covers observation
roles, data alignment, calibration, and independent evaluation.

## Review what the agent returns

Expect a concrete result you can inspect:

- the loaded package path and version;
- the selected process and hypotheses, with the evidence supplied for them;
- readable model code and scenario configuration;
- checks that the required inputs are available, their units and meanings
  match, and the models receive values from the intended sources;
- tests actually run, their results, and any remaining limitations.

For a data-based study, also expect the observation roles and alignment rules,
the calibration/evaluation split, parameter provenance, and reproducible
metrics. An optimizer converging or a declaration check passing does not
establish predictive accuracy.

PlantSimEngine's `Authoring` reports describe models and compare interfaces.
`Diagnostics` explains inputs, connections, timing, and execution. The reports
show which information comes from the model author, which was found by
examining the code, and which is missing. These checks help find implementation
and coupling errors; scientific validation still needs suitable observations
or reference results.

## Check the packaged examples

The skill includes a minimal model, alternative hypotheses, a physical
conversion model, coupling examples, and their tests. You or your agent can check
the copy supplied by the installed package with:

```julia
include(joinpath(
    pkgdir(PlantSimEngine), "skills", "plantsimengine",
    "scripts", "check-examples.jl",
))
```

Use [Model repository layout and tests](@ref) when you are ready to organize
your own reusable model package.
