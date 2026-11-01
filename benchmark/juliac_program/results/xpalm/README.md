# First original XPalm case, qualified 2026-11-01

The pinned XPalm revision is `5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd`.
No XPalm source is modified. The admitted subgraph uses its original
DailyDegreeDays, FTSW and RootGrowthFTSW methods. FTSW's existing `dep` supplies
its call. Only thermal time and soil water are scheduled; FTSW executes root
growth with live parent state and publishes it before finishing its water balance.
Program construction is direct from declarations, with no ordinary PSE plan
followed by a second lowering. Native instantiation constructs model parameters
and state, not ModelSpec or a scenario plan.

## Executed qualification

Julia 1.13.1, JuliaC 0.3.12, Apple M3 Max/macOS arm64. Julia sessions and build
orchestration run through private Kaimon sessions for this worktree. The native
build uses safe trimming and generic CPU, without unsafe fallback or arbitrary
extra entrypoints. Source and binary hashes are in `provenance.json`.

- **926 assertions** pass in the new selector-inference test and existing empty
  selector-scope, object-ID and unified CompositeModel/Object integration files.
- **512 assertions** preserve the original local fixture matrix.
- **255 assertions** compare generic calls against ordinary PSE: conditional and
  selected targets, nested publication suppression, reference aliasing, exclusion
  of callees from the root scheduler, unchanged implicit ordering of call-only
  inputs, coalescence of repeated same-step publications, invalid IDs, complete
  environment schema requirements and parameter-dependent scientific contracts.
- **627 assertions over fourteen XPalm cases** compare all canonical variables
  and every original output's full publication series. They vary scientific
  values, forcing, IDs/populations, and add a newborn at a boundary from zero or
  one initial soil object. `checks.json` records the prototype counts.
- **Five native XPalm cases plus relocation** compare all **23 state variables**
  exactly against ordinary PSE, including zero initial population, multiple births,
  different parameters/IDs, a dry eight-day case and a copied bundle with an empty
  external depot. `native.json` contains the inputs and full expected/actual states.
- The revised CLI also preserves the five original fixture cases, relocation and
  three rejected inputs (`fixture-native.json`).

Native final-state comparisons and Julia-level publication-series comparisons
are distinct; the native entry currently uses unretained simulation outputs and
prints the final state table. No complete-package or scientific qualification is
inferred from these targeted checks. The CI state is reported in the PR itself.

The successful final build records 11.36 s for app instantiate/precompile + native
compilation, 0.049 s linking and 0.527 s bundling. Caches were warm; initial JuliaC
loading and prior failed builds are excluded. These are build phases, not
scientific runtime or process-cold measurements. No XPalm timing speedup was
benchmarked. A separate allocation diagnostic observes **1,536 bytes** in each
of five warmed loops (four soils × eight steps, no construction/retention/IO).
The allocation source is not yet attributed; no zero-allocation XPalm claim is made.

## What the safe verifier found

The initial builds failed on real unresolved calls. No error was bypassed:

1. Re-evaluated `dep` declarations initially had existential selector types at
   comparison. The binder now checks their concrete schema before comparing.
2. The selector constructor normalized heterogeneous keyword pairs through a
   generator, losing the concrete `One` type. A small production correction maps
   the typed key/value tuples instead. Known key names are validated before
   allocating a diagnostic list, so irrelevant dynamic error construction is
   absent from this fixed schema. New inference tests preserve different values
   in the same selector types and check normalization/error behavior.
3. Default validation looped over heterogeneous models/ports and widened a
   declaration's payload to Any. Typed tuple recursion now preserves each
   existing declaration's concrete payload while retaining the same validation.

A preliminary native comparison failed because its parser returned a plain tuple
while the ordinary fingerprint was a NamedTuple; correcting that host-side shape
left the identical printed numerical values unchanged. An added skipped-child
check initially assumed missing environment fields were valid. Ordinary PSE
rejects missing declared sources during preparation, even for an uncalled child;
the corrected test now checks rejection and separately checks skipped execution
with a complete environment. Standalone prototype modules are re-included after
edits because they are not package files tracked by Revise.

## Growth scope and next boundary

This case demonstrates **root-depth growth** and host-controlled addition of
independent soil columns between timesteps, including a previously empty cohort.
It does **not** implement original PhytomerEmission, MTG node creation, multiple
organ categories, newborn initializers, evaluate/accept, multirate temporal inputs,
distributed outputs, custom spatial environments, a library ABI or a whole palm.

A read-only audit identified the smallest original phytomer-emission neighborhood:
DailyDegreeDays, DailyPlantAgeModel, PhyllochronModel, PhytomerEmission;
InitiationAgeFromPlantAge on Phytomer/Internode/Leaf;
FinalPotentialInternodeDimensionModel, FinalPotentialAreaModel and two RmQ10FixedN
applications. It requires five targeted calls, two initializers and MTG lifecycle
operations. An initial Phytomer anchor is required by XPalm's constructor, while
Internode/Leaf categories may start empty. None of that source audit is execution
or trimability evidence. Multiple typed cohorts and those exact PSE lifecycle
boundaries are the next implementation step.

See [reproduction instructions](../../README.md). Earlier local-fixture speed
measurements remain historical and do not predict this XPalm case's performance.
