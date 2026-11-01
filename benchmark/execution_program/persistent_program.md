# Persistent typed execution across lifecycle refresh

This opt-in experiment keeps the existing Shared/Tight/DirectPlanConstruction
scientific backend eligible after same-schema organ birth and removal. The
bounded preparation, graph-row projection and typed output preparation modules
are unchanged. Production `src/` and the default executor are unchanged.

The backend retires old owners before logical refresh, uses ordinary refresh as
the bookkeeping oracle, and admits current eligible regions again. An unaffected
region keeps its wrapper and scientific columns while metadata headers and Tight
frames are rebound. Current targets, references, models, call graphs, environment
handles and output streams must match before reuse. Public exposure permanently
keeps the application ordinary for that timeline. Unsupported protocols retain
ordinary execution; profiled execution explicitly retains the whole ordinary plan.

A first preservation gate exposed incorrect old lazy metadata: descendants that
had not run were synthesized with their parent's time and unpublished flag. The
new prototype tracks each node's real invocation and each call edge's lookup
separately. This preserves skipped children, model-only lookups, nested calls and
partial failure without changing the scientific equations or the existing
`noinline` child boundary. Declaration admission uses strict type/effect inference;
unknown declarations are not evaluated speculatively.

## Initial correctness evidence

Kaimon worker 13886, Julia 1.13.1, this worktree, ordinary canonical references.
At backend SHA `99da730e88ed947133044546abe230dd95901ceb64371dadeb1da0aa436d3156`:

- 1,118 assertions pass across generic lifecycle, Float32/Float64, exact
  state/history/RNG/effects/reference identity, unchanged region identity and
  numerical entry types, saved public targets, unknown status layouts, retained
  calls, conditional lookup/execution prefixes and original nested exceptions.
- Two extra assertions check explicit ordinary profiled fallback.
- Original PB (two objects, two steps): 34 assertions pass for preparation-only,
  typed-only and combined. Each typed arm enters two root batches, four numerical
  roots and 24 original child calls.
- Original accelerated XP (two days): 38 assertions pass for those three arms.
  Growth creates three objects per step; both typed arms actually execute the
  original audited kernels on two newborn objects at each new compiled epoch.
  This is measured path coverage, not credit inferred from prepared pools.

The six XP model families use the existing private-context capability contracts,
with exact inspected source hashes and concrete pilot numeric types. All ports,
selectors, coupling, clocks and ownership still come from ordinary declarations.
Growth, pruning, public-context, distributed, temporal and other unsupported
boundaries continue through ordinary execution. This is a narrow audited pilot,
not an automatic eligibility proof for arbitrary context-unused Julia code.

At final backend SHA `2e2232708a0c4e9fc9f73d9f8026abf0b0db0dd3e8fa15b6da8684b0139b45dd`,
all 1,291 generic and fallback assertions pass, including a delayed-child
header-handoff regression, evaluation/acceptance, Many, fresh mutable environment
sampling, partial-error parity and initially targetless newborn execution. Two
profile assertions also pass. Final PB/XP repeats add 72 assertions; a modest
four-step gate adds 88. Warm timing is still being qualified. One initial extra test incorrectly assumed ordinary PSE
allows retry after an unhandled timestep error. The ordinary schedule rejects
that retry too; the oracle now compares both outcomes rather than changing core
semantics. Early failures remain in raw diagnostics.

## Measurement and scope

Four policies are implemented, with an extra identical ordinary A/A label:
ordinary, improved preparation only, persistent typed only, and combined.
Logical preparation builds its ordinary plan first; typed installation is charged
separately as backend lowering. Conservative owner materialization, ordinary
refresh, re-lowering and metadata work are all charged in execution/complete cost.
No performance conclusion is established by the correctness counters.

Current limits include new Tight-frame allocation during metadata rebasing,
whole-owner capture before refresh, installation before public inspection of the
ordinary zero-step plan, and the need for at least one live scheduled sentinel
batch to readmit a previously targetless application. A completely empty initial
plan keeps ordinary behavior after later external additions. This does not claim
zero JIT, millions of organs, a full feature-matrix qualification, or a production
adoption. Earlier preparation-only scaling/cold evidence remains separate in
[preparation_scaling.md](preparation_scaling.md).
