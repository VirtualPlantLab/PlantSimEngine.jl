# Per-object XPalm writer validation

Runtime source `33157851f`, compared against the frozen prepared runtime at
`171e59fae`. The ordinary PSE implementation and the XPalm fixture are identical
across those revisions. The comparison uses Julia 1.13.1 and XPalm 0.7.0 on the
same Mac on AC power.

The 60-day case uses accelerated reproduction (rate 0.3) and retains all
requested outputs. The 4,160-day case uses untouched XPalm package parameters and
requests no retained outputs. Every arm starts with fresh model, status, topology
and RNG state. The ordinary PSE oracle checks canonical values, topology, RNG and
all retained samples outside the timers.

## Warm Julia timings

Each preparation total is the median of the per-trial sum of reusable planning
and state instantiation. The ordinary PSE column measures scene construction
and zero-step runtime preparation. Scientific model authoring and common forcing
are separate from these totals. Preparation and uninterrupted execution use six
balanced trials per arm. The two day categories come from separately timed
diagnostic runs, four per prepared arm and one for the ordinary PSE reference.
A growth day is any daily step whose final object count exceeds its starting
count. Both categories include all scientific and runtime work on those days.
The raw samples also record allocations and JIT counters.

The 60-day case grows on every day. At 4,160 days, `outputs=:none` still allows
ordinary PSE to store the internal history required by its temporal inputs.
The two prepared variants both keep their own temporal buffers and have zero
user-facing retained samples.

Totals in milliseconds per simulation.

| Days | Runtime | Preparation | Growth days | Other days | Uninterrupted execution |
| ---: | --- | ---: | ---: | ---: | ---: |
| 60 | Ordinary PSE | 14.19 | 375.82 | — | 373.59 |
| 60 | Frozen prototype | 14.17 | 20.72 | — | 20.78 |
| 60 | Per-object validation | 14.56 | 19.83 | — | 19.83 |
| 4,160 | Ordinary PSE | 22.84 | 4,039.05 | 1,408.92 | 4,833.76 |
| 4,160 | Frozen prototype | 14.62 | 1,823.15 | 3,431.39 | 5,070.65 |
| 4,160 | Per-object validation | 15.10 | 1,853.63 | 3,251.01 | 5,015.44 |

The 4,160-day scenario has 485 growth days and 3,675 other days in every arm.
Its growth-day median increases by 1.7% with per-object validation and the
four-run ranges overlap (1.51–1.98 s before, 1.75–1.92 s after). Warm
uninterrupted execution changes by −4.6% at 60 days and −1.1% at 4,160 days.
Preparation increases by 0.39 and 0.48 ms respectively. The observed runtime
differences vary across trials. All measured trials report zero compilation.
The phase medians come from separate runs and can differ from their sum.

Raw measurements for [60 days](writer-validation-60.json) and
[4,160 days](writer-validation-4160.json) include every sample and source hashes.

## Native validation

The same source builds with JuliaC 0.3.12, safe trimming and generic CPU.
The native executable matches ordinary PSE at both durations, including
topology, canonical field values and coverage, retained samples, and both RNG
probes. Floating-point values use the existing `1e-12` relative and absolute
comparison tolerance. The two cases cover 246 and 1,190 objects respectively,
with 122,554 retained samples in the 60-day case. The [native receipt](writer-validation-native.json)
records build and parity counts. The focused prepared-runtime suite passes 192
assertions and the ordinary PSE writer and distributed-output suites pass 99.

## Reproduce

Export the frozen baseline without changing the candidate checkout:

```sh
baseline=$(mktemp -d)
git archive 171e59fae | tar -x -C "$baseline"
printf '%s\n' "$baseline/benchmark/juliac_program"
```

Run the driver from a Kaimon session at the candidate `benchmark/juliac_program/app`
project. Pass the path printed above and a fresh output directory.

```julia
include("../full_program_writer_performance.jl")
destination = mktempdir()
FullProgramWriterPerformance.compare_writers(baseline, destination; days=60)
FullProgramWriterPerformance.compare_writers(baseline, destination; days=4160)
```
