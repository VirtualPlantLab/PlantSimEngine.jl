module IndexedAncestorChecks

using Test, PlantSimEngine
using PlantSimEngine.GraphEditor
const PSE = PlantSimEngine

nearest_ancestor(model, id; kwargs...) = PSE._ancestor_id(model, ObjectId(id); kwargs...)
function ancestor_scene()
    CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(1; scale=:Plant, kind=:plant, parent=:scene),
        Object(:middle; scale=:Plant, kind=:dormant, parent=1),
        Object(:axis; scale=:Axis, kind=:plant, parent=:middle),
        Object(:leaf; scale=:Leaf, kind=:photosynthetic, parent=:axis),
        Object(2; scale=:Plant, kind=:plant, parent=:scene),
    )
end

@testset "nearest indexed ancestor and lifecycle contracts" begin
    model=ancestor_scene()
    @test nearest_ancestor(model,:leaf;scale=:Plant)==ObjectId(:middle)
    @test nearest_ancestor(model,:leaf;kind=:plant)==ObjectId(:axis)
    @test nearest_ancestor(model,:leaf;scale=:Plant,kind=:plant)==ObjectId(1)
    @test nearest_ancestor(model,:leaf;scale=:Leaf)==ObjectId(:leaf)
    @test isnothing(nearest_ancestor(model,:leaf;scale=:Leaf,include_self=false))
    @test nearest_ancestor(model,:leaf;include_self=false)==ObjectId(:axis)
    @test nearest_ancestor(model,:leaf)==ObjectId(:leaf)
    @test isnothing(nearest_ancestor(model,:scene;include_self=false))
    @test isnothing(nearest_ancestor(model,:leaf;scale=:Absent))
    @test isnothing(nearest_ancestor(model,:leaf;scale=:Plant,kind=:Absent))

    relabeled=apply_model_graph_edit(model,
        SetModelObjectMetadata(:middle;scale=:Axis,kind=:plant))
    @test ObjectId(:middle) ∉ relabeled.registry.by_scale[:Plant]
    @test ObjectId(:middle) ∈ relabeled.registry.by_scale[:Axis]
    @test ObjectId(:middle) ∈ relabeled.registry.by_kind[:plant]
    @test nearest_ancestor(relabeled,:leaf;scale=:Plant)==ObjectId(1)
    @test nearest_ancestor(model,:leaf;scale=:Plant)==ObjectId(:middle)
    relabeled=apply_model_graph_edit(relabeled,
        SetModelObjectMetadata(:axis;kind=:dormant))
    @test nearest_ancestor(relabeled,:leaf;scale=:Axis,kind=:plant)==ObjectId(:middle)

    register_object!(model,Object(:new_leaf;scale=:Leaf,kind=:photosynthetic,parent=:axis))
    @test nearest_ancestor(model,:new_leaf;scale=:Plant,kind=:plant)==ObjectId(1)
    reparent_object!(model,:axis,2)
    @test nearest_ancestor(model,:leaf;scale=:Plant)==ObjectId(2)
    @test nearest_ancestor(model,:new_leaf;scale=:Plant)==ObjectId(2)
    remove_object!(model,:axis)
    @test !haskey(model.registry.by_scale, :Axis)
    @test !haskey(model.registry.by_scale, :Leaf)
    @test_throws ErrorException nearest_ancestor(model,:leaf;scale=:Plant)
end

@testset "indexed ancestry retains inconsistent-cache validation order" begin
    model=ancestor_scene()
    path=model.registry.ancestor_ids_by_object[ObjectId(:leaf)]
    path[end-1]=ObjectId(:dangling)
    # Missing labels return before examining the corrupted ancestor, exactly
    # as the prior implementation did. The label-free branch also stays intact.
    @test isnothing(nearest_ancestor(model,:leaf;scale=:Absent))
    @test isnothing(nearest_ancestor(model,:leaf;scale=:Plant,kind=:Absent))
    @test nearest_ancestor(model,:leaf;include_self=false)==ObjectId(:dangling)
    failure=try
        nearest_ancestor(model,:leaf;scale=:Plant)
        nothing
    catch error
        error
    end
    @test failure isa ErrorException
    @test sprint(showerror,failure)=="No model object with id `dangling`."
end

end
