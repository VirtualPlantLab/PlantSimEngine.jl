# Numerical Reliability

A small difference in a computed result can come from rounding. For example,
adding the same floating-point values in a different order can change the
last few digits. This can happen when you split a calculation across objects.
Use `isapprox` with a chosen tolerance to compare such results. Use exact
equality when the calculation is meant to be exact, such as an integer count.

PlantSimEngine lets models use different numeric types for parameters, stored
values, weather data, and results. Avoid converting values to `Float64` unless
your calculation requires that precision. For sums that are sensitive to
rounding, consider pairwise summation (adding smaller groups first) or
compensated summation (tracking rounding losses). Implement the chosen method
in the scientific model and test its error against an appropriate tolerance.

## Choose numeric types for stored values

You can choose the numeric types used to store object values when you create
a [`CompositeModel`](@ref). For example, `Float32` uses less memory than
`Float64`, with less precision. A `type_promotion` rule converts all matching
status values:

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

Here `biomass` and each value in `cohort_masses` become `Float32`.
`cohort_count` remains an integer. Arrays keep their shape. PlantSimEngine
converts the elements of ordinary numeric arrays, but it does not look inside
every user-defined struct or custom container. To convert one of those, add a
rule for the whole container type or use `status_transform`, shown below.

Use `AbstractFloat => Float32` to convert all floating-point status values,
including types other than `Float64`. A broader `Real => Float32` rule also
converts integer counts, so use it only if that is intended. A rule for an
exact type takes priority over a rule for a broader type. If two rules match
and neither is more specific, PlantSimEngine rejects them when you create
the model. Their order in the dictionary does not decide which one wins.

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

`status_transform` receives the variable name and its value, then returns the
value to store. It runs before `type_promotion`, so a value it changes to
`MyNumericType` no longer matches the `Float64` rule above. The function must
handle every status value it receives, including values it should leave alone.
If the function fails, or a conversion with `convert(Target, value)` fails,
model construction stops. The error identifies the variable, its original
type, where its initial value came from, and the object when known.

These settings apply to values stored on objects: supplied initial values,
model input and output defaults, and values on objects added later during
the simulation. Model parameters and environment values keep their types.
Conversion happens when status storage is created or a new object is added;
it is not repeated every time a model runs.

If you supply a `Status`, PlantSimEngine leaves that original object unchanged.
It creates new storage for converted values and reuses existing references
where possible for unchanged values. Each `Object` must have its own `Status`;
sharing one `Status` between objects is rejected. The same conversion rules
apply once to values added later through `register_object!` or `add_organ!`.

`Diagnostics.explain_initialization(model)` shows the type declared by the
model, the type of the supplied value, the type after `status_transform`, and
the final stored type. It also shows which conversion changed each value.

!!! note
    Your model's `run!` function must support the types you choose. Let its
    calculations work with the input types, and avoid forcing intermediate
    values to `Float64` unless the equations require that precision.

## Represent uncertainty in numeric values

Numeric types can also represent uncertainty in weather or model parameters.
For example, `Particles` from MonteCarloMeasurements.jl represents an uncertain
number as a collection of possible values. The equations and the storage for
their results must support this numeric type.

Follow [Propagate Uncertainty Through A Simulation](@ref) for a runnable example
with uncertain radiation and a light-extinction parameter, including plots
of the resulting uncertainty. It also shows how to prepare output storage
with `status_transform`.

## Test the expected tolerance

Changing numeric types can change rounding and the order in which values are
added. Choose a comparison tolerance that makes sense for both the precision
and the scientific calculation. Test exact equality only when the model is
intended to produce an exact result.
