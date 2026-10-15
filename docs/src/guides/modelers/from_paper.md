# Implement a model from a paper

Use this guide when you have a scientific formulation and want a reusable
PlantSimEngine model. The result should make it possible to trace the code
back to the source and to check a calculation independently. An AI agent can
help with extraction and implementation; the [AI agent guide](../../agent_skill.md)
provides a starting prompt.

## Establish what the source specifies

Keep the paper, supplements, and any reference implementation together with
their identifiers and versions. Identify which formulation you are reproducing:
a paper may describe several alternatives or change equations between
experiments. Cite pages, equation numbers, tables, or code locations beside
the relevant implementation notes.

A compact record can capture the information needed to write the model:

| Source item | Record |
|---|---|
| Equations | Formula, source location, and the meaning of each symbol |
| Variables | Input, output, state, forcing, or temporary quantity; units and physical basis |
| Parameters | Value, units, source, and whether published, measured, assumed, or fitted |
| Time | Rate or amount, update interval, integration rule, and temporal lag |
| Conditions | Initialization, boundary conditions, valid domain, and special cases |
| Reference results | Inputs, expected outputs, source, and appropriate comparison tolerance |
| Unresolved information | Missing definitions, conflicting passages, and choices needed to proceed |

Pay attention to conventions that can change a calculation: carbon versus dry
matter, leaf versus ground area, one organ versus a whole plant, temperature
units, and rates versus interval totals. State updates also need an explicit
initial value and a rule for carrying a result into the next step.

When the source is incomplete, distinguish what it states from what you
propose. An assumption made to complete an implementation should have its own
justification. Keep contradictory definitions visible until resolved. A missing
parameter, unit, or reference is not a reason to invent a plausible one.

## Choose the model boundary

Use [New process or new model?](@ref) to look for the existing scientific process.
An alternative equation usually belongs to that process, with its own concrete
model type. Sharing a process does not make alternatives interchangeable;
compare their ports, physical meanings, dependencies, and time requirements
before substituting one.

Keep fixed parameters in the model and each object's changing state in its
`Status`. Put environmental forcing in the environment interface. Declare
units, basis, and temporal meaning with `VariableContract`, and keep conversions
in explicit [adapter models](../coupling.md).

Split a formulation into components when users need to couple, replace,
schedule, or evaluate those calculations independently. For example, separating
light interception from biomass production allows observed intercepted light
to drive a test of the growth equation. A short equation does not need several
components merely because it contains several arithmetic operations.

[Implement a basic model](../../journeys/modelers/basic_model.md) shows the
declarations and kernel. [Port an existing model](@ref) shows how to preserve
a calculation from reference code. Document the hypothesis and provenance with
`Authoring.model_metadata` and known parameter facts with
`Authoring.parameter_metadata`.

## Check implementation and scientific agreement separately

Start with a source-backed calculation, an independently derived numerical
example, or a trusted reference implementation. Compare the direct kernel
result with the same inputs before checking a composed simulation. Include
special cases relevant to the published equations, such as zero input or a
transition between branches. Choose tolerances justified by numerical precision
or the resolution of the reference, rather than by the discrepancy you obtain.

`Authoring.validate_model` checks declarations. A minimal scenario and
`Diagnostics` can establish where inputs come from and when the model runs.
These checks establish computational behavior. They do not demonstrate that
the equations predict observations accurately.

Reproducing a published figure may require weather, initial conditions,
parameter sets, or code that the paper does not provide. Record which information
is available and what remains unresolved. Digitized plot values are approximate
reference values; keep their extraction method and uncertainty visible. Do not
change published parameters merely to make a reproduction look convincing.

Keep parameter estimation separate from reproduction of a published
parameterization. For fitting and independent prediction checks, continue with
[Parameter Fitting](@ref) and [Collecting And Plotting Outputs](@ref). Observations
used to drive a component are imposed inputs; agreement with those same imposed
values does not evaluate its predictive ability.

## Leave a reviewable result

Alongside the readable model and scenario, retain the source-to-code record,
parameter provenance, checks actually run, and unresolved scientific choices.
State the PlantSimEngine version used and whether the implementation has only
structural checks, reproduces reference calculations, was calibrated, or was
evaluated independently. See [Model repository layout and tests](@ref) for
organizing that evidence in a reusable package.
