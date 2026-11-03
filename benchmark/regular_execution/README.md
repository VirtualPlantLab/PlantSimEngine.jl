# Typing and execution in regular Julia

These checks bring useful typing boundaries from the standalone experiments
into the ordinary packages. Simulations use `run!`, `continue!` and `step!`.
No JuliaC installation, native bundle or alternate executor is required.

The PSE changes retain concrete object identity types in execution targets,
contexts and call views; concrete homogeneous batch vectors at an application
boundary; and concrete homogeneous private initial values for temporal `Many`
inputs. Counts, application identifiers and object identity values remain data.
Heterogeneous batches retain their original order and supported schemas.
Topology changes continue through PSE's normal lifecycle refresh, environments,
call evaluation and publication machinery. Call-target identity/status/topology
accessors resolve the owning composite model; `runtime_model(::CallTarget)`
continues to return the scientific kernel. Rebuilding temporal memberships
preserves saved numeric types even when newly observed values have another
schema.

Both materialized and bulk calls cross the same kernel boundary with their
mutable execution owner. When sampling erases the environment type, the kernel
reads the concrete model/status/output payload after dispatch. This avoids
boxing those immutable payloads as separate dispatch arguments. Evaluation,
publication, leases and input materialization retain their existing paths.
Model discovery separately visits each loaded module once per query, without a
persistent world cache; this is a metadata improvement, not a numerical speedup.

## Controls

The engine control is commit `48492cb1df603864ac88c34f75011b0cf011d907`,
frozen before the production changes. Its core source, dependencies and example
assets are retained separately from the candidate checkout. The first candidate
commit is `c35182428`; the final qualified production source is `16a8ba182`.

Package typing and executor effects are measured separately. A package-only
comparison holds PSE at the frozen revision. An engine-only comparison holds the
scientific package source fixed. A combined comparison runs the ported package
with the candidate PSE. Do not multiply ratios or compare rows from different
source/configuration cohorts.

The MAESPA engine comparison uses the untouched source from the earlier full
scenario experiment. The MAESPA package port has its own fresh control at
current main `c45e4b5dee1b574eaa7ea1f472c20d069ca53755`. These are distinct
scientific source cohorts. AMAPSim's package control remains
`86a3215e4a8ec24cb568e238007612e43e9600b5`.

## Reproduction

Start the desired isolated project through Kaimon, develop compatible package
revisions together, and verify `pkgdir` before loading a driver. Keep optional
downstream dependencies out of `benchmark/Project.toml`.

For the complete MAESPA native canopy/soil example, set `PSE_MAESPA_PATH` to the
chosen source before loading its package. The driver reuses the earlier public
scenario fixture and canonical record codec, without loading its experimental
executor or JuliaC:

```julia
include("benchmark/regular_execution/maespa.jl")
RegularMAESPAExecution.measure_matrix(;
    destination="/absolute/new-candidate-directory",
    baseline_directory="/absolute/frozen-baseline-directory",
    samples=3,
)
```

The matrix covers one/four two-tree tiles, 24/96 half-hour steps and `:all`/`:none`
retention. Every trial constructs an independent public model. Configuration,
source and environment hashes guard comparisons. Final result paths are
immutable; use another directory for a repeat. Raw baseline records must match
their recorded count and every sample hash before timing starts.

For unchanged XPalm parameters and its full `architecture=false` graph:

```julia
include("benchmark/regular_execution/xpalm.jl")
RegularXPalmExecution.measure_matrix(;
    destination="/absolute/new-candidate-directory",
    baseline_directory="/absolute/frozen-baseline-directory",
    samples=3,
)
```

Its matrix covers 256 days with both retention modes and 1,024/4,160 days with
no requested retained outputs. Forcing is the existing synthetic daily fixture;
this is an engine comparison, not a scientific calibration or architecture-on
qualification.

Each driver excludes one warmup and records at least three fresh measured
simulations. Construction/authoring, preparation, and complete-timeline execution
have separate clocks and allocation counts. Snapshotting, formatting, validation
and GC before construction are outside those clocks. The recorded warmup is a
first observation in the current process, not a fresh-process cold benchmark.
Run accepted timing cohorts serially, outside test/compilation activity.
The recorded qualification uses Julia 1.13.1, two compute threads and one GC
thread on Apple M3. The optional drivers use Julia's compilation counters from
`@timed`; they do not change PSE's Julia compatibility requirement. Every timed
phase must report zero compilation and recompilation. Reachable simulation
bytes use `Base.summarysize`, not process RSS or peak memory.

## Parity

MAESPA checks every final status, object identity, geometry, ordered topology,
retained stream key (including empty streams), sample value/timestamp, committed
canopy state and construction RNG snapshot against its frozen control. There are
no simulation-owned stochastic generators in this fixed MAESPA scenario.
XPalm checks complete status values, ordered topology, histories and full states
of its model-owned RNGs. Mutable payload snapshots are taken outside timers.

Focused PSE checks cover concrete Symbol/integer/tuple-valued IDs, heterogeneous
identity schemas, transient call environments, call views, continuation,
homogeneous Float32/Float64 temporal snapshots, empty memberships, growth,
removal of the last target and subsequent growth. The package's full regression
suite remains the broader behavioral gate. Completed coverage and accepted measurements are recorded below.

The final owned-call change passes 3,879 assertions across 19 focused call,
environment, lifecycle, identity and temporal files. This includes 32 new
Float32/Float64 bulk-call allocation checks with both publication settings.
Generated-source tests run in their required `Main` namespace. Broader coverage
comes from the earlier functional suite, its corrected hard-call rerun, all
remaining functional files, Aqua and doctests; these are aggregate gates rather
than one final all-green full-suite invocation.

[Owned-call evidence](results/bulk_owned_calls.json) retains the isolated
old/new allocation and inference experiment. For 64,000 calls it removes about
192 bytes of boxing per call, with exact scalar work and released leases.
Its timing observations are excluded because other untimed qualification work
was active. The portable regression is
`test/test-model-materialized-call-dispatch.jl`; the small source archive is
historical evidence, not another runtime.

The source ports are reviewed separately in
[AMAPSim #13](https://github.com/VEZY/AMAPSim.jl/pull/13) and
[MAESPA #14](https://github.com/VEZY/MAESPA.jl/pull/14). MAESPA's
[package-only report](https://github.com/VEZY/MAESPA.jl/blob/codex/maespa-regular-typing/benchmark/ordinary_typing_2026-11-02.md)
keeps all eight measurements and the short retained-output regression. Its
earlier tested-world source-only cohort is distinct from the final clean
combined comparison.

## Changing PSE alone

These are separate matched controls at PSE 48492cb1 and 16a8ba182, with unchanged science. Both processes have the same 16 loaded package/version/project images and no test runner, Aqua or Documenter modules. Each row contains three fresh measured simulations per arm, plus an excluded warmup; all 72 measured simulations match the complete scientific observations and have zero phase compilation. The eight bounded quiet windows, all 24 case intervals and exact checkpoint hashes are archived.

| Scenario | Baseline execution | Candidate execution | Execution ratio | Complete ratio |
| --- | ---: | ---: | ---: | ---: |
| MAESPA 1 / 24 / none | 84.11 ms | 82.26 ms | 1.022× | 1.025× |
| MAESPA 1 / 24 / all | 86.44 ms | 81.62 ms | 1.059× | 1.019× |
| MAESPA 1 / 96 / none | 233.94 ms | 228.23 ms | 1.025× | 1.020× |
| MAESPA 1 / 96 / all | 241.72 ms | 240.21 ms | 1.006× | 0.996× |
| MAESPA 4 / 24 / none | 338.72 ms | 332.60 ms | 1.018× | 0.994× |
| MAESPA 4 / 24 / all | 366.25 ms | 317.74 ms | 1.153× | 1.114× |
| MAESPA 4 / 96 / none | 961.65 ms | 935.34 ms | 1.028× | 1.024× |
| MAESPA 4 / 96 / all | 1020.98 ms | 1015.11 ms | 1.006× | 0.983× |
| XPalm 256 / none | 106.23 ms | 99.53 ms | 1.067× | 1.004× |
| XPalm 256 / all | 152.67 ms | 158.36 ms | 0.964× | 0.979× |
| XPalm 1024 / none | 534.04 ms | 559.90 ms | 0.954× | 0.951× |
| XPalm 4160 / none | 5190.50 ms | 5235.00 ms | 0.992× | 0.988× |

Ratios are baseline/candidate; values below 1 mean a slower candidate. Complete time is the median of each fresh trial's construction + preparation + execution sum, with observation/formatting and pretrial GC excluded. The MAESPA science here is the older full-scenario cohort, not the current-main c45 control used by the package port.

The core changes do not establish a general warm-PSE speedup. MAESPA execution
ratios are 1.006–1.153× in these engine comparisons. XPalm is mixed: the 256-day
case without requested outputs improves, while retained 256-day and
1024/4160-day cases regress. The longest XPalm case also allocates about 2.3%
more during execution. These negative results remain part of the qualification;
the downstream typing ports are reviewed and measured separately.

[Raw timing checkpoints and source inventories](results/engine/), [runtime/dependency comparison](results/engine/environment/clean-environment-comparison.json), and [summary](results/engine/summary.json) preserve the controls. Full raw observations remain at the recorded local paths, with hashes/counts in every checkpoint; large record dumps are not added to Git. The [independent audit](results/engine/independent_audit.json) verifies the archived checkpoints against original observations, source revisions and actual quiet windows.

```sh
python3 benchmark/regular_execution/summarize.py \
  benchmark/regular_execution/results/engine \
  benchmark/regular_execution/results/engine/quiet \
  /tmp/regular-engine-summary.json
```

## Regular MAESPA and PSE together

This separate comparison uses current main MAESPA `c45e4b5` plus PSE
`48492cb1` as the baseline, and MAESPA scientific source `905e2a4` plus PSE
`16a8ba182` as the candidate. Both fresh processes use the same dependencies;
all eight full canopy/soil cases match complete observations. These are warm
execution medians, with three measured fresh simulations per arm/case.

| Scenario | Baseline | Combined | Baseline / combined |
| --- | ---: | ---: | ---: |
| Two trees, 24 half-hour steps, none requested | 16.65 ms | 11.91 ms | 1.399× |
| Eight trees, 96 half-hour steps, none requested | 137.33 ms | 92.23 ms | 1.489× |
| Eight trees, 96 half-hour steps, all outputs | 214.44 ms | 168.75 ms | 1.271× |

All eight execution ratios are 1.159–1.489×; execution allocations fall by
6.8–22.8%. Reachable simulation memory is close to the baseline. Construction
and preparation remain separate, so these execution ratios are not complete
simulation ratios. The package-only source cohort and the older-science PSE
comparison above remain separate controls.

The [complete report, raw phase samples and independent audit](https://github.com/VEZY/MAESPA.jl/blob/codex/maespa-regular-typing/benchmark/combined_typing_2026-11-02.md)
record all eight cases, all 48 measured trials, 512,836 exact observation records
and every quiet-window interval. Neither ratio multiplication nor a universal
ordinary-runtime speedup is claimed.

## Regular AMAPSim and PSE together

This uses the actual default MTG engine and public `build_initial_topology` /
`build_model` / `run!` path. The baseline is AMAPSim `86a3215` plus PSE
`48492cb1`; the candidate uses the shared-core AMAPSim source `a05ee61` plus
PSE `16a8ba182`. Both application environments and 21 actual package-source
inventories match except for those two intentional revisions. This is distinct
from the experimental arena/projection controls.

| Scenario | Baseline execution | Combined execution | Baseline / combined | Complete ratio |
| --- | ---: | ---: | ---: | ---: |
| Branch46 / 1 / all | 4.122 ms | 4.085 ms | 1.009× | 1.017× |
| Branch46 / 1 / none | 3.872 ms | 3.983 ms | 0.972× | 0.986× |
| Branch46 / 4 / all | 13.863 ms | 14.255 ms | 0.973× | 0.963× |
| Branch46 / 4 / none | 13.652 ms | 13.889 ms | 0.983× | 0.989× |
| Merisier / 1 / all | 16.444 ms | 16.746 ms | 0.982× | 0.958× |
| Merisier / 1 / none | 16.179 ms | 16.463 ms | 0.983× | 0.983× |
| Merisier / 4 / all | 53.456 ms | 55.477 ms | 0.964× | 0.961× |
| Merisier / 4 / none | 53.381 ms | 54.935 ms | 0.972× | 0.969× |

There is **no demonstrated warm performance gain for default AMAPSim** in this
combined cohort. Seven execution medians are slower and one is slightly faster;
the largest retained-output case changes from 53.456 to 55.477 ms. The source
and PSE effects are not separated by this two-arm comparison. These results
remain visible rather than being replaced by the much larger standalone
executor ratios from a different graph/cohort.

Five fresh simulations per arm/case give 80 accepted measurements, with zero
phase compilation or recompilation. Every trial matches the final logical
state/status/geometry/history/work/RNG fingerprint. Separate qualification
gates compare 32 intermediate boundaries per arm, including byte-identical
public MTG exports and read-back data. Those exports are not repeated in every
timed trial. Four-plant Merisier arms occupy separate bounded quiet windows
because full untimed validation dominates the wall-clock duration.

The [complete report and original five-sample checkpoints](https://github.com/VEZY/AMAPSim.jl/tree/codex/amapsim-ordinary-typing/dev/evidence/shared-planner-2026-11-03/combined-primary)
preserve all phase samples and negative measurements, plus independent Float32,
mortality, sympody, cached-funding and C++ fixture checks. Typing/inference
witnesses establish the finite payload and numeric/alias contracts; they are
not an end-to-end speed claim.
