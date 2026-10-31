# XPalm CPU attribution and framework fixes

Graph-row projection is the strongest candidate: twelve-day XP tests prepare
25–27% faster and reduce complete fresh-run cost by about 6–9% against the two
identical bounded-metadata controls. Execution time is essentially unchanged. Removing refresh
dictionaries alone does not produce a runtime win once validation is included.

This round investigates why the [newborn binding experiment](newborn_bindings.md)
reduced XP execution allocations without a repeatable whole-run speedup. Original
PSE reference storage and XP/PB scientific kernels remain the controls.

## Attribution before changing the executor

A fresh Kaimon worker verifies Julia 1.13.1, PSE 0.15.1, PB 0.18.1 and XP 0.7.0
from the intended checkouts. Two-day full-history XP checks pass for sequences
alone and with bounded metadata. A prepared-batch harness also passes 24 small
assertions with two identical bounded-executor labels and independently built
simulations; this supplies a fresh-instance repeatability control for later comparisons.

The initial four-day CPU profile has only 95/74 recognized samples and its first
instrumented control compiles instrumentation. It is retained as preliminary
diagnostic evidence, not a comparative timing result. A source-inventory check
also exposed inconsistent traversal of archived source copies under `results/`.
The inventory now uses explicit directory traversal and excludes those trees
deterministically. Failed checks and previous source bytes are retained.

The twelve-day diagnostic uses five independently prepared scenes per arm for
CPU sampling and another five for allocation sampling. It selects stacks inside
the execution entry, reports nearest source operations and retains unrelated
process samples separately. The bounded control and sequence candidate have
678/693 source-operation samples. State, retained history, topology, numeric
types, scientific RNG, work and canonical-reference transitions match outside
profiling. Profiling overhead, compilation and GC remain reported; sampled
durations are not product benchmarks.

Residual dynamic dispatch, output/status preparation, target construction and
execution-group refresh remain visible in both arms. Individual guard names
not appearing among top source sites do not prove they are free: inlined work
can be charged to its caller. The independent warmed framework companions have
zero reported JIT/GC, with input refresh around 10 ms and execution-plan refresh
around 6 ms across twelve days. Their nested timings overlap and are not an
additive split between science and framework work.

The prior unprofiled short runs had zero GC time in both arms. Reducing allocated
bytes therefore did not supply a GC saving in those runs. It also did not remove
the remaining refresh/dispatch work, while the sequence added preparation cost.
The old twelve-day execution difference is sign-fragile; preparation was slower
in all six paired samples. These observations explain why allocation alone is
insufficient evidence, without assigning a precise causal share to each cost.

Preparation-only sampling uses eight independent already-constructed models and
executes zero scientific timesteps. Its two highest source locations in both
arms are `_scenario_call_owners` and `_freeze_scenario_application_children`.
Both scan all applications again for every graph row and evaluate empty-set
defaults inside that scan. Execution sampling also identifies reconstruction of
the previous-group ID dictionary, despite an existing application-slot index.

## Independently gated candidates

`GraphRowProjection` projects actual graph neighbours into authored application
order instead of repeatedly scanning the whole application set. It passes 1,079
metadata assertions, including non-dense slots, sparse/dense graphs, changing
relations, unknown IDs and identical bounded factory/counter shapes. Short
original XP/PB checks pass separately and in composition. XP preparation really
projects two tables with 122 rows and 110 edges; PB projects six rows/four edges.

`ExecutionGroupLookup` uses the existing execution-group slot index only on an
exact application-identity match, with a lazy original ID dictionary for misses.
Growth, heterogeneity, movement, removal/re-addition, distributed and temporal
checks pass, together with original XP/PB parity. Reorder/replacement is tested
with bounded metadata in both arms; the ordinary unbounded control cannot retain
its old concrete compiled-scene field across that test's changed layout. An
initializer fixture correctly takes the existing pure-append path without
entering this lookup experiment; it receives no optimization credit.

The first lookup implementation is scientifically correct but does not avoid
XP's dictionary construction: two-day coverage has 78 identity hits and 22
absent-slot misses, building two dictionaries in two refreshes. A refined
per-refresh identity check for the full slot index now allows proven empty
slots to return absence directly. It passes 2,585 focused assertions, including
wrong-index/ghost-group rejection, lifecycle and original XP/PB cases. Two-day
XP coverage validates both refreshes, returns 78 actual groups and 22 trusted
empty slots, and builds zero dictionaries. The reference snapshot, index scan
and coverage checks remain real work and are included in candidate timing.
Uncertain application epochs retain
the original ID fallback. None of these changes replace scientific values,
declarations, target construction or downstream validation/reuse decisions.

Four two-day scientific composition checks also pass after refinement. The
metadata-only helper checks extend to 32/128/512 synthetic application records;
they preserve table/factory work, include fresh layout setup, and receive no
application-performance credit.

## Balanced application measurements

The small screen uses two independent two-day simulations per sample and four
balanced cycles. Its graph-only preparation and complete cost improve against
both identical controls. The moderate screen expands to four independent
twelve-day simulations per sample and six balanced cycles. Every simulation is
fresh, with original scientific models, independently owned refs and copied
forcing. Full post-run observations, RNG and work match; two-day correctness
checks separately retain all output history.

These are warm-method fresh-scenario measurements. Complete cost includes each
instance's construction, enablement, preparation, lowering and execution. Weather
is read at case registration and copied per fresh instance. The existing growth
diagnostic uses seed 1, initiation age zero, architecture disabled and both
phyllochron speeds set to 0.2 phytomer per degree-day. It is a growth stress case,
with the same parameters and scientific kernels in every arm.

All ratios below are medians of within-cycle ratios to bounded control A;
lower is better. They are not ratios of independent median timings.

| Twelve-day candidate | Preparation | Execution | Complete |
|---|---:|---:|---:|
| Identical bounded control B | 1.013 | 1.023 | 1.015 |
| Previous binding sequences | 1.173 | 1.001 | 1.054 |
| Graph projection | **0.747** | 0.999 | **0.943** |
| Validated slot lookup | 1.036 | 1.041 | 1.048 |
| Graph + lookup | 0.735 | 0.992 | 0.931 |
| Graph + lookup + sequences | 0.886 | 0.972 | 0.953 |

Graph-only preparation wins all six pairs against both controls (ratios
0.747/0.728), with complete ratios 0.943/0.913 and five of six complete wins.
Its execution allocations are essentially unchanged; the demonstrated gain is
preparation work. Complete allocations fall from 112.96 MB to 109.55 MB per
four-simulation batch.

The refined lookup really avoids dictionaries: every twelve-day batch validates
48 refreshes, returns 1,872 nonempty groups and 528 trusted-empty results, and
builds zero ID dictionaries. It still performs index scans, scalar metadata
reads and reference snapshots, and is slower alone. Fewer allocations and zero
map builds therefore do not establish reduced CPU work. Its marginal addition
to graph projection is small: complete ratio 0.983 against graph alone, four of
six wins. This does not establish a reliable incremental gain.

Sequences added to graph+lookup have execution ratio 0.973 (five of six wins)
but preparation ratio 1.196 (zero wins), leaving complete ratio 1.018 (two wins).
Keep this possible runtime tradeoff separate from the robust graph-only result.
The identical-executor A/A execution ratios span 0.967–1.143, so small signals
must be treated cautiously. All timed execution phases have zero reported JIT,
recompilation and GC; small sequence preparation compiler events are retained.
Both timing artifacts have explicit hash-bound quiet-CPU qualification.

## Scope and reproduction

All candidates remain opt-in. Ordinary reference storage, scientific kernels
and execution remain the default/reference. No new cold-Julia-compilation,
peak-RSS, million-organ or full-regression-suite qualification was performed.
PB's short checks confirm preservation; this round does not claim a PB speedup.

In a fresh Kaimon session for this checkout, load definitions in dependency order:

```julia
include("benchmark/native_downstream/load_newborn_binding_experiment.jl")
for file in ("graph_row_projection.jl", "execution_group_lookup.jl",
             "execution_group_epoch_lookup.jl", "xp_prepared_batch_timing.jl",
             "xp_growth_candidate_measurements.jl")
    include(joinpath("benchmark/native_downstream", file))
end
XPGrowthCandidateMeasurements.candidate_checks(:xp;
    arm=:graph_lookup_sequence, steps=2, outputs=:all)
spec = XPGrowthCandidateMeasurements.register_xp_candidate_batch_case!(
    :xp_candidates; batch_size=2, steps=2)
screen = XPGrowthCandidateMeasurements.screen_xp_candidate_batch(spec;
    repetitions=4)
```

The [derived evidence summary](evidence/xp-growth-attribution/summary.json),
[artifact manifest](evidence/xp-growth-attribution/manifest.json) and
[source provenance](evidence/xp-growth-attribution/scientific-provenance.json)
retain timings, diagnostics, source versions, failed expectations, forcing and
independent audits. Accidentally traversed historical source copies are listed
by path/size/hash as exclusions; active before-source files and failed manifest
records remain. `summarize_xp_attribution.py --check-only` validates the local raw
input tree without Julia; `--archive-frozen` creates a new immutable archive and
refuses to overwrite one. Profiler elapsed times and unqualified helper timings
are never promoted to application-speed evidence.
