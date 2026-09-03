# Numerical Reliability

Use exact assertions for deliberately exact integer/rational scenarios and
`isapprox` for floating-point scientific results. Splitting a computation
across objects may change reduction order without changing the model.

PlantSimEngine preserves compatible numeric types through parameters, status,
carriers, meteorology, and streams. Avoid forced `Float64` conversion. For long
or ill-conditioned sums, use pairwise or compensated accumulation inside the
scientific model and test its error tolerance explicitly.

## Choose the status representation

A scenario may give its status values a different numeric representation when
it constructs a [`CompositeModel`](@ref). A type mapping is the shortest way to
convert every matching status value:

```@example status_numeric_types
using PlantSimEngine

model = CompositeModel(
    Object(
        :leaf;
        scale=:Leaf,
        status=Status(
            biomass=1.0,
            cohort_masses=[0.25, 0.75],
            cohort_count=2,
        ),
    );
    type_promotion=Dict(Float64 => Float32),
)

status = only(model_objects(model)).status
(
    biomass_type=typeof(status.biomass),
    cohort_type=eltype(status.cohort_masses),
    count_type=typeof(status.cohort_count),
)
```

Here the scalar `Float64` and the elements of the ordinary numeric array become
`Float32`. The integer is unchanged. Array conversion is element by element and
preserves the array shape. PlantSimEngine does not recursively inspect arbitrary
user structs or custom containers; map the complete container type or handle it
explicitly in `status_transform` when that is required.

Use `AbstractFloat => Float32` when all floating-point status values should be
converted, including types other than `Float64`. Avoid a broad
`Real => Float32` rule unless integer counts should also become floating-point
values. An exact source-type rule takes priority over an abstract rule. Rules
whose source types overlap without one being more specific are rejected during
model construction, so the result never depends on `Dict` iteration order.

Use `status_transform` when the choice also depends on the variable name:

```julia
transform_status = (variable, value) ->
    variable === :biomass ? MyNumericType(value) : value

model = CompositeModel(
    objects...;
    applications=applications,
    status_transform=transform_status,
    type_promotion=Dict(Float64 => Float32),
)
```

The transform receives `(variable, value)` and returns the value to store. It
runs before the general type mapping, so a value changed to another type by the
transform no longer matches the `Float64` rule above. It must be callable for
every status value that is materialized. If it throws, or if a mapped value
cannot be converted with `convert(Target, value)`, model construction stops
with the variable, original type, object when known, and initialization origin
in the error message.

This policy applies only to values stored in object statuses: supplied values,
model input and output defaults, and status values of objects registered later
in the simulation. It does not convert model parameters or environment values.
The conversion happens when status storage is materialized or an object is
registered, not inside every model invocation.

For a supplied `Status`, PlantSimEngine creates a new status reference only for
values that actually change. The supplied `Status` itself is not mutated, and
unchanged references are preserved where possible. Each `Object` must still own
its own `Status`; sharing one `Status` between objects is rejected. The stored
policy is also applied once to values introduced later by `register_object!` or
`add_organ!`.

`Diagnostics.explain_initialization(model)` reports the declared, original,
transformed, and effective types, together with whether the precise transform
or the type mapping changed each materialized value.

!!! note
    Model kernels still need to support the effective types. Keep status
    computations generic and avoid constructing intermediate values as
    `Float64` unless that precision is part of the scientific contract.

## Propagate uncertainty with particles

[MonteCarloMeasurements.jl](https://github.com/baggepinnen/MonteCarloMeasurements.jl)
is an optional package and is not a PlantSimEngine dependency. A precise
`status_transform` can initialize selected inputs and outputs as particles,
while the general mapping converts the remaining floating-point status values.
For example:

```julia
using PlantSimEngine
using MonteCarloMeasurements: Particles, pmean, pstd

@process "uncertain_square" verbose = false

struct UncertainSquare <: AbstractUncertain_SquareModel end

PlantSimEngine.inputs_(::UncertainSquare) = (x=Required(Real),)
PlantSimEngine.outputs_(::UncertainSquare) = (y=0.0, ordinary=1.0)

function PlantSimEngine.run!(
    ::UncertainSquare,
    status,
    environment,
    constants,
    context,
)
    status.y = status.x^2
    return nothing
end

function particle_status(variable, value)
    variable === :x && return Particles([value - 0.1, value + 0.1])
    variable === :y && return Particles(fill(value, 2))
    return value
end

model = CompositeModel(
    UncertainSquare();
    status=(x=1.0,),
    status_transform=particle_status,
    type_promotion=Dict(Float64 => Float32),
)

simulation = run!(model; outputs=:all)
uncertain_result = final_state(simulation).y
(mean=pmean(uncertain_result), standard_deviation=pstd(uncertain_result))
```

Both `x` and the initial storage for `y` are particles, so assigning the
particle result preserves its uncertainty. The unrelated `ordinary` status is
still converted to `Float32`. Model parameters would need their own generic
types if they also have to carry uncertainty.

## Test the expected tolerance

Changing the floating-point representation can change rounding and reduction
order. Compare scientific results with an explicit tolerance appropriate for
the chosen representation. Test exact values only when exactness is an intended
part of the model contract.
