# XP transient layout discovery: source-only recommendation

The existing framework already has a useful cutoff before science execution:
`_targeted_new_object_call_targets(context, name, requested_ids; initializer)`
in `src/composite_model/runtime_outputs.jl:6578`. It constructs the partial
newborn application overlay, output/input status fields and references,
environment *bindings*, application-local Status views, kernel Status views,
and lightweight CallTarget owners, then returns the targets. It does not call a
model kernel or sample an environment. `run_initializer!` only reserves the
initialization key and executes `_run_call_targets!` **after** this function
returns (`runtime_outputs.jl:7509`). Thus a disposable metadata-only phase can
represent the real transient layouts without invoking `run_initializer!`,
`run_call!`, or the XP emission/initialization kernels.

This is a recommendation, not an executed result. Wait for the current XP
coverage data before implementing it. Existing frozen files are unchanged.

## Why a complete future scene can miss

Current `_xp_future_model` adds the three organs before its first zero-step
preparation. Actual `PhytomerEmission.run!` adds them to an already prepared
scene, then resolves seven calls in a specific order before the lifecycle
barrier. Targeted preparation adds outputs for all applications on an organ,
but adds input references only for the requested callees. Local Status field
sets/order, carrier shapes, and the lightweight call owner can differ from the
fully compiled future scene. A match failure would therefore be useful coverage
evidence; it would not imply scientific divergence or a required fallback.

## Small next proof

1. Independently build the initial XP scenario, enable BoundedPreparation if
   selected, and run only ordinary `run!(...; steps=0)`.
2. Obtain the already prepared `Plant__phytomer_emission` target's RunContext
   using the same `_prepare_model_execution_context!` metadata path as the
   present call collector. No scheduler step or environment sampling is needed.
3. Add the next Phytomer, Internode and Leaf with the same public `add_organ!`
   metadata/status adapter and initial-status order as XP. Keep the addition
   delta pending; do not call the global refresh yet.
4. Invoke only `_targeted_new_object_call_targets` in XP's authored call order:
   phytomer initiation age; internode initiation age; internode final potential
   dimensions; internode maintenance-respiration initializer; leaf initiation
   age; leaf final potential area; leaf maintenance-respiration initializer.
   Pass `initializer=true` only for the two declared initializer bindings.
5. Immediately record function/types/immutable labels from each returned target
   before later metadata operations replace Status wrappers. Include canonical,
   local and kernel Status types; lightweight owner and CallTarget types; the
   exact child RunContext type; and explicit declared environment row types.
   Preserve the real `Vector{CallTarget}` call path. Do not invent a homogeneous
   CompiledExecutionBatch for these targets: that would precompile a different
   execution path.
6. After collecting transient entries, an ordinary refresh may additionally
   collect post-barrier views/batches. Dispose of the entire model afterward.

The two initializer reservations should not be advertised as completed science.
The metadata function already records input-preparation cache information, but
no initialization kernels execute. Calls in the finite phase recipe are each
visited once. No live initialized-target set, RNG, streams, statuses, IDs or
carriers are reused. Declaration hooks and custom binding hooks must honor the
same independent-disposable contract as the present builder.

## Minimal generic API boundary

An optional explicit `phase_builder!` on a future archetype, invoked **after**
bounded policy and initial zero-step preparation, can accept the disposable
Simulation and a type-only emitter. It supplies a finite sequence of metadata
events and calls; it does not infer XP kernels or execute them. A helper such as
`collect_newborn_layouts!(catalogue, context, call_name, ids; initializer=false,
environment_types=...)` can encapsulate the private framework cutoff and
immediate type extraction. The emitter stores no CallTarget, Status, context,
model, environment value, Ref, or mutable default. This API is scale-independent
and also covers reproductive branches when explicitly declared later.

Start with the seven first-birth calls only, separately and with bounded
preparation. Require zero live changes, default RNG plus task seed preservation,
zero kernel/sampler work during discovery, and exact observed transient type
matches when real growth subsequently runs. Include construction, zero-step
preparation, metadata discovery and precompile costs in total latency. Request
actual `_run_call!` / vector `_run_call_targets!` entry signatures as well as the
kernel signatures; accepted hints and matching types still do not establish a
compiler cache hit or a net speedup.

## Boundaries

This can reproduce XP's current transient layouts because its seven target
kernels assign into declared references; they do not add status fields or alter
topology between these calls. It does not generically infer scientific
value-dependent structural branches. Override models, different numeric types,
Male/Female branches, spatial sampling/trial states, or arbitrary kernels that
change scientific object types need explicit additional archetypes or ordinary
first-use compilation. The normal executor remains responsible for every real
lifecycle event, selection, reservation, publication, environment sample and
scientific value.
