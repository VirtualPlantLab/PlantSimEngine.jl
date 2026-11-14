module StatusConstructionChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine

@testset "cached layouts preserve order and use the actual reference types" begin
    model = CompositeModel(Object(:object; status=Status()))
    original = Status(keep=1, replace=2.0)
    keep = PSE.refvalue(original, :keep)
    replacement = Ref(3.0f0)
    tail = Ref([4.0])
    edits = PSE._CanonicalStatusRecipe(original)
    @test fieldtype(typeof(edits), :original) === typeof(original)
    @test (@inferred PSE._status_recipe_has_variable(edits, :keep))
    @test isempty(edits.edit_names)
    @test isempty(edits.edit_references)
    @test !PSE._status_recipe_set_reference!(edits, :keep, keep)
    @test PSE._status_recipe_set_reference!(edits, :replace, replacement)
    @test PSE._status_recipe_set_reference!(edits, :tail, tail)
    @test !PSE._status_recipe_set_reference!(edits, :tail, tail)
    constructed = PSE._finish_canonical_status_recipe(identity, model, edits)
    @test propertynames(constructed) == (:keep, :replace, :tail)
    @test PSE.refvalue(constructed, :keep) === keep
    @test PSE.refvalue(constructed, :replace) === replacement
    @test PSE.refvalue(constructed, :tail) === tail
    @test PSE._status_recipe_reference(edits, :keep) === keep
    @test PSE._status_recipe_reference(edits, :replace) === replacement
    @test_throws KeyError PSE._status_recipe_reference(edits, :absent)
    @test PSE._finish_canonical_status_recipe(identity, model, PSE._CanonicalStatusRecipe(original)) === original

    cache = model.registry.objects.layout_cache
    layout = only(values(cache))
    same_shape = PSE._CanonicalStatusRecipe(Status(keep=8, replace=9.0))
    PSE._status_recipe_set_reference!(same_shape, :replace, Ref(big"10.0"))
    PSE._status_recipe_set_reference!(same_shape, :tail, Ref([11.0f0]))
    another = PSE._finish_canonical_status_recipe(identity, model, same_shape)
    @test typeof(another) !== typeof(constructed)
    @test another.replace isa BigFloat
    @test another.tail isa Vector{Float32}
    @test length(cache) == 1
    @test only(values(cache)) === layout
    @test all(isbits, values(cache))
    @test all(key -> key isa Tuple{Tuple{Vararg{Symbol}},Tuple{Vararg{Symbol}}}, keys(cache))

    storage = [12.0]
    external = Ref(storage, 1)
    external_edit = PSE._CanonicalStatusRecipe(Status(keep=1))
    PSE._status_recipe_set_reference!(external_edit, :external, external)
    external_status = PSE._finish_canonical_status_recipe(identity, model, external_edit)
    @test PSE.refvalue(external_status, :external) === external
    storage[1] = 13.0
    @test external_status.external == 13.0

    empty_a = PSE._finish_canonical_status_recipe(identity, model, PSE._CanonicalStatusRecipe(nothing))
    empty_b = PSE._finish_canonical_status_recipe(identity, model, PSE._CanonicalStatusRecipe(nothing))
    @test propertynames(empty_a) == ()
    @test getfield(empty_a, :identity) !== getfield(empty_b, :identity)
    @test all(isbits, values(cache))
    projected = PSE._closed_object_family_store(model.registry.objects)
    @test projected.layout_cache == cache
    @test projected.layout_cache !== cache
    recipes = @inferred PSE._canonical_status_recipe_storage(projected.catalog, keytype(projected))
    Original = typeof(model_status(model, :object))
    @test valtype(typeof(recipes)) === Union{PSE._CanonicalStatusRecipe{Nothing},
        PSE._CanonicalStatusRecipe{Original}}
    @test isempty(recipes)
    order = keytype(projected)[]
    staged = PSE._status_recipe_for_object!(recipes, order, model, ObjectId(:object))
    @test staged.original === model_status(model, :object)
    @test typeof(staged) === PSE._CanonicalStatusRecipe{Original}
    @test PSE._status_recipe_for_object!(recipes, order, model, ObjectId(:object)) === staged
    @test order == [ObjectId(:object)]
    @test isempty(CompositeModel(Object(:other)).registry.objects.layout_cache)
    discarded = PSE.ObjectFamilyStore()
    merge!(discarded.layout_cache, cache)
    empty!(discarded)
    @test isempty(discarded.layout_cache)
    @test !isempty(cache)
end

PSE.@process "status_construction_defaults" verbose=false
struct MutableDefaults{T} <: AbstractStatus_Construction_DefaultsModel
    initial::T
end
PSE.outputs_(model::MutableDefaults) = (items=model.initial[],)
PSE.run!(::MutableDefaults, status, environment, constants, context) = nothing

@testset "ordinary preparation keeps mutable defaults fresh and object-private" begin
    initial = Ref([1.0])
    model = CompositeModel(
        Object(:first; scale=:Leaf), Object(:second; scale=:Leaf);
        applications=(ModelSpec(MutableDefaults(initial); name=:defaults,
            on=Many(scale=:Leaf)),),
        environment=(duration=Hour(1),), type_promotion=Dict(Float64 => Float32))
    simulation = run!(model; steps=0, outputs=:none)
    first = model_status(model, :first).items
    second = model_status(model, :second).items
    @test first == second == Float32[1]
    @test first !== second
    @test first !== initial[]
    @test eltype(first) === Float32
    initial[][1] = 9.0
    register_object!(model, Object(:third; scale=:Leaf))
    continue!(simulation; steps=1)
    third = model_status(model, :third).items
    @test third == Float32[9]
    @test first == second == Float32[1]
    first[1] = 20f0
    @test second == Float32[1]
    @test third == Float32[9]
    @test initial[] == [9.0]
    @test all(isbits, values(model.registry.objects.layout_cache))
end

PSE.@process "status_construction_producer" verbose=false
PSE.@process "status_construction_consumer" verbose=false
struct Producer <: AbstractStatus_Construction_ProducerModel end
struct Consumer <: AbstractStatus_Construction_ConsumerModel end
PSE.outputs_(::Producer) = (value=7.0,)
PSE.inputs_(::Consumer) = (input=Default(0.0),)
PSE.run!(::Producer, status, environment, constants, context) = nothing
PSE.run!(::Consumer, status, environment, constants, context) = nothing

@testset "resolved input aliases still validate their declared defaults" begin
    converted = Pair{Symbol,Any}[]
    transform(variable, value) = begin
        push!(converted, variable => value)
        variable === :input ? value + 1000 : value
    end
    model = CompositeModel(
        Object(:source; status=Status(value=7.0)),
        Object(:reader; status=Status());
        applications=(
            ModelSpec(Producer(); name=:producer, on=One(id=:source)),
            ModelSpec(Consumer(); name=:consumer, on=One(id=:reader),
                inputs=(input=One(SceneScope(); id=:source, application=:producer, var=:value),)),
        ), environment=(duration=Hour(1),), status_transform=transform)
    empty!(converted)
    run!(model; steps=0, outputs=:none)
    @test converted == [:input => 0.0]
    @test model_status(model, :reader).input == 7.0
    @test PSE.refvalue(model_status(model, :reader), :input) ===
          PSE.refvalue(model_status(model, :source), :value)
    @test haskey(model.status_conversion_records,
        (:model_input_default, :consumer, ObjectId(:reader), :input))
end

PSE.@process "status_construction_transaction" verbose=false
struct TransactionDefault{T} <: AbstractStatus_Construction_TransactionModel
    initial::T
end
PSE.outputs_(model::TransactionDefault) = (pending=model.initial,)
PSE.run!(::TransactionDefault, status, environment, constants, context) = nothing

@testset "conversion failure leaves every staged object unchanged" begin
    converted = Float64[]
    transform(variable, value) = begin
        if variable === :pending
            push!(converted, value)
            value == 2.0 && error("intentional later-object conversion failure")
        end
        value
    end
    model = CompositeModel(
        Object(:first; status=Status(keep=11.0)),
        Object(:second; status=Status(keep=12.0));
        applications=(
            ModelSpec(TransactionDefault(1.0); name=:first_default, on=One(id=:first)),
            ModelSpec(TransactionDefault(2.0); name=:second_default, on=One(id=:second)),
        ), environment=(duration=Hour(1),), status_transform=transform)
    first = model_status(model, :first)
    second = model_status(model, :second)
    records = copy(model.status_conversion_records)
    @test_throws ErrorException run!(model; steps=0, outputs=:none)
    @test converted == [1.0, 2.0]
    @test model_status(model, :first) === first
    @test model_status(model, :second) === second
    @test propertynames(first) == propertynames(second) == (:keep,)
    @test first.keep == 11.0
    @test second.keep == 12.0
    @test model.status_conversion_records == records
end

PSE.@process "status_construction_distributed" verbose=false
struct DistributedDefaults{T} <: AbstractStatus_Construction_DistributedModel
    initial::T
end
PSE.outputs_(model::DistributedDefaults) = (flow=Distributed(Default(model.initial[])),)
PSE.run!(::DistributedDefaults, status, environment, constants, context) = nothing

@testset "shared layouts retain fresh effective override defaults" begin
    initial = Ref([1.0])
    overridden = Ref([2.0])
    template = CompositeModelTemplate((
        ModelSpec(DistributedDefaults(initial); name=:writer, on=Many(scale=:Plant),
            outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree())),)),
    ))
    model = CompositeModel(
        ObjectInstance(:left, template; root=Object(:left_root; scale=:Plant),
            objects=(Object(:left_leaf; scale=:Leaf, parent=:left_root),)),
        ObjectInstance(:right, template; root=Object(:right_root; scale=:Plant),
            objects=(Object(:right_leaf; scale=:Leaf, parent=:right_root),),
            overrides=(writer=DistributedDefaults(overridden),));
        environment=(duration=Hour(1),), type_promotion=Dict(Float64 => Float32))
    simulation = run!(model; steps=0, outputs=:none)
    @test model_status(model, :left_leaf).flow == Float32[1]
    @test model_status(model, :right_leaf).flow == Float32[2]
    initial[][1] = 3.0
    overridden[][1] = 4.0
    register_object!(model, Object(:left_new; scale=:Leaf, parent=:left_root))
    register_object!(model, Object(:right_new; scale=:Leaf, parent=:right_root))
    continue!(simulation; steps=1)
    @test model_status(model, :left_new).flow == Float32[3]
    @test model_status(model, :right_new).flow == Float32[4]
    @test model_status(model, :left_leaf).flow == Float32[1]
    @test model_status(model, :right_leaf).flow == Float32[2]
    @test all(isbits, values(model.registry.objects.layout_cache))
end

end
