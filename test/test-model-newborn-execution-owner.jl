module CanonicalNewbornExecutionOwnerChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine

PSE.@process "canonical_newborn_state" verbose=false
PSE.@process "canonical_newborn_creator" verbose=false

struct Leaf{H,C} <: AbstractCanonical_Newborn_StateModel
    hook::H
    contexts::C
end
PSE.inputs_(::Leaf) = (driver=Required(Float64),)
PSE.outputs_(::Leaf) = (value=0.0, calls=0)
function PSE.run!(model::Leaf, status, environment, constants, context)
    push!(model.contexts, context)
    status.calls += 1
    status.value = status.driver + context.time
    hook = model.hook[]
    if !isnothing(hook)
        model.hook[] = nothing
        hook()
    end
    return nothing
end

struct Creator{C,H} <: AbstractCanonical_Newborn_CreatorModel
    capture::C
    hook::H
end
PSE.inputs_(::Creator) = NamedTuple()
PSE.outputs_(::Creator) = (created=false, value=0.0)
function PSE.run!(model::Creator, status, environment, constants, context)
    status.created && return nothing
    runtime = runtime_model(context)
    born = register_object!(runtime, Object(:born; scale=:Leaf, parent=:scene,
        status=Status(driver=2.0, value=0.0, calls=0)))
    first = only(call_targets(context, :leaf; objects=born))
    second = only(call_targets(context, :leaf; objects=born))
    binding = PSE._model_call_targets(context, :leaf).binding
    location = PSE.cohort_location(context.temporal_streams.cohorts, :newborn_state,
        born.id; owner=PSE._execution_call_owner(binding))
    lease_checks = Bool[]
    model.hook[] = () -> begin
        push!(lease_checks, first.context_cache.in_use)
        run_call!(second; publish=false)
        push!(lease_checks, first.context_cache.in_use)
    end
    run_call!(first; publish=true)
    model.capture[] = (; first, second, born, lease_checks,
        dirty=PSE.bindings_dirty(runtime), prebarrier_location=location)
    status.value = first.status.value
    status.created = true
    return nothing
end

@testset "newborn calls use canonical owners without changing pre-barrier leases" begin
    capture = Ref{Any}()
    hook = Ref{Any}(nothing)
    contexts = Any[]
    model = CompositeModel(Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(Creator(capture, hook); name=:creator, on=One(id=:scene),
                calls=(leaf=Many(scale=:Leaf, within=Subtree(), application=:newborn_state),)),
            ModelSpec(Leaf(hook, contexts); name=:newborn_state, on=Many(scale=:Leaf)),
        ))
    simulation = run!(model; outputs=:all)
    data = capture[]
    @test data.first.execution_target isa PSE.CompiledExecutionTarget
    @test data.second.execution_target isa PSE.CompiledExecutionTarget
    @test data.first.execution_target !== data.second.execution_target
    @test data.first.status === data.second.status === model_status(model, :born)
    @test data.first.execution_target.status_view.status === data.first.status
    @test data.first.context_cache === data.second.context_cache
    @test data.first.execution_target.context isa PSE.RunContext
    @test data.first.context_cache.default === data.first.execution_target.context
    @test data.second.execution_target.context === data.first.execution_target.context
    @test data.first.execution_target.context.object_id === ObjectId(:born)
    @test data.first.execution_target.context.application.id === :newborn_state
    @test data.first.execution_target.context.bound_inputs === data.first.bound_inputs
    @test data.first.execution_target.context.calls === data.first.calls
    @test data.first.context_cache.execution_stamp[] == 2
    @test !data.first.context_cache.in_use
    @test data.lease_checks == [true, true]
    @test length(contexts) == 2
    @test contexts[1] !== contexts[2]
    @test contexts[1] === data.first.context_cache.default
    @test contexts[1].time == contexts[2].time == 1.0
    @test contexts[1].publication_allowed
    @test !contexts[2].publication_allowed
    @test contexts[1].environment isa PSE.NoEnvironmentOverride
    @test contexts[2].environment isa PSE.NoEnvironmentOverride
    @test data.dirty
    @test isnothing(data.prebarrier_location)
    @test !PSE.bindings_dirty(model)
    @test model_status(model, :scene).value == 3.0
    @test model_status(model, :born).calls == 2
    @test outputs(simulation)[(:newborn_state, ObjectId(:born), :value)] == [(1.0, 3.0)]
    @test outputs(simulation)[(:newborn_state, ObjectId(:born), :calls)] == [(1.0, 2)]

    # Retained trial views keep their captured metadata and shared execution
    # stamps after the ordinary lifecycle barrier installs current bindings.
    run_call!(data.first; publish=false)
    @test data.first.time == 1.0
    @test data.first.context_cache.execution_stamp[] == 3
    @test model_status(model, :born).calls == 3
    @test outputs(simulation)[(:newborn_state, ObjectId(:born), :calls)] == [(1.0, 2)]
    continue!(simulation)
    @test model_status(model, :born).calls == 3
    @test outputs(simulation)[(:newborn_state, ObjectId(:born), :calls)] == [(1.0, 2)]
end
end
