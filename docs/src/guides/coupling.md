# Coupling models

Coupling means letting models work together. For example, a light model can
calculate the radiation that a growth model needs. The growth model then reads
that result as an input.

Choose how to connect your models from the calculation you need:

| Coupling task | Example | How to set it up |
|---|---|---|
| Value coupling | Growth reads the radiation calculated by a light model | Connect the output to the input with `inputs` |
| Manual call, also called a hard dependency | An energy-balance model runs a photosynthesis model iteratively until convergence | Declare `Call`, then use `run_call!` inside the energy-balance calculation |
| Value conversion (adapter model) | Radiation per square metre must become radiation per plant | Write an ordinary model for the conversion and connect it with `inputs` |

A **model application** is a model configured with `ModelSpec`: it has a name,
a choice of objects, and any settings needed for its inputs or timing.

## Value coupling

Suppose a growth model needs `absorbed_par`. If exactly one model on the same
object writes that variable, PlantSimEngine connects them automatically and
runs the light calculation first. When the value comes from another object,
describe where to find it in `ModelSpec(...; inputs=...)`.

Use these selectors to choose how many objects supply a value:

| Selector | Meaning |
|---|---|
| `One(...)` | Exactly one match is required; zero or several matches are errors |
| `OptionalOne(...)` | A match may be absent; use this only if your model can meaningfully handle that absence |
| `Many(...)` | Read several values, for example to add the respiration of all leaves |

The `within` setting limits where PlantSimEngine looks. `Self()` means the
current object. `Subtree()` means that object and its descendants, such as a
plant and its organs. `SelfPlant()` means the plant instance to which the
current object belongs. `SceneScope()` searches the whole simulation.

[Implement Cross-Object Values](@ref) gives a complete example: a plant model
reads respiration from its own leaves with `Many(...; within=Subtree())`.
The model then adds those values. Choosing `Many` does not perform the sum
for you.

Normally, PlantSimEngine identifies which model writes an input and runs it
before the model that reads it. Sometimes you want to read a value already
stored in an object's `Status`, such as an initial soil-water reserve. Use
`from_status=true` for this case.

That setting reads the current stored value directly. It does not look for a
model that should calculate it first. If you need to wait for a particular
calculation, name it with `after`, for example
`Many(...; var=:reserve, from_status=true, after=:plant_allocation)`.
Otherwise, the applications keep their order in the scenario. You cannot
combine `from_status=true` with `process`, `application`, `policy`, or `window`.

Use `Diagnostics.explain_bindings(model)` to see where each input comes from.
`Diagnostics.explain_initialization(model)` shows how starting values are
obtained, including values you supplied, defaults, and missing required inputs.

## Let two models update the same value

Normally, only one model may set a given variable on an object. If two models
both set `stock`, PlantSimEngine needs to know which value to keep. If the
second model is meant to change the first model's result, use `Updates` to
specify their order. Without that instruction, this configuration is rejected
before either model runs. `ToyStockWriterModel(value)` simply stores the given
number; the values below illustrate ordering, not a biological stock model:

`initial_stock` sets `stock` first, then `adjusted_stock` changes it. The third
model calculates an alternative value that we want to keep for comparison.
`output_routing=(stock=:stream_only,)` records that alternative in its own
output history without replacing the object's `stock` value.

```@example coupling-writers
using Test, PlantSimEngine, DataFrames
using PlantSimEngine.Examples

writer_model = CompositeModel(
    Object(:reserve; scale=:Organ);
    applications=(
        ModelSpec(
            ToyStockWriterModel(4);
            name=:initial_stock,
            on=One(scale=:Organ),
        ),
        ModelSpec(
            ToyStockWriterModel(8);
            name=:adjusted_stock,
            on=One(scale=:Organ),
            updates=Updates(:stock; after=:initial_stock),
        ),
        ModelSpec(
            ToyStockWriterModel(99);
            name=:alternative_stock,
            on=One(scale=:Organ),
            output_routing=(stock=:stream_only,),
        ),
    ),
)

select(
    DataFrame(Diagnostics.explain_writers(writer_model)),
    :object_id,
    :variable,
    :application_ids,
    :update_application_ids,
    :update_after,
)
```

The table lists the models that write the object's stored `stock` and their
order. The alternative only contributes to saved output history. Run all
three applications and collect that history:

```@example coupling-writers
writer_simulation = run!(writer_model; outputs=:all)
stored_stock = final_state(writer_simulation).stock
published = collect_outputs(writer_simulation, :reserve, :stock)
@test stored_stock == 8.0 # hide
@test Dict(row.application_id => row.value for row in eachrow(published)) == Dict( # hide
    :initial_stock => 4.0, # hide
    :adjusted_stock => 8.0, # hide
    :alternative_stock => 99.0, # hide
) # hide
select(published, :application_id, :value)
```

The object's final `stock` is `8`. The three models' output histories keep
their respective values: `4`, `8`, and `99`. The `:stream_only` setting never
lets the alternative replace the stored `stock`, even if no other model sets
it. If you use `OutputRequest` to save selected results, name
`:alternative_stock` explicitly to retain its output; requesting `stock`
without an application name does not select this alternative.

## Manual calls

A model that controls another model's calculation is called a **controller**.
For example, an energy-balance controller can try different temperatures,
run photosynthesis at each temperature, and keep the result that satisfies
its energy-balance equation.

Declare the models to call with `Call` in the controller's `dep` method, or
with `ModelSpec(...; calls=...)` in the scenario. Then use:

| What the controller needs to do | Function |
|---|---|
| Run all models selected by a named call | `run_call!(context, :leaf_energy)` |
| Choose individual models or objects to run | `call_targets(context, :leaf_energy)`, then `run_call!(target)` |
| Read a called model's type or parameters | `call_model(context, :leaf_energy)`; this requires exactly one match |

Here a **target** is one selected model application on one object. If the
controller has already prepared the environmental values for every target,
pass them as `sampled_environment=value` to `run_call!`. Use individual
targets when each object needs different values.

Trial calls use `publish=false`, the default. Their results are not saved as
accepted output samples for time-based connections or output history. Use
`publish=true` for the accepted calculation. This setting does not undo
changes to model state: the controller must handle any changes that should
be discarded after a trial.

A model used only through calls runs when its controller calls it; it does
not also run independently. If a trial calls further models, those nested
calls cannot save accepted samples either. The same rule prevents a nested
controller from committing trial values to the environment.

[Implement A Hard Dependency](@ref) walks through a complete example.
`Diagnostics.explain_calls(model)` lists the selected models and objects;
`Diagnostics.explain_schedule(model)` shows their execution order.

## Explicit adapters

An **adapter** is an ordinary PlantSimEngine model that we use to convert a value
before another model reads it. The word "adapter" is only used to describe its role, but it is not a special type of model.
So to write an adapter, you declare its inputs and outputs, write its calculation in `run!`,
and configure it with `ModelSpec`, just like any other model.

Two variables can have the same name and still mean different things. For
example, radiation per square metre of ground cannot be used directly where
a model expects radiation per plant. Renaming the variable does not convert it.

In this example, `GroundToPlantRadiation` performs the conversion by
multiplying radiation per unit ground area by the ground area assigned to a
plant. Its `run!` method contains this calculation:

```julia
status.par_plant = status.par_ground * model.ground_area
```

The example also declares `VariableContract`s to describe the units and
physical meaning of its inputs and outputs. Any model can provide these
declarations; they are not specific to adapters. PlantSimEngine uses them to
check compatibility between connected variables, not to perform the
conversion. Models can omit contracts, but once either end of a connection
declares one, both ends must declare matching contracts.

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

The adapter reads radiation per ground area and writes radiation per plant.
The models on either side therefore receive the units they expect. You can
inspect and test the area parameter and the conversion equation separately.
For your own adapter, also explain when that conversion is scientifically
appropriate.

Use the same approach to convert a rate to an amount. A constant rate can be
multiplied by its duration. If it varies, add its contributions at each update
or use the correct mean rate over the interval.

Time settings such as `Integrate(reducer)` can calculate an integral, but
they do not change the variable's declared units or meaning. To connect a
declared rate to a model expecting an amount, perform that calculation in an
adapter and declare the rate as its input and the amount as its output.
