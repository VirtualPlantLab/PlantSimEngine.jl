# AMAPSim, MAESPA and coupled ecosystem qualification

This round qualifies the preparation-only candidate on three additional real
applications. Every arm retains the ordinary PSE numerical executor and canonical
reference storage. The separate JuliaC investigation is on
`codex/pse-juliac-program`, draft PR
[#245](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/245).
The execution-program investigation remains draft PR
[#244](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/244).
No default runtime or scientific model is replaced by this round.

## Comparison and scientific cohort

Four arms use fresh independent scenes and the same scientific code:

| Artifact arm | Preparation | Numerical execution |
|---|---|---|
| `ordinary_a` | Ordinary | Ordinary compiled batches |
| `ordinary_b` | Ordinary A/A repeat | Ordinary compiled batches |
| `graph_only` | Bounded preparation + graph-row projection | Ordinary compiled batches |
| `prep_candidate` | Bounded + graph-row + typed output/status preparation | Ordinary compiled batches |

`graph_only` is a bounded-graph control, not graph projection in isolation.
Candidate versus this control tests the additional typed preparation. Neither
arm is the persistent typed driver, native-column backend, cached-proof or
cold-owner prototype. Completed preparation counters are checked; they do not
stand in for numerical invocation counts.

AMAPSim, MAESPA, ArchimedLight, PlantBiophysics and PlantGeom source trees and
scientific inputs were copied to an independent frozen cohort before testing.
The original source hashes, origin commits and dirty-worktree digests are
recorded. Package path pins were relocated to those copies. Other chats can
continue editing their own checkouts; those live changes do not enter the tests.
Original unrelated dirty diffs are represented by hashes rather than republished
in the evidence archive. PSE production `src/` and `ext/` still match the exact
core baseline recorded in the derived summary.

The coupled ordinary gate found a real adapter-contract mismatch:
AMAPSim's `SurfaceFvcb` inherits PlantBiophysics' `Gₗw` contract but did not declare
that output. The frozen adapter now declares `Gₗw` and clears it along with the
other outputs for zero-area surfaces. Positive-area delegation and PB's Fvcb and
Medlyn source files are unchanged. The exact before/after source and two-line
patch are archived, with focused zero-area and original-PB parity checks.
**This compatibility repair applies equally to every ordinary and candidate
arm and receives no optimization credit.** Live AMAPSim/PB checkouts were not
modified.

## Preservation gates

Final logged test groups contain **15,082 passing assertions**: 14,747 AMAPSim/
MAESPA assertions and 335 coupled assertions. Focused SurfaceFvcb checks also
pass; the final numeric-snapshot gate adds 45 representation assertions. Preliminary failing gates are retained as diagnostics, not added to the
passing total.

- AMAPSim uses the original native architecture/geometry engine and PSE organ
  projection. Independent scenes compare complete native state, RNG/event
  queues, geometry, registry/status/history, live references, newborn execution
  and uninterrupted versus continued timelines, with `outputs=:none` and `:all`.
  The original LengthProbe plus an identical harness-only invocation counter
  verifies actual projected-organ execution. Native-only execution is solely a
  scientific-equivalence control, never a performance baseline.
- MAESPA uses the unchanged two-species parameters and public model builder,
  including native canopy/soil exchange. It mounts 100 applications on 27
  objects, with 16 allocated logical leaf slots. In the daylight gate, eight
  slots are active and accepted, with 24 trials in the final step. The separately instrumented
  one-step gate records 37 actual scheduler root-target entries; the application
  count is not an executed-kernel count. Understorey, Tuzet and the optional PB
  extension are outside this scenario's scope.
- The coupled case uses original AMAP growth, ArchimedLight radiation and PB
  photosynthesis/stomatal conductance. Its four-step positive-physics gate has
  207 native organ slots, 54 PSE leaf objects, 50 lit positive-area leaves and
  46 nonzero-assimilation rows. Full native scientific state, RNG/event queues,
  geometry, statuses and retained histories match. Continuation and deliberate
  physical-time/RNG/geometry/ownership perturbations are checked.

The coupled fingerprint normalizes process-specific plant-owner addresses to
logical identities while checking ownership. It excludes exactly the two
qualified geometry/light **wall-clock** outputs and their histories. Physical
time, duration and stream timestamps remain. Opaque ArchimedLight solver-cache
internals are unqualified; the opening physical scene and scientific results
are retained. For `outputs=:none`, dependency streams still needed by PSE are
compared; this option does not promise an empty internal history.


Untimed coupled snapshots encode primitive numeric arrays as their exact dense
column-major bytes, with original type, shape, byte order and alias labels. This
preserves RNG words, signed zeros and NaN payload bits while avoiding a large
per-number report. Nonprimitive numeric types retain the original value path.
The snapshot visitor suppresses specialization on the entire scientific graph;
a task-local dictionary reuses only immutable type/module-name text for one
complete invocation. Cached and earlier uncached coupled runs have exactly the
same full scientific digest. Every fresh scene still rebuilds its value graph;
this is diagnostic code, not a numerical optimization. Dense-array, view,
BitArray, empty, zero-dimensional and mutation/alias checks pass. Final screens
use ordinary minified JSON; exploratory string/reference-table exports remain
raw diagnostics with their passing/rejected transport checks. No model speedup
is credited to report formatting.

These bounded gates add downstream preservation evidence. They do not establish
a complete ecosystem feature matrix, calibrated science or million-organ
scalability.

## Warm measurements

The screens use Kaimon-managed Julia 1.13.1 workers with 14 available threads,
serial scenario execution, four untimed arm warmups and two balanced forward/
reverse cycles. Every measured sample constructs a fresh independent scene and
performs pre-sample GC. Source/forcing hashes are checked before and after each
screen. A healthy whole-RPC monitor excludes screens with another busy Julia
process; it is a local concurrency check, not an exclusive machine reservation.

Construction, zero-step PSE preparation, the no-op additional backend-lowering
callback and execution all contribute to complete cost. Fingerprints, work
reports, retained-size collection and definition loading are outside these phase
clocks. This is a small warm screen, with no new cold-compilation claim.

Medians in milliseconds. Each arm has two independent measured scenes; the
additional lowering callback is a charged no-op and rounds below this table.
Ratios use the median of cycle-paired complete costs, rather than adding phase
percentages. All final timed phases report zero JIT, recompilation and GC.


### AMAPSim, one plant × two steps

| Arm | Construction | Preparation | Execution | Complete | / ordinary A |
|---|---:|---:|---:|---:|---:|
| Ordinary A | 1.216 | 0.920 | 3.745 | 5.881 | 1.000 |
| Ordinary B | 1.294 | 0.980 | 3.759 | 6.033 | 1.027 |
| Bounded graph | 1.220 | 0.956 | 3.442 | 5.619 | 0.956 |
| Bounded graph + typed preparation | 1.243 | 0.999 | 3.495 | 5.737 | 0.976 |

### AMAPSim, four plants × two steps

| Arm | Construction | Preparation | Execution | Complete | / ordinary A |
|---|---:|---:|---:|---:|---:|
| Ordinary A | 1.925 | 1.322 | 14.392 | 17.640 | 1.000 |
| Ordinary B | 2.102 | 1.429 | 14.294 | 17.829 | 1.013 |
| Bounded graph | 2.049 | 1.468 | 13.329 | 16.850 | 0.956 |
| Bounded graph + typed preparation | 2.089 | 1.372 | 12.762 | 16.226 | 0.921 |

### MAESPA, 24 half-hour steps

| Arm | Construction | Preparation | Execution | Complete | / ordinary A |
|---|---:|---:|---:|---:|---:|
| Ordinary A | 5.669 | 56.646 | 79.801 | 142.117 | 1.000 |
| Ordinary B | 5.695 | 57.297 | 80.822 | 143.815 | 1.012 |
| Bounded graph | 5.742 | 47.798 | 80.100 | 133.642 | 0.940 |
| Bounded graph + typed preparation | 5.436 | 46.934 | 79.967 | 132.338 | 0.931 |

### Coupled AMAPSim–ArchimedLight–PB, four intervals

| Arm | Construction | Preparation | Execution | Complete | / ordinary A |
|---|---:|---:|---:|---:|---:|
| Ordinary A | 2.468 | 2.555 | 30.862 | 35.885 | 1.000 |
| Ordinary B | 2.535 | 2.524 | 31.367 | 36.426 | 1.015 |
| Bounded graph | 2.637 | 2.391 | 30.494 | 35.522 | 0.990 |
| Bounded graph + typed preparation | 2.534 | 2.366 | 28.821 | 33.721 | 0.940 |

The combined candidate reduces paired complete cost about **7.9%** for four
AMAP plants, **6.9%** for MAESPA and **6.0%** for the coupled case. Their ordinary
A/A paired differences are about 1.3%, 1.2% and 1.5%, respectively. The one-plant
AMAP candidate's 2.4% difference is within its 2.7% A/A spread, so remains neutral.
Four AMAP plants produce 184 projected internodes across 189 objects, with 272
actual harness consumer invocations and 368 active reference bindings. This is
modest organ/scenario-width scaling, not hundred-model or million-organ scaling.

MAESPA's saving is chiefly preparation: 56.65 to 46.93 ms, while execution stays
near 80 ms. Bounded graph accounts for most of it; the additional typed
preparation increment is small here. In growing AMAP and the coupled case,
execution includes lifecycle refresh, so cheaper preparation/refresh can reduce
that phase while the same ordinary numerical batches and kernels still run.
The controls do not establish which internal refresh subphase explains each
saving; a dedicated profile is the next experiment before attributing it.

These are encouraging screens, not robust speedup estimates or a default-adoption
gate. No medians or percentages from earlier helper-source cohorts or
CPU-contaminated runs are combined with this final cohort. The current-source
two-step MAESPA timing attempts failed the CPU guard; the valid 24-step case
provides its timing evidence. Small correctness gates still cover two steps.

### Allocations and reachable storage

| Workload | Allocated MB, ordinary A → candidate | Reachable bytes, ordinary A → candidate |
|---|---:|---:|
| AMAPSim, one plant × two steps | 4.370 → 4.124 | 839,645 → 843,413 |
| AMAPSim, four plants × two steps | 16.275 → 14.638 | 2,961,319 → 2,963,655 |
| MAESPA, 24 half-hour steps | 207.690 → 174.789 | 2,517,678 → 2,581,838 |
| Coupled AMAPSim–ArchimedLight–PB, four intervals | 34.122 → 31.291 | 3,089,665 → 3,091,697 |

Reachable size is collected after clocks over simulation/program/fixture roots,
not exclusive PSE storage or process peak RSS. It excludes measurement snapshots
and task-local type-name text. MAESPA's candidate retains about 2.5% more here;
allocation savings do not imply smaller retained state. A single reachable-size
measurement per arm can reflect ordinary container-capacity variation.

## Decision

Keep preparation-only as the candidate worth a wider controlled trial. The
bounded-graph control is useful on MAESPA; typed preparation has additional
promising value during AMAP/coupled growth. Keep the ordinary executor as default
and the candidate opt-in. This round neither promotes the older persistent typed
prototype nor establishes cold-compilation, full-feature or large-population
qualification. No expensive new cold-process or full-suite matrix was run.
The JuliaC program/runtime split remains a separate investigation and PR.


## Evidence and reproduction

The lossless immutable archive is
[`evidence/ecosystem-qualification`](evidence/ecosystem-qualification).
Its `summary.json` is derived by
[`summarize_ecosystem_qualification.py`](summarize_ecosystem_qualification.py);
`manifest.json` gives compressed and raw checksums. The archive includes exact
scientific source copies, the compatibility patch, PSE/helper source snapshots,
raw passing/failing gates, every timing attempt, CPU records, worker/source
bindings and the executed Kaimon controller scripts. No diagnostic attempt is
silently relabeled as a valid timing.

Start Julia through Kaimon for this project. Reconstruct or reuse the frozen
package cohort, set the recorded `PSE_*_PATH` roots before importing scientific
packages, and load the archived bootstrap followed by the relevant fixture and
common runner. The coupled fixture requires a clean ArchimedLight import and
the recorded repaired adapter methods. Use `DownstreamQualification.register_case`
and `screen` with the recorded config; set `replace=true` to repeat a registered
case in the same worker. Run the gate controllers before timing. Archived
controller paths/session IDs are local run metadata and must be adapted for a
new Kaimon session. The Python validator performs no Julia execution.
