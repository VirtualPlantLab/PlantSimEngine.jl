# Reusable XPalm bindings, call targets and temporal histories

The full typed program now reuses input memberships, live reference carriers,
ordered execution rows and call memberships. It derives temporal-history needs
from the original input routes. Scientific XPalm kernels and production PSE
`src/` are unchanged. Implementation commits are `cd5a51ca` and `b88875dc`.

## What is reused

- A binding records source-cohort counts/reference epochs and its sorted source
  locations. Unchanged live bindings reuse their carriers. Fixed `Self`, parent
  and exact-ancestor selectors resolve directly through the object registry.
- On source growth, general bindings inspect only newly visible rows. Previously
  selected live references are checked at their cached locations. Unrelated
  growth leaves IDs, locations and carriers unchanged; actual reference
  replacement uses copy-on-change. Values themselves are never cached.
- Scheduled applications reuse sorted cohort row orders. Manual calls reuse
  selected rows and inspect only appended candidates. Each call still constructs
  fresh contexts with the current status, step, environment and publication
  policy. Targeted initializers validate their newborn directly.
- Only outputs consumed by `PreviousTimeStep` maintain initial/last/prior
  snapshots. Retained events are produced only when requested. Temporal inputs
  still receive a fresh owned payload on every invocation, including cache hits.

The source counts distinguish live registration from committed membership:
targeted newborn calls can see an addition immediately, while `Many` observes
it after the creator application closes its lifecycle event. Ascending object
ID order remains the execution/RNG order. All cache data belongs to one
simulation; the prepared program is reusable.

This relies on the entry's existing **append-only topology** contract and
registry-mediated canonical reference replacement. Removal, reparenting, direct
private topology mutation and arbitrary model/schema replacement are not newly
admitted. Reference invalidation is cohort-wide; the subsequent repair examines
selected references and appended candidates rather than rescanning all rows.
Distributed output destination columns still use their existing resolution path.

## Executed preservation gates

| Gate | Result |
| --- | ---: |
| Full original XPalm, every-step state/topology/outputs/RNG | 108,606 assertions |
| Focused reuse, invalidation and numeric contracts | 85 assertions |
| Standard safe executable, four cases and same-host relocation | 21,457 assertions |
| Prior Julia layouts: fixture, calls, soil/root, phytomer, lifecycle | 1,516 assertions |
| Prior native CLI modes | Fixture, soil/root and phytomer cases, invalid inputs and relocation pass |

Focused cases exercise live values without rebuilding a carrier, actual
canonical `Ref` replacement, independent simulations, unsorted insertion IDs,
pending newborn visibility, initializers, partial errors/retry rejection,
producer-specific `Updates` snapshots, consumer-owned temporal arrays, Float32
values/streams, and unrelated growth across two plants. They also exposed and
fixed two admitted optional-selector gaps: a populated `OptionalOne` input now
aliases canonical status, and optional calls reject multiple targets.

`julia.json`, `native.json`, `legacy-julia.json` and `legacy-native.json` contain
the executed results. The standard build uses Julia 1.13.1 / JuliaC 0.3.12,
safe trimming, generic CPU, no verifier override, no diagnostic preload and no
arbitrary entrypoints. Its bundle is identified in `build.json`; the whole
bundle is required for deployment. An initial verifier failure on an abstract
temporal-output tuple was corrected by preserving its concrete schema type.

## Matched warm Julia comparison

Both arms below are the typed program under the same Julia JIT. The baseline is
the pre-cache runtime at `bf4c3ab7`; the candidate is `b88875dc`. This table does
not compare against ordinary PSE and does not measure JuliaC compilation.

Seven alternating before/after trials use fresh states, common forcing and an
independent ordinary PSE oracle. The timer includes MTG/model/RNG/status
instantiation and all daily steps; authoring, program preparation, common forcing,
explicit pre-trial GC and complete parity checks are outside it. GC occurring
during a simulation remains included. Every timed result passes canonical
state, ordered topology and RNG checks; retained cases compare every output.

| Days / outputs | Objects | Retained samples | Before | After | Speedup | Allocated bytes, before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 12 / all | 54 | 6,271 | 2.56 ms | 1.99 ms | 1.29× | 4.89 → 3.92 MB |
| 60 / all | 246 | 122,554 | 46.94 ms | 18.80 ms | 2.50× | 76.08 → 61.19 MB |
| 128 / all | 518 | 539,883 | 475.41 ms | 101.41 ms | 4.69× | 343.05 → 307.65 MB |
| 60 / none | 246 | 0 | 43.01 ms | 14.75 ms | 2.92× | 53.42 → 35.99 MB |

Final reachable state, including the reachable prepared program, costs about
1.9% more at 60 retained days, 4.3% more at 128 retained days, and 7.2% more at
60 days without outputs. The short case uses 6.2% less. These separate
`Base.summarysize` measurements are neither peak RSS nor allocated-byte counts.
The cache storage tradeoff remains relevant to future larger-population work.
Native allocation bytes are not inferred from the JIT measurements.

These are single-host Apple M3 observations without CPU pinning or confidence
intervals. Application width remains 61. Both durations use the same accelerated
qualification inputs: phyllochron endpoints 0.3, flowering 30, abortion 6 and
sex determination 12 degree days, seeds 1 and `architecture=false`. Neither
million-organ scaling, mature palms, architecture rendering nor calibrated
production performance is established.

## Native comparison boundary

The native comparison uses separate before/after instrumented apps, both built
with safe trimming and generic CPU. It alternates process order across three
cycles, with one P0 warmup and seven independent simulations per process:
21 measured simulations per arm. Internal timers cover the same
`simulate_full_xpalm` operation in both executables, including runtime model
replacement and Constants/forcing construction. Build, startup, explicit GC,
printing, host parsing and scientific parity checks are excluded. Each process's
last result is checked against original PSE. P0 times and all scalar trials
remain in the evidence; no cold-start or zero-JIT claim is made.

| Days / outputs | Previous safe executable | Delta safe executable | Additional speedup |
| --- | ---: | ---: | ---: |
| 12 / all | 1.152 ms | 0.888 ms | 1.30× |
| 60 / all | 41.92 ms | 16.73 ms | 2.50× |
| 128 / all | 473.10 ms | 104.83 ms | 4.51× |
| 60 / none | 36.87 ms | 11.65 ms | 3.16× |

These compare two versions of the prepared executable. They are additional
gains over the previous executable, rather than a fresh comparison with ordinary
PSE. Native versus JIT is not a compiler-only control: CPU targets, prepared
constants and forcing-construction boundaries differ. No percentages from the
earlier ordinary-runtime or PR #244 screens are added to these results.

The standard qualified bundle is separate from this instrumentation.
`performance-build.json` records the latter's build; `native-*.json` records
the matched trials and validation counts. `provenance.json` binds source files,
compiler settings and binary hashes.

## Reproduce through Kaimon

Materialize a baseline snapshot from `bf4c3ab7` containing
`benchmark/juliac_program`, then use a Kaimon session at the candidate's app:

```julia
include("../full_program_reuse_checks.jl")
FullProgramReuseChecks.run_checks()
include("../full_xpalm_checks.jl")
FullXPalmChecks.run_checks()
include("../full_program_reuse_performance.jl")
FullProgramReusePerformance.compare_reuse(
    "/path/to/baseline/benchmark/juliac_program"; days=128)
```

For native timing, build an instrumented safe bundle for each revision through
`FullXPalmNativePerformance.build_native_performance`, keeping the baseline's
Project/Manifest path dependencies pointed at its matching checkout. Then:

```julia
include("../full_program_reuse_native_performance.jl")
FullProgramReuseNativePerformance.compare_native_reuse(
    "/path/to/before/bundle", "/path/to/after/bundle"; days=128)
```

The host comparison may load the baseline in an isolated namespace in the same
Kaimon process. Both arms then use the same loaded scientific packages. All
comparisons here used that approach, with baseline runtime source hashes
verified against the recorded revision. No full ordinary preparation is paid
and then lowered again by either typed arm.

## Earlier iterations

`warm-60-initial.json` and `initial-coarse.patch` retain the first cohort-wide
cache experiment: it was faster but allocated 43% more. The patch reconstructs
that exact iteration against `bf4c3ab7`; its runtime hashes match the JSON.
`point/` retains the intermediate `cd5a51ca` results. Its broader invalidation
still raised allocations on growing runs. These are diagnostic records, kept
separate from the final delta measurements and excluded from their summaries.
