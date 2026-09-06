# Why PlantSimEngine?

PlantSimEngine helps you build plant simulations from process models that you
can inspect, test, reuse, and replace. You choose the scientific equations,
the plants, organs or other entities they describe, and the exchanges between
them. The engine connects their inputs and outputs and runs the resulting
simulation in Julia.

This is useful when your research question requires a particular combination
of processes or assumptions:

- **Crop modelling:** assemble development, light interception, biomass, or
  water-balance processes at the resolution your question needs. Start with
  [a coupled simulation for a canopy](../journeys/users/one_object.md).
- **Canopy ecophysiology:** connect weather, local conditions and organ processes,
  including calculations that must iterate together. The
  [MAESPA-style synthesis](../journeys/users/maespa_synthesis.md) demonstrates
  these coupling mechanisms with pedagogical models.
- **Functional–structural plant modelling:** apply processes to organs,
  connect their results to the plant, and update the structure during growth.
  Start with [one multiscale plant](../journeys/users/one_plant.md).

The scientific models, parameter sets, input data, and validation for your
species or experiment come from your own work or model packages such as
[PlantBiophysics.jl](https://github.com/VEZY/PlantBiophysics.jl). PlantSimEngine
provides the tools for connecting and running them.

## Compare hypotheses without rewriting the whole simulation

A process can have several model implementations. For example, you may want
to compare two biomass-production equations or introduce water limitation
into a previously radiation-driven model. Each implementation keeps its own
parameters and equations; the scenario specifies where it runs and how it
receives inputs.

Replacement depends on the model's interface: the values it needs and produces,
and what those values mean. The new model must provide the outputs other
models need, and its own inputs must be available. A variable contract records
information such as units, whether a quantity is per plant or per unit area,
and whether it is a rate or an accumulated amount. The same variable name
alone is insufficient. Moving from a quantity per unit ground area to a total
per plant, for example, needs an explicit conversion.

Replacing a model for selected plants within one application requires a
compatible complete interface. Broader changes may require reconnecting
affected inputs. See
[model compatibility and replacement](../step_by_step/model_switching.md).

For model authors, this separation keeps a process implementation readable
from inputs to outputs. For researchers assembling models, it makes the
choice of hypotheses visible in the scenario. Both can test a component
before investigating its behaviour in the full system.

## Choose the representation that answers your question

An object can represent a leaf, a plant, a canopy layer, a soil compartment,
or another entity you define. You can work with one object, several objects,
or a hierarchy imported from a multiscale tree graph. Geometry is optional.
Different models can be applied to different selections of these objects.

The same process equation can be reused over compatible objects while the
scenario handles their selection and connections. A plant-level model can,
for example, read values from its own leaves. The modeller supplies the
aggregation equation and any required area, mass, or temporal conversion.
Changing resolution also requires checking the assumptions and validity of
the chosen models. See [value coupling across objects](../guides/multiscale/value_coupling.md).

When organs appear, disappear, or move within the plant structure,
PlantSimEngine updates the affected model selections and connections. This lets
growth change which organs contribute to a plant-level calculation while
retaining their identities and historical outputs. Follow
[Modify Plant Structure](../journeys/users/structure_changes.md).

## Connect different time steps and control scientific iteration

Canopy exchange may run hourly while development runs daily. Each model
can run at its own time step, with explicit rules for reading values produced
at another time step. The appropriate averaging, accumulation,
or rate-to-amount conversion is a scientific choice. The
[cadence tutorial](../journeys/users/cadences.md) makes those choices explicit.

Some calculations also need a controller: an energy-balance algorithm may
call gas-exchange models repeatedly while finding an accepted leaf temperature.
Explicit model calls let the controller manage that iteration and record the
accepted result once. See [advanced execution](../journeys/users/advanced_execution.md).

## Understand what the simulation will do

The `Authoring` and `Diagnostics` interfaces expose model declarations,
missing inputs, the sources of values, execution order, local environmental
conditions, and which results are saved. You can inspect why a particular leaf
receives a value, which model supplies it, and when it is updated. The
[graph viewer](../guides/graph_visualizer_editor.md) provides another view of
the same composition.

These reports help separate a coupling problem from a problem in an equation
or its assumptions. Declared contracts expose mismatches at model boundaries;
scientific validation still needs suitable observations, reference results,
and tests. See the [model authoring API](../API/API_public.md) and
[model testing guide](../guides/modelers/repository_and_tests.md).

## Keep repeated simulations practical

PlantSimEngine prepares model selections and connections before repeated
execution, avoids copying input values where possible, and processes groups
of similar objects together. Model equations remain ordinary Julia
calculations whose performance can be measured and improved.

There is application-level performance evidence: the
[2025 PlantBiophysics.jl paper](https://doi.org/10.1093/insilicoplants/diaf021)
reports a median of 5.3 microseconds for one leaf and one time step of its
coupled energy-balance, photosynthesis, and stomatal-conductance benchmark.
That result concerns the implementations, versions, inputs, and hardware used
in the study. For your scenario, measure initialization, repeated execution,
structural changes, and retained outputs separately using the
[benchmarking guidance](../developers.md). A public parallel or distributed
executor remains [planned work](../planned_features.md).

## AI-assisted model development

An AI coding agent is software that can read and edit code and run tests with
your development tools. Small process models, explicit inputs and outputs,
declared units, and reports on model connections give it concrete information
to read and check. An agent can help draft a model, compare declared
interfaces, assemble a scenario, inspect its connections, and run tests with
the tools available in your development environment.

PlantSimEngine provides a versioned [AI agent skill](../agent_skill.md), a
[loaded model catalog](../API/model_catalog.md), and the same authoring tools
used by people. You supply the coding agent and its execution environment.
Model assumptions, physical conversions, supporting references, and scientific
validation remain the responsibility of the researcher. Begin with
[Implement a basic model](../journeys/modelers/basic_model.md) to see the
complete model, an independent equation test, and its use in a simulation.

## How this fits among plant-modelling tools

Modularity and multiscale modelling have a substantial history.
[APSIM](https://docs.apsim.info/docs/development/software/interfaces) supports
replaceable model interfaces;
[DSSAT](https://dssat.net/frontpage/) combines crop models with data and
experimental workflows;
[OpenAlea](https://openalea.readthedocs.io/en/latest/packages/modelling.html)
provides components, multiscale structures, and plant-geometry tools; and
[GroIMP](https://grogra.de/) integrates FSPM modelling and visualisation.
[Cropbox](https://doi.org/10.1093/insilicoplants/diac021) also uses Julia and
dependency analysis for declarative crop modelling.

PlantSimEngine's contribution is the combination described here: readable
process equations, explicit inputs and outputs, a choice of how to represent
plants, different time steps, controlled iteration, changing structures, and
calculations you can inspect. It is a useful fit when you want to develop or assemble
that scientific model combination yourself, while keeping its choices visible
and its components independently testable.
