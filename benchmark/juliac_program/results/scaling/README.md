# Larger XPalm and downstream compiled scenarios

This directory extends the [binding-reuse qualification](../reuse/README.md).
Results are admitted only after comparison with ordinary PlantSimEngine using
the same scientific sources, inputs and output-retention policy.

## XPalm comparison

`../../xpalm_scaling.jl` compares ordinary PSE, the previous prepared runtime
at `bf4c3ab7024f748df68d06a6596b8b33acffa9d9`, the current prepared runtime,
and an explicitly identified JuliaC safe executable. The previous and current
prepared runtimes are loaded in separate namespaces in one Kaimon session.

Two profiles separate growth stress from package parameters:

- `:accelerated` preserves the earlier stress case: both phyllochron endpoints
  are `0.3`, with flowering/abortion/sex thresholds shortened to exercise
  reproductive organs.
- `:package_defaults` passes `XPalm.default_parameters()` unchanged, including
  unequal initial/mature phyllochron endpoints. The constructor still explicitly
  selects `architecture=false` and `initiation_age=0`; weather is the shared
  synthetic daily forcing. This is a computational qualification trajectory.

The fresh-simulation timer includes forcing and constants construction,
runtime instantiation and all timesteps. Scientific Palm/spec construction,
reusable program preparation, explicit pre-trial GC, validation, executable
startup and printing are excluded. GC during execution remains included.
This boundary includes slightly more setup than the earlier reuse tables.
JIT arms rotate order after a warmup; native launches discard their `P0`
warmup. Every measured result passes the same complete final-state, topology,
RNG and requested-output parity gate. Native allocation bytes are not inferred
from JIT allocation measurements. Reachable state size is not peak RSS.

Measured on 2 November 2026 on this Apple M3 host, Julia 1.13.1 / JuliaC
0.3.12. Each JIT median uses three trials; each safe/generic native median
uses nine trials across three launches. Numerical validation is outside the
timers. These are single-host observations without CPU pinning or confidence
intervals.

| Profile / days / outputs | Final objects | Ordinary PSE | Previous prepared | Current prepared | JuliaC safe | Ordinary / native |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Accelerated / 256 / none | 1,030 | 2,382.43 ms | 8,256.66 ms | 559.76 ms | 514.62 ms | 4.63× |
| Package parameters / 256 / none | 86 | 107.20 ms | 37.40 ms | 12.99 ms | 10.51 ms | 10.20× |
| Package parameters / 256 / all | 86 | 139.79 ms | 51.61 ms | 22.02 ms | 18.64 ms | 7.50× |
| Package parameters / 1,024 / none | 311 | 553.00 ms | 1,824.22 ms | 185.68 ms | 161.41 ms | 3.43× |

All rows pass full final canonical-state, ordered-topology and owned-RNG
checks. The retained case additionally matches every one of its 202,846
samples. JSON files contain individual trials, warmups, source hashes,
allocation/GC measurements, native binary identity and parity counts.

The previous prepared executor is slower than ordinary PSE in both larger
rows. Current reuse repairs that regression, but the native speedup over
ordinary PSE decreases substantially with workload size. The earlier short
trajectory speedups do not extrapolate to longer simulations.

An untimed 4,160-day package-parameter preflight also passes full Julia/PSE
state, topology and RNG parity, reaching 1,190 objects including 140 female
and 19 male organs. Its timing and native gate are separate pending work;
`defaults-4160-preflight.json` contains no performance claim.

`../../xpalm_scaling_native_defaults.jl` builds a separate safe/generic copied
app for unchanged package parameters. The established single-rate `perffull`
entry cannot represent unequal phyllochron endpoints. The standard app and
bundle are not modified by this instrumentation.

## Downstream admission

AMAPSim uses its original native architecture/geometry benchmark with dynamic
internode projection, the original length consumer, and the same qualification
counter in every arm. The selected scenario is uncoupled architecture and
geometry; it does not include AMAPSim carbon or physiological extensions.
Adapter typing changes are archived separately and require an additional
ordinary-PSE control with that same adapter.

MAESPA uses its complete public native two-species canopy/soil example, including
the original non-Tuzet leaf-exchange calls, canopy environment and structural
cadences. Population scaling explicitly tiles that example. This is not a
Julia/Fortran parity claim or a scientific validation of the artificial inputs.

The new registry runtimes must run original kernels without ordinary-runtime
fallback. Host-side authoring/lowering cost is reported separately where used.
Compilation support, numerical parity and measured speed are separate gates;
an unqualified downstream case has no reported native speedup.
