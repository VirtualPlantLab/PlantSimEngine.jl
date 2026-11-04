# XPalm reference invalidation and temporal history

The output cache introduced in `bafd33e06` invalidated every cached reference
in a cohort whenever any one status field acquired a different reference.
In the long XPalm case, the `Male` cohort was the only one whose reference epoch
advanced on days without a new organ. The port-level trace counted 32,796
changes to `Male.TEff` across 1,670 of those 3,675 days. Two male applications
bind that field to the Plant and Scene thermal-time producers respectively.
The cohort-wide epoch also invalidated references for ports such as
`carbon_demand`, `carbon_allocation` and `Rm`.

A 10-second OS sample of the previous safe executable found input refresh
on 3,108 of 7,912 main-thread stacks. It also found the output-column builder
on 866 stacks and the producer's unused initial-history lookup on 167 stacks.
These inclusive counts cover the whole workload. The timed comparisons below
run independently of the profiler.

Commit `7c64a3a37` stamps each binding and output column with its source or
destination port's reference epoch. It retains the cohort population check for
births. It also removes an unused producer-side initial-history table. A
previous-step read looks up the consumer's original fallback only if the
producer has no preceding sample. The focused cases exercise both actual and
unrelated reference replacements and check independent mutable fallback values.

## Candidate selection

The four-trial screen measured each change separately. Port-specific epochs
had the best median of the individual variants on days without growth
(1.882 s versus 2.227 s) and the lowest execution allocations. Prebound
history cells increased allocations from 4.525 to 4.758 GB, and adding them
to port-specific epochs did not improve the median. The three-trial shortlist
confirmed that simplifying history lookup alongside port-specific epochs
further reduced the median for days without growth from 1.885 to 1.792 s.
The [screen receipt](steady-binding-screen.json) records all accepted trials,
the profile counts and the reference epoch trace.

## Matched 4,160-day comparison

Julia 1.13.1 on the same Mac on AC power, using the original XPalm parameters
and no requested output retention. The three runs match ordinary PSE and
reproduce the object count on each of the 4,160 days. All measured trials
report zero Julia compilation.

| Runtime | Preparation | 485 growth days | 3,675 other days | Uninterrupted execution | Execution allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary PSE | 26.35 ms | 3.642 s | 1.070 s | 5.070 s | 5.736 GB |
| Frozen prototype `c481461a8` | 30.11 ms | 1.342 s | 2.255 s | 3.717 s | 4.525 GB |
| Port epochs and temporal lookup | 21.72 ms | 1.297 s | 1.700 s | 2.967 s | 4.434 GB |

Preparation is the median of the per-trial sum of plan construction and state
instantiation. Six balanced trials measure uninterrupted execution. Four
additional paired trials per runtime use the same step loop with and without
a daily clock. The day columns are medians from the clocked runs, so their
independent medians can differ from the uninterrupted execution median. Median
clocked-minus-plain differences were -84, 15
and 11 ms across a complete run.

Relative to the frozen prototype, the optimized runtime spent
25% less time on days without a birth and
20% less on uninterrupted execution. The days
without births still took 1.59 times the ordinary PSE
time. The [raw comparison](steady-binding-4160.json) includes the daily trace,
all samples and exact source hashes.

## Correctness

All 216 focused assertions passed on `7c64a3a37`. A fresh Julia 1.13.1 and
JuliaC 0.3.12 build passed safe trimming with generic CPU. The executable
matched ordinary PSE on 60 days with retained outputs (246 objects and 122,554
samples) and 4,160 days with the original XPalm parameters (1,190 objects).
The checks cover topology, canonical state, retained output values and both
RNG probes. The [native receipt](steady-binding-native.json) records the
exact runtime source hashes and parity counts.

## Reproduce

Export the frozen cached prototype without switching the candidate checkout.

```sh
baseline=$(mktemp -d)
git archive c481461a8 | tar -x -C "$baseline"
printf '%s\n' "$baseline/benchmark/juliac_program"
```

In a Kaimon session at the candidate `benchmark/juliac_program/app` project,
pass the printed path as `baseline`.

```julia
include("../full_program_writer_performance.jl")
FullProgramWriterPerformance.compare_writers(baseline, mktempdir();
    days=4160, baseline_revision="c481461a8", paired_phases=true)
```
