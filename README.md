# PlantSimEngine

[![Build Status](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VEZY/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VEZY/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

WIP package that enforce a single API for models related to plants, soil and atmosphere. It helps defining and running processes with any implementation (*i.e.* model), at any scale.

Defining a new processes is done with `@gen_gen_process_methods`, which creates automatically:

- the base function of the process, *e.g.* `energy_balance!_()`
- the user interfaces, *e.g.* `energy_balance!()` and `energy_balance()`
- the abstract process type, used as a supertype of all models implementations, *e.g.* `AbstractEnergy_BalanceModel`
- the documentation for all the above
- a basic tutorial on how to make a model implementation 

Then, modelers are encouraged to implement their models to simulate the process following a set of basic simple rules enforced by the package.  

# Road map

- [x] Remove dev version of PlantMeteo (use the published version)
- [x] Move documentation from PlantBiophysics here
- [ ] Write doc with less dependence on PlantBiophysics
- [ ] Add PlantBiophysics to test `Project.toml`, and move the tests on dependencies, model check etc... in this package test instead of in PlantBiophysics, and keep only the tests related to the model it implements in there.
