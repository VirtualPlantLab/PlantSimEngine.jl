# A Mental Model For PlantSimEngine

## New concept: composition

PlantSimEngine is a framework for composing and running scientific models. It
does not prescribe a plant architecture, and it is not itself a library of
crop, tree, or organ equations. Model packages provide those equations;
PlantSimEngine connects them to simulated entities, orders their execution, and
manages time, environments, and retained results.

Seven ideas are enough to read a PlantSimEngine simulation:

| Idea | Meaning |
|:--|:--|
| **Process** | A scientific responsibility, such as thermal time or light interception |
| **Model** | One reusable implementation of a process |
| **Application** | One configured use of a model in a simulation |
| **Object** | A simulated entity with stable identity, such as a scene, plant, leaf, or soil layer |
| **Status** | The current values owned by an object |
| **Environment** | Values sampled from outside object status, such as weather or microclimate |
| **Simulation** | A running timeline, including the live model, current step, and any retained output streams |

The distinction between a model and an application is important. A model
author writes an equation once. A simulation author can then apply it to one
whole plant, every leaf, selected soil layers, or several named groups without
putting an object loop inside the equation.

Objects are equally general. Scales and parent/child links describe the
topology chosen by the simulation author; PlantSimEngine does not require a
particular hierarchy. A simple simulation can have one object. A detailed one
can have scenes, several plants, organs, voxels, and shared resources.

Values reach a model in two ways:

- status inputs come from the target object or from outputs of other model
  applications;
- environment inputs are sampled from the environment selected for that
  application and object.

Before running, PlantSimEngine compiles applications into concrete
application/object targets, resolves value connections, and determines a valid
execution order. During the timestep loop, model kernels work with their own
parameters, the resolved status view, the sampled environment, constants, and
a runtime context.

## Page recap

- **You added:** no configuration yet—only the vocabulary used by every later
  journey.
- **PlantSimEngine infers:** application order and unambiguous value
  connections once a simulation is assembled.
- **You keep explicit:** scientific equations, object topology, ambiguous
  cross-object connections, time policies, and requested output history.
- **New API names:** none yet. The next page introduces `CompositeModel`,
  `run!`, `Simulation`, `final_state`, and `collect_outputs`.

