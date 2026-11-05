module ConcreteRuntimeIdentityChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "concrete_identity_owner" verbose=false
PSE.@process "concrete_identity_leaf" verbose=false

struct IdentityOwner{C} <: AbstractConcrete_Identity_OwnerModel
    capture::C
end
PSE.outputs_(::IdentityOwner) = (visits=0,)
function PSE.run!(model::IdentityOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct IdentityLeaf{T,C} <: AbstractConcrete_Identity_LeafModel
    zero::T
    captures::C
end
PSE.outputs_(model::IdentityLeaf) = (seen=model.zero, visits=0,)
PSE.environment_inputs_(model::IdentityLeaf) = (T=model.zero,)
function PSE.run!(model::IdentityLeaf, status, environment, constants, context)
    model.captures[object_id(context)] = context
    status.seen = oftype(model.zero, environment.T)
    status.visits += 1
    return nothing
end

_identity(runtime) = object_id(runtime)
function check_identity(runtime, expected)
    @test (@inferred _identity(runtime)) === expected
    @test fieldtype(typeof(runtime), :object_id) === typeof(expected)
    return nothing
end

function fixture(::Type{T}, ids) where {T}
    capture = Ref{Any}()
    contexts = Dict{ObjectId,Any}()
    owner_id = ObjectId(:identity_owner)
    children = [Object(id; kind=:identity_leaf, parent=owner_id) for id in ids]
    model = CompositeModel(Object(owner_id; kind=:identity_owner), children...;
        applications=(
            ModelSpec(IdentityOwner(capture); name=:owner, on=One(id=owner_id),
                calls=(first=One(id=ObjectId(first(ids)), within=SceneScope(), application=:leaves),
                    leaves=Many(kind=:identity_leaf, within=SceneScope(), application=:leaves))),
            ModelSpec(IdentityLeaf(zero(T), contexts); name=:leaves, on=Many(kind=:identity_leaf)),
        ),
        environment=[(date=DateTime(2026, 1, 1), duration=Hour(1), T=T(3)),
            (date=DateTime(2026, 1, 1, 1), duration=Hour(1), T=T(4))],
        type_promotion=Dict(Float64=>T))
    return (; model, capture, contexts, owner_id)
end

@testset "runtime identities preserve concrete value types through calls and continuation" begin
    for T in (Float32, Float64), ids in ((:symbol_leaf,), (17,), ((:plant, :leaf, 1),),
        (:symbol_leaf, 17, (:plant, :leaf, 1)))
        data = fixture(T, ids)
        simulation = run!(data.model; steps=1, outputs=:all)
        owner = data.capture[]
        check_identity(owner, data.owner_id)
        selected = only(call_targets(owner, :first))
        check_identity(selected, ObjectId(first(ids)))
        @test runtime_model(selected) === selected.model
        @test runtime_model(selected) === call_model(owner, :first)
        @test model_object(selected).id === ObjectId(first(ids))
        @test model_status(selected) === model_status(data.model, first(ids))
        @test object_id(selected, first(ids)) === ObjectId(first(ids))
        @test model_object(selected, first(ids)) === model_object(data.model, first(ids))
        @test model_status(selected, first(ids)) === model_status(data.model, first(ids))
        @test_throws ArgumentError source_node(selected)
        @test_throws ArgumentError source_node(selected, first(ids))
        @test fieldtype(typeof(selected.execution_target), :object_id) === typeof(ObjectId(first(ids)))
        targets = collect(call_targets(owner, :leaves))
        @test Set(object_id(target) for target in targets) == Set(ObjectId.(ids))
        for target in targets
            expected = object_id(target)
            check_identity(target, expected)
            # A fresh backend override changes the context's environment type,
            # while its physical object identity and value type stay stable.
            run_call!(target; environment=(T=T(9), duration=Hour(1)), publish=false)
            check_identity(data.contexts[expected], expected)
            @test target.status.seen === T(9)
        end
        run_call!(owner, :leaves; publish=true)
        for target in targets
            check_identity(data.contexts[object_id(target)], object_id(target))
            @test target.status.seen === T(3)
        end

        newborn = ObjectId((:newborn, length(ids)))
        register_object!(data.model, Object(newborn; kind=:identity_leaf, parent=data.owner_id))
        continue!(simulation; steps=1)
        current = data.capture[]
        current_targets = collect(call_targets(current, :leaves))
        @test Set(object_id(target) for target in current_targets) == union(Set(ObjectId.(ids)), Set((newborn,)))
        run_call!(current, :leaves; publish=true)
        for target in current_targets
            check_identity(target, object_id(target))
            check_identity(data.contexts[object_id(target)], object_id(target))
            @test target.status.seen === T(4)
        end
        @test object_id(selected) === ObjectId(first(ids))
        @test selected.time == 1 && current.time == 2
    end
end

end # module ConcreteRuntimeIdentityChecks
