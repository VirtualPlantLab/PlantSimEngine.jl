# Benchmarks

`Project.toml` contains the dependencies for the PlantSimEngine benchmarks.
The default suite runs only these benchmarks, both locally and in CI.
AirspeedVelocity resolves this project before loading `benchmarks.jl`, so
optional downstream packages must stay out of its dependencies and sources.

The dedicated PlantBiophysics and full downstream workflows add their checked-out
packages with `Pkg.develop` after running the corresponding helper in
`prepare_full_performance_project.jl`. The full workflow develops XPalm,
PlantBiophysics, PlantGeom, and the PlantSimEngine checkout together, so XPalm
uses the compatible PlantGeom source instead of an older registry release.

The full downstream benchmarks run on demand, for example before a release or
after changes to the engine's performance. In GitHub Actions, manually run
`Full downstream performance`, or run `Benchmarks` with `full_performance` enabled.
There is no scheduled or tag-triggered full run. The regular CI, integration tests,
and PR benchmarks keep their existing triggers. `Pkg.test()` for PlantSimEngine
does not run the downstream benchmarks.

For a local downstream run, follow the environment setup in
`.github/workflows/FullPerformance.yml`, then set
`PSE_BENCHMARK_INCLUDE_DOWNSTREAM=true` when loading `benchmarks.jl`.
The flag enables the downstream suite; it does not install its dependencies.
`benchmark/test/runtests.jl` uses the same default. Passing a test-name pattern explicitly
selects those tests, as the dedicated downstream CI jobs do.
The pinned release comparisons in `release_baselines/` use separate projects.
