# Pinned downstream release baselines

These isolated projects preserve the release stacks used by the performance
acceptance checks. They deliberately do not share the main benchmark manifest.
Instantiate and run each project in a fresh Julia process with one Julia thread:

```sh
JULIA_NUM_THREADS=1 julia --project=benchmark/release_baselines/plantbiophysics -e 'using Pkg; Pkg.instantiate()'
JULIA_NUM_THREADS=1 julia --project=benchmark/release_baselines/plantbiophysics benchmark/release_baselines/plantbiophysics/run.jl

JULIA_NUM_THREADS=1 julia --project=benchmark/release_baselines/xpalm -e 'using Pkg; Pkg.instantiate()'
JULIA_NUM_THREADS=1 julia --project=benchmark/release_baselines/xpalm benchmark/release_baselines/xpalm/run.jl
```

Both runners warm the relevant API before collecting several one-setup,
many-timestep samples. They write a CSV result when an output path is supplied
as their first argument and otherwise place it beside the runner. Construction
is outside the timed region. Julia startup and package loading are excluded.

Pinned sources:

- PlantSimEngine `v0.14.1`, commit
  `503af98c3709a0b1207407e3741b7cb09ebfbcf7`;
- PlantBiophysics `v0.17.0`, commit
  `9f39af4ffd48bab234e5d80b89cd52c67b9f3f82`;
- XPalm `v0.6.1`, commit
  `a0dbf2e8d6fa9e21f8e8ced3220da184b3ee3f4c`.

Do not commit generated manifests or result CSV files. Preserve the runner,
resolved manifest, raw CSV, machine description, Julia version, and thread
count together when recording a release decision.
