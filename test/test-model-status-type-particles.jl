using MonteCarloMeasurements
using PlantSimEngine
using PlantSimEngine.GraphEditor
using Test

PlantSimEngine.@process "status_type_particle_propagation" verbose = false

struct StatusTypeParticlePropagationModel <:
       AbstractStatus_Type_Particle_PropagationModel end

PlantSimEngine.inputs_(::StatusTypeParticlePropagationModel) = (
    uncertain=Required(Real),
    ordinary=Default(1.0),
)

PlantSimEngine.outputs_(::StatusTypeParticlePropagationModel) = (
    propagated=0.0,
    ordinary_result=0.0,
)

function PlantSimEngine.run!(
    ::StatusTypeParticlePropagationModel,
    status,
    environment,
    constants,
    context,
)
    status.propagated = status.uncertain^2
    status.ordinary_result = status.ordinary + one(status.ordinary)
    return nothing
end

function status_type_particle_transform(variable, value)
    variable in (:uncertain, :propagated) || return value
    value isa Float64 || return value
    spread = variable === :uncertain ? 1.0 : 0.0
    return Particles{Float64,2}([value - spread, value + spread])
end

@testset "real MonteCarloMeasurements particles propagate through status and streams" begin
    model = CompositeModel(
        StatusTypeParticlePropagationModel();
        status=(uncertain=10.0,),
        type_promotion=Dict(Float64 => Float32),
        status_transform=status_type_particle_transform,
    )
    status = only(model_objects(model)).status

    @test status.uncertain isa Particles{Float64,2}
    @test status.uncertain.particles == [9.0, 11.0]

    simulation = run!(model; outputs=:all)
    status = only(model_objects(model)).status
    @test status.propagated isa Particles{Float64,2}
    @test status.propagated.particles == [81.0, 121.0]
    @test status.ordinary === Float32(1)
    @test status.ordinary_result === Float32(2)

    stream = outputs(simulation)[
        (
            :status_type_particle_propagation,
            ObjectId(:scene),
            :propagated,
        )
    ]
    @test fieldtype(eltype(stream), 2) === Particles{Float64,2}
    @test only(last.(stream)).particles == [81.0, 121.0]

    rows = collect_outputs(simulation; sink=nothing)
    propagated = only(
        row for row in rows
        if row.variable === :propagated
    )
    @test propagated.value isa Particles{Float64,2}
    @test propagated.value.particles == [81.0, 121.0]

    graph_json = model_graph_view_json(model)
    @test occursin("Particles", graph_json)
end

# Type-only preparation must not replay the value callback, including callbacks
# with observable counters. The original particle propagation oracle stays above.
struct StatusTypeParticleTransformCounter
    calls::Dict{Symbol,Int}
end
function (counter::StatusTypeParticleTransformCounter)(variable, value)
    counter.calls[variable] = get(counter.calls, variable, 0) + 1
    return status_type_particle_transform(variable, value)
end

struct StatusTypeParticleDefaultProducer <: AbstractStatus_Type_Particle_PropagationModel end
PlantSimEngine.inputs_(::StatusTypeParticleDefaultProducer) = NamedTuple()
PlantSimEngine.outputs_(::StatusTypeParticleDefaultProducer) = (propagated=3.0,)
PlantSimEngine.run!(::StatusTypeParticleDefaultProducer, status, environment, constants, context) = nothing

PlantSimEngine.@process "status_type_particle_reader" verbose=false
struct StatusTypeParticleReader <: AbstractStatus_Type_Particle_ReaderModel end
PlantSimEngine.inputs_(::StatusTypeParticleReader) = (single=Required(Real), several=Default(Float64[]))
PlantSimEngine.outputs_(::StatusTypeParticleReader) = (count=0,)
PlantSimEngine.run!(::StatusTypeParticleReader, status, environment, constants, context) =
    (status.count = length(status.several); nothing)

@testset "transformed defaults prepare exact One and Many reference families" begin
    calls = Dict{Symbol,Int}()
    transform = StatusTypeParticleTransformCounter(calls)
    model = CompositeModel(Object(:source; scale=:Leaf), Object(:reader; scale=:Plant);
        applications=(
            ModelSpec(StatusTypeParticleDefaultProducer(); name=:source, on=One(id=:source)),
            ModelSpec(StatusTypeParticleReader(); name=:reader, on=One(id=:reader), inputs=(
                single=One(SceneScope(); id=:source, application=:source, var=:propagated),
                several=Many(SceneScope(); scale=:Leaf, application=:source, var=:propagated))),
        ), type_promotion=Dict(Float64=>Float32), status_transform=transform)
    @test isempty(calls)
    preparation = model.scenario_plan_cache
    plans = preparation.program.input_records
    @test length(plans) == 2
    particle_reference = Base.RefValue{Particles{Float64,2}}
    allowed_references = (Base.RefValue{Float32}, particle_reference)
    # The counter callback may infer both concrete return branches. Preparation
    # must retain Particle2, stay within that finite family and never call it.
    for plan in plans
        references = fieldtypes(plan.reference_types)
        @test particle_reference in references
        @test all(R -> R in allowed_references, references)
    end
    @test isempty(calls)
    run!(model; steps=0, outputs=:none)
    source = model_status(model, :source)
    reader = model_status(model, :reader)
    @test source.propagated isa Particles{Float64,2}
    @test source.propagated.particles == [3.0, 3.0]
    reference = PlantSimEngine.refvalue(source, :propagated)
    @test all(plan -> typeof(reference) in fieldtypes(plan.reference_types), plans)
    @test PlantSimEngine.refvalue(reader, :single) === PlantSimEngine.refvalue(source, :propagated)
    @test only(parent(reader.several)) === PlantSimEngine.refvalue(source, :propagated)
    @test get(calls, :propagated, 0) == 1
end

# The value-only Vector constructor leaves N unknown to inference; never execute
# it on a dummy biological value to discover a prospective storage family.
struct StatusTypeUnpreparedParticleTransform
    calls::Base.RefValue{Int}
end
function (transform::StatusTypeUnpreparedParticleTransform)(variable, value)
    transform.calls[] += 1
    variable === :propagated && value isa Float64 && return Particles([value, value])
    return value
end

@testset "non-finite transform results have a preparation diagnostic without replay" begin
    calls = Ref(0)
    model = CompositeModel(Object(:source; scale=:Leaf);
        applications=(ModelSpec(StatusTypeParticleDefaultProducer(); name=:source, on=One(id=:source)),),
        status_transform=StatusTypeUnpreparedParticleTransform(calls))
    @test calls[] == 0
    failure = model.scenario_plan_cache.status_manifest
    @test failure isa PlantSimEngine.ScenarioPreparationFailure
    @test failure.error isa ArgumentError
    @test occursin("finite `status_transform` return family", sprint(showerror, failure.error))
    @test_throws r"finite `status_transform` return family" run!(model; steps=0, outputs=:none)
    @test calls[] == 0
    @test model_object(model, :source).status === nothing
end
