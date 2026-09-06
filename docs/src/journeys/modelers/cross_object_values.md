# Implement Cross-Object Values

A model reads its inputs from `status`, whether the values came from the
same object, another object, or several objects. The scenario chooses those
sources. This page shows what the model author writes in each case.

The equations and numbers below are teaching examples. For the corresponding
scenario walkthrough, see [Build One Multiscale Plant](@ref).

## Read one value from another object

The development example calculates:

**growth increment = efficiency × thermal time × stress factor**

Here is its actual input declaration and calculation, extracted from
`examples/ToyModelDeveloper.jl`:

```@eval
Main.DocsSources.section(
    "examples/ToyModelDeveloper.jl",
    "PlantSimEngine.inputs_(::ToyDevelopmentModel)",
    "\"\"\"\n    ToyDailyDevelopmentModel",
)
```

`stress=Default(1.0)` means the model can run without stress reduction when
that is appropriate. A scenario can instead supply a soil object's value:

```@example modeler_cross_object
using Dates, Test, PlantSimEngine
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
                stress=One(
                    scale=:Soil, within=SceneScope(),
                    var=:stress, from_status=true,
                ),
            ),
        ),
    ),
)

simulation = run!(cross_object)
growth = final_state(simulation, :leaf).growth
@test growth == 2.0
growth
```

`from_status=true` reads the explicitly supplied soil state. When a soil model
produces that value, select its application as described in
[Coupling models](@ref). The development equation itself stays unchanged.

## Read several values and combine them

Suppose leaf respiration amounts are available for the same interval. A
plant-level model can add them:

**plant respiration = sum of leaf respiration**

The model asks for a vector of real values and sums it. It does not need to
know how many leaves exist:

```@eval
Main.DocsSources.section(
    "examples/ToyMaintenanceRespirationModel.jl",
    "struct ToyPlantRmModel",
)
```

Test the equation with an ordinary vector first:

```@example modeler_cross_object
plant_respiration = ToyPlantRmModel()
sample = Status(Rm_organs=[0.2, 0.3], Rm=0.0)
PlantSimEngine.run!(plant_respiration, sample, nothing, nothing, nothing)
@test sample.Rm == 0.5
sample.Rm
```

## Choose which leaves contribute

This scenario supplies two illustrative leaf amounts, then selects only the
leaves belonging to the plant:

```@example modeler_cross_object
plant = CompositeModel(
    Object(:plant; scale=:Plant),
    Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(Rm=0.2)),
    Object(:leaf_2; scale=:Leaf, parent=:plant, status=Status(Rm=0.3));
    applications=(
        ModelSpec(
            plant_respiration;
            name=:plant_respiration,
            on=One(scale=:Plant),
            inputs=(
                Rm_organs=Many(
                    scale=:Leaf, within=Subtree(),
                    var=:Rm, from_status=true,
                ),
            ),
        ),
    ),
    environment=(duration=Day(1),),
)
plant_result = final_state(run!(plant), :plant).Rm
@test plant_result == 0.5
plant_result
```

`Many` provides the selected values in a vector-like input. `Subtree()`
restricts the search to this plant's descendants. This avoids accidentally
adding another plant's leaves.

For a real process chain, the producer and consumer must use compatible
units, physical bases, and time intervals. An average per unit leaf area
cannot become a plant total by an unweighted sum; supply the necessary areas
and write that conversion explicitly.

Use `Diagnostics.explain_bindings(plant)` to inspect the selected sources.
The implementation uses live references, so the aggregation equation can
remain independent of object identity and count.
