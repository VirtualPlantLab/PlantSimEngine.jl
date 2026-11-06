module EmptyOutputRequestChecks
using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "empty_request_counter" verbose=false
struct Counter <: AbstractEmpty_Request_CounterModel end
PSE.outputs_(::Counter) = (counter=0,)
PSE.run!(::Counter, status, environment, constants, context) = (status.counter += 1; nothing)

@testset "empty output requests have one concrete schema through growth" begin
    for selection in (:none, :all, nothing, OutputRequest[])
        model = CompositeModel(Object(:first; scale=:Leaf);
            applications=(ModelSpec(Counter(); name=:counter, on=Many(scale=:Leaf)),))
        simulation = run!(model; steps=1, outputs=selection)
        @test simulation.output_requests === ()
        @test isempty(simulation.output_request_matchers)
        @test isempty(simulation.output_request_targets)
        register_object!(model, Object(:second; scale=:Leaf))
        continue!(simulation)
        @test current_step(simulation) == 2
        @test model_status(model, :first).counter == 2
        @test model_status(model, :second).counter == 1
        @test simulation.output_request_model_revision == model.revision
        if selection === :all
            @test outputs(simulation)[(:counter, ObjectId(:first), :counter)] == [(1.0, 1), (2.0, 2)]
            @test outputs(simulation)[(:counter, ObjectId(:second), :counter)] == [(2.0, 1)]
        else
            @test isempty(outputs(simulation))
        end
    end
end

@testset "requested output selection remains explicit" begin
    request = OutputRequest(:Leaf, :counter)
    model = CompositeModel(Object(:first; scale=:Leaf);
        applications=(ModelSpec(Counter(); name=:counter, on=Many(scale=:Leaf)),))
    simulation = run!(model; steps=2, outputs=request)
    @test only(simulation.output_requests) === request
    @test outputs(simulation)[(:counter, ObjectId(:first), :counter)] == [(1.0, 1), (2.0, 2)]
    @test length(collect_outputs(simulation, :counter; sink=nothing)) == 2
    @test_throws ErrorException PSE._model_output_selection(:unsupported)
end
end
