# XPalm runtime comparison, 2026-11-01

The complete prepared XPalm program is faster than the original XPalm graph in
ordinary PSE on the measured cases. This includes the actual JuliaC safe
executable, rather than treating a warm JIT timing as an AOT result.

## Setup and simulation

These are median **warm-process** times on one Apple M3 host. All arms use the
original 61-application `architecture=false` graph, identical forcing,
parameters and seeded scientific kernels. Each sample starts a fresh simulation.
Scientific authoring is outside the timers; the typed program is prepared once
and reused, as it is at build time for the executable.

| Days | Retain outputs | Final objects | Regular XPalm / PSE | Typed program / Julia JIT | JuliaC safe / generic | Regular / JuliaC |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: |
| 12 | all | 54 | 72.03 ms | 2.44 ms | 1.27 ms | 56.7× |
| 60 | all | 246 | 339.58 ms | 47.05 ms | 40.92 ms | 8.3× |
| 60 | none | 246 | 308.81 ms | 43.08 ms | 36.89 ms | 8.4× |

Most of the gain is already present in the prepared runtime: the 60-day retained
case is 7.2× faster under the same warm Julia JIT. JuliaC improves that typed
case by a further 1.15×. These measurements do not establish that compilation
alone makes arbitrary Julia or XPalm code 8–57× faster.

The speedup falls as the growing case becomes larger. Do not extrapolate the
12-day ratio to production-year simulations, multiple palms, or
`architecture=true`. Both durations use the qualification fixture's accelerated
phyllochron rate (0.3) and reproductive thresholds (flowering 30, abortion 6,
sex determination 12 degree days), with RNG seeds 1. These are matched test
inputs, not a calibrated field scenario.

## Timing boundaries and checks

`FullXPalmPerformance.compare_warm` records seven trials per arm/boundary after
warming both paths. Trial order alternates between regular PSE and the typed
runtime. It measures:

- `prepared_steps`: only daily advancement, with both simulations ready before
  the timer. Regular / typed medians are 57.04 / 2.33 ms at 12 days and
  322.87 / 45.45 ms at 60 days with retained outputs.
- `setup_and_steps`: starting from scientifically authored inputs, regular PSE
  includes weather conversion, MTG/status import, scenario compilation and bulk
  `run!`. The typed arm includes MTG reconstruction, model/RNG/status
  instantiation and all steps, using its prepared program. Common plain forcing
  rows and Constants are outside both timers.

The native entry times `simulate_full_xpalm` inside a separate copied app built
with JuliaC 0.3.12, Julia 1.13.1, safe trimming and generic CPU. Its boundary also
includes runtime model replacement and Constants/forcing construction; it is
slightly more inclusive than the JIT typed `setup_and_steps` boundary. It does
not time scientific authoring or program preparation.

Each native process performs one P0 warmup followed by seven independent
simulations. Medians above aggregate 21 samples across three serial processes
per case. Explicit GC precedes each timer; GC triggered during a simulation
remains included. Printing the last result, process startup, host parsing and
parity checks are outside the timer. P0 times remain in the JSON, excluded from
the medians: the first observed 12-day P0 took about 97 ms, while subsequent
processes took about 3 ms. This is not a cold-launch or zero-JIT qualification.

Every JIT trial is checked outside its timer against an independent original
PSE result: all final canonical fields, ordered topology, owned RNG fingerprints
and, when retained, every output key/value. The native last result from every
process receives the established native parity gate:

| Case | Canonical fields | Retained samples | Assertions per native process |
| --- | ---: | ---: | ---: |
| 12 days, all | 1,121 | 6,271 | 7,399 |
| 60 days, all | 4,904 | 122,554 | 127,465 |
| 60 days, none | 4,904 | 0 | 4,911 |

Without retained outputs, canonical state, topology and RNG still match.
Internal temporal-history retention differs between the runtimes and is not
treated as user output. Native allocation bytes were not measured. The warm
JIT setup-and-step allocation medians for the 60-day retained case are 367.4 MB
for regular PSE and 76.1 MB for the typed runtime; these are allocated bytes,
not peak memory or native allocation measurements.

These are single-host desktop observations, without CPU pinning or confidence
intervals. This task launched the comparisons serially with no concurrent
benchmark computation. The qualified standard app, bundle and `build/latest.txt`
are unchanged; only a separate temporary app adds the timing entry.

## Evidence and reproduction through Kaimon

`performance-warm-*.json` and `performance-native-*.json` retain all scalar
samples, settings and validation counts. `performance-provenance.json` records
the measured source revision, versions and instrumented binary/entry hashes.
`performance-reproduction.json` records a second safe build through the committed
helper and a passing 7,399-assertion native parity check. Its instrumented entry
hash exactly matches the entry used for all reported native timing samples.
The source revision predates the new measurement drivers and evidence; the
warm metadata's dirty flag records those untracked additions, with no runtime
source changes in this comparison.

In a Kaimon session at `benchmark/juliac_program/app`:

```julia
include("../full_xpalm_performance.jl")
warm12 = FullXPalmPerformance.compare_warm(; days=12)
warm60 = FullXPalmPerformance.compare_warm(; days=60)
warm60none = FullXPalmPerformance.compare_warm(; days=60, retain=false)
```

Build and measure the separate instrumented app through Kaimon:

```julia
push!(LOAD_PATH, abspath("../buildenv"))
using JuliaC
include("../full_xpalm_native_performance.jl")
built = FullXPalmNativePerformance.build_native_performance()
native12 = FullXPalmNativePerformance.measure_native(built.bundle; days=12)
native60 = FullXPalmNativePerformance.measure_native(built.bundle; days=60)
native60none = FullXPalmNativePerformance.measure_native(built.bundle;
    days=60, retain=false)
```

The builder creates fresh temporary app/bundle directories, rebases path
dependencies, injects only the timing entry and uses the standard verifier.
It never writes the standard app or latest-bundle pointer. No arbitrary
entrypoints, verifier overrides or diagnostic preloads are used.
