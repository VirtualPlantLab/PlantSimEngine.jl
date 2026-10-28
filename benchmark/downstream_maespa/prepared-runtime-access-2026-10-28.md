# Prepared runtime access against the current parent

A: `8177456799c69c20042869d8b40a6790e81cdde1`. B: `a83d8135c620115d594c759b82474a77ca96daef`. Fixed MAESPA: `e4cd5cfe4a11c2a5ad0bc1f5dff9c5fb2a962fe3`.

Primary paired prepared-wall reductions: native-none +5.98%; native-all +2.86%; air3-none +1.73%; air3-all +5.85%. Wall and allocation results are the headline metrics; process CPU is qualified below.

This adjacent comparison covers Status access annotations and concrete default-context singular-call snapshots in one PR. Earlier aa813→57df results are historical and excluded.

Status uses the same live Ref reads, writes and conversions. The snapshot path requires concrete metadata fields and exact environment type; it keeps full identity/time/permission checks and synchronizes descendants before lookup. Broad shells, overrides of a different type and reentry retain the generic path. Sampling and scientific equations are unchanged.

## Protocol

Primary: 96-step continuation of a fresh zero-step-prepared simulation. Secondary: each sample's construction + preparation + continuation sum. No manual target or numerical-environment prefill occurs.
Four conditions receive 12 balanced AB/BA pairs each: 96 fresh measured simulations. Warmup, pre-sample GC, verification and controller/MCP overhead are excluded. Every measured phase has zero compilation and recompilation.
Julia 1.13.1, Apple M3, arm64 macOS; 14 compute, one interactive and 14 GC threads. Each scenario has 27 objects, 100 applications, 16 logical leaf units and 96 half-hour steps.
CPU is process CPU across all Julia threads. Allocations are volume, not peak memory. Positive reduction means lower B cost; negative values are regressions. Paired reduction is the median of within-pair reductions; it is distinct from reduction of the two medians.

## Prepared continuation

| Scenario / output | Metric | A median | B median | Median reduction | Paired reduction |
| --- | --- | --- | --- | --- | --- |
| native-none | Wall (ms) | 96.445 | 89.831 | +6.86% | +5.98% |
| native-none | CPU (ms; GC-influenced) | 123.662 | 89.614 | +27.53% | +21.51% |
| native-none | Allocated (MiB) | 66.725 | 62.585 | +6.20% | +6.20% |
| native-all | Wall (ms) | 104.087 | 100.569 | +3.38% | +2.86% |
| native-all | CPU (ms) | 103.952 | 100.499 | +3.32% | +4.45% |
| native-all | Allocated (MiB) | 84.972 | 80.833 | +4.87% | +4.87% |
| air3-none | Wall (ms) | 177.345 | 172.561 | +2.70% | +1.73% |
| air3-none | CPU (ms) | 176.883 | 170.077 | +3.85% | +1.71% |
| air3-none | Allocated (MiB) | 124.146 | 117.953 | +4.99% | +4.99% |
| air3-all | Wall (ms) | 194.469 | 180.172 | +7.35% | +5.85% |
| air3-all | CPU (ms) | 193.319 | 179.958 | +6.91% | +5.96% |
| air3-all | Allocated (MiB) | 144.162 | 137.969 | +4.30% | +4.30% |

Native-none process CPU is GC-influenced: A has stepping GC in 6/12 samples versus B 0/12, with 75.022 ms aggregate baseline GC wall time. A median CPU/wall are 123.662/96.445 ms; B 89.614/89.831 ms. Its 21.51% paired process-CPU reduction is whole prepared-run CPU, not a scientific-kernel speedup. Parallel GC/process-wide accounting is consistent with the excess, but the receipts cannot uniquely partition worker CPU. All 12 primary pairs remain in the tables.
Post-hoc no-GC subsets and the separate late native-none control are supplemental diagnostics; neither replaces or filters the primary 96 measurements.

## Supplemental native/no-history control

A separate eight-pair AB/BA control ran 16 additional fresh simulations with the same sources, runner, scientific checks, GC policy and thread settings. Paired stepping reductions were **1.69% wall, 1.61% process CPU and 6.20% allocated bytes**. Median wall times were 88.725 → 85.572 ms. Baseline stepping GC occurred in 2/8 runs; candidate GC occurred in none. All phases were compilation-free and all 27 final states matched. These measurements are supplemental; the original 96 measurements remain unchanged. Raw files and derived statistics are retained under `cpu-control/comparison/`.

## Fresh-complete secondary costs

Complete medians are calculated from per-sample sums, never sums of phase medians. Raw build and zero-step preparation phases remain in the receipts.

| Scenario / output | Metric | A median | B median | Median reduction | Paired reduction |
| --- | --- | --- | --- | --- | --- |
| native-none | Wall (ms) | 190.247 | 172.036 | +9.57% | +11.36% |
| native-none | CPU (ms; GC-influenced) | 290.984 | 171.567 | +41.04% | +40.36% |
| native-none | Allocated (MiB) | 217.733 | 213.667 | +1.87% | +1.87% |
| native-all | Wall (ms) | 219.054 | 222.054 | -1.37% | -0.76% |
| native-all | CPU (ms) | 219.121 | 222.121 | -1.37% | +0.13% |
| native-all | Allocated (MiB) | 253.043 | 248.976 | +1.61% | +1.61% |
| air3-none | Wall (ms) | 258.377 | 253.162 | +2.02% | +1.19% |
| air3-none | CPU (ms) | 258.203 | 253.250 | +1.92% | +1.12% |
| air3-none | Allocated (MiB) | 275.153 | 269.036 | +2.22% | +2.22% |
| air3-all | Wall (ms) | 313.953 | 306.955 | +2.23% | +1.28% |
| air3-all | CPU (ms) | 313.452 | 307.021 | +2.05% | +1.15% |
| air3-all | Allocated (MiB) | 312.234 | 306.113 | +1.96% | +1.96% |

## Scientific and engine qualification

All 96 simulations match 27 final object states exactly. History-enabled cases match all 87,464 native / 88,424 air3 rows. Air3 histories retain three iterations at each of 96 steps; no-history cases also verify final iteration counts.
The selected suite is not the full package suite. These assertion groups remain separate from scenario and checkpoint qualifications.

| Group | Records | Passes | Failures | Errors | Broken |
| --- | --- | --- | --- | --- | --- |
| core | 32 | 11894 | 0 | 0 | 0 |
| optional | 4 | 336 | 0 | 0 | 0 |
| quality | 2 | 11 | 0 | 0 | 0 |
| allocation_gates | 2 | 128 | 0 | 0 | 0 |

The initial opaque gate recorded 42 passes and 1 failure(s): Float64 unpublished opaque allocation was 560 bytes/1,024 calls versus typed 128 +64 allowed. Its original failed receipt and all raw samples remain unchanged in validation/final-results. The accepted collation uses one authorized unchanged 1,024-call three-repetition retry, passed 43/0, with the same source/environment/driver anchors and original allowance. The completed 1,024-call nine-repetition diagnostic has zero typed/opaque floors in all four comparisons. The optional 8,192-call diagnostic hit the documented Kaimon inactivity timeout; it remains incomplete, its timeout/partial artifacts are retained, and it is not qualification evidence. Diagnostics and initial failures are not added to accepted assertion totals; no budget was relaxed.

Raw allocation controls cover 7 bulk routes and 3 environment routes; typed/opaque controls retain 16 rows across Float32/Float64 and trial/published execution. Existing budgets, live values, kernel/sampler counts and measured compilation checks passed the independent audit.

Checkpoint qualifications are separate: populated caches at step 48 continue through original, serialize/restore and deepcopy branches without cache clearing or timing claims.

| Scenario | Exact branches | Populated midpoint snapshots | Final objects / retained rows |
| --- | --- | --- | --- |
| native | 3 | 41 | 27 / 87,464 |
| air3 | 3 | 42 | 27 / 88,424 |

## Source-qualified profiles

Separate 5 ms no-history CPU profiles retain 42 PSE and 193 MAESPA source hashes per arm/scenario; all match this phase's frozen source maps and source-check receipt.

| Scenario / arm | Repetitions | Selected samples | Generic type check | Generic construction |
| --- | --- | --- | --- | --- |
| native A | 30 | 570 | 39 / 6.84% (line 5781) | 16 / 2.81% (line 5785) |
| native B | 33 | 561 | 37 / 6.60% (line 5823) | 19 / 3.39% (line 5827) |
| air3 A | 18 | 550 | 46 / 8.36% (line 5781) | 25 / 4.55% (line 5785) |
| air3 B | 17 | 511 | 26 / 5.09% (line 5823) | 16 / 3.13% (line 5827) |

In the candidate canopy-air profile, live prepared environment sampling accounts for 8.22% of selected stacks as the nearest package site, Status reads from crown forcing for 6.07%, and Status reads from layout output checks for 3.52%. Nearest-package attribution is PSE 68.88%, MAESPA 28.77%, GC 1.96% and PlantMeteo 0.39%; this includes model-driven Status/backend access and is not an estimate of removable engine overhead. Generic call-view checks/construction remain visible.

These are nearest-package caller shares at retained generic sites, not causal time fractions or concrete-path hit rates. Different-type air3 overrides still use the generic path. Inlining can move attribution; profile shares do not establish speedup.

## Scope and evidence

The combined comparison cannot separate Status and snapshot contributions. Two fixed workloads do not establish a universal gain; desktop load is uncontrolled, and warm timings exclude cold compilation/code-growth costs. Runtime, allocation and whole-run results remain distinct.
A already includes previous metadata and runtime boxing repairs. Only the adjacent revisions above qualify this report. Full scenario references, equations, inputs, accepted iteration behavior and tolerances are unchanged.
Retain all raw measurements, balanced event ledger, archived environments, frozen assets, analyzer/audit outputs, profile .jls files, disjoint validation/control receipts and checkpoint files.
Evidence: Local evidence bundle pse-prepared-runtime-access, with source hashes, raw measurements, profiles, checkpoints and preserved rechecks
Comparison summary SHA-256: `7f3e893493a37ecb3fdfc766d4deb5e6bb4ea3483fb421acd567466b0de935bd`.
Validation summary (validation/accepted-results) SHA-256: `aebb13f5666f7cde83e447e9064444f886b5ff3a83fd3e4c11afead5ea745a46`.
Independent audit SHA-256: `ce3ed2c51e2687a26b7c0d18e7f6cd722f9d02655236b1a856b5e6cdcc576f64`.
Accepted collation manifest SHA-256: `c16c302fdf3484ee876e53cca9993d07acba6560ce8cafed7e41ee45ce7f22e9`.
