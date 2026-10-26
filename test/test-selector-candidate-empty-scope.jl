using PlantSimEngine
using Test

@testset "Selector candidates with and without scoped entries" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:axis; scale=:Axis, parent=:plant),
        Object(
            :leaf;
            scale=:Leaf,
            kind=:photosynthetic,
            species=:rauh,
            parent=:axis,
        ),
        Object(:other_plant; scale=:Plant, parent=:scene),
        Object(:other_leaf; scale=:Leaf, parent=:other_plant),
    )
    leaf_id = ObjectId(:leaf)
    index = PlantSimEngine._selector_candidate_index()
    push!(index.wildcard, 1)
    index.by_id[leaf_id] = [2]
    index.by_scale[:Leaf] = [3]
    index.by_kind[:photosynthetic] = [4]
    index.by_species[:rauh] = [5]
    index.by_id[ObjectId(:other_leaf)] = [90]
    index.by_scale[:Fruit] = [91]
    index.by_kind[:wood] = [92]
    index.by_species[:merisier] = [93]

    @testset "Empty scopes retain every global criterion" begin
        @test isempty(index.by_scope_anchor)
        for candidate_index in (index, PlantSimEngine._freeze_selector_candidate_index(index))
            candidates = Set([2, 99])
            result = PlantSimEngine._union_selector_candidates!(
                candidates, candidate_index, model, leaf_id,
            )
            @test result === candidates
            @test candidates == Set([1, 2, 3, 4, 5, 99])
        end
        empty_index = PlantSimEngine._selector_candidate_index()
        candidates = Set([99])
        @test PlantSimEngine._union_selector_candidates!(
            candidates, empty_index, model, leaf_id,
        ) === candidates
        @test candidates == Set([99])
    end

    @testset "Scoped candidates include the ancestor chain and self" begin
        index.by_scope_anchor[ObjectId(:scene)] = [6]
        index.by_scope_anchor[ObjectId(:plant)] = [7]
        index.by_scope_anchor[ObjectId(:axis)] = [8]
        index.by_scope_anchor[leaf_id] = [9]
        index.by_scope_anchor[(ObjectId(:plant), :scale, :Leaf)] = [10]
        index.by_scope_anchor[(ObjectId(:axis), :kind, :photosynthetic)] = [11]
        index.by_scope_anchor[(ObjectId(:scene), :species, :rauh)] = [12]
        index.by_scope_anchor[(leaf_id, :id, leaf_id)] = [13]
        # Another plant and nonmatching labels cannot contribute candidates.
        index.by_scope_anchor[ObjectId(:other_plant)] = [94]
        index.by_scope_anchor[(ObjectId(:plant), :scale, :Fruit)] = [95]
        index.by_scope_anchor[(ObjectId(:axis), :kind, :wood)] = [96]
        index.by_scope_anchor[(ObjectId(:scene), :species, :merisier)] = [97]
        index.by_scope_anchor[(ObjectId(:plant), :id, ObjectId(:other_leaf))] = [98]
        for candidate_index in (index, PlantSimEngine._freeze_selector_candidate_index(index))
            candidates = Set([99])
            result = PlantSimEngine._union_selector_candidates!(
                candidates, candidate_index, model, leaf_id,
            )
            @test result === candidates
            @test candidates == Set([1:13; 99])
        end
    end

    @testset "Missing IDs are rejected before any label or scope lookup" begin
        empty_scope_index = PlantSimEngine._selector_candidate_index()
        push!(empty_scope_index.wildcard, 1)
        for candidate_index in (
            empty_scope_index,
            PlantSimEngine._freeze_selector_candidate_index(empty_scope_index),
            index,
            PlantSimEngine._freeze_selector_candidate_index(index),
        )
            candidates = Set([99])
            @test_throws ErrorException PlantSimEngine._union_selector_candidates!(
                candidates, candidate_index, model, ObjectId(:missing),
            )
            @test_throws "No model object with id `missing`." PlantSimEngine._union_selector_candidates!(
                candidates, candidate_index, model, ObjectId(:missing),
            )
            @test candidates == Set([1, 99])
        end
    end
end
