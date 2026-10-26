# Reusing transient hard-call contexts

Iterative models repeatedly call the same leaf or organ under a trial
environment. This change reuses the execution context, not a sampled weather
value or a scientific result. Models keep using the public `run_call!` APIs.

## What is cached

Each compiled target keeps its normal typed context and one last transient
specialization. Materialized `CallTarget` views share that cache with bulk
execution. Transient hits check the environment type and runtime metadata;
normal bulk calls keep their compiler-owned preparation path. Every invocation
refreshes time, publication permission and the trial state.

The cache is bounded to one alternate context. Changing the transient type
replaces that entry. Structural target reconstruction replaces the cache;
in-place call-membership extensions explicitly invalidate the transient entry.
Sampling still runs through each target's current environment handle. No
sampled environment or model output is cached here.

A lease protects an active context. A reentrant invocation gets fresh child
call collections as well as a fresh context, and `finally` releases its own
lease after normal execution or an exception. This does not add concurrent
execution support for one mutable model/status.

`publish=false` still mutates `Status`; it is not rollback. Accepted output
publication and environment commits remain gated by every ancestor's
permission. `sampled_environment` still applies only to the selected target,
whereas `environment` is inherited as provider-aware trial state.

## Local downstream measurement

The final measurement compares engine base `aa93452a` with code `622ef11e`
on the same synthetic MAESPA eight-tree scene: four canopy layers, twelve
points per layer and tree, eight processes / 43 applications, two days.
MAESPA equations, models, inputs and output selection are unchanged.

Julia 1.13.1, two compute threads / one GC thread,
`--startup-file=no --compile=yes -O1 --compiled-modules=existing`, Float64,
`outputs=:none`. Each process first warms a complete 96-step simulation, then
serializes a separate accepted step-16 simulation. Three distinct restored
clones advance through steps 17–24. Restoration, full GC and state comparisons
are outside each timed interval. Source and input hashes are checked again
before recording a completed result.

| Engine | Median initialized eight-step interval | Allocated bytes |
| --- | ---: | ---: |
| Base `aa93452a` | 1.086886 s | 2,077,725,056 |
| Final cache + default fast path | 0.790104 s | 1,555,931,008 |

All repeated step-24 states are exactly equal. The complete public step-24 and
step-96 states also match the base, including every selected object, not just
scene totals. That is 27.31% less elapsed time and 25.11% fewer allocated bytes
on this initialized interval, not a whole-run or universal speedup.

These are sequential ordinary-desktop measurements, not randomized isolated
trials. An external Julia workload was active when the final process started
and was left untouched. The earlier cache candidate measured 0.801869 s with
the same allocation count; this is useful context, not evidence that concurrent
activity cannot affect timings. No CPU affinity or dedicated-machine control
is claimed.

The first complete 96-step call, including model construction, takes
70.795217 s at base and 67.697865 s for the final code. Julia attributes
61.931809 / 61.515710 s respectively to compilation. These are single-process
first-call observations, not pure compilation benchmarks or evidence of a
reliable compilation improvement. Sampled process peaks are 2,890.64 MiB at
base, 2,970.63 for the earlier candidate and 2,639.88 for the final code. They
include construction, warm-up, compilation and checks; no controlled peak-RAM
reduction is established.

## Qualification status

The final source passes 2,098 assertions across thirteen complete engine test
files, 82 benchmark/API/assembly checks, and 21,762 assertions across five
MAESPA integration files: 23,942 targeted assertions, not the whole package
suite. The MAESPA checks include two-tree frozen Fortran trajectories, eight-tree
two-day water/energy accounting, actual per-species model substitution, and
exact serialized continuation at 48 + 48 steps. Frozen references, tolerances
and MAESPA dependencies remain unchanged; Fortran is not rerun.

Maximum water residuals are `3.3725626458203095e-14 mm` (eight trees) and
`3.442298529554577e-14 mm` (two trees). Soil/component energy accounting
residuals are `0.0041312152049357564` / `0.004288579248921565 W/m²`. Leaf sensible
heat is defined by `Rn − λE`, so that part is not independent physical closure.

The new behavioral regression file covers Float32/64 storage, nested bulk and
individual calls, changing trial values/types/time, a return to committed
sampling, ancestor publication suppression, exception recovery, changed Many
membership/spatial handles, an active default-context lease and a cache with
no initial context. Existing allocation gates also cover ordinary hard calls;
new warmed simple and nested transient calls must allocate zero bytes.

## Small-call trade-off

The same current benchmark setups execute at base `aa93452a` and at the final
source, including both new transient cases. For each case, warm the public call
route, then measure three repetitions of 10,000 invocations. Each process is
separate; source hashes and selected output values are checked. Timings are
desktop microbenchmarks, not cross-platform guarantees.

| Public bulk path | Base ns/invocation | Final ns/invocation | Base → final bytes/invocation |
| --- | ---: | ---: | ---: |
| Singular | 20.6 | 29.2 | 0 → 0 |
| Repeated, eight calls | 169.0 | 235.6 | 0 → 0 |
| Nested | 84.2 | 73.0 | 0 → 0 |
| Many, eight targets | 144.7 | 199.7 | 0 → 0 |
| Heterogeneous, two targets | 65.7 | 75.5 | 0 → 0 |
| Explicit sampled value | 8.7 | 17.4 | 0 → 0 |
| Transient backend state | 2,479.1 | 29.2 | 1,232 → 0 |
| Nested transient state | 8,596.7 | 57.5 | 6,528 → 0 |
| Published | 20.6 | 29.5 | 0 → 0 |

These invocations reuse a fixed current timestep. The published case uses
`outputs=:none`; it does not measure retained-history publication or collection.

This is not a universal speedup. Protecting a borrowed context adds about
8–9 ns to the trivial singular path, while avoiding repeated transient
construction removes much larger work. An earlier candidate doubled the
trivial path's cost; restoring the compiler-owned default preparation path
reduced that regression. Passing publication permission as an extra kernel
argument did not improve that result and is not retained. Compilation and
process-RAM gains are not established.

The ordinary PR workflows provide the cross-platform package tests,
PlantBiophysics/XPalm/PlantGeom integrations and AirspeedVelocity comparison.
Their outcome must be checked separately from local results. No dependency
version, model equation or scientific acceptance tolerance changes.

## Evidence receipt

Final Kaimon-controlled children/helpers exited 0/signal 0; source/input checks
passed, all four final logs per job were read, and no resource monitor failed,
sent TERM or sent KILL. Limits: 30 min, sampled 8 GiB RSS, 2 s polling / 5 s
TERM grace. Fixed monitor durations / sampled peaks:

| Job | Duration | Peak MiB |
| --- | ---: | ---: |
| Base eight-tree measurement | 106.287559 s | 2,890.64 |
| Final eight-tree measurement | 104.428419 s | 2,639.88 |
| Final thirteen-file engine qualification | 375.158740 s | 2,126.52 |
| Final benchmark gates and assembly | 36.107557 s | 1,231.30 |
| Final five-file MAESPA qualification | 243.004078 s | 2,652.23 |

Raw data stay in the local downstream validation workspace, not a package
dependency. SHA256 receipts:

- Base eight-tree result: `5196fb86c71ce58d4b5910307509be5a1ab1e03a89fa00a532bf26c5ba174f80`.
- Final eight-tree result: `9f577ac3df8d531411d198b4609b51f9fb2ead2a719fb54cfb09fb1f63ef348e`.
- Base nine-path result: `525d83fa2de56a513fa95dba49043e5c803e4c1c0a3d08f485276dad9aa6aa75`.
- Final nine-path result: `f18c12961fb8c548aa5e635da376a5464d782a10a73f200d19195809aa186cce`.
- Shared complete-state reference: `1c3200474ca4b55d73d20859497d8863591c0a248b589a1c85b9f4fe23fe9be6`.
