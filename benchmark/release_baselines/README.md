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

## Accepted local comparison, 2026-08-11

The release decision was checked on an Apple M3 Max MacBook Pro with 36 GB RAM,
macOS/Darwin 25.5.0, and Julia 1.12.1. The accepted current stack used
PlantSimEngine runtime commit `d5480c50`, PlantBiophysics commit `dbd04e0`, and
XPalm commit `192e43f7`. The release commits are the pinned sources listed
above.

PlantBiophysics used one Julia thread and a single constructed leaf scene for
one continuous 8,760-step trajectory. Each row is the median of 10 samples;
construction was outside the timed steady-state rows.

| Stack and output policy | Median | Minimum | Per step | Allocated bytes | Allocations | Release ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| release, normal retained outputs | 85.142 ms | not retained | 9.719 us | 129,536,608 | 1,759,504 | 1.000x |
| current, `outputs=:none` | 18.414 ms | 17.430 ms | 2.102 us | 25,883,792 | 288,137 | 0.216x |
| current, `outputs=:all` | 32.216 ms | 30.238 ms | 3.678 us | 47,792,736 | 868,558 | 0.378x |

Current PlantBiophysics construction was 16.359 ms median. The separate
100-scene, one-step fan-out diagnostic was 15.205 ms median and is not used as
the acceptance metric. The complete 113,880-row retained-output trajectory was
exactly identical to the pre-optimization current stack, with a maximum
absolute difference of 0.0.

XPalm used 10 Julia threads, although its model execution remained sequential.
Both sides warmed a 100-step run, prepared meteorology and `Palm` outside each
timed sample, and timed the same high-level `XPalm.xpalm` scope: scene
construction, the 4,160-step lifecycle run, requested outputs, and DataFrame
materialization. Julia startup and package loading were excluded. Five samples
were forced with a 120-second BenchmarkTools budget.

| Stack | Median | Per step | Allocated bytes | Allocations | Release ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| XPalm `v0.6.1` / PlantSimEngine `v0.14.1` | 5.416 s | 1.302 ms | 6,898,039,968 | 80,317,174 | 1.000x |
| current XPalm / current PlantSimEngine | 8.035 s | 1.931 ms | 3,378,642,888 | 39,259,563 | **1.483x** |

Raw full-cycle times, in seconds:

- release: `5.115200625`, `5.384637000`, `5.416365375`, `5.474346833`, `5.782515542`;
- current: `7.953668959`, `7.961468750`, `8.034666500`, `8.041943916`, `8.071678500`.

The current full-cycle output matched the committed XPalm `v0.6.1` reference:
step 4,160, 344 phytomers, LAI `5.0587602356164405`, and FTSW
`0.7991179101191216`. A separate staged profile kept construction and retention
costs distinct: 7.779 ms initial compilation, 6.438 ms no-output scene
construction, 83.562 ms for a 100-step no-output run, 79.818 ms for the same
short requested-output simulation, 3.323 ms to materialize its retained output,
and 95.263 ms with all outputs retained. The 100-step no-output profile included
10 lifecycle binding refreshes; the accepted 4,160-step timing includes all
growth-related refresh work.
