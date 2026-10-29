module SimulationDispatchBarrierChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "scheduled_dispatch_source" verbose=false
PSE.@process "scheduled_dispatch_probe" verbose=false
PSE.@process "scheduled_dispatch_ticker" verbose=false

struct ScheduledDispatchSource{T} <: AbstractScheduled_Dispatch_SourceModel
    initial::T
end
PSE.inputs_(::ScheduledDispatchSource) = NamedTuple()
PSE.outputs_(model::ScheduledDispatchSource) = (seed=model.initial,)
function PSE.run!(::ScheduledDispatchSource, status, environment, constants, context)
    status.seed += one(status.seed)
    if context.time == 3
        register_object!(
            runtime_model(context),
            Object(:leaf_2; scale=:Leaf, parent=:scene),
        )
    end
    return nothing
end

struct ScheduledDispatchProbe{T} <: AbstractScheduled_Dispatch_ProbeModel
    initial::T
    log::Vector{Tuple{Int,Symbol,T}}
end
PSE.inputs_(model::ScheduledDispatchProbe{T}) where {T} = (seed=Required(T),)
PSE.outputs_(model::ScheduledDispatchProbe) = (seen=model.initial, visits=0)
PSE.environment_inputs_(model::ScheduledDispatchProbe) = (driver=model.initial,)
function PSE.run!(model::ScheduledDispatchProbe, status, environment, constants, context)
    status.seen = status.seed + environment.driver + constants.increment
    status.visits += 1
    push!(model.log, (Int(context.time), object_id(context).value, status.seen))
    return nothing
end

struct ScheduledDispatchTicker <: AbstractScheduled_Dispatch_TickerModel end
PSE.inputs_(::ScheduledDispatchTicker) = NamedTuple()
PSE.outputs_(::ScheduledDispatchTicker) = (ticks=0,)
function PSE.run!(::ScheduledDispatchTicker, status, environment, constants, context)
    status.ticks += 1
    return nothing
end

function scheduled_dispatch_scene(::Type{T}) where {T}
    log = Tuple{Int,Symbol,T}[]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_1; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(ScheduledDispatchTicker(); name=:ticker, on=One(scale=:Scene)),
            ModelSpec(ScheduledDispatchSource(zero(T)); name=:source,
                on=One(scale=:Scene), every=Hour(2)),
            ModelSpec(ScheduledDispatchProbe(zero(T), log); name=:probe,
                on=Many(scale=:Leaf), every=Hour(2),
                inputs=(:seed => One(scale=:Scene, application=:source, var=:seed),)),
        ),
        environment=(driver=T(7), duration=Hour(1)),
    )
    return model, log
end

@testset "scheduled dispatch reads live simulation fields across refresh and continuation" begin
    for T in (Float32, Float64), performance in (false, true), retention in (:none, :all)
        model, log = scheduled_dispatch_scene(T)
        simulation = run!(model; steps=1, outputs=retention, performance,
            constants=(increment=T(2),))
        reference = simulation
        @test ismutable(simulation)
        schedule = simulation.execution_plan.schedule
        @test log == [(1, :leaf_1, T(10))]

        # Same-type runtime configuration can change between continuations.
        # The batch boundary must extract its current value on every call.
        simulation.constants = (increment=T(4),)
        @test continue!(simulation; steps=2) === reference
        @test simulation.current_step == 3
        @test log == [(1, :leaf_1, T(10)), (3, :leaf_1, T(13)), (3, :leaf_2, T(13))]
        @test simulation.execution_plan.schedule === schedule
        @test model_object(model, :leaf_1).status.visits == 2
        @test model_object(model, :leaf_2).status.visits == 1
        @test model_object(model, :leaf_2).status.seen isa T

        # Mid-step addition above and between-step removal below must refresh
        # the execution targets and contexts without replaying prior groups.
        remove_object!(model, :leaf_1)
        @test continue!(simulation; steps=2) === reference
        @test simulation.current_step == 5
        @test log == [(1, :leaf_1, T(10)), (3, :leaf_1, T(13)),
                      (3, :leaf_2, T(13)), (5, :leaf_2, T(14))]
        @test model_object(model, :scene).status.ticks == 5
        @test model_object(model, :scene).status.seed == T(3)
        @test model_object(model, :leaf_2).status.visits == 2
        @test simulation.execution_plan.schedule === schedule
        for batch in simulation.execution_plan.batches
            @test batch.context_state.compiled === simulation.compiled
            @test batch.context_state.environment_bindings === simulation.environment_bindings
        end
        if retention === :all
            leaf_1 = outputs(simulation)[(:probe, ObjectId(:leaf_1), :seen)]
            leaf_2 = outputs(simulation)[(:probe, ObjectId(:leaf_2), :seen)]
            @test first.(leaf_1) == [1.0, 3.0]
            @test last.(leaf_1) == T[10, 13]
            @test first.(leaf_2) == [3.0, 5.0]
            @test last.(leaf_2) == T[13, 14]
        else
            @test isempty(outputs(simulation))
        end
        if performance
            counts = Advanced.runtime_performance(simulation).counts
            @test counts[:steps_executed] == 5
            @test counts[:application_groups_visited] == 11
            @test counts[:execution_targets_visited] == 12
        end
    end
end

end # module
