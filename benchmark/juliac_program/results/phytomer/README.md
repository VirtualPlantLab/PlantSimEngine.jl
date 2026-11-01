# Original phytomer emission: structural proof, 2026-11-01

The original XPalm `PhytomerEmission` kernel now runs through prepared typed
cohorts and through a JuliaC **safe-trimmed executable**. XPalm is pinned to
`5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd`; no downstream source is changed.
The eleven original models cover thermal time, plant age, phyllochron, emission,
three initiation-age applications, potential internode/leaf dimensions and two
maintenance-respiration applications. Their equations and emission body are not
copied or rewritten. The existing emission ModelSpec supplies five manual calls
and two initializer bindings.

## What was executed

- **94 assertions** compare ordinary PSE and the cohort executor after every
  timestep: all declared status fields, object IDs, categories, parent IDs,
  MTG links/indices and every retained output sample. Four cases cover no birth,
  one birth, five births, and both MTG representations. A separate check reuses
  the exact same program with changed rate, biomass and initial age, verifies
  unchanged state type, independent references, and growth from 4 to 19 nodes.
- **28 focused lifecycle assertions** check pending vs committed membership,
  explicit newborn calls before the barrier, stable references, initializer
  cardinality, exactly-once reservation, failed-event retry refusal, duplicate
  IDs, invalid attributes/types, scientific contracts and distributed rejection.
- **10 native assertions** compare four CLI cases plus relocation against
  ordinary PSE. Initial Internode and Leaf cohorts are empty. Original kernels
  create real MTG phytomers/internodes/leaves, reaching **28 nodes** in the largest
  case. Every final declared status field and the topology projection above is
  compared, not only counts or a numerical checksum (`native.json`).
- **1,394 previous Julia-level assertions** still pass: fixture 512, generic calls
  255 and original XPalm soil/root 627. The final binary also passes the earlier
  soil/root and fixture cases, invalid CLI inputs and relocation
  (`native-regressions.json`).

All Julia work/build orchestration uses dedicated Kaimon sessions. The final
JuliaC 0.3.12 / Julia 1.13.1 build uses safe trimming, generic CPU, no unsafe
bypass and no arbitrary entrypoints. The warmed build phases are recorded in
`provenance.json`; they are not process-cold or scientific-runtime benchmarks.
There is no performance or zero-allocation qualification for structural growth.
Native final-state checks and Julia-level publication-series checks are distinct.

## Program and lifecycle boundaries

`prepare(ModelSpec tuple; initial=...)` chooses a concrete layout: homogeneous
`kind` columns for the earlier cases, heterogeneous `scale` cohorts for MTG input.
These are internal compiled layouts behind the same declaration grammar. Neither
constructs or lowers an ordinary Simulation/plan. The program stores concrete
kernel/schema types, seed/reference recipes, call slots and root order. Scientific
parameter values, topology, IDs, memberships, statuses and histories are state.
Application slots are static schema; organ counts, parameter values and days do
not become type parameters or dynamically generated methods.

The structural entry has six cohorts (Scene, Plant, Stem, Phytomer, Internode,
Leaf). Their schemas derive from model ports and explicit typed initial inputs,
including biomass and scene node count. Cross-object Plant/Scene inputs share
canonical Ref values. `source_node` returns actual MTG nodes and status identity
maps recover each newborn ID. New rows enter the registry immediately, while
ordinary call memberships remain unchanged until the creator application ends.
Targeted calls can reach pending newborns. Later scheduled applications see the
committed additions; completed applications are not replayed.

Initializer targets stay normally scheduled before their creator. Each newborn
initializer reserves its application/ID before executing, returns canonical
Status and publishes no extra midstep sample. Failure leaves the partial state
visible and poisons the unfinished event: callers must construct fresh state,
rather than silently retry/commit partially initialized newborns. This is not
rollback or general recovery support.

## Concrete MTG representation and input scope

Scientific initial values are explicit typed inputs. Native cohort input rejects
nonempty MTG attribute stores instead of silently ignoring them. The ordinary
reference uses the original XPalm status policy overlaid with those same inputs.
The initial graph has Scene/Plant/Stem and one required anchor Phytomer, with no
Internode or Leaf. An initial age different from zero is supplied explicitly to
the anchor and checked against the ordinary reference.

The ordinary Julia reference uses standard ColumnarAttrs nodes. Native execution
uses genuine `Node{NodeMTG,NamedTuple{(),Tuple{}}}` objects, constructed using
MTG's documented Node constructor and original `addchild!` implementation. The
same constructor/attachment operations create newborn nodes. No fake topology,
manual replacement of scientific emission or downstream source patch is used.
Both representations pass the Julia-level state/topology/publication comparison.

This representation matters for closure: the initial safe build reported calls
through the columnar attribute store's Any-valued columns. With state outside MTG
attributes, a fixed empty-attribute layout avoids that machinery. App authoring
and the original PhytomerEmission constructor still use a standard MTG at build
time; native state uses the fixed release's typed topology. Generic attribute
imports, attribute-based query APIs and arbitrary MTG schemas are not supported
by this entry. The pinned dependency also exposes a Julia 1.13 FieldError-handling
problem when its descendants helper is used with empty NamedTuple attributes;
therefore that helper is not part of native state construction.

Safe compilation alone was insufficient: a constructor-method ambiguity initially
compiled to an executable that threw during its first birth. The explicit node
type bound resolved it, then real birth cases were executed and compared. This
failure is retained here as the reason build success and execution parity are
separate evidence.

## Reproduce

In the app Kaimon session (`benchmark/juliac_program/app`):

```julia
include("src/program.jl")
include("src/phytomer_fixture.jl")
include("../phytomer_checks.jl")
include("../cohort_checks.jl")
PhytomerChecks.run_checks()
NativeCohortChecks.run_checks()
```

Build from a Kaimon session at `buildenv/` with `include("../build.jl")`.
The complete bundle path is in `build/latest.txt`. The new CLI is:

```text
/path/to/bundle/bin/run-pse-program phytomer days rate biomass Tmin Tmax initiation_age
/path/to/bundle/bin/run-pse-program phytomer 6 0.1 2.0 22.0 31.0 12
```

The header gives nodes/steps. Subsequent rows give category, ID, parent ID
(zero for the root), link, index, then alphabetically ordered canonical status
fields for that category. Native tests decode against the original contracts.

```julia
include("../phytomer_native_checks.jl")
PhytomerNativeChecks.run_checks()
```

This remains a bounded structural subtree, not a whole-palm release. Carbon
allocation, reproductive organs, removal/reparenting, arbitrary selectors,
heterogeneous model overrides, temporal policies, distributed outputs,
evaluate/accept and spatial environments remain unqualified or unsupported.
