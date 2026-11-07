module SelectorQueryScopeRootChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

sorted_ids(ids...) = PSE._sort_object_ids!(ObjectId[ObjectId(id) for id in ids])

function scope_scene()
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene),
        Object(:axis_a; scale=:Axis, parent=:plant_a),
        Object(1; scale=:Leaf, kind=:active, parent=:axis_a),
        Object(10; scale=:Leaf, kind=:active, parent=:axis_a),
        Object(Symbol("2"); scale=:Leaf, kind=:dormant, parent=:plant_a),
        Object(:plant_b; scale=:Plant, parent=:scene),
        Object(:axis_b; scale=:Axis, parent=:plant_b),
        Object(20; scale=:Leaf, kind=:active, parent=:axis_b),
        Object(:leaf_b; scale=:Leaf, kind=:dormant, parent=:plant_b),
    )
end

@testset "one query anchor preserves topology scopes, default scopes, and ID order" begin
    model = scope_scene()
    leaves_a = sorted_ids(1, 10, Symbol("2"))
    leaves_b = sorted_ids(20, :leaf_b)
    @test leaves_a == ObjectId[ObjectId(1), ObjectId(10), ObjectId(Symbol("2"))]
    @test resolve_object_ids(model, Many(SelfPlant(); scale=:Leaf); context=1) == leaves_a
    @test resolve_object_ids(model, Many(SelfPlant(); scale=:Leaf); context=20) == leaves_b
    @test resolve_object_ids(model, Many(Subtree(); scale=:Leaf); context=:plant_a) == leaves_a
    @test resolve_object_ids(model, Many(Subtree(); scale=:Leaf); context=:axis_a) == sorted_ids(1, 10)
    @test resolve_object_ids(model, Many(Ancestor(scale=:Plant); scale=:Leaf); context=1) == leaves_a
    @test resolve_object_ids(model, Many(Ancestor(scale=:Axis); scale=:Leaf); context=1) == sorted_ids(1, 10)
    @test resolve_object_ids(model, One(Ancestor(scale=:Plant); scale=:Plant); context=1) ==
          sorted_ids(:plant_a)
    @test resolve_object_ids(model, Many(Scope(ObjectId(:plant_a)); scale=:Leaf)) == leaves_a

    selector = Many(scale=:Leaf)
    matcher = PSE._compile_selector_matcher(model, selector)
    @test isnothing(matcher.scope)
    @test PSE._resolve_object_ids(model, selector, matcher;
        context=ObjectId(1), default_scope=SelfPlant()) == leaves_a
    @test isnothing(matcher.scope)
    @test PSE._resolve_object_ids(model, selector, matcher;
        context=ObjectId(:axis_b), default_scope=Subtree()) == sorted_ids(20)
end

@testset "relation roots and explicit scope remain an intersection" begin
    model = scope_scene()
    @test isempty(resolve_object_ids(model,
        Many(Relation(:descendants), Scope(ObjectId(:plant_b)); scale=:Leaf);
        context=:plant_a))
    @test resolve_object_ids(model,
        Many(Relation(:descendants), Scope(ObjectId(:axis_a)); scale=:Leaf);
        context=:plant_a) == sorted_ids(1, 10)
    @test resolve_object_ids(model,
        Many(Relation(:ancestors), Scope(ObjectId(:plant_a)); scale=(:Plant, :Axis));
        context=1) == sorted_ids(:axis_a, :plant_a)
    @test resolve_object_ids(model,
        Many(Relation(:siblings), SelfPlant(); scale=:Leaf); context=1) == sorted_ids(10)
end

@testset "query anchors stay fresh after reparenting and removal" begin
    model = scope_scene()
    selector = Many(SelfPlant(); scale=:Leaf)
    matcher = PSE._compile_selector_matcher(model, selector)
    query() = PSE._resolve_object_ids(model, selector, matcher; context=ObjectId(1))
    @test query() == sorted_ids(1, 10, Symbol("2"))
    reparent_object!(model, 1, :axis_b)
    @test query() == sorted_ids(1, 20, :leaf_b)
    @test resolve_object_ids(model, Many(Subtree(); scale=:Leaf); context=:plant_a) ==
          sorted_ids(10, Symbol("2"))
    remove_object!(model, 20)
    @test query() == sorted_ids(1, :leaf_b)

    named_selector = Many(Scope(ObjectId(:axis_a)); scale=:Leaf)
    named_matcher = PSE._compile_selector_matcher(model, named_selector)
    remove_object!(model, :axis_a)
    @test isempty(PSE._resolve_object_ids(model, named_selector, named_matcher))
    @test_throws "No instance or object ID" resolve_object_ids(model, named_selector)
end

function query_error(model, selector; kwargs...)
    try
        resolve_object_ids(model, selector; kwargs...)
        return ""
    catch error
        return sprint(showerror, error)
    end
end

@testset "raw authored scopes remain in cardinality and context errors" begin
    model = scope_scene()
    for selector in (One(SelfPlant(); scale=:Leaf),
                     One(Subtree(); scale=:Leaf),
                     One(Ancestor(scale=:Plant); scale=:Leaf),
                     One(Scope(ObjectId(:plant_a)); scale=:Leaf))
        error = query_error(model, selector; context=:axis_a)
        @test occursin("Expected exactly one object", error)
        @test occursin(string(selector), error)
        @test !occursin("CompiledNamedScope", error)
    end
    @test_throws "current object context" resolve_object_ids(model, Many(SelfPlant(); scale=:Leaf))
    @test_throws "current object context" resolve_object_ids(model, Many(Subtree(); scale=:Leaf))
    @test_throws "current object context" resolve_object_ids(model,
        Many(Ancestor(scale=:Plant); scale=:Leaf))
    @test_throws "No matching ancestor" resolve_object_ids(model,
        Many(Ancestor(scale=:Axis); scale=:Leaf); context=:plant_a)
    @test_throws "No `scale=:Plant` ancestor" resolve_object_ids(model,
        Many(SelfPlant(); scale=:Leaf); context=:scene)
    @test_throws "No instance or object ID" resolve_object_ids(model,
        Many(Scope(ObjectId(:missing)); scale=:Leaf))
end

function budget_scene()
    objects = Object[Object(:scene; scale=:Scene)]
    for plant in (:plant_a, :plant_b)
        push!(objects, Object(plant; scale=:Plant, parent=:scene))
        for index in 1:32
            push!(objects, Object(Symbol(plant, :_leaf_, index); scale=:Leaf,
                species=index == 1 ? :rare : :common, parent=plant))
        end
    end
    return CompositeModel(objects...)
end

@testset "one anchor serves complete local walks and borrowed global index buckets" begin
    model = budget_scene()
    leaf_index = PSE._smallest_indexed_candidates(model; scale=:Leaf)
    @test !isnothing(PSE._descendant_ids_up_to(model, ObjectId(:plant_a), leaf_index.estimate))
    rare_index = PSE._smallest_indexed_candidates(model; scale=:Leaf, species=:rare)
    @test isnothing(PSE._descendant_ids_up_to(model, ObjectId(:plant_a), rare_index.estimate))
    @test resolve_object_ids(model, Many(SelfPlant(); scale=:Leaf); context=:plant_a) ==
          sorted_ids((Symbol(:plant_a_leaf_, index) for index in 1:32)...)
    @test resolve_object_ids(model, Many(SelfPlant(); scale=:Leaf, species=:rare); context=:plant_a) ==
          sorted_ids(:plant_a_leaf_1)
end

@testset "Self retains current identity inference, references and errors" begin
    for raw_ids in ((1, 2), (:one, :two), (1, :leaf))
        model = CompositeModel((Object(id; name="same",
            status=Status(value=Float32(index)))
            for (index, id) in enumerate(raw_ids))...)
        order = object_ids(model)
        references = Dict(id => PSE.refvalue(model_status(model, id), :value)
            for id in order)
        selector = One(within=Self())
        for id in order
            scoped = PSE._scope_object_ids(model, Self(), id)
            @test (@inferred only(scoped)) === id
            @test resolve_object_ids(model, selector; context=id) == [id]
            @test resolve_object_ids(model, selector; context=model_object(model, id)) == [id]
        end
        @test_throws "current object context" resolve_object_ids(model, selector)
        for missing in (ObjectId(999), ObjectId(:missing), ObjectId(1.25))
            @test_throws "No model object with id" resolve_object_ids(model, selector;
                context=missing)
        end
        @test object_ids(model) == order
        @test all(PSE.refvalue(model_status(model, id), :value) === reference
            for (id, reference) in references)
    end
end

end
