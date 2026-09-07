# AI agent skill

An **AI coding agent** can read and edit code and run tests with the tools you
make available. PlantSimEngine provides an optional skill with instructions
and executable examples for implementing process models and assembling
simulations. A **skill** is a folder of instructions and examples that your
agent can read while working.

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
`assets`, and `scripts` together. Don't forget to tell your agent to upgrade its skill
whenever you update PlantSimEngine: different versions can describe
different APIs.

The skill uses the Julia tools available in your agent's environment. It does
not require a particular editor or connector, but you can use e.g. [Kaimon](https://kahliburke.github.io/Kaimon.jl) to help your agents further.

## Ask it to assemble existing models

You can ask your agents anything, for example you can ask it to assemble existing models into a simulation:

> Use the PlantSimEngine skill shipped with my loaded package. I want to
> compare two existing models for the same process. First identify available
> alternatives and explain their inputs, outputs, units, and assumptions.
> Show what data each needs and flag anything that is missing. Build the
> smallest simulation that can compare them with the same input data. Explain
> their connections, run the tests, and show the results. Keep any required
> physical conversion explicit.

Useful inputs to provide are the package names, the process of interest,
your input data and its units, and the outputs you want to compare. The
[Loaded model catalog](@ref) and [Model compatibility and replacement](@ref)
show the corresponding manual workflow.

Please give as much contest a possible to your agent, for example the data should be documented properly with protocols, units, etc...

## Ask it to implement an equation

Provide the equation or source paper, definitions of the variables,
parameter values and units, and at least one expected result:

> Use the PlantSimEngine skill shipped with my loaded package to implement
> the equation and variable definitions I provide. Check whether an existing
> process already represents this question. Keep the equation readable and
> declare each input and output, including its units and physical meaning.
> Test one calculation against my reference result, then use the model in
> a simulation of one object.
> If any assumption, physical conversion, parameter, or validation criterion
> is unspecified, identify it before choosing one. Show the code, test
> results, and remaining scientific questions.

The [basic model tutorial](journeys/modelers/basic_model.md) follows this
sequence without an agent. For an existing implementation, also use
[Port an existing model](@ref).

## Review what the agent returns

Expect a concrete result you can inspect:

- the loaded package path and version;
- the selected process and hypotheses, with the evidence supplied for them;
- readable model code and scenario configuration;
- checks that the required inputs are available, their units and meanings
  match, and the models receive values from the intended sources;
- tests actually run, their results, and any remaining limitations.

PlantSimEngine's `Authoring` reports describe models and compare interfaces.
`Diagnostics` explains inputs, connections, timing, and execution. The reports
show which information comes from the model author, which was found by
examining the code, and which is missing. These checks help find implementation and coupling errors; scientific
validation still needs suitable observations or reference results.

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
