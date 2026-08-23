# Coupling Values Across Objects

- `One(...)` requires exactly one source.
- `OptionalOne(...)` accepts zero or one.
- `Many(...)` supplies a stable object-ID ordered carrier.

Use `var=` to rename a source and `application=` to distinguish repeated
processes. Homogeneous many-source values use a `RefVector`; heterogeneous
values use an object-aware reference carrier. Inspect both through
`Diagnostics.input_carrier`, `Diagnostics.input_value`, and `Diagnostics.explain_bindings`, not internal fields.

## Keep identities aligned with values

A model that only reduces or broadcasts over a `Many` input can keep using the
ordinary status field. When a model must associate a value with the object that
owns it, request the identity-aware view from the current `RunContext`:

```julia
function PlantSimEngine.run!(model, status, environment, constants, context)
    irradiance = bound_input(context, :irradiance)

    @inbounds for index in eachindex(irradiance)
        object_id = object_ids(irradiance)[index]
        value = irradiance[index]
        # Use object_id and value as one aligned pair.
    end
    return nothing
end
```

`BoundMany` wraps the same live `RefVector` or heterogeneous carrier already
installed in `status.irradiance`; it does not copy values or identities.
Positions follow compiled `ObjectId` order and have no botanical meaning.
Identity lookup is unambiguous when written as
`irradiance[ObjectId(:leaf_12)]`; integer indexing remains positional.

Obtain the view during each model invocation. Lifecycle refresh keeps the
current view aligned when possible and may replace it after insertion,
removal, or reparenting, so model code must not cache a `BoundMany` across a
lifecycle barrier.
