module OwnedMetadataTableChecks

using PlantSimEngine, Random, Test
const PSE = PlantSimEngine

left_entry(table) = table[:left]
second_entry(table) = table[2]

@testset "fixed metadata owner preserves order, lookup, and reference identity" begin
    left, right = Ref(1), Ref(2f0)
    entries = (left=left, right=right)
    table = PSE.CompiledMetadataTable(entries)
    @test ismutabletype(typeof(table))
    @test isconst(typeof(table), :entries)
    @test keys(table) === (:left, :right)
    @test length(table) == 2
    @test !isempty(table)
    @test values(table) === table
    @test (@inferred left_entry(table)) === left
    @test (@inferred second_entry(table)) === right
    @test_throws MethodError table[Int32(1)]
    @test get(table, :left, nothing) === left
    @test get(table, :missing, right) === right
    @test haskey(table, :left)
    @test !haskey(table, :missing)
    @test Tuple(values(table)) === (left, right)
    @test_throws BoundsError table[0]
    @test_throws BoundsError table[3]
    @test_throws KeyError table[:missing]
    left[] = 7
    @test table[:left][] == 7
    @test right[] === 2f0
    reserved = PSE.CompiledMetadataTable((entries=left, length=right))
    @test reserved[:entries] === left
    @test reserved[:length] === right
    empty_table = PSE.CompiledMetadataTable(NamedTuple())
    @test isempty(empty_table)
    @test keys(empty_table) === ()
    @test iterate(empty_table) === nothing
    @test Tuple(values(empty_table)) === ()
end

PSE.@process "metadata_owner_source" verbose=false
PSE.@process "metadata_owner_reader" verbose=false

struct Source{R} <: AbstractMetadata_Owner_SourceModel
    rng::R
    metadata_calls::Base.RefValue{Int}
end
function PSE.inputs_(model::Source)
    model.metadata_calls[] += 1
    return NamedTuple()
end
function PSE.outputs_(model::Source)
    model.metadata_calls[] += 1
    return (x=0f0,)
end
PSE.run!(model::Source, status, environment, constants, context) =
    (status.x += rand(model.rng, Float32); nothing)

struct Reader <: AbstractMetadata_Owner_ReaderModel end
PSE.inputs_(::Reader) = (x=Required(Float32),)
PSE.outputs_(::Reader) = (y=0f0,)
PSE.run!(::Reader, status, environment, constants, context) =
    (status.y = 2f0 * status.x; nothing)

function fixture()
    rng = Xoshiro(71)
    metadata_calls = Ref(0)
    model = CompositeModel(Object(1; scale=:Leaf);
        applications=(
            ModelSpec(Reader(); name=:reader, on=Many(scale=:Leaf)),
            ModelSpec(Source(rng, metadata_calls); name=:source, on=Many(scale=:Leaf)),
        ))
    return model, rng, metadata_calls
end

@testset "metadata indexes reuse canonical application and recipe identities" begin
    model, rng, metadata_calls = fixture()
    simulation = run!(model; steps=1, outputs=:all)
    compiled = simulation.compiled
    source = compiled.applications_by_id[:source]
    recipe = compiled.scenario_plan.input_recipes_by_application[:reader]
    @test source === compiled.applications[2]
    @test compiled.applications_by_id[2] === source
    @test compiled.scenario_plan.applications_by_id[:source] === source.plan
    @test PSE._application_plans(compiled.scenario_plan.input_recipes_by_application, :reader) === recipe
    @test recipe isa PSE.CompiledApplicationInputRecipe
    @test ismutabletype(typeof(recipe))
    @test all(name -> isconst(typeof(recipe), name), fieldnames(typeof(recipe)))
    @test isempty(recipe.explicit)
    @test only(only(recipe.inferred)).input === :x
    calls_before = metadata_calls[]
    rng_before = copy(rng)
    by_id = PSE._applications_by_id(compiled.applications)
    recipes = PSE._compiled_application_input_recipes(compiled.scenario_plan.input_plans_by_application)
    @test by_id[:source] === source
    @test recipes[:reader].inferred === recipe.inferred
    @test metadata_calls[] == calls_before
    @test rand(copy(rng), Float32) === rand(rng_before, Float32)
    @test model_status(model, 1).y === 2f0 * model_status(model, 1).x
    register_object!(model, Object(2; scale=:Leaf))
    continue!(simulation; steps=1)
    @test simulation.compiled.scenario_plan.input_recipes_by_application[:reader] === recipe
    @test ObjectId(2) in simulation.compiled.applications_by_id[:source].target_ids
    @test model_status(model, 2).y === 2f0 * model_status(model, 2).x
end

end
