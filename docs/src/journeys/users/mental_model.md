# A Mental Model For PlantSimEngine

PlantSimEngine connects scientific models and runs them together. For example,
one model can calculate the light absorbed by a canopy, and another can use
that light to calculate biomass production. You choose the equations and the
parts of the plant or environment they describe.

This page explains the terms used in the guides. If you have not run an
example yet, start with [your first simulation](one_object.md).

## Models describe calculations; objects describe what is simulated

A **process** is something you want to calculate, such as photosynthesis or
light interception. A **model** provides the equations for that process.
Two models for the same process can use different equations or assumptions.

An **object** represents something in your simulation: a leaf, a plant, a
canopy, or a soil layer, for example. Each object has a **status**, which
stores its current values, such as leaf area or water content.

You decide how much detail to represent. A canopy can be one object, or it
can contain several plants with individual leaves. PlantSimEngine does not
require a particular plant structure.

## An application says where and how to use a model

A **model application** combines a model with instructions about where to run
it, how often to run it, and where to get its inputs. For example, you could
apply one photosynthesis model to every leaf and run it once an hour.

You write the photosynthesis equation once. PlantSimEngine then runs it for
each selected leaf, using that leaf's own values and local conditions. You
can also apply different models to different groups of leaves or plants.

In the [first simulation](one_object.md), all models describe the same canopy,
so `CompositeModel` creates these applications for you. Later guides use
`ModelSpec` to choose objects and connections explicitly.

## Inputs come from object values or the environment

A model needs **inputs** to calculate its **outputs**. For example, a
light-interception model reads LAI and calculates absorbed light. Another
model can then use that absorbed light as an input.

Weather and local growing conditions are supplied through an **environment**.
This can be a weather table shared by the whole simulation, or a source of
local conditions that differ between leaves or soil layers.

Before the simulation starts, PlantSimEngine checks where each input will
come from and puts the calculations in order. If a biomass model needs the
light model's result, the light model runs first. You can inspect these
connections in the [graph viewer](../../guides/graph_visualizer_editor.md).

## A simulation keeps track of progress and results

Calling `run!` starts a **simulation**. It keeps track of the current time
step and the current values for every object. It also saves the history of
the outputs you requested.

Use `final_state` to read the latest values, `collect_outputs` to make a table
of saved results, and `step!` or `continue!` to advance the same simulation.
The [results guide](../../guides/data/outputs_plotting.md) shows how to select
and plot those outputs.
