# Independent preparation review

Source-only review on 2026-10-30 of the current `src` diff, frozen preparation prototypes, `results/preparation-reuse`, and draft `benchmark/execution_program/preparation_reuse.md`. No Julia executed and no frozen source changed.

## Outcome

No correctness blocker found in the reviewed source paths. Bounded specialization is the promising **first-use XPalm compiler/preparation** candidate. Recipe reuse has real positive coverage but no convincing performance win; the combined result does not improve on bounded preparation alone. Keep all of these conclusions local to the measured fixtures and opt-in prototype.

## Source and semantic checks

- Bounded factories precede all-scene Tuple/NamedTuple construction, retain original per-application/input/call plan objects, and use a coherent representation at all three CompiledCompositeModel construction sites. Ordered Symbol lookup and explicit `_application_plans(::BoundedSymbolTable, slot)` preserve real non-dense slots. Numeric model/status/carrier/batch types remain concrete. Runtime membership, cadence state, environment sampling and output ownership are still ordinary PSE operations.
- Recipe caches contain symbolic binding shape and Many-slot metadata, not scientific defaults, values, refs, model objects or sampled environments. Each assembly uses the current object's canonical state and binding carriers. Temporal/private cases remain ordinary.
- Plain preservation creates a new Status identity token. It verifies canonical names/refs and live BoundMany alignment; backed canonical Status objects fall back. Returning old affected views would have violated the opaque Status identity contract; that approach was removed. The final identity oracle correctly checks every existing view and saved/current call-target epochs rather than assuming the reader must rebuild.
- Passed artifacts checked: PB/factorial state/ref gates, `width-checks.json`, all three XP candidates, corrected temporal/identity gates, six initializer/mutable-environment/Many/mixed-cadence/distributed cases, and both spatial cases. Interrupted Kaimon evaluation and earlier fixture-assumption failures remain unqualified. This is useful focused coverage, not a full PSE regression run or exhaustive validation of arbitrary user kernels. Templates/instances/overrides and readable-source/graph APIs were not exhaustively rerun in this round.
- Reviewed the new typed integration source (SHA 91ec5926…): it compares original scientific kernels and all state/history against ordinary PSE, counts actual roots/children/lookups in a companion, and keeps timed child counters absent. Timed coverage claims entered batches, not inferred children. No source-level blocker found. Its runtime result was still pending at this review; source availability is not a pass.

## Evidence and claim limits

- There are **eight fresh-process cold observations total**, four PB and four XP arms, with one observation per arm. Every package's four arms match one complete state/history digest and matching work. PIDs are distinct and first-use attestations record no prior case/IR execution. The core and preparation implementation hashes match the measured sources. Loader/startup is excluded and separately recorded; this is first scientific use with disk precompile caches retained.
- XP complete first-use wall cost is 132.676 s ordinary, 96.442 s bounded, 134.574 s recipes, and 97.022 s combined. Preparation is 105.900, 73.327, 108.043, and 74.118 s respectively. The draft's ~27% complete/~31% preparation reduction for bounded is numerically correct. Single observations do not establish a repeatable speedup guarantee. PB's ~3% complete difference is not a qualified win.
- Warm PB32×128 has four balanced cycles and no JIT/GC in timed phases; it shows no runtime or complete-cost gain. Warm XP4day has three alternating cycles (not perfectly balanced); complete ratios are ~0.985 recipes, 1.016 bounded, 1.016 combined. Its one ~79 microsecond ordinary-preparation JIT event is recorded. No sustained warm runtime gain is established.
- XP warm execution allocation volume falls from ~12.146 MB ordinary to ~6.979 MB bounded (~42.5% less). This is allocation volume, not peak memory. The measured reachable Simulation size actually rises from 825,785 to 868,521 bytes (~5.2%); global WeakKey recipe/counter registries are outside `summarysize(simulation)`. The draft correctly avoids a peak-RSS claim; do not describe this as a blanket memory-footprint reduction.
- The width fixture establishes constant bounded scenario/compiled types for two/four private-output models with fixed scientific layouts. It is not evidence yet for hundreds of models or millions of organs. Remaining concrete scientific schema widths can still create legitimate specializations.

## Small reporting/provenance refinements

1. The draft says “wall preparation minus compilation is about 0.24 s … identifies JIT/inference.” Prefer: **the reduction tracks reported compiler work and is consistent with a compiler-dominated first preparation**. Compilation counters are not exclusive wall-clock components (PB has counters larger than wall time), and they do not isolate inference from code generation. Avoid treating the subtraction as a measured noncompiler phase.
2. The qualified source manifest currently snapshots PB's cold helper hash `2e53e8e…`; all PB arms use it. All XP arms use the later forcing-row helper hash `af0e83c6…`. Both cohorts are internally consistent and only the XP setup changes, as the draft notes. Archive/label the final XP helper separately before handoff so both exact cold drivers remain reconstructable; do not overwrite the PB snapshot.
3. Include the new typed integration source/result in the final evidence archive only after its gate completes. Do not add its assertions to the qualified totals while pending.

No additional runtime expansion is needed for this review. Repeated, reversed-order cold XP observations and targeted remaining public-feature gates are appropriate before production promotion; the current report already labels the experiment's practical limits.
