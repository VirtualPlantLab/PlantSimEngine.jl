# Roadmap

PlantSimEngine uses the same simulation engine for a single object or many
plants and organs, including models that run at different time steps. This
page lists work planned to extend and check these capabilities.

Current priorities are:

- migrate downstream model packages to `CompositeModel`, `CompositeModelTemplate`,
  `ObjectInstance`, and `ModelSpec`;
- strengthen type-stability and allocation tests for million-object workloads;
- test more combinations of adding, removing, and moving objects, including
  updates to their local growing conditions;
- make error reports clearer when object selections match too many objects,
  models try to set the same output, or time-step connections need attention;
- validate mutable voxel, layer, and octree microclimate backends;
- test more dependent packages and simulation performance before releases;
- investigate running independent groups of model calculations in parallel.

## Environment and microclimate work

### Trial environment sampling

Coupled microclimate solvers can iterate on local environmental state before
accepting a timestep. A canopy energy-balance model, for example, may need to:

1. propose a trial canopy air temperature and humidity;
2. run leaf models against that trial air state;
3. update the trial air state from leaf sensible and latent heat fluxes;
4. repeat until convergence;
5. commit only the accepted canopy or voxel air state to the mutable environment
   backend.

Pass non-committing trial state through `run_call!`:

```julia
run_call!(context, :leaf_energy; environment=trial_environment, publish=false)
```

Then commit the accepted state through the model-facing environment API:

```julia
commit_environment!(context, accepted_environment)
run_call!(context, :leaf_energy; publish=true)
```

Each leaf still receives conditions for its own location, so one call can
supply different trial values to different leaves. `commit_environment!`
saves only the accepted growing conditions. Future work will test this
approach with environments represented by cells, layers, and octrees.

The full issue list is available on
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues).
