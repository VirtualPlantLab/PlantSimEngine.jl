# PlantSimEngine

[![Build Status](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VEZY/PlantSimEngine.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/VEZY/PlantSimEngine.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/VEZY/PlantSimEngine.jl)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)

WIP package for defining and running processes and models related to plants, at any scale. The package is the result of an atomization of PlantBiophysics.jl. It only implements the functions that were there at the moment, and will continue growing from this state.

# Road map

- [ ] Remove dev version of PlantMeteo (use the published version)
- [ ] Move documentation from PlantBiophysics here
- [ ] Add PlantBiophysics to test `Project.toml`, and move the tests on dependencies, model check etc... in this package test instead of in PlantBiophysics, and keep only the tests related to the model it implements in there.
