module TemporalInitialTypingChecks
using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
PSE.@process "typed_initial_source" verbose=false
PSE.@process "typed_initial_consumer" verbose=false
struct Source{T} <: AbstractTyped_Initial_SourceModel
    initial::T
end
PSE.outputs_(model::Source) = (signal=model.initial,)
function PSE.run!(::Source, status, environment, constants, context)
    status.signal += one(status.signal)
    return nothing
end
struct Consumer{T} <: AbstractTyped_Initial_ConsumerModel end
PSE.inputs_(::Consumer) = (signals=Required(AbstractVector),)
PSE.outputs_(::Consumer{T}) where {T} = (total=zero(T),)
function PSE.run!(::Consumer, status, environment, constants, context)
    status.total = sum(status.signals; init=zero(status.total))
    return nothing
end
function fixture(::Type{T}; empty=false) where {T}
    objects = Object[Object(:scene; scale=:Scene, status=Status(signals=T[]))]
    empty || push!(objects, Object(:a; scale=:Leaf, parent=:scene, status=Status(signal=T(2))))
    return CompositeModel(objects...; applications=(
        ModelSpec(Source(zero(T)); name=:source, on=Many(scale=:Leaf)),
        ModelSpec(Consumer{T}(); name=:consumer, on=One(scale=:Scene),
            inputs=(PreviousTimeStep(:signals) => Many(scale=:Leaf, within=SceneScope(),
                application=:source, var=:signal),)),
    ), environment=(duration=Hour(1),))
end
input(sim) = only(sim.compiled.status_views_by_target[(:consumer, ObjectId(:scene))].temporal_inputs)

@testset "homogeneous initial values retain their numerical schema across growth" begin
    for T in (Float32, Float64), retention in (:none, :all)
        model = fixture(T)
        sim = run!(model; steps=1, outputs=retention)
        initial = input(sim).initial
        @test initial isa Vector{T}
        @test initial == T[2]
        @test all(group -> isconcretetype(eltype(group.batches)), sim.execution_plan.groups)
        @test final_state(sim, :scene).total === T(2)
        register_object!(model, Object(:b; scale=:Leaf, status=Status(signal=T(10))); parent=:scene)
        continue!(sim; steps=1)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[2, 10]
        @test final_state(sim, :scene).total === T(13)
        remove_object!(model, :a)
        continue!(sim; steps=1)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[10]
        @test final_state(sim, :scene).total === T(11)
        if retention === :all
            @test outputs(sim)[(:consumer, ObjectId(:scene), :total)] ==
                [(1.0, T(2)), (2.0, T(13)), (3.0, T(11))]
            @test haskey(outputs(sim), (:source, ObjectId(:a), :signal))
        end
        remove_object!(model, :b)
        step!(sim)
        @test final_state(sim, :scene).total === zero(T)
        @test all(group -> all(batch -> !isempty(batch.targets), group.batches), sim.execution_plan.groups)
        register_object!(model, Object(:c; scale=:Leaf, status=Status(signal=T(20))); parent=:scene)
        step!(sim)
        @test final_state(sim, :scene).total === T(20)
        @test all(group -> isconcretetype(eltype(group.batches)), sim.execution_plan.groups)
    end
end
@testset "empty memberships can acquire a concrete schema" begin
    for T in (Float32, Float64)
        model = fixture(T; empty=true)
        sim = run!(model; steps=1, outputs=:all)
        @test isempty(input(sim).initial)
        @test final_state(sim, :scene).total === zero(T)
        register_object!(model, Object(:a; scale=:Leaf, status=Status(signal=T(7))); parent=:scene)
        step!(sim)
        @test input(sim).initial isa Vector{T}
        @test input(sim).initial == T[7]
        @test final_state(sim, :scene).total === T(7)
    end
end
@testset "heterogeneous snapshots never convert values into the first schema" begin
    mixed = Any[Float32(1.25), Float64(2.5)]
    result = PSE._typed_temporal_initial_values(mixed)
    @test result === mixed
    @test typeof.(result) == [Float32, Float64]
    private = Any[Float32[1, 2], Float32[3, 4]]
    typed = PSE._typed_temporal_initial_values(private)
    @test typed isa Vector{Vector{Float32}}
    @test typed[1] === private[1]
    @test typed[2] === private[2]
    # This helper narrows an already private snapshot, never copies its payload.
    typed[1][1] = 9
    @test private[1][1] === 9f0
end
end
