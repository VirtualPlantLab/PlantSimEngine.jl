# Optional MAESPA comparison

This downstream project is separate from `benchmark/Project.toml` and the
AirspeedVelocity suite. It does not add MAESPA to the core benchmark resolver.
Run every Julia process through Kaimon when required by the local project rules.

The runner uses the checked-out MAESPA `examples/two_species.jl` unchanged:
two artificial species, two trees, one soil layer, 16 logical leaf units and
96 half-hour steps. It exercises the complete mounted canopy/soil chain in
that example. Its canopy-air iteration option is disabled; it is not coverage
of Tuzet, iterative canopy air, PlantBiophysics, understorey, parsing, file I/O
or a larger scene. It is an integration/performance workload, not a calibrated
site or independent scientific validation.

## Three independent environments

Prepare one temporary project each for:

- the registered PlantSimEngine 0.15.1 source used by MAESPA;
- the unchanged parent `91317b622ff051de39791598640c288671a95151`;
- the candidate worktree.

Copy this `Project.toml` into each temporary directory. Pin the same transitive
dependency versions using a copy of the existing MAESPA `Manifest.toml`,
resolving relative `path` entries against their original project directory.
Develop the unchanged MAESPA checkout and the desired PlantSimEngine source
together in that project. These operations must run in Kaimon and must modify
only the temporary environment. Never develop or resolve a comparison engine
in MAESPA's ordinary project. Record the exact resolved manifests with results.

Use one Julia version, compute/GC thread count and startup/compiler flags for
all three processes. Check the active project, `Base.pathof(MAESPA)`,
`Base.pathof(PlantSimEngine)` and `Base.pkgversion(PlantSimEngine)` before
measurement. Avoid concurrent benchmark processes; report ambient desktop
load as uncontrolled unless independently established otherwise.

## Running through Kaimon

In the registered-release session:

```julia
include("/path/to/candidate/benchmark/downstream_maespa/run.jl")
MAESPADownstreamBenchmark.run_benchmark("registered-0.15.1", "/tmp/results/registered")
```

In the separate parent and candidate sessions, load the **same runner file**:

```julia
include("/path/to/candidate/benchmark/downstream_maespa/run.jl")
MAESPADownstreamBenchmark.run_benchmark("parent-91317b62", "/tmp/results/parent";
    reference="/tmp/results/registered/complete_snapshot.jls")
```

```julia
include("/path/to/candidate/benchmark/downstream_maespa/run.jl")
MAESPADownstreamBenchmark.run_benchmark("candidate", "/tmp/results/candidate";
    reference="/tmp/results/registered/complete_snapshot.jls")
```

`repetitions=5` and both `outputs=:none`/`:all` are the defaults. Progress is
logged outside timed operations. The first pass is reported separately and
includes any method compilation after package import; it is not process
startup or package-load time. Each output mode receives another complete
warmup before repeated samples. Build, zero-step runtime initialization and
96-step continuation are timed separately. Full GC precedes construction,
outside the timed build. The continuation's GC and compilation contributions
are retained. No profiler or `performance=true` instrumentation is enabled.

After timing, every run's complete final state is checked for exact equality.
For retained output runs, every publication row is also checked. Comparisons
use `isequal`, preserving array shapes, numeric types, NaNs, dates, application
IDs and object IDs. Snapshots are normalized to package-independent structures
so different engine source checkouts can read the same serialized reference.
Source hashes and the active manifest are checked again before completion.
The receipt includes both runner hashes, compute/interactive/GC thread counts
and the available Julia compiler, compiled-module and startup-file settings.

Keep raw `measurements.toml`, `complete_snapshot.jls`, resolved manifests,
Kaimon launch settings and logs together in the external evidence directory.
Do not commit generated manifests, snapshots, timing files or profiles.

## Scope of conclusions

The unchanged downstream comparison measures effects of the engine changes on
existing public calls. It does not measure the potential gain from migrating
MAESPA to the prepared-call/acceptance API. `prepared_calls.jl` provides that
separate check:

```julia
include("/path/to/candidate/benchmark/downstream_maespa/prepared_calls.jl")
PreparedCallBenchmark.run_benchmark("candidate", "/tmp/results/candidate/prepared_calls.toml")
```

Run that same fixture at the registered release and parent as well. Every
revision executes the existing unpublished-trial plus published-replay path.
The candidate additionally executes `evaluate_call!` then `accept_call!`. The
fixture checks exact final states and retained rows over eight real timesteps,
and verifies two versus one kernel evaluation per target. The timed loops use
one and sixteen targets, a fixed current timestep, `outputs=:none`, five samples
and 10,000 operations per sample. They exclude timeline growth, retained-history
growth and output collection. An explicit counter adds the same small amount
of work to each child evaluation on both paths.

Report microbenchmark results separately. Replay elimination may change the
numerical algorithm when kernels have stateful effects; this fixture's leaf
equation is intentionally deterministic and overwrites its output.
