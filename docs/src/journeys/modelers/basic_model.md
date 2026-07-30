# Implement A Basic Model

This page introduces one model-author concept: the complete one-step model
contract. It then proves that the same kernel composes automatically on one
object and runs unchanged over several objects.

For the simulation-user view of these scenarios, see
[Couple Models On One Object](@ref) and
[Run The Coupling On Several Objects](@ref).

## Model 1: declare the complete contract

`ToyDevelopmentModel` has one generic parameter, one required input, one true
default, one output initial value, and the final five-argument kernel. This is
the complete tested implementation from `examples/ToyModelDeveloper.jl`:

```julia
struct ToyDevelopmentModel{T} <: AbstractToy_DevelopmentModel
    efficiency::T
end

PlantSimEngine.inputs_(::ToyDevelopmentModel) = (
    TT=Required(Real),
    stress=Default(1.0),
)
PlantSimEngine.outputs_(model::ToyDevelopmentModel) = (
    growth=zero(model.efficiency),
)

function PlantSimEngine.run!(
    model::ToyDevelopmentModel,
    status,
    environment,
    constants,
    context,
)
    status.growth = model.efficiency * status.TT * status.stress
    return nothing
end
```

`Required(Real)` is a contract, not an initialization value. `Default(1.0)`
means the scientific model genuinely defines unstressed growth as its
fallback. Output values initialize model state and should match the parameter's
numeric type where practical.

Test the kernel directly before involving a scenario:

```@example modeler_basic
using Dates, PlantMeteo, PlantSimEngine, DataFrames
using PlantSimEngine.Examples

development = ToyDevelopmentModel(0.5)
status = Status(TT=8.0, stress=0.75, growth=0.0)
PlantSimEngine.run!(
    development,
    status,
    nothing,
    nothing,
    nothing,
)
status.growth
```

## Model 2: let one object couple it automatically

`ToyDegreeDaysCumulModel` publishes `TT`; `ToyDevelopmentModel` requires `TT`.
Because both applications target the same object and the producer is unique,
the scenario needs no explicit `inputs` wiring:

```@example modeler_basic
one_object = CompositeModel(
    Object(:leaf; scale=:Leaf);
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel(T_base=10.0);
            name=:thermal_time,
            on=One(scale=:Leaf),
        ),
        ModelSpec(
            development;
            name=:development,
            on=One(scale=:Leaf),
        ),
    ),
    environment=Atmosphere(
        T=18.0,
        Wind=1.0,
        Rh=0.7,
        duration=Day(1),
    ),
)

select(
    DataFrame(Diagnostics.explain_bindings(one_object)),
    :application_id,
    :input,
    :origin,
    :source_application_ids,
    :carrier_kind,
)
```

```@example modeler_basic
one_simulation = run!(one_object)
final_state(one_simulation)
```

PlantSimEngine creates `stress=1.0` from the model default and connects `TT`
through a shared `Ref`. The development kernel knows neither fact.

## Model 3: reuse the kernel over several objects

Change only application multiplicity from `One` to `Many`:

```@example modeler_basic
several_objects = CompositeModel(
    Object(:leaf_1; scale=:Leaf),
    Object(:leaf_2; scale=:Leaf);
    applications=(
        ModelSpec(
            ToyDegreeDaysCumulModel(T_base=10.0);
            name=:thermal_time,
            on=Many(scale=:Leaf),
        ),
        ModelSpec(
            development;
            name=:development,
            on=Many(scale=:Leaf),
        ),
    ),
    environment=Atmosphere(
        T=18.0,
        Wind=1.0,
        Rh=0.7,
        duration=Day(1),
    ),
)

final_state(run!(several_objects), Many(scale=:Leaf))
```

Do not loop over objects inside `ToyDevelopmentModel.run!`. PlantSimEngine
compiles homogeneous execution targets and invokes the one-target kernel for
each selected object.

## Model-author recap

- **You implemented:** parameters, `Required`/`Default` inputs, output initial
  state, and one-target arithmetic.
- **PlantSimEngine inferred:** default initialization, same-object coupling,
  execution order, and repeated targets.
- **The scenario author keeps explicit:** objects, application names,
  multiplicity, and environment data.
- **New API names:** `AbstractModel`, `inputs_`, `outputs_`, `Required`,
  `Default`, and `run!`.
