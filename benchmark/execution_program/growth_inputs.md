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
assertions. Heap downstream gates and paired timing screens are in progress;
no new speedup is claimed at this checkpoint.

An initial parameter-dependent declaration fixture changed declarations on a
running simulation and refreshed only its logical model. The ordinary oracle
then retained stale execution views. That invalid fixture is preserved in the
raw evidence and corrected to start a fresh simulation after recompilation.
It is not counted as a passed candidate check or a PSE regression.

No full regression-suite, million-organ, many-hundred-model, peak-memory or
production adoption claim is made.
