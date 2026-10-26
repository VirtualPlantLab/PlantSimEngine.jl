# Singular hard-call target access

`only(call_targets(context, :role))` is useful when a kernel needs one selected
sub-model's live Status. Repeating that access inside numerical iterations
should not construct the generic iterator's `(target, state)` tuples.

This change specializes `Base.only` for PlantSimEngine's own `CallTargets`.
It resolves the current execution batches once, checks singular membership,
and directly indexes a concrete one-batch target vector. Other batch tuples
use a generic cardinality scan. The successful path still calls the normal
`_materialize_call`: application-local Status, captured environment/time,
descendant permissions and reentrant context leases are unchanged.

There is no new public API, macro, process, model-specific name, copied model
kernel or scientific-result cache. Existing `One`, `OptionalOne` and singular
`Many` calls use the same implementation. Empty/multiple collections still
raise the same cardinality error as Base's generic iterator implementation.

## Downstream measurements

The engine baseline is `95fac16e` (PR227 plus its docstring fix), compared with
this 32-line runtime specialization. Both use MAESPA `2a36102`, including its
separately qualified static field setter. The latter's gain is not attributed
to this engine change.

The branch starts at PR227's `14e293e5`, whose complete source tree is identical
to `95fac16e`; its additional commits reconcile PR226's merged history only.
No upstream merge was performed for this optimization.

Same synthetic eight-tree/two-species scene, four layers/twelve points per
layer/tree, 384 physical points, one soil layer and two days/96 half-hours.
MAESPA explicitly uses its compact builder, not a migration of its default
builder. Three whole repetitions parse the unchanged files and build fresh
models. Three initialized repetitions restore accepted step 16 outside timing,
then advance daylight steps 17–24. Each fresh child first warms all 96 steps.

| Warm measurement, median of three | Baseline | Singular target access |
| --- | ---: | ---: |
| Whole parse + build + 96 steps | 3.715643 s | 3.547505 s |
| Whole allocated bytes | 3,905,004,416 | 3,618,035,184 |
| Initialized eight daylight steps | 0.410011 s | 0.397822 s |
| Initialized allocated bytes | 552,124,032 | 503,630,592 |

Observed whole reduction: 4.53% elapsed / 7.35% bytes. Initialized reduction:
2.97% elapsed / 8.78% bytes. Whole time ranges: 3.698506–3.842570 /
3.539902–3.555349 s. These are sequential ordinary-desktop observations,
not confidence intervals. The first job overlapped an unrelated AMAPSim
worker; the prototype job overlapped the independent PSE qualification.
Neither is a randomized, machine-isolated benchmark.

Julia 1.13.1, Float64, two compute threads/one GC thread, `--compile=yes -O1
--compiled-modules=existing --startup-file=no`, `outputs=:none`. Imports,
forced pre-run GC, restoration, checks and serialization are outside warm
timing; measured GC remains included. Allocated bytes are cumulative churn,
not simultaneous memory. Both complete public states at steps 24/96 exactly
match the unchanged pre-optimization reference.

First whole calls take 71.101261 / 68.740249 s, including 67.385077 /
65.124030 s attributed to compilation. Two observations do not establish a
compilation improvement or initialized peak-RAM benefit.

## Generic mechanisms and trade-offs

Consuming a singular target's status in 10,000 warmed accesses allocates
10,240,016 -> 6,560,016 bytes, for Float32/64 storage and homogeneous/distinct
application configurations. The reduction is 368 bytes/access, not
`sizeof(CallTarget)`. Median times are approximately 0.00531 -> 0.00468 s
(Float32 homogeneous) and 0.00571 -> 0.00468 s (Float64 homogeneous).

Nine public-call microcases use the unchanged benchmark fixtures, three
warmed 10,000-call repetitions each:

| Route | Baseline ns/call | Candidate ns/call | Bytes/call |
| --- | ---: | ---: | ---: |
| Singular | 28.68 | 29.05 | 0 |
| Repeated8 | 242.63 | 236.19 | 0 |
| Nested | 68.20 | 78.17 | 0 |
| Many8 | 195.60 | 194.97 | 0 |
| Heterogeneous2 | 80.07 | 80.71 | 0 |
| Sampled environment | 18.11 | 17.73 | 0 |
| Transient environment | 30.28 | 29.74 | 0 |
| Nested transient | 60.85 | 58.17 | 0 |
| Published | 30.87 | 30.09 | 0 |

In particular, the small nested route is about 10 ns slower in this snapshot.
This is a measured trade-off, not a universal speedup or equivalence claim.
No improvement in organ creation is established here. The original generic
baseline is an immutable Git95fac16e export with the same dependency manifest.
No dependency installation or checkout reset is part of the comparison.

## Qualification

The new regression passes 196 assertions against the baseline and prototype:
Float32/64, One/OptionalOne/Many, empty/multiple/heterogeneous collections,
model/Status identity, unpublished versus accepted calls, retained output
membership, and captured environment/time after the parent advances.

Sixteen complete PSE files pass 2,413 assertions: hard calls, active context
leases/reentry, newborn retention/initialization, providers/environments,
identity-aware many inputs, distributed outputs, runtime matrix, multirate and
previous-step policies, lifecycle/type changes, public API, target views,
readable source compilation and the new singular-access regression.

Thirteen complete MAESPA files / 20 TestItems pass 23,846 assertions with the
local prototype, separately from the same 23,846 passes against registered
0.15.1. This includes model substitution, Tuzet/non-Tuzet historical paths,
frozen Fortran trajectories, scalar/coupled leaf models, environments,
two-day scenes, independently assembled budgets and exact serialized 48+48
histories/final states. Maximum water residuals remain
3.3725626458203095e-14 / 3.442298529554577e-14 mm; soil/component energy maxima
remain 0.0041312152049357564 / 0.004288579248921565 W/m². Leaf H=Rn−lambdaE
is historical component accounting, not independent calorimetry.

Engine/science children 76754/80003 and separate helpers terminate 0/signal0;
four complete logs per job are read, pins are unchanged and monitors finish
without error, failed observation, TERM or KILL. Fixed monitor times:
413.300876 / 317.112183 s; sampled whole-child peaks: 2129.48 / 2655.91 MiB.
The timing child 76715 also terminates normally, fixed monitor 114.305037 s,
peak 2940.58 MiB. Mechanism children 72592/74233 similarly finish normally
in 48.219550 / 46.233031 s, with unchanged source and complete logs read.
These are targeted local qualifications, not whole-suite or remote-CI results.

## Reproducibility and next design boundary

Kaimon controls every Julia process, with retained supervisor/real child
handles, 30 min / sampled 8 GiB bounds, 2 s monitoring and 5 s TERM grace.
Raw local evidence: MAESPA's
`legacy_fortran/validation/2026-10-26-generic-calls/`; reused nine-route tables
remain in `2026-10-25-pse-contexts/only-*-routes.toml`. These are development
artifacts, not package dependencies. Frozen Fortran files remain unchanged.

The first probe's test fixture used an unsupported scenario `process=` selector
for One/OptionalOne and failed before testing the runtime change. The fixture
was corrected to explicit application identities; that attempt's logs are
preserved and excluded from qualification. Its completed newborn measurements
were not replayed or claimed as a candidate gain.

The remaining cost warrants a generic typed invocation/environment boundary,
not MAESPA-specific direct calls. Call roles already use typed compiled plans
and `Val` lookup, so a macro adding only `Val(:role)` would not remove erased
environment payloads. A future ergonomic macro should lower to a common
execution primitive, preserve model selection and accepted publication, and
specialize schemas/model types rather than tree counts or parameter values.
