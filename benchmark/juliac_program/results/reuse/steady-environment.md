# XPalm environment validation on days without growth

The 4,160-day XPalm profile records which day each sampled stack belongs to.
In the frozen `5e0d10c11` prototype, 208 of 947 active stacks on days without
growth contain the per-invocation environment validator. It iterated over
declarations and performed property lookups using runtime symbols, even
though both the declarations and the forcing rows are `NamedTuple` values
with known fields. The profile also shows input refresh, where most samples
inside the refresh loop include the binding operations themselves. The
[scoped profile receipt](steady-environment-profile.json) records the
counts for the prepared and ordinary runtimes in both day categories.

The selected environment change checks the fields directly when both sides
are `NamedTuple` values. It still asks the model for its declarations on each
invocation. It checks for missing fields and incompatible types in the
original declaration order and preserves the generic validation path for
other inputs.

The scoped profile also finds 64 stacks at the scheduled-loop call site
that constructs a provisional context. Commit `42bbab173` passes the
application, state and row directly to the invocation. It builds one
context after refreshing the status view. Manual calls still use the
context entry and share the same invocation path.

## Candidate selection

The first four-trial screen isolates the environment change in `82c5b455d`.
It reduces the no-growth median from 1.776 to 1.586 s and execution
allocation volume from 4.434 to 3.491 GB. Direct input refresh independently
takes 1.866 s on the same group. Combining it with the environment change
gives 1.554 s, with overlapping timings and a small complete-run difference.

The three-trial shortlist compares the frozen prototype, the environment
change, and the environment change plus one context per scheduled call.
Their no-growth medians are 1.972, 1.711 and 1.406 s respectively.
The selected combination beats the environment-only runtime in every
paired no-growth trial. Both variants allocate about 3.491 GB per complete
simulation. The [screen receipt](steady-environment-screen.json) preserves
the accepted trials and hashes.

## Matched 4,160-day comparison

Julia 1.13.1 on the same Mac on AC power, using the original XPalm parameters
and no requested output retention. The three runs match ordinary PSE and
reproduce the object count on each of the 4,160 days. All measured trials
report zero Julia compilation.

| Runtime | Preparation | 485 growth days | 3,675 other days | Uninterrupted execution | Execution allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary PSE | 26.19 ms | 4.836 s | 1.503 s | 6.043 s | 5.736 GB |
| Frozen prototype `5e0d10c11` | 20.78 ms | 1.669 s | 2.049 s | 3.253 s | 4.434 GB |
| Direct environment checks and one context | 30.26 ms | 1.485 s | 1.443 s | 2.662 s | 3.491 GB |

Preparation is the median of the per-trial sum of plan construction and state
instantiation. Six balanced trials measure uninterrupted execution. Four
additional paired trials per runtime use the same step loop with and without
a daily clock. The day columns are medians from the clocked runs, so their
independent medians can differ from the uninterrupted execution median. Median
clocked-minus-plain differences were −142, +179 and −14 ms across a complete run.

Relative to the frozen prototype, the optimized runtime spent 30% less time
on days without a birth and 18% less on uninterrupted execution. On days
without births the optimized prototype and ordinary PSE have overlapping
ranges (1.33–1.63 s and 1.15–1.69 s respectively). Their median ratio is 0.96
in this campaign, compared with 1.36 for the frozen prototype. The earlier
1.59 figure came from a different measurement campaign. The
[raw comparison](steady-environment-4160.json) includes the daily trace,
all samples and exact source hashes.

## Correctness

All 222 focused assertions passed at `42bbab173`. The environment tests cover
missing and incompatible fields, order of failure, reordered forcing and
the generic declaration path. The existing lifecycle and manual-call tests
also run through the revised invocation.

A fresh Julia 1.13.1 / JuliaC 0.3.12 safe/generic build matched ordinary PSE
on 60 days with retained outputs (246 objects and 122,554 samples) and
4,160 days with the original XPalm parameters (1,190 objects).
The checks cover topology, canonical state, retained values and both RNG
probes. The [native receipt](steady-environment-native.json) records
the binary and runtime source hashes.

## Reproduce

Export the frozen prototype without switching the candidate checkout.

```sh
baseline=$(mktemp -d)
git archive 5e0d10c11 | tar -x -C "$baseline"
printf '%s\n' "$baseline/benchmark/juliac_program"
```

In a Kaimon session at the candidate `benchmark/juliac_program/app` project,
pass the printed path as `baseline`.

```julia
include("../full_program_writer_performance.jl")
FullProgramWriterPerformance.compare_writers(baseline, mktempdir();
    days=4160, baseline_revision="5e0d10c11", paired_phases=true)
```
