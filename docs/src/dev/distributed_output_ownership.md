# Distributed output ownership

Status: design contract for the `distributed-output-targets` implementation.
Public names shown below remain provisional until the focused prototype and
performance gates pass.

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

Passing writable `Many(...; from_status=true)` carriers can modify those values,
but it does not declare the producing application as their writer. Producer
inference, scheduling, diagnostics, lifecycle refresh, and output retention
therefore cannot recover the scientific ownership of the result.

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
must not be mounted on fake per-organ applications merely to publish values
computed elsewhere.

## Indicative declaration

The proposed scenario spelling is:

```julia
ModelSpec(
    SceneLightModel();
    name=:scene_light,
    on=One(scale=:Scene),
    outputs_to=(
        organs=OutputTo(
            Many(
                scale=(:Leaf, :Internode),
                within=SceneScope(),
            ),
            vars=(
                :incident_par,
                :absorbed_par,
                :sky_fraction,
            ),
        ),
    ),
)
```

Inside the kernel, the application obtains its already compiled destinations:

```julia
targets = output_targets(context, :organs)
assign_outputs!(targets, result_columns; id=:object_id)
```

`outputs_to`, `OutputTo`, `OutputTargets`, `output_targets`, and
`assign_outputs!` are working names, not yet stabilized API.

## Identity contract

PlantSimEngine already stores each compiled `Many` binding as aligned object IDs
and a carrier. Selector results use stable `ObjectId` order; collection position
has no botanical or scientific meaning and may change when lifecycle refresh
rebuilds a binding.

An output result must therefore be associated by `ObjectId`, never by MTG
traversal order or an independently declared ID selector. A model-facing
identity-aware view may expose:

```julia
values = bound_input(context, :organ_values)
object_ids(values)
```

The first implementation should leave the ordinary `RefVector` status carrier
unchanged. Identity-aware access is opt-in until explicit `RefVector` dispatches
and performance have been audited.

## Compilation and initialization

For every output binding, compilation must determine:

1. the producing application and execution object;
2. the destination selector and compiled matcher;
3. destination `ObjectId` values in stable order;
4. declared destination variables and their initial values or requirements;
5. concrete, reference-backed destination columns; and
6. writer ownership for every `(destination_id, variable)` pair.

Destination status initialization occurs before consumer input compilation.
The compiler must reject a destination variable that cannot be initialized or
validated under the selected policy.

Ordinary same-object outputs stay on their current fast path. They may later be
represented internally as implicit `Self()` output bindings only if that
unification has no common-path cost.

## Writer ownership and scheduling

Producer inference must query destination ownership rather than only the
applications mounted on the source object. Consequently, a leaf input can find
a scene application that owns `(leaf_id, :absorbed_par)` and schedule after it
without `from_status=true` or a manual `after=` declaration.

Two applications may not own the same `(destination_id, variable)` unless an
existing, explicit update policy correctly defines their order. Combining
independent producers through a reduction is a separate concept and is outside
this design.

## Coverage and assignment

The default assignment policy is exact coverage:

- every result ID is known;
- IDs are unique;
- every destination expected by the binding is present; and
- every assigned variable was declared.

Subset coverage may be added only with an explicit missing-value policy. It
must not silently convert a missing result to zero or retain an old value.
Scientific adapters decide whether a dead, abscised, filtered, or
non-geometrized object should remain a destination.

`assign_outputs!` has two paths:

1. a checked Tables.jl-compatible path that validates IDs, columns, and
   coverage and compiles a row-to-destination permutation; and
2. a stable bound path that reuses a previously validated identity/order plan
   and performs one typed pass over the result columns.

Validation should finish before status mutation where possible. A complete copy
of every result column is not required.

## Lifecycle

The scenario application graph and selectors remain immutable. Object
membership may change.

At a lifecycle barrier, PlantSimEngine refreshes only affected output bindings:

- add or remove destination IDs and reference columns;
- update the ID-to-position index;
- invalidate a cached result permutation when membership changed;
- update writer ownership and consumer scheduling metadata;
- initialize newly declared destination status; and
- add or close retained streams as required.

Ordinary timesteps then return to the cached execution plan without selector
resolution or graph traversal.

## Output retention and diagnostics

Retained streams remain keyed by producing application, destination object, and
variable. Distributed destinations change which object IDs are enumerated, not
the scientific identity of the producer.

Diagnostics must show:

- execution targets separately from output destinations;
- the destination selector and current destination count;
- every distributed writer and any collision;
- lifecycle refreshes and invalidated assignment plans; and
- retention policy and streams for destination objects.

`outputs=:none` must not allocate destination-history streams. Final status
inspection remains available because destination statuses are updated directly.

## Performance contract

The implementation must preserve these properties:

- no selector resolution, ID-vector copy, dictionary construction, or table
  materialization in the steady-state model call;
- no new work for applications without distributed outputs;
- concrete, columnar destination carriers rather than one type-level tuple
  entry per destination object;
- ID indexes and result permutations built at compilation or lifecycle
  barriers, not per timestep;
- zero-allocation sequential iteration over homogeneous identity-aware views;
  and
- separate measurements for compilation, lifecycle refresh, steady-state
  execution, and output collection.

The baseline and candidate must be measured on the same Julia version, hardware,
thread count, output policy, and repository revisions. Investigate a median
steady-state regression above 2%; do not accept an end-to-end regression above
5% without explicit review.

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
environment, status-view, and hard-call state. Distributed outputs need a
lighter columnar destination view. Internal selector and lifecycle cache
patterns can still be shared.

### Per-step table join

A table join or MTG traversal in every model execution is avoidable work and
makes ordering errors possible. Compile identity mapping once and invalidate it
only when membership changes.

## Open implementation decisions

- Final public names after prototype use.
- Whether identity-aware `Many` becomes the default carrier in a later breaking
  release.
- Exact subset and missing-value policies.
- Whether local outputs become implicit `Self()` bindings in the first
  implementation or a later internal refactor.
- The smallest concrete destination/index representation that preserves current
  compiler and runtime performance.
