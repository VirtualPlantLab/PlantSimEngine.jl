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
        @test isempty(simulation.output_requests)
        @test simulation.output_requests isa PSE.CompiledMetadataTable{NamedTuple{(),Tuple{}}}
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
    @test only(simulation.output_requests).request === request
    @test outputs(simulation)[(:counter, ObjectId(:first), :counter)] == [(1.0, 1), (2.0, 2)]
    @test length(collect_outputs(simulation, :counter; sink=nothing)) == 2
    @test_throws ErrorException PSE._model_output_selection(:unsupported)
end

@testset "typed requests share one owner through output membership changes" begin
    model = CompositeModel(
        Object(1; scale=:Plant),
        Object(2; scale=:Leaf, parent=1),
        Object(3; scale=:Leaf, parent=1);
        applications=(ModelSpec(Counter(); name=:counter, on=Many(scale=:Leaf)),),
    )
    first_request = OutputRequest(OptionalOne(id=2, scale=:Leaf), :counter; name=:first)
    plant_request = OutputRequest(Many(Subtree(), scale=:Leaf), :counter;
        name=:plant, context=ObjectId(1))
    simulation = run!(model; steps=0, outputs=OutputRequest[first_request, plant_request])
    @test Tuple(entry.request for entry in simulation.output_requests) ===
        (first_request, plant_request)
    record = simulation.output_requests[:plant]
    original_target = record.targets[ObjectId(2)]
    original_memberships = original_target.memberships
    batch = only(simulation.execution_plan.batches)
    schema = PSE.PreparedExecutionBatchSchema{Vector{typeof(batch)}}()
    simulation = PSE._prepare_execution_batch_schemas(simulation, (counter=schema,))
    record = simulation.output_requests[:plant]
    @test keytype(typeof(record.targets)) === keytype(typeof(model.registry.objects))
    @test all(id -> id.value isa Int, keys(record.targets))
    @test valtype(typeof(record.targets)) === PSE.OutputRequestTarget{Int}
    @test record.targets[ObjectId(2)] === original_target
    @test record.targets[ObjectId(2)].memberships === original_memberships
    @test_throws ArgumentError PSE._with_output_request_reference(identity, record, Ref(1f0))
    @test_throws ArgumentError PSE._with_output_request_value(identity, record, 1f0)
    step!(simulation)
    register_object!(model, Object(4; scale=:Leaf, parent=1))
    step!(simulation)
    remove_object!(model, 2)
    step!(simulation)
    rows = collect_outputs(simulation, :plant; sink=nothing)
    @test [(row.object_id, row.timestep, row.value) for row in rows] == [
        (2, 1, 1), (3, 1, 1),
        (2, 2, 2), (3, 2, 2), (4, 2, 1),
        (3, 3, 3), (4, 3, 2),
    ]
    @test [(row.object_id, row.timestep, row.value)
        for row in collect_outputs(simulation, :first; sink=nothing)] == [(2, 1, 1), (2, 2, 2)]
    @test record.targets[ObjectId(2)].memberships === original_memberships
    @test only(original_memberships).end_time === 2.0
    @test outputs(simulation)[(:counter, ObjectId(2), :counter)] == [(1.0, 1), (2.0, 2)]
end

@testset "output request cardinality diagnostics survive lifecycle growth" begin
    model = CompositeModel(Object(:first_leaf; scale=:Leaf);
        applications=(ModelSpec(Counter(); name=:counter, on=Many(scale=:Leaf)),))
    request = OutputRequest(OptionalOne(scale=:Leaf), :counter;
        name=:chosen_leaf, application=:counter)
    simulation = run!(model; steps=0, outputs=request)
    original_target = simulation.output_requests[:chosen_leaf].targets[ObjectId(:first_leaf)]
    register_object!(model, Object(:second_leaf; scale=:Leaf))
    failure = try
        continue!(simulation; steps=0)
        nothing
    catch exception
        exception
    end
    @test failure isa ErrorException
    if failure isa ErrorException
        message = sprint(showerror, failure)
        @test occursin("Output request `chosen_leaf` expected at most one current object", message)
        @test occursin("OptionalOne", message)
        @test occursin("first_leaf", message)
        @test occursin("second_leaf", message)
    end
    @test current_step(simulation) == 0
    @test length(simulation.output_requests[:chosen_leaf].targets) == 1
    @test simulation.output_requests[:chosen_leaf].targets[ObjectId(:first_leaf)] === original_target
end
end
