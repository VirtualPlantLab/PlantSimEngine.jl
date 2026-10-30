# Fixed structure, dynamic organ count: what is reusable

Source-only assessment of this investigation checkout, 2026-10-30. No Julia,
new implementation, or edits to frozen prototypes were performed for this note.

## What the current prototypes establish

`CompiledApplicationPlan` separates authored model/selector/cadence declarations
from `CompiledModelApplication.target_ids`. `_compile_model_applications` creates
an application plan even when it currently has no targets. `_extend_compiled_scene`
already shares the immutable `scenario_plan` during supported growth. Vector
length and object ID values need not enter Julia type parameters.

BoundedPreparation strengthens that separation: scenario-wide sequences and
indexes have stable container types instead of one increasingly wide Tuple or
NamedTuple type per scenario shape. Individual scientific model, status, carrier
and homogeneous execution-target types remain concrete. Increasing the number
of same-archetype organs can therefore reuse compiled numerical methods and
metadata code. Ordinary core already permits much of this same-archetype reuse;
the bounded prototype removes extra scenario-wide type-width exposure rather
than inventing organ-count independence. This is a source-based consequence,
not a measured guarantee that first birth has no JIT. A genuinely new status/kernel/context layout still needs
its own method specialization.

PlanViewReuse caches symbolic binding-shape/Many-slot assembly recipes, never
scientific references or samples. Repeated or newborn rows of a seen shape can
skip ordinary view-schema discovery. Plain preservation reuses an already
assembled reference tuple/compatible BoundMany interface but still creates the
fresh Status identity required by ordinary behavior. It does not call Julia
`precompile`, does not prepare recipes for targetless applications, and does not
predict all future canonical Status layouts. Existing unaffected view reuse is
ordinary core behavior and is not an additional gain of this prototype.

## Compiled code versus live state

| Reusable before growth, when its schema is known | Must be constructed or refreshed for actual organs |
| --- | --- |
| Model declarations and parameter-dependent port names/types; cadence and temporal policy definitions | Actual IDs, topology/selector membership, source/destination ordering |
| Status assembly operations and concrete value/reference types after conversion | Fresh scalar/default-array cells, canonical identities and aliases |
| Static call-slot names, model variants and audited kernel signatures | CallTargets, execution owners/leases, cache epochs and accepted evaluations |
| Prepared environment input schema and sampler/kernel method code | Object-specific handles and fresh mutable committed/trial samples |
| Stream schema/publication method code | Timeline position, temporal/private scratch, retained samples and stream buffers |

A blueprint must cache operations/types rather than one instantiated Status,
mutable default array, reference carrier, source-ID vector or sampled row. The
same model concrete type can have parameter-dependent declarations. Status
conversion/transform policies and Overrides also affect the required signatures.

## Remaining first-birth specialization

A targetless application has no real Status/view/target from which the current
code learns the complete execution signature. First birth can introduce the
canonical Status field order and reference types, a projected kernel status,
BoundMany carrier/interface type, private temporal storage, output-stream and
call-context types, and environment-handle/row types. Extra user/MTG fields,
new numerical value types, and a new override can introduce additional layouts.

Even with a fixed declaration graph, an initially empty `Many` can use an untyped
carrier before its first homogeneous source appears. Precompiling only the
nonempty layout would miss the empty-to-typed transition. Preserve ordinary
runtime representation by precompiling the finite relevant variants rather
than silently changing empty-carrier semantics. Cardinality itself belongs in
vectors; it need not generate one method per organ count.

## One bounded next proof

Test an eager, per-application layout/call blueprint for **one explicitly declared
future object archetype**, with its worker application initially targetless:

1. The archetype declares labels/application eligibility, initial status field
   names and value/reference types after conversion, known model/override
   variants and environment schema/handle types. It supplies constructors or
   initialization operations, not shared initialized state. Use a generic kind
   label and Float32 state; do not infer a special leaf or package path.
2. Prepare a symbolic status/binding/call-slot blueprint even with zero targets.
   Compile its exact constructor and kernel signatures with type-only
   `Base.precompile` requests. Do not execute scientific kernels on real state
   to warm them: those kernels may mutate state, consume RNG or change topology.
3. Begin with a scalar local worker plus a known singular static child. Add one
   Many input as a separate boundary case, explicitly including empty and typed
   carrier signatures. Avoid enumerating the cross-product of every optional
   port/model/retention choice in the first experiment.
4. Measure blueprint construction/JIT, first-birth binding/state creation and
   first numerical execution separately, while also reporting their total.
   Moving JIT earlier can improve predictability without reducing total cost;
   that must not be sold as a complete-time improvement.
5. Compare 0→1→2 same-archetype births against ordinary execution, then a small
   0→8 repeat only if promising. Require exact per-step state/history/topology,
   fresh per-organ arrays/cells, public target/local Status identity parity,
   aligned live Many inputs and real original-kernel work. Report observed
   layout/signature reuse and per-phase JIT; inspect IR only after measurement.
6. Deliberately introduce an undeclared extra field/type, override, reparenting
   or changed environment contract. Invalidate/rebuild the relevant blueprint
   through the ordinary path. Supported PSE features remain available beyond
   the guarded archetype rather than relying on cached membership or samples.

A possible clean future API is `prepare!(scenario; archetypes=..., precompile=:declared)`
with one explicit archetype catalogue. This is a proposal, not an implemented
API. The important contract is that known future layouts are declared; fixed
model types alone do not establish them. Backend-wide planning remains bounded,
while numerical specialization is limited to the declared model/status/context
signatures rather than to organ identity or current count.
