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
| Generic, 32 initial units plus controller, two steps, three additions | Instructions | 1.120 | 1.051 |
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
15.21 MB. The added preparation and bookkeeping do not pay back in this screen;
their individual contributions were not separately timed. Small preparation compilation/effects-query events
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
above remains a separate source cohort.

## Sequence timing and scale check

The follow-on screen compares ordinary execution, base instructions, consumer
sequences, bounded metadata, and bounded metadata plus sequences on identical
fresh scenes. All arms pay their enablement/preparation costs. Sequence timing
uses fixed aggregate counters; base instructions retain their original detailed
counters, so differences between those two prototypes cannot be assigned solely
to grouping and lookup changes.

| Fixture | Candidate | Execution / ordinary | Complete / ordinary |
|---|---|---:|---:|
| Generic, 32 initial units, three births | Sequence | 0.944 | 1.001 |
| Same | Bounded + sequence | 0.952 | 1.056 |
| XP, four days | Sequence | 0.935 | 1.034 |
| Same | Bounded + sequence | 0.896 | 0.991 |
| Generic, 128 initial units, 128 births | Sequence | 0.955 | 0.970 |
| Same | Bounded + sequence | 0.930 | 0.959 |
| XP, twelve days | Sequence | 0.970 | 1.030 |
| Same | Bounded + sequence | 1.046 | 1.082 |

Generic cases also contain one controller object and run two steps. The small
screen has four balanced cycles; the moderate screen has six. All eight timing
screens across the two source cohorts pass exact science/RNG/work and balanced
order checks, with explicit artifact-to-CPU qualification. All timed execution
phases have zero reported compilation, recompilation and GC. Small preparation
compilation/recompilation events are retained in the evidence, including a
107.8 microsecond preparation compilation event for the previous PB typed driver.

The useful result is currently the **generic batch-birth candidate**. Against
bounded metadata alone, adding sequences reduces median paired execution time
by 3.2% (six of six wins) and complete cost by 2.3% (five of six). Execution
ratios range from 0.889 to 0.994. All 128 newborn producer bindings execute
through the sequence. This is a small fixture result, not a million-organ claim.

XP does not establish a runtime or complete-cost improvement. The four-day
bounded-plus-sequence execution ratio against bounded alone is 0.872 (four of
four wins), but at twelve days it is 1.005 (three of six, range 0.938–1.180);
complete cost is 1.054 (one of six). The twelve-day sequence executes 419
instructions, including 348 newborn producer instructions, and shortcuts 283
singleton groups. Its execution allocations fall from 38.29 MB to 34.46 MB
against ordinary execution; with bounded metadata they fall from 21.81 MB to
20.62 MB. These allocation reductions are real without a demonstrated XP
speedup. Prepared metadata and declaration proofs still add preparation work.

PB remains a preservation/control case. Both plain sequence and sequence plus
the previous typed driver pass full-history checks, but execute zero binding
instructions in this fixture. No PB binding-performance gain is claimed.

No new cold-process compilation, peak-RSS, large-scale or full-regression-suite
qualification was performed. These prototypes remain opt-in; ordinary storage
and execution remain the reference/default.

## Scope and reproduction

MAESPA's existing two-species benchmark constructs its objects before the
96-step run, so it would not qualify newborn instruction work. AMAPSim has real
growth, but a representative coupled fixture would need to be prepared first;
its current architecture interface alone is a poor scalar-binding test. Both
optional runs are deferred, and their active checkouts were not changed.

For a fresh Kaimon session in this checkout, definitions and a short parity gate
can be loaded with:

```julia
include("benchmark/native_downstream/load_newborn_binding_experiment.jl")
NewbornBindingSequenceMeasurements.newborn_sequence_checks(:xp;
    arm=:bounded_sequence, steps=2, outputs=:all)
case = NewbornBindingSequenceMeasurements.register_newborn_sequence_case!(
    :xp_sequence, :xp; steps=4)
screen = NativeDownstreamMeasurements.screen_case(case;
    repetitions=4, measure_retained=false)
```

The [evidence summary](evidence/newborn-bindings/summary.json),
[manifest](evidence/newborn-bindings/manifest.json) and
[scientific provenance](evidence/newborn-bindings/scientific-provenance.json)
retain exact source cohorts, complete raw checks, failed startup/expectation
attempts, all timed samples, CPU observations and reproduction scripts.
`summarize_newborn_bindings.py --check-only` validates the raw input tree without Julia;
`--archive-frozen` creates a new immutable archive and refuses overwrites.

The next narrow hypotheses are direct scalar-carrier assembly for ordinary
fallback bindings, and separately shared value-free declaration certificates
for repeated preparations. Neither was implemented or measured here. A shared
certificate cache would need to charge its first build and invalidate on method
world changes; it would not establish a cold-first-simulation gain.
