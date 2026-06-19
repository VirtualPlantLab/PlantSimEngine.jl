using PlantSimEngine
using Test

PlantSimEngine.@process "lineage_source" verbose = false
PlantSimEngine.@process "lineage_consumer" verbose = false

struct LineageSourceModel{T} <: AbstractLineage_SourceModel
    value::T
end
struct LineageConsumerModel <: AbstractLineage_ConsumerModel end
PlantSimEngine.inputs_(::LineageSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::LineageSourceModel) = (signal=0.0,)
function PlantSimEngine.run!(model::LineageSourceModel, models, status, meteo, constants, extra)
    status.signal = model.value
end
PlantSimEngine.inputs_(::LineageConsumerModel) = (signal=0.0,)
PlantSimEngine.outputs_(::LineageConsumerModel) = (observed=0.0,)
function PlantSimEngine.run!(::LineageConsumerModel, models, status, meteo, constants, extra)
    status.observed = status.signal
end

@testset "producer lineage, scope, and ambiguity" begin
    same_object = Scene(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source) |>
                AppliesTo(One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source) |>
                AppliesTo(One(scale=:Soil)),
            ModelSpec(LineageSourceModel(3.0); name=:leaf_source) |>
                AppliesTo(One(scale=:Leaf)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer) |>
                AppliesTo(One(scale=:Leaf)),
        ),
    )
    binding = only(
        row for row in explain_bindings(Advanced.refresh_bindings!(same_object))
        if row.application_id == :leaf_consumer
    )
    @test binding.origin == :inferred_same_object
    @test binding.source_ids == [:leaf]
    @test binding.source_application_ids == [:leaf_source]
    run!(same_object)
    @test only(scene_objects(same_object; scale=:Leaf)).status.observed == 3.0

    ambiguous = Scene(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source) |>
                AppliesTo(One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source) |>
                AppliesTo(One(scale=:Soil)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:signal => One(
                    within=SceneScope(),
                    process=:lineage_source,
                    var=:signal,
                )),
        ),
    )
    error = try
        Advanced.refresh_bindings!(ambiguous)
        nothing
    catch exception
        sprint(showerror, exception)
    end
    @test occursin("Expected exactly one object", error)
    @test occursin("plant", error)
    @test occursin("soil", error)

    explicit = Scene(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source) |>
                AppliesTo(One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source) |>
                AppliesTo(One(scale=:Soil)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer) |>
                AppliesTo(One(scale=:Leaf)) |>
                Inputs(:signal => One(
                    scale=:Plant,
                    within=Ancestor(scale=:Plant),
                    application=:plant_source,
                    var=:signal,
                )),
        ),
    )
    explicit_binding = only(explain_bindings(Advanced.refresh_bindings!(explicit)))
    @test explicit_binding.source_ids == [:plant]
    run!(explicit)
    @test only(scene_objects(explicit; scale=:Leaf)).status.observed == 1.0
end
