# Coupling models

PlantSimEngine has three coupling mechanisms with different ownership:

| Mechanism | Use it when | Who owns the operation? |
|---|---|---|
| Value coupling | A consumer reads a producer's accepted value | The scenario declares `inputs`; the compiler transports references or streams |
| Hard call | A parent must choose when or how often a child executes | The parent declares `Call` and invokes `run_call!` |
| Adapter model | Unit, basis, temporal meaning, or aggregation changes | An ordinary model owns and tests the explicit conversion |

Use `inputs` when a model reads a value produced by another application. A
unique same-object producer is inferred; cross-object sources should use an
explicit `One`, `OptionalOne`, or `Many` selector. Inspect the resolved
references with `Diagnostics.explain_bindings`.

Use `calls` only when a parent algorithm owns child execution or iteration.
Use `run_call!(context, :name)` to execute every resolved target. Pass
`sampled_environment=value` to this bulk path when the caller already has one
model-facing environment for all targets. Use `call_model(context, :name)` to
inspect a singular dependency model without materializing a public target. For
selection, target status access, custom ordering, or distinct environments,
retrieve the vector-like collection with `call_targets(context, :name)` and
execute individual targets. Trial calls use `publish=false`; accepted state is
published once.
Nested calls inherit publication suppression, so a descendant cannot publish
inside an unpublished ancestor trial. `Diagnostics.explain_calls` and `Diagnostics.explain_schedule`
show call-only targets and ordering.

`Diagnostics.explain_initialization(model)` classifies values as supplied, generated,
producer-bound, defaulted, required, or environment-bound before execution.

## Value coupling

A consumer on the same object needs no scenario syntax when exactly one
canonical producer exists. Make cross-object intent explicit:

[Implement Cross-Object Values](@ref) is the executable example: a plant
consumer receives a `Many(...; within=Subtree())` collection from its own
leaves while PlantSimEngine preserves each source object's identity.

`One` is a contract: zero or multiple matches are errors. Use `OptionalOne`
only when absence has a scientific meaning, and `Many` when aggregation is
part of the consumer model. `within=Subtree()` searches descendants of the
current target; `within=Self()` selects only the current target;
`within=SelfPlant()` anchors repeated plant instances; and `SceneScope()`
is deliberately global.

By default, an input selector also identifies applications that produce the
selected variable, and those producers are scheduled before the consumer. Use
`from_status=true` only when the input deliberately reads the objects' current
`Status` references independently of any producer. Declare that selector as
`Many(...; var=:reserve, from_status=true, after=:plant_allocation)`.

This is a same-step live-reference binding. It cannot be combined with
`process`, `application`, `policy`, or `window`. It does not infer a producer
edge; use `after=:application_id` when the state must be read or mutated after
a particular application. Otherwise, the scenario's application order is
preserved.

## Manual calls

[Implement A Hard Dependency](@ref) is the executable parent/child example.
Inside a controller, iterate over `call_targets(context, :leaf_energy)`. Run
candidate states with `run_call!(target; publish=false)` and publish the
accepted state once with `publish=true`. A call-only target is excluded from
root scheduling, and an unpublished outer call suppresses publication by every
nested descendant.

## Explicit adapters

Variable renaming only changes the local field name. It must never silently
convert molar to mass units, ground-area to plant-area basis, rates to totals,
or one carbon convention to another. Put that operation in a small, named
model with a contract on each side. The executable adapter shipped with the
agent skill converts radiation per unit ground area to radiation per plant:

```@example coupling-adapter
using PlantSimEngine

asset = joinpath(
    pkgdir(PlantSimEngine),
    "skills",
    "plantsimengine",
    "assets",
    "adapter-model.jl",
)
include(asset)
using .AdapterModelExample

adapter = GroundToPlantRadiation(2.5f0)
contracts = variable_contracts(adapter)
(
    input_contract=contracts.par_ground,
    output_contract=contracts.par_plant,
)
```

```@example coupling-adapter
adapted = adapter_scenario(Float32)
report = Authoring.validate_scenario(adapted)
simulation = run!(adapted)
(
    structurally_valid=report.valid,
    plant=final_state(simulation, :plant),
)
```

The producer-to-adapter binding matches `GROUND_PAR_CONTRACT`; the
adapter-to-consumer binding matches `PLANT_PAR_CONTRACT`. The conversion
parameter, equation, units, and bases are now visible and testable. Document
the scientific domain and validity limits explicitly; the fixture does not
invent them. Use the same pattern for temporal or carbon-basis conversions.

After compilation, inspect `Diagnostics.explain_bindings(compiled)` for source identity
and carrier type, `Diagnostics.explain_calls(compiled)` for call-only targets, and
`Diagnostics.explain_schedule(compiled)` for root execution order. These rows are the
supported diagnostic surface; compiled fields are internal.
