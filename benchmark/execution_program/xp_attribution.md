# XPalm CPU attribution and framework fixes

This round investigates why the [newborn binding experiment](newborn_bindings.md)
reduced XP execution allocations without a repeatable whole-run speedup. Original
PSE reference storage and XP/PB scientific kernels remain the controls.

## Attribution before changing the executor

A fresh Kaimon worker verifies Julia 1.13.1, PSE 0.15.1, PB 0.18.1 and XP 0.7.0
from the intended checkouts. Two-day full-history XP checks pass for sequences
alone and with bounded metadata. A prepared-batch harness also passes 24 small
assertions with two identical bounded-executor labels and independently built
simulations; this supplies a timing-noise control for later comparisons.

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
per-refresh identity check for the full slot index is being tested so proven
empty slots can return absence directly. Uncertain application epochs retain
the original ID fallback. None of these changes replace scientific values,
declarations, target construction or downstream validation/reuse decisions.

Correctness and independent/combined timing qualification follow these profiles.
No new cold-compilation, peak-RSS, full-suite or production-adoption claim is made.
