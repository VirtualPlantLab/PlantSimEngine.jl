# PlantSimEngine Agent And Developer Guide

This file is the maintainer-facing summary of how PlantSimEngine works internally.
It is meant for humans and coding agents making changes to the package.

PlantSimEngine is a Julia engine for composing process models on either:

- a single shared status (`ModelMapping{SingleScale}` / legacy `ModelList`)
- a multiscale MTG scene (`GraphSimulation`)

The package is built around four ideas:

1. Models declare `inputs_`, `outputs_`, and optionally `dep`.
2. The engine compiles a dependency graph from those declarations.
3. Runtime state is reference-based (`Status`, `RefVector`), so coupling is often aliasing, not copying.
4. Multiscale and multirate configuration can change where an input comes from, how it is transported, and when it is sampled.

## What The Package Supports

- Single-scale process composition with automatic soft-dependency inference.
- Hard dependencies declared explicitly and called manually from model code.
- MTG-based multiscale simulations with cross-scale variable mappings.
- Cross-scale scalar sharing through shared `Ref`s.
- Cross-scale multi-node sharing through `RefVector`s.
- Cross-scale writes, where a variable computed at one scale is materialized as an input at another scale.
- Same-scale variable aliasing and renaming.
- Cycle breaking through `PreviousTimeStep`.
- Multi-rate execution through `ModelSpec`, `ClockSpec`, and temporal policies.
- Explicit or inferred `InputBindings` between producers and consumers.
- Meteo resampling/aggregation per model in multi-rate MTG runs.
- Output routing (`:canonical` vs `:stream_only`) and online output export (`OutputRequest`).
- Parallel single-scale execution when model traits allow it.

## Core Runtime Objects

### Processes and models

- All models subtype `AbstractModel`.
- `@process` creates an abstract process type such as `AbstractGrowthModel`.
- Process identity comes from the abstract process type, not the concrete model name.
- The model execution contract is:

```julia
PlantSimEngine.run!(model, models, status, meteo, constants, extra)
```

- `inputs_(model)` and `outputs_(model)` are the authoritative declarations.
- `variables(model)` is `merge(inputs_(model), outputs_(model))`.
- Do not rely on a variable being both an input and an output under the same name: `merge` means the later declaration wins.

### Status

- `Status` is a wrapper around a `NamedTuple` of `Ref`s.
- Reading a field dereferences it. Writing a field mutates the underlying `Ref`.
- This aliasing behavior is intentional and is the basis of most coupling.
- In single-scale runs, vector-valued user inputs are flattened to one timestep value and updated per timestep with `set_variables_at_timestep!`.

### RefVector

- `RefVector` is an `AbstractVector` of `Base.RefValue`s.
- It is used when one model input must see a vector of references coming from many statuses.
- Reading a `RefVector` dereferences each underlying status cell.
- Writing into a `RefVector` mutates the source statuses.
- `RefVector` order follows MTG traversal order during initialization, not a semantic plant order.

### Mapping wrappers

- `MultiScaleModel` wraps one model plus a multiscale mapping declaration.
- `ModelSpec` wraps one model plus scenario-level runtime configuration:
  `multiscale`, `timestep`, `input_bindings`, `meteo_bindings`, `meteo_window`, `output_routing`, and `scope`.
- `ModelMapping` is the normalized mapping container used by current entry points.
- Legacy `ModelList` still exists, but it is compatibility plumbing and should not be treated as the main abstraction for new work.

### Simulation wrappers

- `DependencyGraph` holds root dependency nodes plus unresolved dependencies.
- `GraphSimulation` holds the MTG, statuses, status templates, reverse mappings, dependency graph, models, model specs, outputs, and temporal state.

## Dependency Graph Under The Hood

### Hard dependencies

- Hard dependencies are declared with `dep(::ModelType)`.
- A hard dependency means: "this model directly calls another model from inside its own `run!` implementation."
- Hard dependencies are represented by `HardDependencyNode`.
- They are executed manually by the parent model. The runtime does not automatically recurse into hard dependencies.
- Hard dependencies can be same-scale or explicitly multiscale.

Important nuance:

- A hard dependency does not become an independent soft-dependency node under the parent.
- But it still matters for graph construction, because the graph compiler aggregates the root model's hard-dependency subtree when computing that root's effective inputs and outputs.
- In multiscale graph building, if another model depends on a process that exists only as a nested hard dependency, the code resolves that dependency back to the master soft node that owns that hard subtree.

So "hard dependencies do not directly participate in the soft graph" is true for execution structure, but false if interpreted as "their IO is irrelevant to graph compilation."

### Soft dependencies

- Soft dependencies are inferred by matching model inputs against outputs.
- Matching is name-based after variable flattening, not based on a richer semantic contract.
- Same-scale soft dependencies are built after hard-dependency trees are known.
- A process cannot also list one of its hard dependencies as a soft dependency.
- `PreviousTimeStep` variables are removed from current-step soft dependency inference.
- Soft dependencies are represented by `SoftDependencyNode`.
- A soft node may have multiple parents.
- A node is considered runnable once all of its parent nodes have already run for the current traversal.
- If no producer output matches an input, no soft edge is added. Soft-edge construction does not itself fail on missing producers.

### Single-scale graph build

Single-scale graph construction is:

1. Build `HardDependencyNode`s for each declared process.
2. Attach explicit hard-dependency children under their parents.
3. Traverse each hard-dependency root and collect its effective inputs and outputs.
4. Build one `SoftDependencyNode` per hard-dependency root.
5. Infer parent and child links by matching inputs to outputs.

### Multiscale graph build

Multiscale graph construction is more involved:

1. Normalize the user mapping into `ModelMapping`.
2. Build per-scale hard-dependency graphs.
3. Resolve multiscale hard dependencies declared across scales.
4. Compute per-scale effective inputs and outputs for each hard-dependency root.
5. Build one `SoftDependencyNode` per root process per scale.
6. Compile mapped variables and reverse mappings.
7. Infer same-scale soft dependencies.
8. Infer cross-scale soft dependencies from mapped variables and reverse mappings.
9. If a dependency points to a nested hard dependency, redirect it to the owning soft node.
10. Check the final graph for cycles.

### Cycle handling

- The graph is expected to be acyclic.
- The official way to break a same-step cycle is `PreviousTimeStep`.
- `PreviousTimeStep` breaks cycles by suppressing current-step edge creation, not by adding special scheduler logic.
- In multiscale runs, cycle detection happens after the cross-scale graph is assembled.
- Single-scale `dep(...)` relies mostly on builder-time guards. Multiscale `dep(mapping)` also runs an explicit global cycle check on the final soft graph.

## Multiscale Mapping Model

### Mapping modes

PlantSimEngine distinguishes three mapping modes:

- `SingleNodeMapping(scale)`: one scalar value is read from one source scale.
- `MultiNodeMapping(scales)`: one input reads a vector of values from many source nodes.
- `SelfNodeMapping()`: a source scale must expose a scalar reference to itself so other scales can share it.

The runtime carrier is `MappedVar`, which stores:

- the mapping mode
- the local variable name
- the source variable name
- the resolved default value

### Supported mapping forms

These are the important user-level forms and what they become internally:

| User form | Meaning | Runtime shape |
| --- | --- | --- |
| `:x => :Plant` | scalar read from one `:Plant` node | shared `Ref` |
| `:x => (:Plant => :y)` | scalar read with renaming | shared `Ref` |
| `:x => [:Leaf]` | vector read from all `:Leaf` nodes | `RefVector` |
| `:x => [:Leaf, :Internode]` | vector read from several scales | `RefVector` |
| `:x => [:Leaf => :a, :Internode => :b]` | vector read with per-scale renaming | `RefVector` |
| `PreviousTimeStep(:x) => ...` | lagged mapping, excluded from same-step dependency build | lagged input |
| `PreviousTimeStep(:x)` | pure cycle-breaking marker | local/default value |
| `:x => (Symbol(\"\") => :y)` | same-scale rename | `RefVariable` alias |

### Mapping compilation pipeline

`mapped_variables(...)` does not just mirror user syntax. It compiles it.

The main passes are:

1. Start from effective per-scale inputs and outputs collected from hard-dependency roots.
2. Add variables that are outputs of one scale but must appear as inputs at another scale.
3. Convert scalar cross-scale reads into self-mapped outputs on the source scale so one shared `Ref` exists.
4. Resolve default values recursively back to the ultimate producer.
5. Convert mapping descriptors into runtime carriers:
   - scalar mappings become shared `Ref`s
   - multi-node mappings become empty `RefVector`s
   - same-scale renames become `RefVariable`

### Reverse mapping and status wiring

- Reverse mapping is computed before the reference conversion pass.
- Reverse mapping answers: "when a source node is initialized, which target scale/vector inputs should receive a reference to this source variable?"
- Reverse mapping excludes scalar `SingleNodeMapping` edges when `all=false`, because scalar sharing is already handled by shared `Ref`s.

During `init_node_status!`:

1. A copy of the scale template is made.
2. `:node => Ref(node)` is injected.
3. Remaining uninitialized variables may be filled from MTG attributes.
4. The template becomes a `Status`.
5. The status is pushed into `statuses[scale]`.
6. If this node feeds any downstream `RefVector`, its `Ref`s are pushed into those target vectors.
7. The status is stored on the MTG node under `:plantsimengine_status`.

### Copies vs references

- MTG attribute initialization copies plain values into the status.
- If the MTG attribute itself is already a `Ref`, that `Ref` is preserved.
- The runtime cannot create a live reference directly into a dict-backed MTG attribute.
- Cross-scale sharing is reference-based once the status exists.

## Multi-Rate Runtime

Multi-rate behavior is layered on top of the multiscale MTG runtime.

### Timing and policies

- `timespec(model)` defines the model's default clock. The default is `ClockSpec(1.0, 0.0)`.
- `ModelSpec.timestep` can override runtime clock selection.
- `output_policy(model)` declares per-output temporal policy defaults.

Supported schedule policies are:

- `HoldLast()`: use the latest available producer value.
- `Interpolate()`: interpolate or hold/extrapolate producer streams.
- `Integrate()`: reduce values over the consumer window, default reducer is `SumReducer()`.
- `Aggregate()`: reduce values over the consumer window, default reducer is `MeanReducer()`.

### ModelSpec configuration surface

`ModelSpec` is the configuration point for scenario-specific runtime behavior.

It can define:

- `multiscale`: mapping declaration
- `timestep`: runtime clock
- `input_bindings`: explicit producer selection for consumer inputs
- `meteo_bindings`: per-model weather aggregation
- `meteo_window`: weather window selection strategy
- `output_routing`: `:canonical` or `:stream_only`
- `scope`: `:global`, `:self`, `:plant`, `:scene`, `ScopeId`, or callable

### Input binding inference

- If explicit `InputBindings` are absent, the package tries to infer bindings from the dependency graph and mapping.
- Unique same-scale producers win first.
- Unique cross-scale producers are accepted when unambiguous.
- Existing multiscale mapping hints can disambiguate some cross-scale cases.
- Ambiguity is an error and must be resolved explicitly.

### Runtime sequence in multi-rate MTG mode

For each dependency node and each status at that node's scale:

1. Decide whether the model should run at the current time according to its clock.
2. Resolve consumer inputs from temporal state with explicit or inferred bindings.
3. Sample or aggregate meteo for the model.
4. Call the model's `run!`.
5. Publish outputs back into temporal caches and streams.
6. Materialize any requested online exports.

Important consequences:

- In non-multirate MTG runs, cross-scale coupling is mostly direct aliasing through shared refs.
- In multirate MTG runs, temporal state can overwrite consumer inputs just before execution.
- Multi-rate MTG runs are currently forced to sequential execution.

## Configurations Developers Must Keep In Mind

A variable seen by a model may be in any of these supported configurations:

- Plain local status value initialized by the user.
- Plain local status value initialized from MTG node attributes.
- Output computed locally at the same scale.
- Same-scale alias of another local variable through `RefVariable`.
- Scalar value mapped from another scale through a shared `Ref`.
- Vector of references mapped from one or many other scales through `RefVector`.
- Output computed at one scale and written into another scale, which means it is injected as an input on the receiving scale during mapping compilation.
- Value marked as `PreviousTimeStep`, which removes it from same-step dependency inference.
- Input resolved from a hard dependency that is called manually inside another model.
- Input resolved from temporal streams instead of directly from the current status value.
- Input bound explicitly with `InputBindings`.
- Input bound implicitly by inference from producers and mappings.
- Input sampled with `HoldLast`, `Interpolate`, `Integrate`, or `Aggregate`.
- Output published canonically into status state.
- Output published as `:stream_only`, meaning it participates in temporal streams but not canonical output ownership.
- Value partitioned by scope (`:global`, `:self`, `:plant`, `:scene`, or custom scope function).

When changing dependency, mapping, or runtime code, assume all of these modes can exist in the same simulation.

## Execution Semantics And Important Caveats

- Soft-dependency order controls model order. MTG topology does not define execution order within a scale.
- Within one scale, execution order follows the order of `statuses[scale]`, which comes from MTG traversal at initialization time.
- `SingleNodeMapping` assumes the source node is unique at runtime. The mapping layer does not enforce uniqueness.
- `RefVector` ordering is traversal order, not a guaranteed biological ordering.
- Hard dependencies are manual calls. If model code stops calling them, the declared hard dependency no longer executes.
- Hard dependencies still influence graph compilation through their effective inputs and outputs.
- Multiscale redirection from nested hard dependencies back to the owning soft node is implemented with upward walking through parent links and a defensive depth guard. Treat that path as fragile.
- MTG topology changes after `init_statuses` leave `statuses`, node attributes, and populated `RefVector`s stale. Reinitialize after topology changes.
- Same-scale renaming does not create a graph-wide shared ref. It creates a per-status alias.
- `parent_vars` is dependency metadata, not a full provenance graph, and in multiscale builds it can be overwritten when a node has both same-scale and cross-scale parents.
- Duplicate canonical publishers for one `(scale, variable)` are invalid in multi-rate mode unless non-canonical producers are marked `:stream_only`.
- User `extra` arguments are not allowed in MTG runs because `GraphSimulation` already occupies that slot.
- String scale names still work in many places but are deprecated. Prefer `Symbol` scales.
- `ModelList` is deprecated as the primary API. Prefer `ModelMapping`.
- `run_node_multiscale!` currently uses `node.simulation_id[1]` as the visitation guard. Treat that code carefully if you touch traversal semantics.
- Some variable collection helpers use set-like flattening, so collection order is not always stable. Do not attach semantics to incidental variable ordering.

## High-Signal Files

- `src/PlantSimEngine.jl`: module layout and exports.
- `src/Abstract_model_structs.jl`: `AbstractModel` and `process`.
- `src/processes/process_generation.jl`: `@process`.
- `src/processes/models_inputs_outputs.jl`: model declarations and runtime traits.
- `src/variables_wrappers.jl`: `UninitializedVar`, `PreviousTimeStep`, `RefVariable`.
- `src/component_models/Status.jl`: reference-based status container.
- `src/component_models/RefVector.jl`: vector of references.
- `src/dependencies/*`: hard and soft dependency graph construction and traversal.
- `src/mtg/MultiScaleModel.jl`: mapping syntax normalization.
- `src/mtg/ModelSpec.jl`: runtime configuration wrapper.
- `src/mtg/mapping/*`: mapping compilation, reverse mapping, initialization helpers.
- `src/mtg/initialisation.jl`: status creation and MTG wiring.
- `src/mtg/GraphSimulation.jl`: simulation wrapper.
- `src/time/multirate.jl`: clocks, policies, temporal storage types.
- `src/time/runtime/*`: input resolution, scopes, publishers, meteo sampling, output export.
- `src/run.jl`: single-scale and multiscale execution.

## Practical Rule For Future Changes

If you change dependency, mapping, or runtime behavior, re-check all of these questions:

1. Does it still work for both single-scale and MTG runs?
2. Does it preserve aliasing semantics for `Status` and `RefVector`?
3. Does it preserve the distinction between hard dependencies and soft dependencies?
4. Does it still handle scalar mappings, vector mappings, same-scale aliasing, and cross-scale writes?
5. Does it still behave correctly with `PreviousTimeStep`?
6. Does it still work when input bindings are inferred instead of explicit?
7. Does it still work in multi-rate mode with temporal policies and scoped streams?
8. Does it remain correct if the producer is nested under a hard dependency?
