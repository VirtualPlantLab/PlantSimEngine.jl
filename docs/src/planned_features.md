# Roadmap

PlantSimEngine now has one composite-model/object runtime for single-object, multiscale,
multi-plant, soil, microclimate, and multirate simulations.

Current priorities are:

- migrate downstream model packages to `CompositeModel`, `CompositeModelTemplate`,
  `ObjectInstance`, and `ModelSpec`;
- strengthen type-stability and allocation tests for million-object workloads;
- add broader lifecycle tests for object creation, removal, movement, and
  environment-index refresh;
- improve diagnostics for ambiguous selectors, writer conflicts, and temporal
  policies;
- validate mutable voxel, layer, and octree microclimate backends;
- expand downstream release gates and performance benchmarks;
- evaluate parallel execution for independent compiled application batches.

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

Use `with_environment!` for non-committing trial scopes:

```julia
with_environment!(extra, trial_meteo) do
    run_call!(extra, :leaf_energy; publish=false)
end
```

Then commit the accepted state through the model-facing environment API:

```julia
update_environment!(extra, accepted_meteo)
run_call!(extra, :leaf_energy; publish=true)
```

`with_environment!` makes hard-called descendants sample the temporary state
through the normal environment path and restores the previous state afterwards.
`update_environment!` commits only the accepted meteorological object to a
mutable backend. Future work is to validate richer mutable voxel, layer, and
octree backends on this same model-side API.

The full issue list is available on
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues).
