# Roadmap

## Planned major features

### Varying timesteps

Currently, all models are required to make use of the same timestep. Some physiological phenomenae within a plant tend to run on an hourly basis, others are slower. Weather data is often provided daily. Enabling different timesteps depending on the model is on the roadmap, and is planned as the next milestone.

### Multi-plant/Multi-species simulations

A goal for PlantSimEngine down the line is to be able to simulate complex scenes with data comprising several plants, possibly of different species, for agroforestry purposes.

Its current state doesn't enable practical declaration of several plant species, or multiple plants relying on similar subsets of models with partially different models or parameters.

## Minor features

- Implement a trait or a prepass that checks whether weather data is needed, and if so, if it is properly provided to a simulation
- Better dependency graph visualization and information printing

## Minor planned improvements and QOL features

- A reworked and more consistent mapping API, and multiscale dependency declaration
- Improved user errors
- More examples
- Better dependency graph traversal functions
- Ensure cyclic dependency checking and PreviousTimestep is active for ModelLists

## Improvements on the testing side

- Better tracking of memory usage and type stability
- Working CI/Downstream tests
- state machine checker, validating output invariants
- graph fuzzing for improved corner-case testing

## Possible features (likely not a priority)

- API enabling iterative builds and validation of mappings and ModelLists
- Build step for the models, *i.e.* a function that would write a mapping or ModelList into a Julia script for validation, improved readability and (maybe) performance (no need to traverse the dependency graph anymore).
- Improved parallelisation
- Reintroduce multi-object parallelisation in single-scale

## Other minor points

- Examples/solutions for floating-point accumulation errors
- More examples for fitting/type conversion/error propagation
- MTG couple of new features #106
- Other minor bugs
- Unrolling the run! function

## Other

- Reproducing another FSPM?
- Diffusion model example?

The full list of issues can be found [here](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues)