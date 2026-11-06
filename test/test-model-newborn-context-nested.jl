module NewbornNestedContextChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "newborn_nested_leaf" verbose=false
PSE.@process "newborn_nested_middle" verbose=false
PSE.@process "newborn_nested_creator" verbose=false
struct Leaf{C} <: AbstractNewborn_Nested_LeafModel
    contexts::C
end
struct Middle{C} <: AbstractNewborn_Nested_MiddleModel
    contexts::C
end
struct Creator{C} <: AbstractNewborn_Nested_CreatorModel
    capture::C
end
PSE.inputs_(::Union{Leaf,Middle,Creator}) = NamedTuple()
PSE.outputs_(::Union{Leaf,Middle}) = (value=0.0,calls=0,seen_time=0.0)
PSE.outputs_(::Creator) = (created=false,value=0.0)
function PSE.run!(model::Leaf, status, environment, constants, context)
    push!(model.contexts,context)
    status.calls += 1
    status.value = 5.0 + context.time
    status.seen_time = context.time
    return nothing
end
function PSE.run!(model::Middle, status, environment, constants, context)
    push!(model.contexts,context)
    status.calls += 1
    run_call!(context,:child;publish=true)
    status.value = only(call_targets(context,:child)).status.value + context.time
    status.seen_time = context.time
    return nothing
end
function PSE.run!(model::Creator, status, environment, constants, context)
    status.created && return nothing
    runtime = runtime_model(context)
    middle = register_object!(runtime,Object(:middle;scale=:Middle,parent=:owner,
        status=Status(value=0.0,calls=0,seen_time=0.0)))
    register_object!(runtime,Object(:child;scale=:Leaf,parent=:middle,
        status=Status(value=0.0,calls=0,seen_time=0.0)))
    first = only(call_targets(context,:middle;objects=middle))
    second = only(call_targets(context,:middle;objects=middle))
    before_calls = (model_status(runtime,:middle).calls,model_status(runtime,:child).calls)
    dirty_after_get = PSE.bindings_dirty(runtime)
    run_call!(first;publish=true)
    model.capture[] = (;first,second,before_calls,dirty_after_get,creator_context=context)
    status.value = first.status.value
    status.created = true
    return nothing
end

@testset "manual newborn nested calls keep their resolved graph through full refresh" begin
    capture = Ref{Any}()
    middle_contexts,leaf_contexts = Any[],Any[]
    model = CompositeModel(Object(:owner;scale=:Scene);
        applications=(
            ModelSpec(Creator(capture);name=:creator,on=One(id=:owner),
                calls=(middle=Many(scale=:Middle,within=Subtree(),application=:middle),)),
            ModelSpec(Middle(middle_contexts);name=:middle,on=Many(scale=:Middle),
                calls=(child=One(scale=:Leaf,within=Subtree(),application=:child),)),
            ModelSpec(Leaf(leaf_contexts);name=:child,on=Many(scale=:Leaf)),
        ))
    simulation = run!(model;steps=1,outputs=:all)
    data = capture[]
    @test data.before_calls == (0,0)
    @test !data.dirty_after_get # nested target used the existing full-refresh fallback
    @test length(data.first.execution_target.call_bindings) == 1
    @test PSE._compiled_call_name(only(data.first.execution_target.call_bindings)) === :child
    # Independent explicit selections may refresh nested execution owners.
    # Both views must still expose the same live registry-owned scientific state.
    @test data.first.status === data.second.status === model_status(model, :middle)
    @test only(middle_contexts) === data.first.context_cache.default
    @test only(middle_contexts) !== only(leaf_contexts)
    @test only(middle_contexts) !== data.creator_context
    @test only(middle_contexts).time == only(leaf_contexts).time == 1.0
    @test only(middle_contexts).publication_allowed && only(leaf_contexts).publication_allowed
    @test length(call_targets(only(middle_contexts),:child)) == 1
    @test model_status(model,:middle).value == 7.0
    @test model_status(model,:child).value == 6.0
    @test outputs(simulation)[(:middle,ObjectId(:middle),:calls)] == [(1.0,1)]
    @test outputs(simulation)[(:child,ObjectId(:child),:calls)] == [(1.0,1)]

    run_call!(data.second;publish=false)
    @test model_status(model,:middle).calls == model_status(model,:child).calls == 2
    @test outputs(simulation)[(:middle,ObjectId(:middle),:calls)] == [(1.0,1)]
    @test outputs(simulation)[(:child,ObjectId(:child),:calls)] == [(1.0,1)]
    continue!(simulation;steps=1)
    @test model_status(model,:middle).calls == model_status(model,:child).calls == 2
    @test model_status(model,:middle).seen_time == model_status(model,:child).seen_time == 1.0
end

end
