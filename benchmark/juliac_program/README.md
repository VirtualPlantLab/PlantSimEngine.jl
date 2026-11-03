# Reusable composite program and JuliaC experiment

See the [user guide](USER_GUIDE.md) to build the examples, adapt a scenario
and diagnose common compilation failures.

The complete pinned XPalm `architecture=false` graph now compiles with JuliaC
**safe trimming**. All 61 original applications run, including carbon allocation,
reserves, vegetative growth and seeded male/female emission. Four native cases
and relocation pass 21,457 assertions against ordinary PSE. See the
[full-graph qualification, evidence and CLI](results/full/README.md).

The earlier [structural phytomer](results/phytomer/README.md) and
[soil/root](results/xpalm/README.md) entries remain available and pass in the same
final executable. XPalm is pinned to
`5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd` in the isolated app environment.
XPalm's scientific kernels and sources are unchanged. The separate AMAPSim and
MAESPA experiments use archived inference-typing variants and retain untouched
ordinary-PSE source controls.

## Larger workloads and registry scenarios

The [XPalm scaling report](results/scaling/README.md) compares ordinary PSE,
prepared execution and actual safe/generic JuliaC binaries. Unchanged package
parameters are distinct from the accelerated stress profile. At 4,160 days,
the native run takes 3.879 s versus ordinary PSE's 4.744 s: the short-case
speedups do not extrapolate to long trajectories.

The downstream repositories own their scenario drivers, baseline comparisons,
parity checks and reproduction instructions.

- [AMAPSim JuliaC qualification](https://github.com/VEZY/AMAPSim.jl/pull/14) covers native architecture,
  analytic geometry, stochastic growth and removals in seven cases.
- [MAESPA JuliaC qualification](https://github.com/VEZY/MAESPA.jl/pull/15) covers eight non-Tuzet canopy/soil
  profiles, with two or eight trees, 24 or 96 steps, and all or no retained
  outputs.

The [original qualification archive](https://github.com/VirtualPlantLab/PlantSimEngine.jl/tree/ff8b6e5c2d5ad1388f062627aa07a159e48df4c7/benchmark/juliac_program)
preserves the PSE-side reports and raw results at the handoff revision.
The registry executors and launcher stay in PSE. The ordinary MAESPA comparison
continues to use the shared fixture and record codec.

The new registry runtimes may resolve a private ordinary graph at authoring
time, then retain only owned typed numerical data and execution recipes.
Their runtime contains no ordinary executor fallback. This is distinct from
the original XPalm frontend's direct `ModelSpec` lowering described below.

## Prepared program and admitted subset

`app/src/program.jl` derives an immutable typed call tree and root order directly
from `ModelSpec` and existing contracts. It does not construct an ordinary
`Simulation`/plan and then perform a second lowering. Models/parameters, IDs,
weather, canonical Ref-backed statuses and publication storage belong to each
simulation. Counts, IDs and values remain data. All regions in the admitted
cohort share the canonical status vector without copying scientific values.

The original homogeneous layout admits one category, scalar isbits state, unique local
writers, inferred same-object inputs, typed externally supplied required inputs,
one fixed positive cadence and complete plain NamedTuple environment rows.
Manual calls identify one application on the same object; the parent decides
which targets to execute and when. Callees are excluded from the root schedule.
Call-only inputs do not introduce new implicit ordering on their parent.

Call targets expose status/object ID and returned collections preserve live
status aliases. Runtime graph access through targets is not implemented. Published
calls retain one final sample per application/object/timestep. Unpublished
ancestors suppress descendant publications transitively. Targets capture their
invocation timestep. Scientific variable contracts use PSE's existing validator
and are rechecked when models/parameters are replaced. Declared environment
sources are required even for potentially skipped children, as in ordinary PSE.

`add_object!` adds a known-schema object at a host-controlled timestep boundary,
including to an empty cohort. The XPalm case tests root-depth growth and addition
of independent soil columns. The homogeneous layout does not implement MTG lifecycle. The new cohort layout
covers the bounded phytomer subtree described above. The full layout extends
the same grammar to the pinned daily whole-palm graph, PreviousTimeStep inputs,
distributed columns and ordered writers. It takes the root application schedule
from the same resolved CompositeModel plan as ordinary PSE, including entries
whose first targets appear during growth. Call routes take their target
application, mode and multiplicity from that plan. Distributed output routes
use its variable partitions and destination selectors. Input routes use its
potential producers for both explicit and inferred couplings, including
applications that start without objects. The typed executor resolves object
membership as the topology changes and prepares its binding and storage recipes.
Its qualification is reported separately
in the full-graph evidence above. Evaluate/accept, general temporal policies and
custom spatial environments remain outside the current cases.
Unknown declarations/context operations are rejected or fail explicitly; no
ordinary runtime fallback is hidden inside this prototype.

A production correction in `src/composite_model/selectors.jl` preserves
concrete tuple types while normalizing selector keywords and validating their
names. This closes the original XPalm `dep(Call(process=...))` path under safe
trimming without changing selector semantics. Process authoring also constructs
terminal tutorials only when they are actually displayed, avoiding unused
terminal backend initialization in noninteractive JuliaC builds.

## Julia-level checks through Kaimon

For the original local fixture, use a Kaimon session at the repository root:

```julia
include("benchmark/juliac_program/app/src/program.jl")
include("benchmark/juliac_program/app/src/fixture.jl")
include("benchmark/juliac_program/checks.jl")
include("benchmark/juliac_program/call_checks.jl")
ReusableProgramChecks.run_checks()
NativeCallChecks.run_checks()
```

For XPalm, open a dedicated Kaimon session at `app/`, inspect its environment,
then evaluate (these relative paths are from that session's directory):

```julia
include("src/program.jl")
include("src/xpalm_fixture.jl")
include("../xpalm_checks.jl")
XPalmChecks.run_checks()
```

All canonical states and each original output's full publication series are
compared with ordinary PSE across fourteen cases, varied values/IDs/populations,
and births from zero. See [current XPalm evidence](results/xpalm/README.md).
These targeted checks do not replace scientific or whole-package qualification.
Reload these standalone modules after edits; they are not Revise-tracked package
files. The existing local-fixture timing driver `screen.jl` remains available,
but its recorded figures describe the earlier fixture backend, not XPalm.

## Native executable

Open a separate Kaimon session at `buildenv/`, inspect it, then
`include("../build.jl")`. JuliaC 0.3.12 remains outside PSE's dependencies. Builds
use `trim_mode="safe"`, `cpu_target="generic"` and no arbitrary entrypoint or
unsafe bypass. Each build creates a new bundle and writes its path to
`build/latest.txt`. Distribute that entire bundle. Its `bin/run-pse-program`
configures lookup of bundled artifacts before executing native `bin/pse_program`.

The CLI now has an explicit mode followed by eight numeric inputs:

```text
fixture population steps birth_at newborns id_offset efficiency conversion temperature
xpalm   population steps birth_at newborns id_offset initial_root_depth root_rate rainfall
```

Counts/IDs use Int, scientific inputs Float64. Births happen before `birth_at`;
zero disables births and requires `newborns=0`. XPalm uses fixed initial
ET0=2.5/aPPFD=1.0 and daily forcing defined by `XPalmFixture.rows`. It prints a
population/timestep header, then object ID and all 23 state fields in
`XPalmFixture.STATE_VARIABLES` order. Example:

```text
/path/to/bundle/bin/run-pse-program xpalm 0 4 2 1 500 200.0 0.4 10.0
```

After loading the XPalm modules in the app Kaimon session, evaluate:

```julia
include("../xpalm_native_checks.jl")
XPalmNativeChecks.run_checks()
```

The native check compares every final state variable exactly on five cases and
copies the bundle to a new directory before repeating a birth case with an
empty external depot. The launcher replaces that depot with the shipped one.
Native final-state parity and Julia-level publication-series checks are distinct.
No process-cold speedup, universal zero-JIT or cross-platform portability claim
is made. A native library ABI remains future work. The `phytomer` mode covers
the qualified structural subtree, while `full` runs the complete pinned daily
`architecture=false` XPalm graph described at the top of this page.

Official compiler: [JuliaC](https://github.com/JuliaLang/JuliaC.jl).
