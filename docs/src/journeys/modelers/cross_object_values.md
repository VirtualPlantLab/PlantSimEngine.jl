# Implement Cross-Object Values

**New concept:** scalar and vector-like inputs use the same one-step kernel
contract. Object selection and topology remain scenario concerns.

See [Build One Multiscale Plant](@ref) for the simulation-user construction
journey.

The plain Julia block below is an excerpt from a shipped example whose
declarations and compositions are tested in `test/test-toy_models.jl`.

## Model 4: consume one scalar from another object

`ToyDevelopmentModel` already declares `stress=Default(1.0)`. A scenario may
replace that fallback with one live scalar from a soil object:

```@example modeler_cross_object
using Dates, PlantMeteo, PlantSimEngine, DataFrames
using PlantSimEngine.Examples

cross_object = CompositeModel(
    Object(:soil; scale=:Soil, status=Status(stress=0.4)),
    Object(:leaf; scale=:Leaf, status=Status(TT=10.0));
    applications=(
        ModelSpec(
            ToyDevelopmentModel(0.5);
            name=:development,
            on=One(scale=:Leaf),
            inputs=(
                :stress => One(
                    scale=:Soil,
                    within=SceneScope(),
                    var=:stress,
                    from_status=true,
                ),
            ),
        ),
    ),
)

cross_simulation = run!(cross_object)
(
    leaf=final_state(cross_simulation, :leaf),
    binding=only(Diagnostics.explain_bindings(cross_object)),
)
```

The model kernel still reads only `status.stress`. It does not search for soil,
know object ids, or copy the scalar each step. The scenario's `One` selector
resolves a shared `Ref`.

## Model 5: consume a vector-like multiscale value

`ToyMaintenanceRespirationModel` runs once per leaf and publishes `Rm`.
`ToyPlantRmModel` declares one vector-like input and reduces it:

```julia
PlantSimEngine.inputs_(::ToyPlantRmModel) = (
    Rm_organs=Required(AbstractVector{<:Real}),
)
PlantSimEngine.outputs_(::ToyPlantRmModel) = (Rm=-Inf,)

function PlantSimEngine.run!(
    model::ToyPlantRmModel,
    status,
    environment,
    constants,
    context,
)
    status.Rm = sum(status.Rm_organs)
    return nothing
end
```

The scenario decides that `Rm_organs` means all descendant leaf outputs:

```@example modeler_cross_object
respiration = ToyMaintenanceRespirationModel(
    2.0,
    0.06,
    25.0,
    0.5,
    0.02,
)

multiscale = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(
        :leaf_1;
        scale=:Leaf,
        parent=:plant,
        status=Status(carbon_biomass=10.0),
    ),
    Object(
        :leaf_2;
        scale=:Leaf,
        parent=:plant,
        status=Status(carbon_biomass=20.0),
    );
    applications=(
        ModelSpec(
            respiration;
            name=:maintenance,
            on=Many(scale=:Leaf),
        ),
        ModelSpec(
            ToyPlantRmModel();
            name=:plant_maintenance,
            on=One(scale=:Plant),
            inputs=(
                :Rm_organs => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:maintenance,
                    var=:Rm,
                ),
            ),
        ),
    ),
    environment=Atmosphere(
        T=25.0,
        Wind=1.0,
        Rh=0.7,
        duration=Hour(1),
    ),
)

multiscale_simulation = run!(multiscale)
(
    plant=final_state(multiscale_simulation, :plant),
    leaves=final_state(multiscale_simulation, Many(scale=:Leaf)),
)
```

```@example modeler_cross_object
select(
    DataFrame(Diagnostics.explain_bindings(multiscale)),
    :application_id,
    :input,
    :source_ids,
    :carrier_kind,
    :copy_semantics,
)
```

The `Many` carrier is a live `RefVector`; the aggregation kernel operates on an
`AbstractVector` and stays independent of object count and identity.

## Model-author recap

- **You implemented:** scalar or vector-compatible input schemas and ordinary
  one-step arithmetic.
- **PlantSimEngine inferred:** shared `Ref` and `RefVector` carriers plus
  producer-before-consumer order.
- **The scenario author keeps explicit:** cross-object scope, multiplicity,
  source application, and variable remapping.
- **New API names:** `One`, `Many`, `SceneScope`, `Subtree`, `from_status`,
  `RefVector`, and `input_carrier`.
