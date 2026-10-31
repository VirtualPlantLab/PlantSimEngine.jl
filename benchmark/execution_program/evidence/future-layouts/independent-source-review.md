# Future-layout prototype: source-only safety and claim review

Reviewed the current `future_layouts.jl`, `future_layout_fixtures.jl`,
`future_status_checks.jl`, `future_layout_checks.jl`, and
`future_layout_measurements.jl` in the prototype checkout. I also checked the
call-signature collector against the ordinary runtime signatures; I authored
that collector, so that part is a self-review. No Julia execution or timing is
credited by this review. Frozen Julia sources were not edited.

## Decision for the small generic gate

No source-level blocker remains for the supplied one-archetype generic fixture.
The builder captures a seed, creates independent status/model/backend/RNG
objects, and never evaluates a scientific kernel. The current status collector
prioritizes initially targetless applications. Root already corrected the
keyword-argument `@nospecialize` load error; the two remaining call-module
annotations now name positional arguments only.

## Safety and coverage boundaries

1. **Independence is a contract plus a Julia object-identity check, not a purity
   proof.** The wrapper snapshots the reachable mutable graph of the live model
   and constants, then rejects shared mutable identities before and after
   disposable zero-step preparation (`future_layouts.jl:57-100, 210-232`). It
   restores the caller TaskLocalRNG in `finally` and does not retain scientific
   instances in its catalog. These are appropriate for the supplied fixture.
   A malicious or erroneous builder could mutate a captured live `Ref` before
   returning an independent model; epoch/revision checks do not detect a plain
   status/parameter/constants write. Opaque foreign buffers/pointers and skipped
   Task/IO/custom-string state also exceed the identity check's scope. Do not
   describe this as proof of arbitrary builder purity or foreign-state isolation.
   A useful next negative gate is a fresh returned model sharing a live backend
   or canonical `Ref`; a separate test should document/reject a builder that
   writes live state without retaining an alias.

2. **Current mutation guards are deliberately narrow.** Generic measurement
   guards check kernel counters, environment sample counts, copied scientific
   RNG fingerprints and caller TaskLocalRNG. They do not fingerprint every live
   status, constant, model parameter or backend bind counter
   (`future_layout_fixtures.jl:163-168`). The status-only gate's full before/after
   scientific snapshot supplies stronger evidence for that fixture. Future PB/XP
   gates should compare full state/history/topology and scientific RNG after
   execution, and check live status/constant identity where applicable. Generated
   function/compiler purity remains an assumption of type-only compilation;
   `Base.precompile` is not a general sandbox for arbitrary compile-time effects.

3. **Budget accounting is honest, but multi-archetype selection is ordered.**
   Builder, constant copy, ownership traversal, disposable preparation,
   collection and actual precompile attempts are charged upfront. The remaining
   global call budget is decremented by actual attempt deltas. Within one call
   catalog, initially targetless kernels/batches take priority, including late
   manual children. Across several archetypes, however, the first catalog can
   consume the remaining budget before later archetypes are considered
   (`future_layouts.jl:250-265`); status requests have the same encounter-order
   effect across archetypes. Report coverage per archetype and skipped requests;
   do not infer complete future coverage from a positive aggregate counter.
   Global signature merging/prioritization would be a later refinement.

4. **Type coverage is distinct from compilation reuse.** Explicit environment
   types avoid sampling and frozen environment rows. Actual fixture-owned kernel
   observations verify post-birth worker/child model/status/environment/constants/
   context entry types, independently of merely preparing another scene. Exact
   type matches and `Base.precompile == true` do not establish MethodInstance
   reuse, no invalidation, code-cache hits, or a runtime win. Inline kernels may
   still be compiled in callers; including batch and scheduler entry signatures
   is sensible, but their future-scene types may differ from the live post-growth
   types. The current reports correctly state this distinction.

5. **Ordinary execution preserves unrepresented cases; it does not prove broad
   precompile coverage.** The catalog installs no runtime data or replacement
   executor. Undeclared schemas, overrides, cadence/membership changes, public
   calls, trial environment overrides, and partial newborn initializer paths
   continue through ordinary execution. The call collector reports partial
   initializer gaps explicitly. The wrapper currently supplies model-facing
   environment types only, not the collector's optional context-environment
   override declarations. State that these are coverage limits rather than
   optimized/validated feature claims.

## Measurement interpretation

The four-arm harness uses independent fixture construction, explicit Any-backed
orchestration and invocation barriers, staged receipts, and defers snapshots/type
matching until after timed execution. Normal preparation, future preparation,
first growth and remaining execution are separate; their sum includes all
prototype upfront work. Fresh-process attestation and one case per worker prevent
the previous four-Simulation inference cross-product. Disk/package caches and
module loading remain outside the measured case and should be stated when
reporting cold results. Post-timing type descriptions still stringify full types
before truncation (`future_layouts.jl:275-278`), so keep those diagnostics small.

A lower first-growth latency can be useful even when total time rises. Report
both, with allocations/compilation components and matched/unmatched future
families. No performance claim follows from this source review alone. PB/XP
fixture and measurement review remains pending their completed source.

## Downstream source addendum

The completed PB/XP fixture and correctness-companion source was subsequently
reviewed. `_global_row_types` reads the stored first row of these fixed global
forcing fixtures after ordinary DataFrame-to-NamedTuple preparation. It invokes
neither the environment backend sampler nor a model kernel; this is appropriate
for these fixtures, not a general promise for arbitrary custom providers.
PB's controller only registers the declared generic gas-exchange objects; all
numerical work remains in the original PB methods. XP's future builder creates
a fresh ordinary XP scene and directly adds a Phytomer, Internode and Leaf with
the same public status adapter/initial-field order as PhytomerEmission. It does
not run the emission, initializer, call, sex or architecture kernels. Its finite
declaration intentionally omits Male/Female future organs and transient targeted
call contexts. Scientific methods are not wrapped for coverage claims.

Current measurement source additionally guards identity of every live canonical
Status and its reference cells around the future phase. Current RNG restoration
preserves both TaskLocalRNG state and the separate task-local seed changed by
`Random.seed!`. These strengthen the original guards; neither identity equality
nor epoch equality detects arbitrary writes to the contents of an existing Ref,
so the builder-purity scope above still applies. Downstream companions compare
full scientific/history/topology snapshots, numeric types and copied scientific
RNG draws against ordinary execution and retain ordinary public lifecycle paths.
