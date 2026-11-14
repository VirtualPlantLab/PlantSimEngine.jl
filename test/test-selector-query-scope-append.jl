module SelectorQueryScopeAppendChecks

using PlantSimEngine, PlantSimEngine.Diagnostics, Test
const PSE = PlantSimEngine
PSE.@process "query_scope_append_aggregate" verbose=false
struct ScopeAggregate <: AbstractQuery_Scope_Append_AggregateModel end
PSE.inputs_(::ScopeAggregate) = (values=Required(AbstractVector),)
PSE.outputs_(::ScopeAggregate) = (total=0f0,)
PSE.run!(::ScopeAggregate, status, environment, constants, context) =
    (status.total = sum(status.values); nothing)

function append_scene(scope; relation=nothing, scale=:Leaf)
    selector = isnothing(relation) ?
        Many(scope; scale, var=:x, from_status=true) :
        Many(Relation(relation), scope; scale, var=:x, from_status=true)
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene, status=Status(x=100f0)),
        Object(:consumer; scale=:Axis, parent=:plant_a),
        Object(1; scale=:Leaf, parent=:consumer, status=Status(x=1f0)),
        Object(2; scale=:Leaf, parent=:consumer, status=Status(x=2f0)),
        Object(:plant_b; scale=:Plant, parent=:scene, status=Status(x=200f0)),
        Object(10; scale=:Leaf, parent=:plant_b, status=Status(x=10f0));
        applications=(ModelSpec(ScopeAggregate(); name=:aggregate, on=One(id=:consumer),
            inputs=(values=selector,)),))
    simulation = run!(model)
    return (; model, simulation, binding=only(simulation.compiled.input_bindings))
end

function add_leaf!(model, id, parent)
    return register_object!(model,
        Object(id; scale=:Leaf, parent, status=Status(x=Float32(id))))
end

@testset "Many growth keeps live refs and a query-local scope across lifecycle changes" begin
    for scope in (Subtree(), SelfPlant(), Ancestor(scale=:Plant))
        data = append_scene(scope)
        model, simulation, binding = data.model, data.simulation, data.binding
        @test model_status(model, :consumer).total === 3f0
        carrier, ids = input_carrier(binding), binding.source_ids
        first_refs = copy(parent(carrier))
        add_leaf!(model, 3, :consumer)
        add_leaf!(model, 4, :plant_a)
        add_leaf!(model, 20, :plant_b)
        continue!(simulation)
        current = only(simulation.compiled.input_bindings)
        expected = scope isa Subtree ? [1, 2, 3] : [1, 2, 3, 4]
        @test current.source_ids == ObjectId.(expected)
        @test current.source_ids === ids
        @test input_carrier(current) === carrier
        @test all(parent(carrier)[index] === first_refs[index] for index in eachindex(first_refs))
        @test all(reference === PSE.refvalue(model_status(model, id), :x)
            for (id, reference) in zip(current.source_ids, parent(carrier)))
        @test model_status(model, :consumer).total === Float32(sum(expected))

        # A later append query must use the new ancestor, never a root retained
        # from the previous addition. Structural refresh still owns removals.
        reparent_object!(model, :consumer, :plant_b)
        continue!(simulation)
        expected = scope isa Subtree ? [1, 2, 3] : [1, 2, 3, 10, 20]
        @test only(simulation.compiled.input_bindings).source_ids == ObjectId.(expected)
        @test model_status(model, :consumer).total === Float32(sum(expected))
        add_leaf!(model, 21, :plant_b)
        continue!(simulation)
        expected = scope isa Subtree ? [1, 2, 3] : [1, 2, 3, 10, 20, 21]
        @test only(simulation.compiled.input_bindings).source_ids == ObjectId.(expected)
        @test model_status(model, :consumer).total === Float32(sum(expected))
        remove_object!(model, 20)
        continue!(simulation)
        expected = scope isa Subtree ? [1, 2, 3] : [1, 2, 3, 10, 21]
        @test only(simulation.compiled.input_bindings).source_ids == ObjectId.(expected)
        @test model_status(model, :consumer).total === Float32(sum(expected))
    end
end

function append_selected!(data, ids)
    compiled = data.simulation.compiled
    return PSE._append_added_many_sources!(data.model, data.binding, ObjectId.(ids),
        PSE._applications_by_object(compiled.applications, data.model.registry.objects), compiled.applications_by_id,
        compiled.distributed_outputs)
end

@testset "Many append preserves label and relation short-circuit error order" begin
    data = append_scene(SelfPlant())
    reparent_object!(data.model, :consumer, :scene) # no current Plant anchor
    register_object!(data.model, Object(30; scale=:Branch, parent=:scene))
    @test append_selected!(data, Int[])
    @test append_selected!(data, [30]) # a rejected label must not resolve scope
    @test data.binding.source_ids == ObjectId.([1, 2])
    add_leaf!(data.model, 31, :scene)
    @test_throws "No `scale=:Plant` ancestor" append_selected!(data, [31])
    @test data.binding.source_ids == ObjectId.([1, 2])

    related = append_scene(SelfPlant(); relation=:descendants)
    reparent_object!(related.model, :consumer, :scene)
    add_leaf!(related.model, 31, :scene)
    @test append_selected!(related, [31]) # rejected relation must not resolve scope
    add_leaf!(related.model, 32, :consumer)
    @test_throws "No `scale=:Plant` ancestor" append_selected!(related, [32])
    @test related.binding.source_ids == ObjectId.([1, 2])
end

@testset "nearest Ancestor append keeps its singular point semantics" begin
    data = append_scene(Ancestor(scale=:Plant); scale=:Plant)
    @test data.binding.source_ids == [ObjectId(:plant_a)]
    @test model_status(data.model, :consumer).total === 100f0
    register_object!(data.model,
        Object(33; scale=:Plant, parent=:consumer, status=Status(x=33f0)))
    @test append_selected!(data, [33])
    @test data.binding.source_ids == [ObjectId(:plant_a)]
    reparent_object!(data.model, :consumer, :scene)
    register_object!(data.model,
        Object(34; scale=:Plant, parent=:scene, status=Status(x=34f0)))
    @test append_selected!(data, [34]) # no ancestor remains a nonmatch, not an anchor error
    @test data.binding.source_ids == [ObjectId(:plant_a)]
end

end
