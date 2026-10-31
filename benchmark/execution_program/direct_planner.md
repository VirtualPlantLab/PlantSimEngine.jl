# Direct plan construction, planner boundaries and growth profiling

Direct construction reduces allocations and preserves the previous typed call
driver's larger PB runtime benefit. Its incremental timing difference is small,
and preparation still makes short
complete runs slower than ordinary execution. The three new planner boundaries
show no convincing additional benefit. Existing bounded metadata remains the
strongest first-use candidate for XPalm.

An additional generic admission bridge successfully executes four original XP
kernels through the typed path. Its conservative retirement at growth gives no
whole-run improvement. The growth profile identifies input-binding preparation
as the next concrete target.

## Independent mechanisms

`DirectPlanConstruction` chooses an audited private call protocol from validated
logical bindings, then constructs its instruction tree and Tight frames directly.
It avoids first constructing a full Shared execution plan and replacing batches.
Canonical scientific storage remains ordinary references in every comparison.
Original scientific kernels, model parameters, application order and sampling
remain unchanged. Selection depends on capabilities, concrete types, binding
shape and reference ownership; it has no organ-label or scale rule.

Full-protocol frames, leases, owners and real public target collections are
created on first inspection, protocol fallback or lifecycle retirement. A compact
epoch records the last completed time and the entered prefix of a failed batch.
Materialization seeds the original owner tree and permanently retires that batch
from private execution. Growth then uses the ordinary refresh path. This also
removes the previous typed driver's scan over every row lease on each fast batch
entry. An execution difference therefore includes that guarded control-work
change, as well as changed preparation.

`PlannerBoundaries` independently suppresses inference in three cold phases:
scene compilation, application assembly and scenario-plan assembly. A private
macro generates ordinary and bounded methods from one source body. All current
arms share three cold dynamic entry calls; only the enabled policy selects the
bounded body. Numerical model/status/carrier and homogeneous batch types remain
concrete. The flag is independent of the earlier `BoundedPreparation` container
policy, which replaces wide scenario metadata tuples with fixed-type indexes.

| Arm | Bounded metadata | New planner boundaries | Execution |
| --- | --- | --- | --- |
| reference executor | no | no | ordinary |
| bounded preparation | yes | no | ordinary |
| planner boundaries | no | yes | ordinary |
| selected driver | no | no | direct construction |
| combined | no | yes | direct construction |
| bounded selected | yes | no | direct construction |
| bounded combined | yes | yes | direct construction |
| prior typed | no | no | previous Tight construction |

## Correctness and feature retention

Small Kaimon-controlled checks pass before timing:

- Initial boundary smoke: four applications, two objects and two steps, with
  and without bounded containers, retaining all outputs.
- 247 planner assertions: distinct four/eight-model stacks, Float32 state,
  independent model RNGs, private and canonical state, histories, growth,
  concrete scientific types and canonical reference identity transitions.
- 44 PB factorial assertions and 40 XP factorial assertions: each main candidate
  and the bounded anchor match independent ordinary runs. XP executes two days,
  creates six organs, ends with 14 objects and retains 247 streams in this gate.
- 243 direct-construction assertions: original PB kernels, native/reference
  checks, escaped scalar references, caught and uncaught exceptions, partial-row
  epochs, public-call fallback, saved targets, retirement and mixed-cohort union
  rejection. Rejected later cohorts do not count discarded frames as prepared.
- 42 optional admission assertions: dispatch/capability rejection and exact
  two-day XP state, history, topology, RNG and reference parity for both direct
  and combined configurations.

Extra bounded-composition checks and generic growth observations also agree.
Unknown/full-protocol kernels use ordinary execution. The root scheduler,
temporal policies, value/writer validation, publication, environments and output
retention remain in the ordinary pipeline. These are targeted prototype gates;
the full PSE regression suite and broad scientific validation were not run.

## Qualified warm comparisons

Each sample constructs a fresh model. Four cycles alternate forward/reverse arm
order. Ratios are medians of within-cycle candidate/control ratios. Complete
cost includes construction, preparation and execution. Timed cases request
`outputs=:none`; full-history checks precede these cases. XP forcing is read at
warm registration and copied into each independent sample.

| Task / arm | Execution ratio | Complete ratio |
| --- | ---: | ---: |
| PB 32 objects × 128 steps / direct | 0.672 | 1.066 |
| PB 32 × 128 / combined | 0.683 | 1.089 |
| PB 32 × 128 / prior typed | 0.691 | 1.072 |
| PB 32 × 2,048 / direct | 0.699 | 0.756 |
| PB 32 × 2,048 / combined | 0.693 | 0.753 |
| PB 32 × 2,048 / prior typed | 0.716 | 0.772 |
| PB 32 × 2,048 / bounded selected | 0.706 | 0.763 |
| PB 32 × 2,048 / bounded combined | 0.703 | 0.758 |

The long direct arm wins all four ordinary-control pairs for execution and
complete cost: medians are 43.48/52.55 ms versus 62.10/69.41 ms. Its execution
allocations are 1.884 MB versus 23.839 MB. The short case allocates 0.115 MB
versus 1.487 MB, about 92% less. These are allocation-volume observations,
not retained-memory or peak-RSS claims.

Most of the timing gain over ordinary execution was already delivered by the
previous typed driver. Direct construction reduces long-case execution
allocations from 3.121 MB to 1.884 MB relative to that driver, about 40% less.
Direct construction versus prior typed has paired long-case
ratios **0.985 execution / 0.988 complete**, winning only two of four pairs each.
The small incremental timing signal does not establish a robust new speedup.
New planner boundaries add no consistent warm benefit.

The original four-day XP matrix executes **zero private batches**: 39 ordinary
batches are initially prepared. Its direct/combined execution ratios are
0.999/1.019 and complete ratios 0.996/1.008. That is coverage evidence for the
fallback, not acceleration of XP. The bounded-only anchor gives 0.921 execution
and 0.971 complete in this small screen; its modest runtime signal needs more
qualification. One 126.875 μs preparation JIT event occurs in the selected XP
arm; PB timed samples have zero compilation, recompilation and GC.

## First-use compilation and preparation

One distinct fresh Julia process per arm executes two steps, with two initial
PB objects or the small XP growth fixture. No prior case execution, warmup or IR
probe occurs in those processes. Imports/startup and the experimental loader
are separate. Forcing setup is charged inside cold construction. Package disk
caches remain available. All 11 qualified cold PIDs differ; package source
provenance and within-package complete scientific digests match.

Seconds, one qualified observation per cell:

| Arm | PB preparation | PB complete | XP preparation | XP complete |
| --- | ---: | ---: | ---: | ---: |
| reference executor | 10.173 | 12.689 | 103.431 | 130.410 |
| bounded preparation | 9.458 | 11.987 | 69.344 | 93.435 |
| planner boundaries | 10.331 | 12.977 | 101.757 | 128.741 |
| selected driver | 11.348 | 13.653 | 102.205 | 129.145 |
| combined | 11.413 | 13.732 | 102.079 | 128.979 |
| prior typed | 11.576 | 14.017 | — | — |

Direct construction slightly reduces the previous typed arm's first-use total,
but remains slower than ordinary for the short PB task. The new planner-boundary
differences are small. Existing bounded metadata reduces XP complete first-use
cost by **28.4%**, mainly preparation; the comparison reproduces its earlier
signal on this source. These single observations are screens, not confidence
intervals or guaranteed speedups.

The current ordinary control includes the shared cold dispatch hooks. A
byte-verified fd49eaf6 source export and a matching parent runner were prepared
to measure that unconditional hook effect. No qualified parent-source sample
was obtained: the first export omitted bundled examples, which was corrected,
and subsequent setup attempts stalled in Kaimon environment inspection. No
parent-source timing is reported. Consequently this round does not quantify
the default-hook change against the preceding revision.

## Optional XP local-port admission

`LocalPortsSelectedBridge` derives exact-type admission from the existing
`:local_ports` source contract. It additionally requires empty model
dependencies/environment commits/distributed outputs and an untyped context
signature. Explicit capability methods are preserved. Generic defaults and
scientific methods are not overwritten. Register uniformly before every arm of
a separate comparison cohort.

Four original scheduled types qualify: `DailyDegreeDays`,
`DailyDegreeDaysSinceInit`, `DailyPlantAgeModel` and `PhyllochronModel`. The
two-day companion observes seven private root executions and no child calls.
Eight prepared batches materialize fallback frames at growth, leaving zero
active private batches. Thus admission is real, but it does not survive the
conservative lifecycle retirement in this prototype.

Four-day paired execution/complete ratios in this changed-admission cohort:

| Arm | Execution ratio | Complete ratio |
| --- | ---: | ---: |
| direct | 1.042 | 1.040 |
| combined | 1.079 | 1.066 |
| bounded preparation | 0.964 | 0.968 |
| bounded selected | 0.971 | 0.991 |
| bounded combined | 1.009 | 1.036 |

Relative to bounded-only, adding direct construction gives 1.005 execution and
1.019 complete. This bridge is not a demonstrated runtime improvement. Its
useful outcome is exposing safe applicability and the cost of retirement.
One selected preparation sample has 122.5 μs JIT; other timed compilation,
recompilation and GC counters are zero.

## Growth overhead

The normal executor is sampled over ten independently prepared four-day XP
simulations after warmup. Framework counters/timers come from separate warmed
`performance=true` companions. Those companions explicitly use ordinary
execution when instrumentation disables the selected backend. All sampled
state, RNG and work fingerprints agree with their independent oracle.

Coarse inclusive CPU samples, which overlap and cannot be added:

| Region | Ordinary | Combined |
| --- | ---: | ---: |
| runtime refresh | 74.6% | 73.1% |
| logical extension | 54.8% | 50.5% |
| targeted newborn preparation | 19.2% | 20.9% |
| execution-group refresh | 15.8% | 16.5% |

There are 177/182 selected samples. The ordinary diagnostic includes 8.761 ms
JIT and both include profiler/GC overhead. Diagnostic elapsed times are not
ordinary-runtime measurements or candidate speed comparisons.

Input-binding refresh is the largest measured logical subphase, approximately
0.9–1.2 ms/day inside 1.6–2.1 ms binding refresh. Execution-plan refresh takes
approximately 0.49–0.88 ms/day. These instrumented timers are nested. A three-organ
XP birth replaces 24 input targets, constructs 26 status views/environment
bindings and 20 execution targets, while reusing 17 groups. These counts do not
establish that the affected work is unnecessary.

The generic fixed-addition check already refreshes only three new views and
targets at both 128 and 1,024 existing objects; two execution groups are reused
and Many membership extends directly. The generic timing intervals were not
independently qualified and supply no timing ratio. Visited execution targets
still increase from 133 to 1,029. This is not a million-object scaling result, but it
does not support assuming that this simple path rebuilds all metadata.

The next narrow experiment should split XP input-binding refresh into
selector/source resolution, carrier/wiring assembly and defaults/validation,
then remove the dominant repeated interpretation or allocation within its
actual fan-out. Repeating the earlier unsuccessful small binding cache without
that attribution is not justified by these results.

## Evidence qualification and limitations

Whole-RPC CPU monitoring conservatively rejects activity outside measured
regions too. The final bundle's only busy controller observation falls during
its 42-assertion XP correctness gate, between the PB and XP warm screens. Both
screens independently qualify using conservative wall-clock bounds and quiet
adjacent CPU observations. The PB upper bound subtracts only 137 seconds from
the later XP start, less than the intervening 138.1-second testset duration.
The unchanged result file's last-write time bounds the end of the XP screen.

The original global CPU flag remains false and the original artifact name is
unchanged. `qualification_adjudication.json` binds each qualified screen to raw,
CPU, script, receipt, configuration and sample-cohort hashes. A separate growth
adjudication binds the two explicitly staged quiet CPU-diagnostic intervals.
The older profile RPC's embedded warm timing screens remain excluded. Startup
inspection stalls, an initial parent-export import failure and a conservative
PB CPU exclusion are retained, without being counted as successful simulations
or pooled into timing results.

Cold controls are single observations. Warm screens use four paired cycles.
No large XP run, million-organ run, many-hundred-model compilation screen, full
regression suite, retained-memory study or production adoption is claimed.
Direct execution, bounded containers and bounded phase bodies remain opt-in.
The shared cold entry hooks are present in this experimental branch; this work
is a draft qualification.

## Reproduce

Use Kaimon with compatible local downstream checkouts from
[the benchmark setup guide](../README.md). Optional packages remain outside the
default benchmark project's dependencies.

```julia
include("benchmark/native_downstream/load_direct_planner_experiment.jl")
include("benchmark/native_downstream/direct_plan_checks.jl")
DirectPlanChecks.selected_plan_checks()
DirectPlannerMeasurements.direct_planner_checks(:pb; arm=:combined)
DirectPlannerMeasurements.direct_planner_checks(:xp; arm=:combined, steps=2)
```

For the separate admission cohort, load the bridge and register its audited
types before constructing any compared scenario:

```julia
include("benchmark/native_downstream/local_ports_selected_bridge.jl")
LocalPortsSelectedBridge.register_xpalm_local_ports!()
include("benchmark/native_downstream/local_ports_selected_bridge_checks.jl")
LocalPortsSelectedBridgeChecks.local_ports_xp_checks()
```

`direct_planner_cold_case.jl` runs one explicitly attested fresh-process arm.
Warm registrations and growth-profile entry points are defined in
`direct_planner_measurements.jl` and `direct_planner_growth_profile.jl`.
[Evidence](evidence/direct-planner/summary.json), its manifest, compressed raw
records, source snapshots, independent audits and reproduction drivers retain
the measured and excluded attempts. Run
`python3 benchmark/execution_program/summarize_direct_planner.py --archive-frozen`
only after freezing source and raw evidence; local originals are preserved.
