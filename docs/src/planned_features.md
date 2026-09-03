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

Pass non-committing trial state through `run_call!`:

```julia
run_call!(context, :leaf_energy; environment=trial_environment, publish=false)
```

Then commit the accepted state through the model-facing environment API:

```julia
commit_environment!(context, accepted_environment)
run_call!(context, :leaf_energy; publish=true)
```

The transient state is interpreted by each target backend through its opaque
compiled handle, so one call can sample different cells for different leaves.
`commit_environment!` commits only the accepted state to a mutable backend.
Future work is to validate full voxel, layer, and octree implementations on
this same model-side API.

The full issue list is available on
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues).
