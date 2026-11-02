# Complete MAESPA scenario: fixed registry prototype

This experiment uses the public two-species, non-Tuzet canopy/soil builder with
`mount_leaf_exchange=true`. It includes the original leaf energy/photosynthesis
calls, radiation, water balance, accepted canopy commits and daily/subdaily
clocks. Trial calls and accepted replay execute the original scientific work.
The one-tile case has 27 objects and 100 applications; four adjacent equal-area
tiles have 99 objects and 292 applications. Plot density is preserved.

The original ordinary PSE executor remains the primary baseline. A separately
inventoried inference-typed source copy supplies the ordinary control and the
candidate. Its patch changes concrete storage/type propagation, literal field
access, fixed-name assignments, closure binding and error formatting; it does
not change equations, validation predicates, solver iterations or scientific
calls. `downstream_maespa_typing.py`, its three helper modules, patch and full file
manifest reproduce and identify that copy. The original frozen source is kept
unchanged.

`RegistryPrograms.prepare` resolves an ordinary scenario on a private deep copy
at host authoring time, then projects the resolved references and schedule into
independent typed storage. That setup cost is reported. The resulting program
contains no ordinary `Simulation`, `CompiledCompositeModel`, execution target or
`RunContext`; an ownership traversal checks this boundary. Runtime instantiation,
calls, temporal inputs, publication and environment sampling use the new backend
and the original scientific kernels. The registry is fixed; lifecycle changes
and temporal policies other than `PreviousTimeStep` are not admitted here.

The compiled environment retains the original MAESPA backend and validators. Its
`GlobalConstant` forcing view shares the original table's concrete NamedTuple row
storage, which avoids an abstract row-name tuple in timestep validation. Each
instance preserves that alias while owning private rows. Row-value mutations are
read fresh; wholesale replacement of the table storage or schema is not admitted.
Provider/sink values specialize the original immutable handle at the binding
boundary; the original sampling, sink and duration checks still execute.

Application/object identities, root execution order and call memberships remain
data. The compiled root-family set excludes manual-only groups from root execution
specializations. Iterative refinement groups targets by their model/carrier/call schemas:
one and four tiles both use 68 families (145 and 481 targets). Four original
scientific models retain population-sized weight/ID tuple parameters, so the two
populations have distinct model specializations. The native suite is explicitly
bounded to Float64, one/four tiles, starts 1/13 and retention `none`/`all`.

The earlier inference variant passed exact initial and two-step
daylight parity for canonical statuses, topology/geometry, every stream and
timestamp, committed atmosphere and complete host RNG fingerprints. The daylight
case executes eight accepted logical leaf units and 24 original temperature
trials per step. The nine-file variant also passed all eight ordinary matrix cases and a complete
24-step daylight candidate case against the untouched original. The expanded
26-file inference variant is now undergoing fresh ordinary/candidate checks.
The preceding 23-file variant also passed the complete 24-step ordinary and
schedule-aware candidate case against the original records and RNG snapshot. Eight focused temporal-initial checks preserve Float32 values,
nested aliases and rejection of mismatched fallback schemas. Native safe
qualification remains pending: early compiler gates exposed output/call typing
and scientific field-projection roots, now being repaired and rechecked. No
native performance result is claimed by this checkpoint.

The actual owned seed contains no runtime RNG. Fixed subdaily forcing and
`AllTargetTrees` do not exercise runtime stochastic branches. Native authoring
records the two construction RNGs' serialized-state hashes and four draws from
private copies as provenance, explicitly outside runtime stochastic coverage.

Run Julia work through Kaimon. Load PSE from the active pinned project before
inserting the chosen MAESPA source after `@` in `LOAD_PATH`; keep the app project
as a fallback when the active build environment does not provide PSE. Set
`ENV["PSE_MAESPA_PATH"]` to that exact source root. Then:

```julia
include("benchmark/juliac_program/downstream_maespa_native_checks.jl")
F = DownstreamMAESPAFixture
C = DownstreamMAESPAChecks
R = DownstreamMAESPARegistry
config = F.configuration(steps=2, copies=1, start_slot=13, outputs=:all)
C.check_ordinary(; config)
C.check_candidate(R.candidate(); config)
DownstreamMAESPANativeChecks.check_temporal_initials()
```

Use 24 steps from slot 13 or 96 steps from slot 1 for the larger cases.
`downstream_maespa_measurements.jl` separates fresh construction, ordinary
preparation, one-time candidate authoring, private instantiation and complete
execution. Observation/hash work is outside timers. Trial zero is internally
timed but excluded from measured summaries. Every measured run must match the
original full records; timing windows are serialized across workers.

Native builds use an isolated pinned project and `JuliaC` safe/generic recipes.
The `daylight` profile contains the complete one-tile/start-13/all-output graph;
`matrix` contains all eight population/start/retention combinations. Duration
remains runtime data within the original forcing coverage. Launch long builds
from a held Main task in Kaimon, rather than waiting in one long tool cell:

```julia
include("benchmark/juliac_program/downstream_maespa_build.jl")
global build_task = @async build_maespa_registry(profile=:daylight,
    destination="/private/tmp/maespa-safe-bundle")
```

Poll `istaskdone(build_task)` and the bundle's `stage.toml`; the build helper keeps
its `ImageRecipe`/`LinkRecipe` in `MAESPA_BUILD_IMAGES`/`MAESPA_BUILD_LINKS` for
recovery. A production orchestration cell should also write its result or bounded
failure to a disk receipt. First authoring can exceed the outer tool's inactivity
window; that timeout is not a native verifier result.

Native checks require the completed bundle and its safe/generic build metadata,
binary/launcher hashes, archived/current entry sources, source-typing inventory,
case inventory, the loaded PSE dependency source inventory and construction RNG
provenance. Full records include empty
stream keys (`H`) as well as final status/topology (`F/T/S`), samples (`O`) and
committed air (`E`). Both the manifest-approved original ordinary arm and the
inference-typed ordinary arm must match the candidate exactly. Final safe/matrix qualification is pending before any native speed claim.
