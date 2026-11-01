# Complete XPalm graph compiled with JuliaC safe, 2026-11-01

All 61 original `architecture=false` XPalm applications now execute through the
prepared typed program and a JuliaC **safe-trimmed executable**. The reproductive
case grows from 8 to 54 real MTG objects, including 7 Male and 3 Female organs,
with full state/output parity against ordinary PSE. XPalm is pinned to
`5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd` (v0.7.0); its scientific kernels and
sources are unchanged.

The subsequent [cached-runtime qualification](../reuse/README.md) records the
latest implementation, safe bundle, focused gates and matched before/after
timings. The original full-graph evidence below remains an identifiable source
cohort rather than being overwritten by the follow-up.

After building, run the complete bundle's launcher:

```text
/path/to/bundle/bin/run-pse-program full days phyllochron_rate reproductive
/path/to/bundle/bin/run-pse-program full 3 0.05 false
/path/to/bundle/bin/run-pse-program full 12 0.3 true
```

`build/latest.txt` identifies the latest bundle. Keep the whole bundle together.
Duration and phyllochron endpoints are runtime data. The reproductive parameter
set changes only the original inflorescence thresholds to flowering=30,
abortion duration=6 and sex-determination duration=12 degree days, with both RNG
seeds set to 1. These accelerated test inputs exercise original kernels; they
are not calibration or production phenology recommendations.

## Executed parity gates

| Gate | Assertions | Coverage |
| --- | ---: | --- |
| Complete Julia executor | 108,606 | Every canonical scientific field and topology after every step; every retained output key/value; RNG fingerprints/draw counts; first-day newborns; no-retention execution; independent states with actual RNG advancement |
| Complete safe executable | 21,457 | Four CLI cases, all final canonical fields, complete retained streams, future RNG fingerprints, exact topology and same-host relocation |
| Previous Julia layouts | 1,516 | Fixture, manual calls, soil/root, structural phytomer and focused lifecycle contracts |
| Previous native modes | 25 | Five fixture, five soil/root and four phytomer cases, three invalid inputs and relocation of all three modes |
| ObjectId formatting | 4 | Typed numeric/symbolic diagnostics, including a Float32 payload |

The complete native cases are:

| Days | Rate | Reproduction | Final objects | Male / Female | Retained samples |
| ---: | ---: | :---: | ---: | ---: | ---: |
| 3 | 0.05 | false | 11 | 0 / 0 | 422 |
| 12 | 0.3 | true | 54 | 7 / 3 | 6,271 |
| 5 | 0.075 | false | 17 | 0 / 0 | 1,026 |
| 9 | 0.25 | true | 42 | 6 / 1 | 3,791 |

For the main reproductive case, both Julia executors consume exactly 10 scalar
sex-determination and 9 abortion draws, with matching RNG fingerprints after
every step. Native checks compare four future UInt64 draws from copies of each
final scientific RNG, leaving it unchanged. Floating comparisons use rtol/atol
1e-12; IDs, symbolic states, integer values, stream keys and RNG probes are exact.
The relocated full executable reproduces all 54 objects and 6,271 samples from
an empty cwd, fresh HOME and empty external depot; the launcher supplies bundled
artifacts. This is same-host relocation on arm64 macOS, not cross-platform proof.

Structured evidence is in `julia.json`, `carbon.json`, `reproductive.json`,
`native.json`, `legacy-regressions.json`, `native-regressions.json` and
`provenance.json`. The final standard build uses Julia 1.13.1, JuliaC 0.3.12,
safe trimming, generic CPU, no arbitrary entrypoints and no verifier override or
diagnostic preload. Its compilation/link/bundle phases took about 41.87 / 0.15 /
0.98 seconds in the warmed environment. These phases and the recorded host
launch/parser timings are not scientific-runtime benchmarks or zero-JIT claims.

## Measured runtime performance

The follow-up [binding/target reuse report](../reuse/README.md) compares the
pre-cache typed runtime with the final delta runtime. Warm Julia execution is
2.5× faster at 60 days and 4.7× at 128 days, with lower allocation volume and an
explicit retained-state memory tradeoff. Native evidence and reproduction are
recorded separately in that report.

A separate [matched XPalm comparison](performance.md) measures the original PSE
graph, warm typed Julia execution and the actual safe executable. On this host,
setup plus simulation is about 8.3× faster compiled for the 60-day retained case
(246 objects, 122,554 matching samples), and 8.4× without retained outputs.
These warm-process observations exclude startup/build/printing and use the
accelerated qualification inputs; they are not a general production speedup.

## Typed storage and growth boundaries

The plan derives routes directly from the original ModelSpec tuple, without
constructing or lowering an ordinary CompositeModel/Simulation plan. It has 50
scheduled applications, 11 manual call targets and ten category cohorts.
Per-application status views share live scalar references, provide aligned
reference-backed Many inputs, and keep temporal scratch values private.
Producer-specific PreviousTimeStep histories survive `retain=false`; distributed
columns and explicitly ordered Updates writers publish their own values before
later writers mutate canonical status. New consumers retain their own initial
fallback when no preceding sample exists.

Each simulation owns its model/RNG copies, status references, histories and
actual MTG topology. RNG-consuming applications execute in ascending ObjectId
order. Registration exposes newborns immediately to targeted calls; ordinary
memberships change at the creator barrier. Initializers keep their normal
schedule and canonical ownership, return canonical Status and publish no extra
midstep sample. Failure leaves an unfinished event that cannot be silently
retried.

Authoring imports the original Palm topology and scientific status policy into
typed records. Native execution reconstructs genuine
`Node{NodeMTG,NamedTuple{(),Tuple{}}}` nodes using MTG constructors and attachment
operations. Scientific status belongs to the registry. Palm construction,
parameter loading, ModelSpec construction and preparation happen at build time.
The native entry uses original model instances and their original run! methods.
The output protocol includes F metadata, T topology for every object (including
empty Stem status), S canonical variables, O retained samples and R RNG probes.

Application/port schemas use direct generated field access where Base's large
tuple map/tail paths would lose type information. Application storage is private
heap state, with concrete batch boundaries. ObjectId has a typed PSE display so
original XPalm validation messages avoid reflective fallback. These changes do
not encode organ counts, IDs, parameter values or days into generated methods.
Temporary compiler-display hooks helped diagnose failures by abbreviating SSA
and backtrace text; the qualified final build runs the original verifier without
those hooks.

## Reproduce through Kaimon

In a Kaimon session at `benchmark/juliac_program/app`:

```julia
include("../full_xpalm_checks.jl")
FullXPalmChecks.run_checks()
```

Build in a Kaimon session at `benchmark/juliac_program/buildenv`:

```julia
include("../build.jl")
```

Then, in the app session:

```julia
include("../full_xpalm_native_checks.jl")
FullXPalmNativeChecks.run_checks()
```

This qualifies the complete pinned daily `architecture=false` graph for one
original Palm under these forcing/parameter cases. Architecture rendering,
arbitrary MTG attribute stores/schemas, spatial environments, general multirate
policies, heterogeneous overrides, evaluate/accept calls and topology
removal/reparenting are outside this entry. Scientific calibration and broader
production performance remain separate work.
