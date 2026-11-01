# Bounded graph and typed preparation: downstream scaling and first use

The warm candidate remains **bounded graph + typed output-status preparation**.
It reduces the 128-day accelerated XPalm trajectory's execution/complete cost by
about 17% versus ordinary A and 14% versus ordinary B. PlantBiophysics benefits
from preparation: at 128 objects its complete cost falls about 26%, while its
small scientific execution phase is slightly slower. All candidates remain
opt-in, and ordinary execution/reference storage remains the default.

This round changes measurement fixtures and tooling. Production `src/`, bounded
preparation, graph projection and typed output preparation are unchanged from
the [previous dispatch/refresh experiment](xp_dispatch_refresh.md). Its generic
feature gates therefore apply to the same implementation bytes; this round adds
fresh preservation evidence at larger downstream sizes. No new leaf-, species-
or package-specific optimization is introduced.

## Gradual, independent workloads

Each XP sample is one original live palm in one growing scene, not a batch of
small replicas. The accelerated diagnostic changes only the two phyllochron
speeds to 0.2 phytomer/degree-day. The separate package-default profile changes
no scientific parameter. Both explicitly use initiation age zero and disable
architecture. These settings do not qualify mature palms or architectural
simulation workloads. The original phyllochron kernel can emit at most one
phytomer per day; actual realized organ counts, rather than a proposed rate,
define the tested size.

| XP trajectory | Initial objects | Final objects | Added objects | Final leaves |
| --- | ---: | ---: | ---: | ---: |
| Accelerated, 12 days | 8 | 44 | 36 | 13 |
| Accelerated, 32 days | 8 | 104 | 96 | 33 |
| Accelerated, 64 days | 8 | 200 | 192 | 65 |
| Accelerated, 128 days | 8 | 392 | 384 | 129 |
| Package defaults, 64 days | 8 | 26 | 18 | 7 |

The number of applications stays at 61. This increases real organ count and
duration, not compiled model width; hundreds of distinct models and millions
of organs remain future qualification axes. PB uses original Monteith, Fvcb
and Medlyn models over 16/32/128 gas-exchange objects and 4/8/8 timesteps, with
original forcing construction, reference statuses and parent-controlled calls.
No typed numerical driver, native columns, binding instructions, trusted index
or future-layout precompilation is enabled in these cases.

Each stage follows smaller successful preservation gates and measured costs.
Two-day XP, 2/4-object PB, 12-day XP, 16-object PB, 32-day XP, 32-object PB,
64-day XP and 128-object PB all pass before their corresponding screens.
Full per-step retained-history checks cover both XP profiles through 64 days.
The final 128-day gate compares every step using the measured `outputs=:none`
policy, including its required dependency streams, to keep the check bounded.
Canonical Status/Ref types, replacement transitions, cross-instance reference
ownership, live input carriers, state, RNG and actual work match ordinary
execution. Six million assertions in the final gate mostly repeat binding and
identity invariants; they do not represent six million distinct PSE features.
Package-default two-day XP has no newborns and receives no newborn-path credit.

## Warm fresh-scenario results

All eight screens compare identical ordinary A/A labels, bounded graph alone,
and bounded graph + typed preparation. Numerical execution and scientific
kernels remain ordinary. Every sample constructs a new independent model;
complete cost includes construction, enablement, normal PSE preparation,
backend lowering (empty here) and execution. XP weather is read at registration
outside warm timing and copied within each measured construction. Science,
retained streams, RNG, work, actual pathway counters and source provenance are
checked after execution; the stronger per-step history/identity gates are
separate from timing. One scene, not each organ, is the statistical unit.

The first seven cases have four balanced forward/reverse cycles; XP128 has six.
Ratios below are medians of paired per-cycle ratios to ordinary A. Lower is
better; these are not ratios of independent median times.

| Case | Preparation | Execution | Complete | Ordinary B complete |
| --- | ---: | ---: | ---: | ---: |
| PB, 16 objects × 4 steps | 0.797 | 1.092 | 0.818 | 0.983 |
| PB, 32 objects × 8 steps | 0.772 | 1.092 | 0.816 | 1.007 |
| PB, 128 objects × 8 steps | 0.703 | 1.032 | 0.744 | 0.990 |
| XP, 12 accelerated days | 0.707 | 0.832 | 0.819 | 0.981 |
| XP, 32 accelerated days | 0.696 | 0.865 | 0.848 | 0.946 |
| XP, 64 accelerated days | 0.683 | 0.892 | 0.878 | 1.005 |
| XP, 128 accelerated days | 0.713 | 0.829 | 0.827 | 0.960 |
| XP, 64 days, package-default parameters | 0.715 | 0.931 | 0.844 | 1.014 |

Combined preparation and complete cost beat ordinary A in every cycle of every
screen. The PB saving comes from typed preparation; graph alone is essentially
neutral for its small three-application graph. At 128 PB objects median complete
cost is 13.69 ms ordinary A versus 10.18 ms combined. Scientific execution is
about 1.00 versus 1.03 ms, so this is not a PB numerical-throughput improvement;
longer runs that amortize preparation need separate qualification.

For XP128, ordinary A/B median execution is 605.92/581.81 ms versus 489.38 ms
combined; median complete cost is 627.89/602.56 ms versus 505.98 ms. Against
ordinary B the combined paired execution/complete ratios are 0.859/0.857.
Against graph alone the additional typed-boundary ratios are 0.926/0.928,
winning five of six pairs. At 32 and 64 days the combined execution also beats
graph alone in all four pairs. The package-default 64-day case gives smaller
execution savings: about 21.88 ms ordinary A versus 20.68 ms combined, with
complete cost 43.42 versus 37.08 ms.

Allocation savings now coincide with measurable GC in the larger controls.
XP128 complete allocated bytes are about 516.8 MB ordinary, 297.5 MB graph and
289.3 MB combined. Ordinary A/B execution GC totals across six samples are
150.5/116.9 ms; graph and combined report none. This is real measured cost,
not a peak-RSS or retained-memory result, and does not isolate a causal share
for GC versus dispatch/refresh changes. The earlier short runs without GC could
not receive such a benefit merely from allocating less.

Recorded variation remains visible: XP128 A/A execution ratios span
0.811–1.119, with median 0.960; small differences are not isolated timer-noise
estimates. All timed execution phases report zero JIT/recompilation. Two ordinary
B preparation phases contain small JIT events (PB128 0.162 ms, XP32 0.112 ms).
Some larger ordinary XP samples have GC; those events are retained rather than
removed. Every timing artifact has an explicit hash-bound CPU/script/receipt
qualification. Monitoring concerns competing Julia CPU, not exclusive ownership
of the whole machine.

## Fresh-worker compilation pilots

Five pilot timings qualify: ordinary, graph and combined PB, and ordinary and
combined XP. Each uses a distinct newly started Julia worker, with all four
scientific packages absent from Main and loaded_modules before imports, no
previous scientific case or IR probe, identical source/forcing/configuration,
and strict healthy CPU monitoring. Original state/history/RNG/work and exact
Status/Ref types match across arms and with one freshly constructed warm
companion in each worker; the companion reuses no scientific state.

These are **one observation per arm**, not repeated cold medians. They measure
two-step, two-object PB and two-day accelerated XP with its original growing
scene, not compilation of the full 128-day future trajectory. Normal disk and
package caches remain intact. Kaimon startup/environment checks, a harmless
broker-only sleep used to prewarm job promotion, and quiet waits are outside
the model/import timer; repeated absence guards confirm they load no scientific
packages or drivers and execute no model kernels or compiler/IR probes.

| Qualified pilot | Model first-use, s | PSE preparation, s | Preparation reported JIT, s | Julia-entry inclusive, s |
| --- | ---: | ---: | ---: | ---: |
| PB ordinary | 13.478 | 10.921 | 10.906 | 20.962 |
| PB bounded graph | 12.627 | 10.017 | 10.004 | 20.408 |
| PB bounded graph + typed | 12.676 | 10.135 | 10.122 | 20.279 |
| XP ordinary | 130.016 | 104.024 | 103.797 | 139.135 |
| XP bounded graph + typed | **66.668** | **43.863** | **43.732** | **75.733** |

XP combined model first-use is about 49% lower, and the inclusive timer about
46% lower. The major observed change is preparation/JIT: 104.0 versus 43.9 s;
first scientific execution is 15.69 versus 12.67 s. PB's model-first-use saving
is only about 6%, with no additional cold gain demonstrated by typed preparation
over graph alone. Compiler counters are retained diagnostics, not an exclusive
additive decomposition of wall time; do not subtract their sum to infer pure
scientific computation time. These pilot differences need reversed-order
repeats before any robust cold-performance claim.

Model first-use sums construction, all normal PSE preparation, empty backend
lowering, first scientific step and remainder. The inclusive clock starts before
measurement-driver include and also charges bootstrap, common PSE/PB/XP/PlantGeom
imports, definition loading, registration (including XP weather/CSV setup),
helper compilation and unassigned overhead through first scientific completion.
Common union imports are explicitly included even for PB, because this exact
fixture loader depends on the same package union. The later diagnostics and
fresh warm companion are outside the first-use timer. Kaimon service and worker
startup remain separate controller wall-time records.

One optional graph-only XP cold observation completed its science/parity checks,
but fails the unchanged whole-RPC CPU gate: broker activity at 5.8% appears after
the result file was finalized. Its raw data and full CPU trace are retained as
excluded, with **no qualified timing or incremental XP cold claim**. The requested
ordinary-versus-combined cold comparisons are qualified; no additional expensive
rerun was added merely to fill that optional cell.

Other failed attempts are also explicit: a keyword-specialization annotation
was caught by load-only checking; a Julia1.13 too-new Main binding after imports
was fixed with latest-world helper boundaries; repeated second-worker Kaimon
environment stalls required separate owned services; broker startup, polling and
30-second job promotion caused strict CPU exclusions. Harmless broker promotion
prewarming and active-worker artifact waiting resolve those control-plane costs
before scientific timing. Every created worker and owned service is stopped;
server logs stay private and are not part of the evidence archive.

## Reproduction and limits

A Kaimon session for this branch loads the exact models and opt-in candidates:

```julia
include("benchmark/native_downstream/load_newborn_binding_experiment.jl")
for file in ("graph_row_projection.jl", "typed_output_preparation.jl",
             "execution_group_lookup.jl", "execution_group_epoch_lookup.jl",
             "trusted_execution_group_index.jl", "xp_prepared_batch_timing.jl",
             "xp_dispatch_refresh_measurements.jl", "pb_preparation_scaling.jl",
             "xp_preparation_scaling.jl", "growth_input_reuse_checks.jl",
             "xp_preparation_scaling_checks.jl")
    include(joinpath("benchmark/native_downstream", file))
end
XPPreparationScalingChecks.xp_preparation_scaling_checks(;days=32)
spec = XPPreparationScaling.register_xp_preparation_scaling_case!(
    :xp128;days=128,allow_large=true)
screen = XPPreparationScaling.screen_xp_preparation_scaling(spec;repetitions=6)
pb = PBPreparationScaling.register_pb_preparation_case!(
    :pb128;nobjects=128,steps=8)
```

Cold reproduction uses a distinct Kaimon worker per arm and the saved uninterrupted
entry scripts. Their expected source image, bootstrap clock, absence/freshness
attestations and setup/model phase accounting are explicit; loading a scientific
fixture or probing IR beforehand invalidates that experiment. Local Python
controllers use the task's existing MCP client adapter; all Julia work remains
Kaimon-controlled, and no standalone scientific Julia process is launched.

The [summary](evidence/preparation-scaling/summary.json),
[manifest](evidence/preparation-scaling/manifest.json) and
[source provenance](evidence/preparation-scaling/scientific-provenance.json) retain
lossless raw measurements, failed/excluded attempts, exact code/forcing bytes,
qualification bindings, source epochs and independent audits.
The frozen archive has 908 manifest records; every compressed and raw checksum
was independently verified. It distinguishes eight qualified warm screens, five
qualified cold pilots, six scientifically completed cold cells and the one
optional unqualified timing cell. No excluded attempt is promoted.
A [supplementary independent cold audit](preparation_scaling_audit.md) verifies
the final five-qualified/six-scientific split and per-worker receipt chains
without changing the immutable archive.
`summarize_preparation_scaling.py --check-only` validates without Julia;
`--archive-frozen` creates a new immutable archive and refuses replacement.

Full package regression, multithread throughput, cold model-width scaling,
architectural/mature long-horizon XP, million-organ behavior and peak RSS remain
unqualified. Full history is checked through 64 days; 128 uses measured retention.
Allocated-byte savings are not a live-memory or process-peak measurement.
The ordinary executor remains the default until application-level qualification
and implementation cleanup justify changing it.
