# PlantSimEngine Internal Summary (for agents and developers)

This document explains how PlantSimEngine is structured internally, how models are declared and coupled, and how simulations run. It is intentionally low-level and implementation-oriented.

## High-level architecture

PlantSimEngine is a Julia framework for composing plant models as modular processes. Users or modelers define models that implement a process, declare inputs/outputs, and optionally declare hard dependencies (manual calls). The engine builds a dependency graph (soft dependencies via inputs/outputs and hard dependencies via explicit model calls) and executes models in dependency order. It supports single-scale model lists and multiscale model mappings on a plant graph (MTG).

Core modules (see `src/PlantSimEngine.jl`):
- `component_models`: `Status`, `RefVector`, `ModelMapping`, `TimeStepTable`
- `dependencies`: dependency graph types and builders
- `processes`: model interfaces, inputs/outputs/variables, process macro
- `mtg`: multiscale mapping, GraphSimulation, initialization, save results
- `run.jl`: execution engine for single-scale and multiscale
- `traits`: parallel traits

## Core data structures

### Status
File: `src/component_models/Status.jl`
- `Status` is a mutable NamedTuple-like container storing references (`Ref`) to values.
- Access: `status.var`, `status[:var]`, and indexed access.
- It is used per time step and per node for multiscale MTG simulations.
- `Status` values are references so updates propagate to all shared references.

### RefVector
File: `src/component_models/RefVector.jl`
- `RefVector` is an `AbstractVector` of `RefValue`s, typically references to the same variable across many Status instances.
- Used for multiscale aggregation where a higher scale references values from many lower-scale nodes (e.g., plant-level model reads all leaves).
- Updating a `RefVector` entry updates the referenced Status field.

### ModelList (deprecated)
File: `src/component_models/ModelList.jl`
- `ModelList` is the single-scale container: `models::NamedTuple`, `status::Status`, `dependency_graph::DependencyGraph`.
- Building a ModelList:
  - Parse models and get required variables via `inputs_`/`outputs_`.
  - Create a `Status` by merging user-supplied `status` with default values for missing variables.
  - Build dependency graph via `dep(; models...)`.
- `type_promotion` can upcast default model values (not user-specified ones).

### MultiScaleModel

File: `src/mtg/MultiScaleModel.jl`
- Wrapper to attach a multiscale variable mapping to a model.
- Supports scalar mapping (SingleNode), vector mapping (MultiNode), renaming, and `PreviousTimeStep`.
- Normalizes mapping into a canonical vector of `Pair{Symbol or PreviousTimeStep => Pair{scale, var}}` or vector of pairs.

### Mapping and MappedVar
Files: `src/mtg/mapping/mapping.jl`, `src/dependencies/dependency_graph.jl`
- `MappedVar` records how a variable is sourced from another scale and its default value.
- `SingleNodeMapping`, `MultiNodeMapping`, `SelfNodeMapping` define how a variable should be referenced.
- Mapping drives how references are shared across scales in `init_statuses`.

### Dependency graph nodes
File: `src/dependencies/dependency_graph.jl`
- `HardDependencyNode`: manual dependency edges (model explicitly calls another process).
- `SoftDependencyNode`: inferred dependencies via inputs/outputs (same or cross scale).
- `DependencyGraph`: holds root nodes and `not_found` dependencies.

## Model interface

### Process and model declaration
Files: `src/processes/process_generation.jl`, `src/Abstract_model_structs.jl`
- A process is a named abstract type created by `@process`.
- Model types subtype the process abstract type.
- The core runtime function is `run!(model, models, status, meteo, constants, extra)`.

### Inputs, outputs, variables
File: `src/processes/models_inputs_outputs.jl`
- Each model must implement `inputs_(model)` and `outputs_(model)` returning NamedTuples with defaults.
- `inputs(model)` and `outputs(model)` return just symbol lists.
- `variables(model)` merges inputs and outputs with default values.
- These are used to build Status and dependency graphs.

### Hard dependencies
File: `src/dependencies/hard_dependencies.jl`
- A model can declare `dep(::ModelType)` returning a NamedTuple of required processes and their expected model types.
- Hard dependencies are nested under the parent process and are executed manually by parent model code.
- Hard dependencies can be declared cross-scale for multiscale mapping (with additional metadata).

### Soft dependencies
File: `src/dependencies/soft_dependencies.jl`
- Soft dependencies are inferred by matching input variable names to output variable names.
- The graph is built per scale and then connected across scales using mapping information.

## Multiscale simulation flow

### Mapping to graph and statuses
Files: `src/mtg/initialisation.jl`, `src/mtg/mapping/compute_mapping.jl`
- `init_statuses` builds templates for each scale based on mapping and model variables.
- It converts `MappedVar` into actual reference values:
  - `SingleNodeMapping` and `SelfNodeMapping` become `RefValue`
  - `MultiNodeMapping` becomes `RefVector`
- For each MTG node, `init_node_status!` builds a Status and attaches it to the node.
- When a node is initialized, it pushes references into higher-scale RefVectors (`reverse_multiscale_mapping`).

### Scene structure via MultiScaleTreeGraph (MTG)
The multiscale approach uses `MultiScaleTreeGraph` as the authoritative scene/organism structure. It is a tree of `Node` objects. Each node has:
- `id::Int` unique in the MTG
- `parent`, `children`
- `MTG` encoding (`NodeMTG` or `MutableNodeMTG`) with `link` ("/", "<", "+"), `symbol` (e.g. `"Leaf"`), `index` (free), and `scale` (Int)
- `attributes` (typically a Dict or NamedTuple) and a traversal cache

Key MTG APIs used by PlantSimEngine:
- `symbol(node)`, `scale(node)`, `node_id(node)` for mapping and error messages.
- `children(node)`, `parent(node)` via `AbstractTrees` compatibility.
- `traverse!`/`traverse` to walk nodes with optional filters (`scale`, `symbol`, `link`, `filter_fun`, `recursivity_level`).
- `get_node(node, id)` to retrieve a node by id.

Mapping binds models to node `symbol`s, and initialization attaches a `Status` to each node (stored in node attributes). MTG traversal defines which nodes exist at each scale and therefore which Status instances and RefVectors are created.

#### Mapping rules ↔ MTG filters (symbol/scale/link)
PlantSimEngine’s multiscale mapping is keyed by MTG `symbol` (e.g. `"Leaf"`, `"Plant"`). The MTG API supports filters on `symbol`, `scale`, and `link` in `traverse!/traverse`. In PlantSimEngine, mapping does **not** currently use MTG filters directly; instead it:
- Uses `symbol(node)` to select which model list applies to a node.
- Uses mapping entries (e.g. `"Leaf"` or `["Leaf","Internode"]`) to define cross-scale value sharing, which is then resolved by MTG traversal during initialization.

If you want to extend mapping semantics to link/scale filters, the natural insertion point is `init_statuses`/`init_node_status!`, where the MTG traversal occurs and where it already supports `symbol`-based filtering.

#### Status attachment ↔ MTG attributes lifecycle
`init_statuses` traverses the MTG and, for each node whose `symbol` matches a mapping key, builds a `Status` and stores it on the node attributes (by default under `:plantsimengine_status`). This means:
- Status lives with the MTG node (not global arrays only), and is accessible during model execution via the node reference.
- `GraphSimulation` also maintains `statuses` indexed by scale, but these are populated from the same MTG traversal and are consistent with the per-node attribute.

Practical implication: any MTG mutation (insert/delete nodes) must update statuses or re-run initialization so that the node attributes and `statuses` dictionary remain consistent.

#### Multi-node mappings ↔ RefVector construction and traversal order
Multi-node mappings (e.g., a plant variable mapped from all leaf variables) are converted to `MappedVar{MultiNodeMapping}` and then to `RefVector` instances in `init_statuses`.
Key detail:
- `reverse_multiscale_mapping` is used so that when each node is initialized, it pushes its variable reference into the target RefVector of the other scale.
- The traversal order matters only for the order of refs in the RefVector; the values are references, so updates propagate regardless of order.

If deterministic ordering across runs matters (e.g., leaf ordering), it depends on MTG traversal order and child order in the tree.

#### Dependency graph ↔ MTG traversal
Dependency graphs are computed from model inputs/outputs and mapping information, but execution over the MTG is a two-layer process:
- The dependency graph gives process order.
- For each dependency node, `run_node_multiscale!` iterates over all MTG nodes **at that scale** (the list of Status instances for the scale).

So graph order is independent of MTG topology (e.g., parent/child), except that MTG defines which nodes exist per scale and thus which Status objects get updated at each step. The MTG tree does not currently drive execution order within a scale; if intra-scale ordering matters (e.g., parent before child), that would require an explicit order derived from MTG traversal rather than the current simple loop.

#### Implications checklist
- If you mutate the MTG topology (insert/delete/reparent nodes) after initialization, you must re-run `init_statuses` (or provide an incremental update) to keep Status arrays and node attributes consistent.
- The ordering of entries in `RefVector` depends on MTG traversal order and child ordering; if deterministic ordering across runs matters, enforce child order or define a stable traversal.
- Because execution order within a scale is currently a flat loop over statuses, any parent/child ordering assumptions within a scale are *not* guaranteed.
- Cross-scale data sharing is by reference; if a model mutates a variable that is referenced elsewhere, it will be visible immediately within the same timestep unless explicitly deferred.
- Hard dependencies bypass the soft-dependency graph; be careful to avoid hidden cycles or implicit ordering expectations.

### GraphSimulation
File: `src/mtg/GraphSimulation.jl`
- Wraps MTG + statuses + dependency graph + mapping outputs.
- `run!(::GraphSimulation, ...)` traverses dependency graph roots and executes models on each scale.

## Execution engine

File: `src/run.jl`

### Single-scale ModelList
- `run!(ModelList, meteo, constants; tracked_outputs, check, executor)`
- For each timestep:
  - Flatten vector-valued status variables (if any)
  - Execute dependency graph roots via `run_node!`
  - Save outputs into `TimeStepTable`
- If time-step parallelization is allowed (traits), it runs with `FLoops`.

### Multiscale MTG
- `run!(mtg, mapping, meteo; nsteps, tracked_outputs)`
- Builds a `GraphSimulation` and uses `run_node_multiscale!` to execute each process for all nodes at a scale.
- Multiscale models operate at one scale at a time, and model inputs may reference other scales via shared references.

### Parallel traits
Files: `src/traits/parallel_traits.jl`
- Models can declare parallel independence over time-steps or objects.
- If traits say no, the engine runs sequentially even with a parallel executor.

## Special variable wrappers

File: `src/variables_wrappers.jl`
- `UninitializedVar`: marks required variables not yet supplied.
- `PreviousTimeStep`: excludes a variable from dependency graph, using previous time step value to break cycles.
- `RefVariable`: used to alias or rename variables within the same Status.

## Key design behaviors (important for extension)

- Dependency graph is computed from *current* inputs/outputs. `PreviousTimeStep` variables are removed from graph to break cycles.
- Status is reference-based, so cross-scale data sharing is by reference, not copying.
- Hard dependencies are executed manually inside model code. The graph only knows they exist and excludes them from soft dependency inference.
- Multiscale dependency graph is built by first computing hard-dependency roots per scale, then linking soft dependencies across scales using mapping.
- MTG status initialization is where cross-scale references are wired (RefVector creation and population).

## Useful entry points for debugging

- `dep(m::ModelList)` or `dep(mapping::Dict)` to inspect graph.
- `inputs(model)`, `outputs(model)`, `variables(model)` to confirm interface.
- `init_statuses(mtg, mapping, dep(mapping))` for multiscale wiring.
- `which_timestep_parallelizable(dep_graph)` and `which_object_parallelizable(dep_graph)` for parallel analysis.

## Relevant files by responsibility

- Core model interface: `src/Abstract_model_structs.jl`, `src/processes/models_inputs_outputs.jl`
- Status and references: `src/component_models/Status.jl`, `src/component_models/RefVector.jl`, `src/variables_wrappers.jl`
- Model list and execution: `src/component_models/ModelList.jl`, `src/run.jl`
- Dependency graphs: `src/dependencies/*`
- Multiscale mapping: `src/mtg/mapping/*`, `src/mtg/MultiScaleModel.jl`
- MTG initialization: `src/mtg/initialisation.jl`
- MTG runtime wrapper: `src/mtg/GraphSimulation.jl`

## Known pain points relevant to upcoming features

- Single-scale model lists and multiscale MTG simulations have separate execution paths with duplicated logic.
- Dependency graph nodes are mutable and used for runtime execution order tracking (`simulation_id`), which complicates concurrency and reuse.
- Model identity is keyed by process + scale only, so same scale across multiple plants currently shares models.
- Time-step handling is global to the run; there is no built-in multi-rate scheduler (per-model dt).
- Cross-scale references are built only during MTG initialization; reusing or modifying mappings is cumbersome.
