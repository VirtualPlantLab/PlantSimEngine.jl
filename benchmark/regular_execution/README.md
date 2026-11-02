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
call evaluation and publication machinery. Call-target identity/status/topology accessors resolve the owning composite
model; `runtime_model(::CallTarget)` continues to return the scientific kernel.

## Controls

The engine control is commit `48492cb1df603864ac88c34f75011b0cf011d907`,
frozen before the production changes. Its core source, dependencies and example
assets are retained separately from the candidate checkout. The first candidate
commit is `c35182428`.

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
suite remains the broader behavioral gate. Results and completed coverage are
recorded below after the accepted comparison runs.
