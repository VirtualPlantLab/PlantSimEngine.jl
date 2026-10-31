# Preparing known future layouts before growth

The prototype preserves the checked scientific behavior and can move compilation
before growth, but increases complete time in this screen. Bounded specialization
alone remains the strongest candidate.

This experiment prepares a finite catalogue of declared future status and call
layouts before the live simulation advances. All scientific execution still uses
the ordinary executor. The four arms are ordinary preparation, future-layout
preparation, bounded specialization, and both together.

## Implementation

`FutureLayouts.FutureArchetype(name, builder; environment_types=...)` declares an
independently allocated representative future scene. The builder constructs only
organ/model metadata. It never advances a timeline or invokes a scientific growth,
initializer or numerical kernel. The prototype prepares that disposable scene at
zero steps, records types and assembly metadata, then issues type-only
`Base.precompile` requests. The returned catalogue retains types, functions and
labels, without scientific model instances, statuses, reference cells or samples.
These requests prepare code in the current Julia process; the prototype does not
produce a persistent compiled-scenario artifact or a system image.

Status hints include value-NamedTuple and reference-NamedTuple constructors and
view/Many assembly signatures. `FutureCallLayouts` collects concrete kernel,
context, target, batch, call and scheduler signatures. Initially targetless
applications take priority. Model-facing environment types are explicit
declarations; discovery does not sample a live or custom backend. The supplied
PB/XP declarations read stored global-forcing row types.

Live canonical Status and field Ref identities, kernel/sample counters where
instrumented, scientific RNG next draws from copies, and both Julia task RNG
states are guarded around the future phase. Constants are copied. A reachable
Julia mutable-identity scan rejects shared model/status/environment storage.
Both the default RNG and the separate `Random.get_tls_seed()` state are restored
in `finally`, including builder failure; XP construction calls `Random.seed!`.
These checks supplement the independent-builder contract. They cannot prove the
purity of arbitrary user factories, generated functions or opaque foreign buffers.

No replacement executor or runtime data cache is installed. New organs still
receive fresh canonical state, mutable defaults, bindings, calls and sampled
values. Undeclared layouts, overrides, temporal policies, public calls and other
PSE features continue through the ordinary path. This preserves their execution
path; it does not establish that every possible layout was precompiled.

## Small cases and correctness

- Generic: zero worker/child targets initially; one then two Float32 organs,
  stochastic worker and hard-call child, fresh sampled environment. Exact live
  scientific state/history/topology and RNG parity pass. Four newborn status
  views match, and all eight actual kernel-entry observations match accepted
  requests (creator twice, worker three times, child three times).
- PB: a generic lifecycle controller creates one then two gas-exchange objects.
  All original Monteith/Fvcb/Medlyn applications initially have zero targets.
  Their scientific methods are unchanged. All three candidate arms match the
  ordinary control; all six newborn status views match the catalogue. Original
  scientific entries are not wrapped, so no actual entry/code-cache-hit claim is
  made for those methods.
- XPalm: two diagnostic growth days create six organs. An explicit disposable
  next-archetype builder uses `add_organ!` for Phytomer, Internode and Leaf metadata
  only, without calling PhytomerEmission, an initializer or any scientific kernel.
  All three candidates match complete state/types, history, topology and scientific
  RNGs. Both future arms match all 52 newborn status views observed after refresh.
  The collector reports six partial initializer-call layout gaps. The 15 initially
  targetless reproductive applications are outside this next-vegetative-archetype
  catalogue and remain ordinary; targetless support is directly exercised by the
  generic and PB cases.

The additional carrier gate executes an empty Many consumer, then one and two
Float32 sources. All three candidates preserve per-step values/types/history,
aligned IDs and canonical source Ref identity. Separate negative builders return
distinct models sharing a live backend or scalar Ref; ownership rejection preserves
state, identity and both RNG states.

Constructor-only and alias-rejection checks also pass after the final RNG guard
fix. One early load attempt failed on a keyword `@nospecialize` annotation and
was corrected. A subsequent test compared RNG state across a Test.jl testset
boundary, which deliberately resets that RNG; capturing both states in the same
scope corrected the oracle. Both failed attempts remain in the receipts and are
not counted as passes. The separate TLS-seed leak was then fixed in the prototype,
not hidden by the test correction. Earlier qualified source cohorts are retained.

These are small targeted checks, not a completed PSE regression suite or
validation of scientific hypotheses. The ordinary fallback is preserved, while
broader precompile coverage still requires declared layouts and further checks.

## First-use timing protocol

One distinct fresh Kaimon-controlled Julia process is used per arm, with no prior
case execution, warmup or IR probe. Package disk caches remain available. Loader
cost after Kaimon project import is recorded separately. Every scientific model
is constructed independently. Forcing setup, including XP CSV reads, is charged
to construction and disposable-builder costs in these cases.

Each record separates construction, normal preparation, all future blueprint /
zero-step preparation / precompile / guard work, first growth and execution, and
the remaining second step. Complete time sums all those phases. A reduction in
first-growth latency alone is a shift of cost, not a total-speedup claim. Detailed
inner future-phase timings can omit enclosing-wrapper compilation; the outer
measured future phase and complete total include it. Julia compile/recompile
counters are not disjoint wall-clock components.

One CPU-qualified observation per arm (seconds):

| Package / arm | Normal preparation | Future phase incl. guards | First growth/execution | Complete |
| --- | ---: | ---: | ---: | ---: |
| PB / reference executor | 9.269 | 0.285 | 3.936 | 15.920 |
| PB / future precompile | 9.662 | 4.250 | 2.282 | 18.703 |
| PB / bounded preparation | 8.570 | 0.286 | 3.593 | 14.947 |
| PB / combined | 8.469 | 4.237 | 1.814 | 16.808 |
| XP / reference executor | 100.655 | 0.523 | 15.186 | 128.254 |
| XP / future precompile | 100.658 | 11.475 | 14.371 | 138.250 |
| XP / bounded preparation | 69.310 | 0.524 | 12.235 | 93.662 |
| XP / combined | 69.602 | 11.045 | 11.409 | 103.731 |

The common future phase also measures the same preservation guards in control
arms. Compared with bounded specialization alone, adding future precompilation
raises PB complete cost **14.947 → 16.808 s** and XP complete cost
**93.662 → 103.731 s**. PB first growth improves **3.593 → 1.814 s**; XP first
growth improves only **12.235 → 11.409 s**. The upfront cost outweighs those gains.
Future preparation alone raises complete cost by 17.5% for PB and 7.8% for XP.

Bounded specialization alone is the strongest complete-cost result: PB is 6.1%
lower and XP 27.0% lower than ordinary in these single observations. Their exact
scientific digests match within each package. These are screens, not repeatable
speedup guarantees or confidence intervals; no larger run was attempted.

XP's expensive future phase is mainly signature collection: **7.809 s and
2.07 GB allocated**, versus **0.529 s** for the call precompile requests themselves.
Most recorded cost is compiler work. That makes bounding extraction-helper
specialization and avoiding unnecessary full-scene call materialization a more
plausible next experiment than increasing the hint count. Exact transient
initializer layout preparation is another candidate for first-growth latency.
Neither improvement is claimed as implemented or measured here.

All eight qualified cold processes have distinct PIDs and no observed competing
Julia CPU activity. An earlier PB ordinary attempt overlapped another task and is
preserved as unqualified; setup-only failures have no simulation timing. Cold
sources, scientific work/guards and loaded package provenance were checked
independently. No numerical executor or scientific method was changed.


This is a new growth task for PB and a two-day task for XP. Earlier static PB or
one-day XP timing numbers must not be pooled with these records. The relevant
control is the ordinary arm on this same source, fixture and measurement protocol.

## Current bounds and next work

The small screen permits 12 precompile hints, including at most two status hints.
Discovery has a separate 128-signature cap, 256-layout/target bounds and maximum
call depth 16. More hints are not assumed better: unused signatures can add
compilation and resident code without helping the next birth. Across several
archetypes, the first can consume the global budget; the present screen uses one.

The ownership guard walks the initial live mutable graph, with a 100,000-node
limit. Its full cost is charged. This is not yet preparation independent of the
number of initial organs. A production blueprint could use explicit ownership /
schema declarations to avoid a full live-graph scan, while retaining fresh cells.

A complete future scene also need not represent transient targeted-newborn
initializer status/context layouts before global refresh. A metadata-only phase
archetype could materialize those call targets in authored order and retain only
their signatures. It must not run the scientific initializer to warm the code.
Exact type equality and `Base.precompile == true` are useful coverage evidence;
neither establishes MethodInstance reuse, absence of invalidation or a code-cache
hit. First-use measurements determine whether these requests help this task.

## Reproduce

Use Kaimon with this checkout. The generic loader imports no optional scientific
packages:

```julia
include("benchmark/native_downstream/load_future_layout_experiment.jl")
FutureLayoutChecks.generic_future_layout_checks(; arm=:future_precompile)
FutureLayoutChecks.generic_future_layout_checks(; arm=:combined)
```

For PB/XP, also load `benchmark/native_downstream/load_experiments.jl` with the
compatible local package checkouts from [the benchmark setup guide](../README.md).
Run `downstream_future_layout_checks(:pb; arm=...)` before the XP variant. Use
`FutureLayoutMeasurements.run_future_layout_case(kind, arm; ...)` for one staged
measurement. `future_layout_cold_case.jl` requires an explicit distinct-process
attestation and runs one arm before provenance/snapshot/type diagnostics.

[Summary](evidence/future-layouts/summary.json),
[manifest](evidence/future-layouts/manifest.json), compressed raw results, source
snapshots and Kaimon receipts preserve the evidence. Original local files remain
unchanged. `python3 benchmark/execution_program/summarize_future_layouts.py`
rebuilds the archive losslessly. CPU-isolation records distinguish qualified cold
cases from attempts overlapped by unrelated Julia work.
