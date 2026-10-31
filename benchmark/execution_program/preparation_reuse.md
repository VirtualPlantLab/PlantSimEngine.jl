# Bounded preparation and status-view recipe reuse

The useful result of this screen is lower first-use preparation cost for XPalm
with bounded scenario metadata. Reusing status-view recipes did not produce a
convincing speedup. Both remain opt-in experiments, independently selectable and
composable. Ordinary scientific kernels and reference-backed state are unchanged.

## Mechanisms

`BoundedPreparation` replaces scenario-wide Tuple/NamedTuple metadata with
fixed-type ordered vectors and symbol indexes, before constructing those wide
types. It bounds inference through the cold planner and compiled-scene shell.
Individual scientific models, statuses, carriers and homogeneous numerical
batches retain their concrete types. Application order and real, possibly
non-dense slots are preserved. This reduces specialization on the whole scenario
without erasing the types that numerical loops need.

`PlanViewReuse` caches symbolic binding-shape and Many-slot assembly recipes.
Actual canonical state, references, object IDs, bindings and environment samples
are obtained for each current object. Compatible plain preservation can reuse
reference tuples and BoundMany interfaces while creating the fresh local Status
identity required by ordinary behavior. Temporal/private views use the ordinary
compiler/preservation path. Already-unaffected views are reused by the original
engine and are not credited as a new optimization.

Actual XPalm recipe work is 37 recipe builds, 96 hits and 133 plain assemblies,
with 45 ordinary temporal fallbacks. Both real PB and XPalm workloads record zero
plain-preservation/interface-reuse hits: that path is covered by focused fixtures,
but supplies no demonstrated benefit in these downstream runs.

The core changes are internal metadata factories and two status-view hooks;
the default factories retain the ordinary representation. Loading experimental
modules installs opt-in policies. No leaf, species, scale, or downstream-package
name is used to select these optimizations.

## Fresh-process screen

Each cell is one distinct Kaimon-controlled Julia process, with the same source
and experimental modules loaded, no prior scientific execution or IR probes.
Disk precompile caches remain available. Seconds below exclude the separately
recorded experimental loader and Kaimon/project startup. Complete cost includes
construction, preparation, lowering and execution. Cold execution includes JIT;
it is not a steady-state runtime measurement.

| Package / arm | Preparation (s) | First execution (s) | Complete (s) |
| --- | ---: | ---: | ---: |
| PB ordinary | 10.557 | 0.583 | 12.967 |
| PB view recipes | 10.759 | 0.627 | 13.339 |
| PB bounded | 9.918 | 0.618 | 12.531 |
| PB combined | 9.961 | 0.582 | 12.533 |
| XPalm ordinary | 105.900 | 15.965 | 132.676 |
| XPalm view recipes | 108.043 | 16.283 | 134.574 |
| XPalm bounded | 73.327 | 12.986 | 96.442 |
| XPalm combined | 74.118 | 12.556 | 97.022 |

PB uses two objects and two steps. XPalm executes the first day and first growth
event (three added organs),
using the same four-row forcing backend as the warm fixture. Growth is deliberately
accelerated for this diagnostic; it is not a calibrated production forecast.
All four arms have the same complete state/history digest within each package.

Bounded XPalm preparation is 30.8% lower and complete first-use cost 27.3% lower
than the same-source ordinary control. Combining view reuse gives 30.0% lower
preparation and 26.9% lower complete cost, with no additional gain over bounded
alone. XPalm preparation's compilation counter is 105.656 s ordinary versus
73.088 s bounded. The reduction tracks reported compiler work in a
compiler-dominated first preparation; it does not isolate inference. Julia's
compilation/recompilation counters are retained separately and should not be
summed as disjoint wall-clock components.

These are single observations, not confidence intervals or a cold-start speedup
guarantee. PB's roughly 3% complete difference is too small to promote from this
screen alone. No larger or repeated cold run was attempted.

## Warm screens

Fresh scenarios are constructed for each sample, with alternating arm order.
Entries are the median of candidate/control ratios paired within each cycle;
1.00 means unchanged. Complete includes construction and preparation.

| Case | View recipes execution / complete | Bounded execution / complete | Combined execution / complete |
| --- | ---: | ---: | ---: |
| PB 32 objects × 128 steps, four cycles | 1.020 / 1.039 | 1.006 / 1.006 | 1.025 / 1.033 |
| XPalm four growth days, three cycles | 0.991 / 0.985 | 0.950 / 1.016 | 0.994 / 1.016 |

PB ordinary median warm execution is 3.945 ms; XPalm's is 14.191 ms.
The warm screens show no consistent complete-time improvement. Bounded XPalm
reduces allocation volume substantially, but that is not evidence of lower peak
RSS or a sustained runtime speedup. Complete warm allocation falls from 24.185 MB
to 13.568 MB (43.9%) for bounded XPalm. Conversely, reachable Simulation size
increases from 825,785 to 868,521 bytes (5.2%); global recipe/policy caches are
outside that size measurement. The two-object PB screen is also archived;
its tiny timings are not used to choose a candidate. One 79-microsecond JIT event
occurred in XPalm ordinary preparation; other timed phases in these three screens
have zero compilation/recompilation counters.

## Correctness and observable behavior

Candidates use independently constructed state and the ordinary executor as the
oracle. Checks compare full scientific values/types, retained histories, topology,
actual work, and reference-identity transitions rather than only final totals.

- Real PB: 121 assertions for view reuse and 242 for bounded/combined, two objects
  and two steps with retained outputs.
- Real XPalm: 3,399 assertions across all three candidates, four growth days with
  retained outputs, topology and canonical Ref transitions checked after each step.
- Width/layout fixture: 188 assertions for two/four models and outputs none/all.
  With Float32 scientific state, bounded scenario and compiled types are identical
  across widths; ordinary compiled-type text grows from 7,591 to 8,354 bytes.
  This is structural evidence, not a hundred-model scaling benchmark.
- Lifecycle and schema gates exercise growth, removal, reparenting, movement,
  private histories, parameter-dependent ports of the same model type and fresh
  mutable defaults. Dedicated identity checks pass 113 assertions, including
  escaped views and saved hard-call collections compared with ordinary epochs.
- Focused bounded/combined gates pass 259 assertions for targeted newborn
  initialization, mutable environment sampling, live Many carriers, mixed cadences,
  PreviousTimeStep and late distributed writers; spatial sampling/movement adds
  35 assertions. The old newborn-promotion experiment is disabled here.
- Composition with the existing reference-backed Tight numerical driver passes
  74 assertions across four independent arms and outputs none/all. Each typed
  arm executes four original PB roots, 24 child calls and 12 model lookups, with
  zero fallback batches; scientific snapshots and escaped scalar references match.

The first optional composition harness exceeded an eight-minute budget and was
excluded. Its dictionary generator exposed four large Simulation families to
inference together. A bounded diagnostic harness using explicit Any containers
and dynamic operation barriers completed the same tiny four-arm/output matrix
in 24.2 s (36.1 s including module loading). Scientific compilation settings and
backends were unchanged. This is correctness-orchestration evidence, not an
additional numerical timing or a controlled attribution of the earlier delay.

The tests preserve ordinary fallback behavior rather than removing features to
fit a fast path. This is targeted prototype coverage, not a completed full PSE
suite, exhaustive scientific validation, or proof for every user-defined kernel.

## Known structure before simulation

Your fixed model graph is useful: compile declarations, cadence structure and
kernel/layout methods once, then grow runtime rows and live binding membership.
The engine already shares immutable authored application plans during ordinary
growth. These prototypes reduce additional whole-scenario type exposure and
repeated view assembly; they do not precompile every future birth.

A next bounded experiment is a type-only preparation blueprint for explicitly
known future object layouts, including initially targetless applications and
empty/nonempty Many carrier variants. It could issue `Base.precompile` requests
for the finite model/status/context/handle signatures without executing scientific
kernels or consuming RNG. This moves compilation before the first birth; total
preparation plus simulation must still be measured. Undeclared status fields,
value types, overrides or environment contracts would rebuild only the affected
blueprint. See [the source-only design note](evidence/preparation-reuse/fixed-structure-opportunities.md).

## Reproduce and inspect

Use Kaimon with this checkout and the compatible local PB, XPalm, PlantGeom and
benchmark environments described in [the benchmark guide](../README.md). Optional
packages remain outside `benchmark/Project.toml`. In a fresh Julia image:

```julia
include("benchmark/native_downstream/load_preparation_experiment.jl")
PreparationReuseChecks.preparation_pb_checks()
PreparationReuseChecks.preparation_xp_checks()
PreparationReuseChecks.preparation_identity_checks()
spec = PreparationReuseMeasurements.register_preparation_pb_case!(
    :my_preparation_pb; nobjects=32, steps=128)
screen = M.screen_case(spec; repetitions=4)
```

For the optional typed composition check, load `lean_compiler.jl`,
`direct_calls.jl`, `shared_call_program.jl`, `tight_call_program.jl`, then
`preparation_typed_integration_checks.jl` from the same directory. Run
`PreparationTypedIntegrationChecks.preparation_typed_integration_checks()`;
`typed_boundary_arm_probe` provides one-arm persisted stage diagnostics.

For one cold arm, set `preparation_cold_arm`, `preparation_cold_package`, and the
required distinct-process `preparation_cold_freshness` attestation, then include
`preparation_reuse_cold_case.jl`. Start/shutdown a worker per arm through Kaimon;
do not run a correctness case, warmup, or IR probe in that worker first.

[Summary](evidence/preparation-reuse/summary.json) and
[manifest](evidence/preparation-reuse/manifest.json) accompany losslessly compressed
raw results, Kaimon receipts and qualified source snapshots. The original local
archives remain unchanged. PB cold runs used the archived PB helper snapshot;
the final helper only changes XPalm's forcing-row setup. Preliminary fixture
failures and the interrupted Kaimon evaluation remain in receipts and are not
credited as passes. The corrected fixture source and successful reruns are
separately archived. `python3 benchmark/execution_program/summarize_preparation.py`
rebuilds the evidence index without discarding original samples.
