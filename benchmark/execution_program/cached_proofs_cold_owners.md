# Cached declaration proofs and retained cold owners

The two mechanisms improve parts of the persistent typed prototype, but
**preparation-only remains the preferred performance candidate** in these small
PB/XP screens. The ordinary executor remains the default. All changes are in
benchmark prototypes; production `src/` and `ext/` match `f5894794b` exactly.

## Implementations and comparison

- `CachedDeclarationProofs` shares bounded, locked admission proofs across
  independent preparations. Keys contain the declaration function, argument
  type and Julia method world. Positive and negative Boolean proofs are cached;
  method-world changes expire the table. The original unconditional consistency,
  effect-freedom, nonthrowing and concrete `NamedTuple` guards remain. No live
  declaration is evaluated by this admission check, and defaults, parameters,
  memberships and scientific values are never cached.
- `ColdOwnerProgram` retains the actual ordinary owners already constructed
  during preparation and refresh. At capture/exposure it restores tracked node
  and edge metadata into those same owners, including pending old runtime
  headers and distinct per-call-site descendants. It avoids Shared fallback
  reconstruction, while retaining the ordinary owner graph in memory.
- The original Selected numerical row loop, Tight child exception boundary,
  scientific kernels, reference storage and ordinary bookkeeping remain.
  Unsupported protocols use ordinary execution; public exposure permanently
  declines the exposed application for that timeline.

The seven arms are ordinary A/A, preparation-only, and four typed arms on the
same bounded + graph + typed-output preparation foundation: repaired persistent
baseline, proof-only, owner-only and combined. Organ IDs and population sizes
remain runtime data. The optimization is independent of organ names or scales.

## Preservation before timing

The new first-timestep partial-error check found a real defect in the prior
persistent baseline: ordinary batch preparation synchronized metadata for a row
whose kernel was subsequently left unentered by an earlier exception. The
prototype had retained time zero for that row. Owner reuse passed this case.
The shared persistent baseline now tracks ordinary batch synchronization state
and mirrors its metadata preparation before numerical rows. The original failed
matrix and pre-repair source remain archived. All timing controls use the repair.

Final qualification contains **3,012 assertions**: 2,836 initial assertions and
176 four-step downstream assertions. It covers:

- Strict proof caching, negative results, same-type/different parameter values,
  capacity, concurrent requests, method replacement and unknown capabilities.
- Float32/Float64, retained and unretained outputs, live reference identity,
  exact state/history/RNG/effects, birth/removal and targetless admission.
- Saved targets, independent original root/child owner identities, selective
  calls, unentered descendants and pending headers across consumed refresh.
- First- and second-timestep partial errors, retry rejection parity, and ordinary
  evaluate/accept, stale-token and transient-backend fallback.
- Original two-step and four-step PB/XP runs for all four typed arms. Actual
  newborn IDs execute typed kernels at the current compiled revision.

These are bounded feature gates, not full-feature or million-organ qualification.
Arbitrary environment-sampling exception metadata remains an explicit gap.
The audited six XP model families are unchanged; growth and other unaudited
models retain ordinary execution. XP uses one original palm, architecture=false,
initiation age zero and accelerated phyllochron values 0.2. Four days grow 8 to
20 actual objects; application width stays fixed at 61.

## Small warm measurements

Kaimon worker 25262, Julia 1.13.1, 14 available threads, serial model kernels.
Each screen uses two balanced forward/reverse cycles with fresh independent
scenarios and pre-sample GC. All phases are charged: construction (including XP
weather IO), ordinary zero-step preparation, additional typed lowering and
execution. Common definition loading, source audits and fingerprints are outside
phase clocks. Each proof arm has an independent cache populated in its untimed
warmup; the initial population counters remain in that warmup record.

Five source/forcing-guarded screens have healthy whole-RPC CPU monitoring:
PB two objects × two steps, XP two days, PB 16 × eight, XP four days, and one PB
16 × eight repeat. The first PB 16 screen recorded 0.120 ms preparation JIT in
one ordinary sample and 0.168 ms lowering JIT in one persistent sample. This
triggered the repeat; both full screens remain archived. The repeat and XP
four-day samples report zero JIT, recompilation and GC in timed phases.

### PB, 16 objects × eight steps, repeat

Medians in milliseconds; ratios are medians of paired complete costs.

| Arm | Preparation | Lowering | Execution | Complete | / ordinary A | / persistent |
|---|---:|---:|---:|---:|---:|---:|
| Ordinary A | 2.226 | 0.004 | 0.136 | 2.637 | 1.000 | 0.636 |
| Ordinary B | 2.119 | 0.004 | 0.131 | 2.499 | 0.947 | 0.603 |
| Preparation only | 1.796 | 0.003 | 0.132 | 2.167 | 0.824 | 0.521 |
| Persistent | 1.803 | 1.982 | 0.121 | 4.153 | 1.577 | 1.000 |
| Proof only | 1.806 | 1.633 | 0.121 | 3.832 | 1.453 | 0.923 |
| Owner only | 1.883 | 2.060 | 0.125 | 4.326 | 1.641 | 1.043 |
| Combined | 1.771 | 1.558 | 0.124 | 3.702 | 1.407 | 0.890 |

Proof-only reduces lowering by about 18% here; combined reduces it about 21%.
The tiny PB screen showed roughly 43–47%, demonstrating that the relative
benefit shrinks as other per-organ lowering work grows. Complete combined cost
falls about 11% versus persistent, but is about 71% higher than preparation-only.
No refresh occurs, so this PB screen exercises no cold synchronization and
cannot establish an owner-reuse benefit. The first 16-object screen had complete
costs 4.463 ms persistent and 3.808 ms combined; it supports the same overall
decision, with the recorded compiler activity and normal screen variability.

### XP, four accelerated days

| Arm | Preparation | Lowering | Execution | Complete | / ordinary A | / persistent |
|---|---:|---:|---:|---:|---:|---:|
| Ordinary A | 17.148 | 0.009 | 15.101 | 36.151 | 1.000 | 0.932 |
| Ordinary B | 17.467 | 0.005 | 15.649 | 37.618 | 1.040 | 0.970 |
| Preparation only | 11.837 | 0.006 | 13.653 | 29.465 | 0.815 | 0.759 |
| Persistent | 12.445 | 2.289 | 20.084 | 38.817 | 1.074 | 1.000 |
| Proof only | 12.395 | 1.207 | 19.408 | 36.934 | 1.022 | 0.951 |
| Owner only | 11.960 | 2.101 | 17.461 | 35.520 | 0.983 | 0.915 |
| Combined | 11.880 | 1.192 | 18.859 | 36.157 | 1.000 | 0.932 |

Cached proofs reduce lowering by about 47–48%. Owner-only reduces execution
about 13% and complete cost about 8.5% versus persistent. Combined lowers complete
cost about 6.8% versus persistent and remains about 23% above preparation-only.
The two-day screen likewise showed useful phase savings without beating
preparation-only. Two cycles do not establish the interaction between mechanisms:
combined execution is slower than owner-only here, despite cheaper lowering.
Owner-only's small complete advantage over ordinary A is within the A/A spread.

Every measured cache scene has zero compiler queries and zero world invalidations:
192 actual proof hits per PB 16 scene and 368 per XP four-day scene. XP typed arms
execute 32 selected batches, with four refreshes, eight region reuses and 24
readmissions. Owner arms perform 32 cold synchronizations and restore 68 node
headers, with zero Shared fallback materializations. These audited XP regions
have no child call edges; nested cold-call preservation is tested independently
in the generic gates. The owner report counts 119 current ordinary scheduled
owners across all applications, rather than confusing cumulative setup with
current storage.

## Allocations, retained memory and compilation

| Workload / arm | Complete allocated MB | Reachable simulation/program/fixture bytes |
|---|---:|---:|
| PB ordinary A | 1.746 | 188,873 |
| PB preparation only | 1.342 | 196,441 |
| PB persistent | 5.771 | 192,097 |
| PB proof only | 5.476 | 192,521 |
| PB owner only | 5.794 | 267,593 |
| PB combined | 5.498 | 268,017 |
| XP ordinary A | 24.668 | 826,313 |
| XP preparation only | 12.506 | 868,273 |
| XP persistent | 16.589 | 881,257 |
| XP proof only | 15.899 | 881,681 |
| XP owner only | 16.002 | 918,057 |
| XP combined | 15.312 | 918,481 |

Reachable sizes are collected outside clocks, include shared scientific graph
data and reachable cache metadata, and exclude unrelated global roots. They are
neither exclusive owner storage nor process RSS. Owner retention increases this
size about 39% in PB and 4% in XP versus persistent. Fewer allocations do not
imply a smaller retained graph. Reported RSS is the process lifetime high-water
mark, with no per-case peak claim.

This round measures reuse of compiler-derived proofs in a warm Julia process.
It establishes fewer admission queries and lower lowering cost, not a new cold
compilation speedup. No expensive new cold-process matrix was run.

## Decision and next bounded experiment

Keep both mechanisms opt-in. Proof caching is useful for repeated installation;
owner reuse removes a measurable part of XP growth overhead with a memory tradeoff.
Both retain full ordinary preparation, ordinary lifecycle bookkeeping, changed
region re-lowering and new metadata shells, explaining the remaining work in
this prototype. The current results do not justify default adoption or a large
downstream benchmark campaign.

The next focused hypothesis is to retain the existing per-record proof cache as
a first level, using the shared cache only for misses. That could avoid repeated
locking/report updates during growth; it is untested here. Delta updates for
affected memberships/rows remain the larger subsequent candidate. Neither
proposal is credited as a measured improvement.

## Reproduction and evidence

In a Kaimon session for this worktree, load
`benchmark/native_downstream/load_cached_owner_experiment.jl`. Use
`CachedOwnerChecks` and `CachedOwnerMeasurements` for the gates and seven-arm
screens. `CachedDeclarationProofs.DeclarationProofCache()` is explicitly passed
as `declaration_policy` to persistent lowering or `proof_cache` to cold-owner
lowering. All original science and forcing are hash-pinned in the archive.

The immutable [evidence directory](evidence/cached-proofs-owner-reuse) contains
691 checksum-verified records (about 4.33 MB stored): qualified source snapshots,
scientific source/forcing blobs, raw successes and failures, scripts, Kaimon
receipts, CPU records, a manifest and the machine-derived summary. The Python
validator is `summarize_cached_owner.py`; it checks policies, fingerprints, actual
work, phase sums, cache/owner counters, balanced order and source/CPU bindings.
See [cached_owner_audit.md](cached_owner_audit.md) for semantic boundaries.
