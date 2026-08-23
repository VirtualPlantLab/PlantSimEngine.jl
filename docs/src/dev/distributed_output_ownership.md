# Distributed output ownership

Status: implemented public and compiler contract.

## Problem

Most PlantSimEngine applications compute outputs on the same objects on which
they execute. Some scientifically useful models have a different shape:

- one radiative-transfer model executes once on a complete scene and computes
  values for every simulated organ;
- one plant allocation model executes once per plant and computes allocation
  and reserve values for many organs; or
- one soil or microclimate model executes on a shared domain and computes local
  values for several plant objects.

These are not hard calls to per-object models. The scene or plant application
owns the computation and cadence, while each destination object owns its local
state value.

Passing writable `Many(...; from_status=true)` carriers can modify those
values, but it does not declare the producing application as their writer.
Producer inference, scheduling, diagnostics, lifecycle refresh, and output
retention would then lose the scientific ownership of the result.

## Terms

- **Execution target:** the object on which an application runs. A scene light
  model has one `Scene` execution target.
- **Output destination:** an object whose status owns one output computed by
  that application. The same scene light application can have many `Leaf` and
  `Internode` destinations.
- **Output binding:** the compiled relationship between one application,
  execution target, destination selector, destination object IDs, and declared
  output variables.
- **Destination ownership:** the writer relationship
  `(destination_object_id, variable) => application_id`.

Execution targets and output destinations are deliberately distinct. A model
does not need fake per-organ applications merely to publish values computed
elsewhere.

## Public declaration and scene writer

The scenario declares named destination groups with `outputs_to`:

```julia
ModelSpec(
    SceneLightModel(solve_light);
    name=:scene_light,
    on=One(scale=:Scene),
    outputs_to=(
        organs=OutputTo(
            Many(
                scale=(:Leaf, :Internode),
                within=SceneScope(),
            );
            vars=(
                incident_par=Default(0.0),
                absorbed_par=Default(0.0),
                sky_fraction=Required(Float64),
            ),
        ),
    ),
)
```

`Default(value)` creates the destination status variable when needed.
`Required(T)` requires it to exist on every selected destination. Only
`coverage=:exact`, the default, is accepted.

The scene kernel looks up its compiled group and publishes an identified
solver table:

```julia
PlantSimEngine.@process "scene light" verbose = false

struct SceneLightModel{F} <: AbstractScene_LightModel
    solve::F
end

PlantSimEngine.inputs_(::SceneLightModel) = NamedTuple()
PlantSimEngine.outputs_(::SceneLightModel) = NamedTuple()

function PlantSimEngine.run!(
    model::SceneLightModel,
    status,
    environment,
    constants,
    context,
)
    targets = output_targets(context, :organs)
    result = model.solve(
        runtime_model(context),
        environment,
        object_ids(targets),
    )
    assign_outputs!(targets, result; id=:object_id)
    return nothing
end
```

`result` may be any Tables.jl-compatible row or column table. Its row order is
independent of selector order because assignment uses `ObjectId` values.

## `OutputTargets` runtime surface

`output_targets(context, :organs)` performs a typed lookup on the current
`RunContext`; it does not resolve a selector or rebuild an identity index in
the model call. The group name must be a `Symbol` declared by the current
application.

The returned `OutputTargets` supports `length`, `isempty`, `eachindex`, and
`object_ids`. Its destination carriers are available only through the explicit
column namespace:

```julia
targets.columns.incident_par
targets.columns.absorbed_par
```

Output variables and compiled-binding metadata are deliberately not forwarded
into the public property namespace: `propertynames(targets)` exposes only
`:columns`. This keeps output names separate from implementation fields. An
output named `columns` remains accessible as `targets.columns.columns`.

`object_ids(targets)` is an aligned, read-only identity carrier over the
compiled destination IDs. Positions have no botanical meaning. Direct
positional writes to `targets.columns.<variable>` are valid when the producing
algorithm already uses this exact identity order; identified external results
should use `assign_outputs!`.

An `OutputTargets` value belongs to the current model invocation and lifecycle
generation. Kernels obtain it from `RunContext` on every call and do not store
it on their model.

## Identified assignment

The Tables.jl path is the general adapter:

```julia
assign_outputs!(targets, result_table; id=:object_id)
```

The lower-level path accepts stable columns directly:

```julia
assign_outputs!(targets, result_ids, result_columns)
```

Here `result_ids` is an `AbstractVector` and `result_columns` is a
`NamedTuple`. The lower-level overload avoids a Tables.jl adapter but uses the
same validation, identity mapping, and assignment implementation.

Both forms require:

- one result ID for every current destination;
- no unknown, duplicate, extra, or missing IDs;
- equal lengths for the ID and every declared result column; and
- every variable declared by the `OutputTo` group.

Additional table or `NamedTuple` columns are metadata and are ignored. They
can carry solver-facing values such as `source_element`, `component_index`, or
geometry provenance without becoming status variables. Conversely, omitting a
declared output is an error even when that destination status already has a
value.

No subset or retain-last coverage mode exists. An adapter handles filtered,
abscised, dead, or non-geometrized organs deliberately, or the destination
selector excludes them.

## Identity and permutation cache

Each compiled output binding stores destination IDs, an ID-to-position index,
and live reference-backed columns. The first assignment validates the result
IDs and compiles either an exact-order marker or a row-to-destination
permutation.

The runtime cache is keyed by object identity of the result ID column. Reusing
the same ID-column object promises that its IDs and order are immutable; the
cache does not rescan or hash its contents on every timestep. Value columns may
be mutated and reused freely. Replace the ID-column object whenever its IDs or
order changes.

This contract applies to both public overloads because the Tables.jl path
extracts its ID column before entering the lower-level implementation. Reusing
a table with the same ID carrier reuses the mapping; constructing a new ID
carrier triggers validation and recompilation.

## Atomic validation and aliasing

Coverage, column lengths, value conversions, and source/destination aliasing
are checked before any destination status is changed. If mapping validation
fails, the partially reused cache buffers are marked invalid so a later valid
assignment recompiles cleanly.

A result column may share destination storage only when all three conditions
hold:

1. the result IDs are already in exact destination order;
2. the source is the same declared output column; and
3. the source and destination use the same complete mapping.

Permuted views, partially overlapping views, cross-column aliases, and
permuted self-assignment are rejected. Custom array wrappers that can share
storage must implement Julia's `Base.dataids` and `Base.mightalias` contract so
PlantSimEngine can detect that relationship before mutation.

## Compilation, ownership, and ordinary consumers

For every output group, compilation resolves:

1. the producing application and execution object;
2. the destination selector and current destination IDs;
3. declared variables and their `Required` or `Default` initialization;
4. concrete reference-backed destination columns;
5. the destination ID index; and
6. writer ownership for every `(destination_id, variable)` pair.

Destination status initialization occurs before consumer input compilation.
Writer collisions are rejected unless an existing `Updates(...; after=...)`
declaration establishes intentional ordering.

A destination model consumes the value through its ordinary input contract:

```julia
PlantSimEngine.inputs_(::LeafPhotosynthesis) = (
    absorbed_par=Required(Float64),
)

ModelSpec(
    LeafPhotosynthesis();
    name=:leaf_photosynthesis,
    on=Many(scale=:Leaf),
)
```

Producer inference finds the scene application that owns
`(leaf_id, :absorbed_par)`, binds the leaf status field, and schedules the
scene writer before the leaf consumer. The consumer does not use
`output_targets`, `from_status=true`, a copy model, or an explicit
`after=:scene_light` dependency.

## Lifecycle

The scenario application graph and selectors remain immutable while object
membership may change. At a supported lifecycle barrier, PlantSimEngine:

- rebuilds affected destination memberships and reference columns;
- rebuilds the destination ID index;
- advances the binding membership generation and invalidates result mappings;
- updates writer ownership and consumer scheduling metadata;
- initializes new destination status variables; and
- opens or closes retained streams as requested.

An empty destination group remains a typed `OutputTargets` group and can gain
members after organ creation. The next model invocation receives the refreshed
view and recompiles its result mapping. Ordinary timesteps do not resolve the
selector or traverse the graph.

## Output retention and diagnostics

Retained streams are keyed by producing application, destination object, and
variable. Distributed destinations change which object IDs are enumerated,
not the scientific identity of the producer.

Use the supported diagnostics rather than inspecting compiled fields:

- `Diagnostics.explain_output_bindings` shows execution objects, groups,
  destination IDs, column carrier types, coverage, and membership generation;
- `Diagnostics.explain_writers` shows the producing application for each
  destination variable;
- `Diagnostics.explain_bindings` and `Diagnostics.explain_schedule` show
  ordinary consumer coupling and execution order; and
- `Diagnostics.explain_output_retention` shows retained destination streams.

`outputs=:none` does not allocate destination-history streams. Current values
remain visible through `final_state` because assignment writes directly to
destination statuses.

## Performance characteristics

The implementation keeps ordinary applications on their existing path.
Applications without distributed outputs use the empty compiled marker and an
empty output-target tuple; they do not resolve selectors or build assignment
caches.

For distributed outputs:

- destination selectors, IDs, indexes, ownership, and columns are compiled
  before execution;
- stable ID carriers reuse their exact-order marker or permutation;
- exact-order assignment avoids indexed destination lookup in the write loop;
- homogeneous destination references produce typed `RefVector{T}` columns and
  a concrete recursive column loop;
- heterogeneous destination reference types fall back to `ObjectRefVector`,
  with conversion against each destination reference; and
- lifecycle changes rebuild only the affected compiled execution targets.

After warm-up, the stable homogeneous exact-order and permuted columnar paths
can execute without allocations. Heterogeneous destinations preserve correct
per-object types but are an intentionally slower fallback. Benchmark
compilation, lifecycle refresh, steady-state assignment, and output collection
separately when changing these internals.

## Alternatives rejected

### A second `Many` of IDs

This duplicates compiler-owned identity, lets selectors diverge, and treats
identity as a biological input. It also does not solve writer ownership,
scheduling, or retention.

### Fake per-object applications

These misrepresent computation and cadence, enlarge the application graph, and
make bookkeeping models appear scientifically meaningful.

### Public `CallTargets` reuse

`CallTargets` represents executable callee applications and includes model,
environment, status-view, and hard-call state. Distributed outputs need the
lighter columnar `OutputTargets` view.

### Per-step table join

A table join or MTG traversal in every model execution is avoidable work and
makes ordering errors possible. PlantSimEngine compiles the identity mapping
once per stable ID carrier and invalidates it when destination membership
changes.
