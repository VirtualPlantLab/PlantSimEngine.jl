using PlantSimEngine
using Test

PlantSimEngine.@process "lineage_source" verbose = false
PlantSimEngine.@process "lineage_consumer" verbose = false
PlantSimEngine.@process "lineage_sum" verbose = false

struct LineageSourceModel{T} <: AbstractLineage_SourceModel
    value::T
end
struct LineageConsumerModel <: AbstractLineage_ConsumerModel end
struct LineageSumModel <: AbstractLineage_SumModel end
PlantSimEngine.inputs_(::LineageSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::LineageSourceModel) = (signal=0.0,)
function PlantSimEngine.run!(model::LineageSourceModel, status, environment, constants, context)
    status.signal = model.value
end
PlantSimEngine.inputs_(::LineageConsumerModel) = (signal=Required(Float64),)
PlantSimEngine.outputs_(::LineageConsumerModel) = (observed=0.0,)
function PlantSimEngine.run!(::LineageConsumerModel, status, environment, constants, context)
    status.observed = status.signal
end
PlantSimEngine.inputs_(::LineageSumModel) = (signals=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::LineageSumModel) = (total=0.0,)
function PlantSimEngine.run!(::LineageSumModel, status, environment, constants, context)
    status.total = sum(status.signals)
end

@testset "producer lineage, scope, and ambiguity" begin
    same_object = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source, on=One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source, on=One(scale=:Soil)),
            ModelSpec(LineageSourceModel(3.0); name=:leaf_source, on=One(scale=:Leaf)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer, on=One(scale=:Leaf)),
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
    @test only(model_objects(same_object; scale=:Leaf)).status.observed == 3.0

    ambiguous = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source, on=One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source, on=One(scale=:Soil)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer, on=One(scale=:Leaf), inputs=(:signal => One(
                    within=SceneScope(),
                    process=:lineage_source,
                    var=:signal,
                ))),
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

    explicit = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(
            ModelSpec(LineageSourceModel(1.0); name=:plant_source, on=One(scale=:Plant)),
            ModelSpec(LineageSourceModel(2.0); name=:soil_source, on=One(scale=:Soil)),
            ModelSpec(LineageConsumerModel(); name=:leaf_consumer, on=One(scale=:Leaf), inputs=(:signal => One(
                    scale=:Plant,
                    within=Ancestor(scale=:Plant),
                    application=:plant_source,
                    var=:signal,
                ))),
        ),
    )
    explicit_binding = only(explain_bindings(Advanced.refresh_bindings!(explicit)))
    @test explicit_binding.source_ids == [:plant]
    run!(explicit)
    @test only(model_objects(explicit; scale=:Leaf)).status.observed == 1.0
end

@testset "explicit current Status bindings" begin
    scalar = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(signal=4.0));
        applications=(
            ModelSpec(LineageConsumerModel(); name=:status_consumer, on=One(scale=:Leaf), inputs=(:signal => One(
                        within=Self(),
                        var=:signal,
                        from_status=true,
                        after=:later_source,
                    ),)),
            ModelSpec(LineageSourceModel(10.0); name=:later_source, on=One(scale=:Leaf)),
        ),
    )
    scalar_compiled = Advanced.refresh_bindings!(scalar)
    scalar_binding = only(explain_bindings(scalar_compiled))
    @test isempty(scalar_binding.source_application_ids)
    @test scalar_binding.order_after_application_ids == [:later_source]
    @test scalar_binding.carrier_kind == :ref
    @test getproperty.(explain_schedule(scalar_compiled), :application_id) ==
          [:later_source, :status_consumer]
    run!(scalar)
    scalar_status = only(model_objects(scalar; scale=:Leaf)).status
    @test scalar_status.observed == 10.0
    @test scalar_status.signal == 10.0

    dynamic_many = CompositeModel(
        Object(:plant; scale=:Plant, status=Status(total=0.0)),
        Object(:leaf_1; scale=:Leaf, parent=:plant, status=Status(signal=1.0));
        applications=(
            ModelSpec(LineageSumModel(); name=:status_sum, on=One(scale=:Plant), inputs=(:signals => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        var=:signal,
                        from_status=true,
                    ),)),
            ModelSpec(LineageSourceModel(5.0); name=:later_sources, on=Many(scale=:Leaf)),
        ),
    )
    simulation = run!(dynamic_many; outputs=:none)
    @test only(model_objects(dynamic_many; scale=:Plant)).status.total == 1.0
    register_object!(
        dynamic_many,
        Object(:leaf_2; scale=:Leaf, status=Status(signal=2.0));
        parent=:plant,
    )
    continue!(simulation)
    @test only(model_objects(dynamic_many; scale=:Plant)).status.total == 7.0

    invalid = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(signal=1.0));
        applications=(
            ModelSpec(LineageConsumerModel(); name=:invalid_status_consumer, on=One(scale=:Leaf), inputs=(:signal => One(
                        within=Self(),
                        var=:signal,
                        application=:missing,
                        from_status=true,
                    ),)),
        ),
    )
    @test_throws "`from_status=true` cannot be combined with `application=`" Advanced.refresh_bindings!(
        invalid,
    )
end
