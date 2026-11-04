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
canonical default reference while its producer is absent. A new distributed
writer origin that would change a filtered or temporal producer on an
already committed destination fails explicitly. This case needs the ordinary
PSE lifecycle refresh to rebind the existing destination before it can be
admitted.

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
