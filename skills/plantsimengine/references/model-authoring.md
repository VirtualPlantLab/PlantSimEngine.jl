# Authoring a PlantSimEngine model

Read this reference when implementing or wrapping a model. Also read
`scenario-coupling.md` when the task includes a nontrivial scenario, and
`repository-layout.md` when creating files in a model package.

## 1. Decide whether the process already exists

The process is the scientific operation; the concrete model is one hypothesis
or numerical formulation of that operation.

1. Inspect `Authoring.available_processes()` and search the target package and
   its loaded dependencies.
2. Reuse the existing abstract process type when the new implementation
   answers the same biological or physical question.
3. Declare a process only when the meaning is genuinely new:

```julia
PlantSimEngine.@process "maintenance_respiration" verbose=false
```

This defines `AbstractMaintenance_RespirationModel`. Do not redeclare a
dependency package's process merely to avoid importing its abstract type.

Two concrete types may share `process(model)` while exposing different ports.
They are then alternatives of the same scientific process, but not drop-in
replacements. Use `Authoring.compare_models(a, b)` to establish compatibility.

## 2. Declare the complete model boundary

Keep fixed parameters in an immutable, parametrically typed struct. Keep
timestep-varying state in `Status`.

```julia
struct MyModel{T} <: AbstractMaintenance_RespirationModel
    reference_rate::T
    q10::T
    reference_temperature::T
end

PlantSimEngine.inputs_(::MyModel) = (
    living_biomass=Required(Real),
)

PlantSimEngine.outputs_(model::MyModel) = (
    respiration=zero(model.reference_rate),
)

PlantSimEngine.environment_inputs_(model::MyModel) = (
    T=zero(model.reference_rate),
)

PlantSimEngine.environment_outputs_(::MyModel) = NamedTuple()
```

When parameter documentation is known, expose it as optional structured
metadata rather than relying on field-name guesses:

```julia
PlantSimEngine.Authoring.parameter_metadata(::MyModel) = (
    reference_rate=(
        description="Rate at the declared reference temperature.",
        unit=:g_carbon_per_g_living_biomass_per_day,
        domain=(minimum=0,),
    ),
)
```

Keys must be real model fields. Omit unknown defaults, bounds, units, or
references; `Authoring.describe_model(instance)` reports this metadata but
never invents it.

Also declare model-level scientific provenance when it is known:

```julia
PlantSimEngine.Authoring.model_metadata(::MyModel) = (
    hypothesis="Q10 response around a declared reference temperature.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
```

`reference=nothing` is preferable to a fabricated citation. Public tutorial
alternatives must say explicitly that they are pedagogical and non-calibrated;
structural tests do not constitute scientific validation.

Rules:

- `inputs_` contains only `Required(T)` and scientifically meaningful
  `Default(value)` declarations.
- `Required(T)` is a type requirement, not an initial value.
- `outputs_` provides actual initial values. Derive them from parameters when
  that preserves the intended numeric type.
- Environment schemas provide model-facing initial/default values. Read those
  variables from `environment`, not from `status`.
- Use `NamedTuple()` for an empty schema.
- Do not store mutable simulation state in the model object.

## 3. Declare scientific contracts beside the ports

Use `VariableContract` for unit and meaning, not only a prose comment:

```julia
const RESPIRATION_CONTRACT = VariableContract(
    unit=:g_carbon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)
const LIVING_BIOMASS_CONTRACT = VariableContract(
    unit=:g_dry_matter,
    basis=:plant,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:extensive,
)
const AIR_TEMPERATURE_CONTRACT = VariableContract(
    unit=:degree_celsius,
    basis=:air,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

PlantSimEngine.variable_contracts_(::MyModel) = (
    living_biomass=LIVING_BIOMASS_CONTRACT,
    respiration=RESPIRATION_CONTRACT,
    T=AIR_TEMPERATURE_CONTRACT,
)
```

The available fields are `unit`, `basis`, `temporal`, `aggregation`, and
`extent`. Values are symbols. Declare the complete contract known by the
model; do not use a partial contract as a wildcard. Once one side of a
connection declares a contract, the other side must declare the same complete
contract.

Do not invent a unit or basis to make compilation pass. If the producer and
consumer meanings differ, create a named adapter with one input contract and
one output contract. See `../assets/adapter-model.jl`.

## 4. Add dependencies only when they belong to the model

Use `dep` for model-author defaults that remain valid across scenarios:

```julia
PlantSimEngine.dep(::CanopyTotal) = (
    leaf_fluxes=Input(
        Many(scale=:Leaf, within=Subtree(), var=:leaf_flux),
    ),
)

PlantSimEngine.dep(::IterativeController) = (
    leaf_energy=Call(
        Many(scale=:Leaf, within=Subtree(), process=:energy_balance),
    ),
)
```

`Input` declares a value source. `Call` declares a hard dependency that the
parent executes itself with `run_call!`. Scenario-level `ModelSpec(inputs=...,
calls=...)` may override selectors without changing the model kernel.

Add `timespec`, `timestep_hint`, `output_policy`, `environment_hint`, output
routing, or initializer declarations only when they are intrinsic to the
implementation. Do not bake one scenario's scheduling preference into a
generic model.

## 5. Write `run!` as the scientific narrative

The required kernel is:

```julia
function PlantSimEngine.run!(model::MyModel, status, environment, constants, context)
    temperature_factor =
        model.q10 ^ ((environment.T - model.reference_temperature) / 10)
    status.respiration =
        model.reference_rate * status.living_biomass * temperature_factor
    return nothing
end
```

Keep equations in the order a scientist would explain them. Extract a helper
when it is a named equation, independently reusable/testable calculation, or
isolated optimization mechanism. Do not fragment a short kernel into helpers
that only rename individual arithmetic lines.

Within the kernel:

- read fixed parameters from `model`;
- read dynamic inputs and previous state from `status`;
- read sampled forcing from `environment`;
- read physical constants from `constants`;
- use `context` only through public runtime, call, lifecycle, and output APIs;
- assign every instantaneous output on every path, including early exits;
- preserve generic number types and return `nothing`.

For an external model, first classify every value as fixed parameter, dynamic
input/output, environmental forcing, constant, or internal temporary. Split an
external routine into several PlantSimEngine models only when users need to
couple, replace, schedule, or validate those subprocesses independently.

## 6. Test from the kernel outward

Start with a direct call, which isolates the equation from the compiler:

```julia
model = MyModel(0.02f0, 2.0f0, 20.0f0)
status = Status(living_biomass=10.0f0, respiration=0.0f0)
environment = (T=25.0f0,)
PlantSimEngine.run!(model, status, environment, nothing, nothing)
```

Then test, in proportion to the feature:

1. `inputs_`, `outputs_`, environment schemas, contracts, and process identity;
2. direct `run!` values and a generic type such as `Float32`;
3. one-object `CompositeModel` composition;
4. same-object inference and explicit cross-object bindings;
5. contract mismatch and adapter behavior;
6. hard calls, temporal policies, or lifecycle operations introduced by the
   model;
7. a package-level scenario or empirical regression when available.

Use `Authoring.validate_model(model)` before scenario work. Validation proves
the declared model boundary; it does not prove the scientific hypothesis.

## Complete executable examples

Resolve the files from the loaded package root:

```julia
skill_assets = joinpath(
    pkgdir(PlantSimEngine),
    "skills",
    "plantsimengine",
    "assets",
)
include(joinpath(skill_assets, "minimal-model.jl"))
include(joinpath(skill_assets, "alternative-model.jl"))
```

`minimal-model.jl` is the canonical copyable skeleton.
`alternative-model.jl` demonstrates why common process identity and direct
substitutability are separate questions.
