# Roadmap

PlantSimEngine now has one scene/object runtime for single-object, multiscale,
multi-plant, soil, microclimate, and multirate simulations.

Current priorities are:

- migrate downstream model packages to `Scene`, `ObjectTemplate`,
  `ObjectInstance`, and `ModelSpec`;
- strengthen type-stability and allocation tests for million-object workloads;
- add broader lifecycle tests for object creation, removal, movement, and
  environment-index refresh;
- improve diagnostics for ambiguous selectors, writer conflicts, and temporal
  policies;
- validate mutable voxel, layer, and octree microclimate backends;
- expand downstream release gates and performance benchmarks;
- evaluate parallel execution for independent compiled application batches.

The full issue list is available on
[GitHub](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues).
