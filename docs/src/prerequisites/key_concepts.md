# Key Concepts

## Processes And Models

A process identifies a biological or physical phenomenon, such as
photosynthesis, growth, water balance, or energy balance. A model is one
implementation of a process.

Models subtype `AbstractModel` and declare:

- `inputs_`: values read from object status;
- `outputs_`: values written to object status;
- `meteo_inputs_`: values sampled from the environment;
- `meteo_outputs_`: environment variables a controller may commit;
- `commit_environment!`: accepted meteorological state committed to a mutable
  environment by controller models;
- `dep`: processes called manually by the model, when required.

The numerical kernel is implemented with:

```julia
PlantSimEngine.run!(model, models, status, meteo, constants, extra)
```

## Composite Models And Objects

A `CompositeModel` contains objects and model applications. An `Object` can represent a
model, plant, soil volume, axis, internode, leaf, sensor, or any other simulated
entity. PlantSimEngine does not impose one plant architecture.

Objects can carry:

- a stable identifier;
- scale, kind, species, and name metadata;
- parent-child relationships;
- geometry and position;
- mutable `Status`;
- object-local model applications.

`CompositeModelTemplate` packages reusable applications for a species or object type.
`ObjectInstance` mounts the template in a model. Several instances can share
models and parameters while declaring targeted overrides for exceptional
objects.

## Model Applications

`ModelSpec` configures one use of a model:

- `AppliesTo(...)` selects target objects;
- `Inputs(...)` selects producers for value dependencies;
- `Calls(...)` binds manually controlled model calls;
- `TimeStep(...)` selects the execution cadence;
- `Environment(...)` configures environment sampling;
- `Updates(...; after=:application_id)` orders intentional additional writers;
- `OutputRouting(...)` controls output publication.

This keeps model implementations generic. Models do not need to know which
model, object, timestep, or coupling scenario will use them.

## Soft And Manual Dependencies

Ordinary dependencies are inferred by matching model inputs with outputs and
are compiled into an acyclic execution order. `Inputs(...)` is used when the
source is cross-object, renamed, temporal, or otherwise ambiguous.

Some algorithms need direct call-stack control. For example, a model energy
balance may repeatedly call leaf energy-balance models until canopy
microclimate converges. Such dependencies are bound with `Calls(...)`; the
parent invokes them with `run_call!`.

## Status And References

`Status` stores variables in references. Same-rate coupling normally shares
those references instead of copying values. A many-object input uses a
reference vector, so aggregation models read current source values directly.

Temporal coupling uses published streams when producer and consumer clocks
differ. Policies include `HoldLast`, `Interpolate`, `Integrate`, `Aggregate`,
and `PreviousTimeStep`.

## Environment

The active environment backend may be:

- one constant atmosphere shared by all objects;
- a time-indexed weather table;
- a mutable layer, voxel, grid, or octree microclimate.

Object-to-environment support is compiled and cached. Geometry changes mark the
binding dirty so it can be refreshed without recomputing spatial lookup at
every timestep.

## Multiscale Plant Structure

PlantSimEngine treats scale and object hierarchy as scenario data. A plant may
use leaves directly under a plant, or axes, segments, internodes, roots, and
other intermediate levels. Selectors express relationships such as one source,
many descendants, the current plant, an ancestor, or all matching objects in
the model.

MultiScaleTreeGraph objects can be imported with `objects_from_mtg`, but the
runtime operates on the same composite-model/object representation afterward.
