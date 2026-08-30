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
    return Particles([value - spread, value + spread])
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
