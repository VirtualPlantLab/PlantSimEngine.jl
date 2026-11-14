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
    index = @inferred PlantSimEngine._selector_candidate_index(model, nothing)
    @test isnothing(index.application_target_templates)
    cache = PlantSimEngine._application_target_template_cache(keytype(model.registry.objects))
    cached = @inferred PlantSimEngine._selector_candidate_index(model, cache)
    @test cached.application_target_templates === cache
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
        empty_index = PlantSimEngine._selector_candidate_index(model, nothing)
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
        empty_scope_index = PlantSimEngine._selector_candidate_index(model, nothing)
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

# Close only the actual existing fixture families. No future family is invented.
function _closed_selector_candidate_fixture(model)
    previous = model.registry
    registry = PlantSimEngine.ObjectRegistry(
        PlantSimEngine._closed_object_family_store(previous.objects),
        previous.by_scale, previous.by_kind, previous.by_species,
        previous.ancestor_ids_by_object)
    fields = map(fieldnames(typeof(model))) do name
        name === :registry && return registry
        name in (:scenario_plan_cache, :binding_cache, :environment_binding_cache) && return nothing
        name in (:bindings_dirty, :environment_bindings_dirty) && return true
        getfield(model, name)
    end
    return CompositeModel(fields...)
end

@testset "Typed selector buckets preserve numeric and mixed identities" begin
    for ids in ((10, 11, 12, 13), (0, :plant, "axis", 17)), closed in (false, true)
        scene_id, plant_id, axis_id, leaf_id = ids
        for (kind, species) in ((:photosynthetic, :rauh), (nothing, nothing))
            model = CompositeModel(
                Object(scene_id; scale=:Scene),
                Object(plant_id; scale=:Plant, parent=scene_id),
                Object(axis_id; scale=:Axis, parent=plant_id),
                Object(leaf_id; scale=:Leaf, kind, species, parent=axis_id),
            )
            closed && (model = _closed_selector_candidate_fixture(model))
            @test (model.registry.objects.catalog isa PlantSimEngine.ClosedObjectFamilyCatalog) === closed
            I = keytype(model.registry.objects)
            index = PlantSimEngine._selector_candidate_index(model, nothing)
            frozen_empty = PlantSimEngine._freeze_selector_candidate_index(index)
            @test keytype(index.by_id) === keytype(frozen_empty.by_id) === I
            @test keytype(index.by_scope_anchor) === keytype(frozen_empty.by_scope_anchor) ===
                Union{I,Tuple{I,Symbol,Union{Symbol,I}}}
            @test eltype(index.scope_roots) === eltype(frozen_empty.scope_roots) === I
            @test isempty(frozen_empty.by_id) && isempty(frozen_empty.by_scope_anchor)
            selectors = (
                Many(id=leaf_id),
                Many(scale=(:Leaf, :Fruit)),
                Many(kind=:photosynthetic),
                Many(species=:rauh),
                Many(scale=:Leaf, within=Subtree()),
                Many(within=Subtree()),
                Many(id=scene_id),
            )
            for (position, selector) in pairs(selectors)
                matcher = PlantSimEngine._compile_selector_matcher(model, selector)
                PlantSimEngine._index_selector_candidate!(
                    index, model, matcher, position, ObjectId(plant_id), nothing,
                )
            end
            expected = Set([1, 2, 5, 6])
            isnothing(kind) || push!(expected, 3)
            isnothing(species) || push!(expected, 4)
            for candidate_index in (index, PlantSimEngine._freeze_selector_candidate_index(index))
                candidates = Set([99])
                @test PlantSimEngine._union_selector_candidates!(
                    candidates, candidate_index, model, ObjectId(leaf_id),
                ) === candidates
                @test candidates == union(expected, Set([99]))
            end

            # Both reverse indexes exist BEFORE the selected future object.
            # Open accepts every identity family; Closed keeps its actual union.
            for raw_future in (leaf_id + 1000, :future_leaf, 1.5)
                future_id = ObjectId(raw_future)
                @test !haskey(model.registry.objects, future_id)
                future_index = PlantSimEngine._selector_candidate_index(model, nothing)
                for (slot, selector) in pairs((Many(id=raw_future),
                    Many(id=raw_future, within=Subtree())))
                    matcher = PlantSimEngine._compile_selector_matcher(model, selector)
                    @test PlantSimEngine._index_selector_candidate!(future_index, model,
                        matcher, slot, ObjectId(plant_id), nothing) === future_index
                end
                frozen_future = PlantSimEngine._freeze_selector_candidate_index(future_index)
                for candidate_index in (future_index, frozen_future)
                    @test isempty(PlantSimEngine._union_selector_candidates!(Set{Int}(),
                        candidate_index, model, ObjectId(leaf_id)))
                end
                if future_id isa I
                    @test haskey(future_index.by_id, future_id)
                    @test haskey(future_index.by_scope_anchor,
                        (ObjectId(plant_id), :id, future_id))
                    register_object!(model, Object(raw_future; scale=:Leaf,
                        parent=axis_id, kind, species))
                    for candidate_index in (future_index, frozen_future)
                        candidates = Set{Int}()
                        @test PlantSimEngine._union_selector_candidates!(candidates,
                            candidate_index, model, future_id) === candidates
                        @test candidates == Set([1, 2])
                    end
                else
                    # This type can never be registered in the closed store.
                    # Its otherwise valid selector must stay an empty match.
                    @test closed
                    @test isempty(future_index.by_id)
                    @test isempty(future_index.by_scope_anchor)
                    @test isempty(future_index.wildcard)
                    for candidate_index in (future_index, frozen_future)
                        @test isempty(PlantSimEngine._union_selector_candidates!(Set{Int}(),
                            candidate_index, model, ObjectId(leaf_id)))
                    end
                end
            end
        end
    end
end
