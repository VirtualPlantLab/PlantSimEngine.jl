> Historical first-fixture qualification at `a8c1619d`, before manual calls and
> original XPalm support. Its source/artifact hashes and timings describe that
> revision. See [current XPalm qualification](xpalm/README.md) for the new case;
> the current branch also includes a small selector-normalization production fix.

# Local qualification, 2026-11-01

Julia 1.13.1, JuliaC 0.3.12, Apple M3 Max, macOS arm64. All Julia evaluation and
build orchestration used private Kaimon sessions belonging to this worktree.
Production PSE sources and downstream package sources are unchanged.

## Reusable program

**512 targeted assertions pass**, including exact Float32/Float64 states,
ordinary biomass history, varied values/populations/IDs, shared live references,
independent simulations, birth from empty/nonempty populations, admission errors
and parameter-dependent protocol changes. Every region's row vector is the exact
canonical status vector, so a birth appends it once without rebuilding bindings.
This is a one-category cohort proof. It does not implement general object
membership, kernel-driven lifecycle, calls, temporal inputs or retained streams.

## Warm Julia-level screen

`screen.json` contains all six balanced forward/reverse cycles after one warmup
cycle. Same original kernels, parameters, forcing, arithmetic, application/object
order and exact final results. Common weather construction is excluded in all
arms. Ordinary preparation includes scene construction and zero-step PSE
compilation; program preparation per run includes direct state construction and
binding. Program definition preparation is done once, separately (20.25 µs in
this warmed observation). The hand reference allocates the same status schema
and runs the original scientific methods, omitting validation and scheduler work.

32 objects × 128 steps, median microseconds:

| Arm | Per-run preparation | Execution | Preparation + execution |
|---|---:|---:|---:|
| Ordinary PSE, outputs=:none | 1,571.77 | 124.94 | 1,697.40 |
| Reused program | 8.88 | 5.83 | 14.27 |
| Direct Julia assembly | 1.48 | 3.96 | 5.52 |

The program remains about **1.47× the direct execution time** and 2.58× its
complete per-run cost on these extremely small scientific kernels. The remaining
absolute execution difference is about 1.87 µs. This is encouraging bounded
prototype evidence, not completion of the general direct-execution performance
goal and not an XPalm speedup. No process-cold comparison, exclusive-machine
reservation, million-object case or downstream performance qualification was run.
Warmup does not itself establish universally absent JIT. Raw timings remain a
small local screen, not a stable performance forecast.

`allocations.json` records five additional warmed execution calls: all allocate
zero bytes, excluding state construction and collection. Timed sample allocation
counts remain in `screen.json`; small nonzero incidental counts are retained.

## Native executable

The current build uses **safe trimming** and generic CPU, with no extra arbitrary
entrypoints. The last warmed build's instantiate/precompile + native compilation
takes 10.36 s, linking 0.045 s, bundling 0.423 s. These phases exclude initial
JuliaC loading and are not process-cold compiler measurements. The first build
job took about 64 s including package/tool initialization and warmup effects.
`provenance.json` records the exact artifact and source hashes and phase timings.

`native.json` compares five CLI cases exactly with ordinary PSE, including
boundary births from zero and one populated cohort. It also checks a copied
bundle and three invalid inputs. Each launch creates a fresh native process.
Its wall time includes shell/process startup, Julia runtime/package initialization,
input parsing, direct state construction, scientific execution and printing;
these are not isolated scientific runtime measurements. The Julia-side launcher
helper is warmed before timing.

A real distribution defect was found and repaired: running with an empty external
Julia depot initially failed in `tree_sitter_julia_jll.__init__` (artifact lookup).
The artifacts were bundled, but their lookup needed configuration before package
initialization. `bin/run-pse-program` now sets JULIA_DEPOT_PATH to the bundle's
`share/julia` and executes the native `bin/pse_program`. The relocation check
supplies an empty external depot, which this launcher replaces with the shipped
depot. This verifies same-host relocation and absence of a package-cache dependency
for the tested entry, not arbitrary platform or CPU portability.

No JuliaC library ABI, original XPalm release, general zero-JIT guarantee, full
PSE suite or scientific release qualification is claimed. The next implementation
steps are multiple cohorts, cross-object bindings, calls/evaluate/accept and PSE
lifecycle/publication boundaries before original downstream qualification.

The prior indexed-row measurements and their caveat are retained in `indexed/`
at source commit `67cb7292`.
