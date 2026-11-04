# XPalm distributed output cache

The prepared runtime rebuilt distributed output columns on each request. A
request walked the destination cohorts, evaluated the topology selector, sorted
the selected object IDs, and allocated the vectors of IDs and references.
Publishing distributed outputs repeated that work. Ordinary PSE already reuses
its prepared output carriers.

An OS sample of the previous JuliaC executable during the 4,160-day profile
contained `_full_output_column` in 961 of 3,878 main-thread samples, including
both the carbon kernels and publication. These are inclusive stack counts
from the whole workload. The timing runs below use no profiler.

Commit `bafd33e06` caches the sorted IDs and live references by application
origin and distributed output variable. Both kernel access and publication use
the same columns. A change in committed destination counts or canonical
reference epochs invalidates the cache. Refresh replaces the columns and keeps
pending births outside the existing visibility boundary.

An exploratory three-trial screen compared each candidate independently with
`137919035`. The medians were 5.036 s for the frozen prototype, 5.068 s for a
status-view reuse variant, and 4.416 s for the distributed output cache. The
status-view variant was dropped. The [screen](nongrowth-cache-screen.json)
records those trials.

## 4,160-day comparison

Julia 1.13.1 on the same Apple M3-class Mac, on AC power. The scenario uses
unchanged XPalm parameters and requests no retained outputs. All three arms
matched the ordinary PSE oracle and the object count on every simulated day.
No measured trial compiled code.

| Runtime | Preparation | 485 growth days | 3,675 other days | Uninterrupted execution | Execution allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary PSE | 23.14 ms | 4.389 s | 1.219 s | 5.369 s | 5.736 GB |
| Frozen prototype `137919035` | 21.54 ms | 1.765 s | 3.763 s | 5.561 s | 4.936 GB |
| With distributed output cache | 20.37 ms | 1.765 s | 2.607 s | 4.150 s | 4.525 GB |

Preparation is the median of each trial's planning and instantiation sum.
The uninterrupted figures are medians of six balanced, warmed trials. The
two day columns are medians from four separately timed passes per arm. The
prototype with the cache spends 31% less time on days without a birth than
the frozen prototype. It still spends 2.14 times as long as ordinary PSE on
those days. It finishes the full simulation 25% faster than the frozen
prototype and 23% faster than ordinary PSE.

Each phase trial has a companion that uses the same loop without the daily
clock. Median paired clocked-minus-plain differences were −48, −51 and −23 ms
for ordinary PSE, the frozen prototype and the cache respectively. Individual
differences vary in both directions, so these measurements do not isolate a
precise overhead for the clock. The phase columns describe whole days, and
their independent medians need not sum to the uninterrupted time.

The [raw benchmark](nongrowth-cache-4160.json) records all timing and allocation
samples, daily times and object counts, and source and environment hashes.

## Correctness

The prepared runtime suite passed 207 assertions, including column reuse,
write-through, committed births and replacement of canonical references.
The Julia 1.13.1 / JuliaC 0.3.12 safe/generic binary matched ordinary PSE on the
60-day retained scenario and on 4,160 days with unchanged XPalm parameters
and no requested outputs. Parity covers topology, canonical fields, retained
sample values and coverage, and both RNG probes. The [native receipt](nongrowth-cache-native.json)
records hashes and case counts.

## Reproduce

Export the frozen prototype without switching the candidate checkout.

```sh
baseline=$(mktemp -d)
git archive 137919035 | tar -x -C "$baseline"
printf '%s\n' "$baseline/benchmark/juliac_program"
```

In a Kaimon session at the candidate `benchmark/juliac_program/app` project,
pass the printed path as `baseline`.

```julia
include("../full_program_writer_performance.jl")
FullProgramWriterPerformance.compare_writers(baseline, mktempdir();
    days=4160, baseline_revision="137919035", paired_phases=true)
```
