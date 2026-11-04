# XPalm preparation timing follow-up

The previous 4,160-day comparison reported a rise from 20.78 to 30.26 ms in
median preparation. Planning rose from 19.70 to 28.80 ms. State instantiation
fell from 1.54 to 0.97 ms and allocated 488,000 bytes in every trial. Planning
allocated the same amounts with the same frequencies on both arms. The
previous median paired preparation difference was +4.59 ms and individual
pairs ranged from −3.82 to +12.71 ms. Planning times ranged from 17.10 to
33.93 ms for the prototype and from 18.49 to 35.19 ms for the candidate.
[Previous raw comparison](steady-environment-4160.json)

The only runtime source change between frozen prototype `5e0d10c11` and
candidate `32a3cb251` is in `full_program_runtime.jl`. The changed methods
validate environment values and build contexts when running kernels. The
preparation timers cover XPalm initial values, the shared scenario planner,
the typed plan projection and instantiation. The changed methods run after
both timers.

## Preparation in isolation

Both prepared runtimes rebuilt a fresh plan and a fresh zero-step state in
each of 36 rounds. Ordinary PSE prepared a fresh `CompositeModel` and
ran zero steps, with its usual environment setup. All arms used the same
4,160-day XPalm forcing and unchanged package parameters. Every ordering
of the three arms was used six times. Scientific source authoring and
garbage collection between trials were outside the timers. Julia 1.13.1
ran on the same Mac on AC power.

| Runtime | Plan construction | State instantiation | Total preparation | Process CPU for preparation |
| --- | ---: | ---: | ---: | ---: |
| Ordinary PSE | included | included | 23.70 ms | 23.71 ms |
| Frozen prototype `5e0d10c11` | 16.80 ms | 0.293 ms | 17.11 ms | 17.12 ms |
| Current runtime `42bbab173` | 17.02 ms | 0.292 ms | 17.31 ms | 17.41 ms |

Total preparation is the median of the per-trial sum. The median paired
difference was +0.30 ms wall time and +0.36 ms process CPU, with wall-time
pairs spanning −3.17 to +3.18 ms. The two prepared runtimes had the same
median allocations for plan construction (26,640,496 bytes) and exactly the
same allocations for instantiation (488,000 bytes in every trial). All timed
phases reported zero GC and zero compilation. Topology, canonical state and
RNG probes agreed for the two zero-step prepared states. All three arms
reproduced their own initial states on each trial.

This campaign did not reproduce the previous 9.48 ms gap. A difference on
the scale of the new paired median is possible.
[Preparation trials and source hashes](preparation-followup-isolated.json)

## Matched 4,160-day comparison

Six balanced uninterrupted runs per arm were followed by four clocked and
plain pairs per arm. The verified object-count trace classifies the same
485 days with births and 3,675 other days across all three runtimes. Each
measured run matched the fresh ordinary PSE oracle for final canonical
values, topology and RNGs.

| Runtime | Preparation | 485 growth days | 3,675 other days | Uninterrupted execution | Execution allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary PSE | 26.47 ms | 3.517 s | 1.132 s | 5.013 s | 5.736 GB |
| Frozen prototype `5e0d10c11` | 24.33 ms | 1.269 s | 1.723 s | 3.060 s | 4.434 GB |
| Current runtime `42bbab173` | 18.67 ms | 1.130 s | 1.207 s | 2.395 s | 3.491 GB |

The six preparation pairs had a median difference of −0.92 ms and ranged
from −14.34 to +19.17 ms. The day columns come from the clocked runs. On
days without births the current runtime spent 30% less time than the
frozen prototype. Its median was 7% above ordinary PSE, with overlapping trial
ranges (1.190–1.215 s and 0.941–1.301 s).
[Complete comparison and per-day timings](preparation-followup-4160.json)

## JuliaC safe parity

The Julia 1.13.1 / JuliaC 0.3.12 safe/generic binary from the previous
campaign was executed again after its binary hash and all runtime source
hashes were verified. The 4,160-day run matched the fresh ordinary PSE
oracle for topology, 27,828 canonical fields over 1,190 objects and both
RNG probes. The 60-day accelerated reproductive case also matched its
ordinary PSE oracle, including all 122,554 retained samples.
[Native replay receipt](preparation-followup-native.json)

## Reproduce

Use the [same comparison harness and archived baseline](steady-environment.md#reproduce)
as the previous comparison. The isolated measurements call the same
`_prepared_context`, `_typed_prepared` and `_regular_prepared` functions as
the full benchmark, after warmup, without running steps. Darwin's process CPU
clock includes all threads in the Julia process. Phase timers exclude
the post-measurement state checks.
