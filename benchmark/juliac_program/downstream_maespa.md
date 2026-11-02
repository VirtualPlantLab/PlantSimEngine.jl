# Complete MAESPA scenario: fixed registry prototype

The complete selected public non-Tuzet canopy/soil scenario compiles with
**JuliaC safe/generic**. All eight native cases match untouched-source ordinary
PSE exactly: final canonical status, topology/geometry, committed atmosphere,
stream keys and every retained sample/timestamp. Warm execution is **4.56–6.55×**
faster than the original ordinary executor in these cases. Final inference-typed
ordinary and registry-JIT measurements are still pending, so attribution among
source typing, the new runtime and AOT compilation remains open.

## Original PSE versus native execution

The primary baseline is a fresh ordinary PSE simulation using the unchanged
frozen MAESPA source. One tile contains two trees, 27 objects and 100 applications;
four adjacent equal-area tiles contain eight trees, 99 objects and 292
applications. Plot density is preserved. The 24-step cases start at slot 13;
the 96-step cases start at slot 1 and cover two days, including the night mask
and second-day forcing/rainfall. Each base step is 1,800 seconds.

Median execution milliseconds, three measured fresh simulations per case:

| Trees | Steps | Retained outputs | Original PSE (ms) | JuliaC safe (ms) | Original/native |
| ---: | ---: | :--- | ---: | ---: | ---: |
| 2 | 24 | `all` | 86.657 | 19.000 | 4.56× |
| 2 | 24 | `none` | 80.566 | 17.586 | 4.58× |
| 2 | 96 | `all` | 245.589 | 52.171 | 4.71× |
| 2 | 96 | `none` | 239.512 | 45.545 | 5.26× |
| 8 | 24 | `all` | 359.748 | 68.195 | 5.28× |
| 8 | 24 | `none` | 350.862 | 61.302 | 5.72× |
| 8 | 96 | `all` | 1037.115 | 198.841 | 5.22× |
| 8 | 96 | `none` | 984.623 | 150.218 | 6.55× |

These ratios time the complete simulation advance after setup. Fresh scientific
construction, ordinary preparation, reusable-program authoring, private
instantiation, native build/startup, explicit GC, formatting and parity checks
are separate. GC during execution remains included. Each native process runs
one internally timed P0 warmup, excluded from summaries, followed by trials 1–3.
Native launches request `JULIA_NUM_THREADS=2` and Julia's default GC-thread
setting; the CLI does not report the observed native thread count. The Julia
control sessions observed two threads. Other workers were paused during final
measurement windows.

Every measured ordinary run matches both full records and a full host snapshot
including RNG fingerprints. Each native process emits and validates its final
measured trial; intermediate timed trials are not emitted. An independent,
untimed full native emit also passes for every case. The eight cases compare
512,836 records in total; the largest retained case contains 283,780 records.

[All scalar samples, setup phases and record hashes](results/maespa_scaling/canonical/native_original_summary.json)
and [native qualification/provenance](results/maespa_native_qualification.json)
keep the measured arms and qualification limits explicit. The inference-typed
ordinary arm already passes all eight record and RNG-inclusive snapshot gates.
Its final timings and the registry-JIT matrix are being completed separately;
this table does not attribute the entire ratio to JuliaC.

## Scientific and execution scope

The fixture uses the original public two-species builder with
`mount_leaf_exchange=true`. It executes leaf energy/photosynthesis calls,
radiation, soil water balance, accepted canopy commits, daily/subdaily cadence,
and the original trial evaluation followed by accepted replay. Scientific
kernels, equations, validation predicates, solver work and call ordering are
preserved.

A separate inference-typed source copy supplies the candidate and its typed
ordinary control. Its 26 changed files, out of 208 inventoried files, make
storage types, finite field projections, optional-argument dispatch and compiler
annotations explicit. The original source remains unchanged.
`downstream_maespa_typing.py`, its three helper modules, exact patch and complete
file manifest reproduce the variant. No compatibility layer or alternative
scientific equations are introduced.

`RegistryPrograms.prepare` resolves an ordinary scenario on a private deep copy
at host authoring time, then projects its resolved references and schedule into
owned typed storage. That setup cost is separate from execution. The resulting
program retains no ordinary `Simulation`, `CompiledCompositeModel`, execution
target or `RunContext`; an ownership traversal checks the boundary. Runtime
instantiation, calls, temporal inputs, publication and environment sampling use
the new backend and original scientific kernels. There is no ordinary runtime
fallback.

Application/object identities, ordered execution entries and call memberships
remain data. The compiled root-family set excludes manual-only groups from root
execution contexts. One/four tiles use 68 families, with 145/481 targets. Four
scientific models retain population-sized weight/ID tuples, so the populations
have distinct specializations. This is a fixed-registry, Float64 qualification;
lifecycle changes and temporal policies beyond the selected original
`PreviousTimeStep` policies are not admitted here.

The compiled environment retains the original MAESPA backend, sampler and
validators. Its `GlobalConstant` view shares the original table's concrete
NamedTuple row storage; every instance owns private rows while preserving that
alias. Row values and duration are read fresh. Whole table-storage/schema
replacement is outside this admission. Provider/sink values specialize the
original immutable handle; the original sink and duration checks still run.

The owned seed contains **zero runtime RNGs**. Fixed subdaily forcing and
`AllTargetTrees` do not exercise runtime stochastic branches. Native authoring
archives the two construction RNGs' serialized-state hashes and four draws
from independent copies. These are construction provenance, not native
stochastic coverage; the native record protocol has no RNG rows.

## Native build and relocation

The final eight-case matrix compiled in **746.826 s**, linked in 0.084 s and
bundled in 0.502 s with Julia 1.13.1 / JuliaC 0.3.12, safe trimming and the generic
CPU target. It uses the corrected host build recipe directly, with exact build
time available and no verifier override. The native binary SHA-256 is
`e0c0f133b1235c4f08ac6ea0d00ed857aede56c2e24bebfbdfa8eadda60c710b`.

The largest eight-tree/96-step/all-output case also passes same-host copied-bundle
relocation against a fresh original ordinary simulation: all 283,780 records
match exactly, including 272,336 samples and 4,391 stream keys. It runs with a
fresh empty HOME/cwd and empty external depot; the launcher supplies the copied
bundled depot. Artifact/provenance hashes remain unchanged. The test did not
hide authoring sources or establish system-library/cross-host portability.

R7 is retained as a diagnostic predecessor. Its safe compilation and smoke run
succeeded; a host progress-record Tuple/NamedTuple bug required linking the
already compiled object, with an explicit recovery audit and unavailable exact
compile duration. Its raw parity gate then rejected `Main`-dependent type-tag
qualification. It is excluded from final parity and timings. R8 uses stable,
explicit-context type tags and freshly encoded ordinary records, with **raw
exact equality and no normalization**.

The shared codec passes 82 namespace/context/type-identity/payload assertions;
the build-stage calls pass nine regression assertions. Focused runtime evidence
also covers eight temporal-fallback checks, 293 hard-call-view assertions,
private reference ownership, fresh environment rows and exact original
sink/duration errors. Separate installer tests preserve both controller result
prefixes, Float32 values, destination identity and overlapping-vector write order.

Build metadata binds the binary/launcher, entry/runtime/typing sources,
Project/Manifest, complete scientific typing inventory, case/construction
manifests and loaded PSE dependency source inventory. The host build recipe is
archived as build provenance and frozen separately during qualification.

## Reproduction

Run Julia work through Kaimon. Load PSE from the active pinned project before
inserting the selected frozen MAESPA project after `@` in `LOAD_PATH`. Set
`ENV["PSE_MAESPA_PATH"]` to that exact source root. The dedicated build environment
is `benchmark/juliac_program/buildenv`; the isolated native project and full
source hashes are recorded in build metadata.

```julia
using PlantSimEngine
push!(LOAD_PATH, abspath("benchmark/juliac_program/buildenv"))
using JuliaC
include("benchmark/juliac_program/downstream_maespa_build.jl")
global build_task = @async build_maespa_registry(
    profile=:matrix,
    destination="/private/tmp/maespa-safe-bundle")
```

Poll `istaskdone(build_task)` and `stage.toml`. Keep a bounded result/failure disk
receipt around the held Main task: first authoring can exceed the outer tool's
inactivity window, which is not a verifier result. The helper preserves recipes
in `MAESPA_BUILD_IMAGES`/`MAESPA_BUILD_LINKS`. Exact native commands include:

```text
run-pse-program emit 24 1 13 all
run-pse-program emit 96 4 1 all
run-pse-program perf 96 4 1 none 3
```

`downstream_maespa_native_checks.jl` compares fresh ordinary and native records;
`downstream_maespa_native_scaling.jl` owns the original/native matrix and timing
environment; `downstream_maespa_relocation.jl` qualifies a copied bundle. Host
ordinary/typed/JIT drivers and their raw setup/execution samples remain separate.
The admitted duration stays within the original 96-row forcing coverage.

This is execution equivalence for the stated fixed scenario and source variants,
not scientific calibration, arbitrary MAESPA/Tuzet support, general spatial or
lifecycle support, or a build/setup-inclusive speedup. The complete attribution
matrix remains pending until the final typed-ordinary and registry-JIT results
arrive.
