# Public API refinement decisions

This decision record defines the target public contract for the CompositeModel/Object
API. The CompositeModel/Object compiler and runtime remain the only supported scenario
runtime.

## Terminology and identity

- An **object** is one runtime entity with a stable `ObjectId`.
- A **model** is one scientific implementation of a process.
- A **process** is model metadata and may have several applications.
- An **application** is one named, configured occurrence of a model in a model.
- User declarations that identify a producer, writer, update predecessor, call
  target, or output stream use application identity.
- Process queries are discovery filters. They are not substitutes for an
  application identifier when more than one application matches.
- Every application receives a deterministic identifier. An explicit
  `ModelSpec(...; name=...)` is used verbatim. An unnamed application uses its
  process name only when that identifier is unique; repeated unnamed
  applications are rejected with instructions to name them.
- Mounted template applications are qualified as
  `instance_name__application_name`.

## Object selectors and scope

The same `One`, `OptionalOne`, and `Many` selector values are accepted by
application targeting, inputs, calls, object queries, and output requests.

Scope names have one meaning:

- `Self()` selects only the current object.
- `Subtree()` selects the current object and all of its descendants.
- `SelfPlant()` selects the current object's plant root and its descendants.
- `Ancestor(...)` selects the matching ancestor's subtree.
- `SceneScope()` searches the whole model.
- `Scope(name)` searches the named object's subtree.
- `Relation(...)` selects objects with the requested topological relationship.

Selectors that require a current object fail when used without a context.
Cross-object coupling is always visible in the declaration through `Subtree`,
`SelfPlant`, `Ancestor`, `Scope`, `SceneScope`, or `Relation`.

## Outputs

`run!` uses an explicit `outputs` keyword:

```julia
run!(model; outputs=:none)
run!(model; outputs=:all)
run!(model; outputs=request)
run!(model; outputs=requests)
```

The default is `outputs=:none`. Temporal dependency streams required by the
runtime are still retained with bounded histories; they are not user-retained
outputs.

`tracked_outputs` is deprecated. During the deprecation period,
`tracked_outputs=nothing` maps to `outputs=:all`, an empty request vector maps
to `outputs=:none`, and other values map to `outputs=value`.

An `OutputRequest` contains an object selector, a variable, an optional
application identifier, a unique result name, and optional temporal resampling
policy. `OutputRequest(:Leaf, :x)` remains a convenience spelling that lowers
to `OutputRequest(Many(scale=:Leaf), :x)` during migration.

## Execution and continuation

`run!(model; steps=n, ...)` starts a fresh result timeline at step one while
mutating model status. It returns a live `Simulation` execution handle.

`continue!(simulation; steps=n)` advances that simulation from its current
step, preserving retained streams, temporal dependency history, environment
position, and multirate clock phase. It returns the same simulation.

`step!(simulation)` is equivalent to `continue!(simulation; steps=1)`.

Calling `run!` on an already-mutated model intentionally creates a new result
timeline. Users who intend temporal continuation use `continue!`; the distinct
operation prevents an accidental step-index reset.

Lifecycle mutations between calls to `continue!` are compiled before the next
timestep using the existing targeted invalidation contract.

## Public namespaces

The default namespace is organized around:

- model composition and execution;
- model-author declarations and kernel helpers;
- supported structured explanations;
- documented environment extension interfaces.

Compiled representation types, cache dirty flags, raw compiler stages, and
low-level invalidation helpers are qualified advanced/internal APIs unless a
documented external extension requires them. Removing an export does not make a
symbol inaccessible through `PlantSimEngine.Symbol`; it removes the accidental
promise that ordinary users should depend on it.

## Compatibility policy

- Removed legacy mapping/executor APIs are not restored.
- Current CompositeModel/Object spellings receive targeted deprecations only when they
  have a clear replacement.
- New canonical spellings are implemented and tested before deprecated aliases
  are removed.
- Benchmarks, examples, documentation, PlantBiophysics, and XPalm target the
  canonical API rather than deprecated compatibility paths.
