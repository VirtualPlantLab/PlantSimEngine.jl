# Newborn logical-binding promotion: initial findings

The prototype reuses real newborn binding work, but the initial four-day XPalm
screen is slower than ordinary execution, both alone and combined with the
incremental reference driver. These results support further work on lifecycle
refresh; they do not qualify this implementation as a runtime improvement.

## Measured work and cost

The reference-storage fixture uses the original scientific models, seed 1,
identical forcing, accelerated emission 0.2 and four simulation days. Three warm
cycles alternate arm order; each sample constructs a fresh scene. Correctness
gates retain all outputs, while this timing screen requests `outputs=:none`.

| Arm | Paired execution ratio | Paired complete-run ratio | Median execution allocations |
|---|---:|---:|---:|
| Ordinary executor | 1.000 | 1.000 | 12.203 MB |
| Newborn promotion | 1.085 | 1.042 | 12.888 MB |
| Incremental reference driver | 1.778 | 1.434 | 12.170 MB |
| Both | 1.815 | 1.465 | 12.855 MB |

Ratios are medians of within-cycle ratios, rather than ratios of independently
computed medians. Ordinary median execution is 13.699 ms and complete time is
30.150 ms. Complete time includes construction, PSE preparation, additional
lowering and execution. This is a small warm screen, without a cold-compilation
claim. No sixteen-day expansion was performed after these negative results.

Promotion captures 28 application/object records containing 20 actual bindings,
then promotes all 20 bindings at the ordinary lifecycle barrier. Across 104
promotion attempts, 76 application/object pairs had no prepared record.
At least eight captured target records have no input bindings. These counts establish
saved binding resolution/carrier assembly, rather than saved model executions.
The standalone arm allocates 685,072 more bytes during execution. Status views,
temporal scratch and environment bindings are still prepared normally.

The combined arm executes 134 reference-backed driver rows. Initial numerical
membership contributes at most 56 rows across four days, giving a conservative
lower bound of 78 newborn rows. It performs four incremental refreshes, reuses
56 numerical groups and rebuilds no numerical batch. It still rebuilds 96
ordinary groups and constructs 69 rich targets. There are no full invalidations
or native-column execution claims.

## Correctness and proof boundary

The frozen qualification passed 384 generic, 17 mixed-cadence, 44 distributed,
10 real-XPalm and 16 combined assertions. An independent subsequent gate also
passes when a user-seeded newborn field becomes a distributed destination only
at the global refresh: capture succeeds, refreshed ownership rejects promotion,
and the canonical reference remains live. State, history and topology are
compared at each step. Scalar escaped references retain identity; whole immutable
`Status` wrapper replacement follows the ordinary executor's behavior.

Promotion requires the same lifecycle event and compiled scene, model and
environment revisions, mutation and execution generations, application/input
plans, declared input-port reference types, source identities and applications,
ordered carrier references, and current canonical source references. It admits
`HoldLast` and `PreviousTimeStep` without a temporal window. Each selected local
source has one canonical writer; ambiguous selected local writers, stream-only
sources and unsupported carriers/policies use ordinary compilation. A
`from_status` binding still checks actual field ownership despite having no
source-application metadata. An actual distributed source is rejected again
against refreshed ownership before promotion; unrelated distributed outputs may
coexist with positively executed promotion.

Later additions within the same dirty revision invalidate earlier captures.
Movement, removal, reparenting, model replacement and existing-environment
invalidation cannot satisfy the narrow addition proof. Ordinary writer checks,
Many sharing, required/default validation, canonical rewiring, temporal/status
view construction, environment sampling and scheduler order remain in place.
The cache belongs to the lifecycle event; it copies metadata, not scientific
values. No scientific package source was changed.

## Interpretation and next tests

The following explanation is **source-based inference, not a measured profile**:
only a small part of refresh is removed, while source-ID/reference snapshots and
ownership validation add work. Logical scene extension, distributed destination
and writer refresh, dynamic input updates, status/temporal views, environment
preparation and execution-plan bookkeeping still run. The screen measures the
net cost but does not attribute that cost to those phases.

1. Establish a compact phase/allocation profile of ordinary logical extension
   and enabled promotion before redesigning either. Preserve normal execution;
   compiler performance instrumentation deliberately declines promotion in this
   prototype. Count affected applications, carriers, views and destinations.
2. Test guarded reuse or append-only construction of status views and prepared
   environment schemas. Rebuild changed temporal/private state and membership;
   sample mutable committed/trial environmental values freshly on every call.
3. Test incremental structural reuse for the remaining compiler indexes,
   ownership records and ordinary execution groups, rather than repeatedly
   assembling whole-scene metadata. Keep explicit fallback for non-additions and
   changed existing bindings. Verify Many identity alignment, initializers,
   mixed cadence, distributed destinations and continuation before larger runs.
4. Compare each candidate independently and combined with the ordinary executor
   on the same improved baseline. Preserve model types, organ labels and source
   package code; choose paths by capabilities and mutation proofs. A reduction
   in rebuilt metadata must accompany any claimed runtime improvement.

Primary evidence: [four-arm timings](current-programs/newborn-xp-small.json.gz),
[generic/multirate/distributed gates](current-programs/newborn-narrowed-checks.json.gz),
[real and combined XPalm gates](current-programs/newborn-xp-checks.json.gz),
and [newly distributed ownership gate](current-programs/newborn-late-owner.json.gz).
Frozen prototype source is under
[`source-snapshots-final`](current-programs/source-snapshots-final).
