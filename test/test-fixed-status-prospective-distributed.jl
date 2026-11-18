module FixedStatusProspectiveDistributedChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "fixed_status_future_distributed" verbose=false

struct Source{T} <: AbstractFixed_Status_Future_DistributedModel
    value::T
end
PSE.inputs_(::Source) = (;)
PSE.outputs_(source::Source) = (x=Distributed(Default(source.value)),)
function PSE.run!(source::Source, status, environment, constants, context)
    targets = output_targets(context, (:x,))
    for index in eachindex(targets.columns.x)
        targets.columns.x[index] = source.value
    end
    return nothing
end

@testset "provided distributed data is admitted before its declared producer exists" begin
    root = Object(:plant; scale=:Plant)
    model = CompositeModel(root; applications=(
        ModelSpec(Source(7.0); name=:source, on=Many(scale=:Scene),
            outputs_to=(OutputTo(Many(SceneScope(), scale=:Leaf)),)),))
    # No current Scene, destination or observed x-family exists at preparation.
    @test length(model.registry.objects) == 1
    supplied = Status(x=4.0)
    reference = PSE.refvalue(supplied, :x)
    leaf = Object(:leaf; scale=:Leaf, parent=root.id, status=supplied)
    @test register_object!(model, leaf) === leaf
    canonical = model_status(model, leaf.id)
    @test canonical.x === 4.0
    @test PSE.refvalue(canonical, :x) === reference

    scene = Object(:scene; scale=:Scene, parent=root.id)
    @test register_object!(model, scene) === scene
    run!(model; steps=1, outputs=:none)
    @test model_status(model, leaf.id) === canonical
    @test PSE.refvalue(model_status(model, leaf.id), :x) === reference
    @test canonical.x === 7.0
    @test reference[] === 7.0
end

@testset "public metadata edits update registered producer scale candidates" begin
    model = CompositeModel(Object(:plant; scale=:Plant),
        Object(:producer; scale=:Dormant, parent=:plant); applications=(
        ModelSpec(Source(7.0); name=:source, on=Many(scale=:Scene),
            outputs_to=(OutputTo(Many(SceneScope(), scale=:Leaf)),)),))
    edited = PSE.GraphEditor.apply_model_graph_edit(model,
        PSE.GraphEditor.SetModelObjectMetadata(:producer; scale=:Scene, name="Active producer"))
    @test model_object(model, :producer).scale === :Dormant
    @test model_object(edited, :producer).scale === :Scene
    @test model_object(edited, :producer).name == "Active producer"
    @test resolve_object_ids(edited, Many(scale=:Scene)) == [ObjectId(:producer)]
    supplied = Status(x=4.0)
    reference = PSE.refvalue(supplied, :x)
    register_object!(edited, Object(:leaf; scale=:Leaf, parent=:plant, status=supplied))
    run!(edited; steps=1, outputs=:none)
    @test PSE.refvalue(model_status(edited, :leaf), :x) === reference
    @test reference[] === 7.0
end

end
