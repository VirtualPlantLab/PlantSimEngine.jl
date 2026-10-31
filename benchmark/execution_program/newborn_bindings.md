# Reusable binding instructions for newborn organs

This experiment compiles invariant binding decisions before simulation while
resolving current objects and canonical references when a consumer is created.
It follows the [growth metadata experiment](growth_inputs.md), whose allocation
reductions did not establish an XP runtime or first-use improvement.

`NewbornBindingProgram` initially lowers scalar `One`/`HoldLast` bindings with
either a live status source or a unique known local canonical producer. Source
queries, target membership, targeted-newborn overlays and per-variable writer
ownership remain live. Successful instructions obtain the current canonical
`Ref` directly and append an ordinary compiled input binding. Many, optional,
temporal, stream-only and uncertain declarations retain ordinary compilation.
Fallback after a query passes the already resolved IDs to the ordinary helper;
it neither repeats the query nor appends the consumer twice.

Instructions are scoped to weak logical-application identities. Full scenario
recompilation creates new identities; exact immutable selector/matcher/header
guards reject changed same-slot plans. Method-world changes retire an old
certificate. Source declaration admission uses type and strict effect inference
on the actual `ModelSpec` declaration entry. Fixed output names, strict
consistency/effect-freedom and nonthrowing behavior are required; rejected
declarations are never additionally evaluated by optional compilation. This
preserves mutable/global declarations and metadata RNG/counter behavior through
the ordinary path. No model defaults, scientific values, live memberships or
reference carriers are cached in the program.

All schemas and operations are generic. There is no leaf, species or package
selection rule. Original PB/XP scientific kernels, reference storage, scheduler,
environment, temporal sampling and publication machinery remain unchanged.
Ordinary controls share the new cold hooks with enabled candidates; the hook
cost against the preceding revision is not independently quantified.

## Initial gates

The ordinary two-day XP inventory completes with 134 plans, 198 current input
bindings and 108 bindings on six newborn objects. Source analysis identifies
74 structural opportunities before strict declaration/ownership admission;
that inventory is not optimized execution credit.

The initial prototype passes 841 generic/adversarial assertions. After stronger
world/overlay guards, 1,001 assertions pass for independent Float32/RNG state,
newborn binding execution, live references, One/OptionalOne/Many fallbacks,
creation/removal/reparenting/re-registered IDs, writer membership, ambiguity,
Updates, declaration effects and same-slot semantic changes. Dynamic output
names and side-effecting/RNG declarations reproduce ordinary evaluation work;
constant output declarations on RNG-bearing models remain eligible.

Full-history PB/XP checks pass separately and with the typed PB driver or
bounded XP preparation. The two-day XP candidate completes 109 instructions:
62 for newborn consumers, including 58 producer and four status instructions;
six newborn executions are targeted preparation and 56 are global refresh.
Fifteen already-resolved bindings fall back on competing/distributed ownership.
This is actual executed work, not the structural opportunity count above.

Initializer (112 assertions), mixed cadence (153), distributed sources (84)
and fresh logical recompilation (46) also pass. An initial recompile test
incorrectly required optimization of dynamic output declarations; its scientific
parity passed, and the corrected test explicitly requires strict ordinary
fallback. The failed expectation and old source are preserved.

Positive coverage requires actual
successful instruction completions, including producer instructions for
newborn consumers. Prepared programs, empty consumers and initial bindings do
not count as a newborn optimization. Numerical typed-driver entries remain a
separate measure.

## First small timing screen

Four balanced cycles use independently constructed scenes, `outputs=:none`,
and exact post-run state, topology, type, RNG and work fingerprints. CPU
monitoring found no competing Julia process above the observation threshold.
Ratios below are medians of paired candidate/reference ratios; lower is better.
Complete cost includes construction, preparation, lowering and execution.

| Fixture | Candidate | Execution ratio | Complete ratio |
|---|---|---:|---:|
| Generic, 32 initial objects, two steps, three additions | Instructions | 1.120 | 1.051 |
| Same | Bounded metadata | 1.065 | 0.999 |
| Same | Bounded + instructions | 0.951 | 1.035 |
| XP, four days | Instructions | 1.010 | 1.060 |
| Same | Bounded metadata | 0.971 | 0.961 |
| Same | Bounded + instructions | 0.960 | 1.052 |
| PB, 32 objects, 128 steps | Previous typed driver | 0.688 | 1.070 |
| Same | Typed driver + instructions | 0.695 | 1.100 |

Individual instructions do not establish a runtime improvement. On XP,
execution allocations change only from 12.36 MB to 12.26 MB, while complete
allocations rise from 24.46 MB to 26.99 MB. Bounded metadata alone uses 7.07 MB
in execution and 13.65 MB complete; adding instructions uses 7.10 MB and
15.21 MB. Declaration certificates and per-binding bookkeeping cost more than
this first lowering saves. Small preparation compilation/effects-query events
remain recorded; no execution compilation or GC occurred in this screen.

PB's static fixture executes no instruction. Its driver results are control
measurements of the previous numerical optimization and receive no credit for
newborn binding work. No cold-compilation, large-scale or production-adoption
claim follows from this screen. The full regression suite has not been run.

## Consumer-sequence prototype

`NewbornBindingSequence` reuses an ordered instruction sequence for a whole
consumer, hoists program lookups out of individual bindings, and avoids
rebuilding proven singleton inferred groups. The scalar executor and strict
declaration certificates are shared with the first prototype. Fixed aggregate
completion counters remain enabled; optional detailed reason/per-input
dictionaries are disabled in timing runs and checked separately.

A singleton shortcut requires current **global** local-producer membership.
Targeted overlay membership alone cannot make an inferred producer match.
Explicit bindings run first, authored inferred-group order and manual-call
suppression are preserved, and unsupported operations fall back at their
original position. A late error retains the same partially appended bindings.
No consumer can fall back and replay its preceding successful bindings.

The sequence passes 793 focused assertions covering Float32/RNG and live
references, births/removal/reparenting, order and overlay membership, dynamic
declarations, initialization, mixed cadence, distributed sources, fresh
recompilation and stale headers/method worlds. Its generic fixture also passes
independently and with bounded preparation. The initial negative timing result
above remains a separate source cohort; sequence timing qualification follows
these gates.
