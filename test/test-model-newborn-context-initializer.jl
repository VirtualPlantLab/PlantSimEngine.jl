module NewbornInitializerContextChecks

using Dates, PlantSimEngine, Random, Test
const PSE = PlantSimEngine

PSE.@process "newborn_context_leaf" verbose=false
PSE.@process "newborn_context_creator" verbose=false
struct Leaf{R,C} <: AbstractNewborn_Context_LeafModel
    rng::R
    contexts::C
end
PSE.inputs_(::Leaf) = NamedTuple()
PSE.outputs_(::Leaf) = (calls=0, draw=0.0, seen_time=0.0, seen_T=0f0, allowed=true)
function PSE.run!(model::Leaf, status, environment, constants, context)
    push!(model.contexts, context)
    status.calls += 1
    status.draw = rand(model.rng)
    status.seen_time = context.time
    status.seen_T = environment.T
    status.allowed = context.publication_allowed
    return nothing
end
struct Creator <: AbstractNewborn_Context_CreatorModel end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (day=0,)
function PSE.run!(::Creator, status, environment, constants, context)
    status.day += 1
    if status.day == 2
        born = register_object!(runtime_model(context), Object(:born; scale=:Leaf, parent=:owner,
            status=Status(calls=0, draw=0.0, seen_time=0.0, seen_T=0f0, allowed=true)))
        run_initializer!(context, :initialize, born)
    end
    return nothing
end

@testset "newborn context has invocation time/environment without replay or shared scheduled cache" begin
    rng = Xoshiro(31)
    reference = copy(rng)
    contexts = Any[]
    model = CompositeModel(Object(:owner; scale=:Scene);
        applications=(
            ModelSpec(Creator(); name=:creator, on=One(id=:owner),
                calls=(initialize=Initializer(One(scale=:Leaf, within=Subtree(), application=:leaf)),)),
            ModelSpec(Leaf(rng, contexts); name=:leaf, on=Many(scale=:Leaf)),
        ), environment=(T=3f0,duration=Hour(1)))
    simulation = run!(model; steps=2, outputs=:all)
    born = model_status(model, :born)
    first_draw = rand(reference)
    @test born.calls == 1
    @test born.draw == first_draw
    @test born.seen_time == 2.0
    @test born.seen_T === 3f0
    @test !born.allowed
    @test length(contexts) == 1
    first = only(contexts)
    @test first.time == 2.0
    @test !first.publication_allowed
    @test first.environment isa PSE.NoEnvironmentOverride
    @test first.calls === ()
    @test isempty(get(outputs(simulation),(:leaf,ObjectId(:born),:draw),[]))

    continue!(simulation; steps=1)
    second_draw = rand(reference)
    @test born.calls == 2
    @test born.draw == second_draw
    @test born.seen_time == 3.0
    @test born.allowed
    @test length(contexts) == 2
    @test contexts[2] !== first
    @test first.time == 2.0
    @test outputs(simulation)[(:leaf,ObjectId(:born),:calls)] == [(3.0,2)]
    @test outputs(simulation)[(:leaf,ObjectId(:born),:draw)] == [(3.0,second_draw)]
end

end
