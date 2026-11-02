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

The core changes do not establish a general warm-PSE speedup. MAESPA execution improves by 0.6–15.3% in these engine comparisons. XPalm is mixed: the 256-day case without requested outputs improves, while retained 256-day and 1024/4160-day cases regress. These negative results remain part of the qualification; the downstream typing ports are reviewed and measured separately.

[Raw timing checkpoints and source inventories](results/engine/), [runtime/dependency comparison](results/engine/environment/clean-environment-comparison.json), and [summary](results/engine/summary.json) preserve the controls. Full raw observations remain at the recorded local paths, with hashes/counts in every checkpoint; large record dumps are not added to Git.

```sh
python3 benchmark/regular_execution/summarize.py \
  benchmark/regular_execution/results/engine \
  benchmark/regular_execution/results/engine/quiet \
  /tmp/regular-engine-summary.json
```
