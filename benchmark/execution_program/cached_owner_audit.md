# Cached declaration proofs and cold-owner reuse: qualification boundaries

This experiment changes admission and fallback preparation, while retaining the
original scientific kernels, canonical reference storage, and ordinary PSE
bookkeeping. The ordinary executor remains the feature oracle and the default.

## Independent factors

`CachedOwnerMeasurements.ARMS` contains ordinary A/A, preparation-only, and a
2×2 comparison on the same preparation foundation:

| Arm | Persistent typed execution | Shared declaration proof cache | Retained ordinary owners |
|---|---|---|---|
| `ordinary_a`, `ordinary_b` | no | no | ordinary executor |
| `preparation_only` | no | no | ordinary executor |
| `persistent` | yes | no | reconstructed at fallback/capture |
| `proof_only` | yes | yes | reconstructed at fallback/capture |
| `owner_only` | yes | no | original owners |
| `combined` | yes | yes | original owners |

All four typed arms enable bounded preparation, graph-row projection and typed
output preparation. This cohort must not be pooled with earlier typed-only or
cold-process measurements. Every simulation is constructed independently.

## Declaration proof boundary

Only compiler-derived acceptance booleans belong in the shared table. A key is
the singleton declaration function, its argument type and the Julia method
world. A cache hit must not evaluate a declaration or store a declaration's
returned values. Model parameters remain live scientific data even when their
types are unchanged. The existing unconditional consistency, effect freedom,
nonthrowing and concrete `NamedTuple` return checks remain necessary.

Positive and negative entries, type/function separation, finite capacity,
concurrent queries and method-world invalidation need explicit checks. The
`CachedDeclarationProofChecks` kernels include a real side-effect counter;
static report fields such as `live_declaration_calls=0` alone are not evidence
that a declaration was never evaluated. Unknown numerical capabilities must be
rejected before compiler queries. Cache counters are recorded before lowering
and after execution, including world invalidation and repeated compiler work.

Each timed cache arm owns a separate cache of equal capacity. The ordinary
controls have no cache hook. The screen primes all arms outside sample timers;
its warmup records retain the initial cache population cost. These timings do
not estimate a new Julia process or a cold compiler cache. A world change
between RPC calls can legitimately invalidate a previous warm population.

## Owner and lifecycle boundary

Retaining an ordinary owner retains its context, per-call-site descendants,
live references and public collections. Two hard-call sites targeting the same
application/object may still own distinct contexts; they cannot be merged by
callee identity. Retaining owners also retains memory. A faster capture does
not establish a memory improvement at millions of organs.

Cold synchronization must distinguish node entry from edge lookup. Looking up
a call's model can update one edge without entering the child. A child skipped
before a refresh must retain its old compiled/environment identity until its
ordinary entry performs the pending synchronization of every immediate edge.
Copying only time/publication fields, or normalizing every cold header to the
latest plan, loses this behavior.

`CachedOwnerChecks.cached_owner_epoch_checks` compares raw node/edge epochs and
relative header identity before public lookup could normalize them. Its default
case exposes after two private steps, with a middle context unentered across a
consumed refresh and its worker edge unqueried. Public exposure permanently
declines the exposed application, and saved collections/targets keep matching
ordinary behavior through later growth. First-tick and second-tick partial
errors are separate cases: ordinary batch preparation may synchronize metadata
for rows whose scientific kernels have not entered. A diagnostic matrix keeps
every arm's failure rather than stopping after a failing baseline.

Generic lifecycle checks cover `Float32`/`Float64`, reference identity, exact
state/history/RNG, births and removals. Targetless admission and unsupported
evaluate/accept or transient backend protocols are available as separate small
gates. PB/XP checks require exact original scientific state/history/RNG and
identity transitions after every step. XP newborn credit comes from actual
executed numerical IDs at the current compiled revision. A prepared row or a
cumulative pre-growth entry count is insufficient.

These bounded gates are not a claim that every PSE feature or arbitrary
environment-sampling exception has been qualified. Unsupported paths must
remain ordinary, and new preservation failures must be retained as evidence.

## Timing and memory interpretation

The measurement harness separately charges construction, ordinary zero-step
PSE preparation, additional backend lowering, and execution. Compiler time,
recompilation, allocation and GC are separate phase fields. Cache-report
snapshots are charged to lowering. Source audits and final fingerprints run
outside phase timers. Warm samples use balanced forward/reverse ordering and
an ordinary A/A control.

Use source/forcing hashes before and after each screen and local CPU monitoring
to qualify the source cohort and contention. Do not edit Julia sources while a
screen runs. A saved negative or contended attempt cannot be retroactively
relabeled as a qualified measurement.

`screen_cached_owner(...; measure_retained=true)` records reachable object sizes
after clocks stop. Its `Base.summarysize` values include retained owners reachable
from the simulation/program/fixture, and should be reported separately from
cumulative allocations. The reported RSS is the process lifetime high-water
mark; it is neither a per-case peak nor a reachable-object size.
