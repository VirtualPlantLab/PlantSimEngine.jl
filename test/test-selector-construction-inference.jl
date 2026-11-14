using PlantSimEngine
using Test

@testset "Concrete selector declarations for native entry closure" begin
    # Model dep() may be called again when parameters are supplied to a prepared
    # program. Its result must stay concrete without reinterpreting the schema.
    call = @inferred Call(process=:root_growth)
    selector = @inferred One(within=Self(),application=:root_growth)
    @test object_address(call.selector).process === :root_growth
    @test object_address(selector).application === :root_growth
    @test typeof(Call(process=:alpha)) === typeof(Call(process=:beta))
    @test typeof(One(id=10,kind=:leaf)) === typeof(One(id=1000,kind=:root))
    @test object_address(One(id=10)).id == ObjectId(10)
    @test object_address(Many(id=[10,20])).id == (ObjectId(10),ObjectId(20))
    @test object_address(One(kind="leaf")).kind === :leaf
    @test_throws ErrorException One(unsupported=:value)
end

@testset "selectors without a Relation keep a concrete absent relation" begin
    model = CompositeModel(Object(:leaf; scale=:Leaf))
    direct = @inferred PlantSimEngine._compile_selector_matcher(model, One(id=:leaf))
    scoped = @inferred PlantSimEngine._compile_selector_matcher(model, Many(Subtree(); scale=:Leaf))
    @test direct.relation === nothing
    @test scoped.relation === nothing
    @test resolve_object_ids(model, One(id=:leaf)) == [ObjectId(:leaf)]
end
