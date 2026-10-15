# Implement a model from a paper

Use this reference for translating scientific source material into a
PlantSimEngine component. The outcome is a traceable implementation of the
requested hypothesis, with unresolved choices visible. See
[model-authoring.md](model-authoring.md) for the model API and
[scenario-coupling.md](scenario-coupling.md) when composing it.

## Scientific information that changes the implementation

Read the relevant paper, supplement, and supplied data or code. Record exact
source locations for equations, variable definitions, parameter values, and
boundary/initial conditions. A page, equation, table, or supplement identifier
is more useful than a citation alone. Distinguish the original formulation
from later corrections, adaptations, or choices made for this implementation.

Resolve, where the source supports it:

- the scientific process and hypothesis;
- parameter meanings, units, admissible ranges, and how values were obtained;
- input/output units and physical basis, spatial extent, and temporal meaning;
- state variables, initial conditions, and whether an equation defines a
  rate, interval amount, algebraic relation, or differential equation;
- environmental drivers, validity range, and reported limitations;
- numerical methods and the observations or reference results used to assess
  the formulation.

These are scientific facts to extract, not fields to fill by guessing. If the
source is inaccessible, a symbol is undefined, or the evidence conflicts,
report the specific gap. Proceed with independent implementation work where
possible; choices that change the scientific result need an explicit basis.

## Mapping into PlantSimEngine

Classify fixed values as model parameters, changing state/inputs as `Status`,
drivers as environment inputs, and constants as constants. Reuse a process
type when the new formulation answers the same scientific question.
Separate subprocesses when they need independent coupling, replacement,
scheduling, or validation; a paper's section structure need not become a
package hierarchy.

Declare the scientifically known port contracts. Keep conversions visible in
named adapters, including rate-to-amount and leaf/plant/ground-area changes.
Discretizing a continuous equation is an implementation choice: document the
integration method and initial conditions rather than presenting the
discretization as the published equation. Scenario cadence should remain a
scenario choice unless the scientific formulation requires a particular step.

Keep equations readable and connect code/docstrings to their source locations.
Use `Authoring.model_metadata` and `Authoring.parameter_metadata` for known
structured facts; the model documentation carries the scientific explanation,
provenance, adaptations, and unresolved decisions. A second hypothesis is
useful for a requested comparison, not a prerequisite for implementing one.

## Evidence for the result

Prefer a direct calculation against a published numerical example, analytical
limit, or supplied reference result, followed by a minimal composed scenario.
Check scientifically relevant boundaries and any introduced numerical method.
If the paper gives only a figure, distinguish a visual or digitized comparison
from exact numerical reproduction and retain extraction uncertainty.

For dynamic equations, conservation, positivity, equilibrium behavior, and
timestep sensitivity may supply stronger evidence than one endpoint. Choose
checks relevant to the formulation. If no independent reference result is
available, say which properties were checked and which claims remain untested.

The reviewable result includes the model, relevant tests/scenario, and a short
source-to-code record: equation/source location, implemented quantity, and
any deviation or unresolved choice. Keep agreement with an equation separate
from empirical validity. Fitting published or local parameters does not
constitute independent evaluation; use
[data-calibration-evaluation.md](data-calibration-evaluation.md) for that work.

## Example request

> Implement the hypothesis in this paper as a reusable PlantSimEngine model.
> Preserve the equations, units, state definitions, and assumptions; trace
> implementation choices to source locations and flag missing information.
> Show evidence for a reference calculation and a minimal composition, and
> state what remains scientifically unvalidated.
