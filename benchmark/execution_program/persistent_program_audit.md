# Persistent typed-program source audit

Source-only review, 2026-11-01. No Julia was executed by this auditor. This note
describes admission and validation requirements, not a performance result. The
inspected checkouts are this worktree and the separate `d91b/PlantSimEngine`
worktree; their implementations must not be treated as the same source cohort.

## Why the existing program disappears after growth

`SelectedTightBatch` declares that it requires a full refresh
(`direct_plan_construction.jl:75`). Its capture hook first materializes the old
Shared program (`:186`), and its refresh hook replaces every selected batch with
retired ordinary batches before calling the ordinary refresh (`:190–214`).
`SharedProgramBatch` recursively materializes the old root and descendants
(`shared_call_program.jl:523–577`). `TightBatch` first seeds the previously
unobservable epoch/publication metadata, then delegates the same retirement
(`tight_call_program.jl:196–214,293–319`). This behavior is intentional: the old
public owners and saved call views retain the same semantics as ordinary PSE.

The core captures before logical/environment refresh, preserves the live
schedule, and also handles externally consumed lifecycle events
(`runtime_outputs.jl:5065–5099,7765–7773,8010–8146`). A persistent backend should
reuse these barriers. The smallest experiment is to retire the old representation,
let ordinary refresh finish, then lower the newly valid eligible groups again.
Preserve the returned schedule and complete the plan replacement transactionally.

## The public-exposure hazard

Re-admission cannot depend only on matching types, application slots or newly
valid call graphs. If a user previously accessed a real owner/CallTarget, core
refresh can reuse that owner. Private execution of a new program would then stop
updating the escaped owner's time and descendants. Correct retirement alone does
not solve this later divergence.

A conservative implementation must remember public exposure **before** internal
retirement disables the old leases, and keep those rows on the ordinary path for
the timeline. An alternative is to synchronize all reused exposed owners on every
typed entry; that has a different runtime cost and needs its own evidence. Internal
capture/retirement is not public exposure. Indexing a target facade is exposure;
reading its length or IDs can remain metadata-only.

## Admission after every event

- Re-evaluate the actual model/override, current canonical and local status
  references, input/call bindings, output streams and environment binding. A
  stable concrete type does not prove stable references or membership.
- Keep the existing Native + borrowed-Shared + private-Tight source capabilities
  for the entire reachable graph. Unknown/public-context kernels remain ordinary.
  Keep current exclusions for temporal/private/distributed ports, environment
  commits, initializer calls, Many hard calls, unresolved/empty singular calls,
  recursion and per-object environment providers. They are eligibility limits,
  not removed PSE features.
- Keep active evaluations and public publication/selection/environment overrides
  on the ordinary protocol. `evaluate_call!` / `accept_call!` depend on exact
  cache execution revisions, task/tree identity, lifecycle generation and compiled
  execution generation (`call_evaluations.jl:230–265`). Do not synthesize tokens or
  replay an accepted scientific kernel.
- Preserve application, cohort and row order. Mutable model RNGs and scientific
  side effects make cross-row/type sorting observable. Keep real no-inline child
  frames around exceptions; do not reintroduce the previously removed forced
  inlining through parent catches.
- Preserve first/unentered row epochs after an unhandled exception, and leave
  captured public descendants at their ordinary selected-lookup epoch. Updating
  all descendants eagerly on every parent entry was already shown incorrect.
- Cache environment handles and prepared schemas, never mutable sampled values.
  Re-sample fresh committed state and respect geometry/movement invalidation.
- Keep requested/temporal stream retention, newborn initial stream setup and
  removed-object histories. The externally consumed-event recovery branch is
  especially important for `outputs=:all` and later output requests.

## Small useful ports from d91b

1. **Per-application typed region regrouping.**
   `declared_execution.jl:205–227` reuses a region only if its actual source batches
   remain identical, otherwise updates typed vectors while retaining order.
   `legacy_execution_partitions.jl:29–48` uses a bounded number of concrete batch
   types and an explicit order vector; it preserves ordinary sampling partitions.
   This is useful for general ordinary-context kernels without rewriting calls.
2. **A bounded runtime frame.** `declared_execution.jl:307–375` keeps scene-wide
   metadata out of numerical signatures, resolves runtime handles at an
   application barrier and still invokes the original temporal materialization,
   environment sampling, scientific kernel and publication operations. Copy the
   principle and adapt current APIs; copying its target/context layout wholesale
   would couple unrelated changes.
3. **Object-free extraction recipes with live references.**
   `execution_policy.jl:124–159` separates port names from each object's current
   references. This worktree already has the compatible projected Status backing
   and identity mechanism (`direct_calls.jl:389–411`, `Status.jl:57–111`), so no
   replacement Status container is needed. Do not import d91b's schema-value cache
   without current model/override/world/epoch invalidation proofs.

The descriptive physical-access IR, global declared policy, fusion, call-binding
wrapper types and alternate Status-field hierarchy are unnecessary for the first
persistent Tight experiment. In particular, d91b fusion checks dirty state between
applications (`declared_execution.jl:249–253`); a larger monolith must retain that
barrier rather than merely concatenate kernels.

## Four independent arms and positive coverage

| Arm | Preparation | Scientific execution |
|---|---|---|
| ordinary | ordinary | ordinary canonical references/executor |
| prep-only | bounded metadata + graph projection + typed output preparation | ordinary |
| typed-only | ordinary | persistent selected Tight where eligible; ordinary elsewhere |
| combined | same prep-only policies | same persistent typed backend |

All arms must load the same definition cohort; no native storage, trusted-index or
consumer-sequence policies are implicitly enabled. Include enabling/lowering and
refresh work in preparation/complete cost. Use fresh instances and exact forcing,
scientific model RNGs, state/history/types, topology, canonical Ref identity
transitions and side-effect order. Warm timing and fresh-process compilation are
separate experiments.

Prepared counters are insufficient. A diagnostic companion should record actual
typed entry counts at each compiled/environment epoch, executed object IDs and
post-event root/child entries. Require a newborn ID to execute in a typed batch
after ordinary growth, and an unchanged eligible region to execute after refresh.
When an exposed or unsupported row falls back, require that fallback and zero
private execution credit for that row. Do not infer newborn work from a pool size
or cumulative initial counters.

## Cheap gates before downstream timing

1. Generic two-root/singular-child graph, Float32 and one generic numeric case:
   ordinary creator adds one object before the numeric group, then removes one.
   Compare per-step full state/history, actual RNG calls, original ordering,
   canonical Ref transitions and positive post-birth typed entries.
2. Save a root owner and nested singular target before growth; compare saved and
   current context/time/publication/call views after another step and refresh.
   Test both normal refresh and externally consumed logical/environment refresh.
   The exposed row must stay ordinary if using the denylist design.
3. Reuse the existing nested-caught-throw and unhandled-middle-row exception
   fixtures, plus retained One/Many/evaluation/publication fallback fixtures.
   Recheck schemas, override/rebinding, mixed cadence and spatial movement on
   the ordinary fallback; no large full-suite run is needed for the first gate.
4. PB: start with the unchanged two-object/two-step original Monteith/Fvcb/Medlyn
   fixture, then add one same-schema scientific object through a separate ordinary
   controller or public lifecycle operation. No leaf-specific compiler rule.
5. XP: the six hash-attested original call-free numerical kernels in
   `persistent_xp_source_audit.jl` provide a narrow meaningful start. Leaf and
   internode biomass and accumulated thermal time apply to actual newborn organs.
   Growth, pruning, public-context and distributed controllers stay ordinary.
   Start at two days, require actual post-birth execution of admitted kernels, then
   a four-day warm screen only if preparation/complete cost is plausible.

The generic fixture traces original scientific effects using `constants.tick[]`;
it no longer observes context time or representation. Source capabilities still
require an audit: arbitrary context-unused Julia methods can mutate topology
through globals or scientific references.

## Initial persistent source review

The first `persistent_tight_program.jl` source was reviewed at SHA256
`7c55e6f701d64de7a42579ef952ad7f0712674cacb9162d74a08e49dc43beabe`.
It implements a conservative application-wide exposure denylist before internal
retirement, delegates ordinary bookkeeping, and checks exact live models,
references, binding signatures, environment handles, outputs and root ID order
before rebasing. New admission uses strict world-sensitive declaration effect and
return-type proofs rather than evaluating optional declarations for eligibility.

One concrete issue was reported before execution: the first version installed
wrapper batches under `performance=true` even though core's profiled batch method
accepts only `CompiledExecutionBatch`. This is **resolved in reviewed SHA256
`2fef521420d026a4eab72c14e0e38776b6a2760dc1bc0ca2825c7384cbae85a1`**:
lowering now leaves the whole ordinary plan untouched when instrumentation is
active and reports `:ordinary_profiled_executor`, with zero typed work. The
revised traversal visits only the exact reachable singular targets and caches
completed target proofs transiently within the admission pass.

`_pure_declaration!` passes only function/type information to `Base.infer_effects`
and `Base.promote_op`; it does not call the declaration on a live model. Eligibility
requires consistent/effect-free unconditional proofs, no-throw behavior and a
concrete NamedTuple result. Unknown/conditional effects and unresolved shapes
therefore remain ordinary. No declaration values, bindings, Status or RNG state
are memoized by this proof cache; its keys include the Julia world counter.

The safe API contract also requires installing immediately after zero-step
preparation, before any public ordinary owner has been inspected; the ordinary
plan has no prior exposure tracker to recover that information.

`regions_reused` means the outer wrapper and scientific columns survive. The first
implementation still allocates a new Tight frame tree during metadata rebasing;
stable entry signatures are not a measured MethodInstance/cache-hit assertion.
A completely empty plan has no wrapper sentinel, so later births can fall back to
ordinary execution instead of regaining typed eligibility. Both limits should
remain explicit in any result.

`persistent_feature_checks.jl` adds independent tiny gates using existing trusted
fixtures: original nested catch/retry and partial failure, saved singular views
after externally consumed refresh, accepted/stale evaluations, backend overrides,
fresh mutable environments and retained Many membership. Each is separately
callable; no large automatic matrix was added. Source review is complete for this
first version; root-executed Kaimon gates and any follow-up fixes remain pending.
No persistent performance or feature-preservation result is claimed here.

## Conditional call metadata: additional required fix

Root's new public-exposure gate found an actual mismatch: a never-executed child
owner was initialized with `publication_allowed=false`, while ordinary execution
kept it true. Uniformly seeding every child from the parent's last execution also
cannot preserve skipped or lookup-only branches. This blocks a general preserved
call-metadata claim until fixed and tested; changing one publication default alone
is insufficient.

The minimal trace has separate **node execution** and **edge selection** epochs.
Untouched owner contexts begin at time zero with publication allowed. Root entry
records its current epoch; child entry records its actual epoch and unpublished
permission before the kernel can throw. A `run_call!` selection first updates the
selected edge using the parent's epoch/permission. `call_model` also selects that
edge through ordinary `_find_call_targets`, but does not execute the child. An
unqueried edge and an unentered child keep their previous independent metadata.
Cold materialization must reconstruct both sets of metadata; refresh must carry
them by actual graph node/object, not broadcast the parent's last time.

The added `persistent_conditional_epoch_checks` gate uses original generic kernels
with different per-row first-lookup/first-call steps, nested skips and one newborn.
`inspect_step=0/1/2/3` selects one tiny case. The later cases keep the program
private across growth and externally consumed refresh before inspection. The
observer reads real cached collections and raw owner contexts **before** invoking
public lookup that could normalize a bad epoch. It compares exact ordinary
metadata as well as science, history, side-effect order and actual private work.
There is no automatic matrix or timing claim.

The reviewed `99da730e88ed947133044546abe230dd95901ceb64371dadeb1da0aa436d3156`
version records node and edge epochs separately. Its runtime-change flag uses the
same compiled/environment identity test as ordinary context preparation. Root
reported all four initial conditional prefixes passing, but the independent
`late_unqueried=true, inspect_step=2` extension found a further real mismatch:
after exposure, the first middle entry left its unselected worker edge at
`(0,true)` while ordinary execution advanced that edge to `(3,false)`.

The surviving node had not yet entered the new runtime epoch. Reconstructing its
context with current compiled/environment headers erased the pending mismatch;
normal ordinary entry therefore skipped the all-edge synchronization it should
perform. The fix must retain the exact old context headers until actual entry,
not only copy time/publication or a diagnostic Boolean. Unqueried edge headers
should likewise come from the ordinary template. The test remains frozen for the
fix qualification; no late-case pass is claimed here.

The subsequent reviewed source
`2e2232708a0c4e9fc9f73d9f8026abf0b0db0dd3e8fa15b6da8684b0139b45dd`
addresses this in its implementation. Seeds now retain the exact ordinary node
and edge runtime headers. Cold owner construction restores those headers after
materialization, retaining the old identity mismatch for a pending transition.
Actual private entry updates headers and all immediate edges only when that
transition is due; selected lookup still updates only its edge. These helpers do
not execute science, sample environments or draw randomness. Qualification of
the formerly failing late case remains a required root-executed gate.

That version also addresses the homogeneous root lookup scalability concern:
`_epoch_seeds` builds one application/object identity index per pass instead of
rescanning every group target for every root row. Child owners remain local to
their caller's cache and call path. All indexing, seed/header allocation, ordinary
preparation, retirement and reconstruction costs remain part of the prototype
comparison. Mutable header updates avoid rebuilding header tuples at every
entry; actual allocation measurements must establish their cost.
