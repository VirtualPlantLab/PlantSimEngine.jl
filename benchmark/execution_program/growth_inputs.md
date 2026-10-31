# Growth input refresh and read-only plan storage

This round follows the [direct planner experiment](direct_planner.md). It starts
with fresh ordinary PlantBiophysics and XPalm parity checks, then profiles XP
growth before changing its input compiler. Scientific models and canonical
reference-backed status remain unchanged.

## Measured attribution

The first diagnostic uses five independent four-day XP scenes per profiler,
with separate CPU and allocation runs after an unprofiled oracle. All sampled
states, histories, topology, scientific RNGs and canonical reference identity
transitions match that oracle. CPU sampling selects 107 PSE stacks; allocation
sampling records 4,626 events at a 1% rate. These diagnostics include profiler,
compilation and GC overhead and are not candidate speed measurements.

Default-schema projection accounts for approximately 0.3% of sampled allocation
bytes, so a proposed Default projection optimization is deferred. A second
allocation-only diagnostic uses three fresh four-day scenes in each ordinary
and bounded-metadata arm and attributes allocations to actual PSE source sites.
Its largest ordinary site is `_application_plans`: dynamic lookup across cold
boundaries boxes large inline immutable plan metadata. Existing bounded metadata avoids that
site. Both representations still repeatedly box `CompiledApplicationPlan`
payloads when cold compiler code extracts application properties.

Sampled byte totals have sampling uncertainty. Source sites identify mechanisms;
uninstrumented fresh-scenario execution and complete cost must decide adoption.

## Independent candidates

`GrowthInputReuse` caches only the interpretation of input-plan layout: Symbol
and Bool tags and integer index partitions. Every invocation validates those
tags, reads current plans and resolves current selectors, sources, writers,
policies and reference carriers using the ordinary helpers. Singleton inferred
groups without distributed writers avoid a temporary match vector. It does
not cache live bindings, source membership, negative matches or default values.

`GrowthPlanStorage` constructs application plans with shared heap identity and
the same ten concrete fields as the original plan. Every field is `const`.
Scientific model/selector/override objects and constructor arguments are shared
unchanged. Partial application shells reuse the existing plan object. This is
independent of input partitioning, bounded metadata and the numerical driver.

Both mechanisms are opt-in prototypes. Ordinary controls in this round share
the new cold factory/partition hooks with enabled candidates; the hooks' cost
against the preceding revision has not been independently quantified.

## Validation and measurement status

The initial ordinary PB/XP checks pass 20 assertions. The partition prototype's
first adversarial and generic gates pass 938 assertions, covering current plan
changes, ambiguity errors, Float32 state, One/OptionalOne/Many, growth, removal,
reparenting, re-registered IDs and escaped canonical references. A further 1,171
assertions pass for targeted initialization, mixed cadence, distributed writer
ownership and original PB/XP two-step scientific parity. The corrected mutable
declaration fixture passes 39 assertions. Heap-plan generic, const-field,
lifecycle-identity, deepcopy and checkpoint-continuation checks pass 1,232
assertions. Heap-only targeted initialization, cadence, distributed-source and
original PB/XP checks also pass, as do partition-plus-heap generic/PB/XP checks.

An initial parameter-dependent declaration fixture changed declarations on a
running simulation and refreshed only its logical model. The ordinary oracle
then retained stale execution views. That invalid fixture is preserved in the
raw evidence and corrected to start a fresh simulation after recompilation.
It is not counted as a passed candidate check or a PSE regression.

## Initial balanced warm screens

Fresh independent scenarios run in alternating forward/reverse order over four
cycles. Ratios are medians of within-cycle candidate/control ratios. Complete
cost includes construction, enablement, preparation, lowering and execution.
Both whole-RPC CPU records report no observed competing Julia process at 5% CPU
or above. All timed cases use `outputs=:none`; full-history feature checks run
separately. Science/RNG/work fingerprints match within each case.

The five-arm initial four-day XP screen gives these execution/complete ratios:
partition 1.020/1.020, heap 1.061/1.046, heap plus partition 1.076/1.070, and
existing bounded metadata 0.998/0.982. A separate seven-arm composition screen
checks whether the new mechanisms enable the existing bounded policy:

| XP four-day arm | Execution ratio | Complete ratio | Execution allocation MB |
| --- | ---: | ---: | ---: |
| ordinary | 1.000 | 1.000 | 12.302 |
| partition | 0.967 | 0.993 | 11.605 |
| heap plan | 1.039 | 1.041 | 11.050 |
| heap plus partition | 1.001 | 1.035 | 10.309 |
| bounded metadata | 0.930 | 0.964 | 7.055 |
| bounded plus heap | 0.972 | 0.998 | 6.185 |
| bounded plus heap plus partition | 0.920 | 0.994 | 5.921 |

Partition timing changes direction between the two screens. Relative to the
bounded-only anchor, all three mechanisms together give 0.987 execution and
1.040 complete: fewer allocations do not establish a runtime or complete-cost
win. Pure heap plans also reduce allocation volume while making these short
runs slower. Neither new mechanism is justified as a production default.

PB 32 objects by 128 steps preserves the prior typed-driver execution benefit:
typed and typed-plus-heap ratios are 0.687/0.689 versus ordinary, with identical
114,800 execution allocation bytes. Their complete ratios are 1.058/1.056;
the short run still does not amortize typed preparation. Heap storage adds no
demonstrated PB throughput gain.

The initial XP ordinary sample includes a 118.583 microsecond preparation JIT
event. Other initial timed phases and every composition-screen timed phase
have zero JIT, recompilation and GC. These are small warm screens, not cold
compilation or larger-scale qualification.

## Follow-on payload hypothesis

An escaped erased-access diagnostic identifies the limitation directly. For
the selected XP reproductive-organ application, 500 ordinary `.plan` lookups
allocate 224,000 bytes versus zero for heap plans. But `.spec` still allocates
184,000 bytes in both representations. These loops measure metadata access,
not a scientific model or total application throughput.

A separate `payload=:preboxed` mode therefore keeps the original six cold
payload objects in read-only `Any` fields once, retaining their original types
as phantom plan parameters. Scientific model, status, carrier and numerical
batch types still come from the actual original values. This follow-on must
pass its own feature gates and be measured against controls in a new source
cohort; the earlier source bytes and results are preserved.

Its first generic gate passes 209 assertions. Further focused checks pass for
original PB/XP (141/3,221 assertions), initializer (276), mixed cadence (343),
distributed sources (242) and the real preboxed-plus-partition combination
(954). They check unchanged scientific model objects, runtime payload types,
read-only fields, plan/payload identity and full state/history/RNG/live-reference
parity. Separate timing qualification follows these gates.

No full regression-suite, million-organ, many-hundred-model, peak-memory or
production adoption claim is made.
