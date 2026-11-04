# Shared scenario preparation and JuliaC parity

Ordinary PSE, the full XPalm program and the AMAPSim adapter use the same
scenario preparation for application targets, dependencies and root schedule.
MAESPA projects the prepared ordinary runtime because it also needs the live
status references, environment handles and stream ownership. Its projection
and the ordinary executor use the same runtime initialization.

The full typed program keeps the candidate writers from the canonical plan
and selects among them by object. A temporal input takes its first value
at the growth barrier, before the next producer runs. The tests cover disjoint distributed
writers, filtered `Many` reads, `PreviousTimeStep`, and a new destination
that joins an existing writer during growth. `OptionalOne` retains the
canonical default reference while its producer is absent. The subsequent
[newborn writer correction](writer-rebind.md) also refreshes a filtered or
temporal binding when growth changes the producer of an existing destination.

The mixed-cadence fixture has hourly and daily applications, a manual call,
and a previous-step read. The independent ordinary run compares canonical
state and every retained sample across a 24-hour and a 26-hour continuation.
Separate host cases exercise phased integer and fractional clocks. The
daily XPalm configuration uses the canonical always-due instruction.

| Scope | Validation |
| --- | --- |
| Ordinary PSE | API stabilization, mixed cadences, previous-step views and lifecycle suites passed. |
| Typed XPalm | 243 assertions for reuse, invalidation and per-object producer selection. |
| XPalm JuliaC `safe` | 60 days with 246 objects and 122,554 retained samples. 4,160 days with 1,190 objects and 27,828 canonical fields. Both runs matched ordinary PSE topology, canonical state and RNG probes. |
| Mixed cadences JuliaC `safe` | 89 assertions. The native 50-hour case matched all 59 retained samples from the ordinary run. |
| Per-object producers JuliaC `safe` | A copied app compiled the two-writer fixture from the reuse suite. The native probe observed object IDs `[10, 20]` and previous-step values `[0, 0, 0]` at the first step and `[2, 3, 2]` at the second. |
| AMAPSim JuliaC `safe` | 37 host assertions. Branch46 and Merisier matched the ordinary records byte for byte over two steps. Merisier recorded 36 RNG draws. |
| MAESPA JuliaC `safe` | Six host assertions across initial state and four steps. The native daylight canopy–soil case passed 390 assertions and matched 28,202 ordinary records over 24 steps. |

The hosted selector test measured allocations in the ancestor lookup.
Reading the scale and kind on the cached ancestor path removes the
allocation caused by the abstract object ID's set membership. The same
99 focused assertions pass in local Julia 1.13.1. The hosted tests for the
supported versions run in the [pull request](https://github.com/VirtualPlantLab/PlantSimEngine.jl/pull/245/checks).

The [benchmark guide](../../README.md) gives the commands for building and
replaying the mixed-cadence case. The XPalm comparison uses fresh ordinary
oracles from the 60-day accelerated reproductive and 4,160-day original
parameter cases. The fresh oracles match the archived ordinary observations,
including the retained outputs and both RNG probes.


The binaries were built with Julia 1.13.1 and JuliaC 0.3.12, using safe
trimming and the generic CPU target. XPalm and the cadence fixture use
runtime commit `b2305803b`.

| Bundle | Binary SHA-256 |
| --- | --- |
| XPalm and mixed cadence | `ae2c8554ed9f846bcec08d671bb224b2681aeef73b8e4c02c061cd69aef41161` |
| Per-object producer fixture | `e5639c40154b0b82db4446462ffdf5167087afc348480e378c5b7ec3fdc7b773` |
| AMAPSim | `5cc27190490616e3562c07265efddaeedd76232e1732384a9dd814cf80829739` |
| MAESPA daylight | `c2ad6daebafa9f5e7d8ca5bd0e24516d3b1d1a91d79aadd90062e676c70a10a0` |

## Shared admission and publication follow-up

Ordinary PSE and the native adapters use the same scenario preparation to
validate hard-call cadences and reject distributed outputs on manual targets.
XPalm now uses the existing PSE initializer checks in place of a second scan
of its typed input routes. Graph diagnostics still report the errors in their
call-cadence and writer phases.

The typed XPalm adapter checks the producer's default policy for any input
it lowers to a live reference. It supports `HoldLast` and explicit
`PreviousTimeStep`. It reports an inherited policy such as `Interpolate`
during preparation. An explicit `HoldLast` input overrides the producer's
default in both runtimes. When the same typed plan is reused, a replacement
model must still supply `HoldLast` on outputs whose defaults the plan used.

Ordinary PSE and the MAESPA adapter share sample replacement at a repeated
time and pruning for dependency streams. The MAESPA adapter still copies
mutable values using its typed schema before handing them to the shared
publication code.

The Julia checks passed 280 reuse assertions and 360 graph-view assertions.
The ordinary hard-call, initializer, output-destination, multirate and
previous-step suites also passed.

The `39ffaf5cc` XPalm runtime was rebuilt with Julia 1.13.1 and JuliaC
0.3.12 in `safe` mode for generic CPU. At 60 days it matched the archived
ordinary PSE oracle for 246 objects and 122,554 retained values. At 4,160
days it matched 1,190 objects and 27,828 canonical fields. Both cases compared
topology and two RNG probes. The 50-hour cadence output matched the prior
qualified binary byte for byte. The newborn writer fixture passed with and
without retention.

For MAESPA, the typed Julia executor matched PSE at initialization and after
each of four steps. The daylight `safe` binary matched 28,202 records from a
fresh ordinary PSE run over 24 steps and passed all 390 assertions. The
focused publication test separately verifies replacement at the same time,
retention of the preceding dependency sample and independent mutable copies.

| Follow-up bundle | Binary SHA-256 |
| --- | --- |
| XPalm and mixed cadence | `e8b6d9bbec490f2ea096261622713102ab37da5bceade731e7f73958438c22f8` |
| Newborn writer fixture | `9dc9d9b96782173e1c74d2e0c0162bd8d784a52758bb47aa1eced72356de8090` |
| MAESPA daylight | `8c0b4de507f5914234ec6cc5594f039a9efbedf61bd4fee4554b1260b2ea1765` |

## Reusing the prepared scenario

`CompositeModel` prepares the scenario lazily. If an adapter prepares it
first, ordinary PSE builds its bindings from that plan. If ordinary PSE
prepares first, the adapter can reuse the plan from its binding cache.
Target lists are copied when a consumer creates runtime applications.
MAESPA copies the authored model and prepared snapshot together before
creating its private bindings. Explicit compilation through
`Advanced.compile_composite_model` still builds a fresh plan.

Structural edits invalidate the snapshot. An adapter that prepares while
topology changes are pending gets a snapshot of the current topology. The
active simulation can then apply its pending incremental refresh with its
existing schedule and history. A fresh run checks the base step after a
global environment change. Ordinary `run!` continues to advance the supplied
model and its RNG. The isolation checks use separate owned model instances.

The prepared-scenario tests passed 54 assertions on Julia 1.10.12 with CI
flags and on Julia 1.13.1. They compare fresh and reused plans across
continuation, random draws, retained streams, object addition, reparenting,
removal, and edits to cadence, model and bindings. The Julia 1.10 API
stabilization suite passed all 760 assertions. On Julia 1.13.1, the
API stabilization, lifecycle, multirate, previous-timestep and graph
suites passed 1,291 assertions, and XPalm host reuse passed 280.

Fresh JuliaC 0.3.12 `safe` builds on Julia 1.13.1 used the `generic` CPU
target. XPalm matched the ordinary PSE references for 60 days with all
outputs (246 objects, 4,904 state fields, 122,554 retained samples) and
4,160 days with no retained outputs (1,190 objects, 27,828 state fields).
Both comparisons checked topology and RNG state. The 90-assertion
mixed-cadence suite also compared a native 24 + 26 hour continuation
with a continuous 50-hour run and ordinary PSE, including retained history.

AMAPSim passed 274 host assertions and 45 admission assertions. With
all outputs retained, the safe executable matched ordinary PSE byte for
byte for Branch46 (four plants, 16 steps, 189 objects) and stochastic
Merisier (one plant, eight steps, 735 objects).

The MAESPA daylight executable matched all 28,202 ordinary PSE records
over 24 half-hour steps with all outputs retained. The case covers the
two-tree canopy and soil model without Tuzet stomatal conductance.

The native builds used PSE revision `db34842e5`.

| Executable | SHA-256 |
| --- | --- |
| XPalm and mixed cadence | `d2a2bc0c7cc30974536eb45fd412602b2763f75250e2b3566715a35bc5633029` |
| AMAPSim | `fa83b676087aceb6ea0a70fd5a6d0770ca9150bf4a51d7a4de3ce096715f6d5b` |
| MAESPA daylight | `bcf7a047be6f0e66531401fe919f7a801d6efcd9f00baf9ae185cf3f8fe62329` |
