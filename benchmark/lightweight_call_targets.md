# Lightweight hard-call target views

Materializing a `CallTarget` should not copy its immutable scientific model,
application-local Status and input/output binding payloads on every inspection.
The view now holds its compiled execution owner by reference. Its own caller
clock, publication permission, environment and descendant calls remain captured.
The ordinary view has 12 fields instead of 20; model/status/binding properties
still expose the same objects through the public view interface.

Execution owners are replaced when structural identity changes, not overwritten
in place. Lifecycle updates may still extend already shared streams/carriers.
Targeted newborns have no ordinary execution owner yet: their exact local
payload uses an immutable NamedTuple, without an extra mutable owner allocation
or substitution of canonical Status. Transient context leases and accepted
publication rules are unchanged. No sampled weather or scientific output is
cached by this change.

## Downstream initialized measurement

Compared with `4fc0dbde` (PR226), unchanged MAESPA `0a24911` on a synthetic
eight-tree/two-species scene with four layers/twelve points per tree/layer,
384 physical samples, eight processes and 43 applications:

| Engine | Median initialized eight steps | Allocated bytes |
| --- | ---: | ---: |
| PR226 `4fc0dbde` | 0.797516 s | 1,555,931,008 |
| Lightweight target views only | 0.642296 s | 805,272,192 |

Three distinct restored step 16 simulations advance through daylight steps 17–24
after a full 96-step warmup. Restoration, full GC, assertions and sampled profiling
are outside each timer. Every complete public state at 24 and 96 exactly matches
the pre-change base. Julia 1.13.1, Float64, two compute threads/one GC thread,
startup disabled, `--compile=yes -O1 --compiled-modules=existing`, no history.
These are sequential desktop samples with no other heavy scientist observed at
launch, not randomized machine-isolated or whole-run measurements. The measured
improvement is 19.46% elapsed time/48.25% allocated bytes on this interval.
No compilation-latency or initialized peak-RSS benefit is established.

MAESPA-local sharing of thermodynamics and constructor-validated atmosphere are
measured separately; their additional gains are not attributed to this engine
change. MAESPA's declared dependency/manifests remain unchanged.

## Mechanism and lifecycle checks

An escaping-view microcase writes each materialized view into `Ref{Any}`;
allocation falls from 1,696 to 1,040 bytes per returned view in both Float32/64.
This includes view materialization/descendant metadata, not `sizeof(CallTarget)`
or an end-to-end simulation. The one-batch timing is not a stable benchmark.

The cold targeted route is exercised separately with 16 existing leaves and
eight newborns per fresh run, all outputs retained, three warmed repetitions
per storage type. Combined timing covers the public `step!`: Object/Status
creation, registration, first targeted call, publication and lifecycle barrier.
Initial scenario compilation, forced GC and output checks are outside timing.

| Storage | Eight births, baseline → candidate | Allocated bytes, baseline → candidate |
| --- | ---: | ---: |
| Float32 | 0.887 → 0.934 ms | 410,096 → 412,272 |
| Float64 | 0.869 → 0.870 ms | 408,944 → 412,208 |

This cold path has a small 0.5–0.8% allocation regression, not a universal win.
A separately instrumented split route measures targeted preparation plus forced
materialization at about 21.2 → 22.3 kB/newborn, partly offset by lower measured
creation cost; stage timers are not an exact decomposition of the uninstrumented
whole step. All newborn values, types, histories and calendar stamps match
across revisions, with existing leaves untouched and combined/split outputs
identical. This trade-off is retained for the much larger hot-path saving;
the data do not establish faster general organ creation.

Nine existing public call microcases, three warmed repetitions of 10,000 calls:

| Route | Baseline ns/call | Candidate ns/call | Allocated bytes/call |
| --- | ---: | ---: | ---: |
| Singular | 28.4 | 28.2 | 0 |
| Repeated8 | 239.5 | 229.0 | 0 |
| Nested | 70.5 | 76.8 | 0 |
| Many8 | 194.5 | 193.1 | 0 |
| Heterogeneous2 | 77.9 | 76.8 | 0 |
| Sampled environment | 18.0 | 17.5 | 0 |
| Transient environment | 28.9 | 29.3 | 0 |
| Nested transient | 57.0 | 58.8 | 0 |
| Published | 29.3 | 29.4 | 0 |

These tiny-loop observations show small regressions as well as gains; they are
not proof of timing equivalence or universal improvement. The baseline is a
Git export of 4fc0dbde, not another development worktree. It uses an exact copy
of the local dependency manifest, without Pkg resolution or checkout edits.
The first incomplete-snapshot attempt stopped at dependency loading before
any measurement; its logs are preserved and excluded from the results above.

Newborn-result SHA256, before/after respectively:
`0461221003e42cb6645c519aff5f7bbad807941e4a4c8cbd6e2978f448eab7ec`,
`d2bfff5fd6500d71e16ea9a51079986443f3185a88c11524cb3276e32b34536d`.

## Qualification

Fifteen complete runtime files pass 2,216 assertions: the prior 13 files / 2,098
plus 46 target-view regressions and 72 readable-source-compiler checks. Ten
MAESPA files / 14 TestItems pass 22,663 assertions with the local candidate,
including unchanged frozen Fortran comparisons, independently reconstructed
water/component energy budgets and exact serialized 48 + 48 continuation.
The hard-call allocation/API gates and internal suite assembly add 82 passing checks (48 + 34), including the unchanged zero-allocation transient paths.

These are targeted local qualifications, not the entire PSE suite or a CI
verdict. Children/helpers exit 0 / signal 0, four logs per child are fully read,
source/input pins remain unchanged and monitors finish without errors,
observation failures, TERM or KILL. The separate PR226 remains unchanged.

The new regression exercises Float32/64, a live renamed input, application-local
stream-only output storage, nested rejected publication followed by accepted
replay, and a retained step1 target after its parent's time/environment advance.
Existing context lease/reentry, newborn/initializer, lifecycle, distributed-output,
multirate, environment and readable-source-compiler tests remain required.

Raw MAESPA profile SHA256, before/after respectively:
`034967f0539c207013e1b20be7d745c6e05dc06e13f45217fd0a7f78e005fd58`,
`182e8951f5f8056f0ed16499ec544d8dae33929406aeba1e32fdbd41970fa376`.
Machine-local profiles, bounded process logs and serialized comparisons are
development evidence only, not package runtime dependencies.
