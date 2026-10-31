# XPalm dispatch and refresh experiments

The preferred candidate is **bounded graph preparation plus typed output-status
preparation**. A modest confirmation screen reduces XP execution by about 7%
and complete fresh-run cost by about 13% against ordinary control A. Its extra
gain over bounded graph preparation alone is about 2.5%, with five of six paired
wins. Construction-trusted indexing is correct on the checked paths, but has no
dependable standalone or incremental CPU benefit. All changes remain opt-in.

## Mechanisms and boundaries

`TypedOutputPreparation` dispatches the existing batched output-status body once
on each concrete `ModelSpec`. Scene-wide recipes and conversion records remain
opaque. It evaluates the current local-output declaration once per application,
including targetless applications, and preserves target/port order, canonical
routing, mutable-default copies, conversions and canonical reference storage.
It caches neither scientific values, declarations nor memberships. This is a
generic application boundary, with no XPalm-, organ- or species-specific rule.

`TrustedExecutionGroupIndex` records proof during the existing canonical index
fill. Weak application identities are stamped once per logical plan token while
retained in a bounded registry; growth shells share that token. Refresh checks
identity and lengths instead of scanning the whole index and copying application
references again. Nonempty and empty queries still require the current canonical
application identity. Unregistered/manual/custom indices and uncertain epochs
use the conservative epoch/ID fallback, reported separately. Certification,
stamp construction and registry eviction are real costs included in preparation
and execution. The trust boundary requires core-owned group/index vectors not
to be mutated privately after construction; source audit found no core path
that changes those vector entries. Batch contents can still change normally.

`GraphRowProjection`, from the previous experiment, projects actual graph
neighbours into authored order and uses the original bounded metadata factories.
It is a separate preparation policy, not the ordinary baseline. The previous
[attribution report](xp_attribution.md) compares it against bounded controls;
this round supplies fresh ordinary-executor controls.

## Correctness before timing

A fresh Kaimon worker verifies Julia 1.13.1, PSE 0.15.1, PlantBiophysics 0.18.1
and XPalm 0.7.0 from the intended checkouts. Successful focused suites total
1,379 assertions: isolated typed preparation and construction certificates;
ordinary-versus-candidate XP/PB checks separately and together; and composed
lifecycle/environment/numeric gates. Exact per-step state, retained history,
Status/Ref types and replacement transitions, scientific RNG and actual work
match independently built ordinary simulations.

Coverage includes targetless declarations and first membership, fresh/effectful
mutable defaults, stream-only routing, exception order, heterogeneous growth,
removal/re-addition, reparenting, movement, logical recompilation/reordering/model
replacement, newborn initializers, PreviousTimeStep and mixed cadences,
distributed destinations, spatial rebinding with cached hard calls, templates,
overrides, conversion callbacks, Float32 and BigFloat. Unsupported preparation plans and uncertified indices use conservative paths
rather than receiving optimization credit.
These are focused preservation checks, not the full package regression suite or
scientific calibration validation.

One new override fixture initially lacked a root status required by the shared
snapshot helper. Both arms raised the same error; adding an explicit root
marker fixed the fixture. The failed receipt and original source are retained.
Startup retry/old-worker evidence is also preserved separately and supplies no
timing result.

In two-day XP checks, trusted indexing performs two actual certified refreshes,
78 group hits and 22 empty returns, with zero fallbacks. Typed preparation
performs 104 growth-phase object visits. These visits are not unique newborn
counts: a growing simulation can revisit existing objects.

## Independent and combined measurements

All numerical execution uses the ordinary PSE executor and original XP kernels,
reference statuses, forcing and RNG. The two ordinary labels run identical
code, with bounded metadata, graph projection, typed preparation, trusted index,
old lookup and binding-program policies disabled. Candidate enablement is
inside charged preparation. No native columns, fused numerical driver,
precompiled future catalogue or scientific-kernel wrapper is used.

The small screen uses two fresh independent two-day simulations per sample,
five arms and four balanced cycles. It finds no dependable trusted-only gain,
a small typed signal and a strong preparation signal for bounded graph metadata.
The next screen uses four independent twelve-day simulations per sample, seven
arms and six cycles. Preparation and execution are charged separately; complete
cost sums construction, enablement, all preparation, lowering and execution.
Weather is read at registration and copied into each independent fresh fixture.
One batch, rather than each simulation within it, is the statistical unit.

The existing accelerated-growth diagnostic uses seed 1, initiation age zero,
architecture disabled and both phyllochron speeds at 0.2 phytomer/degree-day.
Each twelve-day trajectory creates 36 objects and ends with 44 objects, with
61 applications. This is a small growth stress case, not a normal long-horizon
production simulation or a large-organ scaling qualification.

Ratios below are medians of within-cycle ratios to ordinary A; lower is better.
They are not ratios of independent median timings.

| Twelve-day first screen | Preparation | Execution | Complete |
| --- | ---: | ---: | ---: |
| Identical ordinary B | 0.994 | 0.988 | 0.996 |
| Bounded graph | 0.699 | 0.952 | 0.892 |
| Trusted index | 1.003 | 1.006 | 0.999 |
| Typed output preparation | 1.008 | 0.969 | 0.985 |
| Trusted + typed | 0.991 | 0.985 | 0.984 |
| Bounded graph + trusted + typed | 0.698 | 0.907 | 0.863 |

The full combination initially beats graph alone by about 4% during execution
and 3.5% in complete cost, six of six pairs. A reduced factorial confirmation
then isolates graph+typed and graph+trusted, alongside ordinary A/A and the full
combination. It changes arm order and repeats six balanced four-by-twelve-day
samples. Core and prototype implementations are unchanged; the measurement
harness adds the two missing arm labels in a separately retained source epoch.

| Factorial confirmation | Preparation | Execution | Complete |
| --- | ---: | ---: | ---: |
| Identical ordinary B | 1.000 | 1.043 | 1.036 |
| Bounded graph | 0.709 | 0.943 | 0.889 |
| Bounded graph + typed | **0.705** | **0.929** | **0.872** |
| Bounded graph + trusted | 0.707 | 0.950 | 0.883 |
| Bounded graph + trusted + typed | 0.679 | 0.935 | 0.880 |

Graph+typed beats ordinary A and B in all six execution and complete pairs.
Against graph alone its execution/complete ratios are 0.975/0.976, five of six
wins each, both order-direction medians below one and leave-one medians below
one. Adding trust to graph+typed gives about 1.001 execution/1.006 complete,
three of six wins, with the sign changing by order direction. The earlier full
combination increment over graph alone does not repeat: confirmation ratios are
0.995/0.993 with three wins. This supports the simpler graph+typed candidate,
not a demonstrated trust synergy.

Confirmation median batch execution is 164.65 ms ordinary A, 155.43 ms graph,
and 151.78 ms graph+typed; complete costs are 238.24, 212.59 and 207.78 ms.
Complete allocated bytes fall from about 200.69 MB to 106.21 MB per four-scene
batch. These are allocated bytes, not live memory or peak RSS. Typed preparation
records 2,496 growth-phase object visits per batch; trusted graph cases certify
48 actual refreshes and return 1,872 groups plus 528 empty slots without an
ID-map fallback. Metadata counters are never scientific kernel counts.

All measured phases in both twelve-day screens have zero reported JIT,
recompilation and GC time. The small screen retains one ordinary preparation
JIT event. Ordinary A/A execution ratios span 0.969–1.168 in the first screen
and 0.995–1.180 in confirmation; small differences remain cautious candidates.
The winning combined direction persists against both controls, while the
increment over graph alone is modest. Exact quiet-CPU monitoring is hash-bound
to each artifact and successful Kaimon receipt. No cold compilation, full-suite,
long-horizon XP, AMAPSim/MAESPA, million-organ or peak-memory claim is established.
PB has short feature-preservation checks, not a new performance claim.

## Reproduction and retained evidence

Load definitions uniformly in a Kaimon session for this branch:

```julia
include("benchmark/native_downstream/load_newborn_binding_experiment.jl")
for file in ("graph_row_projection.jl", "typed_output_preparation.jl",
             "execution_group_lookup.jl", "execution_group_epoch_lookup.jl",
             "trusted_execution_group_index.jl", "xp_prepared_batch_timing.jl",
             "xp_dispatch_refresh_measurements.jl")
    include(joinpath("benchmark/native_downstream", file))
end
XPDispatchRefreshMeasurements.dispatch_refresh_checks(:xp;
    arm=:typed_graph, steps=2, outputs=:all)
spec = XPDispatchRefreshMeasurements.register_xp_dispatch_refresh_case!(
    :xp_confirmation; batch_size=4, steps=12,
    arms=(:ordinary_b, :typed_graph, :bounded_graph,
          :trusted_barrier_graph, :trusted_graph, :ordinary_a))
screen = XPDispatchRefreshMeasurements.screen_xp_dispatch_refresh(spec;
    repetitions=6)
```

The [derived summary](evidence/xp-dispatch-refresh/summary.json),
[artifact manifest](evidence/xp-dispatch-refresh/manifest.json) and
[source provenance](evidence/xp-dispatch-refresh/scientific-provenance.json)
retain exact raw results, scripts, qualification, forcing and source versions.
`summarize_xp_dispatch_refresh.py --check-only` validates the raw tree without
Julia; `--archive-frozen` creates an immutable archive and refuses replacement.
Replaying an older screen requires its recorded source epoch: the old seven-arm
script used the then-current optional-arm list. The confirmation script names
its six arms explicitly and works with the final harness.

A private-source proposal for a whole per-application target-merge/batch barrier
is retained under the archive's unexecuted-future-proposal records. It is
unapplied and untested, with explicit adversarial gates still required. Target
and batch constructors already specialize; only the whole outer block is a
new CPU hypothesis. It earns no correctness or performance credit in this round.
