module OutputRetentionOwnerChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "retention_owner_writer" verbose=false
PSE.@process "retention_owner_reader" verbose=false
PSE.@process "retention_owner_distributor" verbose=false

struct Writer <: AbstractRetention_Owner_WriterModel end
PSE.inputs_(::Writer) = NamedTuple()
PSE.outputs_(::Writer) = (live=0f0, private=0f0)
function PSE.run!(::Writer, status, environment, constants, context)
    status.live = Float32(context.time)
    status.private = 2f0 * status.live
    return nothing
end

struct Reader <: AbstractRetention_Owner_ReaderModel end
PSE.inputs_(::Reader) = (lag=Default(Float32[]),)
PSE.outputs_(::Reader) = (seen=0f0,)
PSE.run!(::Reader, status, environment, constants, context) =
    (status.seen = sum(status.lag; init=0f0); nothing)

function local_scene(; temporal=false)
    specs = (ModelSpec(Writer(); name=:writer, on=Many(scale=:Leaf),
        output_routing=(private=:stream_only,)),)
    if temporal
        specs = (specs..., ModelSpec(Reader(); name=:reader, on=One(id=0),
            inputs=(PreviousTimeStep(:lag) => Many(SceneScope(); scale=:Leaf,
                application=:writer, var=:private),)))
    end
    return CompositeModel(Object(0; scale=:Scene), Object(1; scale=:Leaf, parent=0);
        applications=specs)
end

stream(simulation, application, id, variable) =
    simulation.temporal_streams[(application, ObjectId(id), variable)]

@testset "callback lookup preserves identity and missing-application diagnostics" begin
    simulation = run!(local_scene(); steps=0, outputs=:none)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:writer]
    @test PSE._compiled_application_by_id(compiled, :writer) === application
    @test PSE._compiled_application_by_id(identity, compiled, :writer) === application
    @test PSE._compiled_application_by_id(compiled, :writer) do selected
        selected.id === :writer && selected.plan === application.plan
    end
    error = try
        PSE._compiled_application_by_id(identity, compiled, :missing)
        nothing
    catch exception
        exception
    end
    @test error isa ErrorException
    @test sprint(showerror, error) == "No compiled model application with id `missing`."
    @test current_step(simulation) == 0
end

@testset "none, all and selective local retention keep stream-only ownership and removed history" begin
    request = OutputRequest(Many(scale=:Leaf), :private; name=:chosen, application=:writer)
    for selection in (:none, :all, request)
        simulation = run!(local_scene(); steps=2, outputs=selection)
        @test model_status(simulation.model, 1).live === 2f0
        @test !hasproperty(model_status(simulation.model, 1), :private)
        retained = simulation.output_retention
        @test eltype(retained.temporal_dependencies) === Tuple{Symbol,Symbol}
        @test eltype(retained.requested_outputs) === Tuple{Symbol,Symbol}
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :writer, 1, :private) == [(1.0, 2f0), (2.0, 4f0)]
            @test haskey(simulation.temporal_streams, (:writer, ObjectId(1), :live)) ==
                (selection === :all)
        end
        register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
        step!(simulation)
        @test model_status(simulation.model, 2).live === 3f0
        @test !hasproperty(model_status(simulation.model, 2), :private)
        old_history = selection === :none ? nothing : stream(simulation, :writer, 1, :private)
        before_removal = isnothing(old_history) ? nothing : copy(old_history)
        remove_object!(simulation.model, 1)
        step!(simulation)
        @test model_status(simulation.model, 2).live === 4f0
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :writer, 1, :private) === old_history
            @test old_history == before_removal
            @test stream(simulation, :writer, 2, :private) == [(3.0, 6f0), (4.0, 8f0)]
        end
    end
end

@testset "dependency-only temporal streams survive source growth and removal" begin
    simulation = run!(local_scene(; temporal=true); steps=2, outputs=:none)
    @test model_status(simulation.model, 0).seen === 2f0
    original_retention = simulation.output_retention
    @test (:writer, :private) in original_retention.temporal_dependencies
    @test isempty(original_retention.requested_outputs)
    @test stream(simulation, :writer, 1, :private) isa PSE.TemporalDependencyBuffer{Float32}
    register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
    continue!(simulation; steps=2)
    @test model_status(simulation.model, 0).seen === 12f0
    @test PSE._model_output_retention_covers_addition(simulation.output_retention, simulation.compiled)
    @test simulation.output_retention === original_retention
    first_history = stream(simulation, :writer, 1, :private)
    removed_samples = collect(first_history)
    remove_object!(simulation.model, 1)
    step!(simulation)
    @test model_status(simulation.model, 0).seen === 8f0
    @test stream(simulation, :writer, 1, :private) === first_history
    @test collect(first_history) == removed_samples
    @test stream(simulation, :writer, 2, :private) isa PSE.TemporalDependencyBuffer{Float32}
end

struct Distributor <: AbstractRetention_Owner_DistributorModel end
PSE.inputs_(::Distributor) = NamedTuple()
PSE.outputs_(::Distributor) = (delivered=Distributed(Default(0f0)),)
function PSE.run!(::Distributor, status, environment, constants, context)
    destinations = output_targets(context, (:delivered,))
    for index in eachindex(object_ids(destinations))
        destinations.columns.delivered[index] = Float32(context.time)
    end
    return nothing
end
function distributed_scene(; with_leaf=true)
    objects = with_leaf ? (Object(0; scale=:Scene), Object(1; scale=:Leaf, parent=0)) :
        (Object(0; scale=:Scene),)
    return CompositeModel(objects...; applications=(
        ModelSpec(Distributor(); name=:distributed, on=One(id=0),
            outputs_to=(OutputTo(Many(Subtree(); scale=:Leaf); vars=(:delivered,)),)),))
end

@testset "distributed destinations keep none/all/selective retention and removed samples" begin
    request = OutputRequest(Many(scale=:Leaf), :delivered;
        name=:distributed_values, application=:distributed)
    for selection in (:none, :all, request)
        simulation = run!(distributed_scene(); steps=2, outputs=selection)
        register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
        step!(simulation)
        @test model_status(simulation.model, 1).delivered === 3f0
        @test model_status(simulation.model, 2).delivered === 3f0
        old_history = selection === :none ? nothing : stream(simulation, :distributed, 1, :delivered)
        removed_samples = isnothing(old_history) ? nothing : copy(old_history)
        remove_object!(simulation.model, 1)
        step!(simulation)
        @test model_status(simulation.model, 2).delivered === 4f0
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :distributed, 1, :delivered) === old_history
            @test old_history == removed_samples
            @test stream(simulation, :distributed, 2, :delivered) == [(3.0, 3f0), (4.0, 4f0)]
        end
    end
end

@testset "initially empty distributed declarations still retain future outputs" begin
    simulation = run!(distributed_scene(; with_leaf=false); steps=0, outputs=:all)
    @test simulation.output_retention.retained_outputs_by_application[:distributed] == [:delivered]
    @test isempty(simulation.temporal_streams)
    register_object!(simulation.model, Object(1; scale=:Leaf, parent=0))
    step!(simulation)
    @test stream(simulation, :distributed, 1, :delivered) == [(1.0, 1f0)]
    retained_stream = stream(simulation, :distributed, 1, :delivered)
    PSE._initialize_model_output_streams!(simulation.temporal_streams, simulation.compiled,
        simulation.output_retention, 0, [(:distributed, ObjectId(0))])
    @test stream(simulation, :distributed, 1, :delivered) === retained_stream
    @test retained_stream == [(1.0, 1f0)]
end

end
