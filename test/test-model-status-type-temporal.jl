using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "status_type_temporal_source" verbose = false
PlantSimEngine.@process "status_type_temporal_consumer" verbose = false

struct StatusTypeTemporalSource <: AbstractStatus_Type_Temporal_SourceModel end
struct StatusTypeTemporalConsumer <: AbstractStatus_Type_Temporal_ConsumerModel end

PlantSimEngine.inputs_(::StatusTypeTemporalSource) = NamedTuple()
PlantSimEngine.outputs_(::StatusTypeTemporalSource) = (signal=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeTemporalSource,
    status,
    environment,
    constants,
    context,
)
    status.signal += one(status.signal)
    return nothing
end

PlantSimEngine.inputs_(::StatusTypeTemporalConsumer) = (sample=Required(Real),)
PlantSimEngine.outputs_(::StatusTypeTemporalConsumer) = (observed=0.0,)

function PlantSimEngine.run!(
    ::StatusTypeTemporalConsumer,
    status,
    environment,
    constants,
    context,
)
    status.observed = status.sample
    return nothing
end

function status_type_temporal_scene(policy; window=nothing, source_every=Hour(1))
    selector = One(
        scale=:Leaf,
        application=:source,
        var=:signal,
        policy=policy,
        window=window,
    )
    input = policy isa PreviousTimeStep ?
            (PreviousTimeStep(:sample) => selector,) :
            (:sample => selector,)
    return CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(sample=0.0));
        applications=(
            ModelSpec(
                StatusTypeTemporalSource();
                name=:source,
                on=One(scale=:Leaf),
                every=source_every,
            ),
            ModelSpec(
                StatusTypeTemporalConsumer();
                name=:consumer,
                on=One(scale=:Leaf),
                inputs=input,
                every=Hour(1),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )
end

@testset "temporal input policies preserve converted storage types" begin
    policies = (
        (:hold_last, HoldLast(), nothing, Hour(2)),
        (:interpolate, Interpolate(), nothing, Hour(2)),
        (:integrate, Integrate(), Hour(2), Hour(1)),
        (:aggregate, Aggregate(), Hour(2), Hour(1)),
        (:previous, PreviousTimeStep(:sample), nothing, Hour(1)),
    )
    for (name, policy, window, source_every) in policies
        scene = status_type_temporal_scene(
            policy;
            window=window,
            source_every=source_every,
        )
        simulation = run!(scene; steps=4, outputs=:none)
        status = only(model_objects(scene)).status
        view = simulation.compiled.status_views_by_target[
            (:consumer, ObjectId(:leaf))
        ]

        @testset "$(name)" begin
            @test status.signal isa Float32
            @test status.observed isa Float32
            @test view.status.sample isa Float32
            if policy isa Union{Interpolate,Integrate,Aggregate,PreviousTimeStep}
                temporal = only(view.temporal_inputs)
                @test temporal.reference isa Base.RefValue{Float32}
                stream = outputs(simulation)[
                    (:source, ObjectId(:leaf), :signal)
                ]
                @test stream isa PlantSimEngine.TemporalDependencyBuffer{Float32}
                @test all(sample -> last(sample) isa Float32, stream)
            end
        end
    end
end

@testset "resampled OutputRequest rows retain the effective stream type" begin
    requests = OutputRequest[
        OutputRequest(
            :Leaf,
            :signal;
            name=:held,
            application=:source,
            policy=HoldLast(),
            clock=Hour(1),
        ),
        OutputRequest(
            :Leaf,
            :signal;
            name=:interpolated,
            application=:source,
            policy=Interpolate(),
            clock=Hour(1),
        ),
        OutputRequest(
            :Leaf,
            :signal;
            name=:integrated,
            application=:source,
            policy=Integrate(),
            clock=Hour(2),
        ),
        OutputRequest(
            :Leaf,
            :signal;
            name=:aggregated,
            application=:source,
            policy=Aggregate(),
            clock=Hour(2),
        ),
    ]
    scene = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(
                StatusTypeTemporalSource();
                name=:source,
                on=One(scale=:Leaf),
                every=Hour(2),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )
    simulation = run!(scene; steps=6, outputs=requests)
    collected = collect_outputs(simulation; sink=nothing)

    @test Set(keys(collected)) == Set((:held, :interpolated, :integrated, :aggregated))
    for rows in values(collected)
        @test !isempty(rows)
        @test all(row -> row.value isa Float32, rows)
    end
end
