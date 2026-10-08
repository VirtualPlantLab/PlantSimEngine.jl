# Adaptive selector comparison

`adaptive_selectors.jl` is a standalone, generic compiler benchmark. It does
not add dependencies or join the routinely tuned AirspeedVelocity suite.
Run it through Kaimon sessions for each compared PlantSimEngine checkout.

For an initial smoke run:

```julia
include(joinpath(pkgdir(PlantSimEngine), "benchmark", "adaptive_selectors.jl"))
bench = AdaptiveSelectorBenchmarks
bench.measure_fixture(() -> bench.common_fixture(2); samples=1, timestep_steps=2)
bench.measure_fixture(() -> bench.sparse_fixture(1_000); samples=1, timestep_steps=2)
```

Use the same driver file in both checkout snapshots. The aggregate comparison
is `bench.run(densities=(64, 304, 1376), sparse_objects=100_000, samples=3)`;
large baseline compilation is expensive, so individual `measure_fixture`
calls and `samples=1` are suitable for bounded exploratory measurements.
After warming the same method signatures on the smaller sizes, passing
`warmup=false` skips a redundant full-scene operation at the largest size.
The returned measurement records whether it performed its own warmup.
Set `measure_reachable=false` for large cases: `Base.summarysize` can itself
be expensive on large typed status/batch tuples. The aggregate driver omits
reachable-graph estimates above 304 plants or 60,000 sparse objects. Omitted
estimates are `nothing`; cumulative allocation bytes remain measured.
For a bounded compiler comparison, `measure_selectors=false` omits the raw
selector sweep while still checking exact ordered source IDs, producers, and
live references through the compiled bindings. Its `selector` measurement is
`nothing`; `selector_sweep_measured` records this omission.
On a candidate with query reuse, `cached_selector_sweep(data)` and
`check_cached_selectors(data)` isolate its query-work benefit and verify that
mutating a returned ID vector cannot modify the cached snapshot. Use a fresh
cache per consumer, as the compiler does. Comparing this sweep with
`selector_sweep(data)` does not measure a full compiler speedup.
Record the source revision alongside the returned package path, version,
active project, and Julia version.

The common-label fixture contains exactly 196 objects per plant, including 47
matching leaf objects under 47 branches. Increasing the number of plants
increases the shared global label buckets while preserving each plant's
local query size. One and four input variants select identical object sets
but use distinct producer applications and variables. This comparison can
show whether sharing the object-query work is material after adaptive
resolution. The sparse fixture has one huge subtree with only 64 matching
leaf objects, where a rare index bucket should remain preferable to a full
descendant walk.

Each operation receives an untimed warmup. Object and registry construction,
raw selector sweeps, fresh full compilation, and ordinary compiled timesteps
are measured separately, with garbage collection outside each sample. The
compiler operation uses `Advanced.refresh_bindings!(model; force=true)` so that
a valid binding cache cannot turn it into a no-op. Retaining that compiled
result avoids another full compile when starting the untimed simulation.
Timesteps use no retained
output streams and verify that compiled bindings remain identical across
ordinary continuation.

`median_allocated_bytes` measures cumulative allocations during the operation.
`reachable_bytes` and `model_reachable_bytes` use `Base.summarysize`; these
describe reachable object graphs, not resident memory, peak memory, compiled
code, or allocator slack. Medians and minima are reported without CI timing
thresholds. Untimed gates check ordered resolved IDs, each input's producer
application and source variable, live reference carriers, and aggregate values.
The reference gate mutates and restores a source value while confirming that
the binding cache remains unchanged. Lifecycle, cardinality, and coverage
regressions belong to the package tests.

These fixtures isolate generic PlantSimEngine work. They are not scientific
AgriPV validation and do not measure the separate geometry-ID selector or
ArchimedLight indexing changes.

The resolver estimates global candidates from the smallest usable registry
criterion. Scalar label buckets are borrowed directly; label collections borrow
their buckets and use the sum of their lengths as a conservative estimate.
Repeated collection entries can overestimate the budget but never change the
matched set. A criterion containing an unindexed `nothing` label cannot supply
a complete index, so another criterion or the registry supplies candidates.
An empty usable bucket provides a zero budget and an empty match.

Subtree, named scope, plant/ancestor scope, and descendant-relation queries try
a local walk with that candidate count as the budget, capped at scene size.
The walk stores only depth-sized child cursors and stops before exceeding its
budget. A completed walk is filtered locally; an incomplete walk falls back to
the borrowed smallest bucket and checks all labels and topology. There is no
empirical multiplier in this implementation. The common and sparse fixtures
exercise both choices without assuming that every subtree should be traversed.

Within one consumer's input compilation, repeated `Many` object queries share
an owned, unfiltered ID snapshot. The key contains normalized object matcher
fields, excluding variable, process, and application filters; context and
scene are fixed by the cache's local lifetime. Each input owns a separate vector
before writer filtering. The cache is created only for multiple declared Many
inputs and discarded when that consumer's bindings are assembled. It also
applies when lifecycle refresh compiles new consumers or performs a full
recompile. Existing incremental membership updates and fallback re-resolution
of old bindings remain unchanged.

Ordinary simulation steps already retain compiled bindings. Topology changes
use the existing addition/removal/reparent refresh paths; metadata label edits
through the graph editor reindex objects and request full binding refresh.
Consequently fresh resolutions see current bucket sizes, and no strategy cache
needs to be invalidated or reconsidered on each timestep.

## Measured comparison (2026-10-08)

The base is commit `7f3293644c408a1197131a57ab5301c700ed3140`; the candidate
is the working tree on `codex/adaptive-subtree-selectors` before the PR commit.
Both ran through Kaimon with Julia 1.13.1 and PlantSimEngine 0.15.0 on macOS
aarch64, with sequential timing runs and matched external dependency versions
and tree hashes. The [comparison JSON](adaptive_selectors_comparison.json)
contains package/project paths, source SHA-256 fingerprints and exact values.

Full coupling compilation uses `refresh_bindings!(force=true)`. Allocations
below are cumulative per operation; GB and MB use decimal units. One-input
and four-input cases use distinct producer applications and variables.

| Scene | Inputs | Base compilation (s) | Candidate compilation (s) | Base allocations | Candidate allocations | Time ratio |
|---|---:|---:|---:|---:|---:|---:|
| 64 plants | 1 | 0.098942 | 0.023189 | 117.03 MB | 11.85 MB | 4.3x |
| 64 plants | 4 | 0.414017 | 0.078134 | 471.51 MB | 45.25 MB | 5.3x |
| 304 plants | 1 | 2.635 | 0.111883 | 2.318 GB | 54.79 MB | 23.6x |
| 304 plants | 4 | 11.465 | 0.400852 | 9.292 GB | 211.23 MB | 28.6x |
| 1376 plants | 1 | 100.007 | 0.729261 | 45.509 GB | 324.07 MB | 137.1x |
| 1376 plants | 4 | 370.556 | 2.208 | 181.959 GB | 1.090 GB | 167.8x |
| 100,000-object sparse subtree | 1 | 0.013656 | 0.000994 | 12.22 MB | 1.07 MB | 13.7x |
| 100,000-object sparse subtree | 4 | 0.037373 | 0.002305 | 46.49 MB | 1.85 MB | 16.2x |

The common fixtures contain 12,545, 59,585 and 269,697 total objects for 64,
304 and 1376 plants, with 3,008, 14,288 and 64,672 matching leaves. The sparse
fixture contains 100,001 total objects, including its scene object, with 64
matching leaves. At 1376 plants and four inputs, compilation fell from
370.556 s / 181.959 GB allocated to 2.208 s / 1.090 GB allocated. Both revisions
passed exact ordered IDs, producers, variables and live-reference checks for
all 5504 bindings. The smaller baseline rows also passed ordered raw-selector
and aggregate execution gates; the revised reference gate passed separately
on the baseline tiny fixture.

Raw selector work illustrates the scaling independently of full compilation:
at 304 plants with four inputs it fell from 10.651 s / 9.064 GB to
0.050535 s / 37.47 MB. At 1376 plants with one input it fell from
100.428 s / 45.196 GB to 0.086715 s / 42.10 MB. The largest four-input raw
sweep was omitted on both revisions to keep the baseline workload bounded.

Construction and ordinary execution were measured separately:

| Scene, four inputs | Base construction (s) | Candidate construction (s) | Base 10 steps (ms) | Candidate 10 steps (ms) |
|---|---:|---:|---:|---:|
| 64 plants | 0.025 | 0.029 | 0.688 | 0.856 |
| 304 plants | 0.181 | 0.198 | 6.341 | 6.924 |
| 1376 plants | 1.999 | 1.904 | 41.562 | 44.480 |
| 100,000-object sparse subtree | 5.830 | 5.882 | 0.035 | 0.041 |

Ordinary timesteps retained the same compiled-binding object. The largest
four-input 10-step operation allocated 2,655,520 bytes on both revisions.
Timestep time varies in these measurements; no timestep speedup is claimed.

The candidate-only query reuse comparison at 304 plants and four inputs
measured 0.051452 s / 37.47 MB without sharing versus 0.017047 s / 10.06 MB
with a fresh per-consumer cache. Returned IDs and independently owned result
vectors matched exactly. This measures query resolution, cache lookup and
result copying; it is not a full compiler ablation.

The 64/304-plant and sparse timings are medians of three samples after warmup.
The largest cases have one timed sample after warming the same compiler and
selector method signatures on smaller fixtures; their construction can
include size-specific Julia compilation. Largest four-input selector sweeps
and large reachable-memory estimates are explicitly unmeasured, except for
the completed baseline largest one-input graph estimate. Base summary-size
accounting became expensive outside the timed operations, so it was omitted
for the remaining large cases. Root and temporary test manifests differ in
Julia-bundled stdlib/JLL metadata, while both execute the same Julia 1.13.1
runtime. These machine-local, generic fixtures do not establish scientific
AgriPV validity or downstream full-scene performance.
