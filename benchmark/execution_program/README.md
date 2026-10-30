# Typed call programs and incremental growth experiments

The best current candidate is the reference-backed typed call program. On the
small original PlantBiophysics Monteith/Fvcb/Medlyn task it removes about 29% of
warm execution time and 23% of complete cost over a longer run. The conservative
newborn binding cache performs real reuse in XPalm, but the short timing screen
is slower. These remain opt-in experiments; the ordinary executor handles
unsupported capabilities and lifecycle transitions.

The ordinary baseline incorporates reviewed PRs #240, #241 and #242. Their
percentages are not added to these results. PR #243 is investigated separately;
its CI timeout has no established cause. Historical results from before this
baseline are preserved in [historical-call-growth](evidence/historical-call-growth/index.json).

The later [preparation-factorial screen](preparation_reuse.md) compares bounded
scenario metadata and status-view recipe reuse separately and together. Bounded
metadata reduces XPalm first preparation from 105.9 s to 73.3 s in one fresh-process
screen; warm complete time is unchanged. View recipe reuse adds no convincing gain.
The numerical executor and scientific kernels are ordinary in that comparison.

The [future-layout precompilation experiment](future_layouts.md) prepares known
status and call types before growth, including targetless applications. The small
PB/XP screen preserves scientific behavior, but its upfront catalogue cost exceeds
the saved first-growth work. Bounded specialization alone remains the best
complete-cost arm; the report retains the negative future-precompile results.

## What changed

- `shared_call_program.jl` stores one immutable typed instruction tree per
  homogeneous cohort, with aligned model/status/output columns. Numerical
  contexts are shared between rows; genuine public call collections are lazy.
- `tight_call_program.jl` adds a stronger audited capability: synchronous,
  unpublished calls discard their results, and neither contexts nor results
  escape. Its private context resolves concrete child models directly and
  removes unobservable per-child bookkeeping. Original scientific kernels run
  unchanged. Real child call frames remain to preserve exception behavior.
- The optional same-object union header requires exact canonical Status,
  object-ID and reference agreement across the whole graph. The projected
  interface is the broader candidate; union headers did not add a convincing win.
- `newborn_preparation.jl` promotes successfully prepared logical input bindings
  from the current lifecycle event. Epoch, plan, port, source-reference and
  refreshed writer-ownership proofs precede reuse. Status/temporal views,
  environment preparation, validation, schedules and publication remain ordinary.
  It combines independently with the previous incremental reference driver.

Eligibility depends on kernel capabilities, concrete types, call-graph shape,
reference ownership and mutation proofs. There is no leaf, species or scale
special case. The PB audit opts in the current original scientific methods;
unknown kernels, retained/evaluated/published calls, tracked Many membership,
unsupported temporal/distributed interfaces and changed topology retain the
full Shared/ordinary path as appropriate. Source capabilities are explicit
contracts, not automatic purity inference or a guarantee about future changed
scientific package methods.

## Warm measurements

Medians and paired ratios use fresh independently constructed samples, serial
execution and alternating forward/reverse arm order. Complete time includes
construction, ordinary PSE preparation, backend preparation and execution.

| Fixed task | Ordinary execution | Typed reference execution | Paired execution ratio | Paired complete ratio |
| --- | ---: | ---: | ---: | ---: |
| PB, 32 organs × 128 steps, initial 3 cycles | 4.623 ms | 3.278 ms | 0.721 | 1.081 |
| PB, 32 organs × 2,048 steps, 6 balanced cycles | 70.992 ms | 50.682 ms | 0.709 | 0.765 |
| PB, 256 organs × 128 steps, 3 cycles | 32.341 ms | 21.906 ms | 0.669 | 1.005 |

The longer projected and union arms win all six execution and complete-cost
pairs. Projected execution allocates 3.123 MB versus 23.840 MB, about 87% less.
The exact final field/type/history digest agrees in every qualified sample.
Preparation is still more expensive, so short complete runs can be neutral or
slower. The 256-organ screen is a width check, not evidence for millions of organs
or hundreds of model applications.

The numerical plain-Julia reference calls the same original kernels on
independent RefValue state with the same forcing, parameters, precision, order
and iterative work. It omits scheduling, binding, publication, history,
lifecycle and general environments, so it is a fixed-task numerical reference,
not a full PSE replacement or proven absolute performance bound. The long typed
program is roughly 10–12% above its noinline reference in paired comparisons.
Forced child inlining gives no consistent benefit. Another medium screen puts
the projected path near the reference, showing why one small difference should
not be generalized. Instrumented companions independently confirm 4,096 roots,
24,576 children and 12,288 model lookups for the 32 × 128 task; timed child
counters compile away and remain reported as missing.

Native canonical storage was tested independently and together with both typed
header choices. In the second 32 × 128 screen, native projected/union execution
ratios are 0.734/0.802 versus ordinary reference storage, compared with 0.684 for
typed reference storage; complete ratios are 1.244/1.324 versus 1.047. The
reference-backed candidate is preferred for this workload. Native coverage ties
observed batch entries to the exact canonical payload and does not invent child
execution counts from prepared rows.

For XPalm, the original four-day accelerated-growth fixture creates 12 objects
and ends with 20. All four timing arms have matching final states, output
streams and work. Promotion saves 20 bindings across 28 targets; the combined
arm proves at least 78 newborn driver rows. Paired execution/complete ratios
are 1.085/1.042 for promotion, 1.778/1.434 for incremental references, and
1.815/1.465 for both. No sixteen-day run was started after this negative screen.
See [newborn findings](evidence/newborn-findings.md) for remaining work and
source-based hypotheses, distinguished from measured phase attribution.

## First-use compilation screen

One separately started Julia 1.13.1 process per arm ran the same two-organ,
two-step task before any simulation or IR probe. The exact digests match.
Disk precompile and filesystem caches were not cleared. This is a first-use
screen, not a repeated cold-performance estimate.

| Arm | PSE/backend preparation | First execution | Complete construction + preparation + execution |
| --- | ---: | ---: | ---: |
| Ordinary, PID 72693 | 10.561 s | 0.593 s | 13.096 s |
| Typed projected, PID 74372 | 11.688 s | 0.478 s | 13.993 s |

Preparation and first execution are dominated by reported JIT work. The
prototype adds about 1.1 s to preparation in this screen; it has no demonstrated
compilation-time improvement. Experimental loader cost is separate, 7.35/7.33 s
after Kaimon's project import/startup. The long-run runtime gain does not imply
a faster first short simulation. Avoiding duplicate backend preparation and
bounding scenario metadata specialization remain important next hypotheses.

## Next bounded experiments

1. Construct the selected typed program directly and materialize full fallback
   frames only when needed. Measure preparation independently: the current
   backend prepares Shared fallback structure as well as Tight frames.
2. Keep scenario-wide planning metadata behind bounded dynamic interfaces while
   specializing numerical batch types. Vary application count separately from
   organ count; use fresh 4/16-model cases before attempting hundreds. The
   [width audit](evidence/pr243-and-compiler-width.md) identifies concrete tuple
   and NamedTuple surfaces, without attributing the observed delay to them.
3. Profile XPalm's ordinary logical extension and view/index reconstruction,
   then reuse unaffected compiler structures under explicit mutation proofs.
   Reusing a few newborn bindings alone has insufficient benefit here.
4. For independently proven common-cadence graphs, isolate scheduler cost with
   a time-blocked driver before changing scientific kernels. Keep full scheduling
   for temporal coupling, commits, lifecycle or output requirements that prevent
   reordering. Native column-header compression is a separate experiment, not
   a prerequisite for the current reference-backed candidate.

## Correctness and scope

Small gates compare complete typed scientific state, topology, every retained
output and continuation against independently constructed ordinary runs. They
exercise native/reference storage, unchanged scientific methods, nonlocal
headers and union rejection, generic Float32 state, exception/retry, partial
batch failure, mutable environment sampling, retained One/Many collections and
metadata/publication across growth, external refresh consumption, newborn
initializers, PreviousTimeStep, mixed cadence, live scalar references,
distributed coexistence, actual distributed-source rejection, and ownership
that changes only at the global growth barrier. Unknown and public-context
kernels demonstrably take full-protocol fallbacks.

The focused existing broad regression run was deliberately stopped after its
budget; it has no final aggregate result and is not counted as passed. Exact
smaller existing tests and the independent PR243 investigation are recorded in
[the compiler-width note](evidence/pr243-and-compiler-width.md). These are bounded
prototype checks, not a completed full-suite or scientific validation claim.

The separate PR243 protocol investigation reproduced both extension failures;
the generic adapter passes 22 protocol and 11 unchanged lifecycle assertions.
Its tiny PB typed/native preflight also passes 19 assertions. The source layer
was removed after testing, and is retained as independent patches and evidence.

## Reproduce and inspect

Use a Kaimon-controlled session for this checkout, with compatible PB, XPalm,
PlantGeom and benchmark dependency environments prepared according to
[benchmark/README.md](../README.md). Optional packages remain outside the default
benchmark project. `load_experiments.jl` accepts local checkout paths through
`PSE_DOWNSTREAM_DEV_ROOT` and the explicit `PSE_*_PATH` environment overrides.

Load `load_experiments.jl`, `lean_compiler.jl`, `direct_calls.jl`, then the desired
prototype/check files from `benchmark/native_downstream`. The typed modules
require Shared first; the comparison modules require the plain reference and
boundary-control modules. Use `TightNativeGapBenchmarks.tight_native_gap_preflight()`
before `register_tight_native_gap_case!` and `M.screen_case`. The newborn path
requires the event-cache core hooks and a fresh Julia image after layout edits;
run its generic/distributed gates before real XPalm and combined checks.

`cold_gap_case.jl` requires a distinct fresh-process attestation and measures one
first-use arm before any case execution or IR probe. Loader cost is separate
from model preparation/first execution, after Kaimon's project import. Restart
can preserve PID through exec; [freshness evidence](evidence/kaimon-freshness.md)
explains why explicit shutdown/start with new PIDs is used for cold comparisons.

[summary.json](evidence/current-programs/summary.json) contains paired warm
statistics and separate cold phases. [manifest.json](evidence/current-programs/manifest.json)
records uncompressed and compressed checksums. Individual gzip files preserve
full snapshots, coverage, work and source provenance; use `gzip -dc` to inspect.
Receipts and source snapshots are adjacent. The original local result archives
remain unchanged. `python3 benchmark/execution_program/summarize_evidence.py`
rebuilds this evidence archive from the local raw files without changing them.
