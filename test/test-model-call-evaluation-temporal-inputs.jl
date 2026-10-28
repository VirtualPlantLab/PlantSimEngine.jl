module CallEvaluationTemporalInputChecks

using Dates, PlantSimEngine, PlantMeteo, Test

const PSE = PlantSimEngine
PSE.@process "evaluation_temporal_owner_probe" verbose=false
PSE.@process "evaluation_temporal_parent_probe" verbose=false
PSE.@process "evaluation_temporal_producer_probe" verbose=false
PSE.@process "evaluation_temporal_consumer_probe" verbose=false

struct CaptureOwner{C} <: AbstractEvaluation_Temporal_Owner_ProbeModel
    capture::C
end
PSE.outputs_(::CaptureOwner) = (visits=0,)
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct Producer <: AbstractEvaluation_Temporal_Producer_ProbeModel end
PSE.inputs_(::Producer) = (driver=Default(0.0),)
PSE.outputs_(::Producer) = (source_signal=0.0, producer_calls=0)
function PSE.run!(::Producer, status, environment, constants, context)
    status.producer_calls += 1
    status.source_signal = status.driver
    return nothing
end

struct Consumer{M} <: AbstractEvaluation_Temporal_Consumer_ProbeModel end
PSE.inputs_(::Consumer{false}) = (temporal_input=Required(Real),)
PSE.inputs_(::Consumer{true}) = (temporal_input=Required(AbstractVector),)
PSE.outputs_(::Consumer) = (consumed_signal=0.0, consumer_calls=0)
function PSE.run!(::Consumer, status, environment, constants, context)
    status.consumer_calls += 1
    status.consumed_signal = status.temporal_input isa AbstractVector ?
        sum(status.temporal_input) : status.temporal_input
    return nothing
end

struct Parent <: AbstractEvaluation_Temporal_Parent_ProbeModel
    nested_evaluations::Bool
end
PSE.inputs_(::Parent) = (candidate=Default(5.0),)
PSE.outputs_(::Parent) = (parent_seen=0.0, parent_calls=0)
function PSE.run!(model::Parent, status, environment, constants, context)
    status.parent_calls += 1
    producers = call_targets(context, :producers)
    # An unpublished producer trial must not become visible through temporal
    # inputs, even though it mutates the live canonical source status.
    for producer in producers
        offset = producer.object_id == ObjectId(:producer_b) ? 2 : 0
        producer.status.driver = status.candidate + offset - 100
    end
    run_call!(context, :producers; publish=false)
    for producer in producers
        offset = producer.object_id == ObjectId(:producer_b) ? 2 : 0
        producer.status.driver = status.candidate + offset
    end
    if model.nested_evaluations
        accept_call!(evaluate_call!(context, :producers))
        consumer_evaluation = evaluate_call!(context, :consumer)
        consumer = only(call_targets(consumer_evaluation))
        status.parent_seen = consumer.status.consumed_signal
        accept_call!(consumer_evaluation)
    else
        run_call!(context, :producers; publish=true)
        consumer = only(run_call!(context, :consumer; publish=true))
        status.parent_seen = consumer.status.consumed_signal
    end
    return nothing
end

function fixture(policy; many=false, S=Float64, nested=false, outputs=:all,
    window=Hour(1))
    capture = Ref{Any}()
    source = many ?
        Many(scale=:Producer, within=SceneScope(), application=:producer,
            var=:source_signal, policy=policy, window=window) :
        One(id=:producer_a, within=SceneScope(), application=:producer,
            var=:source_signal, policy=policy, window=window)
    objects = Object[
        Object(:owner; scale=:Scene), Object(:parent; scale=:Plant, parent=:owner),
        Object(:producer_a; scale=:Producer, parent=:parent),
        Object(:consumer; scale=:Consumer, parent=:parent),
    ]
    many && push!(objects, Object(:producer_b; scale=:Producer, parent=:parent))
    model = CompositeModel(objects...; applications=(
        ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner),
            calls=(parent=One(id=:parent, within=Subtree(), application=:parent),)),
        ModelSpec(Parent(nested); name=:parent, on=One(id=:parent), calls=(
            producers=Many(scale=:Producer, within=Subtree(), application=:producer),
            consumer=One(id=:consumer, within=Subtree(), application=:consumer),)),
        ModelSpec(Producer(); name=:producer, on=Many(scale=:Producer)),
        ModelSpec(Consumer{many}(); name=:consumer, on=One(id=:consumer),
            inputs=(temporal_input=source,)),
    ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => S))
    simulation = run!(model; steps=1, outputs)
    return (; model, capture, simulation)
end

raw(simulation, application, object, variable) =
    outputs(simulation)[(application, ObjectId(object), variable)]

@testset "staged producer samples reach singular and Many temporal consumers" begin
    for policy in (HoldLast(), Aggregate(PlantMeteo.SumReducer())),
        many in (false, true), S in (Float32, Float64)
        ordinary = fixture(policy; many, S)
        run_call!(ordinary.capture[], :parent; publish=true)
        expected = many ? S(12) : S(5)
        @test final_state(ordinary.simulation, :parent).parent_seen === expected

        candidate = fixture(policy; many, S)
        parent = only(call_targets(candidate.capture[], :parent))
        parent.status.candidate = S(-10)
        rejected = evaluate_call!(candidate.capture[], :parent)
        @test parent.status.parent_seen === (many ? S(-18) : S(-10))
        parent.status.candidate = S(5)
        accepted = evaluate_call!(candidate.capture[], :parent)
        @test parent.status.parent_seen === expected
        @test isempty(raw(candidate.simulation, :producer, :producer_a, :source_signal))
        @test isempty(raw(candidate.simulation, :consumer, :consumer, :consumed_signal))
        @test_throws ArgumentError accept_call!(rejected)
        accept_call!(accepted)
        @test parent.status.parent_calls == 2
        @test final_state(candidate.simulation, :producer_a).producer_calls == 4
        @test final_state(candidate.simulation, :consumer).consumer_calls == 2
        @test raw(candidate.simulation, :producer, :producer_a, :source_signal) == [(1.0, S(5))]
        if many
            @test raw(candidate.simulation, :producer, :producer_b, :source_signal) == [(1.0, S(7))]
        end
        @test raw(candidate.simulation, :consumer, :consumer, :consumed_signal) == [(1.0, expected)]
        @test raw(candidate.simulation, :parent, :parent, :parent_seen) == [(1.0, expected)]
    end
end

@testset "temporal readers see accepted child events through parent ancestry" begin
    for (policy, many, S) in ((HoldLast(), false, Float32),
        (Aggregate(PlantMeteo.SumReducer()), true, Float64))
        candidate = fixture(policy; many, S, nested=true)
        evaluated = evaluate_call!(candidate.capture[], :parent)
        expected = many ? S(12) : S(5)
        @test only(call_targets(evaluated)).status.parent_seen === expected
        @test isempty(raw(candidate.simulation, :producer, :producer_a, :source_signal))
        @test isempty(raw(candidate.simulation, :consumer, :consumer, :consumed_signal))
        accept_call!(evaluated)
        @test final_state(candidate.simulation, :producer_a).producer_calls == 2
        @test final_state(candidate.simulation, :consumer).consumer_calls == 1
        @test raw(candidate.simulation, :producer, :producer_a, :source_signal) == [(1.0, S(5))]
        @test raw(candidate.simulation, :consumer, :consumer, :consumed_signal) == [(1.0, expected)]
    end
end

@testset "dependency-only temporal buffers also see the current evaluation" begin
    candidate = fixture(Aggregate(PlantMeteo.SumReducer()); outputs=:none)
    evaluated = evaluate_call!(candidate.capture[], :parent)
    @test only(call_targets(evaluated)).status.parent_seen == 5.0
    accept_call!(evaluated)
    @test final_state(candidate.simulation, :consumer).consumed_signal == 5.0
end

@testset "staged current samples combine with committed temporal history" begin
    for retention in (:all, :none), S in (Float32, Float64)
        candidate = fixture(Aggregate(PlantMeteo.SumReducer()); S,
            outputs=retention, window=Hour(2))
        parent = only(call_targets(candidate.capture[], :parent))
        parent.status.candidate = S(3)
        run_call!(candidate.capture[], :parent; publish=true)
        @test parent.status.parent_seen === S(3)
        continue!(candidate.simulation; steps=1)
        parent = only(call_targets(candidate.capture[], :parent))
        parent.status.candidate = S(5)
        evaluated = evaluate_call!(candidate.capture[], :parent)
        @test parent.status.parent_seen === S(8)
        if retention === :all
            @test raw(candidate.simulation, :producer, :producer_a, :source_signal) == [(1.0, S(3))]
        end
        accept_call!(evaluated)
        @test final_state(candidate.simulation, :consumer).consumed_signal === S(8)
        if retention === :all
            @test raw(candidate.simulation, :producer, :producer_a, :source_signal) ==
                [(1.0, S(3)), (2.0, S(5))]
            @test raw(candidate.simulation, :consumer, :consumer, :consumed_signal) ==
                [(1.0, S(3)), (2.0, S(8))]
        end
    end
end

end # module CallEvaluationTemporalInputChecks
